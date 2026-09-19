//! `runtime.hdc.impact-preview`, `runtime.hdc.restart` and
//! `control-action.list`, `.show` and `.reconcile` through the control layer,
//! against the daemon's own host, as Swift's daemon answers them without a
//! managed HDC server (`ControlActionNoHostContractTests`). The isolated
//! composition's union owner, over no HDC and no tool-selection owner, answers
//! every exchange of the committed corpora that needs no managed server; the
//! host without that owner answers the corpus's exchange of a handler with no
//! control-action owner, and every refusal Swift's handler gives before it
//! consults an owner. Refusals compare whole (code, message, details); a page
//! compares whole once its random `snapshotRevision` is checked and set aside.
//! The five success frames of an impact source (a preview, an approval
//! request, a record read twice and a listed action) need a managed server and
//! are counted, not replayed. The control layer admits each answer under the
//! compiled method schema: a view whose schemas predate the no-host frames
//! answers what they do not publish with `internalError`.
use arkdeck_contract::{
    CONTRACT_IDENTITY, CONTRACT_INPUTS, PROTOCOL_VERSION, sha256_hex, strict_json,
    validate_method_value,
};
use arkdeck_control::Control;
use arkdeck_hoststore::ControlActionResources;
use arkdeck_platform::{HostDirectory, VerifiedTool};
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const METHODS: [&str; 5] = [
    "runtime.hdc.impact-preview",
    "runtime.hdc.restart",
    "control-action.show",
    "control-action.reconcile",
    "control-action.list",
];

const ORDER: &str = "createdAtThenControlActionId";
const IDENTITY: &str = "control-action-5f0c1a52-0b4e-4c8a-9d2e-2b7f3c6a9e10";
const HDC_UNAVAILABLE: &str = "the Runtime HDC control-action owner is unavailable";
const NO_OWNER: &str = "the Runtime control-action owner is unavailable";
const IDENTITY_REQUIRED: &str = "an exact control-action identity is required";
const UNSUPPORTED_FILTER: &str = "unsupported control-action discovery filter";
const STALE_CURSOR: &str =
    "cursor is invalid, belongs to another query or its snapshot was reclaimed";

/// The refusals Swift's handler (`hdcControlActionRequest`) gives before it
/// consults a control-action owner, so with or without one.
const HANDLER_REFUSALS: [&str; 5] = [
    HDC_UNAVAILABLE,
    IDENTITY_REQUIRED,
    "unknown control-action list field",
    "invalid page size",
    "invalid control-action cursor",
];

/// The published view runs these tests against the merge base's contract
/// inputs, which name their commit and may predate the no-host frames. The
/// checkout and the candidate view carry them.
fn published_view() -> bool {
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

fn corpus(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// One current frame through the control layer, answered as a value.
fn reply(control: &Control<crate::host::Host>, method: &str, params: Value) -> Value {
    let request = serde_json::to_vec(&json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": "control-action", "method": method, "params": params,
    }))
    .unwrap();
    serde_json::from_slice(control.handle_frame(&request).trim_ascii_end()).unwrap()
}

/// A refusal carrying only the zero-dispatch proof.
fn refusal(code: &str, message: &str) -> Value {
    json!({"code": code, "message": message, "details": {"newDispatchCount": 0}})
}

/// What the control layer answers for a host's `error`: the error when the
/// compiled schema of `method` publishes it, else `internalError`. The
/// checkout and candidate views must publish every answer asked here.
fn published(method: &str, error: Value) -> Value {
    let admitted = validate_method_value(method, "errorCode", &error["code"]).is_ok()
        && error
            .get("details")
            .is_none_or(|details| validate_method_value(method, "errorDetails", details).is_ok());
    assert!(
        admitted || published_view(),
        "{method} does not publish {error}"
    );
    if admitted {
        error
    } else {
        json!({"code": "internalError", "message": "the result does not conform to the current contract"})
    }
}

fn assert_refused(answer: &Value, method: &str, error: Value, context: &str) {
    assert_eq!(answer["ok"], false, "{context}: {answer}");
    assert!(answer.get("result").is_none(), "{context}: {answer}");
    assert_eq!(answer["error"], published(method, error), "{context}");
}

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

