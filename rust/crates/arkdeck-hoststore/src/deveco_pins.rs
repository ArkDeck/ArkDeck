//! Swift `BootstrapDevEcoToolchainRegistry.acquire/release` (TASK-XPA-015,
//! M3): a durable owner's pin on a registered DevEco toolchain, the reference
//! a workspace preset holds while it names the toolchain. Retirement refuses
//! a pinned toolchain. The pin changes registry metadata only; the external
//! DevEco content is measured, never touched.
use super::*;
use crate::deveco_registry::{Index, Owner, Record};

/// Swift `BootstrapBundleRegistry.ReferenceKind`.
const OWNER_KINDS: [&str; 9] = [
    "installation",
    "rollback",
    "controlAction",
    "job",
    "recovery",
    "agentExecution",
    "activeLease",
    "activeSelection",
    "workspacePreset",
];
const MAXIMUM_REFERENCES: usize = 1024;

/// Swift `ReferenceOwner.init`: a closed kind and an identifier.
pub(crate) fn owner(kind: &str, id: &str) -> Result<Owner, WireError> {
    let valid = !id.is_empty()
        && id.len() <= 128
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b));
    if !OWNER_KINDS.contains(&kind) || !valid {
        return Err(failure("invalidInput", "invalid bundle reference owner"));
    }
    Ok(Owner {
        kind: kind.into(),
        id: id.into(),
    })
}

/// Swift `find`.
fn find<'a>(index: &'a mut Index, reference: &str) -> Result<&'a mut Record, WireError> {
    if !reference
        .strip_prefix("toolchain:sha256:")
        .is_some_and(crate::deveco_registry::digest)
    {
        return Err(failure(
            "invalidInput",
            "expected a content-addressed toolchain reference",
        ));
    }
    index
        .records
        .iter_mut()
        .find(|record| record.reference == reference)
        .ok_or_else(|| failure("resourceNotFound", "toolchain reference does not exist"))
}

/// Swift `acquire` on a loaded index: the pinned record's value, and whether
/// the index changed. `verify` is Swift's content verification of the record.
pub(crate) fn acquire_in(
    index: &mut Index,
    reference: &str,
    expected_generation: &str,
    owner: &Owner,
    verify: &dyn Fn(&Record) -> Result<(), WireError>,
) -> Result<(Value, bool), WireError> {
    let record = find(index, reference)?;
    if record.state != "available" || expected_generation != record.generation.to_string() {
        return Err(failure(
            "resourceConflict",
            "DevEco toolchain is retired or changed",
        ));
    }
    verify(record)?;
    let changed = !record.references.contains(owner);
    if changed {
        if record.references.len() >= MAXIMUM_REFERENCES {
            return Err(failure(
                "quotaExceeded",
                "DevEco toolchain reference bound is reached",
            ));
        }
        record.references.push(owner.clone());
        record.references.sort_by(|a, b| {
            (a.kind.as_str(), a.id.as_str()).cmp(&(b.kind.as_str(), b.id.as_str()))
        });
    }
    Ok((record.value(), changed))
}

/// Swift `release` on a loaded index: whether the index changed.
pub(crate) fn release_in(
    index: &mut Index,
    reference: &str,
    owner: &Owner,
    verify: &dyn Fn(&Record) -> Result<(), WireError>,
) -> Result<bool, WireError> {
    let record = find(index, reference)?;
    verify(record)?;
    let before = record.references.len();
    record.references.retain(|held| held != owner);
    Ok(record.references.len() != before)
}

/// Swift `resolve(_:expectedGeneration:owner:)` on a loaded index: the
/// files an available record's exact pin names — its Node launcher, Hvigor
/// script, SDK root and every other pinned child — once the record is
/// verified. The resolution requires the owner's own pin at the record's
/// current generation, so a preset can only run the toolchain it pinned.
pub(crate) fn resolve_in(
    index: &mut Index,
    reference: &str,
    expected_generation: &str,
    owner: &Owner,
    verify: &dyn Fn(&Record) -> Result<(), WireError>,
) -> Result<crate::workspace_composition::ResolvedToolchain, WireError> {
    let record = find(index, reference)?;
    if record.state != "available"
        || expected_generation != record.generation.to_string()
        || !record.references.contains(owner)
    {
        return Err(failure(
            "resourceConflict",
            "DevEco resolution requires an exact workspace-preset pin",
        ));
    }
    verify(record)?;
    let root = record.root.path.trim_end_matches('/');
    Ok(crate::workspace_composition::ResolvedToolchain {
        node_path: format!("{root}/tools/node/bin/node"),
        hvigor_script_path: format!("{root}/tools/hvigor/bin/hvigorw.js"),
        sdk_root_path: format!("{root}/sdk"),
        verified_resources: record
            .children
            .iter()
            .filter(|child| child.role != "node")
            .filter_map(|child| {
                Some(crate::workspace_profile::VerifiedResource {
                    path: format!("{root}/{}", child.relative_path),
                    sha256: child.sha256.clone(),
                    byte_count: u64::try_from(child.byte_count).ok()?,
                    require_executable: child.executable,
                })
            })
            .collect(),
    })
}

