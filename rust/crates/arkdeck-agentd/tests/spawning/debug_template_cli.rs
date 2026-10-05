//! The signed Windows CLI's `debug template run` Job path (TASK-XPA-008).
//! Its four closed commands and normal bytes are the Swift `debug-probe`
//! oracle's. Job states, raw sensitive Artifacts and lost-intent recovery
//! follow the existing macOS Rust owner test `debug_template_run.rs`.
//! Host fixtures alone: no device or installed Runtime is contacted.
use crate::signed_daemon::{SignedDaemon, fixtures, signed_copy, temporary};
use crate::support;
use serde_json::{Value, json};
use std::{fs, path::Path};

const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const TARGET: &str = "TGT-3ba3f5f43b92";
const PARAMETER: &str = "device.debugParameterRead";
const UPTIME: &str = "device.uptime";

fn calls(root: &Path) -> Vec<String> {
    fs::read_to_string(root.join("hdc-calls.log"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn template_calls(root: &Path) -> usize {
    calls(root)
        .iter()
        .filter(|call| {
            [
                "shell bm dump -a",
                "shell param get persist.ace.debug.enabled",
                "shell hidumper -s WindowManagerService -a -a",
                "shell uptime",
            ]
            .iter()
            .any(|command| **call == format!("-t {KEY} {command}"))
        })
        .count()
}

fn input(path: &Path, value: Value) {
    fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
}

fn run(daemon: &SignedDaemon, inputs: &Path, template: &str) -> (Option<i32>, Value) {
    input(inputs, json!({"templateId": template}));
    daemon.cli(&[
        "debug",
        "template",
        "run",
        "--target",
        TARGET,
        "--inputs-file",
        inputs.to_str().unwrap(),
    ])
}

fn unbase64(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    for chunk in text.as_bytes().chunks(4) {
        assert_eq!(chunk.len(), 4);
        let digit = |byte| {
            if byte == b'=' {
                0
            } else {
                ALPHABET.iter().position(|item| *item == byte).unwrap() as u32
            }
        };
        let bits =
            digit(chunk[0]) << 18 | digit(chunk[1]) << 12 | digit(chunk[2]) << 6 | digit(chunk[3]);
        out.push((bits >> 16) as u8);
        if chunk[2] != b'=' {
            out.push((bits >> 8) as u8);
        }
        if chunk[3] != b'=' {
            out.push(bits as u8);
        }
    }
    out
}

fn artifact_bytes(daemon: &SignedDaemon, job: &str, artifact: &str) -> Vec<u8> {
    let (status, read) = daemon.cli(&[
        "artifact",
        "read",
        "--job",
        job,
        "--artifact",
        artifact,
        "--max-bytes",
        "65536",
        "--allow-sensitive",
    ]);
    assert_eq!(status, Some(0), "{read}");
    assert_eq!(read["result"]["eof"], true, "{read}");
    unbase64(read["result"]["base64"].as_str().unwrap())
}

fn successful_artifacts(daemon: &SignedDaemon, job: &str, template: &str, bytes: &[u8]) {
    let (_, inventory) = daemon.cli(&["artifact", "list", "--job", job]);
    let artifacts = inventory["result"]["items"].as_array().unwrap();
    assert_eq!(artifacts.len(), 2, "{inventory}");
    for name in ["template-output.txt", "template-report.json"] {
        let artifact = artifacts.iter().find(|row| row["name"] == name).unwrap();
        let id = artifact["artifactId"].as_str().unwrap();
        let actual = artifact_bytes(daemon, job, id);
        if name == "template-output.txt" {
            assert_eq!(actual, bytes);
            let (status, refused) =
                daemon.cli(&["artifact", "read", "--job", job, "--artifact", id]);
            assert_ne!(status, Some(0), "{refused}");
            assert_eq!(refused["ok"], false, "{refused}");
        } else {
            let report: Value = serde_json::from_slice(&actual).unwrap();
            assert_eq!(report["templateId"], template, "{report}");
            assert_eq!(report["exitStatus"], "0", "{report}");
            assert_eq!(report["durationMilliseconds"], "1", "{report}");
            assert_eq!(report["stdoutByteCount"], bytes.len().to_string());
            assert_eq!(report["stdoutTruncated"], "false", "{report}");
        }
    }
}

fn record(daemon: &SignedDaemon, job: &str, state: &str, unknown: bool) -> Value {
    let (status, observed) = daemon.cli(&["job", "status", "--job", job]);
    assert_eq!(status, Some(0), "{observed}");
    assert_eq!(observed["result"]["state"], state, "{observed}");
    assert_eq!(observed["result"]["outcomeUnknown"], unknown, "{observed}");
    let (_, evidence) = daemon.cli(&["job", "evidence", "--job", job]);
    assert!(evidence["result"]["observation"].is_null(), "{evidence}");
    observed["result"].clone()
}

#[test]
fn closed_templates_run_through_the_signed_cli_and_unknown_intents_never_replay() {
    let _turn = crate::turn();
    let scratch = temporary("debug-template-cli");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("debug-probe");
    let root = scratch.join("root");
    for directory in [&root, &root.join("targets-state")] {
        arkdeck_platform::HostDirectory::open_or_create_private(directory).unwrap();
    }
    let targets = root.join("targets-state/targets.json");
    let target_bytes = fs::read(fixture.join("targets-state/targets.json")).unwrap();
    fs::write(&targets, &target_bytes).unwrap();
    let fake_root = scratch.join("hdc");
    fs::create_dir_all(&fake_root).unwrap();
    let inputs = scratch.join("inputs.json");
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);

    // The macOS owner rejects caller argv and stale bindings before planning
    // dispatches anything. The public domain leaf must reject these inputs too.
    for value in [
        json!({"templateId": "shell uptime"}),
        json!({"templateId": UPTIME, "rawCommand": "shell uptime"}),
        json!({}),
    ] {
        input(&inputs, value);
        let (status, refused) = daemon.cli(&[
            "debug",
            "template",
            "run",
            "--target",
            TARGET,
            "--inputs-file",
            inputs.to_str().unwrap(),
        ]);
        assert_ne!(status, Some(0), "{refused}");
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(template_calls(&fake_root), 0);
    }
    input(&inputs, json!({"templateId": UPTIME}));
    let before = calls(&fake_root);
    let (status, stale) = daemon.cli(&[
        "job",
        "plan",
        "--target",
        TARGET,
        "--operation",
        "debug.template@1",
        "--inputs-file",
        inputs.to_str().unwrap(),
        "--expected-binding-revision",
        "9999",
    ]);
    assert_ne!(status, Some(0), "{stale}");
    assert_eq!(stale["ok"], false, "{stale}");
    assert_eq!(calls(&fake_root), before, "stale binding never dispatches");
    let (status, plan) = daemon.cli(&[
        "job",
        "plan",
        "--target",
        TARGET,
        "--operation",
        "debug.template@1",
        "--inputs-file",
        inputs.to_str().unwrap(),
        "--expected-binding-revision",
        "1",
    ]);
    assert_eq!(status, Some(0), "{plan}");
    assert_eq!(plan["result"]["effectiveEffect"], "readOnly", "{plan}");
    assert_eq!(plan["result"]["steps"].as_array().unwrap().len(), 3);
    assert_eq!(calls(&fake_root), before, "planning never dispatches");

    // The four normal payloads come directly from the existing Swift oracle;
    // their Job result and Artifact treatment are the macOS Rust owner's.
    let cases = support::document(&fixture, "cases.json");
    let mut successes = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        if exchange["method"] != "debug.template.run"
            || exchange["mode"] != "normal"
            || exchange["answer"]["ok"] != true
        {
            continue;
        }
        let template = exchange["params"]["templateId"].as_str().unwrap();
        fs::write(fake_root.join("hdc-mode"), "normal\n").unwrap();
        let before = template_calls(&fake_root);
        let (status, run) = run(&daemon, &inputs, template);
        assert_eq!(status, Some(0), "{template}: {run}");
        assert_eq!(run["ok"], true, "{run}");
        assert_eq!(run["result"]["outcomeUnknown"], false, "{run}");
        let job = run["result"]["jobID"].as_str().unwrap();
        let observed = record(&daemon, job, "succeeded", false);
        assert_eq!(observed["actualEffect"], "readOnly", "{observed}");
        successful_artifacts(
            &daemon,
            job,
            template,
            exchange["answer"]["result"]["stdout"]
                .as_str()
                .unwrap()
                .as_bytes(),
        );
        assert_eq!(
            template_calls(&fake_root),
            before + 1,
            "one closed dispatch"
        );
        successes += 1;
    }
    assert_eq!(successes, 4);

    // Unlike the direct text probe, a Job preserves non-UTF-8 raw Artifact
    // bytes; the macOS owner explicitly tests that distinction.
    fs::write(fake_root.join("hdc-mode"), "templateBinary\n").unwrap();
    let (status, binary) = run(&daemon, &inputs, PARAMETER);
    assert_eq!(status, Some(0), "{binary}");
    let job = binary["result"]["jobID"].as_str().unwrap();
    record(&daemon, job, "succeeded", false);
    successful_artifacts(&daemon, job, PARAMETER, b"persist.ace.debug.enabled=\xff\n");

    for (mode, template, failure) in [
        ("templateOffline", UPTIME, "targetUnavailable"),
        ("templateFailure", UPTIME, "templateExitStatus"),
        ("templateTruncated", PARAMETER, "truncated"),
    ] {
        fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        let before = template_calls(&fake_root);
        let (status, failed) = run(&daemon, &inputs, template);
        assert_eq!(status, Some(1), "{mode}: {failed}");
        assert_eq!(failed["ok"], true, "{failed}");
        let job = failed["result"]["jobID"].as_str().unwrap();
        let observed = record(&daemon, job, "failed", false);
        assert_eq!(observed["failure"]["code"], "executionFailed", "{observed}");
        let (status, timeline) = daemon.cli(&["job", "timeline", "--job", job]);
        assert_eq!(status, Some(0), "{timeline}");
        assert!(
            timeline["result"]
                .to_string()
                .contains(&format!("{failure}:")),
            "{timeline}"
        );
        assert_eq!(template_calls(&fake_root), before + 1);
    }

    // A signal death leaves one durable unknown intent. Neither explicit
    // rerun nor startup recovery may dispatch it, including after restart.
    fs::write(fake_root.join("hdc-mode"), "templateKilled\n").unwrap();
    let before = template_calls(&fake_root);
    let (status, unknown) = run(&daemon, &inputs, UPTIME);
    assert_eq!(status, Some(1), "{unknown}");
    assert_eq!(unknown["ok"], true, "{unknown}");
    assert_eq!(unknown["result"]["outcomeUnknown"], true, "{unknown}");
    let job = unknown["result"]["jobID"].as_str().unwrap().to_owned();
    record(&daemon, &job, "waitingForRecovery", true);
    assert_eq!(template_calls(&fake_root), before + 1);
    let (status, refused) = daemon.cli(&["job", "run", "--job", &job]);
    assert_ne!(status, Some(0), "{refused}");
    assert_eq!(refused["ok"], false, "{refused}");
    let before_restart = calls(&fake_root);
    daemon.stop();
    let restarted =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);
    assert_eq!(calls(&fake_root), before_restart, "startup never replays");
    record(&restarted, &job, "waitingForRecovery", true);
    let (status, reconciled) = restarted.cli(&["job", "reconcile", "--job", &job]);
    assert_eq!(status, Some(0), "{reconciled}");
    assert_eq!(reconciled["result"]["state"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["result"]["failure"]["code"], "executionConfirmedNotPerformed",
        "{reconciled}",
    );
    record(&restarted, &job, "failed", false);
    let (status, refused) = restarted.cli(&["job", "run", "--job", &job]);
    assert_ne!(status, Some(0), "{refused}");
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(
        calls(&fake_root),
        before_restart,
        "reconcile never dispatches"
    );
    assert_eq!(fs::read(&targets).unwrap(), target_bytes);
    restarted.stop();

    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .unwrap();
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    let measured: Vec<_> = coverage["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["feature"] == "debug.template.run")
        .collect();
    assert_eq!(measured.len(), 1);
    assert_eq!(
        measured[0]["implementationStatusByPlatform"]["windows"],
        "implemented"
    );
    fs::remove_dir_all(&scratch).unwrap();
}
