#![cfg(target_os = "macos")]
use arkdeck_contract::{ImportIntent, sha256_hex};
use arkdeck_hoststore::{ImportUploadStore, TargetStore};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
};
const NOW: &str = "2026-09-12T00:00:00Z";
struct Fixture {
    root: PathBuf,
    target: Value,
}
impl Fixture {
    fn new(kind: &str) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "import-target-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for name in ["targets", "artifacts"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(name))
                .unwrap();
        }
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/import-target-current")
            .join(kind);
        for name in ["targets.json", "target-display-names.json"] {
            let path = root.join("targets").join(name);
            fs::copy(source.join(name), &path).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let document: Value =
            serde_json::from_slice(&fs::read(root.join("targets/targets.json")).unwrap()).unwrap();
        Self {
            root,
            target: document["targets"][0].clone(),
        }
    }
    fn intent(&self, kind: &str) -> Value {
        let name = match kind {
            "workspace-patch" => "fixture.patch",
            "native-library" => "libfixture.so",
            "flash-bundle" => "images.tar.gz",
            _ => "fixture.hap",
        };
        json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":format!("native-target-{kind}"),"kind":kind,"targetId":self.target["targetID"],"bindingRevision":self.target["bindingRevision"].as_u64().unwrap().to_string(),"deviceProfile":if kind=="flash-bundle" {json!("dayu200")} else {Value::Null},"name":name,"byteCount":"64","sha256":sha256_hex(&[b'a'; 64])})
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
#[test]
fn native_target_owner_resolves_each_import_kind_without_rewriting_binding() {
    let f = Fixture::new("direct");
    let before = fs::read(f.root.join("targets/targets.json")).unwrap();
    let targets = TargetStore::open(&f.root.join("targets")).unwrap();
    let imports = ImportUploadStore::open(&f.root.join("artifacts")).unwrap();
    for kind in ["hap", "native-library", "workspace-patch", "flash-bundle"] {
        let intent = f.intent(kind);
        let result = imports
            .handle_resource(
                "artifact.import.begin",
                intent.as_object().unwrap(),
                NOW,
                false,
                |intent| targets.resolve_import_binding(intent),
            )
            .unwrap();
        assert_eq!(result["state"], "inProgress");
        assert_eq!(result["nextOffset"], "0");
        let record: Value = serde_json::from_slice(
            &fs::read(f.root.join("artifacts/.imports-v1/records").join(format!(
                "{}.json",
                sha256_hex(intent["importRequestId"].as_str().unwrap().as_bytes())
            )))
            .unwrap(),
        )
        .unwrap();
        let expected = if kind == "workspace-patch" {
            json!({"targetID":f.target["targetID"]})
        } else {
            json!({"targetID":f.target["targetID"],"bindingRevision":1,"stableIdentitySHA256":if kind=="flash-bundle" {f.target["stablePhysicalIdentitySHA256"].clone()} else {json!(sha256_hex(f.target["connectKey"].as_str().unwrap().as_bytes()))}})
        };
        assert_eq!(record["binding"], expected);
        assert_eq!(
            fs::read(f.root.join("targets/targets.json")).unwrap(),
            before
        );
    }
}
#[test]
fn missing_stale_or_injected_authority_never_creates_an_import() {
    let f = Fixture::new("direct");
    let targets = TargetStore::open(&f.root.join("targets")).unwrap();
    let imports = ImportUploadStore::open(&f.root.join("artifacts")).unwrap();
    for vector in ["missing", "stale", "injected"] {
        let mut intent = f.intent("hap");
        match vector {
            "missing" => intent["targetId"] = json!("TGT-missing"),
            "stale" => intent["bindingRevision"] = json!("2"),
            _ => intent["binding"] = json!({"stableIdentitySHA256":"a".repeat(64)}),
        };
        let error = imports
            .handle_resource(
                "artifact.import.begin",
                intent.as_object().unwrap(),
                NOW,
                false,
                |intent| targets.resolve_import_binding(intent),
            )
            .unwrap_err();
        assert_eq!(
            error.code,
            if vector == "injected" {
                "invalidInput"
            } else {
                "resourceConflict"
            }
        );
        assert_eq!(
            fs::read_dir(f.root.join("artifacts/.imports-v1/records"))
                .unwrap()
                .count(),
            0
        );
    }
}
#[test]
fn native_alias_requires_real_route_owner_for_hdc_imports_but_keeps_other_kind_semantics() {
    let f = Fixture::new("alias");
    let targets = TargetStore::open(&f.root.join("targets")).unwrap();
    for kind in ["hap", "native-library", "workspace-patch", "flash-bundle"] {
        let intent = ImportIntent::from_wire(f.intent(kind).as_object().unwrap()).unwrap();
        let result = targets.resolve_import_binding(&intent);
        if ["hap", "native-library"].contains(&kind) {
            assert_eq!(result.unwrap_err().code, "operationUnavailable");
        } else {
            let binding = result.unwrap();
            assert_eq!(binding.target_id, f.target["targetID"].as_str().unwrap());
        }
    }
}
#[test]
fn malformed_alias_history_and_linked_target_files_fail_closed() {
    for vector in ["proof", "symlink", "hardlink"] {
        let f = Fixture::new("alias");
        let targets = TargetStore::open(&f.root.join("targets")).unwrap();
        let path = f.root.join("targets/targets.json");
        match vector {
            "proof" => {
                let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                value["aliasResolutions"][0]["resolutionSHA256"] = json!("0".repeat(64));
                fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            }
            "symlink" => {
                let raw = f.root.join("original-targets");
                fs::rename(&path, &raw).unwrap();
                symlink(&raw, &path).unwrap();
            }
            _ => {
                fs::hard_link(&path, f.root.join("linked-targets")).unwrap();
            }
        }
        assert_eq!(
            targets
                .resolve_import_binding(
                    &ImportIntent::from_wire(f.intent("workspace-patch").as_object().unwrap())
                        .unwrap()
                )
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}
