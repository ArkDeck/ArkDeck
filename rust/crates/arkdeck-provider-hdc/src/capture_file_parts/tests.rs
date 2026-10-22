mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "150100424a544e4600";

    fn inputs(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    fn sub(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(10),
        }
    }

    fn sequence(receipts: Vec<Receipt>) -> FileReceipt {
        FileReceipt {
            subprocesses: receipts,
            landed: None,
        }
    }

    fn trace() -> FileAction {
        FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, false, None).unwrap(),
            path: OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png)
                .unwrap(),
        }
    }

    fn arguments(plan: &FilePlan) -> Vec<Vec<String>> {
        match plan {
            FilePlan::DiagnosticTrace { .. } => {
                panic!("legacy capture must not use interactive session lowering")
            }
            FilePlan::Process(process) | FilePlan::Receive { process, .. } => {
                vec![process.arguments.clone()]
            }
            FilePlan::Sequence(invocations) => invocations
                .iter()
                .map(|invocation| invocation.arguments.clone())
                .collect(),
        }
    }

    fn strings(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_owned()).collect()
    }

    /// The owned path: the job/step/nonce tuple under the staging root, the
    /// suffix the producer's tool requires, bounded components only.
    #[test]
    fn owned_paths_carry_the_producer_s_suffix_and_refuse_unbounded_components() {
        let trace = OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap();
        assert_eq!(
            trace.remote_path,
            "/data/local/tmp/arkdeck-job-1-capture-trace-owned.htrace"
        );
        assert_eq!(trace.basename(), "arkdeck-job-1-capture-trace-owned.htrace");
        for (image_type, suffix) in [(ImageType::Png, ".png"), (ImageType::Jpeg, ".jpeg")] {
            let still =
                OwnedRemotePath::stable("job-enc", "capture-screenshot", image_type).unwrap();
            assert!(still.remote_path.ends_with(suffix), "{}", still.remote_path);
        }
        assert!(
            OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Jpeg)
                .unwrap()
                .remote_path
                .ends_with(".json")
        );
        assert!(
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png)
                .unwrap()
                .remote_path
                .ends_with(".tar")
        );
        assert_eq!(
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence")
                .unwrap()
                .remote_path,
            "/data/local/tmp/arkdeck-job-1-capture-screen-sequence-owned-frames"
        );
        assert!(OwnedRemotePath::new("../x", "capture-trace", "n", ImageType::Png).is_err());
        assert!(OwnedRemotePath::new("job", "capture trace", "n", ImageType::Png).is_err());
        assert!(OwnedRemotePath::new("job", "capture-trace", "", ImageType::Png).is_err());
        assert!(
            OwnedRemotePath::new(&"j".repeat(128), &"s".repeat(128), "n", ImageType::Png).is_err()
        );
    }

    /// The trace request's bounds, and the anchor derived for a ring.
    #[test]
    fn trace_requests_are_bounded_and_a_ring_carries_its_anchor() {
        assert!(TraceRequest::new(0, vec!["ohos".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(121, vec!["ohos".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec![], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec!["oh os".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec!["ohos".into()], 512, false, None).is_err());
        assert!(
            TraceRequest::new(
                5,
                vec!["ohos".into()],
                8192,
                false,
                Some("ARKDECKANCHORab".into())
            )
            .is_err(),
            "an anchor is ring-only"
        );
        assert!(
            TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some("short".into())).is_err()
        );
        let anchor = TraceRequest::anchor("JOB-abc_123", "capture-trace");
        assert_eq!(anchor, "ARKDECKANCHORJOBabc123capturetrace");
        assert!(TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor)).is_ok());
        let long = TraceRequest::anchor(&"x".repeat(60), "capture-trace");
        assert_eq!(long.len(), "ARKDECKANCHOR".len() + 40);
    }

    /// The other request types' bounds.
    #[test]
    fn the_request_types_refuse_what_swift_refuses() {
        assert!(ScreenSequenceRequest::new(1, ImageType::Jpeg, None, None, None).is_err());
        assert!(ScreenSequenceRequest::new(301, ImageType::Jpeg, None, None, None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(720), None, None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(0), Some(1), None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, None, None, Some(65)).is_err());
        let request =
            ScreenSequenceRequest::new(12, ImageType::Png, Some(720), Some(1280), Some(0)).unwrap();
        assert_eq!(request.frame_name(0), "0001.png");
        assert_eq!(request.frame_name(11), "0012.png");
        assert!(FaultLogName::new("cppcrash-com.example.demo-20260731").is_ok());
        assert!(FaultLogName::new("Cppcrash-x").is_err());
        assert!(FaultLogName::new("cppcrash").is_err());
        assert!(FaultLogName::new("cppcrash-../etc").is_err());
        assert!(LivenessRequest::new("com.example.demo", None, None, None).is_ok());
        assert!(LivenessRequest::new("demo", None, None, None).is_err());
        assert!(LivenessRequest::new("com.9example", None, None, None).is_err());
        assert!(LivenessRequest::new("com.example.demo", Some("1Ability"), None, None).is_err());
        assert!(
            LivenessRequest::new(
                "com.example.demo",
                None,
                Some("com.example.demo:worker"),
                None
            )
            .is_ok()
        );
        assert!(LivenessRequest::new("com.example.demo", None, Some("bad name"), None).is_err());
        assert!(LivenessRequest::new("com.example.demo", None, None, Some("ABCD")).is_err());
        assert!(FileAction::component_detail("12", "345").is_ok());
        assert!(FileAction::component_detail("12a", "345").is_err());
        assert!(FileAction::component_detail("", "345").is_err());
    }

    /// Swift `action(for:…)`: the steps this module owns, from the request's
    /// inputs, minting the same owned path for capture, receive and cleanup.
    #[test]
    fn steps_map_to_actions_that_name_one_file_across_their_legs() {
        let empty = Map::new();
        let tree = FileAction::for_step(
            "capture-ui-tree",
            "captureRemoteFile",
            None,
            &empty,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::CaptureComponentTree { path } = &tree else {
            panic!("{tree:?}")
        };
        let receive = FileAction::for_step("receive-ui-tree", "receiveFile", None, &empty, "job-1")
            .unwrap()
            .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(&artifact.path, path);
        assert_eq!(artifact.maximum_bytes, RECEIVE_MAXIMUM_BYTES);
        assert_eq!(artifact.expected_leading_bytes, None);
        let cleanup = FileAction::for_step(
            "cleanup-ui-tree-temp",
            "cleanupOwnedRemotePath",
            None,
            &empty,
            "job-1",
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            cleanup,
            FileAction::CleanupOwnedRemotePath { path: path.clone() }
        );
        // A JPEG still: the type reaches the path, the receive's magic and
        // the cleanup alike.
        let jpeg = inputs(json!({"screenshotImageType": "jpeg"}));
        let still = FileAction::for_step(
            "capture-screenshot",
            "captureRemoteFile",
            None,
            &jpeg,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::CaptureScreenshot { image_type, path } = &still else {
            panic!("{still:?}")
        };
        assert_eq!(*image_type, ImageType::Jpeg);
        assert!(path.remote_path.ends_with(".jpeg"));
        let receive =
            FileAction::for_step("receive-screenshot", "receiveFile", None, &jpeg, "job-1")
                .unwrap()
                .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(&artifact.path, path);
        assert_eq!(
            artifact.expected_leading_bytes.as_deref(),
            Some(&JFIF_MAGIC[..])
        );
        let receive =
            FileAction::for_step("receive-screenshot", "receiveFile", None, &empty, "job-1")
                .unwrap()
                .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(
            artifact.expected_leading_bytes.as_deref(),
            Some(&PNG_MAGIC[..])
        );
        // The trace: the caller's categories, a ring's anchor.
        let ring = inputs(
            json!({"traceCategories": ["ohos", "ace"], "durationSeconds": 500,
            "traceBufferKB": 100, "ringBuffered": true}),
        );
        let trace =
            FileAction::for_step("capture-trace", "captureRemoteFile", None, &ring, "JOB-7")
                .unwrap()
                .unwrap();
        let FileAction::CaptureTrace { request, path } = &trace else {
            panic!("{trace:?}")
        };
        assert_eq!(request.duration_seconds, 120);
        assert_eq!(request.buffer_kb, 1024);
        assert!(request.ring_buffered);
        assert_eq!(
            request.coverage_anchor.as_deref(),
            Some("ARKDECKANCHORJOB7capturetrace")
        );
        assert!(path.remote_path.ends_with("-capture-trace-owned.htrace"));
        assert!(
            FileAction::for_step("capture-trace", "captureRemoteFile", None, &empty, "job-1")
                .is_err(),
            "no invented categories"
        );
        // The stdout legs.
        assert_eq!(
            FileAction::for_step(
                "capture-crash-index",
                "captureRemoteStdout",
                Some("crashIndex"),
                &empty,
                "job-1"
            )
            .unwrap(),
            Some(FileAction::CaptureCrashIndex {
                byte_budget: STDOUT_BUDGET
            })
        );
        assert!(
            FileAction::for_step(
                "capture-crash-log",
                "captureRemoteStdout",
                Some("crashLog"),
                &empty,
                "job-1"
            )
            .is_err()
        );
        let detail = inputs(json!({"windowId": "7", "componentId": "42"}));
        assert_eq!(
            FileAction::for_step(
                "capture-advanced-ui-dump",
                "captureRemoteStdout",
                Some("componentDetail"),
                &detail,
                "job-1"
            )
            .unwrap(),
            Some(FileAction::CaptureComponentDetail {
                window_id: "7".into(),
                component_id: "42".into()
            })
        );
        assert!(
            FileAction::for_step(
                "x",
                "captureRemoteStdout",
                Some("componentTree"),
                &empty,
                "job-1"
            )
            .is_err()
        );
        assert_eq!(
            FileAction::for_step(
                "capture-hilog",
                "captureRemoteStdout",
                Some("boundedHilog"),
                &empty,
                "job-1"
            )
            .unwrap(),
            None,
            "the default legs are another owner's"
        );
        assert_eq!(
            FileAction::for_step("probe-device", "probeDevice", None, &empty, "job-1").unwrap(),
            None
        );
        let live = inputs(
            json!({"bundleName": "com.example.demo", "abilityName": "EntryAbility",
            "processName": "com.example.demo:worker",
            "expectedDeployedArtifactDigest": "d".repeat(64)}),
        );
        let liveness = FileAction::for_step(
            "observe-application-liveness",
            "verifyRemoteState",
            None,
            &live,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::ObserveApplicationLiveness(request) = &liveness else {
            panic!("{liveness:?}")
        };
        assert_eq!(request.process_name, "com.example.demo:worker");
        assert_eq!(request.ability_name.as_deref(), Some("EntryAbility"));
        // The sequence and its cleanup name the same frames.
        let frames = inputs(json!({"frameCount": 3, "imageType": "png", "displayId": 1}));
        let capture = FileAction::for_step(
            "capture-screen-sequence",
            "captureRemoteFile",
            None,
            &frames,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let cleanup = FileAction::for_step(
            "cleanup-screen-sequence-temp",
            "cleanupOwnedRemotePath",
            None,
            &frames,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let (
            FileAction::CaptureScreenSequence {
                frames: a,
                archive: b,
                request: r1,
            },
            FileAction::CleanupScreenSequence {
                frames: c,
                archive: d,
                request: r2,
            },
        ) = (&capture, &cleanup)
        else {
            panic!("{capture:?} {cleanup:?}")
        };
        assert_eq!((a, b, r1), (c, d, r2));
        assert!(
            FileAction::for_step(
                "capture-screen-sequence",
                "captureRemoteFile",
                None,
                &empty,
                "job-1"
            )
            .is_err()
        );
    }

    /// The exact argv of every leg, with the `-t <key>` prefix, and no argv
    /// at all without a connect key.
    #[test]
    fn the_legs_lower_to_swift_s_exact_arguments() {
        let root = Path::new("/private/tmp/arkdeck-receive-tests/abc");
        let path =
            OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let blocking = trace().lower("capture-trace", Some(KEY), root).unwrap();
        assert_eq!(
            arguments(&blocking),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "-t",
                    "5",
                    "-b",
                    "8192",
                    "ohos",
                    "-o",
                    &path.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &path.remote_path]),
            ]
        );
        let FilePlan::Sequence(invocations) = &blocking else {
            panic!()
        };
        assert_eq!(invocations[0].timeout, Duration::from_secs(35));
        assert!(invocations[0].continue_after_non_zero);
        assert_eq!(invocations[1].timeout, Duration::from_secs(15));
        assert!(!invocations[1].continue_after_non_zero);
        let anchor = TraceRequest::anchor("job-receive-1", "capture-trace");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor.clone()))
                .unwrap(),
            path: path.clone(),
        };
        let lowered = ring.lower("capture-trace", Some(KEY), root).unwrap();
        assert_eq!(
            arguments(&lowered),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "--trace_begin",
                    "-b",
                    "8192",
                    "ohos"
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    &format!("echo {anchor} > {TRACE_MARKER_PATH}")
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    &format!("grep -c {anchor} {TRACE_RING_PATH}")
                ]),
                strings(&["-t", KEY, "shell", "sleep", "5"]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "--trace_dump",
                    "-o",
                    &path.remote_path
                ]),
                strings(&["-t", KEY, "shell", "hitrace", "--trace_finish_nodump"]),
                strings(&["-t", KEY, "shell", "ls", "-l", &path.remote_path]),
            ]
        );
        let FilePlan::Sequence(invocations) = &lowered else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![30, 15, 15, 35, 120, 30, 15]
        );
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.continue_after_non_zero)
                .collect::<Vec<_>>(),
            vec![false, false, false, false, true, true, false]
        );
        let tree = OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap();
        assert_eq!(
            arguments(
                &FileAction::CaptureComponentTree { path: tree.clone() }
                    .lower("capture-ui-tree", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "uitest",
                    "dumpLayout",
                    "-p",
                    &tree.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &tree.remote_path]),
            ]
        );
        let still =
            OwnedRemotePath::stable("job-1", "capture-screenshot", ImageType::Jpeg).unwrap();
        assert_eq!(
            arguments(
                &FileAction::CaptureScreenshot {
                    image_type: ImageType::Jpeg,
                    path: still.clone()
                }
                .lower("capture-screenshot", Some(KEY), root)
                .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-f",
                    &still.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &still.remote_path]),
            ]
        );
        let request =
            ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(720), Some(1280), Some(0)).unwrap();
        let frames =
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png).unwrap();
        let sequence = FileAction::CaptureScreenSequence {
            request: request.clone(),
            frames: frames.clone(),
            archive: archive.clone(),
        };
        assert_eq!(
            arguments(
                &sequence
                    .lower("capture-screen-sequence", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&["-t", KEY, "shell", "mkdir", "-p", &frames.remote_path]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-w",
                    "720",
                    "-h",
                    "1280",
                    "-i",
                    "0",
                    "-f",
                    &format!("{}/0001.jpeg", frames.remote_path)
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-w",
                    "720",
                    "-h",
                    "1280",
                    "-i",
                    "0",
                    "-f",
                    &format!("{}/0002.jpeg", frames.remote_path)
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "tar",
                    "-c",
                    "-f",
                    &archive.remote_path,
                    "-C",
                    &frames.remote_path,
                    "."
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &archive.remote_path]),
            ]
        );
        let cleanup = FileAction::CleanupScreenSequence {
            request,
            frames: frames.clone(),
            archive: archive.clone(),
        };
        assert_eq!(
            arguments(
                &cleanup
                    .lower("cleanup-screen-sequence-temp", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "rm",
                    "-f",
                    &format!("{}/0001.jpeg", frames.remote_path),
                    &format!("{}/0002.jpeg", frames.remote_path)
                ]),
                strings(&["-t", KEY, "shell", "rm", "-f", &archive.remote_path]),
                strings(&["-t", KEY, "shell", "rmdir", &frames.remote_path]),
                strings(&["-t", KEY, "shell", "ls", "-ld", &frames.remote_path]),
            ]
        );
        // `file recv` names both paths; the host file is the remote basename.
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: None,
        });
        let lowered = receive
            .lower("receive-trace-artifact", Some(KEY), root)
            .unwrap();
        let FilePlan::Receive { process, landing } = &lowered else {
            panic!("{lowered:?}")
        };
        // The host path is the receive root joined by the platform, so its
        // separator is the platform's (Windows CI compiles these tests too).
        let destination = root.join("arkdeck-job-receive-1-capture-trace-n1.htrace");
        let destination_text = destination.to_string_lossy().into_owned();
        assert_eq!(
            process.arguments,
            strings(&[
                "-t",
                KEY,
                "file",
                "recv",
                &path.remote_path,
                &destination_text
            ])
        );
        assert_eq!(process.timeout, Duration::from_secs(60));
        assert_eq!(landing.destination, destination);
        assert_eq!(landing.maximum_bytes, RECEIVE_MAXIMUM_BYTES);
        assert_eq!(
            arguments(
                &FileAction::CleanupOwnedRemotePath { path: path.clone() }
                    .lower("cleanup-remote-temp", Some(KEY), root)
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "rm",
                "-f",
                &path.remote_path
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::CaptureCrashIndex {
                    byte_budget: STDOUT_BUDGET
                }
                .lower("capture-crash-index", Some(KEY), root)
                .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "1201",
                "-a",
                "-p Faultlogger -l"
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::CaptureCrashLog {
                    name: FaultLogName::new("cppcrash-demo-1").unwrap(),
                    byte_budget: STDOUT_BUDGET
                }
                .lower("capture-crash-log", Some(KEY), root)
                .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "1201",
                "-a",
                "-p Faultlogger -f cppcrash-demo-1"
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::component_detail("7", "42")
                    .unwrap()
                    .lower("capture-advanced-ui-dump", Some(KEY), root)
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "WindowManagerService",
                "-a",
                "-w 7 -element -lastpage 42"
            ])]
        );
        let liveness = FileAction::ObserveApplicationLiveness(
            LivenessRequest::new(
                "com.example.demo",
                Some("EntryAbility"),
                Some("com.example.demo:worker"),
                None,
            )
            .unwrap(),
        );
        let lowered = liveness
            .lower("observe-application-liveness", Some(KEY), root)
            .unwrap();
        assert_eq!(
            arguments(&lowered),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "pidof",
                "com.example.demo:worker"
            ])]
        );
        let FilePlan::Process(process) = &lowered else {
            panic!()
        };
        assert_eq!(process.timeout, Duration::from_secs(30));
        assert!(
            trace()
                .lower("capture-trace", None, root)
                .unwrap_err()
                .contains("factsUnavailable")
        );
        assert!(trace().lower("capture-trace", Some(""), root).is_err());
    }

    /// The trace verdict reads the listing, never hitrace's exit status.
    #[test]
    fn a_trace_is_judged_by_its_listing() {
        let verdict = trace().verify(
            &sequence(vec![
                sub("", 1),
                sub(
                    "-rw-r--r-- 1 root root 4096 2026-07-31 00:00 /data/local/tmp/t.htrace\n",
                    0,
                ),
            ]),
            "",
        );
        assert_eq!(verdict, verified([("remoteByteCount", "4096".into())]));
        let none = trace().verify(
            &sequence(vec![
                sub("", 0),
                sub(
                    "ls: /data/local/tmp/t.htrace: No such file or directory\n",
                    0,
                ),
            ]),
            "",
        );
        assert!(matches!(none, Outcome::Unknown(_)), "{none:?}");
        let empty = trace().verify(
            &sequence(vec![
                sub("", 0),
                sub(
                    "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/t.htrace\n",
                    0,
                ),
            ]),
            "",
        );
        assert!(
            matches!(
                empty,
                Outcome::Failed {
                    code: "emptyTrace",
                    ..
                }
            ),
            "{empty:?}"
        );
        for listing in [
            "drwxr-xr-x 2 root root 4096 2026-07-31 00:00 /data/local/tmp\n",
            "\n",
            "-rw-r--r-- 1 root root\n",
        ] {
            let verdict = trace().verify(&sequence(vec![sub("", 0), sub(listing, 0)]), "");
            assert!(
                matches!(verdict, Outcome::Unknown(_)),
                "{listing:?} gave {verdict:?}"
            );
        }
        assert!(matches!(
            trace().verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let mut truncated = sub("-rw-r--r-- 1 root root 4096 2026", 0);
        truncated.truncated = true;
        assert!(matches!(
            trace().verify(&sequence(vec![sub("", 0), truncated]), ""),
            Outcome::Unknown(_)
        ));
    }

    /// A ring capture is judged by its last process, and reports whether the
    /// ring held the anchor; a ring that did not answer is unknown.
    #[test]
    fn a_ring_capture_reports_its_anchor_from_the_readback_it_already_has() {
        let anchor = TraceRequest::anchor("job-1", "capture-trace");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor.clone()))
                .unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let listing = "-rw-r--r-- 1 root root 8192 2026-07-31 00:00 /data/local/tmp/t.htrace\n";
        let receipts = |count: &str| {
            sequence(vec![
                sub("", 0),
                sub("", 0),
                sub(count, 0),
                sub("", 0),
                sub("", 1),
                sub("", 0),
                sub(listing, 0),
            ])
        };
        let held = ring.verify(&receipts("1\n"), "");
        let Outcome::Verified(summary) = &held else {
            panic!("{held:?}")
        };
        assert_eq!(summary["remoteByteCount"], "8192");
        assert_eq!(summary["ringHeldCoverageAnchor"], "true");
        assert_eq!(summary["coverageAnchor"], anchor);
        let Outcome::Verified(summary) = ring.verify(&receipts("0\n"), "") else {
            panic!()
        };
        assert_eq!(summary["ringHeldCoverageAnchor"], "false");
        assert!(matches!(
            ring.verify(&receipts("grep: no\n"), ""),
            Outcome::Unknown(_)
        ));
        assert!(matches!(
            ring.verify(&sequence(vec![sub("", 0), sub(listing, 0)]), ""),
            Outcome::Unknown(_)
        ));
        let plain = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, None).unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let Outcome::Verified(summary) = plain.verify(
            &sequence(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(listing, 0),
            ]),
            "",
        ) else {
            panic!()
        };
        assert_eq!(summary.len(), 1);
    }

    /// The tree and the still: two processes, the second a regular file of
    /// more than zero bytes.
    #[test]
    fn the_tree_and_the_still_are_judged_by_their_readbacks() {
        let tree = FileAction::CaptureComponentTree {
            path: OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap(),
        };
        let listing = "-rw-r--r-- 1 root root 12 2026-07-31 00:00 /data/local/tmp/x\n";
        assert_eq!(
            tree.verify(
                &sequence(vec![
                    sub("DumpLayout saved to:/data/local/tmp/x\n", 0),
                    sub(listing, 0)
                ]),
                ""
            ),
            verified([("remoteByteCount", "12".into())])
        );
        let zero = "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/x\n";
        assert!(matches!(
            tree.verify(&sequence(vec![sub("", 0), sub(zero, 0)]), ""),
            Outcome::Failed {
                code: "emptyComponentTree",
                ..
            }
        ));
        assert!(matches!(
            tree.verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let still = FileAction::CaptureScreenshot {
            image_type: ImageType::Png,
            path: OwnedRemotePath::stable("job-1", "capture-screenshot", ImageType::Png).unwrap(),
        };
        assert!(matches!(
            still.verify(&sequence(vec![sub("", 0), sub(zero, 0)]), ""),
            Outcome::Failed {
                code: "emptyScreenshot",
                ..
            }
        ));
        assert!(matches!(
            still.verify(
                &sequence(vec![
                    sub("", 0),
                    sub("ls: x: No such file or directory\n", 0)
                ]),
                ""
            ),
            Outcome::Unknown(_)
        ));
    }

    /// The sequence: the archive's listing decides, failed frames are gaps
    /// counted as facts, the cleanup is proved by the directory's absence.
    #[test]
    fn a_screen_sequence_reports_its_gaps_and_its_cleanup_needs_the_directory_gone() {
        let request = ScreenSequenceRequest::new(3, ImageType::Jpeg, None, None, None).unwrap();
        let frames =
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png).unwrap();
        let capture = FileAction::CaptureScreenSequence {
            request: request.clone(),
            frames: frames.clone(),
            archive: archive.clone(),
        };
        let frame = |exit: i32, millis: u64| Receipt {
            duration: Duration::from_millis(millis),
            ..sub("", exit)
        };
        let listing = "-rw-r--r-- 1 root root 30720 2026-08-26 00:00 /data/local/tmp/a.tar\n";
        let verdict = capture.verify(
            &sequence(vec![
                sub("", 0),
                frame(0, 500),
                frame(1, 250),
                frame(0, 500),
                sub("", 0),
                sub(listing, 0),
            ]),
            "",
        );
        let Outcome::Verified(summary) = &verdict else {
            panic!("{verdict:?}")
        };
        assert_eq!(summary["remoteByteCount"], "30720");
        assert_eq!(summary["requestedFrameCount"], "3");
        assert_eq!(summary["capturedFrameCount"], "2");
        assert_eq!(summary["frameDurationsSeconds"], "0.500,0.250,0.500");
        assert_eq!(summary["observedFramesPerSecond"], "1.60");
        assert!(matches!(
            capture.verify(&sequence(vec![sub("", 0), sub("", 0), sub(listing, 0)]), ""),
            Outcome::Unknown(_)
        ));
        let cleanup = FileAction::CleanupScreenSequence {
            request,
            frames: frames.clone(),
            archive,
        };
        let gone = format!("ls: {}: No such file or directory\n", frames.remote_path);
        assert_eq!(
            cleanup.verify(
                &sequence(vec![sub("", 0), sub("", 0), sub("", 0), sub(&gone, 0)]),
                ""
            ),
            verified([("cleaned", "true".into())])
        );
        assert!(matches!(
            cleanup.verify(
                &sequence(vec![
                    sub("", 0),
                    sub("", 0),
                    sub("", 1),
                    sub("drwxr-xr-x 2 root root 4096 2026 x\n", 0)
                ]),
                ""
            ),
            Outcome::Failed {
                code: "sequenceCleanupResidue",
                ..
            }
        ));
        assert!(matches!(
            cleanup.verify(
                &sequence(vec![sub("", 0), sub("", 0), sub("", 0), sub("", 0)]),
                ""
            ),
            Outcome::Unknown(_)
        ));
        let mut noisy = sub(&gone, 0);
        noisy.stderr = b"warning".to_vec();
        assert_eq!(path_presence(&noisy), None);
        assert_eq!(path_presence(&sub(&gone, 1)), None);
        assert_eq!(
            path_presence(&sub("-rw-r--r-- 1 root root 1 2026 x\n", 0)),
            Some(true)
        );
        assert_eq!(path_presence(&sub(&format!("{gone}{gone}"), 0)), None);
    }

    /// The received bytes decide: none is unknown, empty and over-budget
    /// fail without a digest, a pinned hash and a pinned magic are checked,
    /// and the summary names the file, never the host directory.
    #[test]
    fn a_receive_is_judged_by_the_bytes_that_landed() {
        let root =
            std::env::temp_dir().join(format!("arkdeck-capture-files-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let path =
            OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let artifact = |expected: Option<&str>, maximum: i64, magic: Option<&[u8]>| {
            FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
                path: path.clone(),
                expected_sha256: expected.map(str::to_owned),
                maximum_bytes: maximum,
                expected_leading_bytes: magic.map(<[u8]>::to_vec),
            })
        };
        let landing = |maximum: i64| HostLanding {
            destination: host_landing(&root, &path),
            maximum_bytes: maximum,
            expected_sha256: None,
        };
        let receipt = |landing: &HostLanding| FileReceipt {
            subprocesses: vec![sub("FileTransfer finish, Size:0\n", 0)],
            landed: landing.inspect(),
        };
        let landing_64k = landing(64 * 1024);
        landing_64k.prepare().unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Unknown(_)
        ));
        fs::write(&landing_64k.destination, b"").unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "emptyArtifact",
                ..
            }
        ));
        let payload = b"htrace-fixture-bytes";
        fs::write(&landing_64k.destination, payload).unwrap();
        let digest = hex(&Sha256::digest(payload));
        let Outcome::Verified(summary) =
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), "")
        else {
            panic!()
        };
        assert_eq!(summary["byteCount"], payload.len().to_string());
        assert_eq!(summary["sha256"], digest);
        assert_eq!(
            summary["localArtifact"],
            "arkdeck-job-receive-1-capture-trace-n1.htrace"
        );
        assert!(
            summary
                .values()
                .all(|value| !value.contains(&root.to_string_lossy().into_owned()))
        );
        assert!(matches!(
            artifact(Some(&digest), 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Verified(_)
        ));
        assert!(matches!(
            artifact(Some(&"0".repeat(64)), 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "hashMismatch",
                ..
            }
        ));
        assert!(matches!(
            artifact(None, 64 * 1024, Some(&PNG_MAGIC)).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "unexpectedFormat",
                ..
            }
        ));
        fs::write(&landing_64k.destination, [&PNG_MAGIC[..], b"rest"].concat()).unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, Some(&PNG_MAGIC)).verify(&receipt(&landing_64k), ""),
            Outcome::Verified(_)
        ));
        let landing_8 = landing(8);
        fs::write(&landing_8.destination, [0x61u8; 4096]).unwrap();
        let landed = landing_8.inspect().unwrap();
        assert_eq!(landed.byte_count, 4096);
        assert_eq!(
            landed.sha256, None,
            "an over-budget file must not be digested"
        );
        assert!(matches!(
            artifact(None, 8, None).verify(&receipt(&landing_8), ""),
            Outcome::Failed {
                code: "oversizedArtifact",
                ..
            }
        ));
        // A stale file from an earlier attempt is cleared by the preparation;
        // a symlink or a directory at the destination is never inspected.
        landing_64k.prepare().unwrap();
        assert_eq!(landing_64k.inspect(), None);
        fs::create_dir(&landing_64k.destination).unwrap();
        assert_eq!(landing_64k.inspect(), None);
        #[cfg(unix)]
        {
            landing_64k.prepare().unwrap();
            std::os::unix::fs::symlink("/etc/hosts", &landing_64k.destination).unwrap();
            assert_eq!(landing_64k.inspect(), None);
        }
        let _ = fs::remove_dir_all(&root);
    }

    /// The crash ledger and one entry of it.
    #[test]
    fn the_crash_ledger_is_read_as_swift_reads_it() {
        let index = FileAction::CaptureCrashIndex {
            byte_budget: STDOUT_BUDGET,
        };
        let listing =
            "Faultlog list:\n******\ncppcrash-com.example.demo-20260731\n\njscrash-x-1\n******\n";
        assert_eq!(
            index.verify(&sequence(vec![sub(listing, 0)]), ""),
            verified([
                ("entryCount", "2".into()),
                ("byteCount", listing.len().to_string())
            ])
        );
        assert_eq!(
            index.verify(&sequence(vec![sub("no entries\n", 0)]), ""),
            verified([("entryCount", "0".into()), ("byteCount", "11".into())])
        );
        // Between the first and the last separator, whatever lies there: a
        // middle separator is an entry too, as Swift keeps it.
        assert_eq!(
            fault_log_entries("******\n  a \n******\nb\n******\n"),
            vec!["a", "******", "b"]
        );
        assert_eq!(fault_log_entries("******\n"), Vec::<String>::new());
        let mut truncated = sub(listing, 0);
        truncated.truncated = true;
        assert!(matches!(
            index.verify(&sequence(vec![truncated]), ""),
            Outcome::Failed {
                code: "truncated",
                ..
            }
        ));
        let log = FileAction::CaptureCrashLog {
            name: FaultLogName::new("cppcrash-com.example.demo-20260731").unwrap(),
            byte_budget: STDOUT_BUDGET,
        };
        assert_eq!(
            log.verify(
                &sequence(vec![sub("Generated by HiviewDFX@OpenHarmony\nPid:1\n", 0)]),
                ""
            ),
            verified([
                ("faultLogName", "cppcrash-com.example.demo-20260731".into()),
                ("byteCount", "41".into()),
            ])
        );
        assert!(matches!(
            log.verify(&sequence(vec![sub("invalid parameters.\n", 0)]), ""),
            Outcome::Failed {
                code: "faultLogNotFound",
                ..
            }
        ));
        assert!(matches!(
            log.verify(&sequence(vec![sub("something else\n", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let mut binary = sub("", 0);
        binary.stdout = vec![0xFF, 0xFE];
        assert!(matches!(
            log.verify(&sequence(vec![binary]), ""),
            Outcome::Failed {
                code: "invalidEncoding",
                ..
            }
        ));
    }

    /// Liveness is always a verified fact: running, stopped, unreadable or
    /// ambiguous, bound to the application and the deployed digest.
    #[test]
    fn application_liveness_is_a_fact_in_every_case() {
        let request = LivenessRequest::new(
            "com.example.demo",
            Some("EntryAbility"),
            Some("com.example.demo:worker"),
            Some(&"d".repeat(64)),
        )
        .unwrap();
        let action = FileAction::ObserveApplicationLiveness(request.clone());
        let now = "2026-07-29T00:00:00Z";
        let expect = |stdout: &str,
                      exit: i32,
                      state: &str,
                      process_state: &str,
                      observed: &str,
                      reason: &str| {
            let Outcome::Verified(summary) = action.verify(&sequence(vec![sub(stdout, exit)]), now)
            else {
                panic!()
            };
            assert_eq!(summary["state"], state, "{stdout:?}");
            assert_eq!(summary["processState"], process_state);
            assert_eq!(summary["pidObserved"], observed);
            assert_eq!(summary["reasonCode"], reason);
            assert_eq!(summary["abilityState"], "UNKNOWN");
            assert_eq!(summary["observedAtUtc"], now);
            assert_eq!(summary["deployedArtifactDigest"], "d".repeat(64));
            assert_eq!(
                summary["applicationRef"],
                hex(&Sha256::digest(
                    b"com.example.demo|EntryAbility|com.example.demo:worker"
                ))
            );
        };
        expect(
            "3421 3422\n",
            0,
            "HEALTHY",
            "RUNNING",
            "true",
            "targetProcessRunning",
        );
        expect(
            "\n",
            0,
            "UNHEALTHY",
            "STOPPED",
            "false",
            "targetProcessNotRunning",
        );
        expect(
            "3421 abc\n",
            0,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackAmbiguous",
        );
        expect(
            "0\n",
            0,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackAmbiguous",
        );
        expect(
            "3421\n",
            1,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackUnavailable",
        );
        let mut truncated = sub("3421", 0);
        truncated.truncated = true;
        let Outcome::Verified(summary) = action.verify(
            &FileReceipt {
                subprocesses: vec![truncated],
                landed: None,
            },
            now,
        ) else {
            panic!()
        };
        assert_eq!(summary["reasonCode"], "processReadbackTruncated");
        let bare = FileAction::ObserveApplicationLiveness(
            LivenessRequest::new("com.example.demo", None, None, None).unwrap(),
        );
        let Outcome::Verified(summary) = bare.verify(&sequence(vec![sub("1\n", 0)]), now) else {
            panic!()
        };
        assert!(!summary.contains_key("deployedArtifactDigest"));
        assert_eq!(
            summary["applicationRef"],
            hex(&Sha256::digest(b"com.example.demo||com.example.demo"))
        );
    }

    /// Swift's materialization reads every persisted form of these legs back
    /// as the action that persisted it; a pair of characters that is not
    /// hexadecimal is skipped and an odd last one dropped, as Swift reads
    /// `expectedLeadingBytes`. A receive or cleanup of a JPEG still is read
    /// with the still's own suffix — a declared difference: Swift rebuilds it
    /// with its default PNG suffix and refuses the record — and a path that
    /// neither suffix rebuilds is still refused. The screen sequence's kinds
    /// are not this action's ([`ParkedScreenSequence`] reads them).
    #[test]
    fn persisted_forms_materialize_back_as_swift_reads_them() {
        let as_map = |arguments: Vec<(&str, Persisted)>| -> Map<String, Value> {
            arguments
                .into_iter()
                .map(|(key, value)| {
                    let value = match value {
                        Persisted::Text(text) => Value::from(text),
                        Persisted::Integer(number) => Value::from(number),
                        Persisted::Texts(texts) => Value::from(texts),
                    };
                    (key.to_owned(), value)
                })
                .collect()
        };
        let tree = OwnedRemotePath::new("job-1", "capture-ui-tree", "n1", ImageType::Png).unwrap();
        let jpeg =
            OwnedRemotePath::new("job-1", "capture-screenshot", "n2", ImageType::Jpeg).unwrap();
        let png =
            OwnedRemotePath::new("job-1", "capture-screenshot", "n2", ImageType::Png).unwrap();
        let actions = [
            trace(),
            FileAction::CaptureComponentTree { path: tree.clone() },
            FileAction::CaptureScreenshot {
                image_type: ImageType::Jpeg,
                path: jpeg.clone(),
            },
            FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
                path: png,
                expected_sha256: Some("ab".repeat(32)),
                maximum_bytes: RECEIVE_MAXIMUM_BYTES,
                expected_leading_bytes: Some(PNG_MAGIC.to_vec()),
            }),
            FileAction::CleanupOwnedRemotePath { path: tree },
            FileAction::CaptureCrashIndex { byte_budget: 4096 },
            FileAction::CaptureCrashLog {
                name: FaultLogName::new("cppcrash-com.example.demo-20260731").unwrap(),
                byte_budget: 4096,
            },
            FileAction::ObserveApplicationLiveness(
                LivenessRequest::new("com.example.demo", Some("EntryAbility"), None, None).unwrap(),
            ),
        ];
        for action in actions {
            let (kind, arguments) = action.persisted();
            assert_eq!(
                FileAction::from_persisted(kind, &as_map(arguments)),
                Ok(Some(action))
            );
        }
        assert_eq!(lenient_hex("ffd8ffe0"), JFIF_MAGIC);
        assert_eq!(lenient_hex("zzff0"), [0xff]);
        // The declared difference: a JPEG still's receive and cleanup.
        let still = [
            FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
                path: jpeg.clone(),
                expected_sha256: None,
                maximum_bytes: RECEIVE_MAXIMUM_BYTES,
                expected_leading_bytes: Some(JFIF_MAGIC.to_vec()),
            }),
            FileAction::CleanupOwnedRemotePath { path: jpeg.clone() },
        ];
        for action in still {
            let (kind, arguments) = action.persisted();
            assert_eq!(
                FileAction::from_persisted(kind, &as_map(arguments)),
                Ok(Some(action))
            );
        }
        // A suffix neither format writes, or a JPEG suffix on a leg whose
        // suffix is fixed, names no owned path.
        for (step, remote) in [
            (
                "capture-screenshot",
                "/data/local/tmp/arkdeck-job-1-capture-screenshot-n2.gif",
            ),
            (
                "capture-ui-tree",
                "/data/local/tmp/arkdeck-job-1-capture-ui-tree-n2.jpeg",
            ),
        ] {
            for kind in ["hdc.receiveOwnedArtifact", "hdc.cleanupOwnedRemotePath"] {
                let mut arguments = as_map(vec![
                    ("jobId", Persisted::Text("job-1".into())),
                    ("stepId", Persisted::Text(step.into())),
                    ("nonce", Persisted::Text("n2".into())),
                    ("remotePath", Persisted::Text(remote.into())),
                ]);
                arguments.insert("maximumBytes".into(), Value::from(RECEIVE_MAXIMUM_BYTES));
                assert_eq!(
                    FileAction::from_persisted(kind, &arguments),
                    Err(FileActionError::Unsupported(format!(
                        "persisted {kind} remote path does not match its owned components"
                    )))
                );
            }
        }
        for kind in ["hdc.captureScreenSequence", "hdc.cleanupScreenSequence"] {
            assert_eq!(FileAction::from_persisted(kind, &Map::new()), Ok(None));
        }
    }

    /// A parked screen sequence step is read back from the paths its
    /// persisted form names (a declared difference: Swift's materialization
    /// does not know either kind): the forms a capture and its cleanup
    /// persist are read back, the recorded paths must be exactly the owned
    /// ones, and the capture's request is checked again.
    #[test]
    fn a_parked_screen_sequence_is_read_from_its_persisted_paths() {
        let as_map = |arguments: Vec<(&str, Persisted)>| -> Map<String, Value> {
            arguments
                .into_iter()
                .map(|(key, value)| {
                    let value = match value {
                        Persisted::Text(text) => Value::from(text),
                        Persisted::Integer(number) => Value::from(number),
                        Persisted::Texts(texts) => Value::from(texts),
                    };
                    (key.to_owned(), value)
                })
                .collect()
        };
        let job = "job-7dd23f0c724b55c0e2c644de0063493d";
        let request =
            ScreenSequenceRequest::new(3, ImageType::Png, Some(360), Some(640), Some(0)).unwrap();
        let frames = OwnedRemoteDirectory::stable_frames(job, "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable(job, "capture-screen-sequence", ImageType::Png).unwrap();
        let capture = FileAction::CaptureScreenSequence {
            request: request.clone(),
            frames: frames.clone(),
            archive: archive.clone(),
        };
        let cleanup = FileAction::CleanupScreenSequence {
            request,
            frames: frames.clone(),
            archive: archive.clone(),
        };
        let read = |action: &FileAction| {
            let (kind, arguments) = action.persisted();
            ParkedScreenSequence::from_persisted(kind, &as_map(arguments))
        };
        assert_eq!(
            read(&capture),
            Ok(Some(ParkedScreenSequence {
                cleanup: false,
                frames: frames.clone(),
                archive: archive.clone(),
            }))
        );
        assert_eq!(
            read(&cleanup),
            Ok(Some(ParkedScreenSequence {
                cleanup: true,
                frames: frames.clone(),
                archive: archive.clone(),
            }))
        );
        // The capture probes its archive, then its frames directory; the
        // cleanup its frames directory: `ls -ld`, read-only, each once.
        let parked = read(&capture).unwrap().unwrap();
        let probes = parked.readbacks();
        assert_eq!(
            probes,
            [
                HapAction::ReadOwnedPathPresence {
                    path: archive.clone()
                },
                HapAction::ReadOwnedDirectoryPresence(frames.clone()),
            ]
        );
        for probe in &probes {
            assert_eq!(probe.effect(), "readOnly");
            let FilePlan::Process(plan) = probe
                .lower("reconcile-capture-screen-sequence-0", Some(KEY), &[])
                .unwrap()
            else {
                panic!("a presence probe is one process")
            };
            assert_eq!(plan.arguments[..4], ["-t", KEY, "shell", "ls"]);
            assert_eq!(plan.arguments[4], "-ld");
        }
        assert_eq!(
            read(&cleanup).unwrap().unwrap().readbacks(),
            [HapAction::ReadOwnedDirectoryPresence(frames.clone())]
        );
        // Refused before anything is dispatched.
        let (kind, arguments) = capture.persisted();
        let arguments = as_map(arguments);
        let refused = |change: &dyn Fn(&mut Map<String, Value>)| {
            let mut changed = arguments.clone();
            change(&mut changed);
            ParkedScreenSequence::from_persisted(kind, &changed)
                .unwrap_err()
                .to_string()
        };
        assert_eq!(
            refused(&|arguments| {
                arguments.insert(
                    "framesDirectory".into(),
                    Value::from("/data/local/tmp/elsewhere-frames"),
                );
            }),
            "unsupportedAction(\"persisted hdc.captureScreenSequence frames directory does not \
             match its owned components\")"
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert(
                    "remotePath".into(),
                    Value::from("/data/local/tmp/other.tar"),
                );
            }),
            "unsupportedAction(\"persisted hdc.captureScreenSequence remote path does not match \
             its owned components\")"
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("imageType".into(), Value::from("gif"));
            }),
            "unsupportedAction(\"persisted hdc.captureScreenSequence carries an unregistered \
             image type\")"
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("height");
            }),
            "malformed(field: \"width/height\", detail: \"a scaled sequence needs both \
             dimensions\")"
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("framesDirectory");
            }),
            "unsupportedAction(\"persisted hdc.captureScreenSequence is missing string \
             framesDirectory\")"
        );
        let (kind, arguments) = cleanup.persisted();
        let mut many = as_map(arguments);
        many.insert("frameCount".into(), Value::from(301));
        assert_eq!(
            ParkedScreenSequence::from_persisted(kind, &many)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"frameCount\", detail: \"2...300\")"
        );
        // An owned path of another step names no archive of a sequence.
        let trace = OwnedRemotePath::stable(job, "capture-trace", ImageType::Png).unwrap();
        let mut other = as_map(cleanup.persisted().1);
        other.insert("stepId".into(), Value::from("capture-trace"));
        other.insert("remotePath".into(), Value::from(trace.remote_path));
        assert_eq!(
            ParkedScreenSequence::from_persisted(kind, &other)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"persisted hdc.cleanupScreenSequence does not name a screen \
             sequence archive\")"
        );
        assert_eq!(
            ParkedScreenSequence::from_persisted("hdc.cleanupOwnedRemotePath", &Map::new()),
            Ok(None)
        );
    }

    /// Nothing is concluded unless every probe answered: a capture whose
    /// archive is there completed, one that left nothing was not executed,
    /// one whose frames remain without their archive stays unknown; a
    /// cleanup whose frames directory is gone completed, one whose directory
    /// remains was not executed.
    #[test]
    fn a_parked_screen_sequence_concludes_only_on_definite_presences() {
        let job = "job-7dd23f0c724b55c0e2c644de0063493d";
        let frames = OwnedRemoteDirectory::stable_frames(job, "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable(job, "capture-screen-sequence", ImageType::Png).unwrap();
        let capture = ParkedScreenSequence {
            cleanup: false,
            frames: frames.clone(),
            archive: archive.clone(),
        };
        let cleanup = ParkedScreenSequence {
            cleanup: true,
            frames,
            archive,
        };
        let completed = |present: &str| {
            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                "postconditionPresent".to_owned(),
                present.to_owned(),
            )]))
        };
        let indefinite = Reconcile::StillUnknown(INDEFINITE.into());
        assert_eq!(
            capture.reconcile(&[Some(true), Some(true)]),
            completed("true")
        );
        assert_eq!(
            capture.reconcile(&[Some(true), Some(false)]),
            completed("true")
        );
        assert_eq!(
            capture.reconcile(&[Some(false), Some(false)]),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            capture.reconcile(&[Some(false), Some(true)]),
            Reconcile::StillUnknown(
                "frames directory /data/local/tmp/arkdeck-job-7dd23f0c724b55c0e2c644de0063493d-\
                 capture-screen-sequence-owned-frames remains without its archive \
                 /data/local/tmp/arkdeck-job-7dd23f0c724b55c0e2c644de0063493d-capture-screen-\
                 sequence-owned.tar; original not resent"
                    .into()
            )
        );
        for unanswered in [
            vec![None, Some(true)],
            vec![Some(true), None],
            vec![Some(false), None],
            vec![Some(true)],
            vec![],
        ] {
            assert_eq!(capture.reconcile(&unanswered), indefinite, "{unanswered:?}");
        }
        assert_eq!(cleanup.reconcile(&[Some(false)]), completed("false"));
        assert_eq!(
            cleanup.reconcile(&[Some(true)]),
            Reconcile::ConfirmedNotExecuted
        );
        for unanswered in [vec![None], vec![Some(false), Some(false)], vec![]] {
            assert_eq!(cleanup.reconcile(&unanswered), indefinite, "{unanswered:?}");
        }
    }

    /// The persisted forms Swift journals, and the remaining verdicts.
    #[test]
    fn persisted_forms_and_the_stdout_and_cleanup_verdicts_follow_swift() {
        let path = OwnedRemotePath::new("job-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let (kind, arguments) = trace().persisted();
        assert_eq!(kind, "hdc.captureTrace");
        assert!(arguments.contains(&(
            "remotePath",
            Persisted::Text("/data/local/tmp/arkdeck-job-receive-1-capture-trace-n1.htrace".into())
        )));
        assert!(arguments.contains(&("categories", Persisted::Texts(vec!["ohos".into()]))));
        assert!(arguments.contains(&("bufferKB", Persisted::Integer(8192))));
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: Some(JFIF_MAGIC.to_vec()),
        });
        let (kind, arguments) = receive.persisted();
        assert_eq!(kind, "hdc.receiveOwnedArtifact");
        assert!(arguments.contains(&("expectedLeadingBytes", Persisted::Text("ffd8ffe0".into()))));
        assert!(arguments.contains(&("maximumBytes", Persisted::Integer(RECEIVE_MAXIMUM_BYTES))));
        assert!(!arguments.iter().any(|(key, _)| *key == "expectedSha256"));
        assert_eq!(
            FileAction::CleanupOwnedRemotePath { path: path.clone() }
                .persisted()
                .0,
            "hdc.cleanupOwnedRemotePath"
        );
        assert_eq!(
            FileAction::component_detail("1", "2")
                .unwrap()
                .persisted()
                .0,
            "hdc.captureUIDump"
        );
        assert_eq!(
            FileAction::CaptureCrashIndex { byte_budget: 1 }.effect(),
            "readOnly"
        );
        assert_eq!(trace().effect(), "deviceMutation");
        let cleanup = FileAction::CleanupOwnedRemotePath { path: path.clone() };
        assert_eq!(
            cleanup.verify(&sequence(vec![sub("", 0)]), ""),
            verified([("cleaned", path.remote_path.clone())])
        );
        assert!(matches!(
            cleanup.verify(&sequence(vec![sub("", 1)]), ""),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        let detail = FileAction::component_detail("7", "42").unwrap();
        assert_eq!(
            detail.verify(&sequence(vec![sub("<window/>", 0)]), ""),
            verified([("byteCount", "9".into())])
        );
        assert!(matches!(
            detail.verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
    }

    /// The runner: a sequence stops at the first non-zero exit an invocation
    /// does not continue past; a receive prepares and inspects its landing.
    #[test]
    fn the_runner_follows_swift_s_sequence_and_landing_rules() {
        use std::cell::RefCell;
        struct Scripted {
            exits: Vec<i32>,
            seen: RefCell<Vec<Vec<String>>>,
            write: Option<(PathBuf, Vec<u8>)>,
        }
        impl HdcDispatch for Scripted {
            fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
                let index = self.seen.borrow().len();
                self.seen.borrow_mut().push(plan.arguments.clone());
                if let Some((path, bytes)) = &self.write {
                    fs::write(path, bytes).unwrap();
                }
                Ok(sub("", self.exits.get(index).copied().unwrap_or(0)))
            }
        }
        let root = Path::new("/tmp");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, None).unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let plan = ring.lower("capture-trace", Some(KEY), root).unwrap();
        // begin fails: nothing else runs.
        let stopped = Scripted {
            exits: vec![1],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        assert_eq!(run(&plan, &stopped).unwrap().subprocesses.len(), 1);
        // dump fails but continues: the stop and the readback still run.
        let continued = Scripted {
            exits: vec![0, 0, 1, 0, 0],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        assert_eq!(run(&plan, &continued).unwrap().subprocesses.len(), 5);
        assert_eq!(continued.seen.borrow().len(), 5);
        let landing_root =
            std::env::temp_dir().join(format!("arkdeck-capture-run-{}", std::process::id()));
        let _ = fs::remove_dir_all(&landing_root);
        let path = OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap();
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: None,
        });
        let plan = receive
            .lower("receive-ui-tree", Some(KEY), &landing_root)
            .unwrap();
        let destination = host_landing(&landing_root, &path);
        fs::create_dir_all(&landing_root).unwrap();
        fs::write(&destination, b"stale-bytes-from-attempt-1").unwrap();
        let nothing = Scripted {
            exits: vec![0],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        let receipt = run(&plan, &nothing).unwrap();
        assert_eq!(
            receipt.landed, None,
            "the stale file is cleared before the transfer"
        );
        let writes = Scripted {
            exits: vec![0],
            seen: RefCell::new(Vec::new()),
            write: Some((destination.clone(), b"{\"tree\":1}".to_vec())),
        };
        let receipt = run(&plan, &writes).unwrap();
        let landed = receipt.landed.unwrap();
        assert_eq!(landed.byte_count, 10);
        assert_eq!(
            landed.leading,
            b"{\"tree\":".to_vec(),
            "the first eight bytes"
        );
        assert_eq!(landed.sha256, Some(hex(&Sha256::digest(b"{\"tree\":1}"))));
        let _ = fs::remove_dir_all(&landing_root);
    }
}
