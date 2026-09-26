//! Swift `ArkForgeManagedControlPort` (`ArkForgeManagedControlPort.swift`):
//! ArkDeck's side of ArkForge's `ManagedDeviceControlPort`.
//!
//! `arkforged` names a semantic action — "put this device in Loader" — and
//! receives back only what this authority observed. It never receives anything
//! that could reach the device directly: ArkDeck keeps HDC, the connect key,
//! the endpoint and the server lifecycle, ArkForge keeps the device mechanics
//! (ArkForge `architecture.md` 9.2). The receipt built here is the only thing
//! ArkForge learns about the device from this side, so everything that must
//! not travel is stopped where the receipt is built, not discovered when the
//! daemon rejects it.

use crate::flash_lane::canonical_facts_digest;
use arkforge_ipc::messages::{FORBIDDEN_CONTROL_RECEIPT_FACTS, SubmitManagedControlReceiptRequest};
/// ArkForge's own messages for what a managed control is asked, re-exported
/// for the performer that answers it (`flash_session::ControlPerformer`),
/// which lives with the Rockchip host outside this crate. Only this crate
/// depends on ArkForge.
pub use arkforge_ipc::messages::{KeyValue, ManagedControlAction, ManagedControlRequest};
use std::collections::BTreeMap;

/// Swift `providerActions(for:)`: the provider actions each semantic action
/// lowers to, in order. `enterUpdater` is five observations rather than one
/// command: accepted, the bound identity disconnected, and exactly one device
/// rebound in Loader mode.
pub fn provider_actions(action: ManagedControlAction) -> &'static [&'static str] {
    match action {
        ManagedControlAction::EnterUpdater => &[
            "observeHDCNormalUSB",
            "enterLoader",
            "waitForHDCDisconnect",
            "waitForLoader",
            "rebindLoader",
        ],
        // In Loader mode there is no HDC; ArkForge resets the board through
        // its native RockUSB backend and ArkDeck watches the bound target
        // come back.
        ManagedControlAction::RebootToNormal => &["waitForBoundHDCReconnect"],
        ManagedControlAction::ReadProductFacts | ManagedControlAction::ReadBuildFacts => {
            &["verifyBoundBuild"]
        }
    }
}

/// Swift `expectedReceiptFacts(for:)`: the facts a successful receipt for
/// this action must carry.
pub fn expected_receipt_facts(action: ManagedControlAction) -> &'static [&'static str] {
    match action {
        ManagedControlAction::EnterUpdater | ManagedControlAction::RebootToNormal => {
            &["mode", "stableIdentitySHA256", "usbTopology"]
        }
        ManagedControlAction::ReadProductFacts => &["const.product.model"],
        ManagedControlAction::ReadBuildFacts => &["const.ohos.fullname"],
    }
}

/// Swift's name of a control action, as `String(describing:)` spells its
/// `ArkForgeManagedControlAction` case.
pub fn action_name(action: ManagedControlAction) -> &'static str {
    match action {
        ManagedControlAction::EnterUpdater => "enterUpdater",
        ManagedControlAction::RebootToNormal => "rebootToNormal",
        ManagedControlAction::ReadProductFacts => "readProductFacts",
        ManagedControlAction::ReadBuildFacts => "readBuildFacts",
    }
}

/// Swift `forbiddenReceiptFacts`: the keys that must never appear in a
/// receipt, ArkForge's own list. The daemon rejects a receipt carrying one
/// outright, so the list is checked here first.
pub const FORBIDDEN_RECEIPT_FACTS: [&str; 6] = FORBIDDEN_CONTROL_RECEIPT_FACTS;

/// Swift `ReceiptRefusal`: why a receipt must not be sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReceiptRefusal {
    ForbiddenFact(String),
    SuccessWithoutItsFacts {
        action: String,
        missing: Vec<String>,
    },
    EnterUpdaterWithoutFullObservation(Vec<String>),
}

impl std::fmt::Display for ReceiptRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ForbiddenFact(key) => write!(
                f,
                "a receipt carrying `{key}` would hand ArkForge something that reaches the \
                 device directly; architecture.md 9.2 forbids it and the daemon rejects the \
                 whole receipt"
            ),
            Self::SuccessWithoutItsFacts { action, missing } => write!(
                f,
                "{action} claims success without {}; a success whose evidence is absent is a \
                 claim, not an observation",
                missing.join(", ")
            ),
            Self::EnterUpdaterWithoutFullObservation(missing) => write!(
                f,
                "enterUpdater needs the command accepted, the bound identity disconnected, and \
                 exactly one Loader rebind; missing {}. Reporting success on the command alone \
                 records a fact about the message as a fact about the device",
                missing.join(", ")
            ),
        }
    }
}

