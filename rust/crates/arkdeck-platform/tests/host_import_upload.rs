//! The host store's import-upload submodule (TASK-XPA-008), the same tests on
//! macOS and on NTFS: a recorded Import source read by identity, staged,
//! recovered and published to exactly the bytes and digests the recorded
//! Swift run holds; a source whose identity changes mid-read, or that is a
//! link, refused; an existing Artifact never replaced; and a writer killed
//! inside an upload or a publication leaving torn staging but no Artifact.
#![cfg(any(target_os = "macos", windows))]

use arkdeck_platform::{
    DocumentPublishError, HostDirectory, HostImportSource, HostUploadFile, PayloadCheck,
    UploadChunkCheckpoint, UploadWritePoint, random_bytes,
};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::process::Command;

const SOURCE_SHA256: &str = "399a301718f951e835b8630ac1666120b96eefb28da9e37f568596a227a9b67a";
const PREFIX_SHA256: &str = "7bd630e3a9e10785bec667023d0257f6fc138081489a20ef766e519639cd363d";
const STAGE: &str = "imp-dcb7943f-d934-43da-b290-65d0066cae35.stage";
const RECORD: &str = "820b32aa8487dc3a30d8c271b9277068d791f76f8fad5be8d4a3b9a9f0d9dac9.json";
const ABORTED_RECORD: &str =
    "7fc7da249ba203421a7397b17a9688f3451d41163fc2f43a383414a17ca34f13.json";
const ARTIFACT: &str = "ART-0123456789abcdef0123456789abcdef";

/// The macOS-recorded Import fixture the hoststore owner test replays.
fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/import-upload-current")
        .join(path)
}
fn source_bytes() -> Vec<u8> {
    std::fs::read(fixture("fixture.hap")).unwrap()
}
fn recorded_stage() -> Vec<u8> {
    std::fs::read(fixture(&format!("artifacts/.imports-v1/payloads/{STAGE}"))).unwrap()
}
fn recorded(name: &str) -> Vec<u8> {
    std::fs::read(fixture(&format!("artifacts/.imports-v1/records/{name}"))).unwrap()
}
fn sha256(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}
/// The recorded record's committed chunk.
fn committed() -> Vec<UploadChunkCheckpoint> {
    vec![UploadChunkCheckpoint {
        offset: 0,
        byte_count: 2048,
        sha256: PREFIX_SHA256.into(),
    }]
}

/// A private (`0700` / owner-only) root created by the store itself.
struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> (Self, HostDirectory) {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-import-{label}-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        let root = HostDirectory::open_or_create_private(&path).unwrap();
        (Self(path.canonicalize().unwrap()), root)
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

/// A new last-write time on `path`, through a handle that asks for nothing
/// a reader's share mode could refuse: what an editor or a copy tool may do
/// to a file another process is reading.
fn touch(path: &Path) {
    #[cfg(windows)]
    let file = {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES,
        };
        std::fs::OpenOptions::new()
            .access_mode(FILE_WRITE_ATTRIBUTES)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .open(path)
            .unwrap()
    };
    #[cfg(not(windows))]
    let file = std::fs::File::open(path).unwrap();
    file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000))
        .unwrap();
}

