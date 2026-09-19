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
            "workspace.project.register",
            "workspace.project.list",
            "workspace.project.show",
            "workspace.project.update",
            "workspace.project.remove",
            "workspace.preset.list",
            "workspace.preset.show",
            "workspace.preset.register",
            "workspace.preset.update",
            "workspace.preset.remove",
            "artifact.export",
            "artifact.import.list",
            "artifact.import.begin",
            "artifact.import.append",
            "artifact.import.abort",
            "artifact.import.inspect",
            "artifact.import.inspection",
            "artifact.import.commit",
            "artifact.import.release",
            "artifact.inspect",
            "artifact.list",
            "artifact.read",
            "health",
            "doctor",
            "operation.list",
            "target.availability",
            "device.observations",
            "runtime.tool.list",
            "runtime.tool.remove",
            "runtime.tool.inspect",
            "runtime.bundle.inspect",
            "runtime.bundle.register",
            "operation.describe",
            "runtime.tool.register",
            "runtime.bundle.list",
            "runtime.bundle.remove",
        ]
        .contains(method)
        {
            continue;
        }
        let response = call(&control, method, json!({}));
        let expected = if matches!(
            *method,
            "target.list"
                | "target.show"
                | "target.display-name.set"
                | "target.display-name.clear"
                | "device.display-name.set"
                | "device.display-name.clear"
        ) {
            "internalError"
        } else {
            "rejected"
        };
        assert_eq!(response.outcome.unwrap_err().code, expected, "{method}");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

/// Swift's handler refuses a malformed workspace mutation or preset request
/// with its own message and no owner details, before it asks for the owner.
#[test]
fn workspace_mutation_and_preset_parameters_answer_swift_s_refusals() {
    let (control, reads) = setup();
    // A symbol definition under `identity`, then `extra` over both.
    let symbol = |identity: serde_json::Value, extra: serde_json::Value| {
        let mut fields = json!({"kind":"symbol", "templateRef":"openharmony.arkts-symbol@1",
            "timeoutSeconds":"600", "relativeSourceMap":"entry/a.map"});
        for (key, value) in identity
            .as_object()
            .unwrap()
            .iter()
            .chain(extra.as_object().unwrap())
        {
            fields[key] = value.clone();
        }
        fields
    };
    let register = |extra| {
        symbol(
            json!({"registrationRequestId":"r", "projectRef":"p"}),
            extra,
        )
    };
    let update = |extra| {
        symbol(
            json!({"mutationRequestId":"m", "projectRef":"p", "presetRef":"preset-x",
                   "expectedGeneration":"1"}),
            extra,
        )
    };
    let project_update =
        "workspace project update requires exact project, generation, kind and root";
    let project_remove = "workspace project remove requires exact project and generation";
    let preset_register = "workspace preset register requires one closed typed definition";
    let preset_update =
        "workspace preset update requires identity, exact generation and definition";
    let preset_remove = "workspace preset remove requires identity and exact generation";
    for (method, params, message) in [
        ("workspace.project.update", json!({}), project_update),
        (
            "workspace.project.update",
            json!({"projectRef":"p", "expectedGeneration":"0", "kind":"openharmony", "root":"/tmp"}),
            project_update,
        ),
        (
            "workspace.project.remove",
            json!({"projectRef":"p", "expectedGeneration":"01"}),
            project_remove,
        ),
        ("workspace.preset.list", json!({}), "projectRef is required"),
        (
            "workspace.preset.list",
            json!({"projectRef":"p", "extra":"x"}),
            "workspace preset list accepts only projectRef and kind",
        ),
        (
            "workspace.preset.list",
            json!({"projectRef":"p", "kind":3}),
            "kind must be text",
        ),
        (
            "workspace.preset.show",
            json!({"projectRef":"p", "presetRef":""}),
            "projectRef and presetRef are required",
        ),
        (
            "workspace.preset.show",
            json!({"projectRef":"p", "presetRef":"preset-x", "extra":"x"}),
            "workspace preset show requires exact projectRef and presetRef",
        ),
        ("workspace.preset.register", json!({}), preset_register),
        (
            "workspace.preset.register",
            json!({"registrationRequestId":"preset-missing"}),
            preset_register,
        ),
        (
            "workspace.preset.register",
            register(json!({"timeoutSeconds":"0600"})),
            preset_register,
        ),
        (
            "workspace.preset.register",
            register(json!({"toolchainGeneration":1})),
            preset_register,
        ),
        (
            "workspace.preset.register",
            register(json!({"credentialRef":null})),
            preset_register,
        ),
        (
            "workspace.preset.register",
            register(json!({"note":"x"})),
            preset_register,
        ),
        (
            "workspace.preset.register",
            register(json!({"projectRef":7})),
            preset_register,
        ),
        ("workspace.preset.update", json!({}), preset_update),
        (
            "workspace.preset.update",
            update(json!({"expectedGeneration":"0"})),
            preset_update,
        ),
        (
            "workspace.preset.update",
            json!({"mutationRequestId":"m", "projectRef":"p", "presetRef":"preset-x",
                   "expectedGeneration":"2"}),
            preset_update,
        ),
        ("workspace.preset.remove", json!({}), preset_remove),
        (
            "workspace.preset.remove",
            json!({"mutationRequestId":"m", "projectRef":"p", "presetRef":"preset-x",
                   "expectedGeneration":"1", "kind":"symbol"}),
            preset_remove,
        ),
    ] {
        let error = call(&control, method, params.clone()).outcome.unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str(), error.details),
            ("invalidParams", message, None),
            "{method} {params}"
        );
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
    // A well-formed request reaches the owner.
    for (method, params) in [
        ("workspace.preset.register", register(json!({}))),
        (
            "workspace.preset.register",
            register(
                json!({"kind":"build", "templateRef":"openharmony.hvigor-build@1",
                "toolchainRef":"toolchain:sha256:x", "toolchainGeneration":"1",
                "module":"entry", "product":"default", "buildMode":"debug"}),
            ),
        ),
        ("workspace.preset.update", update(json!({}))),
        (
            "workspace.preset.remove",
            json!({"mutationRequestId":"m", "projectRef":"p", "presetRef":"preset-x",
                   "expectedGeneration":"1"}),
        ),
    ] {
        assert_ne!(
            call(&control, method, params.clone())
                .outcome
                .unwrap_err()
                .code,
            "invalidParams",
            "{method} {params}"
        );
    }
}

