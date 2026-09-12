#![cfg(target_os = "macos")]
use arkdeck_platform::{
    BootstrapBundleCapture, BootstrapBundlePublication, inspect_bootstrap_tree,
};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::PathBuf,
};

fn root() -> PathBuf {
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let root = PathBuf::from(format!(
        "/private/tmp/bundle-capture-integration-{nonce:032x}"
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    root // Retained deliberately: no overall fixture deletion.
}
#[test]
fn links_unsafe_modes_depth_and_content_bounds_fail_without_publication() {
    for scenario in [
        "symlink",
        "hardlink",
        "fifo",
        "unsafeMode",
        "depth",
        "bytes",
    ] {
        let root = root();
        let source = root.join("Source.app");
        let registry = root.join("registry");
        fs::DirBuilder::new().mode(0o700).create(&source).unwrap();
        fs::DirBuilder::new().mode(0o700).create(&registry).unwrap();
        let file = source.join("file");
        fs::write(&file, b"kept").unwrap();
        match scenario {
            "symlink" => symlink(&file, source.join("link")).unwrap(),
            "hardlink" => fs::hard_link(&file, source.join("link")).unwrap(),
            "fifo" => {
                use std::os::unix::ffi::OsStrExt;
                let path =
                    std::ffi::CString::new(source.join("fifo").as_os_str().as_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            "unsafeMode" => fs::set_permissions(&file, fs::Permissions::from_mode(0o666)).unwrap(),
            "depth" => {
                let mut path = source.clone();
                for _ in 0..25 {
                    path.push("nested");
                    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
                }
            }
            "bytes" => fs::File::options()
                .write(true)
                .open(&file)
                .unwrap()
                .set_len(1_073_741_825)
                .unwrap(),
            _ => unreachable!(),
        }
        assert!(BootstrapBundleCapture::capture(&registry, &source).is_err());
        assert_eq!(fs::read_dir(registry).unwrap().count(), 0);
        assert!(file.exists());
    }
}
#[test]
fn registry_ancestry_and_source_extension_are_not_repaired() {
    let root = root();
    let registry = root.join("registry");
    let source = root.join("Source.app");
    for path in [&registry, &source] {
        fs::DirBuilder::new().mode(0o700).create(path).unwrap();
    }
    let alias = root.join("alias");
    symlink(&registry, &alias).unwrap();
    assert!(BootstrapBundleCapture::capture(&alias, &source).is_err());
    assert!(BootstrapBundleCapture::capture(&source.join("registry"), &source).is_err());
    assert!(BootstrapBundleCapture::capture(&registry, &root).is_err());
    assert_eq!(fs::read_dir(&registry).unwrap().count(), 0);
}
#[test]
#[ignore = "requires the explicitly authorized existing signed helper Bundle"]
fn real_native_capture_matches_frozen_swift_digest_and_never_overwrites() {
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::os::{fd::AsRawFd, unix::fs::MetadataExt};
    fn raw_quarantine(path: &std::path::Path) -> Option<Vec<u8>> {
        let file = fs::File::open(path).unwrap();
        let size = unsafe {
            libc::fgetxattr(
                file.as_raw_fd(),
                c"com.apple.quarantine".as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                0,
            )
        };
        if size < 0 {
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::ENOATTR)
            );
            return None;
        }
        assert!(size <= 16 * 1024);
        let mut value = vec![0; size as usize];
        assert_eq!(
            unsafe {
                libc::fgetxattr(
                    file.as_raw_fd(),
                    c"com.apple.quarantine".as_ptr(),
                    value.as_mut_ptr().cast(),
                    value.len(),
                    0,
                    0,
                )
            },
            size
        );
        Some(value)
    }
    let source = PathBuf::from(
        std::env::var_os("ARKDECK_BUNDLE_CAPTURE_NATIVE_SOURCE").expect("actual native source"),
    );
    let source_before = inspect_bootstrap_tree(&source).unwrap();
    let entries: Vec<Value> = source_before.entries.iter().map(|e| json!({"path":e.path,"kind":if e.directory{"directory"}else{"file"},"executable":e.executable,"quarantineSHA256":e.quarantine_sha256,"byteCount":e.byte_count.to_string(),"sha256":e.sha256})).collect();
    // These fixed-field JSON objects use the frozen hoststore spelling and key
    // ordering. The expected digest is an independently registered Swift result.
    let encoded =
        serde_json::to_vec(&json!({"schemaVersion":"arkdeck.bundle-content/1","entries":entries}))
            .unwrap();
    let digest = format!("{:x}", Sha256::digest(encoded));
    assert_eq!(
        digest,
        "a5c9e37fa11f07cdfcdbfa5c8620683102597e3c96c1812bd1bc917b79e0fde5"
    );
    let registry = root();
    let mut capture = BootstrapBundleCapture::capture(&registry, &source).unwrap();
    let mut absent = 0;
    let mut present = 0;
    for entry in &source_before.entries {
        let original = raw_quarantine(&source.join(&entry.path));
        let copied = capture.path().join(&entry.path);
        assert_eq!(raw_quarantine(&copied), original);
        if original.is_some() {
            present += 1;
        } else {
            absent += 1;
        }
        assert_eq!(
            fs::metadata(&copied).unwrap().mode() & 0o7777,
            if entry.directory || entry.executable {
                0o700
            } else {
                0o600
            }
        );
    }
    let stage = capture.path().to_owned();
    let published = match capture.publish(&digest).unwrap() {
        BootstrapBundlePublication::Published(path) => path,
        other => panic!("{other:?}"),
    };
    drop(capture);
    assert!(!stage.exists());
    let before_duplicate = inspect_bootstrap_tree(&published).unwrap();
    assert_eq!(before_duplicate.entries, source_before.entries);
    let mut duplicate = BootstrapBundleCapture::capture(&registry, &source).unwrap();
    let duplicate_stage = duplicate.path().to_owned();
    assert_eq!(
        duplicate.publish(&digest).unwrap(),
        BootstrapBundlePublication::AlreadyExists(published.clone())
    );
    drop(duplicate);
    assert!(!duplicate_stage.exists());
    assert_eq!(
        inspect_bootstrap_tree(&published).unwrap(),
        before_duplicate
    );
    assert_eq!(inspect_bootstrap_tree(&source).unwrap(), source_before);
    println!(
        "nativeBundleCapture={}",
        json!({"source":source,"registryRoot":registry,"published":published,"swiftDigest":digest,"quarantineAbsentEntries":absent,"quarantinePresentEntries":present,"deviceAcceptance":false})
    );
}
