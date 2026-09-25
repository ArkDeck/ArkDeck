//! Swift `RuntimeJobEngine`'s automatic Runtime capability policy for a device
//! mutation the catalog authorizes with a standing capability:
//! - which requests a control session owns;
//! - the subject a capability is issued for;
//! - the scope and policy fingerprints that name it;
//! - the envelope it is issued as;
//! - the generation walk that finds or installs it.
//!
//! It also holds the device sessions a daemon keeps in memory
//! (`deviceSessionHolds`).
//!
//! A destructive effect (a Flash) is issued its one-use envelope for the exact
//! plan and Artifact, its generations rolling over as Swift rolls them
//! (`issue_destructive`); the Jobs a superseding recovery epoch covers are
//! left out of its Target lineage check, and a complete-overwrite recovery
//! names its own policy identity.
use crate::capability_store::{Capability, CapabilityQuery, CapabilityStore, Effect, UseOutcome};
use crate::format_time::{plain_utc_seconds, utc_timestamp};
use crate::operation_catalog::CatalogOperation;
use crate::session_json;
use crate::swift_decoding::{swift_integer, swift_value};
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;

/// Swift `sessionScopedInputOperations`: a gesture's authorized subject is
/// the control session, not the one gesture.
const SESSION_SCOPED_OPERATIONS: [&str; 3] = ["input.tap@1", "input.long-press@1", "input.swipe@1"];
/// Swift `screenshotOnlyCaptureStepIDs`.
const SCREENSHOT_ONLY_STEPS: [&str; 3] = [
    "capture-screenshot",
    "receive-screenshot",
    "cleanup-screenshot-temp",
];
/// Swift `sessionScopedInputLifetime`, a destructive envelope's lifetime and
/// a standing one's.
const SESSION_LIFETIME_SECONDS: u64 = 60 * 60;
const DESTRUCTIVE_LIFETIME_SECONDS: u64 = 4 * 60 * 60;
const STANDING_LIFETIME_SECONDS: u64 = 30 * 24 * 60 * 60;
/// Swift `sessionScopedInputMaximumUses`, and a standing envelope's budget.
const SESSION_MAXIMUM_USES: i64 = 2_000;
const STANDING_MAXIMUM_USES: i64 = 10_000;
/// Swift's bound on the generations of one policy identity.
const GENERATIONS: u32 = 100_000;
/// The terminal states whose confirmed outcome closes a destructive
/// generation and opens the next.
const CLOSING_STATES: [&str; 4] = ["succeeded", "recovered", "cancelled", "failed"];
/// One destructive invocation's bounds: sixteen serial attempts proved safe
/// to reflash, within four hours.
const SERIAL_ATTEMPTS: u32 = 16;
const INVOCATION_SECONDS: u64 = 4 * 60 * 60;
/// Swift `deviceSessionHoldIdleTimeout`.
const HOLD_IDLE_SECONDS: i64 = 120;

/// Swift `isSessionScoped`: whether a control session owns the request. A
/// gesture always does. A capture does only when the optional legs it runs
/// are a screenshot and nothing else.
pub(crate) fn session_scoped(descriptor: &CatalogOperation, inputs: &Map<String, Value>) -> bool {
    let reference = descriptor.reference();
    if SESSION_SCOPED_OPERATIONS.contains(&reference.as_str()) {
        return true;
    }
    if reference != "capture.diagnostics@1" {
        return false;
    }
    let mut screenshot = false;
    for step in descriptor.steps.iter().filter(|step| step.optional) {
        if !descriptor.step_is_selected(step, inputs) {
            continue;
        }
        if !SCREENSHOT_ONLY_STEPS.contains(&step.step_id.as_str()) {
            return false;
        }
        screenshot = true;
    }
    screenshot
}

