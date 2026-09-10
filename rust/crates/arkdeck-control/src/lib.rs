//! Transport-free handlers for the current control contract.

use arkdeck_contract::{
    CATALOG_CANONICAL_JSON, CATALOG_DIGEST, CONTRACT_IDENTITY, ContractError,
    DeviceObservationsResult, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS, PROTOCOL_VERSION,
    Response, WireError, decode_request, encode_frame, sha256_hex, strict_json,
    validate_method_value,
};
use serde_json::{Value, json};

/// The composition root supplies local resources and device observations.
/// This interface provides no device mutation or authority administration.
pub trait HostServices: Send + Sync {
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
            "history.filter.list" | "history.filter.save" | "history.filter.delete" => Response {
                id: request.id.clone(),
                outcome: self.host.history_filter(&request.method, &params),
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
            Some(json!({"unavailableOperationCount":count})),
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
