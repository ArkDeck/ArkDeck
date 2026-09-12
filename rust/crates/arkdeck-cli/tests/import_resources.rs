use arkdeck_cli::{CliError, parse};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
#[cfg(target_os = "macos")]
use arkdeck_contract::{ImportIntent, sha256_hex};
use serde_json::{Value, json};
fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn imports_keep_current_swift_leaf_argv_and_inspect_uses_reference_inspection() {
    for kind in [
        "hap",
        "native-library",
        "workspace-patch",
        "flash-bundle",
        "abort",
        "inspect",
    ] {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../tests/fixtures/current-cli-argv/artifact.import.{kind}.json"
        ));
        let fixture: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        for row in fixture["cases"].as_array().unwrap() {
            let args = row["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect::<Vec<_>>();
            let actual = parse(&args);
            if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(actual.unwrap_err().code, "unsupportedOnPlatform");
            } else if row["expected"]["outcome"] == "failure" {
                assert_eq!(actual.unwrap_err().code, row["expected"]["code"], "{row}");
            } else {
                assert_eq!(
                    actual.unwrap().command,
                    format!("artifact.import.{kind}"),
                    "{row}"
                );
            }
        }
    }
    assert_eq!(
        parse(&argv(&[
            "artifact",
            "import",
            "inspect",
            "--import-request-id",
            "stable"
        ]))
        .unwrap()
        .method,
        "artifact.import.inspection"
    );
    for args in [
        vec!["artifact", "import", "begin"],
        vec!["artifact", "import", "append"],
        vec!["artifact", "import", "commit"],
    ] {
        assert_eq!(parse(&argv(&args)).unwrap_err().code, "invalidCommand");
    }
    let abort = parse(&argv(&[
        "artifact",
        "import",
        "abort",
        "--import-request-id",
        "stable",
        "--expected-generation",
        "1",
        "--timeout",
        "9s",
    ]))
    .unwrap();
    assert_eq!(
        abort.params.unwrap(),
        json!({"importRequestId":"stable","generation":"1"})
            .as_object()
            .unwrap()
            .clone()
    );
    assert_eq!(abort.timeout_ms, Some(9000));
}
#[test]
fn import_owner_errors_remain_distinct_and_lost_mutation_responses_are_unknown() {
    for (code, exit) in [
        ("invalidInput", 65),
        ("idempotencyConflict", 65),
        ("resourceConflict", 65),
        ("resourceNotFound", 65),
        ("artifactIntegrityFailed", 2),
        ("recordUnreadable", 2),
        ("quotaExceeded", 69),
        ("operationUnavailable", 69),
    ] {
        let actual = CliError::from_client(
            ClientError::Remote(WireError {
                code: code.into(),
                message: "fixture".into(),
                details: Some(
                    json!({"phase":"importOwner","newDispatchCount":0})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            }),
            "artifact.import.append",
        );
        assert_eq!(actual.code, code);
        assert_eq!(actual.exit_code(), exit);
    }
    for method in [
        "artifact.import.begin",
        "artifact.import.append",
        "artifact.import.abort",
        "artifact.import.commit",
    ] {
        assert_eq!(
            CliError::from_client(ClientError::ConnectionUnusable, method).code,
            "outcomeUnknown"
        );
        assert_eq!(
            CliError::from_client(
                ClientError::Contract(arkdeck_contract::ContractError::Malformed),
                method
            )
            .code,
            "outcomeUnknown"
        );
    }
}

#[cfg(target_os = "macos")]
mod upload {
    use super::*;
    use arkdeck_cli::execute_import;
    use std::os::unix::fs::DirBuilderExt;
    use std::{fs, path::PathBuf};
    struct Source {
        root: PathBuf,
        path: PathBuf,
        bytes: Vec<u8>,
    }
    impl Source {
        fn new(name: &str, bytes: Vec<u8>) -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "cli-import-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            let path = root.join(name);
            fs::write(&path, &bytes).unwrap();
            Self { root, path, bytes }
        }
        fn invocation(&self, kind: &str) -> arkdeck_cli::Invocation {
            parse(&argv(&[
                "artifact",
                "import",
                kind,
                "--import-request-id",
                "request",
                "--target",
                "TGT-fixture",
                "--file",
                self.path.to_str().unwrap(),
            ]))
            .unwrap()
        }
        fn intent(&self) -> ImportIntent {
            ImportIntent {
                request_id: "request".into(),
                kind: "hap".into(),
                target_id: "TGT-fixture".into(),
                binding_revision: 7,
                device_profile: None,
                name: "fixture.hap".into(),
                byte_count: self.bytes.len() as u64,
                sha256: sha256_hex(&self.bytes),
            }
        }
    }
    impl Drop for Source {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.root).unwrap();
        }
    }
    fn resource(intent: &ImportIntent, offset: u64) -> Value {
        json!({"schemaVersion":"arkdeck.import/1","importId":"imp-00000000-0000-4000-8000-000000000001","importRequestId":intent.request_id,"metadata":intent.projection(),"metadataFingerprint":intent.fingerprint().unwrap(),"generation":"1","state":"inProgress","nextOffset":offset.to_string(),"maximumChunkBytes":"2097152","createdAtUtc":"2026-09-12T00:00:00Z","updatedAtUtc":"2026-09-12T00:00:00Z","receipt":null})
    }
    #[test]
    fn lost_begin_and_append_replies_rediscover_only_the_exact_committed_prefix() {
        let source = Source::new("fixture.hap", vec![b'a'; 2 * 1024 * 1024 + 10]);
        let intent = source.intent();
        let mut current = None;
        let mut inspect = 0;
        let mut begun = 0;
        let mut appended = Vec::new();
        let error=execute_import(&source.invocation("hap"),|method,params,remaining| {
            assert!((1..=3_600_000).contains(&remaining));
            match method {
                "artifact.import.inspect" => { inspect+=1; assert_eq!(params["importRequestId"],"request");current.clone().ok_or_else(||CliError::new("resourceNotFound","fixture")) }
                "target.show" => Ok(json!({"schemaVersion":"arkdeck.target/1","targetId":"TGT-fixture","bindingRevision":7})),
                "artifact.import.begin" => {begun+=1; assert_eq!(params,intent.projection().as_object().unwrap().clone()); current=Some(resource(&intent,0));Err(CliError::new("outcomeUnknown","lost begin"))},
                "artifact.import.append" => {
                    let offset=arkdeck_contract::import_decimal(&params["offset"]).unwrap();let count=arkdeck_contract::import_decimal(&params["byteCount"]).unwrap();
                    let bytes=arkdeck_contract::decode_import_chunk(params["base64"].as_str().unwrap(),count).unwrap();
                    assert_eq!(bytes,&source.bytes[offset as usize..(offset+count) as usize]);assert_eq!(params["sha256"],sha256_hex(&bytes));
                    appended.push(offset);current=Some(resource(&intent,offset+count));
                    if appended.len()==1 {Err(CliError::new("outcomeUnknown","lost append"))} else {Ok(current.clone().unwrap())}
                }
                "artifact.import.commit" => Err(CliError::new("operationUnavailable","publication owner is absent")),
                _ => panic!("unexpected method {method}"),
            }
        }).unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(error.details["importRequestId"], "request");
        assert_eq!(begun, 1);
        assert_eq!(inspect, 3);
        assert_eq!(appended, vec![0, 2 * 1024 * 1024]);
    }
    #[test]
    fn corrupted_recovery_changed_source_and_other_owner_never_continue_upload() {
        for failure in ["backward", "owner", "source", "sourceMetadata", "target"] {
            let source = Source::new("fixture.hap", b"abcdefgh".to_vec());
            let intent = source.intent();
            let mut reads = 0;
            let mut appends = 0;
            let error = execute_import(&source.invocation("hap"), |method, _, _| {
                if method == "artifact.import.inspect" {
                    reads += 1;
                    let mut value = resource(&intent, 4);
                    if failure == "sourceMetadata" {
                        let mut other = intent.clone();
                        other.sha256 = "f".repeat(64);
                        value = resource(&other, 4);
                    }
                    if reads == 2 {
                        if failure == "backward" {
                            value["nextOffset"] = json!("0");
                        }
                        if failure == "owner" {
                            value["importId"] = json!("imp-00000000-0000-4000-8000-000000000002");
                        }
                    }
                    if failure == "target" {
                        let mut other = intent.clone();
                        other.target_id = "TGT-another".into();
                        value = resource(&other, 4);
                    }
                    if failure == "source" {
                        fs::write(&source.path, b"changed!").unwrap();
                    }
                    Ok(value)
                } else if method == "artifact.import.append" {
                    appends += 1;
                    Err(CliError::new("outcomeUnknown", "lost"))
                } else {
                    panic!("unexpected {method}")
                }
            })
            .unwrap_err();
            assert_eq!(
                error.code,
                if matches!(failure, "source" | "sourceMetadata") {
                    "artifactIntegrityFailed"
                } else if failure == "target" {
                    "idempotencyConflict"
                } else {
                    "recordUnreadable"
                }
            );
            assert_eq!(
                appends,
                if matches!(failure, "source" | "sourceMetadata" | "target") {
                    0
                } else {
                    1
                }
            );
        }
    }
    #[test]
    fn unconfirmed_append_recovery_is_bounded_and_does_not_create_new_identity() {
        let source = Source::new("fixture.hap", b"abcdefgh".to_vec());
        let intent = source.intent();
        let mut appends = 0;
        let mut inspect = 0;
        let error = execute_import(&source.invocation("hap"), |method, _, _| match method {
            "artifact.import.inspect" => {
                inspect += 1;
                Ok(resource(&intent, 0))
            }
            "artifact.import.append" => {
                appends += 1;
                Err(CliError::new("outcomeUnknown", "lost"))
            }
            _ => panic!("unexpected {method}"),
        })
        .unwrap_err();
        assert_eq!(error.code, "outcomeUnknown");
        assert_eq!(appends, 3);
        assert_eq!(inspect, 3);
    }
    #[test]
    fn unknown_commit_is_inspected_once_and_never_replayed() {
        for state in ["inProgress", "committing"] {
            let source = Source::new("fixture.hap", b"abcdefgh".to_vec());
            let intent = source.intent();
            let mut methods = Vec::new();
            let error = execute_import(&source.invocation("hap"), |method, params, _| {
                methods.push(method.to_owned());
                match method {
                    "artifact.import.inspect" => {
                        assert_eq!(params["importRequestId"], "request");
                        let mut value = resource(&intent, 8);
                        value["state"] = json!(state);
                        Ok(value)
                    }
                    "artifact.import.commit" => {
                        assert_eq!(
                            params["importId"],
                            "imp-00000000-0000-4000-8000-000000000001"
                        );
                        Err(CliError::new(
                            "outcomeUnknown",
                            "publication reply was lost",
                        ))
                    }
                    _ => panic!("unexpected mutation {method}"),
                }
            })
            .unwrap_err();
            assert_eq!(error.code, "outcomeUnknown");
            assert_eq!(
                methods,
                vec![
                    "artifact.import.inspect",
                    "artifact.import.commit",
                    "artifact.import.inspect"
                ]
            );
        }
    }
    #[test]
    fn missing_runtime_target_owner_does_not_begin_and_native_name_is_canonicalized() {
        let source = Source::new(
            "ART-0123456789abcdef0123456789abcdef-libfixture.so",
            vec![0; 64],
        );
        let mut methods = Vec::new();
        let error=execute_import(&source.invocation("native-library"),|method,params,_|{
            methods.push(method.to_owned());
            match method {
                "artifact.import.inspect"=>Err(CliError::new("resourceNotFound","absent")),
                "target.show"=>Ok(json!({"schemaVersion":"arkdeck.target/1","targetId":"TGT-fixture","bindingRevision":7})),
                "artifact.import.begin"=>{assert_eq!(params["name"],"libfixture.so");Err(CliError::new("operationUnavailable","no trusted Target resolver"))},
                _=>panic!("unexpected {method}"),
            }
        }).unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(
            methods,
            vec![
                "artifact.import.inspect",
                "target.show",
                "artifact.import.begin"
            ]
        );
        methods.clear();
        let error = execute_import(&source.invocation("native-library"), |method, _, _| {
            methods.push(method.to_owned());
            Err(CliError::new(
                if method == "artifact.import.inspect" {
                    "resourceNotFound"
                } else {
                    "operationUnavailable"
                },
                "missing Target",
            ))
        })
        .unwrap_err();
        assert_eq!(error.code, "operationUnavailable");
        assert_eq!(methods, vec!["artifact.import.inspect", "target.show"]);
    }
    #[test]
    fn abort_and_inspection_validate_exact_requested_owner() {
        let source = Source::new("fixture.hap", b"abcdefgh".to_vec());
        let intent = source.intent();
        let invocation = parse(&argv(&[
            "artifact",
            "import",
            "abort",
            "--import-request-id",
            "request",
            "--expected-generation",
            "1",
        ]))
        .unwrap();
        let mut aborted = resource(&intent, 4);
        aborted["state"] = json!("aborted");
        aborted["generation"] = json!("2");
        assert_eq!(
            execute_import(&invocation, |method, params, _| {
                assert_eq!(method, "artifact.import.abort");
                assert_eq!(params["generation"], "1");
                Ok(aborted.clone())
            })
            .unwrap(),
            aborted
        );
        let invocation = parse(&argv(&[
            "artifact",
            "import",
            "inspect",
            "--import-request-id",
            "request",
        ]))
        .unwrap();
        let inspection = json!({"schemaVersion":"arkdeck.import-inspection/1","import":aborted,"references":{"state":"clear","activeJobIds":[],"outcomeUnknownJobIds":[],"activeMaterializationCount":"0"}});
        assert_eq!(
            execute_import(&invocation, |method, _, _| {
                assert_eq!(method, "artifact.import.inspection");
                Ok(inspection.clone())
            })
            .unwrap(),
            inspection
        );
        let mut bad = inspection;
        bad["references"]["outcomeUnknownJobIds"] = json!(["job-unknown"]);
        assert_eq!(
            execute_import(&invocation, |_, _, _| Ok(bad.clone()))
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}