/// The encoded index Swift's `saveIndex` publishes, validated as a reader
/// would read it back.
pub(crate) fn encode(index: &Index) -> Result<Vec<u8>, WireError> {
    let encoded =
        canonical_json(&serde_json::to_value(index).map_err(unreadable)?).map_err(unreadable)?;
    if encoded.len() > MAX_INDEX {
        return Err(failure(
            "quotaExceeded",
            "DevEco toolchain index exceeds its storage bound",
        ));
    }
    crate::deveco_registry::read_index(&encoded).map_err(unreadable)?;
    Ok(encoded)
}

/// Swift's `verify` of an available record, with the refusal codes the
/// registry's retirement answers for the same measurement.
fn verify_content(record: &Record) -> Result<(), WireError> {
    crate::deveco_content::verify(record).map_err(|error| {
        let code = if error
            .get_ref()
            .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoIdentityChanged>())
        {
            "fileIdentityChanged"
        } else if error
            .get_ref()
            .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoInputTooLarge>())
        {
            "inputTooLarge"
        } else if error.raw_os_error().is_some() {
            "ioFailure"
        } else {
            match error.kind() {
                io::ErrorKind::PermissionDenied => "admissionDenied",
                io::ErrorKind::NotFound => "fileIdentityChanged",
                _ => "recordUnreadable",
            }
        };
        let message = if code == "recordUnreadable" {
            "registered DevEco root, manifests or child tools changed"
        } else {
            "registered DevEco root, manifests or child tools failed verification"
        };
        failure(code, message)
    })
}

impl DevEcoRegistryStore {
    /// Pins `reference` at `expected_generation` for the durable owner
    /// (`kind`, `id`), as Swift's `acquire`; a held pin is kept as it is.
    pub fn acquire(
        &self,
        reference: &str,
        expected_generation: &str,
        kind: &str,
        id: &str,
    ) -> Result<Value, WireError> {
        let owner = owner(kind, id)?;
        self.pin_transaction(|index| {
            acquire_in(
                index,
                reference,
                expected_generation,
                &owner,
                &verify_content,
            )
        })
    }

    /// Resolves the toolchain the owner's exact pin names, as Swift's
    /// `resolve`: the record re-measured, nothing written.
    pub fn resolve(
        &self,
        reference: &str,
        expected_generation: u64,
        kind: &str,
        id: &str,
    ) -> Result<crate::workspace_composition::ResolvedToolchain, WireError> {
        let owner = owner(kind, id)?;
        self.pin_transaction(|index| {
            resolve_in(
                index,
                reference,
                &expected_generation.to_string(),
                &owner,
                &verify_content,
            )
            .map(|resolved| (resolved, false))
        })
    }

    /// Releases the owner's pin on `reference`, as Swift's `release`; an
    /// absent pin is left absent.
    pub fn release(&self, reference: &str, kind: &str, id: &str) -> Result<(), WireError> {
        let owner = owner(kind, id)?;
        self.pin_transaction(|index| {
            release_in(index, reference, &owner, &verify_content).map(|changed| ((), changed))
        })
    }

