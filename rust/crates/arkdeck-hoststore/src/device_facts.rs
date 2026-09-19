//! The Target facts a device-bound HDC operation is planned and run against:
//! Swift's standalone daemon `TargetStoreFactsPort` over the Target owner,
//! and the engine's `validateEvidenceFacts`. Facts are read, never written:
//! no binding, route or observation is created here.
use crate::TargetStore;
use arkdeck_provider_hdc::{CodeSignHelper, HdcDispatch, stable_identity_sha256};
use std::path::Path;

/// The HDC composition a device-bound operation plans and runs with: the
/// Target owner its facts come from, the executor its steps dispatch to, where
/// the files it receives land, the executable's digest the facts carry (Swift
/// `TargetStoreFactsPort.executableSHA256`), the clock the provider's
/// context reads, and the code-sign helper a native library deployment
/// stages.
pub struct HdcComposition<'a> {
    pub targets: &'a TargetStore,
    pub dispatch: &'a (dyn HdcDispatch + Sync),
    /// Swift `HDCObservationProviderAdapter.hostReceiveRoot`: the host
    /// directory a received file lands in, under the remote file's own name.
    /// The receive argv names it, so it reaches the materialized plan and its
    /// digest. Without one no file is received.
    pub receive_root: Option<&'a Path>,
    pub tool_sha256: &'a str,
    /// Swift `ProviderExecutionContext.nowUTC`, the engine's clock: a pointer
    /// gesture's frame is judged fresh or stale against it when its plan is
    /// materialized.
    pub now: fn() -> Option<String>,
    /// Swift `HDCObservationProviderAdapter.nativeCodeSignHelper`: the
    /// verified helper a native library deployment stages beside the
    /// library. Without one, `deploy.native-library.app-owned@1` is runtime
    /// unavailable.
    pub code_sign_helper: Option<&'a CodeSignHelper>,
}

/// Swift `ProviderFacts` for an HDC Target, as the facts port resolves them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DeviceFacts {
    pub(crate) target_id: String,
    pub(crate) binding_revision: i64,
    pub(crate) tool_version: String,
    pub(crate) tool_sha256: String,
    pub(crate) connect_key: String,
    /// The identity the connect key names, which `confirm-evidence-target`
    /// verifies; not the record's physical identity, which a Loader-mode
    /// flash advances while the connect key stays the normal-mode one.
    pub(crate) identity: String,
}

impl HdcComposition<'_> {
    /// Swift `TargetStoreFactsPort.currentFacts`, with its error rendered as
    /// Swift interpolates it.
    pub(crate) fn facts(&self, target_id: &str) -> Result<DeviceFacts, String> {
        let route = self
            .targets
            .hdc_route(target_id)?
            .ok_or_else(|| format!("target {target_id} has not been adopted"))?;
        Ok(DeviceFacts {
            identity: stable_identity_sha256(&route.connect_key),
            target_id: route.target_id,
            binding_revision: i64::try_from(route.binding_revision)
                .map_err(|_| format!("target {target_id} has an unrepresentable revision"))?,
            tool_version: route.tool_version,
            tool_sha256: self.tool_sha256.to_owned(),
            connect_key: route.connect_key,
        })
    }
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `validateEvidenceFacts`: the facts name the requested Target at the
/// revision the request expects, for this provider, with a connect key, an
/// identity, a tool version and a tool digest. The refusal is the reason
/// Swift's `RuntimeDispatchFailure.failed` carries.
pub(crate) fn validate(
    facts: &DeviceFacts,
    target_id: &str,
    binding_revision: Option<i64>,
) -> Result<(), &'static str> {
    if facts.target_id == target_id
        && binding_revision == Some(facts.binding_revision)
        && !facts.connect_key.is_empty()
        && lowercase_sha256(&facts.identity)
        && !facts.tool_version.is_empty()
        && lowercase_sha256(&facts.tool_sha256)
    {
        Ok(())
    } else {
        Err("evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched")
    }
}
