//! `sign_hap` end to end against `ArkDeckFakeHapSignerFixture` (SPK-10,
//! TASK-XPA-015): the fixture's Swift source, compiled here with `swiftc`, is
//! the "java" of a preset whose JAR file names the fixture's mode, and the
//! preset's envelope lives in a keychain created with `security
//! create-keychain` for the test. The pass criterion of SPK-10 is checked
//! directly: the kernel's record of the running signer's argv and environment
//! (`KERN_PROCARGS2`), every file the run leaves, the returned receipt and
//! every failure text carry neither password.
//!
//! `rust/tests/fixtures/fake-hap-signer/main.swift` is a byte-identical copy of
//! `Packages/ArkDeckKit/Tests/ArkDeckFakeHapSignerFixture/main.swift`, so that
//! the contract views, which hold only `rust/` and the contract inputs, run
//! the same fixture; `the_vendored_fixture_is_the_swift_fixture` keeps them
//! equal. Every test here spawns children, so they share this binary alone.
#![cfg(target_os = "macos")]

use arkdeck_platform::{KeychainItems, process_argument_record, random_bytes};
use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
use arkdeck_provider_workspace::secret_envelope::encode_envelope;
use arkdeck_provider_workspace::signer::{
    SUMMARY_KEYS, SigningFailure, read_verified_result, sign_hap,
};
use arkdeck_provider_workspace::signing_action::{SigningAction, SigningAttemptPaths};
use arkdeck_provider_workspace::signing_preset::{
    DEFAULT_PRESET_ID, KEYCHAIN_ACCESS_SCHEMA, KEYCHAIN_SERVICE, RECEIPT_SCHEMA, SecretPresence,
    SigningPresetReceipt, SigningPresetStore, SigningSecrets, decode_receipt,
};
use arkdeck_provider_workspace::{SigningError, foundation_resolved_path, measure};
use sha2::{Digest, Sha256};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const SWIFT_FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../Packages/ArkDeckKit/Tests/ArkDeckFakeHapSignerFixture/main.swift"
);
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
fn fake_signer() -> &'static Path {
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

/// One test's preset, keychain, input and attempt root; deleted with it.
struct Fixture {
    root: PathBuf,
    keychain: PathBuf,
    store: SigningPresetStore,
    receipt: SigningPresetReceipt,
    keystore_secret: Vec<u8>,
    key_secret: Vec<u8>,
    input: PathBuf,
    input_bytes: Vec<u8>,
    attempts: PathBuf,
}

