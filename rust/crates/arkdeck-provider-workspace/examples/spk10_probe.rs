//! SPK-10 host probe (TASK-XPA-015). Not a test: it runs against the real
//! Java launcher and hap-sign-tool of an installed DevEco Studio, and reads a
//! daemon executable, so it is run by hand on the reference host and its
//! output goes into `evidence/runs/TASK-XPA-015/spk-10-run.md`. Nothing it
//! prints is a secret: passwords stay in `Secret` buffers and reach the signer
//! only through its terminal.
//!
//! ```text
//! spk10_probe fingerprint <daemon executable>
//! spk10_probe sign <work dir> <runs> <password source> <java> <jar> <keystore>
//!                  <certificate> <profile> <key alias> <unsigned hap>
//! spk10_probe verify <work dir> <java> <jar> <keystore> <certificate> <profile>
//!                    <key alias> <signed hap>
//! ```
//!
//! `<password source>` is `public-sdk` (the published SDK password) or
//! `deveco:<build-profile.json5>` (both ciphertexts decoded through the
//! DevEco material beside the keystore, exactly as `runtime signing install
//! --build-profile` decodes them).
#[cfg(target_os = "macos")]
fn main() {
    macos::main();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("spk10_probe runs on macOS only");
    std::process::exit(2);
}

#[cfg(target_os = "macos")]
mod macos {
    use arkdeck_platform::Secret;
    use arkdeck_provider_workspace::deveco_password::decode_if_needed;
    use arkdeck_provider_workspace::secret_envelope::encode_envelope;
    use arkdeck_provider_workspace::signer::{sign_hap, verify_and_record};
    use arkdeck_provider_workspace::signing_action::{SigningAction, SigningAttemptPaths};
    use arkdeck_provider_workspace::signing_preset::{
        DEFAULT_PRESET_ID, KEYCHAIN_ACCESS_SCHEMA, RECEIPT_SCHEMA, SecretPresence,
        SigningPresetReceipt, SigningPresetStore, SigningSecrets,
    };
    use arkdeck_provider_workspace::{SigningError, foundation_resolved_path, measure};
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    const ENVELOPE_ACCOUNT: &str =
        "openharmony-release@1|secret-envelope-6f1c9a52-0b3e-4d7a-8e25-94c1f0d3b7a6";

    /// The envelope held in memory for the probe, as the Keychain holds it.
    struct MemorySecrets(Secret);

    impl SigningSecrets for MemorySecrets {
        fn read(&self, account: &str) -> Result<Secret, SigningError> {
            if account == ENVELOPE_ACCOUNT {
                Ok(self.0.clone())
            } else {
                Err(SigningError::SecretUnavailable("no such account".into()))
            }
        }
        fn presence(&self, account: &str) -> SecretPresence {
            if account == ENVELOPE_ACCOUNT {
                SecretPresence::Present
            } else {
                SecretPresence::Absent
            }
        }
        fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
            Ok(None)
        }
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn fail(message: impl std::fmt::Display) -> ! {
        eprintln!("spk10_probe: {message}");
        std::process::exit(1);
    }

    /// Canonical in Foundation's sense, the spelling the receipt pins.
    fn canonical(path: &str) -> String {
        foundation_resolved_path(path).unwrap_or_else(|| fail(format!("cannot resolve {path}")))
    }

    fn receipt(files: &[String], alias: &str) -> SigningPresetReceipt {
        let measured = |path: &String, role: &str, executable: bool, private: bool| {
            measure(&canonical(path), role, executable, private)
                .unwrap_or_else(|error| fail(format!("{role}: {error}")))
        };
        SigningPresetReceipt {
            schema_version: RECEIPT_SCHEMA.into(),
            installed_at_utc: "2026-09-19T00:00:00Z".into(),
            preset_id: DEFAULT_PRESET_ID.into(),
            project_ref: "spk10-probe".into(),
            java_executable: measured(&files[0], "java", true, false),
            signer_jar: measured(&files[1], "signer JAR", false, false),
            keystore: measured(&files[2], "keystore", false, true),
            app_certificate: measured(&files[3], "app certificate", false, false),
            signed_profile: measured(&files[4], "signed profile", false, false),
            key_alias: alias.into(),
            signing_algorithm: "SHA256withECDSA".into(),
            keystore_password_account: format!("{DEFAULT_PRESET_ID}|keystore"),
            key_password_account: format!("{DEFAULT_PRESET_ID}|key"),
            secret_envelope_account: Some(ENVELOPE_ACCOUNT.into()),
            superseded_envelope_accounts: None,
            trusted_daemon_application_sha256: None,
            keychain_access_schema: Some(KEYCHAIN_ACCESS_SCHEMA.into()),
            managed_material_directory: None,
        }
    }

    fn private_directory(path: &Path) {
        std::fs::create_dir_all(path).unwrap_or_else(|error| fail(error));
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .unwrap_or_else(|error| fail(error));
    }

    /// The quoted value after `"<key>"` in a DevEco build profile.
    fn build_profile_value(text: &str, key: &str) -> String {
        let quoted = format!("\"{key}\"");
        let start = text
            .find(&quoted)
            .unwrap_or_else(|| fail(format!("{key} is absent from the build profile")));
        let rest = &text[start + quoted.len()..];
        let open = rest
            .find('"')
            .unwrap_or_else(|| fail(format!("{key} has no value")));
        let rest = &rest[open + 1..];
        let close = rest
            .find('"')
            .unwrap_or_else(|| fail(format!("{key} is unterminated")));
        rest[..close].to_owned()
    }

