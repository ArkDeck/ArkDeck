//! The durable host store on NTFS (TASK-XPA-005), against scratch
//! directories: owner-only publication and reads, the refusals the Unix
//! store makes for links, foreign rights and replaced names, mandatory locks
//! that never cover data and die with their process, and a Job journal that
//! a process death tears to a byte prefix, repaired and completed by the next
//! process into exactly the bytes macOS recorded.
#![cfg(windows)]

use arkdeck_platform::{
    DocumentPublishError, ExclusiveOutcome, HostDirectory, HostEntryKind, HostJournal,
    HostJournalAppender, JournalAppendError, JournalWritePoint, OwnerOnlyReadFailure, PayloadCheck,
    application_support_directory, arkdeck_application_support_root, random_bytes,
};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, ErrorKind, Read};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;

struct Scratch(PathBuf);
impl Scratch {
    /// A private root created by the store itself, so its owner and DACL are
    /// the store's whatever the account's default owner is.
    fn new(label: &str) -> (Self, HostDirectory) {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-{label}-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        let root = HostDirectory::open_or_create_private(&path).unwrap();
        (Self(path), root)
    }
    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain([0]).collect()
}

/// Rewrite an entry's DACL through SDDL: `edit` receives the current SDDL.
fn edit_dacl(path: &Path, edit: impl FnOnce(String) -> String) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::*;
    use windows_sys::Win32::Security::*;
    use windows_sys::Win32::Storage::FileSystem::*;
    let file = std::fs::OpenOptions::new()
        .access_mode(READ_CONTROL | WRITE_DAC)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .unwrap();
    let mut descriptor = std::ptr::null_mut();
    // SAFETY: live handle; the descriptor is freed below.
    let status = unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut descriptor,
        )
    };
    assert_eq!(status, 0);
    let mut text = std::ptr::null_mut();
    // SAFETY: a valid descriptor; the string is freed below.
    assert_ne!(
        unsafe {
            ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor,
                SDDL_REVISION_1,
                DACL_SECURITY_INFORMATION,
                &mut text,
                std::ptr::null_mut(),
            )
        },
        0
    );
    let mut length = 0;
    // SAFETY: a NUL-terminated string from the call above.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    // SAFETY: `length` characters precede the terminator.
    let sddl = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).unwrap();
    // SAFETY: allocations returned by the two calls above.
    unsafe {
        LocalFree(text.cast());
        LocalFree(descriptor);
    }
    let sddl = wide(OsStr::new(&edit(sddl)));
    let mut replacement = std::ptr::null_mut();
    // SAFETY: NUL-terminated SDDL; freed below.
    assert_ne!(
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut replacement,
                std::ptr::null_mut(),
            )
        },
        0
    );
    let (mut present, mut dacl, mut defaulted) = (0, std::ptr::null_mut(), 0);
    // SAFETY: a valid descriptor from the call above.
    assert_ne!(
        unsafe { GetSecurityDescriptorDacl(replacement, &mut present, &mut dacl, &mut defaulted) },
        0
    );
    // SAFETY: a live handle with WRITE_DAC and a valid ACL.
    let status = unsafe {
        SetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            dacl,
            std::ptr::null(),
        )
    };
    // SAFETY: the allocation from ConvertStringSecurityDescriptor….
    unsafe { LocalFree(replacement) };
    assert_eq!(status, 0);
}

