//! Swift `ArkForgeExecutionAuthorityContractTests`, case for case: the issuing
//! half of the adversarial matrix, which must hold before any of ArkForge's
//! own refusals fire. Beyond Swift: ArkForge's own `verify_permit` accepts
//! what this authority signs, and the admission facts encode as ArkForge's
//! canonical CBOR encodes them.
use super::*;
use arkforge_authority_api::{DispatchIntent, PairingEpoch, verify_permit};
use arkforge_ipc::messages::KeyValue;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

const PLAN_DIGEST: [u8; 32] = [0x11; 32];
const DEVICE_FACTS: [u8; 32] = [0x22; 32];

fn secret() -> ControllerPairingSecret {
    ControllerPairingSecret::new(PairingEpoch(4), b"adversarial-matrix-secret".to_vec())
}

fn approved_plan() -> ApprovedPlan {
    ApprovedPlan {
        job_id: "JOB-1".into(),
        plan_id: "PLAN-1".into(),
        plan_sha256: PLAN_DIGEST.to_vec(),
        admitted_device_facts_sha256: DEVICE_FACTS.to_vec(),
        usb_topology: None,
        binding: AuthorityBinding {
            authority_namespace: "arkdeck".into(),
            binding_id: "TGT-1".into(),
            binding_revision: 2,
            stable_identity_digest: vec![0x33; 32],
        },
        controller_session_id: "SESSION-1".into(),
        permit_lifetime_ms: PERMIT_LIFETIME_MS,
    }
}

/// A snapshot the daemon would send, every field matching what the authority
/// approved; each case moves exactly one fact. It carries no raw device
/// facts: Swift's recorded v1 fixture branch.
fn snapshot() -> StepAdmissionSnapshot {
    StepAdmissionSnapshot {
        job_id: "JOB-1".into(),
        plan_id: "PLAN-1".into(),
        plan_sha256: PLAN_DIGEST.to_vec(),
        step_id: "STEP-WRITE".into(),
        attempt_id: "ATTEMPT-1".into(),
        public_step_sha256: vec![0x44; 32],
        private_action_sha256: vec![0x55; 32],
        effect_set_sha256: vec![0x66; 32],
        admitted_device_facts_sha256: DEVICE_FACTS.to_vec(),
        observed_mode: "loader".into(),
        observed_at_epoch_ms: 1_000_000,
        snapshot_lifetime_ms: 60_000,
        request_id: "ADM-1".into(),
        ..StepAdmissionSnapshot::default()
    }
}

fn with(change: impl FnOnce(&mut StepAdmissionSnapshot)) -> StepAdmissionSnapshot {
    let mut snapshot = snapshot();
    change(&mut snapshot);
    snapshot
}

fn authority_at(now: u64) -> ExecutionAuthority {
    ExecutionAuthority::new(approved_plan(), secret(), move || now)
}

fn authority() -> ExecutionAuthority {
    authority_at(1_000_100)
}

fn signed(decision: Decision) -> SignedPermit {
    match decision {
        Decision::Sign(permit) => permit,
        Decision::Refuse(refusal) => panic!("expected a signature, got {refusal}"),
    }
}

fn refused(decision: Decision) -> Refusal {
    match decision {
        Decision::Refuse(refusal) => refusal,
        Decision::Sign(permit) => panic!("expected a refusal, got {}", permit.permit_id),
    }
}

/// A raw live-daemon admission in Loader at `topology`, whose admitted facts
/// digest is this authority's recomputation of its own facts.
fn raw_loader_snapshot(step: &str, attempt: &str, topology: &str) -> StepAdmissionSnapshot {
    let mut raw = with(|snapshot| {
        snapshot.step_id = step.into();
        snapshot.attempt_id = attempt.into();
        snapshot.observed_mode = "rockusb-loader".into();
        snapshot.topology_sha256 = topology_bytes(topology).unwrap();
        snapshot.descriptor_sha256 = vec![0x77; 32];
        snapshot.serial_sha256 = vec![0x88; 32];
        snapshot.serial_evidence_kind = "descriptor".into();
        snapshot.identity_strength = "serialAndTopology".into();
        snapshot.transport_session_sha256 = vec![0x99; 32];
    });
    raw.admitted_device_facts_sha256 = device_facts_digest(&raw);
    raw
}

// MARK: the happy path, so the refusals below mean something

