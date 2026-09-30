//! XPA-AC-7's kill matrix on Windows (TASK-XPA-005): the Swift crash-window
//! oracle (`rust/tests/fixtures/crash-window`, recorded by
//! `CrashWindowOracleContractTests`) replayed over the NTFS host store with
//! the Rust runner killed at the same four windows, the quadrants of "before
//! or after an intent" and "before or after the capability consume", as
//! `crash_window.rs` replays it on macOS:
//! - `beforeConsume`: at the tool identity check that opens the consume, once
//!   the last evidence step's outcome is durable;
//! - `afterReadOnlyIntent`: as `read-evidence-model` would launch the tool,
//!   its intent durable;
//! - `afterConsume`: at the first clock read once the Job record holds its
//!   `runtimeCapability` evidence (the intent's envelope);
//! - `afterIntent`: as `inject-pointer-input` would launch the injector, its
//!   intent durable.
//!
//! For each window a child of this test binary rebuilds nothing: the parent
//! lays the root down, and the child admits the oracle's `input.tap@1` and
//! runs it until the window, where it exits without unwinding
//! (`std::process::exit`), so nothing past the last durable write happens and
//! every handle it held is closed by the system, as when the process is
//! killed. The parent then does what the Swift oracle did after its daemon
//! died: the store the run left must be Swift's (`crash/`), the daemon starts
//! twice (`recover_active_jobs`), the Job is reconciled twice, a new tap is
//! submitted, and the Job and capabilities are read. Every answer and every
//! store snapshot must be Swift's byte for byte, once each Job record's
//! volume, device, inode and claim generation are read as labels, and
//! neither a start nor a reconcile adds a call to the fake.
//!
//! The fake HDC is `HDCOracleFake`'s table (`hdc-answers.sh`) answered in
//! process: each call is logged as the script logs it and answered with the
//! script's bytes. It reports the tool's identity current, as the macOS
//! `ProcessDispatch` over the fake's verified script does; the Windows
//! `ProcessDispatch` never does (no Windows launch identity is published
//! before the Windows HDC tuple is registered), so the daemon itself reaches
//! none of this. What the matrix measures is the runner, its durable writes,
//! the recovery and the reconciler on NTFS. The tree's POSIX modes are not
//! compared: NTFS keeps owner-only descriptors instead.
#![cfg(windows)]

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobReconciler, JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution,
    RecoveredJobs, SessionPublisher, SessionStore, StorageClaims, StorageProbe, StorageSnapshot,
    TargetStore, recover_active_jobs,
};
use arkdeck_platform::{HostDirectory, HostSqlite, SqliteValue as Sql};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

const WINDOWS: [(&str, i32); 4] = [
    ("beforeConsume", 81),
    ("afterReadOnlyIntent", 82),
    ("afterConsume", 83),
    ("afterIntent", 84),
];
const CHILD: &str = "ARKDECK_CRASH_WINDOW_CHILD";
const ROOT: &str = "ARKDECK_CRASH_WINDOW_ROOT";
const MACHINE_FACTS: [&str; 4] = ["device", "inode", "volumeIdentity", "admissionGeneration"];
/// The fake's connect key (`hdc-answers.sh`).
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn exit_code(window: &str) -> i32 {
    WINDOWS.iter().find(|(name, _)| *name == window).unwrap().1
}

fn fixture(window: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/crash-window")
        .join(window)
}

fn document(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
}

fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// A fresh root below the temporary directory, in the spelling the file
/// system resolves (the host store opens a directory only by it).
fn fresh_root(window: &str) -> PathBuf {
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let temporary = std::env::temp_dir().canonicalize().unwrap();
    let temporary = match temporary
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
    {
        Some(plain) => PathBuf::from(plain),
        None => temporary,
    };
    temporary.join(format!("ad-wincrash-{window}-{nonce:016x}"))
}

