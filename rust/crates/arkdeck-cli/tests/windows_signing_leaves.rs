//! `runtime signing install|remove|status` on Windows (TASK-XPA-011): the
//! same documents as on macOS over a fixture preset root and a fixture secret
//! source, and the process-level refusals that come before any preset root or
//! Credential Manager is touched — a daemon that satisfies no signing pin, and
//! the DevEco password material, which is not read on Windows. No production
//! credential, preset root or daemon is used.
#![cfg(windows)]

use arkdeck_cli::signing_leaves::{install_document, remove_document, status_document};
use arkdeck_platform::{
    Secret, application_support_directory, create_private_directory, create_private_file,
    random_bytes,
};
use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::signing_install::SigningSecretInstallation;
use arkdeck_provider_workspace::signing_preset::{
    SecretPresence, SigningPresetStore, SigningSecrets,
};
use arkdeck_provider_workspace::signing_removal::SigningSecretRemoval;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

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

    fn file(&self, name: &str, bytes: &[u8]) -> String {
        let path = self.0.join(name);
        create_private_file(&path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
        path.to_str().unwrap().to_owned()
    }

    fn options(&self) -> Map<String, Value> {
        json!({
            "java": self.file("java.exe", b"not run: fixture launcher"),
            "jar": self.file("hap-sign-tool.jar", b"fixture jar"),
            "keystore": self.file("release.p12", b"fixture keystore"),
            "certificate": self.file("release.cer", b"fixture certificate"),
            "profile": self.file("release.p7b", b"fixture profile"),
            "keyAlias": "release",
            "projectRef": "demo-app",
        })
        .as_object()
        .unwrap()
        .clone()
    }

    fn root(&self) -> PathBuf {
        self.0.join("preset")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct Memory(Mutex<BTreeMap<String, Secret>>);
impl SigningSecrets for Memory {
    fn read(&self, account: &str) -> Result<Secret, SigningError> {
        self.0
            .lock()
            .unwrap()
            .get(account)
            .cloned()
            .ok_or_else(|| SigningError::SecretUnavailable("fixture absent".into()))
    }
    fn presence(&self, account: &str) -> SecretPresence {
        if self.0.lock().unwrap().contains_key(account) {
            SecretPresence::Present
        } else {
            SecretPresence::Absent
        }
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(None)
    }
}
impl SigningSecretInstallation for Memory {
    fn set_envelope(&self, account: &str, bytes: &[u8]) -> Result<(), SigningError> {
        self.0
            .lock()
            .unwrap()
            .insert(account.into(), Secret::from_slice(bytes));
        Ok(())
    }
    fn remove_envelope(&self, account: &str) -> Result<bool, SigningError> {
        Ok(self.0.lock().unwrap().remove(account).is_some())
    }
}
impl SigningSecretRemoval for Memory {
    fn remove_current(&self, account: &str) -> Result<bool, SigningError> {
        self.remove_envelope(account)
    }
    fn remove_legacy(&self, _: &str) -> Result<bool, SigningError> {
        Ok(false)
    }
}

#[test]
fn install_status_and_remove_serve_the_macos_documents() {
    let scratch = Scratch::new("cli-signing");
    let secrets = Memory::default();
    let root = scratch.root();
    let before = status_document(&root, &secrets);
    assert_eq!(before["installed"], false);
    assert_eq!(before["ready"], false);
    assert_eq!(
        before["diagnostics"],
        json!(["signingCredentialNotInstalled"])
    );

    let mut prompts = Vec::new();
    let installed = install_document(
        &root,
        "runtime.signing.install",
        &scratch.options(),
        &secrets,
        &mut |prompt| {
            prompts.push(prompt.to_owned());
            Ok(Secret::from_slice(if prompt.starts_with("Keystore") {
                b"fixture-ks-1Pz"
            } else {
                b"fixture-key-7Lw"
            }))
        },
        "2026-09-30T00:00:00Z",
    )
    .unwrap();
    assert_eq!(prompts, ["Keystore password: ", "Key password: "]);
    assert_eq!(installed["schemaVersion"], "arkdeck.signing-credential/1");
    assert_eq!(installed["kind"], "openharmony-signing");
    assert_eq!(installed["projectRef"], "demo-app");
    assert_eq!(installed["presetId"], "openharmony-release@1");
    assert_eq!(installed["installedAtUtc"], "2026-09-30T00:00:00Z");
    assert_eq!(installed["referenceCount"], 0);
    assert!(
        installed["credentialRef"]
            .as_str()
            .unwrap()
            .starts_with("credential:sha256-")
    );
    let receipt: Value = serde_json::from_slice(
        &std::fs::read(SigningPresetStore::new(&root).receipt_path()).unwrap(),
    )
    .unwrap();
    assert!(
        receipt["keystore"]["path"]
            .as_str()
            .unwrap()
            .ends_with(r"\release.p12")
    );
    assert!(!receipt.to_string().contains("fixture-ks-1Pz"));

    let status = status_document(&root, &secrets);
    assert_eq!(status["installed"], true);
    assert_eq!(status["ready"], true);
    assert_eq!(status["credential"], installed);
    assert_eq!(status["diagnostics"], json!([]));

    let removed = remove_document(&root, &secrets).unwrap();
    assert_eq!(
        removed,
        json!({"schemaVersion": "arkdeck.signing-credential-removal/1", "state": "removed",
            "removedReceipt": true, "removedKeystorePassword": true,
            "removedKeyPassword": true, "removedManagedMaterial": false,
            "preservedSourceCount": 3})
    );
    assert!(secrets.0.lock().unwrap().is_empty());
    assert_eq!(status_document(&root, &secrets)["installed"], false);
}

#[test]
fn a_relative_path_or_a_deveco_build_profile_is_refused_before_any_secret() {
    let scratch = Scratch::new("cli-signing-refusals");
    let secrets = Memory::default();
    let never = &mut |_: &str| -> Result<Secret, arkdeck_cli::CliError> {
        panic!("no password is asked for")
    };
    let options = scratch.options();
    let mut relative = options.clone();
    relative.insert("jar".into(), json!(r"lib\hap-sign-tool.jar"));
    let error = install_document(
        &scratch.root(),
        "runtime.signing.install",
        &relative,
        &secrets,
        never,
        "2026-09-30T00:00:00Z",
    )
    .unwrap_err();
    assert!(
        error.message.contains("--jar must be an absolute path"),
        "{}",
        error.message
    );
    // A Unix spelling is not absolute here either.
    let mut unix = options.clone();
    unix.insert("keystore".into(), json!("/Users/someone/release.p12"));
    assert!(
        install_document(
            &scratch.root(),
            "runtime.signing.install",
            &unix,
            &secrets,
            never,
            "2026-09-30T00:00:00Z",
        )
        .is_err()
    );
    let mut profile = options;
    profile.insert(
        "buildProfile".into(),
        json!(scratch.file("build-profile.json5", b"{}")),
    );
    let error = install_document(
        &scratch.root(),
        "runtime.signing.install",
        &profile,
        &secrets,
        never,
        "2026-09-30T00:00:00Z",
    )
    .unwrap_err();
    assert_eq!(error.code, "unsupportedOnPlatform");
    assert!(!scratch.root().exists());
    assert!(secrets.0.lock().unwrap().is_empty());
}

/// The CLI with no daemon pin in its environment and `ARKDECK_DAEMON_PATH`
/// naming `daemon`.
fn arkdeck(arguments: &[&str], daemon: &Path, family: Option<&str>) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
    command
        .args(arguments)
        .env("ARKDECK_DAEMON_PATH", daemon)
        .env_remove("ARKDECK_DAEMON_SIGNER_SHA256")
        .env_remove("ARKDECK_DAEMON_PUBLISHER_ORGANIZATION")
        .env_remove("ARKDECK_DAEMON_PUBLISHER_EKU")
        .env_remove("ARKDECK_DAEMON_PACKAGE_FAMILY")
        .stdin(std::process::Stdio::null());
    if let Some(family) = family {
        command.env("ARKDECK_DAEMON_PACKAGE_FAMILY", family);
    }
    command.output().unwrap()
}

#[test]
fn maintenance_refuses_a_daemon_that_satisfies_no_signing_pin_before_anything() {
    let scratch = Scratch::new("cli-signing-pin");
    let daemon = scratch.0.join("arkdeck-agentd.exe");
    let mut copy = create_private_file(&daemon).unwrap();
    std::io::copy(
        &mut std::fs::File::open(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join(r"System32\whoami.exe"),
        )
        .unwrap(),
        &mut copy,
    )
    .unwrap();
    drop(copy);
    let root = SigningPresetStore::default_root().unwrap();
    let existed = root.exists();
    for (arguments, family) in [
        (&["runtime", "signing", "remove"][..], None),
        (&["signing", "remove"][..], None),
        (
            &["runtime", "signing", "remove"][..],
            Some("ArkDeck.Fixture_0000000000000"),
        ),
        (
            &[
                "runtime",
                "signing",
                "install-sdk-release",
                "--sdk",
                r"C:\absent\sdk",
                "--java",
                r"C:\absent\java.exe",
                "--bundle-name",
                "com.example.app",
            ][..],
            None,
        ),
    ] {
        let output = arkdeck(arguments, &daemon, family);
        assert_eq!(output.status.code(), Some(1), "{arguments:?}: {output:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("arkdeck-agentd.exe"),
            "{arguments:?}: {stderr}"
        );
        if family.is_some() {
            assert!(stderr.contains("satisfies no signing pin"), "{stderr}");
        }
    }
    // Nothing was created in the account's preset root.
    assert_eq!(root.exists(), existed);
}

#[test]
fn the_deveco_material_leaves_are_refused_on_windows() {
    let scratch = Scratch::new("cli-signing-deveco");
    let daemon = scratch.0.join("arkdeck-agentd.exe");
    let profile = scratch.file("build-profile.json5", b"{}");
    let root = SigningPresetStore::default_root().unwrap();
    let existed = root.exists();
    for spelling in [&["runtime", "signing"][..], &["signing"][..]] {
        let arguments: Vec<&str> = spelling
            .iter()
            .copied()
            .chain([
                "migrate-deveco",
                "--build-profile",
                &profile,
                "--daemon",
                daemon.to_str().unwrap(),
                "--json",
            ])
            .collect();
        let output = arkdeck(&arguments, &daemon, None);
        assert_ne!(output.status.code(), Some(0), "{output:?}");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            text.contains("not read on Windows yet"),
            "{arguments:?}: {text}"
        );
    }
    assert_eq!(root.exists(), existed);
}