#[test]
fn a_matching_admission_is_signed_once() {
    let mut authority = authority();
    let permit = signed(authority.admit(&snapshot()));
    assert_eq!(permit.permit_id, "PERMIT-JOB-1-STEP-WRITE-ATTEMPT-1");
    assert_eq!(permit.pairing_epoch, 4);
    assert_eq!(permit.integrity_tag.len(), 32);
    assert_eq!(authority.issued_count(), 1);
    assert_eq!(
        authority.issued_permit("PERMIT-JOB-1-STEP-WRITE-ATTEMPT-1"),
        Some(&permit)
    );
}

/// The managed-control receipt publishes `Loader` while ArkForge's live
/// admission publishes `rockusb-loader`: one measured lineage, one key. This
/// exact case reached a real DAYU200 Loader on 2026-08-20 and was refused
/// before STEP-002 when the spellings were kept apart.
#[test]
fn a_loader_control_receipt_extends_the_exact_loader_admission_lineage() {
    let mut authority = authority();
    authority.record_managed_control_facts(&BTreeMap::from([
        ("mode".to_owned(), "Loader".to_owned()),
        ("usbTopology".to_owned(), "17956864".to_owned()),
    ]));
    signed(authority.admit(&raw_loader_snapshot("STEP-002", "ATTEMPT-2", "17956864")));
    // Another topology is not the lineage the receipt extended.
    let elsewhere = raw_loader_snapshot("STEP-003", "ATTEMPT-1", "17956865");
    assert_eq!(
        refused(authority.admit(&elsewhere)),
        Refusal::DeviceFactsMismatch
    );
}

#[test]
fn a_plan_materialized_while_already_in_loader_seeds_its_initial_mode_lineage() {
    let plan = ApprovedPlan {
        usb_topology: Some("17956864".into()),
        ..approved_plan()
    };
    let mut authority = ExecutionAuthority::new(plan.clone(), secret(), || 1_000_100);
    let admission = raw_loader_snapshot("STEP-001", "ATTEMPT-1", "17956864");
    // Only the normal mode is approved until the materialized mode is.
    assert_eq!(
        refused(authority.admit(&admission)),
        Refusal::DeviceFactsMismatch
    );
    authority.record_materialized_observation_mode("rockusb-loader");
    signed(authority.admit(&admission));
}

#[test]
fn every_permit_is_single_use_and_time_bounded() {
    let permit = signed(authority().admit(&snapshot()));
    let decoded = StepPermit::from_canonical_bytes(&permit.signing_body).unwrap();
    assert!(decoded.single_use);
    assert_eq!(decoded.issued_at_epoch_ms, 1_000_100);
    assert_eq!(decoded.expires_at_epoch_ms, 1_000_100 + PERMIT_LIFETIME_MS);
    // Swift's byte check: `singleUse` is followed by CBOR `true`.
    let key = b"singleUse";
    let at = permit
        .signing_body
        .windows(key.len())
        .position(|window| window == key)
        .unwrap();
    assert_eq!(permit.signing_body[at + key.len()], 0xf5);
}

// MARK: the matrix — ways an admission must not be signed

#[test]
fn an_admission_for_another_job_is_refused() {
    let refusal = refused(authority().admit(&with(|snapshot| snapshot.job_id = "JOB-2".into())));
    assert_eq!(
        refusal,
        Refusal::UnknownJob {
            asked: "JOB-2".into(),
            approved: "JOB-1".into(),
        }
    );
    assert_eq!(
        refusal.to_string(),
        "admission names job JOB-2; this authority approved JOB-1"
    );
}

#[test]
fn a_plan_digest_this_authority_did_not_approve_is_refused() {
    let refusal =
        refused(authority().admit(&with(|snapshot| snapshot.plan_sha256 = vec![0xee; 32])));
    assert_eq!(refusal, Refusal::PlanMismatch);
    assert_eq!(
        refusal.to_string(),
        "the admission's plan digest is not the plan this authority approved"
    );
    assert_eq!(
        refused(authority().admit(&with(|snapshot| snapshot.plan_id = "PLAN-2".into()))),
        Refusal::PlanMismatch
    );
}

#[test]
fn device_facts_from_another_binding_are_refused() {
    let refusal = refused(authority().admit(&with(|snapshot| {
        snapshot.admitted_device_facts_sha256 = vec![0xdd; 32]
    })));
    assert_eq!(refusal, Refusal::DeviceFactsMismatch);
    assert_eq!(
        refusal.to_string(),
        "the admission's device facts are not the binding this authority confirmed; the device \
         under the daemon is not the device that was authorized"
    );
}