#[test]
fn workspace_project_parameters_are_checked_before_owner_availability() {
    let (control, reads) = setup();
    for (method, params) in [
        ("workspace.project.register", json!({})),
        (
            "workspace.project.register",
            json!({"registrationRequestId":"r", "kind":"openharmony", "root":3}),
        ),
        (
            "workspace.project.register",
            json!({"registrationRequestId":"r", "kind":"openharmony", "root":"/tmp/project", "extra":true}),
        ),
        ("workspace.project.show", json!({})),
        ("workspace.project.show", json!({"projectRef":""})),
        (
            "workspace.project.show",
            json!({"projectRef":"project-fixture", "extra":true}),
        ),
        ("workspace.project.list", json!({"root":"/tmp/project"})),
        ("workspace.project.update", json!({})),
        (
            "workspace.project.update",
            json!({"projectRef":"p", "expectedGeneration":"0", "kind":"openharmony", "root":"/tmp"}),
        ),
        (
            "workspace.project.update",
            json!({"projectRef":"p", "expectedGeneration":"1", "kind":"openharmony"}),
        ),
        ("workspace.project.remove", json!({"projectRef":"p"})),
        (
            "workspace.project.remove",
            json!({"projectRef":"p", "expectedGeneration":"01"}),
        ),
        ("workspace.preset.list", json!({})),
        ("workspace.preset.list", json!({"projectRef":"p", "kind":3})),
        (
            "workspace.preset.list",
            json!({"projectRef":"p", "extra":"x"}),
        ),
        ("workspace.preset.show", json!({"projectRef":"p"})),
        (
            "workspace.preset.show",
            json!({"projectRef":"p", "presetRef":""}),
        ),
    ] {
        assert_eq!(
            call(&control, method, params).outcome.unwrap_err().code,
            "invalidParams",
            "{method}"
        );
    }
    for (method, params) in [
        (
            "workspace.project.register",
            json!({"registrationRequestId":"r", "kind":"openharmony", "root":"/tmp/project"}),
        ),
        (
            "workspace.project.show",
            json!({"projectRef":"project-fixture"}),
        ),
        ("workspace.project.list", json!({})),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        let expected = if validate_method_value(method, "errorCode", &json!("operationUnavailable"))
            .is_ok()
            && validate_method_value(
                method,
                "errorDetails",
                &json!({"phase":"workspaceProjectOwner","newDispatchCount":0}),
            )
            .is_ok()
        {
            "operationUnavailable"
        } else {
            "internalError"
        };
        assert_eq!(error.code, expected, "{method}");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

/// Swift's `hdcControlActionRequest` reads these six methods' parameters
/// itself, so the control layer hands each request to the host's
/// control-action service unread, and no other method reaches it. The host's
/// answer then passes the method's schema like any other.
#[test]
fn the_control_action_methods_reach_their_host_service_unread() {
    const ROUTED: [&str; 6] = [
        "control-action.list",
        "control-action.reconcile",
        "control-action.show",
        "runtime.hdc.impact-preview",
        "runtime.hdc.restart",
        "runtime.tool.select",
    ];
    struct ControlActionHost {
        asked: Arc<std::sync::Mutex<Vec<(String, Value)>>>,
    }
    impl HostServices for ControlActionHost {
        fn observed_at(&self) -> String {
            "2026-09-19T00:00:00Z".into()
        }
        fn hdc_status(&self, deep: bool) -> HdcStatus {
            HdcStatus::unavailable(deep, "hdc.notConfigured")
        }
        fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
            Err(WireError {
                code: "rejected".into(),
                message: "device observations are not served here".into(),
                details: None,
            })
        }
        fn control_action(
            &self,
            method: &str,
            params: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            self.asked
                .lock()
                .unwrap()
                .push((method.into(), Value::Object(params.clone())));
            Err(WireError {
                code: "operationUnavailable".into(),
                message: "the Runtime HDC control-action owner is unavailable".into(),
                details: Some(serde_json::Map::from_iter([(
                    "newDispatchCount".into(),
                    json!(0),
                )])),
            })
        }
    }
    let asked = Arc::new(std::sync::Mutex::new(Vec::new()));
    let control = Control::new(ControlActionHost {
        asked: Arc::clone(&asked),
    })
    .unwrap();
    for method in METHODS {
        let _ = call(&control, method, json!({}));
    }
    let mut routed: Vec<_> = asked
        .lock()
        .unwrap()
        .drain(..)
        .map(|(method, _)| method)
        .collect();
    routed.sort();
    assert_eq!(routed, ROUTED);
    for method in ROUTED {
        let params = json!({"controlAction":"control action/1", "pageSize":0, "extra":[1]});
        let error = call(&control, method, params.clone()).outcome.unwrap_err();
        assert_eq!(
            asked.lock().unwrap().pop(),
            Some((method.to_owned(), params)),
            "{method}"
        );
        // Show and reconcile do not publish it: the schema check rewrites it.
        let published =
            validate_method_value(method, "errorCode", &json!("operationUnavailable")).is_ok();
        assert_eq!(
            published,
            !matches!(method, "control-action.show" | "control-action.reconcile"),
            "{method}"
        );
        let expected = if published {
            "operationUnavailable"
        } else {
            "internalError"
        };
        assert_eq!(error.code, expected, "{method}");
    }
}

#[test]
fn target_availability_requires_identity_and_an_owner_without_observing_devices() {
    let (control, reads) = setup();
    assert_eq!(
        call(&control, "target.availability", json!({}))
            .outcome
            .unwrap_err()
            .code,
        "invalidParams"
    );
    assert_eq!(
        call(
            &control,
            "target.availability",
            json!({"targetId":"target-fixture"})
        )
        .outcome
        .unwrap_err()
        .code,
        "internalError"
    );
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
            "runtime.hdc.status",
            json!({"path":"/tmp/hdc"}),
            "invalidParams",
        ),
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
        json!({"kind":"hdc","file":null}),
        json!({"kind":"hdc","file":"relative"}),
        json!({"kind":"hdc","file":"/tmp/../hdc"}),
        json!({"kind":"hdc","file":"/tmp/./hdc"}),
        json!({"kind":"hdc","file":"/tmp/hdc\0"}),
        json!({"kind":"hdc","file":"/tmp/hdc","root":"/tmp"}),
        json!({"kind":"hdc","file":"/tmp/hdc","registeredAtUTC":"2026-09-11T00:00:00Z"}),
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
    for file in ["/tmp/hdc", "/tmp/a b/hdc", "//tmp//hdc"] {
        let error = call(&control, method, json!({"kind":"hdc","file":file}))
            .outcome
            .unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(
            error.details.as_ref().unwrap()["phase"],
            "bootstrapRegistryOwner"
        );
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
fn bootstrap_mutation_lost_classified_receipts_preserve_uncertainty_after_one_owner_call() {
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
        fn bootstrap_register_bundle(&self, file: &str) -> Result<Value, WireError> {
            self.bootstrap_register_deveco(file)
        }
        fn bootstrap_register_hdc(&self, file: &str) -> Result<Value, WireError> {
            self.bootstrap_register_deveco(file)
        }
        fn bootstrap_tool_remove(&self, reference: &str, _: &str) -> Result<Value, WireError> {
            self.bootstrap_register_deveco(reference)
        }
        fn bootstrap_register_deveco(&self, _: &str) -> Result<Value, WireError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.receipt.clone()
        }
    }
    for (method, params) in [
        (
            "runtime.bundle.register",
            json!({"kind":"daemon-bundle","file":"/Source.app"}),
        ),
        (
            "runtime.tool.register",
            json!({"kind":"deveco","root":"/A.app/Contents"}),
        ),
        (
            "runtime.tool.register",
            json!({"kind":"hdc","file":"/tmp/hdc"}),
        ),
        (
            "runtime.tool.remove",
            json!({"tool":"tool:sha256:a", "expectedGeneration":"1"}),
        ),
        (
            "runtime.tool.remove",
            json!({"tool":"toolchain:sha256:b", "expectedGeneration":"1"}),
        ),
    ] {
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
            if !METHODS.contains(&method) {
                let request = Request::new("test", method, Some(serde_json::Map::new()));
                let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
                let reply: Value =
                    serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1]))
                        .unwrap();
                assert_eq!(reply["error"]["code"], "unknownMethod");
                assert_eq!(calls.load(Ordering::SeqCst), 0);
                continue;
            }
            let error = call(&control, method, params.clone()).outcome.unwrap_err();
            assert_eq!(error.code, "outcomeUnknown");
            assert_eq!(
                error.details.as_ref().unwrap()["phase"],
                "bootstrapRegistryOwner"
            );
            assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        }
    }
}

