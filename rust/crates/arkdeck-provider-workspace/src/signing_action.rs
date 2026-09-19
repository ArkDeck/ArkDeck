//! Swift `WorkspaceOpenHarmonySigningAction` and
//! `OpenHarmonySigningAttemptPaths`: the durable typed action of
//! `workspace.sign-openharmony-hap@1` and its provider-owned attempt
//! directory. Both are persisted in the Job's action and decoded with
//! exactly Swift's keys. The argv is closed: no password option ever
//! appears; `-pwdInputMode 1` makes the signer ask for both on its terminal.
use crate::signing_preset::SigningPresetReceipt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;

/// Swift `OpenHarmonySigningAttemptPaths`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SigningAttemptPaths {
    pub directory: String,
    #[serde(rename = "signedHAP")]
    pub signed_hap: String,
    #[serde(rename = "certificateChainReadback")]
    pub certificate_chain_readback: String,
    #[serde(rename = "profileReadback")]
    pub profile_readback: String,
    #[serde(rename = "resultRecord")]
    pub result_record: String,
}

impl SigningAttemptPaths {
    /// Swift `OpenHarmonySigningAttemptStore.paths(jobID:)`: one directory
    /// per Job, named by the first 32 hex digits of the SHA-256 of its ID.
    pub fn for_job(root: &Path, job_id: &str) -> Self {
        let digest: String = Sha256::digest(job_id.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let directory = format!(
            "{}/{}",
            root.to_string_lossy().trim_end_matches('/'),
            &digest[..32]
        );
        Self {
            signed_hap: format!("{directory}/signed.hap"),
            certificate_chain_readback: format!("{directory}/certificate-chain.cer"),
            profile_readback: format!("{directory}/profile-readback.p7b"),
            result_record: format!("{directory}/signing-result.json"),
            directory,
        }
    }

    /// Swift `stagedUnsignedHAP`: hap-sign-tool selects its package path by
    /// the `.hap` suffix, which Artifact payload names do not carry.
    pub fn staged_unsigned_hap(&self) -> String {
        format!("{}/unsigned.hap", self.directory)
    }

    /// Swift `supportedCertificateChainReadback`: `verify-app` accepts only a
    /// `.cer` chain output; an early action's `.pem` sibling maps onto it.
    pub fn supported_certificate_chain_readback(&self) -> String {
        let legacy = format!("{}/certificate-chain.pem", self.directory);
        if self.certificate_chain_readback == legacy {
            format!("{}/certificate-chain.cer", self.directory)
        } else {
            self.certificate_chain_readback.clone()
        }
    }
}

/// Swift `WorkspaceOpenHarmonySigningAction`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SigningAction {
    #[serde(rename = "jobID")]
    pub job_id: String,
    #[serde(rename = "projectRef")]
    pub project_ref: String,
    #[serde(
        rename = "signingPresetRef",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub signing_preset_ref: Option<String>,
    pub preset: SigningPresetReceipt,
    #[serde(rename = "inputArtifactID")]
    pub input_artifact_id: String,
    #[serde(rename = "inputFilePath")]
    pub input_file_path: String,
    #[serde(rename = "inputSHA256")]
    pub input_sha256: String,
    #[serde(rename = "inputByteCount")]
    pub input_byte_count: u64,
    pub output: SigningAttemptPaths,
}

impl SigningAction {
    /// Swift `selectedSigningPresetRef`: older actions carried no preset
    /// reference because their fixed receipt ID was the public preset.
    pub fn selected_signing_preset_ref(&self) -> &str {
        self.signing_preset_ref
            .as_deref()
            .unwrap_or(&self.preset.preset_id)
    }

    /// Swift `signArguments`.
    pub fn sign_arguments(&self) -> Vec<String> {
        [
            "-jar",
            &self.preset.signer_jar.path,
            "sign-app",
            "-keyAlias",
            &self.preset.key_alias,
            "-signAlg",
            &self.preset.signing_algorithm,
            "-mode",
            "localSign",
            "-appCertFile",
            &self.preset.app_certificate.path,
            "-profileFile",
            &self.preset.signed_profile.path,
            "-inFile",
            &self.output.staged_unsigned_hap(),
            "-keystoreFile",
            &self.preset.keystore.path,
            "-outFile",
            &self.output.signed_hap,
            "-pwdInputMode",
            "1",
        ]
        .map(str::to_owned)
        .to_vec()
    }

    /// Swift `verifyArguments`.
    pub fn verify_arguments(&self) -> Vec<String> {
        [
            "-jar",
            &self.preset.signer_jar.path,
            "verify-app",
            "-inFile",
            &self.output.signed_hap,
            "-outCertChain",
            &self.output.supported_certificate_chain_readback(),
            "-outProfile",
            &self.output.profile_readback,
        ]
        .map(str::to_owned)
        .to_vec()
    }
}

/// Foundation `standardizedFileURL.path == path` for an absolute path.
pub(crate) fn is_standard_path(path: &str) -> bool {
    path.starts_with('/')
        && path.len() > 1
        && !path.ends_with('/')
        && path[1..]
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
}

#[cfg(test)]
mod tests {
    use super::is_standard_path;

    #[test]
    fn a_standard_absolute_path_has_no_dot_empty_or_trailing_component() {
        for good in [
            "/a",
            "/a/b.c",
            "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java",
        ] {
            assert!(is_standard_path(good), "{good}");
        }
        for bad in [
            "", "/", "a/b", "/a/", "/a//b", "/a/./b", "/a/../b", "/a/.", "/a/..",
        ] {
            assert!(!is_standard_path(bad), "{bad}");
        }
    }
}
