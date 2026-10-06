//! The PTY prompt/secret exchange on Windows (TASK-XPA-011, gate inventory
//! G19): `VerifiedTool::run_pty_exchange` attaches the verified tool to a
//! pseudo console, answers each exact prompt it renders with its secret and
//! returns nothing of what was said.
//!
//! The fake signer is this binary itself, attached to the pseudo console the
//! exchange creates. It is a `harness = false` target, so that when it runs
//! as `<exe> --fake-tool <role> …` nothing but the role's own bytes reach the
//! console; run without that flag it is the test runner. Each role reads its
//! secrets from the console as the OpenHarmony signer's `readPassword` does
//! (echo cleared first, then the prompt, then one line) and proves from the
//! inside what it received; the fixture secrets are constants of this file,
//! never argv or environment. Synchronisation is the console's own output
//! and the child's own reads; no sleep orders anything. No signer, keystore
//! or device is involved, and no process this test did not start is
//! signalled.

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
mod windows {
    use arkdeck_platform::{
        PtyError, PtyExecution, PtyFailureCategory, PtyInteraction, PtyRequest, ToolTermination,
        VerifiedTool, random_bytes,
    };
    use sha2::{Digest, Sha256};
    use std::cell::RefCell;
    use std::ffi::OsString;
    use std::fs;
    use std::io::{BufRead, Write};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
    use windows_sys::Win32::System::Console::{
        ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT, GetConsoleMode, GetStdHandle,
        STD_INPUT_HANDLE, SetConsoleMode,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
    };

    const KEYSTORE: &str = "Enter keystore password:";
    const KEY: &str = "Enter key password:";
    const KEYSTORE_SECRET: &str = "fixture-ks-7Qv";
    /// Not ASCII: the console carries UTF-8 text.
    const KEY_SECRET: &str = "fixture-key-3Zp-\u{e4}\u{20ac}\u{1f511}";
    const WRONG_KEY_SECRET: &str = "fixture-wrong-9Xr";
    /// A near miss of `KEYSTORE`: never answered.
    const NEAR_MISS: &str = "Enter keystore passwd:";

    /// Exit codes a role uses to report what it saw from the inside.
    const SECRET_IN_ARGV_OR_ENVIRONMENT: i32 = 6;
    const READ_AFTER_NEAR_MISS: i32 = 9;
    const NO_CONSOLE: i32 = 10;
    const WRONG_IMAGE_SPELLING: i32 = 11;
    const WRONG_DIRECTORY_SPELLING: i32 = 12;

    // ---- the fake signer ------------------------------------------------

    /// Sets the console's echo as the signer's `readPassword` does: line
    /// input with echo cleared (or, for `echo`, left on).
    fn console_echo(on: bool) {
        // SAFETY: the standard input handle is borrowed, never closed.
        let input = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        let mut mode = 0;
        // SAFETY: fails for anything that is not a console input buffer.
        if unsafe { GetConsoleMode(input, &mut mode) } == 0 {
            std::process::exit(NO_CONSOLE);
        }
        let mode = mode | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT;
        let mode = if on {
            mode | ENABLE_ECHO_INPUT
        } else {
            mode & !ENABLE_ECHO_INPUT
        };
        // SAFETY: the same console input handle.
        if unsafe { SetConsoleMode(input, mode) } == 0 {
            std::process::exit(NO_CONSOLE);
        }
    }

