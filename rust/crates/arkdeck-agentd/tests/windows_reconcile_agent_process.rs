//! The Windows daemon's reconciler and agent execution engine
//! (TASK-XPA-005): `job.reconcile`, `agent.*` and `human-action.*`, as the
//! real daemon composes them over an isolated development root.
//!
//! The root holds, as Swift left them:
//!
//! * the Job store of Swift's restart and reconcile oracle
//!   (`rust/tests/fixtures/job-reconcile-analyzer`, `secondRestart`): two
//!   analyzer Jobs a signal death parked, the second's source payload since
//!   removed, one run to success and one only admitted, with the Artifacts
//!   they read and the succeeded Job's Session (the catalog at generation 1);
//! * the execution records and the Target of Swift's physical-assistance
//!   oracle (`rust/tests/fixtures/agent-human-action`): one waiting for a
//!   person to pick a device, one abandoned while it waited for a trust
//!   prompt, one completed and one refused.
//!
//! Then, over the daemon's pipe (a plain pipe handle, no signer needed):
//!
//! * every recorded `job.reconcile` request in order: the parked Job is
//!   closed failed and its Session published at generation 2, the Job whose
//!   source was removed is refused, the others answered as Swift answered.
//!   The daemon reconciles on its own clock, so the times it writes, and the
//!   digest of the Manifest that names them, are not Swift's; everything else
//!   is (a refusal's wording aside, T2);
//! * the execution waiting for a person to pick a device, and its action
//!   with the selection schema of its two candidates, read as Swift's owner
//!   answered them; run again long after its orchestration deadline, it is
//!   refused `orchestrationBudgetExpired` and ends `budgetExpired` with its
//!   action expired, and reads so, `failureCode` and all, in its status, the
//!   whole execution list and its action; the abandoned execution and its
//!   expired action read, and every recorded refusal answered, as Swift's
//!   owner answered them;
//! * a restart reads all of it back and changes nothing;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `job reconcile`, `agent status` (the abandoned and the waiting
//!   execution) and `human-action show` (the expired action and the
//!   pick-a-device one) report the same, `agent list` and
//!   `human-action list` the pages the pipe answers, and `capability list`
//!   and `capability inspect`, over Swift's capability-read oracle store
//!   `base` placed beside the Job state, what Swift's owner answered. These leaves are Windows
//!   `implemented` in the coverage manifest the CLI renders
//!   (`WINDOWS_MEASURED_LEAVES`). Without that variable this test says so and
//!   checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory;
//! no device or `hdc` is involved: no execution here reaches a device.
#![cfg(windows)]

use arkdeck_hoststore::{JobRecord, JobStore};
use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: a child spawned while another test's daemon starts
/// would inherit that daemon's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
/// The recorded analyzer Job a signal death parked.
const PARKED: &str = "job-bd431d3ab6fe3b03b38dbdbe92c241d3";
/// The recorded execution that waits for a person to pick a device.
const AMBIGUOUS: &str =
    "execution-f2c43a6fa56aac7e64e76e036fd10bb45bb28d77d51013efca02783d6f3d8526.json";

fn reconcile_fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/job-reconcile-analyzer")
        .join(name)
}

fn agent_fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/agent-human-action")
        .join(name)
}

fn capability_fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/capability-read/stores/base")
}

/// The capability-read oracle's recorded exchanges for its `base` store.
fn capability_exchanges() -> Vec<Value> {
    document(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/capability-read/cases.json"),
    )
    .as_array()
    .unwrap()
    .iter()
    .find(|case| case["scenario"] == "base")
    .unwrap()["exchanges"]
        .as_array()
        .unwrap()
        .clone()
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// The oracle's text with each identity it labelled (`<har-2>`) read as a
/// valid one of its kind (`har-00000000-0000-4000-8000-000000000002`).
fn unlabelled(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        out.push_str(&rest[..at]);
        let tail = &rest[at + 1..];
        let label = ["har", "resume", "candidate", "obs"]
            .iter()
            .find_map(|kind| {
                let digits = tail.strip_prefix(kind)?.strip_prefix('-')?;
                let end = digits.find('>')?;
                let number: u64 = digits[..end].parse().ok()?;
                Some((
                    format!("{kind}-00000000-0000-4000-8000-{number:012}"),
                    kind.len() + end + 2,
                ))
            });
        match label {
            Some((identity, used)) => {
                out.push_str(&identity);
                rest = &tail[used..];
            }
            None => {
                out.push('<');
                rest = tail;
            }
        }
    }
    out + rest
}