/// The empty snapshot page the union owner answers, and its revision.
fn empty_page(answer: &Value, context: &str) -> String {
    assert_eq!(answer["ok"], true, "{context}: {answer}");
    let revision = answer["result"]["snapshotRevision"]
        .as_str()
        .unwrap_or_else(|| panic!("{context}: {answer}"))
        .to_owned();
    assert!(is_uuid(&revision), "{context}: {revision}");
    assert_eq!(
        answer["result"],
        json!({
            "schemaVersion": "arkdeck.cli.page/1", "pageKind": "snapshot", "items": [],
            "order": ORDER, "snapshotRevision": revision, "hasMore": false, "nextCursor": null,
        }),
        "{context}"
    );
    revision
}

/// A private state root with the union owner's directory, made as the
/// isolated daemon makes it, and a development HDC that records any launch.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "control-action-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        HostDirectory::open(&root)
            .unwrap()
            .private_child("control-action-snapshots")
            .unwrap();
        // If anything dispatches the development HDC, the sentinel shows it.
        fs::write(
            root.join("hdc"),
            format!(
                "#!/bin/sh\ntouch '{}'\nexit 93\n",
                root.join("DISPATCHED").display()
            ),
        )
        .unwrap();
        fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        Self { root }
    }

    fn snapshots(&self) -> PathBuf {
        self.root.join("control-action-snapshots")
    }

    /// The isolated composition: the union owner beside a development HDC.
    fn owned(&self) -> Control<crate::host::Host> {
        let hdc = VerifiedTool::open(
            self.root.join("hdc"),
            &sha256_hex(&fs::read(self.root.join("hdc")).unwrap()),
        )
        .unwrap();
        Control::new(
            crate::host::Host::from_environment()
                .with_development_hdc(Some(ProcessDispatch::new(hdc, None)))
                .with_control_actions(ControlActionResources::open(&self.snapshots()).unwrap()),
        )
        .unwrap()
    }

    fn snapshot_files(&self) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(self.snapshots())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    /// Nothing but the fixture and the union owner's directory is here:
    /// in particular no `hdc-control-actions`, and no launch.
    fn assert_only_the_owner_wrote(&self) {
        let mut names: Vec<_> = fs::read_dir(&self.root)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["control-action-snapshots", "hdc"]);
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let dispatched = self.root.join("DISPATCHED").exists();
        fs::remove_dir_all(&self.root).unwrap();
        if !std::thread::panicking() {
            assert!(!dispatched, "a control-action route dispatched the HDC");
        }
    }
}

#[test]
fn every_no_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it() {
    let fixture = Fixture::new();
    let owned = fixture.owned();
    let standalone = Control::new(crate::host::Host::from_environment()).unwrap();
    let (mut by_owner, mut without_owner, mut managed, mut lines) = (0, 0, 0, 0);
    let mut owner_absent = 0;
    for method in METHODS {
        for (index, recorded) in corpus(method).into_iter().enumerate() {
            lines += 1;
            let context = format!("{method} line {}", index + 1);
            let params = recorded.get("params").cloned().unwrap_or_else(|| json!({}));
            if recorded["ok"] == true {
                if recorded["result"]["items"] != json!([]) {
                    managed += 1;
                    continue;
                }
                let answer = reply(&owned, method, params);
                let revision = empty_page(&answer, &context);
                let mut expected = recorded["result"].clone();
                expected["snapshotRevision"] = json!(revision);
                assert_eq!(answer["result"], expected, "{context}");
                by_owner += 1;
                continue;
            }
            let message = recorded["error"]["message"].as_str().unwrap();
            if message == NO_OWNER {
                // Recorded from a handler with no control-action owner at
                // all; the isolated composition always has one.
                owner_absent += 1;
            } else {
                let answer = reply(&owned, method, params.clone());
                assert_eq!(answer["ok"], false, "{context}: {answer}");
                assert_eq!(answer["error"], recorded["error"], "{context}");
                by_owner += 1;
            }
            if message == NO_OWNER || HANDLER_REFUSALS.contains(&message) {
                let answer = reply(&standalone, method, params);
                assert_eq!(answer["ok"], false, "{context}: {answer}");
                assert_eq!(answer["error"], recorded["error"], "{context}");
                without_owner += 1;
            }
        }
    }
    // Only the list's pages wrote, one snapshot each.
    let pages = corpus("control-action.list")
        .iter()
        .filter(|recorded| recorded["ok"] == true && recorded["result"]["items"] == json!([]))
        .count();
    assert_eq!(fixture.snapshot_files().len(), pages);
    assert_eq!(managed, 5, "the impact source's success frames");
    assert_eq!(owner_absent, 1, "the list of a handler with no owner");
    assert_eq!(lines, by_owner + owner_absent + managed);
    if !published_view() {
        // Every exchange the no-host run recorded, beside the corpus's own.
        assert_eq!((lines, by_owner, without_owner), (25, 19, 10));
    }
    drop(owned);
    fixture.assert_only_the_owner_wrote();
}