impl Fixture {
    fn new(mode: &str) -> Self {
        let root = base().join(format!("signing-{}", token()));
        std::fs::create_dir(&root).unwrap();
        let material = root.join("material");
        std::fs::create_dir(&material).unwrap();
        let write = |name: &str, bytes: &[u8], mode: u32| {
            let path = material.join(name);
            std::fs::write(&path, bytes).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
            path
        };
        // The fixture reads its mode from the JAR it is handed.
        let jar = write("hap-sign-tool.jar", mode.as_bytes(), 0o644);
        let keystore = write("release.p12", b"fixture-keystore", 0o600);
        let certificate = write("release.cer", b"fixture-certificate", 0o644);
        let profile = write("release.p7b", b"fixture-profile", 0o644);
        let text = |path: &Path| path.to_str().unwrap().to_owned();
        let measured = |path: &Path, role: &str, executable: bool, private: bool| {
            measure(&text(path), role, executable, private).unwrap()
        };

        let keychain = root.join("fixture.keychain-db");
        let status = Command::new("/usr/bin/security")
            .args(["create-keychain", "-p", &token()])
            .arg(&keychain)
            .status()
            .unwrap();
        assert!(status.success());
        let status = Command::new("/usr/bin/security")
            .arg("set-keychain-settings")
            .arg(&keychain)
            .status()
            .unwrap();
        assert!(status.success());

        let keystore_secret = format!("spk10-keystore-secret-{}", token()).into_bytes();
        let key_secret = format!("spk10-key-secret-{}", token()).into_bytes();
        let envelope_account = format!(
            "{DEFAULT_PRESET_ID}|secret-envelope-{}",
            "4f0f3c56-2d8a-4e3b-9a61-7c2b5d9e8f10"
        );
        KeychainItems::file_keychain(KEYCHAIN_SERVICE, &keychain)
            .unwrap()
            .set(
                &envelope_account,
                encode_envelope(&keystore_secret, &key_secret).as_bytes(),
            )
            .unwrap();

        let preset_root = root.join("preset");
        std::fs::create_dir(&preset_root).unwrap();
        std::fs::set_permissions(&preset_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let receipt = SigningPresetReceipt {
            schema_version: RECEIPT_SCHEMA.into(),
            installed_at_utc: "2026-09-19T00:00:00Z".into(),
            preset_id: DEFAULT_PRESET_ID.into(),
            project_ref: "demo-app".into(),
            java_executable: measured(fake_signer(), "java", true, false),
            signer_jar: measured(&jar, "signer JAR", false, false),
            keystore: measured(&keystore, "keystore", false, true),
            app_certificate: measured(&certificate, "app certificate", false, false),
            signed_profile: measured(&profile, "signed profile", false, false),
            key_alias: "test-key".into(),
            signing_algorithm: "SHA256withECDSA".into(),
            keystore_password_account: format!("{DEFAULT_PRESET_ID}|keystore"),
            key_password_account: format!("{DEFAULT_PRESET_ID}|key"),
            secret_envelope_account: Some(envelope_account),
            superseded_envelope_accounts: None,
            trusted_daemon_application_sha256: None,
            keychain_access_schema: Some(KEYCHAIN_ACCESS_SCHEMA.into()),
            managed_material_directory: None,
        };
        std::fs::write(
            preset_root.join("preset-v1.json"),
            serde_json::to_vec_pretty(&receipt).unwrap(),
        )
        .unwrap();

        let input = root.join("ART-INPUT");
        let input_bytes = [&[0x50, 0x4b, 0x03, 0x04][..], b"unsigned-body"].concat();
        std::fs::write(&input, &input_bytes).unwrap();
        // The signer's working directory must be physical.
        let attempts = root.canonicalize().unwrap().join("attempts");
        std::fs::create_dir(&attempts).unwrap();
        Self {
            root,
            keychain,
            store: SigningPresetStore::new(preset_root),
            receipt,
            keystore_secret,
            key_secret,
            input,
            input_bytes,
            attempts,
        }
    }

    fn secrets(&self) -> KeychainSigningSecrets {
        KeychainSigningSecrets::over(
            KeychainItems::file_keychain(KEYCHAIN_SERVICE, &self.keychain).unwrap(),
        )
    }

    fn action(&self, job_id: &str) -> SigningAction {
        SigningAction {
            job_id: job_id.into(),
            project_ref: "demo-app".into(),
            signing_preset_ref: Some("preset-signing".into()),
            preset: self.receipt.clone(),
            input_artifact_id: "ART-INPUT".into(),
            input_file_path: self.input.to_str().unwrap().into(),
            input_sha256: hex(&Sha256::digest(&self.input_bytes)),
            input_byte_count: self.input_bytes.len() as u64,
            output: SigningAttemptPaths::for_job(&self.attempts, job_id),
        }
    }

    /// Neither password appears in `bytes`.
    fn assert_secret_free(&self, what: &str, bytes: &[u8]) {
        for secret in [&self.keystore_secret, &self.key_secret] {
            assert!(
                !bytes
                    .windows(secret.len())
                    .any(|window| window == secret.as_slice()),
                "a password reached {what}"
            );
        }
    }

    /// Every regular file below the fixture root, the keychain included.
    fn assert_files_secret_free(&self) {
        let mut pending = vec![self.root.clone()];
        let mut seen = 0;
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                let metadata = std::fs::symlink_metadata(&path).unwrap();
                if metadata.is_dir() {
                    pending.push(path);
                } else if metadata.is_file() {
                    seen += 1;
                    self.assert_secret_free(
                        &path.display().to_string(),
                        &std::fs::read(&path).unwrap(),
                    );
                }
            }
        }
        assert!(seen >= 6, "the scan must have read the run's files");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = Command::new("/usr/bin/security")
            .arg("delete-keychain")
            .arg(&self.keychain)
            .status();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn the_vendored_fixture_is_the_swift_fixture() {
    match std::fs::read(SWIFT_FIXTURE) {
        Ok(swift) => assert_eq!(
            std::fs::read(VENDORED_FIXTURE).unwrap(),
            swift,
            "rust/tests/fixtures/fake-hap-signer/main.swift drifted from the Swift fixture"
        ),
        // A contract view holds only `rust/`; the checkout run compares.
        Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::NotFound),
    }
}

