//! Swift `RuntimeArtifactStore.collectGarbage(activeJobIDs:nowUTC:)`, which the
//! Swift daemon runs once at startup, after its Job recovery and before it
//! serves. In every Job directory of the Artifact root outside the Jobs it
//! keeps, the index rows whose retention deadline has passed (parsed as Swift
//! parses it, `deadline <= now`) and that are not pinned are reclaimed: the
//! index is rewritten without them first, then each reclaimed published
//! payload is unlinked, so a failure after the index leaves an unreferenced
//! file, never an index naming missing evidence. A row without a deadline never
//! expires; a missing product's row goes with its deadline too. The Job
//! directory and its index, possibly empty, stay.
//!
//! The root is classified before any Job is read, as Swift's
//! `jobDirectories()` classifies it: the Import owner's directory and a regular
//! cleanup ledger are skipped, any other directory is a Job, and anything else
//! refuses the sweep before it reclaims anything. Each index is read as
//! publication reads it, every published payload checked, and every deadline
//! parsed, pinned or not; a Job that does not verify stops the sweep there,
//! with the Jobs before it already swept, as Swift's does.
//!
//! What the sweep keeps ([`RetentionKeep`]) is never less than Swift keeps.
//! Swift keeps the directories of the Jobs its recovery found non-terminal and
//! of the records it quarantined. Here the Job owner's census also keeps every
//! Job it cannot prove settled, the cleanup ledger keeps every Job still owing
//! a cleanup, and each exact Artifact an active Job names as an input lease is
//! kept wherever it lives: ADR-0007 decision 5's "not referenced by an active
//! Job". The sweep holds the Artifact retention guard's lock, which every
//! publication and Trace maintenance take, and not the Trace census, which
//! only Trace maintenance reads.
//!
//! Swift's per-Job payload-verification cache is not written here, so nothing
//! of it is forgotten either.
use super::*;
use std::collections::BTreeSet;

/// What the sweep may not reclaim: the Artifact directories of the Jobs it
/// keeps, and the exact `(owner, Artifact)` pairs an active Job leases.
#[derive(Debug, Default)]
pub(crate) struct RetentionKeep {
    pub(crate) jobs: BTreeSet<String>,
    pub(crate) leases: BTreeSet<(String, String)>,
}

impl RetentionKeep {
    /// Keeps every `lease-v1:<owner>:<Artifact>` string anywhere in `value`,
    /// a Job's typed inputs, whatever slot or Catalog names it.
    pub(crate) fn lease_all(&mut self, value: &Value) {
        match value {
            Value::String(text) => {
                let parts: Vec<&str> = text.split(':').collect();
                if parts.len() == 3
                    && parts[0] == "lease-v1"
                    && !parts[1].is_empty()
                    && parts[2].starts_with("ART-")
                {
                    self.leases
                        .insert((parts[1].to_owned(), parts[2].to_owned()));
                }
            }
            Value::Array(items) => items.iter().for_each(|item| self.lease_all(item)),
            Value::Object(fields) => fields.values().for_each(|item| self.lease_all(item)),
            _ => {}
        }
    }
}

/// The isolated owner's startup sweep: the Artifacts of `artifacts` whose
/// retention has lapsed at `now`, reclaimed outside what the Job owner's
/// census and the cleanup ledger keep, as Swift's daemon reclaims them before
/// it serves. The census holds the Job activity guard through the sweep, so no
/// Job changes state beside it. Answers the reclaimed Artifact identities, or
/// why nothing more was reclaimed.
pub fn collect_expired_artifacts(
    jobs: &crate::JobStore,
    artifacts: &ArtifactReadStore,
    now: &str,
) -> Result<Vec<String>, String> {
    jobs.with_retention_keep(|mut keep| {
        keep.jobs
            .extend(crate::cleanup_debt::outstanding_jobs(artifacts)?);
        ArtifactPublisher {
            store: artifacts,
            quota: u64::MAX,
            home: "",
            now: || None,
        }
        .collect_garbage(&keep, now)
    })
    .map_err(|error| format!("the Job activity census is unreadable: {}", error.message))?
}

fn invalid_timestamp() -> String {
    corrupted("artifact retention contains an invalid UTC timestamp")
}

fn unexpected(name: &str) -> String {
    corrupted(&format!(
        "artifact root contains an unexpected or linked entry {name}"
    ))
}

/// Swift `isExpired(deadlineUTC:currentUTC:)`: no deadline never expires.
fn expired(row: &Value, now: f64) -> Result<bool, String> {
    match row["retention"].get("deadlineUTC") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::String(deadline)) => Ok(crate::format_time::format_timestamp_seconds(deadline)
            .ok_or_else(invalid_timestamp)?
            <= now),
        Some(_) => Err(invalid_timestamp()),
    }
}