impl std::error::Error for ReceiptRefusal {}

/// Swift `Observation`: what this authority observed while performing a
/// control action. `accepted: false` does not mean nothing happened — a mode
/// change may have taken effect unobserved, which the daemon records as an
/// unknown outcome; `failure_reason` is where "it definitely did not happen"
/// would have to be argued.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Observation {
    pub accepted: bool,
    /// Swift's `[String: String]`: one value per key, read in the byte order
    /// of the keys.
    pub facts: BTreeMap<String, String>,
    pub evidence_sha256: Vec<u8>,
    pub failure_reason: String,
    /// For `enterUpdater`: which of its observations were actually made.
    pub observed_disconnect: bool,
    pub observed_unique_loader_rebind: bool,
}

/// Swift `receipt(jobID:requestID:action:observation:)`: the receipt to send,
/// or why none may be built.
///
/// A forbidden key refuses the whole receipt, as a forbidden name inside a
/// value does. An accepted receipt must carry the facts that evidence its
/// action, and an accepted `enterUpdater` both of its observations. The
/// evidence digest of an accepted receipt is defined, not supplied: the
/// canonical digest of its own facts, which the daemon recomputes; a refusal
/// made no observation and carries none. Where Swift's dictionary would name
/// one of several forbidden keys in no fixed order, this names the first in
/// the byte order of the keys, and within a value the first in ArkForge's
/// list.
pub fn receipt(
    job_id: &str,
    request_id: &str,
    action: ManagedControlAction,
    observation: &Observation,
) -> Result<SubmitManagedControlReceiptRequest, ReceiptRefusal> {
    if let Some(key) = observation
        .facts
        .keys()
        .find(|key| FORBIDDEN_RECEIPT_FACTS.contains(&key.as_str()))
    {
        return Err(ReceiptRefusal::ForbiddenFact(key.clone()));
    }
    for (key, value) in &observation.facts {
        if let Some(forbidden) = FORBIDDEN_RECEIPT_FACTS
            .iter()
            .find(|forbidden| value.contains(**forbidden))
        {
            return Err(ReceiptRefusal::ForbiddenFact(format!(
                "{key} → {forbidden}"
            )));
        }
    }
    if observation.accepted {
        let missing: Vec<String> = expected_receipt_facts(action)
            .iter()
            .filter(|fact| !observation.facts.contains_key(**fact))
            .map(|fact| (*fact).to_owned())
            .collect();
        if !missing.is_empty() {
            return Err(ReceiptRefusal::SuccessWithoutItsFacts {
                action: action_name(action).to_owned(),
                missing,
            });
        }
        if action == ManagedControlAction::EnterUpdater {
            let mut absent = Vec::new();
            if !observation.observed_disconnect {
                absent.push("the bound identity's disconnect".to_owned());
            }
            if !observation.observed_unique_loader_rebind {
                absent.push("a unique Loader rebind".to_owned());
            }
            if !absent.is_empty() {
                return Err(ReceiptRefusal::EnterUpdaterWithoutFullObservation(absent));
            }
        }
    }
    let facts: Vec<(String, String)> = observation
        .facts
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let evidence_sha256 = if observation.accepted {
        // One value per key: the digest always exists.
        canonical_facts_digest(&facts).unwrap_or_default()
    } else {
        Vec::new()
    };
    Ok(SubmitManagedControlReceiptRequest {
        job_id: job_id.to_owned(),
        request_id: request_id.to_owned(),
        action,
        accepted: observation.accepted,
        facts: facts
            .into_iter()
            .map(|(key, value)| KeyValue { key, value })
            .collect(),
        evidence_sha256,
        failure_reason: observation.failure_reason.clone(),
    })
}

