//! Flash end to end over the daemon's control socket (TASK-XPA-017, S2):
//! the Rust `arkdeck` CLI's two GJ-4 entry points, `agent run --operation
//! flash.full-restore@1` (and its alias `flash.dayu200`) and `flash run`,
//! each against a Runtime that serves the production control transport
//! (`arkdeck_agentd::serve_control`) on a private Unix socket, to a terminal
//! state: completed, and an unknown outcome that stays unknown and is never
//! replayed.
//!
//! The Host is the one `flash_execution_control` composes: the real Target,
//! Artifact, Import, Job, capability and Agent execution owners, the Flash
//! planning, facts and admission, with the Swift Flash run oracle's fake
//! ArkForge lane and Rockchip host as its only external ports. The fakes live
//! in this test binary alone; the daemon binary has no seam for them, so no
//! production composition can be given a fake lane. No `arkforged`, device,
//! USB host or installed Runtime is reached; nothing here is device evidence.
//!
//! Each case runs in a child of this binary (`--exact … --ignored`), so the
//! server thread it leaves ends with that child.
//!
//! On Windows (TASK-XPA-010) the child is a copy of this binary signed with
//! the host-trusted development signer (`signed_daemon::signed_copy`), serving
//! on a private named pipe, so the CLI verifies the peer's image and signer
//! pin (`ARKDECK_DAEMON_PATH`, `ARKDECK_DAEMON_SIGNER_SHA256`) as it verifies
//! an installed daemon. The Host's HDC is the in-process fake of
//! `flash_execution_control`, given through the test seam.
use crate::flash_execution_control::{Root, execution_fakes, flash_host, request};
use arkdeck_control::Control;
use arkdeck_platform::{LocalEndpoint, LocalListener};
use serde_json::Value;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

/// The daemon binary's `arkdeck` beside it; `cargo test` of the workspace
/// builds both, and testing this crate alone needs `cargo build -p
/// arkdeck-cli` first.
fn cli_path() -> PathBuf {
    Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name(if cfg!(windows) {
        "arkdeck.exe"
    } else {
        "arkdeck"
    })
}

/// The signer pin of the signed copy a Windows case runs in, which its CLI
/// verifies the peer against; set only for that child.
#[cfg(windows)]
const PIN: &str = "ARKDECK_TEST_FLASH_SOCKET_PIN";

/// A private directory short enough for a Unix socket name.
struct SocketDirectory(PathBuf);

impl SocketDirectory {
    #[cfg(unix)]
    fn new() -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/afs-{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }

    #[cfg(unix)]
    fn socket(&self) -> PathBuf {
        self.0.join("control.sock")
    }

    /// A private directory below the temporary directory, for the inputs.
    #[cfg(windows)]
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "afs-{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        ));
        arkdeck_platform::HostDirectory::open_or_create_private(&path).unwrap();
        Self(path)
    }

    /// A private ArkDeck pipe named after the directory.
    #[cfg(windows)]
    fn socket(&self) -> PathBuf {
        PathBuf::from(format!(
            r"\\.\pipe\arkdeck-test-{}",
            self.0.file_name().unwrap().to_string_lossy()
        ))
    }
}

impl Drop for SocketDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Serves `host` on `socket` with the production control transport, from a
/// thread that ends with this process.
fn serve(host: crate::host::Host, socket: &Path) {
    let control = Arc::new(Control::new(host).unwrap());
    let endpoint = LocalEndpoint::new(socket);
    // The listener is bound on the serving thread (a Windows pipe listener
    // stays on the thread that made it), and this returns once it is bound.
    let (bound, ready) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let listener = LocalListener::bind(&endpoint).unwrap();
        bound.send(()).unwrap();
        let _ = arkdeck_agentd::serve_control(
            listener,
            control,
            |listener| listener.accept().map(Some),
            Duration::from_secs(60),
            Duration::from_secs(5),
        );
    });
    ready.recv().unwrap();
}

/// The `arkdeck` CLI against `socket`, asked for its machine answer: its
/// exit status and the envelope it printed.
fn cli(socket: &Path, arguments: &[&str]) -> (Option<i32>, Value) {
    let mut command = Command::new(cli_path());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("ARKDECK_") {
            command.env_remove(key);
        }
    }
    command
        .args(arguments)
        .args(["--output", "json"])
        // The identity the CLI names; the peer on this socket is this binary.
        .env("ARKDECK_DAEMON_PATH", std::env::current_exe().unwrap());
    #[cfg(unix)]
    command.arg("--socket").arg(socket);
    // On Windows `--socket` is macOS-only: the endpoint is named as an
    // installation names it, with the signer pin this signed copy carries.
    #[cfg(windows)]
    command.env("ARKDECK_ENDPOINT", socket).env(
        "ARKDECK_DAEMON_SIGNER_SHA256",
        std::env::var_os(PIN).expect("the signed copy's pin"),
    );
    let output = command.output().expect(
        "the arkdeck CLI beside the daemon: run the workspace tests, or \
             `cargo build -p arkdeck-cli` before testing this crate alone",
    );
    let envelope = serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "{arguments:?}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    });
    (output.status.code(), envelope)
}

