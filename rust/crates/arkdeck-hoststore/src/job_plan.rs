//! Rust `job.plan`: Swift `RuntimeJobEngine.planOnly` for the operations this
//! Runtime materializes, in Swift's order: the typed request, catalog inputs,
//! the request fingerprint, provider and Artifact preflight, the materialized
//! plan document and its digest, and the `arkdeck.job-plan/1` projection.
//! Nothing is admitted, journaled, reserved or dispatched, so every refusal is
//! pre-admission with zero new dispatch.
use crate::ArtifactReadStore;
use crate::artifact_read_owner::{LeasedArtifact, swift_string};
use crate::device_facts::{self, HdcComposition};
use crate::device_steps::{self, ActionRefusal};
use crate::operation_catalog::{CatalogOperation, InputRefusal};
use crate::operation_request::OperationRequest;
use crate::session_json;
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

#[path = "debug_hap_plan.rs"]
mod debug_hap_plan;
#[path = "native_library_plan.rs"]
mod native_library_plan;
#[path = "screen_sequence_plan.rs"]
mod screen_sequence_plan;
#[path = "workspace_plan.rs"]
mod workspace_plan;
pub(crate) use native_library_plan::read_library;

const MAXIMUM_REQUEST_JSON_BYTES: usize = 4 * 1024 * 1024;
const MAXIMUM_ANALYZER_BYTES: u64 = 128 * 1024 * 1024;
const MAXIMUM_ANALYZER_INPUT_BYTES: u64 = 512 * 1024 * 1024;
/// The operations whose plans this Runtime materializes, and so plans and
/// admits. Every other catalog operation is refused before its inputs are
/// judged.
const MATERIALIZED: [&str; 18] = [
    "analyzer.extract-crash-signature@1",
    "analyzer.summarize-hilog@1",
    "observe.device@1",
    "debug.template@1",
    "capture.diagnostics@1",
    "input.tap@1",
    "input.long-press@1",
    "input.swipe@1",
    "port-forward.create@1",
    "port-forward.remove@1",
    "debug.hap@1",
    device_steps::NATIVE,
    "capture.screen-sequence@1",
    "workspace.prepare-isolated-copy@1",
    "workspace.apply-patch@1",
    "workspace.revert-patch@1",
    "workspace.build-openharmony@1",
    "workspace.sign-openharmony-hap@1",
];

/// Swift `AnalyzerProfile`: one analyzer a host configured, its pinned
/// executable and the closed invocation the Runtime lowers for it. The
/// crash-ledger analyzer is the executable a host names with
/// `ARKDECK_ANALYZER_PATH`; the HiLog summary is that same executable when it
/// is the daemon itself (Swift daemon composition, `AnalyzerProfiles`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AnalyzerProfile {
    pub analyzer_ref: String,
    pub analyzer_version: String,
    pub executable_path: PathBuf,
    pub executable_sha256: String,
    pub fixed_arguments: Vec<String>,
    pub timeout_seconds: i64,
    /// The most a verified answer may hold (Swift `outputByteBudget`).
    pub output_byte_budget: usize,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

/// Swift `FixedExecutableResolver.hashing(path:)`: an explicit absolute path
/// to a regular executable file, its physical location, and the SHA-256 of
/// its bytes.
fn hashed_executable(path: &Path) -> io::Result<(PathBuf, String)> {
    if !path.is_absolute() {
        return Err(invalid(
            "provider executable path must be explicit and absolute",
        ));
    }
    let executable = std::fs::canonicalize(path)?;
    let metadata = std::fs::metadata(&executable)?;
    if !metadata.is_file() || metadata.mode() & 0o111 == 0 {
        return Err(invalid(
            "provider executable must be a regular executable file",
        ));
    }
    let bytes = std::fs::read(&executable)?;
    Ok((executable, sha256_hex(&bytes)))
}

impl AnalyzerProfile {
    /// The crash-ledger profile of the executable at `path`.
    pub fn crash_signature(path: &Path) -> io::Result<Self> {
        let (executable, sha256) = hashed_executable(path)?;
        Ok(Self {
            analyzer_ref: "crash-signature@1".into(),
            analyzer_version: "arkdeck-fault-log-ledger@1".into(),
            executable_path: executable,
            executable_sha256: sha256,
            fixed_arguments: vec!["--analyze-crash-ledger".into()],
            timeout_seconds: 30,
            output_byte_budget: 8 * 1024 * 1024,
        })
    }

