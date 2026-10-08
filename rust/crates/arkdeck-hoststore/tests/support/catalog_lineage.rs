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
const HAP_PLANS: &[u8] =
    include_bytes!("../../../../tests/fixtures/catalog-lineage-c6-e4/hap-plans.json");
const HAP_PLANS_SHA: &str = "686920fba1d6ecdfe52a18014b5da25f66668a9181ffe37101a92c3ca4fa381f";
const HAP_CASES: &[u8] = include_bytes!("../../../../tests/fixtures/debug-hap/cases.json");
const HAP_CASES_SHA: &str = "73ca561f75946518c57d512356679be18e864fd8c09c6aff8b40ffef2496d718";
const HAP_ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";

pub struct HapPlans {
    rows: BTreeMap<String, Value>,
    exchanges: BTreeMap<String, Value>,
}

impl HapPlans {
    pub fn frozen() -> Result<Self, String> {
        if sha256_hex(HAP_PLANS) != HAP_PLANS_SHA || sha256_hex(HAP_CASES) != HAP_CASES_SHA {
            return Err("frozen HAP source/capsule bytes changed".into());
        }
        let packet: Value = serde_json::from_slice(HAP_PLANS).map_err(|_| "HAP capsule JSON")?;
        Self::validated(&packet)
    }

    pub fn validated(packet: &Value) -> Result<Self, String> {
        let fields = packet.as_object().ok_or("HAP capsule object")?;
        let allowed = [
            "schemaVersion",
            "sourceFixture",
            "sourceCasesSha256",
            "catalogLineagePacketSha256",
            "rows",
        ];
        if fields.len() != allowed.len()
            || fields.keys().any(|key| !allowed.contains(&key.as_str()))
            || packet["schemaVersion"] != "arkdeck.test-hap-plan-lineage/1"
            || packet["sourceFixture"] != "debug-hap"
            || packet["sourceCasesSha256"] != HAP_CASES_SHA
            || packet["catalogLineagePacketSha256"] != PACKET_SHA
        {
            return Err("unknown HAP capsule source".into());
        }
        let source: Value = serde_json::from_slice(HAP_CASES).map_err(|_| "HAP source JSON")?;
        let mut exchanges = BTreeMap::new();
        for exchange in source["exchanges"].as_array().ok_or("HAP exchanges")? {
            if exchange["method"] != "job.plan" || exchange["answer"]["ok"] != true {
                continue;
            }
            let name = exchange["name"]
                .as_str()
                .ok_or("HAP source case")?
                .to_owned();
            if exchanges.insert(name, exchange.clone()).is_some() {
                return Err("duplicate HAP source case".into());
            }
        }
        let inputs = packet["rows"].as_array().ok_or("HAP capsule rows")?;
        if exchanges.len() != 10 || inputs.len() != 10 {
            return Err("exact ten HAP plans required".into());
        }
        let lineage = Lineage::frozen()?;
        let mut rows = BTreeMap::new();
        for row in inputs {
            let allowed = [
                "case",
                "requestJson",
                "historicalPlanSha256",
                "currentPlanSha256",
                "completeCurrentPlan",
            ];
            let fields = row.as_object().ok_or("HAP row object")?;
            let name = row["case"].as_str().ok_or("HAP case")?;
            let exchange = exchanges.get(name).ok_or("unknown HAP plan case")?;
            let plan = &row["completeCurrentPlan"];
            if fields.len() != allowed.len()
                || fields.keys().any(|key| !allowed.contains(&key.as_str()))
                || row["requestJson"] != exchange["params"]["requestJson"]
                || row["historicalPlanSha256"]
                    != exchange["answer"]["result"]["materializedPlanDigest"]
                || plan["operationReference"] != "debug.hap@1"
            {
                return Err("HAP original request/plan mismatch".into());
            }
            let request: Value =
                serde_json::from_str(row["requestJson"].as_str().ok_or("HAP request JSON")?)
                    .map_err(|_| "HAP request JSON")?;
            if request["operation"]["id"] != "debug.hap"
                || request["operation"]["version"] != 1
                || plan["inputs"] != request["inputs"]
            {
                return Err("HAP request material differs".into());
            }
            let historical = row["historicalPlanSha256"].as_str().ok_or("HAP old hash")?;
            if row["currentPlanSha256"] != lineage.current_digest(plan, historical)? {
                return Err("HAP full current hash mismatch".into());
            }
            if rows.insert(name.to_owned(), row.clone()).is_some() {
                return Err("duplicate HAP capsule case".into());
            }
        }
        if rows.keys().ne(exchanges.keys()) {
            return Err("HAP plan census mismatch".into());
        }
        Ok(Self { rows, exchanges })
    }

    pub fn current_plan(&self, name: &str) -> Result<&Value, String> {
        self.rows
            .get(name)
            .map(|row| &row["completeCurrentPlan"])
            .ok_or_else(|| "unknown HAP plan case".into())
    }

