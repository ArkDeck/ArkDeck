//! `arkdeck job wait` against a fake Runtime, over the Job statuses and event
//! rows Swift's daemon recorded (`Fixtures/ControlFrames/job.status.jsonl`
//! and `job.events.jsonl`). The wait reads until the Job settles and never
//! cancels it. A settled Job is a successful read that exits by its outcome.
//! A Job waiting on a person, an outcome that needs reconciliation and the
//! caller's deadline each end the wait with Swift's refusal. The polling and
//! the stream paths are the ones Swift's handler takes for the same options.
// The fake Runtime this leaf is driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use serde_json::{Value, json};

    const JOB: &str = "job-2b395b58efa418650be51432f3a2c9b0";

    fn frames(method: &str) -> Vec<Value> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
        ));
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    /// The status Swift recorded for `operation` in `state`, as this test's
    /// Job's.
    fn status(state: &str, operation: &str) -> Value {
        let mut status = frames("job.status")
            .into_iter()
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]["state"] == state
                    && frame["result"]["operation"] == operation
            })
            .unwrap_or_else(|| panic!("Swift recorded a {state} {operation} status"))["result"]
            .clone();
        status["jobId"] = json!(JOB);
        status["nextAction"]["owner"]["id"] = json!(JOB);
        status["nextAction"]["resource"]["id"] = json!(JOB);
        status
    }

    fn running() -> Value {
        status("running", "observe.device@1")
    }

    fn read(answer: &Value) -> (String, Value, Value) {
        (
            "job.status".to_owned(),
            json!({"jobId": JOB}),
            json!({"ok": true, "result": answer}),
        )
    }

    /// One recorded event row, re-positioned at `revision`'s snapshot.
    fn row(position: i64, revision: i64, id: &str) -> Value {
        let mut row = frames("job.events")
            .into_iter()
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]["items"]
                        .as_array()
                        .is_some_and(|items| !items.is_empty())
            })
            .expect("a recorded event page")["result"]["items"][0]
            .clone();
        row["eventId"] = json!(id);
        row["streamPosition"] = json!(position.to_string());
        row["runtimeRevision"] = json!(revision.to_string());
        row["cursor"] = json!(format!("cursor-{id}"));
        row
    }

    /// A complete page of the stream at `revision`, and the read that asks for
    /// it.
    fn events(rows: Vec<Value>, revision: i64, after: Option<&str>) -> (String, Value, Value) {
        let mut params = json!({"jobId": JOB, "pageSize": 100});
        if let Some(after) = after {
            params["afterCursor"] = json!(after);
        }
        (
            "job.events".to_owned(),
            params,
            json!({"ok": true, "result": {"schemaVersion": "arkdeck.cli.page/1",
                "pageKind": "eventStream", "order": "streamPositionAsc", "items": rows,
                "snapshotRevision": revision.to_string(), "hasMore": false,
                "nextCursor": "cursor-page"}}),
        )
    }

    fn lines(output: &[u8]) -> Vec<Value> {
        String::from_utf8_lossy(output)
            .lines()
            .map(|line| serde_json::from_str(line).expect("one document per line"))
            .collect()
    }

    #[test]
    fn polling_reads_the_status_until_it_settles_and_exits_by_its_outcome() {
        let unknown = {
            let mut status = running();
            status["outcomeUnknown"] = json!(true);
            status["outcome"] = json!("outcomeUnknown");
            status
        };
        for (settled, exit) in [
            (status("succeeded", "observe.device@1"), 0),
            (status("failed", "observe.device@1"), 1),
            (status("cancelled", "observe.device@1"), 1),
            // An unknown outcome is settled for the wait: it needs
            // reconciliation, never a replay, and says so in its status.
            (unknown, 75),
        ] {
            let (output, envelope) = support::run(
                &["job", "wait", "--job", JOB],
                vec![read(&running()), read(&settled)],
            );
            assert_eq!(output.status.code(), Some(exit), "{envelope}");
            assert_eq!(envelope["ok"], true);
            assert_eq!(envelope["command"], "job.wait");
            assert_eq!(envelope["result"], settled);
        }
    }

    #[test]
    fn polling_answers_a_person_and_a_pending_finalization_at_once() {
        let mut waiting = running();
        waiting["waitingForHuman"] = json!(true);
        let (output, envelope) = support::run(&["job", "wait", "--job", JOB], vec![read(&waiting)]);
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "humanActionRequired");
        assert_eq!(
            envelope["error"]["message"],
            format!("job {JOB} is waiting for a human action and will not settle on its own")
        );
        assert_eq!(
            envelope["error"]["details"],
            json!({"jobId": JOB, "state": "running"})
        );

        let finalizing = status("finalizing", "debug.hap@1");
        let (output, envelope) =
            support::run(&["job", "wait", "--job", JOB], vec![read(&finalizing)]);
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "resultNotReady");
        assert_eq!(
            envelope["error"]["message"],
            format!(
                "Job failure finalization requires reconciliation. Run: arkdeck job reconcile --job {JOB}"
            )
        );
        assert_eq!(
            envelope["error"]["details"]["nextAction"],
            finalizing["nextAction"]
        );
    }

    #[test]
    fn the_callers_deadline_ends_the_wait_and_says_the_job_still_runs() {
        // However many reads fit in the deadline, the last one is still
        // judged, and only then does the deadline end the wait.
        let (output, envelope) = support::run_partial(
            &["job", "wait", "--job", JOB, "--timeout", "300ms"],
            (0..12).map(|_| read(&running())).collect(),
        );
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "clientTimeout");
        assert_eq!(
            envelope["error"]["message"],
            format!("stopped waiting for job {JOB}; it is running and still running")
        );
        assert_eq!(
            envelope["error"]["details"],
            json!({"jobId": JOB, "state": "running"})
        );
    }

    #[test]
    fn the_stream_follows_the_events_and_ends_with_the_settled_status() {
        for (settled, exit) in [
            (status("succeeded", "observe.device@1"), 0),
            (status("failed", "observe.device@1"), 1),
        ] {
            let (output, _) = support::run(
                &["job", "wait", "--job", JOB, "--output", "jsonl"],
                vec![
                    events(vec![row(1, 2, "e1"), row(2, 2, "e2")], 2, None),
                    read(&running()),
                    events(vec![], 2, Some("cursor-page")),
                    read(&settled),
                    // Drained once more after the terminal status.
                    events(vec![], 2, Some("cursor-page")),
                ],
            );
            assert_eq!(output.status.code(), Some(exit));
            let lines = lines(&output.stdout);
            assert_eq!(lines.len(), 3, "{lines:?}");
            assert_eq!(
                [&lines[0]["eventId"], &lines[1]["eventId"]],
                [&json!("e1"), &json!("e2")]
            );
            let terminal = &lines[2];
            assert_eq!(terminal["type"], "terminal");
            assert_eq!(terminal["command"], "job.wait");
            assert_eq!(terminal["sequence"], 3);
            assert_eq!(terminal["ok"], true);
            assert_eq!(terminal["exitCode"], exit);
            assert_eq!(terminal["lastCursor"], "cursor-e2");
            assert_eq!(terminal["result"], settled);
        }
    }

    #[test]
    fn the_stream_refuses_an_outcome_it_cannot_know() {
        let mut unknown = running();
        unknown["outcomeUnknown"] = json!(true);
        unknown["outcome"] = json!("outcomeUnknown");
        unknown["nextAction"] = json!({"kind": "reconcile",
            "owner": {"kind": "job", "id": JOB}, "resource": {"kind": "job", "id": JOB},
            "reasonCode": "recovery.outcomeUnknown"});
        let (output, _) = support::run(
            &["job", "wait", "--job", JOB, "--output", "jsonl"],
            vec![events(vec![row(1, 1, "e1")], 1, None), read(&unknown)],
        );
        assert_eq!(output.status.code(), Some(75));
        let written = lines(&output.stdout);
        let terminal = written.last().unwrap();
        assert_eq!(terminal["ok"], false);
        assert_eq!(terminal["error"]["code"], "outcomeUnknown");
        assert_eq!(
            terminal["error"]["message"],
            "the Job requires reconciliation; observation never replays an effect"
        );
        assert_eq!(
            terminal["error"]["details"],
            json!({"nextAction": unknown["nextAction"], "jobId": JOB,
                "afterCursor": "cursor-page"})
        );
        // A person the published status cannot name is a status this build
        // cannot read, not a wait.
        let mut waiting = running();
        waiting["waitingForHuman"] = json!(true);
        let (output, _) = support::run(
            &["job", "wait", "--job", JOB, "--output", "jsonl"],
            vec![events(vec![], 0, None), read(&waiting)],
        );
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(
            lines(&output.stdout).last().unwrap()["error"]["code"],
            "recordUnreadable"
        );
    }

    #[test]
    fn a_page_size_takes_the_stream_path_without_printing_its_rows_as_json() {
        let settled = status("succeeded", "observe.device@1");
        let (output, envelope) = support::run(
            &["job", "wait", "--job", JOB, "--page-size", "5"],
            vec![
                (
                    "job.events".to_owned(),
                    json!({"jobId": JOB, "pageSize": 5}),
                    events(vec![row(1, 1, "e1")], 1, None).2,
                ),
                read(&settled),
                (
                    "job.events".to_owned(),
                    json!({"jobId": JOB, "pageSize": 5, "afterCursor": "cursor-page"}),
                    events(vec![], 1, None).2,
                ),
            ],
        );
        // One document on stdout: the envelope of the settled status.
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(lines(&output.stdout).len(), 1);
        assert_eq!(envelope["result"], settled);
    }

    #[test]
    fn the_legacy_json_stream_prints_only_the_settled_status_document() {
        // Swift prints the rows in the human rendering only; the legacy `--json`
        // rendering is the settled status's one document.
        let settled = status("succeeded", "observe.device@1");
        let (output, _) = support::run(
            &["job", "wait", "--job", JOB, "--page-size", "5", "--json"],
            vec![
                (
                    "job.events".to_owned(),
                    json!({"jobId": JOB, "pageSize": 5}),
                    events(vec![row(1, 1, "e1")], 1, None).2,
                ),
                read(&settled),
                (
                    "job.events".to_owned(),
                    json!({"jobId": JOB, "pageSize": 5, "afterCursor": "cursor-page"}),
                    events(vec![], 1, None).2,
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&arkdeck_cli::legacy_document(&settled))
        );
        assert!(output.stderr.is_empty());
    }

    fn refused(argv: &[&str]) -> (Option<i32>, Value) {
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(argv)
            .args(["--socket", "/nonexistent/arkdeck-job-wait.sock"])
            .args(if argv.contains(&"--output") {
                &[][..]
            } else {
                &["--output", "json"][..]
            })
            .output()
            .unwrap();
        (
            output.status.code(),
            serde_json::from_slice(&output.stdout).unwrap_or(Value::Null),
        )
    }

    /// What Swift's registry refuses never reaches the Runtime, and the
    /// refusal names the leaf and the option as Swift's parser does.
    #[test]
    fn the_registrys_grammar_is_judged_before_any_request() {
        for (argv, message, details) in [
            (
                vec!["job", "wait"],
                "`job wait` requires --job <job-id>",
                json!({"command": "job.wait", "option": "--job"}),
            ),
            (
                vec!["job", "wait", "--job", JOB, "--timeout", "0s"],
                "`job wait` --timeout must be a duration like `30s` (digits then ms|s|m|h, no larger than 86400000ms)",
                json!({"command": "job.wait", "option": "--timeout"}),
            ),
            (
                vec!["job", "wait", "--job", JOB, "--timeout", "25h"],
                "`job wait` --timeout must be a duration like `30s` (digits then ms|s|m|h, no larger than 86400000ms)",
                json!({"command": "job.wait", "option": "--timeout"}),
            ),
            (
                vec!["job", "wait", "--job", JOB, "--page-size", "1001"],
                "`job wait` --page-size must be 1...1000",
                json!({"command": "job.wait", "option": "--page-size", "value": "1001"}),
            ),
            (
                vec!["job", "wait", "--job", JOB, "--page-size", "05"],
                "`job wait` --page-size must be 1...1000",
                json!({"command": "job.wait", "option": "--page-size", "value": "05"}),
            ),
        ] {
            let (code, envelope) = refused(&argv);
            assert_eq!(code, Some(64), "{argv:?}");
            assert_eq!(envelope["command"], "job.wait", "{argv:?}");
            assert_eq!(envelope["error"]["code"], "invalidOption");
            assert_eq!(envelope["error"]["message"], message);
            assert_eq!(envelope["error"]["details"], details);
        }
        // The stream path judges the identity and the cursor itself, as
        // Swift's handler does, and names the leaf.
        for (argv, error) in [
            (
                vec!["job", "wait", "--job", "job:1", "--page-size", "5"],
                "invalidInput",
            ),
            (
                vec!["job", "wait", "--job", JOB, "--after-cursor", ""],
                "invalidCursor",
            ),
        ] {
            let (code, envelope) = refused(&argv);
            assert_eq!(code, Some(65), "{argv:?}");
            assert_eq!(envelope["command"], "job.wait", "{argv:?}");
            assert_eq!(envelope["error"]["code"], error, "{argv:?}");
        }
        // The polling path sends the identity as given, for the Runtime to
        // judge (Swift's recorded refusal of an unknown Job).
        let refusal = frames("job.status")
            .into_iter()
            .find(|frame| frame["ok"] == false && frame["error"]["code"] == "notFound")
            .expect("Swift recorded an unknown Job");
        let (output, envelope) = support::run(
            &["job", "wait", "--job", "job:1"],
            vec![(
                "job.status".to_owned(),
                json!({"jobId": "job:1"}),
                json!({"ok": false, "error": refusal["error"]}),
            )],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["error"]["message"], refusal["error"]["message"]);
    }
}
