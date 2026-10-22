impl NativeAction {
    /// Swift `nativeLibraryAction`'s step switch (by step id): the eight
    /// steps of the operation, and the two the engine synthesizes for the
    /// compensation. `None` is a host-only step (`verify-elf-locally`,
    /// `hash-library`, `finalize-session`).
    pub fn for_step(
        step_id: &str,
        deployment: &Deployment,
    ) -> Result<Option<Self>, FileActionError> {
        let deployment = deployment.clone();
        Ok(Some(match step_id {
            "send-to-staging" => Self::SendToStaging(deployment),
            "verify-remote-staging" => {
                Self::Inspect(deployment, Inspection::StagingMatchesArtifact)
            }
            "backup-current-version" => Self::Backup(deployment),
            "atomic-publish" => Self::Publish(deployment),
            "restart-target" => Self::StopTarget(deployment),
            "start-target" => Self::StartTarget(deployment),
            "verify-loaded-library" => Self::Inspect(deployment, Inspection::TargetLoaded),
            "cleanup-staging-and-backup" | "cleanup-native-library-compensation" => {
                Self::Cleanup(deployment)
            }
            "rollback-native-library" => Self::Rollback(deployment),
            "verify-elf-locally" | "hash-library" | "finalize-session" => return Ok(None),
            other => {
                return Err(FileActionError::Unsupported(format!(
                    "{other} has no app-owned native-library action"
                )));
            }
        }))
    }

    pub fn deployment(&self) -> &Deployment {
        match self {
            Self::SendToStaging(deployment)
            | Self::Backup(deployment)
            | Self::Publish(deployment)
            | Self::StopTarget(deployment)
            | Self::StartTarget(deployment)
            | Self::Cleanup(deployment)
            | Self::Rollback(deployment)
            | Self::Inspect(deployment, _) => deployment,
        }
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::Inspect(..) => "readOnly",
            _ => "deviceMutation",
        }
    }

    /// Swift `PersistedTypedProviderAction`'s `nativeArguments`, the same
    /// object for every native kind, plus the inspection's expectation.
    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        let deployment = self.deployment();
        let facts = &deployment.artifact_facts;
        let mut arguments = json!({
            "jobId": deployment.job_id,
            "artifactLeaseId": deployment.artifact_lease_id,
            "artifactId": deployment.artifact_id,
            "bundleName": deployment.bundle.bundle_name(),
            "libraryLogicalName": deployment.library_logical_name,
            "abi": facts.abi.raw(),
            "elfClassBits": facts.elf_class_bits,
            "machine": facts.machine,
            "buildId": facts.build_id,
            "sha256": facts.sha256,
            "byteCount": facts.byte_count,
            "restartProfile": deployment.restart_profile.raw(),
            "verificationProfile": deployment.verification_profile.raw(),
            "rollbackPolicy": deployment.rollback_policy.raw(),
            "directoryPath": deployment.directory_path,
            "targetPath": deployment.target_path,
            "loaderVisiblePath": deployment.loader_visible_path,
            "stagingPath": deployment.staging_path,
            "backupPath": deployment.backup_path,
            "rollbackStagingPath": deployment.rollback_staging_path,
        });
        if deployment.staging_directory_is_job_owned {
            arguments["stagingDirectoryPath"] = json!(deployment.staging_directory_path);
        }
        if let Some(code_sign) = &facts.code_sign {
            arguments["codeSignFormatVersion"] = json!(code_sign.format_version);
            arguments["codeSignVersion"] = json!(code_sign.code_sign_version);
            arguments["signedDataByteCount"] = json!(code_sign.signed_data_byte_count);
            arguments["signatureByteCount"] = json!(code_sign.signature_byte_count);
        }
        if let (Some(helper), Some(remote)) = (
            &deployment.code_sign_helper_facts,
            &deployment.code_sign_helper_remote_path,
        ) {
            arguments["codeSignHelperABI"] = json!(helper.abi.raw());
            arguments["codeSignHelperBuildId"] = json!(helper.build_id);
            arguments["codeSignHelperSha256"] = json!(helper.sha256);
            arguments["codeSignHelperByteCount"] = json!(helper.byte_count);
            arguments["codeSignHelperRemotePath"] = json!(remote);
        }
        let kind = match self {
            Self::SendToStaging(_) => "hdc.sendNativeLibraryToStaging",
            Self::Backup(_) => "hdc.backupNativeLibrary",
            Self::Publish(_) => "hdc.publishNativeLibrary",
            Self::StopTarget(_) => "hdc.stopNativeTarget",
            Self::StartTarget(_) => "hdc.startNativeTarget",
            Self::Cleanup(_) => "hdc.cleanupNativeLibrary",
            Self::Rollback(_) => "hdc.rollbackNativeLibrary",
            Self::Inspect(_, expectation) => {
                arguments["expectation"] = json!(expectation.raw());
                "hdc.inspectNativeLibrary"
            }
        };
        let Value::Object(arguments) = arguments else {
            unreachable!("an object literal")
        };
        (kind, arguments)
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for the native
    /// family: the deployment rebuilt from its persisted arguments (its
    /// recorded paths accepted only when they are exactly the namespace's),
    /// refused as Swift refuses it. `None` is a kind of another family.
    pub fn from_persisted(
        kind: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let persisted = PersistedArguments { kind, arguments };
        Ok(Some(match kind {
            "hdc.sendNativeLibraryToStaging" => Self::SendToStaging(deployment(&persisted)?),
            "hdc.backupNativeLibrary" => Self::Backup(deployment(&persisted)?),
            "hdc.publishNativeLibrary" => Self::Publish(deployment(&persisted)?),
            "hdc.stopNativeTarget" => Self::StopTarget(deployment(&persisted)?),
            "hdc.startNativeTarget" => Self::StartTarget(deployment(&persisted)?),
            "hdc.cleanupNativeLibrary" => Self::Cleanup(deployment(&persisted)?),
            "hdc.rollbackNativeLibrary" => Self::Rollback(deployment(&persisted)?),
            "hdc.inspectNativeLibrary" => {
                let Some(expectation) = Inspection::parse(persisted.string("expectation")?) else {
                    return Err(FileActionError::Unsupported(
                        "persisted native inspection expectation is unknown".into(),
                    ));
                };
                Self::Inspect(deployment(&persisted)?, expectation)
            }
            _ => return Ok(None),
        }))
    }

    /// Swift `lower` (`nativeSequence` / `nativeInspectionPlan`): every
    /// native action is a sequence; a send needs the same engine-resolved
    /// Artifact and the verified helper, the publish and the target
    /// inspections a persisted helper path.
    pub fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        resolved: Option<&ResolvedArtifact>,
        resolved_byte_count: Option<i64>,
        helper: Option<&CodeSignHelper>,
    ) -> Result<FilePlan, String> {
        let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
            return Err(format!(
                "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
            ));
        };
        let unsupported = |detail: &str| format!("unsupportedAction(\"{detail}\")");
        let host = |path: &Path| path.to_string_lossy().into_owned();
        let deployment = self.deployment();
        let bundle = deployment.bundle.bundle_name();
        let mut commands: Vec<(Vec<String>, bool, u64)> = Vec::new();
        let mut push = |argv: Vec<&str>, continues: bool, seconds: u64| {
            commands.push((
                argv.into_iter().map(str::to_owned).collect(),
                continues,
                seconds,
            ));
        };
        match self {
            Self::SendToStaging(deployment) => {
                let Some(resolved) = resolved.filter(|resolved| {
                    deployment.artifact_id == resolved.artifact_id
                        && deployment.artifact_facts.sha256 == resolved.sha256
                        && Some(deployment.artifact_facts.byte_count) == resolved_byte_count
                }) else {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                };
                let (Some(expected_helper), Some(helper_remote), Some(helper)) = (
                    &deployment.code_sign_helper_facts,
                    &deployment.code_sign_helper_remote_path,
                    helper,
                ) else {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                };
                if !deployment.staging_directory_is_job_owned || helper.facts != *expected_helper {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                }
                let library_host = host(&resolved.path);
                let helper_host = host(&helper.host_path);
                push(
                    vec!["shell", "mkdir", "-p", &deployment.staging_directory_path],
                    false,
                    30,
                );
                push(
                    vec!["file", "send", &library_host, &deployment.staging_path],
                    false,
                    300,
                );
                push(vec!["file", "send", &helper_host, helper_remote], false, 60);
                push(vec!["shell", "chmod", "700", helper_remote], false, 30);
                push(vec!["shell", "sha256sum", helper_remote], false, 30);
            }
            Self::Backup(deployment) => {
                let root = deployment.native_libraries_root_path();
                push(
                    vec!["shell", "ls", "-ld", &deployment.directory_path],
                    false,
                    15,
                );
                push(
                    vec!["shell", "ls", "-l", &deployment.target_path],
                    false,
                    15,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", "rm", "-f", &deployment.backup_path],
                    false,
                    30,
                );
                push(
                    vec![
                        "shell",
                        "ln",
                        &deployment.target_path,
                        &deployment.backup_path,
                    ],
                    false,
                    30,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.backup_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", "ls", "-l", &deployment.backup_path],
                    false,
                    15,
                );
                // Firmware-layout diagnosis stays inside this typed action;
                // failure reporting exposes only a bounded hex prefix.
                push(vec!["shell", "ls", "-la", &root], true, 15);
            }
            Self::Publish(deployment) => {
                let (Some(helper_remote), Some(_)) = (
                    &deployment.code_sign_helper_remote_path,
                    &deployment.code_sign_helper_facts,
                ) else {
                    return Err(unsupported(
                        "native publish has no persisted code-sign helper identity",
                    ));
                };
                push(
                    vec!["shell", "ls", "-ln", &deployment.target_path],
                    false,
                    15,
                );
                // The backup is a hard link to the file about to be replaced,
                // so it keeps that file's attestation across the rename.
                push(
                    vec!["shell", helper_remote, "verify", &deployment.backup_path],
                    true,
                    30,
                );
                push(
                    vec![
                        "shell",
                        helper_remote,
                        "publish",
                        &deployment.staging_path,
                        &deployment.target_path,
                        &deployment.rollback_staging_path,
                    ],
                    false,
                    60,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", helper_remote, "verify", &deployment.target_path],
                    true,
                    30,
                );
                push(
                    vec!["shell", "ls", "-ln", &deployment.target_path],
                    false,
                    15,
                );
            }
            Self::StopTarget(_) => {
                push(vec!["shell", "aa", "force-stop", bundle], true, 60);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
            }
            Self::StartTarget(_) => {
                push(
                    vec!["shell", "aa", "start", "-b", bundle, "-a", ENTRY_ABILITY],
                    true,
                    60,
                );
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
            }
            Self::Cleanup(deployment) => {
                let paths = deployment.cleanup_paths();
                for path in &paths {
                    let command = if *path == deployment.staging_directory_path {
                        "rmdir"
                    } else {
                        "rm"
                    };
                    if command == "rmdir" {
                        push(vec!["shell", "rmdir", path], true, 30);
                    } else {
                        push(vec!["shell", "rm", "-f", path], true, 30);
                    }
                }
                for path in &paths {
                    push(vec!["shell", "ls", "-ld", path], true, 15);
                }
            }
            Self::Rollback(deployment) => {
                push(
                    vec!["shell", "sha256sum", &deployment.backup_path],
                    false,
                    30,
                );
                push(vec!["shell", "aa", "force-stop", bundle], true, 60);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(
                    vec!["shell", "rm", "-f", &deployment.rollback_staging_path],
                    true,
                    30,
                );
                push(
                    vec![
                        "shell",
                        "ln",
                        &deployment.backup_path,
                        &deployment.rollback_staging_path,
                    ],
                    true,
                    60,
                );
                push(
                    vec![
                        "shell",
                        "mv",
                        "-f",
                        &deployment.rollback_staging_path,
                        &deployment.target_path,
                    ],
                    true,
                    60,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    true,
                    30,
                );
                push(
                    vec!["shell", "aa", "start", "-b", bundle, "-a", ENTRY_ABILITY],
                    true,
                    60,
                );
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(
                    vec![
                        "shell",
                        "grep",
                        "-F",
                        &deployment.loader_visible_path,
                        "/proc/*/maps",
                    ],
                    true,
                    30,
                );
            }
            Self::Inspect(deployment, expectation) => match expectation {
                Inspection::StagingMatchesArtifact => {
                    push(
                        vec!["shell", "sha256sum", &deployment.staging_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "ls", "-l", &deployment.staging_path],
                        true,
                        15,
                    );
                }
                Inspection::BackupMatchesTarget => {
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "sha256sum", &deployment.backup_path],
                        true,
                        30,
                    );
                }
                Inspection::TargetMatchesArtifact | Inspection::TargetLoaded => {
                    let Some(helper_remote) = &deployment.code_sign_helper_remote_path else {
                        return Err(unsupported(if *expectation == Inspection::TargetLoaded {
                            "native loader inspection has no persisted code-sign helper path"
                        } else {
                            "native target inspection has no persisted code-sign helper path"
                        }));
                    };
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", helper_remote, "verify", &deployment.backup_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", helper_remote, "verify", &deployment.target_path],
                        true,
                        30,
                    );
                    if *expectation == Inspection::TargetLoaded {
                        if deployment.verification_profile != VerificationProfile::HashOnly {
                            push(vec!["shell", "pidof", bundle], true, 30);
                        }
                        if deployment.verification_profile
                            == VerificationProfile::HashProcessAndMaps
                        {
                            push(
                                vec![
                                    "shell",
                                    "grep",
                                    "-F",
                                    &deployment.loader_visible_path,
                                    "/proc/*/maps",
                                ],
                                true,
                                30,
                            );
                        }
                    }
                }
                Inspection::TargetStopped | Inspection::TargetStarted => {
                    push(vec!["shell", "pidof", bundle], true, 30);
                }
                Inspection::CleanupComplete => {
                    for path in deployment.cleanup_paths() {
                        push(vec!["shell", "ls", "-ld", &path], true, 15);
                    }
                }
                Inspection::RollbackRestored => {
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "sha256sum", &deployment.backup_path],
                        true,
                        30,
                    );
                    push(vec!["shell", "pidof", bundle], true, 30);
                    if deployment.verification_profile == VerificationProfile::HashProcessAndMaps {
                        push(
                            vec![
                                "shell",
                                "grep",
                                "-F",
                                &deployment.loader_visible_path,
                                "/proc/*/maps",
                            ],
                            true,
                            30,
                        );
                    }
                }
            },
        }
        Ok(FilePlan::Sequence(
            commands
                .into_iter()
                .map(|(tail, continue_after_non_zero, seconds)| {
                    let arguments = device_arguments(key, tail);
                    Invocation {
                        arguments,
                        timeout: Duration::from_secs(seconds),
                        continue_after_non_zero,
                    }
                })
                .collect(),
        ))
    }

    /// Swift `verify` for the native actions and `verifyNativeInspection`.
    pub fn verify(&self, receipt: &FileReceipt) -> Outcome {
        let subprocesses = &receipt.subprocesses;
        // Swift's aggregate exit status of a sequence is its last process's.
        let aggregate_exit = subprocesses.last().map(|process| process.exit_status);
        match self {
            Self::SendToStaging(deployment) => {
                let clean = aggregate_exit == Some(0)
                    && subprocesses.len() == 5
                    && deployment
                        .code_sign_helper_facts
                        .as_ref()
                        .is_some_and(|helper| {
                            sha256_token(&subprocesses[4]).as_deref()
                                == Some(helper.sha256.as_str())
                        });
                if !clean {
                    return failed(
                        "nativeSendFailed",
                        "native library and the pinned code-sign helper did not both transfer cleanly",
                    );
                }
                Outcome::Unknown("native staging send requires remote hash readback".into())
            }
            Self::Backup(deployment) => {
                if subprocesses.len() != 8 {
                    return Outcome::Unknown(
                        "native backup did not produce its complete readback sequence".into(),
                    );
                }
                if path_presence(&subprocesses[0]) == Some(false) {
                    return failed(
                        "nativeAppOwnedDirectoryMissing",
                        "the target bundle has no app-owned native library directory; install the signed application before deploying its library",
                    );
                }
                let target_hash = sha256_token(&subprocesses[2]);
                let backup_hash = sha256_token(&subprocesses[5]);
                let backup_matches = backup_hash.is_some() && backup_hash == target_hash;
                let valid = is_directory_listing(&subprocesses[0])
                    && is_regular_file_listing(&subprocesses[1])
                    && backup_matches
                    && subprocesses[3].exit_status == 0
                    && subprocesses[4].exit_status == 0
                    && is_regular_file_listing(&subprocesses[6]);
                let (Some(backup_hash), true) = (backup_hash, valid) else {
                    let diagnostics = subprocesses
                        .iter()
                        .enumerate()
                        .map(|(index, process)| {
                            format!("{index}:{}", bounded_process_diagnostic(process))
                        })
                        .collect::<Vec<_>>()
                        .join(";");
                    return Outcome::Failed {
                        code: "nativeBackupMismatch",
                        detail: format!(
                            "app-owned directory, original file or verified backup snapshot is invalid (directoryExit={}, directoryListed={}, targetExit={}, targetListed={}, targetHashExit={}, targetHashPresent={}, removeOldBackupExit={}, hardLinkExit={}, backupHashExit={}, backupHashMatches={}, backupExit={}, backupListed={}, diagnostics={diagnostics})",
                            subprocesses[0].exit_status,
                            is_directory_listing(&subprocesses[0]),
                            subprocesses[1].exit_status,
                            is_regular_file_listing(&subprocesses[1]),
                            subprocesses[2].exit_status,
                            target_hash.is_some(),
                            subprocesses[3].exit_status,
                            subprocesses[4].exit_status,
                            subprocesses[5].exit_status,
                            backup_matches,
                            subprocesses[6].exit_status,
                            is_regular_file_listing(&subprocesses[6]),
                        ),
                    };
                };
                verified([
                    ("backupSha256", backup_hash),
                    ("backupPath", deployment.backup_path.clone()),
                ])
            }
            Self::Publish(deployment) => {
                let publish_failure = || {
                    let diagnostics = subprocesses
                        .iter()
                        .enumerate()
                        .map(|(index, process)| {
                            format!("{index}:{}", bounded_process_diagnostic(process))
                        })
                        .collect::<Vec<_>>()
                        .join(";");
                    Outcome::Failed {
                        code: "nativePublishMismatch",
                        detail: format!(
                            "atomic publish did not preserve app-owned mode/uid/gid, read back the leased ELF hash, or leave the published library at least as attested as the one it replaced (subprocessCount={}, diagnostics={diagnostics})",
                            subprocesses.len()
                        ),
                    }
                };
                if subprocesses.len() != 6 {
                    return publish_failure();
                }
                let (Some(original), Some(published)) = (
                    native_file_identity(&subprocesses[0]),
                    native_file_identity(&subprocesses[5]),
                ) else {
                    return publish_failure();
                };
                if original != published
                    || sha256_token(&subprocesses[3]).as_deref()
                        != Some(deployment.artifact_facts.sha256.as_str())
                {
                    return publish_failure();
                }
                let mut summary = BTreeMap::from([
                    (
                        "publishedSha256".to_owned(),
                        deployment.artifact_facts.sha256.clone(),
                    ),
                    (
                        "buildId".to_owned(),
                        deployment.artifact_facts.build_id.clone(),
                    ),
                    ("targetPath".to_owned(), deployment.target_path.clone()),
                    ("mode".to_owned(), original.mode.clone()),
                    ("uid".to_owned(), original.user_id.to_string()),
                    ("gid".to_owned(), original.group_id.to_string()),
                ]);
                let published_attestation = readback_attestation(&subprocesses[4]);
                match readback_attestation(&subprocesses[1]) {
                    // Not an answer about the replaced file, so nothing here
                    // can say the replacement matches it.
                    Attestation::Unreadable => publish_failure(),
                    // An attested original demands an attested replacement,
                    // and the helper's own digest must agree with what the
                    // device reads back afterwards.
                    Attestation::Attested(_) => {
                        let Some(announced) = code_sign_digest(&subprocesses[2], PUBLISHED_MARKER)
                        else {
                            return publish_failure();
                        };
                        if published_attestation != Attestation::Attested(announced.clone()) {
                            return publish_failure();
                        }
                        summary.insert("fsVerityDigest".to_owned(), announced);
                        summary.insert("attestation".to_owned(), "fsVerity".to_owned());
                        Outcome::Verified(summary)
                    }
                    // At this instant the helper is the only thing that touched
                    // the file: if it reports having enabled nothing and the
                    // device reads back an attestation anyway, something
                    // unaccounted for wrote the library. No `fsVerityDigest`
                    // key at all: a record that carries the field is read as
                    // having the property.
                    Attestation::Absent => {
                        if !published_without_attestation(&subprocesses[2])
                            || published_attestation != Attestation::Absent
                        {
                            return publish_failure();
                        }
                        summary.insert(
                            "attestation".to_owned(),
                            "matchesReplacedFile:none".to_owned(),
                        );
                        Outcome::Verified(summary)
                    }
                }
            }
            Self::StopTarget(deployment) => {
                if subprocesses.len() != 4 {
                    return Outcome::Unknown(
                        "native stop did not produce its complete bounded readback sequence".into(),
                    );
                }
                let readback = &subprocesses[3];
                if !process_is_absent(readback) {
                    return Outcome::Failed {
                        code: "nativeTargetStillRunning",
                        detail: format!(
                            "{} remained live after stop (forceStopExit={}, pidofExit={}, pids={}, stdoutBytes={}, stderrBytes={})",
                            deployment.bundle.bundle_name(),
                            subprocesses[0].exit_status,
                            readback.exit_status,
                            pid_summary(readback),
                            readback.stdout.len(),
                            readback.stderr.len()
                        ),
                    };
                }
                verified([("stopped", deployment.bundle.bundle_name().to_owned())])
            }
            Self::StartTarget(deployment) => {
                let pids = (subprocesses.len() == 3)
                    .then(|| process_ids(&subprocesses[2]))
                    .flatten();
                let Some(pids) = pids.filter(|pids| !pids.is_empty()) else {
                    return Outcome::Failed {
                        code: "nativeTargetNotRunning",
                        detail: format!("{} did not start", deployment.bundle.bundle_name()),
                    };
                };
                verified([
                    ("started", deployment.bundle.bundle_name().to_owned()),
                    ("processIds", join_pids(&pids)),
                ])
            }
            Self::Cleanup(deployment) => {
                let absence = deployment.cleanup_paths().len();
                let clean = subprocesses.len() >= absence
                    && subprocesses[subprocesses.len() - absence..]
                        .iter()
                        .all(|process| path_presence(process) == Some(false));
                if !clean {
                    return failed(
                        "cleanupDebt",
                        "native staging or backup path remains after cleanup",
                    );
                }
                verified([
                    ("cleaned", deployment.staging_path.clone()),
                    (
                        "backupRetained",
                        (deployment.rollback_policy == RollbackPolicy::RetainBackup).to_string(),
                    ),
                ])
            }
            Self::Rollback(deployment) => {
                if subprocesses.len() != 13 {
                    return Outcome::Unknown(
                        "native rollback did not produce its complete bounded readback sequence"
                            .into(),
                    );
                }
                let backup_hash = sha256_token(&subprocesses[0]);
                let stop_readback = &subprocesses[4];
                let restored_hash = sha256_token(&subprocesses[8]);
                let pids = process_ids(&subprocesses[11]);
                let maps_matched = pids.as_ref().is_some_and(|pids| {
                    maps_contain(&subprocesses[12], &deployment.loader_visible_path, pids)
                });
                let hashes_match = restored_hash.is_some() && restored_hash == backup_hash;
                let (Some(backup_hash), Some(pids)) = (backup_hash.clone(), pids.clone()) else {
                    return rollback_failure(
                        subprocesses,
                        stop_readback,
                        hashes_match,
                        &pids,
                        maps_matched,
                    );
                };
                if !process_is_absent(stop_readback)
                    || !hashes_match
                    || pids.is_empty()
                    || !maps_matched
                {
                    return rollback_failure(
                        subprocesses,
                        stop_readback,
                        hashes_match,
                        &Some(pids),
                        maps_matched,
                    );
                }
                verified([
                    ("restoredSha256", backup_hash),
                    ("restored", "true".to_owned()),
                    ("processIds", join_pids(&pids)),
                ])
            }
            Self::Inspect(deployment, expectation) => {
                inspect(deployment, *expectation, subprocesses)
            }
        }
    }

    /// Bounded public facts from a confirmed backup or rollback receipt. The
    /// input ELF facts describe the replacement, not the previous library;
    /// only the whole-byte hashes describe the backup and restored bytes.
    /// Remote paths, command output and the Target's connection identity are
    /// deliberately absent. This does not change the verification verdict.
    pub fn verified_readback_evidence(&self, receipt: &FileReceipt) -> Option<Value> {
        if !matches!(self, Self::Backup(_) | Self::Rollback(_))
            || !matches!(self.verify(receipt), Outcome::Verified(_))
        {
            return None;
        }
        let deployment = self.deployment();
        let processes = &receipt.subprocesses;
        let facts = &deployment.artifact_facts;
        let mut evidence = json!({
            "schemaVersion": "arkdeck.native-library.readback/1",
            "inputABI": facts.abi.raw(),
            "inputBuildId": facts.build_id,
            "inputSha256": facts.sha256,
        });
        match self {
            Self::Backup(_) => {
                evidence["phase"] = json!("backup");
                evidence["currentSha256"] = json!(sha256_token(&processes[2])?);
                evidence["backupSha256"] = json!(sha256_token(&processes[5])?);
            }
            Self::Rollback(_) => {
                let pids = process_ids(&processes[11])?;
                let maps = &processes[12].stdout;
                let text = std::str::from_utf8(maps).ok()?;
                let matches = |line: &str, pid: &u32| {
                    line.starts_with(&format!("/proc/{pid}/maps:"))
                        && line.contains(&deployment.loader_visible_path)
                };
                let mapped: Vec<u32> = pids
                    .iter()
                    .copied()
                    .filter(|pid| text.lines().any(|line| matches(line, pid)))
                    .collect();
                let count = text
                    .lines()
                    .filter(|line| pids.iter().any(|pid| matches(line, pid)))
                    .count();
                evidence["phase"] = json!("rollback");
                evidence["backupSha256"] = json!(sha256_token(&processes[0])?);
                evidence["restoredSha256"] = json!(sha256_token(&processes[8])?);
                evidence["processIds"] = json!(pids);
                evidence["mappedProcessIds"] = json!(mapped);
                evidence["mapsVerified"] = json!(maps_contain(
                    &processes[12],
                    &deployment.loader_visible_path,
                    &pids,
                ));
                evidence["mapsSha256"] = json!(arkdeck_contract::sha256_hex(maps));
                evidence["mapsByteCount"] = json!(maps.len());
                evidence["matchingMapLineCount"] = json!(count);
                evidence["loaderPathSha256"] = json!(arkdeck_contract::sha256_hex(
                    deployment.loader_visible_path.as_bytes(),
                ));
            }
            _ => return None,
        }
        Some(evidence)
    }

    /// Swift `reconciliationReadback`: the inspection that concludes this
    /// mutation without resending it; nothing for an inspection.
    pub fn readback(&self) -> Option<Self> {
        let deployment = self.deployment().clone();
        let expectation = match self {
            Self::SendToStaging(_) => Inspection::StagingMatchesArtifact,
            Self::Backup(_) => Inspection::BackupMatchesTarget,
            Self::Publish(_) => Inspection::TargetMatchesArtifact,
            Self::StopTarget(_) => Inspection::TargetStopped,
            Self::StartTarget(_) => Inspection::TargetStarted,
            Self::Cleanup(_) => Inspection::CleanupComplete,
            Self::Rollback(_) => Inspection::RollbackRestored,
            Self::Inspect(..) => return None,
        };
        Some(Self::Inspect(deployment, expectation))
    }

    /// Swift `verifyReconciliationReadback`'s native arms: what a readback's
    /// verdict concludes about the original mutation — a failed readback is
    /// "not executed" for the idempotent mutations, but never for a publish
    /// (its state is not safe to replay) nor a rollback.
    pub fn reconcile(&self, readback_outcome: Outcome) -> Reconcile {
        match readback_outcome {
            Outcome::Verified(summary) => Reconcile::ConfirmedCompleted(summary),
            Outcome::Failed { code, detail } => match self {
                Self::Publish(_) => Reconcile::StillUnknown(format!(
                    "{code}: {detail}; publish state is not safe to replay"
                )),
                Self::Rollback(_) => Reconcile::StillUnknown(format!("{code}: {detail}")),
                Self::Inspect(..) => {
                    Reconcile::StillUnknown("original action has no dedicated readback".into())
                }
                _ => Reconcile::ConfirmedNotExecuted,
            },
            Outcome::Unknown(reason) | Outcome::Unsupported(reason) => {
                Reconcile::StillUnknown(reason)
            }
        }
    }
}
