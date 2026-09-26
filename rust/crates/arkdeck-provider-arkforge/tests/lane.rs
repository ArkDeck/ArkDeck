//! The lane composed end to end against a stand-in `arkforged`: this test
//! binary itself, which the lane launches from a real, verified bundle as its
//! daemon. Launched with `--pair-from-stdin` it plays the daemon: it reads the
//! 32-byte pairing secret, binds `public.sock` then `controller.sock` in its
//! runtime directory, acknowledges each session with the readiness its
//! profile's `# fake-arkforged:` comment names (bound to its own bytes' digest,
//! as `arkforged` reports its own), answers `discoverDevices` with nothing,
//! and ends on its stdin's end — the owner's liveness — with status 11.
//!
//! Three more stand-ins play the owner's stop (`stop_order`): they catch TERM
//! rather than die of it, and record in `events` what reached them and when.
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
    use std::io::{Read, Write};
    use std::os::fd::AsFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    const SECRET: [u8; 32] = [0x5a; 32];
    const AGENTD: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    const HDC: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
    /// The stand-ins of the owner's stop (`stop_order`).
    const STOP_ORDER: [&str; 3] = ["ends-at-eof", "outlasts-eof", "ignores-term"];
    /// The half second the owner's stop gives TERM before KILL, as Swift's
    /// `stopDaemonProcessGroup` does.
    const TERM_GRACE: Duration = Duration::from_millis(500);

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
        // Caught from the start, so that TERM never ends a stop-order
        // stand-in by itself; every other one keeps TERM's default.
        let stop = STOP_ORDER
            .contains(&mode.as_str())
            .then(|| arkdeck_platform::StopSignal::install().unwrap());
        let mut secret = [0u8; 32];
        if std::io::stdin().read_exact(&mut secret).is_err() {
            std::process::exit(12);
        }
        // Held for its whole life: the kernel lets go of it only when this
        // process ends, which is what the cases observe.
        let alive = std::fs::File::create(runtime.join("alive")).unwrap();
        alive.lock().unwrap();
        std::fs::write(runtime.join("pid"), std::process::id().to_string()).unwrap();
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
        if let Some(stop) = stop {
            stop_order(&runtime.join("events"), &mode, &stop);
        }
        // Its owner's end of input, and nothing else, ends it.
        let mut rest = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut rest);
        std::fs::write(runtime.join("eof"), rest.len().to_string()).unwrap();
        std::process::exit(11);
    }

    /// The owner's stop as a stand-in meets it, each event a line of
    /// `events` with the microsecond it was recorded at:
    ///
    /// - `ends-at-eof` watches its input, as `arkforged` does, and exits 11 at
    ///   its end. TERM does nothing to it, as it does nothing to an
    ///   `arkforged` Swift started, which inherits TERM ignored.
    /// - `outlasts-eof` does not watch its input. At TERM it records whether
    ///   that input had already ended, then exits 21.
    /// - `ignores-term` records the same at TERM and keeps running, so only
    ///   KILL can end it.
    fn stop_order(events: &Path, mode: &str, stop: &arkdeck_platform::StopSignal) -> ! {
        if mode == "ends-at-eof" {
            let mut rest = Vec::new();
            let _ = std::io::stdin().read_to_end(&mut rest);
            record(events, "eof", "");
            record(events, "exit", "11");
            std::process::exit(11);
        }
        while !stop.requested() {
            std::thread::sleep(Duration::from_millis(1));
        }
        record(
            events,
            "term",
            if input_ended() {
                "input-ended"
            } else {
                "input-open"
            },
        );
        if mode == "outlasts-eof" {
            record(events, "exit", "21");
            std::process::exit(21);
        }
        loop {
            std::thread::park();
        }
    }

    /// Whether this process's input has ended — its owner closed the pipe's
    /// write end — without waiting for it: a nonblocking read of stdin
    /// answers 0 at the end, and would-block while the owner holds it open.
    /// The pipe is made nonblocking through std's socket door, whose
    /// `set_nonblocking` sets `O_NONBLOCK` on any descriptor; this crate
    /// forbids the unsafe `fcntl`.
    fn input_ended() -> bool {
        let duplicate = || std::io::stdin().as_fd().try_clone_to_owned().unwrap();
        UnixStream::from(duplicate()).set_nonblocking(true).unwrap();
        matches!(std::fs::File::from(duplicate()).read(&mut [0u8; 1]), Ok(0))
    }

    fn record(events: &Path, event: &str, detail: &str) {
        let micros = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros();
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(events)
            .unwrap();
        file.write_all(format!("{event} {micros} {detail}\n").as_bytes())
            .unwrap();
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

        /// The stand-in's own PID, as it recorded it.
        fn pid(&self) -> i32 {
            std::fs::read_to_string(self.runtime.join("pid"))
                .unwrap()
                .parse()
                .unwrap()
        }

        /// Drops `lane` without its stop, as a daemon that ends without its
        /// drain drops it: how long the drop took, and what reached the
        /// stand-in, in the order it recorded it, each event with its detail
        /// and how many milliseconds after the drop began it was recorded.
        fn dropped(&self, lane: Lane) -> (Duration, Vec<(String, String, f64)>) {
            let began = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_micros() as f64;
            let started = Instant::now();
            drop(lane);
            let took = started.elapsed();
            let events = std::fs::read_to_string(self.runtime.join("events"))
                .unwrap_or_default()
                .lines()
                .map(|line| {
                    let mut fields = line.splitn(3, ' ');
                    let event = fields.next().unwrap().to_owned();
                    let micros: f64 = fields.next().unwrap().parse().unwrap();
                    let detail = fields.next().unwrap_or_default().to_owned();
                    (event, detail, (micros - began) / 1000.0)
                })
                .collect();
            (took, events)
        }

        /// Nothing of the stand-in is left: its PID names no process, no
        /// process runs with this scene's runtime directory among its
        /// arguments, and its lifelong lock is free.
        fn nothing_left(&self, pid: i32) {
            assert!(
                arkdeck_platform::process_argument_record(pid).is_none(),
                "the stand-in (pid {pid}) still runs"
            );
            let running = std::process::Command::new("/usr/bin/pgrep")
                .args(["-f", self.runtime.to_str().unwrap()])
                .output()
                .unwrap();
            assert!(
                running.stdout.is_empty(),
                "left running: {}",
                String::from_utf8_lossy(&running.stdout)
            );
            assert!(self.ended(), "the stand-in's lock is still held");
        }
    }

    /// The events a stop-order stand-in recorded, without their times, after
    /// printing them with their times.
    fn seen(case: &str, took: Duration, events: &[(String, String, f64)]) -> Vec<(String, String)> {
        let timeline: Vec<String> = events
            .iter()
            .map(|(event, detail, at)| format!("{event} {detail} +{at:.1} ms"))
            .collect();
        println!("  {case}: the drop took {took:?}; {}", timeline.join(", "));
        events
            .iter()
            .map(|(event, detail, _)| (event.clone(), detail.clone()))
            .collect()
    }

    fn expected(events: &[(&str, &str)]) -> Vec<(String, String)> {
        events
            .iter()
            .map(|(event, detail)| ((*event).to_owned(), (*detail).to_owned()))
            .collect()
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

    // A lane dropped without its stop — as a daemon that ends without its
    // drain drops it — ends its daemon as Swift's failed start does
    // (`DaemonLifecycle.stop`, `stopDaemonProcessGroup`): its end of input,
    // then TERM to its group, then KILL once half a second has passed, and
    // reaps it. Each stand-in catches TERM and records what reached it.

    /// A daemon that ends at its end of input, as `arkforged` does, ends
    /// there with its own status, whatever the TERM that follows does.
    fn a_dropped_lane_ends_a_daemon_at_its_end_of_input() {
        let scene = Scene::new("org.openharmony.dayu200", "ends-at-eof");
        let lane = scene.compose().unwrap();
        let pid = scene.pid();
        let (took, events) = scene.dropped(lane);
        assert_eq!(
            seen("ends-at-eof", took, &events),
            expected(&[("eof", ""), ("exit", "11")])
        );
        scene.nothing_left(pid);
    }

    /// A daemon that does not watch its input finds, at its TERM, that the
    /// input has already ended: the end of input comes first.
    fn a_dropped_lane_sends_term_only_once_the_input_has_ended() {
        let scene = Scene::new("org.openharmony.dayu200", "outlasts-eof");
        let lane = scene.compose().unwrap();
        let pid = scene.pid();
        let (took, events) = scene.dropped(lane);
        assert_eq!(
            seen("outlasts-eof", took, &events),
            expected(&[("term", "input-ended"), ("exit", "21")])
        );
        scene.nothing_left(pid);
    }

    /// A daemon that outlives its TERM is killed once TERM's half second has
    /// passed, and reaped.
    fn a_dropped_lane_kills_a_daemon_that_outlives_term_after_its_grace() {
        let scene = Scene::new("org.openharmony.dayu200", "ignores-term");
        let lane = scene.compose().unwrap();
        let pid = scene.pid();
        let (took, events) = scene.dropped(lane);
        assert_eq!(
            seen("ignores-term", took, &events),
            expected(&[("term", "input-ended")])
        );
        assert!(
            took >= TERM_GRACE,
            "the drop ended {took:?} after it began, within TERM's grace: KILL came early"
        );
        scene.nothing_left(pid);
    }

    pub fn run() {
        let cases: [(&str, fn()); 8] = [
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
            (
                "a_dropped_lane_ends_a_daemon_at_its_end_of_input",
                a_dropped_lane_ends_a_daemon_at_its_end_of_input,
            ),
            (
                "a_dropped_lane_sends_term_only_once_the_input_has_ended",
                a_dropped_lane_sends_term_only_once_the_input_has_ended,
            ),
            (
                "a_dropped_lane_kills_a_daemon_that_outlives_term_after_its_grace",
                a_dropped_lane_kills_a_daemon_that_outlives_term_after_its_grace,
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
