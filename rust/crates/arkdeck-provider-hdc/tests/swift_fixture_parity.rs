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

        // The same hash-verified bytes must also cross the candidate-list arm.
        // Routing them only through the presence parser hid a real divergence:
        // presence normalizes CRLF in its own code, so a target-list parser
        // that refused CRLF stayed green here while Swift accepted it.
        let expected_candidates: Result<&str, &str> = match vector["id"].as_str().unwrap() {
            "device-observation-all-offline-two" => Ok("a1|usb|Offline;b2|usb|Offline"),
            "device-observation-duplicate-key" => Ok("a1|usb|Connected;a1|usb|Offline"),
            "device-observation-empty-marker" => Ok(""),
            "device-observation-empty-stdout" => Err("empty"),
            "device-observation-marker-double-cr" => {
                Err("target line is not the registered 5-column family")
            }
            "device-observation-mixed-connected-offline" => Ok("a1|usb|Connected;b2|usb|Offline"),
            "device-observation-rows-crlf" => Ok("a1|usb|Connected"),
            "device-observation-single-connected" => Ok("a1|usb|Connected"),
            "device-observation-single-offline" => Ok("a1|usb|Offline"),
            "device-observation-two-connected" => Ok("a1|usb|Connected;b2|usb|Connected"),
            "device-observation-unknown-state" => Err("unregistered target state"),
            "device-observation-wrong-columns" => {
                Err("target line is not the registered 5-column family")
            }
            id => panic!("unhandled current Swift observation vector {id}"),
        };
        let candidates = parse_target_list(&bytes, "3.2.0f", false);
        let rendered = match &candidates {
            Ok(rows) => Ok(rows
                .iter()
                .map(|row| {
                    // The fixtures pad their connect keys to 32 characters;
                    // compare the distinguishing suffix, not the padding.
                    let key = &row.connect_key[row.connect_key.len() - 2..];
                    format!("{key}|{}|{}", row.transport, row.state)
                })
                .collect::<Vec<_>>()
                .join(";")),
            Err(ParseError::Empty) => Err("empty"),
            Err(ParseError::Malformed(reason)) => Err(*reason),
            Err(other) => panic!("{}: unexpected {other:?}", vector["id"]),
        };
        assert_eq!(
            rendered
                .as_ref()
                .map(String::as_str)
                .map_err(|reason| *reason),
            expected_candidates,
            "{}: candidate list arm",
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
    // Three parsers, three different CRLF rules, verified against Foundation
    // String indices, CharacterSet.newlines and CharacterSet.whitespaces.
    // The target-list family registers LF and the single CRLF grapheme as
    // terminators; the version probes still split Character("\n") only; the
    // presence parser keeps its own normalization. Porting must not merge them.
    assert_eq!(
        parse_target_list(b"[Empty]\r\n", "3.2.0f", false),
        Ok(Vec::new())
    );
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
fn current_swift_target_line_terminators_and_unregistered_newlines_match() {
    // Only LF and the CRLF grapheme terminate a target line. Every other
    // Foundation newline stays inside its line, keeps the line untrimmed and
    // admits it past the diagnostic filter, so the row grammar refuses it
    // instead of the filter quietly deleting the evidence.
    let mixed = "[I] ignored\r\n\nfirst\t\tUSB\tConnected\tlocalhost\r\n\
                 second\t\tUSB\tOffline\tlocalhost\nthird\t\tUSB\tConnected\tlocalhost\r\n";
    let rows = parse_target_list(mixed.as_bytes(), "3.2.0f", false).unwrap();
    assert_eq!(
        rows.iter()
            .map(|row| format!("{}|{}|{}", row.connect_key, row.transport, row.state))
            .collect::<Vec<_>>(),
        [
            "first|usb|Connected",
            "second|usb|Offline",
            "third|usb|Connected"
        ]
    );

    for accepted in [
        "[Empty]\r\n".as_bytes(),
        b"[Empty]\n",
        b"[Empty]\r\n\r\n",
        // Foundation CharacterSet.whitespaces trims NBSP; it is not a newline.
        "\u{00a0}[Empty]\u{00a0}\r\n".as_bytes(),
    ] {
        assert_eq!(
            parse_target_list(accepted, "3.2.0f", false),
            Ok(Vec::new()),
            "{accepted:?}"
        );
    }
    assert_eq!(
        parse_target_list(b"key\t\tUSB\tConnected\tlocalhost\r\n\n", "3.2.0f", false)
            .unwrap()
            .len(),
        1
    );
    // A bare CR, a double CR and a lone LF terminate nothing.
    for empty in [b"\r\n".as_slice(), b"\n", b"[I] noise\r\n"] {
        assert_eq!(
            parse_target_list(empty, "3.2.0f", false),
            Err(ParseError::Empty),
            "{empty:?}"
        );
    }
    for malformed in [
        b"[Empty]\r".as_slice(),
        b"[Empty]\r\r\n",
        b"[Empty]\r\nkey\t\tUSB\tConnected\tlocalhost\n",
        b"key\t\tUSB\tConnected\tlocalhost\r\r\n",
        b"\r",
        // Unregistered newlines override the ignorable-diagnostic filter, so a
        // dropped `[I]`/`[W]` line can never turn a corrupt feed into `[Empty]`.
        b"[I] malformed\r\n[Empty]\r\n[W] residual\r",
        b"[I] noise\rmore\n[Empty]\n",
        b"[Empty]\x0b\n",
        b"[Empty]\x0c\n",
        "[Empty]\u{0085}".as_bytes(),
        "[Empty]\r\n[W] residual\u{0085}".as_bytes(),
        "[Empty]\r\n\u{2028}".as_bytes(),
        "[Empty]\r\n\u{2029}".as_bytes(),
        // A residual CR inside a field is whitespace, so the key bound rejects it.
        b"ke\ry\t\tUSB\tConnected\tlocalhost\n",
    ] {
        assert!(
            matches!(
                parse_target_list(malformed, "3.2.0f", false),
                Err(ParseError::Malformed(_))
            ),
            "{malformed:?}"
        );
    }
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
