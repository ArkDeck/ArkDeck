//! RuntimeStateContinuity: a new directory cannot reset mutation authority.
//! Read-only validation of the owner's current index and retained Sessions;
//! no capability, record, journal or retired state is repaired or removed.
use super::JobStore;
use arkdeck_contract::{WireError, strict_json};
use arkdeck_platform::{HostDirectory, HostEntryKind};
use std::{
    collections::BTreeSet,
    io,
    path::{Component, Path, PathBuf},
};

const ENTRY_BOUND: usize = 100_000;
const DOCUMENT_BOUND: usize = 16 * 1024 * 1024;
const JOURNAL_BOUND: usize = 64 * 1024 * 1024;

fn refused() -> WireError {
    crate::job_record::failure(
        "recordUnreadable",
        "Runtime mutation state continuity cannot be proved; original state is preserved",
    )
}

fn normalized(path: &Path) -> Result<PathBuf, WireError> {
    if !path.is_absolute() {
        return Err(refused());
    }
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => (),
            _ => result.push(component.as_os_str()),
        }
    }
    Ok(result)
}

fn exists(path: &Path) -> Result<bool, WireError> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(refused()),
    }
}

fn optional_child(parent: &HostDirectory, name: &str) -> Result<Option<HostDirectory>, WireError> {
    match parent.child(name) {
        Ok(child) => Ok(Some(child)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(refused()),
    }
}

fn optional_read(
    parent: &HostDirectory,
    name: &str,
    bound: usize,
) -> Result<Option<Vec<u8>>, WireError> {
    match parent.read(name, bound) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(refused()),
    }
}

fn read_only_history(bytes: &[u8]) -> Result<(), WireError> {
    let value = strict_json(bytes).map_err(|_| refused())?;
    let fields = value.as_object().ok_or_else(refused)?;
    let request = fields
        .get("request")
        .and_then(|v| v.as_object())
        .ok_or_else(refused)?;
    if request.contains_key("authorization")
        || !matches!(
            fields.get("actualEffect").and_then(|v| v.as_str()),
            Some("hostOnly" | "readOnly")
        )
    {
        return Err(refused());
    }
    Ok(())
}

fn check_sessions(path: &Path) -> Result<(), WireError> {
    if !exists(path)? {
        return Ok(());
    }
    // Resolve case spelling on case-insensitive APFS, without permitting any
    // symlink component. A configured `sessions` can also be the default
    // sibling `Sessions`; canonical spelling is not a distinct authority root.
    let physical = session_root_path(path)?;
    let root = HostDirectory::open_session_tree(&physical).map_err(|_| refused())?;
    let mut remaining = ENTRY_BOUND;
    inspect_session_children(&root, &physical, 0, &mut remaining)?;
    if session_root_path(path)? != physical {
        return Err(refused());
    }
    root.validate_path(&physical).map_err(|_| refused())
}

fn session_root_path(path: &Path) -> Result<PathBuf, WireError> {
    for component in path.ancestors() {
        if std::fs::symlink_metadata(component)
            .map_err(|_| refused())?
            .file_type()
            .is_symlink()
        {
            return Err(refused());
        }
    }
    path.canonicalize().map_err(|_| refused())
}

fn inspect_session_children(
    root: &HostDirectory,
    path: &Path,
    depth: usize,
    remaining: &mut usize,
) -> Result<(), WireError> {
    for name in root.names(*remaining).map_err(|_| refused())? {
        *remaining = remaining.checked_sub(1).ok_or_else(refused)?;
        match root.kind_and_size(&name).map_err(|_| refused())?.0 {
            HostEntryKind::Regular => continue,
            HostEntryKind::Directory => (),
            HostEntryKind::Other => return Err(refused()),
        }
        let session = root.child(&name).map_err(|_| refused())?;
        let child_path = path.join(&name);
        let manifest = optional_read(&session, "manifest.json", DOCUMENT_BOUND)?;
        let journal = optional_read(&session, "journal.jsonl", JOURNAL_BOUND)?;
        if let Some(bytes) = &manifest {
            crate::session_manifest::decode_manifest(bytes).map_err(|_| refused())?;
        }
        if let Some(bytes) = &journal {
            let replay =
                crate::job_journal_replay::ReplayState::replay(bytes).map_err(|_| refused())?;
            let facts = replay.state.facts(replay.torn);
            let mutation = |effect: &str| matches!(effect, "deviceMutation" | "destructive");
            if facts.has_torn_tail
                || facts
                    .outstanding_intents
                    .iter()
                    .any(|intent| mutation(&intent.effect))
                || facts
                    .unknown_outcomes
                    .iter()
                    .any(|outcome| mutation(&outcome.effect))
            {
                return Err(refused());
            }
        }
        // Current production SessionStore is YYYY/MM/session-ID. Inspect its
        // containers as well as older flat roots, but never reinterpret raw
        // Artifact subdirectories beneath a discovered Session as control state.
        if manifest.is_none() && journal.is_none() {
            if depth >= 3 {
                return Err(refused());
            }
            inspect_session_children(&session, &child_path, depth + 1, remaining)?;
        }
        session.validate_path(&child_path).map_err(|_| refused())?;
    }
    Ok(())
}