impl ArtifactPublisher<'_> {
    /// Swift `collectGarbage`: the reclaimed Artifact identities, Job by Job
    /// in name order and each Job's in index order.
    pub(crate) fn collect_garbage(
        &self,
        keep: &RetentionKeep,
        now: &str,
    ) -> Result<Vec<String>, String> {
        self.store
            .with_retention_lock(|| self.collect_guarded(keep, now))
            .map_err(|error| io_failure(&format!("cannot inspect artifact retention: {error}")))?
    }

    fn collect_guarded(&self, keep: &RetentionKeep, now: &str) -> Result<Vec<String>, String> {
        let now =
            crate::format_time::format_timestamp_seconds(now).ok_or_else(invalid_timestamp)?;
        let root = self.store.root();
        let mut jobs = Vec::new();
        for name in root
            .names(100_000)
            .map_err(|_| corrupted("artifact root cannot be listed"))?
        {
            match root
                .owned_kind_and_size(&name)
                .map_err(|_| unexpected(&name))?
                .0
            {
                HostEntryKind::Directory if name == IMPORT_NAMESPACE => {}
                HostEntryKind::Directory => jobs.push(name),
                HostEntryKind::Regular if name == CLEANUP_DEBT => {}
                _ => return Err(unexpected(&name)),
            }
        }
        jobs.sort();
        let mut reclaimed = Vec::new();
        for job_id in jobs {
            if keep.jobs.contains(&job_id) {
                continue;
            }
            let job = self.job_directory(&job_id)?;
            let mut kept = Vec::new();
            let mut lapsed = Vec::new();
            for row in self.load_index(&job, &job_id)? {
                let artifact = row["artifactID"].as_str().unwrap_or_default().to_owned();
                if expired(&row, now)?
                    && row["retention"]["pinned"] != true
                    && !keep.leases.contains(&(job_id.clone(), artifact))
                {
                    lapsed.push(row);
                } else {
                    kept.push(row);
                }
            }
            if lapsed.is_empty() {
                continue;
            }
            // The index stops naming the rows before any byte goes.
            Self::persist_index(&job, kept)?;
            for row in lapsed {
                let artifact = row["artifactID"].as_str().unwrap_or_default();
                if published(&row) {
                    let failed = |error: io::Error| {
                        io_failure(&format!("cannot collect {artifact}: {error}"))
                    };
                    let metadata = job.document_metadata(artifact).map_err(failed)?;
                    job.remove_document(artifact, &metadata).map_err(failed)?;
                }
                reclaimed.push(artifact.to_owned());
            }
        }
        Ok(reclaimed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::path::{Path, PathBuf};

    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn root() -> Root {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "artifact-retention-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Root(path)
    }

    fn created() -> Option<String> {
        Some("2026-09-14T00:00:00Z".into())
    }

    fn publisher(store: &ArtifactReadStore) -> ArtifactPublisher<'_> {
        ArtifactPublisher {
            store,
            quota: u64::MAX,
            home: "/Users/nobody",
            now: created,
        }
    }

    fn product<'a>(job: &'a str, name: &'a str, retention: &'a str) -> Product<'a> {
        Product {
            job_id: job,
            session_id: "session-fixture",
            step_id: "step",
            name,
            media_type: "application/octet-stream",
            privacy: "standard",
            retention_class: retention,
            source_operation: "observe.device@1",
            provider_id: "hdc",
            binding: json!({"targetID": "TGT-fixture", "bindingRevision": 1}),
            observation_window: None,
        }
    }

    fn index(root: &Path, job: &str) -> Vec<Value> {
        let bytes = fs::read(root.join(job).join("index.json")).unwrap();
        serde_json::from_slice::<Value>(&bytes).unwrap()["artifacts"]
            .as_array()
            .unwrap()
            .clone()
    }

    fn names(root: &Path, job: &str) -> Vec<String> {
        index(root, job)
            .iter()
            .map(|row| row["name"].as_str().unwrap().to_owned())
            .collect()
    }

    /// Two Jobs: a week-long, a day-long, a pinned and a missing product
    /// each, created at 2026-09-14T00:00:00Z.
    fn sample(root: &Path) -> (ArtifactReadStore, Vec<Value>) {
        let store = ArtifactReadStore::open(root).unwrap();
        let mut rows = Vec::new();
        for job in ["job-a", "job-b"] {
            let publisher = publisher(&store);
            for (name, class) in [
                ("week.bin", "default"),
                ("day.bin", "shortLived"),
                ("pinned.bin", "pinnedUntilVerified"),
            ] {
                rows.push(
                    publisher
                        .publish(
                            &product(job, name, class),
                            format!("{job} {name}").as_bytes(),
                        )
                        .unwrap(),
                );
            }
            rows.push(
                publisher
                    .record_missing(&product(job, "missing.bin", "default"), "not produced")
                    .unwrap(),
            );
        }
        (store, rows)
    }

    #[test]
    fn only_lapsed_unpinned_rows_go_index_first_and_the_directory_stays() {
        let root = root();
        let (store, rows) = sample(&root.0);
        let publisher = publisher(&store);
        let keep = RetentionKeep::default();
        // Before any deadline: nothing lapses.
        assert!(
            publisher
                .collect_garbage(&keep, "2026-09-14T23:59:59Z")
                .unwrap()
                .is_empty()
        );
        // The day-long products lapse at their deadline exactly.
        let reclaimed = publisher
            .collect_garbage(&keep, "2026-09-15T00:00:00Z")
            .unwrap();
        let day: Vec<_> = rows
            .iter()
            .filter(|row| row["name"] == "day.bin")
            .map(|row| row["artifactID"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(reclaimed, day);
        for job in ["job-a", "job-b"] {
            assert_eq!(
                names(&root.0, job),
                ["week.bin", "pinned.bin", "missing.bin"]
            );
        }
        // A fractional or offset spelling parses as Swift's does.
        assert!(
            publisher
                .collect_garbage(&keep, "2026-09-21T07:59:59.999+08:00")
                .unwrap()
                .is_empty()
        );
        // A week later the default and missing rows go too; the pin stays.
        let reclaimed = publisher
            .collect_garbage(&keep, "2026-09-21T00:00:00Z")
            .unwrap();
        assert_eq!(reclaimed.len(), 4);
        for job in ["job-a", "job-b"] {
            assert_eq!(names(&root.0, job), ["pinned.bin"]);
            let files: BTreeSet<_> = fs::read_dir(root.0.join(job))
                .unwrap()
                .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                .collect();
            let pinned = index(&root.0, job)[0]["artifactID"]
                .as_str()
                .unwrap()
                .to_owned();
            assert_eq!(files, BTreeSet::from(["index.json".to_owned(), pinned]));
        }
        // The kept rows are the published metadata, unchanged.
        for row in rows.iter().filter(|row| row["name"] == "pinned.bin") {
            let job = row["jobID"].as_str().unwrap();
            assert_eq!(index(&root.0, job), std::slice::from_ref(row));
        }
        // Nothing is left to reclaim; a later sweep changes nothing.
        assert!(
            publisher
                .collect_garbage(&keep, "2030-01-01T00:00:00Z")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn kept_jobs_and_leased_artifacts_are_never_reclaimed() {
        let root = root();
        let (store, rows) = sample(&root.0);
        let publisher = publisher(&store);
        let week_b = rows
            .iter()
            .find(|row| row["jobID"] == "job-b" && row["name"] == "week.bin")
            .unwrap()["artifactID"]
            .as_str()
            .unwrap()
            .to_owned();
        let mut keep = RetentionKeep::default();
        keep.jobs.insert("job-a".into());
        keep.lease_all(&json!({"sources": [format!("lease-v1:job-b:{week_b}")],
            "other": "lease-v1:job-b", "text": "not a lease"}));
        assert_eq!(
            keep.leases,
            BTreeSet::from([("job-b".to_owned(), week_b.clone())])
        );
        publisher
            .collect_garbage(&keep, "2026-09-21T00:00:00Z")
            .unwrap();
        assert_eq!(
            names(&root.0, "job-a"),
            ["week.bin", "day.bin", "pinned.bin", "missing.bin"]
        );
        assert_eq!(names(&root.0, "job-b"), ["week.bin", "pinned.bin"]);
        assert!(root.0.join("job-b").join(&week_b).exists());
    }

    #[test]
    fn an_unexpected_entry_or_timestamp_refuses_before_anything_is_reclaimed() {
        let root = root();
        let (store, _) = sample(&root.0);
        let publisher = publisher(&store);
        let keep = RetentionKeep::default();
        let before = |job: &str| names(&root.0, job);
        let (a, b) = (before("job-a"), before("job-b"));
        // A stray file in the root: Swift classifies the root first.
        fs::write(root.0.join("stray"), b"x").unwrap();
        fs::set_permissions(root.0.join("stray"), fs::Permissions::from_mode(0o600)).unwrap();
        let refused = publisher
            .collect_garbage(&keep, "2026-09-21T00:00:00Z")
            .unwrap_err();
        assert!(
            refused.contains("unexpected or linked entry stray"),
            "{refused}"
        );
        fs::remove_file(root.0.join("stray")).unwrap();
        assert_eq!((before("job-a"), before("job-b")), (a.clone(), b.clone()));
        // An invalid clock refuses too.
        let refused = publisher.collect_garbage(&keep, "not a time").unwrap_err();
        assert!(refused.contains("invalid UTC timestamp"), "{refused}");
        assert_eq!((before("job-a"), before("job-b")), (a, b));
    }

    /// Every entry under `path`, counted as the Trace census once counted
    /// them against its bound of 4096.
    fn entries(path: &Path) -> usize {
        fs::read_dir(path)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                1 + if entry.file_type().unwrap().is_dir() {
                    entries(&entry.path())
                } else {
                    0
                }
            })
            .sum()
    }

    #[test]
    fn a_store_past_4096_entries_still_publishes_sweeps_and_takes_the_trace_census() {
        let root = root();
        let (store, _) = sample(&root.0);
        // Jobs the sweep emptied keep their directory and an empty index, as
        // Swift's do: a week of captures leaves this many and more.
        for n in 0..2048 {
            let job = root.0.join(format!("job-empty-{n:04}"));
            fs::DirBuilder::new().mode(0o700).create(&job).unwrap();
            let index = job.join("index.json");
            fs::write(&index, br#"{"schemaVersion": "1.0.0", "artifacts": []}"#).unwrap();
            fs::set_permissions(&index, fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert!(entries(&root.0) > 4096);
        // Publication takes only the guard's lock: a new Job's product and a
        // missing one go in as they would in an empty store.
        let publisher = publisher(&store);
        publisher
            .publish(&product("job-c", "week.bin", "default"), b"job-c week.bin")
            .unwrap();
        publisher
            .record_missing(&product("job-c", "missing.bin", "default"), "not produced")
            .unwrap();
        // The Trace census reads the whole store, and any Job retains every
        // Trace entry.
        assert!(store.with_trace_retention(|retain| retain).unwrap());
        // Nor does publication read what only the census reads: a link inside
        // another Job's directory refuses the census, not a publication, and
        // Swift's publication never looks there either.
        let link = root.0.join("job-empty-2047").join("link");
        std::os::unix::fs::symlink(root.0.join("job-a").join("index.json"), &link).unwrap();
        assert!(store.with_trace_retention(|_| ()).is_err());
        publisher
            .publish(&product("job-c", "day.bin", "shortLived"), b"job-c day.bin")
            .unwrap();
        fs::remove_file(&link).unwrap();
        assert_eq!(
            names(&root.0, "job-c"),
            ["week.bin", "missing.bin", "day.bin"]
        );
        let reclaimed = publisher
            .collect_garbage(&RetentionKeep::default(), "2026-09-21T00:00:00Z")
            .unwrap();
        assert_eq!(reclaimed.len(), 9);
        for job in ["job-a", "job-b"] {
            assert_eq!(names(&root.0, job), ["pinned.bin"]);
        }
        assert!(names(&root.0, "job-c").is_empty());
    }

    #[test]
    fn a_job_that_does_not_verify_stops_the_sweep_there() {
        let root = root();
        let (store, rows) = sample(&root.0);
        let publisher = publisher(&store);
        // job-b's week-long payload is rewritten at its length: its digest no
        // longer verifies. job-a is swept first, as Swift sweeps in order.
        let week_b = rows
            .iter()
            .find(|row| row["jobID"] == "job-b" && row["name"] == "week.bin")
            .unwrap()["artifactID"]
            .as_str()
            .unwrap()
            .to_owned();
        let payload = root.0.join("job-b").join(&week_b);
        let length = fs::metadata(&payload).unwrap().len() as usize;
        fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&payload, vec![b'x'; length]).unwrap();
        fs::set_permissions(&payload, fs::Permissions::from_mode(0o400)).unwrap();
        let refused = publisher
            .collect_garbage(&RetentionKeep::default(), "2026-09-21T00:00:00Z")
            .unwrap_err();
        assert!(refused.contains("digest or identity drifted"), "{refused}");
        assert_eq!(names(&root.0, "job-a"), ["pinned.bin"]);
        assert_eq!(
            names(&root.0, "job-b"),
            ["week.bin", "day.bin", "pinned.bin", "missing.bin"]
        );
        // A deadline that does not parse refuses its Job, pinned or not.
        let mut rows = index(&root.0, "job-a");
        rows[0]["retention"] = json!({"retentionClass": "pinnedUntilVerified",
            "pinned": true, "deadlineUTC": "someday"});
        let directory = store.root().child("job-a").unwrap();
        ArtifactPublisher::persist_index(&directory, rows).unwrap();
        let refused = publisher
            .collect_garbage(
                &RetentionKeep {
                    jobs: BTreeSet::from(["job-b".to_owned()]),
                    leases: BTreeSet::new(),
                },
                "2026-09-21T00:00:00Z",
            )
            .unwrap_err();
        assert!(refused.contains("invalid UTC timestamp"), "{refused}");
    }
}
