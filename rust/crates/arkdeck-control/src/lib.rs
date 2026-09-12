//! Transport-free handlers for the current control contract.

use arkdeck_contract::{
    CATALOG_CANONICAL_JSON, CATALOG_DIGEST, CONTRACT_IDENTITY, ContractError,
    DeviceObservationsResult, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS, PROTOCOL_VERSION,
    Response, WireError, decode_request, encode_frame, sha256_hex, strict_json,
    validate_method_value,
};
use serde_json::{Value, json};
mod operation_description;

/// The composition root supplies local resources and device observations.
/// This interface provides no device mutation or authority administration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootstrapRegistryKind {
    Tool,
    Bundle,
}

pub trait HostServices: Send + Sync {
    fn bootstrap_register_bundle(&self, _file: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bundle registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn job_resource(&self, _method: &str, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError { code: "rejected".into(), message: "The Job owner is not configured".into(), details: None })
    }
    fn bootstrap_register_deveco(&self, _root: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "DevEco registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_register_hdc(&self, _file: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "HDC registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn trace_cache_status(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Trace cache owner is not configured".into(),
            details: None,
        })
    }
    fn bootstrap_bundle_list(
        &self,
        _page_size: usize,
        _cursor: Option<&str>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap bundle list owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_inspect(
        &self,
        _kind: BootstrapRegistryKind,
        _reference: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap read owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }

    fn session_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Session owner is not configured".into(),
            details: None,
        })
    }
    fn runtime_storage(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Runtime storage owners are not configured".into(),
            details: None,
        })
    }
    fn history_filter(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "History filter owner is not configured".into(),
            details: None,
        })
    }
    fn bootstrap_bundle_remove(
        &self,
        _reference: &str,
        _generation: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bundle retirement owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_tool_remove(
        &self,
        _reference: &str,
        _generation: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Tool retirement owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_tool_list(
        &self,
        _page_size: usize,
        _cursor: Option<&str>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap bundle list owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn observed_at(&self) -> String;
    fn hdc_status(&self, deep: bool) -> HdcStatus;
    fn observations(&self) -> Result<DeviceObservationsResult, WireError>;
}

#[derive(Debug, Clone)]
pub struct HdcStatus {
    pub configured: bool,
    pub checked: bool,
    pub availability: String,
    pub ownership: String,
    pub server_health: String,
    pub reason_code: String,
}

impl HdcStatus {
    pub fn unavailable(deep: bool, reason_code: &str) -> Self {
        Self {
            configured: false,
            checked: deep,
            availability: "unavailable".into(),
            ownership: "unknown".into(),
            server_health: "unknown".into(),
            reason_code: reason_code.into(),
        }
    }
}

pub struct Control<H> {
    host: H,
    operations: Value,
}

impl<H: HostServices> Control<H> {
    pub fn new(host: H) -> Result<Self, ContractError> {
        if sha256_hex(CATALOG_CANONICAL_JSON.as_bytes()) != CATALOG_DIGEST {
            return Err(ContractError::ContractMismatch);
        }
        let catalog: Vec<Value> =
            serde_json::from_str(CATALOG_CANONICAL_JSON).map_err(|_| ContractError::Malformed)?;
        // This foundation owns discovery, not the full HDC operation provider.
        // Advertising an available operation before its lowering exists would
        // claim an execution path the daemon cannot provide.
        let operations = Value::Array(catalog.iter().map(|d| {
            let reference = match d["version"].as_u64() {
                Some(version) => format!("{}@{version}", d["id"].as_str().expect("Catalog id")),
                None => d["id"].as_str().expect("Catalog id").to_owned(),
            };
            json!({"reference":reference,"canonicalReference":reference,"aliasFor":d.get("aliasFor").unwrap_or(&Value::Null),
                "minimumEffect":d["effect"]["minimum"],"binding":d["binding"],"profiles":d["profiles"],
                "availability":"unavailable","reasonCodes":["provider_not_registered"],"reasonOrigins":["product_build"],
                "reasons":[format!("provider {} is not registered",d["provider"].as_str().expect("Catalog provider"))]})
        }).collect());
        validate_method_value("operation.list", "result", &operations)?;
        Ok(Self { host, operations })
    }

    /// Payload excludes its LF delimiter. Every path returns one bounded frame.
    pub fn handle_frame(&self, bytes: &[u8]) -> Vec<u8> {
        let request = match decode_request(bytes) {
            Ok(request) => request,
            Err(error) => {
                let (code, message) = match error {
                    ContractError::UnsupportedVersion => (
                        "unsupportedProtocolVersion",
                        "this Runtime requires exactly 1.0.0",
                    ),
                    ContractError::ContractMismatch => (
                        "unsupportedProtocolVersion",
                        "client and Runtime must use the same current control contract",
                    ),
                    ContractError::UnknownMethod => {
                        ("unknownMethod", "method is not published by this Runtime")
                    }
                    _ => ("malformedFrame", "undecodable current request frame"),
                };
                let id = if matches!(
                    error,
                    ContractError::UnsupportedVersion
                        | ContractError::ContractMismatch
                        | ContractError::UnknownMethod
                ) {
                    frame_id(bytes)
                } else {
                    "-".into()
                };
                return response_bytes(Response::failure(id, code, message));
            }
        };
        let params = request.params.unwrap_or_default();
        let response = match request.method.as_str() {
            "health" if params.is_empty() => Response::success(
                &request.id,
                json!({
                "status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,
                "catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}),
            ),
            "health" => {
                Response::failure(&request.id, "invalidParams", "health accepts no parameters")
            }
            "operation.list" if params.is_empty() => {
                Response::success(&request.id, self.operations.clone())
            }
            "operation.list" => Response::failure(
                &request.id,
                "invalidParams",
                "operation.list accepts no parameters",
            ),
            "operation.describe" => {
                if params.len() != 1 || !params.get("reference").is_some_and(Value::is_string) {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "an exact operation reference is required",
                    )
                } else {
                    let reference = params["reference"].as_str().expect("checked reference");
                    match self
                        .operations
                        .as_array()
                        .expect("Catalog operations")
                        .iter()
                        .find(|v| v["reference"] == reference)
                    {
                        None => Response::failure(
                            &request.id,
                            "notFound",
                            "operation reference does not exist",
                        ),
                        Some(availability) => {
                            match operation_description::describe(reference, availability) {
                                Ok(Some(result)) => Response::success(&request.id, result),
                                _ => Response::failure(
                                    &request.id,
                                    "internalError",
                                    "Catalog descriptor could not be projected",
                                ),
                            }
                        }
                    }
                }
            }
            "doctor" => {
                if params.keys().any(|k| k != "deep") {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "doctor accepts only the deep boolean",
                    )
                } else if params.get("deep").is_some_and(|v| !v.is_boolean()) {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "doctor deep must be a boolean",
                    )
                } else {
                    Response::success(
                        &request.id,
                        self.doctor(params.get("deep").and_then(Value::as_bool).unwrap_or(false)),
                    )
                }
            }
            "device.observations" => {
                if params.keys().any(|k| k != "following") {
                    observation_failure(
                        &request.id,
                        "invalidInput",
                        "device observations accepts only following",
                        None,
                    )
                } else if let Some(reference) = params.get("following") {
                    // No durable relation or retained snapshot exists in this
                    // foundation. Do not turn a caller reference into identity.
                    if valid_observation_reference(reference) {
                        observation_failure(
                            &request.id,
                            "resourceConflict",
                            "the referenced observation is not retained by this Runtime",
                            Some(reference),
                        )
                    } else {
                        observation_failure(
                            &request.id,
                            "invalidInput",
                            "candidate, observationId and canonical positive observationGeneration are required",
                            None,
                        )
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.observations().and_then(|snapshot| {
                            serde_json::to_value(snapshot).map_err(|_| WireError {
                                code: "internalError".into(),
                                message: "observation encoding failed".into(),
                                details: None,
                            })
                        }),
                    }
                }
            }
            "trace.cache.status" if params.is_empty() => Response {
                id: request.id.clone(),
                outcome: self.host.trace_cache_status(),
            },
            "trace.cache.status" => Response::failure(
                &request.id,
                "invalidParams",
                "Trace cache status accepts no parameters",
            ),
            "runtime.bundle.register" => {
                let file = params.get("file").and_then(Value::as_str);
                if params.len() != 2
                    || params.get("kind") != Some(&json!("daemon-bundle"))
                    || !file.is_some_and(|path| {
                        path.starts_with('/')
                            && path.len() <= 16_384
                            && !path.contains('\0')
                            && !path.split('/').any(|part| matches!(part, "." | ".."))
                    })
                {
                    Response { id: request.id.clone(), outcome: Err(WireError {
                        code: "invalidParams".into(), message: "Bundle registration requires kind daemon-bundle and an absolute local file".into(),
                        details: Some(serde_json::Map::from_iter([("phase".into(), json!("bootstrapRegistryOwner")), ("newDispatchCount".into(), json!(0))])),
                    }) }
                } else {
                    return bootstrap_mutation_response_bytes(
                        "runtime.bundle.register",
                        Response {
                            id: request.id.clone(),
                            outcome: self
                                .host
                                .bootstrap_register_bundle(file.expect("validated file")),
                        },
                    );
                }
            }
            "runtime.tool.register" => {
                let kind = params.get("kind").and_then(Value::as_str);
                let key = match kind {
                    Some("hdc") => "file",
                    _ => "root",
                };
                let root = params.get(key).and_then(Value::as_str);
                if params.len() != 2
                    || !matches!(kind, Some("deveco" | "hdc"))
                    || !root.is_some_and(|path| {
                        path.starts_with('/')
                            && !path.as_bytes().contains(&0)
                            && !path.split('/').any(|part| matches!(part, "." | ".."))
                    })
                {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "Tool registration requires kind and its absolute local path"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    return bootstrap_mutation_response_bytes(
                        "runtime.tool.register",
                        Response {
                            id: request.id.clone(),
                            outcome: if kind == Some("hdc") {
                                self.host
                                    .bootstrap_register_hdc(root.expect("validated file"))
                            } else {
                                self.host
                                    .bootstrap_register_deveco(root.expect("validated root"))
                            },
                        },
                    );
                }
            }
            "runtime.tool.list" => {
                let size = match params.get("pageSize") {
                    None => Some(100),
                    Some(value) => value.as_i64(),
                };
                let cursor = params.get("cursor");
                let valid = params
                    .keys()
                    .all(|key| matches!(key.as_str(), "pageSize" | "cursor"))
                    && size.is_some()
                    && cursor.is_none_or(Value::is_string);
                if !valid {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "tool list accepts only integer pageSize and string cursor"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.bootstrap_tool_list(
                            usize::try_from(size.expect("checked integer")).unwrap_or(0),
                            cursor.and_then(Value::as_str),
                        ),
                    }
                }
            }
            "runtime.bundle.list" => {
                let size = match params.get("pageSize") {
                    None => Some(100),
                    Some(value) => value.as_i64(),
                };
                let cursor = params.get("cursor");
                let valid = params
                    .keys()
                    .all(|key| matches!(key.as_str(), "pageSize" | "cursor"))
                    && size.is_some()
                    && cursor.is_none_or(Value::is_string);
                if !valid {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "bundle list accepts only integer pageSize and string cursor"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.bootstrap_bundle_list(
                            usize::try_from(size.expect("checked integer")).unwrap_or(0),
                            cursor.and_then(Value::as_str),
                        ),
                    }
                }
            }
            "runtime.bundle.remove" => {
                let reference = params.get("bundle").and_then(Value::as_str);
                let generation = params.get("expectedGeneration").and_then(Value::as_str);
                let outcome = if let (2, Some(reference), Some(generation)) =
                    (params.len(), reference, generation)
                {
                    self.host.bootstrap_bundle_remove(reference, generation)
                } else {
                    Err(WireError {
                        code: "invalidParams".into(),
                        message:
                            "bundle retirement requires typed bundle and expectedGeneration strings"
                                .into(),
                        details: Some(serde_json::Map::from_iter([
                            ("phase".into(), json!("bootstrapRegistryOwner")),
                            ("newDispatchCount".into(), json!(0)),
                        ])),
                    })
                };
                Response {
                    id: request.id.clone(),
                    outcome,
                }
            }
            "runtime.tool.remove" => {
                let reference = params.get("tool").and_then(Value::as_str);
                let generation = params.get("expectedGeneration").and_then(Value::as_str);
                let outcome = if let (2, Some(reference), Some(generation)) =
                    (params.len(), reference, generation)
                {
                    self.host.bootstrap_tool_remove(reference, generation)
                } else {
                    Err(WireError {
                        code: "invalidParams".into(),
                        message:
                            "tool retirement requires typed tool and expectedGeneration strings"
                                .into(),
                        details: Some(serde_json::Map::from_iter([
                            ("phase".into(), json!("bootstrapRegistryOwner")),
                            ("newDispatchCount".into(), json!(0)),
                        ])),
                    })
                };
                Response {
                    id: request.id.clone(),
                    outcome,
                }
            }
            "runtime.tool.inspect" | "runtime.bundle.inspect" => {
                let (key, kind, prefixes): (&str, BootstrapRegistryKind, &[&str]) =
                    if request.method == "runtime.tool.inspect" {
                        (
                            "tool",
                            BootstrapRegistryKind::Tool,
                            &["tool:sha256:", "toolchain:sha256:"],
                        )
                    } else {
                        ("bundle", BootstrapRegistryKind::Bundle, &["bundle:sha256:"])
                    };
                let reference = params.get(key).and_then(Value::as_str);
                if params.len() != 1
                    || !reference.is_some_and(|reference| {
                        prefixes.iter().any(|prefix| {
                            reference.strip_prefix(prefix).is_some_and(|digest| {
                                digest.len() == 64
                                    && digest.bytes().all(|byte| {
                                        byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                                    })
                            })
                        })
                    })
                {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "one exact bootstrap resource reference is required".into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self
                            .host
                            .bootstrap_inspect(kind, reference.expect("checked reference")),
                    }
                }
            }
            "history.filter.list" | "history.filter.save" | "history.filter.delete" => Response {
                id: request.id.clone(),
                outcome: self.host.history_filter(&request.method, &params),
            },
            "job.list" | "job.status" | "job.show" | "job.timeline" => Response {
                id: request.id.clone(),
                outcome: self.host.job_resource(&request.method, &params),
            },
            "session.list"
            | "session.show"
            | "session.pin"
            | "session.unpin"
            | "session.cleanup.preview"
            | "session.export.preview"
            | "session.export.apply" => Response {
                id: request.id.clone(),
                outcome: self.host.session_resource(&request.method, &params),
            },
            "runtime.storage.status" | "runtime.storage.policy" | "runtime.storage.root" => {
                Response {
                    id: request.id.clone(),
                    outcome: self.host.runtime_storage(&request.method, &params),
                }
            }
            _ => Response::failure(
                &request.id,
                "rejected",
                "this method is unavailable in the read-only Rust foundation",
            ),
        };
        if request.method == "runtime.tool.remove" {
            return bootstrap_mutation_response_bytes(&request.method, response);
        }
        let conforms = match &response.outcome {
            Ok(result) => validate_method_value(&request.method, "result", result).is_ok(),
            Err(error) => {
                validate_method_value(&request.method, "errorCode", &json!(error.code)).is_ok()
                    && error.details.as_ref().is_none_or(|details| {
                        validate_method_value(&request.method, "errorDetails", &json!(details))
                            .is_ok()
                    })
            }
        };
        if !conforms {
            return response_bytes(Response::failure(
                request.id,
                "internalError",
                "the result does not conform to the current contract",
            ));
        }
        response_bytes(response)
    }

    fn doctor(&self, deep: bool) -> Value {
        let hdc = self.host.hdc_status(deep);
        let count = self
            .operations
            .as_array()
            .expect("Catalog operations")
            .len();
        let mut findings = Vec::new();
        let mut add =
            |code: &str, severity: &str, scope: &str, summary: &str, details: Option<Value>| {
                let mut row =
                    json!({"code":code,"severity":severity,"scope":scope,"summary":summary});
                if let Some(details) = details {
                    row["details"] = details;
                }
                findings.push(row);
            };
        add(
            "runtime.controlReady",
            "info",
            "runtime",
            "the target control protocol is serving bounded diagnostic requests",
            None,
        );
        add(
            "catalog.noAvailableOperations",
            "blocker",
            "catalog",
            "the published Catalog has no operation available on this Runtime",
            None,
        );
        add(
            "catalog.unavailableOperations",
            "warning",
            "catalog",
            "some published operations are unavailable with the current host configuration",
            Some(json!({ "unavailableOperationCount": count })),
        );
        add(
            "provider.noneRegistered",
            "blocker",
            "provider",
            "the Runtime has no registered provider",
            None,
        );
        if !hdc.configured {
            add(
                &hdc.reason_code,
                "blocker",
                "hdc",
                if hdc.reason_code == "hdc.notConfigured" {
                    "the Runtime has no bounded HDC status observer"
                } else {
                    "the selected HDC tool or platform observation evidence is unavailable"
                },
                None,
            );
        } else if deep && hdc.availability != "available" {
            add(
                "hdc.identityUnavailable",
                "blocker",
                "hdc",
                "the selected HDC server identity is unavailable or not Runtime-managed",
                None,
            );
        }
        add(
            "storage.artifactStoreNotConfigured",
            "blocker",
            "storage",
            "the Runtime Artifact store is not configured",
            None,
        );
        add(
            "storage.sessionOutputOwnerUnavailable",
            "warning",
            "storage",
            "Session output storage has no published Runtime owner",
            None,
        );
        add(
            "target.storeNotConfigured",
            "blocker",
            "target",
            "the durable target store is not configured",
            None,
        );
        if !hdc.configured {
            add(
                "target.discoveryNotConfigured",
                "blocker",
                "target",
                "device discovery is not configured",
                None,
            );
        }
        if deep {
            add(
                "recovery.notConfigured",
                "blocker",
                "recovery",
                "the Runtime cleanup debt owner is not configured",
                None,
            );
        } else {
            add(
                "recovery.deepCheckSkipped",
                "info",
                "recovery",
                "cleanup debt was not requested; use doctor --deep to check it",
                None,
            );
        }
        let counts = |kind: &str| findings.iter().filter(|v| v["severity"] == kind).count();
        json!({"schemaVersion":"arkdeck.doctor-report/1","mode":if deep {"deep"} else {"standard"},
        "observedAt":self.host.observed_at(),"overall":"blocked","ready":false,
        "findingCounts":{"blocker":counts("blocker"),"warning":counts("warning"),"info":counts("info")},"findings":findings,
        "checks":{
            "runtime":{"protocolVersion":PROTOCOL_VERSION,"runtimeRequestSchemaVersion":"1.0.0"},
            "catalog":{"digest":CATALOG_DIGEST,"operationCount":count,"availableOperationCount":0,"unavailableOperationCount":count},
            "providers":{"registered":[]},
            "hdc":{"configured":hdc.configured,"checked":hdc.checked,"availability":hdc.availability,"ownership":hdc.ownership,"serverHealth":hdc.server_health,"reasonCode":hdc.reason_code},
            "storage":{"runtimeArtifacts":{"configured":false,"checked":false,"totalBytes":null,"usedBytes":null,"remainingBytes":null},
                "sessionOutput":{"availability":"unavailable","checked":false,"reasonCode":"storage.sessionOutputOwnerNotPublished"}},
            "target":{"configured":false,"bootstrapConfigured":hdc.configured,"adoptedTargetCount":null},
            "recovery":{"checked":false,"outstandingCleanupCount":null}
        }})
    }
}