/// The signer runs, both prompts are answered on the terminal, `verify-app`
/// reads the product back, and the record lands — with no password anywhere.
#[test]
fn a_hap_is_signed_verified_and_recorded_without_any_password_leaving_the_keychain() {
    let fixture = Fixture::new("success");
    let action = fixture.action("job-sign-success");
    let signed = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap();

    let expected_signed = [fixture.input_bytes.as_slice(), b"arkdeck-signed-fixture"].concat();
    assert_eq!(std::fs::read(&signed.signed_hap).unwrap(), expected_signed);
    assert_eq!(signed.byte_count, expected_signed.len() as u64);
    assert_eq!(signed.sha256, hex(&Sha256::digest(&expected_signed)));
    assert_eq!(
        signed
            .summary
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        SUMMARY_KEYS.to_vec()
    );
    for (key, value) in [
        ("verification", "verified".to_owned()),
        ("projectRef", "demo-app".to_owned()),
        ("signingPresetRef", "preset-signing".to_owned()),
        ("sourceArtifactId", "ART-INPUT".to_owned()),
        ("sourceSha256", action.input_sha256.clone()),
        ("sourceByteCount", fixture.input_bytes.len().to_string()),
        ("signedHapSha256", signed.sha256.clone()),
        (
            "certificateChainReadbackSha256",
            hex(&Sha256::digest(b"fixture-certificate-chain")),
        ),
        (
            "profileReadbackSha256",
            hex(&Sha256::digest(b"fixture-profile")),
        ),
        ("javaSha256", fixture.receipt.java_executable.sha256.clone()),
    ] {
        assert_eq!(signed.summary.get(key), Some(&value), "{key}");
    }

    // The record is Swift's canonical pretty document of that summary.
    let record = std::fs::read(&action.output.result_record).unwrap();
    let text = String::from_utf8(record.clone()).unwrap();
    assert!(text.starts_with("{\n  \"schemaVersion\" : \"arkdeck-openharmony-signing-result/v1\",\n  \"summary\" : {\n    \"appCertificateSha256\" : \""));
    assert!(!text.ends_with('\n'));
    let mode = std::fs::metadata(&action.output.result_record)
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    assert_eq!(read_verified_result(&action).unwrap(), signed.summary);

    fixture.assert_secret_free("the receipt", format!("{signed:?}").as_bytes());
    fixture.assert_files_secret_free();
}

