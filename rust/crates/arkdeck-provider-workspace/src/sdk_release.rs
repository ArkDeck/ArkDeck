//! Explicit host maintenance: generate and verify a bundle-bound SDK release
//! profile in private managed material before installing its signing preset.
use crate::{
    SigningError, SigningFileIdentity, foundation_resolved_path, measure, remeasure,
    sdk_release_profile::{application_chain, generate_profile},
    signing_install::SigningPresetConfiguration,
    signing_preset::{
        DEFAULT_PRESET_ID, SigningPresetStore, SigningSecrets, is_identifier,
        public_sdk_release_password,
    },
};
use arkdeck_platform::{
    PtyInteraction, PtyRequest, ToolLimits, ToolRequest, ToolTermination, VerifiedSource,
    VerifiedTool, wipe,
};
use serde_json::Value;
use std::{
    ffi::OsString,
    fs,
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub struct SdkReleaseConfiguration {
    pub project_ref: String,
    pub bundle_name: String,
    pub java_executable: PathBuf,
    pub sdk_root: PathBuf,
}

pub(crate) struct PreparedSdkRelease {
    pub configuration: SigningPresetConfiguration,
    directory: PathBuf,
    retained: bool,
}
impl PreparedSdkRelease {
    /// The owner's durable directory tracking now owns its cleanup. Call
    /// before attempting receipt publication, whose outcome can be unknown.
    pub fn retain_for_transaction(&mut self) {
        self.retained = true;
    }
}
impl Drop for PreparedSdkRelease {
    fn drop(&mut self) {
        if !self.retained {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
}

/// Runs only under the credential owner's guarded replacement lock.
pub(crate) fn prepare(
    store: &SigningPresetStore,
    configuration: &SdkReleaseConfiguration,
    secrets: &dyn SigningSecrets,
    timestamp: i64,
    track: &mut dyn FnMut(&Path) -> Result<(), SigningError>,
) -> Result<PreparedSdkRelease, SigningError> {
    if !is_identifier(&configuration.project_ref) {
        return Err(SigningError::invalid("projectRef is malformed"));
    }
    if !crate::sdk_release_profile::valid_bundle_name(&configuration.bundle_name) {
        return Err(SigningError::invalid("bundleName is malformed"));
    }
    let sdk = path_text(&configuration.sdk_root)?;
    if !crate::signing_action::is_standard_path(sdk) {
        return Err(SigningError::invalid(
            "OpenHarmony SDK root must be an explicit canonical absolute path",
        ));
    }
    if !configuration.sdk_root.is_dir() {
        return Err(SigningError::invalid("OpenHarmony SDK root is absent"));
    }
    if foundation_resolved_path(sdk).as_deref() != Some(sdk) {
        return Err(SigningError::invalid(
            "OpenHarmony SDK root must be an explicit canonical absolute path",
        ));
    }
    let library = configuration.sdk_root.join("toolchains/lib");
    let java = measure(
        path_text(&configuration.java_executable)?,
        "java",
        true,
        false,
    )?;
    let jar = measure_path(&library.join("hap-sign-tool.jar"), "SDK hapsigner JAR")?;
    let keystore = measure_path(&library.join("OpenHarmony.p12"), "SDK release keystore")?;
    let profile_cert = measure_path(
        &library.join("OpenHarmonyProfileRelease.pem"),
        "SDK release profile certificate",
    )?;
    let template = measure_path(
        &library.join("UnsgnedReleasedProfileTemplate.json"),
        "SDK release profile template",
    )?;
    // The owner has already created and locked its private root. Generated
    // material must keep the exact root spelling required by its validator.
    let root = path_text(store.root())?;
    if foundation_resolved_path(root).as_deref() != Some(root) {
        return Err(SigningError::unsafe_file(
            "signing material root is not canonical",
        ));
    }
    let token = crate::signing_install::new_envelope_account()?;
    let uuid = token.split_once("|secret-envelope-").unwrap().1;
    let directory = store.root().join(format!("sdk-release-{uuid}"));
    track(&directory)?;
    if let Some(previous) = store
        .load_validated(DEFAULT_PRESET_ID, false, secrets)
        .ok()
        .and_then(|receipt| receipt.managed_material_directory)
    {
        track(Path::new(&previous))?;
    }
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&directory)
        .map_err(|_| SigningError::io("cannot create private SDK signing material"))?;
    let prepared = PreparedSdkRelease {
        configuration: SigningPresetConfiguration {
            project_ref: configuration.project_ref.clone(),
            java_executable: configuration.java_executable.clone(),
            signer_jar: PathBuf::from(&jar.path),
            keystore: directory.join("OpenHarmony.p12"),
            app_certificate: directory.join("OpenHarmonyApplicationRelease.pem"),
            signed_profile: directory.join("release-profile.p7b"),
            key_alias: "openharmony application release".into(),
            managed_material_directory: Some(directory.clone()),
        },
        directory,
        retained: false,
    };
    let profile_copy = prepared.directory.join("OpenHarmonyProfileRelease.pem");
    write_private(&prepared.configuration.keystore, &read_pinned(&keystore)?)?;
    write_private(&profile_copy, &read_pinned(&profile_cert)?)?;
    let generated = generate_profile(
        &read_pinned(&template)?,
        &configuration.bundle_name,
        timestamp,
        uuid,
    )?;
    let unsigned = prepared.directory.join("release-profile.json");
    write_private(&unsigned, &generated.bytes)?;
    let chain = read_pinned(&profile_cert)?;
    let chain = std::str::from_utf8(&chain)
        .map_err(|_| SigningError::invalid("SDK release profile certificate is not UTF-8 PEM"))?;
    write_private(
        &prepared.configuration.app_certificate,
        &application_chain(chain, &generated.app_certificate)?,
    )?;
    #[cfg(test)]
    if FIXTURE_PROFILE.with(|fixture| fixture.get()) {
        write_private(&prepared.configuration.signed_profile, &generated.bytes)?;
        return Ok(prepared);
    }
    sign_profile(
        &java,
        &jar,
        &prepared.configuration.keystore,
        &profile_copy,
        &unsigned,
        &prepared.configuration.signed_profile,
    )?;
    verify_profile(
        &java,
        &jar,
        &prepared.configuration.signed_profile,
        &configuration.bundle_name,
        generated.not_before,
        generated.not_after,
    )?;
    Ok(prepared)
}

fn path_text(path: &Path) -> Result<&str, SigningError> {
    path.to_str()
        .ok_or_else(|| SigningError::unsafe_file("SDK signing path is not UTF-8"))
}
fn measure_path(path: &Path, role: &str) -> Result<SigningFileIdentity, SigningError> {
    measure(path_text(path)?, role, false, false)
}
fn retain(identity: &SigningFileIdentity) -> Result<VerifiedSource, SigningError> {
    VerifiedSource::open(
        Path::new(&identity.path),
        &identity.sha256,
        identity.byte_count,
    )
    .map_err(|_| SigningError::drift("SDK signing material"))
}
fn read_pinned(identity: &SigningFileIdentity) -> Result<Vec<u8>, SigningError> {
    remeasure(identity, "SDK signing material", false, false)?;
    let held = retain(identity)?;
    let mut bytes = Vec::new();
    fs::File::open(held.inode_path())
        .and_then(|file| file.take(identity.byte_count + 1).read_to_end(&mut bytes))
        .map_err(|_| SigningError::io("cannot read SDK signing material"))?;
    remeasure(identity, "SDK signing material", false, false)?;
    if bytes.len() as u64 != identity.byte_count {
        return Err(SigningError::drift("SDK signing material"));
    }
    Ok(bytes)
}
fn write_private(path: &Path, bytes: &[u8]) -> Result<(), SigningError> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| SigningError::io("cannot create SDK signing material"))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|_| SigningError::io("cannot write SDK signing material"))
}
fn java_tool(java: &SigningFileIdentity) -> Result<VerifiedTool, SigningError> {
    VerifiedTool::open(&java.path, &java.sha256).map_err(|_| SigningError::drift("java"))
}
fn sign_profile(
    java: &SigningFileIdentity,
    jar: &SigningFileIdentity,
    keystore: &Path,
    certificate: &Path,
    input: &Path,
    output: &Path,
) -> Result<(), SigningError> {
    let jar = retain(jar)?;
    let _input = retain(&measure_path(input, "generated release profile")?)?;
    let _keystore = retain(&measure(
        path_text(keystore)?,
        "managed SDK release keystore",
        false,
        true,
    )?)?;
    let _certificate = retain(&measure_path(
        certificate,
        "managed SDK profile certificate",
    )?)?;
    let args: Vec<OsString> = [
        "-jar",
        &jar.inode_path(),
        "sign-profile",
        "-mode",
        "localSign",
        "-keyAlias",
        "openharmony application profile release",
        "-signAlg",
        "SHA256withECDSA",
        "-profileCertFile",
        path_text(certificate)?,
        "-inFile",
        path_text(input)?,
        "-keystoreFile",
        path_text(keystore)?,
        "-outFile",
        path_text(output)?,
        "-pwdInputMode",
        "1",
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    let java = java_tool(java)?;
    let directory = input
        .parent()
        .unwrap()
        .canonicalize()
        .map_err(|_| SigningError::unsafe_file("SDK material directory is absent"))?;
    let password = public_sdk_release_password();
    let mut interactions = [
        PtyInteraction {
            expected_prompt: crate::signer::KEYSTORE_PROMPT.to_vec(),
            secret: password.as_bytes().to_vec(),
        },
        PtyInteraction {
            expected_prompt: crate::signer::KEY_PROMPT.to_vec(),
            secret: password.as_bytes().to_vec(),
        },
    ];
    let result = java.run_pty_exchange(
        &PtyRequest {
            arguments: &args,
            environment: &[],
            working_directory: Some(&directory),
            timeout: Duration::from_secs(120),
        },
        &interactions,
        1024 * 1024,
        &|| false,
    );
    for interaction in &mut interactions {
        wipe(&mut interaction.secret);
    }
    let result = result.map_err(|_| {
        SigningError::io("SDK release profile signer failed with closed diagnostic")
    })?;
    if result.termination != ToolTermination::Exited(0) || result.completed_interactions != 2 {
        return Err(SigningError::io(format!(
            "SDK release profile signer failed with closed diagnostic {}",
            result.failure_category.as_str()
        )));
    }
    let identity = measure_path(output, "signed SDK release profile")?;
    let held = retain(&identity)?;
    let file = fs::File::open(held.inode_path())
        .map_err(|_| SigningError::unsafe_file("signed SDK release profile cannot be opened"))?;
    let metadata = file
        .metadata()
        .map_err(|_| SigningError::unsafe_file("signed SDK release profile cannot be inspected"))?;
    if metadata.nlink() != 1 || metadata.uid() != arkdeck_platform::effective_user_id() {
        return Err(SigningError::unsafe_file(
            "signed SDK release profile must be an owned single-link file",
        ));
    }
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .and_then(|()| file.sync_all())
        .map_err(|_| SigningError::io("cannot secure signed SDK release profile"))?;
    remeasure(&identity, "signed SDK release profile", false, true)?;
    Ok(())
}
fn verify_profile(
    java: &SigningFileIdentity,
    jar: &SigningFileIdentity,
    profile: &Path,
    bundle: &str,
    not_before: i64,
    not_after: i64,
) -> Result<(), SigningError> {
    let jar = retain(jar)?;
    let _profile = retain(&measure_path(profile, "signed SDK release profile")?)?;
    let verification = profile.parent().unwrap().join("profile-verification.json");
    let args: Vec<OsString> = [
        "-jar",
        &jar.inode_path(),
        "verify-profile",
        "-inFile",
        path_text(profile)?,
        "-outFile",
        path_text(&verification)?,
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    let directory = profile
        .parent()
        .unwrap()
        .canonicalize()
        .map_err(|_| SigningError::unsafe_file("SDK material directory is absent"))?;
    let invalid =
        || SigningError::io("SDK release profile did not pass exact verify-profile readback");
    let result = java_tool(java)?
        .run_tool(
            &ToolRequest {
                arguments: &args,
                environment: &[],
                working_directory: Some(&directory),
                limits: ToolLimits {
                    timeout: Duration::from_secs(120),
                    capture_bytes: 256 * 1024,
                },
            },
            &|| false,
        )
        .map_err(|_| invalid())?;
    if result.termination != ToolTermination::Exited(0) || result.truncated {
        return Err(invalid());
    }
    let bytes = read_pinned(&measure_path(
        &verification,
        "SDK release profile verification",
    )?)?;
    let document: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if !crate::sdk_release_profile::verified_readback(&document, bundle, not_before, not_after) {
        return Err(invalid());
    }
    let _ = fs::remove_file(verification);
    Ok(())
}

/// One exact private-root child; never follow a link into source material.
pub(crate) fn remove_material(path: &Path) -> Result<bool, SigningError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(SigningError::io("cannot inspect pending SDK material")),
    };
    let result = if metadata.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    result.map_err(|_| SigningError::io("cannot remove pending SDK material"))?;
    Ok(true)
}

