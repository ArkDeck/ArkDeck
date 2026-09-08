use crate::{
    CONTRACT_IDENTITY, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS, PROTOCOL_VERSION,
    validate_method_value,
};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Value};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractError {
    Malformed,
    DuplicateKey,
    UnsupportedVersion,
    ContractMismatch,
    UnknownMethod,
    SchemaMismatch,
    IntegerBeyondExactRange,
}

impl fmt::Display for ContractError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ContractError {}

/// Serde's Value normally keeps the last duplicate. Wire parsing must refuse it,
/// including nested duplicates and escaped spellings of the same decoded key.
struct StrictValue(Value);
impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct StrictVisitor;
        impl<'de> Visitor<'de> for StrictVisitor {
            type Value = StrictValue;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("strict JSON")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> Result<Self::Value, E> {
                Ok(StrictValue(v.into()))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> Result<Self::Value, E> {
                Ok(StrictValue(v.into()))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> Result<Self::Value, E> {
                Ok(StrictValue(v.into()))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> Result<Self::Value, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| StrictValue(Value::Number(n)))
                    .ok_or_else(|| E::custom("non-finite number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(StrictValue(v.into()))
            }
            fn visit_string<E: de::Error>(self, v: String) -> Result<Self::Value, E> {
                Ok(StrictValue(v.into()))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(StrictValue(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
                let mut array = Vec::new();
                while let Some(StrictValue(value)) = seq.next_element()? {
                    array.push(value);
                }
                Ok(StrictValue(Value::Array(array)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut object = Map::new();
                while let Some((key, StrictValue(value))) =
                    map.next_entry::<String, StrictValue>()?
                {
                    if object.insert(key, value).is_some() {
                        return Err(de::Error::custom("duplicate key"));
                    }
                }
                Ok(StrictValue(Value::Object(object)))
            }
        }
        deserializer.deserialize_any(StrictVisitor)
    }
}

pub fn strict_json(bytes: &[u8]) -> Result<Value, ContractError> {
    serde_json::from_slice::<StrictValue>(bytes)
        .map(|v| v.0)
        .map_err(|_| ContractError::Malformed)
}

fn wire_object(bytes: &[u8], limit: usize) -> Result<Map<String, Value>, ContractError> {
    if bytes.len() >= limit || bytes.iter().any(|b| *b == b'\n' || *b == b'\r') {
        return Err(ContractError::Malformed);
    }
    match strict_json(bytes)? {
        Value::Object(object) => Ok(object),
        _ => Err(ContractError::Malformed),
    }
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c >= '\u{20}')
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub protocol_version: String,
    pub contract_identity: String,
    pub id: String,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Map<String, Value>>,
}

impl Request {
    pub fn new(
        id: impl Into<String>,
        method: impl Into<String>,
        params: Option<Map<String, Value>>,
    ) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION.into(),
            contract_identity: CONTRACT_IDENTITY.into(),
            id: id.into(),
            method: method.into(),
            params,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WireError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Response {
    pub id: String,
    pub outcome: Result<Value, WireError>,
}

impl Response {
    pub fn success(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            outcome: Ok(result),
        }
    }
    pub fn failure(id: impl Into<String>, code: &str, message: &str) -> Self {
        Self {
            id: id.into(),
            outcome: Err(WireError {
                code: code.into(),
                message: message.into(),
                details: None,
            }),
        }
    }
    pub fn value(&self) -> Value {
        match &self.outcome {
            Ok(result) => serde_json::json!({"id":self.id,"ok":true,"result":result}),
            Err(error) => serde_json::json!({"id":self.id,"ok":false,"error":error}),
        }
    }
}

pub fn decode_request(bytes: &[u8]) -> Result<Request, ContractError> {
    let fields = wire_object(bytes, MAX_REQUEST_BYTES)?;
    if fields.keys().any(|k| {
        ![
            "protocolVersion",
            "contractIdentity",
            "id",
            "method",
            "params",
        ]
        .contains(&k.as_str())
    }) || !fields
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(valid_id)
        || !fields
            .get("method")
            .and_then(Value::as_str)
            .is_some_and(|m| !m.is_empty() && m.len() <= 128)
    {
        return Err(ContractError::Malformed);
    }
    if fields.get("protocolVersion").and_then(Value::as_str) != Some(PROTOCOL_VERSION) {
        return Err(ContractError::UnsupportedVersion);
    }
    if fields.get("contractIdentity").and_then(Value::as_str) != Some(CONTRACT_IDENTITY) {
        return Err(ContractError::ContractMismatch);
    }
    if fields.get("params").is_some_and(|p| !p.is_object()) {
        return Err(ContractError::Malformed);
    }
    let request: Request =
        serde_json::from_value(Value::Object(fields)).map_err(|_| ContractError::Malformed)?;
    if !METHODS.contains(&request.method.as_str()) {
        return Err(ContractError::UnknownMethod);
    }
    Ok(request)
}

pub fn decode_response(
    bytes: &[u8],
    expected_id: &str,
    method: &str,
) -> Result<Response, ContractError> {
    let fields = wire_object(bytes, MAX_RESPONSE_BYTES)?;
    if !valid_id(expected_id)
        || fields.get("id").and_then(Value::as_str) != Some(expected_id)
        || fields.len() != 3
    {
        return Err(ContractError::Malformed);
    }
    let outcome = match fields.get("ok").and_then(Value::as_bool) {
        Some(true) => {
            let result = fields.get("result").ok_or(ContractError::Malformed)?;
            validate_method_value(method, "result", result)?;
            Ok(result.clone())
        }
        Some(false) => {
            let raw_error = fields.get("error").ok_or(ContractError::Malformed)?;
            if raw_error
                .get("details")
                .is_some_and(|details| !details.is_object())
            {
                return Err(ContractError::Malformed);
            }
            let error: WireError =
                serde_json::from_value(raw_error.clone()).map_err(|_| ContractError::Malformed)?;
            if error.code.is_empty() {
                return Err(ContractError::Malformed);
            }
            validate_method_value(method, "errorCode", &Value::String(error.code.clone()))?;
            if let Some(details) = &error.details {
                validate_method_value(method, "errorDetails", &Value::Object(details.clone()))?;
            }
            Err(error)
        }
        _ => return Err(ContractError::Malformed),
    };
    Ok(Response {
        id: expected_id.into(),
        outcome,
    })
}

pub fn validate_health(response: &Response) -> Result<(), ContractError> {
    let result = response
        .outcome
        .as_ref()
        .map_err(|_| ContractError::ContractMismatch)?;
    validate_method_value("health", "result", result)?;
    let digest = result["catalogDigest"]
        .as_str()
        .ok_or(ContractError::ContractMismatch)?;
    if result["status"] != "ok"
        || result["protocolVersion"] != PROTOCOL_VERSION
        || result["contractIdentity"] != CONTRACT_IDENTITY
        || result["publishedMethods"] != serde_json::json!(METHODS)
        || digest.len() != 64
        || !digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || !result["providers"]
            .as_array()
            .is_some_and(|p| p.iter().all(|v| v.as_str().is_some_and(|v| !v.is_empty())))
    {
        return Err(ContractError::ContractMismatch);
    }
    Ok(())
}

pub fn encode_frame(value: &impl Serialize, limit: usize) -> Result<Vec<u8>, ContractError> {
    let mut bytes = serde_json::to_vec(value).map_err(|_| ContractError::Malformed)?;
    if bytes.len() >= limit {
        return Err(ContractError::Malformed);
    }
    bytes.push(b'\n');
    Ok(bytes)
}