/// The kernel's record of the live signer — its executable, argv and entire
/// environment — never holds a password. The fixture's `unknown-prompt` mode
/// waits a second after an unexpected prompt; the child is found by its
/// unique attempt directory, stopped while it is read, and resumed.
#[test]
fn the_running_signer_s_argv_and_environment_carry_no_password() {
    let fixture = Fixture::new("unknown-prompt");
    let action = fixture.action("job-live-argv");
    let marker = action.output.directory.clone();
    let observed = AtomicBool::new(false);
    let finished = AtomicBool::new(false);
    std::thread::scope(|scope| {
        scope.spawn(|| {
            let deadline = Instant::now() + Duration::from_secs(120);
            while !finished.load(Ordering::SeqCst) && Instant::now() < deadline {
                let output = Command::new("/usr/bin/pgrep")
                    .args(["-f", &marker])
                    .output()
                    .unwrap();
                for pid in String::from_utf8_lossy(&output.stdout).split_whitespace() {
                    let Ok(pid) = pid.parse::<i32>() else {
                        continue;
                    };
                    if pid == std::process::id() as i32 {
                        continue;
                    }
                    let _ = Command::new("/bin/kill")
                        .args(["-STOP", &pid.to_string()])
                        .status();
                    if let Some(record) = process_argument_record(pid)
                        && record
                            .windows(marker.len())
                            .any(|window| window == marker.as_bytes())
                    {
                        let text = String::from_utf8_lossy(&record);
                        assert!(text.contains("sign-app") && text.contains("-pwdInputMode"));
                        assert!(text.contains("/.vol/"), "the JAR is named by its inode");
                        assert!(!text.contains("-keystorePwd") && !text.contains("-keyPwd"));
                        fixture.assert_secret_free("the signer's argv or environment", &record);
                        observed.store(true, Ordering::SeqCst);
                    }
                    let _ = Command::new("/bin/kill")
                        .args(["-CONT", &pid.to_string()])
                        .status();
                }
                if observed.load(Ordering::SeqCst) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        });
        let failure = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err();
        finished.store(true, Ordering::SeqCst);
        // Swift's executor ends an exchange whose prompts were not all
        // answered as a protocol violation, whatever the exit status.
        assert_eq!(
            failure,
            SigningFailure::OutcomeUnknown(
                "signing PTY outcome requires readback: promptProtocolViolation".into()
            )
        );
    });
    assert!(
        observed.load(Ordering::SeqCst),
        "the running signer was never observed"
    );
    assert!(!Path::new(&action.output.signed_hap).exists());
    fixture.assert_files_secret_free();
}

/// Swift `testPTYSecretEchoFailsClosedWithoutSignedOutputOrResult`.
#[test]
fn a_signer_that_echoes_a_password_fails_closed_without_output() {
    let fixture = Fixture::new("echo-secret");
    let action = fixture.action("job-secret-echo");
    let failure = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err();
    assert_eq!(
        failure,
        SigningFailure::OutcomeUnknown("signing PTY privacyFailure requires readback".into())
    );
    assert!(!Path::new(&action.output.signed_hap).exists());
    assert!(!Path::new(&action.output.result_record).exists());
    fixture.assert_files_secret_free();
}

/// Swift `testSignerNonzeroExitReportsOnlyClosedPTYDiagnostics`.
#[test]
fn a_rejected_password_reports_only_closed_diagnostics() {
    let fixture = Fixture::new("sign-failure");
    let action = fixture.action("job-nonzero");
    let failure = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err();
    let SigningFailure::OutcomeUnknown(message) = &failure else {
        panic!("{failure:?}")
    };
    for part in [
        "termination=exit:74",
        "completedPrompts=2",
        "observedOutputBytes=",
        "diagnosticCode=keystorePasswordRejected",
    ] {
        assert!(message.contains(part), "{message}");
    }
    fixture.assert_secret_free("the failure", message.as_bytes());
    assert!(!Path::new(&action.output.signed_hap).exists());
    assert!(!Path::new(&action.output.result_record).exists());
}

#[test]
fn a_repeated_prompt_is_a_protocol_violation() {
    let fixture = Fixture::new("repeat-prompt");
    let failure = sign_hap(
        &fixture.action("job-repeat"),
        &fixture.store,
        &fixture.secrets(),
        &|| false,
    )
    .unwrap_err();
    assert_eq!(
        failure,
        SigningFailure::OutcomeUnknown(
            "signing PTY outcome requires readback: promptProtocolViolation".into()
        )
    );
}

#[test]
fn a_failed_verification_needs_recovery_and_leaves_no_record() {
    let fixture = Fixture::new("verify-failure");
    let action = fixture.action("job-verify-failure");
    let failure = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err();
    let SigningFailure::OutcomeUnknown(message) = failure else {
        panic!("{failure:?}")
    };
    assert!(
        message.starts_with("signed output postflight requires recovery: "),
        "{message}"
    );
    assert!(Path::new(&action.output.signed_hap).exists());
    assert!(!Path::new(&action.output.result_record).exists());
}

/// Refusals before the spawn leave nothing: an absent envelope, a drifted
/// JAR, a drifted input and a receipt bound to another daemon.
#[test]
fn nothing_is_dispatched_when_the_preset_or_its_secrets_are_not_exactly_as_recorded() {
    let fixture = Fixture::new("success");
    let action = fixture.action("job-refusals");
    let refused = |failure: SigningFailure, prefix: &str| match failure {
        SigningFailure::Refused(message) => assert!(message.starts_with(prefix), "{message}"),
        other => panic!("expected a refusal, got {other:?}"),
    };

    // The input changed after the action was materialized.
    let mut drifted = action.clone();
    drifted.input_sha256 = "0".repeat(64);
    refused(
        sign_hap(&drifted, &fixture.store, &fixture.secrets(), &|| false).unwrap_err(),
        "signing admission refused before spawn: signing identity drift: input HAP",
    );
    assert!(!Path::new(&action.output.directory).exists());

    // A receipt that records a daemon identity is honoured only by it.
    struct OtherDaemon(KeychainSigningSecrets);
    impl SigningSecrets for OtherDaemon {
        fn read(&self, account: &str) -> Result<arkdeck_platform::Secret, SigningError> {
            self.0.read(account)
        }
        fn presence(&self, account: &str) -> SecretPresence {
            self.0.presence(account)
        }
        fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
            Ok(Some("f".repeat(64)))
        }
    }
    let mut bound = fixture.receipt.clone();
    bound.trusted_daemon_application_sha256 = Some("e".repeat(64));
    std::fs::write(
        fixture.store.receipt_path(),
        serde_json::to_vec_pretty(&bound).unwrap(),
    )
    .unwrap();
    let mut bound_action = action.clone();
    bound_action.preset = bound;
    refused(
        sign_hap(
            &bound_action,
            &fixture.store,
            &OtherDaemon(fixture.secrets()),
            &|| false,
        )
        .unwrap_err(),
        "signing preset unavailable before dispatch: signing identity drift: installed arkdeck-agentd",
    );
    std::fs::write(
        fixture.store.receipt_path(),
        serde_json::to_vec_pretty(&fixture.receipt).unwrap(),
    )
    .unwrap();

    // The JAR changed after installation.
    let jar = fixture.receipt.signer_jar.path.clone();
    std::fs::write(&jar, b"success-but-different").unwrap();
    refused(
        sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err(),
        "signing preset unavailable before dispatch: signing identity drift: signer JAR",
    );
    std::fs::write(&jar, b"success").unwrap();

    // The envelope item is gone from the Keychain.
    let account = fixture.receipt.secret_envelope_account.clone().unwrap();
    assert_eq!(fixture.secrets().items().remove(&account), Ok(true));
    refused(
        sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap_err(),
        "signing preset unavailable before dispatch: signing secret unavailable: required Keychain item is absent",
    );
    assert!(!Path::new(&action.output.directory).exists());
}