#[cfg(test)]
thread_local! {
    pub(crate) static FIXTURE_PROFILE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

#[cfg(test)]
mod publication_tests {
    use super::*;
    use crate::{
        credential_owner::{CredentialOwner, FINAL_LEDGER_FAILURE},
        signing_install::{PUBLICATION_FAILURE, SigningSecretInstallation},
        signing_preset::SecretPresence,
    };
    use arkdeck_platform::Secret;
    use serde_json::json;
    use std::{collections::BTreeMap, sync::Mutex};
    #[derive(Default)]
    struct Secrets(Mutex<BTreeMap<String, Secret>>);
    impl SigningSecrets for Secrets {
        fn read(&self, account: &str) -> Result<Secret, SigningError> {
            self.0
                .lock()
                .unwrap()
                .get(account)
                .cloned()
                .ok_or_else(|| SigningError::secret("fixture absent"))
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
    impl crate::signing_removal::SigningSecretRemoval for Secrets {
        fn remove_current(&self, account: &str) -> Result<bool, SigningError> {
            self.remove_envelope(account)
        }
        fn remove_legacy(&self, _: &str) -> Result<bool, SigningError> {
            Ok(false)
        }
    }
    struct Fixture {
        home: PathBuf,
        root: PathBuf,
        configuration: SdkReleaseConfiguration,
    }
    impl Fixture {
        fn new() -> Self {
            let home = PathBuf::from(format!(
                "/private/tmp/arkdeck-sdk-publication-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
            let home = PathBuf::from(foundation_resolved_path(home.to_str().unwrap()).unwrap());
            let sdk = home.join("sdk");
            let lib = sdk.join("toolchains/lib");
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&lib)
                .unwrap();
            let write = |name: &str, bytes: &[u8]| {
                let path = lib.join(name);
                fs::write(&path, bytes).unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            };
            write("hap-sign-tool.jar", b"fixture");
            write("OpenHarmony.p12", b"fixture-keystore");
            let pem = "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n";
            write("OpenHarmonyProfileRelease.pem", pem.repeat(3).as_bytes());
            write("UnsgnedReleasedProfileTemplate.json",&serde_json::to_vec(&json!({"type":"release","app-distribution-type":"os_integration","issuer":"pki_internal","bundle-info":{"apl":"normal","app-feature":"hos_normal_app","distribution-certificate":pem}})).unwrap());
            let java = home.join("java");
            fs::write(&java, b"not executed: publication-boundary unit fixture").unwrap();
            fs::set_permissions(&java, fs::Permissions::from_mode(0o700)).unwrap();
            FIXTURE_PROFILE.with(|fixture| fixture.set(true));
            Self {
                root: home.join("preset"),
                home,
                configuration: SdkReleaseConfiguration {
                    project_ref: "demo-app".into(),
                    bundle_name: "com.example.app".into(),
                    java_executable: java,
                    sdk_root: sdk,
                },
            }
        }
        fn owner(&self) -> CredentialOwner {
            CredentialOwner::new(SigningPresetStore::new(&self.root))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            FIXTURE_PROFILE.with(|fixture| fixture.set(false));
            PUBLICATION_FAILURE.with(|f| f.set(0));
            FINAL_LEDGER_FAILURE.with(|f| f.set(0));
            let _ = fs::remove_dir_all(&self.home);
        }
    }

    #[test]
    fn published_sdk_material_survives_unknown_receipt_and_failed_final_ledger() {
        for prior in [false, true] {
            for fault in [0, 1, 2] {
                let f = Fixture::new();
                let secrets = Secrets::default();
                let owner = f.owner();
                if prior {
                    owner
                        .install_sdk_release(
                            &f.configuration,
                            &secrets,
                            "2026-09-26T00:00:00Z",
                            1_000_000,
                        )
                        .unwrap();
                }
                if fault == 0 {
                    PUBLICATION_FAILURE.with(|failure| failure.set(1));
                } else {
                    FINAL_LEDGER_FAILURE.with(|failure| failure.set(fault));
                }
                assert!(
                    owner
                        .install_sdk_release(
                            &f.configuration,
                            &secrets,
                            "2026-09-26T01:00:00Z",
                            1_003_600
                        )
                        .is_err()
                );
                let receipt = owner
                    .store()
                    .load_validated(DEFAULT_PRESET_ID, false, &secrets)
                    .unwrap();
                for file in [
                    &receipt.keystore,
                    &receipt.app_certificate,
                    &receipt.signed_profile,
                ] {
                    assert!(Path::new(&file.path).is_file());
                }
                let ledger: Value = serde_json::from_slice(
                    &fs::read(f.root.join(crate::credential_owner::LEDGER_FILE)).unwrap(),
                )
                .unwrap();
                assert_eq!(ledger["state"], "replacingSecrets");
                assert!(
                    ledger["pendingMaterialDirectories"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|p| p.as_str() == receipt.managed_material_directory.as_deref())
                );
                assert!(owner.current().is_err());
                assert!(f.owner().current().is_err());
                if prior {
                    let repaired = owner
                        .install_sdk_release(
                            &f.configuration,
                            &secrets,
                            "2026-09-26T02:00:00Z",
                            1_007_200,
                        )
                        .unwrap();
                    assert_eq!(owner.current().unwrap(), repaired);
                }
                owner.remove(&secrets).unwrap();
                assert!(secrets.0.lock().unwrap().is_empty());
                assert!(
                    !fs::read_dir(&f.root)
                        .unwrap()
                        .filter_map(Result::ok)
                        .any(|entry| entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with("sdk-release-"))
                );
            }
        }
    }

    #[test]
    fn pending_material_cleanup_refuses_an_outside_directory_before_mutation() {
        let f = Fixture::new();
        let secrets = Secrets::default();
        let owner = f.owner();
        owner
            .install_sdk_release(
                &f.configuration,
                &secrets,
                "2026-09-26T00:00:00Z",
                1_000_000,
            )
            .unwrap();
        let ledger_path = f.root.join(crate::credential_owner::LEDGER_FILE);
        let mut ledger: Value = serde_json::from_slice(&fs::read(&ledger_path).unwrap()).unwrap();
        ledger["state"] = json!("replacingSecrets");
        ledger["pendingMaterialDirectories"] = json!([f.configuration.sdk_root]);
        let bytes = serde_json::to_vec(&ledger).unwrap();
        fs::write(&ledger_path, &bytes).unwrap();
        let count = secrets.0.lock().unwrap().len();
        assert!(owner.remove(&secrets).is_err());
        assert!(f.configuration.sdk_root.exists());
        assert_eq!(fs::read(&ledger_path).unwrap(), bytes);
        assert_eq!(secrets.0.lock().unwrap().len(), count);
    }
}
