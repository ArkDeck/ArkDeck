//! Pure current-contract types and encodings. No I/O or Runtime authority.

mod canonical;
mod catalog_generated;
mod cbor;
mod control_generated;
mod framing;
mod imports;
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
    ContractError, Request, Response, WireError, decode_request, decode_response, encode_frame,
    strict_json, validate_health,
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
