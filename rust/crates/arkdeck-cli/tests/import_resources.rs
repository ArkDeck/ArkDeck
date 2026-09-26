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
        let fixture: Value =
            arkdeck_cli::machine_contracts::argv_fixture(&format!("artifact.import.{kind}"))
                .unwrap();
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
    // The upload's mutations keep each Import owner code its evidence proves,
    // commit's four owner refusals among them (§8.4, as Swift's mapper).
    for method in ["artifact.import.append", "artifact.import.commit"] {
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
                method,
            );
            assert_eq!(actual.code, code, "{method}");
            assert_eq!(actual.exit_code(), exit, "{method}");
        }
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
            // Swift `CLIImports.swift`'s texts (:194, :91, :121).
            assert_eq!(
                (error.code, error.message.as_str()),
                match failure {
                    "source" | "sourceMetadata" => (
                        "artifactIntegrityFailed",
                        "Import source changed; staged data was not overwritten or aborted",
                    ),
                    "target" => (
                        "idempotencyConflict",
                        "Import request identity already names different metadata",
                    ),
                    _ => (
                        "recordUnreadable",
                        "Import recovery changed its owner or committed prefix",
                    ),
                },
                "{failure}"
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
        let mut bad = inspection.clone();
        bad["references"]["outcomeUnknownJobIds"] = json!(["job-unknown"]);
        let error = execute_import(&invocation, |_, _, _| Ok(bad.clone())).unwrap_err();
        // Swift `ArtifactImportInspectionProjection` and `CLIImports.swift`:53.
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "Import reference inspection is malformed"
            )
        );
        let mut other = inspection;
        other["import"]["importRequestId"] = json!("another");
        other["import"]["metadata"]["importRequestId"] = json!("another");
        let mut intent = source.intent();
        intent.request_id = "another".into();
        other["import"]["metadataFingerprint"] = json!(intent.fingerprint().unwrap());
        let error = execute_import(&invocation, |_, _, _| Ok(other.clone())).unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "Import inspection returned another requested owner"
            )
        );
    }
    /// Swift's CLI refusals of an upload, as `ImportRefusalOracleContractTests`
    /// recorded them (`rust/tests/fixtures/import-refusal-oracle`, "cli"):
    /// code, message, details and exit status.
    #[test]
    fn swift_recorded_upload_refusals_are_answered_in_swift_s_words() {
        let oracle: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/import-refusal-oracle/cases.json"
        ))
        .unwrap();
        let cases = oracle["cli"].as_array().unwrap();
        assert_eq!(cases.len(), 5);
        let mut hap = b"PK\x03\x04".to_vec();
        hap.resize(4096, b'a');
        let held = |request: &str, name: &str, offset: u64| {
            resource(
                &ImportIntent {
                    request_id: request.into(),
                    kind: "hap".into(),
                    target_id: "TGT-fixture".into(),
                    binding_revision: 1,
                    device_profile: None,
                    name: name.into(),
                    byte_count: hap.len() as u64,
                    sha256: sha256_hex(&hap),
                },
                offset,
            )
        };
        for case in cases {
            let name = case["case"].as_str().unwrap();
            // The file each case uploads, and what the Runtime holds for its
            // request identity.
            let (file, bytes, existing) = match name {
                "cli.sourceCannotBeOpened" => ("fixture.hap", None, None),
                "cli.sourceOutsideBound" => ("fixture.hap", Some(Vec::new()), None),
                "cli.metadataOutsideKind" => ("fixture.txt", Some(hap.clone()), None),
                "cli.sourceChangedForExistingIdentity" => {
                    let mut changed = hap.clone();
                    changed[100] = 0xff;
                    (
                        "fixture.hap",
                        Some(changed),
                        Some(held("oracle-cli-changed", "fixture.hap", 100)),
                    )
                }
                "cli.identityNamesDifferentMetadata" => (
                    "other.hap",
                    Some(hap.clone()),
                    Some(held("oracle-cli-renamed", "fixture.hap", 0)),
                ),
                _ => panic!("{name}"),
            };
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "cli-import-oracle-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            let path = root.join(file);
            if let Some(bytes) = bytes {
                fs::write(&path, bytes).unwrap();
            }
            let args: Vec<String> = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|arg| match arg.as_str().unwrap() {
                    "$file" => path.to_str().unwrap().to_owned(),
                    "$targetId" => "TGT-fixture".to_owned(),
                    other => other.to_owned(),
                })
                .collect();
            let error = execute_import(&parse(&args).unwrap(), |method, _, _| match method {
                "artifact.import.inspect" => existing
                    .clone()
                    .ok_or_else(|| CliError::new("resourceNotFound", "Import does not exist")),
                "target.show" => Ok(
                    json!({"schemaVersion":"arkdeck.target/1","targetId":"TGT-fixture","bindingRevision":1}),
                ),
                _ => panic!("{name}: unexpected {method}"),
            })
            .unwrap_err();
            fs::remove_dir_all(&root).unwrap();
            // The error object as this CLI prints it.
            assert_eq!(
                arkdeck_cli::failure_envelope("artifact.import.hap", &error, "oracle", true)["error"],
                case["error"],
                "{name}"
            );
            assert_eq!(i64::from(error.exit_code()), case["exitStatus"], "{name}");
        }
    }
    /// Swift's CLI refusals of Runtime answers it cannot accept, which no
    /// Swift daemon gives and so no oracle holds (`CLIImports.swift`).
    #[test]
    fn upload_refusals_of_unacceptable_runtime_answers_are_swift_s() {
        let source = Source::new("fixture.hap", b"abcdefgh".to_vec());
        let intent = source.intent();
        let refusal = |error: CliError| (error.code, error.message);
        // :73, a Target without its exact current binding.
        assert_eq!(
            refusal(
                execute_import(&source.invocation("hap"), |method, _, _| match method {
                    "artifact.import.inspect" => Err(CliError::new("resourceNotFound", "absent")),
                    "target.show" => Ok(
                        json!({"schemaVersion":"arkdeck.target/1","targetId":"TGT-fixture","bindingRevision":0})
                    ),
                    _ => panic!("unexpected {method}"),
                })
                .unwrap_err()
            ),
            (
                "recordUnreadable",
                "target has no exact current binding reference".into()
            )
        );
        // ArtifactImportProjection.swift:12, an answer that is no Import.
        assert_eq!(
            refusal(
                execute_import(&source.invocation("hap"), |_, _, _| Ok(
                    json!({"state":"inProgress"})
                ))
                .unwrap_err()
            ),
            (
                "recordUnreadable",
                "Runtime returned an invalid Import projection".into()
            )
        );
        // :106, a begin that answers other metadata.
        let mut other = intent.clone();
        other.name = "other.hap".into();
        assert_eq!(
            refusal(
                execute_import(&source.invocation("hap"), |method, _, _| match method {
                    "artifact.import.inspect" => Err(CliError::new("resourceNotFound", "absent")),
                    "target.show" => Ok(
                        json!({"schemaVersion":"arkdeck.target/1","targetId":"TGT-fixture","bindingRevision":7})
                    ),
                    "artifact.import.begin" => Ok(resource(&other, 0)),
                    _ => panic!("unexpected {method}"),
                })
                .unwrap_err()
            ),
            (
                "recordUnreadable",
                "Import receipt changed the upload metadata".into()
            )
        );
        // :116, an append that answers another offset.
        assert_eq!(
            refusal(
                execute_import(&source.invocation("hap"), |method, _, _| match method {
                    "artifact.import.inspect" => Ok(resource(&intent, 0)),
                    "artifact.import.append" => Ok(resource(&intent, 3)),
                    _ => panic!("unexpected {method}"),
                })
                .unwrap_err()
            ),
            (
                "recordUnreadable",
                "Import append returned another owner or offset".into()
            )
        );
        // :137, a commit that answers another owner.
        assert_eq!(
            refusal(
                execute_import(&source.invocation("hap"), |method, _, _| match method {
                    "artifact.import.inspect" => Ok(resource(&intent, 8)),
                    "artifact.import.commit" => {
                        let mut committed = resource(&intent, 8);
                        committed["importId"] = json!("imp-00000000-0000-4000-8000-000000000002");
                        Ok(committed)
                    }
                    _ => panic!("unexpected {method}"),
                })
                .unwrap_err()
            ),
            (
                "recordUnreadable",
                "Import commit returned another owner".into()
            )
        );
        // :147, the client's deadline.
        let timed = parse(&argv(&[
            "artifact",
            "import",
            "hap",
            "--import-request-id",
            "request",
            "--target",
            "TGT-fixture",
            "--file",
            source.path.to_str().unwrap(),
            "--timeout",
            "1ms",
        ]))
        .unwrap();
        assert_eq!(
            refusal(
                execute_import(&timed, |method, _, _| {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                    match method {
                        "artifact.import.inspect" => {
                            Err(CliError::new("resourceNotFound", "absent"))
                        }
                        _ => panic!("unexpected {method}"),
                    }
                })
                .unwrap_err()
            ),
            (
                "clientTimeout",
                "Import client timed out; inspect or retry the same request identity".into()
            )
        );
    }
}

