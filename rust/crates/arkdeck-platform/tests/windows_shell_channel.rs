//! The persistent device shell channel on Windows (TASK-XPA-016): the
//! `DeviceShellChannel` the macOS tests drive with `/bin/sh` on a
//! pseudo-terminal (`shell_channel.rs`), here driven on a pseudo console
//! against a fake `hdc shell`: framed answers with the command's own status,
//! bare tokens only, budget and overflow, timeout and client death as
//! unknown outcomes, and the client's whole tree taken down with the
//! channel.
//!
//! The fake `hdc` is this binary itself, a `harness = false` target: run as
//! `<exe> -t <connectKey> shell` it is the fake, otherwise the test runner.
//! Like `hdc shell` it refuses a standard input that is not a console ("Not
//! support stdio TTY mode"), and it answers only the exact argv a
//! device-scoped dispatch carries. Its shell is a line reader for the few
//! commands the tests name; the console's own echo stands in for the
//! device's. Synchronisation is the console's rendering and the channel's
//! own frames; no sleep orders anything. No real HDC or device is involved.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-t") {
        windows::fake_hdc(&arguments[1..]);
    }
    if arguments.get(1).is_some_and(|flag| flag == "--park") {
        loop {
            std::thread::park();
        }
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod windows {
    use arkdeck_platform::{
        DeviceShellChannel, DeviceShellChannelError, ToolLimits, ToolRequest, ToolTermination,
        VerifiedTool, random_bytes,
    };
    use sha2::{Digest, Sha256};
    use std::ffi::OsString;
    use std::fs;
    use std::io::{BufRead, Write};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
    use windows_sys::Win32::System::Console::{GetConsoleMode, GetStdHandle, STD_INPUT_HANDLE};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
    };

    const CONNECT_KEY: &str = "FAKE0123456789";
    /// Where `spawn-park` names the grandchild it started.
    const REPORT: &str = "ARKDECK_FAKE_HDC_REPORT";
    const UNREGISTERED: i32 = 64;

    // ---- the fake hdc ---------------------------------------------------

    fn out(text: &str) {
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(text.as_bytes()).unwrap();
        stdout.flush().unwrap();
    }

    /// `-t <connectKey> shell` on a console: a prompt, then one line at a
    /// time until the input ends or `exit` is run.
    pub fn fake_hdc(arguments: &[String]) -> ! {
        if arguments != ["-t", CONNECT_KEY, "shell"] {
            eprintln!("unregistered invocation");
            std::process::exit(UNREGISTERED);
        }
        // SAFETY: the standard input handle is borrowed, never closed.
        let input = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        let mut mode = 0;
        // SAFETY: fails for anything that is not a console input buffer.
        if unsafe { GetConsoleMode(input, &mut mode) } == 0 {
            out("[Fail]Not support stdio TTY mode\n");
            std::process::exit(1);
        }
        let mut status = 0;
        loop {
            out("$ ");
            let mut line = String::new();
            if std::io::stdin().lock().read_line(&mut line).unwrap() == 0 {
                std::process::exit(0);
            }
            for command in line.trim_end_matches(['\r', '\n']).split(';') {
                let words: Vec<&str> = command.split_whitespace().collect();
                if !words.is_empty() {
                    status = run(&words, status);
                }
            }
        }
    }

    /// One command of the fake shell; its status.
    fn run(words: &[&str], last: i32) -> i32 {
        match words {
            ["echo", rest @ ..] => {
                let text: Vec<String> = rest
                    .iter()
                    .map(|word| word.replace("$?", &last.to_string()))
                    .collect();
                out(&format!("{}\n", text.join(" ")));
                0
            }
            ["printf", text] => {
                out(text);
                0
            }
            ["true"] => 0,
            ["false"] => 1,
            ["seq", first, last] => {
                let (first, last): (u32, u32) = (first.parse().unwrap(), last.parse().unwrap());
                let lines: String = (first..=last).map(|value| format!("{value}\n")).collect();
                out(&lines);
                0
            }
            ["sleep", seconds] => {
                std::thread::sleep(Duration::from_secs(seconds.parse().unwrap()));
                0
            }
            ["yes"] => {
                let block = "y\n".repeat(4096);
                loop {
                    out(&block);
                }
            }
            ["exit", code] => std::process::exit(code.parse().unwrap()),
            ["spawn-park"] => {
                let report = PathBuf::from(std::env::var_os(REPORT).unwrap());
                let grandchild = std::process::Command::new(std::env::current_exe().unwrap())
                    .arg("--park")
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .unwrap();
                let partial = report.with_extension("partial");
                fs::write(&partial, grandchild.id().to_string()).unwrap();
                fs::rename(&partial, &report).unwrap();
                // Never waited for: the channel's Job ends it.
                std::mem::forget(grandchild);
                0
            }
            [name, ..] => {
                out(&format!("sh: {name}: not found\n"));
                127
            }
            [] => last,
        }
    }

    // ---- the runner -----------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "a_framed_command_answers_with_the_devices_own_status_and_nothing_else",
            a_framed_command_answers_with_the_devices_own_status_and_nothing_else,
        ),
        (
            "an_answer_over_budget_is_trimmed_and_marked_but_the_channel_stays_open",
            an_answer_over_budget_is_trimmed_and_marked_but_the_channel_stays_open,
        ),
        (
            "a_command_that_never_frames_its_answer_is_an_unknown_outcome_and_closes_the_channel",
            a_command_that_never_frames_its_answer_is_an_unknown_outcome_and_closes_the_channel,
        ),
        (
            "a_flood_is_an_unknown_outcome_and_closes_the_channel",
            a_flood_is_an_unknown_outcome_and_closes_the_channel,
        ),
        (
            "a_client_that_exits_leaves_the_channel_unavailable",
            a_client_that_exits_leaves_the_channel_unavailable,
        ),
        ("only_bare_tokens_are_carried", only_bare_tokens_are_carried),
        (
            "the_client_needs_a_console_and_the_exact_device_argv",
            the_client_needs_a_console_and_the_exact_device_argv,
        ),
        (
            "closing_the_channel_ends_the_clients_whole_tree",
            closing_the_channel_ends_the_clients_whole_tree,
        ),
    ];

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

    /// This binary as the verified `hdc`.
    fn fake() -> VerifiedTool {
        let path = std::env::current_exe().unwrap().canonicalize().unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
        VerifiedTool::open(&path, &digest).unwrap()
    }

    fn device_argv() -> Vec<OsString> {
        ["-t", CONNECT_KEY, "shell"].map(OsString::from).to_vec()
    }

    fn open() -> DeviceShellChannel {
        DeviceShellChannel::open(&fake(), &device_argv(), &[], Duration::from_secs(20)).unwrap()
    }

    /// A scratch directory, canonical as verified paths are.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arkdeck-xpa016-shell-{name}-{:032x}",
                u128::from_le_bytes(random_bytes().unwrap())
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn open_process(pid: u32) -> OwnedHandle {
        // SAFETY: query and synchronize access only; the handle is owned at once.
        let handle = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                0,
                pid,
            )
        };
        assert!(!handle.is_null(), "the grandchild could not be opened");
        // SAFETY: a new process handle owned from here on.
        unsafe { OwnedHandle::from_raw_handle(handle) }
    }

    fn ended_within(process: &OwnedHandle, within: Duration) -> bool {
        // SAFETY: a live owned process handle with SYNCHRONIZE access.
        let wait =
            unsafe { WaitForSingleObject(process.as_raw_handle(), within.as_millis() as u32) };
        assert!(wait == WAIT_OBJECT_0 || wait == WAIT_TIMEOUT);
        wait == WAIT_OBJECT_0
    }

    fn unknown(error: &DeviceShellChannelError, reason: &str) -> bool {
        matches!(error, DeviceShellChannelError::OutcomeUnknown(text) if text.contains(reason))
    }

    // ---- the tests ------------------------------------------------------

    fn a_framed_command_answers_with_the_devices_own_status_and_nothing_else() {
        let mut channel = open();
        let answer = channel
            .run(&["printf", "hello"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(answer.stdout, b"hello");
        assert_eq!(answer.device_exit_status, 0);
        assert!(!answer.truncated);
        let failed = channel
            .run(&["false"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(failed.stdout, b"");
        assert_eq!(failed.device_exit_status, 1);
        let missing = channel
            .run(&["no-such-command"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(missing.stdout, b"sh: no-such-command: not found\r\n");
        assert_eq!(missing.device_exit_status, 127);
        let refused = channel
            .run(&["printf", "a;b"], Duration::from_secs(10), 4096)
            .unwrap_err();
        // `;` is not a bare token; the channel refuses rather than quoting.
        assert!(matches!(refused, DeviceShellChannelError::Unavailable(_)));
        let again = channel
            .run(&["printf", "second"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(again.stdout, b"second");
    }

    fn an_answer_over_budget_is_trimmed_and_marked_but_the_channel_stays_open() {
        let mut channel = open();
        let whole = channel
            .run(&["seq", "1", "200"], Duration::from_secs(10), 4096)
            .unwrap();
        // The console's rendering: every line, each ending in CRLF.
        let expected: String = (1..=200).map(|value| format!("{value}\r\n")).collect();
        assert_eq!(String::from_utf8(whole.stdout).unwrap(), expected);
        let answer = channel
            .run(&["seq", "1", "200"], Duration::from_secs(10), 16)
            .unwrap();
        assert_eq!(answer.stdout.len(), 16);
        assert!(answer.truncated);
        assert_eq!(answer.device_exit_status, 0);
        let next = channel
            .run(&["printf", "ok"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(next.stdout, b"ok");
    }

    fn a_command_that_never_frames_its_answer_is_an_unknown_outcome_and_closes_the_channel() {
        let mut channel = open();
        let started = Instant::now();
        let error = channel
            .run(&["sleep", "30"], Duration::from_secs(1), 4096)
            .unwrap_err();
        assert!(unknown(&error, "timeout"), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(10));
        assert!(!channel.is_alive());
        let closed = channel
            .run(&["true"], Duration::from_secs(1), 4096)
            .unwrap_err();
        assert!(matches!(closed, DeviceShellChannelError::Unavailable(_)));
    }

    /// macOS reads a flood to its overflow bound. A pseudo console renders
    /// a screen per frame rather than every byte written, so what reaches
    /// the channel is bounded by the console itself and the flood ends at
    /// the timeout instead; either way the outcome is unknown and the
    /// channel is closed.
    fn a_flood_is_an_unknown_outcome_and_closes_the_channel() {
        let mut channel = open();
        let started = Instant::now();
        let error = channel
            .run(&["yes"], Duration::from_secs(5), 1024)
            .unwrap_err();
        assert!(
            unknown(&error, "past every bound") || unknown(&error, "timeout"),
            "{error:?}"
        );
        assert!(started.elapsed() < Duration::from_secs(15));
        assert!(!channel.is_alive());
    }

    fn a_client_that_exits_leaves_the_channel_unavailable() {
        let mut channel = open();
        let error = channel
            .run(&["exit", "3"], Duration::from_secs(5), 4096)
            .unwrap_err();
        assert!(
            matches!(error, DeviceShellChannelError::OutcomeUnknown(_)),
            "{error:?}"
        );
        assert!(!channel.is_alive());
    }

    fn only_bare_tokens_are_carried() {
        let mut channel = open();
        for command in [
            vec!["printf", "a b"],
            vec!["true;", "false"],
            vec![],
            vec!["$HOME"],
            vec!["printf", "a\\b"],
        ] {
            let error = channel
                .run(&command, Duration::from_secs(5), 4096)
                .unwrap_err();
            assert!(
                matches!(error, DeviceShellChannelError::Unavailable(_)),
                "{command:?}"
            );
        }
        assert!(channel.is_alive());
    }

    fn the_client_needs_a_console_and_the_exact_device_argv() {
        // On pipes, the fake refuses as `hdc shell` does: the reason the
        // channel rides a pseudo console.
        let arguments = device_argv();
        let execution = fake()
            .run_tool(
                &ToolRequest {
                    arguments: &arguments,
                    environment: &[],
                    working_directory: None,
                    limits: ToolLimits {
                        timeout: Duration::from_secs(20),
                        capture_bytes: 4096,
                    },
                },
                &|| false,
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(1));
        assert_eq!(execution.stdout, b"[Fail]Not support stdio TTY mode\n");
        // Without its `-t <connectKey>` the client refuses and exits, and
        // the channel never opens: nothing was written to a device.
        let refused = DeviceShellChannel::open(
            &fake(),
            &[OsString::from("shell")],
            &[],
            Duration::from_secs(20),
        )
        .err()
        .unwrap();
        assert!(
            matches!(&refused, DeviceShellChannelError::Unavailable(_)),
            "{refused:?}"
        );
    }

    fn closing_the_channel_ends_the_clients_whole_tree() {
        let scratch = Scratch::new("tree");
        let report = scratch.0.join("grandchild");
        let mut channel = DeviceShellChannel::open(
            &fake(),
            &device_argv(),
            &[(OsString::from(REPORT), report.clone().into_os_string())],
            Duration::from_secs(20),
        )
        .unwrap();
        let answer = channel
            .run(&["spawn-park"], Duration::from_secs(10), 4096)
            .unwrap();
        assert_eq!(answer.device_exit_status, 0);
        let pid: u32 = read_report(&report).parse().unwrap();
        let grandchild = open_process(pid);
        assert!(!ended_within(&grandchild, Duration::ZERO));
        drop(channel);
        assert!(ended_within(&grandchild, Duration::from_secs(5)));
    }

    /// The report exists once the framed command has answered.
    fn read_report(report: &Path) -> String {
        fs::read_to_string(report).unwrap()
    }
}
