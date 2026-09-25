//! `arkdeck maintainer contracts export|check`, as Swift's
//! `runMaintainerContracts` answers them: the export writes the bundle this
//! build renders, and the check holds a bundle to it, one document either way.
use arkdeck_cli::machine_contracts::{contract_products, fixture_products};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A fresh directory for one test, removed when it ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-contracts-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn contracts(&self) -> PathBuf {
        self.0.join("contracts")
    }
    fn fixtures(&self) -> PathBuf {
        self.0.join("fixtures")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn arkdeck(arguments: &[&str], directory: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
    command.args(arguments);
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    command.output().unwrap()
}

fn run(verb: &str, scratch: &Scratch, json: bool) -> Output {
    let contracts = scratch.contracts();
    let fixtures = scratch.fixtures();
    let mut arguments = vec![
        "maintainer",
        "contracts",
        verb,
        "--contracts-directory",
        contracts.to_str().unwrap(),
        "--fixtures-directory",
        fixtures.to_str().unwrap(),
    ];
    if json {
        arguments.extend(["--output", "json"]);
    }
    arkdeck(&arguments, None)
}

fn envelope(output: &Output) -> Value {
    let text = String::from_utf8(output.stdout.clone()).unwrap();
    assert_eq!(text.matches('\n').count(), 1, "one document: {text}");
    serde_json::from_str(&text).unwrap()
}

#[test]
fn the_export_writes_the_bundle_this_build_renders() {
    let scratch = Scratch::new("export");
    let output = run("export", &scratch, true);
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    assert!(output.stderr.is_empty());
    let answer = envelope(&output);
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["command"], "maintainer.contracts.export");
    let meta = answer["meta"].as_object().unwrap();
    assert_eq!(
        meta.keys().collect::<Vec<_>>(),
        ["cliVersion", "controlProtocolVersion", "controlRequestId"]
    );
    let result = &answer["result"];
    assert_eq!(result["bundleVersion"], "arkdeck.cli.contracts/1");
    assert_eq!(result["removed"], json!([]));
    let mut written = Vec::new();
    for product in contract_products() {
        let file = scratch.contracts().join(&product.relative_path);
        assert_eq!(std::fs::read(&file).unwrap(), product.bytes, "{file:?}");
        written.push(format!("contracts/{}", product.relative_path));
    }
    for product in fixture_products() {
        let file = scratch.fixtures().join(&product.relative_path);
        assert_eq!(std::fs::read(&file).unwrap(), product.bytes, "{file:?}");
        written.push(format!("fixtures/{}", product.relative_path));
    }
    assert_eq!(result["written"], json!(written));
    assert_eq!(written.len(), 235);
    // The atomic writes leave nothing beside the products.
    let check = run("check", &scratch, true);
    assert_eq!(check.status.code(), Some(0), "{check:?}");
    let report = &envelope(&check)["result"];
    assert_eq!(report["clean"], true);
    assert_eq!(report["checked"], 235);
    assert_eq!(report["unexpected"], json!([]));
}

#[test]
fn a_drifted_bundle_is_reported_then_fails_without_a_second_document() {
    let scratch = Scratch::new("drift");
    assert_eq!(run("export", &scratch, true).status.code(), Some(0));
    std::fs::write(scratch.fixtures().join("argv/job.status.json"), b"{}\n").unwrap();
    std::fs::remove_file(scratch.contracts().join("cli-page.schema.json")).unwrap();
    std::fs::write(scratch.fixtures().join("argv/zz-stray.json"), b"{}\n").unwrap();
    std::fs::create_dir_all(scratch.fixtures().join("nested")).unwrap();
    std::fs::write(scratch.fixtures().join("nested/stray.txt"), b"x").unwrap();
    // Hidden files are not the bundle's, as Foundation's enumerator skips them.
    std::fs::write(scratch.fixtures().join(".DS_Store"), b"x").unwrap();
    std::fs::create_dir_all(scratch.fixtures().join(".cache")).unwrap();
    std::fs::write(scratch.fixtures().join(".cache/stray.json"), b"x").unwrap();
    let output = run("check", &scratch, true);
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let answer = envelope(&output);
    assert_eq!(answer["ok"], true);
    let report = &answer["result"];
    assert_eq!(report["clean"], false);
    assert_eq!(report["checked"], 235);
    assert_eq!(report["drifted"], json!(["fixtures/argv/job.status.json"]));
    assert_eq!(report["missing"], json!(["contracts/cli-page.schema.json"]));
    assert_eq!(
        report["unexpected"],
        json!(["fixtures/argv/zz-stray.json", "fixtures/nested/stray.txt"])
    );
    assert_eq!(
        String::from_utf8(output.stderr).unwrap(),
        "arkdeck: the published machine contracts drifted from this build; run `arkdeck maintainer contracts export`\n"
    );
    // The export puts it right: the stray visible files go, the hidden stay.
    let export = run("export", &scratch, true);
    assert_eq!(export.status.code(), Some(0));
    assert_eq!(
        envelope(&export)["result"]["removed"],
        json!(["fixtures/argv/zz-stray.json", "fixtures/nested/stray.txt"])
    );
    assert!(scratch.fixtures().join(".DS_Store").exists());
    assert!(scratch.fixtures().join(".cache/stray.json").exists());
    assert_eq!(run("check", &scratch, true).status.code(), Some(0));
}