    /// Prints a prompt (with the trailing space the signer prints) and reads
    /// one line from the console.
    fn ask(prompt: &str) -> String {
        let mut stdout = std::io::stdout().lock();
        write!(stdout, "{prompt} ").unwrap();
        stdout.flush().unwrap();
        drop(stdout);
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line).unwrap();
        line.trim_end_matches(['\r', '\n']).to_owned()
    }

    fn say(text: &str) {
        let mut stdout = std::io::stdout().lock();
        writeln!(stdout, "{text}").unwrap();
        stdout.flush().unwrap();
    }

    /// Neither secret reached this process through argv or its environment.
    fn assert_not_in_argv_or_environment(secrets: &[&str]) {
        let leaked = std::env::args_os()
            .chain(std::env::vars_os().flat_map(|(key, value)| [key, value]))
            .any(|text| {
                let text = text.to_string_lossy();
                secrets.iter().any(|secret| text.contains(secret))
            });
        if leaked {
            std::process::exit(SECRET_IN_ARGV_OR_ENVIRONMENT);
        }
    }

    /// Starts a grandchild that never ends on its own (it joins this
    /// child's Job) and names it in `report`, written whole, then renamed.
    /// It is never waited for: the Job ends it, and Windows keeps no zombie.
    #[allow(clippy::zombie_processes)]
    fn start_grandchild(report: &Path) {
        let grandchild = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--fake-tool", "park"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let partial = report.with_extension("partial");
        fs::write(&partial, grandchild.id().to_string()).unwrap();
        fs::rename(&partial, report).unwrap();
    }

    /// The keystore and key prompts, answered correctly or not: the signer's
    /// happy path and its keystore-password diagnostic.
    fn sign() -> ! {
        console_echo(false);
        let keystore = ask(KEYSTORE);
        let key = ask(KEY);
        assert_not_in_argv_or_environment(&[KEYSTORE_SECRET, KEY_SECRET, WRONG_KEY_SECRET]);
        // Each secret arrived exactly once, in its turn: a second copy of the
        // first answer would have been read here in place of the second.
        if keystore == KEYSTORE_SECRET && key == KEY_SECRET {
            say("signed");
            std::process::exit(0);
        }
        say("Incorrect keystore password");
        std::process::exit(1)
    }

    /// One role of the fake signer; never returns.
    pub fn fake_tool(arguments: &[OsString]) -> ! {
        let role = arguments
            .first()
            .and_then(|role| role.to_str())
            .unwrap_or("");
        let path = arguments.get(1).map(PathBuf::from);
        match role {
            "sign" => sign(),
            // Consumers such as Java inspect their image and current directory
            // spellings before they can ask for a password.
            "standard-paths" => {
                if std::env::args_os().next().as_ref() != arguments.get(1) {
                    std::process::exit(WRONG_IMAGE_SPELLING);
                }
                if std::env::current_dir().unwrap().as_os_str()
                    != arguments.get(2).expect("expected directory")
                {
                    std::process::exit(WRONG_DIRECTORY_SPELLING);
                }
                sign();
            }
            // The console's own echo left on: the typed secret is rendered.
            "echo" => {
                console_echo(true);
                let _ = ask(KEYSTORE);
            }
            // Echo off, but the signer prints what it read.
            "says" => {
                console_echo(false);
                let secret = ask(KEYSTORE);
                say(&format!("you said {secret}"));
            }
            // A near miss of the prompt, then a read that must never be
            // answered: anything read is recorded and ends the child.
            "near-miss" => {
                console_echo(false);
                let _ = ask(NEAR_MISS);
                fs::write(path.unwrap(), b"read").unwrap();
                std::process::exit(READ_AFTER_NEAR_MISS);
            }
            "twice" => {
                console_echo(false);
                let _ = ask(KEYSTORE);
                let _ = ask(KEYSTORE);
            }
            "reversed" => {
                console_echo(false);
                let _ = ask(KEY);
                let _ = ask(KEYSTORE);
            }
            "early" => say("no prompt here"),
            "early-fail" => std::process::exit(3),
            "flood" => {
                let line = "x".repeat(200);
                loop {
                    say(&line);
                }
            }
            // Never prompts and never ends on its own.
            "hang" => {
                console_echo(false);
                let mut line = String::new();
                let _ = std::io::stdin().lock().read_line(&mut line);
                loop {
                    std::thread::park();
                }
            }
            // A grandchild, then both prompts; `tree-hang` never ends,
            // `tree-exit` exits once answered.
            "tree-hang" | "tree-exit" => {
                start_grandchild(&path.unwrap());
                console_echo(false);
                let _ = ask(KEYSTORE);
                let _ = ask(KEY);
                if role == "tree-exit" {
                    say("signed");
                    std::process::exit(0);
                }
                loop {
                    std::thread::park();
                }
            }
            "park" => loop {
                std::thread::park();
            },
            // Proof that a refused exchange ran nothing.
            "marker" => fs::write(path.unwrap(), b"ran").unwrap(),
            _ => std::process::exit(2),
        }
        std::process::exit(0)
    }

    // ---- the runner -----------------------------------------------------

    type Test = (&'static str, fn());

    const TESTS: &[Test] = &[
        (
            "exact_prompts_are_answered_in_order_and_the_secret_never_comes_back",
            exact_prompts_are_answered_in_order_and_the_secret_never_comes_back,
        ),
        (
            "canonical_inputs_launch_standard_child_paths_without_changing_the_parent",
            canonical_inputs_launch_standard_child_paths_without_changing_the_parent,
        ),
        (
            "a_wrong_secret_is_classified_from_the_signers_last_diagnostic",
            a_wrong_secret_is_classified_from_the_signers_last_diagnostic,
        ),
        (
            "a_rendered_secret_ends_the_exchange",
            a_rendered_secret_ends_the_exchange,
        ),
        (
            "a_near_miss_prompt_is_never_answered",
            a_near_miss_prompt_is_never_answered,
        ),
        (
            "a_repeated_or_out_of_order_prompt_or_an_early_exit_is_a_protocol_violation",
            a_repeated_or_out_of_order_prompt_or_an_early_exit_is_a_protocol_violation,
        ),
        (
            "the_budget_the_timeout_and_a_cancellation_end_the_exchange",
            the_budget_the_timeout_and_a_cancellation_end_the_exchange,
        ),
        (
            "a_cancellation_ends_the_childs_whole_tree",
            a_cancellation_ends_the_childs_whole_tree,
        ),
        (
            "a_child_that_exits_leaves_no_descendant_behind",
            a_child_that_exits_leaves_no_descendant_behind,
        ),
        (
            "bounds_and_refusals_come_before_any_child_runs",
            bounds_and_refusals_come_before_any_child_runs,
        ),
    ];

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
                "arkdeck-xpa011-pty-{name}-{:032x}",
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

    /// This binary as the verified tool.
    fn this_tool() -> VerifiedTool {
        let path = std::env::current_exe().unwrap().canonicalize().unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
        VerifiedTool::open(&path, &digest).unwrap()
    }

    fn args(role: &str, path: Option<&Path>) -> Vec<OsString> {
        let mut arguments: Vec<OsString> = vec!["--fake-tool".into(), role.into()];
        arguments.extend(path.map(|path| path.as_os_str().to_owned()));
        arguments
    }

    fn request(arguments: &[OsString], timeout: Duration) -> PtyRequest<'_> {
        PtyRequest {
            arguments,
            environment: &[],
            working_directory: None,
            timeout,
        }
    }

    fn interaction(prompt: &str, secret: &str) -> PtyInteraction {
        PtyInteraction {
            expected_prompt: prompt.as_bytes().to_vec(),
            secret: secret.as_bytes().to_vec(),
        }
    }

    fn both(key: &str) -> Vec<PtyInteraction> {
        vec![
            interaction(KEYSTORE, KEYSTORE_SECRET),
            interaction(KEY, key),
        ]
    }

    fn exchange(
        role: &str,
        interactions: &[PtyInteraction],
        timeout: Duration,
    ) -> Result<PtyExecution, PtyError> {
        let arguments = args(role, None);
        this_tool().run_pty_exchange(&request(&arguments, timeout), interactions, 4096, &|| false)
    }

    const TIMEOUT: Duration = Duration::from_secs(30);

    /// These short local fixture paths have an ordinary spelling that names
    /// exactly the canonical object. Keep the assertions explicit so the test
    /// exercises lowering rather than the verbatim fallback.
    fn ordinary_fixture_path(canonical: &Path) -> PathBuf {
        let text = canonical.to_str().unwrap().strip_prefix(r"\\?\").unwrap();
        assert!(text.len() < 248 && text.as_bytes().get(1..3) == Some(b":\\"));
        let ordinary = PathBuf::from(text);
        assert_eq!(ordinary.canonicalize().unwrap(), canonical);
        ordinary
    }

    fn canonical_inputs_launch_standard_child_paths_without_changing_the_parent() {
        let parent_directory = std::env::current_dir().unwrap();
        let scratch = Scratch::new("standard-paths");
        let image = std::env::current_exe().unwrap().canonicalize().unwrap();
        let ordinary_image = ordinary_fixture_path(&image);
        let ordinary_directory = ordinary_fixture_path(&scratch.0);
        let arguments = vec![
            "--fake-tool".into(),
            "standard-paths".into(),
            ordinary_image.into_os_string(),
            ordinary_directory.clone().into_os_string(),
        ];
        let execution = this_tool()
            .run_pty_exchange(
                &PtyRequest {
                    working_directory: Some(&scratch.0),
                    ..request(&arguments, TIMEOUT)
                },
                &both(KEY_SECRET),
                4096,
                &|| false,
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        assert_eq!(execution.completed_interactions, 2);
        assert_eq!(execution.failure_category, PtyFailureCategory::None);
        assert_carries_no_secret(&execution);
        assert_eq!(std::env::current_dir().unwrap(), parent_directory);

        // Lowering is child-only: callers must still supply the canonical
        // directory, and an ordinary input is refused before any child runs.
        let marker = scratch.0.join("refused-marker");
        let arguments = args("marker", Some(&marker));
        assert!(matches!(
            this_tool().run_pty_exchange(
                &PtyRequest {
                    working_directory: Some(&ordinary_directory),
                    ..request(&arguments, TIMEOUT)
                },
                &both(KEY_SECRET),
                4096,
                &|| false,
            ),
            Err(PtyError::Refused(_))
        ));
        assert!(!marker.exists());
    }

    /// Nothing the exchange returns carries a secret.
    fn assert_carries_no_secret(execution: &PtyExecution) {
        let text = format!("{execution:?}");
        for secret in [KEYSTORE_SECRET, KEY_SECRET, WRONG_KEY_SECRET] {
            assert!(!text.contains(secret), "{text}");
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

    /// The grandchild the report names, opened while the exchange still
    /// runs (so its PID cannot have been reused).
    fn grandchild_of(report: &Path) -> Option<OwnedHandle> {
        fs::read_to_string(report)
            .ok()
            .and_then(|text| text.parse::<u32>().ok())
            .map(open_process)
    }

    // ---- tests ----------------------------------------------------------

    fn exact_prompts_are_answered_in_order_and_the_secret_never_comes_back() {
        let execution = exchange("sign", &both(KEY_SECRET), TIMEOUT).unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        assert_eq!(execution.completed_interactions, 2);
        assert_eq!(execution.failure_category, PtyFailureCategory::None);
        assert!(execution.observed_output_byte_count > 0);
        assert_carries_no_secret(&execution);
    }

    fn a_wrong_secret_is_classified_from_the_signers_last_diagnostic() {
        let execution = exchange("sign", &both(WRONG_KEY_SECRET), TIMEOUT).unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(1));
        assert_eq!(execution.completed_interactions, 2);
        assert_eq!(
            execution.failure_category,
            PtyFailureCategory::KeystorePasswordRejected
        );
        assert_carries_no_secret(&execution);
    }

    fn a_rendered_secret_ends_the_exchange() {
        for role in ["echo", "says"] {
            let error =
                exchange(role, &[interaction(KEYSTORE, KEYSTORE_SECRET)], TIMEOUT).unwrap_err();
            assert!(
                matches!(error, PtyError::SecretEchoDetected),
                "{role}: {error:?}"
            );
        }
    }

    fn a_near_miss_prompt_is_never_answered() {
        let scratch = Scratch::new("near-miss");
        let marker = scratch.0.join("read");
        let arguments = args("near-miss", Some(&marker));
        let error = this_tool()
            .run_pty_exchange(
                &request(&arguments, Duration::from_secs(2)),
                &[interaction(KEYSTORE, KEYSTORE_SECRET)],
                4096,
                &|| false,
            )
            .unwrap_err();
        // A written answer would have been read and ended the child (a
        // protocol violation) well within the deadline, leaving the marker.
        assert!(matches!(error, PtyError::TimedOut), "{error:?}");
        assert!(!marker.exists());
    }

    fn a_repeated_or_out_of_order_prompt_or_an_early_exit_is_a_protocol_violation() {
        for (role, interactions) in [
            ("twice", vec![interaction(KEYSTORE, KEYSTORE_SECRET)]),
            ("reversed", both(KEY_SECRET)),
            ("early", vec![interaction(KEYSTORE, KEYSTORE_SECRET)]),
            ("early-fail", vec![interaction(KEYSTORE, KEYSTORE_SECRET)]),
        ] {
            let error = exchange(role, &interactions, TIMEOUT).unwrap_err();
            assert!(
                matches!(error, PtyError::PromptProtocolViolation),
                "{role}: {error:?}"
            );
        }
    }

    fn the_budget_the_timeout_and_a_cancellation_end_the_exchange() {
        let one = [interaction(KEYSTORE, KEYSTORE_SECRET)];
        let flood = args("flood", None);
        let error = this_tool()
            .run_pty_exchange(&request(&flood, TIMEOUT), &one, 1024, &|| false)
            .unwrap_err();
        assert!(matches!(error, PtyError::OutputBudgetExceeded), "{error:?}");
        let started = Instant::now();
        let error = exchange("hang", &one, Duration::from_secs(1)).unwrap_err();
        assert!(matches!(error, PtyError::TimedOut), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(10));
        let hang = args("hang", None);
        let error = this_tool()
            .run_pty_exchange(&request(&hang, TIMEOUT), &one, 4096, &|| true)
            .unwrap_err();
        assert!(matches!(error, PtyError::Cancelled), "{error:?}");
    }

    fn a_cancellation_ends_the_childs_whole_tree() {
        let scratch = Scratch::new("tree-hang");
        let report = scratch.0.join("grandchild");
        let arguments = args("tree-hang", Some(&report));
        let grandchild = RefCell::new(None);
        let error = this_tool()
            .run_pty_exchange(
                &request(&arguments, TIMEOUT),
                &both(KEY_SECRET),
                4096,
                &|| {
                    // Cancel once the grandchild is held open: it is alive and a
                    // member of the child's Job.
                    let mut held = grandchild.borrow_mut();
                    if held.is_none() {
                        *held = grandchild_of(&report);
                    }
                    held.is_some()
                },
            )
            .unwrap_err();
        assert!(matches!(error, PtyError::Cancelled), "{error:?}");
        let grandchild = grandchild.into_inner().expect("the grandchild was named");
        assert!(ended_within(&grandchild, Duration::from_secs(5)));
    }

    fn a_child_that_exits_leaves_no_descendant_behind() {
        let scratch = Scratch::new("tree-exit");
        let report = scratch.0.join("grandchild");
        let arguments = args("tree-exit", Some(&report));
        let grandchild = RefCell::new(None);
        let execution = this_tool()
            .run_pty_exchange(
                &request(&arguments, TIMEOUT),
                &both(KEY_SECRET),
                4096,
                &|| {
                    // The report precedes the first prompt, and the child waits
                    // for the second answer, so the grandchild is held open
                    // before the child can exit.
                    let mut held = grandchild.borrow_mut();
                    if held.is_none() {
                        *held = grandchild_of(&report);
                    }
                    false
                },
            )
            .unwrap();
        assert_eq!(execution.termination, ToolTermination::Exited(0));
        assert_eq!(execution.completed_interactions, 2);
        let grandchild = grandchild.into_inner().expect("the grandchild was named");
        assert!(ended_within(&grandchild, Duration::from_secs(5)));
    }

    fn bounds_and_refusals_come_before_any_child_runs() {
        let scratch = Scratch::new("bounded");
        let marker = scratch.0.join("ran");
        let arguments = args("marker", Some(&marker));
        let tool = this_tool();
        let too_many: Vec<PtyInteraction> = (0..5)
            .map(|_| interaction(KEYSTORE, KEYSTORE_SECRET))
            .collect();
        for (interactions, budget) in [
            (Vec::new(), 4096),
            (too_many, 4096),
            (vec![interaction("", "x")], 4096),
            (vec![interaction(KEYSTORE, "")], 4096),
            (vec![interaction(KEYSTORE, "with\nnewline")], 4096),
            (vec![interaction(KEYSTORE, "with\rreturn")], 4096),
            (vec![interaction(KEYSTORE, "with\u{3}ctrl-c")], 4096),
            (vec![interaction(KEYSTORE, "with\u{1b}escape")], 4096),
            (vec![interaction(KEYSTORE, KEYSTORE_SECRET)], 1023),
        ] {
            let error = tool
                .run_pty_exchange(
                    &request(&arguments, TIMEOUT),
                    &interactions,
                    budget,
                    &|| false,
                )
                .unwrap_err();
            assert!(matches!(error, PtyError::InvalidInteraction), "{error:?}");
        }
        let not_utf8 = [PtyInteraction {
            expected_prompt: KEYSTORE.as_bytes().to_vec(),
            secret: vec![b'x', 0xff],
        }];
        let error = tool
            .run_pty_exchange(&request(&arguments, TIMEOUT), &not_utf8, 4096, &|| false)
            .unwrap_err();
        assert!(matches!(error, PtyError::InvalidInteraction), "{error:?}");
        let one = [interaction(KEYSTORE, KEYSTORE_SECRET)];
        let error = tool
            .run_pty_exchange(&request(&arguments, Duration::ZERO), &one, 4096, &|| false)
            .unwrap_err();
        assert!(matches!(error, PtyError::Refused(_)), "{error:?}");
        let environment = [(OsString::from("Path"), OsString::from(r"C:\elsewhere"))];
        let error = tool
            .run_pty_exchange(
                &PtyRequest {
                    arguments: &arguments,
                    environment: &environment,
                    working_directory: None,
                    timeout: TIMEOUT,
                },
                &one,
                4096,
                &|| false,
            )
            .unwrap_err();
        assert!(matches!(error, PtyError::Refused(_)), "{error:?}");
        let relative = Path::new("relative");
        let error = tool
            .run_pty_exchange(
                &PtyRequest {
                    arguments: &arguments,
                    environment: &[],
                    working_directory: Some(relative),
                    timeout: TIMEOUT,
                },
                &one,
                4096,
                &|| false,
            )
            .unwrap_err();
        assert!(matches!(error, PtyError::Refused(_)), "{error:?}");
        assert!(!marker.exists());
    }
}
