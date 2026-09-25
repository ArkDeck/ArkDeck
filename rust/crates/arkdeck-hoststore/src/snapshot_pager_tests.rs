//! The bounded pager against the pager as it was before TASK-XPA-025: what
//! it stores and every answer it reads back are, byte for byte, those of the
//! pager that held whole snapshots, for stored documents of every shape that
//! pager accepted or refused; and what storing or reading holds at once does
//! not grow with the snapshot beyond the rows a projection hands over.
use super::*;
use arkdeck_contract::strict_json;
use arkdeck_platform::{AllocationMeter, peak_allocation};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
};

// Counts what each thread holds, so that a test can bound what one call
// holds at once whatever other tests run beside it.
#[global_allocator]
static METER: AllocationMeter = AllocationMeter;

const METHOD: &str = "session.list";
const ORDER: &str = "completedAtDescSessionIdAsc";
const REVISION: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

/// The pager before TASK-XPA-025 bounded it, verbatim but for its lock and
/// publication: the oracle for what is stored and for every answer read back.
mod whole {
    use super::*;

    #[derive(Serialize, Deserialize)]
    #[serde(deny_unknown_fields, rename_all = "camelCase")]
    pub(super) struct Snapshot {
        pub(super) schema_version: String,
        pub(super) revision: String,
        pub(super) query_digest: String,
        pub(super) order: String,
        pub(super) tokens: Vec<String>,
        pub(super) pages: Vec<Vec<Value>>,
    }

    /// The snapshot of `rows` and its stored bytes, as the first page stored
    /// them, with `revision` and the `token` of each page; or the refusal.
    pub(super) fn store(
        rows: Vec<Value>,
        page_size: usize,
        digest: &str,
        revision: &str,
        token: impl Fn(usize) -> String,
    ) -> Result<(Snapshot, Vec<u8>), WireError> {
        let mut pages = Vec::new();
        let mut current = Vec::new();
        let (mut bytes, mut total) = (2, 0);
        for row in rows {
            let size = canonical_json(&row).map_err(unreadable)?.len() + 1;
            if size + 2 > MAX_PAGE {
                return Err(failure(
                    "inputTooLarge",
                    "Resource projection exceeds its page bound",
                ));
            }
            if current.len() == page_size || bytes + size > MAX_PAGE {
                pages.push(current);
                current = Vec::new();
                bytes = 2;
            }
            total += size;
            if total > MAX_SNAPSHOT {
                return Err(failure(
                    "operationUnavailable",
                    "Snapshot exceeds its storage bound",
                ));
            }
            current.push(row);
            bytes += size;
        }
        if !current.is_empty() || pages.is_empty() {
            pages.push(current);
        }
        let tokens = (0..pages.len()).map(token).collect();
        let snapshot = Snapshot {
            schema_version: "arkdeck.runtime-snapshot/1".into(),
            revision: revision.into(),
            query_digest: digest.into(),
            order: ORDER.into(),
            tokens,
            pages,
        };
        let bytes = canonical_json(&serde_json::to_value(&snapshot).map_err(unreadable)?)
            .map_err(unreadable)?;
        if bytes.len() > MAX_SNAPSHOT {
            return Err(failure(
                "operationUnavailable",
                "Snapshot exceeds its encoded storage bound",
            ));
        }
        Ok((snapshot, bytes))
    }

