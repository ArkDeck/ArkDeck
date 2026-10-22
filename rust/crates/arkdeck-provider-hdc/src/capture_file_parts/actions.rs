impl FileAction {
    /// Swift `HDCObservationProviderAdapter.action` for a
    /// `capture.diagnostics@1` step this module owns, with the request's
    /// inputs and the Job the owned paths are minted for. `None` is a step
    /// of another owner (the default legs, the observe and storage steps);
    /// an error is Swift's refusal of the request for it.
    pub fn for_step(
        step_id: &str,
        kind: &str,
        action_id: Option<&str>,
        inputs: &Map<String, Value>,
        job_id: &str,
    ) -> Result<Option<Self>, FileActionError> {
        let unsupported = |detail: String| Err(FileActionError::Unsupported(detail));
        match kind {
            "captureRemoteStdout" => match action_id {
                Some("componentDetail") => {
                    let (Some(window_id), Some(component_id)) = (
                        string_input(inputs, "windowId"),
                        string_input(inputs, "componentId"),
                    ) else {
                        return unsupported(
                            "componentDetail requires typed windowId and componentId inputs".into(),
                        );
                    };
                    Ok(Some(Self::component_detail(window_id, component_id)?))
                }
                Some("crashIndex") => Ok(Some(Self::CaptureCrashIndex {
                    byte_budget: STDOUT_BUDGET,
                })),
                Some("crashLog") => {
                    let Some(name) = string_input(inputs, "crashLogName") else {
                        return unsupported(
                            "crashLogName input is required to fetch one Faultlogger entry".into(),
                        );
                    };
                    Ok(Some(Self::CaptureCrashLog {
                        name: FaultLogName::new(name)?,
                        byte_budget: STDOUT_BUDGET,
                    }))
                }
                Some("componentTree") => unsupported(
                    "componentTree is a file product, not stdout: use the uiComponentTree \
                     input, which selects the capture-ui-tree file steps; a \
                     captureRemoteStdout step cannot carry it"
                        .into(),
                ),
                Some("windowInventory") | Some("boundedHilog") => Ok(None),
                Some(other) => {
                    unsupported(format!("unregistered stdout action {other} for {step_id}"))
                }
                None => unsupported(format!(
                    "{step_id} declares no catalog action; refusing to infer one"
                )),
            },
            "verifyRemoteState" if step_id == "observe-application-liveness" => {
                let Some(bundle) = string_input(inputs, "bundleName") else {
                    return unsupported("bundleName is required for application liveness".into());
                };
                Ok(Some(Self::ObserveApplicationLiveness(
                    LivenessRequest::new(
                        bundle,
                        string_input(inputs, "abilityName"),
                        string_input(inputs, "processName"),
                        string_input(inputs, "expectedDeployedArtifactDigest"),
                    )?,
                )))
            }
            "captureRemoteFile" => match step_id {
                "capture-session-trace" => {
                    let mut request = trace_request(inputs, job_id)?;
                    request.ring_buffered = true;
                    request.coverage_anchor = Some(TraceRequest::anchor(job_id, step_id));
                    Ok(Some(Self::CaptureDiagnosticTrace {
                        request,
                        path: OwnedRemotePath::stable(job_id, "capture-trace", ImageType::Png)?,
                    }))
                }
                "capture-screen-sequence" => Ok(Some(Self::CaptureScreenSequence {
                    request: screen_sequence_request(inputs)?,
                    frames: OwnedRemoteDirectory::stable_frames(job_id, "capture-screen-sequence")?,
                    archive: OwnedRemotePath::stable(
                        job_id,
                        "capture-screen-sequence",
                        ImageType::Png,
                    )?,
                })),
                "capture-screenshot" => {
                    let image_type = screenshot_image_type(inputs);
                    Ok(Some(Self::CaptureScreenshot {
                        image_type,
                        path: OwnedRemotePath::stable(job_id, "capture-screenshot", image_type)?,
                    }))
                }
                "capture-ui-tree" => Ok(Some(Self::CaptureComponentTree {
                    path: OwnedRemotePath::stable(job_id, "capture-ui-tree", ImageType::Png)?,
                })),
                _ => Ok(Some(Self::CaptureTrace {
                    request: trace_request(inputs, job_id)?,
                    path: OwnedRemotePath::stable(job_id, "capture-trace", ImageType::Png)?,
                })),
            },
            "receiveFile" => {
                // Each receive leg re-mints its producer's owned path, which
                // keeps the received bytes bound to the step that wrote them.
                let producer = file_producer_step_id(step_id);
                let received_type = screenshot_image_type(inputs);
                Ok(Some(Self::ReceiveOwnedArtifact(ReceiveArtifact {
                    path: OwnedRemotePath::stable(job_id, producer, received_type)?,
                    expected_sha256: None,
                    maximum_bytes: RECEIVE_MAXIMUM_BYTES,
                    expected_leading_bytes: (step_id == "receive-screenshot")
                        .then(|| received_type.magic().to_vec()),
                })))
            }
            "cleanupOwnedRemotePath" => {
                if step_id == "cleanup-screen-sequence-temp" {
                    return Ok(Some(Self::CleanupScreenSequence {
                        request: screen_sequence_request(inputs)?,
                        frames: OwnedRemoteDirectory::stable_frames(
                            job_id,
                            "capture-screen-sequence",
                        )?,
                        archive: OwnedRemotePath::stable(
                            job_id,
                            "capture-screen-sequence",
                            ImageType::Png,
                        )?,
                    }));
                }
                Ok(Some(Self::CleanupOwnedRemotePath {
                    path: OwnedRemotePath::stable(
                        job_id,
                        file_producer_step_id(step_id),
                        screenshot_image_type(inputs),
                    )?,
                }))
            }
            _ => Ok(None),
        }
    }

    /// Swift `HDCUIDumpRequest(scope: .componentDetail, …)`: decimal
    /// identifiers of at most twenty digits.
    pub fn component_detail(window_id: &str, component_id: &str) -> Result<Self, RequestError> {
        let identifier = |value: &str| {
            (1..=20).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_digit())
        };
        if !identifier(window_id) || !identifier(component_id) {
            return Err(RequestError::Malformed {
                field: "componentDetail",
                detail: "windowID and componentID must be decimal identifiers",
            });
        }
        Ok(Self::CaptureComponentDetail {
            window_id: window_id.to_owned(),
            component_id: component_id.to_owned(),
        })
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::CaptureCrashIndex { .. }
            | Self::CaptureCrashLog { .. }
            | Self::CaptureComponentDetail { .. }
            | Self::ObserveApplicationLiveness(_)
            | Self::ReceiveOwnedArtifact(_) => "readOnly",
            Self::CaptureTrace { .. }
            | Self::CaptureDiagnosticTrace { .. }
            | Self::CaptureComponentTree { .. }
            | Self::CaptureScreenshot { .. }
            | Self::CaptureScreenSequence { .. }
            | Self::CleanupScreenSequence { .. }
            | Self::CleanupOwnedRemotePath { .. } => "deviceMutation",
        }
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for the persisted
    /// kinds of these legs Swift knows: the action a kind and its arguments
    /// name, rebuilt through the same constructors, in Swift's order, and
    /// refused as Swift refuses it — but that a receive or a cleanup of a
    /// JPEG still is rebuilt with the still's own suffix, a declared
    /// difference (`PersistedArguments::recorded_path`). `None` is a kind of
    /// another family — or one of the screen sequence's two, which Swift's
    /// materialization does not know and [`ParkedScreenSequence`] reads. A
    /// cleanup of an owned path is the one kind the debug HAP's family
    /// shares; it is rebuilt here as this leg's.
    pub fn from_persisted(
        kind: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let persisted = PersistedArguments { kind, arguments };
        Ok(Some(match kind {
            "hdc.captureCrashIndex" => Self::CaptureCrashIndex {
                byte_budget: persisted.integer("byteBudget")?,
            },
            "hdc.captureCrashLog" => Self::CaptureCrashLog {
                name: FaultLogName::new(persisted.string("faultLogName")?)?,
                byte_budget: persisted.integer("byteBudget")?,
            },
            "hdc.captureTrace" => {
                let request = TraceRequest::new(
                    persisted.integer("durationSeconds")?,
                    persisted.string_array("categories")?,
                    persisted.integer("bufferKB")?,
                    false,
                    None,
                )?;
                Self::CaptureTrace {
                    request,
                    path: persisted.owned_path(ImageType::Png)?,
                }
            }
            "hdc.captureComponentTree" => Self::CaptureComponentTree {
                path: persisted.owned_path(ImageType::Png)?,
            },
            // An absent or unknown type is a PNG, as Swift reads it.
            "hdc.captureScreenshot" => {
                let image_type = persisted
                    .string("imageType")
                    .ok()
                    .and_then(ImageType::parse)
                    .unwrap_or(ImageType::Png);
                Self::CaptureScreenshot {
                    image_type,
                    path: persisted.owned_path(image_type)?,
                }
            }
            "hdc.receiveOwnedArtifact" => {
                let path = persisted.recorded_path()?;
                let expected_sha256 = persisted.optional_string("expectedSha256")?;
                let maximum_bytes = persisted.integer("maximumBytes")?;
                let leading = persisted.optional_string("expectedLeadingBytes")?;
                Self::ReceiveOwnedArtifact(ReceiveArtifact {
                    path,
                    expected_sha256: expected_sha256.map(str::to_owned),
                    maximum_bytes,
                    expected_leading_bytes: leading.map(lenient_hex),
                })
            }
            "hdc.observeApplicationLiveness" => {
                let bundle = persisted.bundle()?;
                Self::ObserveApplicationLiveness(LivenessRequest::new(
                    bundle.bundle_name(),
                    persisted.optional_string("abilityName")?,
                    persisted.optional_string("processName")?,
                    persisted.optional_string("expectedDeployedArtifactDigest")?,
                )?)
            }
            "hdc.cleanupOwnedRemotePath" => Self::CleanupOwnedRemotePath {
                path: persisted.recorded_path()?,
            },
            _ => return Ok(None),
        }))
    }

    /// The provider-owned file a capture leg writes on the device, which a
    /// reconcile reads back to conclude the capture (Swift
    /// `reconciliationReadback`: `.readOwnedPathPresence(path)`); none for a
    /// leg that writes no such file.
    pub fn written_path(&self) -> Option<&OwnedRemotePath> {
        match self {
            Self::CaptureTrace { path, .. }
            | Self::CaptureComponentTree { path }
            | Self::CaptureScreenshot { path, .. } => Some(path),
            _ => None,
        }
    }

    /// Swift `PersistedTypedProviderAction`: the kind and arguments a Job
    /// record keeps before the action's intent can be dispatched.
    pub fn persisted(&self) -> (&'static str, Vec<(&'static str, Persisted)>) {
        let text = |value: &str| Persisted::Text(value.into());
        let path_arguments = |path: &OwnedRemotePath| {
            vec![
                ("jobId", text(&path.job_id)),
                ("stepId", text(&path.step_id)),
                ("nonce", text(&path.nonce)),
                ("remotePath", text(&path.remote_path)),
            ]
        };
        match self {
            Self::CaptureCrashIndex { byte_budget } => (
                "hdc.captureCrashIndex",
                vec![("byteBudget", Persisted::Integer(*byte_budget))],
            ),
            Self::CaptureCrashLog { name, byte_budget } => (
                "hdc.captureCrashLog",
                vec![
                    ("faultLogName", text(name.value())),
                    ("byteBudget", Persisted::Integer(*byte_budget)),
                ],
            ),
            Self::CaptureComponentDetail {
                window_id,
                component_id,
            } => (
                "hdc.captureUIDump",
                vec![
                    ("scope", text("componentDetail")),
                    ("byteBudget", Persisted::Integer(UI_DUMP_BUDGET)),
                    ("windowId", text(window_id)),
                    ("componentId", text(component_id)),
                ],
            ),
            Self::ObserveApplicationLiveness(request) => {
                let mut arguments = vec![
                    ("bundleName", text(&request.bundle_name)),
                    ("processName", text(&request.process_name)),
                ];
                if let Some(ability) = &request.ability_name {
                    arguments.push(("abilityName", text(ability)));
                }
                if let Some(digest) = &request.expected_deployed_artifact_digest {
                    arguments.push(("expectedDeployedArtifactDigest", text(digest)));
                }
                ("hdc.observeApplicationLiveness", arguments)
            }
            Self::CaptureTrace { request, path }
            | Self::CaptureDiagnosticTrace { request, path } => {
                let mut arguments = path_arguments(path);
                arguments.push((
                    "durationSeconds",
                    Persisted::Integer(request.duration_seconds),
                ));
                arguments.push(("categories", Persisted::Texts(request.categories.clone())));
                arguments.push(("bufferKB", Persisted::Integer(request.buffer_kb)));
                if matches!(self, Self::CaptureDiagnosticTrace { .. }) {
                    if let Some(anchor) = &request.coverage_anchor {
                        arguments.push(("coverageAnchor", text(anchor)));
                    }
                    ("hdc.captureDiagnosticTrace", arguments)
                } else {
                    ("hdc.captureTrace", arguments)
                }
            }
            Self::CaptureComponentTree { path } => {
                ("hdc.captureComponentTree", path_arguments(path))
            }
            Self::CaptureScreenshot { image_type, path } => {
                let mut arguments = path_arguments(path);
                arguments.push(("imageType", text(image_type.raw())));
                ("hdc.captureScreenshot", arguments)
            }
            Self::CaptureScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut arguments = path_arguments(archive);
                arguments.push(("framesDirectory", text(&frames.remote_path)));
                arguments.push(("frameCount", Persisted::Integer(request.frame_count)));
                arguments.push(("imageType", text(request.image_type.raw())));
                if let (Some(width), Some(height)) = (request.width, request.height) {
                    arguments.push(("width", Persisted::Integer(width)));
                    arguments.push(("height", Persisted::Integer(height)));
                }
                if let Some(display_id) = request.display_id {
                    arguments.push(("displayId", Persisted::Integer(display_id)));
                }
                ("hdc.captureScreenSequence", arguments)
            }
            Self::CleanupScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut arguments = path_arguments(archive);
                arguments.push(("framesDirectory", text(&frames.remote_path)));
                arguments.push(("frameCount", Persisted::Integer(request.frame_count)));
                ("hdc.cleanupScreenSequence", arguments)
            }
            Self::ReceiveOwnedArtifact(artifact) => {
                let mut arguments = path_arguments(&artifact.path);
                arguments.push(("maximumBytes", Persisted::Integer(artifact.maximum_bytes)));
                if let Some(expected) = &artifact.expected_sha256 {
                    arguments.push(("expectedSha256", text(expected)));
                }
                if let Some(magic) = &artifact.expected_leading_bytes {
                    arguments.push(("expectedLeadingBytes", text(&hex(magic))));
                }
                ("hdc.receiveOwnedArtifact", arguments)
            }
            Self::CleanupOwnedRemotePath { path } => {
                ("hdc.cleanupOwnedRemotePath", path_arguments(path))
            }
        }
    }

    /// Swift `lower`: the process or process sequence the executor runs, each
    /// invocation with its budget, and for a receive the host landing the
    /// bytes must reach. A device action names its target by the binding's
    /// connect key and has none without one.
    pub fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        host_receive_root: &Path,
    ) -> Result<FilePlan, String> {
        self.lower_in(step_id, connect_key, Some(host_receive_root))
    }

    /// Whether the leg lands a file on the host, and so lowers only where a
    /// host receive root names the landing.
    pub fn receives(&self) -> bool {
        matches!(self, Self::ReceiveOwnedArtifact(_))
    }

    /// [`Self::lower`] where the composition may name no host receive root:
    /// every leg but a receive lowers without one, since only a receive's
    /// argv names a host path.
    pub fn lower_in(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        host_receive_root: Option<&Path>,
    ) -> Result<FilePlan, String> {
        let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
            return Err(format!(
                "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
            ));
        };
        let device = |tail: Vec<String>| -> Vec<String> { device_arguments(key, tail) };
        let owned = |tail: &[&str]| device(tail.iter().map(|part| (*part).to_owned()).collect());
        let process = |arguments: Vec<String>, seconds: u64| {
            FilePlan::Process(ProcessPlan {
                arguments,
                timeout: Duration::from_secs(seconds),
                capture_bytes: CAPTURE_BYTES,
            })
        };
        let invocation =
            |arguments: Vec<String>, seconds: u64, continue_after_non_zero: bool| Invocation {
                arguments,
                timeout: Duration::from_secs(seconds),
                continue_after_non_zero,
            };
        let readback = |path: &str| invocation(owned(&["shell", "ls", "-l", path]), 15, false);
        Ok(match self {
            // The `-p …` payload is a single argv element after `-a`, exactly
            // as DEVICE-COMMAND-FACTS.md §6 records it; Faultlogger's SA id
            // is 1201.
            Self::CaptureCrashIndex { .. } => process(
                owned(&["shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger -l"]),
                30,
            ),
            Self::CaptureCrashLog { name, .. } => process(
                device(vec![
                    "shell".into(),
                    "hidumper".into(),
                    "-s".into(),
                    "1201".into(),
                    "-a".into(),
                    format!("-p Faultlogger -f {}", name.value()),
                ]),
                30,
            ),
            Self::CaptureComponentDetail {
                window_id,
                component_id,
            } => process(
                device(vec![
                    "shell".into(),
                    "hidumper".into(),
                    "-s".into(),
                    "WindowManagerService".into(),
                    "-a".into(),
                    format!("-w {window_id} -element -lastpage {component_id}"),
                ]),
                30,
            ),
            Self::ObserveApplicationLiveness(request) => {
                process(owned(&["shell", "pidof", &request.process_name]), 30)
            }
            Self::CaptureDiagnosticTrace { request, path } => {
                return crate::diagnostic_trace::lower(
                    request,
                    path,
                    connect_key,
                    host_receive_root,
                );
            }
            Self::CaptureTrace { request, path } if request.ring_buffered => {
                // Arm, let the window pass, snapshot, stop. `--overwrite` is
                // deliberately absent: with it the newest traces are
                // discarded, and the default is what drops the oldest.
                let mut ring = vec![invocation(
                    device(
                        ["shell", "hitrace", "--trace_begin", "-b"]
                            .into_iter()
                            .map(str::to_owned)
                            .chain(std::iter::once(request.buffer_kb.to_string()))
                            .chain(request.categories.iter().cloned())
                            .collect(),
                    ),
                    30,
                    false,
                )];
                if let Some(anchor) = &request.coverage_anchor {
                    // One quoted line each rather than argv elements: passing
                    // the redirect as its own element does not redirect on
                    // this path. The anchor is letters and digits, so nothing
                    // in the line is a shell's to reinterpret.
                    ring.push(invocation(
                        device(vec![
                            "shell".into(),
                            format!("echo {anchor} > {TRACE_MARKER_PATH}"),
                        ]),
                        15,
                        false,
                    ));
                    ring.push(invocation(
                        device(vec![
                            "shell".into(),
                            format!("grep -c {anchor} {TRACE_RING_PATH}"),
                        ]),
                        15,
                        false,
                    ));
                }
                ring.push(invocation(
                    owned(&["shell", "sleep", &request.duration_seconds.to_string()]),
                    request.duration_seconds.unsigned_abs() + 30,
                    false,
                ));
                ring.push(invocation(
                    owned(&["shell", "hitrace", "--trace_dump", "-o", &path.remote_path]),
                    120,
                    true,
                ));
                // Stopping without a second dump: the snapshot above is the
                // product.
                ring.push(invocation(
                    owned(&["shell", "hitrace", "--trace_finish_nodump"]),
                    30,
                    true,
                ));
                ring.push(readback(&path.remote_path));
                FilePlan::Sequence(ring)
            }
            // hitrace's own exit status is the client's, not the remote
            // command's: the capture is judged by the file it was to write,
            // and `ls -l` runs even when hitrace reports non-zero — a partial
            // trace is still a fact the readback should report.
            Self::CaptureTrace { request, path } => FilePlan::Sequence(vec![
                invocation(
                    device(
                        ["shell", "hitrace", "-t"]
                            .into_iter()
                            .map(str::to_owned)
                            .chain([request.duration_seconds.to_string(), "-b".to_owned()])
                            .chain(std::iter::once(request.buffer_kb.to_string()))
                            .chain(request.categories.iter().cloned())
                            .chain(["-o".to_owned(), path.remote_path.clone()])
                            .collect(),
                    ),
                    request.duration_seconds.unsigned_abs() + 30,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // `uitest dumpLayout -p <file>` needs neither `-w` nor `-d` and
            // answers a status line; the file, read back, is the evidence.
            Self::CaptureComponentTree { path } => FilePlan::Sequence(vec![
                invocation(
                    owned(&["shell", "uitest", "dumpLayout", "-p", &path.remote_path]),
                    60,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // `-t` is mandatory: the device refuses a name whose suffix
            // disagrees with the type, so the flag and the suffix are one
            // decision made once.
            Self::CaptureScreenshot { image_type, path } => FilePlan::Sequence(vec![
                invocation(
                    owned(&[
                        "shell",
                        "snapshot_display",
                        "-t",
                        image_type.raw(),
                        "-f",
                        &path.remote_path,
                    ]),
                    60,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // One typed invocation per frame, never a device-side loop; a
            // frame that fails is a gap in the sequence, not the end of it.
            Self::CaptureScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut invocations = vec![invocation(
                    owned(&["shell", "mkdir", "-p", &frames.remote_path]),
                    30,
                    false,
                )];
                for index in 0..request.frame_count {
                    let mut capture: Vec<String> = ["shell", "snapshot_display", "-t"]
                        .into_iter()
                        .map(str::to_owned)
                        .collect();
                    capture.push(request.image_type.raw().to_owned());
                    if let (Some(width), Some(height)) = (request.width, request.height) {
                        capture.extend([
                            "-w".to_owned(),
                            width.to_string(),
                            "-h".to_owned(),
                            height.to_string(),
                        ]);
                    }
                    if let Some(display_id) = request.display_id {
                        capture.extend(["-i".to_owned(), display_id.to_string()]);
                    }
                    capture.push("-f".to_owned());
                    capture.push(format!(
                        "{}/{}",
                        frames.remote_path,
                        request.frame_name(index)
                    ));
                    invocations.push(invocation(device(capture), 60, true));
                }
                invocations.push(invocation(
                    owned(&[
                        "shell",
                        "tar",
                        "-c",
                        "-f",
                        &archive.remote_path,
                        "-C",
                        &frames.remote_path,
                        ".",
                    ]),
                    120,
                    true,
                ));
                invocations.push(readback(&archive.remote_path));
                FilePlan::Sequence(invocations)
            }
            // `rm -f` naming exactly the frames this provider wrote, then the
            // archive, then `rmdir` — never `rm -rf`; `ls -ld`, not `ls -d`,
            // because the presence parser accepts exactly one listing line
            // or the not-found grammar.
            Self::CleanupScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut remove: Vec<String> = ["shell", "rm", "-f"]
                    .into_iter()
                    .map(str::to_owned)
                    .collect();
                remove.extend(
                    (0..request.frame_count).map(|index| {
                        format!("{}/{}", frames.remote_path, request.frame_name(index))
                    }),
                );
                FilePlan::Sequence(vec![
                    invocation(device(remove), 60, true),
                    invocation(
                        owned(&["shell", "rm", "-f", &archive.remote_path]),
                        30,
                        true,
                    ),
                    invocation(owned(&["shell", "rmdir", &frames.remote_path]), 30, true),
                    invocation(
                        owned(&["shell", "ls", "-ld", &frames.remote_path]),
                        15,
                        true,
                    ),
                ])
            }
            // `file recv` takes both paths; the local name is the remote
            // basename so that both landing forms hdc builds use land on the
            // same path instead of on a guess.
            Self::ReceiveOwnedArtifact(artifact) => {
                let Some(host_receive_root) = host_receive_root else {
                    return Err(format!(
                        "{step_id} lowers only within a composition that names its host receive \
                         root"
                    ));
                };
                let destination = host_landing(host_receive_root, &artifact.path);
                FilePlan::Receive {
                    process: ProcessPlan {
                        arguments: device(vec![
                            "file".into(),
                            "recv".into(),
                            artifact.path.remote_path.clone(),
                            destination.to_string_lossy().into_owned(),
                        ]),
                        timeout: Duration::from_secs(60),
                        capture_bytes: CAPTURE_BYTES,
                    },
                    landing: HostLanding {
                        destination,
                        maximum_bytes: artifact.maximum_bytes,
                        expected_sha256: artifact.expected_sha256.clone(),
                    },
                }
            }
            Self::CleanupOwnedRemotePath { path } => {
                process(owned(&["shell", "rm", "-f", &path.remote_path]), 15)
            }
        })
    }

    /// Swift `verify` for these legs: a file product is judged by its
    /// readback, a received one by the bytes that landed, a cleanup by what
    /// the device still shows — never by the client's exit status, which is
    /// the transport's, not the remote command's.
    pub fn verify(&self, receipt: &FileReceipt, now_utc: &str) -> Outcome {
        match self {
            Self::CaptureCrashIndex { .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("crash index produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "crash index exceeded its budget");
                }
                let Ok(text) = std::str::from_utf8(&process.stdout) else {
                    return failed("invalidEncoding", "crash index is not UTF-8");
                };
                // An empty ledger is a truthful answer, not a failure.
                verified([
                    ("entryCount", fault_log_entries(text).len().to_string()),
                    ("byteCount", process.stdout.len().to_string()),
                ])
            }
            Self::CaptureCrashLog { name, .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("crash log produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "crash log exceeded its budget");
                }
                let Ok(text) = std::str::from_utf8(&process.stdout) else {
                    return failed("invalidEncoding", "crash log is not UTF-8");
                };
                if text.contains("invalid parameters.") {
                    // The device's answer for a name it does not have.
                    return Outcome::Failed {
                        code: "faultLogNotFound",
                        detail: format!("device has no entry named {}", name.value()),
                    };
                }
                if !text.contains("Generated by HiviewDFX") {
                    return Outcome::Unknown("crash log did not carry its HiviewDFX header".into());
                }
                verified([
                    ("faultLogName", name.value().to_owned()),
                    ("byteCount", process.stdout.len().to_string()),
                ])
            }
            Self::CaptureComponentDetail { .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("UI dump produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "capture exceeded its byte budget");
                }
                if std::str::from_utf8(&process.stdout).is_err() {
                    return failed("invalidEncoding", "UI dump is not UTF-8");
                }
                if process.stdout.is_empty() {
                    return Outcome::Unknown("empty capture output".into());
                }
                verified([("byteCount", process.stdout.len().to_string())])
            }
            Self::ObserveApplicationLiveness(request) => liveness(request, receipt, now_utc),
            Self::CaptureTrace { request, path }
            | Self::CaptureDiagnosticTrace { request, path } => {
                // begin, [write anchor, read anchor,] window, dump, stop,
                // readback — or the blocking capture and its readback.
                let expected = if matches!(self, Self::CaptureDiagnosticTrace { .. }) {
                    6
                } else if request.ring_buffered {
                    if request.coverage_anchor.is_none() {
                        5
                    } else {
                        7
                    }
                } else {
                    2
                };
                if receipt.subprocesses.len() != expected {
                    return Outcome::Unknown(
                        "trace capture did not produce its readback sequence".into(),
                    );
                }
                let Some(readback) = receipt.subprocesses.last() else {
                    return Outcome::Unknown(
                        "trace capture did not produce its readback sequence".into(),
                    );
                };
                // The anchor readback is in this receipt, so whether the ring
                // was holding it is a fact this verdict already has.
                let mut anchor_held = None;
                if request.coverage_anchor.is_some() && receipt.subprocesses.len() >= 3 {
                    let counted = String::from_utf8_lossy(&receipt.subprocesses[2].stdout);
                    let Ok(occurrences) = counted.trim().parse::<i64>() else {
                        return Outcome::Unknown(
                            "the ring did not answer whether it was holding the coverage anchor"
                                .into(),
                        );
                    };
                    anchor_held = Some(occurrences > 0);
                }
                let Some(byte_count) = remote_regular_file_byte_count(readback) else {
                    // Includes `ls: …: No such file or directory`: the
                    // mutation ran, so this is genuinely unknown.
                    return Outcome::Unknown(format!(
                        "trace readback did not describe {} as a regular file",
                        path.remote_path
                    ));
                };
                if byte_count <= 0 {
                    return Outcome::Failed {
                        code: "emptyTrace",
                        detail: format!("hitrace left a zero-byte file at {}", path.remote_path),
                    };
                }
                let mut summary = BTreeMap::new();
                summary.insert("remoteByteCount".to_owned(), byte_count.to_string());
                if let Some(held) = anchor_held {
                    summary.insert(
                        "ringHeldCoverageAnchor".to_owned(),
                        if held { "true" } else { "false" }.to_owned(),
                    );
                }
                if let Some(anchor) = &request.coverage_anchor {
                    summary.insert("coverageAnchor".to_owned(), anchor.clone());
                }
                Outcome::Verified(summary)
            }
            Self::CaptureComponentTree { path } => file_product(
                receipt,
                2,
                1,
                path,
                "component tree dump did not produce its readback sequence",
                "tree readback",
                "emptyComponentTree",
                "uitest",
            ),
            Self::CaptureScreenshot { path, .. } => file_product(
                receipt,
                2,
                1,
                path,
                "screenshot did not produce its readback sequence",
                "screenshot readback",
                "emptyScreenshot",
                "snapshot_display",
            ),
            Self::CaptureScreenSequence {
                request, archive, ..
            } => {
                // mkdir + N frames + tar + readback; the expected count is
                // tied to the shape the lowering emits.
                let expected = usize::try_from(request.frame_count)
                    .unwrap_or(usize::MAX)
                    .saturating_add(3);
                if receipt.subprocesses.len() != expected {
                    return Outcome::Unknown(format!(
                        "screen sequence did not produce its {expected}-step readback sequence"
                    ));
                }
                let Some(byte_count) =
                    remote_regular_file_byte_count(&receipt.subprocesses[expected - 1])
                else {
                    return Outcome::Unknown(format!(
                        "sequence readback did not describe {} as a regular file",
                        archive.remote_path
                    ));
                };
                if byte_count <= 0 {
                    return Outcome::Failed {
                        code: "emptyScreenSequence",
                        detail: format!("tar left a zero-byte archive at {}", archive.remote_path),
                    };
                }
                // A frame that failed is a gap, not a failure of the run: the
                // count actually captured travels as a fact, and each frame's
                // own duration with it.
                let frames = &receipt.subprocesses[1..expected - 2];
                let captured = frames.iter().filter(|frame| frame.exit_status == 0).count();
                let elapsed: f64 = frames
                    .iter()
                    .map(|frame| frame.duration.as_secs_f64())
                    .sum();
                let mut summary = BTreeMap::new();
                summary.insert("remoteByteCount".to_owned(), byte_count.to_string());
                summary.insert(
                    "requestedFrameCount".to_owned(),
                    request.frame_count.to_string(),
                );
                summary.insert("capturedFrameCount".to_owned(), captured.to_string());
                summary.insert(
                    "frameDurationsSeconds".to_owned(),
                    frames
                        .iter()
                        .map(|frame| format!("{:.3}", frame.duration.as_secs_f64()))
                        .collect::<Vec<_>>()
                        .join(","),
                );
                if captured > 0 && elapsed > 0.0 {
                    summary.insert(
                        "observedFramesPerSecond".to_owned(),
                        format!("{:.2}", captured as f64 / elapsed),
                    );
                }
                Outcome::Verified(summary)
            }
            Self::CleanupScreenSequence { frames, .. } => {
                // The directory being absent from the listing is the proof;
                // neither `rmdir`'s exit nor the readback's decides it.
                let Some(last) = receipt.subprocesses.last() else {
                    return Outcome::Unknown("sequence cleanup produced no readback".into());
                };
                let Some(present) = path_presence(last) else {
                    return Outcome::Unknown(format!(
                        "sequence cleanup readback did not answer whether {} is still there",
                        frames.remote_path
                    ));
                };
                if present {
                    return Outcome::Failed {
                        code: "sequenceCleanupResidue",
                        detail: format!("{} still exists after cleanup", frames.remote_path),
                    };
                }
                verified([("cleaned", "true".to_owned())])
            }
            Self::ReceiveOwnedArtifact(artifact) => {
                // `file recv` exits 0 on forms that transfer nothing and its
                // stdout is a progress line: only the landed bytes decide.
                let Some(landed) = &receipt.landed else {
                    return Outcome::Unknown(
                        "receive left no file at the declared destination".into(),
                    );
                };
                if landed.byte_count == 0 {
                    return Outcome::Failed {
                        code: "emptyArtifact",
                        detail: format!("received file for {} is empty", artifact.path.remote_path),
                    };
                }
                if landed.byte_count > artifact.maximum_bytes.unsigned_abs() {
                    return Outcome::Failed {
                        code: "oversizedArtifact",
                        detail: format!(
                            "received {} bytes over the {} byte budget",
                            landed.byte_count, artifact.maximum_bytes
                        ),
                    };
                }
                let Some(sha256) = &landed.sha256 else {
                    return Outcome::Unknown("received file could not be digested".into());
                };
                if artifact
                    .expected_sha256
                    .as_ref()
                    .is_some_and(|expected| expected != sha256)
                {
                    return failed(
                        "hashMismatch",
                        "received bytes do not match the pinned content hash",
                    );
                }
                if artifact
                    .expected_leading_bytes
                    .as_ref()
                    .is_some_and(|magic| !landed.leading.starts_with(magic))
                {
                    return failed(
                        "unexpectedFormat",
                        "received bytes do not begin with the pinned magic",
                    );
                }
                // The name, not the path: the summary is journalled and
                // published, and the host layout is not evidence.
                verified([
                    (
                        "localArtifact",
                        landed
                            .path
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                            .unwrap_or_default(),
                    ),
                    ("byteCount", landed.byte_count.to_string()),
                    ("sha256", sha256.clone()),
                ])
            }
            Self::CleanupOwnedRemotePath { path } => {
                // Cleanup failure is debt, never silently dropped.
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("remote cleanup produced no process result".into());
                };
                if process.exit_status != 0 {
                    return Outcome::Failed {
                        code: "cleanupDebt",
                        detail: format!("remote cleanup failed for {}", path.remote_path),
                    };
                }
                verified([("cleaned", path.remote_path.clone())])
            }
        }
    }
}