#[test]
fn the_human_rendering_is_swifts() {
    let scratch = Scratch::new("human");
    assert_eq!(run("export", &scratch, false).status.code(), Some(0));
    let output = run("check", &scratch, false);
    assert_eq!(output.status.code(), Some(0));
    let contracts =
        arkdeck_cli::maintainer_contracts::standardized(scratch.contracts().to_str().unwrap());
    let fixtures =
        arkdeck_cli::maintainer_contracts::standardized(scratch.fixtures().to_str().unwrap());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        format!(
            "bundleVersion: arkdeck.cli.contracts/1\nchecked: 235\nclean: true\ncontractsDirectory: {}\ndrifted: (none)\nfixturesDirectory: {}\nmissing: (none)\nunexpected: (none)\n",
            contracts.display(),
            fixtures.display()
        )
    );
    std::fs::write(scratch.fixtures().join("argv/job.status.json"), b"{}\n").unwrap();
    std::fs::write(scratch.fixtures().join("argv/job.show.json"), b"{}\n").unwrap();
    let output = run("check", &scratch, false);
    assert_eq!(output.status.code(), Some(1));
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(
        text.contains(
            "\ndrifted: - fixtures/argv/job.show.json\n  - fixtures/argv/job.status.json\n"
        ),
        "{text}"
    );
}

#[test]
fn a_directory_is_named_as_swifts_url_standardizes_it() {
    let scratch = Scratch::new("paths");
    let export = || {
        let output = arkdeck(
            &[
                "maintainer",
                "contracts",
                "export",
                "--contracts-directory",
                "./a/../contracts/.",
                "--fixtures-directory",
                "fixtures",
                "--output",
                "json",
            ],
            Some(&scratch.0),
        );
        assert_eq!(output.status.code(), Some(0), "{output:?}");
        envelope(&output)["result"].clone()
    };
    // Relative to the working directory, which is the physical one on Unix
    // and the one set on Windows, with `.` and `..` resolved by name.
    let physical = if cfg!(windows) {
        scratch.0.clone()
    } else {
        std::fs::canonicalize(&scratch.0).unwrap()
    };
    let first = export();
    assert!(scratch.contracts().join("cli-result.schema.json").is_file());
    // Foundation drops a leading `/private` only where what remains exists
    // (macOS): the directories did not, when the first export named them.
    assert_eq!(
        first["contractsDirectory"],
        json!(physical.join("contracts"))
    );
    assert_eq!(first["fixturesDirectory"], json!(physical.join("fixtures")));
    let second = export();
    let named = match physical.strip_prefix("/private") {
        Ok(rest) if cfg!(target_os = "macos") => Path::new("/").join(rest),
        _ => physical.clone(),
    };
    assert_eq!(second["contractsDirectory"], json!(named.join("contracts")));
    assert_eq!(second["fixturesDirectory"], json!(named.join("fixtures")));
    if cfg!(target_os = "macos") {
        assert_eq!(
            arkdeck_cli::maintainer_contracts::standardized("/private"),
            PathBuf::from("/private")
        );
    }
}