    fn passwords(source: &str, keystore: &str) -> (Secret, Secret) {
        if source == "public-sdk" {
            return (Secret::from_slice(b"123456"), Secret::from_slice(b"123456"));
        }
        let profile = source
            .strip_prefix("deveco:")
            .unwrap_or_else(|| fail("the password source is public-sdk or deveco:<path>"));
        let text = std::fs::read_to_string(profile).unwrap_or_else(|error| fail(error));
        if canonical(&build_profile_value(&text, "storeFile")) != canonical(keystore) {
            fail("the build profile names another keystore");
        }
        let decode = |key: &str| {
            decode_if_needed(
                build_profile_value(&text, key).as_bytes(),
                Path::new(keystore),
            )
            .unwrap_or_else(|error| fail(format!("{key}: {error}")))
        };
        (decode("storePassword"), decode("keyPassword"))
    }

    fn action(
        receipt: &SigningPresetReceipt,
        work: &Path,
        job: &str,
        input: &Path,
    ) -> SigningAction {
        let bytes = std::fs::read(input).unwrap_or_else(|error| fail(error));
        SigningAction {
            job_id: job.into(),
            project_ref: receipt.project_ref.clone(),
            signing_preset_ref: Some("spk10-probe-signing".into()),
            preset: receipt.clone(),
            input_artifact_id: "ART-SPK10-INPUT".into(),
            input_file_path: input.to_str().unwrap().into(),
            input_sha256: hex(&Sha256::digest(&bytes)),
            input_byte_count: bytes.len() as u64,
            // The signer's working directory is physical, as the tool runner
            // requires; under `/private/tmp` that differs from Foundation's
            // spelling of the same directory.
            output: SigningAttemptPaths::for_job(
                &std::fs::canonicalize(work.join("attempts")).unwrap_or_else(|error| fail(error)),
                job,
            ),
        }
    }

    pub fn main() {
        let arguments: Vec<String> = std::env::args().skip(1).collect();
        match arguments.first().map(String::as_str) {
            Some("fingerprint") if arguments.len() == 2 => {
                let started = std::time::Instant::now();
                let fingerprint =
                    arkdeck_platform::trusted_daemon_fingerprint(Path::new(&arguments[1]))
                        .unwrap_or_else(|error| fail(error));
                println!(
                    "{}",
                    json!({"daemonFingerprint": fingerprint, "seconds": started.elapsed().as_secs_f64()})
                );
            }
            Some("sign") if arguments.len() == 11 => {
                let work = PathBuf::from(canonical(&arguments[1]));
                let runs: usize = arguments[2].parse().unwrap_or_else(|_| fail("runs"));
                let receipt = receipt(&arguments[4..9], &arguments[9]);
                let preset_root = work.join("preset");
                private_directory(&preset_root);
                private_directory(&work.join("attempts"));
                std::fs::write(
                    preset_root.join("preset-v1.json"),
                    serde_json::to_vec_pretty(&receipt).unwrap(),
                )
                .unwrap_or_else(|error| fail(error));
                let (keystore, key) = passwords(&arguments[3], &arguments[6]);
                let secrets = MemorySecrets(encode_envelope(keystore.as_bytes(), key.as_bytes()));
                drop((keystore, key));
                let store = SigningPresetStore::new(&preset_root);
                let input = PathBuf::from(canonical(&arguments[10]));
                let mut results = Vec::new();
                for run in 0..runs {
                    let job = format!(
                        "spk10-real-{run}-{}",
                        hex(&arkdeck_platform::random_bytes::<4>().unwrap())
                    );
                    let action = action(&receipt, &work, &job, &input);
                    match sign_hap(&action, &store, &secrets, &|| false) {
                        Ok(signed) => results.push(json!({
                            "job": job,
                            "seconds": signed.duration.as_secs_f64(),
                            "summary": signed.summary,
                        })),
                        Err(failure) => {
                            results.push(json!({"job": job, "failure": format!("{failure:?}")}))
                        }
                    }
                }
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({
                        "passwordSource": arguments[3].split(':').next(),
                        "input": {"sha256": hex(&Sha256::digest(std::fs::read(&input).unwrap())), "byteCount": std::fs::metadata(&input).unwrap().len()},
                        "runs": results,
                    }))
                    .unwrap()
                );
            }
            Some("verify") if arguments.len() == 9 => {
                let work = PathBuf::from(canonical(&arguments[1]));
                let receipt = receipt(&arguments[2..7], &arguments[7]);
                private_directory(&work.join("attempts"));
                let signed = PathBuf::from(canonical(&arguments[8]));
                let job = format!(
                    "spk10-verify-{}",
                    hex(&arkdeck_platform::random_bytes::<4>().unwrap())
                );
                let action = action(&receipt, &work, &job, &signed);
                private_directory(Path::new(&action.output.directory));
                std::fs::copy(&signed, &action.output.signed_hap)
                    .unwrap_or_else(|error| fail(error));
                let summary = verify_and_record(&action).unwrap_or_else(|error| fail(error));
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({"job": job, "summary": summary})).unwrap()
                );
            }
            _ => fail("usage: see the example's documentation"),
        }
    }
}
