//! Swift `measure`/`remeasure` and the dispatch re-measurement of a receipt
//! on Windows (TASK-XPA-011, G15): the pinned signing files are measured
//! from their owner, DACL and `FileIdInfo` through one no-follow handle,
//! with the Unix refusals and messages. The files are fixture bytes; no
//! keystore, certificate or password of a real installation is read.
#![cfg(windows)]

use arkdeck_platform::{Secret, application_support_directory, random_bytes};
use arkdeck_provider_workspace::signing_preset::{
    SecretPresence, SigningPresetStore, SigningSecrets,
};
use arkdeck_provider_workspace::{SigningError, foundation_resolved_path, measure, remeasure};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;

/// A scratch directory under the account's local application data (never
/// the temporary directory, which on some hosts grants other principals
/// write through inheritance), in its plain `X:\…` spelling.
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
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self, name: &str, bytes: &[u8]) -> String {
        let path = self.0.join(name);
        std::fs::write(&path, bytes).unwrap();
        private(&path);
        path.to_str().unwrap().to_owned()
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn user_sid() -> String {
    let output = Command::new("whoami")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8_lossy(&output.stdout);
    let sid = text.trim().rsplit(',').next().unwrap().trim_matches('"');
    assert!(sid.starts_with("S-1-"));
    sid.to_owned()
}

fn icacls(path: &Path, arguments: &[&str]) {
    let status = Command::new("icacls")
        .arg(path)
        .args(arguments)
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}

/// Owner-only with the system's own principals: the Windows `0600`.
fn private(path: &Path) {
    // Set explicitly: an elevated administrator's default owner is
    // `Administrators`, not the user.
    icacls(path, &["/setowner", &format!("*{}", user_sid())]);
    let user = format!("*{}:F", user_sid());
    icacls(
        path,
        &[
            "/inheritance:r",
            "/grant:r",
            &user,
            "*S-1-5-18:F",
            "*S-1-5-32-544:F",
        ],
    );
}

fn unsafe_file(message: &str) -> SigningError {
    SigningError::UnsafeFile(message.to_owned())
}

#[test]
fn pinned_files_measure_with_the_unix_rules_and_refusals() {
    let scratch = Scratch::new("file-identity");
    let keystore = scratch.file("release.p12", b"keystore fixture");
    let measured = measure(&keystore, "keystore", false, true).unwrap();
    assert_eq!(measured.path, keystore);
    assert_eq!(measured.byte_count, 16);
    let digest: String = Sha256::digest(b"keystore fixture")
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    assert_eq!(measured.sha256, digest);
    remeasure(&measured, "keystore", false, true).unwrap();
    assert_eq!(
        foundation_resolved_path(&keystore).as_deref(),
        Some(keystore.as_str())
    );

    // A write is drift; a readable-by-others keystore is not private; a
    // writable-by-others file is refused for every role.
    std::fs::write(&keystore, b"keystore fixture 2").unwrap();
    assert_eq!(
        remeasure(&measured, "keystore", false, true),
        Err(SigningError::IdentityDrift("keystore".into()))
    );
    icacls(Path::new(&keystore), &["/grant", "*S-1-5-32-545:R"]);
    assert_eq!(
        measure(&keystore, "keystore", false, true),
        Err(unsafe_file(
            "keystore must be owned by this user and private"
        ))
    );
    assert!(measure(&keystore, "keystore", false, false).is_ok());
    icacls(Path::new(&keystore), &["/grant", "*S-1-1-0:M"]);
    assert_eq!(
        measure(&keystore, "keystore", false, false),
        Err(unsafe_file("keystore is group/world writable"))
    );

    // Java must be an image the caller may execute; a JAR is not one.
    let java = scratch.file("java.exe", b"MZ fixture");
    assert!(measure(&java, "java", true, false).is_ok());
    let jar = scratch.file("hap-sign-tool.jar", b"PK fixture");
    assert!(measure(&jar, "signer JAR", false, false).is_ok());
    assert_eq!(
        measure(&jar, "signer JAR", true, false),
        Err(unsafe_file("signer JAR is not executable"))
    );

    // Not a standard canonical absolute path, or not at its own spelling.
    let not_canonical = unsafe_file("java path is not canonical absolute");
    let directory = scratch.0.to_str().unwrap();
    for spelling in [
        "java.exe".to_owned(),
        java.replace('\\', "/"),
        format!(r"\\?\{java}"),
        format!(r"{directory}\.\java.exe"),
        format!(r"{directory}\sub\..\java.exe"),
        format!(r"{java}\"),
        format!("{java}:stream"),
        java.to_lowercase(),
    ] {
        assert_eq!(
            measure(&spelling, "java", true, false),
            Err(not_canonical.clone()),
            "{spelling}"
        );
    }
    let link = scratch.0.join("link");
    let status = Command::new("cmd")
        .args(["/c", "mklink", "/J"])
        .arg(&link)
        .arg(&scratch.0)
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let through = format!(r"{}\java.exe", link.display());
    assert_eq!(
        foundation_resolved_path(&through).as_deref(),
        Some(java.as_str())
    );
    assert_eq!(measure(&through, "java", true, false), Err(not_canonical));

    // Absent, empty, a directory.
    let bounded = unsafe_file("keystore is not a bounded regular file");
    let empty = scratch.file("empty.p12", b"");
    std::fs::create_dir(scratch.0.join("directory.p12")).unwrap();
    for path in [
        format!(r"{directory}\absent.p12"),
        empty,
        format!(r"{directory}\directory.p12"),
    ] {
        assert_eq!(
            measure(&path, "keystore", false, true),
            Err(bounded.clone()),
            "{path}"
        );
    }
}

struct NoSecrets;
impl SigningSecrets for NoSecrets {
    fn read(&self, _: &str) -> Result<Secret, SigningError> {
        Err(SigningError::SecretUnavailable("fixture".into()))
    }
    fn presence(&self, _: &str) -> SecretPresence {
        SecretPresence::Absent
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(None)
    }
}

#[test]
fn a_receipt_with_windows_paths_revalidates_every_pinned_file() {
    let scratch = Scratch::new("receipt");
    let files = [
        (
            "javaExecutable",
            scratch.file("java.exe", b"MZ java"),
            true,
            false,
        ),
        (
            "signerJAR",
            scratch.file("hap-sign-tool.jar", b"PK jar"),
            false,
            false,
        ),
        ("keystore", scratch.file("release.p12", b"p12"), false, true),
        (
            "appCertificate",
            scratch.file("app.pem", b"pem"),
            false,
            false,
        ),
        (
            "signedProfile",
            scratch.file("profile.p7b", b"p7b"),
            false,
            false,
        ),
    ];
    let mut receipt = serde_json::json!({
        "schemaVersion": "arkdeck-openharmony-signing/v1",
        "installedAtUTC": "2026-09-30T00:00:00Z",
        "presetID": "openharmony-release@1",
        "projectRef": "project-fixture",
        "keyAlias": "openharmony application release",
        "signingAlgorithm": "SHA256withECDSA",
        "keystorePasswordAccount": "openharmony-release@1|keystore",
        "keyPasswordAccount": "openharmony-release@1|key",
        "secretEnvelopeAccount":
            "openharmony-release@1|secret-envelope-3f2a9c1e-5b7d-4e8a-9c0f-1d2e3a4b5c6d",
        "keychainAccessSchema": "data-protection-access-group-v1",
    });
    for (key, path, executable, private) in &files {
        receipt[*key] =
            serde_json::to_value(measure(path, key, *executable, *private).unwrap()).unwrap();
    }
    let root = scratch.0.join("preset");
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("preset-v1.json"), receipt.to_string()).unwrap();
    let store = SigningPresetStore::new(&root);
    let loaded = store
        .load_validated("openharmony-release@1", false, &NoSecrets)
        .unwrap();
    assert_eq!(loaded.java_executable.path, files[0].1);

    std::fs::write(&files[3].1, b"another pem").unwrap();
    assert_eq!(
        store
            .load_validated("openharmony-release@1", false, &NoSecrets)
            .err(),
        Some(SigningError::IdentityDrift("app certificate".into()))
    );
}