impl JobStore {
    /// Called before mutation admission and again immediately before consuming
    /// authority. `default_root` and Session roots come from Runtime composition,
    /// never from an operation's inputs, transport peer or development override.
    pub fn require_mutation_state(
        &self,
        default_root: &Path,
        session_roots: &[PathBuf],
    ) -> Result<(), WireError> {
        let expected = normalized(default_root)?;
        if normalized(&self.path)? != expected {
            return Err(refused());
        }
        let _activity = self.activity.lock().map_err(|_| refused())?;
        self.root.validate_path(&self.path).map_err(|_| refused())?;
        let parent = expected.parent().ok_or_else(refused)?;
        if exists(&parent.join("AuthorizationUsage"))? {
            return Err(refused());
        }
        let checkpoint_exists = match optional_child(&self.root, "capabilities")? {
            Some(capabilities) => match capabilities.kind_and_size("runtime-capabilities.json") {
                Ok((HostEntryKind::Regular, _)) => true,
                Err(error) if error.kind() == io::ErrorKind::NotFound => false,
                _ => return Err(refused()),
            },
            None => false,
        };
        if !checkpoint_exists {
            if let Some(jobs) = optional_child(&self.root, "jobs")? {
                for name in jobs.names(ENTRY_BOUND).map_err(|_| refused())? {
                    let job = jobs.child(&name).map_err(|_| refused())?;
                    let bytes = job
                        .read("job-record.json", DOCUMENT_BOUND)
                        .map_err(|_| refused())?;
                    read_only_history(&bytes)?;
                    job.validate_path(&self.path.join("jobs").join(&name))
                        .map_err(|_| refused())?;
                }
                jobs.validate_path(&self.path.join("jobs"))
                    .map_err(|_| refused())?;
            }
            // The index may be the only surviving copy after an interrupted
            // admission or missing Job directory. It cannot be treated as empty.
            for row in self.repository.rows(None).map_err(|_| refused())? {
                read_only_history(&row.record)?;
            }
        }
        let mut roots = BTreeSet::from([parent.join("Sessions")]);
        for root in session_roots {
            roots.insert(normalized(root)?);
        }
        for root in roots {
            check_sessions(&root)?;
        }
        self.root.validate_path(&self.path).map_err(|_| refused())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Fixture {
        base: PathBuf,
        root: PathBuf,
        jobs: JobStore,
    }
    impl Fixture {
        fn new() -> Self {
            let id = arkdeck_contract::sha256_hex(&arkdeck_platform::random_bytes::<16>().unwrap());
            let base = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("mutation-continuity-{id}"));
            let root = base.join("Runtime");
            std::fs::create_dir_all(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let jobs = JobStore::open_owner(&root).unwrap();
            Self { base, root, jobs }
        }
        fn check(&self) -> Result<(), WireError> {
            self.jobs.require_mutation_state(&self.root, &[])
        }
        fn file(&self, relative: &str, bytes: &[u8]) {
            let path = self.base.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bytes).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    #[test]
    fn override_and_retired_authority_are_refused_without_changing_source() {
        let fixture = Fixture::new();
        assert!(fixture.check().is_ok());
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.base.join("other"), &[])
                .is_err()
        );
        fixture.file("AuthorizationUsage/original", b"retained");
        assert!(fixture.check().is_err());
        assert_eq!(
            std::fs::read(fixture.base.join("AuthorizationUsage/original")).unwrap(),
            b"retained"
        );
    }