#[test]
fn the_union_owner_pages_an_empty_listing_in_private_snapshots() {
    let fixture = Fixture::new();
    // The owner's directory is private and holds no lock document: the owner
    // serves one request at a time, as Swift's actor does.
    let mode = |path: &Path| fs::symlink_metadata(path).unwrap().permissions().mode();
    assert_eq!(mode(&fixture.snapshots()) & 0o7777, 0o700);
    assert!(fs::symlink_metadata(fixture.snapshots()).unwrap().is_dir());
    let owned = fixture.owned();
    assert!(fixture.snapshot_files().is_empty());

    // The lifecycle methods answer before any parameter is read; an exact
    // identity is looked up and not found, a malformed one is refused first.
    let endpoint = format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710"));
    for params in [
        json!({}),
        json!({"action": "restart", "actionRequestId": "cli-action",
            "serverEndpointRef": endpoint, "expectedServerGeneration": "100000023"}),
    ] {
        let answer = reply(&owned, "runtime.hdc.impact-preview", params);
        assert_refused(
            &answer,
            "runtime.hdc.impact-preview",
            refusal("operationUnavailable", HDC_UNAVAILABLE),
            "preview",
        );
    }
    for params in [
        json!({}),
        json!({"controlAction": IDENTITY,
            "previewId": "preview-9a4d2c1e-6b3f-4e8a-8c7d-1f2e3d4c5b6a",
            "previewDigest": "d".repeat(64)}),
    ] {
        let answer = reply(&owned, "runtime.hdc.restart", params);
        assert_refused(
            &answer,
            "runtime.hdc.restart",
            refusal("operationUnavailable", HDC_UNAVAILABLE),
            "restart",
        );
    }
    for method in ["control-action.show", "control-action.reconcile"] {
        for (params, error) in [
            (
                json!({"controlAction": IDENTITY}),
                refusal("resourceNotFound", "control action does not exist"),
            ),
            (
                json!({"controlAction": "control action/1"}),
                refusal("invalidInput", IDENTITY_REQUIRED),
            ),
            (
                json!({"controlAction": IDENTITY, "executable": "/usr/bin/false"}),
                refusal("invalidInput", IDENTITY_REQUIRED),
            ),
        ] {
            let answer = reply(&owned, method, params.clone());
            assert_refused(&answer, method, error, &format!("{method} {params}"));
        }
    }
    assert!(fixture.snapshot_files().is_empty());

    // Each page is one new owner-only snapshot of one empty page, named by
    // its revision and bound to the query's filters and resolved page size.
    let tools = json!({"kind": "runtimeToolSelection", "state": "succeeded"});
    let mut listed = Vec::new();
    for (params, filters, size) in [
        (json!({}), json!({}), 100),
        (json!({"pageSize": 1000}), json!({}), 1000),
        (
            json!({"kind": "hdcLifecycle"}),
            json!({"kind": "hdcLifecycle"}),
            100,
        ),
        (
            json!({"state": "awaitingImpactApproval"}),
            json!({"state": "awaitingImpactApproval"}),
            100,
        ),
        (
            json!({"kind": "runtimeToolSelection", "state": "succeeded", "pageSize": 1}),
            tools.clone(),
            1,
        ),
    ] {
        let revision = empty_page(
            &reply(&owned, "control-action.list", params.clone()),
            "list",
        );
        let name = format!("snapshot-{revision}.json");
        listed.push((revision.clone(), params, filters.clone(), size));
        let mut names: Vec<_> = listed
            .iter()
            .map(|(revision, ..)| format!("snapshot-{revision}.json"))
            .collect();
        names.sort();
        assert_eq!(fixture.snapshot_files(), names);
        let file = fixture.snapshots().join(&name);
        let metadata = fs::symlink_metadata(&file).unwrap();
        assert!(metadata.is_file());
        assert_eq!(metadata.permissions().mode() & 0o7777, 0o600);
        let snapshot: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        let token = snapshot["tokens"][0].as_str().unwrap().to_owned();
        assert!(
            token
                .strip_prefix(&format!("{revision}."))
                .is_some_and(is_uuid),
            "{token}"
        );
        // The query's canonical bytes spelled out: sorted keys, no spaces.
        let query = format!(
            r#"{{"filters":{filters},"method":"control-action.list","order":"{ORDER}","pageSize":{size}}}"#
        );
        assert_eq!(
            snapshot,
            json!({
                "schemaVersion": "arkdeck.runtime-snapshot/1", "revision": revision,
                "queryDigest": sha256_hex(query.as_bytes()), "order": ORDER,
                "tokens": [token], "pages": [[]],
            })
        );
    }

    // A stored page is read again through its token, without a new snapshot
    // and across a restart of the owner; another query cannot read it.
    let token = |revision: &str| {
        let file = fixture
            .snapshots()
            .join(format!("snapshot-{revision}.json"));
        let snapshot: Value = serde_json::from_slice(&fs::read(file).unwrap()).unwrap();
        snapshot["tokens"][0].as_str().unwrap().to_owned()
    };
    let (first, ..) = &listed[0];
    let first_token = token(first);
    drop(owned);
    let owned = fixture.owned();
    let again = reply(
        &owned,
        "control-action.list",
        json!({"cursor": first_token}),
    );
    assert_eq!(&empty_page(&again, "stored page"), first);
    let answer = reply(
        &owned,
        "control-action.list",
        json!({"cursor": first_token, "pageSize": 1000}),
    );
    assert_refused(
        &answer,
        "control-action.list",
        refusal("invalidCursor", STALE_CURSOR),
        "another query",
    );

    // A refused list reads no page and publishes no snapshot.
    for (params, error) in [
        (
            json!({"kind": "adbLifecycle"}),
            refusal("invalidInput", UNSUPPORTED_FILTER),
        ),
        (
            json!({"state": "running"}),
            refusal("invalidInput", UNSUPPORTED_FILTER),
        ),
        (
            json!({"kind": 1}),
            refusal("invalidInput", UNSUPPORTED_FILTER),
        ),
        (
            json!({"pageSize": 0}),
            refusal("invalidInput", "invalid page size"),
        ),
        (
            json!({"cursor": "not-a-cursor"}),
            refusal("invalidCursor", STALE_CURSOR),
        ),
        (
            json!({"cursor": format!("{first}.00000000-0000-4000-8000-000000000000")}),
            refusal("invalidCursor", STALE_CURSOR),
        ),
        (
            json!({"cursor": "c".repeat(257)}),
            refusal("invalidCursor", "invalid control-action cursor"),
        ),
    ] {
        let answer = reply(&owned, "control-action.list", params.clone());
        assert_refused(&answer, "control-action.list", error, &params.to_string());
    }
    assert_eq!(fixture.snapshot_files().len(), listed.len());
    drop(owned);
    fixture.assert_only_the_owner_wrote();
}