/// The physical-assistance oracle's exchanges, their identities unlabelled.
fn agent_exchanges() -> Vec<Value> {
    let text = std::fs::read_to_string(agent_fixture("cases.json")).unwrap();
    let cases: Value = serde_json::from_str(&unlabelled(&text)).unwrap();
    cases["exchanges"].as_array().unwrap().clone()
}

fn exchange(exchanges: &[Value], name: &str) -> Value {
    exchanges
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap_or_else(|| panic!("no exchange {name}"))
        .clone()
}

/// A recorded directory's files and directories, below an owned one.
fn copy_tree(from: &Path, to: &HostDirectory) {
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap().path();
        let name = entry.file_name().unwrap().to_str().unwrap();
        if entry.is_dir() {
            copy_tree(&entry, &to.create_private_child(name).unwrap());
        } else {
            to.create_document(name, &std::fs::read(&entry).unwrap())
                .unwrap();
        }
    }
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winreconcile-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        // The canonical spelling without `\\?\`, as the daemon names its root.
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        let root = Self(path);
        root.with_jobs();
        root.with_first_session();
        root.with_executions();
        root
    }
    fn jobs_state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// The Job store Swift's second start left, each row admitted and
    /// persisted to its recorded version, and the Artifacts its Jobs read
    /// and published (index owner-only, payloads sealed).
    fn with_jobs(&self) {
        let state = self.jobs_state();
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let recorded = reconcile_fixture("secondRestart");
        let index = document(recorded.join("index.json"));
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = recorded.join("jobs").join(id);
            let record =
                JobRecord::decode(&std::fs::read(directory.join("job-record.json")).unwrap())
                    .unwrap();
            store
                .admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap();
            for _ in 1..row["version"].as_i64().unwrap() {
                store
                    .persist(&record, row["updatedAtUTC"].as_str().unwrap())
                    .unwrap();
            }
            for file in std::fs::read_dir(&directory).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap();
                if name != "job-record.json" {
                    std::fs::copy(&file, state.join("jobs").join(id).join(name)).unwrap();
                }
            }
        }
        let artifacts = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        for job in std::fs::read_dir(reconcile_fixture("artifacts")).unwrap() {
            let job = job.unwrap().path();
            let owned = artifacts
                .create_private_child(job.file_name().unwrap().to_str().unwrap())
                .unwrap();
            for file in std::fs::read_dir(&job).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap().to_str().unwrap().to_owned();
                owned
                    .create_document(&name, &std::fs::read(&file).unwrap())
                    .unwrap();
                if name != "index.json" {
                    owned.seal_document(&name).unwrap();
                }
            }
        }
    }
    /// The Sessions root as Swift's first daemon left it: the succeeded
    /// Job's Session and a catalog holding it alone, at generation 1.
    fn with_first_session(&self) {
        let recorded = reconcile_fixture("sessions");
        let catalog = document(recorded.join(".arkdeck-retention-catalog.json"));
        let first = &catalog["entries"][0];
        let first_session = first["sessionId"].as_str().unwrap();
        HostDirectory::open_or_create_private(&self.0.join("session-state")).unwrap();
        let sessions = HostDirectory::open_or_create_private(&self.0.join("sessions")).unwrap();
        let catalog = json!({
            "entries": [first],
            "generation": 1,
            "schemaVersion": catalog["schemaVersion"],
        });
        sessions
            .create_document(
                ".arkdeck-retention-catalog.json",
                &serde_json::to_vec(&catalog).unwrap(),
            )
            .unwrap();
        sessions
            .create_document(
                ".arkdeck-retention-catalog.lock",
                &std::fs::read(recorded.join(".arkdeck-retention-catalog.lock")).unwrap(),
            )
            .unwrap();
        let month = sessions.create_private_child("2026").unwrap();
        let month = month.create_private_child("09").unwrap();
        copy_tree(
            &recorded.join("2026/09").join(first_session),
            &month.create_private_child(first_session).unwrap(),
        );
    }
    /// The physical-assistance oracle's Target and execution records.
    fn with_executions(&self) {
        let targets = HostDirectory::open_or_create_private(&self.0.join("targets-state")).unwrap();
        targets
            .create_document(
                "targets.json",
                &std::fs::read(agent_fixture("targets-state/targets.json")).unwrap(),
            )
            .unwrap();
        let executions =
            HostDirectory::open_or_create_private(&self.0.join("agent-executions")).unwrap();
        for entry in std::fs::read_dir(agent_fixture("agent-executions")).unwrap() {
            let path = entry.unwrap().path();
            executions
                .create_document(
                    path.file_name().unwrap().to_str().unwrap(),
                    unlabelled(&std::fs::read_to_string(&path).unwrap()).as_bytes(),
                )
                .unwrap();
        }
    }
    /// Swift's capability-read oracle store `base` in the capability store
    /// beside the Job state: two capabilities with their use ledger.
    fn with_capabilities(&self) {
        let store =
            HostDirectory::open_or_create_private(&self.jobs_state().join("capabilities")).unwrap();
        for name in ["runtime-capabilities.json", "runtime-capabilities.ledger"] {
            store
                .create_document(
                    name,
                    &std::fs::read(capability_fixture().join(name)).unwrap(),
                )
                .unwrap();
        }
    }
    fn job(&self, id: &str) -> Value {
        document(
            self.jobs_state()
                .join("jobs")
                .join(id)
                .join("job-record.json"),
        )
    }
    fn execution(&self, name: &str) -> Value {
        document(self.0.join("agent-executions").join(name))
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(executable: &Path, root: &Path) -> Command {
    let mut command = Command::new(executable);
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
    fn start(executable: &Path, root: &Path) -> Self {
        let mut child = daemon(executable, root).spawn().unwrap();
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
                Err(error) => {
                    let mut stderr = String::new();
                    if let Some(child) = self.child.as_mut()
                        && child.try_wait().ok().flatten().is_some()
                        && let Some(pipe) = child.stderr.as_mut()
                    {
                        let _ = pipe.read_to_string(&mut stderr);
                    }
                    panic!(
                        "no line starting {prefix:?} ({error}); stdout so far {:?}, stderr {stderr:?}",
                        self.seen
                    )
                }
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
        scope
            .request_stop(self.child.as_ref().unwrap().id())
            .unwrap();
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

/// An answer without the request identity and a refusal's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(object) = answer.as_object_mut() {
        object.remove("id");
    }
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

/// A reconcile answer without what the daemon's own clock decides: the
/// times the reconcile writes and the digest of the Manifest naming them.
fn clockless(answer: &Value) -> Value {
    let mut answer = semantic(answer);
    if let Some(result) = answer.get_mut("result").and_then(Value::as_object_mut) {
        if result.get("finishedAtUtc").is_some() && result.get("outcome") == Some(&json!("failed"))
        {
            result.remove("finishedAtUtc");
        }
        if let Some(publication) = result
            .get_mut("sessionPublication")
            .and_then(Value::as_object_mut)
            && publication.get("catalogGeneration") != Some(&json!("1"))
        {
            publication.remove("manifestSha256");
        }
    }
    answer
}

/// Every recorded `job.reconcile` request, in order, answered as Swift did.
fn assert_reconciles(pipe: &str) {
    for case in document(reconcile_fixture("cases.json"))
        .as_array()
        .unwrap()
    {
        let reply = request(pipe, "job.reconcile", case["params"].clone());
        assert_eq!(
            clockless(&reply),
            clockless(&case["response"]),
            "{}",
            case["name"]
        );
    }
}

/// The waiting execution as Swift's owner answered it: its status, and its
/// action as the execution names it, through `human-action.list` and
/// `.show`, the selection schema naming both candidates.
fn assert_waiting(pipe: &str, exchanges: &[Value]) {
    let waiting = exchange(exchanges, "ambiguous.run")["answer"].clone();
    let status = request(
        pipe,
        "agent.status",
        json!({"executionId": "har-ambiguous"}),
    );
    assert_eq!(semantic(&status), semantic(&waiting), "{status}");
    let action = &waiting["result"]["humanAction"];
    assert_eq!(action["selectionSchema"]["type"], "string", "{action}");
    assert_eq!(
        action["selectionSchema"]["enum"].as_array().unwrap().len(),
        2,
        "{action}"
    );
    let actions = request(
        pipe,
        "human-action.list",
        json!({"owner": "har-ambiguous", "ownerKind": "agentExecution"}),
    );
    assert_eq!(actions["result"]["items"], json!([action]), "{actions}");
    let shown = request(
        pipe,
        "human-action.show",
        json!({"humanAction": action["actionId"]}),
    );
    assert_eq!(shown["result"], *action, "{shown}");
}

/// The waiting execution once run out of time: its run refused as Swift's
/// owner refuses it, its status stopped with the refusal's code, and its
/// action expired.
fn assert_expired(pipe: &str, exchanges: &[Value]) {
    let run = request(
        pipe,
        "agent.run",
        exchange(exchanges, "ambiguous.run")["params"].clone(),
    );
    assert_eq!(
        semantic(&run),
        json!({"ok": false, "error": {"code": "orchestrationBudgetExpired",
            "details": {"executionId": "har-ambiguous", "phase": "preAdmission",
                "newDispatchCount": 0}}}),
        "{run}"
    );
    let status = request(
        pipe,
        "agent.status",
        json!({"executionId": "har-ambiguous"}),
    );
    let mut expected = exchange(exchanges, "ambiguous.run")["answer"]["result"].clone();
    for (key, value) in [
        ("state", json!("budgetExpired")),
        ("failureCode", json!("orchestrationBudgetExpired")),
        ("generation", json!("4")),
        ("humanAction", Value::Null),
        ("nextAction", Value::Null),
    ] {
        expected[key] = value;
    }
    assert_eq!(status["result"], expected, "{status}");
    let action = exchange(exchanges, "ambiguous.run")["answer"]["result"]["humanAction"].clone();
    let shown = request(
        pipe,
        "human-action.show",
        json!({"humanAction": action["actionId"]}),
    );
    let mut expired = action.clone();
    expired["status"] = json!("expired");
    assert_eq!(shown["result"], expired, "{shown}");
}

/// The executions and their actions, read and refused as Swift's owner
/// answered them once the waiting execution has run out of time.
fn assert_executions(pipe: &str, exchanges: &[Value]) {
    let status = request(pipe, "agent.status", json!({"executionId": "har-trust"}));
    assert_eq!(
        semantic(&status),
        semantic(&exchange(exchanges, "trust.abandon")["answer"]),
        "{status}"
    );
    // The whole list, and a page of the abandoned executions: the abandoned
    // one as its status reads without its action; the expired one with the
    // code it stopped with.
    let list = request(pipe, "agent.list", json!({}));
    let items = list["result"]["items"]
        .as_array()
        .unwrap_or_else(|| panic!("{list}"));
    let ids: Vec<&str> = items
        .iter()
        .map(|item| item["executionId"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        ["har-ambiguous", "har-connect", "har-trust", "har-unproven"],
        "{list}"
    );
    assert_eq!(items[0]["state"], "budgetExpired", "{list}");
    assert_eq!(
        items[0]["failureCode"], "orchestrationBudgetExpired",
        "{list}"
    );
    let list = request(pipe, "agent.list", json!({"state": "abandoned"}));
    let items = list["result"]["items"]
        .as_array()
        .unwrap_or_else(|| panic!("{list}"));
    let mut abandoned = exchange(exchanges, "trust.abandon")["answer"]["result"].clone();
    abandoned.as_object_mut().unwrap().remove("humanAction");
    assert_eq!(items, &vec![abandoned], "{list}");
    for name in [
        "trust.expired",
        "trust.resume",
        "trust.resumeByAction",
        "refuse.listHalfFilter",
        "refuse.listKind",
        "refuse.listPageSize",
        "refuse.listCursor",
        "refuse.showUnknown",
        "refuse.showInvalid",
        "refuse.resumeUnknown",
        "refuse.agentResumeUnknown",
        "refuse.agentResumeInvalid",
    ] {
        let exchange = exchange(exchanges, name);
        let reply = request(
            pipe,
            exchange["method"].as_str().unwrap(),
            exchange["params"].clone(),
        );
        assert_eq!(semantic(&reply), semantic(&exchange["answer"]), "{name}");
    }
}

#[test]
fn jobs_are_reconciled_and_executions_answered_as_swift_s_across_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let exchanges = agent_exchanges();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, \
              history, workspaceProjects, planning, agentExecutions, humanActions, traceCache, flashHostFacts, deviceAccess"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );

    // The waiting execution as Swift's owner left it and answered it.
    assert_waiting(&pipe, &exchanges);
    // Run again long after its orchestration deadline (this daemon's clock
    // is not the oracle's): refused, and the execution ends in the same
    // write that expires its action.
    assert_expired(&pipe, &exchanges);
    let record = root.execution(AMBIGUOUS);
    assert_eq!(record["state"], "budgetExpired");
    assert_eq!(record["actions"][0]["status"], "expired");
    assert_eq!(record["failureCode"], "orchestrationBudgetExpired");
    assert_eq!(record["generation"], 4);
    assert_executions(&pipe, &exchanges);

    // Every recorded reconcile: the parked Job closed and its Session
    // published at generation 2.
    assert_reconciles(&pipe);
    let parked = root.job(PARKED);
    assert_eq!(
        parked["operationFailure"]["code"],
        "executionConfirmedNotPerformed"
    );
    assert_eq!(
        parked["sessionPublicationRecord"]["phase"],
        "catalogPublished"
    );
    first.stop(&root.0);
    let after_first = (root.job(PARKED), root.execution(AMBIGUOUS));

    // A restart reads it back and changes nothing.
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    assert_reconciles(&pipe);
    assert_executions(&pipe, &exchanges);
    // Run again: the same refusal, and nothing written.
    let run = request(
        &pipe,
        "agent.run",
        exchange(&exchanges, "ambiguous.run")["params"].clone(),
    );
    assert_eq!(run["error"]["code"], "orchestrationBudgetExpired", "{run}");
    second.stop(&root.0);
    assert_eq!((root.job(PARKED), root.execution(AMBIGUOUS)), after_first);
}

/// PowerShell 7, which signs the development daemon.
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
        "PowerShell 7 is required to sign the development daemon"
    );
    alias
}