/// A live admission whose recomputed facts, session or descriptor do not hold
/// is refused, whatever it claims.
#[test]
fn a_raw_admission_is_recomputed_rather_than_believed() {
    let mut authority = authority();
    authority.record_managed_control_facts(&BTreeMap::from([
        ("mode".to_owned(), "loader".to_owned()),
        ("usbTopology".to_owned(), "17956864".to_owned()),
    ]));
    let good = raw_loader_snapshot("STEP-002", "ATTEMPT-1", "17956864");
    let cases: [fn(&mut StepAdmissionSnapshot); 3] = [
        |snapshot| snapshot.admitted_device_facts_sha256 = vec![0xdd; 32],
        |snapshot| snapshot.transport_session_sha256 = vec![0x99; 31],
        |snapshot| snapshot.malformed_descriptor = true,
    ];
    for change in cases {
        let mut admission = good.clone();
        change(&mut admission);
        assert_eq!(
            refused(authority.admit(&admission)),
            Refusal::DeviceFactsMismatch
        );
    }
    assert_eq!(authority.issued_count(), 0);
    signed(authority.admit(&good));
}

#[test]
fn an_expired_snapshot_is_refused() {
    let refusal = refused(authority_at(1_060_001).admit(&snapshot()));
    assert_eq!(
        refusal,
        Refusal::SnapshotExpired {
            observed_at_epoch_ms: 1_000_000,
            lifetime_ms: 60_000,
            now_epoch_ms: 1_060_001,
        }
    );
    assert_eq!(
        refusal.to_string(),
        "the snapshot was read at 1000000 and lives 60000 ms; it is now 1060001. Signing a \
         stale snapshot authorizes a write against facts that have expired"
    );
    // The last millisecond of a snapshot's life is still fresh.
    signed(authority_at(1_060_000).admit(&snapshot()));
}

#[test]
fn a_snapshot_from_the_future_is_refused_rather_than_treated_as_fresh() {
    let refusal = refused(authority_at(999_999).admit(&snapshot()));
    assert_eq!(
        refusal,
        Refusal::SnapshotFromTheFuture {
            observed_at_epoch_ms: 1_000_000,
            now_epoch_ms: 999_999,
        }
    );
    assert_eq!(
        refusal.to_string(),
        "the snapshot claims to have been read at 1000000, which is after this authority's own \
         clock reads 999999; freshness cannot be judged"
    );
}

#[test]
fn an_admission_with_no_step_identity_is_refused() {
    for admission in [
        with(|snapshot| snapshot.step_id.clear()),
        with(|snapshot| snapshot.attempt_id.clear()),
    ] {
        let refusal = refused(authority().admit(&admission));
        assert_eq!(refusal, Refusal::MissingStepIdentity);
        assert_eq!(
            refusal.to_string(),
            "the admission carries no step or attempt identity"
        );
    }
}

/// Swift has no such refusal: it signs any string, and the daemon's typed
/// ids refuse the permit later. Here an identity ArkForge cannot hold, or a
/// digest that is not 32 bytes, is refused before anything is signed.
#[test]
fn an_admission_that_cannot_form_arkforges_permit_is_refused_unsigned() {
    let mut authority = authority();
    let refusal = refused(authority.admit(&with(|snapshot| {
        snapshot.step_id = "STEP WITH SPACES".into()
    })));
    // The permit id embeds the step id, so it is the first field refused.
    assert!(matches!(&refusal, Refusal::Unsignable(detail) if detail.starts_with("permitId")));
    assert!(refusal.to_string().ends_with("; nothing was signed"));
    let refusal = refused(authority.admit(&with(|snapshot| {
        snapshot.private_action_sha256 = vec![0x55; 31]
    })));
    assert_eq!(
        refusal,
        Refusal::Unsignable("privateActionDigest: 31 bytes, not 32".into())
    );
    assert_eq!(authority.issued_count(), 0);
}

