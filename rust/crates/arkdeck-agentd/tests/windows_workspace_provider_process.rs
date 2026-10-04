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
//! * The project resolves to its profile through the code-owned tools of
//!   the ruling of 2026-10-04: the daemon's own image as grep, sed and patch,
//!   the trusted System32 `tar.exe` and Git for Windows. Inside a git working
//!   copy every profile-served read (`read-source-range`,
//!   `inspect-git-status`, `inspect-diff`), the isolated copy and the sweep
//!   run, each publishing exactly what its tool prints when run directly
//!   with the argv the provider built; the copy is adopted after a restart
//!   and destroyed by a wet sweep. Outside a working copy the git reads are
//!   unavailable and a plan of one is refused before admission with zero
//!   dispatch. The workspace mutations are the device-mutation authority's,
//!   which a development root does not hold.
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
        (
            "the_daemon_image_is_the_code_owned_grep_sed_and_patch",
            the_daemon_image_is_the_code_owned_grep_sed_and_patch,
        ),
        (
            "the_profile_served_reads_and_the_isolated_copy_run_through_the_code_owned_tools",
            the_profile_served_reads_and_the_isolated_copy_run_through_the_code_owned_tools,
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

        // The inspection is served, and so is every read of the profile the
        // project resolved to; it is no git working copy, so the git reads
        // are not.
        for reference in [
            "workspace.inspect-source@1",
            "workspace.read-source-range@1",
            "workspace.prepare-isolated-copy@1",
        ] {
            let operation = described(&pipe, reference);
            assert_eq!(operation["availability"], "available", "{operation}");
        }
        for reference in ["workspace.inspect-git-status@1", "workspace.inspect-diff@1"] {
            let operation = described(&pipe, reference);
            assert_eq!(operation["availability"], "unavailable", "{operation}");
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

        // A read the profile does not offer is refused before anything is
        // admitted.
        let refused = request(
            &pipe,
            "job.plan",
            job_request(
                "status",
                "workspace.inspect-git-status",
                json!({"projectRef": registered}),
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

    /// `arkdeck-agentd --workspace-tool <tool> <argv>`, with no environment
    /// and no stdin as the workspace dispatch runs it, answers exactly what
    /// the reimplemented tool answers, and its tree is the one the tool left.
    fn the_daemon_image_is_the_code_owned_grep_sed_and_patch() {
        let root = Root::new("tools");
        let project = root.project();
        let index = format!("{project}\\entry\\src\\main\\ets\\pages\\Index.ets");
        let patch_file = root.0.join("change.patch");
        std::fs::write(
            &patch_file,
            "--- a/entry/src/main/ets/pages/Index.ets\n+++ b/entry/src/main/ets/pages/Index.ets\n@@ -3,3 +3,3 @@\n struct Index {\n-  build() {}\n+  build() { }\n }\n",
        )
        .unwrap();
        let patch_file = patch_file.to_str().unwrap().to_owned();
        for (tool, arguments) in [
            ("sed", vec!["-n", "2,4p", index.as_str()]),
            (
                "grep",
                vec![
                    "-r",
                    "-n",
                    "--include",
                    "*.ets",
                    "--",
                    "build",
                    project.as_str(),
                ],
            ),
            (
                "patch",
                vec![
                    "-f",
                    "-p1",
                    "-d",
                    project.as_str(),
                    "-i",
                    patch_file.as_str(),
                ],
            ),
            ("sed", vec!["-n", "4,4p", index.as_str()]),
            ("sed", vec!["-n", "1,1p", "Z:\\no\\such\\file"]),
        ] {
            // The reimplementation's answer first, over a copy of the tree,
            // when the tool writes.
            let expected = if tool == "patch" {
                let copy = root.0.join("copy");
                std::fs::create_dir_all(copy.join("entry/src/main/ets/pages")).unwrap();
                std::fs::copy(&index, copy.join("entry/src/main/ets/pages/Index.ets")).unwrap();
                let copy = copy.to_str().unwrap().to_owned();
                let mut moved: Vec<String> = arguments.iter().map(|&a| a.to_owned()).collect();
                moved[3] = copy;
                arkdeck_hoststore::run_text_tool(tool, &moved)
            } else {
                arkdeck_hoststore::run_text_tool(
                    tool,
                    &arguments.iter().map(|&a| a.to_owned()).collect::<Vec<_>>(),
                )
            };
            let output = Command::new(DAEMON)
                .arg(arkdeck_hoststore::WORKSPACE_TOOL_FLAG)
                .arg(tool)
                .args(&arguments)
                .env_clear()
                .stdin(Stdio::null())
                .output()
                .unwrap();
            assert_eq!(
                output.status.code(),
                Some(expected.status),
                "{tool} {arguments:?}"
            );
            assert_eq!(output.stdout, expected.stdout, "{tool} {arguments:?}");
            assert_eq!(output.stderr, expected.stderr, "{tool} {arguments:?}");
        }
        // The patch was applied in place, and the second read shows it.
        assert_eq!(
            std::fs::read_to_string(&index).unwrap(),
            INDEX_SOURCE.replace("build() {}", "build() { }")
        );
        let refused = Command::new(DAEMON)
            .args([arkdeck_hoststore::WORKSPACE_TOOL_FLAG, "awk"])
            .env_clear()
            .output()
            .unwrap();
        assert_eq!(refused.status.code(), Some(2), "{refused:?}");
    }

    fn git(project: &str, arguments: &[&str]) {
        let tool =
            arkdeck_platform::trusted_system_tool(arkdeck_platform::SystemTool::Git).unwrap();
        let output = Command::new(&tool.path)
            .arg("-C")
            .arg(project)
            .args(arguments)
            .env_clear()
            .envs([
                ("GIT_CONFIG_NOSYSTEM", "1"),
                ("GIT_AUTHOR_NAME", "Process"),
                ("GIT_AUTHOR_EMAIL", "process@invalid.example"),
                ("GIT_COMMITTER_NAME", "Process"),
                ("GIT_COMMITTER_EMAIL", "process@invalid.example"),
            ])
            .output()
            .unwrap();
        assert!(output.status.success(), "git {arguments:?}: {output:?}");
    }

    /// Swift `workspaceRevision(root:profileVersion:globs:)` of a git working
    /// copy: HEAD's object id (a symbolic HEAD's loose ref), the index file's
    /// digest and every scoped file's digest, in name order.
    fn workspace_revision(project: &str, files: &[&str]) -> String {
        let git = Path::new(project).join(".git");
        let head = std::fs::read_to_string(git.join("HEAD")).unwrap();
        let head = head.trim();
        let oid = match head.strip_prefix("ref: ") {
            Some(reference) => std::fs::read_to_string(git.join(reference))
                .unwrap()
                .trim()
                .to_owned(),
            None => head.to_owned(),
        };
        let index = arkdeck_contract::sha256_hex(&std::fs::read(git.join("index")).unwrap());
        let mut material =
            format!("profileVersion\twaterflow-openharmony@1\nhead\t{oid}\nindex\t{index}\n");
        for file in files {
            let bytes = std::fs::read(Path::new(project).join(file)).unwrap();
            material.push_str(&format!(
                "file\t{file}\t{}\n",
                arkdeck_contract::sha256_hex(&bytes)
            ));
        }
        arkdeck_contract::sha256_hex(material.as_bytes())
    }

    /// The trusted git as the workspace dispatch runs it: no system
    /// configuration, the clean base environment.
    fn git_output(project: &str, arguments: &[&str]) -> Vec<u8> {
        let tool =
            arkdeck_platform::trusted_system_tool(arkdeck_platform::SystemTool::Git).unwrap();
        let mut command = Command::new(&tool.path);
        command
            .arg("-C")
            .arg(project)
            .args(arguments)
            .env_clear()
            .env("GIT_CONFIG_NOSYSTEM", "1");
        for key in ["PATH", "SystemRoot", "WINDIR"] {
            if let Some(value) = std::env::var_os(key) {
                command.env(key, value);
            }
        }
        let output = command.stdin(Stdio::null()).output().unwrap();
        assert!(output.status.success(), "git {arguments:?}: {output:?}");
        output.stdout
    }

    /// One Job of `operation` run to its end: its status and evidence.
    fn run_job(pipe: &str, label: &str, operation: &str, inputs: Value) -> (Value, Value) {
        let request = job_request(label, operation, inputs);
        let planned = answered(pipe, "job.plan", request.clone());
        assert_eq!(planned["authorizationPolicy"], "defaultReadOnly", "{label}");
        assert_eq!(planned["effectiveEffect"], "hostOnly", "{label}");
        let job = answered(pipe, "job.submit", request)["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        let ran = answered(pipe, "job.run", json!({"jobId": job}));
        let result = answered(pipe, "job.result", json!({"jobId": job}));
        (ran, result)
    }

    /// The trusted system tools and the daemon's own image are the
    /// code-owned tools: a registered OpenHarmony project inside a git
    /// working copy resolves to its profile, and every profile-served read,
    /// the isolated copy and the sweep run, each publishing exactly what its
    /// tool prints when run directly with the argv the provider built.
    fn the_profile_served_reads_and_the_isolated_copy_run_through_the_code_owned_tools() {
        let root = Root::new("lanes");
        let project = root.project();
        git(&project, &["init", "--quiet"]);
        git(&project, &["add", "-A"]);
        git(&project, &["commit", "--quiet", "-m", "base"]);
        let mut first = Daemon::spawn(daemon(&root.0));
        let pipe = first.serving();
        let registered = answered(
            &pipe,
            "workspace.project.register",
            json!({"registrationRequestId": "workspace-lanes", "kind": "openharmony",
                "root": project}),
        )["projectRef"]
            .as_str()
            .unwrap()
            .to_owned();
        first.stop(&root.0);

        let mut second = Daemon::spawn(daemon(&root.0));
        let pipe = second.serving();
        let shown = answered(
            &pipe,
            "workspace.project.show",
            json!({"projectRef": registered}),
        );
        assert_eq!(shown["configurationStatus"], "active", "{shown}");
        assert_eq!(shown["availability"], "available", "{shown}");
        for reference in [
            "workspace.read-source-range@1",
            "workspace.inspect-git-status@1",
            "workspace.inspect-diff@1",
            "workspace.prepare-isolated-copy@1",
            "workspace.sweep-isolated-copies@1",
        ] {
            let operation = described(&pipe, reference);
            assert_eq!(operation["availability"], "available", "{operation}");
        }
        // A workspace mutation is the device-mutation authority's, which a
        // development root does not hold (as the macOS isolated owner
        // without its acknowledged authority).
        for reference in [
            "workspace.apply-patch@1",
            "workspace.revert-patch@1",
            "workspace.create-checkpoint@1",
        ] {
            let operation = described(&pipe, reference);
            assert_eq!(operation["availability"], "unavailable", "{operation}");
            assert_eq!(
                operation["availabilityReasons"],
                json!(["runtime.mutationOwnerUnavailable"]),
                "{operation}"
            );
        }

        // The isolated copy of the committed tree, then an edit.
        let scoped = [
            "entry/src/main/ets/pages/Index.ets",
            "entry/src/main/ets/pages/Other.txt",
        ];
        let revision = workspace_revision(&project, &scoped);
        let (ran, copied) = run_job(
            &pipe,
            "copy",
            "workspace.prepare-isolated-copy",
            json!({"projectRef": registered, "allowedFileGlobs": ["entry/src/main/ets/**"],
                "expectedWorkspaceRevision": revision}),
        );
        let timeline = std::fs::read_to_string(
            root.0
                .join("jobs-state")
                .join("jobs")
                .join(ran["jobId"].as_str().unwrap())
                .join("job-record.json"),
        )
        .unwrap_or_default();
        assert_eq!(ran["outcome"], "succeeded", "{ran} {timeline}");
        assert_eq!(copied["evidence"]["status"], "verified", "{copied}");
        let copies = root.0.join("evolution-workspaces");
        let tasks: Vec<PathBuf> = std::fs::read_dir(&copies)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(tasks.len(), 1, "{tasks:?}");
        let copied_index = tasks[0]
            .join("workspace")
            .join("entry/src/main/ets/pages/Index.ets");
        assert_eq!(
            std::fs::read_to_string(&copied_index).unwrap(),
            INDEX_SOURCE
        );
        std::fs::write(
            Path::new(&project).join(INDEX),
            format!("{INDEX_SOURCE}// edited\n"),
        )
        .unwrap();

        let index = format!("{project}\\entry\\src\\main\\ets\\pages\\Index.ets");
        let sed =
            arkdeck_hoststore::run_text_tool("sed", &["-n", "2,4p", &index].map(str::to_owned));
        for (label, operation, inputs, expected) in [
            (
                "range",
                "workspace.read-source-range",
                json!({"projectRef": registered, "filePath": INDEX, "lineStart": 2,
                    "lineEnd": 4}),
                sed.stdout,
            ),
            (
                "status",
                "workspace.inspect-git-status",
                json!({"projectRef": registered}),
                git_output(
                    &project,
                    &[
                        "-C",
                        &project,
                        "status",
                        "--porcelain=v1",
                        "--untracked-files=all",
                        "--",
                        ".",
                    ],
                ),
            ),
            (
                "diff",
                "workspace.inspect-diff",
                json!({"projectRef": registered, "baseRevision": "HEAD",
                    "pathScope": "entry"}),
                git_output(
                    &project,
                    &["-C", &project, "diff", "--stat", "HEAD", "--", "entry"],
                ),
            ),
        ] {
            assert!(!expected.is_empty(), "{label}: the tool answers");
            let (ran, result) = run_job(&pipe, label, operation, inputs);
            assert_eq!(ran["outcome"], "succeeded", "{label}: {ran}");
            assert_eq!(
                result["evidence"]["status"], "verified",
                "{label}: {result}"
            );
            let job = ran["jobId"].as_str().unwrap();
            assert_eq!(derived(&pipe, job).1, expected, "{label}");
        }
        second.stop(&root.0);

        // After a restart the copy is adopted again, and a wet sweep with no
        // quiescence or retention destroys it, keeping its manifest.
        let mut third = Daemon::spawn(daemon(&root.0));
        let pipe = third.serving();
        assert!(
            !third
                .seen
                .iter()
                .any(|line| line.starts_with("runtime workspace not adopted")),
            "{:?}",
            third.seen
        );
        let (ran, swept) = run_job(
            &pipe,
            "sweep",
            "workspace.sweep-isolated-copies",
            json!({"dryRun": false, "minimumQuiescentSeconds": 0, "retainLatestCount": 0}),
        );
        assert_eq!(ran["outcome"], "succeeded", "{ran}");
        assert_eq!(swept["evidence"]["status"], "verified", "{swept}");
        assert!(
            !tasks[0].join("workspace").exists(),
            "the copy is destroyed"
        );
        assert!(
            tasks[0].join("workspace.json").exists(),
            "its manifest is kept"
        );
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