    /// The answer carrying page `index`.
    pub(super) fn answer(snapshot: &Snapshot, index: usize) -> Value {
        let more = index + 1 < snapshot.pages.len();
        json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot",
        "items":snapshot.pages[index],"order":snapshot.order,"snapshotRevision":snapshot.revision,
        "hasMore":more,"nextCursor":snapshot.tokens.get(index+1)})
    }

    /// The answer to `cursor` from stored snapshot `revision`, read whole.
    pub(super) fn read(
        root: &HostDirectory,
        revision: &str,
        cursor: &str,
        digest: &str,
    ) -> Result<Value, WireError> {
        let bytes = root
            .read(&filename(revision), MAX_SNAPSHOT)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    invalid_cursor()
                } else {
                    unreadable(error)
                }
            })?;
        let value = strict_json(&bytes).map_err(unreadable)?;
        let snapshot: Snapshot = serde_json::from_value(value).map_err(unreadable)?;
        if snapshot.schema_version != "arkdeck.runtime-snapshot/1"
            || snapshot.revision != revision
            || snapshot.pages.is_empty()
            || snapshot.pages.len() != snapshot.tokens.len()
            || snapshot.tokens.iter().collect::<BTreeSet<_>>().len() != snapshot.tokens.len()
            || snapshot
                .tokens
                .iter()
                .any(|token| cursor_parts(token).is_none_or(|(id, _)| id != revision))
            || snapshot.pages.iter().any(|page| page.len() > 1000)
        {
            return Err(unreadable(()));
        }
        for page in &snapshot.pages {
            if canonical_json(&json!(page)).map_err(unreadable)?.len() > MAX_PAGE {
                return Err(unreadable(()));
            }
        }
        if snapshot.query_digest != digest || snapshot.order != ORDER {
            return Err(invalid_cursor());
        }
        let index = snapshot
            .tokens
            .iter()
            .position(|value| value == cursor)
            .ok_or_else(invalid_cursor)?;
        Ok(answer(&snapshot, index))
    }
}

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("bounded-pages-{}", uuid().unwrap()));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn pager(&self) -> SnapshotPager {
        SnapshotPager::open(&self.0).unwrap()
    }
    fn directory(&self) -> HostDirectory {
        HostDirectory::open(&self.0).unwrap()
    }
    /// Store `bytes` as snapshot `revision`, owner-only, as the pager does.
    fn plant(&self, revision: &str, bytes: &[u8]) {
        let path = self.0.join(filename(revision));
        let _ = fs::remove_file(&path);
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn digest(page_size: usize) -> String {
    sha256_hex(
        &canonical_json(&json!({"method":METHOD,"filters":{},"order":ORDER,"pageSize":page_size}))
            .unwrap(),
    )
}

/// An answer or a refusal, as the text that would be sent.
fn sent(result: Result<Value, WireError>) -> Result<String, String> {
    result
        .map(|answer| serde_json::to_string(&answer).unwrap())
        .map_err(|error| serde_json::to_string(&error).unwrap())
}

fn string(length: usize) -> Value {
    json!("x".repeat(length))
}

/// Rows of every kind a projection hands over, including rows that are not
/// objects, numbers that do not survive a canonical round trip unchanged,
/// and strings that need escapes.
fn varied_rows() -> Vec<Value> {
    vec![
        json!({"sessionId":"a","count":1,"ratio":0.5,"negative":-3,"exact":9_007_199_254_740_991_i64}),
        json!({"\u{e9}":"\u{e9}","\u{1d11e}":["\u{1d11e}"],"a\u{0}b":"\"\\\n\u{2028}\u{7f}","z":null,"t":true,"f":false}),
        json!({"nested":{"b":{"c":[1,[2,[3,{"d":1.0e-7}]]]}},"float":1.0,"tiny":5e-324,"huge":1.5e300}),
        json!([]),
        json!("a row that is a string"),
        json!(-0.0),
        json!({}),
    ]
}

#[test]
fn stored_documents_and_their_pages_are_those_of_whole_snapshots() {
    let root = Root::new();
    let pager = root.pager();
    let numbered = |count: usize| -> Vec<Value> {
        (0..count)
            .map(|index| json!({"sessionId": format!("s{index:03}"), "index": index}))
            .collect()
    };
    let cases: Vec<(&str, Vec<Value>, usize)> = vec![
        ("no rows", vec![], 1),
        ("no rows, large pages", vec![], 1000),
        ("varied rows, a page each", varied_rows(), 1),
        ("varied rows, pages of four", varied_rows(), 4),
        ("varied rows, one page", varied_rows(), 1000),
        ("pages of seven", numbered(25), 7),
        ("a thousand rows, full pages", numbered(3000), 1000),
        // Pages that their byte bound closes before their row bound does.
        (
            "byte-bound pages",
            (0..5).map(|_| string(400 * 1024)).collect(),
            1000,
        ),
        // The largest row a page takes, one to a page.
        (
            "largest rows",
            (0..3).map(|_| string(MAX_PAGE - 5)).collect(),
            1000,
        ),
    ];
    for (name, rows, page_size) in cases {
        let answer = pager
            .page(METHOD, ORDER, page_size, None, || Ok(rows.clone()))
            .unwrap();
        let revision = answer["snapshotRevision"].as_str().unwrap().to_owned();
        let stored = fs::read(root.0.join(filename(&revision))).unwrap();
        let tokens: Vec<String> = serde_json::from_value(
            serde_json::from_slice::<Value>(&stored).unwrap()["tokens"].clone(),
        )
        .unwrap();
        let (snapshot, bytes) =
            whole::store(rows, page_size, &digest(page_size), &revision, |page| {
                tokens[page].clone()
            })
            .unwrap();
        assert!(stored == bytes, "{name}: the stored document differs");
        assert_eq!(
            sent(Ok(answer)),
            sent(Ok(whole::answer(&snapshot, 0))),
            "{name}: first page"
        );
        for cursor in &snapshot.tokens[1..] {
            assert_eq!(
                sent(pager.page(METHOD, ORDER, page_size, Some(cursor), || {
                    panic!("a cursor never rescans")
                })),
                sent(whole::read(
                    &root.directory(),
                    &revision,
                    cursor,
                    &digest(page_size)
                )),
                "{name}: page {cursor}"
            );
        }
    }
}

#[test]
fn storing_refuses_what_whole_snapshots_refused() {
    let root = Root::new();
    let pager = root.pager();
    // A string of this length is the largest row a page takes: MAX_PAGE - 2
    // bytes with its separator, then the page's brackets.
    let largest = MAX_PAGE - 5;
    let inexact = json!({"count": 9_007_199_254_740_993_u64});
    let cases: Vec<(&str, Vec<Value>, &str)> = vec![
        (
            "a row past its page bound",
            vec![string(largest + 1)],
            "inputTooLarge",
        ),
        (
            "rows past the storage bound",
            (0..17).map(|_| string(largest)).collect(),
            "operationUnavailable",
        ),
        // Within the storage bound row by row, beyond it once encoded.
        (
            "an encoding past the storage bound",
            (0..16).map(|_| string(largest)).collect(),
            "operationUnavailable",
        ),
        (
            "an integer beyond the exact range",
            vec![json!({"sessionId":"a"}), inexact.clone()],
            "recordUnreadable",
        ),
        (
            "the first refused row decides",
            vec![inexact.clone(), string(largest + 1)],
            "recordUnreadable",
        ),
        (
            "the first refused row decides, the other way",
            vec![string(largest + 1), inexact],
            "inputTooLarge",
        ),
    ];
    for (name, rows, code) in cases {
        let expected = whole::store(rows.clone(), 1, &digest(1), REVISION, |page| {
            format!("{REVISION}.{:08x}-0000-4000-8000-000000000000", page)
        })
        .map(|_| ())
        .unwrap_err();
        assert_eq!(expected.code, code, "{name}: the case");
        let refused = pager.page(METHOD, ORDER, 1, None, || Ok(rows)).unwrap_err();
        assert_eq!(sent(Err(refused)), sent(Err(expected)), "{name}");
    }
    // Nothing refused was stored.
    assert!(fs::read_dir(&root.0).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("snapshot-")
    }));
}

