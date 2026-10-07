//! What the replays of the Swift oracles recorded over the shared fake HDC
//! (`HDCOracleFake`, at the fixed root `support/debug_hap.rs` rebuilds) share
//! when their Jobs mutate a device under Runtime capabilities: the owners a
//! daemon composes over that root, the code-sign helper where the oracle
//! composed one, and the replay of every recorded request, each run while the
//! fake answers in the mode the oracle names — its application state cleared
//! first before a Job's run, as each oracle clears it, and left as the runs
//! left it for the cleanup debt continuations. What the replay leaves is
//! Swift's byte for byte.
use super::native_library::code_sign_helper;
use super::{OracleProbe, debug_hap, document, fixed_now, fixed_precise_now};
use arkdeck_contract::{sha256_hex, validate_method_value};
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobRunner, JobStore, MutationAuthority, MutationExecution, SessionPublisher, SessionStore,
    StorageClaims, TargetStore,
};
use arkdeck_hoststore::{JobResultReader, list_cleanup_debt};
#[cfg(unix)]
use arkdeck_platform::VerifiedTool;
#[cfg(unix)]
use arkdeck_provider_hdc::ProcessDispatch;
use arkdeck_provider_hdc::{CodeSignHelper, HdcDispatch};

/// What dispatches to the shared fake: its driver as a real subprocess on
/// macOS; on Windows its answers in process.
#[cfg(unix)]
pub type FakeDispatch = ProcessDispatch;
#[cfg(windows)]
pub type FakeDispatch = super::oracle_fake::OracleFake;
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

#[path = "native_readback.rs"]
pub mod native_readback;

#[path = "native_current.rs"]
pub mod native_current;

/// The fake's application state, which each oracle clears before every Job
/// it runs: whether a package is installed, whether the ability runs, and
/// whether a new native library is published.
const APPLICATION_STATE: [&str; 3] = ["device-installed", "device-running", "device-published"];

