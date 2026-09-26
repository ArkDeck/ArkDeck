//! Shared vendored Swift process fixture; never signs real input or contacts a device.
use arkdeck_platform::random_bytes;
use arkdeck_provider_workspace::foundation_resolved_path;
use sha2::{Digest, Sha256};
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};
const VENDORED_FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../tests/fixtures/fake-hap-signer/main.swift"
);
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn token() -> String {
    hex(&random_bytes::<8>().unwrap())
}

/// The base directory in the spelling Swift's `measure` accepts.
fn base() -> PathBuf {
    let base = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    std::fs::create_dir_all(&base).unwrap();
    PathBuf::from(foundation_resolved_path(base.to_str().unwrap()).unwrap())
}

/// The fixture compiled once per source digest, installed atomically.
pub fn fake_signer() -> &'static Path {
    static BINARY: OnceLock<PathBuf> = OnceLock::new();
    BINARY.get_or_init(|| {
        let source = std::fs::read(VENDORED_FIXTURE).unwrap();
        let digest = hex(&Sha256::digest(&source)[..8]);
        let directory = base().join("fake-hap-signer");
        std::fs::create_dir_all(&directory).unwrap();
        let binary = directory.join(format!("ArkDeckFakeHapSignerFixture-{digest}"));
        if !binary.exists() {
            let staging = directory.join(format!(".build-{}", token()));
            let status = Command::new("/usr/bin/xcrun")
                .args(["swiftc", "-O", "-module-cache-path"])
                .arg(directory.join("module-cache"))
                .arg("-o")
                .arg(&staging)
                .arg(VENDORED_FIXTURE)
                .status()
                .unwrap();
            assert!(status.success(), "swiftc could not build the fake signer");
            std::fs::rename(&staging, &binary).unwrap();
        }
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        binary
    })
}
