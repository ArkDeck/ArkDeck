//! A separately versioned current-Catalog HAP software oracle. Fresh Runtime
//! authority comes from the real owners over an isolated fake transport;
//! no old seed, fixture pin, or production authority is rewritten.
use super::Owners;
use crate::support::{catalog_lineage as lineage, debug_hap, document, oracle_fake};
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

pub const NAME: &str = "debug-hap-catalog-e4-v1";
const ORIGINAL: &str = "debug-hap";
pub fn fixture_name() -> &'static str {
    match CATALOG_DIGEST {
        lineage::CURRENT => NAME,
        lineage::OLD => ORIGINAL,
        _ => panic!("unreviewed HAP software oracle Catalog"),
    }
}
const CURRENT_PROVENANCE_SHA: &str =
    "8b76964022be81197457a65f4afdae8e60a491cfae38f9957d0471475d005160";
const ORIGINAL_PROVENANCE_SHA: &str =
    "fe26006785b607a762acfb2f85b8cc5d7f244e40dbf61f2005c484d1f693e251";

pub fn assert_historical_source() {
    let lineage = lineage::Lineage::frozen().unwrap();
    lineage
        .assert_catalog_view_sources(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Catalog/operations"),
            CATALOG_DIGEST,
        )
        .unwrap();
    lineage.operation("debug.hap@1").unwrap();
    lineage::HapPlans::frozen().unwrap();
    let old = crate::support::fixture(ORIGINAL);
    assert_eq!(
        sha256_hex(&fs::read(old.join("provenance.json")).unwrap()),
        ORIGINAL_PROVENANCE_SHA
    );
    let provenance = document(&old, "provenance.json");
    assert_eq!(provenance["files"].as_object().unwrap().len(), 198);
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(old.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "original {name}"
        );
    }
}

pub fn assert_plan(actual: &Value, exchange: &Value, root: &Path) {
    let old = document(&crate::support::fixture(ORIGINAL), "cases.json");
    let original = super::exchange(&old, exchange["name"].as_str().unwrap());
    assert_eq!(exchange["params"], original["params"]);
    if original["answer"]["ok"] == true {
        lineage::HapPlans::frozen()
            .unwrap()
            .verify_hap_plan_answer(actual, original, root)
            .unwrap();
    } else {
        assert_eq!(
            actual, &original["answer"],
            "unchanged whole pre-admission refusal"
        );
    }
}

pub fn assert_original_calls(log: &str, root: &Path) {
    let expected =
        fs::read_to_string(crate::support::fixture(ORIGINAL).join("hdc-invocations.log")).unwrap();
    assert_eq!(expected.lines().count(), 108);
    assert_eq!(
        oracle_fake::oracle_spelling(log, root),
        expected,
        "all 108 historical dispatches retain exact order and arguments"
    );
}

fn write_new(root: &Path, name: &str, bytes: &[u8]) {
    let path = root.join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .unwrap();
    file.write_all(bytes).unwrap();
    file.sync_all().unwrap();
}

pub fn record(
    output: &Path,
    historical: &Path,
    owners: &Owners,
    cases: &Value,
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) {
    assert_eq!(
        output.file_name().and_then(|name| name.to_str()),
        Some(NAME)
    );
    assert!(!output.exists(), "CREATE_NEW output tree");
    assert_historical_source();
    let original = debug_hap::tree_bytes(historical);
    assert_eq!(original.len(), 199);
    assert_original_calls(&owners.calls(), &owners.root);
    validate_exchanges(&document(historical, "cases.json"), cases);
    fs::create_dir(output).unwrap();
    let mut files = BTreeMap::new();
    for name in ["hdc", "hdc-answers.sh", "targets-state/targets.json"] {
        files.insert(name.to_owned(), fs::read(owners.root.join(name)).unwrap());
    }
    files.insert(
        "cases.json".into(),
        serde_json::to_vec_pretty(cases).unwrap(),
    );
    files.insert(
        "hdc-invocations.log".into(),
        spelled(owners.calls().as_bytes()),
    );
    files.insert(
        "store/index.json".into(),
        serde_json::to_vec_pretty(&crate::support::index_normalized(
            &owners.default_root,
            spelled,
        ))
        .unwrap(),
    );
    let mut tree = Vec::new();
    for (base, prefix) in [
        (owners.default_root.join("jobs"), "store/jobs"),
        (
            owners.default_root.join("capabilities"),
            "store/capabilities",
        ),
        (owners.root.join("Sessions"), "sessions"),
        (owners.root.join("session-owner"), "session-owner"),
    ] {
        let mut bytes = BTreeMap::new();
        crate::support::walk(&base, prefix, &mut bytes, &mut tree);
        files.extend(
            bytes
                .into_iter()
                .map(|(name, bytes)| (name, spelled(&bytes))),
        );
    }
    files.extend(
        crate::support::artifacts(&owners.root.join("artifacts"))
            .into_iter()
            .map(|(name, bytes)| (name, spelled(&bytes))),
    );
    files.insert(
        "tree.json".into(),
        serde_json::to_vec_pretty(
            &tree
                .iter()
                .map(|(path, kind, mode)| json!({"path":path,"kind":kind,"mode":mode}))
                .collect::<Vec<_>>(),
        )
        .unwrap(),
    );
    let mut provenance = owners.provenance.clone();
    provenance["producer"] = json!(
        "Rust debug_hap_current_oracle::record_current_hap_oracle; isolated synthetic dispatch, not hardware evidence"
    );
    provenance["catalogDigest"] = json!(CATALOG_DIGEST);
    provenance["hardwareEvidence"] = json!(false);
    provenance["scopedDelta"] =
        json!("CHG-2026-081 unchanged HAP descriptor; current Catalog authority lineage");
    provenance
        .as_object_mut()
        .unwrap()
        .remove("catalogRegeneration");
    provenance["originalFixture"] = json!("../debug-hap");
    provenance["planCapsuleSha256"] =
        json!("686920fba1d6ecdfe52a18014b5da25f66668a9181ffe37101a92c3ca4fa381f");
    provenance["originalFiles"] = json!(
        original
            .iter()
            .map(|(path, bytes)| (path.to_string_lossy().replace('\\', "/"), sha256_hex(bytes)))
            .collect::<BTreeMap<_, _>>()
    );
    provenance["files"] = json!(
        files
            .iter()
            .map(|(name, bytes)| (name.clone(), sha256_hex(bytes)))
            .collect::<BTreeMap<_, _>>()
    );
    for (name, bytes) in files {
        write_new(output, &name, &bytes);
    }
    write_new(
        output,
        "provenance.json",
        &serde_json::to_vec_pretty(&provenance).unwrap(),
    );
    assert_eq!(
        debug_hap::tree_bytes(historical),
        original,
        "all historical bytes unchanged"
    );
}

