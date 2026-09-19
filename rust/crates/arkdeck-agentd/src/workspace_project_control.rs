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
