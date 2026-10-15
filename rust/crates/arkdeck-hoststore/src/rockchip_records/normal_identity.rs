//! Immutable, owner-only observations. They record what the Runtime read;
//! callers cannot import them and execution always obtains a fresh read.
use super::*;
use arkdeck_provider_hdc::NormalHardwareIdentity;

pub(crate) struct NormalIdentitySubject<'a> {
    pub target_id: &'a str,
    pub binding_revision: i64,
    pub stable_identity_sha256: &'a str,
    pub provider_executable_sha256: &'a str,
    pub job_id: Option<&'a str>,
    pub step_id: Option<&'a str>,
}

pub(crate) fn persist_normal_hardware_identity(
    root: &Path,
    subject: &NormalIdentitySubject<'_>,
    observation: &NormalHardwareIdentity,
) -> Result<String, String> {
    if subject.target_id.is_empty()
        || subject.binding_revision <= 0
        || !swift_sha256(subject.stable_identity_sha256)
        || !swift_sha256(subject.provider_executable_sha256)
    {
        return Err("normalLoaderIdentity.observationSubjectInvalid".into());
    }
    let observed_at =
        crate::format_time::utc_now().ok_or("normalLoaderIdentity.observationClockUnavailable")?;
    let document = json!({
        "schemaVersion": "1.0.0",
        "recordKind": "normalLoaderHardwareIdentityObservation",
        "targetID": subject.target_id,
        "bindingRevision": subject.binding_revision,
        "stableIdentitySHA256": subject.stable_identity_sha256,
        "providerExecutableSHA256": subject.provider_executable_sha256,
        "jobID": subject.job_id,
        "stepID": subject.step_id,
        "observedAtUTC": observed_at,
        "summary": observation.summary(),
        "matchesBoundLoaderIdentity": observation.hardware_serial_sha256 == subject.stable_identity_sha256,
    });
    let bytes = crate::session_json::encode(&document)
        .map_err(|_| "normalLoaderIdentity.observationEncodingFailed")?;
    let digest = sha256_hex(&bytes);
    prepare_directory(root, true)?;
    let path = root.join(format!("{digest}.json"));
    match std::fs::symlink_metadata(&path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            write_record(&document, &path)?;
        }
        Err(_) => return Err("normalLoaderIdentity.observationRecordUnavailable".into()),
    }
    // A successful write alone is insufficient. Re-open using the private
    // record reader and check the exact canonical bytes before any command.
    if record_bytes(&path)? != bytes {
        return Err("normalLoaderIdentity.observationReadbackMismatch".into());
    }
    Ok(digest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Root(PathBuf);

    impl Root {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = crate::test_private::temporary_root().join(format!(
                "arkdeck-normal-identity-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            crate::test_private::create_private_directory(&path);
            Self(path)
        }
    }

    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn observation() -> NormalHardwareIdentity {
        NormalHardwareIdentity {
            normal_identity_sha256: sha256_hex(b"normal-private-key"),
            hardware_serial_sha256: sha256_hex(b"0123456789abcdef"),
            usb_topology: "42".into(),
            connector_identity_sha256: "d".repeat(64),
            stdout_sha256: sha256_hex(b"Serial: 0123456789abcdef\n"),
            stdout_byte_count: 25,
        }
    }

    #[test]
    fn observation_is_private_durable_content_addressed_and_keeps_its_subject() {
        let root = Root::new();
        let observation = observation();
        let provider = "c".repeat(64);
        let subject = NormalIdentitySubject {
            target_id: "TGT-PROOF",
            binding_revision: 7,
            stable_identity_sha256: &observation.hardware_serial_sha256,
            provider_executable_sha256: &provider,
            job_id: Some("job-proof"),
            step_id: Some("enter-loader"),
        };
        let digest = persist_normal_hardware_identity(&root.0, &subject, &observation).unwrap();
        let path = root.0.join(format!("{digest}.json"));
        // This reader rejects public, linked and non-regular records on both hosts.
        let bytes = record_bytes(&path).unwrap();
        assert_eq!(sha256_hex(&bytes), digest);
        let document: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(document["targetID"], "TGT-PROOF");
        assert_eq!(document["bindingRevision"], 7);
        assert_eq!(document["jobID"], "job-proof");
        assert_eq!(document["stepID"], "enter-loader");
        assert_eq!(document["matchesBoundLoaderIdentity"], true);
        assert_eq!(
            document["summary"]["hardwareSerialSha256"],
            observation.hardware_serial_sha256
        );
        let text = std::str::from_utf8(&bytes).unwrap();
        for secret in ["0123456789abcdef", "normal-private-key", "Serial:"] {
            assert!(!text.contains(secret));
        }
        let other = NormalIdentitySubject {
            binding_revision: 8,
            ..subject
        };
        let next = persist_normal_hardware_identity(&root.0, &other, &observation).unwrap();
        assert_ne!(next, digest);
        assert_eq!(
            record_bytes(&path).unwrap(),
            bytes,
            "later observations cannot rewrite history"
        );
    }

    #[test]
    fn invalid_subject_or_unwritable_record_root_never_returns_proof() {
        let root = Root::new();
        let observation = observation();
        let provider = "c".repeat(64);
        let mut subject = NormalIdentitySubject {
            target_id: "TGT-PROOF",
            binding_revision: 0,
            stable_identity_sha256: &observation.hardware_serial_sha256,
            provider_executable_sha256: &provider,
            job_id: None,
            step_id: None,
        };
        assert!(persist_normal_hardware_identity(&root.0, &subject, &observation).is_err());
        assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 0);
        subject.binding_revision = 1;
        let blocked = root.0.join("a-file-is-not-a-directory");
        write_record(&json!({"keep": true}), &blocked).unwrap();
        let original = record_bytes(&blocked).unwrap();
        assert!(persist_normal_hardware_identity(&blocked, &subject, &observation).is_err());
        assert_eq!(record_bytes(&blocked).unwrap(), original);
    }
}