#[test]
fn import_list_maps_only_closed_discovery_options() {
    let invocation = parse(&argv(&[
        "artifact",
        "import",
        "list",
        "--target",
        "TGT-fixture",
        "--state",
        "committed",
        "--page-size",
        "1",
        "--cursor",
        "opaque",
    ]))
    .unwrap();
    assert_eq!(invocation.method, "artifact.import.list");
    assert_eq!(
        invocation.params.unwrap(),
        json!({"target":"TGT-fixture","state":"committed","pageSize":1,"cursor":"opaque"})
            .as_object()
            .unwrap()
            .clone()
    );
    // The registry bounds the state and the page size and knows no file.
    for args in [
        vec!["--state", "unknown"],
        vec!["--page-size", "0"],
        vec!["--page-size", "1001"],
        vec!["--file", "source"],
    ] {
        let mut values = vec!["artifact", "import", "list"];
        values.extend(args);
        assert!(parse(&argv(&values)).is_err());
    }
    // Swift sends the target and the cursor as given, for the Runtime to judge.
    assert_eq!(
        parse(&argv(&[
            "artifact",
            "import",
            "list",
            "--target",
            "../target",
            "--cursor",
            ""
        ]))
        .unwrap()
        .params
        .unwrap(),
        json!({"target":"../target","cursor":""})
            .as_object()
            .unwrap()
            .clone()
    );
}
#[cfg(target_os = "macos")]
#[test]
fn import_list_rejects_malformed_paging_and_foreign_inventory_without_retry() {
    let invocation = parse(&argv(&["artifact", "import", "list"])).unwrap();
    let page = json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot","items":[],"order":"createdAtDescImportIdAsc","snapshotRevision":"00000000-0000-4000-8000-000000000001","hasMore":false,"nextCursor":null});
    let mut calls = 0;
    assert_eq!(
        arkdeck_cli::execute_import(&invocation, |method, fields, _| {
            calls += 1;
            assert_eq!(method, "artifact.import.list");
            assert!(fields.is_empty());
            Ok(page.clone())
        })
        .unwrap(),
        page
    );
    assert_eq!(calls, 1);
    for (key, value) in [
        ("snapshotRevision", json!("bad")),
        ("hasMore", json!(true)),
        ("nextCursor", json!("unexpected")),
        ("order", json!("createdAtAsc")),
    ] {
        let mut bad = page.clone();
        bad[key] = value;
        let error =
            arkdeck_cli::execute_import(&invocation, |_, _, _| Ok(bad.clone())).unwrap_err();
        // Swift `ArtifactImportProjection.validatePage`.
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "Runtime returned an invalid Import page"
            ),
            "{key}"
        );
    }
}

