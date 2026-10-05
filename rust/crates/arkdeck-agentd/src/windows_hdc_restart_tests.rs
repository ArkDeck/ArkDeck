//! A confirmed restart of the registered Windows HDC (CHG-2026-074
//! TASK-XPA-005 over CHG-2026-078), end to end through Control over the
//! Windows composition (`windows_lifecycle::start` and `Authority::compose`)
//! with the real DevEco Studio 26.0.0.43 `hdc.exe` (`3.2.0g`) as its managed
//! server: the impact preview, the restart's impact approval, the foreground
//! console's challenge and its answer, the restart through the HDC lifecycle
//! driver, the proved replacement, and the daemon's stop of both.
//!
//! The foreground-console origin is the one fact this test supplies, as the
//! macOS in-process tests do (`handle_frame_with_console`); the Windows pipe
//! derives it per frame (#2480, maintainer ruling 2026-10-04). The console
//! challenge of an unsigned tool conforms once `human-action.resume` admits
//! its signature (#2488). No board is needed.
//!
//! It needs `ARKDECK_LIVE_WINDOWS_HDC`, the registered `hdc.exe`; without it
//! it says so and checks nothing. Nothing else may listen on
//! `127.0.0.1:8710`; only the servers this composition starts are stopped.
use serde_json::{Value, json};
use std::ffi::OsString;
use std::time::Duration;

const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";

fn endpoint_free() -> bool {
    std::net::TcpStream::connect_timeout(
        &"127.0.0.1:8710".parse().unwrap(),
        Duration::from_millis(300),
    )
    .is_err()
}

fn frame(
    control: &arkdeck_control::Control<crate::host::Host>,
    method: &str,
    params: Value,
    console: bool,
) -> Value {
    let request = json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": method,
        "method": method,
        "params": params,
    });
    let bytes = serde_json::to_vec(&request).unwrap();
    serde_json::from_slice(&control.handle_frame_with_console(&bytes, console)).unwrap()
}

struct Root(std::path::PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_confirmed_restart_of_the_registered_windows_hdc_runs_end_to_end() {
    let Some(hdc) = std::env::var_os("ARKDECK_LIVE_WINDOWS_HDC").filter(|v| !v.is_empty()) else {
        eprintln!(
            "SKIPPED: ARKDECK_LIVE_WINDOWS_HDC does not name the registered hdc.exe (DevEco Studio \
             26.0.0.43's toolchains hdc.exe); nothing was checked"
        );
        return;
    };
    assert_eq!(
        arkdeck_contract::sha256_hex(&std::fs::read(&hdc).unwrap()),
        C2_SHA256,
        "not the registered hdc.exe"
    );
    assert!(
        endpoint_free(),
        "something already listens on 127.0.0.1:8710; this test never stops a server it did \
         not start"
    );
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let path = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("ad-winhdcrestart-{nonce:016x}"));
    let path = std::path::PathBuf::from(
        path.to_str()
            .unwrap()
            .strip_prefix(r"\\?\")
            .unwrap_or(path.to_str().unwrap()),
    );
    std::fs::create_dir(&path).unwrap();
    let root = Root(path);
    let environment = [
        ("ARKDECK_DEVELOPMENT_HDC_PATH", hdc.clone()),
        ("ARKDECK_DEVELOPMENT_HDC_SERVER", OsString::from("managed")),
    ];
    let variable = |name: &str| {
        environment
            .iter()
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value.clone())
    };
    let serving = match crate::windows_lifecycle::start(
        Some(root.0.as_os_str()),
        None,
        &crate::host::utc_now(),
        &variable,
    )
    .unwrap()
    {
        crate::windows_lifecycle::Start::Serve(serving) => serving,
        crate::windows_lifecycle::Start::AlreadyRunning(_) => panic!("a fresh root is owned"),
    };
    let crate::windows_lifecycle::Serving {
        stop: _stop,
        listener: _listener,
        authority,
    } = serving;
    let authority = authority.unwrap();
    let (host, _lane, managed) = authority
        .compose(crate::host::Host::from_environment())
        .unwrap();
    let managed = managed.expect("the registered HDC is composed as the managed server");
    let control = arkdeck_control::Control::new(host).unwrap();

    let status = frame(&control, "runtime.hdc.status", json!({}), false);
    let before = status["result"].clone();
    assert_eq!(before["ownership"], "arkDeckManaged", "{status}");
    let preview = frame(
        &control,
        "runtime.hdc.impact-preview",
        json!({
            "action": "restart",
            "actionRequestId": "live-restart",
            "expectedServerGeneration": before["generation"].clone(),
            "serverEndpointRef": before["serverEndpointRef"].clone(),
        }),
        false,
    );
    let action = preview["result"].clone();
    assert_eq!(action["blockerReasonCode"], Value::Null, "{preview}");
    assert_eq!(action["preview"]["serverHealth"], "healthy", "{preview}");
    assert_eq!(
        action["preview"]["serverOwnership"], "arkDeckManaged",
        "{preview}"
    );
    let restart = frame(
        &control,
        "runtime.hdc.restart",
        json!({
            "controlAction": action["controlActionId"].clone(),
            "previewId": action["preview"]["previewId"].clone(),
            "previewDigest": action["preview"]["previewDigest"].clone(),
        }),
        false,
    );
    let har = restart["result"]["humanAction"].clone();
    assert_eq!(har["category"], "impactApproval", "{restart}");
    let reference = json!({
        "humanAction": har["actionId"].clone(),
        "resumeReference": har["resumeReference"].clone(),
    });
    // Without the console, the approval comes back unchanged.
    let unchanged = frame(&control, "human-action.resume", reference.clone(), false);
    assert_eq!(unchanged["result"]["status"], "waiting", "{unchanged}");
    let challenge = frame(&control, "human-action.resume", reference.clone(), true);
    assert_eq!(
        challenge["result"]["schemaVersion"], "arkdeck.impact-approval-challenge/1",
        "{challenge}"
    );
    let mut answer = reference.clone();
    answer["challengeResponse"] = challenge["result"]["challenge"].clone();
    let restarted = frame(&control, "human-action.resume", answer, true);
    eprintln!("restarted: {restarted}");
    assert_eq!(restarted["ok"], true, "{restarted}");
    assert_eq!(restarted["result"]["state"], "succeeded", "{restarted}");
    assert_eq!(restarted["result"]["dispatchCount"], 1, "{restarted}");

    let after = frame(&control, "runtime.hdc.status", json!({}), false);
    eprintln!("status after: {after}");
    let generation = |value: &Value| {
        value["generation"]
            .as_str()
            .and_then(|text| text.parse::<u64>().ok())
    };
    let shown = frame(
        &control,
        "control-action.show",
        json!({"controlAction": action["controlActionId"].clone()}),
        false,
    );
    eprintln!("control action: {shown}");
    assert!(!endpoint_free(), "the replacement serves the endpoint");
    assert!(
        generation(&after["result"]) > generation(&before),
        "a strictly newer server: {after}"
    );
    assert_eq!(after["result"]["ownership"], "arkDeckManaged", "{after}");

    // The daemon's stop ends the original child and the proved replacement.
    let stopped = managed.stop().expect("stopped once");
    eprintln!("stop: {:?}", stopped.report(true));
    assert_eq!(
        stopped.replacement,
        crate::managed_hdc::ReplacementStop::Ended,
        "{stopped:?}"
    );
    drop(managed);
    drop(control);
    authority.release();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !endpoint_free() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(endpoint_free(), "no server this test started is left");
}
