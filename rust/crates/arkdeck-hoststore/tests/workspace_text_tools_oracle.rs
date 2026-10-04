//! The code-owned grep, sed and patch (TASK-XPA-011, ruling of 2026-10-04)
//! against what the macOS tools answered.
//!
//! * The recorded Swift workspace oracles, on every host: the inspection and
//!   the source range `rust/tests/fixtures/workspace-read-oracle` published
//!   from `/usr/bin/grep` and `/usr/bin/sed` over the same fabricated tree,
//!   byte for byte (the recorded root's spelling replaced by this one's),
//!   and the tree `workspace-patch-oracle` recorded after `/usr/bin/patch`
//!   applied its unified diffs, the failed one's reject and backup included,
//!   digest for digest.
//! * On macOS, the host's own `/usr/bin/grep`, `/usr/bin/sed` and
//!   `/usr/bin/patch` run over a corpus of the argv shapes the workspace
//!   provider builds — line ranges, a missing final newline, a missing file,
//!   a match and no match, a clean apply, an offset, fuzz, an already
//!   applied patch, a reverse, a missing newline in a patch — and answer
//!   exactly what the reimplementation answers: exit status, stdout, stderr
//!   and the tree.
#![cfg(any(target_os = "macos", windows))]

use arkdeck_hoststore::run_text_tool;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
const INDEX_SOURCE: &str = "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n";
const ABILITY_SOURCE: &str = "export default class EntryAbility {}\n";
const RECORDED_ROOT: &str = "/private/tmp/arkdeck-workspace-read-oracle/source";

fn fixture(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(relative)
}

fn sha256(bytes: &[u8]) -> String {
    arkdeck_contract::sha256_hex(bytes)
}

fn run(tool: &str, arguments: &[&str]) -> arkdeck_hoststore::TextToolOutput {
    run_text_tool(
        tool,
        &arguments.iter().map(|&a| a.to_owned()).collect::<Vec<_>>(),
    )
}

