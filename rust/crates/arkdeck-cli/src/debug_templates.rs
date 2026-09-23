//! Offline disclosure of the exact closed commands the HDC provider lowers.
use crate::CliError;
use arkdeck_contract::{CATALOG_CANONICAL_JSON, CATALOG_DIGEST, DEBUG_TEMPLATES};
use serde_json::{Value, json};

pub fn debug_template_list() -> Result<Value, CliError> {
    let catalog: Value = serde_json::from_str(CATALOG_CANONICAL_JSON)
        .map_err(|_| CliError::new("internalError", "the published Catalog is unreadable"))?;
    let operation = catalog.as_array().and_then(|rows| {
        rows.iter()
            .find(|row| row["id"] == "debug.template" && row["version"] == 1)
    });
    let ids: Vec<_> = DEBUG_TEMPLATES.iter().map(|row| row.id).collect();
    if operation.map(|row| &row["inputs"]["fields"]["templateId"]["enum"]) != Some(&json!(ids)) {
        return Err(CliError::new(
            "internalError",
            "the closed Debug template set drifted from the published Catalog descriptor",
        ));
    }
    Ok(json!({
        "schemaVersion":"arkdeck.debug-template-list/1",
        "operation":"debug.template@1", "catalogDigest":CATALOG_DIGEST,"effect":"readOnly",
        "templates":DEBUG_TEMPLATES.iter().map(|row| json!({
            "templateId":row.id,"title":row.title,"effect":"readOnly",
            "remoteCommand":row.command,"outputByteBudget":row.output_byte_budget,
            "inputs":{"templateId":row.id}
        })).collect::<Vec<_>>()
    }))
}
