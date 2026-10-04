//! The Windows verified-tool runner, managed server and server identity proof
//! (TASK-XPA-005, gate inventory group 5): an argv array through
//! `CreateProcessW` (no shell), the clean environment with its named overlay,
//! a child-only working directory, `NUL` as stdin, per-stream capture with
//! drain, the deadline and the cancellation that terminate the whole Job
//! object (a live child tree included), and the commandless proof that one
//! process of the verified file owns the exact loopback listener, with each
//! of its refusals; and the paired server (TASK-XPA-010), handed its secret
//! on stdin and ended by its end of input before its Job.
//!
//! The fake tool is this binary itself. It is a `harness = false` target, so
//! that when it runs as `<exe> --fake-tool <role> …` nothing but the role's
//! own bytes reach its streams; run without that flag it is the test runner.
//! No HDC is launched, and no process this test did not start is signalled.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if arguments.get(1).is_some_and(|flag| flag == "--fake-tool") {
        windows::fake_tool(&arguments[2..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}

#[cfg(windows)]
mod windows {
    use super::loopback_ports::free_port;
    use arkdeck_platform::{
        LoopbackServerLease, ManagedServer, ProvedProcessEnd, ServerExit, ServerIdentityReceipt,
        ToolExecution, ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedTool,
        end_proved_process, random_bytes,
    };
    use sha2::{Digest, Sha256};
    use std::cell::{Cell, RefCell};
    use std::ffi::OsString;
    use std::fs;
    use std::io::{ErrorKind, Read, Write};
    use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{
        CloseHandle, HANDLE, HANDLE_FLAG_INHERIT, SetHandleInformation, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::System::Console::{
        GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
        TerminateProcess, WaitForSingleObject,
    };

    // ---- the fake tool --------------------------------------------------

    /// One role of the fake tool; never returns.
    pub fn fake_tool(arguments: &[OsString]) -> ! {
        let role = arguments
            .first()
            .and_then(|role| role.to_str())
            .unwrap_or("");
        let rest = &arguments[arguments.len().min(1)..];
        let mut stdout = std::io::stdout().lock();
        match role {
            // Each argument on a line of its own, exactly as received.
            "echo" => {
                for argument in rest {
                    writeln!(stdout, "{}", argument.to_str().unwrap()).unwrap();
                }
            }
            // Every environment variable, one `name=value` line each.
            "environment" => {
                let mut rows: Vec<String> = std::env::vars_os()
                    .map(|(key, value)| {
                        format!("{}={}", key.to_str().unwrap(), value.to_str().unwrap())
                    })
                    .collect();
                rows.sort();
                for row in rows {
                    writeln!(stdout, "{row}").unwrap();
                }
            }
            "cwd" => {
                write!(stdout, "{}", std::env::current_dir().unwrap().display()).unwrap();
            }
            // How many bytes stdin had to give.
            "stdin" => {
                let mut bytes = Vec::new();
                std::io::stdin().read_to_end(&mut bytes).unwrap();
                write!(stdout, "{}", bytes.len()).unwrap();
            }
            "exit" => {
                std::process::exit(rest[0].to_str().unwrap().parse().unwrap());
            }
            // N bytes of `o` to stdout and N of `e` to stderr.
            "flood" => {
                let count: usize = rest[0].to_str().unwrap().parse().unwrap();
                stdout.write_all(&vec![b'o'; count]).unwrap();
                stdout.flush().unwrap();
                std::io::stderr().write_all(&vec![b'e'; count]).unwrap();
            }
            // Writes a first line, then never ends on its own.
            "hang" => {
                writeln!(stdout, "started").unwrap();
                stdout.flush().unwrap();
                park();
            }
            // Starts a grandchild that never ends, names it in `<report>`
            // (written whole, then renamed), and never ends itself.
            "tree" => {
                let report = PathBuf::from(&rest[0]);
                let mut grandchild = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--fake-tool", "hang"])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .unwrap();
                let partial = report.with_extension("partial");
                fs::write(&partial, grandchild.id().to_string()).unwrap();
                fs::rename(&partial, &report).unwrap();
                // The grandchild never ends on its own: this waits until
                // the Job ends them both.
                let _ = grandchild.wait();
                park();
            }
            // `spawn-exit <report> <go> [keep]`: starts a grandchild that never
            // ends, names it in `<report>` (written whole, then renamed),
            // and exits 0 once `<go>` exists: what an HDC lifecycle client
            // that starts a server does.
            "spawn-exit" => {
                let report = PathBuf::from(&rest[0]);
                let go = PathBuf::from(&rest[1]);
                // Unless `keep` follows, the grandchild inherits none of this
                // child's standard handles, as a careful launcher does; with
                // it, the grandchild holds this child's pipes open.
                if rest.get(2).and_then(|flag| flag.to_str()) != Some("keep") {
                    for handle in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE, STD_INPUT_HANDLE] {
                        // SAFETY: this process's own standard handle; only its
                        // inheritance flag changes.
                        unsafe {
                            SetHandleInformation(GetStdHandle(handle), HANDLE_FLAG_INHERIT, 0)
                        };
                    }
                }
                let grandchild = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--fake-tool", "hang"])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .unwrap();
                let partial = report.with_extension("partial");
                fs::write(&partial, grandchild.id().to_string()).unwrap();
                fs::rename(&partial, &report).unwrap();
                let deadline = Instant::now() + Duration::from_secs(30);
                while !go.exists() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(5));
                }
                std::process::exit(0);
            }
            // `listen <ready> <address>… [-s <endpoint> -m]`: holds one TCP
            // listener on each address until killed, and names itself
            // listening in `<ready>` (written whole, then renamed). What
            // follows `-s` only declares an endpoint, as HDC's argv does.
            "listen" => {
                let ready = PathBuf::from(&rest[0]);
                let listeners: Vec<TcpListener> = rest[1..]
                    .iter()
                    .take_while(|argument| *argument != "-s")
                    .map(|address| {
                        let address: SocketAddr = address.to_str().unwrap().parse().unwrap();
                        TcpListener::bind(address).unwrap()
                    })
                    .collect();
                writeln!(stdout, "listening {}", listeners.len()).unwrap();
                stdout.flush().unwrap();
                let partial = ready.with_extension("partial");
                fs::write(&partial, b"listening").unwrap();
                fs::rename(&partial, &ready).unwrap();
                park();
            }
            // `paired <mode>`: the working directory as `cwd`, the first 32
            // bytes of stdin as `secret`, then — `ends-at-eof` — the rest as
            // `rest` and exit 11 at the end of input; or — `outlasts-eof` —
            // `eof` at the end of input, and never an end of its own.
            "paired" => {
                let mut secret = [0u8; 32];
                std::io::stdin().read_exact(&mut secret).unwrap();
                fs::write("cwd", std::env::current_dir().unwrap().to_str().unwrap()).unwrap();
                fs::write("secret.partial", secret).unwrap();
                fs::rename("secret.partial", "secret").unwrap();
                let mut input = Vec::new();
                let _ = std::io::stdin().read_to_end(&mut input);
                if rest[0] == "ends-at-eof" {
                    fs::write("rest", input).unwrap();
                    std::process::exit(11);
                }
                fs::write("eof", input).unwrap();
                park();
            }
            _ => std::process::exit(64),
        }
        stdout.flush().unwrap();
        std::process::exit(0);
    }

    fn park() -> ! {
        loop {
            std::thread::park();
        }
    }

    // ---- the runner -----------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "argv_reaches_the_child_verbatim_without_a_shell_and_stdin_is_nul",
            argv_reaches_the_child_verbatim_without_a_shell_and_stdin_is_nul,
        ),
        (
            "a_named_environment_is_overlaid_on_the_clean_base_and_nothing_else_is_inherited",
            a_named_environment_is_overlaid_on_the_clean_base_and_nothing_else_is_inherited,
        ),
        (
            "the_base_the_compatibility_layer_and_malformed_entries_are_refused_before_any_spawn",
            the_base_the_compatibility_layer_and_malformed_entries_are_refused_before_any_spawn,
        ),
        (
            "the_working_directory_binds_the_child_only_and_must_exist_canonically",
            the_working_directory_binds_the_child_only_and_must_exist_canonically,
        ),
        (
            "each_stream_keeps_its_first_bytes_while_the_rest_drains",
            each_stream_keeps_its_first_bytes_while_the_rest_drains,
        ),
        (
            "a_deadline_terminates_the_job_and_keeps_partial_output",
            a_deadline_terminates_the_job_and_keeps_partial_output,
        ),
        (
            "a_deadline_terminates_a_live_child_tree",
            a_deadline_terminates_a_live_child_tree,
        ),
        (
            "a_cancellation_before_the_spawn_leaves_no_child_and_one_during_the_run_drains_the_tree",
            a_cancellation_before_the_spawn_leaves_no_child_and_one_during_the_run_drains_the_tree,
        ),
        (
            "an_ordinary_run_ends_what_its_child_started_even_after_a_clean_exit",
            an_ordinary_run_ends_what_its_child_started_even_after_a_clean_exit,
        ),
        (
            "only_a_lifecycle_run_lets_what_its_child_started_outlive_it",
            only_a_lifecycle_run_lets_what_its_child_started_outlive_it,
        ),
        (
            "a_lifecycle_run_is_not_held_by_the_pipes_a_survivor_kept",
            a_lifecycle_run_is_not_held_by_the_pipes_a_survivor_kept,
        ),
        (
            "a_nonzero_exit_is_reported_as_such",
            a_nonzero_exit_is_reported_as_such,
        ),
        (
            "the_budget_is_bounded_before_any_spawn",
            the_budget_is_bounded_before_any_spawn,
        ),
        (
            "a_launched_server_is_recorded_kept_and_stopped_with_its_output",
            a_launched_server_is_recorded_kept_and_stopped_with_its_output,
        ),
        (
            "a_server_that_ends_on_its_own_reports_its_exit",
            a_server_that_ends_on_its_own_reports_its_exit,
        ),
        (
            "a_refused_environment_or_capture_launches_nothing",
            a_refused_environment_or_capture_launches_nothing,
        ),
        (
            "a_dropped_server_takes_its_child_tree_with_it",
            a_dropped_server_takes_its_child_tree_with_it,
        ),
        (
            "a_proved_server_outside_the_job_is_ended_and_no_other_birth_ever_is",
            a_proved_server_outside_the_job_is_ended_and_no_other_birth_ever_is,
        ),
        (
            "the_listener_owner_is_proved_by_image_birth_and_exact_listener_without_argv",
            the_listener_owner_is_proved_by_image_birth_and_exact_listener_without_argv,
        ),
        (
            "a_receipt_that_differs_in_pid_birth_path_digest_or_endpoint_is_not_the_managed_server",
            a_receipt_that_differs_in_pid_birth_path_digest_or_endpoint_is_not_the_managed_server,
        ),
        (
            "no_listener_is_unavailable_and_a_stopped_server_no_longer_holds",
            no_listener_is_unavailable_and_a_stopped_server_no_longer_holds,
        ),
        (
            "a_listener_owned_by_another_executable_is_not_the_server",
            a_listener_owned_by_another_executable_is_not_the_server,
        ),
        (
            "a_server_whose_file_was_replaced_at_the_verified_path_is_refused",
            a_server_whose_file_was_replaced_at_the_verified_path_is_refused,
        ),
        (
            "a_wildcard_or_second_listener_of_the_verified_executable_is_unknown",
            a_wildcard_or_second_listener_of_the_verified_executable_is_unknown,
        ),
        (
            "the_endpoint_must_be_the_exact_ipv4_loopback",
            the_endpoint_must_be_the_exact_ipv4_loopback,
        ),
        (
            "a_paired_server_reads_its_secret_and_ends_when_its_owner_lets_go",
            a_paired_server_reads_its_secret_and_ends_when_its_owner_lets_go,
        ),
        (
            "a_paired_server_that_outlives_its_input_is_terminated_after_its_grace",
            a_paired_server_that_outlives_its_input_is_terminated_after_its_grace,
        ),
        (
            "a_dropped_paired_server_gets_its_end_of_input_before_its_job_ends",
            a_dropped_paired_server_gets_its_end_of_input_before_its_job_ends,
        ),
        (
            "a_paired_launch_needs_a_canonical_existing_working_directory",
            a_paired_launch_needs_a_canonical_existing_working_directory,
        ),
    ];

    /// A minimal libtest stand-in: runs every test whose name contains one
    /// of the free arguments (all when none is given), one at a time.
    pub fn run_tests(arguments: &[OsString]) -> ! {
        let mut filters = Vec::new();
        let mut list = false;
        let mut skip_value = false;
        for argument in arguments {
            let argument = argument.to_string_lossy();
            if skip_value {
                skip_value = false;
            } else if argument == "--list" {
                list = true;
            } else if matches!(
                argument.as_ref(),
                "--test-threads" | "--skip" | "--format" | "--color" | "-Z"
            ) {
                skip_value = true;
            } else if !argument.starts_with('-') {
                filters.push(argument.into_owned());
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
        let mut failed = Vec::new();
        for (name, test) in &selected {
            let result = std::panic::catch_unwind(test);
            println!(
                "test {name} ... {}",
                if result.is_ok() { "ok" } else { "FAILED" }
            );
            if result.is_err() {
                failed.push(*name);
            }
        }
        println!(
            "\ntest result: {}. {} passed; {} failed",
            if failed.is_empty() { "ok" } else { "FAILED" },
            selected.len() - failed.len(),
            failed.len()
        );
        std::process::exit(i32::from(!failed.is_empty()));
    }

    // ---- helpers --------------------------------------------------------

    /// A scratch directory, canonical (`\\?\` spelled, as verified paths are).
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arkdeck-xpa005-{name}-{:032x}",
                u128::from_le_bytes(random_bytes().unwrap())
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn directory(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            fs::create_dir(&path).unwrap();
            path
        }

        /// A copy of this binary under the scratch directory: another file,
        /// the same bytes.
        fn copy_of_this_binary(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            fs::copy(std::env::current_exe().unwrap(), &path).unwrap();
            path
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn verified(path: &Path) -> VerifiedTool {
        let digest = format!("{:x}", Sha256::digest(fs::read(path).unwrap()));
        VerifiedTool::open(path, &digest).unwrap()
    }

    /// This binary as the verified tool.
    fn this_tool() -> VerifiedTool {
        verified(&std::env::current_exe().unwrap().canonicalize().unwrap())
    }

    fn args(values: &[&str]) -> Vec<OsString> {
        std::iter::once("--fake-tool")
            .chain(values.iter().copied())
            .map(OsString::from)
            .collect()
    }

    fn env(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
        pairs
            .iter()
            .map(|(key, value)| (OsString::from(key), OsString::from(value)))
            .collect()
    }

    fn limits(timeout: Duration, capture_bytes: usize) -> ToolLimits {
        ToolLimits {
            timeout,
            capture_bytes,
        }
    }

    fn run(tool: &VerifiedTool, arguments: &[OsString]) -> ToolExecution {
        tool.run_tool(
            &ToolRequest {
                arguments,
                environment: &[],
                working_directory: None,
                limits: limits(Duration::from_secs(30), 1024 * 1024),
            },
            &|| false,
        )
        .unwrap()
    }

    fn refused(result: Result<ToolExecution, ToolRunError>) -> std::io::Error {
        match result {
            Err(ToolRunError::Refused(error)) => error,
            other => panic!("expected a refusal before any spawn, got {other:?}"),
        }
    }

    /// A process this test observes by a handle it opened while the process
    /// was known to be the one named, so its PID can never name another.
    /// A process handle; one opened `open_to_end` also ends its process when
    /// dropped, so a failed assertion leaves nothing of this test running.
    struct Observed(HANDLE, bool);

    impl Observed {
        fn open(pid: u32) -> Self {
            // SAFETY: query-only access; the handle is owned and closed on drop.
            let handle = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    pid,
                )
            };
            assert!(!handle.is_null(), "process {pid} could not be opened");
            Self(handle, false)
        }

        /// With the right to end it too: a process this test caused and
        /// must not leave running.
        fn open_to_end(pid: u32) -> Self {
            // SAFETY: owned handle, closed on drop.
            let handle = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE | PROCESS_TERMINATE,
                    0,
                    pid,
                )
            };
            assert!(!handle.is_null(), "process {pid} could not be opened");
            Self(handle, true)
        }

        fn end(&self) {
            // SAFETY: live owned handle; ending an ended process is harmless.
            unsafe { TerminateProcess(self.0, 1) };
        }

        fn ended_within(&self, within: Duration) -> bool {
            // SAFETY: live owned process handle with SYNCHRONIZE access.
            let wait = unsafe { WaitForSingleObject(self.0, within.as_millis() as u32) };
            assert!(wait == WAIT_OBJECT_0 || wait == WAIT_TIMEOUT);
            wait == WAIT_OBJECT_0
        }
    }

    impl Drop for Observed {
        fn drop(&mut self) {
            if self.1 {
                self.end();
            }
            // SAFETY: the handle is owned by this value and closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    /// The PID a `tree` child reported for its grandchild, once it has.
    fn reported_pid(report: &Path) -> Option<u32> {
        fs::read_to_string(report).ok()?.parse().ok()
    }

    /// Waits until a `listen` server has named itself listening, while it
    /// is known to be running; never connects to it.
    fn wait_until_listening(server: &mut ManagedServer, ready: &Path) {
        let child = Observed::open(server.launch_record().pid as u32);
        let deadline = Instant::now() + Duration::from_secs(20);
        while !ready.exists() {
            assert!(Instant::now() < deadline, "the server never listened");
            assert!(
                !child.ended_within(Duration::from_millis(10)),
                "the server ended before it listened: {:?}",
                server.exit()
            );
        }
    }

    fn loopback(port: u16) -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
    }

    /// Whether the cases that bind a wildcard (`0.0.0.0`, `[::]`) run. A
    /// program that listens on anything but loopback makes Windows Defender
    /// Firewall ask the interactive user to allow it, once per executable
    /// path, and these listeners run from a fresh scratch copy (and a test
    /// binary under each Cargo target) every time: on a developer's host
    /// every run would raise a new prompt. They run where no one is asked:
    /// a GitHub Actions runner (`GITHUB_ACTIONS=true`, set by the runner for
    /// every step), which is where the Windows workspace lane runs them.
    /// Every loopback case runs everywhere.
    fn wildcard_listeners_allowed() -> bool {
        let allowed = std::env::var_os("GITHUB_ACTIONS").is_some_and(|value| value == "true");
        if !allowed {
            eprintln!(
                "SKIPPED (wildcard listeners only): outside GitHub Actions a wildcard listener \
                 would raise a Windows Defender Firewall prompt; the loopback cases ran"
            );
        }
        allowed
    }

    // ---- the runner's tests ----------------------------------------------

    fn argv_reaches_the_child_verbatim_without_a_shell_and_stdin_is_nul() {
        let tool = this_tool();
        let values = [
            "",
            "two words",
            "quote\"inside",
            "trailing\\",
            "& | < > ^ %PATH% $HOME `x`",
            "\u{00fc}\u{4e2d}",
        ];
        let mut arguments = args(&["echo"]);
        arguments.extend(values.iter().map(OsString::from));
        let execution = run(&tool, &arguments);
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        let expected: String = values.iter().map(|value| format!("{value}\n")).collect();
        assert_eq!(String::from_utf8(execution.stdout).unwrap(), expected);
        assert!(execution.stderr.is_empty());
        assert!(!execution.truncated);
        let stdin = run(&tool, &args(&["stdin"]));
        assert_eq!(stdin.termination, ToolTermination::Exited(0));
        assert_eq!(stdin.stdout, b"0");
    }

    fn a_named_environment_is_overlaid_on_the_clean_base_and_nothing_else_is_inherited() {
        let tool = this_tool();
        let overlay = env(&[("OHOS_HDC_SERVER_PORT", "8711"), ("ARKDECK_ROLE", "a=b c")]);
        let execution = tool
            .run_tool(
                &ToolRequest {
                    arguments: &args(&["environment"]),
                    environment: &overlay,
                    working_directory: None,
                    limits: limits(Duration::from_secs(30), 1024 * 1024),
                },
                &|| false,
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        let windows = std::env::var("SystemRoot").unwrap();
        let mut expected = vec![
            "ARKDECK_ROLE=a=b c".to_owned(),
            "OHOS_HDC_SERVER_PORT=8711".to_owned(),
            format!("PATH={windows}\\System32"),
            format!("SystemRoot={windows}"),
            format!("WINDIR={windows}"),
        ];
        expected.sort();
        let actual: Vec<String> = String::from_utf8(execution.stdout)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect();
        assert_eq!(actual, expected);
    }

    fn the_base_the_compatibility_layer_and_malformed_entries_are_refused_before_any_spawn() {
        let tool = this_tool();
        let report = Scratch::new("refused-env");
        let marker = report.0.join("ran");
        let marker_text = marker.to_str().unwrap().to_owned();
        for overlay in [
            env(&[("PATH", "C:\\evil")]),
            env(&[("path", "C:\\evil")]),
            env(&[("SystemRoot", "C:\\evil")]),
            env(&[("windir", "C:\\evil")]),
            env(&[("__COMPAT_LAYER", "RunAsAdmin")]),
            env(&[("", "value")]),
            env(&[("A=B", "value")]),
            env(&[("KEY", "nul\0inside")]),
            env(&[("TWICE", "1"), ("twice", "2")]),
        ] {
            let error = refused(tool.run_tool(
                &ToolRequest {
                    arguments: &args(&["tree", &marker_text]),
                    environment: &overlay,
                    working_directory: None,
                    limits: limits(Duration::from_secs(30), 1024),
                },
                &|| false,
            ));
            assert_eq!(error.kind(), ErrorKind::InvalidInput, "{overlay:?}");
        }
        assert!(!marker.exists(), "a refused request ran the tool");
    }

    fn the_working_directory_binds_the_child_only_and_must_exist_canonically() {
        let tool = this_tool();
        let scratch = Scratch::new("cwd");
        let directory = scratch.directory("work");
        let before = std::env::current_dir().unwrap();
        let request = |directory: &Path| {
            tool.run_tool(
                &ToolRequest {
                    arguments: &args(&["cwd"]),
                    environment: &[],
                    working_directory: Some(directory),
                    limits: limits(Duration::from_secs(30), 4096),
                },
                &|| false,
            )
        };
        let execution = request(&directory).unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        assert_eq!(
            String::from_utf8(execution.stdout).unwrap(),
            directory.to_str().unwrap()
        );
        assert_eq!(std::env::current_dir().unwrap(), before);
        // The same directory spelled without the canonical `\\?\` prefix, a
        // relative path, a missing directory and a file are all refused.
        let plain = PathBuf::from(directory.to_str().unwrap().trim_start_matches(r"\\?\"));
        assert_ne!(plain, directory);
        fs::write(scratch.0.join("file"), b"").unwrap();
        for unavailable in [
            plain,
            PathBuf::from("work"),
            scratch.0.join("missing"),
            scratch.0.join("file"),
        ] {
            let error = refused(request(&unavailable));
            assert_eq!(error.kind(), ErrorKind::InvalidInput, "{unavailable:?}");
        }
    }

    fn each_stream_keeps_its_first_bytes_while_the_rest_drains() {
        let tool = this_tool();
        let flood = |count: &str, capture: usize| {
            tool.run_tool(
                &ToolRequest {
                    arguments: &args(&["flood", count]),
                    environment: &[],
                    working_directory: None,
                    limits: limits(Duration::from_secs(60), capture),
                },
                &|| false,
            )
            .unwrap()
        };
        // Far past both the capture and the pipe buffers: the child is
        // never blocked on a full pipe, and each stream keeps its own first
        // bytes (the capture is per stream, not combined).
        let over = flood("4194304", 1000);
        assert_eq!(over.termination, ToolTermination::Exited(0));
        assert_eq!(over.stdout, vec![b'o'; 1000]);
        assert_eq!(over.stderr, vec![b'e'; 1000]);
        assert!(over.truncated);
        let exact = flood("1000", 1000);
        assert_eq!(exact.termination, ToolTermination::Exited(0));
        assert_eq!(exact.stdout, vec![b'o'; 1000]);
        assert_eq!(exact.stderr, vec![b'e'; 1000]);
        assert!(!exact.truncated);
    }

    fn a_deadline_terminates_the_job_and_keeps_partial_output() {
        let tool = this_tool();
        let timeout = Duration::from_secs(1);
        let execution = tool
            .run_tool(
                &ToolRequest {
                    arguments: &args(&["hang"]),
                    environment: &[],
                    working_directory: None,
                    limits: limits(timeout, 4096),
                },
                &|| false,
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::TimedOut);
        assert!(execution.duration >= timeout);
        assert_eq!(execution.stdout, b"started\n");
    }

    fn a_deadline_terminates_a_live_child_tree() {
        let tool = this_tool();
        let scratch = Scratch::new("deadline-tree");
        let report = scratch.0.join("grandchild");
        let observed: RefCell<Option<Observed>> = RefCell::new(None);
        let execution = tool
            .run_tool(
                &ToolRequest {
                    arguments: &args(&["tree", report.to_str().unwrap()]),
                    environment: &[],
                    working_directory: None,
                    limits: limits(Duration::from_secs(5), 4096),
                },
                // Never cancels: only opens the grandchild once it is named,
                // while it is known to be alive inside the child's Job.
                &|| {
                    if observed.borrow().is_none()
                        && let Some(pid) = reported_pid(&report)
                    {
                        *observed.borrow_mut() = Some(Observed::open(pid));
                    }
                    false
                },
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::TimedOut);
        let grandchild = observed.into_inner().expect("the grandchild was named");
        // The Job was empty before run_tool returned: already ended.
        assert!(grandchild.ended_within(Duration::ZERO));
    }

    fn a_cancellation_before_the_spawn_leaves_no_child_and_one_during_the_run_drains_the_tree() {
        let tool = this_tool();
        let scratch = Scratch::new("cancel");
        let report = scratch.0.join("grandchild");
        let request = ToolRequest {
            arguments: &args(&["tree", report.to_str().unwrap()]),
            environment: &[],
            working_directory: None,
            limits: limits(Duration::from_secs(60), 4096),
        };
        let early = tool.run_tool(&request, &|| true).unwrap();
        assert_eq!(
            early.termination,
            ToolTermination::Cancelled { drained: true }
        );
        assert_eq!(early.duration, Duration::ZERO);
        assert!(!report.exists(), "a cancellation before the spawn ran it");
        let observed: RefCell<Option<Observed>> = RefCell::new(None);
        let asked = Cell::new(0);
        let execution = tool
            .run_tool(&request, &|| {
                asked.set(asked.get() + 1);
                if observed.borrow().is_none()
                    && let Some(pid) = reported_pid(&report)
                {
                    *observed.borrow_mut() = Some(Observed::open(pid));
                }
                observed.borrow().is_some()
            })
            .unwrap();
        assert_eq!(
            execution.termination,
            ToolTermination::Cancelled { drained: true }
        );
        assert!(asked.get() > 1);
        assert!(execution.duration < Duration::from_secs(60));
        let grandchild = observed.into_inner().unwrap();
        assert!(grandchild.ended_within(Duration::ZERO));
    }

    /// A `spawn-exit` run: the grandchild is opened (with `open`) once it is
    /// named, while the child still waits, and only then is the child let
    /// exit 0.
    fn spawn_exit(
        tool: &VerifiedTool,
        scratch: &Scratch,
        lifecycle: bool,
        keep: bool,
        open: fn(u32) -> Observed,
    ) -> Observed {
        let (report, go) = (scratch.0.join("grandchild"), scratch.0.join("go"));
        let observed: RefCell<Option<Observed>> = RefCell::new(None);
        let mut arguments = args(&["spawn-exit", report.to_str().unwrap(), go.to_str().unwrap()]);
        if keep {
            arguments.push("keep".into());
        }
        let request = ToolRequest {
            arguments: &arguments,
            environment: &[],
            working_directory: None,
            limits: limits(Duration::from_secs(30), 4096),
        };
        let cancelled = || {
            if observed.borrow().is_none()
                && let Some(pid) = reported_pid(&report)
            {
                *observed.borrow_mut() = Some(open(pid));
                fs::write(&go, b"").unwrap();
            }
            false
        };
        let execution = if lifecycle {
            tool.run_lifecycle_tool(&request, &cancelled)
        } else {
            tool.run_tool(&request, &cancelled)
        }
        .unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        observed.into_inner().expect("the grandchild was named")
    }

    /// A process the child started, running when the child exits 0, is ended
    /// with the child's Job before `run_tool` returns: an ordinary tool's
    /// descendants never outlive it.
    fn an_ordinary_run_ends_what_its_child_started_even_after_a_clean_exit() {
        let scratch = Scratch::new("spawnexit");
        let grandchild = spawn_exit(&this_tool(), &scratch, false, false, Observed::open);
        assert!(grandchild.ended_within(Duration::ZERO));
    }

    /// The lifecycle run alone lets the process its child started break away
    /// from the child's Job, as `hdc kill -r`'s replacement server outlives
    /// the client on macOS; the child itself is ended as ever. The test ends
    /// the survivor it caused.
    fn only_a_lifecycle_run_lets_what_its_child_started_outlive_it() {
        let scratch = Scratch::new("detach");
        let survivor = spawn_exit(&this_tool(), &scratch, true, false, Observed::open_to_end);
        let alive = !survivor.ended_within(Duration::from_millis(500));
        survivor.end();
        assert!(survivor.ended_within(Duration::from_secs(10)));
        assert!(
            alive,
            "the process the lifecycle client started was ended with it"
        );
    }

    /// A process the lifecycle client started that holds the client's pipes
    /// does not hold the run: its capture ends with the client, shortly
    /// after it exited, and the client's exit is its outcome.
    fn a_lifecycle_run_is_not_held_by_the_pipes_a_survivor_kept() {
        let scratch = Scratch::new("keep");
        let started = Instant::now();
        let survivor = spawn_exit(&this_tool(), &scratch, true, true, Observed::open_to_end);
        assert!(started.elapsed() < Duration::from_secs(20));
        assert!(!survivor.ended_within(Duration::ZERO));
        survivor.end();
        assert!(survivor.ended_within(Duration::from_secs(10)));
    }

    fn a_nonzero_exit_is_reported_as_such() {
        let tool = this_tool();
        assert_eq!(
            run(&tool, &args(&["exit", "7"])).termination,
            ToolTermination::Exited(7)
        );
        assert_eq!(
            run(&tool, &args(&["unknown-role"])).termination,
            ToolTermination::Exited(64)
        );
    }

    fn the_budget_is_bounded_before_any_spawn() {
        let tool = this_tool();
        for bounds in [
            limits(Duration::ZERO, 1),
            limits(Duration::from_secs(3601), 1),
            limits(Duration::from_secs(1), 0),
            limits(Duration::from_secs(1), 64 * 1024 * 1024 + 1),
        ] {
            let error = refused(tool.run_tool(
                &ToolRequest {
                    arguments: &args(&["hang"]),
                    environment: &[],
                    working_directory: None,
                    limits: bounds,
                },
                &|| false,
            ));
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
        }
    }

    // ---- the paired server ---------------------------------------------------

    /// The secret the paired cases hand over.
    fn secret() -> Vec<u8> {
        (0u8..32).map(|byte| byte.wrapping_mul(7)).collect()
    }

    /// Waits until the paired fake has read its whole secret.
    fn wait_for_secret(server: &mut ManagedServer, run: &Path) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !run.join("secret").exists() {
            assert!(Instant::now() < deadline, "the secret never arrived");
            assert_eq!(server.exit().unwrap(), None, "the server ended unpaired");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Swift `IdentityBoundDaemonLauncher`: the secret arrives on stdin, whole
    /// and nowhere else, in the named working directory; the write end is the
    /// owner's alone, so closing it is the server's end of input. The fake
    /// exits 11 at that end, so its exit proves the owner closed its liveness
    /// before it terminated the Job.
    fn a_paired_server_reads_its_secret_and_ends_when_its_owner_lets_go() {
        let tool = this_tool();
        let scratch = Scratch::new("paired");
        let run = scratch.directory("run");
        let arguments = args(&["paired", "ends-at-eof"]);
        let mut server =
            ManagedServer::launch_paired(&tool, &arguments, &[], &run, &secret(), 4096).unwrap();
        assert_eq!(server.launch_record().arguments, arguments);
        wait_for_secret(&mut server, &run);
        // It keeps running while its owner holds on.
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(server.exit().unwrap(), None);
        assert_eq!(fs::read(run.join("secret")).unwrap(), secret());
        assert_eq!(
            fs::read_to_string(run.join("cwd")).unwrap(),
            run.to_str().unwrap()
        );
        let child = Observed::open(server.launch_record().pid as u32);
        let started = Instant::now();
        let stopped = server.stop().unwrap();
        assert_eq!(stopped.exit, ServerExit::Exited(11));
        assert!(started.elapsed() < Duration::from_millis(500));
        assert!(child.ended_within(Duration::ZERO));
        // Nothing but the secret ever crossed the pipe.
        assert!(fs::read(run.join("rest")).unwrap().is_empty());
    }

    /// Windows has no TERM: a paired server that does not end at its end of
    /// input has half a second to, then its whole Job is terminated.
    fn a_paired_server_that_outlives_its_input_is_terminated_after_its_grace() {
        let tool = this_tool();
        let scratch = Scratch::new("paired-outlasts");
        let run = scratch.directory("run");
        let mut server = ManagedServer::launch_paired(
            &tool,
            &args(&["paired", "outlasts-eof"]),
            &[],
            &run,
            &secret(),
            4096,
        )
        .unwrap();
        wait_for_secret(&mut server, &run);
        let child = Observed::open(server.launch_record().pid as u32);
        let started = Instant::now();
        let stopped = server.stop().unwrap();
        let took = started.elapsed();
        // Terminated by its owner, once its input had ended.
        assert_eq!(stopped.exit, ServerExit::Exited(1));
        assert!(run.join("eof").exists(), "the input never ended");
        assert!(
            took >= Duration::from_millis(500),
            "terminated after {took:?}"
        );
        assert!(child.ended_within(Duration::ZERO));
    }

    /// A paired server its owner drops without its stop is ended as the stop
    /// ends it: its end of input first, so it sees its owner go.
    fn a_dropped_paired_server_gets_its_end_of_input_before_its_job_ends() {
        let tool = this_tool();
        let scratch = Scratch::new("paired-drop");
        let run = scratch.directory("run");
        let mut server = ManagedServer::launch_paired(
            &tool,
            &args(&["paired", "outlasts-eof"]),
            &[],
            &run,
            &secret(),
            4096,
        )
        .unwrap();
        wait_for_secret(&mut server, &run);
        let child = Observed::open(server.launch_record().pid as u32);
        drop(server);
        assert!(run.join("eof").exists(), "dropped before its end of input");
        assert!(child.ended_within(Duration::ZERO));
    }

    /// The working directory is a tool request's: absolute, canonical and
    /// existing; any other launches nothing.
    fn a_paired_launch_needs_a_canonical_existing_working_directory() {
        let tool = this_tool();
        let scratch = Scratch::new("paired-refused");
        let run = scratch.directory("run");
        let arguments = args(&["paired", "ends-at-eof"]);
        for directory in [
            PathBuf::from("run"),
            scratch.0.join("missing"),
            // The same directory, not in its canonical (`\\?\`) spelling.
            PathBuf::from(run.to_str().unwrap().strip_prefix(r"\\?\").unwrap()),
        ] {
            let error =
                ManagedServer::launch_paired(&tool, &arguments, &[], &directory, &secret(), 4096)
                    .err()
                    .expect("refused");
            assert_eq!(error.kind(), ErrorKind::InvalidInput, "{directory:?}");
        }
        assert!(
            !run.join("secret").exists(),
            "a refused launch ran the tool"
        );
    }

    // ---- the managed server ------------------------------------------------

    fn a_launched_server_is_recorded_kept_and_stopped_with_its_output() {
        let tool = this_tool();
        let port = free_port();
        let endpoint = loopback(port);
        let scratch = Scratch::new("launched");
        let ready = scratch.0.join("ready");
        let arguments = args(&["listen", ready.to_str().unwrap(), &endpoint.to_string()]);
        let mut server = ManagedServer::launch(&tool, &arguments, &[], 4096).unwrap();
        let record = server.launch_record().clone();
        assert!(record.pid > 0);
        assert!(record.start_seconds > 1_700_000_000 && record.start_microseconds < 1_000_000);
        assert_eq!(record.executable_path, tool.path());
        assert_eq!(record.executable_sha256, tool.sha256());
        assert_eq!(record.arguments, arguments);
        wait_until_listening(&mut server, &ready);
        assert_eq!(server.exit().unwrap(), None);
        assert!(server.same_birth());
        let child = Observed::open(record.pid as u32);
        let stopped = server.stop().unwrap();
        // Terminated by its owner: the whole Job at once, exit code 1.
        assert_eq!(stopped.exit, ServerExit::Exited(1));
        assert_eq!(stopped.stdout, b"listening 1\n");
        assert!(stopped.stderr.is_empty());
        assert!(!stopped.truncated);
        assert!(child.ended_within(Duration::ZERO));
    }

    fn a_server_that_ends_on_its_own_reports_its_exit() {
        let tool = this_tool();
        let mut server = ManagedServer::launch(&tool, &args(&["exit", "3"]), &[], 4096).unwrap();
        let record = server.launch_record().clone();
        assert!(record.start_seconds > 0 && record.start_microseconds < 1_000_000);
        let child = Observed::open(record.pid as u32);
        assert!(child.ended_within(Duration::from_secs(20)));
        assert_eq!(server.exit().unwrap(), Some(ServerExit::Exited(3)));
        assert_eq!(server.exit().unwrap(), Some(ServerExit::Exited(3)));
        assert_eq!(server.stop().unwrap().exit, ServerExit::Exited(3));
    }

    fn a_refused_environment_or_capture_launches_nothing() {
        let tool = this_tool();
        let scratch = Scratch::new("server-refused");
        let report = scratch.0.join("grandchild");
        let arguments = args(&["tree", report.to_str().unwrap()]);
        for (environment, capture) in [
            (env(&[("PATH", "C:\\evil")]), 4096),
            (env(&[("__compat_layer", "x")]), 4096),
            (Vec::new(), 0),
            (Vec::new(), 64 * 1024 * 1024 + 1),
        ] {
            let error = ManagedServer::launch(&tool, &arguments, &environment, capture)
                .err()
                .expect("refused");
            assert_eq!(error.kind(), ErrorKind::InvalidInput);
        }
        assert!(!report.exists(), "a refused launch ran the tool");
    }

    /// Kill-on-close: a server its owner drops ends with its whole Job,
    /// the grandchild it started included.
    fn a_dropped_server_takes_its_child_tree_with_it() {
        let tool = this_tool();
        let scratch = Scratch::new("drop-tree");
        let report = scratch.0.join("grandchild");
        let server =
            ManagedServer::launch(&tool, &args(&["tree", report.to_str().unwrap()]), &[], 4096)
                .unwrap();
        let child = Observed::open(server.launch_record().pid as u32);
        let deadline = Instant::now() + Duration::from_secs(20);
        let pid = loop {
            if let Some(pid) = reported_pid(&report) {
                break pid;
            }
            assert!(Instant::now() < deadline, "the grandchild was never named");
            assert!(!child.ended_within(Duration::from_millis(10)));
        };
        let grandchild = Observed::open(pid);
        assert!(!grandchild.ended_within(Duration::ZERO));
        drop(server);
        assert!(child.ended_within(Duration::from_secs(5)));
        assert!(grandchild.ended_within(Duration::from_secs(5)));
    }

    // ---- the server identity proof -----------------------------------------

    /// A `listen` server of `tool` on `addresses`, listening by the time it
    /// is returned; `declared` is the endpoint its argv names (`-s <it> -m`).
    fn listening_server(
        tool: &VerifiedTool,
        addresses: &[String],
        declared: Option<SocketAddrV4>,
    ) -> ManagedServer {
        let scratch = Scratch::new("listen");
        let ready = scratch.0.join("ready");
        let mut arguments = args(&["listen", ready.to_str().unwrap()]);
        arguments.extend(addresses.iter().map(OsString::from));
        if let Some(declared) = declared {
            arguments.extend(["-s", &declared.to_string(), "-m"].map(OsString::from));
        }
        let mut server = ManagedServer::launch(tool, &arguments, &[], 4096).unwrap();
        wait_until_listening(&mut server, &ready);
        server
    }

    /// A child the test spawned itself, outside any Job, as `kill -r` leaves
    /// the replacement server; killed on drop if a check failed first.
    struct Detached(std::process::Child);

    impl Drop for Detached {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// The daemon's stop ends the replacement a confirmed restart proved
    /// (TASK-XPA-014 on macOS; `end_proved_process`): a server of the
    /// verified tool that no Job of this process holds, found on the
    /// endpoint by the commandless proof. A receipt of another birth, or of
    /// no PID of its own, ends nothing; the proved one is terminated, its
    /// exit finished and its listener gone, and asking again finds it
    /// already ended.
    fn a_proved_server_outside_the_job_is_ended_and_no_other_birth_ever_is() {
        let tool = this_tool();
        let endpoint = loopback(free_port());
        let scratch = Scratch::new("replacement");
        let ready = scratch.0.join("ready");
        let child = std::process::Command::new(tool.path())
            .args(args(&[
                "listen",
                ready.to_str().unwrap(),
                &endpoint.to_string(),
            ]))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let replacement = Detached(child);
        let observed = Observed::open(replacement.0.id());
        let deadline = Instant::now() + Duration::from_secs(20);
        while !ready.exists() {
            assert!(Instant::now() < deadline, "the replacement never listened");
            assert!(!observed.ended_within(Duration::from_millis(10)));
        }
        let lease = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        let receipt = lease.identity().clone();
        assert_eq!(receipt.pid as u32, replacement.0.id());

        // Another birth at the same PID, or no PID of its own: nothing ends.
        let mut other = receipt.clone();
        other.start_microseconds += 1;
        assert_eq!(
            end_proved_process(&other, Duration::from_millis(250), Duration::from_secs(1)).unwrap(),
            ProvedProcessEnd::AlreadyEnded
        );
        for pid in [0, 4, -1] {
            let mut system = receipt.clone();
            system.pid = pid;
            assert_eq!(
                end_proved_process(&system, Duration::from_millis(250), Duration::from_secs(1))
                    .unwrap_err()
                    .kind(),
                ErrorKind::InvalidInput
            );
        }
        assert!(!observed.ended_within(Duration::ZERO));
        lease.revalidate().unwrap();

        // The proved one is ended, its exit finished: no listener remains.
        assert_eq!(
            end_proved_process(&receipt, Duration::from_millis(250), Duration::from_secs(5))
                .unwrap(),
            ProvedProcessEnd::Killed
        );
        assert!(observed.ended_within(Duration::ZERO));
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        assert_eq!(
            end_proved_process(&receipt, Duration::from_millis(250), Duration::from_secs(1))
                .unwrap(),
            ProvedProcessEnd::AlreadyEnded
        );
        drop(lease);
    }

    fn the_listener_owner_is_proved_by_image_birth_and_exact_listener_without_argv() {
        let tool = this_tool();
        let endpoint = loopback(free_port());
        // The launch declares the endpoint as HDC's foreground server does.
        let server = listening_server(&tool, &[endpoint.to_string()], Some(endpoint));
        let lease = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        let receipt = lease.identity().clone();
        let launch = server.launch_record();
        assert_eq!(
            receipt,
            ServerIdentityReceipt {
                pid: launch.pid,
                start_seconds: launch.start_seconds,
                start_microseconds: launch.start_microseconds,
                executable_path: launch.executable_path.clone(),
                executable_sha256: launch.executable_sha256.clone(),
                endpoint,
            }
        );
        lease.revalidate().unwrap();
        assert!(server.verifies(&receipt));
        assert!(server.same_birth());
        server.stop().unwrap();
        assert_eq!(
            lease.revalidate().unwrap_err().kind(),
            ErrorKind::PermissionDenied
        );
    }

    fn a_receipt_that_differs_in_pid_birth_path_digest_or_endpoint_is_not_the_managed_server() {
        let tool = this_tool();
        let endpoint = loopback(free_port());
        let server = listening_server(&tool, &[endpoint.to_string()], Some(endpoint));
        let receipt = LoopbackServerLease::acquire(&tool, endpoint)
            .unwrap()
            .identity()
            .clone();
        assert!(server.verifies(&receipt));
        let other_port = loopback(free_port());
        for changed in [
            ServerIdentityReceipt {
                pid: receipt.pid + 4,
                ..receipt.clone()
            },
            ServerIdentityReceipt {
                start_seconds: receipt.start_seconds + 1,
                ..receipt.clone()
            },
            ServerIdentityReceipt {
                start_microseconds: (receipt.start_microseconds + 1) % 1_000_000,
                ..receipt.clone()
            },
            ServerIdentityReceipt {
                start_seconds: 0,
                start_microseconds: 0,
                ..receipt.clone()
            },
            ServerIdentityReceipt {
                executable_path: receipt.executable_path.with_file_name("hdc.exe"),
                ..receipt.clone()
            },
            ServerIdentityReceipt {
                executable_sha256: "0".repeat(64),
                ..receipt.clone()
            },
            // Declared by no launch argument and owned by no listener.
            ServerIdentityReceipt {
                endpoint: other_port,
                ..receipt.clone()
            },
        ] {
            assert!(!server.verifies(&changed), "{changed:?}");
        }
        // A server whose launch declares no endpoint is never the managed
        // one, even though it owns the listener.
        let undeclared_endpoint = loopback(free_port());
        let undeclared = listening_server(&tool, &[undeclared_endpoint.to_string()], None);
        let undeclared_receipt = LoopbackServerLease::acquire(&tool, undeclared_endpoint)
            .unwrap()
            .identity()
            .clone();
        assert!(!undeclared.verifies(&undeclared_receipt));
        // Nor is another server's receipt, though every field is its own.
        assert!(!server.verifies(&undeclared_receipt));
        assert!(!undeclared.verifies(&receipt));
        undeclared.stop().unwrap();
        server.stop().unwrap();
    }

    fn no_listener_is_unavailable_and_a_stopped_server_no_longer_holds() {
        let tool = this_tool();
        let endpoint = loopback(free_port());
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        // A server of the tool with no listener at all is no owner either.
        let silent = ManagedServer::launch(&tool, &args(&["hang"]), &[], 4096).unwrap();
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        silent.stop().unwrap();
        let first = listening_server(&tool, &[endpoint.to_string()], None);
        let old = LoopbackServerLease::acquire(&tool, endpoint)
            .unwrap()
            .identity()
            .clone();
        first.stop().unwrap();
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        // A new server on the same endpoint is a new PID and birth.
        let second = listening_server(&tool, &[endpoint.to_string()], None);
        let new = LoopbackServerLease::acquire(&tool, endpoint)
            .unwrap()
            .identity()
            .clone();
        assert_ne!(
            (old.pid, old.start_seconds, old.start_microseconds),
            (new.pid, new.start_seconds, new.start_microseconds)
        );
        assert!(!second.verifies(&old));
        second.stop().unwrap();
    }

    fn a_listener_owned_by_another_executable_is_not_the_server() {
        let tool = this_tool();
        let scratch = Scratch::new("other-image");
        let other = verified(&scratch.copy_of_this_binary("other.exe"));
        let endpoint = loopback(free_port());
        let foreign = listening_server(&other, &[endpoint.to_string()], None);
        // Same bytes, same digest, another file: not a process of the tool.
        assert_eq!(other.sha256(), tool.sha256());
        let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound);
        // A wildcard listener of that other file beside the tool's own exact
        // listener does not disturb the proof of the tool's process (only
        // where no firewall prompt is raised, see
        // `wildcard_listeners_allowed`).
        if wildcard_listeners_allowed() {
            let shared = loopback(free_port());
            let wildcard = listening_server(&other, &[format!("0.0.0.0:{}", shared.port())], None);
            let own = listening_server(&tool, &[shared.to_string()], None);
            let lease = LoopbackServerLease::acquire(&tool, shared).unwrap();
            assert_eq!(lease.identity().pid, own.launch_record().pid);
            own.stop().unwrap();
            wildcard.stop().unwrap();
        }
        foreign.stop().unwrap();
    }

    /// Hash drift: the server runs the file that was at the verified path
    /// when it started; the path now names other bytes, pinned by their own
    /// digest. Windows reports the running image by the path its file has
    /// now (`previous.exe`), so the server is no process of the verified
    /// file: unavailable, as a listener of another executable is.
    fn a_server_whose_file_was_replaced_at_the_verified_path_is_refused() {
        let scratch = Scratch::new("drift");
        let path = scratch.copy_of_this_binary("hdc.exe");
        let endpoint = loopback(free_port());
        let server = {
            let original = verified(&path);
            listening_server(&original, &[endpoint.to_string()], None)
        };
        // A running image cannot be rewritten, but it can be renamed away.
        fs::rename(&path, scratch.0.join("previous.exe")).unwrap();
        let mut drifted = fs::read(scratch.0.join("previous.exe")).unwrap();
        drifted.push(0);
        fs::write(&path, &drifted).unwrap();
        let replaced = verified(&path);
        assert_ne!(replaced.sha256(), server.launch_record().executable_sha256);
        let error = LoopbackServerLease::acquire(&replaced, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound, "{error}");
        // The original bytes, pinned at their new path, are proved again.
        let previous = verified(&scratch.0.join("previous.exe"));
        let lease = LoopbackServerLease::acquire(&previous, endpoint).unwrap();
        assert_eq!(lease.identity().pid, server.launch_record().pid);
        assert!(!server.verifies(lease.identity()));
        server.stop().unwrap();
    }

    fn a_wildcard_or_second_listener_of_the_verified_executable_is_unknown() {
        let tool = this_tool();
        // A second loopback listener runs everywhere; a wildcard only where
        // no firewall prompt is raised (`wildcard_listeners_allowed`).
        let mut cases: Vec<fn(u16) -> Vec<String>> =
            vec![|port| vec![format!("127.0.0.1:{port}"), format!("[::1]:{port}")]];
        let wildcards = wildcard_listeners_allowed();
        if wildcards {
            cases.extend([
                (|port| vec![format!("0.0.0.0:{port}")]) as fn(u16) -> Vec<String>,
                |port| vec![format!("[::]:{port}")],
                |port| vec![format!("127.0.0.1:{port}"), format!("0.0.0.0:{port}")],
            ]);
        }
        for addresses in cases {
            let endpoint = loopback(free_port());
            let addresses = addresses(endpoint.port());
            let server = listening_server(&tool, &addresses, None);
            let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
            assert_eq!(error.kind(), ErrorKind::PermissionDenied, "{addresses:?}");
            server.stop().unwrap();
        }
        if !wildcards {
            return;
        }
        // Two processes of the tool on the endpoint: the second one's
        // wildcard makes the endpoint's owner unknown.
        let endpoint = loopback(free_port());
        let exact = listening_server(&tool, &[endpoint.to_string()], None);
        let wildcard = listening_server(&tool, &[format!("0.0.0.0:{}", endpoint.port())], None);
        let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::PermissionDenied);
        wildcard.stop().unwrap();
        exact.stop().unwrap();
    }

    fn the_endpoint_must_be_the_exact_ipv4_loopback() {
        let tool = this_tool();
        for endpoint in [
            SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 8710),
            SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 2), 8710),
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0),
        ] {
            assert_eq!(
                LoopbackServerLease::acquire(&tool, endpoint)
                    .unwrap_err()
                    .kind(),
                ErrorKind::InvalidInput
            );
        }
    }
}
