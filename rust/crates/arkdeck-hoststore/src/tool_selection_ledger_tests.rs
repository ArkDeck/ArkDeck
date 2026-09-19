//! The Rust ledger against the Swift oracle in
//! `rust/tests/fixtures/tool-selection-registry`
//! (`ToolSelectionRegistryOracleContractTests`): every timeline played again
//! on a fresh store leaves Swift's index bytes after every step, publishes
//! where Swift published, and answers or refuses as Swift did.
use super::*;
use arkdeck_platform::HostDirectory;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::{DirBuilderExt, FileExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/tool-selection-registry")
}

fn json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn scratch() -> PathBuf {
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let path = PathBuf::from(format!("/private/tmp/tool-selection-ledger-{nonce:032x}"));
    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
    path
}

/// The oracle's executables as source files, and its published identities.
struct Tools {
    sources: BTreeMap<String, PathBuf>,
    references: BTreeMap<String, String>,
    identity: Value,
    published: Vec<String>,
    registered_at: String,
}

fn tools(root: &Path) -> Tools {
    let oracle = json(&oracle().join("oracle.json"));
    let sources = root.join("sources");
    fs::DirBuilder::new().mode(0o700).create(&sources).unwrap();
    let mut tools = Tools {
        sources: BTreeMap::new(),
        references: BTreeMap::new(),
        identity: oracle["publishedIdentity"].clone(),
        published: Vec::new(),
        registered_at: oracle["registeredAt"].as_str().unwrap().into(),
    };
    for (label, executable) in oracle["executables"].as_object().unwrap() {
        let bytes = base64(executable["base64"].as_str().unwrap());
        assert_eq!(
            arkdeck_contract::sha256_hex(&bytes),
            executable["sha256"].as_str().unwrap()
        );
        let path = sources.join(format!("hdc-{label}"));
        fs::write(&path, &bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        tools.sources.insert(label.clone(), path);
        tools.references.insert(
            label.clone(),
            executable["toolRef"].as_str().unwrap().into(),
        );
        if executable["published"] == true {
            tools
                .published
                .push(executable["sha256"].as_str().unwrap().into());
        }
    }
    tools
}

fn base64(text: &str) -> Vec<u8> {
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bits = 0u32;
    let mut count = 0;
    let mut bytes = Vec::new();
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = alphabet.iter().position(|a| *a == byte).unwrap() as u32;
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            bytes.push((bits >> count) as u8);
        }
    }
    bytes
}

fn store(path: &Path, tools: &Tools) -> ToolRegistryStore {
    let published = tools.published.clone();
    let identity = tools.identity.clone();
    ToolRegistryStore::open_or_create(path)
        .unwrap()
        .with_published_identities(Arc::new(move |sha256: &str| {
            published
                .iter()
                .any(|known| known == sha256)
                .then(|| identity.clone())
        }))
}

fn startup(value: Option<StartupSelection>, store: &Path) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    json!({
        "toolRef": value.tool_ref,
        "activeGeneration": value.active_generation.to_string(),
        "pendingControlActionId": value.pending_action_id,
        "executable": value.executable.strip_prefix(store).unwrap().to_str().unwrap(),
        "executableSHA256": value.executable_sha256,
        "dependencies": value.dependencies,
    })
}

fn outcome(value: DurableSelectionOutcome) -> Value {
    match value {
        DurableSelectionOutcome::Pending => json!({"outcome": "pending"}),
        DurableSelectionOutcome::Succeeded {
            active_tool_ref,
            active_generation,
        } => json!({"outcome": "succeeded", "activeToolRef": active_tool_ref,
            "activeGeneration": active_generation.to_string()}),
        DurableSelectionOutcome::Failed {
            active_tool_ref,
            active_generation,
            reason_code,
        } => json!({"outcome": "failed", "activeToolRef": active_tool_ref,
            "activeGeneration": active_generation.to_string(), "reasonCode": reason_code}),
        DurableSelectionOutcome::Absent => json!({"outcome": "absent"}),
    }
}