/// A Job leaf of the same CLI over the same socket: `job status` or `job
/// run`, as `{"ok": …, "result"|"error": …}`.
fn job(socket: &Path, verb: &str, job: &str) -> Value {
    cli(socket, &["job", verb, "--job", job]).1
}

/// Which entry point a case drives, and with which request.
#[derive(Clone, Copy)]
enum Entry {
    AgentRun,
    AgentRunAlias,
    FlashRun,
    /// `job plan`, `job submit` and `job run` of the oracle's recorded
    /// request, the reviewed plan digest the plan named.
    JobLeaves,
    /// The protected Flash recovery broker through `recovery flash-invocation
    /// start|evaluate|status|list`, then `flash reconcile-alias`, over the
    /// Flash invocation owner and the post-flash alias reconciler.
    Recovery,
}

fn inputs_file(directory: &Path, exchange: &str) -> (PathBuf, Value) {
    let recorded: Value = serde_json::from_str(&request(exchange)).unwrap();
    let path = directory.join("inputs.json");
    fs::write(&path, serde_json::to_vec(&recorded["inputs"]).unwrap()).unwrap();
    (path, recorded)
}

fn run_case(entry: Entry, outcome: &str) {
    let _turn = crate::turn();
    #[cfg(unix)]
    let mut command = Command::new(std::env::current_exe().unwrap());
    // On Windows the case runs in a signed copy of this binary, which the CLI
    // verifies; without a development signer nothing is checked (reported).
    #[cfg(windows)]
    let (scratch, mut command) = {
        let scratch = SocketDirectory::new();
        let Some((executable, pin)) =
            crate::signed_daemon::signed_copy(&scratch.0.join("signed-bin"))
        else {
            return;
        };
        let mut command = Command::new(executable);
        command.env(PIN, pin);
        (scratch, command)
    };
    let output = command
        .env(
            "ARKDECK_TEST_FLASH_SOCKET_ENTRY",
            match entry {
                Entry::AgentRun => "agent",
                Entry::AgentRunAlias => "alias",
                Entry::FlashRun => "flash",
                Entry::JobLeaves => "job",
                Entry::Recovery => "recovery",
            },
        )
        .env("ARKDECK_TEST_FLASH_SOCKET_OUTCOME", outcome)
        .args([
            "--exact",
            "flash_socket_control::flash_socket_process_fixture",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // The one case the child ran passed, not a filter that matched none.
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("1 passed"),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    #[cfg(windows)]
    drop(scratch);
}

#[test]
fn agent_run_flashes_to_completion_over_the_control_socket() {
    run_case(Entry::AgentRun, "completed");
}

#[test]
fn agent_run_of_the_alias_flashes_to_completion_over_the_control_socket() {
    run_case(Entry::AgentRunAlias, "completed");
}

#[test]
fn agent_run_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket() {
    run_case(Entry::AgentRun, "unknown");
}

#[test]
fn flash_run_flashes_to_completion_over_the_control_socket() {
    run_case(Entry::FlashRun, "completed");
}

#[test]
fn flash_run_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket() {
    run_case(Entry::FlashRun, "unknown");
}

#[test]
fn job_plan_submit_and_run_flash_to_completion_over_the_control_socket() {
    run_case(Entry::JobLeaves, "completed");
}

#[test]
fn job_run_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket() {
    run_case(Entry::JobLeaves, "unknown");
}

#[test]
fn the_recovery_broker_flashes_to_completion_over_the_control_socket() {
    run_case(Entry::Recovery, "completed");
}

#[test]
fn the_recovery_broker_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket() {
    run_case(Entry::Recovery, "unknown");
}

/// The recovery broker's execute action and the sources it is pinned to, as
/// `flash_broker_control` sends them.
const RECOVERY_EXECUTE: &str = r#"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#;
const RECOVERY_SOURCE: &str = "0000000000000000000000000000000000000000000000000000000000000001";
const RECOVERY_BUILD: &str = "0000000000000000000000000000000000000000000000000000000000000065";

#[test]
#[ignore = "subprocess fixture: invoked by the flash socket cases"]
fn flash_socket_process_fixture() {
    let _turn = crate::turn();
    let entry = match std::env::var("ARKDECK_TEST_FLASH_SOCKET_ENTRY").as_deref() {
        Ok("agent") => Entry::AgentRun,
        Ok("alias") => Entry::AgentRunAlias,
        Ok("flash") => Entry::FlashRun,
        Ok("job") => Entry::JobLeaves,
        Ok("recovery") => Entry::Recovery,
        other => panic!("no entry named: {other:?}"),
    };
    let unknown = std::env::var("ARKDECK_TEST_FLASH_SOCKET_OUTCOME").as_deref() == Ok("unknown");
    let root = Root::new();
    let fakes = execution_fakes::Fakes::default();
    if unknown {
        fakes.begin(execution_fakes::Script {
            perform: "outcomeUnknown".into(),
            terminal: "outcomeUnknown".into(),
            ..Default::default()
        });
    }
    let sockets = SocketDirectory::new();
    let host = flash_host(&root, &fakes);
    // The recovery broker's owner beside the planner's state, and the
    // post-flash alias reconciler over the fixture's Application Support
    // root and census, as the daemon compositions compose them.
    let host = match entry {
        Entry::Recovery => host
            .with_flash_invocations(
                arkdeck_hoststore::FlashInvocations::open(&root.0.join("jobs")).unwrap(),
            )
            .with_flash_alias_reconciler(arkdeck_hoststore::FlashAliasReconciler::new(
                &root.0,
                crate::flash_execution_control::census,
                || "2026-09-25T00:00:00Z".to_owned(),
            )),
        _ => host,
    };
    serve(host, &sockets.socket());
    let socket = sockets.socket();
    let exchange = match entry {
        Entry::AgentRunAlias => "alias.full",
        _ => "canonical.full",
    };
    let (inputs, recorded) = inputs_file(&sockets.0, exchange);
    let target = recorded["target"]["targetId"].as_str().unwrap().to_owned();
    let operation = match entry {
        Entry::AgentRunAlias => "flash.dayu200".to_owned(),
        _ => format!(
            "{}@{}",
            recorded["operation"]["id"].as_str().unwrap(),
            recorded["operation"]["version"]
        ),
    };
    let inputs = inputs.to_string_lossy().into_owned();
    let (status, answer) = match entry {
        Entry::AgentRun | Entry::AgentRunAlias => cli(
            &socket,
            &[
                "agent",
                "run",
                "--operation",
                &operation,
                "--target",
                &target,
                "--inputs-file",
                &inputs,
                "--execution-id",
                "gj4-socket-fixture",
                "--maximum-wait",
                "5m",
            ],
        ),
        Entry::FlashRun => cli(
            &socket,
            &[
                "flash",
                "run",
                "--target",
                &target,
                "--inputs-file",
                &inputs,
                "--execution-id",
                "gj4-socket-fixture",
            ],
        ),
        Entry::JobLeaves => {
            let mut request: Value = serde_json::from_str(&request(exchange)).unwrap();
            let file = sockets.0.join("request.json");
            fs::write(&file, request.to_string()).unwrap();
            let file_argument = file.to_string_lossy().into_owned();
            let (status, plan) = cli(&socket, &["job", "plan", "--request-file", &file_argument]);
            assert_eq!(status, Some(0), "{plan}");
            request["reviewedPlanDigest"] = plan["result"]["materializedPlanDigest"].clone();
            assert!(request["reviewedPlanDigest"].is_string(), "{plan}");
            fs::write(&file, request.to_string()).unwrap();
            let (status, admitted) = cli(
                &socket,
                &["job", "submit", "--request-file", &file_argument],
            );
            assert_eq!(status, Some(0), "{admitted}");
            let job_id = job_of(&admitted).unwrap_or_else(|| panic!("{admitted}"));
            let (status, run) = cli(&socket, &["job", "run", "--job", &job_id]);
            assert_eq!(run["ok"], true, "{run}");
            // The Flash host reads over the same Host, through the same CLI.
            for arguments in [
                vec!["flash", "bootloader-status"],
                vec![
                    "flash",
                    "prerequisites",
                    "--target",
                    &target,
                    "--device-profile",
                    "dayu200",
                ],
            ] {
                let (status, answer) = cli(&socket, &arguments);
                assert_eq!(status, Some(0), "{arguments:?}: {answer}");
                assert_eq!(answer["result"]["targetId"], target.as_str(), "{answer}");
                assert_eq!(answer["result"]["bindingRevision"], 1, "{answer}");
            }
            (if unknown { None } else { status }, admitted)
        }
        Entry::Recovery => {
            // The completed case drives `recovery flash-invocation`, the
            // unknown one its `debug` spelling: the same handlers.
            let leaf: &[&str] = if unknown {
                &["debug"]
            } else {
                &["recovery", "flash-invocation"]
            };
            let verb = |verb: &'static str, rest: &[&str]| -> Vec<String> {
                leaf.iter()
                    .chain([verb].iter())
                    .chain(rest.iter())
                    .map(|part| (*part).to_owned())
                    .collect()
            };
            let run = |arguments: Vec<String>| {
                let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
                cli(&socket, &arguments)
            };
            let file = sockets.0.join("request.json");
            fs::write(&file, request(exchange)).unwrap();
            let file_argument = file.to_string_lossy().into_owned();
            let (status, started) = run(verb("start", &["--request-file", &file_argument]));
            assert_eq!(status, Some(0), "{started}");
            let invocation = started["result"]["invocationID"]
                .as_str()
                .unwrap_or_else(|| panic!("{started}"))
                .to_owned();
            let action = sockets.0.join("action.json");
            fs::write(&action, RECOVERY_EXECUTE).unwrap();
            let action_argument = action.to_string_lossy().into_owned();
            let (status, evaluated) = run(verb(
                "evaluate",
                &[
                    "--invocation",
                    &invocation,
                    "--action-file",
                    &action_argument,
                    "--source-sha256",
                    RECOVERY_SOURCE,
                    "--build-sha256",
                    RECOVERY_BUILD,
                ],
            ));
            assert_eq!(evaluated["ok"], true, "{evaluated}");
            let (shown, listed) = (
                run(verb("status", &["--invocation", &invocation])),
                cli(&socket, &["recovery", "flash-invocation", "list"]),
            );
            assert_eq!(shown.0, Some(0), "{}", shown.1);
            assert_eq!(
                shown.1["result"]["state"],
                if unknown { "active" } else { "succeeded" },
                "{}",
                shown.1
            );
            assert_eq!(listed.0, Some(0), "{}", listed.1);
            assert!(
                listed.1["result"]["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|item| item["invocationId"] == invocation.as_str()),
                "{}",
                listed.1
            );
            let reconciled = cli(
                &socket,
                &[
                    "flash",
                    "reconcile-alias",
                    "--target",
                    &target,
                    "--expected-binding-revision",
                    "1",
                ],
            );
            // The reconciler is composed and answers as Swift's: the fake
            // lane's post-flash alias is no reissued lineage of the fixture's
            // board, so nothing is repaired.
            assert_eq!(
                reconciled.1["error"]["details"]["wireCode"], "rejected",
                "{}",
                reconciled.1
            );
            assert!(
                reconciled.1["error"]["message"]
                    .as_str()
                    .unwrap()
                    .starts_with("post-flash alias reconciliation was refused: admissionRejected"),
                "{}",
                reconciled.1
            );
            (if unknown { None } else { status }, evaluated)
        }
    };
    let calls = fakes.calls();
    let job_id = job_of(&answer).unwrap_or_else(|| panic!("{status:?} {answer}; {calls:?}"));
    let job_status = job(&socket, "status", &job_id);
    let performs = |calls: &(Vec<String>, Vec<String>)| {
        calls
            .0
            .iter()
            .filter(|call| call.starts_with("perform "))
            .count()
    };
    assert_eq!(performs(&calls), 1, "{calls:?}");
    if unknown {
        assert_eq!(
            job_status["result"]["state"], "waitingForRecovery",
            "{job_status}; {answer}"
        );
        assert_eq!(job_status["result"]["outcomeUnknown"], true, "{job_status}");
        if !matches!(entry, Entry::JobLeaves | Entry::Recovery) {
            assert_ne!(status, Some(0), "{answer}");
        }
        // The unknown intent is never replayed: another run of the same Job
        // is refused and dispatches nothing.
        let again = job(&socket, "run", &job_id);
        assert_eq!(again["ok"], false, "{again}");
        assert_eq!(fakes.calls(), calls, "an unknown intent must never replay");
        return;
    }
    assert_eq!(status, Some(0), "{answer}; {calls:?}");
    assert_eq!(job_status["result"]["state"], "succeeded", "{job_status}");
    assert_eq!(
        job_status["result"]["outcomeUnknown"], false,
        "{job_status}"
    );
    assert!(
        calls.0.iter().any(|call| call.starts_with("prepare ")),
        "{calls:?}"
    );
    // A terminal Job is never dispatched again.
    let again = job(&socket, "run", &job_id);
    assert_eq!(again["ok"], false, "{again}");
    assert_eq!(fakes.calls(), calls, "terminal records never redispatch");
}

/// The Job an answer names, wherever the entry point put it.
fn job_of(answer: &Value) -> Option<String> {
    let mut stack = vec![answer];
    while let Some(value) = stack.pop() {
        match value {
            Value::Object(object) => {
                for key in ["jobId", "jobID"] {
                    if let Some(Value::String(job)) = object.get(key) {
                        return Some(job.clone());
                    }
                }
                stack.extend(object.values());
            }
            Value::Array(values) => stack.extend(values),
            _ => {}
        }
    }
    None
}
