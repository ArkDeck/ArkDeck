//! The lane composed end to end against a stand-in `arkforged`: this test
//! binary itself, which the lane launches from a real, verified bundle as its
//! daemon. Launched with `--pair-from-stdin` it plays the daemon: it reads the
//! 32-byte pairing secret, binds `public.sock` then `controller.sock` in its
//! runtime directory, acknowledges each session with the readiness its
//! profile's `# fake-arkforged:` comment names (bound to its own bytes' digest,
//! as `arkforged` reports its own), answers `discoverDevices` with nothing,
//! and ends on its stdin's end — the owner's liveness — with status 11.
//!
//! No daemon, board or USB host is involved; nothing here is device evidence.
//! A custom harness (`harness = false`), because the daemon role must run
//! before any test framework reads the arguments.

#[cfg(target_os = "macos")]
mod lane {
    use arkdeck_contract::sha256_hex;
    use arkdeck_provider_arkforge::{
        Absence, BUNDLE_PATH_KEY, DeviceAccessObserver, Lane, LaneInputs, NATIVE_ROCKUSB_TOOLCHAIN,
    };
    use arkforge_ipc::framing::{read_frame, write_frame};
    use arkforge_ipc::messages::{ErrorBody, Hello, HelloAck, Request, Response};
    use arkforge_ipc::{Api, PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status};
    use serde_json::json;
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    const SECRET: [u8; 32] = [0x5a; 32];
    const AGENTD: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    const HDC: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

    // MARK: the stand-in daemon

