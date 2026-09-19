//! The isolated daemon's startup Artifact retention sweep, as a real process.
//! Before it serves, the daemon reclaims the lapsed, unpinned Artifacts of the
//! Jobs its census does not keep and reports them once on stdout, as Swift's
//! daemon does; a sweep that fails is reported the same way and the daemon
//! serves anyway. Host-only: every Artifact is fixture data written here, and
//! no HDC, device, installed state or Swift daemon is used. Spawning children,
//! these tests keep a binary of their own.
#![cfg(target_os = "macos")]
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const LAPSED: &str = "2026-09-13T00:00:00Z";

struct Runtime {
    root: PathBuf,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-artifact-retention-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            root.clone(),
            root.join("state"),
            root.join("state/artifacts"),
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
        Self { root, child: None }
    }

    fn artifacts(&self) -> PathBuf {
        self.root.join("state/artifacts")
    }

    fn socket(&self) -> PathBuf {
        self.root.join("state/control.sock")
    }

    /// A Job directory no Job owns, with one published row per product:
    /// `(name, deadline)`, no deadline being a pin. Answers the identities.
    fn plant(&self, job: &str, products: &[(&str, Option<&str>)]) -> Vec<String> {
        let directory = self.artifacts().join(job);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let mut rows = Vec::new();
        for (name, deadline) in products {
            let bytes = format!("{job} {name}").into_bytes();
            let artifact = format!(
                "ART-{}",
                &sha256_hex(format!("{job}/{name}").as_bytes())[..32]
            );
            let payload = directory.join(&artifact);
            fs::write(&payload, &bytes).unwrap();
            fs::set_permissions(&payload, fs::Permissions::from_mode(0o400)).unwrap();
            let retention = match deadline {
                Some(deadline) => {
                    json!({"retentionClass": "default", "pinned": false, "deadlineUTC": deadline})
                }
                None => json!({"retentionClass": "pinnedUntilVerified", "pinned": true}),
            };
            rows.push(json!({
                "artifactID": artifact, "jobID": job, "sessionID": format!("session-{job}"),
                "stepID": "capture", "name": name, "mediaType": "text/plain",
                "byteCount": bytes.len(), "sha256": sha256_hex(&bytes),
                "createdAtUTC": "2026-09-06T00:00:00Z", "providerID": "hdc",
                "sourceOperation": "capture.diagnostics@1",
                "bindingSnapshot": {"targetID": "TGT-fixture"}, "privacy": "standard",
                "retention": retention, "status": {"published": {}}, "redactionApplied": false,
            }));
        }
        let identities = rows
            .iter()
            .map(|row| row["artifactID"].as_str().unwrap().to_owned())
            .collect();
        let index = directory.join("index.json");
        fs::write(
            &index,
            json!({"schemaVersion": "1.0.0", "artifacts": rows}).to_string(),
        )
        .unwrap();
        fs::set_permissions(&index, fs::Permissions::from_mode(0o600)).unwrap();
        identities
    }

    fn rows(&self, job: &str) -> Vec<String> {
        let bytes = fs::read(self.artifacts().join(job).join("index.json")).unwrap();
        serde_json::from_slice::<Value>(&bytes).unwrap()["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["artifactID"].as_str().unwrap().to_owned())
            .collect()
    }

    fn start(&mut self) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let key_text = key.to_string_lossy();
            if key_text.starts_with("ARKDECK_") || key_text.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        self.child = Some(
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.root.join("state"))
                .env("ARKDECK_ENDPOINT", self.socket())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        // Only an upper bound on startup. The socket is bound before the
        // owners are composed and the sweep runs, so startup ends at an answer.
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            assert!(
                self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited"
            );
            assert!(Instant::now() < deadline, "daemon startup timeout");
            if UnixStream::connect(self.socket()).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(self.call("health", json!({}))["ok"], true);
    }

    /// SIGTERM, then everything the daemon wrote to stdout.
    fn stop(&mut self) -> String {
        let mut child = self.child.take().unwrap();
        assert!(
            Command::new("/bin/kill")
                .args(["-TERM", &child.id().to_string()])
                .status()
                .unwrap()
                .success()
        );
        let status = child.wait().unwrap();
        assert_eq!(status.code(), Some(0), "{status:?}");
        let mut stdout = String::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut stdout)
            .unwrap();
        stdout
    }

    fn call(&self, method: &str, params: Value) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut frame = serde_json::to_vec(&json!({
            "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
            "id": "artifact-retention-process", "method": method, "params": params,
        }))
        .unwrap();
        frame.push(b'\n');
        stream.write_all(&frame).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'), "no answer to {method}: {line:?}");
        serde_json::from_str(&line).unwrap()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn lapsed_artifacts_are_reclaimed_once_before_the_daemon_serves() {
    let mut runtime = Runtime::new();
    let legacy = runtime.plant(
        "job-legacy",
        &[("hilog.txt", Some(LAPSED)), ("pinned.txt", None)],
    );
    let future = runtime.plant("job-future", &[("hilog.txt", Some("2100-01-01T00:00:00Z"))]);
    runtime.start();
    // Before its first answer the daemon had already swept: its quota counts
    // only what stayed.
    let quota = runtime.call("artifact.quota", json!({}));
    assert_eq!(quota["ok"], true, "{quota}");
    let kept_bytes = ["job-legacy pinned.txt", "job-future hilog.txt"]
        .iter()
        .map(|text| text.len() as u64)
        .sum::<u64>();
    assert_eq!(quota["result"]["usedBytes"], kept_bytes, "{quota}");
    assert_eq!(runtime.rows("job-legacy"), std::slice::from_ref(&legacy[1]));
    assert!(
        !runtime
            .artifacts()
            .join("job-legacy")
            .join(&legacy[0])
            .exists()
    );
    assert_eq!(runtime.rows("job-future"), future);
    assert_eq!(
        runtime.stop(),
        "reclaimed 1 expired artifact(s)\narkdeck-agentd stopped\n"
    );
    // Nothing is left to reclaim: a restart reports nothing.
    runtime.start();
    assert_eq!(runtime.stop(), "arkdeck-agentd stopped\n");
    assert_eq!(runtime.rows("job-legacy"), std::slice::from_ref(&legacy[1]));
}

#[test]
fn a_sweep_that_fails_is_reported_and_the_daemon_serves_anyway() {
    let mut runtime = Runtime::new();
    // job-broken sorts first; its payload no longer holds its bytes, so the
    // sweep stops there, before job-legacy.
    let broken = runtime.plant("job-broken", &[("hilog.txt", Some(LAPSED))]);
    let legacy = runtime.plant("job-legacy", &[("hilog.txt", Some(LAPSED))]);
    let payload = runtime.artifacts().join("job-broken").join(&broken[0]);
    let length = fs::metadata(&payload).unwrap().len() as usize;
    fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&payload, vec![b'x'; length]).unwrap();
    fs::set_permissions(&payload, fs::Permissions::from_mode(0o400)).unwrap();
    runtime.start();
    assert_eq!(runtime.call("health", json!({}))["ok"], true);
    let stdout = runtime.stop();
    assert!(
        stdout.starts_with("artifact retention sweep failed; the store may approach its quota: "),
        "{stdout}"
    );
    assert!(stdout.contains("digest or identity drifted"), "{stdout}");
    assert!(stdout.ends_with("\narkdeck-agentd stopped\n"), "{stdout}");
    assert_eq!(runtime.rows("job-broken"), broken);
    assert_eq!(runtime.rows("job-legacy"), legacy);
}