#[test]
fn no_refusal_ever_produces_a_permit() {
    let cases = [
        with(|snapshot| snapshot.job_id = "JOB-2".into()),
        with(|snapshot| snapshot.plan_id = "PLAN-2".into()),
        with(|snapshot| snapshot.plan_sha256 = vec![0xee; 32]),
        with(|snapshot| snapshot.admitted_device_facts_sha256 = vec![0xdd; 32]),
        with(|snapshot| snapshot.step_id.clear()),
        with(|snapshot| snapshot.attempt_id.clear()),
        with(|snapshot| snapshot.observed_at_epoch_ms = 1),
    ];
    let mut authority = authority();
    for admission in &cases {
        refused(authority.admit(admission));
    }
    assert_eq!(authority.issued_count(), 0);
}

// MARK: retransmission replays, never re-derives

#[test]
fn the_same_admission_twice_replays_the_same_bytes() {
    let clock = Arc::new(AtomicU64::new(1_000_100));
    let reader = Arc::clone(&clock);
    let mut authority = ExecutionAuthority::new(approved_plan(), secret(), move || {
        reader.load(Ordering::SeqCst)
    });
    let first = signed(authority.admit(&snapshot()));
    // Time moves: a re-derived permit would carry another issue time.
    clock.store(1_030_000, Ordering::SeqCst);
    let second = signed(authority.admit(&snapshot()));
    assert_eq!(first, second);
    assert_eq!(authority.issued_count(), 1);
}

#[test]
fn a_retransmission_is_answered_even_after_the_snapshot_would_have_expired() {
    let clock = Arc::new(AtomicU64::new(1_000_100));
    let reader = Arc::clone(&clock);
    let mut authority = ExecutionAuthority::new(approved_plan(), secret(), move || {
        reader.load(Ordering::SeqCst)
    });
    let first = signed(authority.admit(&snapshot()));
    clock.store(9_999_999, Ordering::SeqCst);
    assert_eq!(signed(authority.admit(&snapshot())), first);
}

#[test]
fn a_different_attempt_is_a_different_permit() {
    let mut authority = authority();
    let first = signed(authority.admit(&snapshot()));
    let second =
        signed(authority.admit(&with(|snapshot| snapshot.attempt_id = "ATTEMPT-2".into())));
    assert_ne!(first.permit_id, second.permit_id);
    assert_ne!(first.signing_body, second.signing_body);
    assert_eq!(authority.issued_count(), 2);
}

#[test]
fn the_epoch_travels_beside_the_bytes_rather_than_inside_them() {
    let sign_at = |epoch: u64| {
        signed(
            ExecutionAuthority::new(
                approved_plan(),
                ControllerPairingSecret::new(PairingEpoch(epoch), b"s".to_vec()),
                || 1_000_100,
            )
            .admit(&snapshot()),
        )
    };
    let (first, second) = (sign_at(1), sign_at(2));
    assert_eq!(first.signing_body, second.signing_body);
    assert_eq!(
        first.integrity_tag, second.integrity_tag,
        "same secret, same tag"
    );
    assert_ne!(first.pairing_epoch, second.pairing_epoch);
}

// MARK: beyond Swift

/// Once the daemon names its job, the permit binds that name, and an
/// admission for ArkDeck's own job id is another job. A later adoption moves
/// nothing.
#[test]
fn the_daemons_job_is_adopted_once_and_bound() {
    let mut authority = authority();
    authority.adopt_daemon_job("");
    authority.adopt_daemon_job("JOB-000001A0");
    authority.adopt_daemon_job("JOB-OTHER");
    assert_eq!(
        refused(authority.admit(&snapshot())),
        Refusal::UnknownJob {
            asked: "JOB-1".into(),
            approved: "JOB-000001A0".into(),
        }
    );
    let permit = signed(authority.admit(&with(|snapshot| snapshot.job_id = "JOB-000001A0".into())));
    assert_eq!(permit.permit_id, "PERMIT-JOB-000001A0-STEP-WRITE-ATTEMPT-1");
    let decoded = StepPermit::from_canonical_bytes(&permit.signing_body).unwrap();
    assert_eq!(decoded.job_id.as_str(), "JOB-000001A0");
}

