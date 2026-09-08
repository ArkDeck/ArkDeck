use std::fs;
use std::path::{Path, PathBuf};

use arkdeck_provider_hdc::{
    CommandFailure, CommandOutcome, ObservationInput, ObservationTermination, ParseError,
    PresenceSnapshot, SemanticOutputParser, parse_client_version, parse_registered_presence,
    parse_server_check, parse_target_list,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC")
}

fn json(path: impl AsRef<Path>) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn verify_resource(root: &Path, entry: &Value) -> Vec<u8> {
    let path = entry["file"]
        .as_str()
        .or_else(|| entry["path"].as_str())
        .unwrap();
    let bytes = fs::read(root.join(path)).unwrap();
    assert_eq!(
        bytes.len() as u64,
        entry["bytes"]
            .as_u64()
            .or_else(|| entry["sizeBytes"].as_u64())
            .unwrap(),
        "{path}: byte count drift"
    );
    assert_eq!(
        format!("{:x}", Sha256::digest(&bytes)),
        entry["sha256"].as_str().unwrap(),
        "{path}: digest drift"
    );
    bytes
}

#[test]
fn every_swift_golden_byte_and_current_command_classification_match() {
    let golden = root().join("Golden");
    let registry = json(golden.join("1.0.0/registry.json"));
    let entries = registry["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 5);
    for entry in entries {
        let bytes = verify_resource(&golden, entry);
        // Every possible split checks that a marker is not lost when stdout
        // arrives in different process-pipe chunks on Windows and macOS.
        for split in 0..=bytes.len() {
            let mut parser = SemanticOutputParser::new();
            parser.consume(&bytes[..split]);
            parser.consume(&bytes[split..]);
            let expected = match entry["id"].as_str().unwrap() {
                "hdc-golden-failure-unauthorized" => {
                    CommandOutcome::Failure(CommandFailure::Unauthorized)
                }
                "hdc-golden-failure-offline" => CommandOutcome::Failure(CommandFailure::Offline),
                "hdc-golden-success-uninstall" => {
                    assert_eq!(entry["currentParserClassification"], "unknownOutput");
                    // A published command-result capture is not authorization
                    // to execute uninstall from this read-only foundation.
                    CommandOutcome::UnknownOutput
                }
                "hdc-golden-healthy-checkserver" | "hdc-golden-version" => {
                    CommandOutcome::UnknownOutput
                }
                id => panic!("unhandled Swift Golden entry {id}"),
            };
            assert_eq!(parser.finish(0), expected, "{} split={split}", entry["id"]);
            assert_eq!(
                parser.finish(7),
                CommandOutcome::Failure(CommandFailure::NonZeroExit(7))
            );
        }
        match entry["family"].as_str().unwrap() {
            "version" => assert_eq!(parse_client_version(&bytes, false).unwrap(), "3.2.0d"),
            "healthy" => {
                let result = parse_server_check(&bytes, false).unwrap();
                assert_eq!(result.client_version, "3.2.0d");
                assert_eq!(result.server_version, "3.2.0d");
                assert!(result.versions_agree());
            }
            "success" | "failure" => {}
            family => panic!("unhandled Swift Golden family {family}"),
        }
    }
}

#[test]
fn streaming_failure_precedence_and_large_tail_match_swift() {
    let mut parser = SemanticOutputParser::new();
    let chunk = b"progress: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    for _ in 0..16_384 {
        parser.consume(chunk);
    }
    parser.consume(b"[SUCCESS]\n[Fail] Off");
    parser.consume(b"line after transfer\n");
    assert_eq!(
        parser.finish(0),
        CommandOutcome::Failure(CommandFailure::Offline)
    );
    parser.consume(b"e000");
    parser.consume(b"002");
    parser.consume(b"[Fail] offline [success]");
    assert_eq!(
        parser.finish(0),
        CommandOutcome::Failure(CommandFailure::Unauthorized)
    );
    let mut only_success = SemanticOutputParser::new();
    only_success.consume(b"[success]");
    assert_eq!(only_success.finish(0), CommandOutcome::Success);
    let mut empty = SemanticOutputParser::new();
    empty.consume(b"anything outside the registered family");
    assert_eq!(empty.finish(0), CommandOutcome::UnknownOutput);
}