/// `tools.json`'s bytes and file identity, when it exists.
fn index(store: &Path) -> Option<(Vec<u8>, (u64, std::time::SystemTime))> {
    let path = store.join("tools.json");
    let metadata = fs::symlink_metadata(&path).ok()?;
    Some((
        fs::read(&path).unwrap(),
        (metadata.ino(), metadata.created().unwrap()),
    ))
}

/// What Rust answers for one recorded step; `None` for a step Rust has no
/// operation for, which writes the index Swift left instead.
fn perform(
    step: &Value,
    owner: &ToolRegistryStore,
    path: &Path,
    tools: &Tools,
) -> Option<Result<Value, WireError>> {
    let arguments = &step["arguments"];
    let text = |key: &str| arguments[key].as_str().unwrap();
    let source = || &tools.sources[text("executable")];
    Some(match step["operation"].as_str().unwrap() {
        "register" => owner.register(source(), &tools.registered_at),
        "adoptInstalledHDC" => owner
            .adopt_installed_hdc(source(), &tools.registered_at)
            .map(|snapshot| snapshot.value()),
        "initializeServiceSelection" => owner
            .initialize_service_selection(text("toolRef"), text("expectedGeneration"))
            .map(|value| startup(Some(value), path)),
        "selectionCandidate" => owner
            .selection_candidate(
                text("newToolRef"),
                text("expectedActiveGeneration"),
                arguments["pendingActionID"].as_str(),
            )
            .map(|candidate| {
                json!({"selection": candidate.selection.value(), "newTool": candidate.new_tool})
            }),
        "prepareSelection" => owner
            .prepare_selection(
                text("actionID"),
                text("newToolRef"),
                text("expectedActiveGeneration"),
            )
            .map(|snapshot| snapshot.value()),
        "startupSelection" => owner.startup_selection().map(|value| startup(value, path)),
        "publishPendingSelection" => owner
            .publish_pending_selection(text("actionID"))
            .map(|snapshot| snapshot.value()),
        "failPendingSelection" => owner
            .fail_pending_selection(text("actionID"), text("reasonCode"))
            .map(|snapshot| snapshot.value()),
        "selectionOutcome" => owner.selection_outcome(text("actionID")).map(outcome),
        "acknowledgeSelectionOutcome" => owner
            .acknowledge_selection_outcome(text("actionID"))
            .map(|()| Value::Null),
        "remove" => owner.retire(text("toolRef"), text("expectedGeneration")),
        "list" => owner.list().map(Value::Array).map_err(|_| {
            failure("recordUnreadable", "the list owner's refusal is its own")
        }),
        "harness.removeIndex" => {
            fs::remove_file(path.join("tools.json")).unwrap();
            Ok(Value::Null)
        }
        "harness.alterContent" => {
            let digest = &tools.references[text("executable")]["tool:sha256:".len()..];
            let file = fs::OpenOptions::new()
                .write(true)
                .open(path.join(format!("tool-{digest}.hdc/hdc")))
                .unwrap();
            file.write_at(&[0xff], 40).unwrap();
            Ok(Value::Null)
        }
        // Pins no Rust caller takes, and a ledger only a harness can make:
        // Swift's index stands in for them.
        "acquire" | "release" | "harness.unpinActiveTool" => return None,
        other => panic!("unknown operation {other}"),
    })
}

