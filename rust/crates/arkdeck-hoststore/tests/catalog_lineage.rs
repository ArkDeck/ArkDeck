//! Portable software-only proof of the exact unchanged-operation Catalog
//! lineage. No owner, subprocess, endpoint, HDC or capability is opened.
#[path = "support/catalog_lineage.rs"]
mod lineage;

use arkdeck_contract::sha256_hex;
use lineage::{CURRENT, HapPlans, Lineage, OLD};
use serde_json::{Value, json};
use std::path::Path;

const CASES: &[u8] = include_bytes!("../../../tests/fixtures/job-plan-analyzer/cases.json");
const CASES_SHA: &str = "0ddb0b69f9c032147556b7144313ebab447a6c9ba55d37576db75a6216ec9892";
const EXECUTABLE_SHA: &str = "a7362eb6be376728a4ae9923d35d3bdb1532f42942064f195a274a6be220530a";
const PAYLOAD: &str = "/private/tmp/arkdeck-job-plan-oracle/artifacts/job-oracle-source/ART-cf645cc2f23c16cf9965b179bcb35b5e";

fn planned() -> Vec<Value> {
    assert_eq!(sha256_hex(CASES), CASES_SHA);
    serde_json::from_slice::<Vec<Value>>(CASES)
        .unwrap()
        .into_iter()
        .filter(|case| case["response"]["ok"] == true)
        .collect()
}

fn plan(lineage: &Lineage, case: &Value) -> Value {
    let request: Value =
        serde_json::from_str(case["params"]["requestJson"].as_str().unwrap()).unwrap();
    lineage
        .crash_signature_plan(&request, EXECUTABLE_SHA, PAYLOAD)
        .unwrap()
}

#[test]
fn all_thirty_one_unchanged_descriptors_have_the_exact_complete_catalog_lineage() {
    let lineage = Lineage::frozen().unwrap();
    lineage
        .assert_catalog_view_sources(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Catalog/operations"),
            arkdeck_contract::CATALOG_DIGEST,
        )
        .unwrap();
    assert!(
        lineage
            .operation("deploy.native-library.app-owned@1")
            .is_err()
    );
    assert!(lineage.operation("unknown@1").is_err());
}