/// A directory junction (a mount-point reparse point, which needs no
/// privilege) at `link`, naming `target`.
fn junction(link: &Path, target: &Path) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::IO::DeviceIoControl;
    const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
    std::fs::create_dir(link).unwrap();
    let target = target.to_str().unwrap();
    let target = target.strip_prefix(r"\\?\").unwrap_or(target);
    let substitute: Vec<u16> = format!(r"\??\{target}").encode_utf16().collect();
    let substitute_bytes = (substitute.len() * 2) as u16;
    let mut path_buffer = substitute.clone();
    path_buffer.extend([0, 0]);
    let data_length = 8 + path_buffer.len() * 2;
    let mut buffer = Vec::with_capacity(8 + data_length);
    buffer.extend(IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buffer.extend((data_length as u16).to_le_bytes());
    buffer.extend(0u16.to_le_bytes());
    buffer.extend(0u16.to_le_bytes()); // substitute name offset
    buffer.extend(substitute_bytes.to_le_bytes());
    buffer.extend((substitute_bytes + 2).to_le_bytes()); // print name offset
    buffer.extend(0u16.to_le_bytes()); // empty print name
    for unit in path_buffer {
        buffer.extend(unit.to_le_bytes());
    }
    let directory = std::fs::OpenOptions::new()
        .access_mode(FILE_WRITE_ATTRIBUTES | FILE_WRITE_DATA)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(link)
        .unwrap();
    let mut returned = 0;
    // SAFETY: a live directory handle and a complete mount-point buffer.
    let set = unsafe {
        DeviceIoControl(
            directory.as_raw_handle(),
            FSCTL_SET_REPARSE_POINT,
            buffer.as_ptr().cast(),
            buffer.len() as u32,
            std::ptr::null_mut(),
            0,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    assert_ne!(set, 0, "{}", std::io::Error::last_os_error());
}

#[test]
fn private_documents_publish_replace_append_and_read_back() {
    let (scratch, root) = Scratch::new("documents");
    root.probe_writable().unwrap();
    root.publish_document("document.json", b"{\"a\":1}\n", 1024)
        .unwrap();
    let (bytes, first) = root.read_identified("document.json", 1024).unwrap();
    assert_eq!(bytes, b"{\"a\":1}\n");
    // The bytes on disk are exactly the caller's: no newline translation.
    assert_eq!(
        std::fs::read(scratch.join("document.json")).unwrap(),
        b"{\"a\":1}\n"
    );
    assert_eq!(root.file_identity("document.json").unwrap(), first);
    root.publish_document("document.json", b"{\"a\":2}\n", 1024)
        .unwrap();
    let second = root.file_identity("document.json").unwrap();
    assert_ne!(
        (first.device, first.inode),
        (second.device, second.inode),
        "a replace publishes a new file, as a rename does on Unix"
    );
    assert!(matches!(
        root.publish_document("document.json", b"", 1024),
        Err(DocumentPublishError::BeforePublication(_))
    ));
    root.replace_document("ledger", b"", 1024).unwrap();
    assert_eq!(root.read("ledger", 1024).unwrap(), b"");
    root.append_synchronized("ledger", b"one\n").unwrap();
    root.append_synchronized("ledger", b"two\n").unwrap();
    assert_eq!(root.read("ledger", 1024).unwrap(), b"one\ntwo\n");
    assert!(root.read("ledger", 7).is_err(), "larger than the maximum");
    // No temporary survives a publication.
    assert_eq!(root.names(16).unwrap(), ["document.json", "ledger"]);
    assert!(root.names(1).is_err());
    assert_eq!(
        root.kind_and_size("ledger").unwrap(),
        (HostEntryKind::Regular, 8)
    );
    assert_eq!(
        root.owned_kind_and_size("ledger").unwrap(),
        (HostEntryKind::Regular, 8)
    );

    assert_eq!(
        root.create_exclusive_or_match("archive", b"x", 16).unwrap(),
        ExclusiveOutcome::Created
    );
    assert_eq!(
        root.create_exclusive_or_match("archive", b"x", 16).unwrap(),
        ExclusiveOutcome::Matched
    );
    assert_eq!(
        root.create_exclusive_or_match("archive", b"y", 16).unwrap(),
        ExclusiveOutcome::Different
    );
    assert_eq!(root.read_owner_only("absent", 16).unwrap(), None);
    assert_eq!(root.read_owner_only("archive", 16).unwrap().unwrap(), b"x");

    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    root.create_document("payload", b"abc").unwrap();
    assert!(root.create_document("payload", b"abc").is_err());
    root.verify_payload("payload", 3, digest).unwrap();
    assert_eq!(
        root.check_payload("payload", 3, digest).unwrap(),
        PayloadCheck::Verified
    );
    assert_eq!(
        root.check_payload("payload", 2, digest).unwrap(),
        PayloadCheck::TypeOrSize
    );
    assert!(matches!(
        root.check_payload("absent", 3, digest).unwrap(),
        PayloadCheck::Unopenable(_)
    ));
    assert_eq!(
        root.optional_document_digest("payload", 3)
            .unwrap()
            .unwrap(),
        digest
    );
    assert_eq!(root.optional_document_digest("absent", 3).unwrap(), None);
    assert_eq!(
        root.verify_payload_range("payload", 3, digest, 1, 1)
            .unwrap(),
        b"b"
    );
    // Sealed: the owner may read it, and nobody may write it.
    root.seal_document("payload").unwrap();
    root.verify_payload("payload", 3, digest).unwrap();
    assert!(matches!(
        root.read_owner_only_detailed("payload", 16),
        Err(OwnerOnlyReadFailure::Identity)
    ));
    assert_eq!(
        std::fs::OpenOptions::new()
            .write(true)
            .open(scratch.join("payload"))
            .unwrap_err()
            .kind(),
        ErrorKind::PermissionDenied
    );

    let child = root.private_child("jobs").unwrap();
    child.publish_document("job.json", b"{}", 16).unwrap();
    assert!(
        root.private_child("jobs").is_ok(),
        "an existing child is reopened"
    );
    assert!(root.create_private_child("jobs").is_err(), "never adopted");
    let identity = child.directory_identity().unwrap();
    assert!(root.remove_empty_directory("jobs", identity).is_err());
    root.child("jobs").unwrap().remove_tree("job.json").unwrap();
    root.remove_empty_directory("jobs", identity).unwrap();

    let facts = root.export_facts().unwrap();
    assert_eq!(
        (facts.device, facts.inode),
        root.directory_identity().unwrap()
    );
    assert!(
        facts.volume_identity.starts_with("uuid:") && facts.volume_identity.len() == 41,
        "{}",
        facts.volume_identity
    );
    root.validate_path(&scratch.0).unwrap();
    root.sync().unwrap();
}

#[test]
fn paths_must_be_canonical_and_names_single_segments() {
    let (scratch, root) = Scratch::new("canonical");
    let verbatim = scratch.0.to_str().unwrap();
    let plain = PathBuf::from(verbatim.strip_prefix(r"\\?\").unwrap());
    HostDirectory::open(&plain).unwrap();
    root.validate_path(&plain).unwrap();
    // As on Unix, where `Path` equality ignores a trailing separator and a
    // `.` component, only a different component spelling is refused.
    for spelling in [
        plain.display().to_string().to_lowercase(),
        format!(
            r"{}\..\{}",
            plain.display(),
            plain.file_name().unwrap().to_str().unwrap()
        ),
    ] {
        assert!(
            HostDirectory::open(Path::new(&spelling)).is_err(),
            "{spelling}"
        );
    }
    assert!(HostDirectory::open(Path::new("relative")).is_err());
    for name in ["", ".", "..", "a/b", r"a\b", "a:stream", "a*", "a\u{1}"] {
        assert!(root.publish_document(name, b"x", 16).is_err(), "{name:?}");
        assert!(root.lock_document(name).is_err(), "{name:?}");
    }
    assert_eq!(root.names(16).unwrap(), Vec::<String>::new());
}

#[test]
fn links_junctions_and_foreign_rights_are_refused_without_rewriting() {
    let (scratch, root) = Scratch::new("refusals");
    root.publish_document("linked", b"x", 16).unwrap();
    std::fs::hard_link(scratch.join("linked"), scratch.join("second")).unwrap();
    assert!(root.read("linked", 16).is_err(), "a second link");
    assert!(root.owned_kind_and_size("second").is_err());

    let (elsewhere, _) = Scratch::new("elsewhere");
    junction(&scratch.join("junction"), &elsewhere.0);
    assert!(root.child("junction").is_err());
    assert!(root.read("junction", 16).is_err());
    assert_eq!(
        root.kind_and_size("junction").unwrap().0,
        HostEntryKind::Other
    );
    assert!(HostDirectory::open(&scratch.join("junction")).is_err());
    assert!(HostDirectory::open(&scratch.join("junction").join("inner")).is_err());
    assert!(root.remove_tree("junction").is_err());
    assert!(scratch.join("junction").exists(), "never removed");
    assert!(elsewhere.0.exists());

    root.publish_document("public", b"x", 16).unwrap();
    edit_dacl(&scratch.join("public"), |sddl| {
        format!("{sddl}(A;;FR;;;WD)")
    });
    assert!(root.read("public", 16).is_err(), "readable by everyone");
    assert!(root.owned_kind_and_size("public").is_err());
    assert_eq!(
        root.check_payload(
            "public",
            1,
            "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
        )
        .unwrap(),
        PayloadCheck::TypeOrSize
    );
    assert_eq!(std::fs::read(scratch.join("public")).unwrap(), b"x");

    // A Session tree admits content others may read, never content others
    // may write.
    let tree = HostDirectory::open_session_tree(&scratch.0).unwrap();
    assert_eq!(tree.read("public", 16).unwrap(), b"x");
    edit_dacl(&scratch.join("public"), |sddl| {
        format!("{sddl}(A;;FW;;;WD)")
    });
    assert!(tree.read("public", 16).is_err());

    // A root others may write in is not private.
    edit_dacl(&scratch.0, |sddl| format!("{sddl}(A;;FW;;;WD)"));
    assert!(HostDirectory::open(&scratch.0).is_err());
    assert!(root.validate_path(&scratch.0).is_err());
    // Made owner-only again, as `chmod 0700` would.
    HostDirectory::open_or_create_private(&scratch.0).unwrap();
    HostDirectory::open(&scratch.0).unwrap();
}

/// A replacement waits out a moment's holder of the document it replaces
/// (an anti-malware or indexing filter holding it without delete sharing,
/// here a handle of this test released after 100 ms) and then publishes;
/// a holder that stays past the patience refuses it before publication, with
/// the document unchanged.
#[test]
fn a_replacement_waits_out_a_brief_holder_of_the_replaced_document() {
    use std::os::windows::fs::OpenOptionsExt;
    let (scratch, root) = Scratch::new("replace-held");
    root.publish_document("record.json", b"first", 16).unwrap();
    let hold = || {
        std::fs::OpenOptions::new()
            .read(true)
            // FILE_SHARE_READ | FILE_SHARE_WRITE, no FILE_SHARE_DELETE.
            .share_mode(0x1 | 0x2)
            .open(scratch.join("record.json"))
            .unwrap()
    };
    let held = hold();
    let (release, released) = mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        let _ = released.recv_timeout(std::time::Duration::from_millis(100));
        drop(held);
    });
    root.publish_document("record.json", b"second", 16).unwrap();
    drop(release);
    holder.join().unwrap();
    assert_eq!(root.read("record.json", 16).unwrap(), b"second");

    let held = hold();
    assert!(matches!(
        root.publish_document("record.json", b"third", 16),
        Err(DocumentPublishError::BeforePublication(_))
    ));
    drop(held);
    assert_eq!(root.read("record.json", 16).unwrap(), b"second");
    assert_eq!(
        root.names(8).unwrap(),
        vec!["record.json".to_owned()],
        "no staged document is left"
    );
}

#[test]
fn a_reader_keeps_its_bytes_while_the_name_is_replaced_or_removed() {
    let (_scratch, root) = Scratch::new("readers");
    root.publish_document("document.json", b"old", 16).unwrap();
    let document = root.open_document("document.json", 16).unwrap();
    root.publish_document("document.json", b"newer", 16)
        .unwrap();
    let mut held = Vec::new();
    document.pass().read_to_end(&mut held).unwrap();
    assert_eq!(held, b"old");
    assert_eq!(document.read_range(1..3).unwrap(), b"ld");
    assert!(document.check(3).is_err(), "the name links another file");
    assert_eq!(root.read("document.json", 16).unwrap(), b"newer");
    let current = root.open_document("document.json", 16).unwrap();
    let mut read = Vec::new();
    current.pass().read_to_end(&mut read).unwrap();
    current.check(read.len() as u64).unwrap();

    // Staging: moved once, never over an entry, removed by handle.
    let staging = root.private_child(".staging").unwrap();
    let month = root.private_child("2026").unwrap();
    staging
        .create_private_child("first")
        .unwrap()
        .create_document("file", b"x")
        .unwrap();
    staging.create_private_child("second").unwrap();
    assert!(staging.move_exclusive("first", &month, "session").unwrap());
    assert_eq!(
        month.child("session").unwrap().read("file", 16).unwrap(),
        b"x"
    );
    assert!(!staging.move_exclusive("second", &month, "session").unwrap());
    assert!(!root.remove_if_empty(".staging").unwrap());
    staging.remove_tree("second").unwrap();
    staging.remove_tree("second").unwrap();
    drop(staging);
    assert!(root.remove_if_empty(".staging").unwrap());
    assert!(!root.remove_if_empty(".staging").unwrap());

    month
        .child("session")
        .unwrap()
        .publish_exclusive("manifest.json", b"{}")
        .unwrap();
    assert!(matches!(
        month
            .child("session")
            .unwrap()
            .publish_exclusive("manifest.json", b"{}"),
        Err(DocumentPublishError::BeforePublication(_))
    ));
    month
        .child("session")
        .unwrap()
        .append_record("audit", b"a\n")
        .unwrap();
    month
        .child("session")
        .unwrap()
        .append_record("audit", b"b\n")
        .unwrap();
    assert_eq!(
        month.child("session").unwrap().read("audit", 16).unwrap(),
        b"a\nb\n"
    );
}

#[test]
fn locks_exclude_every_other_handle_and_never_cover_data() {
    let (scratch, root) = Scratch::new("locks");
    assert!(root.try_lock_existing("catalog.lock").unwrap().is_none());
    assert_eq!(
        root.try_lock_existing_strict("catalog.lock")
            .err()
            .unwrap()
            .kind(),
        ErrorKind::NotFound
    );
    let held = root.lock_document("catalog.lock").unwrap();
    assert_eq!(
        root.lock_document("catalog.lock").err().unwrap().kind(),
        ErrorKind::WouldBlock
    );
    assert!(root.try_lock_existing("catalog.lock").unwrap().is_none());
    assert!(
        root.try_lock_existing_strict("catalog.lock")
            .unwrap()
            .is_none()
    );
    // The catalog marker is byte 0 of the lock file; the mandatory lock
    // covers a byte far beyond it, so any handle still reads it.
    held.mark_catalog_initialized(&root, "catalog.lock")
        .unwrap();
    held.mark_catalog_initialized(&root, "catalog.lock")
        .unwrap();
    assert_eq!(std::fs::read(scratch.join("catalog.lock")).unwrap(), [0xA5]);
    held.validate_link(&root, "catalog.lock").unwrap();
    drop(held);
    let again = root.try_lock_existing("catalog.lock").unwrap().unwrap();
    drop(again);

    // A blocking waiter gets the lock the moment its holder lets go.
    let held = root.wait_lock("store.lock", true).unwrap();
    let (sender, receiver) = mpsc::channel();
    let path = scratch.0.clone();
    let waiter = std::thread::spawn(move || {
        let root = HostDirectory::open(&path).unwrap();
        let lock = root.wait_lock("store.lock", false).unwrap();
        sender.send(()).unwrap();
        drop(lock);
    });
    assert!(receiver.try_recv().is_err(), "acquired while still held");
    drop(held);
    receiver.recv().unwrap();
    waiter.join().unwrap();
}

/// The other process of the lock and journal tests.
#[test]
fn child_process() {
    let Some(root) = std::env::var_os("ARKDECK_TEST_HOST_STORE_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    match std::env::var("ARKDECK_TEST_HOST_STORE_ROLE")
        .unwrap()
        .as_str()
    {
        "lock" => {
            let directory = HostDirectory::open(&root).unwrap();
            let _lock = directory.lock_document("catalog.lock").unwrap();
            println!("locked");
            // Held until the parent kills this process.
            let _ = std::io::stdin().read_to_end(&mut Vec::new());
            panic!("the parent was to kill this process");
        }
        role => {
            let (stop_at, point) = role.split_once(':').unwrap();
            let stop_at: usize = stop_at.parse().unwrap();
            let point = match point {
                "partial" => JournalWritePoint::AfterPartialRecord,
                _ => JournalWritePoint::AfterRecordSync,
            };
            let (mut appender, bytes) =
                HostJournalAppender::open(&root, false, |_, _| Ok(None)).unwrap();
            let records = recorded_journal();
            let mut index = records
                .iter()
                .scan(0, |end, record| {
                    *end += record.len();
                    Some(*end)
                })
                .position(|end| end == bytes.len())
                .map_or(0, |position| position + 1);
            while index < records.len() {
                appender
                    .append_with_checkpoint(
                        records[index],
                        |_| Ok(()),
                        |reached| {
                            if index == stop_at && reached == point {
                                std::process::exit(86);
                            }
                        },
                    )
                    .unwrap();
                index += 1;
            }
            panic!("the requested checkpoint was not reached");
        }
    }
}

fn child(root: &Path, role: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "child_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("ARKDECK_TEST_HOST_STORE_ROOT", root)
        .env("ARKDECK_TEST_HOST_STORE_ROLE", role);
    command
}

#[test]
fn a_lock_dies_with_its_process() {
    let (scratch, root) = Scratch::new("lock-death");
    let mut holder = child(&scratch.0, "lock")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(holder.stdout.take().unwrap()).lines();
    assert!(
        // libtest prints the test's name on the same line first.
        lines.any(|line| line.unwrap().ends_with("locked")),
        "the child never reported its lock"
    );
    assert!(root.try_lock_existing("catalog.lock").unwrap().is_none());
    holder.kill().unwrap();
    holder.wait().unwrap();
    // Released at once by the holder's death, never by a timeout.
    assert!(root.try_lock_existing("catalog.lock").unwrap().is_some());
}

/// A Job journal macOS recorded (Swift's oracle run, `agent-execution`).
fn recorded_journal() -> Vec<&'static [u8]> {
    static BYTES: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    let bytes = BYTES.get_or_init(|| {
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../tests/fixtures/agent-execution/store/jobs/\
                 job-73b1cb9a96d12a0ea736a065afdf5abd/journal.jsonl",
        ))
        .unwrap()
    });
    bytes.split_inclusive(|byte| *byte == b'\n').collect()
}

/// Swift's replay repair: keep through the last complete record.
fn keep_complete_records(bytes: &[u8], _terminal: bool) -> std::io::Result<Option<u64>> {
    let keep = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1);
    Ok((keep != bytes.len()).then_some(keep as u64))
}