/// The root as `HDCOracleFake.install` left it: the Target document the
/// Swift oracle's adoption wrote, and the empty Job (`store`), Artifact,
/// Sessions and Session owner roots, each owner-only; the fake's empty log.
fn lay_down(fixture: &Path, root: &Path) {
    HostDirectory::open_or_create_private(root).unwrap();
    for name in [
        "targets-state",
        "artifacts",
        "store",
        "Sessions",
        "session-owner",
    ] {
        HostDirectory::open_or_create_private(&root.join(name)).unwrap();
    }
    HostDirectory::open(&root.join("targets-state"))
        .unwrap()
        .create_document(
            "targets.json",
            &fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
}

/// `HDCOracleFake` answered in process: every call logged as the driver
/// logs it (each argument followed by a unit separator, then a newline) and
/// answered as `hdc-answers.sh` answers it.
struct FakeHdc {
    log: PathBuf,
}

impl HdcDispatch for FakeHdc {
    fn mutation_identity_current(&self) -> bool {
        true
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let mut line = Vec::new();
        for argument in &plan.arguments {
            line.extend_from_slice(argument.as_bytes());
            line.push(0x1f);
        }
        line.push(b'\n');
        fs::OpenOptions::new()
            .append(true)
            .open(&self.log)
            .unwrap()
            .write_all(&line)
            .unwrap();
        let joined = plan.arguments.join(" ");
        let (exit_status, stdout, stderr) = if joined == "list targets -v" {
            (
                0,
                format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"),
                String::new(),
            )
        } else if joined == format!("-t {KEY} shell param get const.product.name") {
            (0, "OpenHarmony Reference Device\n".into(), String::new())
        } else if joined == format!("-t {KEY} shell param get const.ohos.fullname") {
            (0, "OpenHarmony-4.1-release\n".into(), String::new())
        } else if joined.starts_with(&format!("-t {KEY} shell uinput ")) {
            let mut rest: Vec<&str> = plan.arguments[4..].iter().map(String::as_str).collect();
            if rest.first() == Some(&"-D") {
                rest.drain(..2);
            }
            let mut out = String::new();
            if rest.get(1) == Some(&"-c") {
                out.push_str(&format!(
                    "   click coordinate: ({}, {})\nclick interval time: 100ms\n",
                    rest[2], rest[3]
                ));
            }
            out.push_str(
                "If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n",
            );
            (0, out, String::new())
        } else {
            (23, String::new(), "unregistered fixture output\n".into())
        };
        Ok(Receipt {
            exit_status,
            stdout: stdout.into_bytes(),
            stderr: stderr.into_bytes(),
            truncated: false,
            duration: Duration::ZERO,
        })
    }
}

/// The oracle's probe: this machine's volume with room for every claim.
struct OracleProbe(u64);

impl StorageProbe for OracleProbe {
    fn snapshot(&self, root: &HostDirectory) -> std::io::Result<StorageSnapshot> {
        Ok(StorageSnapshot {
            volume_identity: root.export_facts()?.volume_identity,
            available_bytes: self.0,
            read_only: false,
        })
    }
}

/// The owners one daemon start opens over the root.
struct Stores {
    targets: TargetStore,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    sessions: SessionStore,
    holds: DeviceHolds,
    claims: StorageClaims,
}

/// A daemon over the root, composed as the standalone daemon composes it:
/// the account-fixed Job root (`store`), the capability store inside it, the
/// Session owner, the Target owner and the fake.
struct Daemon {
    fixture: PathBuf,
    root: PathBuf,
    default_root: PathBuf,
    provenance: Value,
    dispatch: FakeHdc,
    probe: OracleProbe,
    stores: Option<Stores>,
}

/// A control answer as the oracles record it: a refusal carries details only
/// when it has any.
fn answer(outcome: Result<Value, WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    }
}

impl Daemon {
    /// A daemon over `root` for the oracle `window`, its owners open.
    fn open(window: &str, root: &Path) -> Self {
        let mut daemon = Self::attach(window, root);
        daemon.stores = Some(daemon.compose());
        daemon
    }

    /// A daemon over the root another process left, with no owner open yet.
    fn attach(window: &str, root: &Path) -> Self {
        let fixture = fixture(window);
        let provenance = document(&fixture.join("provenance.json"));
        Self {
            dispatch: FakeHdc {
                log: root.join("hdc-invocations.log"),
            },
            probe: OracleProbe(provenance["availableBytes"].as_u64().unwrap()),
            default_root: root.join("store"),
            root: root.to_path_buf(),
            fixture,
            provenance,
            stores: None,
        }
    }

    fn compose(&self) -> Stores {
        let jobs = JobStore::open_owner(&self.default_root).unwrap();
        Stores {
            targets: TargetStore::open(&self.root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&self.root.join("artifacts")).unwrap(),
            capabilities: CapabilityStore::open(&self.default_root.join("capabilities")).unwrap(),
            sessions: SessionStore::open(
                &self.root.join("session-owner"),
                &self.root.join("Sessions"),
            )
            .unwrap(),
            holds: DeviceHolds::default(),
            claims: StorageClaims::default(),
            jobs,
        }
    }

