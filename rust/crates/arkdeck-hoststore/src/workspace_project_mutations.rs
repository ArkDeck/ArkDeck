//! Swift `RuntimeWorkspaceProjectStore.update/remove/listPresets/inspectPreset`
//! behind `workspace.project.update/remove` and `workspace.preset.list/show`
//! (TASK-XPA-015, M3). A mutation first asks the durable Job census whether an
//! active or uncertain workspace Job names the project, as Swift does before it
//! opens its document; these methods never pin or change a preset.
use super::preset_mutations::{
    PresetRecord, canonical_positive, invalid_params, valid_timestamp, validate_preset_ref,
    validate_project_ref,
};
use super::*;

/// The preset owner's refusals carry its phase, as Swift's
/// `workspacePresetFailure` answers them. A malformed request carries none.
pub(super) fn preset_phase(mut error: WireError) -> WireError {
    if let Some(details) = error.details.as_mut() {
        details.insert("phase".into(), json!("workspacePresetOwner"));
    }
    error
}

const PRESET_KINDS: [&str; 4] = ["build", "test", "signing", "symbol"];

/// Swift `encodeRegisteredWorkspaceProject` of a removed project.
fn removed_resource(record: &Record) -> Value {
    let mut value = resource(record);
    for (key, field) in [
        ("configurationStatus", json!("removed")),
        ("availability", json!("removed")),
        ("reasonCode", json!("workspace_project_removed")),
        (
            "reason",
            json!("the private workspace root grant was removed"),
        ),
    ] {
        value[key] = field;
    }
    value
}

fn available_presets<'a>(
    presets: &'a [PresetRecord],
    project: &'a str,
) -> impl Iterator<Item = &'a PresetRecord> {
    presets
        .iter()
        .filter(move |preset| preset.project_ref == project && preset.available())
}

