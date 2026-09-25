//! Swift `RuntimeWorkspaceProjectStore.registerPreset/updatePreset/removePreset`
//! behind `workspace.preset.register/update/remove` (TASK-XPA-015, M3), and the
//! typed preset records they write. A preset that pins a DevEco toolchain or a
//! signing credential goes through the store's crash-recovered dependency
//! transaction (`super::document`); this owner never resolves either pin.
use super::document::Document;
use super::*;

/// Swift `RuntimeWorkspacePresetConstraints`: absent members are omitted, as
/// Swift's encoder omits a nil optional.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Constraints {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub product: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relative_source_map: Option<String>,
}

/// Swift's durable `PresetRecord`, key for key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PresetRecord {
    pub preset_ref: String,
    pub generation: u64,
    pub project_ref: String,
    pub kind: String,
    pub template_ref: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain_generation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_ref: Option<String>,
    pub timeout_seconds: i64,
    pub constraints: Constraints,
    #[serde(rename = "registrationRequestID")]
    pub registration_request_id: String,
    pub registration_project_ref: String,
    pub registration_kind: String,
    pub registration_template_ref: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_toolchain_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_toolchain_generation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_credential_ref: Option<String>,
    pub registration_timeout_seconds: i64,
    pub registration_constraints: Constraints,
    pub registration_digest: String,
    pub current_definition_digest: String,
    #[serde(rename = "registeredAtUTC")]
    pub registered_at: String,
    #[serde(rename = "updatedAtUTC")]
    pub updated_at: String,
    pub state: String,
    #[serde(rename = "lastMutationRequestID")]
    pub last_mutation_request_id: String,
    pub last_mutation_digest: String,
}

/// Swift `PendingDependencyMutation`, kept under the historical
/// `pendingToolchainMutation` document key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PendingMutation {
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain_generation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_ref: Option<String>,
    pub preset_ref: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proposed_record: Option<PresetRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_after_acquire_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_after_acquire_credential_ref: Option<String>,
}

impl PendingMutation {
    /// The release of the dependencies a preset held before this mutation.
    pub(super) fn release(
        preset_ref: &str,
        toolchain_ref: Option<String>,
        toolchain_generation: Option<u64>,
        credential_ref: Option<String>,
    ) -> Self {
        Self {
            action: "release".into(),
            toolchain_ref,
            toolchain_generation,
            credential_ref,
            preset_ref: preset_ref.into(),
            proposed_record: None,
            release_after_acquire_ref: None,
            release_after_acquire_credential_ref: None,
        }
    }
}

impl PresetRecord {
    /// Swift `presetResource`, with the configuration status the store
    /// derives for it (`WorkspaceProjectStore::preset_resource`).
    pub(super) fn resource(&self, status: &str) -> Result<Value, WireError> {
        if timestamp(&self.registered_at).is_none() || timestamp(&self.updated_at).is_none() {
            return Err(failure(
                "recordUnreadable",
                "workspace preset timestamps are invalid",
            ));
        }
        Ok(json!({
            "schemaVersion": "arkdeck.workspace-preset/1",
            "presetRef": self.preset_ref,
            "generation": self.generation.to_string(),
            "projectRef": self.project_ref,
            "kind": self.kind,
            "templateRef": self.template_ref,
            "toolchainRef": self.toolchain_ref,
            "toolchainGeneration": self.toolchain_generation.map(|n| n.to_string()),
            "credentialRef": self.credential_ref,
            "timeoutSeconds": self.timeout_seconds,
            "constraints": self.constraints,
            "registeredAtUtc": self.registered_at,
            "updatedAtUtc": self.updated_at,
            "configurationStatus": status,
        }))
    }

    pub(super) fn available(&self) -> bool {
        self.state == "available"
    }
}

/// One typed preset definition, as Swift's handler decodes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Definition {
    pub kind: String,
    pub template_ref: String,
    pub toolchain_ref: Option<String>,
    pub toolchain_generation: Option<u64>,
    pub credential_ref: Option<String>,
    pub timeout_seconds: i64,
    pub constraints: Constraints,
}

