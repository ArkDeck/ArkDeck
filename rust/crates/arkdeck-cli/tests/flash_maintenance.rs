use arkdeck_cli::{flash_maintenance, parse};
use serde_json::json;
fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| (*s).into()).collect()
}
#[test]
fn maintenance_parameters_fail_before_any_runtime_connection() {
    let error = parse(&args(&["flash", "restore-boot-loop"])).unwrap_err();
    assert_eq!(error.exit_code(), 2);
    let parsed = parse(&args(&[
        "flash",
        "verify",
        "--request-file",
        "/nonexistent/maintenance.json",
        "--timeout",
        "11m",
    ]))
    .unwrap();
    assert_eq!(parsed.timeout_ms, Some(660_000));
    assert!(flash_maintenance::request(&parsed).is_err());
    assert!(
        parse(&args(&[
            "flash",
            "restore-boot-loop",
            "--request-file",
            "x",
            "--yes"
        ]))
        .is_err()
    );
}
#[test]
fn cli_distinguishes_partial_verification_and_stopped_recovery() {
    for code in [0, 9, 7] {
        let result = json!({"state":if code == 7 {"failed"} else {"succeeded"},"outcomeUnknown":false,
            "maintenanceResult":{"schema":"arkforge.flash-verification/v1","exit_code":code}});
        assert_eq!(flash_maintenance::exit_code("flash.verify", &result), code);
    }
    let unknown = json!({"state":"waitingForRecovery","outcomeUnknown":true,
        "maintenanceResult":{"schema":"arkforge.boot-loop-restoration/v1","exit_code":1}});
    assert_eq!(
        flash_maintenance::exit_code("flash.restore-boot-loop", &unknown),
        1
    );
    assert_eq!(flash_maintenance::exit_code("flash.verify", &unknown), 7);
    let forged = json!({"state":"failed","outcomeUnknown":false,
        "maintenanceResult":{"schema":"arkforge.boot-loop-restoration/v1","exit_code":0}});
    assert_eq!(
        flash_maintenance::exit_code("flash.restore-boot-loop", &forged),
        1
    );
    assert_eq!(arkdeck_cli::run_exit(&forged).map(|v| v.0), Some(1));
}
#[test]
fn process_parse_failure_is_exit_two_and_never_creates_a_record() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args([
            "flash",
            "restore-boot-loop",
            "--request-file",
            "/nonexistent/maintenance.json",
            "--output",
            "json",
        ])
        .env("ARKDECK_ENDPOINT", "/nonexistent/maintenance-runtime.sock")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["ok"], false);
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .contains("no request or record")
    );
}
