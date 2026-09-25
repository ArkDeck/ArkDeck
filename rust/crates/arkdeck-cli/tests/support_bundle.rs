//! `arkdeck runtime support-bundle preview|export` (`arkdeck_cli::support_bundle`
//! over `arkdeck_platform::publish_bundle`): what Swift's production provider
//! writes, where, and every way it refuses.
#![cfg(target_os = "macos")]

use arkdeck_cli::support_bundle::{self, MAXIMUM_BUNDLE_BYTES};
use arkdeck_platform::{BundleFailure, BundleFaultPoint};
use serde_json::{Map, Value, json};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A private root below `/tmp` (its `/tmp` spelling is the canonical one),
/// removed however the test ends.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let name = format!(
            "arkdeck-sb-{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        );
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(Path::new("/private/tmp").join(&name))
            .unwrap();
        Self(Path::new("/tmp").join(name))
    }

    fn path(&self, name: &str) -> String {
        self.0.join(name).to_str().unwrap().to_owned()
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ =
            std::fs::remove_dir_all(Path::new("/private").join(self.0.strip_prefix("/").unwrap()));
    }
}

fn options(destination: &str, digest: Option<&str>) -> Map<String, Value> {
    let mut options = Map::from_iter([("destinationPath".to_owned(), json!(destination))]);
    if let Some(digest) = digest {
        options.insert("previewDigest".into(), json!(digest));
    }
    options
}

fn cli(argv: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv)
        .output()
        .unwrap()
}

