//! Actual Control/Host consumption of a private workspace registration owner.
use arkdeck_contract::{Request, decode_response, encode_frame, validate_method_value};
use arkdeck_control::Control;
use arkdeck_hoststore::WorkspaceProjectStore;
use serde_json::{Value, json};
use std::{fs, os::unix::fs::DirBuilderExt};
#[test]
fn actual_host_registers_lists_and_reads_a_project_after_restart() {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "workspace-project-control-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    for name in ["owner", "project"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(name))
            .unwrap();
    }
    let compose = || {
        Control::new(
            crate::host::Host::from_environment()
                .with_workspace_projects(WorkspaceProjectStore::open(&root.join("owner")).unwrap()),
        )
        .unwrap()
    };
    let call = |control: &Control<crate::host::Host>, method: &str, params: Value| {
        let request = Request::new(
            "workspace-1",
            method,
            Some(serde_json::from_value(params).unwrap()),
        );
        let frame = encode_frame(&request, arkdeck_contract::MAX_REQUEST_BYTES).unwrap();
        let bytes = control.handle_frame(frame.trim_ascii_end());
        decode_response(bytes.trim_ascii_end(), "workspace-1", method)
            .unwrap()
            .outcome
    };
    let control = compose();
    let resource=call(&control,"workspace.project.register",json!({"registrationRequestId":"request-1","kind":"openharmony","root":root.join("project").to_str().unwrap()})).unwrap();
    assert!(!resource.to_string().contains(root.to_str().unwrap()));
    let reference = resource["projectRef"].clone();
    drop(control);
    let reopened = compose();
    assert_eq!(
        call(&reopened, "workspace.project.list", json!({})).unwrap()["projects"],
        json!([resource])
    );
    let shown = call(
        &reopened,
        "workspace.project.show",
        json!({"projectRef":reference}),
    );
    if validate_method_value("workspace.project.show", "result", &resource).is_ok() {
        assert_eq!(shown.unwrap(), resource);
    } else {
        assert_eq!(
            shown.unwrap_err().code,
            "internalError",
            "published unsampled view still refuses unsupported response shape"
        );
    }
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

/// The project mutations and preset reads through the actual Control and
/// Host. A mutation consults the durable Job census; without a Job owner
/// nothing proves that no active Job names the project, so it is refused.
#[test]
fn actual_host_updates_removes_and_reads_presets_through_the_job_census() {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "workspace-mutation-control-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    for name in ["owner", "jobs", "first", "second"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(name))
            .unwrap();
    }
    let compose = |jobs: bool| {
        let host = crate::host::Host::from_environment()
            .with_workspace_projects(WorkspaceProjectStore::open(&root.join("owner")).unwrap());
        let host = if jobs {
            host.with_jobs(arkdeck_hoststore::JobStore::open_owner(&root.join("jobs")).unwrap())
        } else {
            host
        };
        Control::new(host).unwrap()
    };
    let call = |control: &Control<crate::host::Host>, method: &str, params: Value| {
        let request = Request::new(
            "workspace-2",
            method,
            Some(serde_json::from_value(params).unwrap()),
        );
        let frame = encode_frame(&request, arkdeck_contract::MAX_REQUEST_BYTES).unwrap();
        let bytes = control.handle_frame(frame.trim_ascii_end());
        decode_response(bytes.trim_ascii_end(), "workspace-2", method)
            .unwrap()
            .outcome
    };
    let control = compose(true);
    let path = |name: &str| root.join(name).to_str().unwrap().to_owned();
    let project = call(
        &control,
        "workspace.project.register",
        json!({"registrationRequestId": "request-2", "kind": "openharmony", "root": path("first")}),
    )
    .unwrap()["projectRef"]
        .clone();
    let listed = call(
        &control,
        "workspace.preset.list",
        json!({"projectRef": project}),
    )
    .unwrap();
    assert_eq!(listed["presets"], json!([]));
    assert_eq!(
        call(
            &control,
            "workspace.preset.show",
            json!({"projectRef": project, "presetRef": "preset-absent"})
        )
        .unwrap_err()
        .code,
        "workspaceReferenceNotFound"
    );
    for (method, params) in [
        (
            "workspace.project.update",
            json!({"projectRef": project, "expectedGeneration": "01",
            "kind": "openharmony", "root": path("second")}),
        ),
        ("workspace.project.remove", json!({"projectRef": project})),
        (
            "workspace.preset.list",
            json!({"projectRef": project, "extra": "x"}),
        ),
        ("workspace.preset.show", json!({"projectRef": project})),
    ] {
        assert_eq!(
            call(&control, method, params.clone()).unwrap_err().code,
            "invalidParams",
            "{method} {params}"
        );
    }
    let moved = call(
        &control,
        "workspace.project.update",
        json!({"projectRef": project, "expectedGeneration": "1", "kind": "openharmony",
               "root": path("second")}),
    )
    .unwrap();
    assert_eq!(moved["generation"], "2");
    assert!(!moved.to_string().contains(&path("second")));
    drop(control);
    let unverified = compose(false);
    assert_eq!(
        call(
            &unverified,
            "workspace.project.remove",
            json!({"projectRef": project, "expectedGeneration": "2"})
        )
        .unwrap_err()
        .code,
        "recordUnreadable",
        "without the Job owner a removal cannot prove no active Job names the project"
    );
    drop(unverified);
    let removed = call(
        &compose(true),
        "workspace.project.remove",
        json!({"projectRef": project, "expectedGeneration": "2"}),
    )
    .unwrap();
    assert_eq!(removed["configurationStatus"], "removed");
    assert_eq!(removed["availability"], "removed");
    fs::remove_dir_all(root).unwrap();
}