    fn stores(&self) -> &Stores {
        self.stores.as_ref().unwrap()
    }

    /// The daemon started again over the same root: the old owners closed,
    /// new ones opened, then `recoverActiveJobs`.
    fn restart(&mut self) -> RecoveredJobs {
        drop(self.stores.take());
        let stores = self.compose();
        let recovered =
            recover_active_jobs(&stores.jobs, Some(&stores.capabilities), fixed_now).unwrap();
        self.stores = Some(stores);
        recovered
    }

    fn close(&mut self) {
        drop(self.stores.take());
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.root.join("hdc-invocations.log")).unwrap()
    }

    fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.stores().targets,
            dispatch,
            receive_root: None,
            tool_sha256: self.provenance["hdcSHA256"].as_str().unwrap(),
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    fn authority(&self) -> MutationAuthority<'_> {
        let stores = self.stores();
        MutationAuthority {
            default_root: &self.default_root,
            sessions: Some(&stores.sessions),
            capabilities: &stores.capabilities,
            holds: &stores.holds,
        }
    }

    fn publisher(&self) -> SessionPublisher<'_> {
        let stores = self.stores();
        SessionPublisher {
            sessions: &stores.sessions,
            claims: &stores.claims,
            probe: &self.probe,
        }
    }

    fn runner<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        publisher: &'a SessionPublisher<'a>,
        now: fn() -> Option<String>,
    ) -> JobRunner<'a> {
        let stores = self.stores();
        JobRunner {
            imports: None,
            mutation: Some(MutationExecution {
                authority: self.authority(),
                state_root: &self.root,
            }),
            jobs: &stores.jobs,
            artifacts: &stores.artifacts,
            analyzer: None,
            quota: self.provenance["quotaBytes"].as_u64().unwrap(),
            home: self.provenance["home"].as_str().unwrap(),
            now,
            precise_now: fixed_precise_now,
            sessions: Some(publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(hdc),
            workspace: None,
        }
    }

    fn run_on(
        &self,
        dispatch: &(dyn HdcDispatch + Sync),
        params: &Map<String, Value>,
        now: fn() -> Option<String>,
    ) -> Value {
        let hdc = self.hdc(dispatch);
        let publisher = self.publisher();
        let runner = self.runner(&hdc, &publisher, now);
        answer(runner.handle(params).map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(refusal.details),
        }))
    }

    /// One recorded request answered by the Rust owner that serves it.
    fn answer(&self, exchange: &Value) -> Value {
        let stores = self.stores();
        let method = exchange["method"].as_str().unwrap();
        let params = exchange["params"].as_object().unwrap();
        match method {
            "job.submit" => {
                let hdc = self.hdc(&self.dispatch);
                let admitter = JobAdmitter {
                    planner: JobPlanner {
                        imports: None,
                        artifacts: Some(&stores.artifacts),
                        analyzer: None,
                        state_root: &self.root,
                        hdc: Some(&hdc),
                        workspace: None,
                    },
                    jobs: &stores.jobs,
                    now: fixed_now,
                    authority: Some(self.authority()),
                };
                answer(admitter.handle(params).map_err(|refusal| WireError {
                    code: refusal.code.into(),
                    message: refusal.message,
                    details: Some(if refusal.proven {
                        Map::from_iter([
                            ("phase".into(), json!("preAdmission")),
                            ("newDispatchCount".into(), json!(0)),
                        ])
                    } else {
                        Map::new()
                    }),
                }))
            }
            "job.reconcile" => {
                let hdc = self.hdc(&self.dispatch);
                let publisher = self.publisher();
                let runner = self.runner(&hdc, &publisher, fixed_now);
                answer(
                    JobReconciler {
                        jobs: &stores.jobs,
                        artifacts: &stores.artifacts,
                        imports: None,
                        now: fixed_now,
                        sessions: Some(&publisher),
                        hdc: Some(&hdc),
                        capabilities: Some(&stores.capabilities),
                        runner: Some(&runner),
                    }
                    .handle(params),
                )
            }
            "job.status" | "job.show" => answer(stores.jobs.handle_resource(method, params)),
            "job.result" | "job.evidence" => answer(
                JobResultReader {
                    jobs: &stores.jobs,
                    artifacts: &stores.artifacts,
                }
                .handle(method, params),
            ),
            "capability.list" | "capability.inspect" => answer(
                stores
                    .capabilities
                    .handle(method, params)
                    .map_err(|refusal| WireError {
                        code: refusal.code.into(),
                        message: refusal.message,
                        details: None,
                    }),
            ),
            other => panic!("{}: the oracle sent {other}", exchange["name"]),
        }
    }

    /// The store snapshot the oracle recorded under `prefix`: the Job index
    /// and every Job file (records read machine-independently) and every file
    /// of the capability store, byte for byte.
    fn assert_snapshot(&self, prefix: &str) {
        let recorded = self.fixture.join(prefix);
        assert_eq!(
            index(&self.default_root),
            document(&recorded.join("index.json")),
            "{prefix}/index.json"
        );
        let actual = files(&self.default_root.join("jobs"), "jobs");
        let expected = files(&recorded.join("jobs"), "jobs");
        assert_same(&actual, &expected, prefix);
        let actual = files(&self.default_root.join("capabilities"), "capabilities");
        let expected = files(&recorded.join("capabilities"), "capabilities");
        assert_same(&actual, &expected, prefix);
    }
}