fn token(page: usize) -> String {
    format!("{REVISION}.6a1b2c3d-0000-4000-8000-{page:012x}")
}

/// A stored snapshot's text, each member's value given as JSON text.
fn document(schema: &str, revision: &str, digest: &str, tokens: &str, pages: &[&str]) -> Vec<u8> {
    format!(
        r#"{{"order":"{ORDER}","pages":[{}],"queryDigest":{digest},"revision":{revision},"schemaVersion":{schema},"tokens":{tokens}}}"#,
        pages.join(",")
    )
    .into_bytes()
}

#[derive(Debug, PartialEq)]
enum Expect {
    Page,
    Unreadable,
    InvalidCursor,
}

#[test]
fn stored_pages_are_read_as_whole_snapshots_were() {
    let root = Root::new();
    let pager = root.pager();
    let query = format!("\"{}\"", digest(1));
    let revision = format!("\"{REVISION}\"");
    let schema = "\"arkdeck.runtime-snapshot/1\"";
    let tokens = format!("[\"{}\",\"{}\",\"{}\"]", token(0), token(1), token(2));
    let first = r#"[{"sessionId":"a","n":1}]"#;
    let target = r#"[{"sessionId":"b","nested":{"x":[1,2,{"y":null}]},"f":1.5}]"#;
    let last = r#"[{"sessionId":"c"}]"#;
    let with_pages = |pages: &[&str]| document(schema, &revision, &query, &tokens, pages);
    let base = with_pages(&[first, target, last]);
    let text = |bytes: &[u8]| String::from_utf8(bytes.to_vec()).unwrap();
    let replaced = |from: &str, to: &str| {
        let base = text(&base);
        assert!(base.contains(from), "{from}");
        base.replacen(from, to, 1).into_bytes()
    };
    let nested = |depth: usize| format!("[{}{}]", "[".repeat(depth), "]".repeat(depth));
    let (deepest, too_deep) = (nested(124), nested(125));
    let pretty =
        serde_json::to_vec_pretty(&serde_json::from_slice::<Value>(&base).unwrap()).unwrap();
    let positional = |members: &[&str]| format!("[{}]", members.join(",")).into_bytes();
    let pages = format!("[{first},{target},{last}]");
    let order = format!("\"{ORDER}\"");
    let mut invalid_utf8 = replaced(r#""c""#, r#""c INVALID""#);
    let at = invalid_utf8
        .windows(7)
        .position(|window| window == b"INVALID")
        .unwrap();
    invalid_utf8[at] = 0xff;
    let thousand = format!("[{}]", vec![r#"{"n":1}"#; 1000].join(","));
    let past_thousand = format!("[{}]", vec![r#"{"n":1}"#; 1001].join(","));
    let past_bound = format!("[\"{}\"]", "x".repeat(MAX_PAGE));
    let mut padded = base.clone();
    padded.resize(MAX_SNAPSHOT + 1, b' ');
    let cases: Vec<(&str, Vec<u8>, Expect)> = vec![
        ("canonical", base.clone(), Expect::Page),
        ("pretty", pretty, Expect::Page),
        (
            "members in another order",
            format!(
                r#"{{"tokens":{tokens},"schemaVersion":{schema},"revision":{revision},"queryDigest":{query},"pages":{pages},"order":{order}}}"#
            )
            .into_bytes(),
            Expect::Page,
        ),
        (
            "an escaped member name",
            replaced(r#""pages":"#, r#""pages":"#),
            Expect::Page,
        ),
        (
            "members in declared order as an array",
            positional(&[schema, &revision, &query, &order, &tokens, &pages]),
            Expect::Page,
        ),
        (
            "an array with a member too many",
            positional(&[schema, &revision, &query, &order, &tokens, &pages, "1"]),
            Expect::Unreadable,
        ),
        (
            "an array a member short",
            positional(&[schema, &revision, &query, &order, &tokens]),
            Expect::Unreadable,
        ),
        (
            "a repeated member",
            replaced(r#""pages":"#, &format!(r#""order":{order},"pages":"#)),
            Expect::Unreadable,
        ),
        (
            "a repeated member spelled with an escape",
            replaced(r#""pages":"#, &format!(r#""order":{order},"pages":"#)),
            Expect::Unreadable,
        ),
        (
            "a repeated name in another page's row",
            replaced(r#"{"sessionId":"c"}"#, r#"{"sessionId":"c","sessionId":"c"}"#),
            Expect::Unreadable,
        ),
        (
            "a repeated escaped name deep in another page",
            replaced(r#""n":1"#, r#""n":{"k":{"a":1,"a":2}}"#),
            Expect::Unreadable,
        ),
        (
            "a repeated name on the page read",
            replaced(r#""f":1.5"#, r#""f":1.5,"f":1.5"#),
            Expect::Unreadable,
        ),
        (
            "a member not published",
            replaced(r#""pages":"#, r#""extra":1,"pages":"#),
            Expect::Unreadable,
        ),
        (
            "a member missing",
            replaced(&format!(r#""order":{order},"#), ""),
            Expect::Unreadable,
        ),
        (
            "tokens that are not an array",
            document(schema, &revision, &query, &format!("\"{}\"", token(1)), &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "a token that is not a string",
            document(schema, &revision, &query, &format!("[\"{}\",1,\"{}\"]", token(0), token(2)), &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "a page that is not an array",
            with_pages(&[first, target, r#"{"sessionId":"c"}"#]),
            Expect::Unreadable,
        ),
        (
            "pages that are not an array",
            replaced(&format!(r#""pages":{pages}"#), r#""pages":{}"#),
            Expect::Unreadable,
        ),
        (
            "a schema version that is not a string",
            document("1", &revision, &query, &tokens, &[first, target, last]),
            Expect::Unreadable,
        ),
        ("trailing data", [base.as_slice(), b" x"].concat(), Expect::Unreadable),
        ("trailing whitespace", [base.as_slice(), b" \n\t\r"].concat(), Expect::Page),
        ("empty", Vec::new(), Expect::Unreadable),
        (
            "a byte order mark",
            [b"\xef\xbb\xbf".as_slice(), &base].concat(),
            Expect::Unreadable,
        ),
        ("invalid UTF-8 in another page", invalid_utf8, Expect::Unreadable),
        (
            "a lone surrogate in another page",
            replaced(r#""c""#, r#""\ud800""#),
            Expect::Unreadable,
        ),
        (
            "an integer beyond the exact range in another page",
            replaced(r#""n":1"#, r#""n":9007199254740993"#),
            Expect::Unreadable,
        ),
        (
            "a number out of range in another page",
            replaced(r#""n":1"#, r#""n":1e400"#),
            Expect::Unreadable,
        ),
        (
            "numbers on the page read",
            replaced(r#""f":1.5"#, r#""f":1.0,"g":-0,"h":1e-7,"i":123456789.125,"j":-5,"k":0.1,"l":1E+2"#),
            Expect::Page,
        ),
        (
            "a full page read",
            with_pages(&[first, &thousand, last]),
            Expect::Page,
        ),
        (
            "another page past its row bound",
            with_pages(&[&past_thousand, target, last]),
            Expect::Unreadable,
        ),
        (
            "another page past its byte bound",
            with_pages(&[first, target, &past_bound]),
            Expect::Unreadable,
        ),
        (
            "the deepest row on the page read",
            with_pages(&[first, &deepest, last]),
            Expect::Page,
        ),
        (
            "a row too deep on the page read",
            with_pages(&[first, &too_deep, last]),
            Expect::Unreadable,
        ),
        (
            "the deepest row in another page",
            with_pages(&[&deepest, target, last]),
            Expect::Page,
        ),
        (
            "a row too deep in another page",
            with_pages(&[first, target, &too_deep]),
            Expect::Unreadable,
        ),
        (
            "the deepest row, members as an array",
            positional(&[schema, &revision, &query, &order, &tokens, &format!("[{first},{deepest},{last}]")]),
            Expect::Page,
        ),
        (
            "a row too deep, members as an array",
            positional(&[schema, &revision, &query, &order, &tokens, &format!("[{first},{too_deep},{last}]")]),
            Expect::Unreadable,
        ),
        (
            "a repeated token",
            document(schema, &revision, &query, &format!("[\"{}\",\"{}\",\"{}\"]", token(1), token(1), token(2)), &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "a token of another snapshot",
            document(schema, &revision, &query, &format!("[\"{}\",\"{}\",\"3f8fad5b-d9cb-469f-a165-70867728950e.6a1b2c3d-0000-4000-8000-000000000002\"]", token(0), token(1)), &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "a token that is not a cursor",
            document(schema, &revision, &query, &format!("[\"{}\",\"{}\",\"{REVISION}.X\"]", token(0), token(1)), &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "a token too many",
            with_pages(&[first, target]),
            Expect::Unreadable,
        ),
        (
            "no pages",
            document(schema, &revision, &query, "[]", &[]),
            Expect::Unreadable,
        ),
        (
            "another schema",
            document("\"arkdeck.runtime-snapshot/2\"", &revision, &query, &tokens, &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "another revision inside",
            document(schema, "\"3f8fad5b-d9cb-469f-a165-70867728950e\"", &query, &tokens, &[first, target, last]),
            Expect::Unreadable,
        ),
        (
            "another query",
            document(schema, &revision, &format!("\"{}\"", "0".repeat(64)), &tokens, &[first, target, last]),
            Expect::InvalidCursor,
        ),
        (
            "another order",
            replaced(&format!(r#""order":{order}"#), r#""order":"createdAtAscJobIdAsc""#),
            Expect::InvalidCursor,
        ),
        (
            "a cursor the snapshot does not list",
            document(schema, &revision, &query, &format!("[\"{}\",\"{}\",\"{}\"]", token(0), token(3), token(2)), &[first, target, last]),
            Expect::InvalidCursor,
        ),
        ("past the storage bound", padded, Expect::Unreadable),
    ];
    let cursor = token(1);
    for (name, bytes, expect) in cases {
        root.plant(REVISION, &bytes);
        let answer = pager.page(METHOD, ORDER, 1, Some(&cursor), || {
            panic!("a cursor never rescans")
        });
        let outcome = match &answer {
            Ok(_) => Expect::Page,
            Err(error) if error.code == "invalidCursor" => Expect::InvalidCursor,
            Err(_) => Expect::Unreadable,
        };
        assert_eq!(
            sent(answer),
            sent(whole::read(
                &root.directory(),
                REVISION,
                &cursor,
                &digest(1)
            )),
            "{name}"
        );
        assert_eq!(outcome, expect, "{name}");
    }

    // The file's own checks come before its content, as a whole read's did.
    let file = root.0.join(filename(REVISION));
    for (name, expect) in [
        ("a snapshot that is not owner-only", "recordUnreadable"),
        ("a snapshot through a link", "recordUnreadable"),
        ("a reclaimed snapshot", "invalidCursor"),
    ] {
        match expect {
            "invalidCursor" => {
                let _ = fs::remove_file(&file);
            }
            _ if name.ends_with("link") => {
                let outside = root.0.join("outside.json");
                fs::write(&outside, &base).unwrap();
                fs::set_permissions(&outside, fs::Permissions::from_mode(0o600)).unwrap();
                let _ = fs::remove_file(&file);
                symlink(&outside, &file).unwrap();
            }
            _ => {
                root.plant(REVISION, &base);
                fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
            }
        }
        let answer = pager.page(METHOD, ORDER, 1, Some(&cursor), || {
            panic!("a cursor never rescans")
        });
        assert_eq!(
            answer.as_ref().map_err(|error| error.code.as_str()).err(),
            Some(expect),
            "{name}"
        );
        assert_eq!(
            sent(answer),
            sent(whole::read(
                &root.directory(),
                REVISION,
                &cursor,
                &digest(1)
            )),
            "{name}"
        );
    }
}

/// Rows of the size and shape of a Job history row: about a kilobyte each.
fn history_rows(count: usize) -> Vec<Value> {
    (0..count)
        .map(|index| {
            json!({
                "jobId": format!("{index:08x}-0000-4000-8000-000000000000"),
                "state": (["succeeded", "cancelled", "failed"])[index % 3],
                "operation": {"id": "observe.device", "version": 1},
                "target": {"targetId": format!("target-{}", index % 7), "bindingRevision": index},
                "createdAt": "2026-09-25T00:00:00.000Z",
                "updatedAt": "2026-09-25T00:00:01.250Z",
                "steps": [
                    {"kind": "hdc", "action": "list targets", "exitStatus": 0, "durationMs": 10.5},
                    {"kind": "hdc", "action": "param get", "exitStatus": 0, "durationMs": 12.25},
                ],
                "evidence": {"artifacts": [{"name": "observation.json", "bytesVerified": true,
                    "sha256": "a".repeat(64)}]},
                "summary": "x".repeat(480),
            })
        })
        .collect()
}

#[test]
fn reading_a_stored_page_holds_that_page_and_not_the_snapshot() {
    let held = |rows: usize| {
        let root = Root::new();
        let pager = root.pager();
        let first = pager
            .page(METHOD, ORDER, 100, None, || Ok(history_rows(rows)))
            .unwrap();
        let cursor = first["nextCursor"].as_str().unwrap().to_owned();
        let (page, held) = peak_allocation(|| {
            pager
                .page(METHOD, ORDER, 100, Some(&cursor), || {
                    panic!("a cursor never rescans")
                })
                .unwrap()
        });
        assert_eq!(page["items"].as_array().map(Vec::len), Some(100));
        held
    };
    let (small, large) = (held(1_000), held(10_000));
    eprintln!(
        "reading a page of 100 rows held at most {small} bytes of a 1,000-row snapshot and {large} bytes of a 10,000-row one"
    );
    // Holding the snapshot, even only its bytes, grows about tenfold. What
    // may grow is its tokens, one short string for each page.
    assert!(
        large < small + small / 5,
        "reading one page held {small} bytes of a 1,000-row snapshot but {large} bytes of a 10,000-row one"
    );
}

#[test]
fn storing_a_snapshot_holds_its_rows_once() {
    let rows = 2_000;
    let ((), projection) = peak_allocation(|| drop(history_rows(rows)));
    let root = Root::new();
    let pager = root.pager();
    let (answer, held) = peak_allocation(|| {
        pager
            .page(METHOD, ORDER, 100, None, || Ok(history_rows(rows)))
            .unwrap()
    });
    assert_eq!(answer["items"].as_array().map(Vec::len), Some(100));
    eprintln!(
        "storing {rows} rows held at most {held} bytes; the projection alone held {projection}"
    );
    // The projection's rows are all held when it hands them over. Storing
    // them encodes each once and drops it, keeping the first page's; a
    // second copy of the rows, or of their encoding beside them, is not held.
    assert!(
        held < projection + projection / 4,
        "storing {rows} rows held {held} bytes; the projection alone held {projection}"
    );
}