/// The real CLI beside the daemon, against `pipe`, verifying `daemon` and
/// its signer `pin` as it verifies an installed daemon.
fn cli(daemon: &Path, pin: &str, pipe: &str, arguments: &[&str]) -> (Option<i32>, Value) {
    let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck.exe");
    let mut command = Command::new(&cli);
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("ARKDECK_")
        {
            command.env_remove(key);
        }
    }
    let output = command
        .args(arguments)
        .args(["--output", "json"])
        .env("ARKDECK_ENDPOINT", pipe)
        .env("ARKDECK_DAEMON_PATH", daemon)
        .env("ARKDECK_DAEMON_SIGNER_SHA256", pin)
        .stdin(Stdio::null())
        .output()
        .unwrap_or_else(|error| {
            panic!(
                "the arkdeck CLI beside the daemon ({}): {error}; run the workspace tests, or \
                 `cargo build -p arkdeck-cli` before testing this crate alone",
                cli.display()
            )
        });
    let envelope = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
    (output.status.code(), envelope)
}

/// The host-trusted development signer's thumbprint, or `None` once the
/// test has said it checks nothing without one.
fn development_signer() -> Option<std::ffi::OsString> {
    let thumbprint =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty());
    if thumbprint.is_none() {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted development \
             signer can sign the daemon the CLI must verify (rust/scripts/windows-dev-identity.ps1 \
             create); nothing was checked"
        );
    }
    thumbprint
}