/// Swift `sessionScopedAuthorizationSubject`: the inputs a capability is
/// issued and consumed for. A gesture keeps only the frame it was mapped
/// against; a session screenshot keeps nothing; any other request keeps all.
pub(crate) fn subject(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> Map<String, Value> {
    if !session_scoped(descriptor, inputs) {
        return inputs.clone();
    }
    if !SESSION_SCOPED_OPERATIONS.contains(&descriptor.reference().as_str()) {
        return Map::new();
    }
    ["displayId", "displayWidth", "displayHeight"]
        .into_iter()
        .filter_map(|key| inputs.get(key).map(|value| (key.to_owned(), value.clone())))
        .collect()
}

/// Swift `authorizationScopeFingerprint(of:)`: the engine's, not the store's.
/// A session-scoped subject's plan digest is not among its lines, so every
/// gesture of a session lands on one capability.
fn scope_fingerprint(query: &CapabilityQuery, session_scoped: bool) -> String {
    let or_dash = |value: &Option<String>| value.clone().unwrap_or_else(|| "-".into());
    let mut lines = vec![
        format!("operation={}", query.operation_reference()),
        format!("effect={}", query.effect.raw()),
        format!("target={}", or_dash(&query.target_stable_identity_sha256)),
        format!(
            "bindingRevision={}",
            query
                .target_binding_revision
                .map_or_else(|| "-".into(), |revision| revision.to_string())
        ),
        format!(
            "planDigest={}",
            if session_scoped {
                "session-scoped".to_owned()
            } else {
                or_dash(&query.plan_digest)
            }
        ),
    ];
    // Validated inputs always encode (Swift's precondition).
    let inputs = session_json::encode(&swift_value(&Value::Object(query.inputs.clone())))
        .unwrap_or_default();
    lines.push(format!("inputs={}", String::from_utf8_lossy(&inputs)));
    for (key, value) in &query.artifact_facts {
        lines.push(format!("artifact.{key}={value}"));
    }
    sha256_hex(lines.join("\n").as_bytes())
}

/// Swift `automaticCapabilityPolicyFingerprint` for an ordinary admission,
/// one no recovery context covers: uppercase hexadecimal.
pub(crate) fn policy_fingerprint(query: &CapabilityQuery, session_scoped: bool) -> String {
    recovery_policy_fingerprint(query, session_scoped, None)
}

/// Swift `automaticCapabilityPolicyFingerprint`: `recovery` is a complete-
/// overwrite recovery context's fingerprint lines (its uncertain effect set,
/// coverage contract version, covered effect set and epoch ordinal), and an
/// ordinary admission has none.
pub(crate) fn recovery_policy_fingerprint(
    query: &CapabilityQuery,
    session_scoped: bool,
    recovery: Option<&str>,
) -> String {
    sha256_hex(
        format!(
            "{CATALOG_DIGEST}\n{}\n{}",
            scope_fingerprint(query, session_scoped),
            recovery.unwrap_or("ordinary")
        )
        .as_bytes(),
    )
    .to_uppercase()
}

/// Swift `exactCapabilityConstraints(for:)`: each string input pinned exactly
/// and each integral number to itself; anything else is left to the exact
/// inputs.
fn constraints(inputs: &Map<String, Value>) -> Map<String, Value> {
    inputs
        .iter()
        .filter_map(|(key, value)| {
            let constraint = match value {
                Value::String(text) => json!({"kind": "exactString", "value": text}),
                Value::Number(number) => {
                    let exact = swift_integer(number)?;
                    json!({"kind": "integerRange", "minimum": exact, "maximum": exact})
                }
                _ => return None,
            };
            Some((key.clone(), constraint))
        })
        .collect()
}

/// Swift `automaticCapabilityExpiry`: a session's hour, a destructive
/// envelope's four hours, or a standing envelope's thirty days.
fn expiry(issued_at: &str, effect: Effect, session_scoped: bool) -> Option<String> {
    let lifetime = if session_scoped {
        SESSION_LIFETIME_SECONDS
    } else if effect == Effect::Destructive {
        DESTRUCTIVE_LIFETIME_SECONDS
    } else {
        STANDING_LIFETIME_SECONDS
    };
    Some(utc_timestamp(plain_utc_seconds(issued_at)? + lifetime))
}

fn operation_scope(descriptor: &CatalogOperation) -> Value {
    let mut scope = Map::new();
    scope.insert("operationID".into(), json!(descriptor.id()));
    if let Some(version) = descriptor.version() {
        scope.insert("version".into(), json!(version));
    }
    Value::Object(scope)
}

/// Why no automatic capability was issued.
pub(crate) enum IssueFailure {
    /// Swift's `authorizationRequired` refusal, with its message.
    Refused(String),
    /// The store could not be read while its generations were walked.
    Unreadable,
}

/// Swift `automaticRuntimeCapability` for an ordinary mutation under a
/// standing capability policy — a device's, or a Runtime-owned workspace
/// copy's — or under a Runtime-owned policy (`runtimeCapability`), whose
/// envelope admits one use of the exact plan. The Target binding's lineage
/// is checked across every capability
/// first (a workspace use names no binding, so none blocks it there). The
/// answer is then the first generation of the policy's identity that is not
/// spent, or that is spent but was revoked. That generation is installed when
/// it does not exist yet.
pub(crate) fn issue(
    store: &CapabilityStore,
    descriptor: &CatalogOperation,
    query: &CapabilityQuery,
    session_scoped: bool,
    issued_at: &str,
) -> Result<String, IssueFailure> {
    let Some(expires_at) = expiry(issued_at, query.effect, session_scoped) else {
        return Err(IssueFailure::Refused(
            "automatic Runtime policy cannot verify the runtime clock".into(),
        ));
    };
    let identity = query.target_stable_identity_sha256.as_deref().unwrap_or("");
    let binding_revision = query.target_binding_revision.unwrap_or(0);
    let blocked = match store.unresolved_use(identity, binding_revision, None) {
        Ok(None) => None,
        Ok(Some(unresolved)) => Some(unresolved.blocker()),
        Err(error) => Some(error),
    };
    if let Some(error) = blocked {
        return Err(IssueFailure::Refused(format!(
            "automatic Runtime target lineage is blocked: {}",
            error.swift()
        )));
    }
    let fingerprint = policy_fingerprint(query, session_scoped);
    for generation in 1..=GENERATIONS {
        let capability_id = format!("CAP-RT-POLICY-{}-G{generation}", &fingerprint[..40]);
        if let Some(existing) = store
            .generation(&capability_id)
            .map_err(|_| IssueFailure::Unreadable)?
        {
            // A spent generation is skipped so the next one is created; a
            // revoked lineage is not rolled forward.
            let spent = existing.remaining_uses == 0 || existing.expires_at.as_str() <= issued_at;
            if spent && !existing.revoked {
                continue;
            }
            return Ok(capability_id);
        }
        return install(
            store,
            descriptor,
            query,
            session_scoped,
            &capability_id,
            issued_at,
            &expires_at,
        );
    }
    Err(IssueFailure::Refused(
        "automatic Runtime capability generations are exhausted".into(),
    ))
}

/// Swift's new generation: the envelope, scoped to whatever the plan
/// addresses, installed.
fn install(
    store: &CapabilityStore,
    descriptor: &CatalogOperation,
    query: &CapabilityQuery,
    session_scoped: bool,
    capability_id: &str,
    issued_at: &str,
    expires_at: &str,
) -> Result<String, IssueFailure> {
    // A workspace plan names its tree, its revision now and its writable
    // scopes, and no device.
    let target_scope = match &query.workspace_identity_sha256 {
        Some(workspace) => json!({
            "kind": "workspaceIdentity", "sha256": workspace,
            "expectedWorkspaceRevision": query.workspace_revision.as_deref().unwrap_or(""),
            "allowedFileScopesDigest":
                query.workspace_file_scopes_digest.as_deref().unwrap_or(""),
        }),
        None => json!({
            "kind": "stablePhysicalIdentity",
            "sha256": query.target_stable_identity_sha256.as_deref().unwrap_or(""),
        }),
    };
    // Swift `pinsExactPlan`: an envelope a Runtime-owned policy authorizes,
    // or a destructive one, admits one use of exactly the plan it was issued
    // for.
    let pins_exact_plan = query.effect == Effect::Destructive
        || descriptor
            .authorization
            .get(query.effect.raw())
            .is_some_and(|policy| policy == "runtimeCapability");
    let maximum_uses = if pins_exact_plan {
        1
    } else if session_scoped {
        SESSION_MAXIMUM_USES
    } else {
        STANDING_MAXIMUM_USES
    };
    let mut envelope = json!({
        "capabilityID": capability_id,
        "targetScope": target_scope,
        "operationScope": [operation_scope(descriptor)],
        "effectCeiling": query.effect.raw(),
        "inputConstraints": constraints(&query.inputs),
        "exactInputs": query.inputs,
        "issuedAtUTC": issued_at,
        "expiresAtUTC": expires_at,
        "maximumUses": maximum_uses,
        "issuer": {
            "kind": "runtimeDefaultPolicy",
            "reference": format!("catalog:{CATALOG_DIGEST}:{}", descriptor.reference()),
        },
        "revocation": {"state": "active"},
    });
    // A destructive envelope is also bound to the exact Artifact the plan
    // writes.
    if query.effect == Effect::Destructive {
        envelope["exactArtifactFacts"] = json!(query.artifact_facts);
    }
    if pins_exact_plan && let Some(plan) = &query.plan_digest {
        envelope["exactPlanDigest"] = json!(plan);
    }
    if let Some(revision) = query.target_binding_revision {
        envelope["exactBindingRevision"] = json!(revision);
    }
    let capability = Capability::issued(&envelope).map_err(|error| {
        IssueFailure::Refused(format!(
            "automatic Runtime policy could not create a bounded capability: {error}"
        ))
    })?;
    store.install(&capability).map_err(|error| {
        IssueFailure::Refused(format!(
            "automatic Runtime capability could not become durable: {}",
            error.swift()
        ))
    })?;
    Ok(capability_id.to_owned())
}

/// Swift `automaticRuntimeCapability` for a destructive effect: the Target
/// binding's lineage checked across every capability first, the Jobs a
/// superseding recovery epoch or the admitted recovery covers left out; then
/// the policy identity's generations walked as Swift walks them:
///
/// - a live generation with a use left is the answer;
/// - an unused one that expired rolls to the next;
/// - one whose last use is pending or unknown is the answer, spent, so that
///   its validation refuses (an unknown write is never replayed);
/// - one confirmed `succeeded`, `recovered`, `cancelled` or `failed` closes
///   and the next opens, starting a new invocation;
/// - one proved safe to reflash rolls to the next within one invocation of
///   at most sixteen serial attempts and four hours.
///
/// A missing generation is installed as a one-use envelope for the exact
/// plan and Artifact, expiring in four hours.
pub(crate) fn issue_destructive(
    store: &CapabilityStore,
    descriptor: &CatalogOperation,
    query: &CapabilityQuery,
    recovery: Option<&str>,
    superseded: &BTreeSet<String>,
    issued_at: &str,
) -> Result<String, IssueFailure> {
    let Some(expires_at) = expiry(issued_at, query.effect, false) else {
        return Err(IssueFailure::Refused(
            "automatic Runtime policy cannot verify the runtime clock".into(),
        ));
    };
    let identity = query.target_stable_identity_sha256.as_deref().unwrap_or("");
    let binding_revision = query.target_binding_revision.unwrap_or(0);
    let blocked = match store.unresolved_use_beyond(identity, binding_revision, None, superseded) {
        Ok(None) => None,
        Ok(Some(unresolved)) => Some(unresolved.blocker()),
        Err(error) => Some(error),
    };
    if let Some(error) = blocked {
        return Err(IssueFailure::Refused(format!(
            "automatic Runtime target lineage is blocked: {}",
            error.swift()
        )));
    }
    let fingerprint = recovery_policy_fingerprint(query, false, recovery);
    let admitted = plain_utc_seconds(issued_at);
    let (mut attempts, mut invocation_start) = (0u32, None::<u64>);
    for generation in 1..=GENERATIONS {
        let capability_id = format!("CAP-RT-POLICY-{}-G{generation}", &fingerprint[..40]);
        let Some(existing) = store
            .generation(&capability_id)
            .map_err(|_| IssueFailure::Unreadable)?
        else {
            return install(
                store,
                descriptor,
                query,
                false,
                &capability_id,
                issued_at,
                &expires_at,
            );
        };
        if existing.remaining_uses > 0
            && existing.expires_at.as_str() > issued_at
            && existing.lineage_allows_new_execution
        {
            return Ok(capability_id);
        }
        let Some((outcome, terminal_state)) = existing.last_outcome else {
            // An unused expired generation has no intent to replay.
            continue;
        };
        match outcome {
            UseOutcome::Pending | UseOutcome::OutcomeUnknown => return Ok(capability_id),
            UseOutcome::Confirmed => {
                if !CLOSING_STATES.contains(&terminal_state.as_str()) {
                    return Ok(capability_id);
                }
                (attempts, invocation_start) = (0, None);
            }
            UseOutcome::SafeToReflash => {
                if invocation_start.is_none() {
                    invocation_start = plain_utc_seconds(&existing.issued_at);
                }
                if let (Some(admitted), Some(start)) = (admitted, invocation_start)
                    && admitted.saturating_sub(start) > INVOCATION_SECONDS
                {
                    // The prior invocation closed by expiry; a fresh request
                    // starts a new bounded window.
                    (attempts, invocation_start) = (0, None);
                    continue;
                }
                attempts += 1;
                if attempts >= SERIAL_ATTEMPTS {
                    return Ok(capability_id);
                }
            }
        }
    }
    Err(IssueFailure::Refused(
        "automatic Runtime capability generations are exhausted".into(),
    ))
}

/// Swift `deviceSessionHolds`: which client's control session holds each
/// device, in this daemon's memory. Only a session-scoped request takes a
/// hold, and while one is live another client's device mutation is refused.
#[derive(Default)]
pub struct DeviceHolds(
    Mutex<HashMap<String, Hold>>,
    Mutex<()>,
    Mutex<HashMap<String, Value>>,
);

struct Hold {
    client: String,
    since: String,
    last: String,
}

impl DeviceHolds {
    pub(crate) fn remember_session_evidence(&self, key: String, evidence: Value) {
        if let Ok(mut cache) = self.2.lock() {
            cache.insert(key, evidence);
        }
    }
    pub(crate) fn session_evidence(&self, key: &str) -> Option<Value> {
        self.2.lock().ok()?.get(key).cloned()
    }

    /// Serializes the cross-capability lineage check with durable reservation
    /// and Job evidence. It neither changes the client's hold nor grants authority.
    pub(crate) fn mutation_reservation_guard(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, ()>, String> {
        self.1
            .lock()
            .map_err(|_| "mutation reservation serialization is untrusted".into())
    }

    /// Swift `admitAgainstDeviceHold`. A hold outlives its last act by two
    /// minutes. The refusal is Swift's message.
    pub(crate) fn admit(
        &self,
        identity: Option<&str>,
        client: &str,
        session_scoped: bool,
        now: &str,
    ) -> Result<(), String> {
        let Some(identity) = identity else {
            return Ok(());
        };
        let mut holds = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(held) = holds.get(identity) {
            // An unreadable last act has expired; an unreadable clock
            // expires nothing.
            let idle = plain_utc_seconds(&held.last).is_none_or(|last| {
                plain_utc_seconds(now)
                    .is_some_and(|now| now as i64 - last as i64 > HOLD_IDLE_SECONDS)
            });
            if idle {
                holds.remove(identity);
            } else if held.client != client {
                return Err(format!(
                    "a control session opened by {} holds this device since {}; it was not \
                     queued behind that session",
                    held.client, held.since
                ));
            }
        }
        if session_scoped {
            holds
                .entry(identity.to_owned())
                .and_modify(|held| held.last = now.to_owned())
                .or_insert_with(|| Hold {
                    client: client.to_owned(),
                    since: now.to_owned(),
                    last: now.to_owned(),
                });
        }
        Ok(())
    }
}
