//! The HDC lifecycle executor's process part on Windows (TASK-XPA-005, H2b),
//! judged as `lifecycle.rs` judges it on macOS: the exact restart and stop
//! commands, the launch identity a launch-window audit records, one launch
//! per preparation through the lifecycle runner, and the post-dispatch
//! re-observation that alone decides the outcome.
//!
//! The fake `hdc` is this binary itself, a `harness = false` target: run as
//! `<exe> -s <endpoint> …` it is the fake, otherwise the test runner. Its
//! `-m` server listens, names its PID and port in `listening-<pid>` beside
//! the copy, and ends when `stop-<port>` appears there (or after two
//! minutes, so that nothing of a failed run outlives it for long). Its
//! `kill` client writes that marker and waits for the port to free; `kill
//! -r` then starts a new `-m` server detached (which inherits the pipes
//! the runner gave the client, as nothing stops a real server from doing)
//! and records its PID in `servers`. The variant is the copy's file
//! name: `hdc-nonzero.exe` exits 23 on `kill`, `hdc-stderr.exe` writes
//! stderr, `hdc-noop.exe` does nothing, and `hdc-foreign.exe`'s `kill -r`
//! starts its replacement from `other.exe`, a copy with other bytes, which
//! the commandless proof cannot bind to the tool. No real HDC is launched,
//! and every server a test caused is ended through its marker.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-s") {
        windows::fake_hdc(&arguments[1..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}

#[cfg(windows)]
mod windows {
    use super::loopback_ports::free_endpoint;
    use arkdeck_platform::{LoopbackServerLease, ToolTermination, VerifiedTool, random_bytes};
    use arkdeck_provider_hdc::{
        LifecycleAction, LifecycleBudget, LifecycleCommand, LifecycleOutcome,
        PostDispatchObservation, PreparedLifecycle, generation,
    };
    use sha2::{Digest, Sha256};
    use std::fs;
    use std::io::Write;
    use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    // ---- the fake hdc -----------------------------------------------------

    fn reachable(endpoint: SocketAddrV4) -> bool {
        TcpStream::connect_timeout(&SocketAddr::V4(endpoint), Duration::from_millis(100)).is_ok()
    }

    /// Writes `path` whole, then renames it into place.
    fn publish(path: &Path, text: &str) {
        let partial = path.with_extension("partial");
        fs::write(&partial, text).unwrap();
        fs::rename(&partial, path).unwrap();
    }

    /// Asks the server on `endpoint` to end and waits for its port to free.
    fn stop_server(directory: &Path, endpoint: SocketAddrV4) {
        publish(&directory.join(format!("stop-{}", endpoint.port())), "stop");
        let deadline = Instant::now() + Duration::from_secs(10);
        while reachable(endpoint) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    pub fn fake_hdc(arguments: &[String]) -> ! {
        let executable = std::env::current_exe().unwrap();
        let directory = executable.parent().unwrap().to_owned();
        let variant = executable.file_stem().unwrap().to_str().unwrap().to_owned();
        let endpoint: SocketAddrV4 = arguments[1].parse().unwrap();
        let command: Vec<&str> = arguments[2..].iter().map(String::as_str).collect();
        match command.as_slice() {
            ["-m"] => serve(&directory, endpoint),
            ["kill"] | ["kill", "-r"] => {
                match variant.as_str() {
                    "hdc-nonzero" => std::process::exit(23),
                    "hdc-stderr" => {
                        eprintln!("kill: unexpected condition");
                        std::process::exit(0);
                    }
                    "hdc-noop" => std::process::exit(0),
                    _ => {}
                }
                stop_server(&directory, endpoint);
                if command.len() == 2 {
                    let replacement = if variant == "hdc-foreign" {
                        directory.join("other.exe")
                    } else {
                        executable.clone()
                    };
                    let pid = detach(&replacement, endpoint);
                    let mut servers = fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(directory.join("servers"))
                        .unwrap();
                    writeln!(servers, "{pid}").unwrap();
                }
                std::process::exit(0);
            }
            _ => std::process::exit(64),
        }
    }

    /// `-m`: listens until `stop-<port>` appears, which it consumes.
    fn serve(directory: &Path, endpoint: SocketAddrV4) -> ! {
        let listener = TcpListener::bind(endpoint).unwrap();
        listener.set_nonblocking(true).unwrap();
        publish(
            &directory.join(format!("listening-{}", std::process::id())),
            &format!("{} {}\n", std::process::id(), endpoint.port()),
        );
        let marker = directory.join(format!("stop-{}", endpoint.port()));
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            if marker.exists() {
                let _ = fs::remove_file(&marker);
                break;
            }
            let _ = listener.accept();
            std::thread::sleep(Duration::from_millis(10));
        }
        std::process::exit(0);
    }

    /// Starts `executable -s <endpoint> -m` detached, as HDC starts its
    /// server: in no console of this client's. It inherits this client's
    /// standard handles, as a server a client starts may: the lifecycle
    /// runner's capture ends with the client regardless.
    fn detach(executable: &Path, endpoint: SocketAddrV4) -> u32 {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        Command::new(executable)
            .args(["-s", &endpoint.to_string(), "-m"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .unwrap()
            .id()
    }

    // ---- the runner -----------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "the_actual_command_and_the_launch_identity_are_windows_s",
            the_actual_command_and_the_launch_identity_are_windows_s,
        ),
        (
            "a_changed_executable_is_not_prepared",
            a_changed_executable_is_not_prepared,
        ),
        (
            "a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation",
            a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation,
        ),
        (
            "a_replacement_the_proof_cannot_bind_is_never_adopted_and_is_reported",
            a_replacement_the_proof_cannot_bind_is_never_adopted_and_is_reported,
        ),
        (
            "a_confirmed_stop_ends_in_an_unavailable_endpoint",
            a_confirmed_stop_ends_in_an_unavailable_endpoint,
        ),
        (
            "a_nonzero_exit_leaves_the_outcome_unknown",
            a_nonzero_exit_leaves_the_outcome_unknown,
        ),
        (
            "unregistered_stderr_leaves_the_outcome_unknown",
            unregistered_stderr_leaves_the_outcome_unknown,
        ),
        (
            "a_command_that_changes_nothing_cannot_be_re_proved",
            a_command_that_changes_nothing_cannot_be_re_proved,
        ),
    ];

    /// A minimal libtest stand-in: runs every test whose name contains one
    /// of the free arguments (all when none is given), one at a time.
    pub fn run_tests(arguments: &[String]) -> ! {
        let mut filters = Vec::new();
        let mut list = false;
        let mut skip_value = false;
        for argument in arguments {
            if skip_value {
                skip_value = false;
            } else if argument == "--list" {
                list = true;
            } else if matches!(
                argument.as_str(),
                "--test-threads" | "--skip" | "--format" | "--color" | "-Z"
            ) {
                skip_value = true;
            } else if !argument.starts_with('-') {
                filters.push(argument.clone());
            }
        }
        let selected: Vec<&Test> = TESTS
            .iter()
            .filter(|(name, _)| filters.is_empty() || filters.iter().any(|f| name.contains(f)))
            .collect();
        if list {
            for (name, _) in &selected {
                println!("{name}: test");
            }
            std::process::exit(0);
        }
        println!("\nrunning {} tests", selected.len());
        let mut failed = 0;
        for (name, test) in &selected {
            let passed = std::panic::catch_unwind(test).is_ok();
            println!("test {name} ... {}", if passed { "ok" } else { "FAILED" });
            failed += usize::from(!passed);
        }
        println!(
            "\ntest result: {}. {} passed; {failed} failed",
            if failed == 0 { "ok" } else { "FAILED" },
            selected.len() - failed,
        );
        std::process::exit(i32::from(failed != 0));
    }

    // ---- helpers --------------------------------------------------------

    /// One copy of this binary as a fake `hdc` variant (and `other.exe`,
    /// the same bytes with one more), in its own canonical directory.
    struct FakeHdc {
        directory: PathBuf,
        tool: VerifiedTool,
        /// Every endpoint a server of this fake was started on, each asked
        /// to end when the fake is dropped, on a panic as well.
        endpoints: std::cell::RefCell<Vec<SocketAddrV4>>,
        /// Dropped last, once the tool's handle on the copy has closed:
        /// NTFS removes no directory holding a file still open.
        _removed: Removed,
    }

    /// The fake's scratch directory, removed when dropped: retried while a
    /// server that was asked to end still holds its image open.
    struct Removed(PathBuf);

    impl Drop for Removed {
        fn drop(&mut self) {
            let deadline = Instant::now() + Duration::from_secs(10);
            while fs::remove_dir_all(&self.0).is_err() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }

    impl FakeHdc {
        fn new(variant: &str) -> Self {
            let temporary = std::env::temp_dir().canonicalize().unwrap();
            let temporary = temporary
                .to_str()
                .and_then(|text| text.strip_prefix(r"\\?\"))
                .map_or(temporary.clone(), PathBuf::from);
            let directory = temporary.join(format!(
                "arkdeck-lifecycle-{variant}-{:032x}",
                u128::from_le_bytes(random_bytes().unwrap())
            ));
            fs::create_dir(&directory).unwrap();
            let bytes = fs::read(std::env::current_exe().unwrap()).unwrap();
            let path = directory.join(format!("{variant}.exe"));
            fs::write(&path, &bytes).unwrap();
            let mut other = bytes;
            other.push(0);
            fs::write(directory.join("other.exe"), other).unwrap();
            let digest = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
            let tool = VerifiedTool::open(&path, &digest).unwrap();
            Self {
                _removed: Removed(directory.clone()),
                directory,
                tool,
                endpoints: std::cell::RefCell::default(),
            }
        }

        /// A server of the fake at the endpoint, started by the test as the
        /// daemon would have started it, and its proved generation.
        fn server(&self, endpoint: SocketAddrV4) -> (Server, u64) {
            self.endpoints.borrow_mut().push(endpoint);
            let mut server = Server(
                Command::new(self.tool.path())
                    .args(["-s", &endpoint.to_string(), "-m"])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            );
            let pid = server.0.id();
            let listening = self.directory.join(format!("listening-{pid}"));
            let deadline = Instant::now() + Duration::from_secs(60);
            while !listening.exists() {
                if let Some(status) = server.0.try_wait().unwrap() {
                    panic!("the fake server ended before it listened on {endpoint}: {status}");
                }
                assert!(Instant::now() < deadline, "the fake server never listened");
                std::thread::sleep(Duration::from_millis(10));
            }
            let lease = LoopbackServerLease::acquire(&self.tool, endpoint)
                .unwrap_or_else(|error| panic!("{endpoint} has no proved owner: {error}"));
            assert_eq!(u32::try_from(lease.identity().pid).ok(), Some(pid));
            let expected = generation(lease.identity()).unwrap();
            (server, expected)
        }

        /// The PIDs `kill -r` recorded for the servers it started.
        fn replacements(&self) -> Vec<u32> {
            fs::read_to_string(self.directory.join("servers"))
                .unwrap_or_default()
                .lines()
                .map(|line| line.parse().unwrap())
                .collect()
        }
    }

    impl Drop for FakeHdc {
        fn drop(&mut self) {
            for endpoint in self.endpoints.borrow().iter() {
                if reachable(*endpoint) {
                    stop_server(&self.directory, *endpoint);
                }
            }
            // The directory goes with `_removed`, after the tool's handle.
        }
    }

    struct Server(Child);

    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn budget(probe: Duration) -> LifecycleBudget {
        LifecycleBudget {
            probe_deadline: probe,
            ..LifecycleBudget::default()
        }
    }

    fn launch(
        fake: &FakeHdc,
        action: LifecycleAction,
        endpoint: SocketAddrV4,
        expected: u64,
        probe: Duration,
    ) -> arkdeck_provider_hdc::LifecycleReceipt {
        let command = LifecycleCommand::new(action, endpoint, &fake.tool);
        PreparedLifecycle::prepare(&fake.tool, command, expected)
            .unwrap()
            .launch(&budget(probe))
    }

    // ---- tests ----------------------------------------------------------

    fn the_actual_command_and_the_launch_identity_are_windows_s() {
        let fake = FakeHdc::new("hdc");
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710);
        let restart = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
        assert_eq!(restart.arguments, ["-s", "127.0.0.1:8710", "kill", "-r"]);
        assert_eq!(restart.executable, fake.tool.path());
        let stop = LifecycleCommand::new(LifecycleAction::Stop, endpoint, &fake.tool);
        assert_eq!(stop.arguments, ["-s", "127.0.0.1:8710", "kill"]);
        let prepared = PreparedLifecycle::prepare(&fake.tool, restart.clone(), 1).unwrap();
        assert_eq!(prepared.command(), &restart);
        let identity = prepared.identity();
        // Windows launches by the authorized path; the retained file's
        // identity is its volume and NTFS file id.
        assert_eq!(identity.authorized_path, fake.tool.path());
        assert_eq!(
            identity.inode_launch_path,
            fake.tool.path().to_str().unwrap()
        );
        assert_ne!(identity.inode, 0);
        assert_ne!(identity.device, 0);
        assert_eq!(
            identity.file_size,
            fs::metadata(fake.tool.path()).unwrap().len()
        );
        assert_eq!(identity.sha256, fake.tool.sha256());
        // The same file keeps its identity; a second preparation agrees.
        let again = PreparedLifecycle::prepare(&fake.tool, stop, 1).unwrap();
        assert_eq!(again.identity(), identity);
    }

    fn a_changed_executable_is_not_prepared() {
        let fake = FakeHdc::new("hdc");
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710);
        let command = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
        // The retained handle shares no write: the file cannot change under
        // it, and a copy with other bytes is another tool, never prepared as
        // this one.
        assert!(
            fs::OpenOptions::new()
                .append(true)
                .open(fake.tool.path())
                .is_err()
        );
        let other = fake.directory.join("other.exe");
        let digest = fake.tool.sha256().to_owned();
        assert!(VerifiedTool::open(&other, &digest).is_err());
        assert!(PreparedLifecycle::prepare(&fake.tool, command, 1).is_ok());
    }

    /// The client is ended with its run; the server its `kill -r` started
    /// breaks away from the client's Job, is proved by a fresh commandless
    /// proof to be a strictly newer server of the same tool, and so is the
    /// outcome.
    fn a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation() {
        let fake = FakeHdc::new("hdc");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        let old_pid = server.0.id();
        let receipt = launch(
            &fake,
            LifecycleAction::Restart,
            endpoint,
            expected,
            Duration::from_secs(10),
        );
        let LifecycleOutcome::Succeeded {
            resulting_generation,
        } = &receipt.outcome
        else {
            panic!("expected the restart to succeed: {receipt:?}");
        };
        assert!(*resulting_generation > expected);
        assert_eq!(
            receipt.observation,
            Some(PostDispatchObservation::Generation(*resulting_generation))
        );
        assert_eq!(receipt.termination, Some(ToolTermination::Exited(0)));
        assert!(receipt.stdout.is_empty() && receipt.stderr.is_empty());
        assert!(!receipt.unproved_listener);
        let lease = LoopbackServerLease::acquire(&fake.tool, endpoint).unwrap();
        let replacement = u32::try_from(lease.identity().pid).unwrap();
        assert_ne!(replacement, old_pid);
        assert_eq!(fake.replacements(), [replacement]);
        drop(lease);
        drop(server);
    }

    /// A replacement from other bytes answers the endpoint, but the
    /// commandless proof cannot bind it to the tool: the restart is never
    /// reported as succeeded, the server is not adopted or signalled by the
    /// executor, and the receipt says that an unproved listener holds the
    /// endpoint. The test ends the server it caused.
    fn a_replacement_the_proof_cannot_bind_is_never_adopted_and_is_reported() {
        let fake = FakeHdc::new("hdc-foreign");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        let receipt = launch(
            &fake,
            LifecycleAction::Restart,
            endpoint,
            expected,
            Duration::from_secs(2),
        );
        assert_eq!(
            receipt.outcome,
            LifecycleOutcome::OutcomeUnknown(
                "lifecycle process completed but server state could not be re-probed".into()
            ),
            "{receipt:?}"
        );
        assert_eq!(receipt.observation, None);
        assert!(receipt.unproved_listener, "{receipt:?}");
        // Still running, still answering, and never this tool's.
        assert_eq!(fake.replacements().len(), 1);
        assert!(reachable(endpoint));
        assert!(LoopbackServerLease::acquire(&fake.tool, endpoint).is_err());
        drop(server);
    }

    fn a_confirmed_stop_ends_in_an_unavailable_endpoint() {
        let fake = FakeHdc::new("hdc");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        let receipt = launch(
            &fake,
            LifecycleAction::Stop,
            endpoint,
            expected,
            Duration::from_secs(10),
        );
        assert_eq!(receipt.outcome, LifecycleOutcome::Stopped, "{receipt:?}");
        assert_eq!(
            receipt.observation,
            Some(PostDispatchObservation::Unavailable)
        );
        assert!(!receipt.unproved_listener);
        assert!(!reachable(endpoint));
        assert!(fake.replacements().is_empty());
        drop(server);
    }

    fn a_nonzero_exit_leaves_the_outcome_unknown() {
        let fake = FakeHdc::new("hdc-nonzero");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        let receipt = launch(
            &fake,
            LifecycleAction::Restart,
            endpoint,
            expected,
            Duration::from_millis(500),
        );
        assert_eq!(
            receipt.outcome,
            LifecycleOutcome::OutcomeUnknown(
                "lifecycle launch window was entered and the process did not exit zero; post-dispatch state requires reconciliation".into()
            )
        );
        assert_eq!(receipt.termination, Some(ToolTermination::Exited(23)));
        assert_eq!(receipt.observation, None);
        drop(server);
    }

    fn unregistered_stderr_leaves_the_outcome_unknown() {
        let fake = FakeHdc::new("hdc-stderr");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        let receipt = launch(
            &fake,
            LifecycleAction::Stop,
            endpoint,
            expected,
            Duration::from_millis(500),
        );
        assert_eq!(
            receipt.outcome,
            LifecycleOutcome::OutcomeUnknown(
                "lifecycle process emitted unregistered stderr; post-dispatch state is not trusted"
                    .into()
            )
        );
        assert_eq!(receipt.stderr, b"kill: unexpected condition\n");
        drop(server);
    }

    fn a_command_that_changes_nothing_cannot_be_re_proved() {
        let fake = FakeHdc::new("hdc-noop");
        let endpoint = free_endpoint();
        let (server, expected) = fake.server(endpoint);
        for action in [LifecycleAction::Restart, LifecycleAction::Stop] {
            let receipt = launch(
                &fake,
                action,
                endpoint,
                expected,
                Duration::from_millis(700),
            );
            assert_eq!(
                receipt.outcome,
                LifecycleOutcome::OutcomeUnknown(
                    "lifecycle process completed but server state could not be re-probed".into()
                ),
                "{action:?}"
            );
            assert_eq!(receipt.observation, None);
            // The proved original still holds the endpoint: nothing unproved.
            assert!(!receipt.unproved_listener);
        }
        assert!(reachable(endpoint));
        drop(server);
    }
}
