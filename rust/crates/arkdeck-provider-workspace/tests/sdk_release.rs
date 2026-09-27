//! SDK release success and failure paths use the vendored process stand-in
//! and memory secrets. No production Java, Keychain or device is accessed.
#![cfg(target_os = "macos")]
#[path = "support/sdk_signer.rs"]
mod sdk_signer;
use arkdeck_platform::Secret;
use arkdeck_provider_workspace::{
    SigningError,
    credential_owner::CredentialOwner,
    sdk_release::SdkReleaseConfiguration,
    signing_install::SigningSecretInstallation,
    signing_preset::{DEFAULT_PRESET_ID, SecretPresence, SigningPresetStore, SigningSecrets},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
#[derive(Default)]
struct Secrets {
    values: Mutex<BTreeMap<String, Secret>>,
    writes: AtomicUsize,
}
impl SigningSecrets for Secrets {
    fn read(&self, account: &str) -> Result<Secret, SigningError> {
        self.values
            .lock()
            .unwrap()
            .get(account)
            .cloned()
            .ok_or_else(|| SigningError::SecretUnavailable("fixture absent".into()))
    }
    fn presence(&self, account: &str) -> SecretPresence {
        if self.values.lock().unwrap().contains_key(account) {
            SecretPresence::Present
        } else {
            SecretPresence::Absent
        }
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(Some("a".repeat(64)))
    }
}
impl SigningSecretInstallation for Secrets {
    fn set_envelope(&self, account: &str, bytes: &[u8]) -> Result<(), SigningError> {
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.values
            .lock()
            .unwrap()
            .insert(account.into(), Secret::from_slice(bytes));
        Ok(())
    }
    fn remove_envelope(&self, account: &str) -> Result<bool, SigningError> {
        Ok(self.values.lock().unwrap().remove(account).is_some())
    }
}
fn pem(name: &str) -> String {
    format!("-----BEGIN CERTIFICATE-----\n{name}\n-----END CERTIFICATE-----\n")
}
struct Fixture {
    home: PathBuf,
    root: PathBuf,
    configuration: SdkReleaseConfiguration,
}
impl Fixture {
    fn new(mode: &str) -> Self {
        let home = PathBuf::from(format!(
            "/private/tmp/arkdeck-sdk-release-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        let home = PathBuf::from(
            arkdeck_provider_workspace::foundation_resolved_path(home.to_str().unwrap()).unwrap(),
        );
        let root = home.join("preset");
        let sdk = home.join("sdk");
        let library = sdk.join("toolchains/lib");
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&library)
            .unwrap();
        let write = |name: &str, bytes: &[u8]| {
            let path = library.join(name);
            fs::write(&path, bytes).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        };
        write("hap-sign-tool.jar", mode.as_bytes());
        write("OpenHarmony.p12", b"SDK public fixture keystore");
        write(
            "OpenHarmonyProfileRelease.pem",
            format!("{}{}{}", pem("root"), pem("ca"), pem("profile")).as_bytes(),
        );
        write("UnsgnedReleasedProfileTemplate.json",&serde_json::to_vec(&json!({"type":"release","app-distribution-type":"os_integration","issuer":"pki_internal","bundle-info":{"apl":"normal","app-feature":"hos_normal_app","distribution-certificate":pem("application")},"validity":{"not-before":0,"not-after":1}})).unwrap());
        Self {
            home,
            root,
            configuration: SdkReleaseConfiguration {
                project_ref: "demo-app".into(),
                bundle_name: "com.example.app".into(),
                java_executable: sdk_signer::fake_signer().to_owned(),
                sdk_root: sdk,
            },
        }
    }
    fn owner(&self) -> CredentialOwner {
        CredentialOwner::new(SigningPresetStore::new(&self.root))
    }
    fn receipt(&self) -> Value {
        serde_json::from_slice(&fs::read(self.root.join("preset-v1.json")).unwrap()).unwrap()
    }
    fn material_count(&self) -> usize {
        fs::read_dir(&self.root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("sdk-release-")
            })
            .count()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.home);
    }
}
#[test]
fn sdk_profile_is_signed_verified_bound_to_bundle_and_replaces_only_managed_material() {
    let f = Fixture::new("success");
    let secrets = Secrets::default();
    let owner = f.owner();
    let first = owner
        .install_sdk_release(
            &f.configuration,
            &secrets,
            "2026-09-26T00:00:00Z",
            1_000_000,
        )
        .unwrap();
    let receipt = f.receipt();
    let old = PathBuf::from(receipt["managedMaterialDirectory"].as_str().unwrap());
    let profile: Value = serde_json::from_slice(
        &fs::read(receipt["signedProfile"]["path"].as_str().unwrap()).unwrap(),
    )
    .unwrap();
    assert_eq!(profile["bundle-info"]["bundle-name"], "com.example.app");
    assert_eq!(
        profile["validity"],
        json!({"not-before":999700,"not-after":32536000})
    );
    assert!(!old.join("profile-verification.json").exists());
    assert_eq!(
        fs::read_to_string(old.join("OpenHarmonyApplicationRelease.pem")).unwrap(),
        format!("{}{}{}", pem("root"), pem("ca"), pem("application"))
    );
    let validated = owner
        .store()
        .load_validated(DEFAULT_PRESET_ID, true, &secrets)
        .unwrap();
    assert_eq!(
        owner
            .store()
            .secret_pair(&validated, &secrets)
            .unwrap()
            .key
            .as_bytes(),
        b"123456"
    );
    let second = owner
        .install_sdk_release(
            &f.configuration,
            &secrets,
            "2026-09-26T01:00:00Z",
            1_003_600,
        )
        .unwrap();
    assert_ne!(first.credential_ref, second.credential_ref);
    assert!(!old.exists());
    assert_eq!(f.material_count(), 1);
    assert_eq!(
        fs::read(
            f.configuration
                .sdk_root
                .join("toolchains/lib/OpenHarmony.p12")
        )
        .unwrap(),
        b"SDK public fixture keystore"
    );
}
#[test]
fn signing_or_verification_failure_writes_no_secret_or_receipt_and_cleans_attempt() {
    for mode in ["sign-profile-failure", "verify-profile-failure"] {
        let f = Fixture::new(mode);
        let secrets = Secrets::default();
        assert!(
            f.owner()
                .install_sdk_release(
                    &f.configuration,
                    &secrets,
                    "2026-09-26T00:00:00Z",
                    1_000_000
                )
                .is_err()
        );
        assert_eq!(secrets.writes.load(Ordering::SeqCst), 0);
        assert!(!f.root.join("preset-v1.json").exists());
        assert_eq!(f.material_count(), 0);
    }
}
#[test]
fn pinned_sdk_credential_is_not_rebuilt_or_replaced() {
    let f = Fixture::new("success");
    let secrets = Secrets::default();
    let owner = f.owner();
    let credential = owner
        .install_sdk_release(
            &f.configuration,
            &secrets,
            "2026-09-26T00:00:00Z",
            1_000_000,
        )
        .unwrap();
    owner
        .acquire(&credential.credential_ref, "preset-a", &secrets)
        .unwrap();
    let before = f.receipt();
    let writes = secrets.writes.load(Ordering::SeqCst);
    assert!(
        owner
            .install_sdk_release(&f.configuration, &secrets, "later", 1_003_600)
            .is_err()
    );
    assert_eq!(f.receipt(), before);
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    assert_eq!(f.material_count(), 1);
}
#[test]
fn unaccepted_template_or_chain_never_reaches_secret_installation() {
    for corrupt_chain in [false, true] {
        let f = Fixture::new("success");
        let secrets = Secrets::default();
        let path = f
            .configuration
            .sdk_root
            .join("toolchains/lib")
            .join(if corrupt_chain {
                "OpenHarmonyProfileRelease.pem"
            } else {
                "UnsgnedReleasedProfileTemplate.json"
            });
        fs::write(
            path,
            if corrupt_chain {
                pem("single")
            } else {
                "{\"type\":\"debug\"}".into()
            },
        )
        .unwrap();
        assert!(
            f.owner()
                .install_sdk_release(
                    &f.configuration,
                    &secrets,
                    "2026-09-26T00:00:00Z",
                    1_000_000
                )
                .is_err()
        );
        assert_eq!(secrets.writes.load(Ordering::SeqCst), 0);
        assert_eq!(f.material_count(), 0);
    }
}

#[test]
fn a_failed_replacement_preserves_the_previous_credential_and_managed_material() {
    let f = Fixture::new("success");
    let mode = format!(
        "verify-profile-succeed-once:{}",
        f.home.join("verified-once").display()
    );
    fs::write(
        f.configuration
            .sdk_root
            .join("toolchains/lib/hap-sign-tool.jar"),
        mode,
    )
    .unwrap();
    let secrets = Secrets::default();
    let owner = f.owner();
    let first = owner
        .install_sdk_release(
            &f.configuration,
            &secrets,
            "2026-09-26T00:00:00Z",
            1_000_000,
        )
        .unwrap();
    let before = fs::read(f.root.join("preset-v1.json")).unwrap();
    let writes = secrets.writes.load(Ordering::SeqCst);
    let error = owner
        .install_sdk_release(
            &f.configuration,
            &secrets,
            "2026-09-26T01:00:00Z",
            1_003_600,
        )
        .unwrap_err();
    assert!(error.to_string().contains("verify-profile readback"));
    assert_eq!(fs::read(f.root.join("preset-v1.json")).unwrap(), before);
    assert_eq!(owner.current().unwrap(), first);
    assert_eq!(f.material_count(), 1);
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
}