    /// The HiLog summary profile of the executable at `path`.
    pub fn hilog_summary(path: &Path) -> io::Result<Self> {
        let (executable, sha256) = hashed_executable(path)?;
        Ok(Self::hilog_summary_of(executable, sha256))
    }

    /// Swift `HilogSummaryDerivedAnalyzer.profile`: the closed
    /// `--summarize-hilog` mode of the analyzer executable `analyzer` names,
    /// under the 120 s budget and the summary's 8 KiB bound.
    pub(crate) fn hilog_summary_from(analyzer: &Self) -> Self {
        Self::hilog_summary_of(
            analyzer.executable_path.clone(),
            analyzer.executable_sha256.clone(),
        )
    }

    fn hilog_summary_of(executable: PathBuf, sha256: String) -> Self {
        Self {
            analyzer_ref: crate::hilog_summary::ANALYZER_REF.into(),
            analyzer_version: crate::hilog_summary::ANALYZER_VERSION.into(),
            executable_path: executable,
            executable_sha256: sha256,
            fixed_arguments: vec!["--summarize-hilog".into()],
            timeout_seconds: 120,
            output_byte_budget: crate::hilog_summary::MAXIMUM_OUTPUT_BYTES,
        }
    }

    /// Swift `ArkTraceProfileFileReader.matches(requireExecutable: true)` at
    /// every plan: the profiled path still names these exact executable bytes,
    /// through no symbolic link.
    pub(crate) fn still_matches(&self) -> bool {
        let current = || -> io::Result<bool> {
            if std::fs::canonicalize(&self.executable_path)? != self.executable_path {
                return Ok(false);
            }
            let metadata = std::fs::symlink_metadata(&self.executable_path)?;
            if !metadata.is_file() || metadata.len() > MAXIMUM_ANALYZER_BYTES {
                return Ok(false);
            }
            let bytes = std::fs::read(&self.executable_path)?;
            Ok(bytes.len() as u64 == metadata.len()
                && metadata.mode() & 0o111 != 0
                && sha256_hex(&bytes) == self.executable_sha256)
        };
        current().unwrap_or(false)
    }
}

/// A `job.plan` refusal: its control-plane code and message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanRefusal {
    pub code: &'static str,
    pub message: String,
}

fn refusal(code: &'static str, message: impl Into<String>) -> PlanRefusal {
    PlanRefusal {
        code,
        message: message.into(),
    }
}

/// Swift's Job lifecycle handler reports every internal planning failure with
/// this one message, whatever failed.
fn internal_failure() -> PlanRefusal {
    refusal(
        "internalError",
        "the Runtime could not complete the Job lifecycle request",
    )
}

/// The owners a plan reads. The state root holds the Runtime debug attempt
/// permits Swift consults while materializing.
pub struct JobPlanner<'a> {
    pub artifacts: Option<&'a ArtifactReadStore>,
    pub imports: Option<&'a crate::ImportUploadStore>,
    /// The analyzers the host composed, which an analyzer operation is
    /// planned against.
    pub analyzer: Option<&'a dyn crate::AnalyzerComposition>,
    pub state_root: &'a Path,
    /// The HDC composition a device-bound operation materializes against;
    /// without one no HDC provider is registered.
    pub hdc: Option<&'a HdcComposition<'a>>,
    /// The workspace provider a workspace operation materializes against;
    /// without one no workspace provider is registered.
    pub workspace: Option<&'a crate::WorkspaceComposition>,
}

/// A materialized plan: its digest and, for a device-bound plan, the Target
/// identity and binding revision it binds.
pub(crate) struct Materialized<'a> {
    _import_use: Option<crate::import_upload::ImportUse<'a>>,
    /// The registration a workspace Job materializes against, held until the
    /// plan or admission is done with it.
    _workspace_use: Option<crate::WorkspaceUse<'a>>,
    pub(crate) digest: String,
    pub(crate) artifact_facts: BTreeMap<String, String>,
    pub(crate) identity: Option<String>,
    pub(crate) binding_revision: Option<i64>,
}

