//! Test-only, exact c6 -> e4 expectation proof. This is not a Runtime authority
//! adapter. Historical seeds are never rewritten; only a newly planned answer
//! can be read against its frozen historical answer after the full plan hash
//! proves that its only change is this reviewed Catalog lineage.
#![allow(dead_code)]

use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fmt::Write;
use std::fs;
use std::path::Path;

pub const OLD: &str = "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036";
pub const CURRENT: &str = "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7";
const NATIVE: &str = "deploy.native-library.app-owned@1";
const PACKET_SHA: &str = "d1a2614926275e9e8b38783ca5ac3054b6ea4fa63f051e2aedacfe59d7c937ab";
const PACKET: &[u8] =
    include_bytes!("../../../../tests/fixtures/catalog-lineage-c6-e4/catalogs.json");

#[derive(Clone)]
pub struct Lineage {
    operations: BTreeMap<String, Value>,
}

fn reference(operation: &Value) -> Result<String, String> {
    let id = operation["id"].as_str().ok_or("operation id")?;
    let version = operation
        .get("version")
        .map_or(Some(0), Value::as_u64)
        .ok_or("version")?;
    Ok(format!("{id}@{version}"))
}

// Exactly scripts/catalog_gen/generate.py catalog_digest: sorted objects,
// sorted operation id/version, compact JSON and ensure_ascii=True.
fn catalog_bytes(operations: &[Value]) -> Result<Vec<u8>, String> {
    let mut ordered = operations.to_vec();
    ordered.sort_by_key(|operation| {
        (
            operation["id"].as_str().unwrap_or_default().to_owned(),
            operation["version"].as_u64().unwrap_or(0),
        )
    });
    let text = serde_json::to_string(&ordered).map_err(|_| "catalog encoding")?;
    let mut ascii = String::new();
    for character in text.chars() {
        if character.is_ascii() {
            ascii.push(character);
        } else {
            let mut units = [0; 2];
            for unit in character.encode_utf16(&mut units) {
                write!(ascii, "\\u{unit:04x}").unwrap();
            }
        }
    }
    Ok(ascii.into_bytes())
}

// The full plans supported here contain only integers. In that closed domain
// this is byte-identical to session_json::encode; floating point is refused,
// not approximated with a different Foundation spelling.
pub fn plan_bytes(document: &Value) -> Result<Vec<u8>, String> {
    fn integers(value: &Value) -> bool {
        match value {
            Value::Number(number) => number.is_i64() || number.is_u64(),
            Value::Array(values) => values.iter().all(integers),
            Value::Object(fields) => fields.values().all(integers),
            _ => true,
        }
    }
    if !integers(document) {
        return Err("unsupported floating-point plan".into());
    }
    serde_json::to_vec(document).map_err(|_| "plan encoding".into())
}

impl Lineage {
    pub fn frozen() -> Result<Self, String> {
        if sha256_hex(PACKET) != PACKET_SHA {
            return Err("frozen lineage packet bytes changed".into());
        }
        let packet: Value = serde_json::from_slice(PACKET).map_err(|_| "lineage packet JSON")?;
        Self::validated(&packet)
    }

    pub fn validated(packet: &Value) -> Result<Self, String> {
        let fields = packet.as_object().ok_or("lineage packet object")?;
        let allowed = [
            "schemaVersion",
            "oldSourceCommit",
            "oldCatalogDigest",
            "currentCatalogDigest",
            "historicalOperations",
            "currentOperations",
        ];
        if fields.len() != allowed.len()
            || fields.keys().any(|key| !allowed.contains(&key.as_str()))
            || packet["schemaVersion"] != "arkdeck.test-catalog-lineage/1"
            || packet["oldSourceCommit"] != "fc3630ea2240497f35061858a17381ea653beccb"
            || packet["oldCatalogDigest"] != OLD
            || packet["currentCatalogDigest"] != CURRENT
        {
            return Err("unknown lineage".into());
        }
        let old = packet["historicalOperations"]
            .as_array()
            .ok_or("historical descriptors")?;
        let current = packet["currentOperations"]
            .as_array()
            .ok_or("current descriptors")?;
        if old.len() != 32
            || current.len() != 32
            || sha256_hex(&catalog_bytes(old)?) != OLD
            || sha256_hex(&catalog_bytes(current)?) != CURRENT
        {
            return Err("complete Catalog digest mismatch".into());
        }
        let collect = |rows: &[Value]| -> Result<BTreeMap<String, Value>, String> {
            let mut result = BTreeMap::new();
            for row in rows {
                if result.insert(reference(row)?, row.clone()).is_some() {
                    return Err("duplicate operation".into());
                }
            }
            Ok(result)
        };
        let original = collect(old)?;
        let operations = collect(current)?;
        if original.keys().ne(operations.keys()) {
            return Err("operation inventory changed".into());
        }
        let mut unchanged = 0;
        for (name, operation) in &operations {
            if name != NATIVE {
                if operation != &original[name] {
                    return Err("unchanged operation differs".into());
                }
                unchanged += 1;
                continue;
            }
            let mut prior = operation.clone();
            let steps = prior["steps"].as_array_mut().ok_or("native steps")?;
            if steps.len() < 5 {
                return Err("native prefix missing".into());
            }
            let added: Vec<_> = steps.drain(2..5).collect();
            if added
                .iter()
                .map(|step| step["stepID"].as_str())
                .collect::<Vec<_>>()
                != [
                    Some("confirm-evidence-target"),
                    Some("read-evidence-model"),
                    Some("read-evidence-firmware"),
                ]
                || prior != original[name]
            {
                return Err("native delta differs".into());
            }
        }
        if unchanged != 31 {
            return Err("unchanged descriptor census".into());
        }
        Ok(Self { operations })
    }