pub fn refused(code: &str, message: String, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

pub fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

/// An answer as the daemon's control layer admits it: a result under the
/// method's result schema, a refusal's code and details under its own.
pub fn assert_conforms(method: &str, answer: &Value) {
    let conforms = if answer["ok"] == true {
        validate_method_value(method, "result", &answer["result"]).is_ok()
    } else {
        validate_method_value(method, "errorCode", &answer["error"]["code"]).is_ok()
            && answer["error"].get("details").is_none_or(|details| {
                validate_method_value(method, "errorDetails", details).is_ok()
            })
    };
    assert!(conforms, "{method}: {answer}");
}

pub fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// The owners a daemon composes over the rebuilt root. The Job owner's root
/// is the account-fixed one its mutation authority names, and the capability
/// store is opened inside it once the Job owner holds it, as the daemon opens
/// it (a new Job repository takes only an empty directory). The HDC
/// composition carries the code-sign helper the oracle composed, if any.
pub struct Owners {
    pub root: PathBuf,
    pub default_root: PathBuf,
    pub digest: String,
    pub provenance: Value,
    pub targets: TargetStore,
    pub artifacts: ArtifactReadStore,
    pub jobs: JobStore,
    pub capabilities: CapabilityStore,
    pub sessions: SessionStore,
    pub dispatch: FakeDispatch,
    pub holds: DeviceHolds,
    pub claims: StorageClaims,
    pub probe: OracleProbe,
    pub helper: Option<CodeSignHelper>,
    /// Where received files land, when the oracle fixed a host receive root
    /// (`provenance.json`'s `receiveRoot`, the fake's root's `receive`).
    pub receive_root: Option<PathBuf>,
}

impl Owners {
    /// The owners over the root rebuilt from `fixture`; the caller holds
    /// [`debug_hap::exclusive`].
    pub fn open(fixture: &Path) -> Self {
        let provenance = document(fixture, "provenance.json");
        let cases = document(fixture, "cases.json");
        let root = debug_hap::rebuild(fixture);
        // The resources the oracle's answers read beside them.
        if fixture.join("resources").is_dir() {
            debug_hap::private_dir(&root.join("resources"));
            for resource in fs::read_dir(fixture.join("resources")).unwrap() {
                let resource = resource.unwrap().path();
                fs::copy(
                    &resource,
                    root.join("resources").join(resource.file_name().unwrap()),
                )
                .unwrap();
            }
        }
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let default_root = root.join("store");
        let jobs = JobStore::open_owner(&default_root).unwrap();
        let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
        Self {
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs,
            capabilities,
            sessions: SessionStore::open(&root.join("session-owner"), &root.join("Sessions"))
                .unwrap(),
            #[cfg(unix)]
            dispatch: ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            ),
            // The driver's answers cannot run on Windows: the same answers in
            // process, over the same root (`oracle_fake.rs`).
            #[cfg(windows)]
            dispatch: super::oracle_fake::OracleFake::new(
                &root,
                super::oracle_fake::Answers::of(
                    &fs::read_to_string(root.join("hdc-answers.sh")).unwrap(),
                ),
            ),
            holds: DeviceHolds::default(),
            claims: StorageClaims::default(),
            probe: OracleProbe::new(&provenance),
            helper: cases
                .get("codeSignHelper")
                .map(|_| code_sign_helper(&cases, &root)),
            receive_root: provenance.get("receiveRoot").map(|_| root.join("receive")),
            provenance,
            digest,
            default_root,
            root,
        }
    }

    pub fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.targets,
            dispatch,
            receive_root: self.receive_root.as_deref(),
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: self.helper.as_ref(),
        }
    }

    /// The mutation authority of the owner whose account-fixed Job root is
    /// `default_root`.
    pub fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
        MutationAuthority {
            default_root,
            sessions: Some(&self.sessions),
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    pub fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
            workspace: None,
        }
    }

    pub fn admitter<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        default_root: &'a Path,
    ) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority(default_root)),
        }
    }

    pub fn publisher(&self) -> SessionPublisher<'_> {
        SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        }
    }

    /// The runner, with or without the mutation owner a device mutation
    /// consumes its use through.
    pub fn runner<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        publisher: &'a SessionPublisher<'a>,
        owned: bool,
    ) -> JobRunner<'a> {
        JobRunner {
            imports: None,
            mutation: owned.then(|| MutationExecution {
                authority: self.authority(&self.default_root),
                state_root: &self.root,
            }),
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            analyzer: None,
            quota: self.provenance["quotaBytes"].as_u64().unwrap(),
            home: self.provenance["home"].as_str().unwrap(),
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(hdc),
            workspace: None,
        }
    }

    pub fn job_file(&self, job: &str, name: &str) -> PathBuf {
        self.default_root.join("jobs").join(job).join(name)
    }

    pub fn record(&self, job: &str) -> Value {
        serde_json::from_slice(&fs::read(self.job_file(job, "job-record.json")).unwrap()).unwrap()
    }

    pub fn calls(&self) -> String {
        fs::read_to_string(self.root.join("hdc-invocations.log")).unwrap()
    }

    /// The fake answers the next Job in `mode`, its application state cleared
    /// first, as each oracle clears it before every Job it runs.
    pub fn mode(&self, mode: &str) {
        for state in APPLICATION_STATE {
            let _ = fs::remove_file(self.root.join(state));
        }
        self.set_mode(mode);
    }

    /// The fake answers in `mode` from now on, over the application state the
    /// runs left (Swift `HDCOracleFake.setMode`).
    pub fn set_mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }
}

/// The members of `job.run`, `job.result` and `job.evidence` answers that a
/// plan digest derives: the Runtime capability's reference and a use's
/// consumption fingerprint, beside the store's own (`debug_hap::DERIVED`), and
/// a Session manifest's digest, whose bytes the leftovers compare relabelled.
const ANSWER_DERIVED: [&str; 5] = [
    "manifestSha256",
    "planDigest",
    "consumptionFingerprintSha256",
    "capabilityId",
    "reference",
];

/// The seals whose `sha256` is the digest of a Journal prefix the leftovers
/// compare relabelled, which names a plan digest's derived values.
const SEALS: [&str; 2] = ["checkpointSeal", "journalSeal"];