    #[test]
    fn missing_checkpoint_checks_job_directories_with_strict_json() {
        let fixture = Fixture::new();
        let relative = "Runtime/jobs/job-one/job-record.json";
        let parent = fixture.root.join("jobs");
        std::fs::create_dir_all(parent.join("job-one")).unwrap();
        for path in [&parent, &parent.join("job-one")] {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        fixture.file(relative, br#"{"request":{},"actualEffect":"readOnly"}"#);
        assert!(fixture.check().is_ok());
        for bytes in [
            br#"{"request":{},"actualEffect":"deviceMutation"}"#.as_slice(),
            br#"{"request":{"authorization":null},"actualEffect":"readOnly"}"#,
            br#"{"request":{},"actualEffect":"deviceMutation","actualEffect":"readOnly"}"#,
            br#"{"request":{}}"#,
        ] {
            fixture.file(relative, bytes);
            assert!(fixture.check().is_err());
            assert_eq!(std::fs::read(fixture.base.join(relative)).unwrap(), bytes);
        }
    }

    #[test]
    fn sqlite_only_mutation_history_cannot_reset_the_budget() {
        let fixture = Fixture::new();
        let bytes = br#"{"request":{},"actualEffect":"deviceMutation"}"#;
        fixture
            .jobs
            .repository
            .admit(
                "job-index-only",
                "intent-index-only",
                &"a".repeat(64),
                "preflight",
                "2026-09-19T00:00:00Z",
                bytes,
            )
            .unwrap();
        assert!(!fixture.root.join("jobs/job-index-only").exists());
        assert!(fixture.check().is_err());
        assert_eq!(fixture.jobs.repository.rows(None).unwrap()[0].record, bytes);
        assert!(
            !fixture
                .root
                .join("capabilities/runtime-capabilities.json")
                .exists()
        );
    }

    #[test]
    fn retained_session_mutation_and_torn_tail_block_even_with_checkpoint() {
        let fixture = Fixture::new();
        fixture.file("Runtime/capabilities/runtime-capabilities.json", b"{}");
        std::fs::set_permissions(
            fixture.root.join("capabilities"),
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let original = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-50242330d29da200cc17ae91a74808d1/journal.jsonl"
        );
        let prefix = |count| {
            original
                .split_inclusive(|byte| *byte == b'\n')
                .take(count)
                .flatten()
                .copied()
                .collect::<Vec<_>>()
        };
        // Actual Swift oracle prefix: an outstanding read-only probe is allowed.
        fixture.file("Sessions/one/journal.jsonl", &prefix(4));
        assert!(fixture.check().is_ok());
        // The next intent injects a pointer gesture and must never be hidden.
        let mutation = prefix(6);
        fixture.file("Sessions/one/journal.jsonl", &mutation);
        assert!(fixture.check().is_err());
        assert_eq!(
            std::fs::read(fixture.base.join("Sessions/one/journal.jsonl")).unwrap(),
            mutation
        );
        let unknown = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-dda3780682ad4198fc853da9011bc974/journal.jsonl"
        );
        fixture.file("Sessions/one/journal.jsonl", unknown);
        assert!(fixture.check().is_err());
        fixture.file("Sessions/one/journal.jsonl", b"{");
        assert!(fixture.check().is_err());
    }

    #[test]
    fn configured_session_roots_and_invalid_manifests_are_checked() {
        let fixture = Fixture::new();
        fixture.file("Archive/session/manifest.json", b"{}");
        assert!(fixture.check().is_ok());
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.root, &[fixture.base.join("Archive")])
                .is_err()
        );
        assert_eq!(
            std::fs::read(fixture.base.join("Archive/session/manifest.json")).unwrap(),
            b"{}"
        );
    }

    #[test]
    fn nested_production_sessions_and_case_aliases_cannot_hide_unknown_mutation() {
        let fixture = Fixture::new();
        let unknown = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-dda3780682ad4198fc853da9011bc974/journal.jsonl"
        );
        fixture.file("sessions/2026/09/session-unknown/journal.jsonl", unknown);
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.root, &[fixture.base.join("sessions")])
                .is_err()
        );
        if fixture.base.join("Sessions").exists() {
            // APFS case-insensitive spelling must inspect the same real root.
            assert!(fixture.check().is_err());
            std::fs::write(
                fixture
                    .base
                    .join("sessions/2026/09/session-unknown/journal.jsonl"),
                b"",
            )
            .unwrap();
            assert!(fixture.check().is_ok());
        }
    }

    #[test]
    fn symlinked_roots_and_retired_state_are_not_followed() {
        let fixture = Fixture::new();
        symlink(
            fixture.base.join("missing"),
            fixture.base.join("AuthorizationUsage"),
        )
        .unwrap();
        assert!(fixture.check().is_err());
        std::fs::remove_file(fixture.base.join("AuthorizationUsage")).unwrap();
        symlink(
            fixture.base.join("elsewhere"),
            fixture.base.join("Sessions"),
        )
        .unwrap();
        assert!(fixture.check().is_err());
        assert!(
            std::fs::symlink_metadata(fixture.base.join("Sessions"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}
