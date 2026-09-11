#![cfg(target_os = "macos")]
//! Actual native bytes exercise capture; these tests never execute a candidate.
use arkdeck_platform::{
    BootstrapToolCapture, BootstrapToolCaptureError, BootstrapToolPublication,
    BootstrapToolPublishError, inspect_bootstrap_tree, inspect_native_code_signature, random_bytes,
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, FileExt, MetadataExt, PermissionsExt, symlink},
    },
    path::{Path, PathBuf},
};

fn fixture() -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-tool-capture-{:032x}",
        u128::from_ne_bytes(random_bytes().unwrap())
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let registry = root.join("registry");
    fs::DirBuilder::new().mode(0o700).create(&registry).unwrap();
    (root, registry)
}
fn native_source(root: &Path) -> PathBuf {
    let source = root.join("native-source");
    fs::copy("/usr/bin/true", &source).unwrap();
    fs::set_permissions(&source, fs::Permissions::from_mode(0o700)).unwrap();
    source
}
fn main_only(file: &File, library: bool) -> Result<bool, BootstrapToolCaptureError> {
    assert!(!library);
    // The platform receives classification from hoststore's full Mach-O parser.
    // This fixture checks that the callback receives the actual held native fd.
    let mut header = [0; 4];
    file.read_exact_at(&mut header, 0).unwrap();
    assert!(matches!(
        header,
        [0xca, 0xfe, 0xba, 0xbe] | [0xcf, 0xfa, 0xed, 0xfe] | [0xfe, 0xed, 0xfa, 0xcf]
    ));
    Ok(false)
}
fn names(path: &Path) -> Vec<String> {
    let mut names: Vec<_> = fs::read_dir(path)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}
fn content_digest(path: &Path) -> String {
    let tree = inspect_bootstrap_tree(path).unwrap();
    let entries: Vec<_> = tree
        .entries
        .iter()
        .map(|e| {
            serde_json::json!({
                "path":e.path,"kind":if e.directory{"directory"}else{"file"},
                "executable":e.executable,"quarantineSHA256":e.quarantine_sha256,
                "byteCount":e.byte_count.to_string(),"sha256":e.sha256,
            })
        })
        .collect();
    let manifest = serde_json::json!({"schemaVersion":"arkdeck.tool-content/1","kind":"hdc","layout":"hdc-sibling-libusb/1","entries":entries});
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&manifest).unwrap())
    )
}
fn set_quarantine(path: &Path, bytes: &[u8]) {
    let file = File::open(path).unwrap();
    assert_eq!(
        unsafe {
            libc::fsetxattr(
                file.as_raw_fd(),
                c"com.apple.quarantine".as_ptr(),
                bytes.as_ptr().cast(),
                bytes.len(),
                0,
                0,
            )
        },
        0
    );
}
fn capture_error(
    result: Result<BootstrapToolCapture, BootstrapToolCaptureError>,
) -> BootstrapToolCaptureError {
    match result {
        Err(error) => error,
        Ok(_) => panic!("capture unexpectedly succeeded"),
    }
}

