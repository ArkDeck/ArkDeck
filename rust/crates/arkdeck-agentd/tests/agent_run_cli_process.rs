//! `arkdeck agent run` through the Rust CLI against the isolated Rust daemon,
//! as Golden Journeys 5 and 2 run it (TASK-XPA-015): the copy of a workspace
//! project registered through the CLI (`workspace.prepare-isolated-copy@1`),
//! and the three pointer gestures on an adopted Target under the development
//! mutation authority. Each run ends `completed`, its Job `succeeded` and its
//! evidence verified, and the CLI exits 0: the daemon's own conformance check
//! and the CLI's admit a host-only execution's evidence (no binding revision,
//! stable identity or observation) and a gesture capability's authority that
//! names no Artifact (`artifactDigest` null). Before the latter was published
//! the daemon refused its own `agent.status` answer and `agent run` exited 70
//! (the GJ-5 fake rehearsal of 2026-09-25). A tap sent again under its
//! execution identity is answered by `agent.run` itself, from the completed
//! execution, with no new injection. Then a tap that names no target waits for
//! the device to be connected, is resumed with `agent resume` once it is, and
//! is resumed again with `agent resume` and `human-action resume`, each
//! answering the completed execution without injecting again.
//!
//! Host-only: the device is the one Swift's agent execution evidence oracle
//! ran against (`rust/tests/fixtures/agent-execution-evidence/hdc-answers.sh`,
//! the pointer oracle's device in the mode `tools/mode` names), answering
//! behind the managed HDC server's fake compiled here from C (`DRIVER`); the
//! USB relations are a development file; the Target is the adoption fixture's.
//! No real HDC, device or Swift daemon is used. Spawning children, this test
//! keeps a binary of its own.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::fs;
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");
const DEVICE: &str =
    include_str!("../../../tests/fixtures/agent-execution-evidence/hdc-answers.sh");
const TARGET: &str = "TGT-3ba3f5f43b92";
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The profile the daemon derives for an OpenHarmony project registration.
const PROFILE: &str = "waterflow-openharmony@1";

mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}
use loopback_ports::free_port;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn private_directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}

