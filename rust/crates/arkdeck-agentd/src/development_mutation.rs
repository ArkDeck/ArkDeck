//! The isolated owner's development mutation authority: the state root a
//! device mutation proves its continuity against.
//!
//! A device mutation is admitted only where `RuntimeStateContinuity` can be
//! proved (`arkdeck_hoststore` `mutation_state_continuity`), and that proof is
//! anchored at the Runtime's own state root: the installed
//! `Library/Application Support/ArkDeck/Agentd`. An isolated development root
//! is not that root, so every device mutation there was refused, whatever the
//! caller held. The GJ-1 preflight found it, and M2's real-device acceptance
//! needs it.
//!
//! The maintainer's decision of 2026-09-20 handles it as the GJ-1 opt-in of
//! 2026-09-19 did (option A): the isolated owner may anchor that proof at its
//! own development root, and only when the caller acknowledges the authority
//! ([`ACKNOWLEDGMENT`]) and the owner runs its development HDC as the managed
//! server. What the owner then proves about a real device is development-root
//! evidence, never `REAL_DEVICE_PASS`, and the dashboard's Golden Journey
//! count does not move. The standalone daemon and the facade never read the
//! acknowledgment: their authority stays the installed Runtime's, and the
//! acknowledgment is refused there before anything is served.
//!
//! Nothing else about the proof changes. Anchored at the development root, it
//! still refuses a root beside recorded authorization usage, a Job history
//! that is not read-only, and an unsafe, foreign or unreadable Session root,
//! and a device mutation still needs its capability and its device hold.
use std::ffi::OsStr;

/// Names the caller's acknowledgment that this isolated owner may prove its
/// mutation state against its own development root; its one value is
/// `acknowledged`.
pub(crate) const ACKNOWLEDGMENT: &str = "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY";

/// The acknowledgment names exactly one composition.
const ACKNOWLEDGED_ONLY: &str = "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY is acknowledged only \
                                 with an isolated development state root whose development HDC \
                                 the owner starts as its managed server";

/// Whether the acknowledgment's value, if one is set, acknowledges.
pub(crate) fn acknowledged(value: Option<&OsStr>) -> Result<bool, String> {
    match value {
        None => Ok(false),
        Some(value) if value == "acknowledged" => Ok(true),
        Some(_) => Err(format!("{ACKNOWLEDGMENT} accepts only acknowledged")),
    }
}

/// Whether the owner anchors the mutation state proof at its development
/// root: `development` when a development state root is composed, `managed`
/// when the owner starts its development HDC as the managed server, and
/// `acknowledged` when the caller acknowledges the authority. Without the
/// acknowledgment nothing changes and the installed Runtime's root stays the
/// anchor, which an isolated root can never match; the acknowledgment is
/// refused in every other composition, so that it never stands unused in a
/// configuration.
pub(crate) fn admit(
    development: bool,
    managed: bool,
    acknowledged: bool,
) -> Result<bool, &'static str> {
    if !acknowledged {
        return Ok(false);
    }
    if development && managed {
        Ok(true)
    } else {
        Err(ACKNOWLEDGED_ONLY)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_development_authority_is_taken_only_as_the_acknowledgment_names_it() {
        // (development, managed, acknowledged) and the answer.
        for (composition, expected) in [
            // Without the acknowledgment every composition is as before.
            ((true, true, false), Ok(false)),
            ((true, false, false), Ok(false)),
            ((false, false, false), Ok(false)),
            // The one composition the acknowledgment names.
            ((true, true, true), Ok(true)),
            // Every other composition refuses it: no managed server, no
            // development root, neither.
            ((true, false, true), Err(ACKNOWLEDGED_ONLY)),
            ((false, true, true), Err(ACKNOWLEDGED_ONLY)),
            ((false, false, true), Err(ACKNOWLEDGED_ONLY)),
        ] {
            let (development, managed, acknowledged) = composition;
            assert_eq!(
                admit(development, managed, acknowledged),
                expected,
                "{composition:?}"
            );
        }
    }

    #[test]
    fn the_acknowledgment_has_one_value() {
        assert_eq!(acknowledged(None), Ok(false));
        assert_eq!(acknowledged(Some(OsStr::new("acknowledged"))), Ok(true));
        for value in ["", "yes", "true", "1", "Acknowledged", "acknowledged "] {
            assert_eq!(
                acknowledged(Some(OsStr::new(value))),
                Err("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY accepts only acknowledged".to_owned()),
                "{value:?}"
            );
        }
    }
}