#[test]
fn bundle_list_structure_is_closed_and_unconfigured_owner_is_explicit() {
    let (control, reads) = setup();
    let method = "runtime.bundle.list";
    if !METHODS.contains(&method) {
        let request = Request::new("test", method, Some(serde_json::Map::new()));
        let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
        let reply: Value =
            serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1])).unwrap();
        assert_eq!(reply["error"]["code"], "unknownMethod");
        return;
    }
    for params in [
        json!({"pageSize":null}),
        json!({"pageSize":1.5}),
        json!({"cursor":1}),
        json!({"path":"/private/tmp/forbidden"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "invalidParams");
        assert_eq!(error.details.unwrap()["newDispatchCount"], 0);
    }
    for params in [
        json!({}),
        json!({"pageSize":1}),
        json!({"pageSize":0,"cursor":"invalid"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(error.details.unwrap()["phase"], "bootstrapRegistryOwner");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn bundle_retirement_is_typed_and_unconfigured_owner_is_explicit() {
    let (control, reads) = setup();
    let method = "runtime.bundle.remove";
    if !METHODS.contains(&method) {
        return;
    }
    for params in [
        json!({}),
        json!({"bundle":null,"expectedGeneration":"1"}),
        json!({"bundle":"invalid","expectedGeneration":1}),
        json!({"bundle":"invalid","expectedGeneration":"1","path":"/tmp"}),
    ] {
        assert_eq!(
            call(&control, method, params).outcome.unwrap_err().code,
            "invalidParams"
        );
    }
    let error = call(
        &control,
        method,
        json!({"bundle":"invalid","expectedGeneration":"2"}),
    )
    .outcome
    .unwrap_err();
    assert_eq!(error.code, "operationUnavailable");
    assert_eq!(error.details.unwrap()["phase"], "bootstrapRegistryOwner");
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn tool_retirement_is_typed_and_unconfigured_owner_is_explicit() {
    let (control, reads) = setup();
    let method = "runtime.tool.remove";
    if !METHODS.contains(&method) {
        return;
    }
    for params in [
        json!({}),
        json!({"tool":null,"expectedGeneration":"1"}),
        json!({"tool":"invalid","expectedGeneration":1}),
        json!({"tool":"invalid","expectedGeneration":"1","path":"/tmp"}),
    ] {
        assert_eq!(
            call(&control, method, params).outcome.unwrap_err().code,
            "invalidParams"
        );
    }
    let error = call(
        &control,
        method,
        json!({"tool":"invalid","expectedGeneration":"2"}),
    )
    .outcome
    .unwrap_err();
    assert_eq!(error.code, "operationUnavailable");
    assert_eq!(error.details.unwrap()["phase"], "bootstrapRegistryOwner");
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn tool_list_structure_is_closed_and_unconfigured_owner_is_explicit() {
    let (control, reads) = setup();
    let method = "runtime.tool.list";
    if !METHODS.contains(&method) {
        let request = Request::new("test", method, Some(serde_json::Map::new()));
        let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
        let reply: Value =
            serde_json::from_slice(&control.handle_frame(&frame[..frame.len() - 1])).unwrap();
        assert_eq!(reply["error"]["code"], "unknownMethod");
        return;
    }
    for params in [
        json!({"pageSize":null}),
        json!({"pageSize":1.5}),
        json!({"cursor":1}),
        json!({"path":"/private/tmp/forbidden"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "invalidParams");
        assert_eq!(error.details.unwrap()["newDispatchCount"], 0);
    }
    for params in [
        json!({}),
        json!({"pageSize":1}),
        json!({"pageSize":0,"cursor":"invalid"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(error.details.unwrap()["phase"], "bootstrapRegistryOwner");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn bundle_registration_rejects_caller_authority_and_observes_nothing() {
    let (control, reads) = setup();
    let method = "runtime.bundle.register";
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
        json!({"kind":"hdc","file":"/Source.app"}),
        json!({"kind":"daemon-bundle","file":"relative.app"}),
        json!({"kind":"daemon-bundle","file":"/tmp/../Source.app"}),
        json!({"kind":"daemon-bundle","file":"/Source.app","digest":"caller-digest"}),
        json!({"kind":"daemon-bundle","file":"/Source.app","registeredAtUTC":"2026-09-12T00:00:00Z"}),
        json!({"kind":"daemon-bundle","file":"/Source.app","capability":"caller-authority"}),
    ] {
        let error = call(&control, method, params).outcome.unwrap_err();
        assert_eq!(error.code, "invalidParams");
        assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
    }
    let error = call(
        &control,
        method,
        json!({"kind":"daemon-bundle","file":"/Source.app"}),
    )
    .outcome
    .unwrap_err();
    assert_eq!(error.code, "operationUnavailable");
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}

#[test]
fn artifact_methods_report_unconfigured_owner_and_route_exact_typed_parameters() {
    let (control, reads) = setup();
    for method in ["artifact.inspect", "artifact.read", "artifact.export"] {
        let failure = call(
            &control,
            method,
            json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"ART-1"}),
        )
        .outcome
        .unwrap_err();
        assert_eq!(failure.code, "operationUnavailable");
        assert_eq!(failure.details.unwrap()["phase"], "artifactOwner");
    }
    assert_eq!(reads.load(Ordering::SeqCst), 0);
    struct ArtifactHost;
    impl HostServices for ArtifactHost {
        fn observed_at(&self) -> String {
            "2026-09-12T00:00:00Z".into()
        }
        fn hdc_status(&self, _: bool) -> HdcStatus {
            panic!("Artifact query entered HDC")
        }
        fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
            panic!("Artifact query entered HDC")
        }
        fn artifact_resource(
            &self,
            method: &str,
            params: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            assert_eq!(method, "artifact.read");
            assert_eq!(params,&json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"ART-1","offset":2,"maxBytes":3,"allowSensitive":false}).as_object().unwrap().clone());
            Ok(
                json!({"artifactId":"ART-1","artifactDigest":"a".repeat(64),"offset":2,"nextOffset":5,"totalByteCount":5,"byteCount":3,"base64":"YWJj","eof":true}),
            )
        }
    }
    let control = Control::new(ArtifactHost).unwrap();
    let result = call(&control,"artifact.read",json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"ART-1","offset":2,"maxBytes":3,"allowSensitive":false})).outcome.unwrap();
    assert_eq!(result["base64"], "YWJj");
}

#[test]
fn import_upload_methods_use_only_the_typed_import_owner() {
    struct ImportHost;
    impl HostServices for ImportHost {
        fn observed_at(&self) -> String {
            panic!("Import read the unrelated clock")
        }
        fn hdc_status(&self, _: bool) -> HdcStatus {
            panic!("Import touched HDC")
        }
        fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
            panic!("Import touched device observations")
        }
        fn import_resource(
            &self,
            method: &str,
            params: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            assert!(method.starts_with("artifact.import."));
            assert_eq!(params.get("importRequestId").unwrap(), "stable-request");
            Err(WireError {
                code: "operationUnavailable".into(),
                message: "Target/publication/reference owner missing".into(),
                details: Some(
                    json!({"phase":"importOwner","newDispatchCount":0})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            })
        }
    }
    let control = Control::new(ImportHost).unwrap();
    for method in [
        "artifact.import.list",
        "artifact.import.begin",
        "artifact.import.append",
        "artifact.import.abort",
        "artifact.import.inspect",
        "artifact.import.inspection",
        "artifact.import.commit",
        "artifact.import.release",
    ] {
        let response = call(
            &control,
            method,
            json!({"importRequestId":"stable-request"}),
        )
        .outcome
        .unwrap_err();
        // The published view keeps its old vocabulary until the actual Swift
        // producer supplement merges; candidate inputs expose the owner refusal.
        let available =
            validate_method_value(method, "errorCode", &json!("operationUnavailable")).is_ok();
        assert_eq!(
            response.code,
            if available {
                "operationUnavailable"
            } else {
                "internalError"
            }
        );
        if available {
            assert_eq!(response.details.unwrap()["phase"], "importOwner");
        }
    }
}

#[test]
fn physical_resume_routes_reach_the_same_execution_owner() {
    struct ResumeHost(Arc<AtomicUsize>, &'static str);
    impl HostServices for ResumeHost {
        fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
            panic!("resume routes must reach their execution owner")
        }

        fn observed_at(&self) -> String {
            "2026-09-14T00:00:00Z".into()
        }
        fn hdc_status(&self, deep: bool) -> HdcStatus {
            HdcStatus::unavailable(deep, "hdc.notConfigured")
        }
        fn agent_execution(
            &self,
            method: &str,
            params: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            assert!(matches!(method, "agent.resume" | "human-action.resume"));
            assert_eq!(params["resumeReference"], "resume-missing");
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(WireError {
                code: self.1.into(),
                message: "human action does not exist".into(),
                details: Some(
                    serde_json::from_value(
                        if method == "agent.resume"
                            && ["recordUnreadable", "factsDrifted"].contains(&self.1)
                        {
                            json!({})
                        } else {
                            json!({"phase":"preAdmission","newDispatchCount":0})
                        },
                    )
                    .unwrap(),
                ),
            })
        }
    }
    let calls = Arc::new(AtomicUsize::new(0));
    for code in [
        "resourceNotFound",
        "idempotencyConflict",
        "orchestrationClockUntrusted",
        "orchestrationBudgetExpired",
        "admissionDenied",
        "resourceConflict",
        "reviewedPlanMismatch",
        "recordUnreadable",
        "factsDrifted",
    ] {
        let control = Control::new(ResumeHost(calls.clone(), code)).unwrap();
        for method in ["agent.resume", "human-action.resume"] {
            let params = if method == "agent.resume" {
                json!({"resumeReference":"resume-missing"})
            } else {
                json!({"resumeReference":"resume-missing","humanAction":"har-missing"})
            };
            // Published source views retain their old sampled error vocabulary.
            // Candidate views must expose the newly recorded owner refusals.
            let supported = validate_method_value(method, "errorCode", &json!(code)).is_ok()
                && !(method == "agent.resume"
                    && ["recordUnreadable", "factsDrifted"].contains(&code)
                    && validate_method_value(method, "errorDetails", &json!({})).is_err());
            assert_eq!(
                call(&control, method, params).outcome.unwrap_err().code,
                if supported { code } else { "internalError" }
            );
        }
    }
    assert_eq!(calls.load(Ordering::SeqCst), 18);
}
