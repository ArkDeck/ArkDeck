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
    previous: Option<PathBuf>,
    committed: bool,
}
impl PreparedSdkRelease {
    /// Call only after the owner has durably published a stable credential.
    pub fn commit(mut self) {
        self.committed = true;
        if let Some(old) = &self.previous
            && old != &self.directory
            && old.parent() == self.directory.parent()
        {
            // remove_dir_all never follows a symbolic link into source data.
            let _ = fs::remove_dir_all(old);
        }
    }
}
impl Drop for PreparedSdkRelease {
    fn drop(&mut self) {
        if !self.committed {
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
        previous: store
            .load_validated(DEFAULT_PRESET_ID, false, secrets)
            .ok()
            .and_then(|r| r.managed_material_directory)
            .map(PathBuf::from),
        directory,
        committed: false,
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