#[test]
fn retention_keeps_the_latest_32_snapshots_within_64_mib() {
    let fixture = Fixture::new();
    let owned = fixture.owned();
    let first = empty_page(&reply(&owned, "control-action.list", json!({})), "first");
    let file = fixture.snapshots().join(format!("snapshot-{first}.json"));
    let snapshot: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    let cursor = snapshot["tokens"][0].as_str().unwrap().to_owned();
    for index in 0..32 {
        empty_page(
            &reply(&owned, "control-action.list", json!({})),
            &format!("page {index}"),
        );
    }
    // The 33rd page reclaimed the oldest, whose cursor is now stale.
    let files = fixture.snapshot_files();
    assert_eq!(files.len(), 32);
    assert!(!files.contains(&format!("snapshot-{first}.json")));
    let answer = reply(&owned, "control-action.list", json!({"cursor": cursor}));
    assert_refused(
        &answer,
        "control-action.list",
        refusal("invalidCursor", STALE_CURSOR),
        "reclaimed",
    );
    drop(owned);

    // Four older snapshots of 16 MiB fill the 64 MiB: the next page
    // reclaims the oldest of them, and no more.
    let fixture = Fixture::new();
    let planted: Vec<_> = (0..4)
        .map(|index| format!("snapshot-00000000-0000-4000-8000-00000000000{index}.json"))
        .collect();
    for (index, name) in planted.iter().enumerate() {
        let file = fs::File::create(fixture.snapshots().join(name)).unwrap();
        file.set_len(16 * 1024 * 1024).unwrap();
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .unwrap();
        file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(60 * index as u64))
            .unwrap();
    }
    let owned = fixture.owned();
    let revision = empty_page(&reply(&owned, "control-action.list", json!({})), "full");
    let mut expected = planted[1..].to_vec();
    expected.push(format!("snapshot-{revision}.json"));
    expected.sort();
    assert_eq!(fixture.snapshot_files(), expected);

    // More than 32 snapshots is not a store this owner made: refused with
    // only the zero-dispatch proof, and nothing is reclaimed.
    for index in 0..29 {
        let file = fixture.snapshots().join(format!(
            "snapshot-00000000-0000-4000-8000-1000000000{index:02}.json"
        ));
        fs::write(&file, b"{}").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    }
    assert_eq!(fixture.snapshot_files().len(), 33);
    let answer = reply(&owned, "control-action.list", json!({}));
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error"]["code"], "recordUnreadable", "{answer}");
    assert_eq!(answer["error"]["details"], json!({"newDispatchCount": 0}));
    assert_eq!(fixture.snapshot_files().len(), 33);
}