    /// The published selection predicate and original compensation order,
    /// correlated with every declaration in the whole pinned plan capsule.
    pub fn step_set_digest(&self, name: &str) -> Result<String, String> {
        use arkdeck_contract::operation_catalog::CatalogOperation;
        let plan = self.current_plan(name)?;
        let inputs = plan["inputs"].as_object().ok_or("HAP plan inputs")?;
        let descriptor =
            CatalogOperation::lookup("debug.hap", Some(1)).ok_or("current HAP descriptor")?;
        let mut selected: Vec<_> = descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, inputs))
            .map(|step| (step.step_id.clone(), step))
            .collect();
        for id in [
            "stop-ability",
            "cleanup-uninstall",
            "cleanup-remote-staging",
        ] {
            if id == "cleanup-uninstall"
                && inputs.get("cleanupPolicy").and_then(Value::as_str) == Some("retain")
            {
                continue;
            }
            let step = descriptor
                .steps
                .iter()
                .find(|step| step.step_id == id)
                .ok_or("HAP compensation declaration")?;
            selected.push((format!("compensation-{id}"), step));
        }
        let steps = plan["steps"].as_array().ok_or("complete HAP steps")?;
        if steps.len() != selected.len() {
            return Err("HAP selected declaration census".into());
        }
        let mut lines = Vec::new();
        for (actual, (id, step)) in steps.iter().zip(selected) {
            if actual["stepID"] != id
                || actual["kind"] != step.kind
                || actual["effect"] != step.effect
                || actual["cancellation"] != step.cancellation
                || actual["binding"] != step.binding
            {
                return Err("complete HAP selected declaration differs".into());
            }
            lines.push(format!(
                "{id}|{}|{}|{}|{}",
                step.kind, step.effect, step.cancellation, step.binding
            ));
        }
        Ok(sha256_hex(lines.join("\n").as_bytes()))
    }

    /// Prove the independently serialized raw host plan digest first. The
    /// only path substitution is an exact source-bound string leaf under the
    /// original fixture root; all non-digest answer fields remain exact.
    pub fn verify_hap_plan_answer(
        &self,
        actual: &Value,
        original: &Value,
        root: &Path,
    ) -> Result<Value, String> {
        let name = original["name"].as_str().ok_or("HAP original case")?;
        if self.exchanges.get(name) != Some(original) || !root.is_absolute() {
            return Err("HAP original exchange/root mismatch".into());
        }
        let plan = Self::at_root(self.current_plan(name)?, root)?;
        let observed_digest = sha256_hex(&plan_bytes(&plan)?);
        if actual["result"]["materializedPlanDigest"] != observed_digest {
            return Err("raw HAP host plan digest mismatch".into());
        }
        let mut expected = Self::at_root(&original["answer"], root)?;
        expected["result"]["catalogDigest"] = json!(CURRENT);
        expected["result"]["materializedPlanDigest"] = json!(observed_digest);
        expected["result"]["stepSetDigestSHA256"] = json!(self.step_set_digest(name)?);
        if actual != &expected {
            return Err("complete HAP plan answer differs".into());
        }
        Ok(expected)
    }

    pub fn at_root(value: &Value, root: &Path) -> Result<Value, String> {
        if !root.is_absolute() {
            return Err("absolute HAP fixture root required".into());
        }
        Ok(match value {
            Value::String(text) if text.starts_with(&format!("{HAP_ROOT}/")) => {
                let suffix = &text[HAP_ROOT.len() + 1..];
                if suffix.split('/').any(|part| {
                    part.is_empty() || part == "." || part == ".." || part.contains(['\\', ':'])
                }) {
                    return Err("HAP fixture path leaf differs".into());
                }
                let mut path = root.to_path_buf();
                for component in suffix.split('/') {
                    path.push(component);
                }
                json!(path.to_string_lossy())
            }
            Value::Array(values) => Value::Array(
                values
                    .iter()
                    .map(|value| Self::at_root(value, root))
                    .collect::<Result<_, _>>()?,
            ),
            Value::Object(fields) => Value::Object(
                fields
                    .iter()
                    .map(|(key, value)| Ok((key.clone(), Self::at_root(value, root)?)))
                    .collect::<Result<_, String>>()?,
            ),
            _ => value.clone(),
        })
    }
}

#[derive(Clone)]
pub struct Lineage {
    historical_operations: BTreeMap<String, Value>,
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
        Ok(Self {
            historical_operations: original,
            operations,
        })
    }

    pub fn assert_current_sources(&self, directory: &Path) -> Result<(), String> {
        self.assert_sources(directory, &self.operations)
    }

    /// Both isolated CI views compile the candidate test implementation, but
    /// each materializes its own complete Catalog sources. Bind this software
    /// source proof to that view's compiled digest; never relabel its sources.
    pub fn assert_catalog_view_sources(
        &self,
        directory: &Path,
        catalog_digest: &str,
    ) -> Result<(), String> {
        let expected = match catalog_digest {
            CURRENT => &self.operations,
            OLD => &self.historical_operations,
            _ => return Err("unknown compiled Catalog view".into()),
        };
        self.assert_sources(directory, expected)
    }

    fn assert_sources(
        &self,
        directory: &Path,
        expected: &BTreeMap<String, Value>,
    ) -> Result<(), String> {
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
        if &observed != expected {
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
