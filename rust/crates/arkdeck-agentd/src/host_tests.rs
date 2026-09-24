//! `host`'s unit tests, declared by the binary's root rather than beside
//! `host`: `tests/spawning` compiles `host` from its source as well, and must
//! not also run these (see there).

#[cfg(test)]
mod tests {
    use crate::host::*;
    /// The development authority moves the root a device mutation proves its
    /// state continuity against, and changes nothing else about that proof.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_development_mutation_root_is_the_root_the_isolated_owner_proves() {
        use std::{fs, os::unix::fs::DirBuilderExt};
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("development-mutation-host-{}", fresh_id().unwrap()));
        let jobs = path.join("jobs-state");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&jobs)
            .unwrap();
        let store = arkdeck_hoststore::JobStore::open_owner(&jobs).unwrap();
        let host = Host::from_environment().with_capabilities(
            arkdeck_hoststore::CapabilityStore::open(&jobs.join("capabilities")).unwrap(),
        );
        // The installed Runtime's root, which an isolated owner is not: its
        // mutation state can never be proved continuous with it.
        let installed = host.authority().unwrap();
        assert_ne!(installed.default_root, jobs);
        assert_eq!(
            installed.require_state(&store).unwrap_err().code,
            "recordUnreadable"
        );
        // Taken, the proof is anchored at this owner's own Job state.
        let host = host.with_development_mutation_root(jobs.clone());
        assert_eq!(host.authority().unwrap().default_root, jobs);
        host.authority().unwrap().require_state(&store).unwrap();
        // Everything else the proof refuses, it still refuses there: recorded
        // authorization usage beside the root, and a Session root that is a
        // link out of it.
        fs::write(path.join("AuthorizationUsage"), b"").unwrap();
        assert_eq!(
            host.authority()
                .unwrap()
                .require_state(&store)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        fs::remove_file(path.join("AuthorizationUsage")).unwrap();
        std::os::unix::fs::symlink(&path, path.join("Sessions")).unwrap();
        assert_eq!(
            host.authority()
                .unwrap()
                .require_state(&store)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        fs::remove_file(path.join("Sessions")).unwrap();
        host.authority().unwrap().require_state(&store).unwrap();
        fs::remove_dir_all(&path).unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn candidate_name_owner_uses_only_runtime_snapshot_and_advances_cas() {
        use arkdeck_contract::DeviceObservationsResult;
        use arkdeck_control::HostServices;
        use serde_json::json;
        use std::{fs, os::unix::fs::DirBuilderExt};
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("candidate-host-{}", fresh_id().unwrap()));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        let mut host = Host::from_environment()
            .with_targets(arkdeck_hoststore::TargetStore::open(&path).unwrap());
        host.provider = None; // Explicitly simulated in-memory snapshot; no transport is reachable.
        let params = json!({"candidate":"fixture-serial","observationId":"obs-fixture","observationGeneration":"1","name":"Bench"});
        assert_eq!(
            host.candidate_display_name("device.display-name.set", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let snapshot:DeviceObservationsResult=serde_json::from_value(json!({"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-09-12T00:00:00Z","health":"current","observations":[{"candidateKey":"fixture-serial","authorizationState":"Connected","observationId":"obs-fixture","observationContinuity":"generationScoped","displayNameGeneration":"1","adoptedTargetId":null,"bindingRevision":null,"displayName":null,"deviceInformation":null,"observedFacts":null}]})).unwrap();
        *host.observations.lock().unwrap() = ObservationState {
            generation: 1,
            snapshot: Some(snapshot),
        };
        let reply = host
            .candidate_display_name("device.display-name.set", params.as_object().unwrap())
            .unwrap();
        assert_eq!(reply["generation"], "2");
        assert_eq!(
            host.observations
                .lock()
                .unwrap()
                .snapshot
                .as_ref()
                .unwrap()
                .observations[0]
                .display_name
                .as_deref(),
            Some("Bench")
        );
        assert_eq!(
            host.candidate_display_name("device.display-name.set", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let mut forged = params.clone();
        forged["observationGeneration"] = json!("2");
        forged["freshFacts"] = json!({"connected":true});
        assert_eq!(
            host.candidate_display_name("device.display-name.set", forged.as_object().unwrap())
                .unwrap_err()
                .code,
            "invalidParams"
        );
        let clear = json!({"candidate":"fixture-serial","observationId":"obs-fixture","observationGeneration":"2"});
        assert_eq!(
            host.candidate_display_name("device.display-name.clear", clear.as_object().unwrap())
                .unwrap()["generation"],
            "3"
        );
        drop(host);
        let restarted = Host::from_environment()
            .with_targets(arkdeck_hoststore::TargetStore::open(&path).unwrap());
        assert_eq!(
            restarted
                .candidate_display_name("device.display-name.clear", clear.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(restarted);
        fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn utc_spelling_and_leap_day() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(1_709_251_199), "2024-02-29T23:59:59Z");
        assert_eq!(timestamp(1_709_251_200), "2024-03-01T00:00:00Z");
    }
}

#[cfg(all(test, target_os = "macos"))]
mod session_activity_tests {
    use crate::host::*;
    use arkdeck_control::HostServices;
    use std::{fs, os::unix::fs::DirBuilderExt};
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("host-cleanup-{}", fresh_id().unwrap()));
            for name in ["state", "sessions", "artifacts", "jobs"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            Self(root)
        }
        fn host(&self) -> Host {
            Host::from_environment().with_storage(
                arkdeck_hoststore::SessionStore::open(
                    &self.0.join("state"),
                    &self.0.join("sessions"),
                )
                .unwrap(),
                arkdeck_hoststore::ArtifactUsage::open(&self.0.join("artifacts"), 1024).unwrap(),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn cleanup_requires_activity_owner_and_propagates_unreadable_job_inventory() {
        let fixture = Fixture::new();
        let params = serde_json::Map::new();
        assert_eq!(
            fixture
                .host()
                .session_resource("session.cleanup.preview", &params)
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert!(!fixture.0.join("state/session-cleanup-previews").exists());
        let unavailable = fixture
            .host()
            .with_jobs(arkdeck_hoststore::JobStore::open(&fixture.0.join("jobs")).unwrap());
        fs::rename(
            fixture.0.join("jobs/runtime-jobs.sqlite3"),
            fixture.0.join("jobs/replaced.sqlite3"),
        )
        .unwrap();
        assert_eq!(
            unavailable
                .session_resource("session.cleanup.preview", &params)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!fixture.0.join("state/session-cleanup-previews").exists());
    }
    #[test]
    fn preview_and_apply_use_the_actual_job_owner_and_refuse_when_it_is_missing() {
        let fixture = Fixture::new();
        let host = fixture
            .host()
            .with_jobs(arkdeck_hoststore::JobStore::open(&fixture.0.join("jobs")).unwrap());
        let preview = host
            .session_resource("session.cleanup.preview", &serde_json::Map::new())
            .unwrap();
        let params = serde_json::json!({"previewId":preview["previewId"], "previewDigest":preview["previewDigest"]});
        let result = host
            .session_resource("session.cleanup.apply", params.as_object().unwrap())
            .unwrap();
        assert_eq!(result["removedSessionIds"], serde_json::json!([]));
        let absent = fixture.host();
        assert_eq!(
            absent
                .session_resource("session.cleanup.apply", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
    }
}

#[cfg(all(test, target_os = "macos"))]
mod cancellation_tests {
    use crate::host::*;
    use arkdeck_control::HostServices;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use std::{fs, os::unix::fs::DirBuilderExt};

    /// A composition whose Job owner is empty, so every request that reaches
    /// the owner answers for an absent Job.
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("host-cancel-{}", fresh_id().unwrap()));
            for name in ["jobs", "artifacts"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            Self(root)
        }
        fn host(&self) -> Host {
            Host::from_environment()
                .with_jobs(arkdeck_hoststore::JobStore::open_owner(&self.0.join("jobs")).unwrap())
                .with_artifacts(
                    arkdeck_hoststore::ArtifactReadStore::open(&self.0.join("artifacts")).unwrap(),
                )
                .with_planning(&self.0, None)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn job(id: &str) -> serde_json::Map<String, serde_json::Value> {
        serde_json::Map::from_iter([("jobId".into(), serde_json::json!(id))])
    }

    /// Holds `id` as a run or a cancellation of this owner would.
    fn hold(host: &Host, id: &str, cancelling: bool) -> Arc<RunSlot> {
        let slot = Arc::new(RunSlot {
            cancelling,
            ..RunSlot::default()
        });
        host.running
            .lock()
            .unwrap()
            .insert(id.to_owned(), slot.clone());
        slot
    }

    #[test]
    fn a_request_waits_in_the_run_and_falls_back_to_the_record_when_it_ends() {
        let fixture = Fixture::new();
        let host = fixture.host();
        let slot = hold(&host, "job-a", false);
        std::thread::scope(|scope| {
            let cancel = scope.spawn(|| host.job_cancel(&job("job-a")));
            // The run alone writes the Job's Journal, so the request waits in
            // it rather than in this owner.
            let deadline = Instant::now() + Duration::from_secs(30);
            while !slot.cancellation.pending() {
                assert!(
                    Instant::now() < deadline,
                    "the request never reached the run"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(!cancel.is_finished());
            // The run returns without acting on it, as job_run lets a run go.
            slot.cancellation.end();
            slot.finish(&Ok(serde_json::json!({})));
            host.running.lock().unwrap().remove("job-a");
            // The Job's record then decides; this owner holds no such Job.
            let absent = cancel.join().unwrap().unwrap_err();
            assert_eq!(
                (
                    absent.code.as_str(),
                    absent.message.as_str(),
                    &absent.details
                ),
                ("notFound", "unknown job job-a", &None)
            );
        });
        assert!(host.running.lock().unwrap().is_empty());
    }

    #[test]
    fn a_cancellation_is_joined_and_a_run_waits_it_out() {
        let fixture = Fixture::new();
        let host = fixture.host();
        let slot = hold(&host, "job-b", true);
        std::thread::scope(|scope| {
            let cancel = scope.spawn(|| host.job_cancel(&job("job-b")));
            let run = scope.spawn(|| host.job_run(&job("job-b")));
            // Both callers hold the slot: the map, this test and the two.
            let deadline = Instant::now() + Duration::from_secs(30);
            while Arc::strong_count(&slot) < 4 {
                assert!(Instant::now() < deadline, "the callers never met the slot");
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(!cancel.is_finished() && !run.is_finished());
            host.running.lock().unwrap().remove("job-b");
            slot.finish(&Ok(serde_json::json!({"cancelRequested": true})));
            // The concurrent cancellation answers what the first one did; the
            // run starts its own and meets the Job as the cancellation left it.
            assert_eq!(
                cancel.join().unwrap().unwrap(),
                serde_json::json!({"cancelRequested": true})
            );
            assert_eq!(run.join().unwrap().unwrap_err().code, "resourceNotFound");
        });
        assert!(host.running.lock().unwrap().is_empty());
    }

    /// A run resumes Jobs a reconcile concludes, so it never drives a Job
    /// beside a reconcile of it: a run of a Job a reconcile holds waits the
    /// reconcile out without taking the Job, then starts its own and meets
    /// the Job as the reconcile left it; a run of a Job another run holds
    /// joins that one.
    #[test]
    fn a_run_waits_out_a_reconcile_of_its_job_under_way() {
        let fixture = Fixture::new();
        let host = fixture.host();
        let reconcile = Arc::new(RunSlot::default());
        host.reconciling
            .lock()
            .unwrap()
            .insert("job-c".into(), reconcile.clone());
        std::thread::scope(|scope| {
            let run = scope.spawn(|| host.job_run(&job("job-c")));
            // The run holds the reconcile's slot: the map, this test and it.
            let deadline = Instant::now() + Duration::from_secs(30);
            while Arc::strong_count(&reconcile) < 3 {
                assert!(Instant::now() < deadline, "the run never met the reconcile");
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(!run.is_finished());
            assert!(!host.running.lock().unwrap().contains_key("job-c"));
            // Released before its waiters wake, as job_reconcile lets go.
            host.reconciling.lock().unwrap().remove("job-c");
            reconcile.finish(&Ok(serde_json::json!({})));
            assert_eq!(run.join().unwrap().unwrap_err().code, "resourceNotFound");
        });
        assert!(host.running.lock().unwrap().is_empty());
        let slot = hold(&host, "job-d", false);
        assert!(matches!(
            host.claim_run("job-d"),
            Some(RunClaim::Held(held)) if Arc::ptr_eq(&held, &slot)
        ));
    }
}