/// A copy of the daemon below `root`, signed by `thumbprint`: its path and
/// the signer pin the CLI verifies it by.
fn signed_daemon(root: &Root, thumbprint: &std::ffi::OsStr) -> (PathBuf, String) {
    let signed = root.0.join("signed-bin");
    std::fs::create_dir(&signed).unwrap();
    let daemon = signed.join("arkdeck-agentd.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-agentd"), &daemon).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(thumbprint)
        .arg("-Path")
        .arg(&daemon)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(signing.status.success(), "{signing:?}");
    let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
    (daemon, pin["pin"].as_str().unwrap().to_owned())
}

#[test]
fn reconcile_agent_and_human_action_hops_run_through_the_cli_against_a_dev_signed_daemon() {
    let Some(thumbprint) = development_signer() else {
        return;
    };
    let _turn = turn();
    let root = Root::new();
    let exchanges = agent_exchanges();
    root.with_capabilities();
    let (daemon, pin) = signed_daemon(&root, &thumbprint);

    let mut started = Daemon::start(&daemon, &root.0);
    let pipe = started.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "reconcile", "--job", PARKED]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["outcome"], "failed", "{envelope}");
    assert_eq!(
        envelope["result"]["sessionPublication"]["catalogGeneration"], "2",
        "{envelope}"
    );
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["agent", "status", "--execution-id", "har-trust"],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"],
        exchange(&exchanges, "trust.abandon")["answer"]["result"],
        "{envelope}"
    );
    // The waiting execution and its pick-a-device action, before any run.
    let waiting = exchange(&exchanges, "ambiguous.run")["answer"]["result"].clone();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["agent", "status", "--execution-id", "har-ambiguous"],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"], waiting, "{envelope}");
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "human-action",
            "show",
            "--human-action",
            waiting["humanAction"]["actionId"].as_str().unwrap(),
        ],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"], waiting["humanAction"], "{envelope}");
    let expired = exchange(&exchanges, "trust.expired");
    let action = expired["params"]["humanAction"].as_str().unwrap();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["human-action", "show", "--human-action", action],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"], expired["answer"]["result"],
        "{envelope}"
    );
    // The whole execution list and every action, as the pipe pages them.
    for (arguments, method) in [
        (["agent", "list"], "agent.list"),
        (["human-action", "list"], "human-action.list"),
    ] {
        let (status, envelope) = cli(&daemon, &pin, &pipe, &arguments);
        assert_eq!(status, Some(0), "{envelope}");
        let page = request(&pipe, method, json!({}))["result"].clone();
        assert!(!page["items"].as_array().unwrap().is_empty(), "{page}");
        assert_eq!(envelope["result"]["items"], page["items"], "{envelope}");
        assert_eq!(envelope["result"]["hasMore"], false, "{envelope}");
    }
    // Swift's recorded capability store, read as Swift's owner answered it.
    let recorded = capability_exchanges();
    assert_eq!(recorded.len(), 3);
    for exchange in &recorded {
        let arguments: Vec<&str> = match exchange["params"]["capabilityId"].as_str() {
            Some(id) => vec!["capability", "inspect", "--capability", id],
            None => vec!["capability", "list"],
        };
        let (status, envelope) = cli(&daemon, &pin, &pipe, &arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        assert_eq!(
            envelope["result"], exchange["response"]["result"],
            "{arguments:?}"
        );
    }
    started.stop(&root.0);
    assert_measured(&[
        "capability.inspect",
        "job.reconcile",
        "agent.status",
        "agent.list",
        "human-action.show",
        "human-action.list",
    ]);
}

/// What this test measured is what the coverage manifest counts: each
/// leaf's entries are Windows `implemented` in the manifest the CLI renders
/// (`maintainer contracts export`'s product, held to the committed
/// `openspec/contracts/cli-feature-coverage.json` by the CLI's own tests).
fn assert_measured(leaves: &[&str]) {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for leaf in leaves {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == *leaf)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert!(
            !statuses.is_empty() && statuses.iter().all(|status| *status == "implemented"),
            "{leaf}: {statuses:?}"
        );
    }
}
