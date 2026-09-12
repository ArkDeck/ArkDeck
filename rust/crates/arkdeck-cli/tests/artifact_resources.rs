use arkdeck_cli::{
    CliError, artifact_bytes, parse, validate_artifact_metadata, validate_artifact_read,
};
use serde_json::{Value, json};
fn invocation(verb: &str, job: &str, artifact: &str, options: &[&str]) -> arkdeck_cli::Invocation {
    let mut args = vec!["artifact", verb, "--job", job, "--artifact", artifact];
    args.extend(options);
    parse(&args.into_iter().map(str::to_owned).collect::<Vec<_>>()).unwrap()
}
fn corpus(method: &str) -> Vec<Value> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"));
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|row| serde_json::from_str(row).unwrap())
        .collect()
}
#[test]
fn artifact_cli_keeps_the_published_argv_contract() {
    for method in ["artifact.inspect", "artifact.read"] {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../tests/fixtures/current-cli-argv/{method}.json"
        ));
        let rows: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        for row in rows["cases"].as_array().unwrap() {
            let args = row["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect::<Vec<_>>();
            let result = parse(&args);
            if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
            } else if row["expected"]["outcome"] == "failure" {
                assert_eq!(result.unwrap_err().code, row["expected"]["code"], "{row}");
            } else {
                assert_eq!(result.unwrap().command, method, "{row}");
            }
        }
    }
    let bounded = invocation(
        "read",
        "JOB-1",
        "ART-1",
        &[
            "--offset",
            "4",
            "--max-bytes",
            "8",
            "--timeout",
            "999ms",
            "--allow-sensitive",
            "--raw",
        ],
    );
    assert_eq!(bounded.timeout_ms, Some(999));
    assert!(bounded.raw);
    assert_eq!(bounded.params.unwrap(), json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"ART-1","offset":4,"maxBytes":8,"allowSensitive":true}).as_object().unwrap().clone());
    for options in [
        vec!["--offset", "-1"],
        vec!["--max-bytes", "0"],
        vec!["--max-bytes", "4194305"],
        vec!["--offset", "9007199254740992"],
        vec!["--timeout", "25h"],
        vec!["--import", "imp-00000000-0000-0000-0000-000000000000"],
    ] {
        let mut args = vec!["artifact", "read", "--job", "JOB-1", "--artifact", "ART-1"];
        args.extend(options);
        assert!(parse(&args.into_iter().map(str::to_owned).collect::<Vec<_>>()).is_err());
    }
    assert_eq!(
        invocation("inspect", "JOB-1", "ART-1", &[]).timeout_ms,
        Some(3_600_000)
    );
}
#[test]
fn actual_swift_metadata_is_accepted_and_mismatched_identity_is_refused() {
    let mut count = 0;
    for row in corpus("artifact.inspect") {
        if row["ok"] != true {
            continue;
        }
        count += 1;
        let params = row["params"].as_object().unwrap();
        validate_artifact_metadata(params, &row["result"]).unwrap();
        for (field, value) in [
            ("artifactId", json!("ART-another")),
            ("byteCount", json!(9007199254740992_u64)),
            ("artifactDigest", json!("bad")),
            ("lease", json!("lease-v1:wrong:ART-1")),
            ("privacy", json!("unrestricted")),
            ("extra", json!(true)),
            (
                "observationWindow",
                json!({"startUtc":"2026-09-12T00:00:01Z","endUtc":"2026-09-12T00:00:00Z"}),
            ),
        ] {
            let mut changed = row["result"].clone();
            changed[field] = value;
            assert_eq!(
                validate_artifact_metadata(params, &changed)
                    .unwrap_err()
                    .code,
                "recordUnreadable",
                "{field}"
            );
        }
        let mut changed = row["result"].clone();
        changed["owner"]["id"] = json!("JOB-another");
        assert!(validate_artifact_metadata(params, &changed).is_err());
    }
    assert!(count >= 6);
}
#[test]
fn actual_swift_ranges_require_selected_metadata_and_requested_bounds() {
    let inspected = corpus("artifact.inspect");
    let mut count = 0;
    for row in corpus("artifact.read") {
        if row["ok"] != true {
            continue;
        }
        let value = &row["result"];
        let Some(metadata) = inspected.iter().find(|entry| {
            entry["ok"] == true && entry["result"]["artifactId"] == value["artifactId"]
        }) else {
            continue;
        };
        let offset = value["offset"].to_string();
        let owner_flag = if row["params"]["owner"]["kind"] == "import" {
            "--import"
        } else {
            "--job"
        };
        let inv = parse(
            &[
                "artifact",
                "read",
                owner_flag,
                row["params"]["owner"]["id"].as_str().unwrap(),
                "--artifact",
                value["artifactId"].as_str().unwrap(),
                "--offset",
                &offset,
                "--max-bytes",
                "4194304",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>(),
        )
        .unwrap();
        validate_artifact_read(&inv, &metadata["result"], value).unwrap();
        count += 1;
        for (key, replacement) in [
            ("artifactId", json!("ART-another")),
            ("artifactDigest", json!("a".repeat(64))),
            ("nextOffset", json!(9007199254740991_u64)),
            ("offset", json!(9007199254740991_u64)),
            ("base64", json!("invalid")),
            ("eof", json!(!value["eof"].as_bool().unwrap())),
        ] {
            let mut malformed = value.clone();
            malformed[key] = replacement;
            assert!(
                validate_artifact_read(&inv, &metadata["result"], &malformed).is_err(),
                "{key}"
            );
        }
    }
    assert!(count >= 2);
}
#[test]
fn base64_rejects_noncanonical_padding_and_unbounded_allocations() {
    for (encoded, expected) in [
        ("", b"".as_slice()),
        ("Zg==", b"f"),
        ("Zm8=", b"fo"),
        ("Zm9v", b"foo"),
        ("////", &[255, 255, 255]),
    ] {
        assert_eq!(
            artifact_bytes(&json!({"base64":encoded,"byteCount":expected.len()})).unwrap(),
            expected
        );
    }
    for (encoded, count) in [
        ("Zh==", 1),
        ("Zm9=", 2),
        ("Zg==Zg==", 2),
        ("Zg=", 1),
        ("Zg==\n", 1),
        ("Zg==", 4_194_305),
        ("====", 1),
    ] {
        assert!(artifact_bytes(&json!({"base64":encoded,"byteCount":count})).is_err());
    }
}
#[test]
fn artifact_refusals_keep_owner_evidence_and_current_exit_codes() {
    use arkdeck_client::ClientError;
    use arkdeck_contract::WireError;
    for (code, exit) in [
        ("artifactIntegrityFailed", 2),
        ("sensitiveAccessDenied", 77),
        ("resourceNotFound", 65),
        ("operationUnavailable", 69),
    ] {
        let wire = WireError {
            code: code.into(),
            message: "fixture".into(),
            details: Some(
                json!({"phase":"artifactOwner","newDispatchCount":0})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        };
        let result = CliError::from_client(ClientError::Remote(wire.clone()), "artifact.read");
        assert_eq!(result.code, code);
        assert_eq!(result.exit_code(), exit);
        let mut unproven = wire;
        unproven.details = None;
        assert_eq!(
            CliError::from_client(ClientError::Remote(unproven), "artifact.read").code,
            "internalError"
        );
    }
}

#[cfg(target_os = "macos")]
mod endpoint {
    use super::*;
    use arkdeck_contract::{
        CATALOG_DIGEST, CONTRACT_IDENTITY, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS,
        PROTOCOL_VERSION, encode_frame,
    };
    use arkdeck_platform::{LocalEndpoint, LocalListener, read_frame};
    use std::io::{BufReader, Read, Write};
    use std::os::unix::fs::DirBuilderExt;

    fn run(argv: &[&str], replies: Vec<Value>) -> (std::process::Output, Vec<Value>) {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::path::PathBuf::from(format!("/private/tmp/artifact-cli-{nonce:x}"));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let path = root.join("socket");
        let mut listener = LocalListener::bind(&LocalEndpoint::new(&path)).unwrap();
        let server = std::thread::spawn(move || {
            let mut stream = BufReader::new(listener.accept().unwrap());
            stream
                .get_ref()
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let health = json!({"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS});
            let mut requests = Vec::new();
            for result in std::iter::once(health).chain(replies) {
                let bytes = match read_frame(&mut stream, MAX_REQUEST_BYTES) {
                    Ok(bytes) => bytes,
                    Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                    Err(error) => panic!("test transport: {error}"),
                };
                let request: Value = serde_json::from_slice(&bytes).unwrap();
                let reply = json!({"id":request["id"],"ok":true,"result":result});
                requests.push(request);
                stream
                    .get_mut()
                    .write_all(&encode_frame(&reply, MAX_RESPONSE_BYTES).unwrap())
                    .unwrap();
            }
            let mut extra = Vec::new();
            stream.read_to_end(&mut extra).unwrap();
            assert!(
                extra.is_empty(),
                "Artifact CLI replayed or followed another resource"
            );
            requests
        });
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(argv)
            .args(["--output", "json", "--socket"])
            .arg(&path)
            .output()
            .unwrap();
        let requests = server.join().unwrap();
        std::fs::remove_dir(root).unwrap();
        (output, requests)
    }

    #[test]
    fn executable_inspects_then_reads_once_and_raw_is_the_validated_range() {
        let metadata = corpus("artifact.inspect")
            .into_iter()
            .find(|r| r["ok"] == true && r["params"]["owner"]["id"] == "job-window-wire")
            .unwrap()["result"]
            .clone();
        let read = corpus("artifact.read")
            .into_iter()
            .find(|r| r["ok"] == true && r["result"]["artifactId"] == metadata["artifactId"])
            .unwrap()["result"]
            .clone();
        let offset = read["offset"].to_string();
        let args = [
            "artifact",
            "read",
            "--job",
            "job-window-wire",
            "--artifact",
            metadata["artifactId"].as_str().unwrap(),
            "--offset",
            &offset,
            "--max-bytes",
            "4194304",
        ];
        let (output, requests) = run(&args, vec![metadata.clone(), read.clone()]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["result"],
            read
        );
        assert_eq!(
            requests
                .iter()
                .map(|r| r["method"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["health", "artifact.inspect", "artifact.read"]
        );
        assert_eq!(
            requests[1]["params"],
            json!({"owner":{"kind":"job","id":"job-window-wire"},"artifactId":metadata["artifactId"]})
        );
        let raw_args = [&args[..], &["--raw"]].concat();
        let (output, requests) = run(&raw_args, vec![metadata.clone(), read.clone()]);
        assert!(output.status.success());
        assert_eq!(output.stdout, artifact_bytes(&read).unwrap());
        assert_eq!(requests.len(), 3);
        let mut wrong = metadata.clone();
        wrong["owner"]["id"] = json!("job-other");
        let (output, requests) = run(&raw_args, vec![wrong, read.clone()]);
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(
            requests.len(),
            2,
            "metadata mismatch must refuse before content read"
        );
        let mut wrong = read;
        wrong["artifactDigest"] = json!("f".repeat(64));
        let (output, requests) = run(&raw_args, vec![metadata.clone(), wrong]);
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(requests.len(), 3);
        let error: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(error["error"]["code"], "recordUnreadable");
        assert!(error.get("result").is_none());
    }
}
