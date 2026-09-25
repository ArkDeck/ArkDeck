//! Replays the Swift oracle of `JSCrashSymbolizer`
//! (`rust/tests/fixtures/crash-symbolizer-oracle`, recorded by
//! `CrashSymbolizerOracleContractTests`) against the Rust port: for every
//! source map and crash dump — the device's own case, a hand-written case per
//! rule and 60 generated ones — the exact report Swift wrote, or an error of
//! the kind Swift threw (with its own detail where the symbolizer, not
//! Foundation's parser, wrote one).
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{SymbolizeError, symbolize_crash};
use serde_json::Value;

/// Standard Base64, as the oracle encodes the inputs' exact bytes.
fn unbase64(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = Vec::new();
    let (mut buffer, mut bits) = (0_u32, 0);
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = ALPHABET.iter().position(|a| *a == byte).unwrap() as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    bytes
}

#[test]
fn the_rust_symbolizer_reports_as_recorded() {
    let fixture = support::fixture("crash-symbolizer-oracle");
    let cases: Value = support::document(&fixture, "cases.json");
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 77);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let map = unbase64(case["map"].as_str().unwrap());
        let dump = unbase64(case["dump"].as_str().unwrap());
        let answer = symbolize_crash(&map, &dump);
        match (case.get("report"), case.get("error")) {
            (Some(report), None) => {
                assert_eq!(answer.as_deref(), Ok(report.as_str().unwrap()), "{name}");
            }
            (None, Some(error)) => {
                assert_eq!(error, "sourceMapUnreadable", "{name}");
                let Err(SymbolizeError::SourceMapUnreadable(detail)) = answer else {
                    panic!("{name}: {answer:?}");
                };
                if let Some(expected) = case.get("detail") {
                    assert_eq!(detail, expected.as_str().unwrap(), "{name}");
                }
            }
            _ => panic!("{name}: the oracle records a report or an error"),
        }
    }
}
