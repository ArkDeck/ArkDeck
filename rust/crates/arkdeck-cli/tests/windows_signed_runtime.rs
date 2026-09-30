//! The Windows CLI against a Runtime it authenticates over the named pipe
//! (TASK-XPA-018): the leaves the Windows daemon answers, run end to end, and
//! a console Ctrl+Break of a waiting leaf.
//!
//! The CLI sends no frame to a daemon whose image is not the pinned path or
//! whose Authenticode signer is not the pinned certificate (XPA-AC-6), and
//! nothing here relaxes that. Each server is instead a copy signed with the
//! development certificate this host trusts
//! (`rust/scripts/windows-dev-identity.ps1`, design §L.1 item 22), named by
//! `ARKDECK_DEV_SIGNER_THUMBPRINT`; without one every check here is skipped
//! with a message, as the unsigned refusal is already held by
//! `check-readonly.py`.
//!
//! - The real daemon (`arkdeck-agentd`, built beside the CLI), signed, on a
//!   private pipe with every other `ARKDECK_`/`OHOS_HDC_` input removed:
//!   `doctor`, `doctor --deep`, `operation list` and `device candidates` are
//!   answered as `check-readonly.py`'s signed matrix records them, and
//!   `runtime health`, `operation describe`, `example` and `validate` answer
//!   `observe.device@1`'s contract (its Catalog entry, a submittable request,
//!   its empty typed inputs valid) with nothing dispatched.
//! - The same daemon over a development root holding a recorded Target
//!   (`rust/tests/fixtures/target-adoption`) and a project directory: every
//!   leaf in `WINDOWS_MEASURED_LEAVES` beyond `doctor` and `operation list`
//!   is run through the CLI and answers its complete contract (`target
//!   list|show|display-name set|clear`, `workspace project
//!   register|list|show`, `workspace preset list|show`, `trace cache
//!   status`), and what they wrote is read back after a restart. Each of
//!   their coverage entries must be Windows `implemented` in
//!   `openspec/contracts/cli-feature-coverage.json`.
//! - A fake Runtime, which is this binary itself run as
//!   `<exe> --fake-runtime <pipe>` (a `harness = false` target, so nothing but
//!   its own lines reach its streams), serving `job watch` the same recorded
//!   event page on every read. Once it has served a read, the CLI, started in
//!   a process group of its own, is sent `CTRL_BREAK_EVENT` (Ctrl+C cannot be
//!   targeted at one group). It must stop waiting and end as the Unix latch
//!   ends it: the `clientInterrupted` terminal line, exit status 130, and no
//!   request but the reads it was already making.
//!
//! Every process here is started by this test and ended by it; no other
//! process is signalled, and nothing installed is read or written.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments
        .get(1)
        .is_some_and(|flag| flag == "--fake-runtime")
    {
        windows::fake_runtime(&arguments[2]);
    }
    windows::run_tests();
}