#[test]
fn every_swift_timeline_plays_again_byte_for_byte() {
    let root = scratch();
    let tools = tools(&root);
    let timelines = json(&oracle().join("timelines.json"));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(root.join("stores"))
        .unwrap();
    for timeline in timelines.as_array().unwrap() {
        let name = timeline["name"].as_str().unwrap();
        let path = root.join("stores").join(name);
        let owner = store(&path, &tools);
        let mut previous = index(&path).map(|(_, identity)| identity);
        for (number, step) in timeline["steps"].as_array().unwrap().iter().enumerate() {
            let at = format!("{name} step {number} ({})", step["operation"]);
            let held = (step["lockHeldByAnotherOwner"] == true).then(|| {
                HostDirectory::open(&path)
                    .unwrap()
                    .lock_document(".lock")
                    .unwrap()
            });
            let answer = perform(step, &owner, &path, &tools);
            drop(held);
            match answer {
                Some(Ok(value)) => assert_eq!(value, step["answer"], "{at}"),
                Some(Err(error)) if step["operation"] == "list" => {
                    assert!(step.get("refusal").is_some(), "{at}: {error:?}")
                }
                Some(Err(error)) => assert_eq!(
                    json!({"code": error.code, "message": error.message}),
                    step["refusal"],
                    "{at}"
                ),
                None => {
                    let bytes = fs::read(
                        oracle().join(format!("indexes/{}.json", step["index"].as_str().unwrap())),
                    )
                    .unwrap();
                    fs::write(path.join("tools.json"), bytes).unwrap();
                    fs::set_permissions(path.join("tools.json"), fs::Permissions::from_mode(0o600))
                        .unwrap();
                    previous = index(&path).map(|(_, identity)| identity);
                    continue;
                }
            }
            let now = index(&path);
            match (&now, step["index"].as_str()) {
                (Some((bytes, _)), Some(digest)) => assert_eq!(
                    String::from_utf8_lossy(bytes),
                    String::from_utf8_lossy(
                        &fs::read(oracle().join(format!("indexes/{digest}.json"))).unwrap()
                    ),
                    "{at}"
                ),
                (None, None) => {}
                _ => panic!("{at}: index presence differs"),
            }
            let identity = now.map(|(_, identity)| identity);
            assert_eq!(
                identity.is_some() && identity != previous,
                step["published"] == true,
                "{at}: publication differs"
            );
            previous = identity;
        }
    }
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn every_swift_index_is_its_own_canonical_bytes() {
    // The one ledger the reader refuses: a harness took its active pin out.
    let unpinned = "d98a9a14fa744e7a5fbec4580360725751524e3c15a5ce06db8bcdaefecfc006";
    let mut count = 0;
    for entry in fs::read_dir(oracle().join("indexes")).unwrap() {
        let path = entry.unwrap().path();
        let bytes = fs::read(&path).unwrap();
        let index: ToolIndex = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            canonical_json(&serde_json::to_value(&index).unwrap()).unwrap(),
            bytes,
            "{path:?}"
        );
        let name = path.file_stem().unwrap().to_str().unwrap();
        assert_eq!(read_tools(&bytes).is_ok(), name != unpinned, "{path:?}");
        count += 1;
    }
    assert_eq!(count, 22);
}

fn reference(digit: &str) -> String {
    format!("tool:sha256:{}", digit.repeat(64))
}

/// A record with every member Swift's `Record` declares, the optional ones
/// included.
fn full_record(digit: &str, references: Value) -> Value {
    let trust = json!({"signature": "verified", "identifier": "com.huawei.hdc",
        "teamIdentifier": "FIXTURETEAM", "codeDirectorySHA256": "c".repeat(64)});
    json!({
        "reference": reference(digit), "contentDigest": digit.repeat(64),
        "executableSHA256": "f".repeat(64), "registeredAt": "2026-09-01T00:00:00Z",
        "byteCount": 1, "quarantineSHA256": "9".repeat(64), "trust": trust,
        "dependencies": [{"name": "libusb_shared.dylib", "sha256": "d".repeat(64), "byteCount": 2,
            "quarantineSHA256": "e".repeat(64), "trust": trust}],
        "relocatable": true, "generation": 1, "state": "available", "references": references,
    })
}

