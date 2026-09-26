//! The explicit install leaf over fake secret storage. Process-level cases
//! refuse before any Keychain access; successful installs are library fixtures.
#![cfg(target_os = "macos")]
#[path = "support/signing_fixture.rs"]
mod signing_fixture;
use arkdeck_cli::signing_leaves::install_document;
use arkdeck_platform::Secret;
use arkdeck_provider_workspace::{
    SigningError,
    signing_install::SigningSecretInstallation,
    signing_preset::{SecretPresence, SigningSecrets},
};
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Command, Stdio},
    sync::Mutex,
};
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        Self(PathBuf::from(format!(
            "/private/tmp/arkdeck-cli-install-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        )))
    }
    fn options(&self) -> Map<String, Value> {
        let receipt = signing_fixture::install(&self.0);
        json!({"java":receipt["javaExecutable"]["path"],"jar":receipt["signerJAR"]["path"],"keystore":receipt["keystore"]["path"],"certificate":receipt["appCertificate"]["path"],"profile":receipt["signedProfile"]["path"],"keyAlias":"release","projectRef":"demo-app"}).as_object().unwrap().clone()
    }
    fn profile(&self, contents: &str) -> String {
        let path = self.0.join("build-profile.json5");
        fs::write(&path, contents).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        arkdeck_provider_workspace::foundation_resolved_path(path.to_str().unwrap()).unwrap()
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[derive(Default)]
struct Secrets(Mutex<BTreeMap<String, Secret>>);
impl SigningSecrets for Secrets {
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
        Ok(Some("a".repeat(64)))
    }
}
impl SigningSecretInstallation for Secrets {
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
#[test]
fn install_uses_two_terminal_prompts_and_publishes_only_the_credential_projection() {
    let home = Home::new();
    let options = home.options();
    let secrets = Secrets::default();
    let mut prompts = Vec::new();
    let result = install_document(
        &home.0,
        "runtime.signing.install",
        &options,
        &secrets,
        &mut |prompt| {
            prompts.push(prompt.to_owned());
            Ok(Secret::from_slice(b"fixture-password"))
        },
        "2026-09-26T00:00:00Z",
    )
    .unwrap();
    assert_eq!(prompts, ["Keystore password: ", "Key password: "]);
    assert_eq!(result["schemaVersion"], "arkdeck.signing-credential/1");
    assert_eq!(result["state"], "available");
    assert_eq!(result["referenceCount"], 0);
    assert!(!result.to_string().contains("fixture-password"));
    assert_eq!(secrets.0.lock().unwrap().len(), 1);
}
#[test]
fn a_headless_profile_is_bound_to_the_exact_keystore_before_any_secret_write() {
    let home = Home::new();
    let mut options = home.options();
    let secrets = Secrets::default();
    let profile = home.profile(&format!(
        "{{storeFile:'{}',storePassword:'{}',keyPassword:'{}'}}",
        options["keystore"].as_str().unwrap(),
        "ab".repeat(16),
        "cd".repeat(16)
    ));
    options.insert("buildProfile".into(), json!(profile));
    let result = install_document(
        &home.0,
        "runtime.signing.install",
        &options,
        &secrets,
        &mut |_| panic!("headless profile must not prompt"),
        "2026-09-26T00:00:00Z",
    )
    .unwrap();
    assert_eq!(result["projectRef"], "demo-app");
    options.insert("keystore".into(), json!("/a/different.p12"));
    let before = secrets.0.lock().unwrap().len();
    let error = install_document(
        &home.0,
        "runtime.signing.install",
        &options,
        &secrets,
        &mut |_| panic!("must not prompt"),
        "later",
    )
    .unwrap_err();
    assert_eq!(error.plain_exit, Some(64));
    assert!(error.message.contains("different storeFile"));
    assert_eq!(secrets.0.lock().unwrap().len(), before);
}
#[test]
fn ambiguous_mutable_or_noncanonical_profiles_refuse() {
    use arkdeck_cli::signing_inputs::read_deveco_profile;
    let home = Home::new();
    home.options();
    for content in [
        format!(
            "{{storeFile:'/x.p12',storePassword:'{}',keyPassword:'{}',storePassword:'{}'}}",
            "ab".repeat(16),
            "cd".repeat(16),
            "ef".repeat(16)
        ),
        format!(
            "{{storeFile:'relative.p12',storePassword:'{}',keyPassword:'{}'}}",
            "ab".repeat(16),
            "cd".repeat(16)
        ),
        format!(
            "{{storeFile:'/x.p12',storePassword:'{}',keyPassword:'{}'}}",
            "a".repeat(33),
            "cd".repeat(16)
        ),
    ] {
        let profile = home.profile(&content);
        assert_eq!(
            read_deveco_profile(profile.as_ref())
                .err()
                .unwrap()
                .plain_exit,
            Some(64)
        );
    }
    let profile = home.profile(&format!(
        "{{storeFile:'/x.p12',storePassword:'{}',keyPassword:'{}'}}",
        "ab".repeat(16),
        "cd".repeat(16)
    ));
    fs::set_permissions(&profile, fs::Permissions::from_mode(0o666)).unwrap();
    assert!(read_deveco_profile(profile.as_ref()).is_err());
}
#[test]
fn actual_cli_replays_swifts_pre_keychain_refusals_without_touching_the_home() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../tests/fixtures/signing-install/cases.json"
    ))
    .unwrap();
    for case in cases {
        let home = Home::new();
        fs::create_dir(&home.0).unwrap();
        let profile = case
            .get("profileContents")
            .and_then(Value::as_str)
            .map(|contents| home.profile(contents));
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(case["argv"].as_array().unwrap().iter().map(|v| {
                if v == "{PROFILE}" {
                    profile.as_deref().unwrap()
                } else {
                    v.as_str().unwrap()
                }
            }))
            .env("HOME", &home.0)
            .env("CFFIXED_USER_HOME", &home.0)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(case["exit"].as_i64().unwrap() as i32)
        );
        assert_eq!(output.stdout, case["stdout"].as_str().unwrap().as_bytes());
        assert_eq!(output.stderr, case["stderr"].as_str().unwrap().as_bytes());
        assert_eq!(
            fs::read_dir(&home.0).unwrap().count(),
            usize::from(profile.is_some())
        );
        if let Some(profile) = profile {
            assert_eq!(
                fs::read_to_string(profile).unwrap(),
                case["profileContents"].as_str().unwrap()
            );
        }
    }
}

