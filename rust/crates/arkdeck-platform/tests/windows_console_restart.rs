//! The confirmed restart of the registered Windows HDC as a human runs it
//! (CHG-2026-074 TASK-XPA-005 over CHG-2026-078): the real daemon over an
//! isolated development root, composing the registered DevEco Studio
//! 26.0.0.43 `hdc.exe` (`3.2.0g`) as its managed server, and the real
//! `arkdeck.exe` verifying a copy of the daemon signed with the host-trusted
//! development signer.
//!
//! * The impact preview and the restart's approval request run through the
//!   CLI as any caller runs them.
//! * `human-action resume` with a redirected stdin is refused: the daemon
//!   derives the foreground-console origin of the pipe client (#2480,
//!   maintainer ruling 2026-10-04), but the CLI reads a challenge answer
//!   only from a terminal, so nothing is answered and nothing restarts.
//! * `human-action resume` in a pseudo console (`CreatePseudoConsole`): the
//!   CLI renders the impact and the one-time challenge, the test types it as
//!   a human would, and the restart runs; the control action ends
//!   `succeeded` with a strictly newer, proved server.
//! * A wrong answer typed at the console is refused and restarts nothing.
//!
//! It needs `ARKDECK_LIVE_WINDOWS_HDC` (the registered `hdc.exe`) and
//! `ARKDECK_DEV_SIGNER_THUMBPRINT`; without either it says so and checks
//! nothing. Nothing else may listen on `127.0.0.1:8710`: only the servers
//! this daemon starts are stopped, by the daemon. No board is needed.
//!
//! A `harness = false` target of this crate, which alone may host a pseudo
//! console (the workspace forbids `unsafe` elsewhere); the daemon and the
//! CLI are the workspace's own builds beside it.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    windows::run();
}

#[cfg(windows)]
mod windows {
    use arkdeck_platform::StateRoot;
    use serde_json::Value;
    use std::ffi::c_void;
    use std::fs::File;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc::{self, Receiver};
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::WAIT_OBJECT_0;
    use windows_sys::Win32::System::Console::{
        COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList,
        EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess, InitializeProcThreadAttributeList,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, PROCESS_INFORMATION, STARTF_USESTDHANDLES,
        STARTUPINFOEXW, UpdateProcThreadAttribute, WaitForSingleObject,
    };