impl WorkspaceProjectStore {
    pub(super) fn handle_mutation(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &dyn Fn() -> String,
        census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        let text = |key: &str| params.get(key).and_then(Value::as_str);
        match method {
            "workspace.project.update" | "workspace.project.remove" => {
                let update = method.ends_with(".update");
                let (keys, message): (&[&str], &str) = if update {
                    (
                        &["projectRef", "expectedGeneration", "kind", "root"],
                        "workspace project update requires exact project, generation, kind and root",
                    )
                } else {
                    (
                        &["projectRef", "expectedGeneration"],
                        "workspace project remove requires exact project and generation",
                    )
                };
                let generation = canonical_positive(params.get("expectedGeneration"));
                if params.len() != keys.len()
                    || keys.iter().any(|key| text(key).is_none())
                    || generation.is_none()
                {
                    return Err(invalid_params(message));
                }
                let (project, generation) = (text("projectRef").unwrap(), generation.unwrap());
                validate_project_ref(project)?;
                let target = if update {
                    let family = text("kind").unwrap();
                    if !kind(family) {
                        return Err(failure(
                            "invalidInput",
                            "workspace project kind must be arkdeck or openharmony",
                        ));
                    }
                    Some((family, inspect_root(text("root").unwrap())?))
                } else {
                    None
                };
                self.with_document(
                    || {
                        self.require_no_use(project)?;
                        census(WorkspaceReference::Project(project))
                    },
                    |transaction, document| {
                        let mut next = document;
                        let index = next
                            .records
                            .iter()
                            .position(|record| record.project_ref == project)
                            .ok_or_else(|| {
                                failure(
                                    "workspaceReferenceNotFound",
                                    "workspace project is not registered",
                                )
                            })?;
                        if next.records[index].generation != generation {
                            return Err(failure(
                                "resourceConflict",
                                "workspace project generation changed",
                            ));
                        }
                        let Some((family, root)) = target else {
                            if available_presets(&next.presets, project).next().is_some() {
                                return Err(failure(
                                    "resourceConflict",
                                    "remove project presets before removing the project",
                                ));
                            }
                            let removed = next.records.remove(index);
                            transaction.save(&next)?;
                            return Ok(removed_resource(&removed));
                        };
                        if next.records[index].kind != family
                            && available_presets(&next.presets, project).next().is_some()
                        {
                            return Err(failure(
                                "resourceConflict",
                                "remove project presets before changing the project kind",
                            ));
                        }
                        if next
                            .records
                            .iter()
                            .enumerate()
                            .any(|(offset, record)| offset != index && record.root == root)
                        {
                            return Err(failure(
                                "resourceConflict",
                                "workspace root is already registered",
                            ));
                        }
                        if generation >= i64::MAX as u64 {
                            return Err(failure(
                                "resourceConflict",
                                "workspace project generation is exhausted",
                            ));
                        }
                        let record = &mut next.records[index];
                        record.generation = generation + 1;
                        record.kind = family.into();
                        record.root = root;
                        record.updated_at = valid_timestamp(now)?;
                        let answer = resource(record);
                        transaction.save(&next)?;
                        Ok(answer)
                    },
                )
            }
            "workspace.preset.list" | "workspace.preset.show" => {
                let show = method.ends_with(".show");
                let project = text("projectRef").filter(|reference| !reference.is_empty());
                if show {
                    if project.is_none() || text("presetRef").is_none_or(str::is_empty) {
                        return Err(invalid_params("projectRef and presetRef are required"));
                    }
                    if params.len() != 2 {
                        return Err(invalid_params(
                            "workspace preset show requires exact projectRef and presetRef",
                        ));
                    }
                } else {
                    if project.is_none() {
                        return Err(invalid_params("projectRef is required"));
                    }
                    if params
                        .keys()
                        .any(|key| key != "projectRef" && key != "kind")
                    {
                        return Err(invalid_params(
                            "workspace preset list accepts only projectRef and kind",
                        ));
                    }
                    if params.get("kind").is_some_and(|kind| !kind.is_string()) {
                        return Err(invalid_params("kind must be text"));
                    }
                }
                let project = project.unwrap();
                let read = || {
                    validate_project_ref(project)?;
                    if show {
                        validate_preset_ref(text("presetRef").unwrap())?;
                    } else if let Some(kind) = text("kind")
                        && !PRESET_KINDS.contains(&kind)
                    {
                        return Err(failure(
                            "invalidInput",
                            "workspace preset kind must be build, test, signing or symbol",
                        ));
                    }
                    self.with_document(
                        || Ok(()),
                        |_, document| {
                            if show {
                                let preset = text("presetRef").unwrap();
                                return available_presets(&document.presets, project)
                                    .find(|candidate| candidate.preset_ref == preset)
                                    .ok_or_else(|| {
                                        failure(
                                            "workspaceReferenceNotFound",
                                            "workspace preset is not registered",
                                        )
                                    })?
                                    .resource();
                            }
                            if !document
                                .records
                                .iter()
                                .any(|record| record.project_ref == project)
                            {
                                return Err(failure(
                                    "workspaceReferenceNotFound",
                                    "workspace project is not registered",
                                ));
                            }
                            let mut presets: Vec<&PresetRecord> =
                                available_presets(&document.presets, project)
                                    .filter(|preset| {
                                        text("kind").is_none_or(|kind| preset.kind == kind)
                                    })
                                    .collect();
                            presets.sort_by(|left, right| left.preset_ref.cmp(&right.preset_ref));
                            Ok(json!({
                                "schemaVersion": "arkdeck.workspace-preset-list/1",
                                "projectRef": project,
                                "presets": presets
                                    .into_iter()
                                    .map(PresetRecord::resource)
                                    .collect::<Result<Vec<_>, _>>()?,
                            }))
                        },
                    )
                };
                read().map_err(preset_phase)
            }
            _ => Err(failure("unknownMethod", "not a workspace project method")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;

    struct Fixture {
        base: PathBuf,
        store: WorkspaceProjectStore,
    }

    impl Fixture {
        fn new() -> Self {
            let base = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "workspace-mutations-{}",
                sha256_hex(&arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            for name in ["", "owner", "first", "second", "third"] {
                std::fs::DirBuilder::new()
                    .mode(0o700)
                    .create(base.join(name))
                    .unwrap();
            }
            let store = WorkspaceProjectStore::open(&base.join("owner")).unwrap();
            Self { base, store }
        }

        fn call(&self, method: &str, params: Value) -> Result<Value, WireError> {
            self.call_with(method, params, &|_| Ok(()))
        }

        fn call_with(
            &self,
            method: &str,
            params: Value,
            census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
        ) -> Result<Value, WireError> {
            self.store.handle(
                method,
                params.as_object().unwrap(),
                &|| "2026-09-19T00:00:00.000Z".into(),
                census,
            )
        }

        fn project(&self, request: &str, root: &str) -> String {
            self.call(
                "workspace.project.register",
                json!({"registrationRequestId": request, "kind": "openharmony",
                       "root": self.base.join(root).to_str().unwrap()}),
            )
            .unwrap()["projectRef"]
                .as_str()
                .unwrap()
                .to_owned()
        }

        fn document(&self) -> Value {
            serde_json::from_slice(&std::fs::read(self.base.join("owner/projects.json")).unwrap())
                .unwrap()
        }

        fn write(&self, document: &Value) {
            let path = self.base.join("owner/projects.json");
            std::fs::write(&path, crate::session_json::encode(document).unwrap()).unwrap();
        }

        /// A Swift-shaped available symbol preset of `project`, its digests
        /// computed by the validator's own definition digest.
        fn seed_symbol_preset(&self, project: &str, request: &str) -> String {
            let reference = format!("preset-{}", &sha256_hex(request.as_bytes())[..24]);
            let constraints = json!({"relativeSourceMap": "entry/build/sourceMaps.map"});
            let mut preset = json!({
                "presetRef": reference, "generation": 1, "projectRef": project,
                "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
                "timeoutSeconds": 600, "constraints": constraints,
                "registrationRequestID": request, "registrationProjectRef": project,
                "registrationKind": "symbol",
                "registrationTemplateRef": "openharmony.arkts-symbol@1",
                "registrationTimeoutSeconds": 600, "registrationConstraints": constraints,
                "registeredAtUTC": "2026-09-19T00:00:00.000Z",
                "updatedAtUTC": "2026-09-19T00:00:00.000Z", "state": "available",
                "lastMutationRequestID": request,
            });
            let digest = presets::definition(&preset, true).unwrap();
            preset["registrationDigest"] = json!(digest);
            preset["currentDefinitionDigest"] = json!(presets::definition(&preset, false).unwrap());
            preset["lastMutationDigest"] = json!(digest);
            let mut document = self.document();
            document["presets"].as_array_mut().unwrap().push(preset);
            self.write(&document);
            reference
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    /// The code and owner phase of a refusal. A malformed request carries no
    /// owner details, as Swift's daemon answers it.
    fn code(result: Result<Value, WireError>) -> (String, Value) {
        let error = result.unwrap_err();
        let phase = error
            .details
            .map_or(Value::Null, |details| details["phase"].clone());
        (error.code, phase)
    }

    fn phase_of(code: &str, owner: &str) -> Value {
        if code == "invalidParams" {
            Value::Null
        } else {
            json!(owner)
        }
    }

    #[test]
    fn presets_are_listed_and_shown_as_swift_projects_them() {
        let fixture = Fixture::new();
        let alpha = fixture.project("alpha", "first");
        let beta = fixture.project("beta", "second");
        let preset = fixture.seed_symbol_preset(&alpha, "symbol-request");
        let listed = fixture
            .call("workspace.preset.list", json!({"projectRef": alpha}))
            .unwrap();
        assert_eq!(listed["schemaVersion"], "arkdeck.workspace-preset-list/1");
        assert_eq!(listed["projectRef"], alpha.as_str());
        let resource = &listed["presets"][0];
        assert_eq!(resource["presetRef"], preset.as_str());
        assert_eq!(resource["generation"], "1");
        assert_eq!(resource["toolchainRef"], Value::Null);
        assert_eq!(resource["toolchainGeneration"], Value::Null);
        assert_eq!(resource["credentialRef"], Value::Null);
        assert_eq!(resource["timeoutSeconds"], 600);
        assert_eq!(
            resource["constraints"],
            json!({"relativeSourceMap": "entry/build/sourceMaps.map"})
        );
        assert_eq!(resource["configurationStatus"], "runtimeRestartRequired");
        assert!(
            validate_method_result("workspace.preset.list", &listed),
            "{listed}"
        );
        assert_eq!(
            fixture
                .call(
                    "workspace.preset.list",
                    json!({"projectRef": alpha, "kind": "build"})
                )
                .unwrap()["presets"],
            json!([])
        );
        assert_eq!(
            fixture
                .call(
                    "workspace.preset.show",
                    json!({"projectRef": alpha, "presetRef": preset})
                )
                .unwrap(),
            *resource
        );
        for (method, params, expected) in [
            (
                "workspace.preset.list",
                json!({"projectRef": "project-unknown"}),
                "workspaceReferenceNotFound",
            ),
            (
                "workspace.preset.list",
                json!({"projectRef": "bad/reference"}),
                "invalidInput",
            ),
            (
                "workspace.preset.list",
                json!({"projectRef": alpha, "kind": "sideways"}),
                "invalidInput",
            ),
            (
                "workspace.preset.show",
                json!({"projectRef": beta, "presetRef": preset}),
                "workspaceReferenceNotFound",
            ),
            (
                "workspace.preset.show",
                json!({"projectRef": alpha, "presetRef": "nope"}),
                "invalidInput",
            ),
            (
                "workspace.preset.show",
                json!({"projectRef": alpha}),
                "invalidParams",
            ),
        ] {
            assert_eq!(
                code(fixture.call(method, params.clone())),
                (
                    expected.to_owned(),
                    phase_of(expected, "workspacePresetOwner")
                ),
                "{method} {params}"
            );
        }
    }

    #[test]
    fn a_project_is_updated_and_removed_under_swift_s_rules() {
        let fixture = Fixture::new();
        let alpha = fixture.project("alpha", "first");
        let beta = fixture.project("beta", "second");
        fixture.seed_symbol_preset(&alpha, "symbol-request");
        let root = |name: &str| fixture.base.join(name).to_str().unwrap().to_owned();
        let update = |project: &str, generation: &str, kind: &str, directory: &str| {
            json!({"projectRef": project, "expectedGeneration": generation,
                   "kind": kind, "root": root(directory)})
        };
        for (params, expected) in [
            (update(&alpha, "1", "arkdeck", "first"), "resourceConflict"),
            (
                update(&alpha, "1", "openharmony", "second"),
                "resourceConflict",
            ),
            (
                update(&alpha, "7", "openharmony", "third"),
                "resourceConflict",
            ),
            (
                update("project-unknown", "1", "openharmony", "third"),
                "workspaceReferenceNotFound",
            ),
            (update(&alpha, "1", "sideways", "third"), "invalidInput"),
            (update(&alpha, "1", "openharmony", "absent"), "invalidInput"),
            (
                update(&alpha, "01", "openharmony", "third"),
                "invalidParams",
            ),
        ] {
            assert_eq!(
                code(fixture.call("workspace.project.update", params.clone())),
                (
                    expected.to_owned(),
                    phase_of(expected, "workspaceProjectOwner")
                ),
                "{params}"
            );
        }
        let before = fixture.document();
        let refused = fixture.call_with(
            "workspace.project.update",
            update(&alpha, "1", "openharmony", "third"),
            &|reference| {
                assert_eq!(reference, WorkspaceReference::Project(&alpha));
                Err(failure(
                    "resourceConflict",
                    "workspace project is referenced by an active or uncertain Job",
                ))
            },
        );
        assert_eq!(refused.unwrap_err().code, "resourceConflict");
        assert_eq!(
            fixture.document(),
            before,
            "a refused update writes nothing"
        );
        let moved = fixture
            .call(
                "workspace.project.update",
                update(&alpha, "1", "openharmony", "third"),
            )
            .unwrap();
        assert_eq!(moved["generation"], "2");
        assert_eq!(moved["configurationStatus"], "runtimeRestartRequired");
        assert!(!moved.to_string().contains(&root("third")));
        assert_eq!(
            fixture.document()["records"][0]["root"]["path"],
            root("third")
        );

        let remove = |project: &str, generation: &str| json!({"projectRef": project, "expectedGeneration": generation});
        assert_eq!(
            code(fixture.call("workspace.project.remove", remove(&alpha, "2"))).0,
            "resourceConflict",
            "a project with an available preset is kept"
        );
        assert_eq!(
            code(fixture.call("workspace.project.remove", remove(&beta, "2"))).0,
            "resourceConflict"
        );
        let removed = fixture
            .call("workspace.project.remove", remove(&beta, "1"))
            .unwrap();
        assert_eq!(removed["configurationStatus"], "removed");
        assert_eq!(removed["availability"], "removed");
        assert_eq!(removed["reasonCode"], "workspace_project_removed");
        assert_eq!(
            fixture.call("workspace.project.list", json!({})).unwrap()["projects"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            code(fixture.call("workspace.project.remove", remove(&beta, "1"))).0,
            "workspaceReferenceNotFound"
        );
    }

    #[test]
    fn a_retained_mutation_or_an_unreadable_document_refuses_every_method() {
        let fixture = Fixture::new();
        let alpha = fixture.project("alpha", "first");
        let preset = fixture.seed_symbol_preset(&alpha, "symbol-request");
        let requests = [
            (
                "workspace.project.update",
                json!({"projectRef": alpha, "expectedGeneration": "1", "kind": "openharmony",
                       "root": fixture.base.join("third").to_str().unwrap()}),
            ),
            (
                "workspace.project.remove",
                json!({"projectRef": alpha, "expectedGeneration": "1"}),
            ),
            ("workspace.preset.list", json!({"projectRef": alpha})),
            (
                "workspace.preset.show",
                json!({"projectRef": alpha, "presetRef": preset}),
            ),
        ];
        let mut pending = fixture.document();
        pending["pendingToolchainMutation"] = json!({
            "action": "release", "toolchainRef": format!("toolchain:sha256:{}", "a".repeat(64)),
            "toolchainGeneration": 1, "presetRef": "preset-retained",
        });
        let broken = b"{broken".to_vec();
        for (bytes, expected) in [
            (
                crate::session_json::encode(&pending).unwrap(),
                "operationUnavailable",
            ),
            (broken, "recordUnreadable"),
        ] {
            std::fs::write(fixture.base.join("owner/projects.json"), &bytes).unwrap();
            for (method, params) in &requests {
                assert_eq!(
                    fixture.call(method, params.clone()).unwrap_err().code,
                    expected,
                    "{method}"
                );
                assert_eq!(
                    std::fs::read(fixture.base.join("owner/projects.json")).unwrap(),
                    bytes
                );
            }
        }
    }

    /// One key more in a project record than Swift's `CodingKeys` is refused,
    /// not dropped, by every new method.
    #[test]
    fn a_record_with_one_more_key_is_refused() {
        let fixture = Fixture::new();
        let alpha = fixture.project("alpha", "first");
        let mut document = fixture.document();
        document["records"][0]["note"] = json!("x");
        fixture.write(&document);
        assert_eq!(
            fixture
                .call("workspace.preset.list", json!({"projectRef": alpha}))
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(
            fixture
                .call(
                    "workspace.project.remove",
                    json!({"projectRef": alpha, "expectedGeneration": "1"})
                )
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }

    fn validate_method_result(method: &str, value: &Value) -> bool {
        arkdeck_contract::validate_method_value(method, "result", value).is_ok()
    }
}