#[test]
fn both_complete_source_views_are_exact_and_wrong_view_or_descriptor_drift_refuse() {
    let lineage = Lineage::frozen().unwrap();
    let packet: Value = serde_json::from_slice(include_bytes!(
        "../../../tests/fixtures/catalog-lineage-c6-e4/catalogs.json"
    ))
    .unwrap();
    let root = std::env::temp_dir().join(format!(
        "arkdeck-lineage-source-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    for (field, digest, wrong) in [
        ("historicalOperations", OLD, CURRENT),
        ("currentOperations", CURRENT, OLD),
    ] {
        let directory = root.join(field);
        std::fs::create_dir(&directory).unwrap();
        let rows = packet[field].as_array().unwrap();
        assert_eq!(rows.len(), 32);
        for (index, row) in rows.iter().enumerate() {
            std::fs::write(
                directory.join(format!("{index}.json")),
                serde_json::to_vec(row).unwrap(),
            )
            .unwrap();
        }
        lineage
            .assert_catalog_view_sources(&directory, digest)
            .unwrap();
        assert!(
            lineage
                .assert_catalog_view_sources(&directory, wrong)
                .is_err()
        );
        assert!(
            lineage
                .assert_catalog_view_sources(&directory, "unknown")
                .is_err()
        );
        assert_eq!(
            lineage.assert_current_sources(&directory).is_ok(),
            digest == CURRENT
        );
        let mut altered = rows[0].clone();
        altered["extraSourceField"] = json!(true);
        std::fs::write(
            directory.join("0.json"),
            serde_json::to_vec(&altered).unwrap(),
        )
        .unwrap();
        assert!(
            lineage
                .assert_catalog_view_sources(&directory, digest)
                .is_err()
        );
        std::fs::remove_file(directory.join("0.json")).unwrap();
        assert!(
            lineage
                .assert_catalog_view_sources(&directory, digest)
                .is_err()
        );
        for index in 1..rows.len() {
            std::fs::remove_file(directory.join(format!("{index}.json"))).unwrap();
        }
        std::fs::remove_dir(&directory).unwrap();
    }
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn all_four_frozen_analyzer_plans_prove_the_whole_old_hash_before_deriving_current() {
    let lineage = Lineage::frozen().unwrap();
    let cases = planned();
    assert_eq!(cases.len(), 4);
    for case in cases {
        let current = plan(&lineage, &case);
        let historical = case["response"]["result"]["materializedPlanDigest"]
            .as_str()
            .unwrap();
        let current_sha = lineage.current_digest(&current, historical).unwrap();
        let mut old = current.clone();
        old["catalogDigest"] = json!(OLD);
        assert_eq!(sha256_hex(&lineage::plan_bytes(&old).unwrap()), historical);
        assert_ne!(current_sha, historical);
        let mut actual = case["response"].clone();
        actual["result"]["catalogDigest"] = json!(CURRENT);
        actual["result"]["materializedPlanDigest"] = json!(current_sha);
        assert_eq!(
            lineage
                .historical_answer(&actual, &case["response"], &current)
                .unwrap(),
            case["response"],
            "{}",
            case["name"]
        );
    }
}

#[test]
fn changed_full_plan_fields_and_unknown_catalog_or_operation_never_relabel() {
    let lineage = Lineage::frozen().unwrap();
    let case = &planned()[0];
    let current = plan(&lineage, case);
    let historical = case["response"]["result"]["materializedPlanDigest"]
        .as_str()
        .unwrap();
    for field in [
        "targetID",
        "providerID",
        "inputs",
        "steps",
        "catalogDigest",
        "operationReference",
    ] {
        let mut altered = current.clone();
        match field {
            "inputs" => altered[field]["sourceArtifactRef"] = json!("lease-v1:job-other:ART-other"),
            "steps" => altered[field][0]["argumentSummary"][1] = json!("/different-source"),
            "catalogDigest" => altered[field] = json!(OLD),
            "operationReference" => altered[field] = json!("deploy.native-library.app-owned@1"),
            _ => altered[field] = json!("drift"),
        }
        assert!(
            lineage.current_digest(&altered, historical).is_err(),
            "{field}"
        );
    }
    for field in [
        "timeoutSeconds",
        "executableSHA256",
        "journalArguments",
        "effect",
        "binding",
        "isOptional",
    ] {
        let mut altered = current.clone();
        altered["steps"][0][field] = json!("changed");
        assert!(
            lineage.current_digest(&altered, historical).is_err(),
            "{field}"
        );
    }
    let mut missing = current.clone();
    missing.as_object_mut().unwrap().remove("steps");
    assert!(lineage.current_digest(&missing, historical).is_err());
    let mut extra = current.clone();
    extra["unapproved"] = json!(true);
    assert!(lineage.current_digest(&extra, historical).is_err());
    let mut fractional = current.clone();
    fractional["steps"][0]["timeoutSeconds"] = json!(0.5);
    assert!(lineage.current_digest(&fractional, historical).is_err());
    assert!(lineage.current_digest(&current, &"f".repeat(64)).is_err());
}

#[test]
fn frame_drift_and_actual_hash_drift_remain_whole_answer_failures() {
    let lineage = Lineage::frozen().unwrap();
    let case = &planned()[0];
    let current = plan(&lineage, case);
    let expected = &case["response"];
    let current_sha = lineage
        .current_digest(
            &current,
            expected["result"]["materializedPlanDigest"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
    let mut actual = expected.clone();
    actual["result"]["catalogDigest"] = json!(CURRENT);
    actual["result"]["materializedPlanDigest"] = json!(current_sha);
    let mut wrong_hash = actual.clone();
    wrong_hash["result"]["materializedPlanDigest"] = json!("0".repeat(64));
    assert!(
        lineage
            .historical_answer(&wrong_hash, expected, &current)
            .is_err()
    );
    let mut refused = actual.clone();
    refused["ok"] = json!(false);
    assert!(
        lineage
            .historical_answer(&refused, expected, &current)
            .is_err()
    );
    for field in [
        "unexpected",
        "bindingRevision",
        "requestFingerprintSha256",
        "steps",
    ] {
        let mut drift = actual.clone();
        drift["result"][field] = json!("drift");
        let projected = lineage
            .historical_answer(&drift, expected, &current)
            .unwrap();
        assert_ne!(projected, *expected, "projection must not erase {field}");
    }
    // A historical durable seed is never a newly produced plan envelope.
    assert!(
        lineage
            .historical_answer(&json!({"catalogDigest":OLD}), expected, &current)
            .is_err()
    );
}

#[test]
fn unknown_lineage_and_catalog_descriptor_tampering_are_refused() {
    let bytes = include_bytes!("../../../tests/fixtures/catalog-lineage-c6-e4/catalogs.json");
    let original: Value = serde_json::from_slice(bytes).unwrap();
    for field in [
        "oldCatalogDigest",
        "currentCatalogDigest",
        "oldSourceCommit",
        "schemaVersion",
    ] {
        let mut changed = original.clone();
        changed[field] = json!("unknown");
        assert!(Lineage::validated(&changed).is_err(), "{field}");
    }
    for member in ["historicalOperations", "currentOperations"] {
        let mut changed = original.clone();
        changed[member][0]["timeoutSeconds"] = json!(1);
        assert!(Lineage::validated(&changed).is_err());
        let mut duplicated = original.clone();
        duplicated[member][1] = duplicated[member][0].clone();
        assert!(Lineage::validated(&duplicated).is_err());
    }
    let mut extra = original.clone();
    extra["genericTranslation"] = json!(true);
    assert!(Lineage::validated(&extra).is_err());
}

#[test]
fn all_ten_hap_capsules_prove_exact_raw_host_digest_and_whole_answer() {
    let plans = HapPlans::frozen().unwrap();
    let source: Value = serde_json::from_slice(include_bytes!(
        "../../../tests/fixtures/debug-hap/cases.json"
    ))
    .unwrap();
    let root = std::env::temp_dir().join("arkdeck-lineage-no-files-created");
    let mut count = 0;
    for exchange in source["exchanges"].as_array().unwrap() {
        if exchange["method"] != "job.plan" || exchange["answer"]["ok"] != true {
            continue;
        }
        let name = exchange["name"].as_str().unwrap();
        let plan = HapPlans::at_root(plans.current_plan(name).unwrap(), &root).unwrap();
        let mut actual = HapPlans::at_root(&exchange["answer"], &root).unwrap();
        actual["result"]["catalogDigest"] = json!(CURRENT);
        actual["result"]["materializedPlanDigest"] =
            json!(sha256_hex(&lineage::plan_bytes(&plan).unwrap()));
        actual["result"]["stepSetDigestSHA256"] = json!(plans.step_set_digest(name).unwrap());
        assert_eq!(
            plans
                .verify_hap_plan_answer(&actual, exchange, &root)
                .unwrap(),
            actual
        );
        let mut drift = actual.clone();
        drift["result"]["materializedPlanDigest"] = json!("0".repeat(64));
        assert!(
            plans
                .verify_hap_plan_answer(&drift, exchange, &root)
                .is_err()
        );
        drift = actual.clone();
        drift["result"]["stepSetDigestSHA256"] = json!("0".repeat(64));
        assert!(
            plans
                .verify_hap_plan_answer(&drift, exchange, &root)
                .is_err()
        );
        drift = actual.clone();
        drift["result"]
            .as_object_mut()
            .unwrap()
            .remove("stepSetDigestSHA256");
        assert!(
            plans
                .verify_hap_plan_answer(&drift, exchange, &root)
                .is_err()
        );
        drift = actual.clone();
        drift["result"]["unrelated"] = json!(true);
        assert!(
            plans
                .verify_hap_plan_answer(&drift, exchange, &root)
                .is_err()
        );
        let mut wrong_exchange = exchange.clone();
        wrong_exchange["params"]["requestJson"] = json!("{}");
        assert!(
            plans
                .verify_hap_plan_answer(&actual, &wrong_exchange, &root)
                .is_err()
        );
        assert!(
            plans
                .verify_hap_plan_answer(&actual, exchange, Path::new("relative"))
                .is_err()
        );
        count += 1;
    }
    assert_eq!(count, 10);
}

#[test]
fn hap_capsule_missing_duplicate_unknown_request_and_full_plan_drift_refuse() {
    let packet: Value = serde_json::from_slice(include_bytes!(
        "../../../tests/fixtures/catalog-lineage-c6-e4/hap-plans.json"
    ))
    .unwrap();
    for edit in [
        "missing",
        "duplicate",
        "unknown",
        "request",
        "hash",
        "plan",
        "source",
        "extra",
    ] {
        let mut value = packet.clone();
        match edit {
            "missing" => {
                value["rows"].as_array_mut().unwrap().pop();
            }
            "duplicate" => value["rows"][1] = value["rows"][0].clone(),
            "unknown" => value["rows"][0]["case"] = json!("unknown.plan"),
            "request" => value["rows"][0]["requestJson"] = json!("{}"),
            "hash" => value["rows"][0]["currentPlanSha256"] = json!("f".repeat(64)),
            "plan" => {
                value["rows"][0]["completeCurrentPlan"]["steps"][0]["unrelated"] = json!(true)
            }
            "source" => value["sourceCasesSha256"] = json!("f".repeat(64)),
            _ => value["rows"][0]["genericMapping"] = json!(true),
        }
        assert!(HapPlans::validated(&value).is_err(), "{edit}");
    }
}

#[test]
fn hap_path_substitution_is_only_an_exact_path_string_leaf() {
    let root = std::env::temp_dir().join("arkdeck-lineage-no-files-created");
    let value = json!({"/private/tmp/arkdeck-hdc-oracle/key":
        ["near /private/tmp/arkdeck-hdc-oracle/artifacts/a", "/private/tmp/arkdeck-hdc-oracle-other/artifacts/a",
         "/private/tmp/arkdeck-hdc-oracle/artifacts/a"]});
    let mapped = HapPlans::at_root(&value, &root).unwrap();
    let rows = mapped["/private/tmp/arkdeck-hdc-oracle/key"]
        .as_array()
        .unwrap();
    assert_eq!(rows[0], value["/private/tmp/arkdeck-hdc-oracle/key"][0]);
    assert_eq!(rows[1], value["/private/tmp/arkdeck-hdc-oracle/key"][1]);
    assert_eq!(
        rows[2],
        json!(root.join("artifacts").join("a").to_string_lossy())
    );
    assert!(HapPlans::at_root(&json!("/private/tmp/arkdeck-hdc-oracle/../other"), &root).is_err());
}