    const DEADLINE: Duration = Duration::from_secs(120);
    const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";
    const CHALLENGE_PROMPT: &str = "Type this one-time challenge exactly: ";

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("ad-winconsolerestart-{nonce:016x}"));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct Daemon {
        child: Option<Child>,
        lines: Receiver<String>,
        seen: Vec<String>,
    }

    impl Daemon {
        fn start(executable: &Path, root: &Path, hdc: &Path) -> Self {
            let mut command = Command::new(executable);
            for (key, _) in std::env::vars_os() {
                let key = key.to_string_lossy().into_owned();
                if key.to_ascii_uppercase().starts_with("ARKDECK_")
                    || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
                {
                    command.env_remove(key);
                }
            }
            let mut child = command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
                .env("ARKDECK_DEVELOPMENT_HDC_PATH", hdc)
                .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap();
            let stdout = child.stdout.take().unwrap();
            let (sender, lines) = mpsc::channel();
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if sender.send(line).is_err() {
                        break;
                    }
                }
            });
            Self {
                child: Some(child),
                lines,
                seen: Vec::new(),
            }
        }

        fn line_starting(&mut self, prefix: &str) -> String {
            let deadline = Instant::now() + DEADLINE;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match self.lines.recv_timeout(left) {
                    Ok(line) => {
                        self.seen.push(line.clone());
                        if line.starts_with(prefix) {
                            return line;
                        }
                    }
                    Err(error) => panic!(
                        "no line starting {prefix:?} ({error}); stdout so far {:?}",
                        self.seen
                    ),
                }
            }
        }

        fn stop(&mut self, root: &Path) -> Vec<String> {
            let child = self.child.take().unwrap();
            let scope = StateRoot::development(root).unwrap().scope().unwrap();
            scope.request_stop(child.id()).unwrap();
            self.line_starting("arkdeck-agentd stopped");
            let mut child = child;
            let deadline = Instant::now() + DEADLINE;
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success(), "{status:?}");
                    return std::mem::take(&mut self.seen);
                }
                assert!(Instant::now() < deadline, "the daemon did not end");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    impl Drop for Daemon {
        fn drop(&mut self) {
            if let Some(mut child) = self.child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    fn pwsh() -> PathBuf {
        if let Some(found) = std::env::var_os("PATH").and_then(|path| {
            std::env::split_paths(&path)
                .map(|directory| directory.join("pwsh.exe"))
                .find(|candidate| candidate.exists())
        }) {
            return found;
        }
        let alias = PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
            .join("Microsoft/WindowsApps/pwsh.exe");
        assert!(
            alias.exists(),
            "PowerShell 7 is required to sign the daemon"
        );
        alias
    }

    /// A binary of the workspace beside this test's own build: the daemon
    /// and the CLI, which the workspace tests build (or `cargo build -p
    /// arkdeck-agentd -p arkdeck-cli` before testing this crate alone).
    fn workspace_binary(name: &str) -> PathBuf {
        let deps = std::env::current_exe().unwrap();
        let path = deps.parent().unwrap().parent().unwrap().join(name);
        assert!(
            path.exists(),
            "{} is not built: run the workspace tests, or `cargo build -p arkdeck-agentd -p              arkdeck-cli` before testing this crate alone",
            path.display()
        );
        path
    }

    fn cli_path() -> PathBuf {
        workspace_binary("arkdeck.exe")
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        Sha256::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    /// The CLI's environment: this process's, without any `ARKDECK_` input,
    /// plus the pipe and the daemon identity it verifies.
    fn cli_environment(daemon: &Path, pin: &str, pipe: &str) -> Vec<(String, String)> {
        let mut environment: Vec<(String, String)> = std::env::vars()
            .filter(|(key, _)| !key.to_ascii_uppercase().starts_with("ARKDECK_"))
            .collect();
        environment.push(("ARKDECK_ENDPOINT".into(), pipe.into()));
        environment.push(("ARKDECK_DAEMON_PATH".into(), daemon.display().to_string()));
        environment.push(("ARKDECK_DAEMON_SIGNER_SHA256".into(), pin.into()));
        environment
    }

    /// The real CLI with a redirected stdin: its exit code and envelope.
    fn cli(environment: &[(String, String)], arguments: &[&str]) -> (Option<i32>, Value) {
        let output = Command::new(cli_path())
            .env_clear()
            .envs(environment.iter().cloned())
            .args(arguments)
            .args(["--output", "json"])
            .stdin(Stdio::null())
            .output()
            .unwrap_or_else(|error| {
                panic!(
                    "the arkdeck CLI beside the daemon ({}): {error}; build arkdeck-cli first",
                    cli_path().display()
                )
            });
        let envelope = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
        (output.status.code(), envelope)
    }

    struct Rendered {
        bytes: Mutex<Vec<u8>>,
        changed: Condvar,
    }

    fn pipe() -> (OwnedHandle, OwnedHandle) {
        let (mut read, mut write) = (std::ptr::null_mut(), std::ptr::null_mut());
        // SAFETY: live out values; no inheritance.
        assert_ne!(
            unsafe { CreatePipe(&mut read, &mut write, std::ptr::null(), 0) },
            0
        );
        // SAFETY: two new handles owned from here on.
        unsafe {
            (
                OwnedHandle::from_raw_handle(read),
                OwnedHandle::from_raw_handle(write),
            )
        }
    }

    /// The text a pseudo console rendered, its VT control sequences removed.
    fn plain(bytes: &[u8]) -> String {
        let text = String::from_utf8_lossy(bytes);
        let mut out = String::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' {
                match chars.next() {
                    Some('[') => {
                        for c in chars.by_ref() {
                            if ('@'..='~').contains(&c) {
                                break;
                            }
                        }
                    }
                    Some(']') => {
                        while let Some(c) = chars.next() {
                            if c == '\u{7}' {
                                break;
                            }
                            if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                                chars.next();
                                break;
                            }
                        }
                    }
                    _ => {}
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// The real CLI in a pseudo console: once `answer` sees the rendered
    /// text, what it returns is typed. Returns the exit code and the
    /// rendered text.
    fn console_cli(
        environment: &[(String, String)],
        arguments: &[&str],
        answer: impl Fn(&str) -> Option<String>,
    ) -> (u32, String) {
        let (input_read, input_write) = pipe();
        let (output_read, output_write) = pipe();
        let mut console: HPCON = 0;
        // SAFETY: live pipe ends and out value.
        let status = unsafe {
            CreatePseudoConsole(
                COORD { X: 240, Y: 400 },
                input_read.as_raw_handle(),
                output_write.as_raw_handle(),
                0,
                &mut console,
            )
        };
        assert_eq!(status, 0, "CreatePseudoConsole");
        let rendered = Arc::new(Rendered {
            bytes: Mutex::new(Vec::new()),
            changed: Condvar::new(),
        });
        let reader = {
            let rendered = Arc::clone(&rendered);
            let mut output = File::from(output_read);
            std::thread::spawn(move || {
                let mut buffer = [0u8; 4096];
                while let Ok(count @ 1..) = output.read(&mut buffer) {
                    rendered
                        .bytes
                        .lock()
                        .unwrap()
                        .extend_from_slice(&buffer[..count]);
                    rendered.changed.notify_all();
                }
            })
        };
        let mut size = 0usize;
        // SAFETY: the documented size query; it fails with the size set.
        unsafe { InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size) };
        let mut list = vec![0usize; size.div_ceil(size_of::<usize>())];
        let attributes = list.as_mut_ptr().cast::<c_void>();
        // SAFETY: a buffer of the queried size; the pseudo console handle
        // value is the attribute, as documented.
        unsafe {
            assert_ne!(
                InitializeProcThreadAttributeList(attributes, 1, 0, &mut size),
                0
            );
            assert_ne!(
                UpdateProcThreadAttribute(
                    attributes,
                    0,
                    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                    console as *const c_void,
                    size_of::<HPCON>(),
                    std::ptr::null_mut(),
                    std::ptr::null(),
                ),
                0
            );
        }
        let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        // Null standard handles: with nothing inherited, the CLI takes the
        // pseudo console's own input and output, never this process's
        // (redirected) ones, as the product's pseudo console spawn does.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.lpAttributeList = attributes;
        let mut command_line = format!("\"{}\"", cli_path().display());
        for argument in arguments.iter().chain(&["--output", "json"]) {
            command_line.push_str(&format!(" \"{argument}\""));
        }
        let mut command: Vec<u16> = command_line.encode_utf16().chain(Some(0)).collect();
        let mut block: Vec<u16> = Vec::new();
        for (key, value) in environment {
            block.extend(format!("{key}={value}").encode_utf16());
            block.push(0);
        }
        block.push(0);
        let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: every pointer is live for the call; no handle is inherited.
        let created = unsafe {
            CreateProcessW(
                std::ptr::null(),
                command.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                block.as_ptr().cast(),
                std::ptr::null(),
                &startup.StartupInfo,
                &mut process,
            )
        };
        assert_ne!(created, 0, "CreateProcessW");
        // SAFETY: the new process and thread handles are owned from here on.
        let (child, _thread) = unsafe {
            (
                OwnedHandle::from_raw_handle(process.hProcess),
                OwnedHandle::from_raw_handle(process.hThread),
            )
        };
        drop(input_read);
        drop(output_write);
        let mut input = File::from(input_write);
        {
            let deadline = Instant::now() + DEADLINE;
            let mut bytes = rendered.bytes.lock().unwrap();
            loop {
                // SAFETY: a live process handle; a zero wait only polls.
                if unsafe { WaitForSingleObject(child.as_raw_handle(), 0) } == WAIT_OBJECT_0 {
                    break;
                }
                if let Some(typed) = answer(&plain(&bytes)) {
                    drop(bytes);
                    input.write_all(typed.as_bytes()).unwrap();
                    input.flush().unwrap();
                    break;
                }
                let left = deadline
                    .checked_duration_since(Instant::now())
                    .unwrap_or_else(|| panic!("no prompt was rendered: {}", plain(&bytes)));
                bytes = rendered
                    .changed
                    .wait_timeout(bytes, left.min(Duration::from_millis(200)))
                    .unwrap()
                    .0;
            }
        }
        // SAFETY: a live process handle.
        let waited =
            unsafe { WaitForSingleObject(child.as_raw_handle(), DEADLINE.as_millis() as u32) };
        assert_eq!(waited, WAIT_OBJECT_0, "the CLI did not end");
        let mut code = 0;
        // SAFETY: a live process handle and out value.
        assert_ne!(
            unsafe { GetExitCodeProcess(child.as_raw_handle(), &mut code) },
            0
        );
        // SAFETY: the console is closed once; the attribute list is deleted
        // after the process that used it has ended.
        unsafe {
            ClosePseudoConsole(console);
            DeleteProcThreadAttributeList(attributes);
        }
        drop(input);
        reader.join().unwrap();
        let text = plain(&rendered.bytes.lock().unwrap());
        (code, text)
    }

    /// The one-time challenge a rendered console shows, once fully rendered.
    fn challenge(text: &str) -> Option<String> {
        let start = text.find(CHALLENGE_PROMPT)? + CHALLENGE_PROMPT.len();
        let rest = &text[start..];
        let token: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect();
        // Complete once something other than the token follows it.
        (token.len() > "ARKDECK-".len() && rest.len() > token.len()).then_some(token)
    }

    fn endpoint_free() -> bool {
        std::net::TcpStream::connect_timeout(
            &"127.0.0.1:8710".parse().unwrap(),
            Duration::from_millis(300),
        )
        .is_err()
    }

    /// An impact preview of the server's current generation and its
    /// restart's approval request, through the CLI.
    fn request_approval(environment: &[(String, String)], label: &str) -> (Value, Value) {
        let (code, status) = cli(environment, &["runtime", "hdc", "status"]);
        assert_eq!(code, Some(0), "{status}");
        let status = status["result"].clone();
        assert_eq!(status["ownership"], "arkDeckManaged", "{status}");
        let (code, preview) = cli(
            environment,
            &[
                "runtime",
                "hdc",
                "impact-preview",
                "--action",
                "restart",
                "--server-endpoint-ref",
                status["serverEndpointRef"].as_str().unwrap(),
                "--expected-server-generation",
                status["generation"].as_str().unwrap(),
                "--action-request-id",
                label,
            ],
        );
        assert_eq!(code, Some(0), "{preview}");
        let action = preview["result"].clone();
        assert_eq!(action["blockerReasonCode"], Value::Null, "{action}");
        let (code, restart) = cli(
            environment,
            &[
                "runtime",
                "hdc",
                "restart",
                "--control-action",
                action["controlActionId"].as_str().unwrap(),
                "--preview-id",
                action["preview"]["previewId"].as_str().unwrap(),
                "--preview-digest",
                action["preview"]["previewDigest"].as_str().unwrap(),
            ],
        );
        eprintln!("restart: exit {code:?}");
        let har = restart["result"]["humanAction"].clone();
        assert_eq!(har["category"], "impactApproval", "{restart}");
        (status, restart["result"].clone())
    }

    fn resume_arguments(action: &Value) -> Vec<String> {
        let har = &action["humanAction"];
        vec![
            "human-action".into(),
            "resume".into(),
            "--human-action".into(),
            har["actionId"].as_str().unwrap().into(),
            "--resume-reference".into(),
            har["resumeReference"].as_str().unwrap().into(),
        ]
    }

    fn shown(environment: &[(String, String)], action: &Value) -> Value {
        let (code, shown) = cli(
            environment,
            &[
                "control-action",
                "show",
                "--control-action",
                action["controlActionId"].as_str().unwrap(),
            ],
        );
        assert_eq!(code, Some(0), "{shown}");
        shown["result"].clone()
    }

    fn generation(value: &Value) -> u64 {
        value["generation"].as_str().unwrap().parse().unwrap()
    }

    fn the_console_approves_a_confirmed_restart() {
        let Some(hdc) = std::env::var_os("ARKDECK_LIVE_WINDOWS_HDC").filter(|v| !v.is_empty())
        else {
            eprintln!(
                "SKIPPED: ARKDECK_LIVE_WINDOWS_HDC does not name the registered hdc.exe; nothing \
                 was checked"
            );
            return;
        };
        let Some(thumbprint) =
            std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
        else {
            eprintln!(
                "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set, so no host-trusted development \
                 signer can sign the daemon the CLI must verify; nothing was checked"
            );
            return;
        };
        let hdc = PathBuf::from(hdc);
        assert_eq!(
            sha256_hex(&std::fs::read(&hdc).unwrap()),
            C2_SHA256,
            "{} is not the registered hdc.exe",
            hdc.display()
        );
        assert!(
            endpoint_free(),
            "something already listens on 127.0.0.1:8710; this test never stops a server it did \
             not start"
        );
        let root = Root::new();
        let signed = root.0.join("signed-bin");
        std::fs::create_dir(&signed).unwrap();
        let daemon = signed.join("arkdeck-agentd.exe");
        std::fs::copy(workspace_binary("arkdeck-agentd.exe"), &daemon).unwrap();
        let script =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
        let signing = Command::new(pwsh())
            .args(["-NoProfile", "-NonInteractive", "-File"])
            .arg(&script)
            .arg("sign")
            .arg("-Thumbprint")
            .arg(&thumbprint)
            .arg("-Path")
            .arg(&daemon)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(signing.status.success(), "{signing:?}");
        let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
        let pin = pin["pin"].as_str().unwrap().to_owned();

        let mut running = Daemon::start(&daemon, &root.0, &hdc);
        let pipe = running
            .line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned();
        let environment = cli_environment(&daemon, &pin, &pipe);

        // 1. A redirected stdin: the challenge is never answered.
        let (before, action) = request_approval(&environment, "console-redirected");
        let arguments = resume_arguments(&action);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (code, refused) = cli(&environment, &arguments);
        eprintln!("redirected resume: exit {code:?} {refused}");
        assert_ne!(code, Some(0), "{refused}");
        assert_eq!(refused["ok"], false, "{refused}");
        assert_ne!(shown(&environment, &action)["state"], "succeeded");
        assert_eq!(shown(&environment, &action)["dispatchCount"], 0);

        // 2. A wrong answer at the console: refused, nothing restarts.
        let (code, text) = console_cli(&environment, &arguments, |text| {
            challenge(text).map(|_| "ARKDECK-WRONGANSWER\r".to_owned())
        });
        eprintln!("wrong answer: exit {code}");
        assert_ne!(code, 0, "{text}");
        assert!(text.contains(CHALLENGE_PROMPT), "{text}");
        assert_eq!(shown(&environment, &action)["dispatchCount"], 0);

        // 3. The challenge typed exactly at the console: the restart runs.
        let (_, action) = if shown(&environment, &action)["state"] == "awaitingImpactApproval" {
            (Value::Null, action)
        } else {
            // A refused answer may retire the approval; ask again.
            request_approval(&environment, "console-typed")
        };
        let arguments = resume_arguments(&action);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (code, text) = console_cli(&environment, &arguments, |text| {
            challenge(text).map(|token| format!("{token}\r"))
        });
        eprintln!("typed answer: exit {code}");
        assert!(text.contains("Review the complete immutable Runtime control-action impact"));
        assert_eq!(code, 0, "{text}");
        let finished = shown(&environment, &action);
        assert_eq!(finished["state"], "succeeded", "{finished}");
        assert_eq!(finished["dispatchCount"], 1, "{finished}");
        let (code, after) = cli(&environment, &["runtime", "hdc", "status"]);
        assert_eq!(code, Some(0), "{after}");
        let after = after["result"].clone();
        eprintln!("status after: {after}");
        assert!(generation(&after) > generation(&before), "{after}");
        assert_eq!(after["ownership"], "arkDeckManaged", "{after}");

        let tail = running.stop(&root.0);
        eprintln!("daemon stop: {tail:?}");
        assert!(endpoint_free(), "the daemon ended the server it started");
    }

    pub fn run() -> ! {
        let mut filters = Vec::new();
        let mut list = false;
        let mut skip_value = false;
        for argument in std::env::args().skip(1) {
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
                filters.push(argument);
            }
        }
        const NAME: &str = "the_console_approves_a_confirmed_restart";
        let selected = filters.is_empty() || filters.iter().any(|filter| NAME.contains(filter));
        if list {
            if selected {
                println!("{NAME}: test");
            }
            std::process::exit(0);
        }
        println!("\nrunning {} tests", usize::from(selected));
        let passed =
            !selected || std::panic::catch_unwind(the_console_approves_a_confirmed_restart).is_ok();
        if selected {
            println!("test {NAME} ... {}", if passed { "ok" } else { "FAILED" });
        }
        println!(
            "\ntest result: {}. {} passed; {} failed",
            if passed { "ok" } else { "FAILED" },
            usize::from(selected && passed),
            usize::from(!passed)
        );
        std::process::exit(i32::from(!passed));
    }
}