#[cfg(test)]
mod tests {
    //! Swift `ArkForgeManagedControlPortContractTests`, case for case.
    use super::*;
    use arkdeck_contract::sha256_hex;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn facts(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    fn mode_facts() -> BTreeMap<String, String> {
        facts(&[
            ("mode", "Loader"),
            ("stableIdentitySHA256", &"a".repeat(64)),
            ("usbTopology", "0x14200000"),
        ])
    }

    fn observed(facts: BTreeMap<String, String>, disconnect: bool, rebind: bool) -> Observation {
        Observation {
            accepted: true,
            facts,
            evidence_sha256: vec![0x9a; 32],
            failure_reason: String::new(),
            observed_disconnect: disconnect,
            observed_unique_loader_rebind: rebind,
        }
    }

    #[test]
    fn every_control_action_binds_to_the_actions_arkforge_publishes() {
        assert_eq!(
            provider_actions(ManagedControlAction::EnterUpdater),
            [
                "observeHDCNormalUSB",
                "enterLoader",
                "waitForHDCDisconnect",
                "waitForLoader",
                "rebindLoader"
            ]
        );
        assert_eq!(
            provider_actions(ManagedControlAction::RebootToNormal),
            ["waitForBoundHDCReconnect"]
        );
        for action in [
            ManagedControlAction::ReadProductFacts,
            ManagedControlAction::ReadBuildFacts,
        ] {
            assert_eq!(provider_actions(action), ["verifyBoundBuild"]);
        }
        // Every action ArkForge's wire can name is bound, and each to more
        // than nothing; an action this build does not know cannot be decoded
        // at all, so nothing falls through to a default sequence.
        for action in ManagedControlAction::ALL {
            assert!(!provider_actions(action).is_empty(), "{action:?}");
            assert!(!expected_receipt_facts(action).is_empty(), "{action:?}");
        }
    }

    #[test]
    fn entering_the_loader_is_five_observations_not_one_command() {
        let actions = provider_actions(ManagedControlAction::EnterUpdater);
        for required in [
            "enterLoader",
            "waitForHDCDisconnect",
            "waitForLoader",
            "rebindLoader",
        ] {
            assert!(actions.contains(&required), "{required}");
        }
        assert!(actions.len() > 1);
    }

    #[test]
    fn a_forbidden_key_refuses_the_whole_receipt() {
        for forbidden in [
            "connectKey",
            "hdcExecutablePath",
            "hdcEndpoint",
            "argv",
            "shell",
            "serverLifecycleAction",
        ] {
            let mut facts = mode_facts();
            facts.insert(forbidden.to_owned(), "anything".to_owned());
            assert_eq!(
                receipt(
                    "JOB-1",
                    "REQ-1",
                    ManagedControlAction::EnterUpdater,
                    &observed(facts, true, true)
                ),
                Err(ReceiptRefusal::ForbiddenFact(forbidden.to_owned())),
                "{forbidden}"
            );
        }
    }

    #[test]
    fn a_forbidden_name_hidden_in_a_value_is_also_refused() {
        let mut facts = mode_facts();
        facts.insert(
            "detail".to_owned(),
            "retried after the connectKey changed".to_owned(),
        );
        let refusal = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &observed(facts, true, true),
        )
        .unwrap_err();
        assert_eq!(
            refusal,
            ReceiptRefusal::ForbiddenFact("detail → connectKey".to_owned())
        );
        assert_eq!(
            refusal.to_string(),
            "a receipt carrying `detail → connectKey` would hand ArkForge something that \
             reaches the device directly; architecture.md 9.2 forbids it and the daemon \
             rejects the whole receipt"
        );
    }

