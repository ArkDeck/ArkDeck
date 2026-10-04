//! `runtime signing install|remove|status|migrate-deveco` on Windows
//! (TASK-XPA-011): the same documents as on macOS over a fixture preset root
//! and a fixture secret source, the DevEco build profile and password
//! material read as DevEco writes them on Windows (a `\\`-escaped drive
//! `storeFile`, the material tree beside the keystore) and decoded with the
//! Swift vectors (`arkdeck-provider-workspace/tests/deveco_password.rs`), and
//! the process-level refusals that come before any preset root or Credential
//! Manager is touched — a daemon that satisfies no signing pin, and a
//! `migrate-deveco --daemon` that is not the installed daemon. No production
//! credential, preset root or daemon is used. With
//! `ARKDECK_LIVE_DEVECO_BUILD_PROFILE` naming one of this host's DevEco build
//! profiles, its passwords are decoded through the host's own material and
//! only their shape is checked; nothing is printed or written.
#![cfg(windows)]

use arkdeck_cli::signing_inputs::read_deveco_profile;
use arkdeck_cli::signing_leaves::{
    install_document, migrate_deveco_document, remove_document, status_document,
    validate_migration_daemon,
};
use arkdeck_platform::{
    Secret, application_support_directory, create_private_directory, create_private_file,
    random_bytes,
};
use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::deveco_password::decode_if_needed;
use arkdeck_provider_workspace::secret_envelope::decode_envelope;
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
    assert!(!scratch.root().exists());
    assert!(secrets.0.lock().unwrap().is_empty());
}

/// The Swift fixture vector (`OpenHarmonyLocalSigningContractTests
/// .makeDevEcoPasswordFixture`, printed by
/// `evidence/runs/TASK-XPA-015/spk-10/deveco-vectors.swift`): the material
/// parts, salt and work key, and one ciphertext of its plaintext.
const PARTS: [&str; 3] = [
    "11111111111111111111111111111111",
    "42424242424242424242424242424242",
    "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5",
];
const SALT: &str = "000102030405060708090a0b0c0d0e0f";
const WORK_KEY: &str = "00000020212121212121212121212121995703aa42513e859495056d6c978fd621d24b98a0fbc95c72e355d17630bf7a";
const ENCRYPTED: &str = "0000002937373737373737373737373724639e22e0a17224e9556e5e89cd83f938a39b7684f35148b4b0967540b1dcb425687b58aa91d813e1";
const PLAINTEXT: &str = "deveco-plaintext-password";

fn bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).unwrap())
        .collect()
}

impl Scratch {
    /// DevEco's material tree beside the scratch keystore, owner-only.
    fn material(&self) {
        let material = self.0.join("material");
        for directory in [
            material.clone(),
            material.join("fd"),
            material.join("ac"),
            material.join("ce"),
        ] {
            create_private_directory(&directory).unwrap();
        }
        for (index, part) in PARTS.iter().enumerate() {
            let slot = material.join("fd").join(index.to_string());
            create_private_directory(&slot).unwrap();
            create_private_file(&slot.join(format!("part-{index}")))
                .unwrap()
                .write_all(&bytes(part))
                .unwrap();
        }
        create_private_file(&material.join("ac").join("salt"))
            .unwrap()
            .write_all(&bytes(SALT))
            .unwrap();
        create_private_file(&material.join("ce").join("work-key"))
            .unwrap()
            .write_all(&bytes(WORK_KEY))
            .unwrap();
    }

    /// A build profile naming `keystore` as DevEco writes it on Windows: the
    /// drive path JSON-escaped, both passwords the vector's ciphertext.
    fn build_profile(&self, keystore: &str) -> String {
        let escaped = keystore.replace('\\', r"\\");
        self.file(
            "build-profile.json5",
            format!(
                "{{\n  \"app\": {{\n    \"signingConfigs\": [\n      {{\n        \"name\": \"default\",\n        \"type\": \"OpenHarmony\",\n        \"material\": {{\n          \"storePassword\": \"{ENCRYPTED}\",\n          \"keyAlias\": \"debugKey\",\n          \"keyPassword\": \"{ENCRYPTED}\",\n          \"signAlg\": \"SHA256withECDSA\",\n          \"storeFile\": \"{escaped}\"\n        }}\n      }}\n    ]\n  }}\n}}\n"
            )
            .as_bytes(),
        )
    }
}

