//! Local Target presentation owner. Binding/alias documents are read-only.
//! Runtime supplies active observation references internally, never through RPC.
use crate::{
    decode_display_names,
    display_names::{Candidate, Document, Record, target_identifier, valid_name},
    target_document::TargetDocument,
};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};
const NAMES: &str = "target-display-names.json";
const LOCK: &str = ".target-display-names.lock";
const MAX: usize = 512 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObservationReference {
    pub candidate: String,
    pub observation_id: String,
    pub generation: u64,
}
fn same_text(a: &str, b: &str) -> bool {
    matches!((crate::canonical_host_text(a),crate::canonical_host_text(b)),(Ok(a),Ok(b)) if a==b)
}
impl ObservationReference {
    fn same_reference(&self, other: &Self) -> bool {
        self.generation == other.generation
            && same_text(&self.candidate, &other.candidate)
            && same_text(&self.observation_id, &other.observation_id)
    }
}
pub struct TargetStore {
    path: PathBuf,
    root: HostDirectory,
}
pub(super) fn failure(code: &str, message: &str, phase: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: (!phase.is_empty()).then(|| {
            Map::from_iter([
                ("phase".into(), json!(phase)),
                ("newDispatchCount".into(), json!(0)),
            ])
        }),
    }
}
fn unreadable(phase: &str) -> WireError {
    failure(
        "recordUnreadable",
        "Target presentation storage is unreadable or unsafe",
        phase,
    )
}
fn positive(text: &str) -> Option<u64> {
    text.parse::<u64>()
        .ok()
        .filter(|n| (1..=i64::MAX as u64).contains(n) && n.to_string() == text)
}
fn empty_names() -> Document {
    Document {
        schema_version: "arkdeck.target-display-names/1".into(),
        records: Vec::new(),
        candidates: None,
    }
}
fn target_name(doc: &Document, id: &str) -> Value {
    doc.records.iter().find(|r| r.target_id == id).map_or_else(|| json!({"schemaVersion":"arkdeck.target-display-name/1","targetId":id,"generation":"1","name":null,"updatedAtUtc":null}), |r| json!({"schemaVersion":"arkdeck.target-display-name/1","targetId":id,"generation":r.generation.to_string(),"name":r.name,"updatedAtUtc":r.updated_at}))
}
impl TargetStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        let owner = Self {
            path: path.to_owned(),
            root: HostDirectory::open(path)?,
        };
        owner
            .transaction("targetDisplayNameOwner", |targets, names| {
                let active = targets.active_ids();
                let before = serde_json::to_value(&*names)
                    .map_err(|_| unreadable("targetDisplayNameOwner"))?;
                names.records.retain(|r| active.contains(&r.target_id));
                names.candidates = Some(Vec::new());
                let changed = before
                    != serde_json::to_value(&*names)
                        .map_err(|_| unreadable("targetDisplayNameOwner"))?;
                Ok((Value::Null, changed))
            })
            .map_err(|e| io::Error::other(e.message))?;
        Ok(owner)
    }
    fn transaction(
        &self,
        phase: &str,
        action: impl FnOnce(&TargetDocument, &mut Document) -> Result<(Value, bool), WireError>,
    ) -> Result<Value, WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| unreadable(phase))?;
        let target_lock = self.root.lock_document(".targets.lock").map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                failure(
                    if phase.is_empty() {
                        "internalError"
                    } else {
                        "resourceConflict"
                    },
                    "Target storage is being updated",
                    phase,
                )
            } else {
                unreadable(phase)
            }
        })?;
        let names_lock = self.root.lock_document(LOCK).map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                failure(
                    if phase.is_empty() {
                        "internalError"
                    } else {
                        "resourceConflict"
                    },
                    "Display names are being updated",
                    phase,
                )
            } else {
                unreadable(phase)
            }
        })?;
        let targets = match self.root.read("targets.json", 4 * 1024 * 1024) {
            Ok(bytes) => TargetDocument::decode(&bytes).map_err(|_| unreadable(phase))?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => TargetDocument::empty(),
            Err(_) => return Err(unreadable(phase)),
        };
        let mut names = match self.root.read(NAMES, MAX) {
            Ok(bytes) => {
                let decoded = decode_display_names(&bytes).map_err(|_| unreadable(phase))?;
                serde_json::from_slice(&decoded.document).map_err(|_| unreadable(phase))?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => empty_names(),
            Err(_) => return Err(unreadable(phase)),
        };
        let (value, write) = action(&targets, &mut names)?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| unreadable(phase))?;
        target_lock
            .validate_link(&self.root, ".targets.lock")
            .map_err(|_| unreadable(phase))?;
        names_lock
            .validate_link(&self.root, LOCK)
            .map_err(|_| unreadable(phase))?;
        if write {
            names.records.sort_by(|a, b| a.target_id.cmp(&b.target_id));
            if let Some(candidates) = names.candidates.as_mut() {
                candidates.sort_by(|a, b| {
                    if same_text(&a.candidate, &b.candidate) {
                        a.observation_id.cmp(&b.observation_id)
                    } else {
                        a.candidate.cmp(&b.candidate)
                    }
                });
            }
            let bytes = serde_json::to_vec(&names).map_err(|_| unreadable(phase))?;
            if bytes.len() >= MAX {
                return Err(failure(
                    "quotaExceeded",
                    "Display-name storage exceeds its bound",
                    phase,
                ));
            }
            let validated = decode_display_names(&bytes).map_err(|_| unreadable(phase))?;
            self.root.publish_document(NAMES, &validated.document, MAX).map_err(|e| match e {
                DocumentPublishError::BeforePublication(_) => failure("ioFailure", "Display-name update could not be written", phase),
                DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "Display-name publication is unconfirmed; read current state before another update", phase),
            })?;
            if self.root.validate_path(&self.path).is_err()
                || names_lock.validate_link(&self.root, LOCK).is_err()
                || target_lock
                    .validate_link(&self.root, ".targets.lock")
                    .is_err()
            {
                return Err(failure(
                    "outcomeUnknown",
                    "Target namespace changed during publication",
                    phase,
                ));
            }
        }
        Ok(value)
    }
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &str,
    ) -> Result<Value, WireError> {
        let write = matches!(
            method,
            "target.display-name.set" | "target.display-name.clear"
        );
        let phase = if write { "targetDisplayNameOwner" } else { "" };
        let keys: &[&str] = match method {
            "target.list" => &[],
            "target.show" => &["targetId"],
            "target.display-name.set" => &["targetId", "expectedGeneration", "name"],
            "target.display-name.clear" => &["targetId", "expectedGeneration"],
            _ => {
                return Err(failure(
                    "unknownMethod",
                    "Not a Target presentation method",
                    phase,
                ));
            }
        };
        if params.len() != keys.len()
            || keys
                .iter()
                .any(|k| !params.get(*k).is_some_and(Value::is_string))
        {
            return Err(failure(
                "invalidParams",
                "Target method requires its exact typed parameters",
                phase,
            ));
        }
        let id = params.get("targetId").and_then(Value::as_str).unwrap_or("");
        if method != "target.list" && !target_identifier(id) {
            return Err(failure(
                "invalidParams",
                "Target identity must be a bounded identifier",
                phase,
            ));
        }
        let expected = if write {
            positive(params["expectedGeneration"].as_str().unwrap()).ok_or_else(|| {
                failure(
                    "invalidParams",
                    "expectedGeneration must be canonical and positive",
                    phase,
                )
            })?
        } else {
            0
        };
        let name = params.get("name").and_then(Value::as_str);
        if name.is_some_and(|n| !valid_name(n)) {
            return Err(failure(
                "invalidInput",
                "Display name must be nonblank bounded text",
                phase,
            ));
        }
        self.transaction(phase, |targets, names| {
            let active = targets.active_ids();
            if method == "target.list" {
                let rows: Vec<_> = targets.targets.iter().filter(|t| active.contains(&t.target_id)).map(|t| {
                    let name = target_name(names, &t.target_id);
                    json!({"targetId":t.target_id,"bindingRevision":t.binding_revision,"toolVersion":t.tool_version,"adoptedAtUtc":t.adopted_at,"displayName":name["name"],"displayNameGeneration":name["generation"]})
                }).collect();
                return Ok((json!(rows), false));
            }
            let target = targets.targets.iter().find(|t| t.target_id == id).ok_or_else(|| failure(if write {"resourceNotFound"} else {"notFound"}, "Durable target does not exist", phase))?;
            let current = target_name(names, id);
            if !write { return Ok((json!({"schemaVersion":"arkdeck.target/1","targetId":id,"stablePhysicalIdentitySha256":target.identity,"bindingRevision":target.binding_revision,"connectKey":target.connect_key,"toolVersion":target.tool_version,"adoptedAtUtc":target.adopted_at,"displayName":current["name"],"displayNameGeneration":current["generation"],"live":null,"observedFacts":null}), false)); }
            if !active.contains(id) { return Err(failure("resourceNotFound", "Durable target is an inactive alias", phase)); }
            let generation = positive(current["generation"].as_str().unwrap()).ok_or_else(|| unreadable(phase))?;
            if generation != expected || generation == i64::MAX as u64 { return Err(failure("resourceConflict", "Target display-name generation changed or is exhausted", phase)); }
            if !crate::format_time::valid_format_timestamp(now) { return Err(unreadable(phase)); }
            let record = Record { target_id: id.into(), generation: generation + 1, name: name.map(str::to_owned), updated_at: now.into() };
            if let Some(row) = names.records.iter_mut().find(|r| r.target_id == id) { *row = record; }
            else { if names.records.len() >= 4096 { return Err(failure("quotaExceeded", "Target display-name count exceeds its bound", phase)); } names.records.push(record); }
            Ok((target_name(names,id),true))
        })
    }
    /// Presentation lookup from provider-observed addresses. This does not select
    /// an execution route or establish freshness/physical continuity.
    pub fn candidate_presentations(&self, keys: &[String]) -> Result<Value, WireError> {
        if keys.len() > 1000 {
            return Err(failure(
                "recordUnreadable",
                "Candidate snapshot exceeds its bound",
                "",
            ));
        }
        self.transaction("", |targets, names| {
            let mut result=Map::new();
            for key in keys { if let Some(target)=targets.candidate_target(key) {
                let name=target_name(names,&target.target_id);
                result.insert(key.clone(),json!({"targetId":target.target_id,"bindingRevision":target.binding_revision,"displayName":name["name"],"displayNameGeneration":name["generation"]}));
            } }
            Ok((Value::Object(result),false))
        })
    }
    pub fn expire_candidates(&self) -> Result<(), WireError> {
        self.transaction("candidateDisplayNameOwner", |_, names| {
            let write = names.candidates.as_ref().is_some_and(|c| !c.is_empty());
            names.candidates = Some(Vec::new());
            Ok((Value::Null, write))
        })
        .map(|_| ())
    }
    /// Runtime-owned observation references are supplied by the in-memory coordinator.
    /// Only the requested reference and text originate from the caller.
    pub fn mutate_candidate(
        &self,
        reference: &ObservationReference,
        active: &[ObservationReference],
        name: Option<&str>,
        now: &str,
    ) -> Result<Value, WireError> {
        let phase = "candidateDisplayNameOwner";
        if !(1..=1024).contains(&reference.candidate.len())
            || !(1..=128).contains(&reference.observation_id.len())
            || reference.generation == 0
            || name.is_some_and(|n| !valid_name(n))
        {
            return Err(failure(
                "invalidInput",
                "Candidate name requires exact bounded observation and text",
                phase,
            ));
        }
        let next = reference
            .generation
            .checked_add(1)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| {
                failure(
                    "resourceConflict",
                    "Observation generation is exhausted",
                    phase,
                )
            })?;
        if active.len() > 4096
            || !active.iter().any(|r| r.same_reference(reference))
            || active.iter().any(|r| r.generation != reference.generation)
            || active
                .iter()
                .map(|r| &r.observation_id)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                != active.len()
        {
            return Err(failure(
                "resourceConflict",
                "Candidate observation is no longer current",
                phase,
            ));
        }
        if !crate::format_time::valid_format_timestamp(now) {
            return Err(unreadable(phase));
        }
        self.transaction(phase, |targets, names| {
            if targets.candidate_target(&reference.candidate).is_some() { return Err(failure("resourceConflict", "Candidate is already adopted; use its durable target", phase)); }
            let mut rows = names.candidates.take().unwrap_or_default();
            let is_active = |r: &Candidate| active.iter().any(|a| same_text(&a.candidate,&r.candidate) && same_text(&a.observation_id,&r.observation_id));
            if rows.iter().any(|r| is_active(r) && r.generation != reference.generation) { return Err(failure("resourceConflict", "Candidate display-name generation changed", phase)); }
            rows.retain(|r| is_active(r) && !(same_text(&r.candidate,&reference.candidate) && same_text(&r.observation_id,&reference.observation_id)));
            for r in &mut rows { r.generation = next; r.staged_target_id = None; r.staged_target_generation = None; }
            if let Some(name) = name {
                if rows.len() >= 4096 { return Err(failure("quotaExceeded", "Candidate display-name count exceeds its bound", phase)); }
                rows.push(Candidate { candidate: reference.candidate.clone(), observation_id: reference.observation_id.clone(), generation: next, name: name.into(), updated_at: now.into(), staged_target_id: None, staged_target_generation: None });
            }
            names.candidates = Some(rows);
            Ok((json!({"schemaVersion":"arkdeck.candidate-display-name/1","candidateKey":reference.candidate,"observationId":reference.observation_id,"generation":next.to_string(),"name":name,"updatedAtUtc":now}),true))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
        sync::{Arc, Barrier},
    };
    const NOW: &str = "2026-09-12T00:00:00Z";
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "target-owner-{:x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, value: &Value) {
            let path = self.0.join(name);
            fs::write(&path, serde_json::to_vec(value).unwrap()).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        fn targets(&self) {
            self.write("targets.json",&json!({"schemaVersion":"1.0.0","targets":[{"targetID":"target-fixture","stablePhysicalIdentitySHA256":"a".repeat(64),"bindingRevision":1,"connectKey":"fixture-address","toolVersion":"fixture-tool","adoptedAtUTC":NOW}]}));
        }
        fn open(&self) -> TargetStore {
            TargetStore::open(&self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn params(generation: &str, name: Option<&str>) -> Map<String, Value> {
        let mut p = json!({"targetId":"target-fixture","expectedGeneration":generation})
            .as_object()
            .unwrap()
            .clone();
        if let Some(name) = name {
            p.insert("name".into(), json!(name));
        }
        p
    }
    #[test]
    fn target_names_survive_restart_clear_with_tombstone_and_preserve_binding_bytes() {
        let root = Root::new();
        root.targets();
        let before = fs::read(root.0.join("targets.json")).unwrap();
        let owner = root.open();
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
        let set = owner
            .handle(
                "target.display-name.set",
                &params("1", Some("Bench e\u{301}")),
                NOW,
            )
            .unwrap();
        assert_eq!(set["generation"], "2");
        assert_eq!(
            owner
                .handle("target.display-name.clear", &params("1", None), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let clear = root
            .open()
            .handle("target.display-name.clear", &params("2", None), NOW)
            .unwrap();
        assert_eq!(clear["generation"], "3");
        assert!(clear["name"].is_null());
        assert_eq!(
            root.open()
                .handle(
                    "target.show",
                    json!({"targetId":"target-fixture"}).as_object().unwrap(),
                    NOW
                )
                .unwrap()["displayNameGeneration"],
            "3"
        );
        assert_eq!(fs::read(root.0.join("targets.json")).unwrap(), before);
        if let Some(path) = std::env::var_os("ARKDECK_RUST_TARGET_NAMES_COPY") {
            fs::copy(root.0.join(NAMES), path).unwrap();
        }
    }
    #[test]
    fn target_names_refuse_unknown_extra_noncanonical_and_invalid_values() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        assert_eq!(
            owner
                .handle("target.display-name.set", &params("01", Some("Bench")), NOW)
                .unwrap_err()
                .code,
            "invalidParams"
        );
        assert_eq!(
            owner
                .handle(
                    "target.display-name.set",
                    &params("1", Some(" invalid")),
                    NOW
                )
                .unwrap_err()
                .code,
            "invalidInput"
        );
        let mut p = params("1", Some("Bench"));
        p.insert("freshFacts".into(), json!({}));
        assert_eq!(
            owner
                .handle("target.display-name.set", &p, NOW)
                .unwrap_err()
                .code,
            "invalidParams"
        );
        p.remove("freshFacts");
        p.insert("targetId".into(), json!("target-missing"));
        assert_eq!(
            owner
                .handle("target.display-name.set", &p, NOW)
                .unwrap_err()
                .code,
            "resourceNotFound"
        );
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
    }
    #[test]
    fn concurrent_target_writers_have_one_cas_winner() {
        let root = Root::new();
        root.targets();
        let a = Arc::new(root.open());
        let b = Arc::new(root.open());
        let barrier = Arc::new(Barrier::new(2));
        let threads = [a, b]
            .into_iter()
            .map(|owner| {
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    owner.handle("target.display-name.set", &params("1", Some("Bench")), NOW)
                })
            })
            .collect::<Vec<_>>();
        let results = threads
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert!(
            results
                .iter()
                .filter_map(|r| r.as_ref().err())
                .all(|e| e.code == "resourceConflict")
        );
    }
    #[test]
    fn candidate_names_advance_all_active_generations_and_expire_on_restart() {
        let root = Root::new();
        let owner = root.open();
        let first = ObservationReference {
            candidate: "candidate-a".into(),
            observation_id: "obs-a".into(),
            generation: 1,
        };
        let second = ObservationReference {
            candidate: "candidate-b".into(),
            observation_id: "obs-b".into(),
            generation: 1,
        };
        let result = owner
            .mutate_candidate(&first, &[first.clone(), second.clone()], Some("A"), NOW)
            .unwrap();
        assert_eq!(result["generation"], "2");
        let mut first2 = first.clone();
        first2.generation = 2;
        let mut second2 = second.clone();
        second2.generation = 2;
        owner
            .mutate_candidate(&second2, &[first2.clone(), second2.clone()], Some("B"), NOW)
            .unwrap();
        assert_eq!(
            owner
                .mutate_candidate(&first2, &[first2.clone(), second2], None, NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let decoded = decode_display_names(&fs::read(root.0.join(NAMES)).unwrap()).unwrap();
        assert_eq!(decoded.projection["candidates"][0]["generation"], "3");
        assert_eq!(decoded.projection["candidates"][1]["generation"], "3");
        root.open();
        let decoded = decode_display_names(&fs::read(root.0.join(NAMES)).unwrap()).unwrap();
        assert_eq!(decoded.projection["candidates"], json!([]));
    }
    #[test]
    fn adopted_candidate_rejects_presentation_alias_and_unknown_reference() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        let reference = ObservationReference {
            candidate: "fixture-address".into(),
            observation_id: "obs-fixture".into(),
            generation: 1,
        };
        assert_eq!(
            owner
                .mutate_candidate(
                    &reference,
                    std::slice::from_ref(&reference),
                    Some("Candidate"),
                    NOW
                )
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            owner
                .mutate_candidate(&reference, &[], Some("Candidate"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
    }
    #[test]
    fn unsafe_or_duplicate_documents_fail_without_resetting_state() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        let names = fs::read(root.0.join(NAMES)).unwrap();
        fs::write(
            root.0.join("targets.json"),
            b"{\"schemaVersion\":\"1.0.0\",\"schemaVersion\":\"1.0.0\",\"targets\":[]}",
        )
        .unwrap();
        assert_eq!(
            owner
                .handle("target.list", &Map::new(), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(root.0.join(NAMES)).unwrap(), names);
        root.targets();
        fs::remove_file(root.0.join(NAMES)).unwrap();
        symlink("targets.json", root.0.join(NAMES)).unwrap();
        assert_eq!(
            owner
                .handle("target.list", &Map::new(), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(TargetStore::open(&root.0).is_err());
    }
    #[test]
    #[ignore = "requires an actual Swift owner export in ARKDECK_SWIFT_TARGET_STORE"]
    fn actual_swift_target_document_is_read_by_rust_without_rewriting_binding() {
        let source =
            std::env::var_os("ARKDECK_SWIFT_TARGET_STORE").expect("actual Swift owner export");
        let root = Root::new();
        let source = PathBuf::from(source);
        for name in ["targets.json", NAMES] {
            fs::copy(source.join(name), root.0.join(name)).unwrap();
            fs::set_permissions(root.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
        }
        let before = fs::read(root.0.join("targets.json")).unwrap();
        let owner = root.open();
        let listed = owner.handle("target.list", &Map::new(), NOW).unwrap();
        assert!(!listed.as_array().unwrap().is_empty());
        assert_eq!(fs::read(root.0.join("targets.json")).unwrap(), before);
    }
}