const OPTIONAL_DEFINITION_KEYS: [&str; 7] = [
    "toolchainRef",
    "toolchainGeneration",
    "credentialRef",
    "module",
    "product",
    "buildMode",
    "relativeSourceMap",
];

/// Swift `canonicalPositiveUInt64`: canonical decimal text in 1...Int64.max.
pub(super) fn canonical_positive(value: Option<&Value>) -> Option<u64> {
    let text = value?.as_str()?;
    text.parse::<u64>()
        .ok()
        .filter(|n| *n > 0 && *n <= i64::MAX as u64 && n.to_string() == text)
}

impl Definition {
    /// Swift `decodeWorkspacePresetDefinition`: the mutation keys and the
    /// definition's required keys present, nothing outside them and the
    /// optional keys, every value typed. `None` is Swift's `invalidParams`.
    pub(super) fn from_params(params: &Map<String, Value>, mutation_keys: &[&str]) -> Option<Self> {
        let required: Vec<&str> = mutation_keys
            .iter()
            .copied()
            .chain(["kind", "templateRef", "timeoutSeconds"])
            .collect();
        if required.iter().any(|key| !params.contains_key(*key))
            || params.keys().any(|key| {
                !required.contains(&key.as_str())
                    && !OPTIONAL_DEFINITION_KEYS.contains(&key.as_str())
            })
        {
            return None;
        }
        let kind = params["kind"].as_str()?;
        let template_ref = params["templateRef"].as_str()?;
        let timeout = canonical_positive(params.get("timeoutSeconds"))?;
        if OPTIONAL_DEFINITION_KEYS
            .iter()
            .filter(|key| **key != "toolchainGeneration")
            .any(|key| params.get(*key).is_some_and(|value| !value.is_string()))
        {
            return None;
        }
        let toolchain_generation = match params.get("toolchainGeneration") {
            Some(value) => Some(canonical_positive(Some(value))?),
            None => None,
        };
        let text = |key: &str| params.get(key).and_then(Value::as_str).map(String::from);
        Some(Self {
            kind: kind.into(),
            template_ref: template_ref.into(),
            toolchain_ref: text("toolchainRef"),
            toolchain_generation,
            credential_ref: text("credentialRef"),
            timeout_seconds: i64::try_from(timeout).ok()?,
            constraints: Constraints {
                module: text("module"),
                product: text("product"),
                build_mode: text("buildMode"),
                relative_source_map: text("relativeSourceMap"),
            },
        })
    }

    /// Swift `validatePresetDefinition`, check for check and message for
    /// message.
    pub(super) fn validate(&self) -> Result<(), WireError> {
        let refuse = |message: &str| Err(failure("invalidInput", message));
        let Some(template) = template_for(&self.kind) else {
            return refuse("workspace preset kind must be build, test, signing or symbol");
        };
        if template != self.template_ref {
            return refuse("workspace preset template does not match its kind");
        }
        if !(1..=3600).contains(&self.timeout_seconds) {
            return refuse("workspace preset timeout must be between 1 and 3600 seconds");
        }
        if let Some(generation) = self.toolchain_generation {
            validate_generation(generation)?;
        }
        if self.toolchain_ref.is_none() != self.toolchain_generation.is_none() {
            return refuse("workspace preset toolchain reference and generation are inseparable");
        }
        if self
            .toolchain_ref
            .as_deref()
            .is_some_and(|reference| !toolchain_reference(reference))
        {
            return refuse("workspace preset toolchain reference is malformed");
        }
        if self
            .credential_ref
            .as_deref()
            .is_some_and(|reference| !credential_reference(reference))
        {
            return refuse("workspace preset credential reference is malformed");
        }
        let c = &self.constraints;
        let id = |value: &Option<String>, max: usize| {
            value.as_deref().is_some_and(|value| identifier(value, max))
        };
        match self.kind.as_str() {
            "build" | "test" => {
                if self.toolchain_ref.is_none()
                    || self.credential_ref.is_some()
                    || !id(&c.module, 128)
                    || !id(&c.product, 128)
                    || !id(&c.build_mode, 64)
                    || c.relative_source_map.is_some()
                {
                    return refuse(
                        "build and test presets require a toolchain, module, product and build mode",
                    );
                }
            }
            "signing" => {
                if self.toolchain_ref.is_none()
                    || self.credential_ref.is_none()
                    || c.module.is_some()
                    || c.product.is_some()
                    || c.build_mode.is_some()
                    || c.relative_source_map.is_some()
                {
                    return refuse(
                        "signing presets require only toolchain and credential references",
                    );
                }
            }
            _ => {
                if self.toolchain_ref.is_some()
                    || self.credential_ref.is_some()
                    || c.module.is_some()
                    || c.product.is_some()
                    || c.build_mode.is_some()
                    || !c.relative_source_map.as_deref().is_some_and(relative_path)
                {
                    return refuse("symbol presets require one bounded relative source-map path");
                }
            }
        }
        Ok(())
    }

