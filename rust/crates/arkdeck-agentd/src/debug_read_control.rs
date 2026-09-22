//! Production Host/Control Debug reads against an inert local test executable.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
use arkdeck_control::Control;
use arkdeck_hoststore::TargetStore;
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "operation-availability-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["jobs", "artifacts", "targets"] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(name))
                .unwrap();
        }
        // If anything dispatches these tools, the sentinel exposes it. The
        // launcher never needs to execute a tool to answer availability.
        for name in ["analyzer", "hdc"] {
            fs::write(
                root.join(name),
                format!(
                    "#!/bin/sh\ntouch '{}'\nexit 93\n",
                    root.join("DISPATCHED").display()
                ),
            )
            .unwrap();
            fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self(root)
    }
    fn adopt(&self) -> String {
        use arkdeck_hoststore::{ObservationReference, Sources, TargetObservations};
        use arkdeck_provider_hdc::{
            DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation,
        };
        // Seed the durable binding through the real adoption owner, using an
        // in-memory source explicitly confined to this synthetic host test.
        struct AdoptionFixture;
        impl HdcDispatch for AdoptionFixture {
            fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
                let argv: Vec<_> = plan.arguments.iter().map(String::as_str).collect();
                let stdout = match argv.as_slice() {
                    ["-v"] => "Ver: 3.2.0f\n",
                    ["list", "targets", "-v"] => "fixture-device\t\tUSB\tConnected\tlocalhost\n",
                    _ => {
                        return Err(DispatchFailure::Refused(
                            "unexpected adoption action".into(),
                        ));
                    }
                };
                Ok(Receipt {
                    exit_status: 0,
                    stdout: stdout.as_bytes().to_vec(),
                    stderr: Vec::new(),
                    truncated: false,
                    duration: std::time::Duration::ZERO,
                })
            }
        }
        let targets = TargetStore::open(&self.0.join("targets")).unwrap();
        let observer = TargetObservations::default();
        let usb = || {
            Ok(vec![UsbRelation {
                serial: "fixture-device".into(),
                location: "1".into(),
                attachment_id: 1,
                vendor_id: 0x2207,
                product_id: 0x5000,
            }])
        };
        let now = || "2026-09-19T00:00:00Z".to_owned();
        let sources = Sources {
            dispatch: &AdoptionFixture,
            relations: &usb,
            targets: &targets,
            now: &now,
        };
        let snapshot = observer.snapshot(&sources, None).unwrap();
        observer
            .adopt(
                &sources,
                &ObservationReference {
                    candidate: snapshot.observations[0].candidate.connect_key.clone(),
                    observation_id: snapshot.observations[0].observation_id.clone(),
                    generation: snapshot.generation,
                },
            )
            .unwrap()
            .target_id
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn call(control: &Control<crate::host::Host>, method: &str, params: Value) -> Value {
    serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion":PROTOCOL_VERSION, "contractIdentity":CONTRACT_IDENTITY,
                "id":"debug", "method":method, "params":params
            }))
            .unwrap(),
        ),
    )
    .unwrap()
}
#[test]
fn debug_reads_execute_only_closed_commands_on_an_adopted_route() {
    let fixture = Fixture::new();
    let target = fixture.adopt();
    let script = r#"#!/bin/sh
root='FIXTURE_ROOT'
printf '%s\n' "$*" >> "$root/calls"
case "$*" in
'-t fixture-device shell bm dump -a') printf 'com.example.z\ncom.example.a\n';;
'-t fixture-device fport ls') printf 'tcp:9000 tcp:8000\n';;
'-t fixture-device rport ls') printf '[Fail] offline\n' >&2;;
'-t fixture-device shell uptime') printf 'up 10 minutes\n'; exit 7;;
'-t fixture-device shell param get persist.ace.debug.enabled') printf '\377';;
'-t fixture-device shell hidumper -s WindowManagerService -a -a') printf '{"windows":[]}\n';;
*) exit 93;;
esac
"#;
    let script = script.replace("FIXTURE_ROOT", fixture.0.to_str().unwrap());
    fs::write(fixture.0.join("hdc"), &script).unwrap();
    let digest = sha256_hex(script.as_bytes());
    let control = Control::new(
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&fixture.0.join("targets")).unwrap())
            .with_development_hdc(Some(ProcessDispatch::new(
                VerifiedTool::open(fixture.0.join("hdc"), &digest).unwrap(),
                None,
            ))),
    )
    .unwrap();
    let probe = call(&control, "debug.probe", json!({"targetId":target}));
    assert_eq!(
        probe["result"]["packages"],
        json!(["com.example.a", "com.example.z"]),
        "{probe}"
    );
    assert_eq!(
        probe["result"]["warnings"],
        json!(["reverseRulesUnavailable"])
    );
    assert_eq!(
        probe["result"]["portRules"],
        json!([{"direction":"forward","localPort":9000,"remotePort":8000}])
    );
    let result = call(
        &control,
        "debug.template.run",
        json!({"targetId":target, "templateId":"device.uptime"}),
    );
    assert_eq!(result["result"]["exitCode"], 7, "{result}");
    assert_eq!(result["result"]["stdout"], "up 10 minutes\n");
    assert_eq!(
        result["result"]["arguments"],
        json!(["-t", "<redacted-connect-key>", "shell", "uptime"])
    );
    assert_eq!(
        result["result"]["loweringSha256"],
        sha256_hex(format!("{digest}\0-t\0fixture-device\0shell\0uptime").as_bytes())
    );
    assert_eq!(
        call(
            &control,
            "debug.template.run",
            json!({"targetId":target,"templateId":"device.debugParameterRead"})
        )["error"]["code"],
        "rejected"
    );
    let before = fs::read(fixture.0.join("calls")).unwrap();
    for (method, params, code) in [
        (
            "debug.probe",
            json!({"targetId":target, "rawCommand":"shell uptime"}),
            "invalidParams",
        ),
        ("debug.probe", json!({"targetId":""}), "invalidParams"),
        (
            "debug.template.run",
            json!({"targetId":target,"templateId":"shell uptime"}),
            "invalidParams",
        ),
        ("debug.probe", json!({"targetId":"unadopted"}), "rejected"),
    ] {
        assert_eq!(call(&control, method, params)["error"]["code"], code);
    }
    assert_eq!(fs::read(fixture.0.join("calls")).unwrap(), before);
}

