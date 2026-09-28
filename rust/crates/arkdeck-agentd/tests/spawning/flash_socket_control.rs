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
use crate::flash_execution_control::{Root, execution_fakes, flash_host, request};
use arkdeck_control::Control;
use arkdeck_platform::{LocalEndpoint, LocalListener};
use serde_json::Value;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

/// The daemon binary's `arkdeck` beside it; `cargo test` of the workspace
/// builds both, and testing this crate alone needs `cargo build -p
/// arkdeck-cli` first.
fn cli_path() -> PathBuf {
    Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck")
}

/// A private directory short enough for a Unix socket name.
struct SocketDirectory(PathBuf);

impl SocketDirectory {
    fn new() -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/afs-{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }

    fn socket(&self) -> PathBuf {
        self.0.join("control.sock")
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
    let listener = LocalListener::bind(&LocalEndpoint::new(socket)).unwrap();
    let control = Arc::new(Control::new(host).unwrap());
    std::thread::spawn(move || {
        let _ = arkdeck_agentd::serve_control(
            listener,
            control,
            |listener| listener.accept().map(Some),
            Duration::from_secs(60),
            Duration::from_secs(5),
        );
    });
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
    let output = command
        .args(arguments)
        .args(["--output", "json", "--socket"])
        .arg(socket)
        // The identity the CLI names; the peer on this socket is this binary.
        .env("ARKDECK_DAEMON_PATH", std::env::current_exe().unwrap())
        .output()
        .expect(
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
}

fn inputs_file(directory: &Path, exchange: &str) -> (PathBuf, Value) {
    let recorded: Value = serde_json::from_str(&request(exchange)).unwrap();
    let path = directory.join("inputs.json");
    fs::write(&path, serde_json::to_vec(&recorded["inputs"]).unwrap()).unwrap();
    (path, recorded)
}

fn run_case(entry: Entry, outcome: &str) {
    let _turn = crate::turn();
    let output = Command::new(std::env::current_exe().unwrap())
        .env(
            "ARKDECK_TEST_FLASH_SOCKET_ENTRY",
            match entry {
                Entry::AgentRun => "agent",
                Entry::AgentRunAlias => "alias",
                Entry::FlashRun => "flash",
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
#[ignore = "subprocess fixture: invoked by the flash socket cases"]
fn flash_socket_process_fixture() {
    let _turn = crate::turn();
    let entry = match std::env::var("ARKDECK_TEST_FLASH_SOCKET_ENTRY").as_deref() {
        Ok("agent") => Entry::AgentRun,
        Ok("alias") => Entry::AgentRunAlias,
        Ok("flash") => Entry::FlashRun,
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
    serve(flash_host(&root, &fakes), &sockets.socket());
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
        assert_ne!(status, Some(0), "{answer}");
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
