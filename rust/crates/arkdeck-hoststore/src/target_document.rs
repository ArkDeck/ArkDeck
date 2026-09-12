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
    /// A canonical HDC route with a proven alias also needs the live route
    /// observation owner. Import must not substitute the presentation digest.
    pub fn has_hdc_alias(&self, target_id: &str) -> bool {
        self.resolutions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .any(|r| r.canonical == target_id)
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