#[test]
fn a_windows_build_profile_and_its_material_decode_as_swift_decodes_them() {
    let scratch = Scratch::new("cli-signing-deveco");
    scratch.material();
    let options = scratch.options();
    let keystore = options["keystore"].as_str().unwrap().to_owned();
    let profile = scratch.build_profile(&keystore);
    let material = read_deveco_profile(Path::new(&profile)).unwrap();
    assert_eq!(material.store_file, PathBuf::from(&keystore));
    assert_eq!(material.keystore.as_bytes(), ENCRYPTED.as_bytes());
    assert_eq!(
        decode_if_needed(material.key.as_bytes(), &material.store_file)
            .unwrap()
            .as_bytes(),
        PLAINTEXT.as_bytes()
    );

    // `install --build-profile` asks for nothing and stores the decoded pair.
    let secrets = Memory::default();
    let mut with_profile = options.clone();
    with_profile.insert("buildProfile".into(), json!(profile));
    let installed = install_document(
        &scratch.root(),
        "runtime.signing.install",
        &with_profile,
        &secrets,
        &mut |_| panic!("a build profile asks for no password"),
        "2026-10-05T00:00:00Z",
    )
    .unwrap();
    let account = SigningPresetStore::new(scratch.root())
        .load_validated("openharmony-release@1", false, &secrets)
        .unwrap()
        .secret_envelope_account
        .unwrap();
    let pair = decode_envelope(secrets.0.lock().unwrap()[&account].as_bytes()).unwrap();
    assert_eq!(pair.keystore.as_bytes(), PLAINTEXT.as_bytes());
    assert_eq!(pair.key.as_bytes(), PLAINTEXT.as_bytes());

    // `migrate-deveco` replaces the envelope of the installed preset from the
    // same profile, and keeps the installation and its credential.
    secrets.0.lock().unwrap().insert(
        account.clone(),
        arkdeck_provider_workspace::secret_envelope::encode_envelope(b"old-ks", b"old-key"),
    );
    let migrated = migrate_deveco_document(
        &scratch.root(),
        json!({"buildProfile": profile}).as_object().unwrap(),
        &secrets,
    )
    .unwrap();
    assert_eq!(migrated["operation"], "migrate-deveco");
    assert_eq!(
        migrated["credential"]["credentialRef"],
        installed["credentialRef"]
    );
    let pair = decode_envelope(secrets.0.lock().unwrap()[&account].as_bytes()).unwrap();
    assert_eq!(pair.keystore.as_bytes(), PLAINTEXT.as_bytes());

    // A profile naming another keystore is refused before any secret.
    let other = scratch.file("other.p12", b"another keystore");
    let other_profile = Scratch::new("cli-signing-deveco-other");
    let mut mismatched = options.clone();
    mismatched.insert(
        "buildProfile".into(),
        json!(other_profile.build_profile(&other)),
    );
    let error = install_document(
        &other_profile.root(),
        "runtime.signing.install",
        &mismatched,
        &Memory::default(),
        &mut |_| panic!("no password is asked for"),
        "2026-10-05T00:00:00Z",
    )
    .unwrap_err();
    assert!(
        error
            .message
            .contains("names a different storeFile than --keystore"),
        "{}",
        error.message
    );
    assert!(!other_profile.root().exists());
}

