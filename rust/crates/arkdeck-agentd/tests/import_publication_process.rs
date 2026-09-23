//! Host-only process integration: actual Rust CLI and isolated Rust daemon.
//! The copied Target is an explicit test fixture, never hardware evidence. No
//! HDC executable, Swift facade, installed state, or device transport is used.
#![cfg(target_os = "macos")]
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

struct Runtime {
    root: PathBuf,
    child: Option<Child>,
}
impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-import-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let targets = root.join("targets-state");
        fs::DirBuilder::new().mode(0o700).create(&targets).unwrap();
        fs::copy(
            fixture("target-adoption/targets-state/targets.json"),
            targets.join("targets.json"),
        )
        .unwrap();
        fs::set_permissions(
            targets.join("targets.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        // Isolated host analyzer fixture; it consumes the exact imported file
        // path through the production runner and returns a bounded typed answer.
        let analyzer = root.join("host-analyzer");
        fs::write(&analyzer, b"#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = --analyze-crash-ledger ] && [ -r \"$2\" ] || exit 64\n/usr/bin/head -c 4 \"$2\" >/dev/null || exit 66\nprintf '%s' '{\"analyzerRef\":\"crash-signature@1\",\"analyzerVersion\":\"arkdeck-fault-log-ledger@1\",\"schemaVersion\":\"1.0.0\",\"status\":\"answered\",\"entries\":[]}'\n").unwrap();
        fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
        let mut runtime = Self { root, child: None };
        runtime.start();
        runtime
    }
    fn socket(&self) -> PathBuf {
        self.root.join("control.sock")
    }
    fn start(&mut self) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        clean(&mut command);
        self.child = Some(
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", &self.root)
                .env("ARKDECK_ENDPOINT", self.socket())
                .env("ARKDECK_ANALYZER_PATH", self.root.join("host-analyzer"))
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while UnixStream::connect(self.socket()).is_err() {
            assert!(
                self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited"
            );
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    fn cli_at(&self, args: &[&str], socket: &Path, identity: &Path) -> Output {
        // Cargo builds both binary packages before running workspace tests.
        // Focused invocation first builds arkdeck-cli, as documented in evidence.
        let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck");
        let mut command = Command::new(cli);
        clean(&mut command);
        command
            .args(args)
            .args(["--output", "json", "--socket"])
            .arg(socket)
            .env("ARKDECK_DAEMON_PATH", identity)
            .output()
            .unwrap()
    }
    fn cli(&self, args: &[&str]) -> Value {
        let output = self.cli_at(
            args,
            &self.socket(),
            Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
        );
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(envelope["ok"], true);
        envelope["result"].clone()
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop();
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}
fn clean(command: &mut Command) {
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("ARKDECK_") {
            command.env_remove(key);
        }
    }
}
fn upload_args<'a>(kind: &'a str, request: &'a str, path: &'a str) -> Vec<&'a str> {
    vec![
        "artifact",
        "import",
        kind,
        "--import-request-id",
        request,
        "--target",
        "TGT-3ba3f5f43b92",
        "--file",
        path,
    ]
}