#[test]
fn actual_native_capture_preserves_bytes_quarantine_and_immutable_destination() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    let quarantine = b"0081;65a00000;ArkDeck capture test;";
    set_quarantine(&source, quarantine);
    let original = fs::read(&source).unwrap();
    let source_before = inspect_bootstrap_tree(&source).unwrap();
    let mut captured = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    assert_eq!(names(captured.path()), ["hdc"]);
    assert_eq!(fs::read(captured.path().join("hdc")).unwrap(), original);
    assert_eq!(fs::metadata(captured.path()).unwrap().mode() & 0o777, 0o700);
    assert_eq!(
        fs::metadata(captured.path().join("hdc")).unwrap().mode() & 0o777,
        0o700
    );
    let staged = inspect_bootstrap_tree(captured.path()).unwrap();
    assert_eq!(
        staged.entries[1].quarantine_sha256,
        source_before.entries[0].quarantine_sha256
    );
    let trust = inspect_native_code_signature(&captured.path().join("hdc")).unwrap();
    assert_eq!(trust, inspect_native_code_signature(&source).unwrap());
    assert_ne!(trust.signature, "unsigned");
    captured.revalidate_sources().unwrap();
    let digest = content_digest(captured.path());
    let destination = registry.join(format!("tool-{digest}.hdc"));
    assert_eq!(
        captured.publish(&digest).unwrap(),
        BootstrapToolPublication::Published(destination.clone())
    );
    captured.revalidate_sources().unwrap();
    drop(captured);
    assert_eq!(names(&registry), [format!("tool-{digest}.hdc")]);
    assert_eq!(fs::read(destination.join("hdc")).unwrap(), original);
    assert_eq!(inspect_bootstrap_tree(&source).unwrap(), source_before);

    let before = inspect_bootstrap_tree(&destination).unwrap();
    let mut again = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage = again.path().to_owned();
    assert_eq!(
        again.publish(&digest).unwrap(),
        BootstrapToolPublication::AlreadyExists(destination.clone())
    );
    drop(again);
    assert!(!stage.exists());
    assert_eq!(inspect_bootstrap_tree(&destination).unwrap(), before);
    assert_eq!(fs::read(&source).unwrap(), original);
}

#[test]
fn changed_source_blocks_publication_and_only_own_stage_is_removed() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    let sentinel = registry.join("retained-sentinel");
    fs::write(&sentinel, b"existing content").unwrap();
    let sentinel_inode = fs::metadata(&sentinel).unwrap().ino();
    let mut capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage = capture.path().to_owned();
    fs::rename(&source, root.join("original-held-source")).unwrap();
    fs::copy(root.join("original-held-source"), &source).unwrap();
    assert_eq!(
        capture.revalidate_sources().unwrap_err().code,
        "fileIdentityChanged"
    );
    assert!(matches!(
        capture.publish(&"a".repeat(64)),
        Err(BootstrapToolPublishError::BeforePublication(_))
    ));
    drop(capture);
    assert!(!stage.exists());
    assert_eq!(fs::read(&sentinel).unwrap(), b"existing content");
    assert_eq!(fs::metadata(&sentinel).unwrap().ino(), sentinel_inode);
}

#[test]
fn replaced_staging_child_and_unknown_member_are_never_deleted() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    let capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage = capture.path().to_owned();
    fs::rename(stage.join("hdc"), root.join("owned-copy-moved-away")).unwrap();
    fs::write(stage.join("hdc"), b"foreign replacement").unwrap();
    let replacement_inode = fs::metadata(stage.join("hdc")).unwrap().ino();
    assert!(capture.revalidate_sources().is_err());
    drop(capture);
    assert_eq!(fs::read(stage.join("hdc")).unwrap(), b"foreign replacement");
    assert_eq!(
        fs::metadata(stage.join("hdc")).unwrap().ino(),
        replacement_inode
    );
    assert!(root.join("owned-copy-moved-away").exists());

    let capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage = capture.path().to_owned();
    fs::write(stage.join("unowned"), b"do not remove").unwrap();
    drop(capture);
    assert_eq!(names(&stage), ["hdc", "unowned"]);
    assert_eq!(fs::read(stage.join("unowned")).unwrap(), b"do not remove");
}

