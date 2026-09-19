//! Read-only validation of Swift's Target binding and alias history document.
//! This decoder never creates a binding, observation proof, or alias resolution.
use crate::{DecodeError, display_names::target_identifier, format_time::valid_format_timestamp};
use arkdeck_contract::{sha256_hex, strict_json};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct TargetRecord {
    #[serde(rename = "targetID")]
    pub target_id: String,
    #[serde(rename = "stablePhysicalIdentitySHA256")]
    pub identity: String,
    pub binding_revision: u64,
    pub connect_key: String,
    pub tool_version: String,
    #[serde(rename = "adoptedAtUTC")]
    pub adopted_at: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    #[serde(rename = "jobID")]
    job: String,
    #[serde(rename = "intentEventID")]
    event: String,
    #[serde(rename = "stepID")]
    step: String,
    effect: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Resolution {
    #[serde(rename = "resolutionID")]
    id: String,
    #[serde(rename = "aliasTargetID")]
    alias: String,
    #[serde(rename = "aliasStableIdentitySHA256")]
    alias_identity: String,
    #[serde(rename = "aliasBindingRevision")]
    alias_revision: u64,
    #[serde(rename = "canonicalTargetID")]
    canonical: String,
    #[serde(rename = "canonicalStableIdentitySHA256")]
    canonical_identity: String,
    #[serde(rename = "canonicalBindingRevision")]
    canonical_revision: u64,
    #[serde(rename = "routedHDCIdentitySHA256")]
    routed_identity: String,
    #[serde(rename = "routedUSBTopology")]
    topology: String,
    #[serde(rename = "establishingFlashJobID")]
    job: String,
    #[serde(rename = "establishingFlashPlanDigestSHA256")]
    plan: String,
    #[serde(rename = "confirmedStepIDs")]
    steps: Vec<String>,
    #[serde(rename = "coveredUnknownIntents")]
    intents: Vec<Intent>,
    #[serde(rename = "establishedAtUTC")]
    established_at: String,
    #[serde(
        rename = "previousResolutionSHA256",
        skip_serializing_if = "Option::is_none"
    )]
    previous: Option<String>,
    #[serde(rename = "resolutionSHA256")]
    digest: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct TargetDocument {
    #[serde(rename = "schemaVersion")]
    schema: String,
    pub targets: Vec<TargetRecord>,
    #[serde(rename = "aliasResolutions", skip_serializing_if = "Option::is_none")]
    resolutions: Option<Vec<Resolution>>,
}
pub(super) fn sha(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
impl TargetDocument {
    pub fn empty() -> Self {
        Self {
            schema: "1.0.0".into(),
            targets: Vec::new(),
            resolutions: None,
        }
    }
    pub fn active_ids(&self) -> BTreeSet<String> {
        self.targets
            .iter()
            .filter(|t| {
                !self
                    .resolutions
                    .as_deref()
                    .unwrap_or_default()
                    .iter()
                    .any(|r| r.alias == t.target_id)
            })
            .map(|t| t.target_id.clone())
            .collect()
    }
    /// Swift `RuntimeTargetStore.hdcExecutionRoute`: the Target and the
    /// connect key its HDC commands use, or none for a Target never adopted.
    /// A Target without a proven alias uses its adopted key. With one, the
    /// alias Target must be exactly the one the resolution proved (identity,
    /// revision and the digest of its key); then a fresh live observation
    /// (`live`: each candidate's key and state) selects the sole Connected
    /// key of the two, and without one the alias's key is used, as Swift does
    /// before its first observation and for host-only Artifact binding.
    /// Errors are Swift's `BootstrapError`, as Swift interpolates it.
    pub fn hdc_route(
        &self,
        target_id: &str,
        live: Option<&[(String, String)]>,
    ) -> Result<Option<(&TargetRecord, String)>, String> {
        let store = |detail: &str| format!("storeFailure(\"{detail}\")");
        let mut targets = self.targets.iter().filter(|t| t.target_id == target_id);
        let target = match (targets.next(), targets.next()) {
            (_, Some(_)) => return Err(store("HDC execution target is ambiguous")),
            (None, None) => return Ok(None),
            (Some(target), None) => target,
        };
        let mut resolutions = self
            .resolutions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .filter(|r| r.canonical == target_id);
        let resolution = match (resolutions.next(), resolutions.next()) {
            (_, Some(_)) => return Err(store("HDC execution route is ambiguous")),
            (None, None) => return Ok(Some((target, target.connect_key.clone()))),
            (Some(resolution), None) => resolution,
        };
        let mut aliases = self
            .targets
            .iter()
            .filter(|t| t.target_id == resolution.alias);
        let alias = match (aliases.next(), aliases.next()) {
            (Some(alias), None)
                if alias.identity == resolution.alias_identity
                    && alias.binding_revision == resolution.alias_revision
                    && sha256_hex(alias.connect_key.as_bytes()) == resolution.routed_identity =>
            {
                alias
            }
            _ => return Err(store("HDC execution route lacks its proven alias target")),
        };
        let Some(live) = live else {
            return Ok(Some((target, alias.connect_key.clone())));
        };
        let connected: BTreeSet<&str> = live
            .iter()
            .filter(|(key, state)| {
                state == "Connected" && (*key == target.connect_key || *key == alias.connect_key)
            })
            .map(|(key, _)| key.as_str())
            .collect();
        let mut connected = connected.into_iter();
        match (connected.next(), connected.next()) {
            (Some(key), None) => Ok(Some((target, key.to_owned()))),
            (None, _) => Err(format!(
                "observationFailed(\"fresh HDC observation found no Connected proven route for \
                 target {target_id}\")"
            )),
            (Some(_), Some(_)) => Err(format!(
                "observationFailed(\"fresh HDC observation found multiple Connected proven routes \
                 for target {target_id}\")"
            )),
        }
    }
    pub fn candidate_target(&self, key: &str) -> Option<&TargetRecord> {
        let direct = self.targets.iter().find(|t| matches!((crate::canonical_host_text(&t.connect_key),crate::canonical_host_text(key)),(Ok(a),Ok(b)) if a==b))?;
        let id = self
            .resolutions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .find(|r| r.alias == direct.target_id)
            .map_or(direct.target_id.as_str(), |r| r.canonical.as_str());
        self.targets.iter().find(|t| t.target_id == id)
    }
    /// Swift `materializeAdoption`: the Target an adopted identity belongs
    /// to — the canonical Target of an alias, the Target of the same
    /// identity (or its canonical one), or a new Target at revision 1 named
    /// `TGT-` and the identity's first twelve digits — and whether it is new.
    pub fn materialize_adoption(
        &mut self,
        identity: &str,
        connect_key: &str,
        tool_version: &str,
        now: &str,
    ) -> Result<(TargetRecord, bool), String> {
        let resolutions = self.resolutions.as_deref().unwrap_or_default();
        let target = |id: &str| self.targets.iter().find(|t| t.target_id == id).cloned();
        if let Some(canonical) = resolutions
            .iter()
            .find(|r| r.alias_identity == identity || r.routed_identity == identity)
            .and_then(|r| target(&r.canonical))
        {
            return Ok((canonical, false));
        }
        if let Some(existing) = self.targets.iter().find(|t| t.identity == identity) {
            let canonical = resolutions
                .iter()
                .find(|r| r.alias == existing.target_id)
                .and_then(|r| target(&r.canonical));
            return Ok((canonical.unwrap_or_else(|| existing.clone()), false));
        }
        let derived = format!("TGT-{}", identity.get(..12).unwrap_or(identity));
        if let Some(same) = target(&derived) {
            if same.connect_key != connect_key {
                return Err(format!(
                    "storeFailure(\"adopted target {derived} is bound to another connect key\")"
                ));
            }
            return Ok((same, false));
        }
        let record = TargetRecord {
            target_id: derived,
            identity: identity.into(),
            binding_revision: 1,
            connect_key: connect_key.into(),
            tool_version: tool_version.into(),
            adopted_at: now.into(),
        };
        self.targets.push(record.clone());
        Ok((record, true))
    }
    /// The document as Swift's `JSONEncoder` writes it: sorted keys, pretty
    /// printed, no trailing newline.
    pub fn encode(&self) -> Result<Vec<u8>, DecodeError> {
        let value = serde_json::to_value(self).map_err(|_| DecodeError::Shape)?;
        crate::session_json::encode_pretty(&value).map_err(|_| DecodeError::Shape)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        if bytes.is_empty() || bytes.len() > 4 * 1024 * 1024 {
            return Err(DecodeError::Size);
        }
        let raw = strict_json(bytes).map_err(|_| DecodeError::Shape)?;
        let doc: Self = serde_json::from_value(raw.clone()).map_err(|_| DecodeError::Shape)?;
        if serde_json::to_value(&doc).map_err(|_| DecodeError::Shape)? != raw
            || doc.schema != "1.0.0"
            || doc.targets.len() > 4096
            || doc.resolutions.as_ref().is_some_and(|r| r.len() > 4096)
        {
            return Err(DecodeError::Shape);
        }
        let mut target_ids = BTreeSet::new();
        let mut connect_keys = BTreeSet::new();
        for t in &doc.targets {
            if !target_identifier(&t.target_id)
                || !target_ids.insert(t.target_id.as_str())
                || !connect_keys.insert(crate::canonical_host_text(&t.connect_key)?)
                || !sha(&t.identity)
                || !(1..=i64::MAX as u64).contains(&t.binding_revision)
                || !(1..=1024).contains(&t.connect_key.len())
                || !crate::valid_host_text(&t.connect_key, true, false)
                || t.tool_version.len() > 4096
                || !valid_format_timestamp(&t.adopted_at)
            {
                return Err(DecodeError::Shape);
            }
        }
        let mut aliases = BTreeSet::new();
        let mut jobs = BTreeSet::new();
        let mut intents = BTreeSet::new();
        let mut previous = None;
        let required = [
            "enter-loader-mode",
            "flash-partitions",
            "verify-flash-readback",
            "reboot-device",
            "wait-for-hdc",
            "rebind-and-verify-build",
        ];
        for r in doc.resolutions.as_deref().unwrap_or_default() {
            let alias = doc
                .targets
                .iter()
                .find(|t| t.target_id == r.alias)
                .ok_or(DecodeError::Shape)?;
            let canonical = doc
                .targets
                .iter()
                .find(|t| t.target_id == r.canonical)
                .ok_or(DecodeError::Shape)?;
            let steps: BTreeSet<_> = r.steps.iter().map(String::as_str).collect();
            let seed = sha256_hex(format!("{}\n{}\n{}", r.alias, r.canonical, r.job).as_bytes());
            if r.alias == r.canonical
                || alias.identity != r.alias_identity
                || alias.binding_revision != r.alias_revision
                || canonical.identity != r.canonical_identity
                || canonical.binding_revision != r.canonical_revision
                || r.alias_identity != r.routed_identity
                || sha256_hex(alias.connect_key.as_bytes()) != r.routed_identity
                || !sha(&r.plan)
                || r.job.is_empty()
                || r.topology.is_empty()
                || !r.topology.bytes().all(|b| b.is_ascii_digit())
                || steps.len() != r.steps.len()
                || !required.iter().all(|s| steps.contains(s))
                || !valid_format_timestamp(&r.established_at)
                || !aliases.insert(r.alias.as_str())
                || !jobs.insert(r.job.as_str())
                || r.id != format!("target-alias-resolution-{}", &seed[..32])
                || r.previous.as_deref() != previous
            {
                return Err(DecodeError::Shape);
            }
            for i in &r.intents {
                if i.job.is_empty()
                    || i.event.is_empty()
                    || i.step != "enter-loader-mode"
                    || i.effect != "deviceMutation"
                    || !intents.insert((&i.job, &i.event))
                {
                    return Err(DecodeError::Shape);
                }
            }
            let mut material = serde_json::to_value(r).map_err(|_| DecodeError::Shape)?;
            material
                .as_object_mut()
                .ok_or(DecodeError::Shape)?
                .remove("resolutionSHA256");
            // All field names are ASCII. Value serializes sorted keys without slash escaping,
            // matching CanonicalJSONEncoders.canonical() used by the Swift owner.
            if sha256_hex(&serde_json::to_vec(&material).map_err(|_| DecodeError::Shape)?)
                != r.digest
            {
                return Err(DecodeError::Shape);
            }
            previous = Some(&r.digest);
        }
        if doc
            .resolutions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .any(|r| aliases.contains(r.canonical.as_str()))
        {
            return Err(DecodeError::Shape);
        }
        Ok(doc)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    fn fixture() -> Value {
        let identity = sha256_hex(b"alias-address");
        let mut doc = json!({"schemaVersion":"1.0.0","targets":[{"targetID":"target-alias","stablePhysicalIdentitySHA256":identity,"bindingRevision":1,"connectKey":"alias-address","toolVersion":"fixture","adoptedAtUTC":"2026-09-12T00:00:00Z"},{"targetID":"target-main","stablePhysicalIdentitySHA256":"b".repeat(64),"bindingRevision":2,"connectKey":"main-address","toolVersion":"fixture","adoptedAtUTC":"2026-09-12T00:00:00Z"}],"aliasResolutions":[]});
        let seed = sha256_hex(b"target-alias\ntarget-main\njob-fixture");
        let mut resolution = json!({"resolutionID":format!("target-alias-resolution-{}",&seed[..32]),"aliasTargetID":"target-alias","aliasStableIdentitySHA256":identity,"aliasBindingRevision":1,"canonicalTargetID":"target-main","canonicalStableIdentitySHA256":"b".repeat(64),"canonicalBindingRevision":2,"routedHDCIdentitySHA256":identity,"routedUSBTopology":"100","establishingFlashJobID":"job-fixture","establishingFlashPlanDigestSHA256":"c".repeat(64),"confirmedStepIDs":["enter-loader-mode","flash-partitions","verify-flash-readback","reboot-device","wait-for-hdc","rebind-and-verify-build"],"coveredUnknownIntents":[{"jobID":"job-unknown","intentEventID":"intent-fixture","stepID":"enter-loader-mode","effect":"deviceMutation"}],"establishedAtUTC":"2026-09-12T00:00:00Z"});
        resolution["resolutionSHA256"] =
            json!(sha256_hex(&serde_json::to_vec(&resolution).unwrap()));
        doc["aliasResolutions"] = json!([resolution]);
        doc
    }
    #[test]
    fn complete_alias_history_selects_only_canonical_and_does_not_infer_routes() {
        let doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
        assert_eq!(doc.active_ids(), BTreeSet::from(["target-main".into()]));
        assert_eq!(
            doc.candidate_target("alias-address").unwrap().target_id,
            "target-main"
        );
    }
    fn key(
        doc: &TargetDocument,
        target: &str,
        live: Option<&[(&str, &str)]>,
    ) -> Result<Option<String>, String> {
        let live: Option<Vec<(String, String)>> = live.map(|rows| {
            rows.iter()
                .map(|(key, state)| (key.to_string(), state.to_string()))
                .collect()
        });
        doc.hdc_route(target, live.as_deref())
            .map(|route| route.map(|(record, key)| format!("{}@{key}", record.target_id)))
    }
    /// Swift `testProvenAliasResolutionUsesOnlyFreshConnectedOwnedRouteAndPreservesHistory`.
    #[test]
    fn a_proven_alias_routes_the_canonical_target_as_swift_does() {
        let doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
        let routed = |live| key(&doc, "target-main", live);
        // Before any fresh observation: the proven alias's address.
        assert_eq!(routed(None), Ok(Some("target-main@alias-address".into())));
        // A fresh unique observation wins, whichever of the two it shows.
        assert_eq!(
            routed(Some(&[("main-address", "Connected")])),
            Ok(Some("target-main@main-address".into()))
        );
        assert_eq!(
            routed(Some(&[
                ("alias-address", "Connected"),
                ("elsewhere", "Connected")
            ])),
            Ok(Some("target-main@alias-address".into()))
        );
        let none = "observationFailed(\"fresh HDC observation found no Connected proven route for \
                    target target-main\")";
        for live in [
            &[("main-address", "Offline"), ("alias-address", "Offline")][..],
            &[("elsewhere", "Connected")][..],
            &[][..],
        ] {
            assert_eq!(routed(Some(live)), Err(none.into()), "{live:?}");
        }
        assert_eq!(
            routed(Some(&[
                ("main-address", "Connected"),
                ("alias-address", "Connected")
            ])),
            Err(
                "observationFailed(\"fresh HDC observation found multiple Connected proven \
                 routes for target target-main\")"
                    .into()
            )
        );
        // A Target without an alias of its own keeps its adopted key; one
        // never adopted has no route.
        assert_eq!(
            key(&doc, "target-alias", Some(&[])),
            Ok(Some("target-alias@alias-address".into()))
        );
        assert_eq!(key(&doc, "target-other", None), Ok(None));
    }
    #[test]
    fn an_alias_target_the_resolution_did_not_prove_fails_closed() {
        let lacks =
            Err("storeFailure(\"HDC execution route lacks its proven alias target\")".to_owned());
        for drift in ["connectKey", "identity", "revision"] {
            let mut doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
            let alias = &mut doc.targets[0];
            match drift {
                "connectKey" => alias.connect_key = "moved-address".into(),
                "identity" => alias.identity = "d".repeat(64),
                _ => alias.binding_revision = 9,
            }
            assert_eq!(key(&doc, "target-main", None), lacks, "{drift}");
        }
        let mut doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
        doc.targets.remove(0);
        assert_eq!(key(&doc, "target-main", None), lacks);
        let mut doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
        let second: Resolution =
            serde_json::from_value(fixture()["aliasResolutions"][0].clone()).unwrap();
        doc.resolutions.as_mut().unwrap().push(second);
        assert_eq!(
            key(&doc, "target-main", None),
            Err("storeFailure(\"HDC execution route is ambiguous\")".into())
        );
        let mut doc = TargetDocument::decode(&serde_json::to_vec(&fixture()).unwrap()).unwrap();
        let duplicate = doc.targets[1].clone();
        doc.targets.push(duplicate);
        assert_eq!(
            key(&doc, "target-main", None),
            Err("storeFailure(\"HDC execution target is ambiguous\")".into())
        );
    }
    #[test]
    fn corrupted_alias_proof_or_duplicate_binding_fails_closed() {
        for field in [
            "canonicalBindingRevision",
            "routedUSBTopology",
            "resolutionSHA256",
            "previousResolutionSHA256",
        ] {
            let mut v = fixture();
            v["aliasResolutions"][0][field] = json!("changed");
            assert!(TargetDocument::decode(&serde_json::to_vec(&v).unwrap()).is_err());
        }
        let mut v = fixture();
        let duplicate = v["targets"][0].clone();
        v["targets"].as_array_mut().unwrap().push(duplicate);
        assert!(TargetDocument::decode(&serde_json::to_vec(&v).unwrap()).is_err());
    }
}
