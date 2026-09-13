//! Disposable host fixtures test ownership, not parser or device acceptance.
use super::*;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
};

struct Fixture {
    root: PathBuf,
    cache: PathBuf,
    relative: String,
    lock_id: String,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/trace-maintenance-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        let cache = root.join("traces");
        for path in [
            cache.join(".staging/.owners"),
            cache.join(".locks"),
            cache.join(".leases"),
            root.join("staging/.owners"),
        ] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(path)
                .unwrap();
        }
        let trace = "a".repeat(64);
        let parser = "b".repeat(64);
        let relative = format!("{trace}/{parser}");
        let entry = cache.join(&relative);
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&entry)
            .unwrap();
        write(&entry.join("database.sqlite"), b"fixture database");
        write(&root.join("original.htrace"), b"original fixture Artifact");
        let metadata = json!({"formatVersion":1,
            "cacheKey":{"traceSHA256":trace,"parserBinarySHA256":parser,"upstreamRevision":"fixture","schemaAdapterVersion":"fixture","indexSchemaVersion":1,"parserKey":parser},
            "parser":{"name":"fixture","reportedVersion":"fixture","binarySHA256":parser,"upstreamRepository":"fixture","upstreamRevision":"fixture","architecture":"fixture","adapterVersion":"fixture","buildRecipeVersion":"fixture"},
            "traceSHA256":trace,"sourceSHA256":trace,"sourceByteCount":3,"schemaFingerprint":"fixture","schemaAdapterVersion":"fixture","indexSchemaVersion":1,
            "databasePreparation":{"schemaAdapterVersion":"fixture","schemaFingerprint":"fixture","indexVersion":1,"upstreamDatabaseSHA256":trace,"upstreamDatabaseByteCount":16},
            "databaseByteCount":16,"createdAt":"2026-09-11T00:00:00Z","lastAccessedAt":"2026-09-11T00:00:00Z"});
        write(
            &entry.join("metadata.json"),
            &serde_json::to_vec(&metadata).unwrap(),
        );
        let lock_id = arkdeck_contract::sha256_hex(format!("{trace}:{parser}").as_bytes());
        for (directory, suffix) in [(".locks", "lock"), (".leases", "lease")] {
            write(
                &cache.join(directory).join(format!("{lock_id}.{suffix}")),
                b"",
            );
        }
        let fixture = Self {
            root,
            cache,
            relative,
            lock_id,
        };
        fixture.owner("ready", &fixture.relative);
        fixture
    }
    fn entry(&self) -> PathBuf {
        self.cache.join(&self.relative)
    }
    fn owners(&self) -> PathBuf {
        self.cache.join(".staging/.owners")
    }
    fn owner(&self, state: &str, relative: &str) {
        let (device, inode) = HostDirectory::open(&self.entry())
            .unwrap()
            .directory_identity()
            .unwrap();
        write(&self.owners().join("entry-fixture.lock"), b"");
        write(
            &self.owners().join("entry-fixture.json"),
            &serde_json::to_vec(&json!({
            "formatVersion":1,"state":state,"device":device,"inode":inode,"relativePath":relative}))
            .unwrap(),
        );
    }
    fn hold(&self, directory: &str, suffix: &str) -> HostReadLock {
        HostDirectory::open_trace_inventory(&self.cache.join(directory))
            .unwrap()
            .try_trace_lock_existing(&format!("{}.{}", self.lock_id, suffix), None)
            .unwrap()
            .unwrap()
    }
    fn run(&self, retain: bool) -> Value {
        purge(&self.cache, retain, &|_| Ok(())).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn write(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn ready_purge_removes_only_owned_derived_entry_and_second_call_is_empty() {
    let fixture = Fixture::new();
    let result = fixture.run(false);
    assert_eq!(result["removedEntryCount"], 1);
    assert_eq!(result["after"]["entryCount"], 0);
    assert_eq!(result["originalTraceArtifactRemovalCount"], 0);
    assert!(!fixture.entry().exists());
    assert!(!fixture.owners().join("entry-fixture.json").exists());
    assert_eq!(
        fs::read(fixture.root.join("original.htrace")).unwrap(),
        b"original fixture Artifact"
    );
    assert_eq!(fixture.run(false)["removedEntryCount"], 0);
}

#[test]
fn retained_jobs_or_artifacts_prevent_all_recovery_and_deletion() {
    let fixture = Fixture::new();
    write(
        &fixture.root.join("staging/.owners/session-orphan.lock"),
        b"",
    );
    let before = fs::read(fixture.owners().join("entry-fixture.json")).unwrap();
    let result = fixture.run(true);
    assert_eq!(result["before"], result["after"]);
    for key in [
        "removedEntryCount",
        "recoveredPrivateDirectoryCount",
        "removedOrphanOwnerMarkerCount",
    ] {
        assert_eq!(result[key], 0);
    }
    assert_eq!(result["skippedActiveEntryCount"], 1);
    assert!(
        fixture
            .root
            .join("staging/.owners/session-orphan.lock")
            .exists()
    );
    assert_eq!(
        fs::read(fixture.owners().join("entry-fixture.json")).unwrap(),
        before
    );
}

#[test]
fn each_existing_ready_lock_and_promoted_building_lease_protects_the_entry() {
    for mode in ["key", "lease", "owner", "building"] {
        let fixture = Fixture::new();
        if mode == "building" {
            fixture.owner("building", ".staging/entry-original");
        }
        let held = match mode {
            "key" => fixture.hold(".locks", "lock"),
            "lease" | "building" => fixture.hold(".leases", "lease"),
            _ => HostDirectory::open_trace_inventory(&fixture.owners())
                .unwrap()
                .try_trace_lock_existing("entry-fixture.lock", Some(4096))
                .unwrap()
                .unwrap(),
        };
        let result = fixture.run(false);
        assert_eq!(result["removedEntryCount"], 0, "{mode}");
        assert_eq!(result["recoveredPrivateDirectoryCount"], 0, "{mode}");
        assert!(fixture.entry().exists());
        drop(held);
        assert_eq!(fixture.run(false)["removedEntryCount"], 1, "{mode}");
    }
}

#[test]
fn unbound_or_malformed_owner_evidence_never_authorizes_removal() {
    for mode in ["creating", "identity", "malformed", "absent"] {
        let fixture = Fixture::new();
        let path = fixture.owners().join("entry-fixture.json");
        match mode {
            "creating" => write(&path, br#"{"formatVersion":1,"state":"creating","relativePath":"entry-fixture"}"#),
            "identity" => write(&path, &serde_json::to_vec(&json!({"formatVersion":1,"state":"ready","relativePath":fixture.relative,"device":0,"inode":0})).unwrap()),
            "malformed" => write(&path, b"{}"),
            _ => fs::remove_file(path).unwrap(),
        }
        let result = purge(&fixture.cache, false, &|_| Ok(()));
        if mode == "malformed" {
            assert!(result.is_err());
        } else {
            assert_eq!(result.unwrap()["removedEntryCount"], 0, "{mode}");
        }
        assert!(fixture.entry().exists());
    }
}

#[test]
fn quarantine_publication_and_removal_faults_preserve_proof_and_never_delete_replacement() {
    for boundary in [
        "beforeQuarantine",
        "afterQuarantine",
        "afterOwnerPublication",
        "afterDirectoryRemoval",
    ] {
        let fixture = Fixture::new();
        let original = fs::read(fixture.owners().join("entry-fixture.json")).unwrap();
        assert!(
            purge(&fixture.cache, false, &|phase| {
                if phase == boundary {
                    Err(io::Error::other("injected maintenance boundary"))
                } else {
                    Ok(())
                }
            })
            .is_err()
        );
        assert!(fixture.owners().join("entry-fixture.json").exists());
        if boundary == "beforeQuarantine" {
            assert!(fixture.entry().exists());
            assert_eq!(
                fs::read(fixture.owners().join("entry-fixture.json")).unwrap(),
                original
            );
        } else {
            assert!(!fixture.entry().exists());
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(fixture.entry())
                .unwrap();
            write(&fixture.entry().join("replacement"), b"preserve");
            let result = fixture.run(false);
            assert_eq!(result["removedEntryCount"], 0);
            assert_eq!(
                fs::read(fixture.entry().join("replacement")).unwrap(),
                b"preserve"
            );
        }
        assert_eq!(
            fs::read(fixture.root.join("original.htrace")).unwrap(),
            b"original fixture Artifact"
        );
    }
}

#[test]
fn private_session_recovery_uses_existing_inode_proof_and_preserves_creating_records() {
    let fixture = Fixture::new();
    let private = fixture.root.join("staging/session-stale");
    fs::DirBuilder::new().mode(0o700).create(&private).unwrap();
    write(&private.join("private.sqlite"), b"private fixture");
    let (device, inode) = HostDirectory::open(&private)
        .unwrap()
        .directory_identity()
        .unwrap();
    let owners = fixture.root.join("staging/.owners");
    write(&owners.join("session-stale.lock"), b"");
    write(&owners.join("session-stale.json"), &serde_json::to_vec(&json!({"formatVersion":1,"state":"session","device":device,"inode":inode,"relativePath":"session-stale"})).unwrap());
    write(&owners.join("session-creating.lock"), b"");
    write(
        &owners.join("session-creating.json"),
        br#"{"formatVersion":1,"state":"creating","relativePath":"session-unbound"}"#,
    );
    write(&owners.join("session-orphan.lock"), b"");
    let result = fixture.run(false);
    assert_eq!(result["recoveredPrivateDirectoryCount"], 1);
    assert_eq!(result["removedOrphanOwnerMarkerCount"], 1);
    assert!(!private.exists());
    assert!(owners.join("session-creating.json").exists());
}