/// Swift's Job lifecycle `requestJSON()`: exactly one non-empty `requestJson`
/// of at most 4 MiB.
pub(crate) fn request_json(params: &Map<String, Value>) -> Result<&str, PlanRefusal> {
    if params.len() != 1 || !params.contains_key("requestJson") {
        return Err(refusal(
            "invalidInput",
            "the target Job request accepts exactly one bounded requestJson",
        ));
    }
    let Some(text) = params["requestJson"]
        .as_str()
        .filter(|text| !text.is_empty())
    else {
        return Err(refusal(
            "invalidInput",
            "requestJson must be a non-empty typed request document",
        ));
    };
    if text.len() > MAXIMUM_REQUEST_JSON_BYTES {
        return Err(refusal(
            "inputTooLarge",
            "requestJson exceeds the target control request bound",
        ));
    }
    Ok(text)
}

impl<'a> JobPlanner<'a> {
    /// Classify a typed request using the same Catalog and input validation as
    /// admission, without Target lookup, materialization or authority issuance.
    pub fn validated_effect(request: &OperationRequest) -> Result<String, PlanRefusal> {
        let descriptor = Self::descriptor(request)?;
        Self::validate_inputs(request, descriptor)?;
        Ok(descriptor.effective_effect(&request.inputs))
    }