/// Swift's receipt keys, and one more refused rather than dropped.
#[test]
fn the_receipt_decodes_with_exactly_swift_s_keys() {
    let fixture = Fixture::new("success");
    let bytes = std::fs::read(fixture.store.receipt_path()).unwrap();
    assert_eq!(decode_receipt(&bytes).unwrap(), fixture.receipt);
    let mut document: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    document["futureField"] = serde_json::json!(true);
    assert!(matches!(
        decode_receipt(&serde_json::to_vec(&document).unwrap()),
        Err(SigningError::ReceiptUnavailable(_))
    ));
    let mut document: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    document["keystore"]["mode"] = serde_json::json!(384);
    assert!(decode_receipt(&serde_json::to_vec(&document).unwrap()).is_err());
    let mut document: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    document.as_object_mut().unwrap().remove("keyAlias");
    assert!(decode_receipt(&serde_json::to_vec(&document).unwrap()).is_err());
}

/// A recorded verification is honoured only while it and its product are as
/// written; a record with one more summary key is refused.
#[test]
fn a_recorded_verification_is_read_back_only_while_exact() {
    let fixture = Fixture::new("success");
    let action = fixture.action("job-readback");
    let signed = sign_hap(&action, &fixture.store, &fixture.secrets(), &|| false).unwrap();
    assert_eq!(read_verified_result(&action).unwrap(), signed.summary);

    let record = std::fs::read(&action.output.result_record).unwrap();
    let mut document: serde_json::Value = serde_json::from_slice(&record).unwrap();
    document["summary"]["extra"] = serde_json::json!("x");
    std::fs::write(
        &action.output.result_record,
        serde_json::to_vec(&document).unwrap(),
    )
    .unwrap();
    assert_eq!(
        read_verified_result(&action).unwrap_err(),
        SigningError::IoFailure("signing result record is malformed".into())
    );
    std::fs::write(&action.output.result_record, &record).unwrap();

    let mut other = action.clone();
    other.input_artifact_id = "ART-OTHER".into();
    assert!(read_verified_result(&other).is_err());

    std::fs::write(&action.output.signed_hap, b"PK\x03\x04tampered").unwrap();
    assert_eq!(
        read_verified_result(&action).unwrap_err(),
        SigningError::IdentityDrift("signed HAP recovery output".into())
    );
}
