use arkdeck_contract::*;
use arkdeck_control::{Control, HdcStatus, HostServices};
use serde_json::{Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

struct Host {
    reads: Arc<AtomicUsize>,
}
impl HostServices for Host {
    fn observed_at(&self) -> String {
        "2026-09-01T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        let data = include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/device.observations.jsonl"
        );
        let result = data
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|record| record["ok"] == true)
            .unwrap()["result"]
            .clone();
        Ok(serde_json::from_value(result).unwrap())
    }
}
fn setup() -> (Control<Host>, Arc<AtomicUsize>) {
    let reads = Arc::new(AtomicUsize::new(0));
    (
        Control::new(Host {
            reads: Arc::clone(&reads),
        })
        .unwrap(),
        reads,
    )
}
fn call<H: HostServices>(control: &Control<H>, method: &str, params: Value) -> Response {
    let request = Request::new("test", method, params.as_object().cloned());
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let response = control.handle_frame(&frame[..frame.len() - 1]);
    decode_response(&response[..response.len() - 1], "test", method).unwrap()
}

#[test]
fn operation_descriptors_and_unconfigured_doctor_match_the_current_swift_outputs() {
    let (control, reads) = setup();
    for (method, corpus) in [
        (
            "operation.list",
            include_str!(
                "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.list.jsonl"
            ),
        ),
        (
            "doctor",
            include_str!(
                "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/doctor.jsonl"
            ),
        ),
    ] {
        let recorded: Value = serde_json::from_str(corpus.lines().next().unwrap()).unwrap();
        let response = call(
            &control,
            method,
            recorded.get("params").cloned().unwrap_or(Value::Null),
        );
        let actual = response.outcome.unwrap();
        if method == "doctor" {
            assert_eq!(actual, recorded["result"]);
        } else {
            let actual = actual.as_array().unwrap();
            let expected = recorded["result"].as_array().unwrap();
            assert_eq!(actual.len(), expected.len());
            for (actual, expected) in actual.iter().zip(expected) {
                // The Swift recording has an HDC provider. Compare shared
                // descriptors exactly, and only compare availability where
                // both hosts lack the operation provider.
                for field in [
                    "reference",
                    "canonicalReference",
                    "aliasFor",
                    "minimumEffect",
                    "binding",
                    "profiles",
                ] {
                    assert_eq!(actual[field], expected[field], "{field}");
                }
                assert_eq!(actual["availability"], "unavailable");
                assert_eq!(actual["reasonCodes"], json!(["provider_not_registered"]));
                if expected["reasonCodes"] == json!(["provider_not_registered"]) {
                    assert_eq!(actual, expected);
                }
            }
        }
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn every_unimplemented_method_is_refused_without_entering_the_host() {
    let (control, reads) = setup();
    for method in METHODS {
        if [
            "health",
            "doctor",
            "operation.list",
            "device.observations",
            "runtime.tool.inspect",
            "runtime.bundle.inspect",
            "operation.describe",
            "runtime.tool.register",
        ]
        .contains(method)
        {
            continue;
        }
        let response = call(&control, method, json!({}));
        assert_eq!(response.outcome.unwrap_err().code, "rejected", "{method}");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn semantic_invalid_requests_do_not_trigger_observation_or_capability_paths() {
    let (control, reads) = setup();
    for (method, params, code) in [
        ("operation.describe", json!({}), "invalidParams"),
        (
            "operation.describe",
            json!({"reference": 1}),
            "invalidParams",
        ),
        (
            "operation.describe",
            json!({"reference": "unknown@1"}),
            "notFound",
        ),
        ("doctor", json!({"deep":"true"}), "invalidParams"),
        ("doctor", json!({"unknown":true}), "invalidParams"),
        ("health", json!({"padding":"x"}), "invalidParams"),
        ("operation.list", json!({"path":"/tmp"}), "invalidParams"),
        (
            "device.observations",
            json!({"candidateKey":"untrusted"}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"useWarmSnapshot":true}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"following":null}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"following":{}}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"following":{"candidate":"x","observationId":"old","observationGeneration":"01"}}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"following":{"candidate":"x","observationId":"old","observationGeneration":"9223372036854775808"}}),
            "invalidInput",
        ),
        (
            "device.observations",
            json!({"following":{"candidate":"x","observationId":"old","observationGeneration":"1"}}),
            "resourceConflict",
        ),
    ] {
        assert_eq!(
            call(&control, method, params).outcome.unwrap_err().code,
            code
        );
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn accepted_observation_uses_the_host_once_and_preserves_its_complete_projection() {
    let (control, reads) = setup();
    let response = call(&control, "device.observations", json!({}));
    let result = response.outcome.unwrap();
    assert_eq!(result["schemaVersion"], "arkdeck.device-observations/1");
    assert_eq!(reads.load(Ordering::SeqCst), 1);
}

#[test]
fn malformed_wrong_contract_and_unknown_methods_fail_before_host_entry() {
    let (control, reads) = setup();
    let valid = serde_json::to_value(Request::new("test", "device.observations", None)).unwrap();
    let mut wrong_version = valid.clone();
    wrong_version["protocolVersion"] = json!("2.0.0");
    let mut wrong_identity = valid.clone();
    wrong_identity["contractIdentity"] = json!("0".repeat(64));
    let mut unknown = valid.clone();
    unknown["method"] = json!("device.candidates");
    let mut forged = valid.clone();
    forged["arkdeckOrigin"] = json!({"foregroundConsole":true});
    for (frame, code) in [
        (b"{".to_vec(), "malformedFrame"),
        (vec![0xff], "malformedFrame"),
        (
            serde_json::to_vec(&wrong_version).unwrap(),
            "unsupportedProtocolVersion",
        ),
        (
            serde_json::to_vec(&wrong_identity).unwrap(),
            "unsupportedProtocolVersion",
        ),
        (serde_json::to_vec(&unknown).unwrap(), "unknownMethod"),
        (serde_json::to_vec(&forged).unwrap(), "malformedFrame"),
        (vec![b'x'; MAX_REQUEST_BYTES], "malformedFrame"),
    ] {
        let reply = control.handle_frame(&frame);
        let response: Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], code);
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn bootstrap_reads_validate_before_owner_and_refuse_an_unconfigured_owner() {
    let (control, reads) = setup();
    for (method, key, prefix) in [
        ("runtime.tool.inspect", "tool", "tool:sha256:"),
        ("runtime.bundle.inspect", "bundle", "bundle:sha256:"),
    ] {
        if !METHODS.contains(&method) {
            // A published input view predating this additive RPC must still
            // refuse it. Candidate views below exercise its complete handler.
            let request = Request::new("test", method, Some(serde_json::Map::new()));
            let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
            let reply: Value =
                serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1])).unwrap();
            assert_eq!(reply["error"]["code"], "unknownMethod");
            continue;
        }
        for params in [
            json!({}),
            json!({key:1}),
            json!({key:"bad"}),
            json!({key:format!("{prefix}{}", "0".repeat(64)),"path":"/tmp"}),
        ] {
            let error = call(&control, method, params).outcome.unwrap_err();
            assert_eq!(error.code, "invalidParams");
            assert_eq!(
                error.details,
                Some(serde_json::Map::from_iter([
                    ("phase".into(), json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), json!(0))
                ]))
            );
        }
        let error = call(
            &control,
            method,
            json!({key:format!("{prefix}{}", "0".repeat(64))}),
        )
        .outcome
        .unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn deveco_registration_is_closed_and_unpublished_views_never_reach_an_owner() {
    let (control, reads) = setup();
    let method = "runtime.tool.register";
    if !METHODS.contains(&method) {
        let request = Request::new("test", method, Some(serde_json::Map::new()));
        let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
        let reply: Value =
            serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1])).unwrap();
        assert_eq!(reply["error"]["code"], "unknownMethod");
        assert_eq!(reads.load(Ordering::SeqCst), 0);
        return;
    }
    for params in [
        json!({}),
        json!({"kind":"hdc","root":"/A.app/Contents"}),
        json!({"kind":"deveco","file":"/A.app/Contents"}),
        json!({"kind":"deveco","root":null}),
        json!({"kind":"deveco","root":"relative"}),
        json!({"kind":"deveco","root":"/A.app/../Contents"}),
        json!({"kind":"deveco","root":"/A.app/./Contents"}),
        json!({"kind":"deveco","root":"/A.app/Contents\0"}),
        json!({"kind":"deveco","root":"/A.app/Contents","registeredAtUTC":"2026-09-11T00:00:00Z"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "invalidParams");
        assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
    }
    for root in ["/A.app/Contents", "/A.app/Contents/", "/A.app//Contents"] {
        let error = call(&control, method, json!({"kind":"deveco","root":root}))
            .outcome
            .unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(
            error.details.as_ref().unwrap()["phase"],
            "bootstrapRegistryOwner"
        );
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn registration_lost_classified_receipts_preserve_uncertainty_after_one_owner_call() {
    struct ReceiptFailureHost {
        calls: Arc<AtomicUsize>,
        receipt: Result<Value, WireError>,
    }
    impl HostServices for ReceiptFailureHost {
        fn observed_at(&self) -> String {
            "2026-09-11T00:00:00Z".into()
        }
        fn hdc_status(&self, deep: bool) -> HdcStatus {
            HdcStatus::unavailable(deep, "hdc.notConfigured")
        }
        fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
            panic!("registration must not observe devices")
        }
        fn bootstrap_register_deveco(&self, _: &str) -> Result<Value, WireError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.receipt.clone()
        }
    }
    for receipt in [
        Ok(json!({"invalidReceipt": true})),
        Err(WireError {
            code: "unclassified".into(),
            message: "lost classification".into(),
            details: None,
        }),
        Err(WireError {
            code: "outcomeUnknown".into(),
            message: "x".repeat(MAX_RESPONSE_BYTES),
            details: None,
        }),
    ] {
        let calls = Arc::new(AtomicUsize::new(0));
        let control = Control::new(ReceiptFailureHost {
            calls: Arc::clone(&calls),
            receipt,
        })
        .unwrap();
        let method = "runtime.tool.register";
        if !METHODS.contains(&method) {
            let request = Request::new("test", method, Some(serde_json::Map::new()));
            let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
            let reply: Value =
                serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1])).unwrap();
            assert_eq!(reply["error"]["code"], "unknownMethod");
            assert_eq!(calls.load(Ordering::SeqCst), 0);
            continue;
        }
        let error = call(
            &control,
            method,
            json!({"kind":"deveco", "root":"/A.app/Contents"}),
        )
        .outcome
        .unwrap_err();
        assert_eq!(error.code, "outcomeUnknown");
        assert_eq!(
            error.details.as_ref().unwrap()["phase"],
            "bootstrapRegistryOwner"
        );
        assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
}