pub fn validate_exchanges(original: &Value, current: &Value) {
    assert_eq!(
        original.as_object().unwrap().keys().collect::<Vec<_>>(),
        current.as_object().unwrap().keys().collect::<Vec<_>>()
    );
    assert_eq!(original["jobs"], current["jobs"]);
    assert_eq!(original["leases"], current["leases"]);
    assert_eq!(original["target"], current["target"]);
    let old = original["exchanges"].as_array().unwrap();
    let new = current["exchanges"].as_array().unwrap();
    assert_eq!(old.len(), 63);
    assert_eq!(new.len(), 63);
    let old_caps = &super::exchange(original, "capabilities.list")["answer"]["result"];
    let new_caps = &super::exchange(current, "capabilities.list")["answer"]["result"];
    assert_eq!(old_caps.as_array().unwrap().len(), 2);
    assert_eq!(new_caps.as_array().unwrap().len(), 2);
    for (old, new) in old.iter().zip(new) {
        for field in ["name", "method", "mode"] {
            assert_eq!(old[field], new[field]);
        }
        if old["method"] != "capability.inspect" {
            assert_eq!(old["params"], new["params"]);
        } else {
            assert_eq!(new["params"].as_object().unwrap().len(), 1);
            let id = new["params"]["capabilityId"].as_str().unwrap();
            let at = old_caps
                .as_array()
                .unwrap()
                .iter()
                .position(|row| row["capabilityId"] == old["params"]["capabilityId"])
                .unwrap();
            assert_eq!(
                new_caps[at]["capabilityId"], id,
                "inspect same position's exact newly issued reference"
            );
        }
        assert_eq!(old["answer"]["ok"], new["answer"]["ok"]);
        if old["answer"]["ok"] == false {
            assert_eq!(
                old["answer"]["error"]["code"],
                new["answer"]["error"]["code"]
            );
        }
        for key in ["state", "outcomeUnknown", "outstandingResidueCount"] {
            assert_eq!(
                old["answer"]["result"][key], new["answer"]["result"][key],
                "same observed {key}"
            );
        }
    }
    for (old, new) in old_caps
        .as_array()
        .unwrap()
        .iter()
        .zip(new_caps.as_array().unwrap())
    {
        let mut new = new.clone();
        new["capabilityId"] = old["capabilityId"].clone();
        assert_eq!(
            old, &new,
            "all fresh lineage use/outcome/count predicates unchanged"
        );
    }
}

pub fn assert_source(fixture: &Path) {
    assert_historical_source();
    assert_eq!(
        sha256_hex(&fs::read(fixture.join("provenance.json")).unwrap()),
        CURRENT_PROVENANCE_SHA
    );
    let provenance = document(fixture, "provenance.json");
    assert_eq!(provenance["catalogDigest"], CATALOG_DIGEST);
    assert_eq!(provenance["hardwareEvidence"], false);
    assert_eq!(
        provenance["planCapsuleSha256"],
        "686920fba1d6ecdfe52a18014b5da25f66668a9181ffe37101a92c3ca4fa381f"
    );
    let old = crate::support::fixture(ORIGINAL);
    let bytes = debug_hap::tree_bytes(&old);
    assert_eq!(bytes.len(), 199);
    assert_eq!(
        json!(
            bytes
                .iter()
                .map(|(path, bytes)| (path.to_string_lossy().replace('\\', "/"), sha256_hex(bytes)))
                .collect::<BTreeMap<_, _>>()
        ),
        provenance["originalFiles"]
    );
    validate_exchanges(
        &document(&old, "cases.json"),
        &document(fixture, "cases.json"),
    );
    assert_eq!(
        fs::read(fixture.join("hdc-invocations.log")).unwrap(),
        fs::read(old.join("hdc-invocations.log")).unwrap()
    );
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap()
        );
    }
}