#[test]
fn a_recorded_source_imports_through_staging_to_the_recorded_bytes() {
    let bytes = source_bytes();
    let source =
        HostImportSource::open(&fixture("fixture.hap"), 64 * 1024 * 1024, || Ok(())).unwrap();
    assert_eq!(source.name, "fixture.hap");
    assert_eq!(source.byte_count, 4096);
    assert_eq!(source.sha256, SOURCE_SHA256);
    assert_eq!(sha256(&bytes), SOURCE_SHA256);
    assert!(source.chunk(4000, 97).is_err(), "beyond the source");
    assert!(source.chunk(0, 0).is_err());

    let (scratch, root) = Scratch::new("recorded");
    let payloads = root.private_child("payloads").unwrap();
    let artifacts = root.private_child("artifacts").unwrap();
    let records = root.private_child("records").unwrap();

    // An absent committed prefix is never replaced by a new empty stage.
    assert_eq!(
        HostUploadFile::open(&payloads, STAGE, false)
            .err()
            .unwrap()
            .kind(),
        ErrorKind::NotFound
    );
    assert!(HostUploadFile::open(&payloads, "imp-not-an-import.stage", true).is_err());
    let mut file = HostUploadFile::open(&payloads, STAGE, true).unwrap();
    assert_eq!(file.byte_count().unwrap(), 0);
    assert!(
        file.append(0, &source.chunk(0, 2048).unwrap(), SOURCE_SHA256)
            .is_err(),
        "a chunk whose digest differs is refused"
    );
    assert!(
        file.append(1, &source.chunk(0, 2048).unwrap(), PREFIX_SHA256)
            .is_err()
    );
    file.append(0, &source.chunk(0, 2048).unwrap(), PREFIX_SHA256)
        .unwrap();
    drop(file);
    // T0: the committed prefix is the recorded Swift stage, byte for byte.
    assert_eq!(
        std::fs::read(scratch.join("payloads").join(STAGE)).unwrap(),
        recorded_stage()
    );

    // The next lifetime reopens (never creates) and recovers the prefix.
    let mut file = HostUploadFile::open(&payloads, STAGE, false).unwrap();
    file.recover(&committed(), 2048).unwrap();
    assert!(file.recover(&committed(), 4096).is_err());
    let identity = file.checkpoint_identity().unwrap();
    assert_eq!(file.checkpoint_identity().unwrap(), identity);
    let rest = source.chunk(2048, 2048).unwrap();
    file.append(2048, &rest, &sha256(&rest)).unwrap();
    assert_ne!(file.checkpoint_identity().unwrap(), identity);
    assert_eq!(file.byte_count().unwrap(), 4096);
    assert_eq!(file.complete_digest(4096).unwrap(), SOURCE_SHA256);
    assert!(file.complete_digest(4095).is_err());
    assert_eq!(file.validator_bytes(4096, false).unwrap(), bytes);
    assert!(file.validator_bytes(100, false).is_err());
    assert_eq!(file.validator_bytes(100, true).unwrap(), bytes[..100]);
    let mut read = Vec::new();
    file.validator_reader().read_to_end(&mut read).unwrap();
    assert_eq!(read, bytes);
    source.check_identity().unwrap();

    // Published once, sealed, verified, and exactly the source's bytes.
    assert!(
        file.publish_immutable(&artifacts, ARTIFACT, 4096, PREFIX_SHA256)
            .is_err()
    );
    assert_eq!(artifacts.names(16).unwrap(), Vec::<String>::new());
    file.publish_immutable(&artifacts, ARTIFACT, 4096, SOURCE_SHA256)
        .unwrap();
    assert_eq!(artifacts.names(16).unwrap(), [ARTIFACT]);
    let published = scratch.join("artifacts").join(ARTIFACT);
    assert_eq!(std::fs::read(&published).unwrap(), bytes);
    assert_eq!(
        artifacts
            .check_payload(ARTIFACT, 4096, SOURCE_SHA256)
            .unwrap(),
        PayloadCheck::Verified
    );
    assert!(
        std::fs::OpenOptions::new()
            .write(true)
            .open(&published)
            .is_err(),
        "the payload is sealed owner read-only"
    );
    // The staging stays the Import lifetime's own; publication never moves it.
    assert_eq!(file.complete_digest(4096).unwrap(), SOURCE_SHA256);

    // The frozen checkpoint records: a new identity is exclusive, a frozen
    // successor replaces exactly the prior document the caller names.
    let record = recorded(RECORD);
    let successor = recorded(ABORTED_RECORD);
    records
        .publish_import_checkpoint(RECORD, None, &record, 64 * 1024)
        .unwrap();
    assert_eq!(records.read(RECORD, 64 * 1024).unwrap(), record);
    assert!(matches!(
        records.publish_import_checkpoint(RECORD, None, &successor, 64 * 1024),
        Err(DocumentPublishError::BeforePublication(error)) if error.kind() == ErrorKind::AlreadyExists
    ));
    assert!(
        records
            .publish_import_checkpoint(RECORD, Some(&successor), &successor, 64 * 1024)
            .is_err(),
        "a prior that is not the document there is refused"
    );
    assert!(
        records
            .publish_import_checkpoint(ABORTED_RECORD, Some(&record), &successor, 64 * 1024)
            .is_err(),
        "a prior for an absent document is refused"
    );
    assert!(
        records
            .publish_import_checkpoint("record.txt", None, &record, 64 * 1024)
            .is_err()
    );
    assert_eq!(records.read(RECORD, 64 * 1024).unwrap(), record);
    records
        .publish_import_checkpoint(RECORD, Some(&record), &successor, 64 * 1024)
        .unwrap();
    assert_eq!(records.read(RECORD, 64 * 1024).unwrap(), successor);
    assert_eq!(records.names(16).unwrap(), [RECORD], "no staging is left");
}

