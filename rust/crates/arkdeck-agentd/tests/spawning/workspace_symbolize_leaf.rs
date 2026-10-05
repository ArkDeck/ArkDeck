//! GJ-5's `workspace symbolize` end to end on Windows (TASK-XPA-011): the
//! real signed `arkdeck.exe` registers an OpenHarmony project and its symbol
//! preset, then symbolizes a device's crash through
//! `workspace.symbolize-crash@1` against the signed test daemon
//! (`signed_daemon.rs`), whose symbolizer (`ARKDECK_ANALYZER_PATH`) is the
//! daemon's own build in its one-shot `--symbolize-crash` mode, as the
//! production daemon names it.
//!
//! The crash is the one the Swift oracle's device capture published
//! (`rust/tests/fixtures/workspace-test-symbolize-oracle`), laid into the
//! root's Artifact store before the daemon starts, as the macOS process test
//! lays it (`workspace_symbolize_process.rs`), against the Swift symbolizer
//! oracle's source map (`crash-symbolizer-oracle`). The leaf is run as a
//! person runs it, with the capture's lease; the report is exactly what the
//! symbolizer writes for that map and dump
//! (`arkdeck_hoststore::symbolize_crash`) and resolves the crash's frame to
//! its ArkTS source. Without a symbolizer the preset does not compose and the
//! leaf is refused before admission. Host tests only: no device, `hdc` or
//! board is reached.
use crate::gj1_device_leaves::assert_windows_status;
use crate::signed_daemon::{SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

/// The project-relative source map the symbol preset names.
const MAP: &str = "entry/build/default/outputs/default/mapping/sourceMaps.map";

fn unbase64(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = Vec::new();
    let (mut buffer, mut bits) = (0_u32, 0);
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = ALPHABET.iter().position(|a| *a == byte).unwrap() as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    bytes
}

/// The capture the oracle published, laid into the root's Artifact store as
/// the device's Job left it, kept: its crash log's lease and bytes.
fn lay_crash_log(root: &Path) -> (String, Vec<u8>) {
    let source = fixtures("workspace-test-symbolize-oracle")
        .join("artifacts")
        .join("job-input-crash");
    HostDirectory::open_or_create_private(&root.join("artifacts")).unwrap();
    let path = root.join("artifacts").join("job-input-crash");
    HostDirectory::open_or_create_private(&path).unwrap();
    let directory = HostDirectory::open(&path).unwrap();
    let mut index: Value =
        serde_json::from_slice(&fs::read(source.join("index.json")).unwrap()).unwrap();
    let mut lease = None;
    for row in index["artifacts"].as_array_mut().unwrap() {
        row["retention"] = json!({"pinned": true, "retentionClass": "pinnedUntilVerified"});
        let id = row["artifactID"].as_str().unwrap().to_owned();
        let bytes = fs::read(source.join(&id)).unwrap();
        directory.create_document(&id, &bytes).unwrap();
        directory.seal_document(&id).unwrap();
        if row["name"] == "crash-log.txt" {
            lease = Some((format!("lease-v1:job-input-crash:{id}"), bytes));
        }
    }
    directory
        .create_document("index.json", &serde_json::to_vec_pretty(&index).unwrap())
        .unwrap();
    lease.unwrap()
}

#[test]
fn the_real_cli_symbolizes_a_devices_crash_with_the_daemons_own_mode() {
    let _turn = crate::turn();
    let scratch = temporary("gj5-workspace-symbolize");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    // The fake HDC no exchange reaches.
    let fixture = fixtures("observe-device");
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&fake_root).unwrap();
    let cases: Value = serde_json::from_slice(
        &fs::read(fixtures("crash-symbolizer-oracle").join("cases.json")).unwrap(),
    )
    .unwrap();
    let map = unbase64(
        cases
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["name"] == "device")
            .unwrap()["map"]
            .as_str()
            .unwrap(),
    );
    let project = scratch.join("project");
    for (path, bytes) in [
        ("build-profile.json5", b"{}\n".to_vec()),
        ("entry/src/main/module.json5", b"{}\n".to_vec()),
        (
            "entry/src/main/ets/pages/Index.ets",
            b"@Entry\n@Component\nstruct Index {}\n".to_vec(),
        ),
        (MAP, map.clone()),
    ] {
        let file = project.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, bytes).unwrap();
    }
    let base: [(&str, String); 0] = [];
    let symbolizing = [(
        "ARKDECK_ANALYZER_PATH",
        env!("CARGO_BIN_EXE_arkdeck-agentd").to_owned(),
    )];
    let start = |variables: &[(&str, String)]| {
        SignedDaemon::start_with(&executable, &pin, &root, &fixture, &fake_root, variables)
    };
    let run = |daemon: &SignedDaemon, arguments: &[&str]| -> Value {
        let (status, envelope) = daemon.cli(arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        envelope["result"].clone()
    };
    let inputs = |name: &str, value: Value| {
        let path = scratch.join(format!("{name}.json"));
        fs::write(&path, value.to_string()).unwrap();
        path.to_str().unwrap().to_owned()
    };

    // The project and its symbol preset, registered.
    let daemon = start(&base);
    let registered = run(
        &daemon,
        &[
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "symbolize-leaf-project",
            "--kind",
            "openharmony",
            "--root",
            project.to_str().unwrap(),
        ],
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let preset = run(
        &daemon,
        &[
            "workspace",
            "preset",
            "register",
            "--registration-request-id",
            "symbolize-leaf-preset",
            "--project",
            &registered,
            "--kind",
            "symbol",
            "--template",
            "openharmony.arkts-symbol@1",
            "--timeout-seconds",
            "60",
            "--relative-source-map",
            MAP,
        ],
    )["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();
    let (oracle_lease, oracle_dump) = lay_crash_log(&root);
    let symbolize = |daemon: &SignedDaemon, label: &str, lease: &str| {
        daemon.cli(&[
            "workspace",
            "symbolize",
            "--inputs-file",
            &inputs(
                label,
                json!({"projectRef": registered, "dumpArtifactRef": lease,
                    "symbolPresetRef": preset}),
            ),
            "--execution-id",
            &format!("exec-windows-symbolize-{label}"),
        ])
    };

    // Without a symbolizer the preset does not compose.
    let daemon = start(&base);
    let (status, refused) = symbolize(&daemon, "unconfigured", &oracle_lease);
    assert_eq!(status, Some(65), "{refused}");
    assert_eq!(refused["error"]["code"], "invalidInput", "{refused}");
    assert_eq!(
        refused["error"]["message"],
        "workspace.symbolize-crash@1 is runtime unavailable: workspace.symbolPresetUnavailable",
        "{refused}"
    );
    assert_eq!(refused["error"]["details"]["newDispatchCount"], 0);
    daemon.stop();

    // With the daemon's own mode as its symbolizer, the oracle's crash is
    // symbolized as the mode writes it.
    let daemon = start(&symbolizing);
    let report = |envelope: &Value| -> String {
        let receipt = &envelope["result"];
        assert_eq!(
            receipt["operationReference"], "workspace.symbolize-crash@1",
            "{receipt}"
        );
        assert_eq!(receipt["terminalState"], "succeeded", "{receipt}");
        let job = receipt["jobID"].as_str().unwrap();
        let listed = run(&daemon, &["artifact", "list", "--job", job]);
        let item = &listed["items"][0];
        assert_eq!(item["name"], "symbolized-crash.txt", "{listed}");
        assert_eq!(item["privacy"], "sensitive", "{listed}");
        String::from_utf8(
            fs::read(
                root.join("artifacts")
                    .join(job)
                    .join(item["artifactId"].as_str().unwrap()),
            )
            .unwrap(),
        )
        .unwrap()
    };
    let (status, symbolized) = symbolize(&daemon, "oracle", &oracle_lease);
    assert_eq!(status, Some(0), "{symbolized}");
    let expected = arkdeck_hoststore::symbolize_crash(&map, &oracle_dump).unwrap();
    assert_eq!(report(&symbolized), expected);
    assert!(
        expected.contains("-> entry/src/main/ets/fixture/CrashProbe.ets:30:"),
        "{expected}"
    );

    daemon.stop();
    let _ = fs::remove_dir_all(&scratch);
    assert_windows_status(&["workspace.symbolize-crash@1"], "implemented");
}