#[test]
fn a_job_journal_survives_process_death_as_a_byte_prefix_and_completes_to_the_recorded_bytes() {
    let records = recorded_journal();
    assert!(records.len() >= 3, "the recorded journal has records");
    let expected: Vec<u8> = records.concat();
    for (stop_at, point) in [
        (0, "partial"),
        (1, "partial"),
        (1, "synced"),
        (records.len() - 1, "partial"),
    ] {
        let (scratch, _) = Scratch::new("journal");
        HostJournalAppender::open(&scratch.0, true, |bytes, terminal| {
            assert!(bytes.is_empty() && !terminal);
            Ok(None)
        })
        .unwrap();
        let died = child(&scratch.0, &format!("{stop_at}:{point}"))
            .stdout(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(died.status.code(), Some(86), "{died:?}");

        // What the dead writer left is a prefix of what it was writing.
        let left = std::fs::read(scratch.join("journal.jsonl")).unwrap();
        let through: usize = records[..=stop_at].iter().map(|r| r.len()).sum();
        let before: usize = records[..stop_at].iter().map(|r| r.len()).sum();
        assert_eq!(left, expected[..left.len()]);
        if point == "partial" {
            assert!(
                left.len() > before && left.len() < through,
                "{}",
                left.len()
            );
        } else {
            assert_eq!(left.len(), through);
        }

        // The next process repairs the torn tail and completes the journal.
        let (mut appender, kept) =
            HostJournalAppender::open(&scratch.0, false, keep_complete_records).unwrap();
        assert_eq!(kept, expected[..kept.len()]);
        assert_eq!(
            kept.len(),
            if point == "partial" { before } else { through }
        );
        for record in records.iter().skip(if point == "partial" {
            stop_at
        } else {
            stop_at + 1
        }) {
            appender.append(record, |_| Ok(())).unwrap();
        }
        assert_eq!(
            std::fs::read(scratch.join("journal.jsonl")).unwrap(),
            expected
        );

        // Read back as the event reader reads it, under the same lock.
        let journal = HostJournal::open(&scratch.0).unwrap();
        assert_eq!(journal.byte_count(), expected.len() as u64);
        assert_eq!(journal.read(0, expected.len()).unwrap(), expected);
        let key = journal.cursor_key(false).unwrap();
        assert_eq!(journal.cursor_key(true).unwrap(), key);
        journal.validate().unwrap();
        drop(journal);

        // After terminal publication nothing more is appended.
        let directory = HostDirectory::open(&scratch.0).unwrap();
        directory
            .publish_exclusive("manifest.json", b"{}\n")
            .unwrap();
        assert!(matches!(
            appender.append(b"{}\n", |_| Ok(())),
            Err(JournalAppendError::Refused(_))
        ));
        assert!(
            HostJournalAppender::open(&scratch.0, false, |_, terminal| {
                assert!(terminal);
                Ok(Some(0))
            })
            .is_err()
        );
    }
}

#[test]
fn the_state_root_is_the_accounts_known_folder_not_the_environment() {
    let directory = application_support_directory().unwrap();
    assert!(
        directory.is_absolute() && directory.is_dir(),
        "{}",
        directory.display()
    );
    assert_eq!(
        arkdeck_application_support_root().unwrap(),
        directory.join("ArkDeck")
    );
    if let Some(printed) = std::env::var_os("ARKDECK_TEST_PRINT_STATE_ROOT") {
        assert_eq!(printed, "1");
        println!("state-root={}", directory.display());
        return;
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "the_state_root_is_the_accounts_known_folder_not_the_environment",
            "--nocapture",
        ])
        .env("ARKDECK_TEST_PRINT_STATE_ROOT", "1")
        .env("LOCALAPPDATA", r"C:\elsewhere")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let printed = String::from_utf8(output.stdout).unwrap();
    assert!(
        printed.contains(&format!("state-root={}", directory.display())),
        "{printed}"
    );
}