    pub fn fake_arkforged(arguments: Vec<String>) -> ! {
        let value = |flag: &str| {
            arguments
                .iter()
                .position(|argument| argument == flag)
                .and_then(|index| arguments.get(index + 1))
                .cloned()
                .unwrap_or_default()
        };
        let runtime = PathBuf::from(value("--runtime-dir"));
        let profile = std::fs::read_to_string(value("--profile")).unwrap_or_default();
        let mode = profile
            .lines()
            .find_map(|line| line.strip_prefix("# fake-arkforged: "))
            .unwrap_or("ready")
            .to_owned();
        let mut secret = [0u8; 32];
        if std::io::stdin().read_exact(&mut secret).is_err() {
            std::process::exit(12);
        }
        // Held for its whole life: the kernel lets go of it only when this
        // process ends, which is what the cases observe.
        let alive = std::fs::File::create(runtime.join("alive")).unwrap();
        alive.lock().unwrap();
        std::fs::write(runtime.join("paired"), sha256_hex(&secret)).unwrap();
        std::fs::write(runtime.join("arguments"), arguments[1..].join("\n")).unwrap();
        if mode == "exit-at-once" {
            std::process::exit(3);
        }
        let digest = sha256_hex(&std::fs::read(std::env::current_exe().unwrap()).unwrap());
        for (name, kind) in [
            ("public.sock", SessionKind::Public),
            ("controller.sock", SessionKind::Controller),
        ] {
            let listener = UnixListener::bind(runtime.join(name)).unwrap();
            let (mode, digest) = (mode.clone(), digest.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let (mode, digest) = (mode.clone(), digest.clone());
                    std::thread::spawn(move || serve(stream, kind, &mode, &digest));
                }
            });
        }
        // Its owner's end of input, and nothing else, ends it.
        let mut rest = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut rest);
        std::fs::write(runtime.join("eof"), rest.len().to_string()).unwrap();
        std::process::exit(11);
    }

    fn serve(mut stream: UnixStream, kind: SessionKind, mode: &str, digest: &str) {
        let Ok(Some(frame)) = read_frame(&mut stream) else {
            return;
        };
        let Ok(hello) = Hello::decode(&frame) else {
            return;
        };
        let ready = mode != "not-ready";
        let ack = HelloAck {
            protocol_major: PROTOCOL_MAJOR,
            protocol_minor: PROTOCOL_MINOR,
            session_kind: kind,
            daemon_version: "0.1.0".into(),
            refusal: (hello.session_kind != kind)
                .then(|| format!("this socket serves {kind:?} sessions")),
            execution_ready: ready,
            execution_blockers: if ready {
                Vec::new()
            } else {
                vec!["NO_DISPATCHER".into()]
            },
            toolchain_id: if mode == "replay" {
                "replay".into()
            } else {
                NATIVE_ROCKUSB_TOOLCHAIN.into()
            },
            toolchain_sha256: digest.into(),
        };
        if write_frame(&mut stream, &ack.encode()).is_err() {
            return;
        }
        while let Ok(Some(frame)) = read_frame(&mut stream) {
            let Ok(request) = Request::decode(&frame) else {
                return;
            };
            let (status, payload) = if request.api == Api::DiscoverDevices {
                (Status::Ok, Vec::new())
            } else {
                (
                    Status::Refused,
                    ErrorBody {
                        code: "UNSUPPORTED".into(),
                        message: "the stand-in answers discoverDevices only".into(),
                    }
                    .encode(),
                )
            };
            let response = Response {
                request_id: request.request_id,
                api: request.api,
                status,
                payload,
                stream_sequence: 0,
                stream_end: true,
            };
            if write_frame(&mut stream, &response.encode()).is_err() {
                return;
            }
        }
    }

    // MARK: the bundle and the runtime directory

    struct Scene {
        root: PathBuf,
        bundle: PathBuf,
        runtime: PathBuf,
    }

    impl Scene {
        /// A verified `ArkForge.bundle` whose daemon is this binary, with a
        /// DeviceProfile declaring `profile_id` and naming `mode`.
        fn new(profile_id: &str, mode: &str) -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let root = PathBuf::from("/private/tmp").join(format!(
                "adln-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let bundle = root.join("ArkForge.bundle");
            let runtime = root.join("run");
            for directory in [
                bundle.join("Contents/MacOS"),
                bundle.join("Contents/Resources/profiles"),
                runtime.clone(),
            ] {
                std::fs::create_dir_all(directory).unwrap();
            }
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let members = [
                (
                    "Contents/MacOS/arkforge",
                    b"#!/bin/sh\nexit 0\n".to_vec(),
                    "cli",
                    None,
                ),
                (
                    "Contents/MacOS/arkforged",
                    std::fs::read(std::env::current_exe().unwrap()).unwrap(),
                    "daemon",
                    None,
                ),
                (
                    "Contents/Resources/profiles/dayu200.yaml",
                    format!(
                        "# fake-arkforged: {mode}\nschema: arkforge.device-profile/v1\n\
                         profile:\n  id: {profile_id}\n  version: 1.0.0\n"
                    )
                    .into_bytes(),
                    "profile",
                    Some("org.openharmony.dayu200"),
                ),
            ];
            let mut manifest = Vec::new();
            for (path, bytes, role, profile) in &members {
                std::fs::write(bundle.join(path), bytes).unwrap();
                std::fs::set_permissions(bundle.join(path), std::fs::Permissions::from_mode(0o755))
                    .unwrap();
                manifest.push(json!({"path": path, "sha256": sha256_hex(bytes),
                    "bytes": bytes.len(), "role": role, "profileId": profile}));
            }
            std::fs::write(
                bundle.join("Contents/Resources/arkforge-bundle.json"),
                serde_json::to_vec(&json!({"schema": "arkforge.release-bundle/v1",
                    "version": "0.1.0-test", "members": manifest}))
                .unwrap(),
            )
            .unwrap();
            Self {
                root,
                bundle,
                runtime,
            }
        }

        fn inputs(&self) -> LaneInputs {
            let bundle = self.bundle.to_str().unwrap().to_owned();
            LaneInputs::read(|key| (key == BUNDLE_PATH_KEY).then(|| bundle.clone())).unwrap()
        }

        fn compose(&self) -> Result<Lane, Absence> {
            Lane::compose(
                &self.inputs(),
                &self.runtime,
                1_770_000_000,
                &SECRET,
                AGENTD,
                HDC,
            )
        }

        /// Whether anything still serves this socket.
        fn serving(&self, name: &str) -> bool {
            UnixStream::connect(self.runtime.join(name)).is_ok()
        }

        /// Whether the stand-in this scene launched has ended: the lock it
        /// holds on `alive` for its whole life is free again.
        fn ended(&self) -> bool {
            let alive =
                std::fs::File::open(self.runtime.join("alive")).expect("the stand-in was launched");
            alive.try_lock().is_ok()
        }
    }

    impl Drop for Scene {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn unavailable(result: Result<Lane, Absence>) -> String {
        match result {
            Err(Absence::DaemonUnavailable(detail)) => detail,
            Err(other) => panic!("not a daemon refusal: {other}"),
            Ok(_) => panic!("the lane was composed"),
        }
    }

    // MARK: the cases

    fn a_bundle_composes_one_paired_ready_daemon_that_ends_with_its_owner() {
        let scene = Scene::new("org.openharmony.dayu200", "ready");
        let lane = scene.compose().unwrap();
        assert_eq!(lane.profile_reference(), "org.openharmony.dayu200@1.0.0");
        assert_eq!(lane.daemon_sha256(), scene.inputs().daemon_sha256);
        assert!(lane.assessment_only_reason().is_some());
        // The secret reached it whole, on stdin, and never in its arguments.
        assert_eq!(
            std::fs::read_to_string(scene.runtime.join("paired")).unwrap(),
            sha256_hex(&SECRET)
        );
        let arguments = std::fs::read_to_string(scene.runtime.join("arguments")).unwrap();
        assert_eq!(
            arguments.lines().collect::<Vec<_>>(),
            [
                "--runtime-dir",
                scene.runtime.to_str().unwrap(),
                "--profile",
                scene.inputs().device_profile_path.to_str().unwrap(),
                "--pair-from-stdin",
                "1770000000"
            ]
        );
        // The lane's daemon answers device access through its public socket.
        assert_eq!(
            DeviceAccessObserver::new(&scene.runtime).observe(),
            Ok(Vec::new())
        );
        let stopped = lane.stop().expect("the lane owned a daemon");
        assert!(
            scene.runtime.join("eof").exists()
                || stopped.exit == arkdeck_platform::ServerExit::Signalled(15),
            "{:?}",
            stopped.exit
        );
        assert!(!scene.serving("controller.sock"));
        assert!(scene.ended());
        assert!(lane.stop().is_none(), "one generation stops once");
    }

    fn a_stale_socket_is_never_taken_for_the_new_daemon() {
        let scene = Scene::new("org.openharmony.dayu200", "ready");
        // A previous generation's socket file, which nothing serves.
        drop(UnixListener::bind(scene.runtime.join("controller.sock")).unwrap());
        assert!(scene.runtime.join("controller.sock").exists());
        let lane = scene.compose().unwrap();
        assert!(scene.serving("controller.sock"));
        lane.stop();
    }

    fn a_daemon_that_is_not_ready_is_stopped_and_refused() {
        let scene = Scene::new("org.openharmony.dayu200", "not-ready");
        assert_eq!(
            unavailable(scene.compose()),
            "arkforged is not ready to execute: NO_DISPATCHER. Nothing was dispatched — this \
             is a standing fact about the daemon, not a fault of this job"
        );
        // The refusal returns only once the generation has ended. Whether the
        // stand-in read its end of input before TERM reached it is a race
        // Swift's stop leaves open too, as the stop sends TERM right after
        // closing the input; the platform's paired-launch test proves the
        // input is closed first.
        assert!(scene.ended(), "the generation was stopped");
        assert!(!scene.serving("public.sock"));

        let scene = Scene::new("org.openharmony.dayu200", "replay");
        assert!(unavailable(scene.compose()).starts_with(
            "the daemon bound toolchain replay, while this lane expects \
                 arkforged-native-rockusb"
        ));
        assert!(scene.ended(), "the generation was stopped");
        assert!(!scene.serving("public.sock"));
    }

    fn a_daemon_that_never_opens_its_socket_is_stopped_and_refused() {
        let scene = Scene::new("org.openharmony.dayu200", "exit-at-once");
        let started = Instant::now();
        assert_eq!(
            unavailable(scene.compose()),
            "arkforged started but never opened its controller socket; the owned process \
             generation was stopped before returning the failure"
        );
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "an exited daemon is not waited for"
        );
    }

    fn nothing_is_launched_before_the_profile_and_the_authority_are_proved() {
        let scene = Scene::new("org.openharmony.dayu600", "ready");
        assert_eq!(
            unavailable(scene.compose()),
            "the bundle manifest selected org.openharmony.dayu200, but the DeviceProfile \
             declares org.openharmony.dayu600"
        );
        let scene = Scene::new("org.openharmony.dayu200", "ready");
        let inputs = scene.inputs();
        assert_eq!(
            unavailable(Lane::compose(&inputs, &scene.runtime, 1, &SECRET, "", HDC)),
            "cannot bind ArkForge authority support: the exact running arkdeck-agentd digest \
             is absent or malformed"
        );
        assert_eq!(
            unavailable(Lane::compose(
                &inputs,
                &scene.runtime,
                1,
                &SECRET,
                AGENTD,
                "-"
            )),
            "cannot bind ArkForge authority support: the managed-control HDC digest is absent \
             or malformed"
        );
        // A daemon whose bytes changed after they were measured never runs.
        let daemon = scene.bundle.join("Contents/MacOS/arkforged");
        let mut bytes = std::fs::read(&daemon).unwrap();
        bytes.extend_from_slice(b"changed");
        std::fs::write(&daemon, bytes).unwrap();
        assert!(
            unavailable(Lane::compose(
                &inputs,
                &scene.runtime,
                1,
                &SECRET,
                AGENTD,
                HDC
            ))
            .starts_with("arkforged did not start: ")
        );
        for name in ["paired", "public.sock", "controller.sock"] {
            assert!(!scene.runtime.join(name).exists(), "{name}");
        }
    }

    pub fn run() {
        let cases: [(&str, fn()); 5] = [
            (
                "a_bundle_composes_one_paired_ready_daemon_that_ends_with_its_owner",
                a_bundle_composes_one_paired_ready_daemon_that_ends_with_its_owner,
            ),
            (
                "a_stale_socket_is_never_taken_for_the_new_daemon",
                a_stale_socket_is_never_taken_for_the_new_daemon,
            ),
            (
                "a_daemon_that_is_not_ready_is_stopped_and_refused",
                a_daemon_that_is_not_ready_is_stopped_and_refused,
            ),
            (
                "a_daemon_that_never_opens_its_socket_is_stopped_and_refused",
                a_daemon_that_never_opens_its_socket_is_stopped_and_refused,
            ),
            (
                "nothing_is_launched_before_the_profile_and_the_authority_are_proved",
                nothing_is_launched_before_the_profile_and_the_authority_are_proved,
            ),
        ];
        let mut failed = 0;
        for (name, case) in cases {
            match std::panic::catch_unwind(case) {
                Ok(()) => println!("test {name} ... ok"),
                Err(_) => {
                    failed += 1;
                    println!("test {name} ... FAILED");
                }
            }
        }
        println!(
            "\ntest result: {}. {} passed; {failed} failed",
            if failed == 0 { "ok" } else { "FAILED" },
            cases.len() - failed
        );
        if failed > 0 {
            std::process::exit(101);
        }
    }

    #[allow(dead_code)]
    fn unused(_: &Path) {}
}

fn main() {
    #[cfg(target_os = "macos")]
    {
        let arguments: Vec<String> = std::env::args().collect();
        if arguments
            .iter()
            .any(|argument| argument == "--pair-from-stdin")
        {
            lane::fake_arkforged(arguments);
        }
        lane::run();
    }
}
