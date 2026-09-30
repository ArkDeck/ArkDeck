//! The signing owners on Windows (TASK-XPA-011): a credential installed
//! through the credential owner, a HAP signed through the registered Java and
//! hap-sign-tool identities on a pseudo console, the product verified and
//! recorded, the managed SDK release material generated and signed, and the
//! credential removed again.
//!
//! The fake Java is this binary itself (`harness = false`), copied into a
//! private fixture tree as `java.exe` so that it measures as a registered,
//! executable, trusted-write-only launcher. Run as `java.exe -jar <jar>
//! <command> …` it plays hap-sign-tool: `sign-app` and `sign-profile` read
//! both passwords from the console with echo cleared (through the platform's
//! console entry, `read_terminal_secret`) and check them against
//! the fixture constants of this file (never argv or environment),
//! `verify-app` and `verify-profile` write their readbacks. While it runs it
//! proves from the inside that the JAR it was named by, the JAR's directory
//! and the staged input cannot be deleted or renamed. Each run is appended to
//! a log in the fixture tree, so a test can prove what ran and what did not.
//! No real DevEco, JDK, keystore, certificate or password is involved; the
//! Credential Manager case works in its own fixture namespace and removes
//! every item it wrote.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-jar") {
        windows::fake_java(&arguments[1..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod windows {
    use arkdeck_platform::{
        KeychainItems, Secret, application_support_directory, create_private_directory,
        create_private_file, measure_host_file, random_bytes,
    };
    use arkdeck_provider_workspace::SigningError;
    use arkdeck_provider_workspace::credential_owner::CredentialOwner;
    use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
    use arkdeck_provider_workspace::sdk_release::SdkReleaseConfiguration;
    use arkdeck_provider_workspace::secret_envelope::SecretPair;
    use arkdeck_provider_workspace::signer::{
        KEY_PROMPT, KEYSTORE_PROMPT, SigningFailure, read_verified_result, recovered_receipt,
        sign_hap,
    };
    use arkdeck_provider_workspace::signing_action::{SigningAction, SigningAttemptPaths};
    use arkdeck_provider_workspace::signing_install::{
        SigningPresetConfiguration, SigningSecretInstallation,
    };
    use arkdeck_provider_workspace::signing_preset::{
        DEFAULT_PRESET_ID, KEYCHAIN_SERVICE, SecretPresence, SigningPresetStore, SigningSecrets,
    };
    use arkdeck_provider_workspace::signing_removal::SigningSecretRemoval;
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::collections::BTreeMap;
    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    const KEYSTORE_SECRET: &str = "fixture-ks-5Hn";
    /// Not ASCII: the console carries UTF-8 text.
    const KEY_SECRET: &str = "fixture-key-8Wd-\u{e4}\u{20ac}";
    const WRONG_KEY_SECRET: &str = "fixture-wrong-2Kq";
    /// The password published with the OpenHarmony SDK release keystore.
    const SDK_SECRET: &str = "123456";
    const JAR_BYTES: &[u8] = b"fixture hap-sign-tool jar";
    const UNSIGNED_HAP: &[u8] = b"PK\x03\x04fixture unsigned hap";
    const SIGNED_SUFFIX: &[u8] = b"+fixture signature";
    const LOG: &str = "fake-java.log";

    /// Exit codes the fake reports what it saw from the inside with.
    const BAD_ARGUMENTS: i32 = 5;
    const SECRET_IN_ARGV_OR_ENVIRONMENT: i32 = 6;
    const JAR_NOT_AS_NAMED: i32 = 7;
    const HELD_FILE_NOT_HELD: i32 = 8;
    const NO_CONSOLE: i32 = 10;

    // ---- the fake Java ---------------------------------------------------

    fn option<'a>(arguments: &'a [String], name: &str) -> &'a str {
        arguments
            .iter()
            .position(|argument| argument == name)
            .and_then(|index| arguments.get(index + 1))
            .map(String::as_str)
            .unwrap_or_else(|| std::process::exit(BAD_ARGUMENTS))
    }

    /// The fixture tree this copy lives in: `<scratch>\jdk\bin\java.exe`.
    fn scratch_of_this_copy() -> PathBuf {
        std::env::current_exe()
            .unwrap()
            .ancestors()
            .nth(3)
            .unwrap()
            .to_path_buf()
    }

    /// hap-sign-tool's `readPassword`: echo cleared, the prompt, one line
    /// — here through the platform's console entry, which refuses anything
    /// that is not a console.
    fn ask(prompt: &[u8]) -> Secret {
        arkdeck_platform::read_terminal_secret(std::str::from_utf8(prompt).unwrap())
            .unwrap_or_else(|_| std::process::exit(NO_CONSOLE))
    }

    fn say(text: &str) {
        let mut stdout = std::io::stdout().lock();
        writeln!(stdout, "{text}").unwrap();
        stdout.flush().unwrap();
    }

    fn assert_not_in_argv_or_environment() {
        let secrets = [KEYSTORE_SECRET, KEY_SECRET, WRONG_KEY_SECRET];
        let leaked = std::env::args_os()
            .chain(std::env::vars_os().flat_map(|(key, value)| [key, value]))
            .any(|text| {
                let text = text.to_string_lossy();
                secrets.iter().any(|secret| text.contains(secret))
            });
        if leaked {
            std::process::exit(SECRET_IN_ARGV_OR_ENVIRONMENT);
        }
    }

    /// A file the signer holds can be neither deleted nor renamed, and
    /// neither can its directory.
    fn assert_held(path: &Path) {
        let parent = path.parent().unwrap();
        let moved = parent.with_extension("moved");
        if fs::remove_file(path).is_ok() {
            std::process::exit(HELD_FILE_NOT_HELD);
        }
        if fs::rename(path, path.with_extension("moved")).is_ok() {
            let _ = fs::rename(path.with_extension("moved"), path);
            std::process::exit(HELD_FILE_NOT_HELD);
        }
        if fs::rename(parent, &moved).is_ok() {
            let _ = fs::rename(&moved, parent);
            std::process::exit(HELD_FILE_NOT_HELD);
        }
    }

    /// Both passwords, read as the signer reads them; `true` for a pair
    /// the fixture keystore opens with.
    fn read_passwords() -> bool {
        let keystore = ask(KEYSTORE_PROMPT);
        let key = ask(KEY_PROMPT);
        assert_not_in_argv_or_environment();
        let (keystore, key) = (keystore.as_bytes(), key.as_bytes());
        (keystore == KEYSTORE_SECRET.as_bytes() && key == KEY_SECRET.as_bytes())
            || (keystore == SDK_SECRET.as_bytes() && key == SDK_SECRET.as_bytes())
    }

    /// `arguments` starts at `-jar`.
    pub fn fake_java(arguments: &[String]) -> ! {
        let jar = Path::new(&arguments[1]);
        let command = arguments.get(2).map(String::as_str).unwrap_or("");
        let mut log = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(scratch_of_this_copy().join(LOG))
            .unwrap();
        writeln!(log, "{command}").unwrap();
        drop(log);
        if fs::read(jar).ok().as_deref() != Some(JAR_BYTES) {
            std::process::exit(JAR_NOT_AS_NAMED);
        }
        assert_held(jar);
        match command {
            "sign-app" => {
                let input = Path::new(option(arguments, "-inFile"));
                assert_held(input);
                if !read_passwords() {
                    say("Incorrect keystore password");
                    std::process::exit(1);
                }
                let mut signed = fs::read(input).unwrap();
                signed.extend_from_slice(SIGNED_SUFFIX);
                fs::write(option(arguments, "-outFile"), signed).unwrap();
                say("sign-app success");
            }
            "verify-app" => {
                let signed = fs::read(option(arguments, "-inFile")).unwrap();
                if !signed.ends_with(SIGNED_SUFFIX) {
                    std::process::exit(1);
                }
                fs::write(
                    option(arguments, "-outCertChain"),
                    b"-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n",
                )
                .unwrap();
                fs::write(
                    option(arguments, "-outProfile"),
                    b"fixture profile readback",
                )
                .unwrap();
            }
            "sign-profile" => {
                let input = Path::new(option(arguments, "-inFile"));
                assert_held(input);
                if !read_passwords() {
                    say("Incorrect keystore password");
                    std::process::exit(1);
                }
                fs::copy(input, option(arguments, "-outFile")).unwrap();
                say("sign-profile success");
            }
            "verify-profile" => {
                let content: Value =
                    serde_json::from_slice(&fs::read(option(arguments, "-inFile")).unwrap())
                        .unwrap();
                fs::write(
                    option(arguments, "-outFile"),
                    serde_json::to_vec(&json!({"verifiedPassed": true, "content": content}))
                        .unwrap(),
                )
                .unwrap();
            }
            _ => std::process::exit(BAD_ARGUMENTS),
        }
        std::process::exit(0)
    }

    // ---- the runner ------------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "a_hap_is_signed_verified_and_recorded_through_the_registered_identities",
            a_hap_is_signed_verified_and_recorded_through_the_registered_identities,
        ),
        (
            "the_credential_manager_carries_the_envelope_from_install_to_signing_to_removal",
            the_credential_manager_carries_the_envelope_from_install_to_signing_to_removal,
        ),
        (
            "a_rejected_password_is_an_unknown_outcome_without_a_record",
            a_rejected_password_is_an_unknown_outcome_without_a_record,
        ),
        (
            "a_drifted_jar_is_refused_before_anything_runs",
            a_drifted_jar_is_refused_before_anything_runs,
        ),
        (
            "the_sdk_release_material_is_generated_signed_installed_and_removed",
            the_sdk_release_material_is_generated_signed_installed_and_removed,
        ),
        (
            "the_default_root_is_the_accounts_local_application_data",
            the_default_root_is_the_accounts_local_application_data,
        ),
    ];

    pub fn run_tests(arguments: &[String]) -> ! {
        let mut filters = Vec::new();
        let mut list = false;
        let mut skip_value = false;
        for argument in arguments {
            if skip_value {
                skip_value = false;
            } else if argument == "--list" {
                list = true;
            } else if matches!(
                argument.as_str(),
                "--test-threads" | "--skip" | "--format" | "--color" | "-Z"
            ) {
                skip_value = true;
            } else if !argument.starts_with('-') {
                filters.push(argument.clone());
            }
        }
        let selected: Vec<&Test> = TESTS
            .iter()
            .filter(|(name, _)| filters.is_empty() || filters.iter().any(|f| name.contains(f)))
            .collect();
        if list {
            for (name, _) in &selected {
                println!("{name}: test");
            }
            std::process::exit(0);
        }
        println!("\nrunning {} tests", selected.len());
        let mut failed = Vec::new();
        for (name, test) in &selected {
            let result = std::panic::catch_unwind(test);
            println!(
                "test {name} ... {}",
                if result.is_ok() { "ok" } else { "FAILED" }
            );
            if result.is_err() {
                failed.push(*name);
            }
        }
        println!(
            "\ntest result: {}. {} passed; {} failed",
            if failed.is_empty() { "ok" } else { "FAILED" },
            selected.len() - failed.len(),
            failed.len()
        );
        std::process::exit(i32::from(!failed.is_empty()));
    }

    // ---- fixtures --------------------------------------------------------

    fn private_file(path: &Path, bytes: &[u8]) {
        let mut file = create_private_file(path).unwrap();
        file.write_all(bytes).unwrap();
    }

    fn private_directories(path: &Path) {
        if !path.exists() {
            private_directories(path.parent().unwrap());
            create_private_directory(path).unwrap();
        }
    }

    fn pem(value: &str) -> String {
        format!("-----BEGIN CERTIFICATE-----\n{value}\n-----END CERTIFICATE-----\n")
    }

    /// A private tree under the account's local application data, in its
    /// plain `X:\…` spelling, with the fake Java, an SDK library, source
    /// signing material and an unsigned HAP; removed on drop.
    struct Scratch {
        root: PathBuf,
    }

    impl Scratch {
        fn new(label: &str) -> Self {
            let base = application_support_directory()
                .unwrap()
                .canonicalize()
                .unwrap();
            let base = base.to_str().unwrap();
            let root = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
                "arkdeck-test-signing-{label}-{:032x}",
                u128::from_le_bytes(random_bytes().unwrap())
            ));
            create_private_directory(&root).unwrap();
            let scratch = Self { root };
            private_directories(scratch.java().parent().unwrap());
            let mut java = create_private_file(&scratch.java()).unwrap();
            std::io::copy(
                &mut fs::File::open(std::env::current_exe().unwrap()).unwrap(),
                &mut java,
            )
            .unwrap();
            drop(java);
            let library = scratch.library();
            private_directories(&library);
            private_file(&library.join("hap-sign-tool.jar"), JAR_BYTES);
            private_file(&library.join("OpenHarmony.p12"), b"fixture sdk keystore");
            private_file(
                &library.join("OpenHarmonyProfileRelease.pem"),
                [pem("root"), pem("intermediate"), pem("profile")]
                    .concat()
                    .as_bytes(),
            );
            private_file(
                &library.join("UnsgnedReleasedProfileTemplate.json"),
                &serde_json::to_vec(&json!({
                    "type": "release",
                    "app-distribution-type": "os_integration",
                    "issuer": "pki_internal",
                    "bundle-info": {
                        "apl": "normal",
                        "app-feature": "hos_normal_app",
                        "distribution-certificate": pem("application"),
                    },
                }))
                .unwrap(),
            );
            let material = scratch.root.join("material");
            create_private_directory(&material).unwrap();
            private_file(&material.join("release.p12"), b"fixture keystore");
            private_file(&material.join("release.cer"), pem("app").as_bytes());
            private_file(&material.join("release.p7b"), b"fixture signed profile");
            let inputs = scratch.root.join("inputs");
            create_private_directory(&inputs).unwrap();
            private_file(&inputs.join("app.hap"), UNSIGNED_HAP);
            create_private_directory(&scratch.root.join("attempts")).unwrap();
            scratch
        }

        fn java(&self) -> PathBuf {
            self.root.join("jdk").join("bin").join("java.exe")
        }

        fn sdk(&self) -> PathBuf {
            self.root.join("sdk")
        }

        fn library(&self) -> PathBuf {
            self.sdk().join("toolchains").join("lib")
        }

        fn store(&self) -> SigningPresetStore {
            SigningPresetStore::new(self.root.join("preset"))
        }

        fn owner(&self) -> CredentialOwner {
            CredentialOwner::new(self.store())
        }

        fn configuration(&self) -> SigningPresetConfiguration {
            let material = self.root.join("material");
            SigningPresetConfiguration {
                project_ref: "demo-app".into(),
                java_executable: self.java(),
                signer_jar: self.library().join("hap-sign-tool.jar"),
                keystore: material.join("release.p12"),
                app_certificate: material.join("release.cer"),
                signed_profile: material.join("release.p7b"),
                key_alias: "release".into(),
                managed_material_directory: None,
            }
        }

        /// The commands the fake Java ran, in order.
        fn runs(&self) -> Vec<String> {
            fs::read_to_string(self.root.join(LOG))
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        /// The signing action of `job` over the unsigned fixture HAP and the
        /// installed receipt.
        fn action(&self, job: &str, secrets: &dyn SigningSecrets) -> SigningAction {
            let preset = self
                .store()
                .load_validated(DEFAULT_PRESET_ID, true, secrets)
                .unwrap();
            SigningAction {
                job_id: job.into(),
                project_ref: "demo-app".into(),
                signing_preset_ref: None,
                preset,
                input_artifact_id: "artifact-1".into(),
                input_file_path: self
                    .root
                    .join("inputs")
                    .join("app.hap")
                    .to_str()
                    .unwrap()
                    .into(),
                input_sha256: format!("{:x}", Sha256::digest(UNSIGNED_HAP)),
                input_byte_count: UNSIGNED_HAP.len() as u64,
                output: SigningAttemptPaths::for_job(&self.root.join("attempts"), job),
            }
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    /// An in-memory secret store bound to no daemon identity.
    #[derive(Default)]
    struct Memory(Mutex<BTreeMap<String, Secret>>);

    impl SigningSecrets for Memory {
        fn read(&self, account: &str) -> Result<Secret, SigningError> {
            self.0
                .lock()
                .unwrap()
                .get(account)
                .cloned()
                .ok_or_else(|| SigningError::SecretUnavailable("absent".into()))
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

    fn pair(keystore: &str, key: &str) -> SecretPair {
        SecretPair {
            keystore: Secret::from_slice(keystore.as_bytes()),
            key: Secret::from_slice(key.as_bytes()),
        }
    }

    fn assert_private(path: &str) {
        let measured = measure_host_file(Path::new(path), 64 * 1024 * 1024).unwrap();
        assert!(measured.owner_private, "{path} is not private");
        assert_eq!(measured.links, 1, "{path}");
    }

    // ---- tests -----------------------------------------------------------

    fn a_hap_is_signed_verified_and_recorded_through_the_registered_identities() {
        let scratch = Scratch::new("sign");
        let secrets = Memory::default();
        let owner = scratch.owner();
        let resource = owner
            .install(
                &scratch.configuration(),
                &pair(KEYSTORE_SECRET, KEY_SECRET),
                &secrets,
                "2026-09-30T00:00:00Z",
            )
            .unwrap();
        assert_eq!(owner.current().unwrap(), resource);
        let receipt = scratch
            .store()
            .load_validated(DEFAULT_PRESET_ID, true, &secrets)
            .unwrap();
        // The receipt pins the Windows spellings and the launcher.
        assert_eq!(
            receipt.java_executable.path,
            scratch.java().to_str().unwrap()
        );
        assert!(
            receipt
                .signer_jar
                .path
                .ends_with(r"\toolchains\lib\hap-sign-tool.jar")
        );
        assert_eq!(receipt.trusted_daemon_application_sha256, None);
        assert_private(scratch.store().receipt_path().to_str().unwrap());

        let action = scratch.action("job-windows-sign", &secrets);
        assert!(
            action
                .output
                .directory
                .starts_with(scratch.root.to_str().unwrap())
        );
        assert!(!action.output.directory.contains('/'));
        let signed = sign_hap(&action, &scratch.store(), &secrets, &|| false).unwrap();
        assert_eq!(scratch.runs(), ["sign-app", "verify-app"]);
        let expected = [UNSIGNED_HAP, SIGNED_SUFFIX].concat();
        assert_eq!(fs::read(&signed.signed_hap).unwrap(), expected);
        assert_eq!(signed.byte_count, expected.len() as u64);
        assert_eq!(signed.sha256, format!("{:x}", Sha256::digest(&expected)));
        assert_eq!(signed.summary["verification"], "verified");
        assert_eq!(signed.summary["signedHapSha256"], signed.sha256);
        assert_eq!(
            signed.summary["signerJarSha256"],
            format!("{:x}", Sha256::digest(JAR_BYTES))
        );
        // No password in the record, and the record and staged copy are
        // private.
        let record = fs::read_to_string(&action.output.result_record).unwrap();
        for secret in [KEYSTORE_SECRET, KEY_SECRET] {
            assert!(!record.contains(secret));
        }
        let document: Value = serde_json::from_str(&record).unwrap();
        assert_eq!(
            document["schemaVersion"],
            "arkdeck-openharmony-signing-result/v1"
        );
        assert_private(&action.output.result_record);
        assert_private(&action.output.staged_unsigned_hap());

        // A reconcile reads the record back; nothing runs again.
        assert_eq!(read_verified_result(&action).unwrap(), signed.summary);
        assert_eq!(recovered_receipt(&action).unwrap().summary, signed.summary);
        assert_eq!(scratch.runs(), ["sign-app", "verify-app"]);
        // A product that moved is drift, never a replay.
        fs::write(&signed.signed_hap, [expected.as_slice(), b"!"].concat()).unwrap();
        assert!(matches!(
            read_verified_result(&action),
            Err(SigningError::IdentityDrift(_))
        ));

        let removal = owner.remove(&secrets).unwrap();
        assert!(removal.removed_receipt);
        assert!(secrets.0.lock().unwrap().is_empty());
        assert!(owner.current().is_err());
    }

    fn the_credential_manager_carries_the_envelope_from_install_to_signing_to_removal() {
        let scratch = Scratch::new("credential-manager");
        let namespace = format!(
            "test-{}-{:016x}",
            std::process::id(),
            u64::from_le_bytes(random_bytes().unwrap())
        );
        let items = || KeychainItems::fixture_namespace(KEYCHAIN_SERVICE, &namespace).unwrap();
        /// Deletes every account a receipt or ledger of the tree may name.
        struct Cleanup<'a>(&'a Scratch, KeychainItems);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                let root = self.0.store().root().to_path_buf();
                let mut accounts = Vec::new();
                for name in ["preset-v1.json", "credential-owner-v1.json"] {
                    let Ok(bytes) = fs::read(root.join(name)) else {
                        continue;
                    };
                    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                        continue;
                    };
                    for key in [
                        "secretEnvelopeAccount",
                        "supersededEnvelopeAccounts",
                        "pendingEnvelopeAccounts",
                    ] {
                        match &value[key] {
                            Value::String(account) => accounts.push(account.clone()),
                            Value::Array(list) => accounts
                                .extend(list.iter().filter_map(Value::as_str).map(str::to_owned)),
                            _ => {}
                        }
                    }
                }
                for account in accounts {
                    let _ = self.1.remove(&account);
                }
            }
        }
        let _cleanup = Cleanup(&scratch, items());
        let secrets = KeychainSigningSecrets::over(items());
        let owner = scratch.owner();
        owner
            .install(
                &scratch.configuration(),
                &pair(KEYSTORE_SECRET, KEY_SECRET),
                &secrets,
                "2026-09-30T00:00:00Z",
            )
            .unwrap();
        let receipt = scratch
            .store()
            .load_validated(DEFAULT_PRESET_ID, true, &secrets)
            .unwrap();
        let account = receipt.secret_envelope_account.clone().unwrap();
        let target = items().target_name(&account).unwrap().unwrap();
        assert!(target.starts_with(&format!("ArkDeck-fixture/{namespace}/{KEYCHAIN_SERVICE}/")));
        assert_eq!(secrets.presence(&account), SecretPresence::Present);

        let action = scratch.action("job-windows-credential-manager", &secrets);
        let signed = sign_hap(&action, &scratch.store(), &secrets, &|| false).unwrap();
        assert_eq!(signed.summary["verification"], "verified");
        assert_eq!(scratch.runs(), ["sign-app", "verify-app"]);

        // Re-key in place: the same envelope account, the new passwords.
        let (created, _) = owner
            .replace_secret_envelope(
                &receipt,
                &pair(KEYSTORE_SECRET, WRONG_KEY_SECRET),
                None,
                &secrets,
            )
            .unwrap();
        assert!(!created);
        let action = scratch.action("job-windows-rekeyed", &secrets);
        assert!(matches!(
            sign_hap(&action, &scratch.store(), &secrets, &|| false),
            Err(SigningFailure::OutcomeUnknown(_))
        ));

        let removal = owner.remove(&secrets).unwrap();
        assert!(removal.removed_receipt);
        assert!(removal.removed_key_password);
        assert_eq!(secrets.presence(&account), SecretPresence::Absent);
    }

    fn a_rejected_password_is_an_unknown_outcome_without_a_record() {
        let scratch = Scratch::new("rejected");
        let secrets = Memory::default();
        let owner = scratch.owner();
        owner
            .install(
                &scratch.configuration(),
                &pair(KEYSTORE_SECRET, WRONG_KEY_SECRET),
                &secrets,
                "2026-09-30T00:00:00Z",
            )
            .unwrap();
        let action = scratch.action("job-windows-rejected", &secrets);
        let Err(SigningFailure::OutcomeUnknown(message)) =
            sign_hap(&action, &scratch.store(), &secrets, &|| false)
        else {
            panic!("a rejected password must be an unknown outcome");
        };
        assert!(
            message.contains("hapsigner did not exit successfully"),
            "{message}"
        );
        assert!(message.contains("termination=exit:1"), "{message}");
        assert!(message.contains("completedPrompts=2"), "{message}");
        for secret in [KEYSTORE_SECRET, WRONG_KEY_SECRET] {
            assert!(!message.contains(secret));
        }
        assert_eq!(scratch.runs(), ["sign-app"]);
        assert!(!Path::new(&action.output.result_record).exists());
        assert!(!Path::new(&action.output.signed_hap).exists());
        owner.remove(&secrets).unwrap();
    }

    fn a_drifted_jar_is_refused_before_anything_runs() {
        let scratch = Scratch::new("drift");
        let secrets = Memory::default();
        let owner = scratch.owner();
        owner
            .install(
                &scratch.configuration(),
                &pair(KEYSTORE_SECRET, KEY_SECRET),
                &secrets,
                "2026-09-30T00:00:00Z",
            )
            .unwrap();
        let action = scratch.action("job-windows-drift", &secrets);
        let jar = scratch.library().join("hap-sign-tool.jar");
        fs::remove_file(&jar).unwrap();
        private_file(&jar, b"another jar");
        let Err(SigningFailure::Refused(message)) =
            sign_hap(&action, &scratch.store(), &secrets, &|| false)
        else {
            panic!("a drifted JAR must be refused before dispatch");
        };
        assert!(message.contains("before dispatch"), "{message}");
        assert!(scratch.runs().is_empty());
        assert!(!Path::new(&action.output.directory).exists());
        owner.remove(&secrets).unwrap();
    }

    fn the_sdk_release_material_is_generated_signed_installed_and_removed() {
        let scratch = Scratch::new("sdk-release");
        let secrets = Memory::default();
        let owner = scratch.owner();
        let configuration = SdkReleaseConfiguration {
            project_ref: "demo-app".into(),
            bundle_name: "com.example.app".into(),
            java_executable: scratch.java(),
            sdk_root: scratch.sdk(),
        };
        let now = 1_790_000_000;
        owner
            .install_sdk_release(&configuration, &secrets, "2026-09-30T00:00:00Z", now)
            .unwrap();
        assert_eq!(
            scratch.runs(),
            ["sign-profile", "verify-profile"],
            "the profile is signed with the published password and verified"
        );
        let receipt = scratch
            .store()
            .load_validated(DEFAULT_PRESET_ID, true, &secrets)
            .unwrap();
        assert!(receipt.is_managed_sdk_release());
        let managed = PathBuf::from(receipt.managed_material_directory.clone().unwrap());
        assert_eq!(managed.parent(), Some(scratch.store().root()));
        for file in [
            &receipt.keystore,
            &receipt.app_certificate,
            &receipt.signed_profile,
        ] {
            assert_private(&file.path);
        }
        let profile: Value =
            serde_json::from_slice(&fs::read(&receipt.signed_profile.path).unwrap()).unwrap();
        assert_eq!(profile["bundle-info"]["bundle-name"], "com.example.app");
        assert_eq!(profile["validity"]["not-before"], now - 300);
        assert!(!managed.join("profile-verification.json").exists());

        // The managed preset signs with the published password.
        let action = scratch.action("job-windows-sdk-release", &secrets);
        let signed = sign_hap(&action, &scratch.store(), &secrets, &|| false).unwrap();
        assert_eq!(signed.summary["verification"], "verified");
        assert_eq!(
            scratch.runs(),
            ["sign-profile", "verify-profile", "sign-app", "verify-app"]
        );

        let removal = owner.remove(&secrets).unwrap();
        assert!(removal.removed_managed_material);
        assert!(!managed.exists());
        assert!(secrets.0.lock().unwrap().is_empty());
    }

    fn the_default_root_is_the_accounts_local_application_data() {
        let root = SigningPresetStore::default_root().unwrap();
        assert_eq!(
            root,
            application_support_directory()
                .unwrap()
                .join("ArkDeck")
                .join("Signing")
                .join("OpenHarmony")
        );
    }
}