#[test]
fn release_uses_original_generation_and_refuses_foreign_or_unbounded_receipts() {
    let id = "imp-00000000-0000-4000-8000-000000000001";
    let invocation = parse(&argv(&[
        "artifact",
        "import",
        "release",
        "--import",
        id,
        "--generation",
        "2",
    ]))
    .unwrap();
    assert_eq!(invocation.method, "artifact.import.release");
    assert_eq!(
        invocation.params.as_ref().unwrap(),
        json!({"importId":id,"generation":"2"}).as_object().unwrap()
    );
    for args in [
        vec!["artifact", "import", "release", "--import", id],
        vec![
            "artifact",
            "import",
            "release",
            "--import",
            id,
            "--generation",
            "0",
        ],
        vec![
            "artifact",
            "import",
            "release",
            "--import",
            id,
            "--generation",
            "9007199254740992",
        ],
    ] {
        assert!(parse(&argv(&args)).is_err());
    }
    #[cfg(target_os = "macos")]
    {
        let artifact = "ART-00000000000000000000000000000000";
        let receipt = json!({"schemaVersion":"arkdeck.import-release/1","importId":id,"importRequestId":"release","owner":{"kind":"import","id":id},"artifactId":artifact,"lease":format!("lease-v1:{id}:{artifact}"),"releasedGeneration":"2","generation":"3","state":"released","releasedAtUtc":"2026-09-12T00:00:00Z","retention":{"class":"default","pinned":false,"deadlineUtc":"2026-09-19T00:00:00Z"}});
        assert_eq!(
            arkdeck_cli::execute_import(&invocation, |method, _, _| {
                assert_eq!(method, "artifact.import.release");
                Ok(receipt.clone())
            })
            .unwrap(),
            receipt
        );
        for (key, value) in [
            (
                "importId",
                json!("imp-00000000-0000-4000-8000-000000000002"),
            ),
            ("generation", json!("4")),
            (
                "lease",
                json!("lease-v1:job-other:ART-00000000000000000000000000000000"),
            ),
            (
                "retention",
                json!({"class":"default","pinned":false,"deadlineUtc":"2026-09-11T00:00:00Z"}),
            ),
        ] {
            let mut bad = receipt.clone();
            bad[key] = value;
            let error =
                arkdeck_cli::execute_import(&invocation, |_, _, _| Ok(bad.clone())).unwrap_err();
            // Swift `ArtifactImportReleaseProjection`: the receipt is not
            // one for its own Import.
            assert_eq!(
                (error.code, error.message.as_str()),
                ("recordUnreadable", "Import release receipt is malformed"),
                "{key}"
            );
        }
        // A well-formed receipt of another Import (`CLIImports.swift`:46).
        let other = "imp-00000000-0000-4000-8000-000000000002";
        let mut foreign = receipt.clone();
        foreign["importId"] = json!(other);
        foreign["owner"] = json!({"kind":"import","id":other});
        foreign["lease"] = json!(format!("lease-v1:{other}:{artifact}"));
        let error =
            arkdeck_cli::execute_import(&invocation, |_, _, _| Ok(foreign.clone())).unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "Import release receipt does not match the requested owner and generation"
            )
        );
    }
}

