//! Data-only closure of the additive transport descriptor against unchanged
//! trace goldens and the actual provider. Synthetic CRLF is not capture evidence.
use arkdeck_provider_hdc::{
    BYTRACE_HELP_FAMILY, HITRACE_HELP_FAMILY, TraceSelection, TraceTool, evaluate_help,
    evaluate_tag_list,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, path::Path};

const DESCRIPTOR: &str =
    "openspec/integrations/openharmony/trace-probes/representations/1.0.0/registry.json";
const DESCRIPTOR_SHA: &str = "e0fe28bd62f0f725d8c24b3e8acd488ddd42c3f8c61af42c717049fa54ecde62";
const BASE: &str = "openspec/integrations/openharmony/trace-probes/1.0.0";

fn bytes(path: &str) -> Vec<u8> {
    fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../..")
            .join(path),
    )
    .unwrap()
}
fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[test]
fn the_descriptor_closes_on_unchanged_resources_and_exact_provider_verdicts() {
    let raw = bytes(DESCRIPTOR);
    assert_eq!(sha(&raw), DESCRIPTOR_SHA);
    let descriptor: Value = serde_json::from_slice(&raw).unwrap();
    assert_eq!(
        descriptor["registryId"],
        "OPENHARMONY-TRACE-REPRESENTATIONS"
    );
    assert_eq!(descriptor["registryVersion"], "1.0.0");
    assert_eq!(descriptor["integrationProfile"], "OPENHARMONY-TOOLS@0.8.0");
    let base = &descriptor["baseRegistry"];
    assert_eq!(base["sha256"], sha(&bytes(base["path"].as_str().unwrap())));
    let resources_raw = bytes(base["resourcesPath"].as_str().unwrap());
    assert_eq!(base["resourcesSha256"], sha(&resources_raw));
    let resources: Value = serde_json::from_slice(&resources_raw).unwrap();
    let rows = descriptor["representations"].as_array().unwrap();
    assert_eq!(rows.len(), 4);
    for (row, (tool, kind, family, selection, count, pairs)) in rows.iter().zip([
        (
            TraceTool::Hitrace,
            "help",
            HITRACE_HELP_FAMILY,
            "captureEligible",
            3382,
            46,
        ),
        (
            TraceTool::Hitrace,
            "tags",
            HITRACE_HELP_FAMILY,
            "captureEligible",
            3604,
            83,
        ),
        (
            TraceTool::Bytrace,
            "help",
            BYTRACE_HELP_FAMILY,
            "probeOnly",
            3382,
            46,
        ),
        (
            TraceTool::Bytrace,
            "tags",
            BYTRACE_HELP_FAMILY,
            "probeOnly",
            3604,
            83,
        ),
    ]) {
        assert_eq!(row["tool"], tool.raw());
        assert_eq!(row["kind"], kind);
        assert_eq!(row["family"], family);
        assert_eq!(row["selection"], selection);
        let resource = resources["resources"]
            .as_array()
            .unwrap()
            .iter()
            .find(|resource| resource["id"] == row["baseResource"])
            .unwrap();
        let lf = bytes(&format!("{BASE}/{}", resource["path"].as_str().unwrap()));
        assert_eq!(resource["sha256"], sha(&lf));
        assert_eq!(resource["sizeBytes"], lf.len());
        assert_eq!(lf.len(), count);
        assert!(!lf.contains(&b'\r'));
        assert_eq!(lf.iter().filter(|&&byte| byte == b'\n').count(), pairs);
        let crlf: Vec<_> = lf
            .iter()
            .flat_map(|&byte| {
                if byte == b'\n' {
                    vec![b'\r', b'\n']
                } else {
                    vec![byte]
                }
            })
            .collect();
        assert_eq!(row["lfByteCount"], lf.len());
        assert_eq!(row["crlfByteCount"], crlf.len());
        assert_eq!(row["crlfPairCount"], pairs);
        assert_eq!(row["lfSuffixSha256"], sha(&lf[20..]));
        assert_eq!(row["crlfSuffixSha256"], sha(&crlf[20..]));
        let expected = if tool == TraceTool::Hitrace {
            TraceSelection::CaptureEligible(family)
        } else {
            TraceSelection::ProbeOnly(family)
        };
        if kind == "help" {
            assert_eq!(evaluate_help(tool, &lf, b""), expected);
            assert_eq!(evaluate_help(tool, &crlf, b""), expected);
        } else {
            let lf_tags = evaluate_tag_list(tool, &lf, b"");
            let crlf_tags = evaluate_tag_list(tool, &crlf, b"");
            assert_eq!(lf_tags.0, expected);
            assert_eq!(crlf_tags, lf_tags);
            assert_eq!(crlf_tags.1.len(), 81);
        }
    }
    assert_eq!(
        descriptor["provenance"]["evidenceClass"],
        "repoReadOnlyDiagnostic"
    );
    assert_eq!(descriptor["provenance"]["formalAcceptance"], false);
    assert_eq!(descriptor["provenance"]["hardwarePass"], false);
    let profile = String::from_utf8(bytes("openspec/integrations/openharmony/profile.md")).unwrap();
    let lock = String::from_utf8(bytes(
        "openspec/integrations/INTEGRATION-PROFILES.lock.yaml",
    ))
    .unwrap();
    for text in [profile, lock] {
        assert!(text.contains("OPENHARMONY-TRACE-REPRESENTATIONS"));
        assert!(text.contains(DESCRIPTOR));
        assert!(text.contains(DESCRIPTOR_SHA));
    }
}