fn digest_of(destination: &str) -> String {
    support_bundle::preview(&options(destination, None)).unwrap()["scopeSHA256"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
fn a_preview_writes_nothing_and_an_export_publishes_the_approved_owner_only_tree() {
    let root = Root::new();
    let destination = root.path("support");
    let preview = support_bundle::preview(&options(&destination, None)).unwrap();
    assert_eq!(
        preview["schemaVersion"],
        "arkdeck.runtime-support-bundle-preview/1"
    );
    assert_eq!(
        preview["includedEntries"],
        json!(["bundle.json", "hdc/tool-placeholder.json", "metadata.json"])
    );
    assert_eq!(preview["deviceRawExcluded"], true);
    assert_eq!(
        preview["sensitiveDataWarning"],
        support_bundle::SENSITIVE_DATA_WARNING
    );
    assert!(!Path::new(&destination).exists());
    let digest = preview["scopeSHA256"].as_str().unwrap();
    let receipt = support_bundle::export(&options(&destination, Some(digest))).unwrap();
    assert_eq!(
        receipt,
        json!({"schemaVersion": "arkdeck.runtime-support-bundle-export/1", "status": "exported",
            "destination": destination, "scopeSHA256": digest,
            "exportedBytes": preview["estimatedBytes"], "deviceRawExcluded": true})
    );
    // Exactly the three documents, owner-only, and their bytes add up to the
    // approved estimate.
    let mut total = 0;
    for (relative, mode) in [
        ("", 0o700),
        ("hdc", 0o700),
        ("bundle.json", 0o600),
        ("metadata.json", 0o600),
        ("hdc/tool-placeholder.json", 0o600),
    ] {
        let path = Path::new(&destination).join(relative);
        let metadata = std::fs::symlink_metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, mode, "{relative}");
        if metadata.is_file() {
            total += metadata.len();
        }
    }
    assert_eq!(json!(total), preview["estimatedBytes"]);
    let names = |path: &str| {
        let mut names: Vec<String> = std::fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    };
    assert_eq!(names(&destination), ["bundle.json", "hdc", "metadata.json"]);
    // Nothing is left staged beside it.
    assert_eq!(names(root.0.to_str().unwrap()), ["support"]);
    assert_eq!(
        std::fs::read_to_string(Path::new(&destination).join("hdc/tool-placeholder.json")).unwrap(),
        r#"{"path":"redacted","serverEndpoint":"redacted","serverOwnership":"unverified","version":"unverified"}"#
    );
    let manifest: Value = serde_json::from_slice(
        &std::fs::read(Path::new(&destination).join("bundle.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["automaticUploadEnabled"], false);
    assert_eq!(manifest["schemaVersion"], "1.0.0");
    let mut summarized = preview.clone();
    summarized.as_object_mut().unwrap().remove("schemaVersion");
    assert_eq!(manifest["preview"], summarized);
}

#[test]
fn the_digest_binds_the_destination_its_parent_and_the_entries() {
    let root = Root::new();
    let destination = root.path("support");
    let digest = digest_of(&destination);
    // Swift's formula, over this parent's identity and the documents written.
    let parent = std::fs::metadata(&root.0).unwrap();
    let preview = support_bundle::preview(&options(&destination, None)).unwrap();
    assert_eq!(preview["scopeSHA256"], digest, "stable across previews");
    let exported = support_bundle::export(&options(&destination, Some(&digest))).unwrap();
    assert_eq!(exported["scopeSHA256"], digest);
    let mut scope = format!(
        "{destination}\nparent-device:{}\nparent-inode:{}\n",
        parent.dev(),
        parent.ino()
    )
    .into_bytes();
    for path in ["hdc/tool-placeholder.json", "metadata.json"] {
        let bytes = std::fs::read(Path::new(&destination).join(path)).unwrap();
        scope.extend_from_slice(path.as_bytes());
        scope.push(0);
        scope.extend_from_slice(arkdeck_contract::sha256_hex(&bytes).as_bytes());
        scope.push(b'\n');
    }
    assert_eq!(arkdeck_contract::sha256_hex(&scope), digest);
    // Another destination is another scope.
    assert_ne!(digest_of(&root.path("elsewhere")), digest);
}

#[test]
fn every_refusal_is_swifts_and_leaves_nothing_behind() {
    let root = Root::new();
    let code = |answer: Result<Value, arkdeck_cli::CliError>| {
        let error = answer.unwrap_err();
        (error.code, error.exit_code())
    };
    // Not canonical, or not absolute. (A `/private` spelling of a destination
    // that does not exist yet is canonical to Foundation: the oracle replay
    // holds it.)
    for destination in [
        "support".to_owned(),
        format!("{}/", root.path("support")),
        root.path("x/../support"),
    ] {
        assert_eq!(
            code(support_bundle::preview(&options(&destination, None))),
            ("invalidInput", 65),
            "{destination}"
        );
    }
    // A parent that is missing, or that a group can write.
    assert_eq!(
        code(support_bundle::preview(&options(
            &root.path("missing/support"),
            None
        ))),
        ("ioFailure", 74)
    );
    let writable = root.0.join("writable");
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&writable)
        .unwrap();
    std::fs::set_permissions(&writable, std::fs::Permissions::from_mode(0o770)).unwrap();
    assert_eq!(
        code(support_bundle::preview(&options(
            &root.path("writable/support"),
            None
        ))),
        ("invalidInput", 65)
    );
    // A digest another destination was approved with, or none of them.
    let destination = root.path("support");
    let elsewhere = digest_of(&root.path("elsewhere"));
    assert_eq!(
        code(support_bundle::export(&options(
            &destination,
            Some(&elsewhere)
        ))),
        ("previewDrifted", 77)
    );
    assert_eq!(
        code(support_bundle::export(&options(
            &destination,
            Some(&"0".repeat(64))
        ))),
        ("previewDrifted", 77)
    );
    assert!(!Path::new(&destination).exists());
    // An existing destination is never replaced.
    let digest = digest_of(&destination);
    support_bundle::export(&options(&destination, Some(&digest))).unwrap();
    assert_eq!(
        code(support_bundle::export(&options(
            &destination,
            Some(&digest)
        ))),
        ("resourceConflict", 65)
    );
    assert_eq!(
        code(support_bundle::preview(&options(&destination, None))),
        ("resourceConflict", 65)
    );
    // Over the quota: refused at the preview, nothing written.
    let small = root.path("small");
    let digest = digest_of(&small);
    assert_eq!(
        code(support_bundle::export_with(
            &options(&small, Some(&digest)),
            64,
            &|_| Ok(())
        )),
        ("quotaExceeded", 69)
    );
    assert!(!Path::new(&small).exists());
}

#[test]
fn a_failure_while_publishing_removes_the_bundle_or_is_an_unknown_outcome() {
    let root = Root::new();
    // A failure after the rename: the published tree is removed, and the
    // failure is the one that happened.
    let destination = root.path("support");
    let digest = digest_of(&destination);
    let failure = support_bundle::export_with(
        &options(&destination, Some(&digest)),
        MAXIMUM_BUNDLE_BYTES,
        &|point| {
            if point == BundleFaultPoint::AfterRenameBeforeCommit {
                Err(BundleFailure::FileOperation {
                    path: "fault".into(),
                    errno: 5,
                })
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();
    assert_eq!((failure.code, failure.exit_code()), ("ioFailure", 74));
    assert!(!Path::new(&destination).exists());
    assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 0);
    // The published tree moved away before the failure: cleanup cannot find
    // it under its name while its directory is still linked, so the outcome
    // is unknown and nothing is guessed at.
    let moved = root.0.join("moved");
    let failure = support_bundle::export_with(
        &options(&destination, Some(&digest_of(&destination))),
        MAXIMUM_BUNDLE_BYTES,
        &|point| {
            if point == BundleFaultPoint::AfterRenameBeforeCommit {
                std::fs::rename(Path::new("/private").join(&destination[1..]), &moved).unwrap();
                Err(BundleFailure::FileOperation {
                    path: "fault".into(),
                    errno: 5,
                })
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();
    assert_eq!((failure.code, failure.exit_code()), ("outcomeUnknown", 75));
    assert!(moved.join("bundle.json").exists());
    // A failure before publication: the staging directory is removed.
    let failure = support_bundle::export_with(
        &options(&root.path("staged"), Some(&digest_of(&root.path("staged")))),
        MAXIMUM_BUNDLE_BYTES,
        &|point| {
            if point == BundleFaultPoint::BeforePublish {
                Err(BundleFailure::InvalidInput("fault".into()))
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();
    assert_eq!((failure.code, failure.exit_code()), ("invalidInput", 65));
    let left: Vec<String> = std::fs::read_dir(&root.0)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(left, ["moved"]);
}

#[test]
fn the_cli_renders_each_answer_and_takes_only_its_own_options() {
    let root = Root::new();
    let destination = root.path("support");
    let output = cli(&[
        "runtime",
        "support-bundle",
        "preview",
        "--destination",
        &destination,
        "--output",
        "json",
        "--control-request-id",
        "ctl-sb",
    ]);
    assert_eq!(output.status.code(), Some(0));
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(arkdeck_cli::render(&envelope).unwrap(), output.stdout);
    assert_eq!(envelope["command"], "runtime.support-bundle.preview");
    assert_eq!(envelope["meta"]["controlRequestId"], "ctl-sb");
    let digest = envelope["result"]["scopeSHA256"]
        .as_str()
        .unwrap()
        .to_owned();
    let output = cli(&[
        "runtime",
        "support-bundle",
        "export",
        "--destination",
        &destination,
        "--preview-digest",
        &digest,
        "--json",
    ]);
    assert_eq!(output.status.code(), Some(0));
    let document: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(document["status"], "exported");
    let output = cli(&[
        "runtime",
        "support-bundle",
        "export",
        "--destination",
        &destination,
        "--preview-digest",
        &digest,
    ]);
    assert_eq!(output.status.code(), Some(65));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "arkdeck: the support-bundle destination already exists\n"
    );
    for argv in [
        vec!["runtime", "support-bundle", "preview"],
        vec![
            "runtime",
            "support-bundle",
            "export",
            "--destination",
            "/tmp/x",
        ],
        vec![
            "runtime",
            "support-bundle",
            "export",
            "--destination",
            "/tmp/x",
            "--preview-digest",
            "ABC",
        ],
        vec![
            "runtime",
            "support-bundle",
            "preview",
            "--destination",
            "/tmp/x",
            "--socket",
            "/tmp/s",
        ],
        vec![
            "runtime",
            "support-bundle",
            "preview",
            "--destination",
            "/tmp/x",
            "--output",
            "jsonl",
        ],
    ] {
        let output = cli(&argv);
        assert_eq!(output.status.code(), Some(64), "{argv:?}");
    }
}

/// `text` with each SHA-256 and each generation time spelled as a
/// placeholder: the digest binds a host's directory identity, and the time
/// is the export's own.
fn stable(text: &str) -> String {
    let mut output = String::new();
    let bytes = text.as_bytes();
    let mut at = 0;
    while at < bytes.len() {
        let hex = bytes.len() >= at + 64
            && bytes[at..at + 64]
                .iter()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
            && (at == 0 || !bytes[at - 1].is_ascii_hexdigit())
            && bytes
                .get(at + 64)
                .is_none_or(|byte| !byte.is_ascii_hexdigit());
        if hex {
            output.push_str("<digest>");
            at += 64;
            continue;
        }
        if text[at..].starts_with("\"generatedAt\":\"") {
            let start = at + "\"generatedAt\":\"".len();
            let end = text[start..]
                .find('"')
                .map_or(text.len(), |end| start + end);
            output.push_str("\"generatedAt\":\"<time>\"");
            at = end + 1;
            continue;
        }
        let character = text[at..].chars().next().unwrap();
        output.push(character);
        at += character.len_utf8();
    }
    output
}

/// Swift's recorded runs (`rust/tests/fixtures/support-bundle`,
/// `CLISupportBundleOracleContractTests`, whose owners are
/// `RuntimeCLI.runRuntimeSupportBundle`, `RuntimeSupportBundleApplicationFacade`
/// and `LocalDiagnosticBundle`), replayed in a private root spelled both ways:
/// the same exit status, stdout and stderr in a machine mode, the human
/// rendering held to its status (Swift's outline, this CLI's pretty JSON, T2),
/// and the same exported tree, byte for byte and mode for mode. The approved
/// digest is this preview's own; a digest and a generation time are compared
/// as such.
#[test]
fn swifts_recorded_runs_replay_through_the_cli() {
    let oracle: Value = serde_json::from_slice(
        &std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/support-bundle/cases.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let name = format!(
        "arkdeck-sb-{:016x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    );
    // The temporary directory in its standardized spelling, and the same
    // directory through `/private`.
    let private_root = std::fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(&name);
    let private_root = private_root.to_str().unwrap().to_owned();
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&private_root)
        .unwrap();
    // Foundation drops `/private` only where what remains exists.
    let root = support_bundle::standardized(&private_root);
    assert!(!root.starts_with("/private/"));
    struct Remove(String);
    impl Drop for Remove {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _remove = Remove(private_root.clone());
    let writable = format!("{private_root}/writable");
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&writable)
        .unwrap();
    std::fs::set_permissions(&writable, std::fs::Permissions::from_mode(0o770)).unwrap();
    let label = |text: &str| {
        text.replace(&private_root, "<private-root>")
            .replace(&root, "<root>")
    };
    let unlabel = |text: &str| {
        text.replace("<private-root>", &private_root)
            .replace("<root>", &root)
    };
    let mut digest: Option<String> = None;
    let mut failures = Vec::new();
    for run in oracle["runs"].as_array().unwrap() {
        let name = run["name"].as_str().unwrap();
        let argv: Vec<String> = run["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| {
                let argument = unlabel(argument.as_str().unwrap());
                match &digest {
                    // Where Swift approved its preview, approve this one.
                    Some(digest) if argument.len() == 64 && argument != "0".repeat(64) => {
                        digest.clone()
                    }
                    _ => argument,
                }
            })
            .collect();
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let output = cli(&argv);
        let stdout = label(&String::from_utf8_lossy(&output.stdout));
        let stderr = label(&String::from_utf8_lossy(&output.stderr));
        if name == "previewJson" {
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            digest = envelope["result"]["scopeSHA256"]
                .as_str()
                .map(str::to_owned);
        }
        let machine = argv.contains(&"--output") || argv.contains(&"--json");
        let same = run["exit"].as_i64() == output.status.code().map(i64::from)
            && run["stderr"] == stderr.as_str()
            && (!machine || stable(run["stdout"].as_str().unwrap()) == stable(&stdout));
        if !same {
            failures.push(format!(
                "{name}: exit {:?} stdout {stdout} stderr {stderr}",
                output.status.code()
            ));
        }
        if name == "export" {
            let mut paths = vec![String::new()];
            let base = format!("{private_root}/support");
            fn walk(base: &str, relative: &str, paths: &mut Vec<String>) {
                let directory = if relative.is_empty() {
                    base.to_owned()
                } else {
                    format!("{base}/{relative}")
                };
                for entry in std::fs::read_dir(directory).unwrap() {
                    let name = entry.unwrap().file_name().into_string().unwrap();
                    let child = if relative.is_empty() {
                        name
                    } else {
                        format!("{relative}/{name}")
                    };
                    paths.push(child.clone());
                    if std::fs::symlink_metadata(format!("{base}/{child}"))
                        .unwrap()
                        .is_dir()
                    {
                        walk(base, &child, paths);
                    }
                }
            }
            walk(&base, "", &mut paths);
            paths.sort();
            let files: Vec<Value> = paths
                .iter()
                .map(|path| {
                    let full = if path.is_empty() {
                        base.clone()
                    } else {
                        format!("{base}/{path}")
                    };
                    let metadata = std::fs::symlink_metadata(&full).unwrap();
                    let mut file = json!({"path": path, "mode": metadata.permissions().mode() & 0o7777,
                        "kind": if metadata.is_dir() { "directory" } else { "file" }});
                    if !metadata.is_dir() {
                        file["text"] =
                            json!(stable(&label(&String::from_utf8_lossy(&std::fs::read(&full).unwrap()))));
                    }
                    file
                })
                .collect();
            let expected: Vec<Value> = oracle["exportedFiles"]
                .as_array()
                .unwrap()
                .iter()
                .map(|file| {
                    let mut file = file.clone();
                    if let Some(text) = file["text"].as_str() {
                        file["text"] = json!(stable(text));
                    }
                    file
                })
                .collect();
            if files != expected {
                failures.push(format!("exported tree: {files:#?} against {expected:#?}"));
            }
        }
    }
    assert_eq!(oracle["runs"].as_array().unwrap().len(), 15);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