#[test]
fn a_source_whose_identity_changes_mid_read_is_refused() {
    let (scratch, _root) = Scratch::new("identity");
    let path = scratch.join("source.hap");
    std::fs::write(&path, source_bytes()).unwrap();
    std::fs::write(scratch.join("other.hap"), b"other bytes").unwrap();

    // A metadata change between the open and the first read.
    let mut calls = 0;
    let refused = HostImportSource::open(&path, 64 * 1024, || {
        calls += 1;
        if calls == 2 {
            touch(&path);
        }
        Ok(())
    })
    .err()
    .unwrap();
    assert_eq!(refused.kind(), ErrorKind::InvalidData, "{refused}");

    // Its name replaced between the open and the first read.
    let mut calls = 0;
    let mut replaced = None;
    let opened = HostImportSource::open(&path, 64 * 1024, || {
        calls += 1;
        if calls == 2 {
            replaced = Some(std::fs::rename(scratch.join("other.hap"), &path));
        }
        Ok(())
    });
    let replaced = replaced.unwrap();
    if cfg!(windows) {
        // Shared for reading only: the name cannot be replaced while held,
        // so the read completes on the file that was identified.
        assert!(replaced.is_err(), "the held source's name was replaced");
        assert_eq!(opened.unwrap().sha256, SOURCE_SHA256);
    } else {
        replaced.unwrap();
        assert_eq!(opened.err().unwrap().kind(), ErrorKind::InvalidData);
    }

    // An oversized, empty or non-regular source is outside its bound.
    std::fs::write(scratch.join("empty.hap"), b"").unwrap();
    std::fs::write(scratch.join("large.hap"), source_bytes()).unwrap();
    for (name, maximum) in [("large.hap", 4095), ("empty.hap", 1024)] {
        let path = scratch.join(name);
        assert_eq!(
            HostImportSource::open(&path, maximum, || Ok(()))
                .err()
                .unwrap()
                .kind(),
            ErrorKind::InvalidInput
        );
    }
    assert!(HostImportSource::open(&scratch.0, 1024, || Ok(())).is_err());
    // The caller's deadline stops the read.
    assert_eq!(
        HostImportSource::open(&fixture("fixture.hap"), 64 * 1024, || Err(
            std::io::Error::from(ErrorKind::TimedOut)
        ))
        .err()
        .unwrap()
        .kind(),
        ErrorKind::TimedOut
    );
}

/// Windows: while the source is held nobody writes it or deletes its name;
/// once it is released both are possible again.
#[cfg(windows)]
#[test]
fn a_held_source_cannot_be_written_or_removed() {
    let (scratch, _root) = Scratch::new("share");
    let path = scratch.join("source.hap");
    std::fs::write(&path, source_bytes()).unwrap();
    let source = HostImportSource::open(&path, 64 * 1024, || Ok(())).unwrap();
    let write = std::fs::OpenOptions::new().write(true).open(&path);
    assert_eq!(write.err().unwrap().raw_os_error(), Some(32));
    assert!(std::fs::remove_file(&path).is_err());
    source.check_identity().unwrap();
    assert_eq!(source.chunk(0, 4096).unwrap(), source_bytes());
    drop(source);
    std::fs::OpenOptions::new().write(true).open(&path).unwrap();
    std::fs::remove_file(&path).unwrap();
}