    /// Swift `presetDigest`: the canonical definition document of `project`.
    pub(super) fn digest(&self, project: &str) -> Result<String, WireError> {
        let document = json!({
            "schemaVersion": "arkdeck.workspace-preset-definition/1",
            "projectRef": project,
            "kind": self.kind,
            "templateRef": self.template_ref,
            "toolchainRef": self.toolchain_ref,
            "toolchainGeneration": self.toolchain_generation.map(|n| n.to_string()),
            "credentialRef": self.credential_ref,
            "timeoutSeconds": self.timeout_seconds,
            "constraints": self.constraints,
        });
        arkdeck_contract::canonical_json(&document)
            .map(|bytes| sha256_hex(&bytes))
            .map_err(unreadable)
    }

    fn pins(&self) -> bool {
        self.toolchain_ref.is_some() || self.credential_ref.is_some()
    }
}

fn template_for(kind: &str) -> Option<&'static str> {
    match kind {
        "build" => Some("openharmony.hvigor-build@1"),
        "test" => Some("openharmony.hvigor-test@1"),
        "signing" => Some("openharmony.local-sign@1"),
        "symbol" => Some("openharmony.arkts-symbol@1"),
        _ => None,
    }
}

/// Swift `validToolchainRef`.
pub(super) fn toolchain_reference(value: &str) -> bool {
    value
        .strip_prefix("toolchain:sha256:")
        .is_some_and(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// Swift `validCredentialRef`.
pub(super) fn credential_reference(value: &str) -> bool {
    value
        .strip_prefix("credential:")
        .is_some_and(|rest| identifier(rest, 128))
}

/// Swift `validRelativePath`.
fn relative_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 1024
        && !value.starts_with('/')
        && !value.contains('\0')
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

/// Swift `validateRequestID`, for registration and mutation identities alike.
pub(super) fn validate_request_id(value: &str) -> Result<(), WireError> {
    if identifier(value, 128) {
        Ok(())
    } else {
        Err(failure(
            "invalidInput",
            "registration request identity is malformed",
        ))
    }
}

/// Swift `validateProjectRef`.
pub(super) fn validate_project_ref(value: &str) -> Result<(), WireError> {
    if identifier(value, 128) {
        Ok(())
    } else {
        Err(failure(
            "invalidInput",
            "workspace project reference is malformed",
        ))
    }
}

/// Swift `validatePresetRef`.
pub(super) fn validate_preset_ref(value: &str) -> Result<(), WireError> {
    if value.starts_with("preset-") && identifier(value, 128) {
        Ok(())
    } else {
        Err(failure(
            "invalidInput",
            "workspace preset reference is malformed",
        ))
    }
}

/// Swift `validateGeneration`.
pub(super) fn validate_generation(value: u64) -> Result<(), WireError> {
    if value > 0 && value <= i64::MAX as u64 {
        Ok(())
    } else {
        Err(failure(
            "invalidInput",
            "workspace project generation must be a canonical positive integer",
        ))
    }
}

/// Swift `presetRef(requestID:)`.
fn preset_reference(request: &str) -> String {
    format!("preset-{}", &sha256_hex(request.as_bytes())[..24])
}

/// Swift `presetMutationDigest(verb: "update", ...)` of a definition digest.
fn update_digest(project: &str, preset: &str, expected: u64, definition: &str) -> String {
    sha256_hex(format!("update\0{project}\0{preset}\0{expected}\0{definition}").as_bytes())
}

/// Swift `removalDigest`.
fn removal_digest(request: &str, project: &str, preset: &str, expected: u64) -> String {
    sha256_hex(format!("remove\0{request}\0{project}\0{preset}\0{expected}").as_bytes())
}

/// Swift's daemon answers a malformed request with no owner details.
pub(super) fn invalid_params(message: &str) -> WireError {
    WireError {
        code: "invalidParams".into(),
        message: message.into(),
        details: None,
    }
}

/// Swift's generation advance for a preset mutation.
fn advanced(expected: u64) -> Result<u64, WireError> {
    expected
        .checked_add(1)
        .filter(|next| *next <= i64::MAX as u64)
        .ok_or_else(|| {
            failure(
                "resourceConflict",
                "workspace preset generation is exhausted",
            )
        })
}

impl WorkspaceProjectStore {
    pub(super) fn handle_preset_mutation(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &dyn Fn() -> String,
        census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        let text = |key: &str| params.get(key).and_then(Value::as_str);
        let answer = match method {
            "workspace.preset.register" => {
                let definition =
                    Definition::from_params(params, &["registrationRequestId", "projectRef"])
                        .filter(|_| {
                            text("registrationRequestId").is_some() && text("projectRef").is_some()
                        })
                        .ok_or_else(|| {
                            invalid_params(
                                "workspace preset register requires one closed typed definition",
                            )
                        })?;
                self.register_preset(
                    text("registrationRequestId").unwrap(),
                    text("projectRef").unwrap(),
                    &definition,
                    now,
                )
            }
            "workspace.preset.update" => {
                let mutation = ["mutationRequestId", "projectRef", "presetRef"];
                let definition = Definition::from_params(
                    params,
                    &[
                        "mutationRequestId",
                        "projectRef",
                        "presetRef",
                        "expectedGeneration",
                    ],
                )
                .filter(|_| mutation.iter().all(|key| text(key).is_some()));
                let generation = canonical_positive(params.get("expectedGeneration"));
                let (Some(definition), Some(generation)) = (definition, generation) else {
                    return Err(invalid_params(
                        "workspace preset update requires identity, exact generation and definition",
                    ));
                };
                self.update_preset(
                    text("mutationRequestId").unwrap(),
                    text("projectRef").unwrap(),
                    text("presetRef").unwrap(),
                    generation,
                    &definition,
                    now,
                    census,
                )
            }
            "workspace.preset.remove" => {
                let keys = [
                    "mutationRequestId",
                    "projectRef",
                    "presetRef",
                    "expectedGeneration",
                ];
                let generation = canonical_positive(params.get("expectedGeneration"));
                if params.len() != keys.len()
                    || keys.iter().any(|key| text(key).is_none())
                    || generation.is_none()
                {
                    return Err(invalid_params(
                        "workspace preset remove requires identity and exact generation",
                    ));
                }
                self.remove_preset(
                    text("mutationRequestId").unwrap(),
                    text("projectRef").unwrap(),
                    text("presetRef").unwrap(),
                    generation.unwrap(),
                    now,
                    census,
                )
            }
            _ => Err(failure("unknownMethod", "not a workspace preset method")),
        };
        answer.map_err(super::mutations::preset_phase)
    }

    fn register_preset(
        &self,
        request: &str,
        project: &str,
        definition: &Definition,
        now: &dyn Fn() -> String,
    ) -> Result<Value, WireError> {
        validate_request_id(request)?;
        validate_project_ref(project)?;
        definition.validate()?;
        let digest = definition.digest(project)?;
        let preset = preset_reference(request);
        self.with_document(
            || Ok(()),
            |transaction, document| {
                let mut next = document;
                if let Some(existing) = next
                    .presets
                    .iter()
                    .find(|candidate| candidate.registration_request_id == request)
                {
                    if existing.registration_digest != digest || existing.preset_ref != preset {
                        return Err(failure(
                            "idempotencyConflict",
                            "registration request identity belongs to another preset",
                        ));
                    }
                    return self.preset_resource(existing);
                }
                if !next
                    .records
                    .iter()
                    .any(|record| record.project_ref == project)
                {
                    return Err(failure(
                        "workspaceReferenceNotFound",
                        "workspace project is not registered",
                    ));
                }
                if next.presets.len() >= 256 {
                    return Err(failure(
                        "quotaExceeded",
                        "workspace preset registration limit is reached",
                    ));
                }
                let at = valid_timestamp(now)?;
                let record = PresetRecord {
                    preset_ref: preset.clone(),
                    generation: 1,
                    project_ref: project.into(),
                    kind: definition.kind.clone(),
                    template_ref: definition.template_ref.clone(),
                    toolchain_ref: definition.toolchain_ref.clone(),
                    toolchain_generation: definition.toolchain_generation,
                    credential_ref: definition.credential_ref.clone(),
                    timeout_seconds: definition.timeout_seconds,
                    constraints: definition.constraints.clone(),
                    registration_request_id: request.into(),
                    registration_project_ref: project.into(),
                    registration_kind: definition.kind.clone(),
                    registration_template_ref: definition.template_ref.clone(),
                    registration_toolchain_ref: definition.toolchain_ref.clone(),
                    registration_toolchain_generation: definition.toolchain_generation,
                    registration_credential_ref: definition.credential_ref.clone(),
                    registration_timeout_seconds: definition.timeout_seconds,
                    registration_constraints: definition.constraints.clone(),
                    registration_digest: digest.clone(),
                    current_definition_digest: digest.clone(),
                    registered_at: at.clone(),
                    updated_at: at,
                    state: "available".into(),
                    last_mutation_request_id: request.into(),
                    last_mutation_digest: digest.clone(),
                };
                if definition.pins() {
                    self.require_preset_dependencies(
                        project,
                        definition.toolchain_ref.as_deref(),
                        definition.credential_ref.as_deref(),
                    )?;
                    next.pending = Some(PendingMutation {
                        action: "acquire".into(),
                        toolchain_ref: definition.toolchain_ref.clone(),
                        toolchain_generation: definition.toolchain_generation,
                        credential_ref: definition.credential_ref.clone(),
                        preset_ref: preset.clone(),
                        proposed_record: Some(record),
                        release_after_acquire_ref: None,
                        release_after_acquire_credential_ref: None,
                    });
                    transaction.save(&next)?;
                    next = self.reconcile(transaction, next)?;
                } else {
                    next.presets.push(record);
                    next.presets
                        .sort_by(|left, right| left.preset_ref.cmp(&right.preset_ref));
                    transaction.save(&next)?;
                }
                next.presets
                    .iter()
                    .find(|candidate| candidate.preset_ref == preset)
                    .ok_or_else(|| {
                        failure(
                            "outcomeUnknown",
                            "workspace preset publication could not be verified",
                        )
                    })
                    .and_then(|record| self.preset_resource(record))
            },
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn update_preset(
        &self,
        request: &str,
        project: &str,
        preset: &str,
        expected: u64,
        definition: &Definition,
        now: &dyn Fn() -> String,
        census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        validate_request_id(request)?;
        validate_project_ref(project)?;
        validate_preset_ref(preset)?;
        validate_generation(expected)?;
        definition.validate()?;
        let mutation_digest =
            update_digest(project, preset, expected, &definition.digest(project)?);
        // Swift's process lock covers the in-process use tokens and the
        // durable Job census.
        self.with_document(
            || {
                self.require_no_preset_use(preset)?;
                census(WorkspaceReference::Preset(preset))
            },
            |transaction, document| {
                let mut next = document;
                let index = next
                    .presets
                    .iter()
                    .position(|candidate| {
                        candidate.project_ref == project && candidate.preset_ref == preset
                    })
                    .ok_or_else(|| {
                        failure(
                            "workspaceReferenceNotFound",
                            "workspace preset is not registered",
                        )
                    })?;
                let current = next.presets[index].clone();
                if current.last_mutation_request_id == request {
                    if current.last_mutation_digest != mutation_digest {
                        return Err(failure(
                            "idempotencyConflict",
                            "mutation request identity belongs to another preset update",
                        ));
                    }
                    return self.preset_resource(&current);
                }
                if !current.available() || current.generation != expected {
                    return Err(failure(
                        "resourceConflict",
                        "workspace preset generation changed",
                    ));
                }
                let generation = advanced(expected)?;
                let current_definition_digest = definition.digest(&current.project_ref)?;
                let proposed = PresetRecord {
                    generation,
                    kind: definition.kind.clone(),
                    template_ref: definition.template_ref.clone(),
                    toolchain_ref: definition.toolchain_ref.clone(),
                    toolchain_generation: definition.toolchain_generation,
                    credential_ref: definition.credential_ref.clone(),
                    timeout_seconds: definition.timeout_seconds,
                    constraints: definition.constraints.clone(),
                    current_definition_digest,
                    updated_at: valid_timestamp(now)?,
                    state: "available".into(),
                    last_mutation_request_id: request.into(),
                    last_mutation_digest: mutation_digest.clone(),
                    ..current.clone()
                };
                if definition.toolchain_ref != current.toolchain_ref
                    || definition.toolchain_generation != current.toolchain_generation
                    || definition.credential_ref != current.credential_ref
                {
                    if definition.pins() {
                        self.require_preset_dependencies(
                            &current.project_ref,
                            definition.toolchain_ref.as_deref(),
                            definition.credential_ref.as_deref(),
                        )?;
                        next.pending = Some(PendingMutation {
                            action: "acquire".into(),
                            toolchain_ref: definition.toolchain_ref.clone(),
                            toolchain_generation: definition.toolchain_generation,
                            credential_ref: definition.credential_ref.clone(),
                            preset_ref: preset.into(),
                            proposed_record: Some(proposed),
                            release_after_acquire_ref: current
                                .toolchain_ref
                                .clone()
                                .filter(|_| current.toolchain_ref != definition.toolchain_ref),
                            release_after_acquire_credential_ref: current
                                .credential_ref
                                .clone()
                                .filter(|_| current.credential_ref != definition.credential_ref),
                        });
                    } else {
                        next.presets[index] = proposed;
                        if current.toolchain_ref.is_some() || current.credential_ref.is_some() {
                            self.require_dependency_owners(
                                current.toolchain_ref.as_deref(),
                                current.credential_ref.as_deref(),
                            )?;
                            next.pending = Some(PendingMutation::release(
                                preset,
                                current.toolchain_ref.clone(),
                                current.toolchain_generation,
                                current.credential_ref.clone(),
                            ));
                        }
                    }
                    transaction.save(&next)?;
                    next = self.reconcile(transaction, next)?;
                } else {
                    next.presets[index] = proposed;
                    transaction.save(&next)?;
                }
                next.presets
                    .iter()
                    .find(|candidate| candidate.preset_ref == preset)
                    .ok_or_else(|| {
                        failure(
                            "outcomeUnknown",
                            "workspace preset update could not be verified",
                        )
                    })
                    .and_then(|record| self.preset_resource(record))
            },
        )
    }

    fn remove_preset(
        &self,
        request: &str,
        project: &str,
        preset: &str,
        expected: u64,
        now: &dyn Fn() -> String,
        census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        validate_request_id(request)?;
        validate_project_ref(project)?;
        validate_preset_ref(preset)?;
        validate_generation(expected)?;
        let mutation_digest = removal_digest(request, project, preset, expected);
        self.with_document(
            || {
                self.require_no_preset_use(preset)?;
                census(WorkspaceReference::Preset(preset))
            },
            |transaction, document| {
                let mut next = document;
                let index = next
                    .presets
                    .iter()
                    .position(|candidate| {
                        candidate.project_ref == project && candidate.preset_ref == preset
                    })
                    .ok_or_else(|| {
                        failure(
                            "workspaceReferenceNotFound",
                            "workspace preset is not registered",
                        )
                    })?;
                let current = next.presets[index].clone();
                if current.last_mutation_request_id == request {
                    if current.last_mutation_digest != mutation_digest {
                        return Err(failure(
                            "idempotencyConflict",
                            "mutation request identity belongs to another preset removal",
                        ));
                    }
                    return self.preset_resource(&current);
                }
                if !current.available() || current.generation != expected {
                    return Err(failure(
                        "resourceConflict",
                        "workspace preset generation changed",
                    ));
                }
                let generation = advanced(expected)?;
                let removed = &mut next.presets[index];
                removed.generation = generation;
                removed.state = "removed".into();
                removed.updated_at = valid_timestamp(now)?;
                removed.last_mutation_request_id = request.into();
                removed.last_mutation_digest = mutation_digest.clone();
                if current.toolchain_ref.is_some() || current.credential_ref.is_some() {
                    self.require_dependency_owners(
                        current.toolchain_ref.as_deref(),
                        current.credential_ref.as_deref(),
                    )?;
                    next.pending = Some(PendingMutation::release(
                        preset,
                        current.toolchain_ref.clone(),
                        current.toolchain_generation,
                        current.credential_ref.clone(),
                    ));
                }
                transaction.save(&next)?;
                let next = self.reconcile(transaction, next)?;
                self.forget_applied_preset(preset);
                self.preset_resource(&next.presets[index])
            },
        )
    }
}

/// Swift `validTimestamp()`: the injected clock, read where Swift reads it.
pub(super) fn valid_timestamp(now: &dyn Fn() -> String) -> Result<String, WireError> {
    let at = now();
    if timestamp(&at).is_none() {
        return Err(failure(
            "recordUnreadable",
            "workspace project clock is unavailable",
        ));
    }
    Ok(at)
}

impl Document {
    /// Swift `validatePresetRecord`, which the acquire transaction applies to
    /// the record it is about to publish.
    pub(super) fn validate_proposed(&self, preset: &PresetRecord) -> Result<(), WireError> {
        validate_preset_ref(&preset.preset_ref)?;
        validate_project_ref(&preset.project_ref)?;
        validate_generation(preset.generation)?;
        validate_request_id(&preset.registration_request_id)?;
        validate_request_id(&preset.last_mutation_request_id)?;
        let registration = Definition {
            kind: preset.registration_kind.clone(),
            template_ref: preset.registration_template_ref.clone(),
            toolchain_ref: preset.registration_toolchain_ref.clone(),
            toolchain_generation: preset.registration_toolchain_generation,
            credential_ref: preset.registration_credential_ref.clone(),
            timeout_seconds: preset.registration_timeout_seconds,
            constraints: preset.registration_constraints.clone(),
        };
        registration.validate()?;
        let current = Definition {
            kind: preset.kind.clone(),
            template_ref: preset.template_ref.clone(),
            toolchain_ref: preset.toolchain_ref.clone(),
            toolchain_generation: preset.toolchain_generation,
            credential_ref: preset.credential_ref.clone(),
            timeout_seconds: preset.timeout_seconds,
            constraints: preset.constraints.clone(),
        };
        current.validate()?;
        if !((preset.state == "available" && preset.generation >= 1)
            || (preset.state == "removed" && preset.generation >= 2))
        {
            return Err(failure(
                "recordUnreadable",
                "workspace preset state and generation are inconsistent",
            ));
        }
        let registration_digest = registration.digest(&preset.registration_project_ref)?;
        let current_digest = current.digest(&preset.project_ref)?;
        let last = if preset.state == "removed" {
            removal_digest(
                &preset.last_mutation_request_id,
                &preset.project_ref,
                &preset.preset_ref,
                preset.generation - 1,
            )
        } else if preset.generation == 1 {
            registration_digest.clone()
        } else {
            update_digest(
                &preset.project_ref,
                &preset.preset_ref,
                preset.generation - 1,
                &current_digest,
            )
        };
        if !self
            .records
            .iter()
            .any(|record| record.project_ref == preset.project_ref)
            || preset.registration_project_ref != preset.project_ref
            || preset.registration_digest != registration_digest
            || preset.current_definition_digest != current_digest
            || preset.last_mutation_digest != last
            || !(preset.generation > 1
                || preset.last_mutation_request_id == preset.registration_request_id)
            || !timestamp(&preset.registered_at)
                .zip(timestamp(&preset.updated_at))
                .is_some_and(|(registered, updated)| updated >= registered)
        {
            return Err(failure(
                "recordUnreadable",
                "workspace preset store record is inconsistent",
            ));
        }
        Ok(())
    }
}
