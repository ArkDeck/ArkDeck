//! A Windows signing receipt bound to the installed daemon's code identity
//! (TASK-XPA-011): the credential owner records the daemon's Authenticode
//! signer and bytes (`arkdeck_platform::trusted_daemon_fingerprint`) at
//! installation, refuses the credential to any other daemon image, and binds
//! it again to an updated daemon only through explicit maintenance
//! (`refresh_daemon_identity`), as on macOS.
//!
//! The secret source is `KeychainSigningSecrets` over a Credential Manager
//! fixture namespace, bound to a fixture daemon: a copy of a system
//! executable signed with the host's development signer
//! (`ARKDECK_DEV_SIGNER_THUMBPRINT`); the signed part is skipped, saying so,
//! where the host has none. Every credential the test writes is removed.
#![cfg(windows)]

use arkdeck_platform::{
    KeychainItems, Secret, application_support_directory, create_private_directory,
    create_private_file, random_bytes, trusted_daemon_fingerprint,
};
use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::credential_owner::CredentialOwner;
use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
use arkdeck_provider_workspace::secret_envelope::SecretPair;
use arkdeck_provider_workspace::signing_install::SigningPresetConfiguration;
use arkdeck_provider_workspace::signing_preset::{
    DEFAULT_PRESET_ID, KEYCHAIN_SERVICE, SecretPresence, SigningPresetStore, SigningSecrets,
};
use std::io::Write;
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
        Self(arkdeck_platform::host_resolved_path(&path).unwrap())
    }

    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        create_private_file(&path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
        path
    }

    /// `System32\<system>` copied over `path` (replacing it) and signed.
    fn install_daemon(&self, path: &Path, system: &str) -> bool {
        let _ = std::fs::remove_file(path);
        let mut source = std::fs::File::open(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(system),
        )
        .unwrap();
        let mut copy = create_private_file(path).unwrap();
        std::io::copy(&mut source, &mut copy).unwrap();
        drop(copy);
        sign(path)
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

/// Removes every account the tree's receipt or ledger names.
struct Cleanup(PathBuf, KeychainItems);
impl Drop for Cleanup {
    fn drop(&mut self) {
        for name in ["preset-v1.json", "credential-owner-v1.json"] {
            let Ok(bytes) = std::fs::read(self.0.join(name)) else {
                continue;
            };
            let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
                continue;
            };
            for key in [
                "secretEnvelopeAccount",
                "supersededEnvelopeAccounts",
                "pendingEnvelopeAccounts",
            ] {
                let accounts: Vec<String> = match &value[key] {
                    serde_json::Value::String(account) => vec![account.clone()],
                    serde_json::Value::Array(list) => list
                        .iter()
                        .filter_map(|account| account.as_str().map(str::to_owned))
                        .collect(),
                    _ => Vec::new(),
                };
                for account in accounts {
                    let _ = self.1.remove(&account);
                }
            }
        }
    }
}

#[test]
fn a_receipt_is_honoured_only_by_the_daemon_it_was_bound_to() {
    let scratch = Scratch::new("daemon-binding");
    let helpers = scratch.0.join("helpers");
    create_private_directory(&helpers).unwrap();
    let daemon = helpers.join("arkdeck-agentd.exe");
    if !scratch.install_daemon(&daemon, "whoami.exe") {
        return;
    }
    let namespace = format!(
        "test-{}-{:016x}",
        std::process::id(),
        u64::from_le_bytes(random_bytes().unwrap())
    );
    let items = || KeychainItems::fixture_namespace(KEYCHAIN_SERVICE, &namespace).unwrap();
    let root = scratch.0.join("preset");
    let _cleanup = Cleanup(root.clone(), items());
    let secrets = KeychainSigningSecrets::over(items()).bound_to(daemon.clone());
    let owner = CredentialOwner::new(SigningPresetStore::new(&root));
    let jdk = scratch.0.join("jdk");
    create_private_directory(&jdk).unwrap();
    let configuration = SigningPresetConfiguration {
        project_ref: "demo-app".into(),
        java_executable: scratch.file(r"jdk\java.exe", b"not run: fixture launcher"),
        signer_jar: scratch.file("hap-sign-tool.jar", b"fixture jar"),
        keystore: scratch.file("release.p12", b"fixture keystore"),
        app_certificate: scratch.file("release.cer", b"fixture certificate"),
        signed_profile: scratch.file("release.p7b", b"fixture profile"),
        key_alias: "release".into(),
        managed_material_directory: None,
    };
    let pair = SecretPair {
        keystore: Secret::from_slice(b"fixture-ks-6Tb"),
        key: Secret::from_slice(b"fixture-key-4Qm"),
    };

    owner
        .install(&configuration, &pair, &secrets, "2026-09-30T00:00:00Z")
        .unwrap();
    let store = SigningPresetStore::new(&root);
    let receipt = store
        .load_validated(DEFAULT_PRESET_ID, true, &secrets)
        .unwrap();
    let bound = trusted_daemon_fingerprint(&daemon).unwrap();
    assert_eq!(
        receipt.trusted_daemon_application_sha256,
        Some(bound.clone())
    );
    assert!(store.secret_pair(&receipt, &secrets).is_ok());
    let credential = owner.current().unwrap().credential_ref;

    // Another daemon image at the installed path: the credential is refused
    // to it, for signing and for resolution alike, and nothing is read.
    assert!(scratch.install_daemon(&daemon, "hostname.exe"));
    let drift = store
        .load_validated(DEFAULT_PRESET_ID, true, &secrets)
        .unwrap_err();
    assert!(
        matches!(&drift, SigningError::IdentityDrift(message) if message.contains("arkdeck-agentd")),
        "{drift:?}"
    );
    assert!(owner.resolve(&credential, None, true, &secrets).is_err());
    // An unsigned image has no identity at all.
    std::fs::remove_file(&daemon).unwrap();
    let mut unsigned = create_private_file(&daemon).unwrap();
    std::io::copy(
        &mut std::fs::File::open(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join(r"System32\whoami.exe"),
        )
        .unwrap(),
        &mut unsigned,
    )
    .unwrap();
    drop(unsigned);
    assert!(
        store
            .load_validated(DEFAULT_PRESET_ID, true, &secrets)
            .is_err()
    );

    // Explicit maintenance binds the credential to the updated daemon; its
    // public identity does not change, and neither does the secret.
    assert!(scratch.install_daemon(&daemon, "hostname.exe"));
    owner.refresh_daemon_identity(&secrets).unwrap();
    let refreshed = store
        .load_validated(DEFAULT_PRESET_ID, true, &secrets)
        .unwrap();
    assert_eq!(
        refreshed.trusted_daemon_application_sha256,
        Some(trusted_daemon_fingerprint(&daemon).unwrap())
    );
    assert_ne!(refreshed.trusted_daemon_application_sha256, Some(bound));
    assert_eq!(owner.current().unwrap().credential_ref, credential);
    let pair = store.secret_pair(&refreshed, &secrets).unwrap();
    assert_eq!(pair.key.as_bytes(), b"fixture-key-4Qm");

    let account = refreshed.secret_envelope_account.clone().unwrap();
    owner.remove(&secrets).unwrap();
    assert_eq!(secrets.presence(&account), SecretPresence::Absent);
}