fn full_indexes() -> [Value; 2] {
    let active = json!({"kind": "activeSelection", "id": "runtime-hdc-selection"});
    let pin = json!({"kind": "controlAction", "id": "select-2"});
    [
        json!({"schemaVersion": "arkdeck.bootstrap-tools/2",
            "records": [full_record("1", json!([active, pin])), full_record("2", json!([pin]))],
            "selection": {"activeToolRef": reference("1"), "activeGeneration": 1,
                "pending": {"actionID": "select-2", "oldToolRef": reference("1"),
                    "newToolRef": reference("2"), "expectedActiveGeneration": 1}}}),
        json!({"schemaVersion": "arkdeck.bootstrap-tools/2",
            "records": [full_record("1", json!([active])), full_record("2", json!([]))],
            "selection": {"activeToolRef": reference("1"), "activeGeneration": 1,
                "lastOutcome": {"actionID": "select-2", "result": "failed",
                    "oldToolRef": reference("1"), "newToolRef": reference("2"),
                    "activeGeneration": 1, "reasonCode": "tool.selectionFailed"}}}),
    ]
}

/// Every object in `value`, as a JSON pointer.
fn objects(value: &Value, pointer: String, out: &mut Vec<String>) {
    match value {
        Value::Object(fields) => {
            out.push(pointer.clone());
            for (key, child) in fields {
                objects(child, format!("{pointer}/{key}"), out);
            }
        }
        Value::Array(items) => {
            for (position, child) in items.iter().enumerate() {
                objects(child, format!("{pointer}/{position}"), out);
            }
        }
        _ => {}
    }
}

#[test]
fn members_are_swifts_and_no_other() {
    // Swift's `CodingKeys` that may be absent (`encodeIfPresent`).
    let optional = [
        "quarantineSHA256",
        "identifier",
        "teamIdentifier",
        "codeDirectorySHA256",
        "selection",
        "pending",
        "lastOutcome",
        "reasonCode",
    ];
    for document in full_indexes() {
        let bytes = canonical_json(&document).unwrap();
        let (index, _) = read_tools(&bytes).unwrap();
        assert_eq!(
            canonical_json(&serde_json::to_value(&index).unwrap()).unwrap(),
            bytes
        );
        let mut pointers = Vec::new();
        objects(&document, String::new(), &mut pointers);
        for pointer in pointers {
            let mut more = document.clone();
            more.pointer_mut(&pointer)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .insert("extra".into(), json!(1));
            assert!(
                read_tools(&canonical_json(&more).unwrap()).is_err(),
                "a member more at {pointer:?}"
            );
            let keys: Vec<String> = document
                .pointer(&pointer)
                .unwrap()
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect();
            for key in keys {
                let mut less = document.clone();
                less.pointer_mut(&pointer)
                    .unwrap()
                    .as_object_mut()
                    .unwrap()
                    .remove(&key);
                assert_eq!(
                    read_tools(&canonical_json(&less).unwrap()).is_ok(),
                    optional.contains(&key.as_str()),
                    "{key} missing at {pointer:?}"
                );
            }
        }
    }
}

#[test]
fn publication_stops_at_the_last_generation() {
    let root = scratch();
    let [mut pending, _] = full_indexes();
    pending["selection"]["activeGeneration"] = json!(u64::MAX);
    pending["selection"]["pending"]["expectedActiveGeneration"] = json!(u64::MAX);
    let bytes = serde_json::to_vec(&pending).unwrap();
    for (name, bytes) in [
        (
            "bundles.json",
            &b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\"}"[..],
        ),
        ("tools.json", &bytes[..]),
    ] {
        fs::write(root.join(name), bytes).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    let owner = ToolRegistryStore::open_existing(&root).unwrap();
    let error = owner.publish_pending_selection("select-2").unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "resourceConflict",
            "the exact pending tool selection does not exist"
        )
    );
    assert_eq!(fs::read(root.join("tools.json")).unwrap(), bytes);
    fs::remove_dir_all(&root).unwrap();
}
