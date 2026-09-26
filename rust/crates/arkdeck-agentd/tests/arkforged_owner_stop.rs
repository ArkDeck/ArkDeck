//! The daemon's own end of the ArkForge lane's `arkforged` (TASK-XPA-017),
//! over its process: a start that fails once the lane is composed stops its
//! managed HDC server first and `arkforged` after it, as Swift's failed start
//! does (`main.swift` 1595-1602), naming each by PID on stderr and leaving
//! nothing running; its drain stops `arkforged` first and the managed server
//! after it (1624-1627), writing the line it always wrote.
//!
//! `arkforged` is this test binary, which the daemon launches from a verified
//! bundle: launched with `--pair-from-stdin` it plays the daemon, reads the
//! 32-byte pairing secret, serves a ready controller and public session in
//! its runtime directory with ArkForge's own codec, and ends at its end of
//! input with status 11, as `arkforged` does. It starts with SIGINT and
//! SIGTERM ignored, as the lane launches it and as Swift's daemon starts
//! `arkforged`, so TERM does nothing to it. The
//! HDC is the fake the managed-server tests compile from C. No device,
//! installed state or Swift daemon is used; nothing here is device evidence.
//! A custom harness (`harness = false`): the daemon role must run before any
//! test framework reads the arguments, and the cases run one at a time.

#[cfg(target_os = "macos")]
mod owner {
    use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
    use arkdeck_provider_arkforge::NATIVE_ROCKUSB_TOOLCHAIN;
    use arkforge_ipc::framing::{read_frame, write_frame};
    use arkforge_ipc::messages::{ErrorBody, Hello, HelloAck, Request, Response};
    use arkforge_ipc::{Api, PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status};
    use serde_json::{Value, json};
    use std::fs;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");
    const PROFILE: &str = "schema: arkforge.device-profile/v1\nprofile:\n  id: \
                           org.openharmony.dayu200\n  version: 1.0.0\n";

    mod loopback_ports {
        include!("../../../tests/support/loopback_ports.rs");
    }
    mod fake_hdc_servers {
        include!("../../../tests/support/fake_hdc_servers.rs");
    }

    // MARK: the stand-in `arkforged`