    /// Swift's `withSharedStore` transaction, as `retire` runs it: both
    /// indexes loaded under the bootstrap lock, the change published only if
    /// the index changed and nothing else moved meanwhile.
    fn pin_transaction<T>(
        &self,
        body: impl FnOnce(&mut Index) -> Result<(T, bool), WireError>,
    ) -> Result<T, WireError> {
        let owner = RetirementRoot {
            root: &self.root,
            path: &self.path,
        };
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure(
                    "resourceConflict",
                    "another bootstrap operation holds the store; retry after it completes",
                )
            } else {
                unreadable(error)
            }
        })?;
        owner.retirement_binding(&lock)?;
        let bundles = owner.retirement_load(&lock, BUNDLES)?;
        decode_bundles(&bundles.bytes).map_err(unreadable)?;
        let previous = owner.retirement_load(&lock, DEVECO)?;
        let (mut index, _) =
            crate::deveco_registry::read_index(&previous.bytes).map_err(unreadable)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        let (answer, changed) = body(&mut index)?;
        if !changed {
            return Ok(answer);
        }
        let encoded = encode(&index)?;
        owner.retirement_binding(&lock)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        owner.retirement_index(DEVECO, &previous)?;
        self.root
            .publish_document(DEVECO, &encoded, MAX_INDEX)
            .map_err(|error| publication(error, DEVECO))?;
        (|| {
            owner.retirement_binding(&lock)?;
            owner.retirement_index(BUNDLES, &bundles)?;
            if self.root.read(DEVECO, MAX_INDEX).map_err(unreadable)? != encoded {
                return Err(unreadable("published index changed"));
            }
            Ok(())
        })()
        .map_err(|_: WireError| unknown())?;
        Ok(answer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn oracle() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/deveco-toolchain-pins")
    }

    /// Every acquire and release Swift's registry recorded, replayed on the
    /// index it recorded before the step: the same answer or refusal, and the
    /// index it recorded after, byte for byte. Content verification is Swift's
    /// injected one: it holds until the recorded content change, then refuses.
    #[test]
    fn pins_and_releases_leave_swift_s_index_byte_for_byte() {
        let cases: Value =
            serde_json::from_slice(&std::fs::read(oracle().join("cases.json")).unwrap()).unwrap();
        let state = |digest: &Value| {
            std::fs::read(oracle().join(format!("states/{}.json", digest.as_str().unwrap())))
                .unwrap()
        };
        let mut replayed = 0;
        for timeline in cases["timelines"].as_array().unwrap() {
            let mut current: Option<Vec<u8>> = None;
            let mut content_changed = false;
            for step in timeline["steps"].as_array().unwrap() {
                let name = format!("{} {}", timeline["name"], step["name"]);
                let recorded = state(&step["state"]);
                let call = step["call"].as_str().unwrap();
                if call == "changeHvigor" {
                    content_changed = true;
                }
                if call == "acquire" || call == "release" {
                    let changed_content = content_changed;
                    let verify = move |_: &Record| {
                        if changed_content {
                            Err(failure(
                                "recordUnreadable",
                                "registered DevEco root, manifests or child tools changed",
                            ))
                        } else {
                            Ok(())
                        }
                    };
                    let before = current.clone().expect("a registered index");
                    let (mut index, _) = crate::deveco_registry::read_index(&before).unwrap();
                    let owner = owner(
                        step["owner"]["kind"].as_str().unwrap(),
                        step["owner"]["id"].as_str().unwrap(),
                    )
                    .unwrap();
                    let reference = step["reference"].as_str().unwrap();
                    let outcome = if call == "acquire" {
                        acquire_in(
                            &mut index,
                            reference,
                            step["expectedGeneration"].as_str().unwrap(),
                            &owner,
                            &verify,
                        )
                    } else {
                        release_in(&mut index, reference, &owner, &verify)
                            .map(|changed| (Value::Null, changed))
                    };
                    let after = match outcome {
                        Ok((answer, changed)) => {
                            assert_eq!(step["error"], Value::Null, "{name}");
                            assert_eq!(answer, step["answer"], "{name}");
                            if changed {
                                encode(&index).unwrap()
                            } else {
                                before
                            }
                        }
                        Err(error) => {
                            assert_eq!(
                                json!({"code": error.code, "message": error.message}),
                                step["error"],
                                "{name}"
                            );
                            before
                        }
                    };
                    assert_eq!(
                        String::from_utf8(after).unwrap(),
                        String::from_utf8(recorded.clone()).unwrap(),
                        "{name}"
                    );
                    replayed += 1;
                }
                current = Some(recorded);
            }
        }
        assert_eq!(
            replayed, 19,
            "every recorded acquire and release was replayed"
        );
    }

    fn registry() -> (PathBuf, DevEcoRegistryStore) {
        use std::os::unix::fs::DirBuilderExt;
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/deveco-pins-{nonce:032x}"));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        let store = DevEcoRegistryStore::open_existing(&path).unwrap();
        (path, store)
    }

    fn write(path: &std::path::Path, name: &str, bytes: &[u8]) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path.join(name), bytes).unwrap();
        std::fs::set_permissions(path.join(name), std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    /// An empty registry is created as Swift's shared store creates it, and
    /// holds no toolchain to pin; nothing else is written.
    #[test]
    fn a_pin_in_an_empty_registry_finds_no_toolchain() {
        let (path, store) = registry();
        let reference = format!("toolchain:sha256:{}", "a".repeat(64));
        let refused = store
            .acquire(&reference, "1", "workspacePreset", "preset-a")
            .unwrap_err();
        assert_eq!(
            (refused.code.as_str(), refused.message.as_str()),
            ("resourceNotFound", "toolchain reference does not exist")
        );
        assert_eq!(
            std::fs::read(path.join(DEVECO)).unwrap(),
            br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1"}"#
        );
        for (reference, owner, code) in [
            ("toolchain:md5:abc", "preset-a", "invalidInput"),
            (reference.as_str(), "-preset", "invalidInput"),
        ] {
            assert_eq!(
                store
                    .release(reference, "workspacePreset", owner)
                    .unwrap_err()
                    .code,
                code
            );
        }
        std::fs::remove_dir_all(path).unwrap();
    }

    /// A retired toolchain cannot be pinned, and nothing is published for the
    /// refusal. Its retained metadata needs no retained content.
    #[test]
    fn a_retired_toolchain_is_not_pinned() {
        let (path, store) = registry();
        let cases: Value =
            serde_json::from_slice(&std::fs::read(oracle().join("cases.json")).unwrap()).unwrap();
        let life = &cases["timelines"][0]["steps"];
        let removed = life
            .as_array()
            .unwrap()
            .iter()
            .find(|step| step["name"] == "remove")
            .unwrap();
        let state = std::fs::read(oracle().join(format!(
            "states/{}.json",
            removed["state"].as_str().unwrap()
        )))
        .unwrap();
        write(
            &path,
            BUNDLES,
            br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#,
        );
        write(&path, DEVECO, &state);
        let refused = store
            .acquire(
                cases["reference"].as_str().unwrap(),
                "1",
                "workspacePreset",
                "preset-a",
            )
            .unwrap_err();
        assert_eq!(
            (refused.code.as_str(), refused.message.as_str()),
            ("resourceConflict", "DevEco toolchain is retired or changed")
        );
        assert_eq!(std::fs::read(path.join(DEVECO)).unwrap(), state);
        std::fs::remove_dir_all(path).unwrap();
    }

    /// Swift's `ReferenceOwner`: a closed kind and an identifier that starts
    /// with a letter or digit.
    #[test]
    fn an_owner_outside_swift_s_kinds_or_identifiers_is_refused() {
        assert!(owner("workspacePreset", "preset-a").is_ok());
        assert!(owner("job", "9.job_x-1").is_ok());
        for (kind, id) in [
            ("workspacepreset", "preset-a"),
            ("workspacePreset", ""),
            ("workspacePreset", "-preset"),
            ("workspacePreset", "preset/a"),
            ("workspacePreset", &"p".repeat(129)),
        ] {
            let refused = owner(kind, id).unwrap_err();
            assert_eq!(
                (refused.code.as_str(), refused.message.as_str()),
                ("invalidInput", "invalid bundle reference owner"),
                "{kind} {id}"
            );
        }
    }

    /// A resolution requires the owner's own pin at the current generation
    /// and a verified record, and names the pinned children but Node.
    #[test]
    fn a_resolution_names_the_pinned_toolchain_only_for_its_exact_pin() {
        let cases: Value =
            serde_json::from_slice(&std::fs::read(oracle().join("cases.json")).unwrap()).unwrap();
        // The first timeline's state after its first successful acquire.
        let timeline = &cases["timelines"][0];
        let step = timeline["steps"]
            .as_array()
            .unwrap()
            .iter()
            .find(|step| step["call"] == "acquire" && step["error"].is_null())
            .expect("a recorded acquire");
        let bytes = std::fs::read(
            oracle().join(format!("states/{}.json", step["state"].as_str().unwrap())),
        )
        .unwrap();
        let (mut index, _) = crate::deveco_registry::read_index(&bytes).unwrap();
        let reference = step["reference"].as_str().unwrap();
        let generation = step["expectedGeneration"].as_str().unwrap();
        let pinned = owner(
            step["owner"]["kind"].as_str().unwrap(),
            step["owner"]["id"].as_str().unwrap(),
        )
        .unwrap();
        let verified = |_: &Record| Ok(());
        let resolved = resolve_in(&mut index, reference, generation, &pinned, &verified).unwrap();
        let root = index
            .records
            .iter()
            .find(|record| record.reference == reference)
            .unwrap()
            .root
            .path
            .clone();
        assert_eq!(resolved.node_path, format!("{root}/tools/node/bin/node"));
        assert_eq!(
            resolved.hvigor_script_path,
            format!("{root}/tools/hvigor/bin/hvigorw.js")
        );
        assert_eq!(resolved.sdk_root_path, format!("{root}/sdk"));
        assert!(!resolved.verified_resources.is_empty());
        assert!(
            resolved
                .verified_resources
                .iter()
                .all(|resource| !resource.path.ends_with("/tools/node/bin/node"))
        );
        let conflict = |result: Result<_, WireError>| {
            assert_eq!(result.unwrap_err().code, "resourceConflict");
        };
        let other = owner("workspacePreset", "preset-someone-else").unwrap();
        conflict(resolve_in(
            &mut index, reference, generation, &other, &verified,
        ));
        conflict(resolve_in(&mut index, reference, "999", &pinned, &verified));
        let drifted = |_: &Record| {
            Err(failure(
                "recordUnreadable",
                "registered DevEco root, manifests or child tools changed",
            ))
        };
        assert_eq!(
            resolve_in(&mut index, reference, generation, &pinned, &drifted)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}