#[test]
fn a_build_profile_that_is_unsafe_or_ambiguous_is_refused() {
    let scratch = Scratch::new("cli-signing-profile-refusals");
    let keystore = scratch.file("release.p12", b"fixture keystore");
    let escaped = keystore.replace('\\', r"\\");
    for (name, document, message) in [
        (
            "two-stores.json5",
            format!(
                "{{\"storeFile\": \"{escaped}\", \"storeFile\": \"{escaped}\", \"storePassword\": \"{ENCRYPTED}\", \"keyPassword\": \"{ENCRYPTED}\"}}"
            ),
            "exactly one storeFile path",
        ),
        (
            "relative.json5",
            format!(
                "{{\"storeFile\": \"release.p12\", \"storePassword\": \"{ENCRYPTED}\", \"keyPassword\": \"{ENCRYPTED}\"}}"
            ),
            "canonical absolute path",
        ),
        (
            "escape.json5",
            format!(
                "{{\"storeFile\": \"C:\\\\a\\tb.p12\", \"storePassword\": \"{ENCRYPTED}\", \"keyPassword\": \"{ENCRYPTED}\"}}"
            ),
            "canonical absolute path",
        ),
        (
            "dot-dot.json5",
            format!(
                "{{\"storeFile\": \"C:\\\\a\\\\..\\\\b.p12\", \"storePassword\": \"{ENCRYPTED}\", \"keyPassword\": \"{ENCRYPTED}\"}}"
            ),
            "canonical absolute path",
        ),
        (
            "no-key.json5",
            format!("{{\"storeFile\": \"{escaped}\", \"storePassword\": \"{ENCRYPTED}\"}}"),
            "exactly one keyPassword ciphertext",
        ),
    ] {
        let path = scratch.file(name, document.as_bytes());
        let error = read_deveco_profile(Path::new(&path)).err().unwrap();
        assert!(error.message.contains(message), "{name}: {}", error.message);
    }
    // A profile others may change is refused before it is parsed.
    let widened = scratch.file(
        "widened.json5",
        format!(
            "{{\"storeFile\": \"{escaped}\", \"storePassword\": \"{ENCRYPTED}\", \"keyPassword\": \"{ENCRYPTED}\"}}"
        )
        .as_bytes(),
    );
    assert!(read_deveco_profile(Path::new(&widened)).is_ok());
    let status = Command::new("icacls")
        .arg(&widened)
        .args(["/grant", "*S-1-5-32-545:(M)"])
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let error = read_deveco_profile(Path::new(&widened)).err().unwrap();
    assert!(
        error.message.contains("mutable by another user"),
        "{}",
        error.message
    );
    // Another spelling of the same file (here, its short or upper-case form)
    // is not the spelling on disk.
    let upper = widened.to_uppercase();
    if upper != widened {
        assert!(read_deveco_profile(Path::new(&upper)).is_err());
    }
}

#[test]
fn migrate_deveco_names_only_the_installed_daemon() {
    let scratch = Scratch::new("cli-signing-migrate-daemon");
    let installed = PathBuf::from(scratch.file("arkdeck-agentd.exe", b"fixture daemon"));
    let profile = scratch.file("build-profile.json5", b"{}");
    let check = |daemon: &str, profile: &str| {
        validate_migration_daemon(
            "runtime.signing.migrate-deveco",
            json!({"buildProfile": profile, "daemon": daemon})
                .as_object()
                .unwrap(),
            &installed,
        )
    };
    assert!(check(installed.to_str().unwrap(), &profile).is_ok());
    for (daemon, profile) in [
        (r"arkdeck-agentd.exe", profile.as_str()),
        (installed.to_str().unwrap(), "build-profile.json5"),
        (r"C:\Windows\System32\whoami.exe", profile.as_str()),
    ] {
        assert!(check(daemon, profile).is_err(), "{daemon} {profile}");
    }
    let other = scratch.file("other-agentd.exe", b"another daemon");
    let error = check(&other, &profile).unwrap_err();
    assert!(
        error
            .message
            .contains("must name the canonical installed daemon"),
        "{}",
        error.message
    );
}

/// This host's DevEco: one of its build profiles, decoded through the
/// material DevEco keeps beside its keystore. Only the shape of the result
/// is checked, nothing is printed, and the secrets are wiped on drop.
#[test]
fn a_live_deveco_build_profile_decodes_through_its_own_material() {
    let Some(profile) = std::env::var_os("ARKDECK_LIVE_DEVECO_BUILD_PROFILE") else {
        eprintln!(
            "SKIPPED: ARKDECK_LIVE_DEVECO_BUILD_PROFILE names no DevEco build-profile.json5 \
             on this host"
        );
        return;
    };
    let material = read_deveco_profile(Path::new(&profile)).unwrap();
    for ciphertext in [&material.keystore, &material.key] {
        let decoded = decode_if_needed(ciphertext.as_bytes(), &material.store_file).unwrap();
        assert!(!decoded.as_bytes().is_empty());
        assert_ne!(decoded.as_bytes(), ciphertext.as_bytes(), "decoded");
    }
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
fn migrate_deveco_refuses_a_daemon_that_satisfies_no_signing_pin_before_anything() {
    let scratch = Scratch::new("cli-signing-deveco-pin");
    let daemon = scratch.0.join("arkdeck-agentd.exe");
    std::fs::copy(
        PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join(r"System32\whoami.exe"),
        &daemon,
    )
    .unwrap();
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
            ])
            .collect();
        let output = arkdeck(&arguments, &daemon, None);
        assert_eq!(output.status.code(), Some(1), "{arguments:?}: {output:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("arkdeck-agentd.exe"),
            "{arguments:?}: {stderr}"
        );
        assert!(!stderr.contains("unsupportedOnPlatform"), "{stderr}");
    }
    assert_eq!(root.exists(), existed);
}