/// Preset registration, update and removal through the actual Control and
/// Host of the isolated daemon, which composes no DevEco toolchain or signing
/// credential owner: a symbol preset is served in full, a preset that pins
/// either is refused before any write, and an update or removal without the
/// Job owner cannot prove that no active Job names the preset.
#[test]
fn actual_host_registers_updates_and_removes_presets_without_dependency_owners() {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "workspace-preset-control-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    for name in ["owner", "jobs", "first"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(name))
            .unwrap();
    }
    let compose = |jobs: bool| {
        let host = crate::host::Host::from_environment()
            .with_workspace_projects(WorkspaceProjectStore::open(&root.join("owner")).unwrap());
        let host = if jobs {
            host.with_jobs(arkdeck_hoststore::JobStore::open_owner(&root.join("jobs")).unwrap())
        } else {
            host
        };
        Control::new(host).unwrap()
    };
    let call = |control: &Control<crate::host::Host>, method: &str, params: Value| {
        let request = Request::new(
            "workspace-3",
            method,
            Some(serde_json::from_value(params).unwrap()),
        );
        let frame = encode_frame(&request, arkdeck_contract::MAX_REQUEST_BYTES).unwrap();
        let bytes = control.handle_frame(frame.trim_ascii_end());
        decode_response(bytes.trim_ascii_end(), "workspace-3", method)
            .unwrap()
            .outcome
    };
    let refusal = |error: arkdeck_contract::WireError| {
        (
            error.code,
            error.message,
            error.details.map(|details| details["phase"].clone()),
        )
    };
    let document = || fs::read(root.join("owner/projects.json")).unwrap();
    let control = compose(true);
    let project = call(
        &control,
        "workspace.project.register",
        json!({"registrationRequestId": "request-3", "kind": "openharmony",
               "root": root.join("first").to_str().unwrap()}),
    )
    .unwrap()["projectRef"]
        .clone();
    let symbol = |request: &str, timeout: &str| {
        json!({"registrationRequestId": request, "projectRef": project, "kind": "symbol",
               "templateRef": "openharmony.arkts-symbol@1", "timeoutSeconds": timeout,
               "relativeSourceMap": "entry/build/sourceMaps.map"})
    };
    let registered = call(
        &control,
        "workspace.preset.register",
        symbol("symbol", "600"),
    )
    .unwrap();
    assert_eq!(
        (
            &registered["generation"],
            &registered["configurationStatus"]
        ),
        (&json!("1"), &json!("runtimeRestartRequired"))
    );
    let preset = registered["presetRef"].clone();
    assert_eq!(
        call(
            &control,
            "workspace.preset.register",
            symbol("symbol", "600")
        )
        .unwrap(),
        registered,
        "a registration is replayed under its identity"
    );
    let before = document();
    let build = json!({"registrationRequestId": "build", "projectRef": project, "kind": "build",
        "templateRef": "openharmony.hvigor-build@1", "timeoutSeconds": "600",
        "toolchainRef": format!("toolchain:sha256:{}", "b".repeat(64)),
        "toolchainGeneration": "1", "module": "entry", "product": "default",
        "buildMode": "debug"});
    assert_eq!(
        refusal(call(&control, "workspace.preset.register", build.clone()).unwrap_err()),
        (
            "operationUnavailable".into(),
            "DevEco toolchain reference owner is unavailable".into(),
            Some(json!("workspacePresetOwner"))
        )
    );
    assert_eq!(document(), before, "a refused pinned preset writes nothing");
    let mutation = |request: &str, generation: &str| {
        json!({"mutationRequestId": request, "projectRef": project, "presetRef": preset,
               "expectedGeneration": generation})
    };
    let mut longer = symbol("unused", "900");
    longer
        .as_object_mut()
        .unwrap()
        .remove("registrationRequestId");
    for (key, value) in mutation("longer", "1").as_object().unwrap() {
        longer[key] = value.clone();
    }
    let updated = call(&control, "workspace.preset.update", longer).unwrap();
    assert_eq!(
        (&updated["generation"], &updated["timeoutSeconds"]),
        (&json!("2"), &json!(900))
    );
    for (method, params) in [
        (
            "workspace.preset.register",
            json!({"registrationRequestId": "partial"}),
        ),
        ("workspace.preset.update", mutation("partial", "2")),
        ("workspace.preset.remove", json!({"projectRef": project})),
    ] {
        assert_eq!(
            call(&control, method, params.clone()).unwrap_err().code,
            "invalidParams",
            "{method} {params}"
        );
    }
    drop(control);
    let unverified = compose(false);
    assert_eq!(
        refusal(
            call(
                &unverified,
                "workspace.preset.remove",
                mutation("remove", "2")
            )
            .unwrap_err()
        ),
        (
            "recordUnreadable".into(),
            "workspace Job references cannot be verified".into(),
            Some(json!("workspacePresetOwner"))
        ),
        "without the Job owner a removal cannot prove no active Job names the preset"
    );
    call(
        &unverified,
        "workspace.preset.register",
        symbol("second", "60"),
    )
    .expect("a registration consults no Job census");
    drop(unverified);
    let control = compose(true);
    let removed = call(&control, "workspace.preset.remove", mutation("remove", "2")).unwrap();
    assert_eq!(
        (&removed["generation"], &removed["configurationStatus"]),
        (&json!("3"), &json!("removed"))
    );
    let listed = call(
        &control,
        "workspace.preset.list",
        json!({"projectRef": project, "kind": "symbol"}),
    )
    .unwrap();
    assert_eq!(listed["presets"].as_array().unwrap().len(), 1);
    assert_ne!(listed["presets"][0]["presetRef"], preset);
    drop(control);
    fs::remove_dir_all(root).unwrap();
}