#[test]
fn debug_reads_replay_the_existing_swift_oracle_through_production_host() {
    // The checked-in fake names this fixed root; share its lock with all other
    // oracle replays, including Swift. This never names an installed Runtime.
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open("/private/tmp/arkdeck-hdc-oracle.lock")
        .unwrap();
    lock.lock().unwrap();
    let root = PathBuf::from("/private/tmp/arkdeck-hdc-oracle");
    let _ = fs::remove_dir_all(&root);
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root.join("targets-state"))
        .unwrap();
    let fixtures =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-probe");
    for file in ["hdc", "hdc-answers.sh", "targets-state/targets.json"] {
        fs::copy(fixtures.join(file), root.join(file)).unwrap();
        fs::set_permissions(
            root.join(file),
            fs::Permissions::from_mode(if file == "hdc" { 0o700 } else { 0o600 }),
        )
        .unwrap();
    }
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let control = Control::new(
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&root.join("targets-state")).unwrap())
            .with_development_hdc(Some(ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            ))),
    )
    .unwrap();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures.join("cases.json")).unwrap()).unwrap();
    let mut all_calls = String::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        fs::write(root.join("hdc-calls.log"), "").unwrap();
        let reply = call(
            &control,
            exchange["method"].as_str().unwrap(),
            exchange["params"].clone(),
        );
        let mut answer = if reply["ok"] == true {
            json!({"ok":true,"result":reply["result"]})
        } else {
            json!({"ok":false,"error":reply["error"]})
        };
        if answer["result"].get("durationMilliseconds").is_some() {
            assert!(answer["result"]["durationMilliseconds"].as_u64().is_some());
            answer["result"]["durationMilliseconds"] = json!(12); // Oracle fixes the host clock.
        }
        assert_eq!(answer, exchange["answer"], "{}", exchange["name"]);
        let calls = fs::read_to_string(root.join("hdc-calls.log")).unwrap();
        let mut calls: Vec<_> = calls.lines().collect();
        calls.sort_unstable();
        for line in calls {
            all_calls.push_str(line);
            all_calls.push('\n');
        }
    }
    assert_eq!(
        all_calls,
        fs::read_to_string(fixtures.join("hdc-calls.log")).unwrap()
    );
    fs::remove_dir_all(root).unwrap();
}