fn valid_observation_reference(value: &Value) -> bool {
    let Some(fields) = value.as_object() else {
        return false;
    };
    fields.len() == 3
        && fields
            .get("candidate")
            .and_then(Value::as_str)
            .is_some_and(|s| (1..=1024).contains(&s.len()))
        && fields
            .get("observationId")
            .and_then(Value::as_str)
            .is_some_and(|s| (1..=128).contains(&s.len()))
        && fields
            .get("observationGeneration")
            .and_then(Value::as_str)
            .is_some_and(|s| {
                !s.starts_with('0')
                    && s.bytes().all(|b| b.is_ascii_digit())
                    && s.parse::<i64>().is_ok_and(|n| n > 0)
            })
}

fn observation_failure(id: &str, code: &str, message: &str, reference: Option<&Value>) -> Response {
    // All callers are before the host entry; this proof is local, not inferred
    // from a timeout, lost reply or external observation failure.
    let mut details = serde_json::Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ]);
    if let Some(reference) = reference {
        for key in ["candidate", "observationId", "observationGeneration"] {
            details.insert(key.into(), reference[key].clone());
        }
    }
    Response {
        id: id.into(),
        outcome: Err(WireError {
            code: code.into(),
            message: message.into(),
            details: Some(details),
        }),
    }
}