    pub fn fake_arkforged(arguments: Vec<String>) -> ! {
        let runtime = PathBuf::from(
            arguments
                .iter()
                .position(|argument| argument == "--runtime-dir")
                .and_then(|index| arguments.get(index + 1))
                .expect("--runtime-dir"),
        );
        let mut secret = [0u8; 32];
        if std::io::stdin().read_exact(&mut secret).is_err() {
            std::process::exit(12);
        }
        fs::write(runtime.join("pid"), std::process::id().to_string()).unwrap();
        let digest = sha256_hex(&fs::read(std::env::current_exe().unwrap()).unwrap());
        for (name, kind) in [
            ("public.sock", SessionKind::Public),
            ("controller.sock", SessionKind::Controller),
        ] {
            let listener = UnixListener::bind(runtime.join(name)).unwrap();
            let digest = digest.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let digest = digest.clone();
                    std::thread::spawn(move || serve(stream, kind, &digest));
                }
            });
        }
        // Its owner's end of input ends it, as it ends `arkforged`.
        let _ = std::io::stdin().read_to_end(&mut Vec::new());
        std::process::exit(11);
    }

    /// A ready session bound to this binary's own digest, as `arkforged`
    /// reports its own; `discoverDevices` sees nothing.
    fn serve(mut stream: UnixStream, kind: SessionKind, digest: &str) {
        let Ok(Some(frame)) = read_frame(&mut stream) else {
            return;
        };
        let Ok(hello) = Hello::decode(&frame) else {
            return;
        };
        let ack = HelloAck {
            protocol_major: PROTOCOL_MAJOR,
            protocol_minor: PROTOCOL_MINOR,
            session_kind: kind,
            daemon_version: "0.1.0".into(),
            refusal: (hello.session_kind != kind)
                .then(|| format!("this socket serves {kind:?} sessions")),
            execution_ready: true,
            execution_blockers: Vec::new(),
            toolchain_id: NATIVE_ROCKUSB_TOOLCHAIN.into(),
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

    // MARK: the isolated daemon with its managed server and its lane

    struct Scene {
        root: PathBuf,
        port: u16,
        child: Option<Child>,
    }

    impl Scene {
        /// An isolated root with the fake HDC and a verified
        /// `ArkForge.bundle` whose daemon is this binary. The root is short:
        /// the lane's sockets must fit a socket address.
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let root = PathBuf::from(format!(
                "/private/tmp/adao-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&root);
            for directory in [
                root.clone(),
                root.join("state"),
                root.join("state/targets-state"),
                root.join("tools"),
            ] {
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(&directory)
                    .unwrap();
            }
            let targets = root.join("state/targets-state/targets.json");
            fs::copy(
                fixture("target-adoption/targets-state/targets.json"),
                &targets,
            )
            .unwrap();
            fs::set_permissions(&targets, fs::Permissions::from_mode(0o600)).unwrap();
            let tools = root.join("tools");
            let source = tools.join("fake-hdc.c");
            fs::write(&source, FAKE_HDC).unwrap();
            let output = Command::new("cc")
                .arg("-O0")
                .arg(format!("-DRESTART_DIR=\"{}\"", tools.display()))
                .arg(format!("-DSELF_PATH=\"{}\"", tools.join("hdc").display()))
                .arg(format!(
                    "-DRECORD_CALLS=\"{}\"",
                    tools.join("calls").display()
                ))
                .arg(format!("-DOWNER_PID={}", std::process::id()))
                .arg("-o")
                .arg(tools.join("hdc"))
                .arg(&source)
                .output()
                .expect("cc from the developer tools compiles the fake");
            assert!(
                output.status.success(),
                "fake hdc did not compile: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            fs::set_permissions(tools.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
            let scene = Self {
                root,
                port: loopback_ports::free_port(),
                child: None,
            };
            scene.bundle();
            scene
        }

        /// A verified release bundle: a CLI, this binary as its daemon, and
        /// DAYU200's profile.
        fn bundle(&self) {
            let bundle = self.root.join("ArkForge.bundle");
            for directory in ["Contents/MacOS", "Contents/Resources/profiles"] {
                fs::create_dir_all(bundle.join(directory)).unwrap();
            }
            let mut manifest = Vec::new();
            for (path, bytes, role, profile) in [
                (
                    "Contents/MacOS/arkforge",
                    b"#!/bin/sh\nexit 0\n".to_vec(),
                    "cli",
                    None,
                ),
                (
                    "Contents/MacOS/arkforged",
                    fs::read(std::env::current_exe().unwrap()).unwrap(),
                    "daemon",
                    None,
                ),
                (
                    "Contents/Resources/profiles/dayu200.yaml",
                    PROFILE.as_bytes().to_vec(),
                    "profile",
                    Some("org.openharmony.dayu200"),
                ),
            ] {
                fs::write(bundle.join(path), &bytes).unwrap();
                fs::set_permissions(bundle.join(path), fs::Permissions::from_mode(0o755)).unwrap();
                manifest.push(json!({"path": path, "sha256": sha256_hex(&bytes),
                    "bytes": bytes.len(), "role": role, "profileId": profile}));
            }
            fs::write(
                bundle.join("Contents/Resources/arkforge-bundle.json"),
                serde_json::to_vec(&json!({"schema": "arkforge.release-bundle/v1",
                    "version": "0.1.0-test", "members": manifest}))
                .unwrap(),
            )
            .unwrap();
        }

        fn state(&self) -> PathBuf {
            self.root.join("state")
        }

        fn socket(&self) -> PathBuf {
            self.state().join("control.sock")
        }

        fn hdc(&self) -> PathBuf {
            self.root.join("tools/hdc")
        }

        /// The lane's runtime directory beside the Job state.
        fn lane(&self) -> PathBuf {
            self.state().join("jobs-state/arkforge")
        }

        /// The daemon with its managed server on this scene's port and the
        /// lane over this scene's bundle, its stderr kept in `stderr`.
        fn command(&self) -> Command {
            let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
            for (key, _) in std::env::vars_os() {
                let key_text = key.to_string_lossy();
                if key_text.starts_with("ARKDECK_") || key_text.starts_with("OHOS_HDC_") {
                    command.env_remove(key);
                }
            }
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.state())
                .env("ARKDECK_ENDPOINT", self.socket())
                .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.hdc())
                .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
                .env("OHOS_HDC_SERVER_PORT", self.port.to_string())
                .env(
                    "ARKDECK_ARKFORGE_BUNDLE_PATH",
                    self.root.join("ArkForge.bundle"),
                )
                .stdin(Stdio::null())
                .stdout(fs::File::create(self.root.join("stdout")).unwrap())
                .stderr(fs::File::create(self.root.join("stderr")).unwrap());
            command
        }

        fn stderr(&self) -> String {
            fs::read_to_string(self.root.join("stderr")).unwrap()
        }

        fn stdout(&self) -> String {
            fs::read_to_string(self.root.join("stdout")).unwrap()
        }

        /// The stand-in `arkforged`'s own PID, as it recorded it.
        fn arkforged(&self) -> i32 {
            fs::read_to_string(self.lane().join("pid"))
                .expect("the lane's arkforged was launched")
                .parse()
                .unwrap()
        }

        /// Whether any process still runs with this scene's root among its
        /// arguments: the fake HDC's server, or the stand-in `arkforged`
        /// with its runtime directory and profile.
        fn anything_running(&self) -> String {
            let output = Command::new("/usr/bin/pgrep")
                .args(["-fl", self.root.to_str().unwrap()])
                .output()
                .unwrap();
            String::from_utf8_lossy(&output.stdout).into_owned()
        }

        /// The daemon's end within `within`: its status.
        fn exit_within(&mut self, within: Duration) -> std::process::ExitStatus {
            let mut child = self.child.take().unwrap();
            let deadline = Instant::now() + within;
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    return status;
                }
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("the daemon did not end within {within:?}");
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        /// One request over a new connection, and its answer.
        fn call(&self, method: &str) -> Value {
            let mut stream = UnixStream::connect(self.socket()).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(20)))
                .unwrap();
            let mut frame = serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "arkforged-owner-stop", "method": method, "params": {},
            }))
            .unwrap();
            frame.push(b'\n');
            stream.write_all(&frame).unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).unwrap();
            serde_json::from_str(&line).unwrap()
        }
    }

    impl Drop for Scene {
        fn drop(&mut self) {
            if let Some(mut child) = self.child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
            // Whatever a failing case left, ended before its root goes.
            let _ = Command::new("/usr/bin/pkill")
                .args(["-KILL", "-f", self.root.to_str().unwrap()])
                .status();
            fake_hdc_servers::tear_down(&self.root.join("tools"), &self.hdc());
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures")
            .join(name)
    }

    /// The PID a stop line names, and what it says of the end: the text
    /// after `prefix` up to "), which ".
    fn named(line: &str, prefix: &str) -> (i32, String) {
        let (pid, end) = line
            .strip_prefix(prefix)
            .unwrap()
            .split_once("), which ")
            .unwrap();
        (pid.parse().unwrap(), end.to_owned())
    }

    // MARK: the cases

    /// A start that fails once its managed server is launched and its lane
    /// composed — here its Job recovery, refusing an admitted Job whose
    /// record outlived its journal — stops the managed server first and
    /// `arkforged` after it, as Swift's failed start does, each named by PID
    /// with its end, before the refusal. Neither process is left, and
    /// nothing runs from this root.
    fn a_start_that_fails_once_the_lane_is_composed_stops_hdc_then_arkforged() {
        const JOB: &str = "job-082b8363fce0462b4571a62147751099";
        let mut scene = Scene::new();
        {
            let state = scene.state().join("jobs-state");
            fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
            let jobs = arkdeck_hoststore::JobStore::open_owner(&state).unwrap();
            let record = arkdeck_hoststore::JobRecord::decode(
                &fs::read(fixture(&format!(
                    "job-reconcile-analyzer/before/jobs/{JOB}/job-record.json"
                )))
                .unwrap(),
            )
            .unwrap();
            jobs.admit(&record, &"a".repeat(64)).unwrap();
            fs::DirBuilder::new()
                .mode(0o700)
                .recursive(true)
                .create(state.join("jobs").join(JOB))
                .unwrap();
            jobs.persist(&record, "2026-09-26T00:00:00Z").unwrap();
        }
        scene.child = Some(scene.command().spawn().unwrap());
        let status = scene.exit_within(Duration::from_secs(60));
        let stderr = scene.stderr();
        assert_eq!(status.code(), Some(69), "{stderr}");
        let lines: Vec<&str> = stderr.lines().collect();
        assert_eq!(
            lines.last().copied(),
            Some(
                format!(
                    "arkdeck-agentd: internalFailure(\"admitted job {JOB} has a partial \
                     durable projection\")"
                )
                .as_str()
            ),
            "{stderr}"
        );
        let position = |prefix: &str| {
            lines
                .iter()
                .position(|line| line.starts_with(prefix))
                .unwrap_or_else(|| panic!("no line starts with {prefix:?}: {stderr}"))
        };
        const HDC: &str =
            "arkdeck-agentd: stopped the managed HDC server this daemon launched (pid ";
        const ARKFORGED: &str = "arkdeck-agentd: stopped the arkforged this daemon launched (pid ";
        let (hdc, arkforged) = (position(HDC), position(ARKFORGED));
        assert!(
            hdc < arkforged && arkforged == lines.len() - 2,
            "not the managed server, then arkforged, then the refusal: {stderr}"
        );
        for line in &lines[hdc..] {
            println!("  {line}");
        }
        let (server, _) = named(lines[hdc], HDC);
        let (pid, end) = named(lines[arkforged], ARKFORGED);
        assert_eq!(pid, scene.arkforged(), "{stderr}");
        // At its end of input: the TERM right after it does nothing.
        assert_eq!(end, "exited with status 11", "{stderr}");
        for (name, pid) in [("the managed server", server), ("arkforged", pid)] {
            assert!(
                arkdeck_platform::process_argument_record(pid).is_none(),
                "{name} (pid {pid}) still runs"
            );
        }
        let running = scene.anything_running();
        assert!(running.is_empty(), "left running: {running}");
    }

    /// The drain stops `arkforged` before the managed server and writes the
    /// line it always wrote; the drop's report never follows it, as nothing
    /// is left to stop.
    fn the_drain_stops_arkforged_with_its_line_as_before() {
        let mut scene = Scene::new();
        scene.child = Some(scene.command().spawn().unwrap());
        let deadline = Instant::now() + Duration::from_secs(60);
        while UnixStream::connect(scene.socket()).is_err() {
            let exited = scene.child.as_mut().unwrap().try_wait().unwrap();
            assert!(exited.is_none(), "daemon exited: {}", scene.stderr());
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(scene.call("health")["ok"], true, "{}", scene.stderr());
        let pid = scene.arkforged();
        let daemon = scene.child.as_ref().unwrap().id().to_string();
        assert!(
            Command::new("/bin/kill")
                .args(["-TERM", &daemon])
                .status()
                .unwrap()
                .success()
        );
        let status = scene.exit_within(Duration::from_secs(60));
        let stderr = scene.stderr();
        assert_eq!(status.code(), Some(0), "{stderr}");
        assert!(scene.stdout().ends_with("arkdeck-agentd stopped\n"));
        let stops: Vec<&str> = stderr
            .lines()
            .filter(|line| line.contains("stopped") || line.contains("did not stop"))
            .collect();
        for line in &stops {
            println!("  {line}");
        }
        assert_eq!(
            stops,
            ["arkdeck-agentd: stopped arkforged (Exited(11))"],
            "{stderr}"
        );
        assert!(
            arkdeck_platform::process_argument_record(pid).is_none(),
            "arkforged (pid {pid}) still runs"
        );
        let running = scene.anything_running();
        assert!(running.is_empty(), "left running: {running}");
    }

    pub fn run() {
        let cases: [(&str, fn()); 2] = [
            (
                "a_start_that_fails_once_the_lane_is_composed_stops_hdc_then_arkforged",
                a_start_that_fails_once_the_lane_is_composed_stops_hdc_then_arkforged,
            ),
            (
                "the_drain_stops_arkforged_with_its_line_as_before",
                the_drain_stops_arkforged_with_its_line_as_before,
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
}

fn main() {
    #[cfg(target_os = "macos")]
    {
        let arguments: Vec<String> = std::env::args().collect();
        if arguments
            .iter()
            .any(|argument| argument == "--pair-from-stdin")
        {
            owner::fake_arkforged(arguments);
        }
        owner::run();
    }
}