#[test]
fn without_the_owner_the_host_answers_as_swifts_handler_with_none() {
    // The standalone composition keeps no state, so it has no union owner:
    // Swift's handler then refuses as before, and answers the owner's absence
    // where its schema publishes it.
    let standalone = Control::new(crate::host::Host::from_environment()).unwrap();
    for method in ["runtime.hdc.impact-preview", "runtime.hdc.restart"] {
        for params in [json!({}), json!({"controlAction": IDENTITY})] {
            let answer = reply(&standalone, method, params);
            assert_refused(
                &answer,
                method,
                refusal("operationUnavailable", HDC_UNAVAILABLE),
                method,
            );
        }
    }
    let foundation = json!({"code": "rejected",
        "message": "this method is unavailable in the read-only Rust foundation"});
    for method in ["control-action.show", "control-action.reconcile"] {
        for (params, error) in [
            (json!({}), refusal("invalidInput", IDENTITY_REQUIRED)),
            (
                json!({"controlAction": "control action/1"}),
                refusal("invalidInput", IDENTITY_REQUIRED),
            ),
            // Swift: operationUnavailable, which these schemas do not publish.
            (json!({"controlAction": IDENTITY}), foundation.clone()),
        ] {
            let answer = reply(&standalone, method, params.clone());
            assert_refused(&answer, method, error, &format!("{method} {params}"));
        }
    }
    for (params, error) in [
        (json!({}), refusal("operationUnavailable", NO_OWNER)),
        // The owner's filter check never runs without it.
        (
            json!({"kind": "adbLifecycle", "pageSize": 1}),
            refusal("operationUnavailable", NO_OWNER),
        ),
        (
            json!({"owner": "x"}),
            refusal("invalidInput", "unknown control-action list field"),
        ),
        (
            json!({"pageSize": 1001}),
            refusal("invalidInput", "invalid page size"),
        ),
        (
            json!({"cursor": "c".repeat(257)}),
            refusal("invalidCursor", "invalid control-action cursor"),
        ),
    ] {
        let answer = reply(&standalone, "control-action.list", params.clone());
        assert_refused(&answer, "control-action.list", error, &params.to_string());
    }
}