fn assert_same(actual: &BTreeMap<String, Vec<u8>>, expected: &BTreeMap<String, Vec<u8>>, at: &str) {
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>(),
        "{at}"
    );
    for (path, bytes) in expected {
        assert_eq!(
            String::from_utf8_lossy(&actual[path]),
            String::from_utf8_lossy(bytes),
            "{at}: {path}"
        );
    }
}

/// Every file below `base` as `prefix/<relative path>` (forward slashes),
/// a Job record read machine-independently; directories as `prefix/<path>/`.
fn files(base: &Path, prefix: &str) -> BTreeMap<String, Vec<u8>> {
    let mut found = BTreeMap::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        let Ok(entries) = fs::read_dir(base.join(&relative)) else {
            continue;
        };
        for entry in entries {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            let name = format!("{prefix}/{}", path.to_str().unwrap().replace('\\', "/"));
            if entry.file_type().unwrap().is_dir() {
                pending.push(path);
                continue;
            }
            let bytes = fs::read(base.join(&path)).unwrap();
            found.insert(
                name,
                if path.file_name().unwrap() == "job-record.json" {
                    machine_independent(&bytes)
                } else {
                    bytes
                },
            );
        }
    }
    found
}

/// Every entry below `base` as `prefix/<relative path>` and its kind.
fn tree(base: &Path, prefix: &str, into: &mut Vec<(String, &'static str)>) {
    let mut entries = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        let Ok(listing) = fs::read_dir(base.join(&relative)) else {
            continue;
        };
        for entry in listing {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                pending.push(path.clone());
            }
            entries.push(path);
        }
    }
    entries.sort();
    for relative in entries {
        let kind = if base.join(&relative).is_dir() {
            "directory"
        } else {
            "file"
        };
        into.push((
            format!("{prefix}/{}", relative.to_str().unwrap().replace('\\', "/")),
            kind,
        ));
    }
}

/// A Job record's publication marker names this machine's volume, device,
/// inode and claim generation; each reads as a fixed label, and a refused
/// marker's blank or zero value stays as it is.
fn machine_independent(bytes: &[u8]) -> Vec<u8> {
    let mut text = String::from_utf8(bytes.to_vec()).unwrap();
    for key in MACHINE_FACTS {
        let needle = format!("\"{key}\"");
        let label = format!("<{key}>");
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(at) = rest.find(&needle) {
            let (head, tail) = rest.split_at(at + needle.len());
            out.push_str(head);
            rest = tail;
            let Some(value) = tail
                .trim_start_matches(' ')
                .strip_prefix(':')
                .map(|after| after.trim_start_matches(' '))
                .and_then(|after| after.strip_prefix('"'))
            else {
                continue;
            };
            let Some(end) = value.find('"') else {
                continue;
            };
            out.push_str(&tail[..tail.len() - value.len()]);
            let current = &value[..end];
            out.push_str(if current.is_empty() || current == "0" {
                current
            } else {
                &label
            });
            rest = &value[end..];
        }
        out.push_str(rest);
        text = out;
    }
    text.into_bytes()
}

/// The facts the Swift oracle records of the Job index, each record's
/// digest taken over its machine-independent reading.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), true, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(&machine_independent(bytes))),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows})
}

/// The fake's dispatcher, which dies where the window names.
struct Dying<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    window: &'static str,
    journal: PathBuf,
}

