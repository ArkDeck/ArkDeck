//! `ManagedHdcServer` and `ProcessDispatch` on Windows (TASK-XPA-005): the
//! HDC server the daemon owns, started, proved ready and bound to its own
//! launch through the Windows Job-object runner and the commandless listener
//! proof, as the macOS tests (`managed_server.rs`, `process_dispatch.rs`) do
//! it with a fake compiled from C.
//!
//! The fake `hdc` is this binary itself, a `harness = false` target: run as
//! `<exe> -s <endpoint> …` it is the fake, otherwise the test runner. A
//! variant is chosen by the copy's file name, since the host names the
//! child's environment: `hdc-early.exe` ends before it binds (status 3),
//! `hdc-mismatch.exe` answers a disagreeing server version, `hdc-nobind.exe`
//! runs as a server without ever binding. Run as `<exe> -t <connectKey> …`
//! it is the fake device face: it answers the product-name read of the
//! connect key it was given. Every invocation appends its arguments to
//! `calls` beside the copy. No real HDC is launched.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-s") {
        windows::fake_hdc(&arguments[1..]);
    }
    if arguments.get(1).is_some_and(|flag| flag == "-t") {
        windows::fake_device(&arguments[1..]);
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
    use arkdeck_platform::{
        LoopbackServerLease, ProvedProcessEnd, ServerExit, VerifiedTool, end_proved_process,
        random_bytes,
    };
    use arkdeck_provider_hdc::{
        Action, HdcDispatch, ManagedHdcServer, ProcessDispatch, ProcessPlan, Property, StartBudget,
        StartFailure,
    };
    use sha2::{Digest, Sha256};
    use std::fs;
    use std::io::Write;
    use std::net::{SocketAddr, SocketAddrV4, TcpListener, TcpStream};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    // ---- the fake hdc -----------------------------------------------------

    /// `-s <endpoint> -m` binds the endpoint and accepts forever;
    /// `-s <endpoint> checkserver` answers the registered line; `-s
    /// <endpoint> echo …` prints its arguments and the server port it was
    /// named; anything else is unregistered (status 64).
    pub fn fake_hdc(arguments: &[String]) -> ! {
        let executable = std::env::current_exe().unwrap();
        let variant = executable.file_stem().unwrap().to_str().unwrap().to_owned();
        let mut calls = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(executable.with_file_name("calls"))
            .unwrap();
        calls
            .write_all(format!("{}\n", arguments.join(" ")).as_bytes())
            .unwrap();
        drop(calls);
        let endpoint: SocketAddrV4 = arguments[1].parse().unwrap();
        let mut stdout = std::io::stdout().lock();
        match arguments.get(2).map(String::as_str) {
            Some("-m") => {
                if variant == "hdc-early" {
                    std::process::exit(3);
                }
                if variant == "hdc-nobind" {
                    loop {
                        std::thread::park();
                    }
                }
                let listener = TcpListener::bind(endpoint).unwrap();
                for connection in listener.incoming() {
                    drop(connection);
                }
                std::process::exit(0);
            }
            Some("checkserver") => {
                let server = if variant == "hdc-mismatch" {
                    "3.2.0f"
                } else {
                    "3.2.0d"
                };
                writeln!(
                    stdout,
                    "Client version:Ver: 3.2.0d, server version:Ver: {server}"
                )
                .unwrap();
            }
            Some("echo") => {
                let port = std::env::var("OHOS_HDC_SERVER_PORT").unwrap_or_default();
                writeln!(stdout, "port={port} args={}", arguments[3..].join("|")).unwrap();
            }
            _ => std::process::exit(64),
        }
        stdout.flush().unwrap();
        std::process::exit(0);
    }

    /// `-t <connectKey> shell param get const.product.name` answers the
    /// product name; any other device command is unregistered (status 64).
    pub fn fake_device(arguments: &[String]) -> ! {
        let executable = std::env::current_exe().unwrap();
        let mut calls = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(executable.with_file_name("calls"))
            .unwrap();
        calls
            .write_all(format!("{}\n", arguments.join("|")).as_bytes())
            .unwrap();
        drop(calls);
        if arguments[2..] == ["shell", "param", "get", "const.product.name"] {
            let mut stdout = std::io::stdout().lock();
            writeln!(stdout, "OpenHarmony Reference Device").unwrap();
            stdout.flush().unwrap();
            std::process::exit(0);
        }
        std::process::exit(64);
    }

    // ---- the runner -----------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "a_server_becomes_ready_and_is_bound_to_its_launch",
            a_server_becomes_ready_and_is_bound_to_its_launch,
        ),
        (
            "a_server_that_ends_before_it_listens_reports_its_exit",
            a_server_that_ends_before_it_listens_reports_its_exit,
        ),
        (
            "a_server_whose_versions_disagree_is_never_ready_and_is_stopped",
            a_server_whose_versions_disagree_is_never_ready_and_is_stopped,
        ),
        (
            "an_occupied_endpoint_launches_nothing",
            an_occupied_endpoint_launches_nothing,
        ),
        (
            "a_proved_replacement_is_ended_and_the_endpoint_serves_the_next_start",
            a_proved_replacement_is_ended_and_the_endpoint_serves_the_next_start,
        ),
        (
            "a_listener_of_another_process_never_binds_the_launch",
            a_listener_of_another_process_never_binds_the_launch,
        ),
        (
            "a_dispatch_runs_the_plan_argv_with_the_server_port_and_grants_no_mutation",
            a_dispatch_runs_the_plan_argv_with_the_server_port_and_grants_no_mutation,
        ),
        (
            "a_device_plan_reaches_the_child_with_its_connect_key_first",
            a_device_plan_reaches_the_child_with_its_connect_key_first,
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

    /// One copy of this binary as a fake `hdc` variant, under its own
    /// canonical scratch directory.
    struct FakeHdc {
        directory: PathBuf,
        tool: VerifiedTool,
        /// Dropped last, once the tool's handle on the copy has closed:
        /// NTFS removes no directory holding a file still open.
        _removed: Removed,
    }

    /// The fake's scratch directory, removed when dropped.
    struct Removed(PathBuf);

    impl FakeHdc {
        fn new(variant: &str) -> Self {
            let directory = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arkdeck-xpa005-hdc-{:032x}",
                u128::from_le_bytes(random_bytes().unwrap())
            ));
            fs::create_dir(&directory).unwrap();
            let path = directory.join(format!("{variant}.exe"));
            fs::copy(std::env::current_exe().unwrap(), &path).unwrap();
            let digest = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
            let tool = VerifiedTool::open(&path, &digest).unwrap();
            Self {
                _removed: Removed(directory.clone()),
                directory,
                tool,
            }
        }

        /// Every invocation's arguments, one line each.
        fn calls(&self) -> Vec<String> {
            fs::read_to_string(self.directory.join("calls"))
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }
    }

    impl Drop for Removed {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn budget(readiness: Duration) -> StartBudget {
        StartBudget {
            readiness,
            ..StartBudget::default()
        }
    }

    fn reachable(endpoint: SocketAddrV4) -> bool {
        TcpStream::connect_timeout(&SocketAddr::V4(endpoint), Duration::from_millis(100)).is_ok()
    }

    fn unreachable_within(endpoint: SocketAddrV4, budget: Duration) -> bool {
        let deadline = Instant::now() + budget;
        while Instant::now() < deadline {
            if !reachable(endpoint) {
                return true;
            }
        }
        !reachable(endpoint)
    }

    // ---- tests ----------------------------------------------------------

    fn a_server_becomes_ready_and_is_bound_to_its_launch() {
        let fake = FakeHdc::new("hdc");
        let endpoint = free_endpoint();
        let mut server =
            ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(15))).unwrap();
        assert_eq!(server.endpoint(), endpoint);
        assert_eq!(server.check().client_version, "3.2.0d");
        assert_eq!(server.check().server_version, "3.2.0d");
        let launch = server.launch().clone();
        let identity = server.identity().clone();
        assert_eq!(identity.pid, launch.pid);
        assert_eq!(
            (identity.start_seconds, identity.start_microseconds),
            (launch.start_seconds, launch.start_microseconds)
        );
        assert_eq!(identity.executable_path, launch.executable_path);
        assert_eq!(identity.executable_sha256, fake.tool.sha256());
        assert_eq!(identity.endpoint, endpoint);
        let spelled = endpoint.to_string();
        assert_eq!(
            launch.arguments,
            ["-s", spelled.as_str(), "-m"].map(std::ffi::OsString::from)
        );
        server.revalidate().unwrap();
        assert!(!server.exited());
        let stopped = server.stop().unwrap();
        // Terminated by its owner: the whole Job at once, exit code 1.
        assert_eq!(stopped.exit, ServerExit::Exited(1));
        assert!(stopped.stdout.is_empty());
        // The listener went with the process: nothing answers any more.
        assert!(!reachable(endpoint));
        let calls = fake.calls();
        assert_eq!(calls[0], format!("-s {spelled} -m"));
        assert!(
            calls[1..]
                .iter()
                .all(|call| *call == format!("-s {spelled} checkserver"))
        );
    }

    fn a_server_that_ends_before_it_listens_reports_its_exit() {
        let fake = FakeHdc::new("hdc-early");
        let endpoint = free_endpoint();
        let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(10)))
            .err()
            .expect("a server that ends is not ready");
        let StartFailure::Exited(reason) = error else {
            panic!("expected the exit, got {error:?}");
        };
        assert_eq!(reason, "foreground HDC server exited with status 3");
    }

    fn a_server_whose_versions_disagree_is_never_ready_and_is_stopped() {
        let fake = FakeHdc::new("hdc-mismatch");
        let endpoint = free_endpoint();
        let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(3)))
            .err()
            .expect("disagreeing versions are not ready");
        let StartFailure::NotReady(reason) = error else {
            panic!("expected the deadline, got {error:?}");
        };
        assert!(
            reason.starts_with("checkserver exit=0 stdoutBytes="),
            "{reason}"
        );
        // The failed launch was dropped, and its Job terminated with it: its
        // listener goes away.
        assert!(unreachable_within(endpoint, Duration::from_secs(5)));
    }

    fn an_occupied_endpoint_launches_nothing() {
        let fake = FakeHdc::new("hdc");
        let holder = TcpListener::bind(free_endpoint()).unwrap();
        let SocketAddr::V4(endpoint) = holder.local_addr().unwrap() else {
            unreachable!("an IPv4 listener");
        };
        let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(5)))
            .err()
            .expect("an occupied endpoint is refused");
        let StartFailure::Occupied(reason) = error else {
            panic!("expected the occupant, got {error:?}");
        };
        assert_eq!(
            reason,
            "managed HDC endpoint was not absent before the foreground launch: a listener \
             that is not the configured HDC executable holds it"
        );
        assert!(fake.calls().is_empty(), "{:?}", fake.calls());
    }

    /// TASK-XPA-014's replacement lifetime (#2131) on Windows: a confirmed
    /// restart leaves a replacement server that no Job of this process holds.
    /// While it listens, a start launches nothing and names it by PID, never
    /// adopting or stopping it. Once the daemon's stop ends the proved
    /// replacement (`end_proved_process` over the commandless proof), the
    /// next start owns the endpoint.
    fn a_proved_replacement_is_ended_and_the_endpoint_serves_the_next_start() {
        let fake = FakeHdc::new("hdc");
        let endpoint = free_endpoint();
        let spelled = endpoint.to_string();
        let mut replacement = std::process::Command::new(fake.tool.path())
            .args(["-s", spelled.as_str(), "-m"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(20);
        let lease = loop {
            match LoopbackServerLease::acquire(&fake.tool, endpoint) {
                Ok(lease) => break lease,
                Err(_) => {
                    assert!(Instant::now() < deadline, "the replacement never listened");
                    assert!(replacement.try_wait().unwrap().is_none());
                    std::thread::yield_now();
                }
            }
        };
        assert_eq!(lease.identity().pid as u32, replacement.id());
        let launched = fake.calls().len();

        // While it listens, nothing is launched; the holder is named.
        let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(5)))
            .err()
            .expect("an endpoint the replacement holds is refused");
        let StartFailure::Occupied(reason) = error else {
            panic!("expected the occupant, got {error:?}");
        };
        assert!(
            reason.contains(&format!(
                "a server of the configured HDC executable that this launch did not start \
                 listens there (pid {}",
                replacement.id()
            )),
            "{reason}"
        );
        assert_eq!(fake.calls().len(), launched, "{:?}", fake.calls());
        assert!(replacement.try_wait().unwrap().is_none());

        // The stop ends the proved replacement, and its listener with it.
        lease.revalidate().unwrap();
        assert_eq!(
            end_proved_process(
                lease.identity(),
                Duration::from_millis(250),
                Duration::from_secs(5)
            )
            .unwrap(),
            ProvedProcessEnd::Killed
        );
        assert!(replacement.try_wait().unwrap().is_some());
        assert!(!reachable(endpoint));
        drop(lease);

        // The next start owns the endpoint.
        let server =
            ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(15))).unwrap();
        assert_eq!(server.endpoint(), endpoint);
        assert_ne!(server.identity().pid as u32, replacement.id());
        server.stop().unwrap();
        let _ = replacement.wait();
    }

    /// A listener that appears only after the launch — once the fake has run
    /// as a server that never binds — answers the endpoint, but it is not the
    /// launched process: the launch is never bound to it.
    fn a_listener_of_another_process_never_binds_the_launch() {
        let fake = FakeHdc::new("hdc-nobind");
        let endpoint = free_endpoint();
        let calls = fake.directory.join("calls");
        let foreign = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !fs::read_to_string(&calls)
                .unwrap_or_default()
                .lines()
                .any(|line| line.ends_with(" -m"))
            {
                assert!(Instant::now() < deadline, "the server never launched");
                std::thread::yield_now();
            }
            TcpListener::bind(endpoint).unwrap()
        });
        let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(15)))
            .err()
            .expect("a foreign listener never binds the launch");
        let listener = foreign.join().unwrap();
        let StartFailure::Unbound(reason) = error else {
            panic!("expected the unbound launch, got {error:?}");
        };
        assert_eq!(
            reason,
            "managed HDC launch could not be bound to its live process identity"
        );
        drop(listener);
    }

    fn a_dispatch_runs_the_plan_argv_with_the_server_port_and_grants_no_mutation() {
        let fake = FakeHdc::new("hdc");
        let tool = {
            let digest = fake.tool.sha256().to_owned();
            VerifiedTool::open(fake.tool.path(), &digest).unwrap()
        };
        let dispatch = ProcessDispatch::new(tool, Some("8711"));
        // No launch identity is published on Windows yet: a mutation is
        // never granted, whatever the plan.
        assert!(!dispatch.mutation_identity_current());
        let plan = ProcessPlan {
            arguments: ["-s", "127.0.0.1:8711", "echo", "a b", "&|$x", ""]
                .map(str::to_owned)
                .to_vec(),
            timeout: Duration::from_secs(30),
            capture_bytes: 4096,
        };
        let receipt = dispatch.dispatch(&plan).unwrap();
        assert_eq!(receipt.exit_status, 0);
        assert_eq!(receipt.stdout, b"port=8711 args=a b|&|$x|\n");
        assert!(receipt.stderr.is_empty());
        assert!(!receipt.truncated);
        let unregistered = ProcessPlan {
            arguments: ["-s", "127.0.0.1:8711", "kill"].map(str::to_owned).to_vec(),
            timeout: Duration::from_secs(30),
            capture_bytes: 4096,
        };
        assert_eq!(dispatch.dispatch(&unregistered).unwrap().exit_status, 64);
        // An inherited port that is not one is dropped, never forwarded.
        let fallback = {
            let digest = fake.tool.sha256().to_owned();
            ProcessDispatch::new(
                VerifiedTool::open(fake.tool.path(), &digest).unwrap(),
                Some("0"),
            )
        };
        assert!(fallback.environment().is_empty());
        assert_eq!(
            fallback.dispatch(&plan).unwrap().stdout,
            b"port= args=a b|&|$x|\n"
        );
    }

    /// XPA-AC-2 on Windows: the fake process face receives the real argv of a
    /// lowered device plan, verbatim and without a shell, its target named by
    /// `-t <connectKey>` first (`device_arguments`, the single injection
    /// point), and the answer reaches the plan's judge.
    fn a_device_plan_reaches_the_child_with_its_connect_key_first() {
        const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let fake = FakeHdc::new("hdc");
        let tool = {
            let digest = fake.tool.sha256().to_owned();
            VerifiedTool::open(fake.tool.path(), &digest).unwrap()
        };
        let dispatch = ProcessDispatch::new(tool, Some("8711"));
        let action = Action::QueryProperty(Property::ProductName);
        let plan = action.lower("probe", Some(KEY)).unwrap();
        assert_eq!(
            plan.arguments,
            ["-t", KEY, "shell", "param", "get", "const.product.name"]
        );
        let receipt = dispatch.dispatch(&plan).unwrap();
        assert_eq!(receipt.exit_status, 0);
        assert_eq!(receipt.stdout, b"OpenHarmony Reference Device\n");
        assert_eq!(
            fake.calls(),
            [format!("-t|{KEY}|shell|param|get|const.product.name")]
        );
        // Without a connect key there is no device plan, and nothing runs.
        assert!(action.lower("probe", None).is_err());
        assert!(action.lower("probe", Some("")).is_err());
        assert_eq!(fake.calls().len(), 1);
    }
}
