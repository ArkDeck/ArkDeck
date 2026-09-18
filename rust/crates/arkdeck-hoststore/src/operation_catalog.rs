//! Typed view of the published operation catalog (Swift
//! `RuntimeOperationCatalog`) and the rules Swift admission and planning apply
//! to it: exact descriptor lookup, typed input validation, the host-only
//! descriptor check, the effect a request resolves to and the steps it selects.
use crate::catalog_pattern;
use arkdeck_contract::CATALOG_CANONICAL_JSON;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::sync::OnceLock;

#[derive(Clone, Debug)]
pub(crate) struct CatalogField {
    pub(crate) name: String,
    pub(crate) kind: String,
    pub(crate) required: bool,
    enum_values: Option<Vec<String>>,
    max_length: Option<u64>,
    pattern: Option<String>,
    minimum: Option<i64>,
    maximum: Option<i64>,
    max_items: Option<u64>,
    default: Option<Value>,
}

#[derive(Clone, Debug)]
pub(crate) struct CatalogStep {
    pub(crate) step_id: String,
    pub(crate) kind: String,
    pub(crate) effect: String,
    pub(crate) cancellation: String,
    pub(crate) binding: String,
    pub(crate) optional: bool,
    /// Swift `actionReference`: the catalog and action an approved remote
    /// operation names, as (`catalogId`, `actionId`).
    pub(crate) action: Option<(String, String)>,
}

/// A product the operation declares (Swift `CatalogArtifactDeclaration`).
#[derive(Clone, Debug)]
pub(crate) struct CatalogArtifact {
    pub(crate) name: String,
    pub(crate) required: bool,
    pub(crate) media_type: String,
    pub(crate) privacy: String,
    pub(crate) retention_class: String,
}

#[derive(Clone, Debug)]
pub(crate) struct CatalogOperation {
    id: String,
    version: Option<i64>,
    pub(crate) provider: String,
    binding: String,
    minimum_effect: String,
    permitted_effects: Vec<String>,
    pub(crate) authorization: BTreeMap<String, String>,
    concurrency_key: String,
    default_policy_issuance: bool,
    pub(crate) inputs: Vec<CatalogField>,
    pub(crate) steps: Vec<CatalogStep>,
    pub(crate) artifacts: Vec<CatalogArtifact>,
    pub(crate) timeout_seconds: i64,
    pub(crate) output_byte_budget: i64,
}

/// Why typed inputs are refused. `Unsupported` names a constraint this
/// validator does not evaluate; a caller refuses rather than skipping it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum InputRefusal {
    Invalid(String),
    Unsupported(String),
}

/// Swift `WorkflowEffect` order.
fn rank(effect: &str) -> u8 {
    match effect {
        "hostOnly" => 0,
        "readOnly" => 1,
        "deviceMutation" => 2,
        _ => 3,
    }
}

fn operations() -> &'static [CatalogOperation] {
    static OPERATIONS: OnceLock<Vec<CatalogOperation>> = OnceLock::new();
    OPERATIONS.get_or_init(|| {
        let catalog: Vec<Value> =
            serde_json::from_str(CATALOG_CANONICAL_JSON).expect("generated catalog");
        catalog.iter().map(CatalogOperation::from_value).collect()
    })
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or_default().to_owned()
}