#[test]
fn links_wrong_kinds_missing_sibling_and_oversize_are_bounded_refusals() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &source.join("child"),
            main_only
        ))
        .code,
        "invalidInput"
    );
    symlink(&root, root.join("parent-link")).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &root.join("parent-link/native-source"),
            main_only
        ))
        .code,
        "fileIdentityChanged"
    );
    symlink(&source, root.join("symlink")).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &root.join("symlink"),
            main_only
        ))
        .code,
        "fileIdentityChanged"
    );
    fs::hard_link(&source, root.join("hardlink")).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &root.join("hardlink"),
            main_only
        ))
        .code,
        "invalidInput"
    );
    fs::remove_file(root.join("hardlink")).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &source,
            |_, _| Ok(true)
        ))
        .code,
        "ioFailure"
    );
    fs::write(root.join("script"), b"#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(root.join("script"), fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &root.join("script"),
            |_, _| Err(BootstrapToolCaptureError::new(
                "invalidInput",
                "fixture parser refused non-Mach-O"
            ))
        ))
        .code,
        "invalidInput"
    );
    let huge = root.join("huge");
    File::create(&huge)
        .unwrap()
        .set_len(256 * 1024 * 1024 + 1)
        .unwrap();
    fs::set_permissions(&huge, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(
            &registry,
            &huge,
            |_, _| panic!("oversize reached parser")
        ))
        .code,
        "inputTooLarge"
    );
    assert!(names(&registry).is_empty());
}

#[test]
fn source_quarantine_change_and_oversized_quarantine_are_refused() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    let capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage = capture.path().to_owned();
    set_quarantine(&source, b"0081;65a00000;changed;");
    assert_eq!(
        capture.revalidate_sources().unwrap_err().code,
        "fileIdentityChanged"
    );
    drop(capture);
    assert!(!stage.exists());
    set_quarantine(&source, &vec![b'a'; 16 * 1024 + 1]);
    assert_eq!(
        capture_error(BootstrapToolCapture::capture(&registry, &source, main_only)).code,
        "fileIdentityChanged"
    );
    assert!(names(&registry).is_empty());
}

#[test]
fn replaced_registry_binding_refuses_publication_without_touching_replacement() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    let mut capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
    let stage_name = capture.path().file_name().unwrap().to_owned();
    let old = root.join("held-registry");
    fs::rename(&registry, &old).unwrap();
    fs::DirBuilder::new().mode(0o700).create(&registry).unwrap();
    let replacement = fs::metadata(&registry).unwrap().ino();
    assert!(matches!(
        capture.publish(&"b".repeat(64)),
        Err(BootstrapToolPublishError::BeforePublication(_))
    ));
    drop(capture);
    assert_eq!(fs::metadata(&registry).unwrap().ino(), replacement);
    assert!(names(&registry).is_empty());
    assert!(old.join(stage_name).join("hdc").exists());
}

#[test]
fn existing_file_or_symlink_destination_is_never_replaced_or_cleaned() {
    let (root, registry) = fixture();
    let source = native_source(&root);
    for (digit, link) in [('a', false), ('b', true)] {
        let digest = digit.to_string().repeat(64);
        let destination = registry.join(format!("tool-{digest}.hdc"));
        if link {
            symlink(&source, &destination).unwrap();
        } else {
            fs::write(&destination, b"existing foreign file").unwrap();
        }
        let before = fs::symlink_metadata(&destination).unwrap();
        let mut capture = BootstrapToolCapture::capture(&registry, &source, main_only).unwrap();
        let stage = capture.path().to_owned();
        assert_eq!(
            capture.publish(&digest).unwrap(),
            BootstrapToolPublication::AlreadyExists(destination.clone())
        );
        drop(capture);
        assert!(!stage.exists());
        let after = fs::symlink_metadata(&destination).unwrap();
        assert_eq!(
            (
                before.dev(),
                before.ino(),
                before.mode(),
                before.len(),
                before.mtime(),
                before.mtime_nsec()
            ),
            (
                after.dev(),
                after.ino(),
                after.mode(),
                after.len(),
                after.mtime(),
                after.mtime_nsec()
            )
        );
        if link {
            assert_eq!(fs::read_link(&destination).unwrap(), source);
        } else {
            assert_eq!(fs::read(&destination).unwrap(), b"existing foreign file");
        }
    }
}