#[test]
fn every_registered_presence_vector_matches_swift_and_retains_fixture_hash() {
    let pack = root().join("Probes/DeviceObservation/1.0.0");
    let resources = json(pack.join("resources.json"));
    verify_resource(&pack, &resources["registryCopy"]);
    verify_resource(&pack, &resources["controls"]);
    let vectors = resources["vectors"].as_array().unwrap();
    assert_eq!(vectors.len(), 12);
    for vector in vectors {
        let bytes = verify_resource(&pack, vector);
        let actual =
            parse_registered_presence(&ObservationInput::exited(&bytes, b"", 0), &[0x11; 32]);
        let outcome = match &actual {
            Ok(PresenceSnapshot::ObservedEmpty) => "observedEmpty".to_owned(),
            Ok(PresenceSnapshot::ObservedConnectedSet(ids)) => {
                for identifier in ids {
                    assert!(identifier.starts_with("redacted-device-"));
                    assert_eq!(identifier.len(), "redacted-device-".len() + 24);
                    assert!(
                        identifier["redacted-device-".len()..]
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                    );
                    assert!(!identifier.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"));
                }
                format!("observed:{}", ids.len())
            }
            Err(failure) => failure.classification().to_owned(),
        };
        assert_eq!(
            outcome, vector["expectedOutcome"],
            "{}: {actual:?}",
            vector["id"]
        );
    }
}

#[test]
fn presence_pseudonyms_match_hmac_and_do_not_cross_session_or_order_boundaries() {
    let bytes =
        fs::read(root().join("Probes/DeviceObservation/1.0.0/vectors/two-connected.bin")).unwrap();
    let actual =
        parse_registered_presence(&ObservationInput::exited(&bytes, b"", 0), &[0x11; 32]).unwrap();
    assert_eq!(
        actual,
        PresenceSnapshot::ObservedConnectedSet(vec![
            "redacted-device-6dcd1f0514d664f8cecb6689".to_owned(),
            "redacted-device-a116460b5e31aa0b3af57150".to_owned(),
        ])
    );
    let reversed = std::str::from_utf8(&bytes)
        .unwrap()
        .lines()
        .rev()
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    assert_eq!(
        actual,
        parse_registered_presence(
            &ObservationInput::exited(reversed.as_bytes(), b"", 0),
            &[0x11; 32]
        )
        .unwrap()
    );
    assert_ne!(
        actual,
        parse_registered_presence(&ObservationInput::exited(&bytes, b"", 0), &[0x22; 32]).unwrap()
    );
}

#[test]
fn all_raw_execution_controls_are_fail_closed() {
    let pack = root().join("Probes/DeviceObservation/1.0.0");
    let controls = json(pack.join("controls/fail-closed-vectors.json"));
    let mut output_controls = 0;
    let mut provider_controls = Vec::new();
    for control in controls["cases"].as_array().unwrap() {
        let mut input = ObservationInput::exited(b"[Empty]\r\n", b"", 0);
        match control["id"].as_str().unwrap() {
            "stderr-non-empty" => input.stderr = b"unexpected stderr",
            "nonzero-exit" => input.termination = ObservationTermination::Exited(1),
            "stdout-truncated" => input.stdout_truncated = true,
            "timeout" => input.termination = ObservationTermination::TimedOut,
            "cancelled" => input.termination = ObservationTermination::Cancelled,
            "invalid-encoding" => input.stdout = &[0xff, 0xfe, 0x00],
            // These are exercised by the sealed Provider's dispatch-order,
            // profile and lease tests, not supplied to a pure byte parser.
            id @ ("server-absent"
            | "endpoint-drift"
            | "server-identity-drift"
            | "executable-identity-drift") => {
                provider_controls.push(id);
                continue;
            }
            id => panic!("unhandled current Swift fail-closed vector {id}"),
        }
        output_controls += 1;
        let failure = parse_registered_presence(&input, &[0x11; 32]).unwrap_err();
        assert_eq!(
            failure.classification(),
            control["expected"],
            "{}",
            control["id"]
        );
    }
    assert_eq!(output_controls, 6);
    assert_eq!(provider_controls.len(), 4);
}

#[test]
fn unknown_rows_collapse_the_whole_presence_snapshot() {
    for tail in [
        "bad\t\tUSB\tBooting\tlocalhost\n",
        "bad\t\tTCP\tConnected\tlocalhost\n",
        "bad\t\tUSB\tConnected\tremote\n",
        "\t\tUSB\tConnected\tlocalhost\n",
        "bad\t\tUSB\tConnected\tlocalhost\r\r\n",
        "bad\t\tUSB\tConnected\tlocalhost",
        "key\t\tUSB\tOffline\tlocalhost\n",
        "[Empty]\r\n",
    ] {
        let bytes = format!("key\t\tUSB\tConnected\tlocalhost\n{tail}");
        assert!(
            parse_registered_presence(
                &ObservationInput::exited(bytes.as_bytes(), b"", 0),
                &[0; 32]
            )
            .is_err()
        );
    }
    for stdout in [b"".as_slice(), b"[Empty]\n", b"[Empty]\r", b"\n"] {
        assert!(
            parse_registered_presence(&ObservationInput::exited(stdout, b"", 0), &[0; 32]).is_err()
        );
    }
}

#[test]
fn all_existing_probe_receipt_packs_remain_hash_exact_and_separate() {
    let probes = root().join("Probes");
    let readonly = json(probes.join("1.0.0/resources.json"));
    for resource in readonly["resources"].as_array().unwrap() {
        verify_resource(&probes, resource);
    }
    let supervisor = probes.join("SupervisorObservation/1.0.0");
    let resources = json(supervisor.join("resources.json"));
    for key in ["registryCopy", "receipt", "controls", "attributes"] {
        verify_resource(&supervisor, &resources[key]);
    }
    let receipt = json(supervisor.join("receipts/server-identity-generation.json"));
    assert_eq!(receipt["selectedCandidate"]["platform"], "macos");
    assert_eq!(receipt["selectedCandidate"]["reportedVersion"], "3.2.0f");
    assert!(
        receipt["boundary"]
            .as_str()
            .unwrap()
            .contains("not a reusable production receipt")
    );
    // Archived, redacted and synthetic receipts are never inputs to Provider
    // construction. Their hashes are parity data, not live server identity.
    assert_eq!(readonly["integrationProfile"], "OPENHARMONY-TOOLS@0.3.0");
    assert_eq!(resources["integrationProfile"], "OPENHARMONY-TOOLS@0.6.0");
}

#[test]
fn candidate_parser_matches_current_swift_without_borrowing_presence_semantics() {
    let rows = b"key-a\t\tUSB\tConnected\tlocalhost\nkey-b\t\tTCP\tUnauthorized\tlocalhost\nkey-a\t\tUART\tOffline\tlocalhost\n";
    let candidates = parse_target_list(rows, "3.2.0f", false).unwrap();
    assert_eq!(candidates.len(), 3);
    assert_eq!(candidates[0].connect_key, candidates[2].connect_key);
    assert_eq!(candidates[1].state, "Unauthorized");
    assert_eq!(candidates[2].state, "Offline");
    assert_eq!(candidates[1].transport, "tcp");
    assert_eq!(candidates[2].transport, "uart");
    assert!(
        parse_target_list(b"[Empty]\n", "3.2.0f", false)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        parse_target_list(b"", "3.2.0f", false),
        Err(ParseError::Empty)
    );
    assert_eq!(
        parse_target_list(b"[Empty]\n", "9.9.9z", false),
        Err(ParseError::UnsupportedVersion("9.9.9z".to_owned()))
    );
    assert_eq!(
        parse_target_list(&[0xff], "3.2.0f", false),
        Err(ParseError::InvalidEncoding)
    );
    assert_eq!(
        parse_target_list(rows, "3.2.0f", true),
        Err(ParseError::Truncated)
    );
    for invalid in [
        b"key\tUSB\tConnected\n".as_slice(),
        b"key\tname\tUSB\tConnected\tlocalhost\n",
        b"key\t\tUSB\tBooting\tlocalhost\n",
        b"key\t\tUnknown\tConnected\tlocalhost\n",
        b"key\t\tUSB\tConnected\tremote\n",
        b"bad key\t\tUSB\tConnected\tlocalhost\n",
    ] {
        assert!(matches!(
            parse_target_list(invalid, "3.2.0f", false),
            Err(ParseError::Malformed(_))
        ));
    }
    let long_key = format!("{}\t\tUSB\tConnected\tlocalhost\n", "k".repeat(129));
    assert!(parse_target_list(long_key.as_bytes(), "3.2.0f", false).is_err());
}

#[test]
fn current_swift_crlf_family_boundary_is_explicit() {
    // Verified against Foundation String.split and CharacterSet.whitespaces:
    // the compatibility parser does not normalize CRLF, while the separately
    // registered presence parser does. Porting must not silently merge them.
    assert!(parse_target_list(b"[Empty]\r\n", "3.2.0f", false).is_err());
    assert!(parse_client_version(b"Ver: 3.2.0f\r\n", false).is_err());
    assert_eq!(
        parse_client_version(b"[I] noise\r\nVer: 3.2.0f\n", false),
        Err(ParseError::Empty)
    );
    assert_eq!(
        parse_registered_presence(&ObservationInput::exited(b"[Empty]\r\n", b"", 0), &[0; 32]),
        Ok(PresenceSnapshot::ObservedEmpty)
    );
}

#[test]
fn version_and_server_parser_failures_match_swift() {
    assert_eq!(
        parse_client_version(
            b"[I] server starting\n\n   Ver: 3.2.0f   \n[W] benign\n",
            false
        )
        .unwrap(),
        "3.2.0f"
    );
    for version in ["3.2.0d", "3.2.0f"] {
        assert_eq!(
            parse_client_version(format!("Ver: {version}\n").as_bytes(), false).unwrap(),
            version
        );
    }
    assert_eq!(parse_client_version(b"", false), Err(ParseError::Empty));
    assert_eq!(
        parse_client_version(b"Ver: 1.0.0a\n", false),
        Err(ParseError::UnsupportedVersion("1.0.0a".to_owned()))
    );
    assert_eq!(
        parse_client_version(&[0xff, 0xfe, 0x00], false),
        Err(ParseError::InvalidEncoding)
    );
    assert_eq!(
        parse_client_version(b"Ver: 3.2.0f\n", true),
        Err(ParseError::Truncated)
    );
    assert!(matches!(
        parse_client_version(b"Ver: 3.2.0f\nVer: 3.2.0d\n", false),
        Err(ParseError::Malformed(_))
    ));
    let mismatch = parse_server_check(
        b"Client version:Ver: 3.2.0f, server version:Ver: 3.2.0d\n",
        false,
    )
    .unwrap();
    assert!(!mismatch.versions_agree());
    assert_eq!(
        parse_server_check(
            b"Client version:Ver: 3.2.0f, server version:Ver: 9.9.9z\n",
            false
        ),
        Err(ParseError::UnsupportedVersion("9.9.9z".to_owned()))
    );
    for stdout in [
        b"Ver: 3.2.0f\n".as_slice(),
        b"[Fail] Offline after transfer\n",
        b"Client version:Ver: 3.2.0f server version:Ver: 3.2.0f\n",
    ] {
        assert!(matches!(
            parse_server_check(stdout, false),
            Err(ParseError::Malformed(_))
        ));
    }
}