    /// The `job.plan` control parameters: exactly one bounded `requestJson`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, PlanRefusal> {
        self.plan(request_json(params)?.as_bytes())
    }

    pub fn plan(&self, request_json: &[u8]) -> Result<Value, PlanRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refusal(rejection.code.wire_code(), rejection.message))?;
        if request.capability_id.is_some() {
            return Err(refusal(
                "invalidInput",
                "planOnly does not accept or consume a Runtime capability",
            ));
        }
        let descriptor = Self::descriptor(&request)?;
        Self::validate_inputs(&request, descriptor)?;
        let fingerprint = request.fingerprint();
        let materialized = self.materialized(&request, descriptor)?;
        let reference = descriptor.reference();
        let effect = descriptor.effective_effect(&request.inputs);
        let steps = crate::catalog_review::selected_steps(descriptor, &request.inputs);
        let step_set = step_set_digest(descriptor, &request.inputs)?;
        Ok(json!({
            "schemaVersion": "arkdeck.job-plan/1",
            "executionMode": "planOnly",
            "operation": reference,
            "targetId": request.target_id,
            "bindingRevision": materialized.binding_revision,
            "stableIdentitySha256": materialized.identity,
            "providerId": descriptor.provider,
            "catalogDigest": CATALOG_DIGEST,
            "requestFingerprintSha256": fingerprint,
            "materializedPlanDigest": materialized.digest,
            "stepSetDigestSHA256": step_set,
            "inputs": request.inputs,
            "steps": steps,
            "effectiveEffect": effect,
            "authorizationPolicy": descriptor.authorization.get(&effect),
            "providerAdmissionBlocker": null,
            "jobAdmitted": false,
            "dispatchDisposition": "notDispatched",
        }))
    }

    /// The exact catalog operation a request names, when this Runtime
    /// materializes it; every other operation is refused before its inputs
    /// are judged.
    pub(crate) fn descriptor(
        request: &OperationRequest,
    ) -> Result<&'static CatalogOperation, PlanRefusal> {
        let Some(descriptor) =
            CatalogOperation::lookup(&request.operation_id, request.operation_version)
        else {
            return Err(refusal(
                "operationUnavailable",
                format!("operation {} is not in the catalog", request.reference()),
            ));
        };
        let reference = descriptor.reference();
        if !MATERIALIZED.contains(&reference.as_str()) {
            return Err(refusal(
                "rejected",
                format!("{reference} is not materialized by the Rust Runtime yet"),
            ));
        }
        Ok(descriptor)
    }

    /// Swift `validateInputs`; a catalog constraint this validator does not
    /// evaluate is refused rather than skipped.
    pub(crate) fn validate_inputs(
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<(), PlanRefusal> {
        descriptor
            .validate_inputs(&request.inputs)
            .map_err(|failure| match failure {
                InputRefusal::Invalid(message) => refusal("invalidInput", message),
                InputRefusal::Unsupported(message) => refusal("rejected", message),
            })
    }

    /// Swift's Import holds, then `materializeTypedPlanBeforeAuthorization`:
    /// the materialized plan document's digest and, for a device-bound plan,
    /// what it binds.
    pub(crate) fn materialized(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        let references = crate::job_owner::import_references::ImportReference::inputs(
            &request.inputs,
            descriptor,
        )
        .map_err(|_| refusal("invalidInput", "Import input references are malformed"))?;
        let hold = if references.is_empty() {
            None
        } else {
            let owner = self
                .imports
                .ok_or_else(|| refusal("invalidInput", "Import input owner is unavailable"))?;
            let artifacts = self
                .artifacts
                .ok_or_else(|| refusal("invalidInput", "Artifact owner is unavailable"))?;
            owner
                .acquire_inputs(artifacts, &references)
                .map_err(|error| refusal("invalidInput", error.message))?
        };
        // Swift `acquireWorkspaceProjectInput`, after the Import holds and
        // before anything is materialized.
        let workspace_use = match self.workspace {
            Some(workspace) => workspace
                .acquire(descriptor, &request.inputs)
                .map_err(|(code, message)| refusal(code, message))?,
            None => None,
        };
        if descriptor.provider == "hdc" {
            let mut materialized = self.materialize_device(request, descriptor)?;
            materialized._import_use = hold;
            return Ok(materialized);
        }
        let (digest, artifact_facts) = if descriptor.provider == "workspace" {
            self.materialize_workspace(request, descriptor)?
        } else {
            (self.materialize(request, descriptor)?, BTreeMap::new())
        };
        Ok(Materialized {
            _import_use: hold,
            _workspace_use: workspace_use,
            digest,
            artifact_facts,
            identity: None,
            binding_revision: None,
        })
    }

    /// Swift consults a Runtime debug attempt permit for every plan; this
    /// Runtime reads none, so a request that has one is refused.
    fn refuse_debug_permit(&self, request: &OperationRequest) -> Result<(), PlanRefusal> {
        let permit = self
            .state_root
            .join("runtime-debug-attempts")
            .join(format!("{}.json", request.idempotency_key));
        if std::fs::symlink_metadata(permit).is_ok() {
            return Err(refusal(
                "rejected",
                "a Runtime debug attempt permit is not read by the Rust Runtime yet",
            ));
        }
        Ok(())
    }

    /// Swift `materializeTypedPlanBeforeAuthorization` for an HDC operation:
    /// a registered provider, the Artifact store its products need, the
    /// Target's facts checked against the request, then every selected step
    /// as the engine or the HDC provider materializes it, the provider's with
    /// the exact arguments its executor will run.
    fn materialize_device(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        let reference = descriptor.reference();
        let Some(hdc) = self.hdc else {
            return Err(refusal(
                "invalidInput",
                format!("provider {} is not registered", descriptor.provider),
            ));
        };
        // Swift `runtimeAvailability`: a native deployment stages the
        // code-sign helper its composition verified, and without one the
        // operation is unavailable.
        if reference == device_steps::NATIVE && hdc.code_sign_helper.is_none() {
            return Err(refusal(
                "invalidInput",
                format!(
                    "{reference} is runtime unavailable: bundled arm64 OpenHarmony code-sign \
                     helper cannot be verified"
                ),
            ));
        }
        if self.artifacts.is_none() {
            return Err(refusal(
                "invalidInput",
                format!("{reference} is runtime unavailable: runtime.artifactStoreUnavailable"),
            ));
        }
        let unmaterialized = |error: String| {
            refusal(
                "invalidInput",
                format!(
                    "target facts cannot materialize the typed plan before authorization: {error}"
                ),
            )
        };
        let facts = hdc.facts(&request.target_id).map_err(unmaterialized)?;
        device_facts::validate(
            &facts,
            &request.target_id,
            request.expected_binding_revision,
        )
        .map_err(|reason| unmaterialized(format!("failed({})", swift_string(reason))))?;
        // A HAP binds its leased packages, whose owner-validated facts name the
        // capability it is admitted under; its execution owner is separate work.
        if reference == "debug.hap@1" {
            return self.materialize_hap(request, descriptor, &facts);
        }
        // A native deployment binds its leased library, verified as the
        // expected ABI's code-signed ELF, whose facts name its capability.
        if reference == device_steps::NATIVE {
            return self.materialize_native(request, descriptor, &facts);
        }
        // A screen sequence's and a capture's legs are named for the
        // authorization envelope; a receive among them lowers against the
        // composition's host receive root.
        if [device_steps::SCREEN_SEQUENCE, device_steps::CAPTURE].contains(&reference.as_str()) {
            return self.materialize_file_capture(request, descriptor, &facts);
        }
        self.refuse_debug_permit(request)?;
        // The provider context's clock, which a pointer gesture's frame is
        // judged against.
        let now = (hdc.now)().ok_or_else(internal_failure)?;
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            if device_steps::engine_step(&step.kind) {
                steps.push(json!({
                    "stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                    "cancellation": step.cancellation, "binding": step.binding,
                    "isOptional": step.optional, "processKind": "engine",
                }));
                continue;
            }
            let action = match device_steps::action(step, &reference, &request.inputs, &now) {
                Ok(action) => action,
                Err(ActionRefusal::Unported) => {
                    return Err(refusal(
                        "rejected",
                        format!(
                            "{} of {reference} is not materialized by the Rust Runtime yet",
                            step.step_id
                        ),
                    ));
                }
                Err(ActionRefusal::Invalid(error)) => {
                    return Err(refusal(
                        "invalidInput",
                        format!("typed plan preflight failed before authorization: {error}"),
                    ));
                }
            };
            let Some(arguments) =
                device_steps::journal_arguments_for(step, &reference, &request.inputs, &action)
            else {
                return Err(internal_failure());
            };
            if action.effect() != step.effect {
                return Err(internal_failure());
            }
            let plan = action
                .lower(&step.step_id, Some(&facts.connect_key))
                .map_err(|error| {
                    refusal(
                        "invalidInput",
                        format!("typed plan preflight failed before authorization: {error}"),
                    )
                })?;
            steps.push(json!({
                "stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                "cancellation": step.cancellation, "binding": step.binding,
                "isOptional": step.optional, "journalArguments": arguments,
                "processKind": "process",
                // Swift lowers the executable's identity at dispatch.
                "executableSHA256": "resolved-at-dispatch",
                "argumentSummary": plan.arguments,
                "timeoutSeconds": plan.timeout.as_secs(),
            }));
        }
        let document = json!({
            "operationReference": reference,
            "catalogDigest": CATALOG_DIGEST,
            "inputs": request.inputs,
            "targetID": request.target_id,
            "stableTargetIdentitySHA256": facts.identity,
            "bindingRevision": facts.binding_revision,
            "providerID": descriptor.provider,
            "steps": steps,
        });
        let bytes = session_json::encode(&document).map_err(|_| internal_failure())?;
        Ok(Materialized {
            _import_use: None,
            _workspace_use: None,
            artifact_facts: BTreeMap::new(),
            digest: sha256_hex(&bytes),
            identity: Some(facts.identity),
            binding_revision: Some(facts.binding_revision),
        })
    }

    /// Swift `RuntimeArtifactStore.resolveLease` plus
    /// `validateResolvedInputArtifact` for an analyzer source: a published Job
    /// Artifact collected from the request's own target. A refusal is the
    /// error Swift interpolates into its message.
    fn resolve_lease(
        &self,
        artifacts: &ArtifactReadStore,
        lease: &str,
        request: &OperationRequest,
    ) -> Result<LeasedArtifact, String> {
        let leased = if let Some(reference) =
            crate::job_owner::import_references::ImportReference::parse(lease)
                .map_err(|error| error.message)?
        {
            self.imports
                .ok_or("Import owner is unavailable")?
                .resolve_input(artifacts, &reference)
                .map_err(|error| error.message)?
        } else {
            artifacts.lease(lease)?
        };
        // Swift `validateArtifactBinding` lets a host-only analyzer read an
        // Artifact collected from exactly its own target.
        if leased.row["bindingSnapshot"]["targetID"] != request.target_id.as_str() {
            return Err(format!(
                "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, {})",
                swift_string(
                    "Artifact lease target/binding/identity does not match the materialized request"
                )
            ));
        }
        Ok(leased)
    }

    /// The materialized plan document's digest, as Swift
    /// `materializeTypedPlanBeforeAuthorization` computes it.
    fn materialize(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<String, PlanRefusal> {
        let reference = descriptor.reference();
        let unavailable = |reason: &str| {
            refusal(
                "invalidInput",
                format!("{reference} is runtime unavailable: {reason}"),
            )
        };
        // Swift `AnalyzerProvider.runtimeAvailability`: the operation's one
        // analyzer as the host composed it, its executable still its bytes.
        let profile = crate::analyzer_composition::runtime_availability(self.analyzer, &reference)
            .map_err(|(_, reason)| unavailable(&reason))?;
        let Some(artifacts) = self.artifacts else {
            return Err(unavailable("runtime.artifactStoreUnavailable"));
        };
        descriptor
            .validate_host_only()
            .map_err(|message| refusal("invalidInput", message))?;
        if request.expected_binding_revision.is_some() {
            return Err(refusal(
                "invalidInput",
                format!("{reference} is host-only: a request must not pin a binding revision"),
            ));
        }
        let Some(Value::String(lease)) = request.inputs.get("sourceArtifactRef") else {
            return Err(refusal(
                "invalidInput",
                format!("{reference} requires a configured Artifact lease store"),
            ));
        };
        let leased = self
            .resolve_lease(artifacts, lease, request)
            .map_err(|reason| {
                refusal(
                    "invalidInput",
                    format!("analyzer source artifact Artifact lease is not resolvable: {reason}"),
                )
            })?;
        self.refuse_debug_permit(request)?;
        let path = leased
            .path
            .to_str()
            .ok_or_else(internal_failure)?
            .to_owned();
        let byte_count = leased.row["byteCount"].as_u64().unwrap_or(0);
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            if step.kind != "runDeterministicAnalyzer" || step.effect != "hostOnly" {
                return Err(internal_failure());
            }
            // Swift `AnalyzerProvider.action`: the lease is the claim and the
            // bytes are the fact, so they are read again before lowering.
            if byte_count == 0
                || byte_count > MAXIMUM_ANALYZER_INPUT_BYTES
                || !artifacts.payload_matches(&leased)
            {
                return Err(refusal(
                    "invalidInput",
                    "typed plan preflight failed before authorization: analyzer input Artifact bytes do not match their lease",
                ));
            }
            let mut arguments = profile.fixed_arguments.clone();
            arguments.push(path.clone());
            steps.push(json!({
                "stepID": step.step_id,
                "kind": step.kind,
                "effect": step.effect,
                "cancellation": step.cancellation,
                "binding": step.binding,
                "isOptional": step.optional,
                "journalArguments": {
                    "analyzerRef": profile.analyzer_ref,
                    "inputArtifactId": leased.artifact_id,
                    "artifactId": crate::analyzer_composition::derived_artifact_name(
                        &profile.analyzer_ref,
                    ),
                },
                "processKind": "process",
                "executableSHA256": profile.executable_sha256,
                "argumentSummary": arguments,
                "timeoutSeconds": profile.timeout_seconds,
            }));
        }
        let document = json!({
            "operationReference": reference,
            "catalogDigest": CATALOG_DIGEST,
            "inputs": request.inputs,
            "targetID": request.target_id,
            "providerID": descriptor.provider,
            "steps": steps,
        });
        let bytes = session_json::encode(&document).map_err(|_| internal_failure())?;
        Ok(sha256_hex(&bytes))
    }
}

/// Swift RuntimeJobEngine.stepSetDigest. This is provenance, never dispatch permission.
pub(crate) fn step_set_digest(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> Result<String, PlanRefusal> {
    let mut lines: Vec<String> = descriptor
        .steps
        .iter()
        .filter(|step| descriptor.step_is_selected(step, inputs))
        .map(|step| {
            format!(
                "{}|{}|{}|{}|{}",
                step.step_id, step.kind, step.effect, step.cancellation, step.binding
            )
        })
        .collect();
    if descriptor.reference() == "debug.hap@1" {
        for step in debug_hap_plan::compensations(descriptor, inputs)? {
            lines.push(format!(
                "compensation-{}|{}|{}|{}|{}",
                step.step_id, step.kind, step.effect, step.cancellation, step.binding
            ));
        }
    }
    Ok(sha256_hex(lines.join("\n").as_bytes()))
}