#[test]
fn real_cli_daemon_three_kinds_restart_and_lost_commit_reply() {
    let mut runtime = Runtime::new();
    // The exact protected-main contract before the native Swift supplement
    // cannot represent nullable patch bindings. Keep testing that old pin's
    // refusal, not the candidate's new success shape, in its isolated view.
    // Every other method-schema digest must run the complete three-format success journey.
    let inspect_schema = arkdeck_contract::METHOD_SCHEMAS
        .iter()
        .find(|(method, _)| *method == "artifact.import.inspect")
        .unwrap()
        .1;
    if arkdeck_contract::sha256_hex(inspect_schema.as_bytes())
        == "b2d5133ea4edcf927ef71857afeea275efe136b3d90fb6dd2b766a46ad3d0698"
    {
        published_contract_preserves_patch_refusal(&mut runtime);
        return;
    }
    let mut payloads = vec![
        (
            "hap",
            "test.hap",
            b"PK\x03\x04host-only exact bytes".to_vec(),
        ),
        (
            "workspace-patch",
            "change.patch",
            b"diff --git a/a b/a\n--- a/a\n+++ b/a\n+token=unchanged\n".to_vec(),
        ),
    ];
    payloads.push(("native-library","libentry.so",fs::read(fixture("deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397")).unwrap()));
    let mut results = Vec::new();
    for (kind, name, bytes) in &payloads {
        let path = runtime.root.join(name);
        fs::write(&path, bytes).unwrap();
        let result = runtime.cli(&upload_args(kind, kind, path.to_str().unwrap()));
        assert_eq!(result["state"], "committed");
        results.push(result);
    }
    runtime.stop();
    runtime.start();
    for ((kind, name, bytes), result) in payloads.iter().zip(&results) {
        let id = result["importId"].as_str().unwrap();
        let aid = result["receipt"]["artifactId"].as_str().unwrap();
        let mut args = vec!["artifact", "read", "--import", id, "--artifact", aid];
        if *kind == "workspace-patch" {
            let denied = runtime.cli_at(
                &args,
                &runtime.socket(),
                Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
            );
            assert!(!denied.status.success());
            let envelope: Value = serde_json::from_slice(&denied.stdout).unwrap();
            assert_eq!(envelope["error"]["code"], "sensitiveAccessDenied");
            args.push("--allow-sensitive");
        }
        let read = runtime.cli(&args);
        assert_eq!(
            read["base64"],
            arkdeck_contract::encode_import_chunk(bytes).unwrap()
        );
        // Retrying the original CLI import executes its request-ID inspect path.
        let path = runtime.root.join(name);
        assert_eq!(
            runtime.cli(&upload_args(kind, kind, path.to_str().unwrap())),
            *result
        );
    }
    // Proxy only the test connection and discard a *real daemon* commit reply.
    // This tests unknown transport outcome without injecting a Runtime fault.
    let proxy_path = runtime.root.join("drop-reply.sock");
    let listener = UnixListener::bind(&proxy_path).unwrap();
    fs::set_permissions(&proxy_path, fs::Permissions::from_mode(0o600)).unwrap();
    let endpoint = runtime.socket();
    listener.set_nonblocking(true).unwrap();
    let proxy = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut committed = None;
        for _ in 0..16 {
            let client = loop {
                match listener.accept() {
                    Ok((client, _)) => break client,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "proxy deadline");
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("proxy accept: {error}"),
                }
            };
            client.set_nonblocking(false).unwrap();
            client
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut client = BufReader::new(client);
            let upstream = UnixStream::connect(&endpoint).unwrap();
            upstream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut upstream = BufReader::new(upstream);
            loop {
                let mut request = String::new();
                if client.read_line(&mut request).unwrap() == 0 {
                    break;
                }
                let parsed: Value = serde_json::from_str(&request).unwrap();
                upstream.get_mut().write_all(request.as_bytes()).unwrap();
                let mut response = String::new();
                assert!(upstream.read_line(&mut response).unwrap() > 0);
                if parsed["method"] == "artifact.import.commit" {
                    assert!(
                        committed.is_none(),
                        "commit must never replay after its lost reply"
                    );
                    let response: Value = serde_json::from_str(&response).unwrap();
                    assert_eq!(response["ok"], true);
                    committed = Some(response["result"].clone());
                    break;
                }
                client.get_mut().write_all(response.as_bytes()).unwrap();
                if parsed["method"] == "artifact.import.inspect"
                    && let Some(committed) = committed
                {
                    return committed;
                }
            }
        }
        panic!("CLI never rediscovered lost commit receipt");
    });
    let path = runtime.root.join("test.hap");
    let args = upload_args("hap", "lost-reply", path.to_str().unwrap());
    let output = runtime.cli_at(&args, &proxy_path, &std::env::current_exe().unwrap());
    let expected = proxy.join().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let recovered: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(recovered["result"], expected);
    runtime.stop();
    runtime.start();
    assert_eq!(runtime.cli(&args), expected);
    assert_eq!(
        runtime.cli(&["artifact", "import", "list", "--state", "committed"])["items"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    assert_eq!(
        expected["receipt"]["owner"],
        json!({"kind":"import","id":expected["importId"]})
    );
    for result in &results {
        let listed = runtime.cli(&[
            "artifact",
            "list",
            "--import",
            result["importId"].as_str().unwrap(),
        ]);
        assert_eq!(
            listed["items"][0]["artifactId"],
            result["receipt"]["artifactId"]
        );
    }
    let first = runtime.cli(&["artifact", "import", "list", "--page-size", "1"]);
    let next = runtime.cli(&[
        "artifact",
        "import",
        "list",
        "--page-size",
        "1",
        "--cursor",
        first["nextCursor"].as_str().unwrap(),
    ]);
    assert_ne!(first["items"][0]["importId"], next["items"][0]["importId"]);
    let refused = runtime.cli_at(
        &["artifact", "import", "list", "--cursor", "foreign"],
        &runtime.socket(),
        Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
    );
    assert!(!refused.status.success());
    let failure: Value = serde_json::from_slice(&refused.stdout).unwrap();
    assert_eq!(failure["error"]["code"], "invalidCursor");
    let missing = runtime.cli_at(
        &[
            "artifact",
            "inspect",
            "--import",
            "imp-00000000-0000-0000-0000-000000000000",
            "--artifact",
            "ART-absent",
        ],
        &runtime.socket(),
        Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
    );
    assert!(!missing.status.success());
    let failure: Value = serde_json::from_slice(&missing.stdout).unwrap();
    assert_eq!(failure["error"]["code"], "resourceNotFound");
    let input = runtime.root.join("analyzer-input.json");
    fs::write(
        &input,
        serde_json::to_vec(&json!({"sourceArtifactRef":results[0]["receipt"]["lease"]})).unwrap(),
    )
    .unwrap();
    let args = [
        "--target",
        "TGT-3ba3f5f43b92",
        "--operation",
        "analyzer.extract-crash-signature@1",
        "--inputs-file",
        input.to_str().unwrap(),
        "--request-id",
        "request-import-analyzer",
        "--idempotency-key",
        "idem-import-analyzer",
    ];
    let mut plan = vec!["job", "plan"];
    plan.extend(args);
    assert_plan(&runtime, &plan);
    let mut submit = vec!["job", "submit"];
    submit.extend(args);
    let accepted = runtime.cli(&submit);
    let jid = accepted["jobId"].as_str().unwrap();
    let id = results[0]["importId"].as_str().unwrap();
    let inspection = runtime.cli(&["artifact", "import", "inspect", "--import", id]);
    assert_eq!(inspection["references"]["activeJobIds"], json!([jid]));
    let refused = runtime.cli_at(
        &[
            "artifact",
            "import",
            "release",
            "--import",
            id,
            "--generation",
            "2",
        ],
        &runtime.socket(),
        Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
    );
    assert!(!refused.status.success());
    let failure: Value = serde_json::from_slice(&refused.stdout).unwrap();
    assert_eq!(failure["error"]["code"], "resourceConflict");
    runtime.stop();
    runtime.start();
    let finished = runtime.cli(&["job", "run", "--job", jid]);
    assert_eq!(finished["state"], "succeeded");

    // Real CLI lifecycle leaves, followed by a new daemon process. Released
    // artifacts remain readable; their old lease is never advertised anew.
    for result in &results {
        let id = result["importId"].as_str().unwrap();
        let inspection = runtime.cli(&["artifact", "import", "inspect", "--import", id]);
        assert_eq!(inspection["references"]["state"], "clear");
        let released = runtime.cli(&[
            "artifact",
            "import",
            "release",
            "--import",
            id,
            "--generation",
            "2",
        ]);
        assert_eq!(released["state"], "released");
        runtime.stop();
        runtime.start();
        assert_eq!(
            runtime.cli(&[
                "artifact",
                "import",
                "release",
                "--import",
                id,
                "--generation",
                "2"
            ]),
            released
        );
        let listed = runtime.cli(&["artifact", "list", "--import", id]);
        assert_eq!(listed["items"][0]["lease"], Value::Null);
        let aid = result["receipt"]["artifactId"].as_str().unwrap();
        let mut args = vec!["artifact", "read", "--import", id, "--artifact", aid];
        if result["metadata"]["kind"] == "workspace-patch" {
            args.push("--allow-sensitive");
        }
        assert!(runtime.cli(&args)["base64"].is_string());
    }
}

/// `job plan` as the daemon's control layer answers it under this build's
/// `job.plan` schema. The checkout and candidate views publish the additive
/// step-set review digest every Rust plan carries. The published view compiles
/// the merge base's closed result schema, which predates it, so the daemon
/// answers `internalError` in place of a result that schema cannot publish.
fn assert_plan(runtime: &Runtime, plan: &[&str]) {
    let schema: Value = serde_json::from_str(
        arkdeck_contract::METHOD_SCHEMAS
            .iter()
            .find(|(method, _)| *method == "job.plan")
            .unwrap()
            .1,
    )
    .unwrap();
    if schema["$defs"]["result"]["properties"]
        .get("stepSetDigestSHA256")
        .is_some()
    {
        let planned = runtime.cli(plan);
        assert!(planned["materializedPlanDigest"].is_string());
        let digest = planned["stepSetDigestSHA256"].as_str().unwrap_or_default();
        assert!(
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            "{planned}"
        );
        return;
    }
    // Only the published view's inputs name their merge-base commit.
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    assert!(
        inputs["kind"] == "development" && inputs.get("commit").is_some(),
        "only the merge base's schema may predate the step-set review digest"
    );
    let refused = runtime.cli_at(
        plan,
        &runtime.socket(),
        Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
    );
    assert!(!refused.status.success());
    let failure: Value = serde_json::from_slice(&refused.stdout).unwrap();
    assert_eq!(failure["error"]["code"], "internalError", "{failure}");
    assert_eq!(
        failure["error"]["message"],
        "the result does not conform to the current contract"
    );
    assert_eq!(failure["error"]["details"]["wireCode"], "internalError");
}

/// A real process path under the exact old published contract. Its supported
/// HAP result remains usable; an unrepresentable patch response stays refused.
fn published_contract_preserves_patch_refusal(runtime: &mut Runtime) {
    let hap_bytes = b"PK\x03\x04published-contract";
    let hap = runtime.root.join("published.hap");
    fs::write(&hap, hap_bytes).unwrap();
    let accepted = runtime.cli(&upload_args("hap", "published-hap", hap.to_str().unwrap()));
    assert_eq!(accepted["state"], "committed");
    let patch = runtime.root.join("published.patch");
    fs::write(
        &patch,
        b"diff --git a/a b/a\n--- a/a\n+++ b/a\n+token=unchanged\n",
    )
    .unwrap();
    let patch_receipt = runtime.cli(&upload_args(
        "workspace-patch",
        "published-patch",
        patch.to_str().unwrap(),
    ));
    assert_eq!(patch_receipt["state"], "committed");
    let record_path = runtime
        .root
        .join("artifacts/.imports-v1/records")
        .join(format!(
            "{}.json",
            arkdeck_contract::sha256_hex(b"published-patch")
        ));
    let durable = fs::read(&record_path).unwrap();
    runtime.stop();
    runtime.start();
    let payload_path = runtime
        .root
        .join("artifacts")
        .join(patch_receipt["importId"].as_str().unwrap())
        .join(patch_receipt["receipt"]["artifactId"].as_str().unwrap());
    let payload = fs::read(&payload_path).unwrap();
    for attempt in 0..2 {
        let proxy_path = runtime.root.join(format!("inspect-proxy-{attempt}.sock"));
        let listener = UnixListener::bind(&proxy_path).unwrap();
        fs::set_permissions(&proxy_path, fs::Permissions::from_mode(0o600)).unwrap();
        let endpoint = runtime.socket();
        let proxy = std::thread::spawn(move || {
            let (client, _) = listener.accept().unwrap();
            client
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut client = BufReader::new(client);
            let upstream = UnixStream::connect(endpoint).unwrap();
            upstream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut upstream = BufReader::new(upstream);
            let mut methods = Vec::new();
            loop {
                let mut request = String::new();
                if client.read_line(&mut request).unwrap() == 0 {
                    break;
                }
                let request_value: Value = serde_json::from_str(&request).unwrap();
                methods.push(request_value["method"].as_str().unwrap().to_owned());
                upstream.get_mut().write_all(request.as_bytes()).unwrap();
                let mut response = String::new();
                assert!(upstream.read_line(&mut response).unwrap() > 0);
                client.get_mut().write_all(response.as_bytes()).unwrap();
            }
            methods
        });
        let output = runtime.cli_at(
            &upload_args(
                "workspace-patch",
                "published-patch",
                patch.to_str().unwrap(),
            ),
            &proxy_path,
            &std::env::current_exe().unwrap(),
        );
        let methods = proxy.join().unwrap();
        assert_eq!(
            methods
                .iter()
                .filter(|method| method.starts_with("artifact.import."))
                .cloned()
                .collect::<Vec<_>>(),
            ["artifact.import.inspect"]
        );
        assert!(!output.status.success());
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(envelope["error"]["code"], "internalError");
        assert_eq!(
            envelope["error"]["details"]["method"],
            "artifact.import.inspect"
        );
        assert_eq!(envelope["error"]["details"]["wireCode"], "internalError");
        // commit already succeeded under its own published response schema.
        // A later inspect-schema refusal must not rewrite that durable receipt.
        assert_eq!(fs::read(&record_path).unwrap(), durable);
        assert_eq!(fs::read(&payload_path).unwrap(), payload);
        runtime.stop();
        runtime.start();
        let read = runtime.cli(&[
            "artifact",
            "read",
            "--import",
            accepted["importId"].as_str().unwrap(),
            "--artifact",
            accepted["receipt"]["artifactId"].as_str().unwrap(),
        ]);
        assert_eq!(
            read["base64"],
            arkdeck_contract::encode_import_chunk(hap_bytes).unwrap()
        );
    }
}
