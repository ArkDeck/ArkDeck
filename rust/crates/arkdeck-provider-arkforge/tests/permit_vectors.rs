//! The StepPermit vectors ArkDeck publishes
//! (`openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md`),
//! minted through ArkForge's own authority API at the revision this lane
//! pins: the canonical CBOR signing body and the HMAC-SHA256 tag a Rust lane
//! would hand `arkforged` must be the bytes Swift's lane mints today, and the
//! bytes `arkdeck-contract`'s own codec reproduces (`canonical_parity.rs`).

use arkforge_authority_api::authority_side::mint_integrity_tag;
use arkforge_authority_api::{
    ControllerPairingSecret, PairingEpoch, PermitIntegrityTag, StepPermit,
};
use arkforge_core::digest::sha256;
use arkforge_core::ids::{
    AttemptId, ControllerSessionId, JobId, OpaqueId, PermitId, PlanId, StepId,
};
use arkforge_core::{AuthorityBindingRef, AuthorityNamespace};

/// The published vectors' secret and epoch.
const SECRET: &[u8] = b"arkforge-arkdeck-permit-vector-secret";
const EPOCH: PairingEpoch = PairingEpoch(1);

/// `(step, attempt, private action preimage, body SHA-256, tag)`, as the
/// published table lists them.
const VECTORS: [(&str, &str, &str, &str, &str); 3] = [
    (
        "STEP-ENSURE-MODE",
        "ATTEMPT-1",
        "enter-loader",
        "bae9c1e8d669e6850eb967524885bed0632b6adbb9de5fb3bea971250fb5cd51",
        "d0a4dbc07944f6a802a4f157574f89ddc1cca5f9eb89c7b5c26d99884ea37ae0",
    ),
    (
        "STEP-WRITE-SYSTEM",
        "ATTEMPT-1",
        "write-partition:system",
        "fbdfcab7a865c5ae6400ab64594c1780e71a06a47da43ab6232674e1cdaa2d2e",
        "db38ba9d9a8fbac7840a89b6a9434938b25ed18bc357b4f27e39751d21be1523",
    ),
    (
        "STEP-RESET",
        "ATTEMPT-2",
        "reset-device",
        "cea82597e94d8a47092ef11c7ff91af63e6d9a890292f5407eeeab60960d65f8",
        "86805a7585615edaed931ac3ac005e445529ba5de7495292d6fae10e2d9029ec",
    ),
];

fn permit(step: &str, attempt: &str, private_action: &str) -> StepPermit {
    StepPermit {
        permit_id: PermitId::new(format!("PERMIT-{step}")).unwrap(),
        authority_namespace: AuthorityNamespace::new("arkdeck").unwrap(),
        controller_session_id: ControllerSessionId::new("SESSION-VECTOR").unwrap(),
        job_id: JobId::new("JOB-VECTOR").unwrap(),
        plan_id: PlanId::new("PLAN-VECTOR").unwrap(),
        plan_digest: sha256(b"plan-vector"),
        step_id: StepId::new(step).unwrap(),
        attempt_id: AttemptId::new(attempt).unwrap(),
        public_step_digest: sha256(b"public-step-vector"),
        private_action_digest: sha256(private_action.as_bytes()),
        effect_set_digest: sha256(b"effect-set-vector"),
        authority_binding: AuthorityBindingRef {
            authority_namespace: AuthorityNamespace::new("arkdeck").unwrap(),
            binding_id: OpaqueId::new("BINDING-VECTOR").unwrap(),
            binding_revision: 3,
            stable_identity_digest: sha256(b"stable-identity-vector"),
        },
        admitted_device_facts_digest: sha256(b"admitted-facts-vector"),
        issued_at_epoch_ms: 1_770_000_000_000,
        expires_at_epoch_ms: 1_770_000_060_000,
        single_use: true,
        // Not part of the signing body; minted below.
        integrity_tag: PermitIntegrityTag {
            epoch: EPOCH,
            tag: sha256(b""),
        },
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn arkforges_authority_api_mints_the_published_permit_vectors() {
    let secret = ControllerPairingSecret::new(EPOCH, SECRET.to_vec());
    for (step, attempt, preimage, body_sha256, tag) in VECTORS {
        let mut permit = permit(step, attempt, preimage);
        let body = permit.signing_body().unwrap();
        assert_eq!(hex(sha256(&body).as_bytes()), body_sha256, "{step} body");
        permit.integrity_tag = mint_integrity_tag(&permit, &secret).unwrap();
        assert_eq!(permit.integrity_tag.epoch, EPOCH);
        assert_eq!(hex(permit.integrity_tag.tag.as_bytes()), tag, "{step} tag");
        // The body reads back as the permit it encodes, byte for byte.
        let read = StepPermit::from_canonical_bytes(&body).unwrap();
        assert_eq!(read.signing_body().unwrap(), body, "{step} round trip");
    }
}