/// Every recorded request of the oracle `name`, answered in order by the Rust
/// owners: `exchanges` of them, each answered as Swift answered it, message
/// included, the cleanup debt lists and continuations among them. The fake
/// must have received Swift's `calls` calls in order, each Job must have
/// consumed its one use before its first mutation (every later mutation of
/// its run, and a continuation's retry, continued under it), and everything
/// the replay leaves below the root must be Swift's byte for byte: a
/// continued Job's record with its recovery load's `recovered: journal
/// clean` and its settled residue, and the ledger with its settlements.
///
/// On Windows the fake answers in process, and what names a host path below
/// the replay's root is read in the oracle's spelling (its fixed macOS root,
/// `/` between components), with the plan digests and the values derived
/// from them read as Swift's (`debug_hap::HostLabels`); every other byte
/// must be Swift's. On macOS nothing is respelled or relabelled.
pub fn assert_replays(name: &str, exchanges: usize, calls: usize) {
    replay(name, exchanges, calls, Mutations::Owned);
}

/// The oracle's Jobs, as [`assert_replays`] replays them.
#[derive(Clone, Copy, Eq, PartialEq)]
enum Mutations {
    /// Each Job mutates the device under its one Runtime capability use, and
    /// every answer is Swift's, message included.
    Owned,
    /// The Jobs are read-only, admitted and run with no mutation owner as the
    /// oracle ran them (`observe.device@1`, `capture.diagnostics@1`), and a
    /// refusal's message is Swift's wording (T2): reported, not compared.
    ReadOnly,
    /// The Jobs are admitted and run under the durable mutation authority, as
    /// the oracle ran them, and every answer is Swift's, message included;
    /// a Job may end before its first write, so none is required to have
    /// consumed a use (`capture.diagnostics@1`'s file and Trace legs).
    Authorized,
}

/// [`assert_replays`] for an oracle run under the mutation authority whose
/// Jobs need not each consume a use ([`Mutations::Authorized`]). Where the
/// oracle's calls ran concurrently it recorded each call's own line in
/// `hdc-calls.log`; those are compared exchange by exchange, sorted, and
/// `calls` counts them.
pub fn assert_authorized_replays(name: &str, exchanges: usize, calls: usize) {
    replay(name, exchanges, calls, Mutations::Authorized);
}

/// [`assert_replays`] for an oracle of read-only Jobs ([`Mutations::ReadOnly`]):
/// the same exchanges, calls and leftovers, with no capability store.
pub fn assert_read_only_replays(name: &str, exchanges: usize, calls: usize) {
    replay(name, exchanges, calls, Mutations::ReadOnly);
}

fn replay(name: &str, exchanges: usize, calls: usize, mutations: Mutations) {
    replay_into(name, exchanges, calls, mutations, None);
}

/// Explicit CREATE_NEW recording of the proposed current Native oracle.
/// This never updates the historical Swift fixture or a contract pin.
pub fn record_native_current(output: &Path) {
    replay_into(
        "deploy-native-library",
        40,
        240,
        Mutations::Owned,
        Some(output),
    );
}

