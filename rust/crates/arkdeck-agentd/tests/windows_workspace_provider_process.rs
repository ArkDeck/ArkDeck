//! The workspace provider on Windows (TASK-XPA-011, GJ-5), as the real
//! daemon composes it over an isolated development root.
//!
//! * A registered OpenHarmony project is composed by the next start, with
//!   the inspector the host configured (`ARKDECK_WORKSPACE_INSPECTOR`):
//!   this test binary, copied into the root, which answers as `grep -r -n
//!   --include <scope> -- <symbol> <root>` answers when the daemon runs it.
//!   `workspace.inspect-source@1` is available, plans under the default
//!   read-only policy, runs, and publishes exactly what the inspector prints
//!   when run directly with the argv the provider builds; after a restart
//!   the Job and its Artifact read back and a resubmission is the same Job.
//! * The project resolves to no profile: Swift's profiles pin code-owned
//!   system tools (`grep`, `sed`, `patch`, `bsdtar`, `git`, SwiftPM), and no
//!   such tool is trusted on Windows yet. Every profile-served workspace
//!   operation is unavailable with that reason, and a plan of one is refused
//!   before admission with zero dispatch.
//! * The census names the workspace provider where the macOS census does.
//!   An inspector that is no executable refuses the start.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root and its inspector: nothing installed is read or
//! written, no toolchain, signing material, HDC or device is involved.
//!
//! The binary is its own harness (`harness = false`): run with `-r` first
//! it is the inspector, otherwise it runs its tests.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-r") {
        windows::fake_inspector(&arguments[1..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod windows {
    use arkdeck_platform::StateRoot;
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc::{self, Receiver};
    use std::time::{Duration, Instant};

    const DEADLINE: Duration = Duration::from_secs(60);
    const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
    const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
    const INDEX_SOURCE: &str = "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n";
    const TOOLS_REASON: &str = "workspace.toolchainUnavailable: no code-owned source tool \
        (grep, sed, patch, bsdtar, git or SwiftPM) is trusted on Windows";

    /// `grep -r -n --include <glob> -- <symbol> <root>` over a tree of plain
    /// files: every line holding `symbol` in a file whose name `glob`
    /// (`*.<extension>` or a whole name) matches, as `<path>:<line>:<text>`,
    /// files in name order; exit 0 with a match, 1 without, 2 on misuse.
    pub fn fake_inspector(arguments: &[String]) -> ! {
        let (Some(glob), Some(symbol), Some(root)) =
            (arguments.get(3), arguments.get(5), arguments.get(6))
        else {
            std::process::exit(2);
        };
        if arguments[..3] != ["-r", "-n", "--include"] || arguments[4] != "--" {
            std::process::exit(2);
        }
        let matches_name = |name: &str| match glob.strip_prefix('*') {
            Some(suffix) => name.ends_with(suffix),
            None => name == glob,
        };
        let mut output = Vec::new();
        let mut stack = vec![PathBuf::from(root)];
        let mut files = Vec::new();
        while let Some(directory) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&directory) else {
                std::process::exit(2);
            };
            for entry in entries {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    stack.push(path);
                } else if matches_name(path.file_name().unwrap().to_str().unwrap()) {
                    files.push(path);
                }
            }
        }
        files.sort();
        for file in files {
            let text = std::fs::read_to_string(&file).unwrap_or_default();
            for (index, line) in text.lines().enumerate() {
                if line.contains(symbol.as_str()) {
                    output.extend(format!("{}:{}:{line}\n", file.display(), index + 1).bytes());
                }
            }
        }
        std::io::stdout().write_all(&output).unwrap();
        std::process::exit(if output.is_empty() { 1 } else { 0 });
    }

    type Test = (&'static str, fn());
    const TESTS: &[Test] = &[
        (
            "the_configured_inspector_inspects_a_registered_project_across_a_restart",
            the_configured_inspector_inspects_a_registered_project_across_a_restart,
        ),
        (
            "an_inspector_that_is_no_executable_refuses_the_start",
            an_inspector_that_is_no_executable_refuses_the_start,
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
            "\ntest result: {}. {} passed; {} failed; 0 ignored; 0 measured; 0 filtered out\n",
            if failed.is_empty() { "ok" } else { "FAILED" },
            selected.len() - failed.len(),
            failed.len()
        );
        std::process::exit(if failed.is_empty() { 0 } else { 101 });
    }

    /// A fresh development root below the temporary directory in its plain
    /// canonical spelling (a workspace root must be that spelling), with an
    /// OpenHarmony project and the inspector, removed with what it holds.
    struct Root(PathBuf);
    impl Root {
        fn new(tag: &str) -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let temporary = std::env::temp_dir().canonicalize().unwrap();
            let temporary = match temporary
                .to_str()
                .and_then(|text| text.strip_prefix(r"\\?\"))
            {
                Some(plain) => PathBuf::from(plain),
                None => temporary,
            };
            let path = temporary.join(format!("ad-winworkspace-{tag}-{nonce:016x}"));
            std::fs::create_dir(&path).unwrap();
            let project = path.join("sources").join("project");
            for (relative, bytes) in [
                ("build-profile.json5", "{}\n"),
                ("entry/src/main/module.json5", "{}\n"),
                (INDEX, INDEX_SOURCE),
                ("entry/src/main/ets/pages/Other.txt", "build\n"),
            ] {
                let file = project.join(relative);
                std::fs::create_dir_all(file.parent().unwrap()).unwrap();
                std::fs::write(file, bytes).unwrap();
            }
            std::fs::create_dir(path.join("tools")).unwrap();
            std::fs::copy(
                std::env::current_exe().unwrap(),
                path.join("tools").join("inspector.exe"),
            )
            .unwrap();
            Self(path)
        }
        fn project(&self) -> String {
            self.0
                .join("sources")
                .join("project")
                .to_str()
                .unwrap()
                .to_owned()
        }
        fn inspector(&self) -> PathBuf {
            self.0.join("tools").join("inspector.exe")
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn daemon(root: &Path) -> Command {
        let mut command = Command::new(DAEMON);
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            if key.to_ascii_uppercase().starts_with("ARKDECK_")
                || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
            {
                command.env_remove(key);
            }
        }
        command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }

    /// A running daemon, its stdout read line by line as it comes.
    struct Daemon {
        child: Option<Child>,
        lines: Receiver<String>,
        seen: Vec<String>,
    }

    impl Daemon {
        fn spawn(mut command: Command) -> Self {
            let mut child = command.spawn().unwrap();
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

        fn pid(&self) -> u32 {
            self.child.as_ref().unwrap().id()
        }

        /// Every line up to the first that starts with `prefix`, returned.
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

        fn serving(&mut self) -> String {
            self.line_starting("arkdeck-agentd listening on ")
                .trim_start_matches("arkdeck-agentd listening on ")
                .to_owned()
        }

        fn stop(&mut self, root: &Path) {
            let scope = StateRoot::development(root).unwrap().scope().unwrap();
            scope.request_stop(self.pid()).unwrap();
            self.line_starting("arkdeck-agentd stopped");
            let status = wait(self.child.take().unwrap());
            assert!(status.success(), "{status:?}");
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

    fn wait(mut child: Child) -> std::process::ExitStatus {
        let (sender, receiver) = mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let status = child.wait();
            let _ = sender.send(());
            (child, status)
        });
        receiver
            .recv_timeout(DEADLINE)
            .expect("the daemon did not end within the deadline");
        waiter.join().unwrap().1.unwrap()
    }

    /// One request on a fresh plain handle of the daemon's pipe.
    fn request(pipe: &str, method: &str, params: Value) -> Value {
        let mut connection = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(pipe)
            .unwrap();
        let mut frame = serde_json::to_vec(&json!({
            "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
            "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
            "id": method,
            "method": method,
            "params": params,
        }))
        .unwrap();
        frame.push(b'\n');
        connection.write_all(&frame).unwrap();
        let mut reply = Vec::new();
        let mut byte = [0u8; 1];
        while byte[0] != b'\n' {
            assert_eq!(
                connection.read(&mut byte).unwrap(),
                1,
                "the reply ended early"
            );
            reply.push(byte[0]);
        }
        serde_json::from_slice(&reply).unwrap()
    }

    fn answered(pipe: &str, method: &str, params: Value) -> Value {
        let reply = request(pipe, method, params.clone());
        assert_eq!(reply["ok"], true, "{method} {params}: {reply}");
        reply["result"].clone()
    }

    fn job_request(label: &str, operation: &str, inputs: Value) -> Value {
        json!({"requestJson": json!({
            "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
            "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
            "operation": {"id": operation, "version": 1},
            "target": {"targetId": "workspace-host"},
            "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
        }).to_string()})
    }

    /// The inspector's own answer to `arguments`, run directly.
    fn direct(inspector: &Path, arguments: &[&str]) -> Vec<u8> {
        let output = Command::new(inspector)
            .args(arguments)
            .env_clear()
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0), "{output:?}");
        output.stdout
    }

    /// The single derived Artifact of `job`, read whole.
    fn derived(pipe: &str, job: &str) -> (String, Vec<u8>) {
        let owner = json!({"kind": "job", "id": job});
        let listed = answered(pipe, "artifact.list", json!({"owner": owner}));
        let items = listed["items"].as_array().unwrap();
        assert_eq!(items.len(), 1, "{listed}");
        let read = answered(
            pipe,
            "artifact.read",
            json!({"owner": owner, "artifactId": items[0]["artifactId"]}),
        );
        assert_eq!(read["eof"], true, "{read}");
        (
            items[0]["name"].as_str().unwrap().to_owned(),
            unbase64(read["base64"].as_str().unwrap()),
        )
    }

    fn unbase64(text: &str) -> Vec<u8> {
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut bytes = Vec::new();
        for chunk in text.trim_end_matches('=').as_bytes().chunks(4) {
            let digits: Vec<u32> = chunk
                .iter()
                .map(|c| ALPHABET.iter().position(|a| a == c).unwrap() as u32)
                .collect();
            let mut value = 0u32;
            for (index, digit) in digits.iter().enumerate() {
                value |= digit << (18 - 6 * index);
            }
            bytes.extend(&value.to_be_bytes()[1..digits.len()]);
        }
        bytes
    }

    fn described(pipe: &str, reference: &str) -> Value {
        answered(pipe, "operation.describe", json!({"reference": reference}))
    }

    fn the_configured_inspector_inspects_a_registered_project_across_a_restart() {
        let root = Root::new("inspect");
        // Registered, then composed by the next start.
        let mut first = Daemon::spawn(daemon(&root.0));
        let pipe = first.serving();
        let registered = answered(
            &pipe,
            "workspace.project.register",
            json!({"registrationRequestId": "workspace-provider-process", "kind": "openharmony",
                "root": root.project()}),
        )["projectRef"]
            .as_str()
            .unwrap()
            .to_owned();
        first.stop(&root.0);

        let mut second = {
            let mut command = daemon(&root.0);
            command.env("ARKDECK_WORKSPACE_INSPECTOR", root.inspector());
            Daemon::spawn(command)
        };
        let owners = second.line_starting("arkdeck-agentd owners: ");
        assert!(
            owners.contains(", workspaceProjects, workspaceOperations, bootstrap, "),
            "{owners}"
        );
        let pipe = second.serving();

        // The inspection is served; every profile-served read is not, for
        // the code-owned tools Windows does not trust yet.
        let inspect = described(&pipe, "workspace.inspect-source@1");
        assert_eq!(inspect["availability"], "available", "{inspect}");
        for reference in [
            "workspace.read-source-range@1",
            "workspace.inspect-git-status@1",
            "workspace.inspect-diff@1",
            "workspace.prepare-isolated-copy@1",
            "workspace.build-openharmony@1",
            "workspace.sign-openharmony-hap@1",
        ] {
            let operation = described(&pipe, reference);
            assert_eq!(operation["availability"], "unavailable", "{operation}");
            // A mutation is also refused for the mutation owner a development
            // root does not compose.
            assert!(
                operation["availabilityReasonCodes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|code| code == "provider_tool_unavailable"),
                "{operation}"
            );
            let reasons = operation["availabilityReasons"].to_string();
            assert!(reasons.contains(TOOLS_REASON), "{reference}: {reasons}");
        }

        let inspection = job_request(
            "inspect",
            "workspace.inspect-source",
            json!({"projectRef": registered, "symbol": "build", "fileScope": "*.ets"}),
        );
        let planned = answered(&pipe, "job.plan", inspection.clone());
        assert_eq!(
            planned["authorizationPolicy"], "defaultReadOnly",
            "{planned}"
        );
        assert_eq!(planned["effectiveEffect"], "hostOnly", "{planned}");
        let job = answered(&pipe, "job.submit", inspection.clone())["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        let ran = answered(&pipe, "job.run", json!({"jobId": job}));
        assert_eq!(ran["state"], "succeeded", "{ran}");
        let result = answered(&pipe, "job.result", json!({"jobId": job}));
        assert_eq!(result["evidence"]["status"], "verified", "{result}");
        let expected = direct(
            &root.inspector(),
            &[
                "-r",
                "-n",
                "--include",
                "*.ets",
                "--",
                "build",
                &root.project(),
            ],
        );
        assert!(
            String::from_utf8_lossy(&expected).contains("Index.ets:4:  build() {}"),
            "{}",
            String::from_utf8_lossy(&expected)
        );
        let (name, published) = derived(&pipe, &job);
        assert_eq!(name, "source-inspection.txt");
        let home = arkdeck_platform::runtime_home().unwrap_or_default();
        let redacted = if home.is_empty() {
            expected.clone()
        } else {
            String::from_utf8(expected.clone())
                .unwrap()
                .replace(&home, "<HOME>")
                .into_bytes()
        };
        assert_eq!(
            published,
            redacted,
            "{}",
            String::from_utf8_lossy(&published)
        );

        // A profile-served read is refused before anything is admitted.
        let refused = request(
            &pipe,
            "job.plan",
            job_request(
                "range",
                "workspace.read-source-range",
                json!({"projectRef": registered, "filePath": INDEX, "lineStart": 2,
                    "lineEnd": 4}),
            ),
        );
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(
            refused["error"]["details"]["newDispatchCount"], 0,
            "{refused}"
        );
        second.stop(&root.0);

        // After a restart the Job and its Artifact read back, and the same
        // request is the same Job.
        let mut third = {
            let mut command = daemon(&root.0);
            command.env("ARKDECK_WORKSPACE_INSPECTOR", root.inspector());
            Daemon::spawn(command)
        };
        let pipe = third.serving();
        let status = answered(&pipe, "job.status", json!({"jobId": job}));
        assert_eq!(status["state"], "succeeded", "{status}");
        assert_eq!(derived(&pipe, &job), (name, published));
        let again = answered(&pipe, "job.submit", inspection)["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(again, job);
        third.stop(&root.0);
    }

    fn an_inspector_that_is_no_executable_refuses_the_start() {
        let root = Root::new("refused");
        let not_executable = root.0.join("inspector.txt");
        std::fs::write(&not_executable, b"not a program").unwrap();
        let mut command = daemon(&root.0);
        command.env("ARKDECK_WORKSPACE_INSPECTOR", &not_executable);
        let output = command.output().unwrap();
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(
            stderr.contains("workspace inspector") && stderr.contains("nothing was started"),
            "{stderr}"
        );
    }
}