/// The daemon's own verification — the tag under the pairing secret, the
/// epoch, the lifetime and every binding field against the dispatch it was
/// asked about — accepts what this authority signs.
#[test]
fn arkforges_own_verification_accepts_the_permit_for_its_dispatch() {
    let permit = signed(authority().admit(&snapshot()));
    let mut decoded = StepPermit::from_canonical_bytes(&permit.signing_body).unwrap();
    decoded.integrity_tag = PermitIntegrityTag {
        epoch: PairingEpoch(permit.pairing_epoch),
        tag: Sha256Digest::from_bytes(permit.integrity_tag.clone().try_into().unwrap()),
    };
    let intent = DispatchIntent {
        controller_session_id: ControllerSessionId::new("SESSION-1").unwrap(),
        job_id: JobId::new("JOB-1").unwrap(),
        plan_id: PlanId::new("PLAN-1").unwrap(),
        plan_digest: Sha256Digest::from_bytes(PLAN_DIGEST),
        step_id: StepId::new("STEP-WRITE").unwrap(),
        attempt_id: AttemptId::new("ATTEMPT-1").unwrap(),
        public_step_digest: Sha256Digest::from_bytes([0x44; 32]),
        private_action_digest: Sha256Digest::from_bytes([0x55; 32]),
        effect_set_digest: Sha256Digest::from_bytes([0x66; 32]),
        authority_binding: AuthorityBindingRef {
            authority_namespace: AuthorityNamespace::new("arkdeck").unwrap(),
            binding_id: OpaqueId::new("TGT-1").unwrap(),
            binding_revision: 2,
            stable_identity_digest: Sha256Digest::from_bytes([0x33; 32]),
        },
        admitted_device_facts_digest: Sha256Digest::from_bytes(DEVICE_FACTS),
        now_epoch_ms: 1_000_200,
    };
    verify_permit(&decoded, &secret(), &intent, false).unwrap();
    // Under another secret the tag does not verify.
    let other = ControllerPairingSecret::new(PairingEpoch(4), b"another-secret".to_vec());
    assert!(verify_permit(&decoded, &other, &intent, false).is_err());
}

/// The admission facts encode exactly as ArkForge's canonical CBOR encodes
/// the daemon's own admission facts map; only the domain prefix is this
/// authority's (F2).
#[test]
fn the_admission_facts_encode_as_arkforges_canonical_cbor() {
    use arkforge_core::CborValue as Theirs;
    let mut raw = raw_loader_snapshot("STEP-002", "ATTEMPT-1", "17956864");
    raw.protocol_identity = vec![
        KeyValue {
            key: "vid".into(),
            value: "2207".into(),
        },
        KeyValue {
            key: "pid".into(),
            value: "350a".into(),
        },
    ];
    for kind in ["descriptor", "absent"] {
        raw.serial_evidence_kind = kind.into();
        let serial = if kind == "absent" {
            Theirs::Null
        } else {
            Theirs::bytes(raw.serial_sha256.clone())
        };
        let theirs = Theirs::map(vec![
            ("mode", Theirs::text(raw.observed_mode.clone())),
            ("topologyDigest", Theirs::bytes(raw.topology_sha256.clone())),
            (
                "descriptorDigest",
                Theirs::bytes(raw.descriptor_sha256.clone()),
            ),
            (
                "serialEvidence",
                Theirs::map(vec![("kind", Theirs::text(kind)), ("digest", serial)]),
            ),
            (
                "protocolIdentity",
                Theirs::array(
                    raw.protocol_identity
                        .iter()
                        .map(|pair| {
                            Theirs::map(vec![
                                ("key", Theirs::text(pair.key.clone())),
                                ("value", Theirs::text(pair.value.clone())),
                            ])
                        })
                        .collect(),
                ),
            ),
            (
                "identityStrength",
                Theirs::text(raw.identity_strength.clone()),
            ),
            (
                "malformedDescriptor",
                Theirs::Bool(raw.malformed_descriptor),
            ),
        ]);
        let mut preimage = DEVICE_FACTS_DOMAIN.to_vec();
        preimage.extend(theirs.to_canonical_bytes().unwrap());
        assert_eq!(
            device_facts_digest(&raw),
            hex_to_bytes(&sha256_hex(&preimage)).unwrap(),
            "{kind}"
        );
    }
}

#[test]
fn the_canonical_mode_is_swifts() {
    for (mode, canonical) in [
        ("normal", "hdc-normal"),
        (" HDC-Normal\n", "hdc-normal"),
        ("Loader", "rockusb-loader"),
        ("updater", "rockusb-loader"),
        ("rockusb-loader", "rockusb-loader"),
        ("MaskROM", "rockusb-maskrom"),
        ("rockusb-maskrom", "rockusb-maskrom"),
        // Anything else is trimmed and kept as it is spelled.
        ("  Recovery\t", "Recovery"),
    ] {
        assert_eq!(canonical_mode(mode), canonical, "{mode:?}");
    }
}
