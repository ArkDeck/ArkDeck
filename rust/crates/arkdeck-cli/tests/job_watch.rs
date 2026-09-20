//! `arkdeck job watch` against a fake Runtime, with pages built from the event
//! rows Swift recorded (`Fixtures/ControlFrames/job.events.jsonl`): rows are
//! written as they arrive, a page the Runtime serves again is recognised and
//! skipped, and the stream always ends in one terminal line it never invents a
//! resume point for.
// The fake Runtime this leaf is driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use serde_json::{Value, json};

    const JOB: &str = "job-2b395b58efa418650be51432f3a2c9b0";

    /// One recorded row, re-positioned: its `data` is the Runtime's own, which
    /// is what the page contract judges.
    fn row(position: i64, revision: i64, id: &str) -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.events.jsonl",
        );
        let recorded = std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]["items"]
                        .as_array()
                        .is_some_and(|items| !items.is_empty())
            })
            .expect("a recorded event page")["result"]["items"][0]
            .clone();
        let mut row = recorded;
        row["eventId"] = json!(id);
        row["streamPosition"] = json!(position.to_string());
        row["runtimeRevision"] = json!(revision.to_string());
        row["cursor"] = json!(format!("cursor-{id}"));
        row
    }

    fn page(rows: Vec<Value>, revision: i64, next: &str) -> Value {
        json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"eventStream","order":"streamPositionAsc",
            "items":rows,"snapshotRevision":revision.to_string(),"hasMore":false,"nextCursor":next})
    }

    fn pages(answers: Vec<Value>) -> Vec<(String, Value, Value)> {
        answers
            .into_iter()
            .enumerate()
            .map(|(index, answer)| {
                // Each read resumes from the cursor the previous page ended
                // with; a row's own cursor is where a stream that failed
                // mid-page would resume instead.
                let mut params = json!({"jobId":JOB,"pageSize":100});
                if index > 0 {
                    params["afterCursor"] = json!(answer["afterCursor"]);
                }
                (
                    "job.events".to_owned(),
                    params,
                    json!({"ok":true,"result":answer["page"]}),
                )
            })
            .collect()
    }

    /// The answers a test serves, each with the cursor the CLI must resume from.
    fn expected(page: Value, after: Option<&str>) -> Value {
        json!({"page": page, "afterCursor": after})
    }

    fn lines(output: &[u8]) -> Vec<Value> {
        String::from_utf8_lossy(output)
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("one document per line"))
            .collect()
    }

    fn argv<'a>(timeout: &'a str, mode: &'a str) -> Vec<&'a str> {
        vec![
            "job",
            "watch",
            "--job",
            JOB,
            "--output",
            mode,
            "--timeout",
            timeout,
        ]
    }

    #[test]
    fn rows_are_written_as_they_arrive_and_the_stream_ends_at_its_deadline() {
        // The Runtime answers the same page every time it is asked. The stream
        // deduplicates each replay, so what this call writes, where it says it
        // stopped, and how it ended are the same whether the deadline arrives
        // after one read or after two — the read count is the only thing a
        // loaded host changes, and the answer must not depend on it.
        let served = page(vec![row(1, 2, "e1"), row(2, 2, "e2")], 2, "page-a");
        let mut answers = vec![expected(served.clone(), None)];
        // The wait reads, then pauses 250 ms, so a two-second deadline is at
        // most nine reads however fast the host is, and leaves a slow one far
        // more than it needs for the first. Offering more than it can use is
        // what makes the count harmless.
        answers.extend((0..9).map(|_| expected(served.clone(), Some("page-a"))));
        let (output, _) = support::run_partial(&argv("2s", "jsonl"), pages(answers));
        assert_eq!(output.status.code(), Some(75));
        let lines = lines(&output.stdout);
        assert_eq!(lines.len(), 3, "{lines:?}");
        for (index, line) in lines.iter().enumerate() {
            assert_eq!(line["schemaVersion"], "arkdeck.cli.event/1");
            assert_eq!(line["command"], "job.watch");
            assert_eq!(line["sequence"], json!(index + 1));
        }
        assert_eq!(lines[0]["eventId"], "e1");
        assert_eq!(lines[0]["streamPosition"], "1");
        assert_eq!(lines[1]["eventId"], "e2");
        // The terminal line names the resume point it actually delivered.
        let terminal = &lines[2];
        assert_eq!(terminal["type"], "terminal");
        assert_eq!(terminal["ok"], false);
        assert_eq!(terminal["exitCode"], 75);
        assert_eq!(terminal["lastCursor"], "cursor-e2");
        assert_eq!(terminal["error"]["code"], "clientTimeout");
        assert_eq!(
            terminal["error"]["message"],
            "client observation timed out; the Job was not cancelled"
        );
        assert_eq!(terminal["error"]["details"]["jobId"], JOB);
        assert_eq!(terminal["error"]["details"]["afterCursor"], "page-a");
    }

    #[test]
    fn a_served_page_is_deduplicated_and_a_reused_identity_is_refused() {
        let first = page(vec![row(1, 2, "e1"), row(2, 2, "e2")], 2, "page-a");
        let again = page(vec![row(2, 2, "e2")], 2, "page-b");
        let reused = page(vec![row(3, 3, "e2")], 3, "page-c");
        let (output, _) = support::run(
            &argv("5s", "jsonl"),
            pages(vec![
                expected(first, None),
                expected(again, Some("page-a")),
                expected(reused, Some("page-b")),
            ]),
        );
        assert_eq!(output.status.code(), Some(2));
        let lines = lines(&output.stdout);
        // Two rows delivered, the replay skipped, then the terminal line.
        assert_eq!(lines.len(), 3, "{lines:?}");
        assert_eq!(lines[2]["type"], "terminal");
        assert_eq!(lines[2]["error"]["code"], "recordUnreadable");
        assert_eq!(
            lines[2]["error"]["message"],
            "event identity was reused at a new position"
        );
    }

    #[test]
    fn a_stream_that_cannot_start_at_its_origin_says_where_it_can() {
        let late = page(vec![row(5, 5, "e5")], 5, "page-a");
        let (output, _) = support::run(&argv("5s", "jsonl"), pages(vec![expected(late, None)]));
        assert_eq!(output.status.code(), Some(75));
        let lines = lines(&output.stdout);
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert_eq!(lines[0]["type"], "terminal");
        assert_eq!(lines[0]["error"]["code"], "eventHistoryUnavailable");
        assert_eq!(
            lines[0]["error"]["message"],
            "the retained stream origin is unavailable"
        );
        assert_eq!(
            lines[0]["error"]["details"]["earliestRetainedPosition"],
            "5"
        );
        // Nothing was delivered, so there is no resume point to name.
        assert_eq!(lines[0]["lastCursor"], Value::Null);
    }

    #[test]
    fn human_output_is_the_rows_and_nothing_else() {
        // The same page every time, for the same reason as above: the row is
        // written once however many reads the deadline allows.
        let served = page(vec![row(1, 1, "e1")], 1, "page-a");
        let mut answers = vec![expected(served.clone(), None)];
        answers.extend((0..9).map(|_| expected(served.clone(), Some("page-a"))));
        let (output, _) = support::run_partial(&argv("2s", "human"), pages(answers));
        assert_eq!(output.status.code(), Some(75));
        let text = String::from_utf8_lossy(&output.stdout);
        assert!(text.contains("\"eventId\": \"e1\""), "{text}");
        assert!(!text.contains("terminal"), "{text}");
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("client observation timed out; the Job was not cancelled")
        );
    }
}