/// The isolated development root, its managed fake HDC and the daemon over
/// them; whatever the test leaves is ended and removed however it ends.
struct Runtime {
    root: PathBuf,
    port: u16,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-agent-run-cli-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            root.clone(),
            root.join("state"),
            root.join("state/targets-state"),
            root.join("tools"),
        ] {
            private_directory(&directory);
        }
        let targets = root.join("state/targets-state/targets.json");
        fs::copy(
            fixture("target-adoption/targets-state/targets.json"),
            &targets,
        )
        .unwrap();
        fs::set_permissions(&targets, fs::Permissions::from_mode(0o600)).unwrap();
        let tools = root.join("tools");
        // The device answers every command that is not the server's, in the
        // mode `mode` names (`normal` without one); every call is recorded
        // in `calls`.
        let driver = tools.join("device");
        fs::write(
            &driver,
            format!(
                "#!/bin/sh\nmode=normal\n[ -r {mode} ] && IFS= read -r mode < {mode}\n{DEVICE}",
                mode = tools.join("mode").display()
            ),
        )
        .unwrap();
        fs::set_permissions(&driver, fs::Permissions::from_mode(0o700)).unwrap();
        let source = tools.join("fake-hdc.c");
        fs::write(&source, FAKE_HDC).unwrap();
        let output = Command::new("cc")
            .arg("-O0")
            .arg(format!("-DRESTART_DIR=\"{}\"", tools.display()))
            .arg(format!("-DSELF_PATH=\"{}\"", tools.join("hdc").display()))
            .arg(format!(
                "-DRECORD_CALLS=\"{}\"",
                tools.join("calls").display()
            ))
            .arg(format!("-DOWNER_PID={}", std::process::id()))
            .arg(format!("-DDRIVER=\"{}\"", driver.display()))
            .arg("-o")
            .arg(tools.join("hdc"))
            .arg(&source)
            .output()
            .expect("cc from the developer tools compiles the fake");
        assert!(
            output.status.success(),
            "fake hdc did not compile: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fs::set_permissions(tools.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            root,
            port: free_port(),
            child: None,
        }
    }

    fn hdc(&self) -> PathBuf {
        self.root.join("tools/hdc")
    }

    fn socket(&self) -> PathBuf {
        self.root.join("state/control.sock")
    }

    /// The daemon over the isolated root with its managed server, the
    /// development mutation authority and the development USB relations,
    /// serving once its start has composed.
    fn start(&mut self) {
        let mut command = Command::new(DAEMON);
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy();
            if key.starts_with("ARKDECK_") || key.starts_with("OHOS_HDC_") {
                command.env_remove(&*key);
            }
        }
        self.child = Some(
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.root.join("state"))
                .env("ARKDECK_ENDPOINT", self.socket())
                .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.hdc())
                .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
                .env("OHOS_HDC_SERVER_PORT", self.port.to_string())
                .env("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "acknowledged")
                .env(
                    "ARKDECK_DEVELOPMENT_USB_RELATIONS",
                    self.root.join("tools/usb-relations.json"),
                )
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        // Only an upper bound on the start, which includes the managed
        // server's readiness.
        let deadline = Instant::now() + Duration::from_secs(60);
        while UnixStream::connect(self.socket()).is_err() {
            assert!(
                self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited"
            );
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGTERM: the daemon drains, stops its managed server and ends with 0.
    fn stop(&mut self) {
        let mut child = self.child.take().unwrap();
        let signalled = Command::new("/bin/kill")
            .args(["-TERM", &child.id().to_string()])
            .status()
            .unwrap();
        assert!(signalled.success());
        let deadline = Instant::now() + Duration::from_secs(60);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not end within 60 s of SIGTERM");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut stdout = String::new();
        let _ = child.stdout.take().unwrap().read_to_string(&mut stdout);
        assert_eq!(status.code(), Some(0), "{stdout}");
    }

    /// The mode the device answers the next commands in.
    fn set_mode(&self, mode: &str) {
        fs::write(self.root.join("tools/mode"), format!("{mode}\n")).unwrap();
    }

    /// The device plugged on a USB attachment, as the Runtime's USB
    /// observation then reads it.
    fn plug(&self, attachment: u64) {
        fs::write(
            self.root.join("tools/usb-relations.json"),
            json!({"relations": [{"serial": KEY, "location": "100",
                "attachmentId": attachment, "vendorId": 8711, "productId": 20480}]})
            .to_string(),
        )
        .unwrap();
    }

    /// The Rust CLI beside the daemon, against this daemon's socket, asked
    /// for its machine answer: its exit status and the envelope it printed.
    fn cli(&self, arguments: &[&str]) -> (Option<i32>, Value) {
        // Cargo builds both binary packages before running workspace tests.
        let cli = Path::new(DAEMON).with_file_name("arkdeck");
        let mut command = Command::new(cli);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let output: Output = command
            .args(arguments)
            .args(["--output", "json", "--socket"])
            .arg(self.socket())
            .env("ARKDECK_DAEMON_PATH", DAEMON)
            .output()
            .expect(
                "the arkdeck CLI beside the daemon: run the workspace tests, or \
                 `cargo build -p arkdeck-cli` before testing this crate alone",
            );
        let envelope = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
        (output.status.code(), envelope)
    }

    /// `arkdeck agent run` of `operation` with `inputs`.
    fn agent_run(
        &self,
        execution: &str,
        operation: &str,
        target: Option<&str>,
        inputs: &Value,
    ) -> (Option<i32>, Value) {
        let file = self.root.join(format!("{execution}.json"));
        fs::write(&file, inputs.to_string()).unwrap();
        let mut arguments = vec![
            "agent",
            "run",
            "--execution-id",
            execution,
            "--operation",
            operation,
            "--inputs-file",
            file.to_str().unwrap(),
            "--maximum-wait",
            "2m",
        ];
        if let Some(target) = target {
            arguments.extend(["--target", target]);
        }
        self.cli(&arguments)
    }

    /// Every injection the device was asked for, one line each.
    fn injections(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("tools/calls"))
            .unwrap_or_default()
            .lines()
            .filter(|line| line.contains(" shell uinput "))
            .map(str::to_owned)
            .collect()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // A server this test left behind would keep its port: end it first.
        let _ = Command::new("/usr/bin/pkill")
            .args(["-KILL", "-f", &self.hdc().to_string_lossy()])
            .status();
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The published contract view runs this checkout's tests against the merge
/// base's inputs, which name their commit. The checkout and candidate views
/// carry this checkout's.
fn published_view() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// Whether the contract this build compiled publishes `method`'s answer for
/// an execution whose Runtime capability names no Artifact. A merge base
/// older than that refuses the daemon's own answer; one that includes it
/// publishes it, as the checkout does.
fn publishes_capability_without_artifact(method: &str) -> bool {
    let (_, schema) = arkdeck_contract::METHOD_SCHEMAS
        .iter()
        .find(|(name, _)| *name == method)
        .unwrap();
    let schema: Value = serde_json::from_str(schema).unwrap();
    let authority = &schema["$defs"]["result"]["properties"]["evidence"]["properties"]["authority"];
    let branches = match authority["anyOf"].as_array() {
        Some(branches) => branches.clone(),
        None => vec![authority.clone()],
    };
    branches.iter().any(|branch| {
        branch["properties"]["artifactDigest"]["type"]
            .as_array()
            .is_some_and(|types| types.contains(&json!("null")))
    })
}

/// The daemon's refusal of its own answer, as the CLI prints it.
fn assert_nonconforming(status: Option<i32>, envelope: &Value, method: &str) {
    assert_eq!(status, Some(70), "{envelope}");
    assert_eq!(envelope["error"]["code"], "internalError", "{envelope}");
    assert_eq!(
        envelope["error"]["message"], "the result does not conform to the current contract",
        "{envelope}"
    );
    assert_eq!(envelope["error"]["details"]["method"], method, "{envelope}");
}

/// The revision the daemon's provider measures for the WaterFlow profile
/// over these files.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// A completed execution as the CLI prints it for `command`: its Job
/// succeeded and its evidence verified.
fn assert_completed(envelope: &Value, command: &str, execution: &str, operation: &str) -> Value {
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["command"], command, "{envelope}");
    let result = &envelope["result"];
    assert_eq!(result["executionId"], execution, "{envelope}");
    assert_eq!(result["operation"], operation, "{envelope}");
    assert_eq!(result["state"], "completed", "{envelope}");
    assert_eq!(result["jobState"], "succeeded", "{envelope}");
    assert_eq!(result["outcomeUnknown"], false, "{envelope}");
    assert_eq!(result["failureCode"], Value::Null, "{envelope}");
    assert_eq!(result["evidence"]["status"], "verified", "{envelope}");
    assert_eq!(
        result["evidence"]["terminalState"], "succeeded",
        "{envelope}"
    );
    assert_eq!(result["evidence"]["blockers"], json!([]), "{envelope}");
    result.clone()
}

/// A completed gesture on the adopted Target, under the Runtime's capability
/// for its operation, which names no Artifact.
fn assert_gestured(result: &Value, ordinal: u64) {
    assert_eq!(result["targetId"], TARGET, "{result}");
    assert_eq!(result["bindingRevision"], 1, "{result}");
    assert_eq!(result["artifacts"], json!([]), "{result}");
    let evidence = &result["evidence"];
    assert_eq!(evidence["actualEffect"], "deviceMutation", "{result}");
    // The device's model and firmware are read by the first gesture of a
    // session and carried by the next ones.
    let kinds = evidence["actualStepKinds"].as_array().unwrap();
    assert_eq!(kinds.first(), Some(&json!("probeDevice")), "{result}");
    assert_eq!(kinds.last(), Some(&json!("injectPointerInput")), "{result}");
    assert_eq!(evidence["bindingRevision"], 1, "{result}");
    assert_eq!(evidence["observation"]["targetId"], TARGET, "{result}");
    let authority = &evidence["authority"];
    assert_eq!(authority["kind"], "runtimeCapability", "{result}");
    assert_eq!(authority["artifactDigest"], Value::Null, "{result}");
    assert_eq!(authority["useOrdinal"], ordinal, "{result}");
}

#[test]
fn agent_run_answers_a_workspace_copy_and_every_gesture_through_the_cli() {
    let mut runtime = Runtime::new();
    let project = runtime.root.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "old\n"),
        ("entry/src/main/ets/Other.ets", "other\n"),
    ] {
        fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        fs::write(project.join(path), bytes).unwrap();
    }

    // The project is registered through the CLI; a daemon composes it at its
    // next start.
    runtime.start();
    let (status, registered) = runtime.cli(&[
        "workspace",
        "project",
        "register",
        "--registration-request-id",
        "agent-run-cli",
        "--kind",
        "openharmony",
        "--root",
        project.to_str().unwrap(),
    ]);
    assert_eq!(status, Some(0), "{registered}");
    let project_ref = registered["result"]["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    runtime.stop();
    runtime.start();

    // Golden Journey 5's isolation: host-only, its target the project.
    let (status, envelope) = runtime.agent_run(
        "gj5-isolate",
        "workspace.prepare-isolated-copy@1",
        None,
        &json!({
            "projectRef": project_ref,
            "expectedWorkspaceRevision": revision(&[
                ("entry/src/main/ets/Other.ets", b"other\n"),
                ("entry/src/main/ets/pages/Index.ets", b"old\n"),
            ]),
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"],
        }),
    );
    assert_eq!(status, Some(0), "{envelope}");
    let copied = assert_completed(
        &envelope,
        "agent.run",
        "gj5-isolate",
        "workspace.prepare-isolated-copy@1",
    );
    assert_eq!(copied["targetId"], project_ref.as_str(), "{envelope}");
    assert_eq!(copied["bindingRevision"], Value::Null, "{envelope}");
    let evidence = &copied["evidence"];
    assert_eq!(evidence["actualEffect"], "hostOnly", "{envelope}");
    assert_eq!(evidence["authority"]["kind"], "defaultReadOnlyPolicy");
    assert_eq!(evidence["bindingRevision"], Value::Null, "{envelope}");
    assert_eq!(evidence["observation"], Value::Null, "{envelope}");
    let artifacts = copied["artifacts"].as_array().unwrap();
    assert_eq!(artifacts.len(), 1, "{envelope}");
    assert_eq!(artifacts[0]["targetId"], project_ref.as_str());
    assert_eq!(artifacts[0]["bindingRevision"], Value::Null);
    assert_eq!(artifacts[0]["stableIdentitySha256"], Value::Null);
    assert_eq!(evidence["artifacts"], copied["artifacts"]);

    // Golden Journey 2's gestures, each under the Runtime's capability for
    // its operation, and each injection the device acknowledged once.
    let frame = json!({"displayWidth": 1280, "displayHeight": 2832});
    let with = |fields: Value| {
        let mut inputs = frame.clone();
        inputs
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        inputs
    };
    let tap = with(json!({"x": 640, "y": 1500}));
    let tapped = format!("-t {KEY} shell uinput -T -c 640 1500");
    let gestures = [
        ("gj2-tap", "input.tap@1", tap.clone(), tapped.clone()),
        (
            "gj2-long-press",
            "input.long-press@1",
            with(json!({"x": 12, "y": 700, "durationMs": 1200, "displayId": 2})),
            format!("-t {KEY} shell uinput -D 2 -T -d 12 700 -i 1200 -u 12 700"),
        ),
        (
            "gj2-swipe",
            "input.swipe@1",
            with(json!({
                "fromX": 100, "fromY": 2200, "toX": 100, "toY": 1200, "durationMs": 500
            })),
            format!("-t {KEY} shell uinput -T -m 100 2200 100 1200 500"),
        ),
    ];
    let published = publishes_capability_without_artifact("agent.status");
    let mut injected = Vec::new();
    for (execution, operation, inputs, injection) in &gestures {
        let (status, envelope) = runtime.agent_run(execution, operation, Some(TARGET), inputs);
        injected.push(injection.clone());
        assert_eq!(runtime.injections(), injected, "{operation}: {envelope}");
        if !published {
            // Only a published view's merge base can predate a capability
            // without an Artifact: the Job succeeded, and the daemon refuses
            // its own answer.
            assert!(published_view(), "agent.status must publish {operation}");
            assert_nonconforming(status, &envelope, "agent.status");
            continue;
        }
        assert_eq!(status, Some(0), "{envelope}");
        assert_gestured(
            &assert_completed(&envelope, "agent.run", execution, operation),
            1,
        );
    }

    // The tap sent again under its identity: `agent.run` answers from the
    // completed execution, and nothing is injected again.
    if published {
        assert!(publishes_capability_without_artifact("agent.run"));
        let (status, envelope) = runtime.agent_run("gj2-tap", "input.tap@1", Some(TARGET), &tap);
        assert_eq!(status, Some(0), "{envelope}");
        assert_gestured(
            &assert_completed(&envelope, "agent.run", "gj2-tap", "input.tap@1"),
            1,
        );
        assert_eq!(runtime.injections(), injected);
    }

    // A tap that names no target: with the device offline the execution
    // waits for a person to connect it.
    runtime.set_mode("offline");
    let (status, waiting) = runtime.agent_run("gj2-assisted-tap", "input.tap@1", None, &tap);
    assert_eq!(status, Some(75), "{waiting}");
    assert_eq!(waiting["error"]["code"], "humanActionRequired", "{waiting}");
    let action = &waiting["error"]["details"]["execution"]["humanAction"];
    assert_eq!(action["category"], "physicalConnection", "{waiting}");
    let reference = action["resumeReference"].as_str().unwrap().to_owned();
    let action = action["actionId"].as_str().unwrap().to_owned();
    assert_eq!(runtime.injections(), injected);

    // Connected and plugged, the resumed execution adopts the device and
    // taps it once, the tap capability's second use.
    runtime.set_mode("normal");
    runtime.plug(18);
    let (status, envelope) = runtime.cli(&["agent", "resume", "--resume-reference", &reference]);
    injected.push(tapped);
    assert_eq!(runtime.injections(), injected);
    if !published {
        assert!(published_view());
        assert_nonconforming(status, &envelope, "agent.status");
        runtime.stop();
        return;
    }
    assert_eq!(status, Some(0), "{envelope}");
    assert_gestured(
        &assert_completed(&envelope, "agent.resume", "gj2-assisted-tap", "input.tap@1"),
        2,
    );

    // Resumed again, either way: the resolved action answers the completed
    // execution, and nothing is injected again.
    for (command, arguments) in [
        (
            "agent.resume",
            vec!["agent", "resume", "--resume-reference", &reference],
        ),
        (
            "human-action.resume",
            vec![
                "human-action",
                "resume",
                "--human-action",
                &action,
                "--resume-reference",
                &reference,
            ],
        ),
    ] {
        assert!(publishes_capability_without_artifact(command));
        let (status, envelope) = runtime.cli(&arguments);
        assert_eq!(status, Some(0), "{envelope}");
        assert_gestured(
            &assert_completed(&envelope, command, "gj2-assisted-tap", "input.tap@1"),
            2,
        );
        assert_eq!(runtime.injections(), injected);
    }
    runtime.stop();
}