/// The published inputs' contract view compiles the merge base's contract
/// into this tree's code; the checkout and candidate views carry this
/// checkout's.
fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// In a checkout, the committed bundle is the one this build exports. A
/// contract view carries only part of it, so there this waits for the
/// checkout.
#[test]
fn the_committed_bundle_checks_clean() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let contracts = repository.join("openspec/contracts");
    let fixtures = repository.join("Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI");
    if published_view() || !contracts.join("cli-command-registry.yaml").is_file() {
        return;
    }
    let output = arkdeck(
        &[
            "maintainer",
            "contracts",
            "check",
            "--contracts-directory",
            contracts.to_str().unwrap(),
            "--fixtures-directory",
            fixtures.to_str().unwrap(),
            "--output",
            "json",
        ],
        None,
    );
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let report = &envelope(&output)["result"];
    assert_eq!(report["clean"], true);
    assert_eq!(report["checked"], 235);
}

#[test]
fn an_unwritable_bundle_is_an_io_failure_in_one_document() {
    let scratch = Scratch::new("io");
    // A file where the contracts directory should be.
    std::fs::write(scratch.contracts(), b"not a directory").unwrap();
    let output = run("export", &scratch, true);
    assert_eq!(output.status.code(), Some(74), "{output:?}");
    let answer = envelope(&output);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"]["code"], "ioFailure");
    assert!(
        answer["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("the contract bundle could not be written or read: ")
    );
    assert!(answer["meta"]["controlProtocolVersion"].is_string());
    let human = run("export", &scratch, false);
    assert_eq!(human.status.code(), Some(74));
    assert!(human.stdout.is_empty());
    assert!(
        String::from_utf8(human.stderr)
            .unwrap()
            .starts_with("arkdeck: the contract bundle could not be written or read: ")
    );
}

/// Neither leaf connects, so each refuses the Runtime's options in the words
/// of Swift's parser, before anything is written.
#[test]
fn the_leaves_refuse_a_runtime_endpoint_and_correlation() {
    for (option, value) in [("--socket", "/tmp/s"), ("--control-request-id", "ctl-1")] {
        for verb in ["export", "check"] {
            let argv: Vec<String> = [
                "maintainer",
                "contracts",
                verb,
                "--contracts-directory",
                "/tmp/c",
                "--fixtures-directory",
                "/tmp/f",
                option,
                value,
            ]
            .map(str::to_owned)
            .to_vec();
            let error = arkdeck_cli::parse(&argv).unwrap_err();
            let command = format!("maintainer.contracts.{verb}");
            if option == "--socket" && !cfg!(target_os = "macos") {
                assert_eq!(error.code, "unsupportedOnPlatform", "{argv:?}");
                continue;
            }
            assert_eq!(
                (error.code, error.command, error.message.as_str()),
                (
                    "invalidOption",
                    Some(command.as_str()),
                    format!(
                        "`maintainer contracts {verb}` does not accept {option}; run `arkdeck help maintainer contracts {verb}` for its options"
                    )
                    .as_str()
                ),
                "{argv:?}"
            );
        }
    }
}

/// One setup step of a recorded case (`record-maintainer-contracts-oracle.py`):
/// `export` is this CLI's own, as the recording's was Swift's.
#[cfg(unix)]
fn set_up(root: &Path, step: &Value) {
    let path = root.join(step["path"].as_str().unwrap_or_default());
    match step["op"].as_str().unwrap() {
        "export" => {
            let contracts = root.join("contracts");
            let fixtures = root.join("fixtures");
            let output = arkdeck(
                &[
                    "maintainer",
                    "contracts",
                    "export",
                    "--contracts-directory",
                    contracts.to_str().unwrap(),
                    "--fixtures-directory",
                    fixtures.to_str().unwrap(),
                ],
                None,
            );
            assert_eq!(output.status.code(), Some(0), "{output:?}");
        }
        "write" => {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, step["text"].as_str().unwrap()).unwrap();
        }
        "remove" => std::fs::remove_file(&path).unwrap(),
        "symlink" => {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::os::unix::fs::symlink(step["target"].as_str().unwrap(), &path).unwrap();
        }
        other => panic!("unknown setup step {other}"),
    }
}