#[cfg(target_os = "macos")]
mod support;

/// Swift's daemon refuses the inspection and the release of an Import it never
/// began, and the inspection of one more active Jobs reference than its bound,
/// with the Import owner's code, words and zero-dispatch evidence
/// (`DurableImportContractTests
/// .testInspectionAndReleaseRefusalsCarryTheImportOwnersCodeMessageAndEvidence`,
/// TASK-XPA-017). Wherever this build's schema publishes the code, this CLI
/// reads the refusal and answers the Import owner's code (§8.4). check-contracts'
/// published view compiles the merge base's schemas, which predate the codes.
#[cfg(target_os = "macos")]
#[test]
fn inspection_and_release_refusals_reach_the_caller_with_the_import_owners_code() {
    let missing = "imp-00000000-0000-0000-0000-000000000001";
    let referenced = "imp-c7737f12-9678-47a8-aca9-a39a12d80a0b";
    for (argv, method, params, code, message) in [
        (
            vec!["artifact", "import", "inspect", "--import", missing],
            "artifact.import.inspection",
            json!({ "importId": missing }),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            vec![
                "artifact",
                "import",
                "inspect",
                "--import-request-id",
                "never-began",
            ],
            "artifact.import.inspection",
            json!({"importRequestId":"never-began"}),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            vec![
                "artifact",
                "import",
                "release",
                "--import",
                missing,
                "--generation",
                "2",
            ],
            "artifact.import.release",
            json!({"importId":missing,"generation":"2"}),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            vec!["artifact", "import", "inspect", "--import", referenced],
            "artifact.import.inspection",
            json!({ "importId": referenced }),
            "inputTooLarge",
            "Import reference inspection exceeds its Job bound",
        ),
    ] {
        let error = json!({"code":code,"message":message,
            "details":{"newDispatchCount":0,"phase":"importOwner"}});
        if arkdeck_contract::validate_method_value(method, "errorCode", &json!(code)).is_err() {
            let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
            assert!(
                inputs["kind"] == "development" && inputs.get("commit").is_some(),
                "only the merge base's schema predates {method}'s {code}"
            );
            continue;
        }
        // The refusal is the frame Swift's daemon answered, as its corpus holds it.
        let corpus = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
                "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
            )),
        )
        .unwrap();
        assert!(
            corpus
                .lines()
                .map(|line| serde_json::from_str::<Value>(line).unwrap())
                .any(|row| row["params"] == params && row["error"] == error),
            "{method} {params}"
        );
        let (output, envelope) = support::run(
            &argv,
            vec![(
                method.into(),
                params.clone(),
                json!({"ok":false,"error":error}),
            )],
        );
        assert_eq!(
            output.status.code(),
            Some(i32::from(CliError::new(code, message).exit_code())),
            "{method} {params}"
        );
        assert_eq!(envelope["ok"], false, "{method} {params}");
        assert_eq!(
            (&envelope["error"]["code"], &envelope["error"]["message"]),
            (&json!(code), &json!(message)),
            "{method} {params}"
        );
    }
}