impl HdcDispatch for Dying<'_> {
    fn mutation_identity_current(&self) -> bool {
        // The consume path opens with this check, after every evidence
        // step's outcome is durable and before anything is consumed.
        if self.window == "beforeConsume"
            && fs::read_to_string(&self.journal)
                .is_ok_and(|journal| journal.contains("\"outcome-read-evidence-firmware\""))
        {
            std::process::exit(exit_code(self.window));
        }
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let launches = |argument: &str| plan.arguments.iter().any(|a| a == argument);
        if (self.window == "afterReadOnlyIntent" && launches("const.product.name"))
            || (self.window == "afterIntent" && launches("uinput"))
        {
            std::process::exit(exit_code(self.window));
        }
        self.inner.dispatch(plan)
    }
}

/// The Job record the `afterConsume` clock watches.
static EVIDENCE: OnceLock<PathBuf> = OnceLock::new();

/// The oracle's clock, until the Job record on disk holds the consumed
/// capability's evidence: the next read is where `afterConsume` dies.
fn dying_clock() -> Option<String> {
    if let Some(record) = EVIDENCE.get()
        && fs::read_to_string(record).is_ok_and(|text| text.contains("\"runtimeCapability\""))
    {
        std::process::exit(exit_code("afterConsume"));
    }
    fixed_now()
}

/// The Rust daemon's run of the oracle's tap, dying at the window the
/// environment names over the root it names. Run only as the child of the
/// test below.
#[test]
fn crash_window_child() {
    let (Ok(window), Ok(root)) = (std::env::var(CHILD), std::env::var(ROOT)) else {
        return;
    };
    let window = WINDOWS.iter().find(|(name, _)| *name == window).unwrap().0;
    let daemon = Daemon::open(window, Path::new(&root));
    let cases = document(&daemon.fixture.join("cases.json"));
    let job = cases["job"]["jobId"].as_str().unwrap();
    let submit = exchange(&cases, "tap.submit");
    assert_eq!(
        daemon.answer(submit),
        submit["answer"],
        "{window}: tap.submit"
    );
    let jobs = daemon.default_root.join("jobs").join(job);
    let dying = Dying {
        inner: &daemon.dispatch,
        window,
        journal: jobs.join("journal.jsonl"),
    };
    let now: fn() -> Option<String> = if window == "afterConsume" {
        EVIDENCE.set(jobs.join("job-record.json")).unwrap();
        dying_clock
    } else {
        fixed_now
    };
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    let ran = daemon.run_on(&dying, &params, now);
    panic!("{window}: the run ended without reaching its window: {ran}");
}

/// The one leftover Swift's store does not share where no Session was
/// published (as `crash_window.rs` excuses it): the Rust admission's
/// storage-state check leaves the storage owner's and the retention catalog's
/// lock files and an empty catalog, the bytes Swift writes when it first
/// publishes; they are removed before the tree is compared.
fn excuse_admission_session_files(daemon: &Daemon, window: &str) {
    let files = [
        ("session-owner/.session-storage.lock", "session-owner"),
        ("sessions/.arkdeck-retention-catalog.json", "Sessions"),
        ("sessions/.arkdeck-retention-catalog.lock", "Sessions"),
    ];
    let tree = document(&daemon.fixture.join("tree.json"));
    let recorded = |path: &str| {
        tree.as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["path"] == path)
    };
    if files.iter().all(|(path, _)| recorded(path)) {
        return;
    }
    assert!(
        files.iter().all(|(path, _)| !recorded(path)),
        "{window}: Swift left only some of the Session owner's files"
    );
    let swift = fixture("afterReadOnlyIntent");
    for (path, directory) in files {
        let name = path.rsplit('/').next().unwrap();
        let actual = daemon.root.join(directory).join(name);
        assert_eq!(
            fs::read(&actual).unwrap(),
            fs::read(swift.join(path)).unwrap(),
            "{window}: {path}"
        );
        fs::remove_file(actual).unwrap();
    }
}