fn frame_id(bytes: &[u8]) -> String {
    if bytes.len() >= MAX_REQUEST_BYTES {
        return "-".into();
    }
    strict_json(bytes)
        .ok()
        .and_then(|v| v["id"].as_str().map(str::to_owned))
        .filter(|id| !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c >= '\u{20}'))
        .unwrap_or_else(|| "-".into())
}

// The Bootstrap owner may already have published host metadata. Losing its
// classified receipt must preserve uncertainty, including schema/encoding failure.
fn bootstrap_mutation_response_bytes(method: &str, response: Response) -> Vec<u8> {
    let conforms = match &response.outcome {
        Ok(value) => validate_method_value(method, "result", value).is_ok(),
        Err(error) => {
            validate_method_value(method, "errorCode", &json!(error.code)).is_ok()
                && error.details.as_ref().is_none_or(|details| {
                    validate_method_value(method, "errorDetails", &json!(details)).is_ok()
                })
        }
    };
    if conforms && let Ok(bytes) = encode_frame(&response.value(), MAX_RESPONSE_BYTES) {
        return bytes;
    }
    response_bytes(Response {
        id: response.id,
        outcome: Err(WireError {
            code: "outcomeUnknown".into(),
            message: "Bootstrap mutation did not return a bounded classified receipt".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        }),
    })
}

fn response_bytes(response: Response) -> Vec<u8> {
    encode_frame(&response.value(), MAX_RESPONSE_BYTES).unwrap_or_else(|_| {
        encode_frame(
            &Response::failure(
                response.id,
                "internalError",
                "response exceeds the current frame limit",
            )
            .value(),
            MAX_RESPONSE_BYTES,
        )
        .expect("bounded error response")
    })
}