#[cfg(windows)]
mod windows {
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use arkdeck_platform::{LocalEndpoint, LocalListener};
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Write};
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc::{self, Receiver};
    use std::time::Duration;

    const CLI: &str = env!("CARGO_BIN_EXE_arkdeck");
    const JOB: &str = "job-2b395b58efa418650be51432f3a2c9b0";
    /// A bound on every wait, so that a broken CLI fails the test rather than
    /// hanging it; never how the test learns that something has happened.
    const BOUND: Duration = Duration::from_secs(60);
    /// `CREATE_NEW_PROCESS_GROUP`: the child's id names a console group of
    /// its own, which Ctrl+Break can be sent to alone.
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

    // ---- the fake Runtime ------------------------------------------------

    /// One recorded event row (`Fixtures/ControlFrames/job.events.jsonl`),
    /// re-positioned, as `job_watch.rs` serves it.
    fn row(position: i64, id: &str) -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.events.jsonl",
        );
        let mut row = std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]["items"]
                        .as_array()
                        .is_some_and(|items| !items.is_empty())
            })
            .expect("a recorded event page")["result"]["items"][0]
            .clone();
        row["eventId"] = json!(id);
        row["streamPosition"] = json!(position.to_string());
        row["runtimeRevision"] = json!("2");
        row["cursor"] = json!(format!("cursor-{id}"));
        row
    }

    /// Serves health and then one request on each connection, answering
    /// every `job.events` read with the same page, until it is ended. Each
    /// request's method is written to stdout once it has been answered.
    pub fn fake_runtime(pipe: &str) -> ! {
        let page = json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"eventStream",
            "order":"streamPositionAsc","items":[row(1, "e1"), row(2, "e2")],
            "snapshotRevision":"2","hasMore":false,"nextCursor":"page-a"});
        let health = json!({"ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
            "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],
            "publishedMethods":METHODS}});
        let mut listener = LocalListener::bind(&LocalEndpoint::new(pipe)).unwrap();
        println!("listening");
        std::io::stdout().flush().unwrap();
        loop {
            let connection = listener.accept().unwrap();
            let mut reader = BufReader::new(connection);
            for _ in 0..2 {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                let method = request["method"].as_str().unwrap_or_default().to_owned();
                let mut answer = match method.as_str() {
                    "health" => health.clone(),
                    "job.events" => json!({"ok":true,"result":page}),
                    _ => {
                        json!({"ok":false,"error":{"code":"invalidRequest","message":"unexpected"}})
                    }
                };
                answer["id"] = request["id"].clone();
                if writeln!(reader.get_mut(), "{answer}").is_err() {
                    break;
                }
                println!("{method}");
                std::io::stdout().flush().unwrap();
            }
        }
    }

    // ---- the runner ------------------------------------------------------

    pub fn run_tests() {
        let Some(thumbprint) = std::env::var("ARKDECK_DEV_SIGNER_THUMBPRINT")
            .ok()
            .filter(|value| !value.is_empty())
        else {
            println!(
                "skipped: ARKDECK_DEV_SIGNER_THUMBPRINT names no host-trusted development \
                 signer (rust/scripts/windows-dev-identity.ps1 create); the Windows CLI \
                 authenticates only a signed daemon"
            );
            return;
        };
        for (name, test) in [
            (
                "daemon_answered_leaves_run_end_to_end_through_the_pipe",
                daemon_answered_leaves_run_end_to_end_through_the_pipe as fn(&str),
            ),
            (
                "measured_owner_leaves_answer_their_contract_through_the_pipe",
                measured_owner_leaves_answer_their_contract_through_the_pipe,
            ),
            (
                "ctrl_break_ends_a_waiting_watch_with_the_interrupted_envelope",
                ctrl_break_ends_a_waiting_watch_with_the_interrupted_envelope,
            ),
        ] {
            println!("test {name} ...");
            test(&thumbprint);
            println!("test {name} ... ok");
        }
    }

    /// A fresh private directory below the temporary directory, removed
    /// afterwards.
    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("ad-clisigned-{}", nonce()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn nonce() -> String {
        format!(
            "{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        )
    }

    /// PowerShell 7, which the signing script needs.
    fn pwsh() -> PathBuf {
        let on_path = std::env::var_os("PATH").and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|directory| directory.join("pwsh.exe"))
                .find(|candidate| candidate.is_file())
        });
        on_path.unwrap_or_else(|| {
            let alias = PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap())
                .join(r"Microsoft\WindowsApps\pwsh.exe");
            assert!(alias.exists(), "PowerShell 7 is required to sign the copy");
            alias
        })
    }

    /// `source` copied into `directory` and signed with the development
    /// certificate: its path and the signer pin the CLI is given.
    fn signed_copy(source: &Path, directory: &Directory, thumbprint: &str) -> (PathBuf, String) {
        let copy = directory.0.join(source.file_name().unwrap());
        std::fs::copy(source, &copy).unwrap_or_else(|error| {
            panic!(
                "{} ({error}): run the workspace tests, or `cargo build -p arkdeck-agentd` \
                 before testing this crate alone",
                source.display()
            )
        });
        // A plain drive path: PowerShell cannot authorize a script named by
        // a verbatim (`\\?\`) path, which is what `canonicalize` returns.
        let script = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .unwrap()
            .join(r"scripts\windows-dev-identity.ps1");
        let output = Command::new(pwsh())
            .args(["-NoProfile", "-NonInteractive", "-File"])
            .arg(&script)
            .args(["sign", "-Thumbprint", thumbprint, "-Path"])
            .arg(&copy)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "signing failed: {output:?}");
        let signed: Value = serde_json::from_slice(&output.stdout).unwrap();
        (copy, signed["pin"].as_str().unwrap().to_owned())
    }

    /// A server this test started, its stdout read line by line; ended with
    /// the test however it ends.
    struct Server {
        child: Child,
        lines: Receiver<String>,
    }

    impl Server {
        fn start(mut command: Command) -> Self {
            for (key, _) in std::env::vars_os() {
                let upper = key.to_string_lossy().to_ascii_uppercase();
                if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
                    command.env_remove(key);
                }
            }
            let mut child = command
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
            Self { child, lines }
        }

        /// Every line up to the first that starts with `prefix`.
        fn line_starting(&self, prefix: &str) -> Vec<String> {
            let mut seen = Vec::new();
            loop {
                match self.lines.recv_timeout(BOUND) {
                    Ok(line) => {
                        let found = line.starts_with(prefix);
                        seen.push(line);
                        if found {
                            return seen;
                        }
                    }
                    Err(error) => panic!("no line starting {prefix:?} ({error}): {seen:?}"),
                }
            }
        }

        /// Ends it, and every line it wrote that was not read yet.
        fn end(mut self) -> Vec<String> {
            let _ = self.child.kill();
            let _ = self.child.wait();
            self.lines.try_iter().collect()
        }
    }

    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    /// The CLI against `pipe`, authenticating `daemon` by `pin`.
    fn cli(pipe: &str, daemon: &Path, pin: &str) -> Command {
        let mut command = Command::new(CLI);
        for (key, _) in std::env::vars_os() {
            if key
                .to_string_lossy()
                .to_ascii_uppercase()
                .starts_with("ARKDECK_")
            {
                command.env_remove(key);
            }
        }
        command
            .env("ARKDECK_ENDPOINT", pipe)
            .env("ARKDECK_DAEMON_PATH", daemon)
            .env("ARKDECK_DAEMON_SIGNER_SHA256", pin)
            .stdin(Stdio::null());
        command
    }

    fn daemon_answered_leaves_run_end_to_end_through_the_pipe(thumbprint: &str) {
        let directory = Directory::new();
        let (daemon, pin) = signed_copy(
            &Path::new(CLI).with_file_name("arkdeck-agentd.exe"),
            &directory,
            thumbprint,
        );
        // An isolated development root: the daemon announces its pipe once
        // it is serving, and stops for its root's stop request.
        let root = directory.0.join("root");
        std::fs::create_dir(&root).unwrap();
        let mut command = Command::new(&daemon);
        command.env("ARKDECK_DEVELOPMENT_STATE_ROOT", &root);
        let mut server = Server::start(command);
        let pipe = server
            .line_starting("arkdeck-agentd listening on ")
            .pop()
            .unwrap()
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned();
        let inputs = directory.0.join("inputs.json");
        std::fs::write(&inputs, b"{}").unwrap();
        let inputs = inputs.to_str().unwrap();
        let observe = ["--operation", "observe.device@1"];
        for (argv, code, error) in [
            (&["doctor"][..], 0, None),
            (&["doctor", "--deep"][..], 0, None),
            (&["runtime", "health"][..], 0, None),
            (&["operation", "list"][..], 0, None),
            (
                &[&["operation", "describe"][..], &observe].concat()[..],
                0,
                None,
            ),
            (
                &[&["operation", "example"][..], &observe].concat()[..],
                0,
                None,
            ),
            (
                &[
                    &["operation", "validate"][..],
                    &observe,
                    &["--inputs-file", inputs],
                ]
                .concat()[..],
                0,
                None,
            ),
            // No registered HDC tuple on Windows: the observation owner
            // refuses, structured, and nothing is observed.
            (&["device", "candidates"][..], 1, Some("operationFailed")),
        ] {
            let output = cli(&pipe, &daemon, &pin)
                .args(argv)
                .args(["--output", "json"])
                .output()
                .unwrap();
            let envelope: Value = serde_json::from_slice(&output.stdout)
                .unwrap_or_else(|_| panic!("{argv:?}: {output:?}"));
            assert_eq!(output.status.code(), Some(code), "{argv:?}: {envelope}");
            assert_eq!(envelope["ok"], error.is_none(), "{argv:?}: {envelope}");
            match error {
                None => assert!(!envelope["result"].is_null(), "{argv:?}: {envelope}"),
                Some(error) => assert_eq!(envelope["error"]["code"], error, "{envelope}"),
            }
            match argv[..argv.len().min(2)] {
                ["runtime", "health"] => {
                    assert_eq!(envelope["result"]["contractIdentity"], CONTRACT_IDENTITY);
                    assert_eq!(envelope["result"]["catalogDigest"], CATALOG_DIGEST);
                    assert_eq!(envelope["result"]["publishedMethods"], json!(METHODS));
                }
                ["operation", "describe"] => {
                    assert_eq!(envelope["result"]["reference"], "observe.device@1");
                }
                ["operation", "example"] => {
                    assert_eq!(
                        envelope["result"]["operation"],
                        json!({"id": "observe.device", "version": 1})
                    );
                }
                ["operation", "validate"] => {
                    assert_eq!(envelope["result"]["structurallyValid"], true, "{envelope}");
                    assert_eq!(envelope["result"]["findings"], json!([]), "{envelope}");
                }
                _ => {}
            }
            if argv == ["operation", "list"] {
                let operations = envelope["result"].as_array().unwrap();
                assert!(!operations.is_empty(), "{envelope}");
                assert!(
                    operations
                        .iter()
                        .all(|operation| operation["reference"].is_string())
                );
            }
        }
        // A pin the server's signer does not match is refused before any
        // frame: the pin is what these answers rested on.
        let refused = cli(&pipe, &daemon, &"0".repeat(64))
            .args(["doctor", "--output", "json"])
            .output()
            .unwrap();
        assert_eq!(refused.status.code(), Some(69), "{refused:?}");
        let refused: Value = serde_json::from_slice(&refused.stdout).unwrap();
        assert_eq!(refused["error"]["code"], "runtimeUnavailable", "{refused}");
        // Stopped by its own stop request, as the restart hop stops it.
        let scope = arkdeck_platform::StateRoot::development(&root)
            .unwrap()
            .scope()
            .unwrap();
        scope.request_stop(server.child.id()).unwrap();
        server.line_starting("arkdeck-agentd stopped");
        let status = server.child.wait().unwrap();
        assert!(status.success(), "{status:?}");

        // What this measured is what the coverage manifest counts.
        for leaf in [
            "health",
            "operation.describe",
            "operation.example",
            "operation.validate",
        ] {
            let statuses = windows_statuses(leaf);
            assert!(
                !statuses.is_empty() && statuses.iter().all(|status| status == "implemented"),
                "{leaf}: {statuses:?}"
            );
        }
    }

    /// The daemon over its development root, started and serving: its pipe.
    fn serve(daemon: &Path, root: &Path) -> (Server, String) {
        let mut command = Command::new(daemon);
        command.env("ARKDECK_DEVELOPMENT_STATE_ROOT", root);
        let server = Server::start(command);
        let pipe = server
            .line_starting("arkdeck-agentd listening on ")
            .pop()
            .unwrap()
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned();
        (server, pipe)
    }

    /// Stopped by its root's stop request, as the restart hop stops it.
    fn stop(mut server: Server, root: &Path) {
        let scope = arkdeck_platform::StateRoot::development(root)
            .unwrap()
            .scope()
            .unwrap();
        scope.request_stop(server.child.id()).unwrap();
        server.line_starting("arkdeck-agentd stopped");
        let status = server.child.wait().unwrap();
        assert!(status.success(), "{status:?}");
    }

    /// One CLI leaf that must answer: its result.
    fn answered(pipe: &str, daemon: &Path, pin: &str, argv: &[&str]) -> Value {
        let output = cli(pipe, daemon, pin)
            .args(argv)
            .args(["--output", "json"])
            .output()
            .unwrap();
        let envelope: Value = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|_| panic!("{argv:?}: {output:?}"));
        assert_eq!(output.status.code(), Some(0), "{argv:?}: {envelope}");
        assert_eq!(envelope["ok"], true, "{argv:?}: {envelope}");
        envelope["result"].clone()
    }

    /// The Windows status of the coverage entry of the daemon method `leaf`
    /// fronts, in the coverage manifest this CLI renders. That is the product
    /// `maintainer contracts export` writes, which `tests/machine_contracts.rs`
    /// holds to the committed `openspec/contracts/cli-feature-coverage.json`.
    /// It is read from the build rather than the checkout, because
    /// check-contracts' views copy `rust/` without `openspec/`.
    fn windows_statuses(leaf: &str) -> Vec<String> {
        let product = arkdeck_cli::machine_contracts::contract_products()
            .into_iter()
            .find(|product| product.relative_path == "cli-feature-coverage.json")
            .expect("the CLI renders its feature coverage");
        let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
        coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == leaf)
            .map(|entry| {
                entry["implementationStatusByPlatform"]["windows"]
                    .as_str()
                    .unwrap_or("unset")
                    .to_owned()
            })
            .collect()
    }

    fn measured_owner_leaves_answer_their_contract_through_the_pipe(thumbprint: &str) {
        const TARGET: &str = "TGT-3ba3f5f43b92";
        let directory = Directory::new();
        let (daemon, pin) = signed_copy(
            &Path::new(CLI).with_file_name("arkdeck-agentd.exe"),
            &directory,
            thumbprint,
        );
        // A development root named as the disk names it (a workspace root
        // must be that spelling), holding the Swift adoption oracle's Target.
        let canonical = std::fs::canonicalize(&directory.0).unwrap();
        let canonical = canonical.to_str().unwrap();
        let base = PathBuf::from(canonical.strip_prefix(r"\\?\").unwrap_or(canonical));
        let root = base.join("root");
        std::fs::create_dir(&root).unwrap();
        arkdeck_platform::HostDirectory::open_or_create_private(&root.join("targets-state"))
            .unwrap();
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/target-adoption/targets-state/targets.json"),
            root.join("targets-state").join("targets.json"),
        )
        .unwrap();
        let project = base.join("project");
        std::fs::create_dir(&project).unwrap();
        let project = project.to_str().unwrap().to_owned();

        let (server, pipe) = serve(&daemon, &root);
        let run = |argv: &[&str]| answered(&pipe, &daemon, &pin, argv);
        let listed = run(&["target", "list"]);
        assert_eq!(listed[0]["targetId"], TARGET, "{listed}");
        let shown = run(&["target", "show", "--target", TARGET]);
        assert_eq!(shown["targetId"], TARGET, "{shown}");
        let named = run(&[
            "target",
            "display-name",
            "set",
            "--target",
            TARGET,
            "--expected-generation",
            "1",
            "--name",
            "Bench",
        ]);
        assert_eq!(named["generation"], "2", "{named}");
        let registered = run(&[
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "request-measured",
            "--kind",
            "openharmony",
            "--root",
            &project,
        ]);
        let reference = registered["projectRef"].as_str().unwrap().to_owned();
        assert_eq!(
            run(&["workspace", "project", "list"])["projects"],
            json!([registered])
        );
        assert_eq!(
            run(&["workspace", "project", "show", "--project", &reference]),
            registered
        );
        assert_eq!(
            run(&["workspace", "preset", "list", "--project", &reference])["presets"],
            json!([])
        );
        // A symbol preset pins no toolchain or credential, so it registers
        // on Windows and its projection can be shown.
        let preset = run(&[
            "workspace",
            "preset",
            "register",
            "--registration-request-id",
            "preset-measured",
            "--project",
            &reference,
            "--kind",
            "symbol",
            "--template",
            "openharmony.arkts-symbol@1",
            "--timeout-seconds",
            "600",
            "--relative-source-map",
            "entry/build/sourceMaps.map",
        ]);
        let preset_ref = preset["presetRef"].as_str().unwrap().to_owned();
        let status = run(&["trace", "cache", "status"]);
        assert_eq!(status["schemaVersion"], "arkdeck.trace-cache-status/1");
        assert_eq!(status["entryCount"], 0, "{status}");
        stop(server, &root);

        // Restarted over the same root: every write is read back.
        let (server, pipe) = serve(&daemon, &root);
        let run = |argv: &[&str]| answered(&pipe, &daemon, &pin, argv);
        assert_eq!(
            run(&["target", "show", "--target", TARGET])["displayName"],
            "Bench"
        );
        let cleared = run(&[
            "target",
            "display-name",
            "clear",
            "--target",
            TARGET,
            "--expected-generation",
            "2",
        ]);
        assert_eq!(cleared["generation"], "3", "{cleared}");
        assert_eq!(
            run(&["workspace", "project", "show", "--project", &reference]),
            registered
        );
        assert_eq!(
            run(&[
                "workspace",
                "preset",
                "show",
                "--project",
                &reference,
                "--preset",
                &preset_ref,
            ]),
            preset
        );
        assert_eq!(
            run(&["workspace", "preset", "list", "--project", &reference])["presets"],
            json!([preset])
        );
        stop(server, &root);

        // What this measured is what the coverage manifest counts.
        for leaf in [
            "target.list",
            "target.show",
            "target.display-name.set",
            "target.display-name.clear",
            "workspace.project.register",
            "workspace.project.list",
            "workspace.project.show",
            "workspace.preset.list",
            "workspace.preset.show",
            "trace.cache.status",
        ] {
            let statuses = windows_statuses(leaf);
            assert!(
                !statuses.is_empty() && statuses.iter().all(|status| status == "implemented"),
                "{leaf}: {statuses:?}"
            );
        }
    }

    fn ctrl_break_ends_a_waiting_watch_with_the_interrupted_envelope(thumbprint: &str) {
        let directory = Directory::new();
        let (fake, pin) = signed_copy(&std::env::current_exe().unwrap(), &directory, thumbprint);
        let pipe = format!(r"\\.\pipe\arkdeck-cli-watch-{}", nonce());
        let mut command = Command::new(&fake);
        command.args(["--fake-runtime", &pipe]);
        let server = Server::start(command);
        server.line_starting("listening");

        let mut watch = cli(&pipe, &fake, &pin)
            .args([
                "job",
                "watch",
                "--job",
                JOB,
                "--output",
                "jsonl",
                "--timeout",
                "120s",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .unwrap();
        // The latch is installed before the first read: once a read has been
        // answered, the watch is waiting.
        server.line_starting("job.events");
        arkdeck_platform::send_console_break(watch.id()).unwrap();

        let (sender, done) = mpsc::channel();
        let stdout = watch.stdout.take().unwrap();
        let stderr = watch.stderr.take().unwrap();
        std::thread::spawn(move || {
            let mut out = Vec::new();
            let mut err = Vec::new();
            let _ = std::io::Read::read_to_end(&mut { stdout }, &mut out);
            let _ = std::io::Read::read_to_end(&mut { stderr }, &mut err);
            let _ = sender.send((out, err));
        });
        let Ok((stdout, stderr)) = done.recv_timeout(BOUND) else {
            let _ = watch.kill();
            panic!("the watch never ended after Ctrl+Break");
        };
        let status = watch.wait().unwrap();
        // Recorded, not acted on: the default handler would have ended it
        // with STATUS_CONTROL_C_EXIT and no terminal line.
        assert_eq!(
            status.code(),
            Some(130),
            "{status:?} {}",
            String::from_utf8_lossy(&stderr)
        );
        let lines: Vec<Value> = String::from_utf8_lossy(&stdout)
            .lines()
            .map(|line| serde_json::from_str(line).expect("one document per line"))
            .collect();
        // The stop is seen at the watch's next look: after the first row,
        // after the second, or at a pause. Which one is the host's timing;
        // what it wrote before is always a prefix of the page, and the
        // terminal line names the resume point it actually delivered.
        let (terminal, rows) = lines.split_last().expect("a terminal line");
        assert!(!rows.is_empty() && rows.len() <= 2, "{lines:?}");
        for (row, id) in rows.iter().zip(["e1", "e2"]) {
            assert_eq!(row["eventId"], id, "{lines:?}");
        }
        assert_eq!(terminal["type"], "terminal");
        assert_eq!(terminal["ok"], false);
        assert_eq!(terminal["exitCode"], 130);
        assert_eq!(terminal["lastCursor"], rows.last().unwrap()["cursor"]);
        assert_eq!(terminal["error"]["code"], "clientInterrupted");
        assert_eq!(
            terminal["error"]["message"],
            "client observation interrupted; the Job was not cancelled"
        );
        assert_eq!(terminal["error"]["details"]["jobId"], JOB);
        // Mid-page, the row's own cursor; after the page, the page's.
        let after = &terminal["error"]["details"]["afterCursor"];
        assert!(
            *after == rows.last().unwrap()["cursor"] || after == "page-a",
            "{terminal}"
        );

        // Nothing but health and the reads it was already making reached the
        // Runtime: no cancel, no other request.
        let requests = server.end();
        assert!(
            requests
                .iter()
                .all(|method| method == "health" || method == "job.events"),
            "{requests:?}"
        );
    }
}