/// Everything the replay left below the root against what the oracle
/// recorded: the Job index, every entry's path and kind (NTFS keeps no POSIX
/// mode), and every file of the Job store, the capability store, the Sessions
/// root and the storage owner.
fn assert_leftovers(daemon: &Daemon) {
    let fixture = &daemon.fixture;
    assert_eq!(
        index(&daemon.default_root),
        document(&fixture.join("store/index.json"))
    );
    let bases = [
        (daemon.default_root.join("jobs"), "store/jobs"),
        (
            daemon.default_root.join("capabilities"),
            "store/capabilities",
        ),
        (daemon.root.join("Sessions"), "sessions"),
        (daemon.root.join("session-owner"), "session-owner"),
    ];
    let mut entries = Vec::new();
    let mut actual = BTreeMap::new();
    for (base, prefix) in &bases {
        tree(base, prefix, &mut entries);
        actual.extend(files(base, prefix));
    }
    let recorded_tree: Vec<(String, String)> = document(&fixture.join("tree.json"))
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            (
                entry["path"].as_str().unwrap().to_owned(),
                entry["kind"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    let entries: Vec<(String, String)> = entries
        .into_iter()
        .map(|(path, kind)| (path, kind.to_owned()))
        .collect();
    assert_eq!(entries, recorded_tree, "the tree");
    let mut recorded = BTreeMap::new();
    for (path, _) in document(&fixture.join("provenance.json"))["files"]
        .as_object()
        .unwrap()
    {
        if [
            "store/jobs/",
            "store/capabilities/",
            "sessions/",
            "session-owner/",
        ]
        .iter()
        .any(|prefix| path.starts_with(prefix))
        {
            recorded.insert(path.clone(), fs::read(fixture.join(path)).unwrap());
        }
    }
    let recorded: BTreeMap<String, Vec<u8>> = recorded
        .into_iter()
        .map(|(path, bytes)| {
            let bytes = if path.ends_with("job-record.json") {
                machine_independent(&bytes)
            } else {
                bytes
            };
            (path, bytes)
        })
        .collect();
    assert_same(&actual, &recorded, "leftovers");
}

#[test]
fn rust_dies_at_each_crash_window_and_recovers_as_swift_does_on_windows() {
    let mut differences = Vec::new();
    for (window, code) in WINDOWS {
        let root = fresh_root(window);
        let fixture = fixture(window);
        lay_down(&fixture, &root);
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "crash_window_child", "--nocapture"])
            .env(CHILD, window)
            .env(ROOT, &root)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(code),
            "{window}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let mut daemon = Daemon::attach(window, &root);
        let cases = document(&fixture.join("cases.json"));

        // The store the dead run left is the one Swift's daemon left.
        daemon.assert_snapshot("crash");
        let at_death = daemon.calls();
        let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
        assert_eq!(
            swift.len() as u64,
            cases["invocationsAtCrash"].as_u64().unwrap(),
            "{window}"
        );
        let answered = swift.strip_prefix(at_death.as_str()).unwrap_or_else(|| {
            panic!("{window}: the Rust calls are not Swift's first calls:\n{at_death}\n{swift}")
        });
        match window {
            "afterReadOnlyIntent" => assert!(answered.contains("const.product.name"), "{window}"),
            "afterIntent" => assert!(answered.contains("uinput"), "{window}"),
            _ => assert!(answered.is_empty(), "{window}: {answered}"),
        }

        // The daemon starts again over that root, and then once more.
        for start in cases["starts"].as_array().unwrap() {
            let recovered = daemon.restart();
            assert!(recovered.quarantined.is_empty() && recovered.refused.is_empty());
            assert_eq!(
                json!(recovered.statuses),
                start["recovered"],
                "{window}: {}",
                start["name"]
            );
            daemon.assert_snapshot(start["name"].as_str().unwrap());
        }
        assert_eq!(daemon.calls(), at_death, "{window}: a start dispatched");

        // Every request after the death, each reconcile followed by its store.
        for exchange in cases["exchanges"].as_array().unwrap() {
            if exchange["name"] == "tap.submit" {
                continue;
            }
            let actual = daemon.answer(exchange);
            if actual != exchange["answer"] {
                differences.push(format!(
                    "{window} {}:\n  swift {}\n  rust  {actual}",
                    exchange["name"], exchange["answer"]
                ));
            }
            if exchange["method"] == "job.reconcile" {
                daemon.assert_snapshot(&format!("steps/{}", exchange["name"].as_str().unwrap()));
            }
        }
        assert_eq!(
            daemon.calls(),
            at_death,
            "{window}: a reconcile or read dispatched"
        );

        // What the replay leaves: the Target document and the Job store,
        // capability store, Sessions, storage owner and tree.
        daemon.close();
        excuse_admission_session_files(&daemon, window);
        assert_eq!(
            fs::read(root.join("targets-state/targets.json")).unwrap(),
            fs::read(fixture.join("targets-state/targets.json")).unwrap(),
            "{window}: the Target document"
        );
        assert_leftovers(&daemon);
        let _ = fs::remove_dir_all(&root);
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}