/// Every entry below `root`, by `lstat`, as the recorder lists it: a file's
/// digest, a link's target, a directory as such.
#[cfg(unix)]
fn tree(root: &Path) -> Vec<Value> {
    fn walk(root: &Path, directory: &Path, entries: &mut Vec<Value>) {
        for entry in std::fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            let kind = std::fs::symlink_metadata(&path).unwrap().file_type();
            if kind.is_symlink() {
                let target = std::fs::read_link(&path).unwrap();
                entries.push(json!({"path": relative, "symlink": target}));
            } else if kind.is_dir() {
                entries.push(json!({"path": relative, "directory": true}));
                walk(root, &path, entries);
            } else {
                let bytes = std::fs::read(&path).unwrap();
                entries.push(
                    json!({"path": relative, "sha256": arkdeck_contract::sha256_hex(&bytes)}),
                );
            }
        }
    }
    let mut entries = Vec::new();
    walk(root, root, &mut entries);
    entries.sort_by(|left, right| left["path"].as_str().cmp(&right["path"].as_str()));
    entries
}

/// The recorder's normalization: the case's root, and the random control
/// request identity.
#[cfg(unix)]
fn normalized(bytes: &[u8], root: &str) -> String {
    let text = String::from_utf8(bytes.to_vec())
        .unwrap()
        .replace(root, "<root>");
    let key = "\"controlRequestId\":\"";
    match text.find(key) {
        Some(start) => {
            let value = start + key.len();
            let end = value + text[value..].find('"').unwrap();
            format!("{}<controlRequestId>{}", &text[..value], &text[end..])
        }
        None => text,
    }
}

/// What Swift's CLI answered in each recorded case, this CLI answers byte for
/// byte, and it leaves the same tree behind.
#[cfg(unix)]
#[test]
fn swifts_recorded_answers_replay() {
    let oracle: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/maintainer-contracts/oracle.json"
    ))
    .unwrap();
    let cases = oracle["cases"].as_array().unwrap();
    assert!(cases.len() >= 10, "{} cases", cases.len());
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let scratch = Scratch::new("oracle");
        // As Foundation names it, so the answer names the same root.
        let root = arkdeck_cli::maintainer_contracts::standardized(scratch.0.to_str().unwrap());
        for step in case["setup"].as_array().unwrap() {
            set_up(&root, step);
        }
        let contracts = root.join(case["contractsDirectory"].as_str().unwrap());
        let fixtures = root.join(case["fixturesDirectory"].as_str().unwrap());
        let mut arguments = vec![
            "maintainer",
            "contracts",
            case["verb"].as_str().unwrap(),
            "--contracts-directory",
            contracts.to_str().unwrap(),
            "--fixtures-directory",
            fixtures.to_str().unwrap(),
        ];
        if case["mode"] == "json" {
            arguments.extend(["--output", "json"]);
        }
        let output = arkdeck(&arguments, None);
        let root_text = root.to_str().unwrap();
        assert_eq!(
            json!(output.status.code()),
            case["exitCode"],
            "{name}: {output:?}"
        );
        assert_eq!(
            json!(normalized(&output.stdout, root_text)),
            case["stdout"],
            "{name}"
        );
        assert_eq!(
            json!(normalized(&output.stderr, root_text)),
            case["stderr"],
            "{name}"
        );
        if case["verb"] == "export" {
            assert_eq!(json!(tree(&root)), case["tree"], "{name}");
        }
    }
}

/// An export deletes only what `lstat` calls a regular, visible file under
/// the fixtures directory: never a link, never through one.
#[cfg(unix)]
#[test]
fn an_export_never_deletes_a_link_or_through_one() {
    let scratch = Scratch::new("links");
    let outside = scratch.0.join("outside");
    std::fs::create_dir_all(outside.join("directory")).unwrap();
    std::fs::write(outside.join("file.txt"), b"outside\n").unwrap();
    std::fs::write(outside.join("directory/inner.json"), b"{}\n").unwrap();
    std::fs::create_dir_all(scratch.fixtures()).unwrap();
    std::os::unix::fs::symlink(
        "../outside/file.txt",
        scratch.fixtures().join("link-to-file"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        "../outside/directory",
        scratch.fixtures().join("link-to-directory"),
    )
    .unwrap();
    let output = run("export", &scratch, true);
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    assert_eq!(envelope(&output)["result"]["removed"], json!([]));
    for link in ["link-to-file", "link-to-directory"] {
        let path = scratch.fixtures().join(link);
        assert!(
            std::fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
    assert_eq!(
        std::fs::read(outside.join("file.txt")).unwrap(),
        b"outside\n"
    );
    assert_eq!(
        std::fs::read(outside.join("directory/inner.json")).unwrap(),
        b"{}\n"
    );
}