    #[test]
    fn a_clean_receipt_is_built_with_its_facts_sorted() {
        let built = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &observed(mode_facts(), true, true),
        )
        .unwrap();
        assert_eq!(built.job_id, "JOB-1");
        assert_eq!(built.request_id, "REQ-1");
        assert_eq!(built.action, ManagedControlAction::EnterUpdater);
        assert!(built.accepted);
        assert_eq!(
            built
                .facts
                .iter()
                .map(|fact| fact.key.as_str())
                .collect::<Vec<_>>(),
            ["mode", "stableIdentitySHA256", "usbTopology"]
        );
        // The port defines the evidence rather than relaying the observation's.
        let pairs: Vec<(String, String)> = mode_facts().into_iter().collect();
        assert_eq!(
            built.evidence_sha256,
            canonical_facts_digest(&pairs).unwrap()
        );
        assert!(built.failure_reason.is_empty());
    }

    #[test]
    fn enter_updater_cannot_claim_success_on_the_command_alone() {
        let refusal = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &observed(mode_facts(), false, false),
        )
        .unwrap_err();
        assert_eq!(
            refusal,
            ReceiptRefusal::EnterUpdaterWithoutFullObservation(vec![
                "the bound identity's disconnect".to_owned(),
                "a unique Loader rebind".to_owned(),
            ])
        );
        assert_eq!(
            refusal.to_string(),
            "enterUpdater needs the command accepted, the bound identity disconnected, and \
             exactly one Loader rebind; missing the bound identity's disconnect, a unique \
             Loader rebind. Reporting success on the command alone records a fact about the \
             message as a fact about the device"
        );
        for (disconnect, rebind) in [(true, false), (false, true)] {
            assert!(
                receipt(
                    "JOB-1",
                    "REQ-1",
                    ManagedControlAction::EnterUpdater,
                    &observed(mode_facts(), disconnect, rebind)
                )
                .is_err()
            );
        }
    }

    #[test]
    fn success_without_the_facts_that_would_evidence_it_is_refused() {
        let refusal = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::ReadBuildFacts,
            &observed(BTreeMap::new(), false, false),
        )
        .unwrap_err();
        assert_eq!(
            refusal,
            ReceiptRefusal::SuccessWithoutItsFacts {
                action: "readBuildFacts".to_owned(),
                missing: vec!["const.ohos.fullname".to_owned()],
            }
        );
        assert_eq!(
            refusal.to_string(),
            "readBuildFacts claims success without const.ohos.fullname; a success whose \
             evidence is absent is a claim, not an observation"
        );
        let built = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::ReadBuildFacts,
            &observed(
                facts(&[("const.ohos.fullname", "OpenHarmony-7.0.0.36")]),
                false,
                false,
            ),
        )
        .unwrap();
        assert_eq!(built.facts[0].value, "OpenHarmony-7.0.0.36");
    }

    #[test]
    fn a_failed_observation_needs_no_facts_and_is_not_a_claim_that_nothing_happened() {
        let built = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &Observation {
                accepted: false,
                evidence_sha256: vec![0x9a; 32],
                failure_reason: "no device rebound within the 15,579 ms window measured in \
                                 AD-020"
                    .to_owned(),
                ..Observation::default()
            },
        )
        .unwrap();
        assert!(!built.accepted);
        assert!(built.facts.is_empty());
        assert!(built.failure_reason.contains("15,579"));
    }

    #[test]
    fn the_forbidden_list_is_arkforges_byte_for_byte() {
        assert_eq!(
            FORBIDDEN_RECEIPT_FACTS,
            [
                "connectKey",
                "hdcExecutablePath",
                "hdcEndpoint",
                "argv",
                "shell",
                "serverLifecycleAction"
            ]
        );
    }

    /// Swift's golden vector, mirrored in `arkforged`'s admission surface
    /// tests: the daemon recomputes this digest before taking an accepted
    /// receipt.
    #[test]
    fn the_canonical_facts_digest_matches_the_daemons_spelling() {
        let pairs = [
            ("mode", "Loader"),
            (
                "stableIdentitySHA256",
                "94a25a89c9c214dc9f8a0cf1b2cb3703a466e132a97fa015dfdbebfc65546f42",
            ),
            ("usbTopology", "17956864"),
        ]
        .map(|(key, value)| (key.to_owned(), value.to_owned()));
        assert_eq!(
            hex(&canonical_facts_digest(&pairs).unwrap()),
            "68c995f4a099a63f61c3226a70e6691889050b767100d991f383c5f09962ad1f"
        );
        assert_eq!(hex(&canonical_facts_digest(&[]).unwrap()), sha256_hex(b""));
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn an_accepted_receipt_carries_the_facts_digest_and_a_refusal_carries_none() {
        let pairs = facts(&[
            ("mode", "Loader"),
            ("stableIdentitySHA256", &"ab".repeat(32)),
            ("usbTopology", "17956864"),
        ]);
        let accepted = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &Observation {
                evidence_sha256: Vec::new(),
                ..observed(pairs.clone(), true, true)
            },
        )
        .unwrap();
        let listed: Vec<(String, String)> = pairs.into_iter().collect();
        assert_eq!(
            accepted.evidence_sha256,
            canonical_facts_digest(&listed).unwrap()
        );
        assert_eq!(accepted.evidence_sha256.len(), 32);
        let refused = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &Observation {
                failure_reason: "the Loader was not observed".to_owned(),
                ..Observation::default()
            },
        )
        .unwrap();
        assert!(refused.evidence_sha256.is_empty());
    }

    /// The receipt the daemon receives is ArkForge's own message: it
    /// round-trips through ArkForge's codec unchanged.
    #[test]
    fn the_receipt_is_arkforges_own_message() {
        let built = receipt(
            "JOB-1",
            "REQ-1",
            ManagedControlAction::EnterUpdater,
            &observed(mode_facts(), true, true),
        )
        .unwrap();
        assert_eq!(
            SubmitManagedControlReceiptRequest::decode(&built.encode()).unwrap(),
            built
        );
    }
}
