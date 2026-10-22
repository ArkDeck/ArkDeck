mod tests {
    use super::*;
    use crate::capture_files::Landed;
    use std::path::Path;
    use std::time::Duration;

    const KEY: &str = "150100424a544e4600";
    const JOB: &str = "job-186c8faffebe3b9cb8b0150ef9a645b2";
    const LEASE: &str = "lease-v1:job-input-native-library:ART-469c10579b3c5461ab4d0a891c316397";
    const ARTIFACT: &str = "ART-469c10579b3c5461ab4d0a891c316397";
    const LIBRARY_SHA256: &str = "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53";
    const HELPER_SHA256: &str = "86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1";
    const REPLACED: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn library() -> Vec<u8> {
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../tests/fixtures/deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
        ))
        .unwrap()
    }

    fn resolved() -> ResolvedArtifact {
        ResolvedArtifact {
            artifact_id: ARTIFACT.into(),
            sha256: LIBRARY_SHA256.into(),
            path: PathBuf::from(
                "/private/tmp/arkdeck-hdc-oracle/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
            ),
        }
    }

    fn helper() -> CodeSignHelper {
        CodeSignHelper {
            facts: CodeSignHelperFacts {
                abi: NativeAbi::Arm64,
                build_id: "4e6f5302a74bab03fa0ecb72a4f96b9b4fa45323".into(),
                sha256: HELPER_SHA256.into(),
                byte_count: 214_016,
            },
            host_path: PathBuf::from(
                "/private/tmp/arkdeck-hdc-oracle/host/arkdeck-code-sign-enable",
            ),
        }
    }

    fn inputs(extra: &[(&str, &str)]) -> Map<String, Value> {
        let mut inputs = json!({
            "libraryArtifactLease": LEASE, "targetBundle": "com.example.demo",
            "libraryLogicalName": "libexample.so", "expectedABI": "arm64-v8a",
        });
        for (key, value) in extra {
            inputs[*key] = json!(value);
        }
        inputs.as_object().cloned().unwrap()
    }

    fn deployment() -> Deployment {
        Deployment::from_inputs(
            &inputs(&[]),
            JOB,
            Some(&resolved()),
            &library(),
            Some(&helper()),
        )
        .unwrap()
    }

    fn sub(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(5),
        }
    }

    fn with_stderr(stdout: &str, stderr: &str, exit_status: i32) -> Receipt {
        Receipt {
            stderr: stderr.as_bytes().to_vec(),
            ..sub(stdout, exit_status)
        }
    }

    fn receipt(subprocesses: Vec<Receipt>) -> FileReceipt {
        FileReceipt {
            subprocesses,
            landed: None::<Landed>,
        }
    }

    fn argv(action: &NativeAction, step: &str) -> Vec<Vec<String>> {
        let FilePlan::Sequence(invocations) = action
            .lower(
                step,
                Some(KEY),
                Some(&resolved()),
                Some(588),
                Some(&helper()),
            )
            .unwrap()
        else {
            panic!("a sequence")
        };
        invocations
            .into_iter()
            .map(|invocation| invocation.arguments)
            .collect()
    }

    /// The namespace: derived from the bundle, the ABI and the Job; persisted
    /// paths accepted only when they are exactly that (the historical arm64
    /// directory and the legacy sibling staging included).
    #[test]
    fn the_namespace_is_derived_and_persisted_paths_must_match_it() {
        let deployment = deployment();
        let stg = "/data/app/el2/100/base/com.example.demo/haps/entry/files/arkdeck-native/job-186c8faffebe3b9cb8b0150ef9a645b2";
        assert_eq!(
            deployment.directory_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm"
        );
        assert_eq!(
            deployment.target_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/libexample.so"
        );
        assert_eq!(
            deployment.loader_visible_path,
            "/data/storage/el1/bundle/libs/arm/libexample.so"
        );
        assert_eq!(deployment.staging_directory_path, stg);
        assert!(deployment.staging_directory_is_job_owned);
        assert_eq!(
            deployment.staging_path,
            format!("{stg}/libexample.so.staging")
        );
        assert_eq!(
            deployment.backup_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/.libexample.so.arkdeck-job-186c8faffebe3b9cb8b0150ef9a645b2.backup"
        );
        assert_eq!(
            deployment.rollback_staging_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/.libexample.so.arkdeck-job-186c8faffebe3b9cb8b0150ef9a645b2.rollback"
        );
        assert_eq!(
            deployment.code_sign_helper_remote_path.as_deref(),
            Some(format!("{stg}/arkdeck-code-sign-enable").as_str())
        );
        assert_eq!(
            deployment.native_libraries_root_path(),
            "/data/app/el1/bundle/public/com.example.demo/libs"
        );
        let rebuild = |exact: &ExactPaths| {
            Deployment::new(
                JOB,
                LEASE,
                ARTIFACT,
                BundleReference::new("com.example.demo").unwrap(),
                "libexample.so",
                deployment.artifact_facts.clone(),
                RestartProfile::RestartAbility,
                VerificationProfile::HashProcessAndMaps,
                RollbackPolicy::AutoRollback,
                deployment.code_sign_helper_facts.clone(),
                Some(exact),
            )
        };
        let exact = deployment.exact_paths();
        assert_eq!(rebuild(&exact).unwrap(), deployment);
        let mut historical = exact.clone();
        historical.directory_path =
            "/data/app/el1/bundle/public/com.example.demo/libs/arm64".into();
        historical.target_path = format!("{}/libexample.so", historical.directory_path);
        historical.loader_visible_path = "/data/storage/el1/bundle/libs/arm64/libexample.so".into();
        historical.backup_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.backup",
            historical.directory_path
        );
        historical.rollback_staging_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.rollback",
            historical.directory_path
        );
        assert_eq!(
            rebuild(&historical).unwrap().directory_path,
            historical.directory_path
        );
        let mut legacy = exact.clone();
        legacy.staging_directory_path = None;
        legacy.staging_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.staging",
            exact.directory_path
        );
        legacy.code_sign_helper_remote_path = None;
        let legacy_deployment = rebuild(&legacy).unwrap();
        assert!(!legacy_deployment.staging_directory_is_job_owned);
        assert_eq!(
            legacy_deployment.staging_directory_path,
            exact.directory_path
        );
        let mut foreign = exact.clone();
        foreign.backup_path = "/data/local/tmp/backup".into();
        assert_eq!(
            rebuild(&foreign).unwrap_err().to_string(),
            "unsupportedAction(\"persisted native deployment paths escape the provider-owned namespace\")"
        );
        let mut other_abi = exact;
        other_abi.directory_path =
            "/data/app/el1/bundle/public/com.example.demo/libs/x86_64".into();
        assert!(rebuild(&other_abi).is_err());
        let bad_job = Deployment::new(
            "job/1",
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "libexample.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        );
        assert_eq!(
            bad_job.unwrap_err().to_string(),
            "unsupportedAction(\"native deployment job identity is invalid\")"
        );
        let bad_name = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "example.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        );
        assert_eq!(
            bad_name.unwrap_err().to_string(),
            "unsupportedAction(\"native library logical name is invalid\")"
        );
        let no_helper = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "libexample.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        )
        .unwrap();
        assert_eq!(no_helper.code_sign_helper_remote_path, None);
    }

    /// Swift's admission over the inputs, in its order of refusals.
    #[test]
    fn admission_refuses_what_swift_refuses_in_its_order() {
        let refused = |inputs: Map<String, Value>,
                       resolved: Option<&ResolvedArtifact>,
                       bytes: &[u8],
                       helper: Option<&CodeSignHelper>| {
            Deployment::from_inputs(&inputs, JOB, resolved, bytes, helper)
                .unwrap_err()
                .to_string()
        };
        let bytes = library();
        let mut missing = inputs(&[]);
        missing.remove("libraryArtifactLease");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"libraryArtifactLease input is required\")"
        );
        let mut missing = inputs(&[]);
        missing.remove("targetBundle");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"targetBundle input is required\")"
        );
        let mut missing = inputs(&[]);
        missing.remove("libraryLogicalName");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"libraryLogicalName input is required\")"
        );
        assert_eq!(
            refused(
                inputs(&[("expectedABI", "mips")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"expectedABI input is invalid\")"
        );
        assert_eq!(
            refused(
                inputs(&[("restartProfile", "reboot")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"native deployment profile is invalid\")"
        );
        assert_eq!(
            refused(
                inputs(&[("restartProfile", "restartProcess")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"restartProcess has no complete app-owned restart/readback plan; refusing before authorization\")"
        );
        assert_eq!(
            refused(inputs(&[]), None, &bytes, Some(&helper())),
            "unsupportedAction(\"native deployment requires an engine-resolved Artifact lease\")"
        );
        let other = ResolvedArtifact {
            artifact_id: "ART-other".into(),
            ..resolved()
        };
        assert_eq!(
            refused(inputs(&[]), Some(&other), &bytes, Some(&helper())),
            "unsupportedAction(\"native deployment requires an engine-resolved Artifact lease\")"
        );
        assert_eq!(
            refused(
                inputs(&[("expectedABI", "x86_64")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"native library ABI arm64-v8a does not match expected x86_64\")"
        );
        let drifted = ResolvedArtifact {
            sha256: "0".repeat(64),
            ..resolved()
        };
        assert_eq!(
            refused(inputs(&[]), Some(&drifted), &bytes, Some(&helper())),
            "unsupportedAction(\"leased native Artifact bytes drifted during materialization\")"
        );
        assert_eq!(
            refused(inputs(&[]), Some(&resolved()), &bytes, None),
            "unsupportedAction(\"native deployment code-sign helper is unavailable\")"
        );
        let weaker = Deployment::from_inputs(
            &inputs(&[
                ("verificationProfile", "hashOnly"),
                ("rollbackPolicy", "retainBackup"),
            ]),
            JOB,
            Some(&resolved()),
            &bytes,
            Some(&helper()),
        )
        .unwrap();
        assert_eq!(weaker.verification_profile, VerificationProfile::HashOnly);
        assert_eq!(weaker.rollback_policy, RollbackPolicy::RetainBackup);
        assert_eq!(
            deployment().verification_profile,
            VerificationProfile::HashProcessAndMaps,
            "the default is at least the Catalog's"
        );
    }

    /// Every step's action, the shape of every lowering, and the refusals
    /// of a send or an inspection without what it needs.
    #[test]
    fn steps_map_to_actions_and_every_action_lowers_to_swift_s_sequence() {
        let deployment = deployment();
        let counts = [
            ("send-to-staging", 5),
            ("verify-remote-staging", 2),
            ("backup-current-version", 8),
            ("atomic-publish", 6),
            ("restart-target", 4),
            ("start-target", 3),
            ("verify-loaded-library", 5),
            ("cleanup-staging-and-backup", 10),
            ("cleanup-native-library-compensation", 10),
            ("rollback-native-library", 13),
        ];
        for (step, count) in counts {
            let action = NativeAction::for_step(step, &deployment).unwrap().unwrap();
            assert_eq!(argv(&action, step).len(), count, "{step}");
            assert!(
                argv(&action, step)
                    .iter()
                    .all(|arguments| arguments[..2] == ["-t".to_owned(), KEY.to_owned()])
            );
        }
        for step in ["verify-elf-locally", "hash-library", "finalize-session"] {
            assert_eq!(NativeAction::for_step(step, &deployment).unwrap(), None);
        }
        assert_eq!(
            NativeAction::for_step("other", &deployment)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"other has no app-owned native-library action\")"
        );
        let send = NativeAction::SendToStaging(deployment.clone());
        let stg = &deployment.staging_directory_path;
        assert_eq!(
            argv(&send, "send-to-staging"),
            vec![
                ["-t", KEY, "shell", "mkdir", "-p", stg].map(str::to_owned).to_vec(),
                ["-t", KEY, "file", "send", "/private/tmp/arkdeck-hdc-oracle/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397", &deployment.staging_path].map(str::to_owned).to_vec(),
                ["-t", KEY, "file", "send", "/private/tmp/arkdeck-hdc-oracle/host/arkdeck-code-sign-enable", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
                ["-t", KEY, "shell", "chmod", "700", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
                ["-t", KEY, "shell", "sha256sum", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
            ]
        );
        let FilePlan::Sequence(invocations) = send
            .lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(588),
                Some(&helper()),
            )
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![30, 300, 60, 30, 30]
        );
        assert!(
            invocations
                .iter()
                .all(|invocation| !invocation.continue_after_non_zero)
        );
        assert_eq!(
            send.lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(587),
                Some(&helper())
            )
            .unwrap_err(),
            "unsupportedAction(\"native send requires the same engine-resolved Artifact and a job-owned staging directory\")"
        );
        assert!(
            send.lower("send-to-staging", Some(KEY), None, None, Some(&helper()))
                .is_err()
        );
        assert!(
            send.lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(588),
                None
            )
            .is_err()
        );
        assert!(
            send.lower(
                "send-to-staging",
                None,
                Some(&resolved()),
                Some(588),
                Some(&helper())
            )
            .unwrap_err()
            .contains("factsUnavailable")
        );
        let backup = NativeAction::Backup(deployment.clone());
        let FilePlan::Sequence(invocations) =
            backup.lower("b", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.continue_after_non_zero)
                .collect::<Vec<_>>(),
            vec![false, false, false, false, false, false, false, true]
        );
        assert_eq!(
            invocations[7].arguments[2..],
            [
                "shell",
                "ls",
                "-la",
                "/data/app/el1/bundle/public/com.example.demo/libs"
            ]
            .map(str::to_owned)
        );
        let publish = NativeAction::Publish(deployment.clone());
        let FilePlan::Sequence(invocations) =
            publish.lower("p", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations[2].arguments[2..],
            [
                "shell",
                &format!("{stg}/arkdeck-code-sign-enable"),
                "publish",
                &deployment.staging_path,
                &deployment.target_path,
                &deployment.rollback_staging_path
            ]
            .map(str::to_owned)
        );
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| (
                    invocation.continue_after_non_zero,
                    invocation.timeout.as_secs()
                ))
                .collect::<Vec<_>>(),
            vec![
                (false, 15),
                (true, 30),
                (false, 60),
                (false, 30),
                (true, 30),
                (false, 15)
            ]
        );
        let stop = NativeAction::StopTarget(deployment.clone());
        let FilePlan::Sequence(invocations) = stop.lower("s", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![60, 30, 5, 30]
        );
        let cleanup = NativeAction::Cleanup(deployment.clone());
        let lines = argv(&cleanup, "c");
        assert_eq!(lines[2][2..], ["shell", "rmdir", stg].map(str::to_owned));
        assert_eq!(
            lines[9][2..],
            ["shell", "ls", "-ld", &deployment.backup_path].map(str::to_owned)
        );
        let mut retained = deployment.clone();
        retained.rollback_policy = RollbackPolicy::RetainBackup;
        assert_eq!(argv(&NativeAction::Cleanup(retained), "c").len(), 8);
        let rollback = NativeAction::Rollback(deployment.clone());
        let lines = argv(&rollback, "r");
        assert_eq!(
            lines[6][2..],
            [
                "shell",
                "ln",
                &deployment.backup_path,
                &deployment.rollback_staging_path
            ]
            .map(str::to_owned)
        );
        assert_eq!(
            lines[12][2..],
            [
                "shell",
                "grep",
                "-F",
                &deployment.loader_visible_path,
                "/proc/*/maps"
            ]
            .map(str::to_owned)
        );
        let FilePlan::Sequence(invocations) =
            rollback.lower("r", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert!(
            !invocations[0].continue_after_non_zero
                && invocations[1..]
                    .iter()
                    .all(|invocation| invocation.continue_after_non_zero)
        );
        let mut hash_only = deployment.clone();
        hash_only.verification_profile = VerificationProfile::HashOnly;
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only.clone(), Inspection::TargetLoaded),
                "v"
            )
            .len(),
            3
        );
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only.clone(), Inspection::RollbackRestored),
                "v"
            )
            .len(),
            3
        );
        hash_only.verification_profile = VerificationProfile::HashAndProcess;
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only, Inspection::TargetLoaded),
                "v"
            )
            .len(),
            4
        );
        let mut helperless = deployment.clone();
        helperless.code_sign_helper_remote_path = None;
        assert_eq!(
            NativeAction::Inspect(helperless.clone(), Inspection::TargetLoaded)
                .lower("v", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native loader inspection has no persisted code-sign helper path\")"
        );
        assert_eq!(
            NativeAction::Inspect(helperless.clone(), Inspection::TargetMatchesArtifact)
                .lower("v", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native target inspection has no persisted code-sign helper path\")"
        );
        assert_eq!(
            NativeAction::Publish(helperless)
                .lower("p", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native publish has no persisted code-sign helper identity\")"
        );
        for (inspection, count) in [
            (Inspection::StagingMatchesArtifact, 2),
            (Inspection::BackupMatchesTarget, 2),
            (Inspection::TargetMatchesArtifact, 3),
            (Inspection::TargetStopped, 1),
            (Inspection::TargetStarted, 1),
            (Inspection::CleanupComplete, 5),
            (Inspection::RollbackRestored, 4),
        ] {
            assert_eq!(
                argv(&NativeAction::Inspect(deployment.clone(), inspection), "v").len(),
                count,
                "{inspection:?}"
            );
        }
    }

    /// The journal form: one object for every kind, the inspection's
    /// expectation added.
    #[test]
    fn persisted_forms_follow_swift() {
        let deployment = deployment();
        let (kind, arguments) = NativeAction::Publish(deployment.clone()).persisted();
        assert_eq!(kind, "hdc.publishNativeLibrary");
        for key in [
            "jobId",
            "artifactLeaseId",
            "artifactId",
            "bundleName",
            "libraryLogicalName",
            "abi",
            "elfClassBits",
            "machine",
            "buildId",
            "sha256",
            "byteCount",
            "restartProfile",
            "verificationProfile",
            "rollbackPolicy",
            "directoryPath",
            "targetPath",
            "loaderVisiblePath",
            "stagingPath",
            "backupPath",
            "rollbackStagingPath",
            "stagingDirectoryPath",
            "codeSignFormatVersion",
            "codeSignVersion",
            "signedDataByteCount",
            "signatureByteCount",
            "codeSignHelperABI",
            "codeSignHelperBuildId",
            "codeSignHelperSha256",
            "codeSignHelperByteCount",
            "codeSignHelperRemotePath",
        ] {
            assert!(arguments.contains_key(key), "{key}");
        }
        assert_eq!(arguments["machine"], 183);
        assert_eq!(arguments["elfClassBits"], 64);
        assert_eq!(arguments["abi"], "arm64-v8a");
        assert_eq!(arguments["codeSignHelperABI"], "arm64-v8a");
        assert!(!arguments.contains_key("expectation"));
        let (kind, arguments) =
            NativeAction::Inspect(deployment.clone(), Inspection::TargetLoaded).persisted();
        assert_eq!(kind, "hdc.inspectNativeLibrary");
        assert_eq!(arguments["expectation"], "targetLoaded");
        let mut plain = deployment.clone();
        plain.artifact_facts.code_sign = None;
        plain.code_sign_helper_facts = None;
        plain.code_sign_helper_remote_path = None;
        plain.staging_directory_is_job_owned = false;
        let (_, arguments) = NativeAction::Cleanup(plain).persisted();
        for key in [
            "codeSignFormatVersion",
            "codeSignHelperABI",
            "stagingDirectoryPath",
        ] {
            assert!(!arguments.contains_key(key), "{key}");
        }
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped).effect(),
            "readOnly"
        );
        assert_eq!(NativeAction::Backup(deployment).effect(), "deviceMutation");
    }

    /// Swift `materialize()`: every persisted native form reads back as the
    /// action that wrote it, with or without the helper and the code-sign
    /// facts, and each missing, foreign or moved fact is refused as Swift
    /// refuses it.
    #[test]
    fn persisted_forms_materialize_as_swift_materializes_them() {
        let deployment = deployment();
        let mut facts = deployment.artifact_facts.clone();
        facts.code_sign = None;
        let plain = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            deployment.bundle.clone(),
            "libexample.so",
            facts,
            RestartProfile::RestartAbility,
            VerificationProfile::HashOnly,
            RollbackPolicy::RetainBackup,
            None,
            None,
        )
        .unwrap();
        let mut actions = Vec::new();
        for deployment in [deployment.clone(), plain] {
            actions.extend([
                NativeAction::SendToStaging(deployment.clone()),
                NativeAction::Backup(deployment.clone()),
                NativeAction::Publish(deployment.clone()),
                NativeAction::StopTarget(deployment.clone()),
                NativeAction::StartTarget(deployment.clone()),
                NativeAction::Cleanup(deployment.clone()),
                NativeAction::Rollback(deployment.clone()),
            ]);
            actions.extend(
                [
                    Inspection::StagingMatchesArtifact,
                    Inspection::BackupMatchesTarget,
                    Inspection::TargetMatchesArtifact,
                    Inspection::TargetStopped,
                    Inspection::TargetStarted,
                    Inspection::TargetLoaded,
                    Inspection::CleanupComplete,
                    Inspection::RollbackRestored,
                ]
                .map(|expectation| NativeAction::Inspect(deployment.clone(), expectation)),
            );
        }
        for action in actions {
            let (kind, arguments) = action.persisted();
            assert_eq!(
                NativeAction::from_persisted(kind, &arguments).unwrap(),
                Some(action),
                "{kind}"
            );
        }

        let (kind, arguments) = NativeAction::Cleanup(deployment.clone()).persisted();
        let refused = |change: &dyn Fn(&mut Map<String, Value>)| {
            let mut changed = arguments.clone();
            change(&mut changed);
            NativeAction::from_persisted(kind, &changed)
                .unwrap_err()
                .to_string()
        };
        let prefix = "unsupportedAction(\"persisted hdc.cleanupNativeLibrary";
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("abi");
            }),
            format!("{prefix} is missing string abi\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("rollbackPolicy".into(), json!("never"));
            }),
            format!("{prefix} carries an unknown native deployment profile\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("machine".into(), json!(65_536));
            }),
            format!("{prefix} native ELF machine is outside UInt16\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("signedDataByteCount");
            }),
            format!("{prefix} carries incomplete native code-sign facts\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("codeSignHelperRemotePath");
            }),
            format!("{prefix} carries incomplete code-sign helper facts\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("byteCount".into(), json!("588"));
            }),
            format!("{prefix} is missing integer byteCount\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("stagingPath".into(), json!("/data/local/tmp/libexample.so"));
            }),
            "unsupportedAction(\"persisted native deployment paths escape the provider-owned \
             namespace\")"
        );
        let mut inspected = NativeAction::Inspect(deployment, Inspection::CleanupComplete)
            .persisted()
            .1;
        inspected.insert("expectation".into(), json!("cleanupSkipped"));
        assert_eq!(
            NativeAction::from_persisted("hdc.inspectNativeLibrary", &inspected)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"persisted native inspection expectation is unknown\")"
        );
        assert_eq!(
            NativeAction::from_persisted("hdc.uninstallPackage", &arguments).unwrap(),
            None
        );
    }

    /// The parsers on their own.
    #[test]
    fn the_parsers_read_as_swift_reads() {
        assert_eq!(
            sha256_token(&sub(&format!("{REPLACED}  /x\n"), 0)).as_deref(),
            Some(REPLACED)
        );
        assert_eq!(sha256_token(&sub(REPLACED, 1)), None);
        assert_eq!(sha256_token(&sub(&REPLACED.to_uppercase(), 0)), None);
        assert_eq!(
            sha256_token(&sub("sha256sum: x: No such file or directory\n", 0)),
            None
        );
        assert!(is_directory_listing(&sub(
            "drwx------ 2 20010050 20010050 3452 2026-09-14 00:00 /x\n",
            0
        )));
        assert!(!is_directory_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            0
        )));
        assert!(is_regular_file_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            0
        )));
        assert!(!is_regular_file_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            1
        )));
        assert_eq!(
            native_file_identity(&sub(
                "-rw------- 1 20010050 20010050 256 2026-09-14 00:00 /x\n",
                0
            )),
            Some(NativeFileIdentity {
                mode: "-rw-------".into(),
                user_id: 20010050,
                group_id: 20010050
            })
        );
        assert_eq!(
            native_file_identity(&with_stderr("-rw------- 1 1 1 2 x\n", "warn", 0)),
            None
        );
        assert_eq!(
            native_file_identity(&sub("drwx------ 2 1 1 2 x\n", 0)),
            None
        );
        assert_eq!(
            native_file_identity(&sub("-rw------- 1 a b 2 x\n", 0)),
            None
        );
        assert!(maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                0
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert!(!maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                0
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[1]
        ));
        assert!(!maps_contain(
            &sub("/proc/4321/maps:7f000 /other.so\n", 0),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert!(!maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                1
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert_eq!(process_ids(&sub("4321 4322\n", 0)), Some(vec![4321, 4322]));
        assert_eq!(process_ids(&sub("4321 abc\n", 0)), None);
        assert_eq!(process_ids(&sub("0\n", 0)), None);
        assert_eq!(process_ids(&sub("", 0)), None);
        assert_eq!(process_ids(&sub("4321", 1)), None);
        assert!(process_is_absent(&sub("", 1)));
        assert!(process_is_absent(&sub("\n", 0)));
        assert!(!process_is_absent(&sub("", 2)));
        assert!(!process_is_absent(&with_stderr("", "x", 1)));
        assert!(!process_is_absent(&sub("4321", 0)));
        assert_eq!(
            readback_attestation(&sub(
                &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
                0
            )),
            Attestation::Attested(REPLACED.into())
        );
        assert_eq!(
            readback_attestation(&with_stderr(
                "",
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n",
                30
            )),
            Attestation::Absent
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=95\n",
                0
            )),
            Attestation::Absent
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=2\n",
                30
            )),
            Attestation::Unreadable
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\nmore\n",
                30
            )),
            Attestation::Unreadable
        );
        assert_eq!(readback_attestation(&sub("", 0)), Attestation::Unreadable);
        assert_eq!(
            code_sign_digest(
                &sub(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    0
                ),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            )
            .as_deref(),
            Some(REPLACED)
        );
        assert_eq!(
            code_sign_digest(
                &with_stderr(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    "x",
                    0
                ),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            ),
            None
        );
        assert_eq!(
            code_sign_digest(
                &sub(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    0
                ),
                "ARKDECK_CODE_SIGN_VERIFIED"
            ),
            None
        );
        assert_eq!(
            code_sign_digest(
                &sub("ARKDECK_CODE_SIGN_PUBLISHED sha256:abc\n", 0),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            ),
            None
        );
        assert!(published_without_attestation(&sub(
            "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED replaced-file-had-none\n",
            0
        )));
        assert!(!published_without_attestation(&sub(
            "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED\n",
            0
        )));
        let attested = sub(
            &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
            0,
        );
        let absent = sub(
            "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n",
            30,
        );
        let unreadable = sub("", 0);
        assert_eq!(
            attestation_at_least_replaced(&absent, &attested),
            Some(BTreeMap::from([
                ("fsVerityDigest".to_owned(), REPLACED.to_owned()),
                ("attestation".to_owned(), "fsVerity".to_owned())
            ])),
            "a floor, not an equality"
        );
        assert_eq!(
            attestation_at_least_replaced(&absent, &absent),
            Some(BTreeMap::from([(
                "attestation".to_owned(),
                "matchesReplacedFile:none".to_owned()
            )]))
        );
        assert_eq!(attestation_at_least_replaced(&attested, &absent), None);
        assert_eq!(attestation_at_least_replaced(&unreadable, &attested), None);
        assert_eq!(attestation_at_least_replaced(&absent, &unreadable), None);
    }

    /// The verdicts Swift reaches that the oracle's five Jobs do not cover.
    #[test]
    fn the_remaining_verdicts_follow_swift() {
        let deployment = deployment();
        let listing = |mode: &str| {
            sub(
                &format!("{mode} 1 20010050 20010050 256 2026-09-14 00:00 /x\n"),
                0,
            )
        };
        let send = NativeAction::SendToStaging(deployment.clone());
        assert_eq!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("FileTransfer finish\n", 0),
                sub("FileTransfer finish\n", 0),
                sub("", 0),
                sub(&format!("{HELPER_SHA256}  /h\n"), 0)
            ])),
            Outcome::Unknown("native staging send requires remote hash readback".into())
        );
        assert!(matches!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(&format!("{REPLACED}  /h\n"), 0)
            ])),
            Outcome::Failed {
                code: "nativeSendFailed",
                ..
            }
        ));
        assert!(matches!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(&format!("{HELPER_SHA256}  /h\n"), 1)
            ])),
            Outcome::Failed {
                code: "nativeSendFailed",
                ..
            }
        ));
        let backup = NativeAction::Backup(deployment.clone());
        assert!(matches!(
            backup.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let Outcome::Failed {
            code: "nativeBackupMismatch",
            detail,
        } = backup.verify(&receipt(vec![
            listing("drwx------"),
            listing("-rw-------"),
            sub(&format!("{REPLACED}  /t\n"), 0),
            sub("", 0),
            sub("", 1),
            sub(&format!("{REPLACED}  /b\n"), 0),
            listing("-rw-------"),
            sub("total 4\n", 0),
        ]))
        else {
            panic!("a failed hard link")
        };
        assert!(
            detail.contains("hardLinkExit=1")
                && detail.contains("backupHashMatches=true")
                && detail.contains("diagnostics=0:outBytes="),
            "{detail}"
        );
        let stop = NativeAction::StopTarget(deployment.clone());
        let Outcome::Failed {
            code: "nativeTargetStillRunning",
            detail,
        } = stop.verify(&receipt(vec![
            sub("", 0),
            sub("4321\n", 0),
            sub("", 0),
            sub("4321\n", 0),
        ]))
        else {
            panic!("still running")
        };
        assert_eq!(
            detail,
            "com.example.demo remained live after stop (forceStopExit=0, pidofExit=0, pids=4321, stdoutBytes=5, stderrBytes=0)"
        );
        assert!(matches!(
            stop.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let start = NativeAction::StartTarget(deployment.clone());
        assert!(matches!(
            start.verify(&receipt(vec![sub("", 0), sub("", 0), sub("", 1)])),
            Outcome::Failed {
                code: "nativeTargetNotRunning",
                ..
            }
        ));
        let cleanup = NativeAction::Cleanup(deployment.clone());
        let gone = sub("ls: /x: No such file or directory\n", 0);
        assert_eq!(
            cleanup.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone()
            ])),
            Outcome::Verified(BTreeMap::from([
                ("cleaned".to_owned(), deployment.staging_path.clone()),
                ("backupRetained".to_owned(), "false".to_owned())
            ]))
        );
        assert!(matches!(
            cleanup.verify(&receipt(vec![
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                listing("-rw-------")
            ])),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        let rollback = NativeAction::Rollback(deployment.clone());
        assert!(matches!(
            rollback.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let mut thirteen: Vec<Receipt> = (0..13).map(|_| sub("", 0)).collect();
        thirteen[0] = sub(&format!("{REPLACED}  /b\n"), 0);
        thirteen[4] = sub("", 1);
        thirteen[8] = sub(&format!("{REPLACED}  /t\n"), 0);
        thirteen[11] = sub("4321\n", 0);
        thirteen[12] = sub(
            "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
            0,
        );
        assert!(matches!(
            rollback.verify(&receipt(thirteen.clone())),
            Outcome::Verified(_)
        ));
        thirteen[8] = sub(&format!("{LIBRARY_SHA256}  /t\n"), 0);
        let Outcome::Failed {
            code: "nativeRollbackVerificationFailed",
            detail,
        } = rollback.verify(&receipt(thirteen))
        else {
            panic!("bytes not restored")
        };
        assert!(
            detail.contains("targetHashMatches=false")
                && detail.contains("startedPids=4321")
                && detail.contains("mapsMatched=true"),
            "{detail}"
        );
        // Inspections beyond the oracle: a weaker profile states what it did
        // not observe; a rollback readback stays unknown rather than failed.
        let mut hash_only = deployment.clone();
        hash_only.verification_profile = VerificationProfile::HashOnly;
        let attested = sub(
            &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
            0,
        );
        let loaded = NativeAction::Inspect(hash_only.clone(), Inspection::TargetLoaded).verify(
            &receipt(vec![
                sub(&format!("{LIBRARY_SHA256}  /t\n"), 0),
                attested.clone(),
                attested.clone(),
            ]),
        );
        let Outcome::Verified(summary) = loaded else {
            panic!("{loaded:?}")
        };
        assert_eq!(summary["loaderVerified"], "notObserved");
        assert!(!summary.contains_key("processIds"));
        assert_eq!(summary["attestation"], "fsVerity");
        let restored =
            NativeAction::Inspect(hash_only, Inspection::RollbackRestored).verify(&receipt(vec![
                sub(&format!("{REPLACED}  /t\n"), 0),
                sub(&format!("{REPLACED}  /b\n"), 0),
                sub("4321\n", 0),
            ]));
        let Outcome::Verified(summary) = restored else {
            panic!("{restored:?}")
        };
        assert_eq!(summary["loaderVerified"], "notObserved");
        let unproven = NativeAction::Inspect(deployment.clone(), Inspection::RollbackRestored)
            .verify(&receipt(vec![
                sub(&format!("{REPLACED}  /t\n"), 0),
                sub(&format!("{REPLACED}  /b\n"), 0),
                sub("4321\n", 0),
                sub("/proc/1/maps:x\n", 0),
            ]));
        assert_eq!(
            unproven,
            Outcome::Unknown("rollback bytes exist but restored loader state is unproven".into())
        );
        let staging = NativeAction::Inspect(deployment.clone(), Inspection::StagingMatchesArtifact);
        let Outcome::Failed {
            code: "nativeStagingMismatch",
            detail,
        } = staging.verify(&receipt(vec![sub(&format!("{REPLACED}  /s\n"), 0)]))
        else {
            panic!()
        };
        assert_eq!(
            detail,
            "remote staging bytes do not match the leased ELF (hashExit=0, hashMatches=false, listingExit=missing, regularFile=false)"
        );
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::BackupMatchesTarget).verify(
                &receipt(vec![
                    sub(&format!("{REPLACED}  /t\n"), 0),
                    sub(&format!("{LIBRARY_SHA256}  /b\n"), 0)
                ])
            ),
            Outcome::Failed {
                code: "nativeBackupMismatch",
                ..
            }
        ));
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped)
                .verify(&receipt(vec![sub("", 1)])),
            Outcome::Verified(BTreeMap::from([("running".to_owned(), "false".to_owned())]))
        );
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStarted)
                .verify(&receipt(vec![sub("", 1)])),
            Outcome::Failed {
                code: "nativeTargetNotRunning",
                ..
            }
        ));
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::CleanupComplete)
                .verify(&receipt(vec![gone.clone(); 4])),
            Outcome::Failed {
                code: "nativeCleanupIncomplete",
                ..
            }
        ));
        // Readbacks and their conclusions.
        assert_eq!(
            NativeAction::Publish(deployment.clone()).readback(),
            Some(NativeAction::Inspect(
                deployment.clone(),
                Inspection::TargetMatchesArtifact
            ))
        );
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped).readback(),
            None
        );
        let failed = Outcome::Failed {
            code: "nativeTargetHashMismatch",
            detail: "d".into(),
        };
        assert_eq!(
            NativeAction::Publish(deployment.clone()).reconcile(failed.clone()),
            Reconcile::StillUnknown(
                "nativeTargetHashMismatch: d; publish state is not safe to replay".into()
            )
        );
        assert_eq!(
            NativeAction::Rollback(deployment.clone()).reconcile(failed.clone()),
            Reconcile::StillUnknown("nativeTargetHashMismatch: d".into())
        );
        assert_eq!(
            NativeAction::Backup(deployment.clone()).reconcile(failed),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            NativeAction::Backup(deployment.clone()).reconcile(Outcome::Unknown("u".into())),
            Reconcile::StillUnknown("u".into())
        );
        assert_eq!(
            NativeAction::Backup(deployment).reconcile(Outcome::Verified(BTreeMap::new())),
            Reconcile::ConfirmedCompleted(BTreeMap::new())
        );
    }

    #[test]
    fn public_backup_and_rollback_evidence_retains_exact_receipt_values_without_paths() {
        let deployment = deployment();
        let listing = |mode: &str| sub(&format!("{mode} 1 100 100 256 /private-name\n"), 0);
        let backup = NativeAction::Backup(deployment.clone());
        let mut backup_receipt = receipt(vec![
            listing("drwx------"),
            listing("-rw-------"),
            sub(&format!("{REPLACED}  /private-current\n"), 0),
            sub("", 0),
            sub("", 0),
            sub(&format!("{REPLACED}  /private-backup\n"), 0),
            listing("-rw-------"),
            sub("", 0),
        ]);
        let input = json!({
            "schemaVersion": "arkdeck.native-library.readback/1",
            "inputABI": "arm64-v8a",
            "inputBuildId": deployment.artifact_facts.build_id,
            "inputSha256": LIBRARY_SHA256,
        });
        let mut expected = input.clone();
        expected["phase"] = json!("backup");
        expected["currentSha256"] = json!(REPLACED);
        expected["backupSha256"] = json!(REPLACED);
        assert_eq!(
            backup.verified_readback_evidence(&backup_receipt),
            Some(expected)
        );
        backup_receipt.subprocesses[5] = sub(&format!("{LIBRARY_SHA256}  /private-backup\n"), 0);
        assert_eq!(backup.verified_readback_evidence(&backup_receipt), None);
        assert!(matches!(
            backup.verify(&backup_receipt),
            Outcome::Failed { .. }
        ));

        let rollback = NativeAction::Rollback(deployment.clone());
        let mut processes: Vec<Receipt> = (0..13).map(|_| sub("", 0)).collect();
        processes[0] = sub(&format!("{REPLACED}  /private-backup\n"), 0);
        processes[4] = sub("", 1);
        processes[8] = sub(&format!("{REPLACED}  /private-current\n"), 0);
        processes[11] = sub("4321 7654\n", 0);
        let maps = format!(
            "/proc/4321/maps:7f000 {}\n/proc/4321/maps:7f100 {}\n/proc/99/maps:secret-other-path\n",
            deployment.loader_visible_path, deployment.loader_visible_path,
        );
        processes[12] = sub(&maps, 0);
        let restored = receipt(processes);
        let mut expected = input;
        expected["phase"] = json!("rollback");
        expected["backupSha256"] = json!(REPLACED);
        expected["restoredSha256"] = json!(REPLACED);
        expected["processIds"] = json!([4321, 7654]);
        expected["mappedProcessIds"] = json!([4321]);
        expected["mapsVerified"] = json!(true);
        expected["mapsSha256"] = json!(arkdeck_contract::sha256_hex(maps.as_bytes()));
        expected["mapsByteCount"] = json!(maps.len());
        expected["matchingMapLineCount"] = json!(2);
        expected["loaderPathSha256"] = json!(arkdeck_contract::sha256_hex(
            deployment.loader_visible_path.as_bytes(),
        ));
        assert_eq!(
            rollback.verified_readback_evidence(&restored),
            Some(expected.clone())
        );
        for private in [
            KEY,
            "/proc/",
            "/private-",
            "secret-other-path",
            &deployment.loader_visible_path,
        ] {
            assert!(!expected.to_string().contains(private), "{private}");
        }
        assert_ne!(expected["inputSha256"], expected["restoredSha256"]);
        for index in [0, 8, 11, 12] {
            let mut changed = restored.clone();
            changed.subprocesses[index] = match index {
                0 | 8 => sub(&format!("{LIBRARY_SHA256}  /wrong\n"), 0),
                11 => sub("not-a-pid\n", 0),
                _ => sub("/proc/4321/maps:7f000 /wrong\n", 0),
            };
            assert_eq!(
                rollback.verified_readback_evidence(&changed),
                None,
                "{index}"
            );
            assert!(!matches!(rollback.verify(&changed), Outcome::Verified(_)));
        }
        let mut incomplete = restored.clone();
        incomplete.subprocesses.pop();
        assert_eq!(rollback.verified_readback_evidence(&incomplete), None);
        assert!(matches!(rollback.verify(&incomplete), Outcome::Unknown(_)));
        let mut truncated = restored;
        truncated.subprocesses[12].truncated = true;
        assert_eq!(rollback.verified_readback_evidence(&truncated), None);
        assert_eq!(
            NativeAction::Publish(deployment).verified_readback_evidence(&truncated),
            None
        );
    }

    /// A bounded arm64 static executable with a GNU build id and no
    /// OpenHarmony signature: what the bundled code-sign helper is.
    fn helper_elf(kind: u16, machine: u16, segments: &[u32]) -> Vec<u8> {
        const HEADER: usize = 64;
        const PROGRAM_ENTRY: usize = 56;
        const SECTION_ENTRY: usize = 64;
        let note_name = b"GNU\0";
        let description: [u8; 20] = [
            0x4e, 0x6f, 0x74, 0x41, 0x52, 0x65, 0x61, 0x6c, 0x42, 0x75, 0x69, 0x6c, 0x64, 0x49,
            0x64, 0x00, 0x11, 0x22, 0x33, 0x44,
        ];
        let programs = HEADER;
        let sections = programs + segments.len() * PROGRAM_ENTRY;
        let note = sections + SECTION_ENTRY;
        let note_size = 12 + note_name.len() + description.len();
        let mut data = vec![0_u8; note + note_size];
        data[..4].copy_from_slice(&[0x7f, b'E', b'L', b'F']);
        data[4] = 2;
        data[5] = 1;
        data[16..18].copy_from_slice(&kind.to_le_bytes());
        data[18..20].copy_from_slice(&machine.to_le_bytes());
        data[32..40].copy_from_slice(&(programs as u64).to_le_bytes());
        data[40..48].copy_from_slice(&(sections as u64).to_le_bytes());
        data[54..56].copy_from_slice(&(PROGRAM_ENTRY as u16).to_le_bytes());
        data[56..58].copy_from_slice(&(segments.len() as u16).to_le_bytes());
        data[58..60].copy_from_slice(&(SECTION_ENTRY as u16).to_le_bytes());
        data[60..62].copy_from_slice(&1_u16.to_le_bytes());
        for (index, segment) in segments.iter().enumerate() {
            let at = programs + index * PROGRAM_ENTRY;
            data[at..at + 4].copy_from_slice(&segment.to_le_bytes());
        }
        data[sections + 4..sections + 8].copy_from_slice(&7_u32.to_le_bytes());
        data[sections + 24..sections + 32].copy_from_slice(&(note as u64).to_le_bytes());
        data[sections + 32..sections + 40].copy_from_slice(&(note_size as u64).to_le_bytes());
        data[note..note + 4].copy_from_slice(&(note_name.len() as u32).to_le_bytes());
        data[note + 4..note + 8].copy_from_slice(&(description.len() as u32).to_le_bytes());
        data[note + 8..note + 12].copy_from_slice(&3_u32.to_le_bytes());
        data[note + 12..note + 12 + note_name.len()].copy_from_slice(note_name);
        let at = note + 12 + note_name.len();
        data[at..at + description.len()].copy_from_slice(&description);
        data
    }

    #[test]
    fn the_helper_is_a_static_arm64_executable_without_a_signature() {
        let bytes = helper_elf(2, 183, &[1]);
        let helper = CodeSignHelper::verified(&bytes, PathBuf::from("/host/helper")).unwrap();
        assert_eq!(helper.facts.abi, NativeAbi::Arm64);
        assert_eq!(helper.facts.byte_count, bytes.len() as i64);
        assert_eq!(
            helper.facts.sha256,
            crate::native_elf::validate_elf(&bytes, None, false)
                .unwrap()
                .sha256
        );
        assert_eq!(helper.facts.build_id.len(), 40);
        assert_eq!(helper.host_path, PathBuf::from("/host/helper"));
        // An interpreter, no loadable segment, a shared object and another
        // ABI are each refused, as Swift's bundled() refuses them.
        for (kind, machine, segments) in [
            (2_u16, 183_u16, vec![1_u32, 3]),
            (2, 183, vec![2]),
            (3, 183, vec![1]),
            (2, 40, vec![1]),
        ] {
            assert!(
                CodeSignHelper::verified(&helper_elf(kind, machine, &segments), PathBuf::new())
                    .is_err(),
                "{kind} {machine} {segments:?}"
            );
        }
        assert!(CodeSignHelper::verified(b"not an ELF", PathBuf::new()).is_err());
    }

    /// The helper ArkDeckWorkflows carries, when this checkout has it: the
    /// isolated contract view keeps only `rust/`, so its absence is not a
    /// failure. Its facts are the ones the oracle recorded for the helper
    /// Swift staged.
    #[test]
    fn the_bundled_helper_carries_the_facts_the_oracle_recorded() {
        let cases: Value = serde_json::from_slice(
            &std::fs::read(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/deploy-native-library/cases.json"),
            )
            .unwrap(),
        )
        .unwrap();
        let recorded = &cases["codeSignHelper"];
        assert_eq!(recorded["sha256"], HELPER_SHA256);
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Packages/ArkDeckKit/Resources")
            .join("OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable");
        let Ok(bytes) = std::fs::read(&path) else {
            return;
        };
        let helper = CodeSignHelper::verified(&bytes, path.clone()).unwrap();
        assert_eq!(helper.facts.abi, NativeAbi::Arm64);
        assert_eq!(helper.facts.sha256, recorded["sha256"].as_str().unwrap());
        assert_eq!(helper.facts.build_id, recorded["buildId"].as_str().unwrap());
        assert_eq!(
            helper.facts.byte_count,
            recorded["byteCount"].as_i64().unwrap()
        );
    }
}