impl CatalogOperation {
    fn from_value(value: &Value) -> Self {
        let mut inputs: Vec<CatalogField> = value["inputs"]["fields"]
            .as_object()
            .map(|fields| {
                fields
                    .iter()
                    .map(|(name, field)| CatalogField {
                        name: name.clone(),
                        kind: text(&field["type"]),
                        required: field["required"] == true,
                        enum_values: field["enum"]
                            .as_array()
                            .map(|values| values.iter().map(text).collect()),
                        max_length: field["maxLength"].as_u64(),
                        pattern: field["pattern"].as_str().map(str::to_owned),
                        minimum: field["minimum"].as_i64(),
                        maximum: field["maximum"].as_i64(),
                        max_items: field["maxItems"].as_u64(),
                        default: field.get("default").cloned(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        inputs.sort_by(|left, right| left.name.cmp(&right.name));
        let steps = value["steps"]
            .as_array()
            .map(|steps| {
                steps
                    .iter()
                    .map(|step| CatalogStep {
                        step_id: text(&step["stepID"]),
                        kind: text(&step["kind"]),
                        effect: text(&step["effect"]),
                        cancellation: text(&step["cancellation"]),
                        binding: text(&step["binding"]),
                        optional: step["optional"] == true,
                        action: step["actionRef"].as_object().map(|reference| {
                            (text(&reference["catalogId"]), text(&reference["actionId"]))
                        }),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            id: text(&value["id"]),
            version: value["version"].as_i64(),
            provider: text(&value["provider"]),
            binding: text(&value["binding"]),
            minimum_effect: text(&value["effect"]["minimum"]),
            permitted_effects: value["effect"]["permitted"]
                .as_array()
                .map(|values| values.iter().map(text).collect())
                .unwrap_or_default(),
            authorization: value["authorization"]
                .as_object()
                .map(|policies| {
                    policies
                        .iter()
                        .map(|(effect, policy)| (effect.clone(), text(policy)))
                        .collect()
                })
                .unwrap_or_default(),
            concurrency_key: text(&value["concurrencyKey"]),
            default_policy_issuance: value["defaultPolicyIssuance"] == "enabled",
            inputs,
            steps,
            artifacts: value["artifacts"]
                .as_array()
                .map(|artifacts| {
                    artifacts
                        .iter()
                        .map(|artifact| CatalogArtifact {
                            name: text(&artifact["name"]),
                            required: artifact["required"] == true,
                            media_type: text(&artifact["mediaType"]),
                            privacy: text(&artifact["privacy"]),
                            // Swift's generated descriptors default the class.
                            retention_class: artifact["retentionClass"]
                                .as_str()
                                .unwrap_or("default")
                                .to_owned(),
                        })
                        .collect()
                })
                .unwrap_or_default(),
            // An absent bound can never satisfy a policy limit.
            timeout_seconds: value["timeoutSeconds"].as_i64().unwrap_or(i64::MAX),
            output_byte_budget: value["outputByteBudget"].as_i64().unwrap_or(i64::MAX),
        }
    }

    /// Swift `RuntimeOperationCatalog.descriptor(id:version:)`: an exact id
    /// and version, so an unversioned request names only an unversioned entry.
    pub(crate) fn lookup(id: &str, version: Option<i64>) -> Option<&'static Self> {
        operations()
            .iter()
            .find(|operation| operation.id == id && operation.version == version)
    }

    pub(crate) fn reference(&self) -> String {
        match self.version {
            Some(version) => format!("{}@{version}", self.id),
            None => self.id.clone(),
        }
    }

    /// Swift `CatalogOperationDescriptor.binding`: `none` for an operation
    /// that binds no device, otherwise the binding its steps require.
    pub(crate) fn binding(&self) -> &str {
        &self.binding
    }

    /// Swift `RuntimeJobEngine.validateInputs`; keys are judged in byte order.
    pub(crate) fn validate_inputs(&self, inputs: &Map<String, Value>) -> Result<(), InputRefusal> {
        let invalid = |message: String| Err(InputRefusal::Invalid(message));
        // A pattern outside the syntax `catalog_pattern` reads is refused, not
        // skipped; every pattern the published catalog declares is read.
        let unevaluated = |key: &str| {
            Err(InputRefusal::Unsupported(format!(
                "input {key} carries a catalog pattern the Rust Runtime does not evaluate yet"
            )))
        };
        for field in &self.inputs {
            if field.required && !inputs.contains_key(&field.name) {
                return invalid(format!("required input {} is absent", field.name));
            }
        }
        let mut keys: Vec<&String> = inputs.keys().collect();
        keys.sort();
        for key in keys {
            let value = &inputs[key.as_str()];
            let Some(field) = self.inputs.iter().find(|field| &field.name == key) else {
                return invalid(format!(
                    "input {key} is not declared by {}",
                    self.reference()
                ));
            };
            let matches = match (field.kind.as_str(), value) {
                ("string" | "artifactLease" | "artifactReference", Value::String(_)) => true,
                ("integer", Value::Number(number)) => number.is_i64() || number.is_u64(),
                ("boolean", Value::Bool(_)) => true,
                ("stringArray" | "artifactLeaseArray", Value::Array(items)) => {
                    items.iter().all(Value::is_string)
                }
                _ => false,
            };
            if !matches {
                return invalid(format!(
                    "input {key} has the wrong type for {}",
                    self.reference()
                ));
            }
            if let (Some(allowed), Value::String(raw)) = (&field.enum_values, value)
                && !allowed.contains(raw)
            {
                return invalid(format!("input {key} value is outside its enum"));
            }
            match value {
                Value::String(text) => {
                    if let Some(maximum) = field.max_length
                        && text.len() as u64 > maximum
                    {
                        return invalid(format!("input {key} exceeds maxLength {maximum}"));
                    }
                    if let Some(pattern) = &field.pattern {
                        match catalog_pattern::matches(pattern, text) {
                            Some(true) => {}
                            Some(false) => {
                                return invalid(format!(
                                    "input {key} does not match its catalog pattern"
                                ));
                            }
                            None => return unevaluated(key),
                        }
                    }
                }
                Value::Array(values) => {
                    if let Some(maximum) = field.max_items
                        && values.len() as u64 > maximum
                    {
                        return invalid(format!("input {key} exceeds maxItems {maximum}"));
                    }
                    if let Some(maximum) = field.max_length
                        && values
                            .iter()
                            .filter_map(Value::as_str)
                            .any(|item| item.len() as u64 > maximum)
                    {
                        return invalid(format!(
                            "input {key} contains an item exceeding maxLength {maximum}"
                        ));
                    }
                    // Swift judges each item against an array field's pattern.
                    if let Some(pattern) = &field.pattern {
                        for item in values.iter().filter_map(Value::as_str) {
                            match catalog_pattern::matches(pattern, item) {
                                Some(true) => {}
                                Some(false) => {
                                    return invalid(format!(
                                        "input {key} contains an item outside its catalog pattern"
                                    ));
                                }
                                None => return unevaluated(key),
                            }
                        }
                    }
                }
                Value::Number(number) => {
                    let Some(raw) = number.as_i64() else {
                        return invalid(format!(
                            "input {key} is outside the supported integer range"
                        ));
                    };
                    if let Some(minimum) = field.minimum
                        && raw < minimum
                    {
                        return invalid(format!("input {} is below minimum {minimum}", field.name));
                    }
                    if let Some(maximum) = field.maximum
                        && raw > maximum
                    {
                        return invalid(format!("input {} exceeds maximum {maximum}", field.name));
                    }
                }
                _ => (),
            }
        }
        Ok(())
    }

    /// Swift `CatalogOperationEffectResolver.resolvedInputValue`.
    fn resolved<'a>(&'a self, name: &str, inputs: &'a Map<String, Value>) -> Option<&'a Value> {
        inputs.get(name).or_else(|| {
            self.inputs
                .iter()
                .find(|field| field.name == name)
                .and_then(|field| field.default.as_ref())
        })
    }

    /// Swift `CatalogOperationEffectResolver.stepIsSelected`.
    pub(crate) fn step_is_selected(&self, step: &CatalogStep, inputs: &Map<String, Value>) -> bool {
        if step.optional {
            return self.optional_step_is_selected(step, inputs);
        }
        match step.step_id.as_str() {
            "stop-ability" => match self.resolved("postRunAbilityState", inputs) {
                Some(Value::String(state)) => state == "stopped",
                _ => true,
            },
            _ => true,
        }
    }

    /// Swift `CatalogOperationEffectResolver.optionalStepIsSelected`.
    fn optional_step_is_selected(&self, step: &CatalogStep, inputs: &Map<String, Value>) -> bool {
        let flag = |name: &str, fallback: bool| match self.resolved(name, inputs) {
            Some(Value::Bool(enabled)) => *enabled,
            _ => fallback,
        };
        let string = |name: &str| match self.resolved(name, inputs) {
            Some(Value::String(value)) => Some(value.as_str()),
            _ => None,
        };
        match step.step_id.as_str() {
            "capture-hilog" => flag("captureHilog", true),
            "capture-trace" | "receive-trace-artifact" | "cleanup-remote-temp" => {
                match self.resolved("traceCategories", inputs) {
                    Some(Value::Array(categories)) => !categories.is_empty(),
                    _ => false,
                }
            }
            "capture-ui-dump" => flag("uiDump", true),
            "capture-advanced-ui-dump" => flag("advancedDump", false),
            "capture-crash-index" => flag("crashLogs", false),
            "capture-crash-log" => string("crashLogName").is_some_and(|name| !name.is_empty()),
            "observe-application-liveness" => {
                string("bundleName").is_some_and(|name| !name.is_empty())
            }
            "capture-screenshot" | "receive-screenshot" | "cleanup-screenshot-temp" => {
                flag("uiScreenshot", false)
            }
            "capture-ui-tree" | "receive-ui-tree" | "cleanup-ui-tree-temp" => {
                flag("uiComponentTree", false)
            }
            "capture-diagnostics" => flag("captureDiagnostics", true),
            "cleanup-uninstall" => {
                string("cleanupPolicy").is_none_or(|policy| policy == "uninstall")
            }
            "capture-post-flash-diagnostics" => {
                string("postFlashVerification").is_none_or(|profile| profile == "full")
            }
            _ => true,
        }
    }

    /// Swift `CatalogOperationEffectResolver.effectiveEffect`.
    pub(crate) fn effective_effect(&self, inputs: &Map<String, Value>) -> String {
        let mut effect = self.minimum_effect.clone();
        for step in &self.steps {
            if self.step_is_selected(step, inputs) && rank(&step.effect) > rank(&effect) {
                effect = step.effect.clone();
            }
        }
        effect
    }

    /// Swift `RuntimeJobEngine.validateHostOnlyDescriptor`: an unbound
    /// operation stays host-only all the way down, except the two reviewed
    /// workspace mutation authorities.
    pub(crate) fn validate_host_only(&self) -> Result<(), String> {
        let reference = self.reference();
        let standing_workspace_mutation = self.provider == "workspace"
            && self
                .permitted_effects
                .iter()
                .all(|effect| rank(effect) <= rank("deviceMutation"))
            && self.authorization.get("deviceMutation").map(String::as_str)
                == Some("standingCapability");
        let runtime_checkpoint = reference == "workspace.create-checkpoint@1"
            && self.provider == "workspace"
            && self.minimum_effect == "deviceMutation"
            && self.permitted_effects == ["deviceMutation"]
            && self.authorization.get("deviceMutation").map(String::as_str)
                == Some("runtimeCapability")
            && self.default_policy_issuance
            && self.concurrency_key == "host-exclusive"
            && self.steps.len() == 1
            && self.steps[0].kind == "createWorkspaceCheckpoint"
            && self.steps[0].effect == "deviceMutation"
            && self.steps[0].binding == "none";
        let unbound_mutation = standing_workspace_mutation || runtime_checkpoint;
        let above =
            || format!("{reference} declares binding none but permits an effect above hostOnly");
        if !(rank(&self.minimum_effect) <= rank("hostOnly")
            || (unbound_mutation && self.minimum_effect == "deviceMutation"))
        {
            return Err(above());
        }
        if !(self
            .permitted_effects
            .iter()
            .all(|effect| rank(effect) <= rank("hostOnly"))
            || unbound_mutation)
        {
            return Err(above());
        }
        for step in &self.steps {
            if step.binding != "none" {
                return Err(format!(
                    "{reference} is host-only but step {} requires a device binding",
                    step.step_id
                ));
            }
            if !(rank(&step.effect) <= rank("hostOnly")
                || (unbound_mutation && step.effect == "deviceMutation"))
            {
                return Err(format!(
                    "{reference} is host-only but step {} declares effect {}",
                    step.step_id, step.effect
                ));
            }
        }
        let _ = &self.binding;
        Ok(())
    }
}