fn replay_into(
    name: &str,
    exchanges: usize,
    calls: usize,
    mutations: Mutations,
    output: Option<&Path>,
) {
    if let Some(path) = output {
        assert!(!path.exists(), "CREATE_NEW oracle destination");
    }
    let owned = mutations != Mutations::ReadOnly;
    let _lock = debug_hap::exclusive();
    let fixture = super::fixture(name);
    let cases = document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let current = name == native_current::NAME || output.is_some();
    if output.is_some() {
        native_current::install_answers(&owners.root, &fixture);
    }
    let native_import = current.then(|| native_current::prepare_import(&owners.root));
    let hdc = owners.hdc(&owners.dispatch);
    let admitter = if owned {
        owners.admitter(&hdc, &owners.default_root)
    } else {
        JobAdmitter {
            planner: owners.planner(&hdc),
            jobs: &owners.jobs,
            now: fixed_now,
            authority: None,
        }
    };
    let publisher = owners.publisher();
    let runner = owners.runner(&hdc, &publisher, owned);
    let reader = JobResultReader {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
    };
    let root = owners.root.clone();
    let spelled = |bytes: &[u8]| -> Vec<u8> {
        // The additional native proof is asserted in full before projecting
        // it out of this one frozen pre-proof oracle comparison.
        let native;
        let bytes = if name == "deploy-native-library" && !current {
            native = native_readback::historical_bytes(bytes);
            native.as_slice()
        } else {
            bytes
        };
        // A payload that is not text names no path.
        let Ok(text) = String::from_utf8(bytes.to_vec()) else {
            return bytes.to_vec();
        };
        // The Sessions root a record names is Foundation's spelling of it
        // (`session_publication::foundation_path`): on macOS the fake's root
        // without its `/private` alias, in the document's own escaping.
        let sessions = format!(
            "\"{}\"",
            root.join("Sessions").to_string_lossy().replace('\\', r"\\")
        );
        let foundation = if text.contains(r"\/") {
            r#""\/tmp\/arkdeck-hdc-oracle\/Sessions""#
        } else {
            r#""/tmp/arkdeck-hdc-oracle/Sessions""#
        };
        let text = if cfg!(windows) || current {
            text.replace(&sessions, foundation)
        } else {
            text
        };
        let text = super::oracle_fake::oracle_spelling_json(&text, &root);
        // The platform a Session was published on is the host's own
        // (`session_publication.rs`): read as the oracle's, as the Windows
        // Session tests read it.
        super::oracle_fake::oracle_spelling(&text, &root)
            .replace("\"PLATFORM-WINDOWS@0.2.0\"", "\"PLATFORM-MACOS@0.2.0\"")
            .into_bytes()
    };
    let spelled_json = |value: &Value| -> Value {
        serde_json::from_slice(&spelled(&serde_json::to_vec(value).unwrap())).unwrap()
    };
    let mut labels = if current {
        debug_hap::HostLabels::portable()
    } else {
        debug_hap::HostLabels::default()
    };
    let swift_capabilities = if owned {
        document(&fixture, "store/capabilities/runtime-capabilities.json")
    } else {
        Value::Null
    };
    let (mut answers, mut replayed) = (Vec::new(), 0);
    let mut publication_proofs = Vec::new();
    let mut recorded_cases = cases.clone();
    // The concurrent calls' own log, each exchange's read sorted.
    let concurrent = fixture.join("hdc-calls.log").is_file();
    let (mut sorted_calls, mut seen) = (Vec::new(), 0);
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        replayed += 1;
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match owners.planner(&hdc).handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(proven())),
            },
            "job.submit" => {
                let answer = match admitter.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(
                        refusal.code,
                        refusal.message,
                        Some(if refusal.proven { proven() } else { Map::new() }),
                    ),
                };
                // The capabilities issued so far, in Swift's install order,
                // so a later request naming one names this host's.
                if let Ok(bytes) = fs::read(
                    owners
                        .default_root
                        .join("capabilities/runtime-capabilities.json"),
                ) {
                    let ours: Value = serde_json::from_slice(&bytes).unwrap();
                    labels.learn_keys(&ours, &swift_capabilities, &["capabilityID"]);
                }
                answer
            }
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    owners.mode(mode);
                }
                // What the oracle's fake keeps of an earlier Job's calls.
                let _ = fs::remove_file(owners.root.join("tag-list-read"));
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
                }
            }
            "job.result" | "job.evidence" => match reader.handle(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, error.message, error.details),
            },
            "job.show" => match owners.jobs.handle_resource(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, error.message, error.details),
            },
            "artifact.list" => {
                let jobs = &owners.jobs;
                match owners
                    .artifacts
                    .handle_list(params, |job| jobs.read_snapshot(job).map(|_| ()))
                {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            "capability.list" | "capability.inspect" => {
                let params = labels.host_json(&Value::Object(params.clone()));
                if output.is_some() {
                    recorded_cases["exchanges"][replayed - 1]["params"] = params.clone();
                }
                match owners
                    .capabilities
                    .handle(method, params.as_object().unwrap())
                {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => refused(error.code, error.message, None),
                }
            }
            "cleanupDebt.list" => match list_cleanup_debt(&owners.artifacts) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(message) => refused("internalError", message, None),
            },
            // The oracle continues its debts over the state its runs left,
            // in the mode it names.
            "cleanupDebt.continue" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    owners.set_mode(mode);
                }
                match runner.continue_cleanup_debt(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            other => panic!("{name}: the oracle sent {other}"),
        };
        // What the daemon would answer passes the method's published
        // contract, as its control layer requires of every answer.
        if current || method.starts_with("cleanupDebt.") {
            assert_conforms(method, &actual);
        }
        if current && method == "job.run" && exchange.get("mode").is_some() {
            publication_proofs.push(native_current::publication_proof(
                &owners,
                native_import.as_ref().unwrap(),
                params["jobId"].as_str().unwrap(),
            ));
        }
        if concurrent {
            let log = fs::read_to_string(owners.root.join("hdc-calls.log")).unwrap_or_default();
            let lines: Vec<&str> = log.lines().collect();
            let mut exchange_calls: Vec<String> = lines[seen..]
                .iter()
                .map(|line| String::from_utf8(spelled(line.as_bytes())).unwrap())
                .collect();
            exchange_calls.sort_unstable();
            sorted_calls.extend(exchange_calls.into_iter().map(|line| format!("{line}\n")));
            seen = lines.len();
        }
        // Compared once every derived value is learned, below.
        let actual = if current {
            actual
        } else {
            super::legacy_plan_answer(actual)
        };
        let actual = spelled_json(&actual);
        if output.is_some() {
            recorded_cases["exchanges"][replayed - 1]["answer"] = actual.clone();
        }
        answers.push((name.clone(), actual, exchange["answer"].clone()));
    }
    assert_eq!(replayed, exchanges, "every exchange");

    if current {
        native_current::assert_original_calls(&owners.calls(), &owners.root);
        assert_eq!(publication_proofs.len(), 5);
    }

    // The fake received Swift's calls, in order (where they ran
    // concurrently, each exchange's sorted).
    if output.is_none() && concurrent {
        let swift = fs::read_to_string(fixture.join("hdc-calls.log")).unwrap();
        assert_eq!(swift.lines().count(), calls);
        assert_eq!(sorted_calls.concat(), swift, "each exchange's calls");
    } else if output.is_none() {
        let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
        assert_eq!(swift.lines().count(), calls);
        assert_eq!(
            String::from_utf8(spelled(owners.calls().as_bytes())).unwrap(),
            swift,
            "the fake's calls"
        );
    }
    assert_eq!(
        fs::read(owners.root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );

    // Each Job consumed its one use before its first mutation; every later
    // mutation of its run, and a continuation's retry, continued under it.
    let consumes = mutations == Mutations::Owned;
    for (case, job) in cases["jobs"]
        .as_object()
        .unwrap()
        .iter()
        .filter(|_| consumes)
    {
        let timeline = owners.record(job.as_str().unwrap())["timeline"].clone();
        let consumed = timeline
            .as_array()
            .unwrap()
            .iter()
            .filter(|line| *line == "capability consumed before first mutation")
            .count();
        assert_eq!(consumed, 1, "{case}");
    }

    if let Some(output) = output {
        native_current::record(
            output,
            &fixture,
            &owners,
            &recorded_cases,
            &publication_proofs,
            spelled,
        );
        return;
    }
    if current {
        answers.extend(native_current::publication_answers(
            &fixture,
            &publication_proofs,
            &spelled,
        ));
    }

    let Owners {
        jobs,
        root: replayed_root,
        default_root,
        ..
    } = owners;
    drop(jobs);
    assert_relabelled(
        &fixture,
        &replayed_root,
        &default_root,
        &answers,
        &mut labels,
        owned,
        spelled,
    );
}