#[test]
fn signing_option_spellings_do_not_leak_into_other_command_surfaces() {
    for argv in [
        vec!["workspace", "project", "show", "--project-ref", "demo-app"],
        vec!["runtime", "signing", "install", "--project", "demo-app"],
    ] {
        let error = arkdeck_cli::parse(&argv.iter().map(|v| v.to_string()).collect::<Vec<_>>())
            .unwrap_err();
        assert_eq!(error.code, "invalidOption");
    }
}

#[test]
fn migrate_authenticates_profile_keystore_and_preserves_installation() {
    use arkdeck_cli::signing_leaves::migrate_deveco_document;
    let home = Home::new();
    let options = home.options();
    let secrets = Secrets::default();
    let first = install_document(
        &home.0,
        "runtime.signing.install",
        &options,
        &secrets,
        &mut |_| Ok(Secret::from_slice(b"old-password")),
        "2026-09-26T00:00:00Z",
    )
    .unwrap();
    let profile = home.profile(&format!(
        "{{storeFile:'{}',storePassword:'{}',keyPassword:'{}'}}",
        options["keystore"].as_str().unwrap(),
        "ab".repeat(16),
        "cd".repeat(16)
    ));
    let migrate = json!({"buildProfile":profile});
    let result = migrate_deveco_document(&home.0, migrate.as_object().unwrap(), &secrets).unwrap();
    assert_eq!(result["credential"], first);
    assert_eq!(result["createdEnvelopeItem"], false);
    let other = home.0.join("different.p12");
    fs::write(&other, b"unrelated keystore").unwrap();
    fs::set_permissions(&other, fs::Permissions::from_mode(0o600)).unwrap();
    let other =
        arkdeck_provider_workspace::foundation_resolved_path(other.to_str().unwrap()).unwrap();
    home.profile(&format!(
        "{{storeFile:'{other}',storePassword:'{}',keyPassword:'{}'}}",
        "ab".repeat(16),
        "cd".repeat(16)
    ));
    let before: BTreeMap<_, _> = secrets
        .0
        .lock()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_bytes().to_vec()))
        .collect();
    let error =
        migrate_deveco_document(&home.0, migrate.as_object().unwrap(), &secrets).unwrap_err();
    assert!(
        error
            .message
            .contains("does not match the installed preset")
    );
    for (account, value) in before {
        assert_eq!(secrets.read(&account).unwrap().as_bytes(), value);
    }
}

#[test]
fn migrate_cli_replays_swift_refusals_before_keychain_access() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../tests/fixtures/signing-migrate/cases.json"
    ))
    .unwrap();
    assert_eq!(cases.len(), 12);
    for case in cases {
        let home = Home::new();
        fs::create_dir(&home.0).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(
                case["argv"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap()),
            )
            .env("HOME", &home.0)
            .env("CFFIXED_USER_HOME", &home.0)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(case["exit"].as_i64().unwrap() as i32)
        );
        assert_eq!(output.stdout, case["stdout"].as_str().unwrap().as_bytes());
        assert_eq!(output.stderr, case["stderr"].as_str().unwrap().as_bytes());
        assert_eq!(fs::read_dir(&home.0).unwrap().count(), 0);
    }
}
