//! GJ-1's device reads end to end on Windows (TASK-XPA-005): the real signed
//! `arkdeck.exe` against the signed test daemon (`signed_daemon.rs`), which
//! composes the production Windows development root with the shared fake
//! HDC's answers in process (`oracle_fake.rs`) and a synthetic USB census
//! naming the boards each exchange plugs ([`signed_daemon::CENSUS`]).
//!
//! The Swift Target adoption oracle (`rust/tests/fixtures/target-adoption`)
//! replays through the CLI: every observation (`device candidates`), adoption
//! (`target adopt`) and availability (`target availability`) the CLI can
//! spell answers as Swift's daemon answered it, once the observation
//! identities read as the oracle's labels and every time as `<time>` (the
//! daemon runs on the host's clock), as `target_observation_control.rs`
//! reads them through `Control` on macOS. The fake's calls, the Target
//! document and the display names are Swift's. Then, over the Target it
//! adopted, `device wait` follows the exact observation until its state is
//! proved (or stops at its own deadline, having adopted nothing), and
//! `device list` answers the Target list. Host tests only: no device, `hdc`
//! or board is reached.
use crate::gj1_device_leaves::assert_windows_status;
use crate::gj23_replay::wire;
use crate::signed_daemon::{self, SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// The oracle's candidate: the fake's one connect key and USB serial.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracle adopted.
const TARGET: &str = "TGT-3ba3f5f43b92";

/// Whether `text` is a lowercase UUID, as Swift spells one.
fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// The oracle's labels for the observation identities the owner mints at
/// random: `<obs-1>` for the first to appear, and so on.
#[derive(Default)]
struct Labels {
    labels: BTreeMap<String, String>,
    identities: BTreeMap<String, String>,
}

impl Labels {
    fn label(&mut self, text: &str) -> String {
        let mut out = String::new();
        let mut rest = text;
        while let Some(at) = rest.find("obs-") {
            match rest.get(at..at + 40) {
                Some(identity) if is_uuid(&identity[4..]) => {
                    out.push_str(&rest[..at]);
                    let count = self.labels.len() + 1;
                    let label = self
                        .labels
                        .entry(identity.to_owned())
                        .or_insert_with(|| format!("<obs-{count}>"))
                        .clone();
                    self.identities.insert(label.clone(), identity.to_owned());
                    out.push_str(&label);
                    rest = &rest[at + 40..];
                }
                _ => {
                    out.push_str(&rest[..at + 4]);
                    rest = &rest[at + 4..];
                }
            }
        }
        out + rest
    }

    fn identity(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (label, identity) in &self.identities {
            text = text.replace(label.as_str(), identity);
        }
        text
    }
}

/// `text` with every UTC time read as `<time>`.
fn mask_times(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while at < bytes.len() {
        if let Some(length) = time_at(&bytes[at..]) {
            out.push_str("<time>");
            at += length;
        } else {
            let character = text[at..].chars().next().unwrap();
            out.push(character);
            at += character.len_utf8();
        }
    }
    out
}

/// The length of the `YYYY-MM-DDTHH:MM:SS[.fraction]Z` time `bytes` starts
/// with, if it starts with one.
fn time_at(bytes: &[u8]) -> Option<usize> {
    let shape = b"dddd-dd-ddTdd:dd:dd";
    let shaped = bytes.len() > shape.len()
        && shape.iter().zip(bytes).all(|(want, got)| {
            if *want == b'd' {
                got.is_ascii_digit()
            } else {
                want == got
            }
        });
    if !shaped {
        return None;
    }
    let mut end = shape.len();
    if bytes[end] == b'.' {
        let digits = bytes[end + 1..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if digits == 0 {
            return None;
        }
        end += 1 + digits;
    }
    (bytes.get(end) == Some(&b'Z')).then_some(end + 1)
}

/// Plugs the boards `exchange` names in the census file, as a new epoch.
fn plug(census: &Path, epoch: u64, exchange: &Value) {
    let Some(relations) = exchange.get("usbRelations") else {
        return;
    };
    let mut plugged = json!({"epoch": epoch, "relations": relations});
    if let Some(after) = exchange.get("usbRelationsAfter") {
        plugged["after"] = after.clone();
    }
    fs::write(census, serde_json::to_vec(&plugged).unwrap()).unwrap();
}

/// The CLI's arguments for one recorded request, or `None` when the CLI's
/// grammar cannot spell its parameters (the oracle sent them to its daemon
/// directly).
fn arguments(method: &str, params: &Value) -> Option<Vec<String>> {
    let text = |key: &str| params[key].as_str().map(str::to_owned);
    let owned = |items: &[&str]| items.iter().map(|item| (*item).to_owned()).collect();
    match method {
        "device.observations" => {
            assert_eq!(params, &json!({}));
            Some(owned(&["device", "candidates"]))
        }
        "target.adopt" => {
            let generation = text("observationGeneration")?;
            generation
                .parse::<u64>()
                .ok()
                .filter(|number| number.to_string() == generation)?;
            let mut arguments: Vec<String> = owned(&["target", "adopt"]);
            arguments.extend([
                "--candidate".into(),
                text("candidate")?,
                "--observation".into(),
                text("observationId")?,
                "--observation-generation".into(),
                generation,
            ]);
            Some(arguments)
        }
        "target.availability" => Some(vec![
            "target".into(),
            "availability".into(),
            "--target".into(),
            text("targetId")?,
        ]),
        other => panic!("the oracle sent {other}"),
    }
}

/// A development root with an empty Target store, the fake's root and the
/// census file, below `scratch`.
fn roots(scratch: &Path) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    fs::create_dir_all(&fake_root).unwrap();
    let census = scratch.join("census.json");
    fs::write(&census, br#"{"epoch":0,"relations":[]}"#).unwrap();
    (root, fake_root, census)
}

#[test]
fn the_real_cli_observes_adopts_and_reads_availability_as_the_swift_oracle() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-device-reads");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("target-adoption");
    let (root, fake_root, census) = roots(&scratch);
    let daemon = SignedDaemon::start_with(
        &executable,
        &pin,
        &root,
        &fixture,
        &fake_root,
        &[(signed_daemon::CENSUS, census.to_str().unwrap().to_owned())],
    );
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let mut labels = Labels::default();
    let (mut replayed, mut unspelled) = (Vec::new(), Vec::new());
    for (index, exchange) in cases["exchanges"].as_array().unwrap().iter().enumerate() {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        plug(&census, index as u64 + 1, exchange);
        let params: Value =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let Some(arguments) = arguments(method, &params) else {
            unspelled.push(name.to_owned());
            continue;
        };
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (_, envelope) = daemon.cli(&arguments);
        let reply: Value =
            serde_json::from_str(&mask_times(&labels.label(&wire(&envelope).to_string()))).unwrap();
        let mut recorded: Value =
            serde_json::from_str(&mask_times(&exchange["answer"].to_string())).unwrap();
        if method == "target.availability" && recorded["ok"] == true {
            // The Swift oracle's daemon supplied its managed HDC's
            // diagnostics, and its own operation availability; this
            // composition's are its own (the same reads `operation list`
            // answers), each checked below.
            recorded["result"]["tool"] = reply["result"]["tool"].clone();
            recorded["result"]["operations"] = reply["result"]["operations"].clone();
        }
        assert_eq!(reply, recorded, "{name}: {envelope}");
        replayed.push(name.to_owned());
    }
    assert_eq!(
        unspelled,
        ["adopt.invalid", "adopt.leadingZero", "availability.missing"],
        "the requests only a direct client sends"
    );
    assert_eq!(replayed.len(), 18, "{replayed:?}");

    // The availability's own legs: the tool this composition runs, and the
    // operations `operation list` answers.
    let (status, availability) = daemon.cli(&["target", "availability", "--target", TARGET]);
    assert_eq!(status, Some(0), "{availability}");
    let (status, operations) = daemon.cli(&["operation", "list"]);
    assert_eq!(status, Some(0), "{operations}");
    let items: Vec<Value> = operations["result"]
        .as_array()
        .unwrap()
        .iter()
        .map(|operation| {
            json!({
                "reference": operation["reference"],
                "availability": operation["availability"],
                "reasons": operation["reasons"],
                "reasonCodes": operation["reasonCodes"],
            })
        })
        .collect();
    assert_eq!(
        availability["result"]["operations"]["items"],
        Value::Array(items),
        "{availability}"
    );
    // This composition runs no managed HDC server; its tool leg says so.
    assert_eq!(
        availability["result"]["tool"],
        json!({
            "state": "absent", "reasonCode": "runtime_tool_unavailable",
            "reason": "Runtime has no managed HDC server",
        })
    );

    // The fake's calls, the Target document and the display names are
    // Swift's, their times read alike.
    assert_eq!(
        fs::read_to_string(fake_root.join("hdc-invocations.log")).unwrap(),
        fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap(),
        "the fake's calls"
    );
    for file in [
        "targets-state/targets.json",
        "targets-state/target-display-names.json",
    ] {
        assert_eq!(
            mask_times(&fs::read_to_string(root.join(file)).unwrap()),
            mask_times(&fs::read_to_string(fixture.join(file)).unwrap()),
            "{file}"
        );
    }

    // Over the Target it adopted, with the oracle's board plugged again.
    fs::write(fake_root.join("hdc-mode"), "normal\n").unwrap();
    plug(&census, 100, &cases["exchanges"][0]);
    let candidate = |daemon: &SignedDaemon| -> (String, String, Value) {
        let (status, candidates) = daemon.cli(&["device", "candidates"]);
        assert_eq!(status, Some(0), "{candidates}");
        let result = &candidates["result"];
        let row = result["observations"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["candidateKey"] == KEY)
            .unwrap_or_else(|| panic!("{candidates}"))
            .clone();
        (
            row["observationId"].as_str().unwrap().to_owned(),
            result["snapshotGeneration"].as_str().unwrap().to_owned(),
            row,
        )
    };
    let (observation, generation, row) = candidate(&daemon);
    assert_eq!(row["adoptedTargetId"], TARGET, "{row}");
    assert_eq!(row["observationContinuity"], "relationProven", "{row}");
    let wait = |state: &str, timeout: &str| {
        daemon.cli(&[
            "device",
            "wait",
            "--candidate",
            KEY,
            "--observation",
            &observation,
            "--observation-generation",
            &generation,
            "--state",
            state,
            "--timeout",
            timeout,
        ])
    };
    // The state already proved: the exact observation, re-proved by this
    // read, Connected and still the adopted Target's.
    let (status, waited) = wait("connected", "10s");
    assert_eq!(status, Some(0), "{waited}");
    let document = &waited["result"];
    assert_eq!(document["schemaVersion"], "arkdeck.device-wait/1");
    assert_eq!(document["state"], "connected");
    let proved = &document["observation"];
    assert_eq!(proved["observationId"], observation.as_str(), "{waited}");
    assert_eq!(proved["candidateKey"], KEY);
    assert_eq!(proved["authorizationState"], "Connected");
    assert_eq!(proved["observationContinuity"], "relationProven");
    assert_eq!(proved["adoptedTargetId"], TARGET);
    let after: u64 = document["snapshotGeneration"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        after >= generation.parse::<u64>().unwrap(),
        "never an older snapshot: {waited}"
    );

    // The board unauthorized: waiting for Connected stops at the client's
    // own deadline, having adopted and cancelled nothing.
    fs::write(fake_root.join("hdc-mode"), "unauthorized\n").unwrap();
    let (status, stopped) = wait("connected", "2s");
    assert_eq!(status, Some(75), "{stopped}");
    let error = &stopped["error"];
    assert_eq!(error["code"], "clientTimeout", "{stopped}");
    assert_eq!(error["details"]["requestedState"], "connected");
    assert_eq!(error["details"]["observationId"], observation.as_str());
    assert_eq!(error["details"]["newDispatchCount"], 0);
    assert!(
        error["details"]["lastObservedGeneration"].is_string(),
        "{stopped}"
    );
    // And waiting for Unauthorized proves it on the same observation.
    let (status, unauthorized) = wait("unauthorized", "10s");
    assert_eq!(status, Some(0), "{unauthorized}");
    assert_eq!(unauthorized["result"]["state"], "unauthorized");
    let proved = &unauthorized["result"]["observation"];
    assert_eq!(
        proved["observationId"],
        observation.as_str(),
        "{unauthorized}"
    );
    assert_eq!(proved["authorizationState"], "Unauthorized");

    // `device list`, Swift's legacy leaf, answers the Target list.
    let (status, listed) = daemon.cli(&["device", "list"]);
    assert_eq!(status, Some(0), "{listed}");
    let (status, targets) = daemon.cli(&["target", "list"]);
    assert_eq!(status, Some(0), "{targets}");
    assert_eq!(listed["result"], targets["result"]);
    assert_eq!(listed["result"][0]["targetId"], TARGET, "{listed}");
    daemon.stop();
    let _ = fs::remove_dir_all(&scratch);
    assert_windows_status(
        &["device.observations", "target.availability"],
        "implemented",
    );
}

/// The Swift Trace probe oracle (`rust/tests/fixtures/trace-probe`) through
/// `trace probe`: every probe the CLI can spell answers as Swift's daemon
/// answered it, and the fake received Swift's reads, each exchange's
/// concurrent reads sorted as the oracle records them
/// (`trace_probe_control.rs` replays the same through `Control` on macOS).
#[test]
fn the_real_cli_probes_trace_as_the_swift_oracle() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-trace-probe");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("trace-probe");
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    HostDirectory::open(&root.join("targets-state"))
        .unwrap()
        .create_document(
            "targets.json",
            &fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
    fs::create_dir_all(fake_root.join("resources")).unwrap();
    for entry in fs::read_dir(fixture.join("resources")).unwrap() {
        let entry = entry.unwrap();
        fs::copy(
            entry.path(),
            fake_root.join("resources").join(entry.file_name()),
        )
        .unwrap();
    }
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixture, &fake_root);
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let mut calls = String::new();
    let mut unspelled = Vec::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        let Some(target) = exchange["params"]["targetId"]
            .as_str()
            .filter(|target| !target.is_empty())
        else {
            unspelled.push(name.to_owned());
            continue;
        };
        let (_, envelope) = daemon.cli(&["trace", "probe", "--target", target]);
        assert_eq!(wire(&envelope), exchange["answer"], "{name}: {envelope}");
        let log = fake_root.join("hdc-calls.log");
        let mut read: Vec<String> = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect();
        fs::write(&log, "").unwrap();
        read.sort_unstable();
        for line in read {
            calls.push_str(&line);
            calls.push('\n');
        }
    }
    daemon.stop();
    assert_eq!(
        unspelled,
        ["probe.emptyTarget", "probe.noParameters"],
        "the requests only a direct client sends"
    );
    assert_eq!(
        calls,
        fs::read_to_string(fixture.join("hdc-calls.log")).unwrap(),
        "the fake's reads"
    );
    let _ = fs::remove_dir_all(&scratch);
    assert_windows_status(&["trace.probe"], "implemented");
}