/// What every replay of these oracles checks once its exchanges are made and
/// its Job owner is closed: each recorded document beside the one the replay
/// left in its place under `root` (its Job store `default_root`), from which
/// the plan digests and what they derive are learned; then every answer,
/// read through those labels, must be the recorded one (`answers` holds each
/// exchange's name, the answer as `spelled` reads it, and the recorded
/// answer), and everything left below the root must be Swift's. A replay
/// without mutation owners (`owned` false: a read-only oracle) compares a
/// refusal without its words, which are Swift's (T2) and reported.
pub fn assert_relabelled(
    fixture: &Path,
    replayed_root: &Path,
    default_root: &Path,
    answers: &[(Value, Value, Value)],
    labels: &mut debug_hap::HostLabels,
    owned: bool,
    spelled: impl Fn(&[u8]) -> Vec<u8>,
) {
    let spelled_json = |value: &Value| -> Value {
        serde_json::from_slice(&spelled(&serde_json::to_vec(value).unwrap())).unwrap()
    };
    // Each recorded document beside the one the replay left in its place:
    // the plan digests and what they derive, read as Swift's (nothing is
    // learned on macOS).
    let mut keys = debug_hap::DERIVED.to_vec();
    keys.push("capabilityId");
    // A Session manifest names the platform it was published on: two bytes
    // longer as `PLATFORM-WINDOWS@0.2.0`, read above as the oracle's.
    keys.push("manifestByteCount");
    if fixture.file_name().and_then(|name| name.to_str()) == Some(native_current::NAME) {
        keys.push("manifestSHA256");
    }
    let documents = |bytes: &[u8]| -> Vec<Value> {
        serde_json::from_slice(bytes).map_or_else(
            |_| {
                bytes
                    .split(|byte| *byte == b'\n')
                    .filter_map(|line| serde_json::from_slice(line).ok())
                    .collect()
            },
            |document| vec![document],
        )
    };
    for (path, _) in document(fixture, "provenance.json")["files"]
        .as_object()
        .unwrap()
    {
        let actual = [
            ("store/", default_root.to_path_buf()),
            ("sessions/", replayed_root.join("Sessions")),
            ("session-owner/", replayed_root.join("session-owner")),
            ("artifacts/", replayed_root.join("artifacts")),
        ]
        .into_iter()
        .find_map(|(prefix, base)| {
            path.strip_prefix(prefix)
                .map(|rest| rest.split('/').fold(base, |path, part| path.join(part)))
        });
        let Some(actual) = actual.filter(|actual| actual.is_file()) else {
            continue;
        };
        let (ours, theirs) = (
            documents(&spelled(&fs::read(actual).unwrap())),
            documents(&fs::read(fixture.join(path)).unwrap()),
        );
        labels.learn_keys(&json!(ours), &json!(theirs), &keys);
        // A record seals its Journal by a prefix's digest; the Journal itself
        // is compared, relabelled, below.
        for seal in SEALS {
            labels.learn_within(&json!(ours), &json!(theirs), seal, "sha256");
        }
    }
    let index = if fixture.file_name().and_then(|name| name.to_str()) == Some(native_current::NAME)
    {
        super::index_normalized(default_root, &spelled)
    } else {
        super::index(default_root)
    };
    let index =
        if fixture.file_name().and_then(|name| name.to_str()) == Some("deploy-native-library") {
            native_readback::historical_index(&index, |job| {
                fs::read(default_root.join("jobs").join(job).join("job-record.json")).unwrap()
            })
        } else {
            index
        };
    labels.learn_keys(
        &spelled_json(&index),
        &document(fixture, "store/index.json"),
        &["requestHash", "recordSHA256"],
    );
    // Every answer as Swift gave it, with the plan digests and the values
    // derived from them read as Swift's.
    for (_, actual, expected) in answers {
        labels.learn(actual, expected, "/result/materializedPlanDigest");
        labels.learn_keys(actual, expected, &ANSWER_DERIVED);
    }
    let current = fixture.file_name().and_then(|name| name.to_str()) == Some(native_current::NAME);
    if current {
        native_current::learn_import_labels(fixture, replayed_root, answers, labels, &spelled);
    }
    // A read-only oracle's refusal wording is Swift's (T2): reported.
    let semantic = |answer: &Value| {
        let mut answer = answer.clone();
        if !owned && let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
            error.remove("message");
        }
        answer
    };
    let differences: Vec<String> = answers
        .iter()
        .filter_map(|(name, actual, expected)| {
            let actual = labels.swift(actual);
            if semantic(&actual) == semantic(expected) && actual != *expected {
                eprintln!(
                    "refusal wording (T2): {name}: swift {:?}, rust {:?}",
                    expected["error"]["message"], actual["error"]["message"]
                );
            }
            (semantic(&actual) != semantic(expected))
                .then(|| format!("{name}:\n  swift {expected}\n  rust  {actual}"))
        })
        .collect();
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    if current {
        native_current::assert_leftovers(
            fixture,
            replayed_root,
            default_root,
            index,
            labels,
            &spelled,
        );
        native_current::assert_import_snapshot(fixture, replayed_root, labels, &spelled);
    } else {
        super::assert_leftovers_relabelled_with_index(
            fixture,
            replayed_root,
            default_root,
            index,
            |bytes| labels.swift_bytes(&spelled(bytes)),
        );
    }
}