    pub fn assert_current_sources(&self, directory: &Path) -> Result<(), String> {
        let mut observed = BTreeMap::new();
        for entry in fs::read_dir(directory).map_err(|_| "current Catalog source")? {
            let entry = entry.map_err(|_| "current Catalog entry")?;
            let path = entry.path();
            if path.extension().is_none_or(|extension| extension != "json") {
                continue;
            }
            let metadata = fs::symlink_metadata(&path).map_err(|_| "descriptor metadata")?;
            if !metadata.is_file() || metadata.len() > 1 << 20 {
                return Err("descriptor file bound".into());
            }
            let operation: Value =
                serde_json::from_slice(&fs::read(path).map_err(|_| "descriptor read")?)
                    .map_err(|_| "descriptor JSON")?;
            if observed.insert(reference(&operation)?, operation).is_some() {
                return Err("duplicate source".into());
            }
        }
        if observed != self.operations {
            return Err("current descriptor source drift".into());
        }
        Ok(())
    }

    pub fn operation(&self, name: &str) -> Result<&Value, String> {
        if name == NATIVE {
            return Err("Native requires its independently versioned oracle".into());
        }
        self.operations
            .get(name)
            .ok_or_else(|| "unknown operation".into())
    }

    pub fn current_digest(
        &self,
        current_plan: &Value,
        historical_digest: &str,
    ) -> Result<String, String> {
        let name = current_plan["operationReference"]
            .as_str()
            .ok_or("plan operation")?;
        self.operation(name)?;
        if current_plan["catalogDigest"] != CURRENT {
            return Err("unknown plan Catalog".into());
        }
        if historical_digest.len() != 64
            || !historical_digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err("historical digest shape".into());
        }
        let mut original = current_plan.clone();
        original["catalogDigest"] = json!(OLD);
        if sha256_hex(&plan_bytes(&original)?) != historical_digest {
            return Err("complete original plan hash mismatch".into());
        }
        Ok(sha256_hex(&plan_bytes(current_plan)?))
    }

    /// Exact plan-only envelope projection, after complete original hash proof.
    /// All other fields remain for the caller's existing whole-answer equality.
    pub fn historical_answer(
        &self,
        actual: &Value,
        expected: &Value,
        current_plan: &Value,
    ) -> Result<Value, String> {
        if actual["ok"] != true
            || expected["ok"] != true
            || actual["result"]["schemaVersion"] != "arkdeck.job-plan/1"
            || expected["result"]["catalogDigest"] != OLD
            || actual["result"]["catalogDigest"] != CURRENT
            || actual["result"]["operation"] != current_plan["operationReference"]
            || expected["result"]["operation"] != current_plan["operationReference"]
        {
            return Err("not an exact new plan output".into());
        }
        let historical = expected["result"]["materializedPlanDigest"]
            .as_str()
            .ok_or("frozen plan digest")?;
        let current = self.current_digest(current_plan, historical)?;
        if actual["result"]["materializedPlanDigest"] != current {
            return Err("actual complete plan hash mismatch".into());
        }
        let mut projection = actual.clone();
        projection["result"]["catalogDigest"] = json!(OLD);
        projection["result"]["materializedPlanDigest"] = json!(historical);
        Ok(projection)
    }

    /// The fixed crash-signature plan shape in job_plan.rs: full original
    /// invocation, executable hash, lease identity, timeout and declarations.
    pub fn crash_signature_plan(
        &self,
        request: &Value,
        executable_sha: &str,
        payload: &str,
    ) -> Result<Value, String> {
        if request["operation"]["id"] != "analyzer.extract-crash-signature"
            || request["operation"]["version"] != 1
        {
            return Err("unsupported analyzer".into());
        }
        let operation = self.operation("analyzer.extract-crash-signature@1")?;
        let lease = request["inputs"]["sourceArtifactRef"]
            .as_str()
            .ok_or("source lease")?;
        let artifact = lease.rsplit(':').next().ok_or("source artifact")?;
        let steps = operation["steps"].as_array().ok_or("steps")?;
        if steps.len() != 1 {
            return Err("analyzer step census".into());
        }
        let step = &steps[0];
        Ok(
            json!({"operationReference":"analyzer.extract-crash-signature@1", "catalogDigest":CURRENT,
            "inputs":request["inputs"], "targetID":request["target"]["targetId"], "providerID":operation["provider"],
            "steps":[{"stepID":step["stepID"], "kind":step["kind"], "effect":step["effect"],
                "cancellation":step["cancellation"], "binding":step["binding"],
                "isOptional":step.get("optional").cloned().unwrap_or(json!(false)),
                "journalArguments":{"analyzerRef":"crash-signature@1", "inputArtifactId":artifact,
                    "artifactId":"crash-signature.json"}, "processKind":"process",
                "executableSHA256":executable_sha, "argumentSummary":["--analyze-crash-ledger",payload],
                "timeoutSeconds":30}]}),
        )
    }
}
