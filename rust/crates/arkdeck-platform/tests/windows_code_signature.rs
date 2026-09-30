//! The Authenticode signature of a registered tool on Windows (TASK-XPA-011,
//! G12): `verified` with the signer's name and leaf SHA-256, `unsigned` for
//! an image with no signature, and a refusal for one whose signature does not
//! verify. The images are copies of system executables in a private scratch
//! tree; the signed cases sign them with the host's development signer
//! (`ARKDECK_DEV_SIGNER_THUMBPRINT`) and are skipped, saying so, without it.
//! Nothing is run.
#![cfg(windows)]

use arkdeck_platform::{
    application_support_directory, create_private_directory, create_private_file,
    inspect_native_code_signature, inspect_publisher, random_bytes,
};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

const DEVELOPMENT_SIGNER: &str = "ArkDeck Development Daemon (host-trusted only)";

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let base = application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let base = base.to_str().unwrap();
        let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-test-code-signature-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        create_private_directory(&path).unwrap();
        Self(path)
    }
    fn copy(&self, name: &str, system: &str) -> PathBuf {
        let path = self.0.join(name);
        let bytes = std::fs::read(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(system),
        )
        .unwrap();
        create_private_file(&path)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sign(path: &Path) -> bool {
    let Some(thumbprint) = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT") else {
        eprintln!("ARKDECK_DEV_SIGNER_THUMBPRINT is not set; the signed path is not exercised");
        return false;
    };
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let alias = std::env::var_os("LOCALAPPDATA")
        .map(|local| PathBuf::from(local).join(r"Microsoft\WindowsApps\pwsh.exe"))
        .filter(|alias| alias.exists());
    let pwsh = std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|directory| directory.join("pwsh.exe"))
                .find(|candidate| candidate.is_file())
        })
        .or(alias)
        .expect("PowerShell 7 signs the copies");
    let output = std::process::Command::new(pwsh)
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(&thumbprint)
        .arg("-Path")
        .arg(path)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    true
}

#[test]
fn a_signed_image_is_verified_an_unsigned_one_is_unsigned_and_a_broken_one_is_refused() {
    let scratch = Scratch::new();
    // A system executable copied out of its catalog carries no signature.
    let unsigned = scratch.copy("unsigned.exe", "whoami.exe");
    let answer = inspect_native_code_signature(&unsigned).unwrap();
    assert_eq!(answer.signature, "unsigned");
    assert_eq!(answer.identifier, None);
    assert_eq!(answer.code_directory_sha256, None);
    // Absent.
    assert!(inspect_native_code_signature(&scratch.0.join("absent.exe")).is_err());

    let signed = scratch.copy("signed.exe", "hostname.exe");
    if !sign(&signed) {
        return;
    }
    let answer = inspect_native_code_signature(&signed).unwrap();
    assert_eq!(answer.signature, "verified");
    assert_eq!(answer.identifier.as_deref(), Some(DEVELOPMENT_SIGNER));
    assert_eq!(answer.team_identifier, None);
    let leaf = answer.code_directory_sha256.clone().unwrap();
    assert_eq!(leaf.len(), 64);
    // The same signer on other bytes names the same leaf.
    let other = scratch.copy("other.exe", "whoami.exe");
    assert!(sign(&other));
    assert_eq!(
        inspect_native_code_signature(&other)
            .unwrap()
            .code_directory_sha256,
        Some(leaf)
    );

    // A byte of the image changed after signing: refused, never "unsigned".
    let mut bytes = std::fs::read(&signed).unwrap();
    let inside = bytes.len() / 4;
    bytes[inside] ^= 0xff;
    std::fs::write(&signed, bytes).unwrap();
    assert_eq!(
        inspect_native_code_signature(&signed).unwrap_err().kind(),
        ErrorKind::PermissionDenied
    );
}

#[test]
fn a_deveco_launcher_must_carry_the_expected_publisher() {
    let scratch = Scratch::new();
    create_private_directory(&scratch.0.join("bin")).unwrap();
    let launcher = scratch.copy(r"bin\devecostudio64.exe", "whoami.exe");
    // Unsigned: refused whatever the publisher.
    assert!(inspect_publisher(&scratch.0, DEVELOPMENT_SIGNER).is_err());
    if !sign(&launcher) {
        return;
    }
    assert_eq!(
        inspect_publisher(&scratch.0, DEVELOPMENT_SIGNER)
            .unwrap()
            .identifier
            .as_deref(),
        Some(DEVELOPMENT_SIGNER)
    );
    // Another publisher is refused: the DevEco publisher's check is exact.
    assert_eq!(
        inspect_publisher(&scratch.0, arkdeck_platform::DEVECO_PUBLISHER)
            .unwrap_err()
            .kind(),
        ErrorKind::PermissionDenied
    );
}