/// A directory junction (a mount-point reparse point, which needs no
/// privilege) at `link`, naming `target`.
#[cfg(windows)]
fn junction(link: &Path, target: &Path) {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
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
fn link_sources_are_refused() {
    let (scratch, _root) = Scratch::new("links");
    let target = scratch.join("source.hap");
    std::fs::write(&target, source_bytes()).unwrap();
    let link = scratch.join("link.hap");
    #[cfg(windows)]
    {
        // A junction as the source's last component, and a stream name.
        junction(&scratch.join("junction"), &scratch.0);
        assert!(HostImportSource::open(&scratch.join("junction"), 64 * 1024, || Ok(())).is_err());
        let stream = PathBuf::from(format!("{}:stream", target.display()));
        assert!(HostImportSource::open(&stream, 64 * 1024, || Ok(())).is_err());
        // A file symbolic link needs a privilege or Developer Mode; without
        // either the host cannot create one, so there is none to refuse.
        match std::os::windows::fs::symlink_file(&target, &link) {
            Ok(()) => {}
            Err(error) if error.raw_os_error() == Some(1314) => {
                eprintln!("no file symbolic link on this host: {error}");
                return;
            }
            Err(error) => panic!("{error}"),
        }
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let refused = HostImportSource::open(&link, 64 * 1024, || Ok(()))
        .err()
        .unwrap();
    assert!(
        !matches!(
            refused.kind(),
            ErrorKind::InvalidData | ErrorKind::InvalidInput
        ),
        "a link is unopenable, as O_NOFOLLOW answers: {refused}"
    );
    assert_eq!(std::fs::read(&target).unwrap(), source_bytes(), "unchanged");
}

/// A complete stage of the recorded source in `payloads`.
fn complete_stage(payloads: &HostDirectory) -> HostUploadFile {
    let bytes = source_bytes();
    let mut file = HostUploadFile::open(payloads, STAGE, true).unwrap();
    file.append(0, &bytes[..2048], PREFIX_SHA256).unwrap();
    file.append(2048, &bytes[2048..], &sha256(&bytes[2048..]))
        .unwrap();
    file
}

#[test]
fn an_existing_artifact_is_never_replaced() {
    let (scratch, root) = Scratch::new("existing");
    let payloads = root.private_child("payloads").unwrap();
    let artifacts = root.private_child("artifacts").unwrap();
    let file = complete_stage(&payloads);
    artifacts.create_document(ARTIFACT, b"earlier").unwrap();
    let refused = file
        .publish_immutable(&artifacts, ARTIFACT, 4096, SOURCE_SHA256)
        .err()
        .unwrap();
    assert_eq!(refused.kind(), ErrorKind::AlreadyExists, "{refused}");
    assert_eq!(
        std::fs::read(scratch.join("artifacts").join(ARTIFACT)).unwrap(),
        b"earlier"
    );
    assert_eq!(artifacts.names(16).unwrap(), [ARTIFACT], "no copy is left");
}

/// The writer of the killed-writer test, run in its own process.
#[test]
fn upload_child_process() {
    let Some(root) = std::env::var_os("ARKDECK_TEST_IMPORT_ROOT") else {
        return;
    };
    let point = match std::env::var("ARKDECK_TEST_IMPORT_POINT").unwrap().as_str() {
        "partial" => UploadWritePoint::AfterPartialChunk,
        _ => UploadWritePoint::AfterChunkSync,
    };
    let root = HostDirectory::open(Path::new(&root)).unwrap();
    let payloads = root.child("payloads").unwrap();
    let bytes = source_bytes();
    let mut file = HostUploadFile::open(&payloads, STAGE, true).unwrap();
    file.append(0, &bytes[..2048], PREFIX_SHA256).unwrap();
    file.append_with_checkpoint(2048, &bytes[2048..], &sha256(&bytes[2048..]), |reached| {
        if reached == point {
            std::process::exit(86);
        }
        Ok(())
    })
    .unwrap();
    panic!("the requested checkpoint was not reached");
}

#[test]
fn a_killed_writer_leaves_torn_staging_and_no_published_artifact() {
    let bytes = source_bytes();
    for point in ["partial", "synced"] {
        let (scratch, root) = Scratch::new("killed");
        let payloads = root.private_child("payloads").unwrap();
        let artifacts = root.private_child("artifacts").unwrap();
        let died = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "upload_child_process", "--test-threads=1"])
            .env("ARKDECK_TEST_IMPORT_ROOT", &scratch.0)
            .env("ARKDECK_TEST_IMPORT_POINT", point)
            .output()
            .unwrap();
        assert_eq!(died.status.code(), Some(86), "{died:?}");

        // What the dead writer left is a prefix of what it was writing,
        // beyond the committed chunk, and nothing is published.
        let left = std::fs::read(scratch.join("payloads").join(STAGE)).unwrap();
        assert_eq!(left, bytes[..left.len()]);
        if point == "partial" {
            assert!(left.len() > 2048 && left.len() < 4096, "{}", left.len());
        } else {
            assert_eq!(left.len(), 4096);
        }
        assert_eq!(artifacts.names(16).unwrap(), Vec::<String>::new());

        // The next lifetime rolls the uncommitted suffix back to the
        // durable record's prefix, the recorded stage.
        let mut file = HostUploadFile::open(&payloads, STAGE, false).unwrap();
        file.recover(&committed(), 2048).unwrap();
        assert_eq!(
            std::fs::read(scratch.join("payloads").join(STAGE)).unwrap(),
            recorded_stage()
        );

        // A publisher killed before its rename leaves a private copy file
        // and no Artifact; the next publication reclaims it.
        let orphan = format!(".{ARTIFACT}.{:032x}.tmp", 0x5eed_u128);
        artifacts.create_document(&orphan, &bytes[..1000]).unwrap();
        assert!(
            artifacts
                .check_payload(ARTIFACT, 4096, SOURCE_SHA256)
                .map_or(true, |check| check != PayloadCheck::Verified)
        );
        file.append(2048, &bytes[2048..], &sha256(&bytes[2048..]))
            .unwrap();
        file.publish_immutable(&artifacts, ARTIFACT, 4096, SOURCE_SHA256)
            .unwrap();
        assert_eq!(artifacts.names(16).unwrap(), [ARTIFACT]);
        assert_eq!(
            std::fs::read(scratch.join("artifacts").join(ARTIFACT)).unwrap(),
            bytes
        );
    }
}
