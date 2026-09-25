//! Pure current-contract types and encodings. No I/O or Runtime authority.

/// ArkForge's release unit, as Swift's ArkForge SDK reads and verifies it.
pub mod arkforge_bundle;
mod canonical;
mod debug_templates;
pub use debug_templates::{DEBUG_TEMPLATES, DebugTemplateDefinition};
mod catalog_generated;
mod catalog_pattern;
mod cbor;
mod control_generated;
/// Foundation's path arithmetic for inputs read from disk.
pub mod foundation_json;
pub mod foundation_path;
mod framing;
mod imports;
mod job_state_preflight;
pub mod operation_catalog;
pub use imports::{
    IMPORT_MAX_CHUNK_BYTES, IMPORT_MAX_CHUNKS, IMPORT_MAX_RECORD_BYTES, IMPORT_MAX_RECORDS,
    IMPORT_STAGING_QUOTA, ImportIntent, ImportProjection, decode_import_chunk, encode_import_chunk,
    import_decimal, import_digest, import_id, import_identifier, import_timestamp,
    validate_import_inspection, validate_import_release,
};
mod schema;

pub use canonical::{canonical_json, sha256_hex};
pub use catalog_generated::{CATALOG_CANONICAL_JSON, CATALOG_DIGEST};
pub use cbor::{CborValue, canonical_cbor};
pub use control_generated::*;
pub use framing::{
    ContractError, Request, Response, StrictValue, WireError, decode_request, decode_response,
    encode_frame, strict_json, validate_health,
};
pub use job_state_preflight::{
    CutoverBlock, CutoverExecution, CutoverJob, CutoverUse, JOB_STATE_PREFLIGHT_TABLE,
    JobStateClass, MalformedCurrentJob, RestartPreflight, agent_execution_active,
    capability_use_unsettled, classify_restart, cutover_job_class, cutover_preflight,
    job_state_class, job_states,
};
pub use schema::validate_method_value;

// A required nullable field must distinguish absent from explicit JSON null.
// Serde otherwise gives both cases None for an Option<T> field.
pub fn required_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    <Option<T> as serde::Deserialize>::deserialize(deserializer)
}
