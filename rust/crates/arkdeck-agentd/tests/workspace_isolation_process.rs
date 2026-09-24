//! The isolated Rust daemon makes a Runtime-owned copy of a registered
//! workspace project and adopts it again when it restarts (TASK-XPA-015, M3),
//! through its control socket as a caller meets it: a project registered
//! while a daemon runs is refused until the daemon restarts; after the
//! restart `workspace.prepare-isolated-copy@1` plans, is admitted under the
//! default read-only policy, runs and publishes its product; after another
//! restart the copy resolves to its source's registration again, and a copy
//! whose tree moved is reported and stays unresolvable. Host-only: no HDC, no
//! Swift daemon, no device.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const PROFILE: &str = "waterflow-openharmony@1";

fn private_directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}

/// The daemon's root, removed however the test ends.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The isolated daemon over `root`, serving once its start has composed.
struct Daemon(Child);

impl Daemon {
    fn start(root: &Path) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_ENDPOINT", root.join("control.sock"))
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(root.join("control.sock")).is_err() {
            assert!(child.try_wait().unwrap().is_none(), "daemon exited");
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }

    /// Stops the daemon and returns the copies it reported it could not
    /// adopt, as it printed them.
    fn stop(mut self) -> Vec<String> {
        let _ = self.0.kill();
        let _ = self.0.wait();
        let mut printed = String::new();
        if let Some(mut stdout) = self.0.stdout.take() {
            stdout.read_to_string(&mut printed).unwrap();
        }
        printed
            .lines()
            .filter(|line| line.starts_with("runtime workspace"))
            .map(str::to_owned)
            .collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// One control frame, answered.
fn request(root: &Path, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(root.join("control.sock")).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "workspace-isolation-process", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn prepare(project: &str, revision: &str, label: &str) -> Value {
    json!({"requestJson": json!({
        "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "operation": {"id": "workspace.prepare-isolated-copy", "version": 1},
        "target": {"targetId": "workspace-host"},
        "inputs": {"projectRef": project, "expectedWorkspaceRevision": revision,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"]},
        "requestedOutputs": ["derivedArtifacts"],
    }).to_string()})
}

/// The revision Swift's provider measures for the WaterFlow profile over
/// these files.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// Whether this contract view publishes the null `workspaceKind` every
/// projection of a workspace Job carries. `check-contracts.py`'s published
/// view builds this checkout against the merge base's schemas, which refuse
/// it; there the control plane answers the run as a nonconforming result.
fn publishes_workspace_jobs() -> bool {
    let schema: Value = serde_json::from_str(
        arkdeck_contract::METHOD_SCHEMAS
            .iter()
            .find(|(name, _)| *name == "job.run")
            .unwrap()
            .1,
    )
    .unwrap();
    schema["$defs"]["result"]["properties"]["workspaceKind"]["type"] != "string"
}

fn register(root: &Path, request_id: &str, project: &Path) -> String {
    let answer = request(
        root,
        "workspace.project.register",
        json!({"registrationRequestId": request_id, "kind": "openharmony",
            "root": project.to_str().unwrap()}),
    );
    assert_eq!(answer["ok"], true, "{answer}");
    answer["result"]["projectRef"].as_str().unwrap().to_owned()
}

#[test]
fn the_isolated_daemon_copies_a_registered_project_and_adopts_the_copy_after_restart() {
    let scratch = Scratch(PathBuf::from(format!(
        "/private/tmp/arkdeck-workspace-isolation-process-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    )));
    let root = scratch.0.clone();
    private_directory(&root);
    let project = root.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "old\n"),
        ("entry/src/main/ets/Other.ets", "other\n"),
    ] {
        fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        fs::write(project.join(path), bytes).unwrap();
    }
    let source_revision = revision(&[
        ("entry/src/main/ets/Other.ets", b"other\n"),
        ("entry/src/main/ets/pages/Index.ets", b"old\n"),
    ]);

    // A project registered while the daemon runs is not composed by it.
    let daemon = Daemon::start(&root);
    let registered = register(&root, "workspace-isolation-process", &project);
    let refused = request(
        &root,
        "job.plan",
        prepare(&registered, &source_revision, "before-restart"),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(
        refused["error"]["code"], "operationUnavailable",
        "{refused}"
    );
    assert_eq!(daemon.stop(), Vec::<String>::new());

    // After a restart the copy is planned, admitted, made and published.
    let daemon = Daemon::start(&root);
    let params = prepare(&registered, &source_revision, "isolate");
    let planned = request(&root, "job.plan", params.clone());
    assert_eq!(planned["ok"], true, "{planned}");
    assert_eq!(planned["result"]["authorizationPolicy"], "defaultReadOnly");
    assert_eq!(planned["result"]["effectiveEffect"], "hostOnly");
    let submitted = request(&root, "job.submit", params);
    assert_eq!(submitted["ok"], true, "{submitted}");
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = request(&root, "job.run", json!({"jobId": job}));
    if !publishes_workspace_jobs() {
        assert_eq!(ran["error"]["code"], "internalError", "{ran}");
        assert_eq!(
            ran["error"]["message"],
            "the result does not conform to the current contract"
        );
        return;
    }
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    // The standalone daemon publishes every terminal Job as a Session, a host
    // Session for this one.
    assert_eq!(
        ran["result"]["sessionPublication"]["state"], "published",
        "{ran}"
    );
    // A workspace Job belongs to no App workspace: every status surface
    // answers it with a null workspace kind, as Swift answers it.
    assert_eq!(ran["result"]["workspaceKind"], Value::Null, "{ran}");
    for method in ["job.status", "job.show", "job.reconcile", "job.list"] {
        let params = if method == "job.list" {
            json!({})
        } else {
            json!({"jobId": job})
        };
        let answer = request(&root, method, params);
        assert_eq!(answer["ok"], true, "{method}: {answer}");
    }
    let result = request(&root, "job.result", json!({"jobId": job}));
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(
        result["result"]["artifacts"][0]["name"],
        "isolated-workspace.json"
    );
    assert_eq!(
        result["result"]["evidence"]["authority"]["kind"],
        "defaultReadOnlyPolicy"
    );
    assert_eq!(daemon.stop(), Vec::<String>::new());
    let digest = sha256_hex(
        format!(
            "runtime-{job}|{registered}|{}",
            revision(&[("entry/src/main/ets/pages/Index.ets", b"old\n")])
        )
        .as_bytes(),
    );
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let copied = root
        .join("evolution-workspaces")
        .join(&workspace_id)
        .join("workspace");
    assert_eq!(
        fs::read(copied.join("entry/src/main/ets/pages/Index.ets")).unwrap(),
        b"old\n"
    );

    // After another restart the copy resolves to its source's registration:
    // a Job naming it acquires the source project, and the copy is refused
    // only because a copy is never copied again.
    let daemon = Daemon::start(&root);
    let copy_revision = revision(&[("entry/src/main/ets/pages/Index.ets", b"old\n")]);
    let again = request(
        &root,
        "job.plan",
        prepare(&copy, &copy_revision, "copy-of-copy"),
    );
    assert_eq!(
        again["error"]["message"],
        "typed plan preflight failed before authorization: workspace.presetUnavailable",
        "{again}"
    );
    assert_eq!(daemon.stop(), Vec::<String>::new());

    // A copy whose tree moved is named when the daemon starts and stays
    // unresolvable: a Job naming it acquires nothing.
    fs::write(copied.join("entry/src/main/ets/pages/Index.ets"), "moved\n").unwrap();
    let daemon = Daemon::start(&root);
    let unknown = request(
        &root,
        "job.plan",
        prepare(&copy, &copy_revision, "moved-copy"),
    );
    assert_eq!(unknown["error"]["code"], "invalidInput", "{unknown}");
    assert_eq!(
        unknown["error"]["message"],
        "workspace project is not registered"
    );
    assert_eq!(
        daemon.stop(),
        [format!(
            "runtime workspace not adopted for {workspace_id}:revision"
        )]
    );
}
