//! The installed daemon's code identity a Windows signing receipt is bound to
//! (TASK-XPA-011): `trusted_daemon_fingerprint` accepts only a safe, canonical
//! `.exe` whose Authenticode signature `WinVerifyTrust` accepts, and binds its
//! signer and its bytes. The images are copies of system executables in a
//! private scratch tree under the account's local application data; the
//! signed cases sign such a copy with the host's development signer
//! (`ARKDECK_DEV_SIGNER_THUMBPRINT`, `rust/scripts/windows-dev-identity.ps1
//! sign`) and are skipped, saying so, where it is absent. Nothing is run.
#![cfg(windows)]

use arkdeck_platform::{
    application_support_directory, create_private_directory, random_bytes,
    trusted_daemon_fingerprint,
};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> Self {
        let base = application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let base = base.to_str().unwrap();
        let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-test-{label}-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        create_private_directory(&path).unwrap();
        Self(path)
    }

    /// A copy of `System32\<system>` at `<scratch>\<directory>\arkdeck-agentd.exe`.
    fn daemon(&self, directory: &str, system: &str) -> PathBuf {
        let directory = self.0.join(directory);
        create_private_directory(&directory).unwrap();
        let path = directory.join("arkdeck-agentd.exe");
        let mut source = std::fs::File::open(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(system),
        )
        .unwrap();
        let mut copy = arkdeck_platform::create_private_file(&path).unwrap();
        std::io::copy(&mut source, &mut copy).unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Signs `path` with the host's development signer; `false` (and why, on
/// stderr) where the host has none.
fn sign(path: &Path) -> bool {
    let Some(thumbprint) = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT") else {
        eprintln!("ARKDECK_DEV_SIGNER_THUMBPRINT is not set; the signed path is not exercised");
        return false;
    };
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let alias = std::env::var_os("LOCALAPPDATA")
        .map(|local| PathBuf::from(local).join("Microsoft\\WindowsApps\\pwsh.exe"))
        .filter(|alias| alias.exists());
    let pwsh = std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|directory| directory.join("pwsh.exe"))
                .find(|candidate| candidate.is_file())
        })
        .or(alias)
        .expect("PowerShell 7 signs the development daemon copy");
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
fn an_unsigned_absent_or_unsafe_daemon_has_no_identity() {
    let scratch = Scratch::new("daemon-fingerprint-refusals");
    let daemon = scratch.daemon("unsigned", "whoami.exe");
    // A system executable copied out of its catalog is unsigned.
    let error = trusted_daemon_fingerprint(&daemon).unwrap_err();
    assert_eq!(error.kind(), ErrorKind::Other, "{error}");
    // Absent, not the spelling on disk, verbatim, relative, a directory.
    let text = daemon.to_str().unwrap();
    for path in [
        scratch.0.join("absent.exe"),
        PathBuf::from(text.replace("arkdeck-agentd.exe", "ARKDECK-AGENTD.EXE")),
        PathBuf::from(format!(r"\\?\{text}")),
        PathBuf::from("arkdeck-agentd.exe"),
        scratch.0.clone(),
    ] {
        let error = trusted_daemon_fingerprint(&path).unwrap_err();
        assert_eq!(
            error.kind(),
            ErrorKind::PermissionDenied,
            "{}",
            path.display()
        );
    }
    // Not an image, and writable by others.
    let named = scratch.0.join("unsigned").join("arkdeck-agentd.bin");
    std::fs::copy(&daemon, &named).unwrap();
    assert_eq!(
        trusted_daemon_fingerprint(&named).unwrap_err().kind(),
        ErrorKind::PermissionDenied
    );
    let status = std::process::Command::new("icacls")
        .arg(&daemon)
        .args(["/grant", "*S-1-1-0:(M)"])
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(
        trusted_daemon_fingerprint(&daemon).unwrap_err().kind(),
        ErrorKind::PermissionDenied
    );
}

#[test]
fn a_signed_daemon_is_bound_by_its_signer_and_its_bytes() {
    let scratch = Scratch::new("daemon-fingerprint-signed");
    let first = scratch.daemon("first", "whoami.exe");
    if !sign(&first) {
        return;
    }
    let fingerprint = trusted_daemon_fingerprint(&first).unwrap();
    assert_eq!(fingerprint.len(), 64);
    assert!(
        fingerprint
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    );
    // Stable, and a property of the image, not of where it is installed.
    assert_eq!(trusted_daemon_fingerprint(&first).unwrap(), fingerprint);
    let moved = scratch.0.join("moved");
    create_private_directory(&moved).unwrap();
    let moved = moved.join("arkdeck-agentd.exe");
    std::fs::copy(&first, &moved).unwrap();
    assert_eq!(trusted_daemon_fingerprint(&moved).unwrap(), fingerprint);
    // Other bytes under the same signer are another identity.
    let other = scratch.daemon("other", "hostname.exe");
    assert!(sign(&other));
    assert_ne!(trusted_daemon_fingerprint(&other).unwrap(), fingerprint);
    // A byte of the image changed after signing breaks the signature (the
    // certificate table at the end is not hashed, so change one well before
    // it).
    let mut bytes = std::fs::read(&first).unwrap();
    let inside = bytes.len() / 4;
    bytes[inside] ^= 0xff;
    std::fs::write(&first, bytes).unwrap();
    assert_eq!(
        trusted_daemon_fingerprint(&first).unwrap_err().kind(),
        ErrorKind::Other
    );
}
