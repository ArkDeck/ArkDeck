//! The Windows raw DEFLATE decoder (TASK-XPA-010) over zlib's own streams
//! (`rust/tests/fixtures/raw-deflate`, written by `make-streams.py`): fixed
//! and dynamic codes, long and run-length matches, and more than one output
//! window. Each stream, fed whole and in odd splits, decodes to exactly the
//! plaintext recorded for it, in windows of at most 1 MiB; cut short, it is
//! refused. The Flash archive oracle (`arkdeck-hoststore`) replays Swift's
//! answers over real flash bundles through the same decoder.
#![cfg(windows)]

use arkdeck_platform::{INFLATE_WINDOW_BYTES, InflateError, RawInflate};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/raw-deflate")
}

/// `make-streams.py`'s plaintext.
fn plaintext() -> Vec<u8> {
    let mut data = b"hello, flash bundle\n".repeat(20000);
    data.extend(std::iter::repeat_n(0u8, 300_000));
    let mut state: u64 = 0x243F_6A88_85A3_08D3;
    for _ in 0..20000 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        data.push((state >> 56) as u8);
    }
    for line in 0..12000 {
        data.extend_from_slice(format!("line {line:06} of the partition table\n").as_bytes());
    }
    data
}

fn decode(stream: &[u8], split: usize) -> Result<Vec<u8>, InflateError<()>> {
    let mut inflate = RawInflate::new().unwrap();
    let mut out = Vec::new();
    let mut sink = |window: &[u8]| {
        assert!(!window.is_empty() && window.len() <= INFLATE_WINDOW_BYTES);
        out.extend_from_slice(window);
        Ok(())
    };
    for chunk in stream.chunks(split) {
        inflate.feed(chunk, false, &mut sink)?;
    }
    inflate.feed(&[], true, &mut sink)?;
    Ok(out)
}

#[test]
fn zlib_streams_decode_to_their_plaintext_in_any_split() {
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixtures().join("streams.json")).unwrap()).unwrap();
    let expected = plaintext();
    assert_eq!(
        expected.len() as u64,
        manifest["plaintextBytes"].as_u64().unwrap()
    );
    assert_eq!(
        format!("{:x}", Sha256::digest(&expected)),
        manifest["plaintextSha256"].as_str().unwrap()
    );
    let streams = manifest["streams"].as_array().unwrap();
    assert_eq!(streams.len(), 4);
    for name in streams {
        let name = name.as_str().unwrap();
        let stream = std::fs::read(fixtures().join("streams").join(name)).unwrap();
        for split in [stream.len(), 65_536, 4_099, 97] {
            assert!(
                decode(&stream, split).unwrap() == expected,
                "{name} in chunks of {split}"
            );
        }
        // Finalized before its final block, it is refused.
        assert_eq!(
            decode(&stream[..stream.len() / 2], 4_099),
            Err(InflateError::DecompressionFailed),
            "{name} cut short"
        );
    }
}