/// The isolated daemon's own composition: a preset's toolchain is pinned in
/// this owner's bootstrap registry, as Swift pins it in its DevEco registry.
/// With nothing registered there, the registry's own refusal reaches the
/// caller and nothing of the preset is written. A signing preset still wants
/// the credential owner, which this composition does not have.
#[test]
fn actual_host_pins_a_preset_toolchain_in_its_own_bootstrap_registry() {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "workspace-preset-pin-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    for name in ["owner", "jobs", "bootstrap", "project"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(name))
            .unwrap();
    }
    let control = Control::new(
        crate::host::Host::from_environment()
            .with_workspace_projects(
                WorkspaceProjectStore::open(&root.join("owner"))
                    .unwrap()
                    .with_dependency_pinning(
                        Some(crate::host::toolchain_pinning(&root.join("bootstrap")).unwrap()),
                        None,
                    ),
            )
            .with_jobs(arkdeck_hoststore::JobStore::open_owner(&root.join("jobs")).unwrap()),
    )
    .unwrap();
    let call = |method: &str, params: Value| {
        let request = Request::new(
            "workspace-4",
            method,
            Some(serde_json::from_value(params).unwrap()),
        );
        let frame = encode_frame(&request, arkdeck_contract::MAX_REQUEST_BYTES).unwrap();
        let bytes = control.handle_frame(frame.trim_ascii_end());
        decode_response(bytes.trim_ascii_end(), "workspace-4", method)
            .unwrap()
            .outcome
    };
    let project = call(
        "workspace.project.register",
        json!({"registrationRequestId": "request-4", "kind": "openharmony",
               "root": root.join("project").to_str().unwrap()}),
    )
    .unwrap()["projectRef"]
        .clone();
    let document = || fs::read(root.join("owner/projects.json")).unwrap();
    let before = document();
    let toolchain = format!("toolchain:sha256:{}", "b".repeat(64));
    let refused = call(
        "workspace.preset.register",
        json!({"registrationRequestId": "build", "projectRef": project, "kind": "build",
               "templateRef": "openharmony.hvigor-build@1", "timeoutSeconds": "600",
               "toolchainRef": toolchain, "toolchainGeneration": "1", "module": "entry",
               "product": "default", "buildMode": "debug"}),
    )
    .unwrap_err();
    assert_eq!(
        (
            refused.code.as_str(),
            refused.message.as_str(),
            refused.details.map(|details| details["phase"].clone())
        ),
        (
            "resourceNotFound",
            "toolchain reference does not exist",
            Some(json!("workspacePresetOwner"))
        ),
        "the DevEco owner's own refusal reaches the caller"
    );
    assert_eq!(document(), before, "a refused pin writes nothing");
    let signing = call(
        "workspace.preset.register",
        json!({"registrationRequestId": "signing", "projectRef": project, "kind": "signing",
               "templateRef": "openharmony.local-sign@1", "timeoutSeconds": "600",
               "toolchainRef": toolchain, "toolchainGeneration": "1",
               "credentialRef": format!("credential:sha256-{}", "c".repeat(64))}),
    )
    .unwrap_err();
    assert_eq!(
        (signing.code.as_str(), signing.message.as_str()),
        (
            "operationUnavailable",
            "signing credential reference owner is unavailable"
        )
    );
    assert_eq!(document(), before);
    // A preset that pins nothing is still served in full.
    let symbol = call(
        "workspace.preset.register",
        json!({"registrationRequestId": "symbol", "projectRef": project, "kind": "symbol",
               "templateRef": "openharmony.arkts-symbol@1", "timeoutSeconds": "60",
               "relativeSourceMap": "entry/a.map"}),
    )
    .unwrap();
    assert_eq!(symbol["configurationStatus"], "runtimeRestartRequired");
    drop(control);
    fs::remove_dir_all(root).unwrap();
}
