//! Replays the Swift `workspace.sign-openharmony-hap@1` oracle
//! (`rust/tests/fixtures/workspace-sign-oracle`, recorded on macOS by
//! `WorkspaceSignOracleContractTests`) on Windows (TASK-XPA-011, GJ-5): the
//! Rust planner, admitter, runner, reconciler and result reader over the same
//! layout below the temporary directory, the same receipt, the same fake
//! passwords and clock, and a stand-in signer on a pseudo console.
//!
//! The stand-in is this binary itself (`harness = false`), copied into the
//! root as `tools\java.exe`. Run as `java.exe -jar <jar> <command> …` it
//! follows `hap-signer.sh`'s protocol exactly: both passwords asked for on
//! the console and never printed, `sign-app` appending the marker to the
//! staged input, `verify-app` writing the two readbacks, and the mode read
//! from the HAP's `mode=` line, with the recorded `/tmp/…` marker path read
//! as the same name below this root.
//!
//! Every answer, the two parked records, the credential owner's ledger and
//! the published signed HAPs and reports must be Swift's byte for byte,
//! read through the host's labels (maintainer rulings 48 and 61): a value the
//! Runtime derives from host content that differs from the recording's —
//! the stand-in Java's SHA-256 and byte count, and everything derived from
//! them or from the root's spelling (the credential reference, plan and
//! request digests, Job, Artifact and capability identities) — is learned as
//! the recording's value at the same place, one to one, and the content is
//! then compared byte for byte. A value that does not depend on the host
//! (every material and input digest, the signed HAP) is never relabelled.
//! The same binary pins what the recording does not, as the macOS replay
//! does: no password reaches any file below the root; a parked Job is never
//! signed again; a drifted signing file refuses the dispatch before the
//! signer runs; every attempt directory is gone; durable answers read back.
//!
//! It also ports the macOS replay of a registered signing preset
//! (`registered_signing_preset`), in both project orders, over a registered
//! project whose profile resolves on Windows through the code-owned tools.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-jar") {
        windows::stand_in(&arguments[1..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
#[path = "support/mod.rs"]
mod support;

#[cfg(windows)]
mod windows {
    use super::support;
    use super::support::fixture_fs::{private_dir, temporary_root};
    use arkdeck_contract::sha256_hex;
    use arkdeck_hoststore::{
        ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
        JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
        ResolvedToolchain, SigningPresetRef, SigningSetup, WorkspaceCommandPreset,
        WorkspaceComposition, WorkspaceProfile, WorkspaceProjectStore, WorkspaceToolchainPinning,
        credential_pinning,
    };
    use arkdeck_platform::{HostDirectory, Secret, create_private_file};
    use arkdeck_provider_workspace::SigningError;
    use arkdeck_provider_workspace::credential_owner::{CredentialOwner, credential_reference};
    use arkdeck_provider_workspace::secret_envelope::encode_envelope;
    use arkdeck_provider_workspace::signing_preset::{
        SecretPresence, SigningPresetReceipt, SigningPresetStore, SigningSecrets,
    };
    use serde_json::{Map, Value, json};
    use std::collections::{BTreeMap, BTreeSet};
    use std::fs::{self, File, OpenOptions};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    /// The recording's root, as its receipt and the inputs name it.
    const SWIFT_ROOT: &str = "/tmp/arkdeck-workspace-sign-oracle";
    const NAME: &str = "arkdeck-workspace-sign-oracle";
    const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
    const PROJECT: &str = "SignOracleProject";
    const PROFILE: &str = "workspace-sign-oracle@1";
    const PRESET: &str = "preset-signing-oracle";
    const ENVELOPE: &str =
        "openharmony-release@1|secret-envelope-5d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f";
    /// The recording's fake passwords: nothing they unlock exists anywhere.
    const KEYSTORE_SECRET: &str = "oracle-keystore-password-7f3a";
    const KEY_SECRET: &str = "oracle-key-password-2c9e";
    const KEYSTORE_PROMPT: &str = "please input KeystorePwd (timeout 30 seconds):";
    const KEY_PROMPT: &str = "please input KeyPwd (timeout 30 seconds):";

    fn oracle_now() -> Option<String> {
        Some(TIMESTAMP.into())
    }

    fn root() -> PathBuf {
        temporary_root().join(NAME)
    }

    // ---- the stand-in signer ---------------------------------------------

    fn option(arguments: &[String], name: &str) -> String {
        arguments
            .iter()
            .position(|argument| argument == name)
            .and_then(|index| arguments.get(index + 1))
            .cloned()
            .unwrap_or_default()
    }

    fn say(text: &str) {
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(text.as_bytes()).unwrap();
        stdout.flush().unwrap();
    }

    /// `IFS= read -r` after a prompt, from the console, echo cleared.
    fn ask(prompt: &str) -> Option<Secret> {
        arkdeck_platform::read_terminal_secret(prompt)
            .ok()
            .filter(|secret| !secret.as_bytes().is_empty())
    }

    /// `hap-signer.sh`, statement for statement. `arguments` starts at
    /// `-jar`.
    pub fn stand_in(arguments: &[String]) -> ! {
        use std::process::exit;
        if arguments.len() < 3 || !Path::new(&arguments[1]).is_file() {
            exit(64);
        }
        // `<root>\tools\java.exe`.
        let root = std::env::current_exe()
            .unwrap()
            .ancestors()
            .nth(2)
            .unwrap()
            .to_path_buf();
        let command = arguments[2].as_str();
        let rest = &arguments[3..];
        let input = option(rest, "-inFile");
        let output = option(rest, "-outFile");
        let chain = option(rest, "-outCertChain");
        let profile = option(rest, "-outProfile");
        let Ok(bytes) = fs::read(&input) else {
            exit(64)
        };
        let mode = String::from_utf8_lossy(&bytes)
            .lines()
            .find_map(|line| line.strip_prefix("mode=").map(str::to_owned))
            .unwrap_or_default();
        match command {
            "sign-app" => {
                if output.is_empty() {
                    exit(64);
                }
                if mode == "unknown-prompt" {
                    say("Password: ");
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    exit(65);
                }
                let Some(keystore) = ask(KEYSTORE_PROMPT) else {
                    exit(66)
                };
                if mode == "repeat-prompt" {
                    say(KEYSTORE_PROMPT);
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    exit(67);
                }
                let Some(_key) = ask(KEY_PROMPT) else {
                    exit(68)
                };
                match mode.as_str() {
                    "echo-secret" => {
                        say(std::str::from_utf8(keystore.as_bytes()).unwrap());
                        exit(69);
                    }
                    "sign-failure" => {
                        say(
                            "Incorrect keystore password, please input the correct plaintext \
                             password.",
                        );
                        exit(74);
                    }
                    _ => {}
                }
                if !input.ends_with(".hap") {
                    say("Invalid file format.");
                    exit(75);
                }
                if Path::new(&output).exists() {
                    exit(71);
                }
                let mut signed = bytes;
                signed.extend_from_slice(b"arkdeck-signed-fixture");
                if fs::write(&output, signed).is_err() {
                    exit(70);
                }
                exit(0)
            }
            "verify-app" => {
                if chain.is_empty() || profile.is_empty() || !bytes.starts_with(b"PK\x03\x04") {
                    exit(72);
                }
                if mode == "verify-failure" {
                    exit(73);
                }
                if let Some(marker) = mode.strip_prefix("verify-once:") {
                    let relative = marker
                        .strip_prefix(&format!("{SWIFT_ROOT}/"))
                        .unwrap_or_else(|| exit(72));
                    let marker = root.join(relative.replace('/', "\\"));
                    if !marker.exists() {
                        fs::write(&marker, b"failed-once").unwrap();
                        exit(73);
                    }
                }
                if !Path::new(&chain).exists() {
                    fs::write(&chain, b"fixture-certificate-chain").unwrap();
                }
                if !Path::new(&profile).exists() {
                    fs::write(&profile, b"fixture-profile").unwrap();
                }
                exit(0)
            }
            _ => exit(64),
        }
    }

    // ---- the runner ------------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "the_rust_runtime_answers_the_recorded_signing_sequence",
            the_rust_runtime_answers_the_recorded_signing_sequence,
        ),
        (
            "the_labels_read_only_host_derived_values",
            the_labels_read_only_host_derived_values,
        ),
        (
            "a_registered_signing_preset_pins_its_credential_and_signs_after_a_restart",
            a_registered_signing_preset_pins_its_credential_and_signs_after_a_restart,
        ),
        (
            "a_registered_signing_project_need_not_be_the_first_project",
            a_registered_signing_project_need_not_be_the_first_project,
        ),
    ];

    /// What the labels may and may not read as the recording's.
    fn the_labels_read_only_host_derived_values() {
        let a = "a".repeat(64);
        let b = "b".repeat(64);
        let c = "c".repeat(64);
        // A digest at the same place is learned and read back.
        let mut labels = Labels::default();
        labels.learn(
            &json!({"d": format!("job-{a}")}),
            &json!({"d": format!("job-{b}")}),
        );
        assert_eq!(labels.swift(&json!([a.clone()])), json!([b.clone()]));
        // Text around it that differs is not: nothing is learned.
        let mut labels = Labels::default();
        labels.learn(&json!(format!("job-{a}")), &json!(format!("run-{b}")));
        assert_eq!(labels.swift.len(), 0);
        // Short runs (a count, a short id) are never labels.
        labels.learn(&json!("n=1234567"), &json!("n=7654321"));
        assert_eq!(labels.swift.len(), 0);
        // One host value never reads as two recorded values.
        let mut labels = Labels::default();
        labels.learn_value(&a, &b);
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let twice = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            labels.learn_value(&a, &c);
        }));
        std::panic::set_hook(hook);
        assert!(twice.is_err());
        // Only the named host spellings are read as the recording's.
        let mut labels = Labels::default();
        let host = root().join("material").join("release.cer");
        assert_eq!(
            host_spelling(
                &mut labels,
                &json!({"path": host.to_str().unwrap(), "byteCount": 19}),
                &json!({"path": format!("{SWIFT_ROOT}/material/release.cer"), "byteCount": 20}),
            ),
            json!({"path": format!("{SWIFT_ROOT}/material/release.cer"), "byteCount": 19})
        );
        assert_eq!(
            host_spelling(
                &mut labels,
                &json!(host.to_str().unwrap()),
                &json!(format!("{SWIFT_ROOT}/material/release.p12")),
            ),
            json!(host.to_str().unwrap())
        );
        assert_eq!(
            host_spelling(
                &mut labels,
                &json!("x (observedOutputBytes=305; diagnosticCode=a)"),
                &json!("x (observedOutputBytes=160; diagnosticCode=b)"),
            ),
            json!("x (observedOutputBytes=160; diagnosticCode=a)")
        );
    }

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

    // ---- labels ----------------------------------------------------------

    /// The host's derived values read as the recording's (rulings 48, 61):
    /// a lowercase hexadecimal run of at least 32 digits this host produced
    /// where the recording has another run of the same length, learned one
    /// to one. Nothing else is ever rewritten.
    #[derive(Default)]
    struct Labels {
        swift: BTreeMap<String, String>,
        host: BTreeMap<String, String>,
    }

    fn hex_runs(text: &str) -> Vec<(usize, usize)> {
        let bytes = text.as_bytes();
        let mut runs = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            if matches!(bytes[index], b'0'..=b'9' | b'a'..=b'f') {
                let start = index;
                while index < bytes.len() && matches!(bytes[index], b'0'..=b'9' | b'a'..=b'f') {
                    index += 1;
                }
                if index - start >= 32 {
                    runs.push((start, index));
                }
            } else {
                index += 1;
            }
        }
        runs
    }

    impl Labels {
        fn learn_value(&mut self, host: &str, swift: &str) {
            assert_eq!(host.len(), swift.len(), "{host} relabels {swift}");
            if host == swift {
                return;
            }
            if let Some(previous) = self.swift.insert(host.to_owned(), swift.to_owned()) {
                assert_eq!(previous, swift, "{host} reads as two recorded values");
            }
            if let Some(previous) = self.host.insert(swift.to_owned(), host.to_owned()) {
                assert_eq!(previous, host, "{swift} is read from two host values");
            }
        }

        /// Learns the hexadecimal runs where two strings that differ only
        /// in them place one.
        fn learn_text(&mut self, host: &str, swift: &str) {
            let (host_runs, swift_runs) = (hex_runs(host), hex_runs(swift));
            if host_runs.len() != swift_runs.len() || host.len() != swift.len() {
                return;
            }
            if host_runs != swift_runs {
                return;
            }
            let mut previous = 0;
            for &(start, end) in &host_runs {
                if host[previous..start] != swift[previous..start] {
                    return;
                }
                previous = end;
            }
            if host[previous..] != swift[previous..] {
                return;
            }
            for (start, end) in host_runs {
                self.learn_value(&host[start..end], &swift[start..end]);
            }
        }

        /// Walks `host` and `swift` together, learning every place where
        /// they differ only by hexadecimal runs.
        fn learn(&mut self, host: &Value, swift: &Value) {
            match (host, swift) {
                (Value::Object(host), Value::Object(swift)) => {
                    for (key, value) in host {
                        if let Some(other) = swift.get(key) {
                            self.learn(value, other);
                        }
                    }
                }
                (Value::Array(host), Value::Array(swift)) => {
                    for (value, other) in host.iter().zip(swift) {
                        self.learn(value, other);
                    }
                }
                (Value::String(host), Value::String(swift)) => {
                    self.learn_text(host, swift);
                    // A string that carries JSON (a request) is walked too.
                    if let (Ok(host), Ok(swift)) = (
                        serde_json::from_str::<Value>(host),
                        serde_json::from_str::<Value>(swift),
                    ) && (host.is_object() || host.is_array())
                    {
                        self.learn(&host, &swift);
                    }
                }
                _ => (),
            }
        }

        /// `text` with every learned run read as the recording's.
        fn swift_text(&self, text: &str) -> String {
            let mut out = String::with_capacity(text.len());
            let mut previous = 0;
            for (start, end) in hex_runs(text) {
                out.push_str(&text[previous..start]);
                let run = &text[start..end];
                out.push_str(self.swift.get(run).map_or(run, String::as_str));
                previous = end;
            }
            out.push_str(&text[previous..]);
            out
        }

        fn swift_bytes(&self, bytes: &[u8]) -> Vec<u8> {
            match std::str::from_utf8(bytes) {
                Ok(text) => self.swift_text(text).into_bytes(),
                Err(_) => bytes.to_vec(),
            }
        }

        fn swift(&self, value: &Value) -> Value {
            match value {
                Value::Object(object) => Value::Object(
                    object
                        .iter()
                        .map(|(key, value)| (self.swift_text(key), self.swift(value)))
                        .collect(),
                ),
                Value::Array(array) => Value::Array(array.iter().map(|v| self.swift(v)).collect()),
                Value::String(text) => Value::String(self.swift_text(text)),
                other => other.clone(),
            }
        }

        fn host(&self, swift: &str) -> String {
            self.host
                .get(swift)
                .cloned()
                .unwrap_or_else(|| swift.to_owned())
        }
    }

    /// Learns `host` against `swift`, then requires them equal as labels.
    fn assert_relabelled(labels: &mut Labels, host: &Value, swift: &Value, what: &str) {
        let host = host_spelling(labels, host, swift);
        labels.learn(&host, swift);
        assert_eq!(&labels.swift(&host), swift, "{what}");
    }

    /// The host-only spellings of one value read as the recording's at the
    /// same place, and nothing else:
    ///
    /// - a path below this root, where the recording names the same entry
    ///   below its root (`/tmp/…`, or Foundation's `/private/tmp/…`), with
    ///   `\` for `/` and the stand-in `tools\java.exe` for `tools/java`;
    /// - the stand-in Java's byte count (`javaExecutable.byteCount`);
    /// - `observedOutputBytes=<n>` in a signer diagnostic, which counts the
    ///   pseudo console's rendered VT stream on Windows (the PTY exchange's
    ///   recorded decision) where macOS counts the terminal's raw bytes;
    /// - a durable typed action's Base64 payload, whose JSON is read the
    ///   same way and must then be the recording's.
    fn host_spelling(labels: &mut Labels, host: &Value, swift: &Value) -> Value {
        match (host, swift) {
            (Value::Object(host), Value::Object(swift)) => Value::Object(
                host.iter()
                    .map(|(key, value)| {
                        let read = match swift.get(key) {
                            Some(other) if key == "javaExecutable" => {
                                let mut value = host_spelling(labels, value, other);
                                if value["byteCount"].is_number() && other["byteCount"].is_number()
                                {
                                    value["byteCount"] = other["byteCount"].clone();
                                }
                                value
                            }
                            Some(other) => host_spelling(labels, value, other),
                            None => value.clone(),
                        };
                        (key.clone(), read)
                    })
                    .collect(),
            ),
            (Value::Array(host), Value::Array(swift)) => Value::Array(
                host.iter()
                    .enumerate()
                    .map(|(index, value)| match swift.get(index) {
                        Some(other) => host_spelling(labels, value, other),
                        None => value.clone(),
                    })
                    .collect(),
            ),
            (Value::String(host), Value::String(swift)) => {
                Value::String(host_text(labels, host, swift))
            }
            _ => host.clone(),
        }
    }

    fn host_text(labels: &mut Labels, host: &str, swift: &str) -> String {
        if host == swift {
            return host.to_owned();
        }
        if same_entry(host, swift) {
            return swift.to_owned();
        }
        if let (Some(host_count), Some(swift_count)) = (output_count(host), output_count(swift))
            && host_count != swift_count
        {
            return host_text(labels, &host.replacen(host_count, swift_count, 1), swift);
        }
        if let (Some(host_json), Some(swift_json)) = (base64_json(host), base64_json(swift)) {
            let read = host_spelling(labels, &host_json, &swift_json);
            labels.learn(&read, &swift_json);
            if labels.swift(&read) == swift_json {
                // The payload's own bytes are Swift's encoding of that
                // document; its content is what is compared.
                return swift.to_owned();
            }
        }
        host.to_owned()
    }

    /// Whether the host path `host` names, below this root, the entry the
    /// recording's path `swift` names below its root.
    fn same_entry(host: &str, swift: &str) -> bool {
        let root = root();
        let Some(rest) = host
            .strip_prefix(root.to_str().unwrap())
            .and_then(|rest| rest.strip_prefix('\\'))
        else {
            return false;
        };
        let rest = rest.replace('\\', "/");
        let rest = if rest == "tools/java.exe" {
            "tools/java".to_owned()
        } else {
            rest
        };
        [
            format!("{SWIFT_ROOT}/{rest}"),
            format!("/private{SWIFT_ROOT}/{rest}"),
        ]
        .iter()
        .any(|spelling| spelling == swift)
    }

    /// The digits after `observedOutputBytes=`.
    fn output_count(text: &str) -> Option<&str> {
        let start = text.find("observedOutputBytes=")? + "observedOutputBytes=".len();
        let length = text[start..].bytes().take_while(u8::is_ascii_digit).count();
        (length > 0).then(|| &text[start..start + length])
    }

    /// `text` as standard Base64 of a JSON object.
    fn base64_json(text: &str) -> Option<Value> {
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        if !text.len().is_multiple_of(4) || text.len() < 8 {
            return None;
        }
        let mut bytes = Vec::new();
        let mut buffer = 0u32;
        let mut bits = 0;
        for &byte in text.as_bytes() {
            if byte == b'=' {
                break;
            }
            let value = alphabet.iter().position(|&a| a == byte)? as u32;
            buffer = (buffer << 6) | value;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                bytes.push((buffer >> bits) as u8);
                buffer &= (1 << bits) - 1;
            }
        }
        let value: Value = serde_json::from_slice(&bytes).ok()?;
        value.is_object().then_some(value)
    }

    // ---- fixtures --------------------------------------------------------

    fn exclusive() -> File {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(temporary_root().join(format!("{NAME}.lock")))
            .unwrap();
        lock.lock().unwrap();
        lock
    }

    /// The oracle's Keychain: the envelope holding both fake passwords, in
    /// memory, under the receipt's account.
    struct OracleSecrets(Mutex<BTreeMap<String, Vec<u8>>>);

    impl OracleSecrets {
        fn installed() -> Self {
            let envelope = encode_envelope(KEYSTORE_SECRET.as_bytes(), KEY_SECRET.as_bytes());
            Self(Mutex::new(BTreeMap::from([(
                ENVELOPE.to_owned(),
                envelope.as_bytes().to_vec(),
            )])))
        }
    }

    impl SigningSecrets for OracleSecrets {
        fn read(&self, account: &str) -> Result<Secret, SigningError> {
            self.0
                .lock()
                .unwrap()
                .get(account)
                .map(|bytes| Secret::from_slice(bytes))
                .ok_or_else(|| SigningError::SecretUnavailable("missing oracle secret".into()))
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

    /// A private root, removed when the test ends.
    struct Root(PathBuf);

    impl Root {
        fn fixed() -> Self {
            let root = root();
            let _ = fs::remove_dir_all(&root);
            private_dir(&root);
            for directory in ["artifacts", "jobs-state"] {
                private_dir(&root.join(directory));
            }
            Self(root)
        }
        fn join(&self, relative: &str) -> PathBuf {
            self.0.join(relative.replace('/', "\\"))
        }
        fn text(&self) -> String {
            self.0.to_str().unwrap().to_owned()
        }
    }

    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A file below the private root, created private.
    fn write(path: &Path, bytes: &[u8]) {
        let mut missing = Vec::new();
        let mut parent = path.parent().unwrap();
        while fs::symlink_metadata(parent).is_err() {
            missing.push(parent.to_path_buf());
            parent = parent.parent().unwrap();
        }
        for directory in missing.into_iter().rev() {
            private_dir(&directory);
        }
        let _ = fs::remove_file(path);
        let mut file = create_private_file(path).unwrap();
        file.write_all(bytes).unwrap();
        file.sync_all().unwrap();
    }

    /// The recorded receipt over this root: every path the host's spelling
    /// of the same name, and the Java launcher the stand-in that is there.
    fn host_receipt(root: &Root, fixture: &Path) -> Vec<u8> {
        let mut receipt = support::document(fixture, "preset-v1.json");
        for key in [
            "appCertificate",
            "javaExecutable",
            "keystore",
            "signedProfile",
            "signerJAR",
        ] {
            let swift = receipt[key]["path"].as_str().unwrap().to_owned();
            let relative = swift.strip_prefix(&format!("{SWIFT_ROOT}/")).unwrap();
            let relative = if key == "javaExecutable" {
                "tools/java.exe".to_owned()
            } else {
                relative.to_owned()
            };
            let host = root.join(&relative);
            receipt[key]["path"] = json!(host.to_str().unwrap());
            if key == "javaExecutable" {
                let bytes = fs::read(&host).unwrap();
                receipt[key]["byteCount"] = json!(bytes.len());
                receipt[key]["sha256"] = json!(sha256_hex(&bytes));
            } else {
                assert_eq!(
                    receipt[key]["sha256"].as_str().unwrap(),
                    sha256_hex(&fs::read(&host).unwrap()),
                    "{key} is the recorded file"
                );
            }
        }
        serde_json::to_vec_pretty(&receipt).unwrap()
    }

    /// The installed preset, the project source and the five published
    /// inputs, as the Swift recording left them before its first request;
    /// the Java launcher the stand-in.
    fn seed(root: &Root, fixture: &Path) {
        write(
            &root.join("tools/java.exe"),
            &fs::read(std::env::current_exe().unwrap()).unwrap(),
        );
        for (name, bytes) in [
            ("material/hap-sign-tool.jar", "oracle hap-sign-tool\n"),
            ("material/release.p12", "oracle keystore\n"),
            ("material/release.cer", "oracle certificate\n"),
            ("material/release.p7b", "oracle profile\n"),
            (
                "source/entry/src/main/ets/pages/Index.ets",
                "struct Index {}\n",
            ),
        ] {
            write(&root.join(name), bytes.as_bytes());
        }
        private_dir(&root.join("preset"));
        write(
            &root.join("preset/preset-v1.json"),
            &host_receipt(root, fixture),
        );
        let inputs = root.join("artifacts/job-input-hap");
        private_dir(&inputs);
        let directory = HostDirectory::open(&inputs).unwrap();
        for file in fs::read_dir(fixture.join("artifacts/job-input-hap")).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap().to_str().unwrap().to_owned();
            let bytes = fs::read(&file).unwrap();
            if name == "index.json" {
                write(&inputs.join(&name), &bytes);
            } else {
                directory.create_document(&name, &bytes).unwrap();
                directory.seal_document(&name).unwrap();
            }
        }
    }

    struct Owners {
        root: Root,
        jobs: JobStore,
        artifacts: ArtifactReadStore,
        capabilities: CapabilityStore,
        holds: DeviceHolds,
        workspace: WorkspaceComposition,
    }

    fn proven() -> Map<String, Value> {
        Map::from_iter([
            ("phase".into(), json!("preAdmission")),
            ("newDispatchCount".into(), json!(0)),
        ])
    }

    fn refused(code: &str, message: &str, details: Option<Map<String, Value>>) -> Value {
        let mut error = json!({"code": code, "message": message});
        if let Some(details) = details {
            error["details"] = Value::Object(details);
        }
        json!({"ok": false, "error": error})
    }

    impl Owners {
        fn default_root(&self) -> PathBuf {
            self.root.join("jobs-state")
        }
        fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
            MutationAuthority {
                default_root,
                sessions: None,
                capabilities: &self.capabilities,
                holds: &self.holds,
            }
        }
        fn planner(&self) -> JobPlanner<'_> {
            JobPlanner {
                artifacts: Some(&self.artifacts),
                imports: None,
                analyzer: None,
                state_root: &self.root.0,
                hdc: None,
                workspace: Some(&self.workspace),
            }
        }
        fn runner<'a>(&'a self, default_root: &'a Path) -> JobRunner<'a> {
            JobRunner {
                mutation: Some(MutationExecution {
                    authority: self.authority(default_root),
                    state_root: &self.root.0,
                }),
                jobs: &self.jobs,
                artifacts: &self.artifacts,
                imports: None,
                analyzer: None,
                quota: 8 * 1024 * 1024 * 1024,
                home: r"C:\nonexistent-home",
                now: oracle_now,
                precise_now: oracle_now,
                sessions: None,
                cancellation: None,
                after_commit: None,
                hdc: None,
                workspace: Some(&self.workspace),
            }
        }
        fn plan(&self, params: &Value) -> Value {
            match self.planner().handle(params.as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, &refusal.message, Some(proven())),
            }
        }
        fn submit(&self, params: &Value) -> Value {
            let default_root = self.default_root();
            let admitter = JobAdmitter {
                planner: self.planner(),
                jobs: &self.jobs,
                now: oracle_now,
                authority: Some(self.authority(&default_root)),
            };
            match admitter.handle(params.as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    &refusal.message,
                    Some(if refusal.proven { proven() } else { Map::new() }),
                ),
            }
        }
        fn run(&self, job: &str) -> Value {
            let default_root = self.default_root();
            match self
                .runner(&default_root)
                .handle(json!({"jobId": job}).as_object().unwrap())
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, &refusal.message, Some(refusal.details)),
            }
        }
        fn reconcile(&self, job: &str) -> Value {
            let default_root = self.default_root();
            let runner = self.runner(&default_root);
            let reconciler = JobReconciler {
                jobs: &self.jobs,
                artifacts: &self.artifacts,
                imports: None,
                now: oracle_now,
                sessions: None,
                hdc: None,
                capabilities: Some(&self.capabilities),
                runner: Some(&runner),
            };
            match reconciler.handle(json!({"jobId": job}).as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, &error.message, error.details),
            }
        }
        fn result(&self, job: &str) -> Value {
            let reader = JobResultReader {
                jobs: &self.jobs,
                artifacts: &self.artifacts,
            };
            match reader.handle("job.result", json!({"jobId": job}).as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, &error.message, error.details),
            }
        }
        fn record(&self, job: &str) -> Value {
            self.jobs.read_snapshot(job).unwrap().value().unwrap()
        }

        /// Close execution and read owners before reopening only durable
        /// readers: owner-level restart evidence.
        fn assert_reopened_readback(self, job_ids: &[String]) {
            let expected: Vec<_> = job_ids
                .iter()
                .map(|job| (self.record(job), self.result(job)))
                .collect();
            let Self {
                root,
                jobs,
                artifacts,
                capabilities,
                holds,
                workspace,
            } = self;
            drop((jobs, artifacts, capabilities, holds, workspace));
            let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
            let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
            let reader = JobResultReader {
                jobs: &jobs,
                artifacts: &artifacts,
            };
            for (job, (record, result)) in job_ids.iter().zip(expected) {
                assert_eq!(jobs.read_snapshot(job).unwrap().value().unwrap(), record);
                let reopened =
                    match reader.handle("job.result", json!({"jobId": job}).as_object().unwrap()) {
                        Ok(value) => json!({"ok": true, "result": value}),
                        Err(error) => refused(&error.code, &error.message, error.details),
                    };
                assert_eq!(
                    reopened, result,
                    "{job}: durable result after closing owners"
                );
            }
        }
    }

    /// The recording's Runtime over the fixed root: the signing preset the
    /// workspace preset pins through the credential owner, the only
    /// registered preset of the profile, no fallback to the installed
    /// receipt.
    fn owners(root: Root) -> Owners {
        let preset_root = root.join("preset");
        let store = SigningPresetStore::new(preset_root.to_str().unwrap());
        let owner = CredentialOwner::new(store);
        let credential = owner.current().unwrap().credential_ref;
        owner
            .acquire(&credential, PRESET, &OracleSecrets::installed())
            .unwrap();
        // The profile's inspection and patch presets are never run here;
        // any executable stands for them.
        let executable = root.join("tools/java.exe");
        let preset = |id: &str| {
            WorkspaceCommandPreset::hashing(id, executable.to_str().unwrap(), None, &[], 10)
                .unwrap()
        };
        let profile = WorkspaceProfile::primary(
            PROFILE,
            PROJECT,
            root.join("source").to_str().unwrap(),
            &["entry/src/main/ets/**"],
            preset("inspect"),
            preset("patch"),
            ProfilePresets::default(),
        )
        .unwrap()
        .with_signing(
            vec![SigningPresetRef::new(PRESET, &credential, 600).unwrap()],
            false,
        );
        let workspace = WorkspaceComposition::with_profiles(
            vec![profile],
            &root.join("evolution-workspaces"),
            oracle_now,
        )
        .unwrap()
        .with_signing(
            &preset_root,
            Box::new(OracleSecrets::installed()),
            &root.join("signing-attempts"),
        )
        .unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let capabilities = CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap();
        Owners {
            jobs,
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            capabilities,
            holds: DeviceHolds::default(),
            workspace,
            root,
        }
    }

    fn request_id(params: &Value) -> Option<String> {
        let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
        document["requestId"].as_str().map(str::to_owned)
    }

    /// The regular files of one directory whose names start with `prefix`.
    fn files(directory: &Path, prefix: &str) -> Vec<(String, Vec<u8>)> {
        let mut found: Vec<(String, Vec<u8>)> = fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(prefix)
            })
            .map(|path| {
                (
                    path.file_name().unwrap().to_string_lossy().into_owned(),
                    fs::read(&path).unwrap(),
                )
            })
            .collect();
        found.sort();
        found
    }

    /// Every regular file below `root`.
    fn every_file(root: &Path) -> Vec<PathBuf> {
        let mut found = Vec::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                let kind = fs::symlink_metadata(&path).unwrap().file_type();
                if kind.is_dir() {
                    pending.push(path);
                } else if kind.is_file() {
                    found.push(path);
                }
            }
        }
        found
    }

    /// Neither fake password appears anywhere in `bytes`, as UTF-8 or as
    /// UTF-16.
    fn secret_free(what: &str, bytes: &[u8]) {
        for secret in [KEYSTORE_SECRET, KEY_SECRET] {
            let wide: Vec<u8> = secret.encode_utf16().flat_map(u16::to_le_bytes).collect();
            for needle in [secret.as_bytes(), &wide[..]] {
                assert!(
                    !bytes.windows(needle.len()).any(|window| window == needle),
                    "a password reached {what}"
                );
            }
        }
    }

    fn the_rust_runtime_answers_the_recorded_signing_sequence() {
        let _held = exclusive();
        let fixture = support::fixture("workspace-sign-oracle");
        let provenance = support::document(&fixture, "provenance.json");
        for (name, digest) in provenance["files"].as_object().unwrap() {
            assert_eq!(
                sha256_hex(&fs::read(fixture.join(name)).unwrap()),
                digest.as_str().unwrap(),
                "{name} is the recorded file"
            );
        }
        let root = Root::fixed();
        seed(&root, &fixture);
        let mut labels = Labels::default();
        // The credential reference is Swift's over the recorded receipt,
        // and this host's over the same receipt with the stand-in's Java.
        let recorded: SigningPresetReceipt =
            serde_json::from_slice(&fs::read(fixture.join("preset-v1.json")).unwrap()).unwrap();
        let swift_ledger = support::document(&fixture, "credential-owner-v1.json");
        assert_eq!(
            credential_reference(&recorded).unwrap(),
            swift_ledger["credentialRef"].as_str().unwrap(),
            "the recorded credential reference is Swift's"
        );
        // Values that do not depend on this host are never relabelled.
        // The stand-in Java's bytes are this binary, not `hap-signer.sh`, so
        // its digest and every recorded file that names it (the signing
        // reports) are host-derived; every other recorded file is not.
        let java = provenance["files"]["hap-signer.sh"]
            .as_str()
            .unwrap()
            .to_owned();
        let mut fixed: BTreeSet<String> = provenance["files"]
            .as_object()
            .unwrap()
            .iter()
            .filter(|(name, digest)| {
                digest.as_str() != Some(java.as_str())
                    && !String::from_utf8_lossy(&fs::read(fixture.join(name.as_str())).unwrap())
                        .contains(java.as_str())
            })
            .map(|(_, digest)| digest.as_str().unwrap().to_owned())
            .collect();
        for key in ["appCertificate", "keystore", "signedProfile", "signerJAR"] {
            fixed.insert(
                support::document(&fixture, "preset-v1.json")[key]["sha256"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
        }
        let owners = owners(root);
        // The credential owner's ledger is Swift's once the preset pinned
        // it, read through the credential reference's label.
        let ledger: Value = serde_json::from_slice(
            &fs::read(owners.root.join("preset/credential-owner-v1.json")).unwrap(),
        )
        .unwrap();
        assert_relabelled(&mut labels, &ledger, &swift_ledger, "the ledger");
        let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(frames.len(), 19);
        let mut jobs: BTreeMap<String, String> = BTreeMap::new();
        for (index, frame) in frames.iter().enumerate() {
            let method = frame["method"].as_str().unwrap();
            // The request as this host would have sent it: the recorded
            // one, every learned label read back as this host's value.
            let params = {
                let text = serde_json::to_string(&frame["params"]).unwrap();
                let mut host = String::with_capacity(text.len());
                let mut previous = 0;
                for (start, end) in hex_runs(&text) {
                    host.push_str(&text[previous..start]);
                    host.push_str(&labels.host(&text[start..end]));
                    previous = end;
                }
                host.push_str(&text[previous..]);
                serde_json::from_str::<Value>(&host).unwrap()
            };
            let label = request_id(&params)
                .or_else(|| {
                    let job = params["jobId"].as_str()?;
                    jobs.iter()
                        .find(|(_, id)| id.as_str() == job)
                        .map(|(label, _)| label.clone())
                })
                .unwrap_or_default();
            let answer = match method {
                "job.plan" => support::legacy_plan_answer(owners.plan(&params)),
                "job.submit" => {
                    let answer = owners.submit(&params);
                    if let Some(job) = answer["result"]["jobId"].as_str() {
                        jobs.insert(label.clone(), job.to_owned());
                    }
                    answer
                }
                "job.run" => owners.run(params["jobId"].as_str().unwrap()),
                "job.reconcile" => owners.reconcile(params["jobId"].as_str().unwrap()),
                "job.result" => owners.result(params["jobId"].as_str().unwrap()),
                other => panic!("the oracle records no {other}"),
            };
            let mut recorded = json!({"ok": frame["ok"]});
            if frame["ok"] == true {
                recorded["result"] = frame["result"].clone();
            } else {
                recorded["error"] = frame["error"].clone();
            }
            assert_relabelled(
                &mut labels,
                &answer,
                &recorded,
                &format!("frame {index}: {method} {label}"),
            );
            if method == "job.run" && answer["result"]["state"] == "waitingForRecovery" {
                let job = params["jobId"].as_str().unwrap();
                let name = match label.as_str() {
                    "request-rejected" => Some("rejected-parked-record.json"),
                    "request-verify-once" => Some("verify-once-parked-record.json"),
                    _ => None,
                };
                if let Some(name) = name {
                    assert_relabelled(
                        &mut labels,
                        &owners.record(job),
                        &support::document(&fixture, name),
                        name,
                    );
                }
                // A parked Job is never signed again.
                let before = owners.record(job);
                assert_eq!(
                    owners.run(job),
                    refused(
                        "resourceConflict",
                        &format!("job {job} is waitingForRecovery, not runnable"),
                        Some(proven())
                    ),
                    "{label}"
                );
                assert_eq!(owners.record(job), before, "{label}");
            }
        }
        // The signed and the recovered Jobs' products, byte for byte through
        // the labels.
        for job in fs::read_dir(fixture.join("artifacts")).unwrap() {
            let job = job.unwrap().file_name().into_string().unwrap();
            if job == "job-input-hap" {
                continue;
            }
            let host_job = labels.host(&job["job-".len()..]);
            let host: Vec<(String, Vec<u8>)> = files(
                &owners
                    .root
                    .join("artifacts")
                    .join(format!("job-{host_job}")),
                "ART-",
            )
            .into_iter()
            .map(|(name, bytes)| (labels.swift_text(&name), labels.swift_bytes(&bytes)))
            .collect();
            let mut host = host;
            host.sort();
            assert_eq!(
                host,
                files(&fixture.join("artifacts").join(&job), "ART-"),
                "{job}'s published products"
            );
        }
        // The ledger is unchanged by every resolution since.
        let ledger: Value = serde_json::from_slice(
            &fs::read(owners.root.join("preset/credential-owner-v1.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(labels.swift(&ledger), swift_ledger);
        // No value that does not depend on this host was relabelled.
        let relabelled: BTreeSet<&String> = labels.swift.values().collect();
        for value in &fixed {
            assert!(!relabelled.contains(value), "{value} was relabelled");
        }
        println!(
            "relabelled {} host-derived values: {:?}",
            labels.swift.len(),
            labels.swift
        );
        // A signing file that drifts after admission refuses the dispatch
        // before the signer runs: the Job fails with its outcome known.
        let drifted = json!({"requestJson": json!({
            "documentType": "runtime-operation-request",
            "idempotencyKey": "idempotency-drift",
            "inputs": {"projectRef": PROJECT, "signingPresetRef": PRESET,
                       "unsignedHapArtifactLease":
                           "lease-v1:job-input-hap:ART-81ae19b19ca7ea0d3ce99c554182c815"},
            "operation": {"id": "workspace.sign-openharmony-hap", "version": 1},
            "requestId": "request-drift",
            "requestedOutputs": ["derivedArtifacts"],
            "schemaVersion": "1.0.0",
            "target": {"targetId": "workspace-host"},
        }).to_string()});
        let accepted = owners.submit(&drifted);
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        write(
            &owners.root.join("material/release.cer"),
            b"a certificate the receipt never pinned\n",
        );
        let run = owners.run(&job);
        let record = owners.record(&job);
        assert_eq!(record["state"], "failed", "{run}");
        assert_eq!(record["outcomeUnknown"], false, "{record}");
        let timeline: Vec<&str> = record["timeline"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| line.as_str().unwrap())
            .collect();
        assert!(
            timeline.contains(&"reason: workspace.presetUnavailable"),
            "{timeline:?}"
        );
        assert!(
            !timeline.iter().any(|line| line.starts_with("intent ")),
            "{timeline:?}"
        );
        assert!(
            !every_file(&owners.root.join("artifacts"))
                .iter()
                .any(
                    |path| path.starts_with(owners.root.join("artifacts").join(&job))
                        && path
                            .file_name()
                            .is_some_and(|name| name.to_string_lossy().starts_with("ART-"))
                ),
            "nothing was published for {job}"
        );
        // Every attempt directory is gone once its Job is terminal.
        assert_eq!(
            fs::read_dir(owners.root.join("signing-attempts"))
                .unwrap()
                .count(),
            0
        );
        // No password reached any file the Runtime keeps.
        let every = every_file(&owners.root.0);
        assert!(every.len() > 20, "the scan read the run's files");
        for path in every {
            if path == owners.root.join("tools/java.exe") {
                // The stand-in itself carries the fixture constants.
                continue;
            }
            secret_free(&path.display().to_string(), &fs::read(&path).unwrap());
        }
        let _ = owners.root.text();
        let mut readback_jobs: Vec<String> = jobs.values().cloned().collect();
        readback_jobs.push(job);
        owners.assert_reopened_readback(&readback_jobs);
    }

    fn ledger_owners(root: &Root) -> Value {
        let ledger: Value = serde_json::from_slice(
            &fs::read(root.join("preset/credential-owner-v1.json")).unwrap(),
        )
        .unwrap();
        ledger["presetOwners"].clone()
    }

    /// The production composition of a registered signing preset, as the
    /// macOS replay drives it (`registered_signing_preset`): registering it
    /// pins the credential through the owner's ledger — refused, before the
    /// store writes anything, for a credential bound to another project.
    /// After a restart the preset composes through its toolchain pin and its
    /// credential into its project's profile, whose code-owned tools now
    /// resolve on Windows, and signs with it; the owner releases at start-up
    /// a pin no preset record carries. Without the credential owner the same
    /// preset stays unresolved and nothing is signed. Removing the preset
    /// releases its pin.
    fn a_registered_signing_preset_pins_its_credential_and_signs_after_a_restart() {
        registered_signing_preset(false);
    }

    fn a_registered_signing_project_need_not_be_the_first_project() {
        registered_signing_preset(true);
    }

    fn registered_signing_preset(signing_last: bool) {
        let _held = exclusive();
        let fixture = support::fixture("workspace-sign-oracle");
        let root = Root::fixed();
        seed(&root, &fixture);
        for tree in ["source", "other"] {
            write(&root.join(&format!("{tree}/build-profile.json5")), b"{}\n");
            write(
                &root.join(&format!("{tree}/entry/src/main/module.json5")),
                b"{}\n",
            );
        }
        private_dir(&root.join("workspace-projects"));
        let store = root.join("preset");
        let projects = Arc::new(
            WorkspaceProjectStore::open(&root.join("workspace-projects"))
                .unwrap()
                .with_dependency_pinning(
                    Some(WorkspaceToolchainPinning {
                        acquire: Box::new(|_, _, _| Ok(())),
                        release: Box::new(|_, _| Ok(())),
                    }),
                    Some(credential_pinning(
                        store.clone(),
                        Box::new(OracleSecrets::installed()),
                    )),
                ),
        );
        let call = |method: &str, params: Value| {
            projects.handle(
                method,
                params.as_object().unwrap(),
                &|| "2026-09-25T00:00:00.000Z".into(),
                &|_| Ok(()),
            )
        };
        let register = |request: &str, tree: &str| {
            call(
                "workspace.project.register",
                json!({"registrationRequestId": request, "kind": "openharmony",
                       "root": root.join(tree).to_str().unwrap()}),
            )
            .unwrap()["projectRef"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let first = register("project", "source");
        let second = register("other", "other");
        // Startup records are sorted by project reference. Exercise both
        // orders without weakening the foreign-project credential refusal.
        let (project, other) = if (first > second) == signing_last {
            (first, second)
        } else {
            (second, first)
        };
        // The installed receipt binds the credential to the registered
        // project.
        let receipt = fs::read_to_string(root.join("preset/preset-v1.json")).unwrap();
        write(
            &root.join("preset/preset-v1.json"),
            receipt
                .replace("\"SignOracleProject\"", &format!("\"{project}\""))
                .as_bytes(),
        );
        let owner = CredentialOwner::new(SigningPresetStore::new(store.to_str().unwrap()));
        let credential = owner.current().unwrap().credential_ref;
        let signing = |request: &str, project: &str| {
            call(
                "workspace.preset.register",
                json!({"registrationRequestId": request, "projectRef": project,
                       "kind": "signing", "templateRef": "openharmony.local-sign@1",
                       "timeoutSeconds": "600",
                       "toolchainRef": format!("toolchain:sha256:{}", "a".repeat(64)),
                       "toolchainGeneration": "1", "credentialRef": credential}),
            )
        };
        // Another project's preset may not pin this credential; nothing is
        // written, so the store keeps answering.
        let foreign = signing("foreign", &other).unwrap_err();
        assert_eq!(
            (foreign.code.as_str(), foreign.message.as_str()),
            (
                "resourceConflict",
                format!(
                    "signing credential {credential} is bound to project {project}, not {other}"
                )
                .as_str()
            )
        );
        assert_eq!(
            call("workspace.preset.list", json!({"projectRef": other})).unwrap()["presets"],
            json!([])
        );
        assert_eq!(ledger_owners(&root), json!([]));
        let preset = signing("signing", &project).unwrap()["presetRef"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(ledger_owners(&root), json!([preset]));
        // A pin a retired state directory left behind.
        owner
            .acquire(&credential, "preset-retired", &OracleSecrets::installed())
            .unwrap();
        // The resolved DevEco toolchain: never run here, so the stand-in
        // stands for Node and the Hvigor script.
        let stand_in = root.join("tools/java.exe").to_str().unwrap().to_owned();
        let sdk = root.join("material").to_str().unwrap().to_owned();
        let toolchains = |_: &str, _: u64, _: &str| {
            Ok(ResolvedToolchain {
                node_path: stand_in.clone(),
                hvigor_script_path: stand_in.clone(),
                sdk_root_path: sdk.clone(),
                verified_resources: Vec::new(),
            })
        };
        let request = |label: &str| {
            json!({"requestJson": json!({
                "documentType": "runtime-operation-request",
                "idempotencyKey": format!("idempotency-{label}"),
                "inputs": {"projectRef": project, "signingPresetRef": preset,
                           "unsignedHapArtifactLease":
                               "lease-v1:job-input-hap:ART-81ae19b19ca7ea0d3ce99c554182c815"},
                "operation": {"id": "workspace.sign-openharmony-hap", "version": 1},
                "requestId": format!("request-{label}"),
                "requestedOutputs": ["derivedArtifacts"],
                "schemaVersion": "1.0.0",
                "target": {"targetId": "workspace-host"},
            }).to_string()})
        };
        let home = r"C:\nonexistent-home";
        // Without the credential owner the preset resolves to nothing, so it
        // is never applied and a Job naming it is refused as Swift refuses
        // it.
        let (unsigned, notes) = WorkspaceComposition::compose(
            Arc::clone(&projects),
            &root.0,
            home,
            oracle_now,
            &toolchains,
            None,
            None,
        )
        .unwrap();
        assert_eq!(notes.released_credential_owners, None);
        let owners = Owners {
            jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            capabilities: CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap(),
            holds: DeviceHolds::default(),
            workspace: unsigned,
            root,
        };
        let answer = owners.plan(&request("unsigned"));
        assert_eq!(
            answer,
            refused(
                "operationUnavailable",
                "workspace preset configuration changed; restart the Runtime before submitting \
                 a Job",
                Some(proven())
            )
        );
        assert_eq!(
            ledger_owners(&owners.root),
            json!([preset.as_str(), "preset-retired"])
        );
        // The restarted Runtime owns the default state directory.
        let (signed, notes) = WorkspaceComposition::compose(
            Arc::clone(&projects),
            &owners.root.0,
            home,
            oracle_now,
            &toolchains,
            Some(
                SigningSetup::with_secrets(
                    store.clone(),
                    owners.root.join("signing-attempts"),
                    Box::new(OracleSecrets::installed()),
                )
                .releasing_orphaned_owners(),
            ),
            None,
        )
        .unwrap();
        assert_eq!(
            notes.released_credential_owners,
            Some(Ok(vec!["preset-retired".to_owned()]))
        );
        assert!(notes.unadopted.is_empty(), "{:?}", notes.unadopted);
        assert_eq!(ledger_owners(&owners.root), json!([preset]));
        let owners = Owners {
            workspace: signed,
            ..owners
        };
        assert_eq!(owners.plan(&request("sign"))["ok"], true);
        let accepted = owners.submit(&request("sign"));
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        let run = owners.run(&job);
        assert_eq!(run["result"]["state"], "succeeded", "{run}");
        let result = owners.result(&job);
        let names: Vec<&str> = result["result"]["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|artifact| artifact["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["signed.hap", "signing-report.json"], "{result}");
        assert_eq!(
            fs::read_dir(owners.root.join("signing-attempts"))
                .unwrap()
                .count(),
            0
        );
        // Removing the preset releases its pin.
        call(
            "workspace.preset.remove",
            json!({"mutationRequestId": "remove", "projectRef": project,
                   "presetRef": preset, "expectedGeneration": "1"}),
        )
        .unwrap();
        assert_eq!(ledger_owners(&owners.root), json!([]));
        for path in every_file(&owners.root.0) {
            if path == owners.root.join("tools/java.exe") {
                continue;
            }
            secret_free(&path.display().to_string(), &fs::read(&path).unwrap());
        }
        owners.assert_reopened_readback(&[job]);
    }
}
