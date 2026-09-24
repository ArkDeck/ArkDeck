//! Swift's Target binding and alias history document: its validation, and
//! the changes Swift's Runtime makes to it — an adoption, a binding lineage
//! advance, and an alias resolution appended only from a draft proven by
//! terminal Flash history. Nothing here creates a binding or an observation
//! proof.
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
/// Swift's resolution digest: its material — every member but the digest
/// itself — as `CanonicalJSONEncoders.canonical()` encodes it. All member
/// names are ASCII, and a `Value` serializes its keys sorted and its slashes
/// unescaped, as that encoder does.
fn resolution_digest(resolution: &Resolution) -> String {
    let mut material = serde_json::to_value(resolution).expect("a resolution always encodes");
    if let Some(members) = material.as_object_mut() {
        members.remove("resolutionSHA256");
    }
    sha256_hex(&serde_json::to_vec(&material).expect("a value always encodes"))
}
/// Swift `RuntimeTargetAliasResolutionDraft`: every member of a proven alias
/// relation but its identity, chain link and digest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AliasResolutionDraft {
    pub(crate) alias: String,
    pub(crate) alias_identity: String,
    pub(crate) alias_revision: u64,
    pub(crate) canonical: String,
    pub(crate) canonical_identity: String,
    pub(crate) canonical_revision: u64,
    pub(crate) routed_identity: String,
    pub(crate) topology: String,
    pub(crate) job: String,
    pub(crate) plan: String,
    pub(crate) steps: Vec<String>,
    /// Each covered unknown intent: its Job, intent event, step and effect.
    pub(crate) intents: Vec<(String, String, String, String)>,
    pub(crate) established_at: String,
}
/// What a start-up line names of an alias relation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AliasResolutionName {
    pub(crate) resolution_id: String,
    pub(crate) alias: String,
    pub(crate) canonical: String,
}
impl Resolution {
    fn draft(&self) -> AliasResolutionDraft {
        AliasResolutionDraft {
            alias: self.alias.clone(),
            alias_identity: self.alias_identity.clone(),
            alias_revision: self.alias_revision,
            canonical: self.canonical.clone(),
            canonical_identity: self.canonical_identity.clone(),
            canonical_revision: self.canonical_revision,
            routed_identity: self.routed_identity.clone(),
            topology: self.topology.clone(),
            job: self.job.clone(),
            plan: self.plan.clone(),
            steps: self.steps.clone(),
            intents: self
                .intents
                .iter()
                .map(|i| {
                    (
                        i.job.clone(),
                        i.event.clone(),
                        i.step.clone(),
                        i.effect.clone(),
                    )
                })
                .collect(),
            established_at: self.established_at.clone(),
        }
    }
    fn name(&self) -> AliasResolutionName {
        AliasResolutionName {
            resolution_id: self.id.clone(),
            alias: self.alias.clone(),
            canonical: self.canonical.clone(),
        }
    }
}
/// Swift `resolutionID(for:)`: derived from the two Targets and the Flash
/// that established the relation.
fn resolution_id(alias: &str, canonical: &str, job: &str) -> String {
    let seed = sha256_hex(format!("{alias}\n{canonical}\n{job}").as_bytes());
    format!("target-alias-resolution-{}", &seed[..32])
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
    /// Swift `RuntimeTargetStore.hasConflictingHDCAliasOwner`'s decision over
    /// this document: whether a Target other than `canonical` holds the
    /// post-flash alias's connect key or identity without the proven alias
    /// resolution that names exactly it, the canonical Target at their
    /// revisions and that identity. `None` when the canonical Target is
    /// missing or not one of a kind.
    pub fn has_conflicting_hdc_alias_owner(
        &self,
        canonical: &str,
        connect_key: &str,
        identity: &str,
    ) -> Option<bool> {
        let canonicals: Vec<&TargetRecord> = self
            .targets
            .iter()
            .filter(|target| target.target_id == canonical)
            .collect();
        let [owner] = canonicals.as_slice() else {
            return None;
        };
        let resolutions = self.resolutions.as_deref().unwrap_or_default();
        Some(
            self.targets
                .iter()
                .filter(|target| {
                    target.target_id != canonical
                        && (target.connect_key == connect_key || target.identity == identity)
                })
                .any(|conflict| {
                    !resolutions.iter().any(|resolution| {
                        resolution.alias == conflict.target_id
                            && resolution.alias_identity == conflict.identity
                            && resolution.alias_revision == conflict.binding_revision
                            && resolution.canonical == canonical
                            && resolution.canonical_identity == owner.identity
                            && resolution.canonical_revision == owner.binding_revision
                            && resolution.routed_identity == identity
                    })
                }),
        )
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
    /// The Target whose mutation lane a request naming `target_id` runs in:
    /// the canonical Target a proven alias resolution merged it into — the
    /// same device, whose own route may use the alias's key — else the named
    /// Target itself, adopted or not. A chain of resolutions is followed to
    /// its end; one that comes back on itself names no lane.
    pub fn mutation_lane_target(&self, target_id: &str) -> Result<String, String> {
        let resolutions = self.resolutions.as_deref().unwrap_or_default();
        let mut current = target_id;
        let mut followed = BTreeSet::new();
        while let Some(resolution) = resolutions.iter().find(|r| r.alias == current) {
            if !followed.insert(current) {
                return Err(format!(
                    "the alias resolutions of target {target_id} form a cycle"
                ));
            }
            current = &resolution.canonical;
        }
        Ok(current.to_owned())
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
    /// Swift `RuntimeTargetStore.advanceBindingLineage(_:)` over this
    /// document: one adopted Target carried across a strictly adjacent,
    /// proven binding lineage edge, keeping its identity, connect key and
    /// adoption, with the alias resolutions naming it carried along; and
    /// whether that changed the document. The exact current edge is
    /// idempotent; a missing, ambiguous, colliding or skipped lineage refuses
    /// with Swift's `storeFailure` and changes nothing.
    pub fn advance_binding_lineage(
        &mut self,
        advance: &crate::rockchip_binding::LineageAdvance,
    ) -> Result<(TargetRecord, bool), String> {
        let failure = |detail: &str| format!("storeFailure(\"{detail}\")");
        let (previous, current) = (
            advance.previous_identity_sha256.as_str(),
            advance.current_identity_sha256.as_str(),
        );
        let revisions = u64::try_from(advance.previous_revision)
            .ok()
            .zip(u64::try_from(advance.current_revision).ok());
        let Some((previous_revision, current_revision)) =
            revisions.filter(|(from, to)| *from > 0 && from.checked_add(1) == Some(*to))
        else {
            return Err(failure("invalid target binding lineage advance"));
        };
        if !sha(previous) || !sha(current) || previous == current {
            return Err(failure("invalid target binding lineage advance"));
        }
        let current_matches: Vec<usize> = (0..self.targets.len())
            .filter(|&index| {
                self.targets[index].identity == current
                    && self.targets[index].binding_revision == current_revision
            })
            .collect();
        let previous_matches: Vec<usize> = (0..self.targets.len())
            .filter(|&index| self.targets[index].identity == previous)
            .collect();
        if let [index] = current_matches.as_slice() {
            if !previous_matches.is_empty()
                || self
                    .targets
                    .iter()
                    .filter(|t| t.identity == current)
                    .count()
                    != 1
            {
                return Err(failure("ambiguous completed target binding lineage"));
            }
            return Ok((self.targets[*index].clone(), false));
        }
        if !current_matches.is_empty() {
            return Err(failure("ambiguous current target binding lineage"));
        }
        if self.targets.iter().any(|t| t.identity == current) {
            return Err(failure(
                "target binding lineage collides with a durable record",
            ));
        }
        let [index] = previous_matches.as_slice() else {
            return Err(failure(
                "previous target binding lineage is missing or ambiguous",
            ));
        };
        if self.targets[*index].binding_revision != previous_revision {
            return Err(failure(
                "previous target binding lineage is missing or ambiguous",
            ));
        }
        let target = &mut self.targets[*index];
        target.identity = current.into();
        target.binding_revision = current_revision;
        let advanced = target.clone();
        self.carry_alias_resolutions_forward(&advanced.target_id, current, current_revision);
        Ok((advanced, true))
    }
    /// Swift `carryAliasResolutionsForward`: an alias resolution names a
    /// relation between two identities, not two revisions, so a canonical
    /// Target's advance moves every resolution naming it to its new identity
    /// and revision, and the chain is digested again from its start —
    /// otherwise the advanced document would not decode.
    fn carry_alias_resolutions_forward(&mut self, canonical: &str, identity: &str, revision: u64) {
        let Some(resolutions) = self.resolutions.as_mut() else {
            return;
        };
        if !resolutions.iter().any(|r| r.canonical == canonical) {
            return;
        }
        let mut chain: Option<String> = None;
        for resolution in resolutions.iter_mut() {
            if resolution.canonical == canonical {
                resolution.canonical_identity = identity.into();
                resolution.canonical_revision = revision;
            }
            resolution.id =
                resolution_id(&resolution.alias, &resolution.canonical, &resolution.job);
            resolution.previous = chain.take();
            resolution.digest = resolution_digest(resolution);
            chain = Some(resolution.digest.clone());
        }
    }
    /// The relation `ProductRockchipTargetAliasReconciler` reuses: one whose
    /// every identity-bearing member still matches, whichever Flash later
    /// republished the route.
    pub(crate) fn matching_alias_resolution(
        &self,
        draft: &AliasResolutionDraft,
    ) -> Option<AliasResolutionName> {
        self.resolutions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .find(|r| {
                r.alias == draft.alias
                    && r.alias_identity == draft.alias_identity
                    && r.alias_revision == draft.alias_revision
                    && r.canonical == draft.canonical
                    && r.canonical_identity == draft.canonical_identity
                    && r.canonical_revision == draft.canonical_revision
                    && r.routed_identity == draft.routed_identity
                    && r.topology == draft.topology
            })
            .map(Resolution::name)
    }
    /// Swift `RuntimeTargetStore.appendAliasResolution(_:)` over this
    /// document: the proven relation appended to the chain, digested as the
    /// store digests it; the exact same relation already there is answered
    /// as it is; a different one, a chain or a reused proof refuses with
    /// Swift's `storeFailure`. Whether the document changed.
    pub(crate) fn append_alias_resolution(
        &mut self,
        draft: &AliasResolutionDraft,
    ) -> Result<(AliasResolutionName, bool), String> {
        let failure = |detail: &str| format!("storeFailure(\"{detail}\")");
        if !self.proves(draft) {
            return Err(failure(
                "target alias resolution lacks exact identity, history or postflight proof",
            ));
        }
        let existing = self.resolutions.as_deref().unwrap_or_default();
        if let Some(resolution) = existing
            .iter()
            .find(|r| r.alias == draft.alias || r.canonical == draft.alias)
        {
            if resolution.draft() != *draft {
                return Err(failure(
                    "target alias already has a different durable resolution",
                ));
            }
            return Ok((resolution.name(), false));
        }
        if existing.iter().any(|r| r.alias == draft.canonical) {
            return Err(failure("target alias resolution chains are forbidden"));
        }
        let key = |job: &str, event: &str| format!("{job}\n{event}");
        let used: BTreeSet<String> = existing
            .iter()
            .flat_map(|r| r.intents.iter().map(|i| key(&i.job, &i.event)))
            .collect();
        if draft
            .intents
            .iter()
            .any(|(job, event, _, _)| used.contains(&key(job, event)))
            || existing.iter().any(|r| r.job == draft.job)
        {
            return Err(failure(
                "target alias resolution reuses durable Flash or intent proof",
            ));
        }
        let mut resolution = Resolution {
            id: resolution_id(&draft.alias, &draft.canonical, &draft.job),
            alias: draft.alias.clone(),
            alias_identity: draft.alias_identity.clone(),
            alias_revision: draft.alias_revision,
            canonical: draft.canonical.clone(),
            canonical_identity: draft.canonical_identity.clone(),
            canonical_revision: draft.canonical_revision,
            routed_identity: draft.routed_identity.clone(),
            topology: draft.topology.clone(),
            job: draft.job.clone(),
            plan: draft.plan.clone(),
            steps: draft.steps.clone(),
            intents: draft
                .intents
                .iter()
                .map(|(job, event, step, effect)| Intent {
                    job: job.clone(),
                    event: event.clone(),
                    step: step.clone(),
                    effect: effect.clone(),
                })
                .collect(),
            established_at: draft.established_at.clone(),
            previous: existing.last().map(|r| r.digest.clone()),
            digest: String::new(),
        };
        resolution.digest = resolution_digest(&resolution);
        let name = resolution.name();
        self.resolutions
            .get_or_insert_with(Vec::new)
            .push(resolution);
        Ok((name, true))
    }
    /// Swift `validate(_ draft:targets:)`: the exact two Targets, the routed
    /// identity the alias's own address, a complete postflight and only
    /// enter-Loader intents covered.
    fn proves(&self, draft: &AliasResolutionDraft) -> bool {
        let one = |id: &str| {
            let mut found = self.targets.iter().filter(|t| t.target_id == id);
            match (found.next(), found.next()) {
                (Some(target), None) => Some(target),
                _ => None,
            }
        };
        let (Some(alias), Some(canonical)) = (one(&draft.alias), one(&draft.canonical)) else {
            return false;
        };
        let required = [
            "enter-loader-mode",
            "flash-partitions",
            "verify-flash-readback",
            "reboot-device",
            "wait-for-hdc",
            "rebind-and-verify-build",
        ];
        let steps: BTreeSet<&str> = draft.steps.iter().map(String::as_str).collect();
        let intents: BTreeSet<(&str, &str)> = draft
            .intents
            .iter()
            .map(|(job, event, _, _)| (job.as_str(), event.as_str()))
            .collect();
        draft.alias != draft.canonical
            && alias.identity == draft.alias_identity
            && alias.binding_revision == draft.alias_revision
            && canonical.identity == draft.canonical_identity
            && canonical.binding_revision == draft.canonical_revision
            && draft.alias_identity == draft.routed_identity
            && sha256_hex(alias.connect_key.as_bytes()) == draft.routed_identity
            && sha(&draft.canonical_identity)
            && sha(&draft.plan)
            && !draft.job.is_empty()
            && !draft.topology.is_empty()
            && draft.topology.bytes().all(|b| b.is_ascii_digit())
            && required.iter().all(|step| steps.contains(step))
            && steps.len() == draft.steps.len()
            && intents.len() == draft.intents.len()
            && draft.intents.iter().all(|(job, event, step, effect)| {
                !job.is_empty()
                    && !event.is_empty()
                    && step == "enter-loader-mode"
                    && effect == "deviceMutation"
            })
            && valid_format_timestamp(&draft.established_at)
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
            if resolution_digest(r) != r.digest {
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
