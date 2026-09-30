//! Executable NTFS durability probe for SPK-5 (CHG-2026-074, TASK-XPA-005 write path).
//! It measures host facts only: no Runtime store, device, capability or journal
//! decision is involved, and no result is product or platform acceptance.
//!
//! `cargo run --release -p arkdeck-platform --example windows_spk5 -- all <work-dir>...`
//! prints one JSON document per work directory. The `child-*` commands are the
//! processes the parent kills or races; they are not meant to be run by hand.

#[cfg(not(windows))]
fn main() {
    println!(r#"{{"probe":"spk5","error":"Windows only"}}"#);
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    if let Err(error) = windows::run() {
        println!(
            "{}",
            serde_json::json!({"probe":"spk5", "error":error.to_string(), "osError":error.raw_os_error()})
        );
        std::process::exit(1);
    }
}

#[cfg(windows)]
mod windows {
    use serde_json::{Value, json};
    use std::ffi::{OsStr, OsString};
    use std::fs::{File, OpenOptions};
    use std::io::{self, BufRead, BufReader, Read, Write};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{
        ERROR_LOCK_VIOLATION, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, DELETE, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_WRITE_THROUGH, FILE_ID_INFO,
        FILE_RENAME_INFO, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FileIdInfo,
        FileRenameInfoEx, FlushFileBuffers, GetFileInformationByHandleEx, LOCKFILE_EXCLUSIVE_LOCK,
        LOCKFILE_FAIL_IMMEDIATELY, LockFileEx, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        MoveFileExW, OPEN_EXISTING, SetFileInformationByHandle, UnlockFileEx,
    };
    use windows_sys::Win32::System::IO::OVERLAPPED;

    // winbase.h; not exported by windows-sys.
    const FILE_RENAME_FLAG_REPLACE_IF_EXISTS: u32 = 0x1;
    const FILE_RENAME_FLAG_POSIX_SEMANTICS: u32 = 0x2;

    pub fn run() -> io::Result<()> {
        let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
        let command = arguments.first().and_then(|v| v.to_str()).unwrap_or("");
        let rest = &arguments[arguments.len().min(1)..];
        match command {
            "all" => {
                // `--journals N` bounds the exhaustive matrix to N sampled Journals (default 16),
                // for volumes where every file operation is scanned and the full run is slow.
                let (sample, directories) = match rest.first().and_then(|v| v.to_str()) {
                    Some("--journals") => {
                        let count = rest
                            .get(1)
                            .and_then(|v| v.to_str())
                            .and_then(|v| v.parse().ok());
                        (
                            count.ok_or_else(|| invalid("--journals <count>"))?,
                            &rest[rest.len().min(2)..],
                        )
                    }
                    _ => (16usize, rest),
                };
                if directories.is_empty() {
                    return Err(invalid("all [--journals N] <work-dir>..."));
                }
                for directory in directories {
                    let report = all(Path::new(directory), sample)?;
                    println!("{}", serde_json::to_string_pretty(&report)?);
                }
                Ok(())
            }
            "child-append" => child_append(rest),
            "child-lock" => child_lock(rest),
            _ => Err(invalid("expected all <work-dir>...")),
        }
    }

    fn invalid(message: &str) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidInput, message.to_string())
    }

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain([0]).collect()
    }

    fn check(ok: i32) -> io::Result<()> {
        if ok != 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    fn outcome(result: io::Result<()>) -> Value {
        outcome_of(&result)
    }

    fn outcome_of(result: &io::Result<()>) -> Value {
        match result {
            Ok(()) => json!({"ok": true}),
            Err(error) => {
                json!({"ok": false, "osError": error.raw_os_error(), "error": error.to_string()})
            }
        }
    }

    fn open_raw(path: &Path, access: u32, share: u32, flags: u32) -> io::Result<File> {
        let name = wide(path);
        // SAFETY: a NUL-terminated wide path; the returned handle is owned by the File.
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                access,
                share,
                std::ptr::null(),
                OPEN_EXISTING,
                flags,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: CreateFileW returned a new owned handle.
        Ok(unsafe { File::from_raw_handle(handle as _) })
    }

    fn flush(file: &File) -> io::Result<()> {
        // SAFETY: a live handle owned by `file`.
        check(unsafe { FlushFileBuffers(file.as_raw_handle() as HANDLE) })
    }

    /// Volume serial number and 128-bit file identifier.
    fn file_id(file: &File) -> io::Result<String> {
        let mut info = FILE_ID_INFO::default();
        // SAFETY: the buffer is a FILE_ID_INFO of the stated size.
        check(unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle() as HANDLE,
                FileIdInfo,
                (&mut info as *mut FILE_ID_INFO).cast(),
                size_of::<FILE_ID_INFO>() as u32,
            )
        })?;
        let id: String = info
            .FileId
            .Identifier
            .iter()
            .rev()
            .map(|b| format!("{b:02x}"))
            .collect();
        Ok(format!("{:016x}:{id}", info.VolumeSerialNumber))
    }

    fn id_of(path: &Path) -> io::Result<String> {
        file_id(&open_raw(
            path,
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0,
        )?)
    }

    fn lock(file: &File) -> io::Result<()> {
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        // SAFETY: a live handle and a zeroed OVERLAPPED at offset 0; the whole range is locked.
        check(unsafe {
            LockFileEx(
                file.as_raw_handle() as HANDLE,
                LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                0,
                u32::MAX,
                u32::MAX,
                &mut overlapped,
            )
        })
    }

    fn unlock(file: &File) -> io::Result<()> {
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        // SAFETY: as in `lock`.
        check(unsafe {
            UnlockFileEx(
                file.as_raw_handle() as HANDLE,
                0,
                u32::MAX,
                u32::MAX,
                &mut overlapped,
            )
        })
    }

    fn fresh(directory: &Path, name: &str) -> io::Result<PathBuf> {
        let path = directory.join(name);
        match std::fs::remove_dir_all(&path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        std::fs::create_dir_all(&path)?;
        Ok(path)
    }

    fn all(root: &Path, sample: usize) -> io::Result<Value> {
        std::fs::create_dir_all(root)?;
        let root = root.canonicalize()?;
        let journals = fixture_journals()?;
        Ok(json!({
            "probe": "spk5",
            "workDirectory": root.display().to_string(),
            "directoryFlush": directory_flush(&fresh(&root, "dir-flush")?)?,
            "identity": identity(&fresh(&root, "identity")?)?,
            "replace": replace(&fresh(&root, "replace")?)?,
            "lock": lock_semantics(&fresh(&root, "lock")?)?,
            "tornTail": torn_tail(&fresh(&root, "torn")?, &journals, sample)?,
            "appendLatency": append_latency(&fresh(&root, "latency")?, &journals)?,
        }))
    }

    // ------------------------------------------------------------ directory flush

    fn directory_flush(directory: &Path) -> io::Result<Value> {
        let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        let mut rows = serde_json::Map::new();
        for (label, access) in [
            ("read", GENERIC_READ),
            ("readWrite", GENERIC_READ | GENERIC_WRITE),
        ] {
            let row = match open_raw(directory, access, share, FILE_FLAG_BACKUP_SEMANTICS) {
                Ok(handle) => json!({"open": {"ok": true}, "flush": outcome(flush(&handle))}),
                Err(error) => json!({"open": outcome(Err(error))}),
            };
            rows.insert(label.into(), row);
        }
        Ok(Value::Object(rows))
    }

    // ------------------------------------------------------------ identity

    fn identity(directory: &Path) -> io::Result<Value> {
        let a = directory.join("a");
        let b = directory.join("b");
        std::fs::write(&a, b"a")?;
        std::fs::write(&b, b"b")?;
        let first = id_of(&a)?;
        let again = id_of(&a)?;
        let other = id_of(&b)?;
        std::fs::write(&a, b"rewritten in place")?;
        let rewritten = id_of(&a)?;
        Ok(json!({
            "stableAcrossOpens": first == again,
            "distinctFiles": first != other,
            "stableAcrossInPlaceRewrite": first == rewritten,
            "example": first,
        }))
    }

    // ------------------------------------------------------------ atomic replace

    fn move_replace(from: &Path, to: &Path) -> io::Result<()> {
        let (from, to) = (wide(from), wide(to));
        // SAFETY: two NUL-terminated wide paths.
        check(unsafe {
            MoveFileExW(
                from.as_ptr(),
                to.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        })
    }

    fn posix_rename(from: &Path, to: &Path) -> io::Result<()> {
        let source = open_raw(
            from,
            DELETE | GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0,
        )?;
        let target: Vec<u16> = to.as_os_str().encode_wide().collect();
        let header = std::mem::offset_of!(FILE_RENAME_INFO, FileName);
        let size = header + target.len() * 2 + 2;
        let mut buffer = vec![0u64; size.div_ceil(8)];
        // SAFETY: the u64 buffer is aligned for and at least as large as the variable-length struct.
        unsafe {
            let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFO>();
            (*info).Anonymous.Flags =
                FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
            (*info).RootDirectory = std::ptr::null_mut();
            (*info).FileNameLength = (target.len() * 2) as u32;
            std::ptr::copy_nonoverlapping(
                target.as_ptr(),
                (*info).FileName.as_mut_ptr(),
                target.len(),
            );
            check(SetFileInformationByHandle(
                source.as_raw_handle() as HANDLE,
                FileRenameInfoEx,
                info.cast(),
                size as u32,
            ))
        }
    }

    fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let mut file = File::create(path)?;
        file.write_all(bytes)?;
        flush(&file)
    }

    type Rename = fn(&Path, &Path) -> io::Result<()>;

    fn replace_case(
        directory: &Path,
        method: Rename,
        holder_share: Option<u32>,
    ) -> io::Result<Value> {
        let target = directory.join("record.json");
        let temporary = directory.join(".record.json.tmp");
        write_synced(&target, b"old")?;
        let old_id = id_of(&target)?;
        write_synced(&temporary, b"new")?;
        let new_id = id_of(&temporary)?;
        let holder = match holder_share {
            Some(share) => Some(open_raw(&target, GENERIC_READ, share, 0)?),
            None => None,
        };
        let result = method(&temporary, &target);
        let mut row = json!({"replace": outcome_of(&result)});
        if let Some(mut holder) = holder {
            let mut seen = Vec::new();
            holder.read_to_end(&mut seen)?;
            row["holderReads"] = json!(String::from_utf8_lossy(&seen));
        }
        if result.is_ok() {
            row["targetContent"] = json!(String::from_utf8_lossy(&std::fs::read(&target)?));
            row["targetIdIsSourceId"] = json!(id_of(&target)? == new_id);
            row["targetIdIsOldId"] = json!(id_of(&target)? == old_id);
            row["sourceStillExists"] = json!(temporary.exists());
        }
        let _ = std::fs::remove_file(&temporary);
        let _ = std::fs::remove_file(&target);
        Ok(row)
    }

    fn replace(directory: &Path) -> io::Result<Value> {
        let read_write = FILE_SHARE_READ | FILE_SHARE_WRITE;
        let all = read_write | FILE_SHARE_DELETE;
        let mut rows = serde_json::Map::new();
        for (label, method) in [
            ("moveFileExWriteThrough", move_replace as Rename),
            ("posixRenameInfoEx", posix_rename as Rename),
        ] {
            rows.insert(
                label.into(),
                json!({
                    "unopenedTarget": replace_case(directory, method, None)?,
                    "targetOpenWithoutShareDelete": replace_case(directory, method, Some(read_write))?,
                    "targetOpenWithShareDelete": replace_case(directory, method, Some(all))?,
                }),
            );
        }
        Ok(Value::Object(rows))
    }

    // ------------------------------------------------------------ LockFileEx

    fn spawn_self(arguments: &[&OsStr]) -> io::Result<Child> {
        Command::new(std::env::current_exe()?)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
    }

    fn read_line(child: &mut Child) -> io::Result<String> {
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().ok_or_else(|| invalid("no stdout"))?)
            .read_line(&mut line)?;
        Ok(line.trim().to_string())
    }

    fn child_lock(arguments: &[OsString]) -> io::Result<()> {
        let path = Path::new(
            arguments
                .first()
                .ok_or_else(|| invalid("child-lock <file> try|hold"))?,
        );
        let mode = arguments.get(1).and_then(|v| v.to_str()).unwrap_or("try");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .open(path)?;
        let result = lock(&file);
        println!("{}", json!({"lock": outcome_of(&result)}));
        io::stdout().flush()?;
        if mode == "hold" && result.is_ok() {
            std::thread::sleep(Duration::from_secs(120));
        }
        Ok(())
    }

    fn lock_semantics(directory: &Path) -> io::Result<Value> {
        let path = directory.join(".manifest.lock");
        let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        std::fs::write(&path, b"lock-file-content")?;
        let open = || {
            OpenOptions::new()
                .read(true)
                .write(true)
                .share_mode(share)
                .open(&path)
        };
        let first = open()?;
        let second = open()?;
        let acquired = outcome(lock(&first));
        let same_process_second_handle = lock(&second);
        let mut buffer = [0u8; 4];
        let read_through_second_handle = (&second).read(&mut buffer).map(|_| ());
        let mut other = spawn_self(&[
            OsStr::new("child-lock"),
            path.as_os_str(),
            OsStr::new("try"),
        ])?;
        let other_process = read_line(&mut other)?;
        other.wait()?;
        unlock(&first)?;
        let after_unlock = outcome(lock(&second));
        unlock(&second)?;
        drop((first, second));

        // A holder killed while it holds the lock: how soon may the next owner take it?
        let mut holder = spawn_self(&[
            OsStr::new("child-lock"),
            path.as_os_str(),
            OsStr::new("hold"),
        ])?;
        let holder_line = read_line(&mut holder)?;
        let waiter = open()?;
        let while_held = lock(&waiter).is_err();
        holder.kill()?;
        holder.wait()?;
        let killed = Instant::now();
        let mut attempts = 0u32;
        let released = loop {
            attempts += 1;
            if lock(&waiter).is_ok() {
                break Some(killed.elapsed());
            }
            if killed.elapsed() > Duration::from_secs(10) {
                break None;
            }
            std::thread::sleep(Duration::from_millis(1));
        };
        Ok(json!({
            "firstHandle": acquired,
            "secondHandleSameProcess": outcome(same_process_second_handle),
            "readOfLockedRangeThroughSecondHandle": outcome(read_through_second_handle),
            "lockViolationCode": ERROR_LOCK_VIOLATION,
            "otherProcess": serde_json::from_str::<Value>(&other_process).unwrap_or(json!(other_process)),
            "secondHandleAfterUnlock": after_unlock,
            "killedHolder": {
                "holderAcquired": serde_json::from_str::<Value>(&holder_line).unwrap_or(json!(holder_line)),
                "refusedWhileHeld": while_held,
                "acquiredAfterKillMs": released.map(|d| d.as_secs_f64() * 1000.0),
                "attempts": attempts,
            },
        }))
    }

    // ------------------------------------------------------------ torn tail

    /// The recorded Swift Journals the fixtures hold: each `.jsonl` whose first record
    /// is a `jobCreated`, as `job_journal_replay`'s own fixture test selects them.
    fn fixture_journals() -> io::Result<Vec<(PathBuf, Vec<u8>)>> {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures");
        let mut found = Vec::new();
        let mut pending = vec![root];
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(&directory)? {
                let path = entry?.path();
                if path.is_dir() {
                    pending.push(path);
                } else if path.extension().is_some_and(|e| e == "jsonl") {
                    let bytes = std::fs::read(&path)?;
                    let first = bytes.split(|b| *b == b'\n').next().unwrap_or_default();
                    let created = serde_json::from_slice::<Value>(first)
                        .is_ok_and(|v| v["kind"] == "jobCreated");
                    if created && bytes.ends_with(b"\n") {
                        found.push((path, bytes));
                    }
                }
            }
        }
        found.sort();
        Ok(found)
    }

    /// `ReplayState::replay`'s split: the durable length ends at the last LF.
    fn durable_length(bytes: &[u8]) -> usize {
        bytes.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1)
    }

    fn records(bytes: &[u8]) -> Vec<&[u8]> {
        bytes.split_inclusive(|b| *b == b'\n').collect()
    }

    /// Open, repair a torn tail by truncating to the durable length, flush, reread.
    fn repair(path: &Path) -> io::Result<Vec<u8>> {
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        let bytes = std::fs::read(path)?;
        let keep = durable_length(&bytes);
        if keep != bytes.len() {
            file.set_len(keep as u64)?;
            flush(&file)?;
        }
        drop(file);
        std::fs::read(path)
    }

    fn open_append(path: &Path, write_through: bool) -> io::Result<File> {
        let mut options = OpenOptions::new();
        options
            .append(true)
            .create(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
        if write_through {
            options.custom_flags(FILE_FLAG_WRITE_THROUGH);
        }
        options.open(path)
    }

    /// The Unix appender's discipline: the first half, a checkpoint, the rest, a full flush.
    fn append_record(
        file: &mut File,
        record: &[u8],
        checkpoint: &mut dyn FnMut(&str) -> io::Result<()>,
    ) -> io::Result<()> {
        let first = (record.len() / 2).max(1);
        file.write_all(&record[..first])?;
        checkpoint("partial")?;
        file.write_all(&record[first..])?;
        flush(file)?;
        checkpoint("synced")
    }

    /// Writes the records of `source` to `target`; in `step` mode it reports each
    /// checkpoint and waits for a line on stdin before going on.
    fn child_append(arguments: &[OsString]) -> io::Result<()> {
        let usage = || invalid("child-append <source> <target> step|free");
        let source = Path::new(arguments.first().ok_or_else(usage)?);
        let target = Path::new(arguments.get(1).ok_or_else(usage)?);
        let step = arguments.get(2).and_then(|v| v.to_str()) == Some("step");
        let bytes = std::fs::read(source)?;
        let mut file = open_append(target, false)?;
        let stdin = io::stdin();
        let mut index = 0usize;
        loop {
            for record in records(&bytes) {
                append_record(&mut file, record, &mut |point| {
                    if step {
                        println!("{index} {point}");
                        io::stdout().flush()?;
                        let mut line = String::new();
                        stdin.lock().read_line(&mut line)?;
                    }
                    Ok(())
                })?;
                index += 1;
            }
            if step {
                return Ok(());
            }
        }
    }

    fn torn_tail(
        directory: &Path,
        journals: &[(PathBuf, Vec<u8>)],
        count: usize,
    ) -> io::Result<Value> {
        // 1. Exhaustive: every byte length of every sampled Journal, written through the
        //    appender's calls, then repaired; the repair must keep exactly the complete records.
        let sample: Vec<&(PathBuf, Vec<u8>)> = journals
            .iter()
            .step_by((journals.len() / count.max(1)).max(1))
            .collect();
        let started = Instant::now();
        let (mut cases, mut failures) = (0u64, Vec::new());
        let path = directory.join("journal.jsonl");
        for (name, bytes) in &sample {
            for length in 0..=bytes.len() {
                let _ = std::fs::remove_file(&path);
                // The prefix is left in the cache; the repair's own flush is what is measured.
                let mut file = open_append(&path, false)?;
                file.write_all(&bytes[..length])?;
                drop(file);
                let repaired = repair(&path)?;
                let expected = &bytes[..durable_length(&bytes[..length])];
                cases += 1;
                if repaired != expected && failures.len() < 10 {
                    failures.push(json!({"journal": name.display().to_string(), "length": length}));
                }
            }
        }
        let exhaustive = json!({
            "journalsAvailable": journals.len(),
            "journalsSampled": sample.len(),
            "cases": cases,
            "failures": failures,
            "seconds": started.elapsed().as_secs_f64(),
        });

        // 2. Kill at every checkpoint of one Journal: after the first half of each record
        //    and after its flush. On disk there must be the exact prefix written, and the
        //    repair must keep exactly the records completed before the kill.
        let (source_name, source) = journals
            .iter()
            .filter(|(_, b)| records(b).len() >= 8)
            .min_by_key(|(_, b)| b.len())
            .ok_or_else(|| invalid("no fixture Journal with eight records"))?;
        let parts = records(source);
        let (mut checkpoint_cases, mut checkpoint_failures) = (0u32, Vec::new());
        for target_index in 0..parts.len() {
            for point in ["partial", "synced"] {
                let target = directory.join("killed.jsonl");
                let _ = std::fs::remove_file(&target);
                let mut child = spawn_self(&[
                    OsStr::new("child-append"),
                    source_name.as_os_str(),
                    target.as_os_str(),
                    OsStr::new("step"),
                ])?;
                loop {
                    let line = read_line(&mut child)?;
                    if line == format!("{target_index} {point}") {
                        break;
                    }
                    child
                        .stdin
                        .as_mut()
                        .ok_or_else(|| invalid("no stdin"))?
                        .write_all(b"\n")?;
                }
                child.kill()?;
                child.wait()?;
                let on_disk = std::fs::read(&target)?;
                let complete: usize = parts[..target_index].iter().map(|r| r.len()).sum();
                let written = if point == "partial" {
                    complete + (parts[target_index].len() / 2).max(1)
                } else {
                    complete + parts[target_index].len()
                };
                let repaired = repair(&target)?;
                let keep = if point == "partial" {
                    complete
                } else {
                    written
                };
                checkpoint_cases += 1;
                if on_disk != source[..written] || repaired != source[..keep] {
                    checkpoint_failures.push(json!({"record": target_index, "point": point, "onDisk": on_disk.len(), "expected": written}));
                }
            }
        }

        // 3. Kill at arbitrary moments of a free-running appender; the file must always be
        //    a byte prefix of the stream, and the repair a whole number of records.
        let stream: Vec<u8> = source.repeat(4096);
        let (mut random_cases, mut random_failures, mut torn_seen) = (0u32, Vec::new(), 0u32);
        let mut state = 0x2545_f491_4f6c_dd1du64;
        for _ in 0..200 {
            let target = directory.join("random.jsonl");
            let _ = std::fs::remove_file(&target);
            let mut child = spawn_self(&[
                OsStr::new("child-append"),
                source_name.as_os_str(),
                target.as_os_str(),
                OsStr::new("free"),
            ])?;
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            std::thread::sleep(Duration::from_micros(20_000 + state % 60_000));
            child.kill()?;
            child.wait()?;
            let on_disk = std::fs::read(&target)?;
            let repaired = repair(&target)?;
            random_cases += 1;
            torn_seen += u32::from(durable_length(&on_disk) != on_disk.len());
            let prefix = on_disk.len() <= stream.len() && on_disk == stream[..on_disk.len()];
            if !prefix || repaired != stream[..durable_length(&on_disk)] {
                random_failures.push(json!({"length": on_disk.len(), "prefix": prefix}));
            }
        }
        Ok(json!({
            "exhaustiveTruncationRepair": exhaustive,
            "killAtCheckpoints": {"journal": source_name.file_name().map(|n| n.to_string_lossy().to_string()), "records": parts.len(), "cases": checkpoint_cases, "failures": checkpoint_failures},
            "killAtRandom": {"cases": random_cases, "tornTailsObserved": torn_seen, "failures": random_failures},
            "notCovered": "power loss and OS crash: a process kill leaves the cache intact, so only its ordering is tested here",
        }))
    }

    // ------------------------------------------------------------ append latency

    fn percentiles(mut samples: Vec<f64>) -> Value {
        samples.sort_by(f64::total_cmp);
        let at = |q: f64| samples[((samples.len() as f64 - 1.0) * q).round() as usize];
        json!({"n": samples.len(), "p50Ms": at(0.50), "p95Ms": at(0.95), "p99Ms": at(0.99), "maxMs": at(1.0)})
    }

    fn append_latency(directory: &Path, journals: &[(PathBuf, Vec<u8>)]) -> io::Result<Value> {
        let corpus: Vec<&[u8]> = journals
            .iter()
            .flat_map(|(_, b)| records(b))
            .take(1000)
            .collect();
        let mean = corpus.iter().map(|r| r.len()).sum::<usize>() as f64 / corpus.len() as f64;
        let share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        let mut rows = serde_json::Map::new();
        for (label, write_through, directory_flush) in [
            ("flushFileBuffers", false, false),
            ("flushFileBuffersAndDirectory", false, true),
            ("writeThroughHandleAndFlush", true, false),
        ] {
            let path = directory.join(format!("{label}.jsonl"));
            let mut file = open_append(&path, write_through)?;
            let parent = if directory_flush {
                Some(open_raw(
                    directory,
                    GENERIC_READ | GENERIC_WRITE,
                    share,
                    FILE_FLAG_BACKUP_SEMANTICS,
                )?)
            } else {
                None
            };
            let mut samples = Vec::with_capacity(corpus.len());
            for record in &corpus {
                let started = Instant::now();
                append_record(&mut file, record, &mut |_| Ok(()))?;
                if let Some(parent) = &parent {
                    flush(parent)?;
                }
                samples.push(started.elapsed().as_secs_f64() * 1000.0);
            }
            rows.insert(label.into(), percentiles(samples));
        }
        rows.insert("meanRecordBytes".into(), json!(mean));
        rows.insert("budget".into(), json!("append <= 10 ms p95 (design §I.2)"));
        Ok(Value::Object(rows))
    }
}