/// A fresh directory below the temporary directory in its canonical
/// spelling, removed afterwards.
struct Scratch(PathBuf);
impl Scratch {
    fn new(tag: &str) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir().join(format!("ad-texttools-{tag}-{nonce:016x}"));
        fs::create_dir_all(&path).unwrap();
        let canonical = path.canonicalize().unwrap();
        let text = canonical.to_str().unwrap();
        Self(PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(text)))
    }
    fn path(&self, relative: &str) -> PathBuf {
        let mut path = self.0.clone();
        for part in relative.split('/') {
            path.push(part);
        }
        path
    }
    fn write(&self, relative: &str, bytes: &[u8]) {
        let path = self.path(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    fn text(&self, relative: &str) -> String {
        self.path(relative).to_str().unwrap().to_owned()
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The read oracle's fabricated OpenHarmony tree.
fn read_tree(scratch: &Scratch) {
    scratch.write(
        "entry/src/main/ets/entryability/EntryAbility.ets",
        ABILITY_SOURCE.as_bytes(),
    );
    scratch.write(INDEX, INDEX_SOURCE.as_bytes());
    scratch.write("build-profile.json5", b"{}\n");
}

fn recorded(job: &str, artifact: &str) -> Vec<u8> {
    fs::read(fixture(&format!(
        "workspace-read-oracle/artifacts/{job}/{artifact}"
    )))
    .unwrap()
}

#[test]
fn the_reimplemented_grep_and_sed_publish_what_the_macos_tools_published() {
    let scratch = Scratch::new("read");
    read_tree(&scratch);
    let root = scratch.0.to_str().unwrap();
    // grep -r -n --include '*.ets' -- build <root>: the one match, named
    // below the root as this host joins it.
    let found = run(
        "grep",
        &["-r", "-n", "--include", "*.ets", "--", "build", root],
    );
    let expected = String::from_utf8(recorded(
        "job-202a696b201b6d684c9db049dda2ace9",
        "ART-dd3b7a1af9c849db70aec3f8a748a59d",
    ))
    .unwrap();
    let relative = expected
        .strip_prefix(&format!("{RECORDED_ROOT}/"))
        .expect("the recorded match is named below the recorded root");
    let (name, line) = relative.split_once(':').unwrap();
    assert_eq!(found.status, 0);
    assert_eq!(
        String::from_utf8(found.stdout).unwrap(),
        format!("{}:{line}", scratch.text(name))
    );
    // No occurrence: nothing published, exit status 1.
    let none = run(
        "grep",
        &["-r", "-n", "--include", "*.ets", "--", "NoSuchSymbol", root],
    );
    assert_eq!(none.status, 1);
    assert_eq!(
        none.stdout,
        recorded(
            "job-9b91bfa850784cfb95575a9b0c6d3a87",
            "ART-b829d467ed05633a789e0bb798510a6f"
        )
    );
    // sed -n 2,4p <file>.
    let range = run("sed", &["-n", "2,4p", &scratch.text(INDEX)]);
    assert_eq!(range.status, 0);
    assert_eq!(
        range.stdout,
        recorded(
            "job-d11a5281790ab1960775ee86373ea5c8",
            "ART-f91e7099f413f6a4b127451b3dfffd0b"
        )
    );
    // A file that is not there fails the read (the recorded Job failed).
    let missing = run(
        "sed",
        &[
            "-n",
            "1,1p",
            &scratch.text("entry/src/main/ets/pages/Missing.ets"),
        ],
    );
    assert_eq!((missing.status, missing.stdout.len()), (1, 0));
}

#[test]
fn the_reimplemented_patch_leaves_the_tree_the_macos_patch_left() {
    let scratch = Scratch::new("patch");
    scratch.write("Sources/App.txt", b"old\n");
    scratch.write("Sources/Other.txt", b"outside the narrowed scope\n");
    let inputs = fixture("workspace-patch-oracle/artifacts/job-input-patch");
    let root = scratch.0.to_str().unwrap().to_owned();
    let apply = |artifact: &str, reverse: bool| {
        let input = inputs.join(artifact);
        let input = input.to_str().unwrap();
        let mut arguments = vec!["-f"];
        if reverse {
            arguments.push("-R");
        }
        arguments.extend(["-p1", "-d", &root, "-i", input]);
        run("patch", &arguments)
    };
    // old -> new applies; stale -> newer, against "new", does not.
    assert_eq!(
        apply("ART-4ccb0a35050cacc5248ae8c1d2e9fb1c", false).status,
        0
    );
    let failed = apply("ART-43837c01d84f6d61f22bb58d4ab373aa", false);
    assert_eq!(failed.status, 1);
    let tree: Value =
        serde_json::from_slice(&fs::read(fixture("workspace-patch-oracle/tree.json")).unwrap())
            .unwrap();
    let mut present: Vec<(String, String)> = Vec::new();
    let mut stack = vec![(scratch.0.clone(), String::new())];
    while let Some((directory, prefix)) = stack.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name().into_string().unwrap();
            let relative = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            if entry.file_type().unwrap().is_dir() {
                stack.push((entry.path(), relative));
            } else {
                present.push((relative, sha256(&fs::read(entry.path()).unwrap())));
            }
        }
    }
    present.sort();
    let expected: Vec<(String, String)> = tree["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            (
                entry["path"].as_str().unwrap().to_owned(),
                entry["sha256"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(present, expected);
    // The applied patch reverses cleanly.
    assert_eq!(
        apply("ART-4ccb0a35050cacc5248ae8c1d2e9fb1c", true).status,
        0
    );
    assert_eq!(fs::read(scratch.path("Sources/App.txt")).unwrap(), b"old\n");
}

/// One corpus case: the files before, the tool and its argv (`{root}` and
/// `{patch}` substituted), and the files whose bytes are compared after.
#[cfg(target_os = "macos")]
struct Case {
    name: &'static str,
    files: &'static [(&'static str, &'static [u8])],
    patch: Option<&'static [u8]>,
    tool: &'static str,
    arguments: &'static [&'static str],
    compared: &'static [&'static str],
}

#[cfg(target_os = "macos")]
const CASES: &[Case] = &[
    Case {
        name: "sed range",
        files: &[("a.ets", b"one\ntwo\nthree\nfour\n")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "2,3p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed reversed range",
        files: &[("a.ets", b"one\ntwo\nthree\nfour\n")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "3,2p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed past the end",
        files: &[("a.ets", b"one\ntwo\n")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "2,9p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed without a final newline",
        files: &[("a.ets", b"one\ntwo")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "1,2p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed empty file",
        files: &[("a.ets", b"")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "1,2p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed carriage returns",
        files: &[("a.ets", b"one\r\ntwo\r\nthree")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "2,3p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed last line only, unterminated",
        files: &[("a.ets", b"one\ntwo")],
        patch: None,
        tool: "sed",
        arguments: &["-n", "2,2p", "{root}/a.ets"],
        compared: &[],
    },
    Case {
        name: "sed missing file",
        files: &[],
        patch: None,
        tool: "sed",
        arguments: &["-n", "1,2p", "{root}/missing.ets"],
        compared: &[],
    },
    Case {
        name: "grep one match",
        files: &[
            ("entry/a.ets", b"x\n  build() {}\n"),
            ("entry/b.txt", b"build\n"),
        ],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "build", "{root}"],
        compared: &[],
    },
    Case {
        name: "grep regular expression",
        files: &[("entry/a.ets", b"build\nbuilt\nbu.ld\n")],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "bu.l[dt]", "{root}"],
        compared: &[],
    },
    Case {
        name: "grep unterminated last line",
        files: &[("entry/a.ets", b"x\n  build() {}")],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "build", "{root}"],
        compared: &[],
    },
    Case {
        name: "grep carriage returns",
        files: &[("entry/a.ets", b"build\r\nx\r\n")],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "build$", "{root}"],
        compared: &[],
    },
    Case {
        name: "grep empty file",
        files: &[("entry/a.ets", b"")],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "build", "{root}"],
        compared: &[],
    },
    Case {
        name: "grep no match",
        files: &[("entry/a.ets", b"x\n")],
        patch: None,
        tool: "grep",
        arguments: &["-r", "-n", "--include", "*.ets", "--", "absent", "{root}"],
        compared: &[],
    },
    Case {
        name: "patch clean git diff",
        files: &[("Sources/App.txt", b"zero\nold\nkeep\n")],
        patch: Some(b"diff --git a/Sources/App.txt b/Sources/App.txt\nindex 1111111..2222222 100644\n--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1,3 +1,3 @@\n zero\n-old\n+new\n keep\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch offset",
        files: &[("Sources/App.txt", b"a\nb\nzero\nold\nkeep\n")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1,3 +1,3 @@\n zero\n-old\n+new\n keep\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch fuzz",
        files: &[("Sources/App.txt", b"zero\nold\nchanged\n")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1,3 +1,3 @@\n zero\n-old\n+new\n keep\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch already applied",
        files: &[("Sources/App.txt", b"new\n")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1 @@\n-stale\n+newer\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch reverse",
        files: &[("Sources/App.txt", b"new\n")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1 @@\n-old\n+new\n"),
        tool: "patch",
        arguments: &["-f", "-R", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch carriage returns",
        files: &[("Sources/App.txt", b"zero\r\nold\r\nkeep\r\n")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1,3 +1,3 @@\n zero\r\n-old\r\n+new\r\n keep\r\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch adds a line to an unterminated file",
        files: &[("Sources/App.txt", b"a")],
        patch: Some(b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1,2 @@\n-a\n\\ No newline at end of file\n+a\n+b\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/App.txt", "Sources/App.txt.orig", "Sources/App.txt.rej"],
    },
    Case {
        name: "patch two files and a missing newline",
        files: &[("Sources/A.txt", b"a\n"), ("Sources/B.txt", b"b")],
        patch: Some(b"--- a/Sources/A.txt\n+++ b/Sources/A.txt\n@@ -1 +1,2 @@\n a\n+a2\n--- a/Sources/B.txt\n+++ b/Sources/B.txt\n@@ -1 +1 @@\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file\n"),
        tool: "patch",
        arguments: &["-f", "-p1", "-d", "{root}", "-i", "{patch}"],
        compared: &["Sources/A.txt", "Sources/B.txt"],
    },
];

/// The host's own tools, in the closed environment the workspace oracles
/// run them in, answer each corpus case exactly as the reimplementation
/// does.
#[cfg(target_os = "macos")]
#[test]
fn the_macos_tools_answer_the_corpus_as_the_reimplementation_does() {
    let mut mismatches = Vec::new();
    for case in CASES {
        let answer = |host: bool| {
            let scratch = Scratch::new("corpus");
            for (relative, bytes) in case.files {
                scratch.write(relative, bytes);
            }
            let patch_path = scratch.0.with_extension("patch");
            if let Some(bytes) = case.patch {
                fs::write(&patch_path, bytes).unwrap();
            }
            let root = scratch.0.to_str().unwrap().to_owned();
            let arguments: Vec<String> = case
                .arguments
                .iter()
                .map(|argument| {
                    argument
                        .replace("{root}", &root)
                        .replace("{patch}", patch_path.to_str().unwrap())
                })
                .collect();
            let (status, stdout, stderr) = if host {
                let output = std::process::Command::new(format!("/usr/bin/{}", case.tool))
                    .args(&arguments)
                    .env_clear()
                    .envs([("PATH", "/usr/bin:/bin"), ("LANG", "C"), ("LC_ALL", "C")])
                    .output()
                    .unwrap();
                (output.status.code(), output.stdout, output.stderr)
            } else {
                let output = run_text_tool(case.tool, &arguments);
                (Some(output.status), output.stdout, output.stderr)
            };
            let files: Vec<Option<Vec<u8>>> = case
                .compared
                .iter()
                .map(|relative| fs::read(scratch.path(relative)).ok())
                .collect();
            let _ = fs::remove_file(&patch_path);
            let unrooted = |bytes: Vec<u8>| {
                String::from_utf8_lossy(&bytes)
                    .replace(&root, "{root}")
                    .replace(patch_path.to_str().unwrap(), "{patch}")
            };
            (status, unrooted(stdout), unrooted(stderr), files)
        };
        let (reimplemented, host) = (answer(false), answer(true));
        if reimplemented != host {
            mismatches.push(format!(
                "{}:\n  reimplementation {reimplemented:?}\n  /usr/bin/{} {host:?}",
                case.name, case.tool
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}
