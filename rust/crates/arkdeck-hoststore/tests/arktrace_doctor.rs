//! Replays the Swift ArkTrace doctor oracle (`rust/tests/fixtures/
//! arktrace-doctor`, produced by `ArkTraceDoctorOracleContractTests`) against
//! the Rust `ProductionDoctorProbe`: the same stand-in CLI compiled from
//! `fake-arktrace.c` into a bundle at the same fixed root, the same answers,
//! drifts and contract, and every verdict, every recorded launch (argument
//! zero, arguments, home) and the private home it made, as Swift's. The
//! probe spawns the stand-in at its canonical path, so this binary is its.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    DoctorContract, DoctorProbe, PinnedFile, PinnedTree, ProductionDoctorProbe, ResolvedExecutable,
};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

const ROOT: &str = "/private/tmp/arkdeck-arktrace-oracle/doctor";
const LOCK: &str = "/private/tmp/arkdeck-arktrace-oracle.lock";

fn fixture() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/arktrace-doctor")
}

fn write(path: &str, bytes: &[u8], mode: u32) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn rust_probes_the_swift_arktrace_stand_in() {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    let recorded: Value =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let app = format!("{ROOT}/ArkTraceCLI.app");
    let executable = format!("{app}/Contents/MacOS/arktrace");
    let manifest = format!("{app}/Contents/Resources/manifest.json");
    let home = format!("{ROOT}/home");
    let _ = fs::remove_dir_all(ROOT);
    for directory in [
        ROOT.to_owned(),
        app.clone(),
        format!("{app}/Contents"),
        format!("{app}/Contents/MacOS"),
        format!("{app}/Contents/Resources"),
    ] {
        fs::create_dir_all(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let compiled = Command::new("cc")
        .args(["-O0", "-o", &executable])
        .arg(fixture().join("fake-arktrace.c"))
        .output()
        .expect("cc from the developer tools compiles the stand-in");
    assert!(compiled.status.success(), "{compiled:?}");
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    let manifest_bytes = recorded["manifest"].as_str().unwrap().as_bytes().to_vec();
    write(&manifest, &manifest_bytes, 0o644);
    let executable_bytes = fs::read(&executable).unwrap();
    let executable_sha256 = arkdeck_contract::sha256_hex(&executable_bytes);
    let tree = arkdeck_platform::tree_snapshot(
        &arkdeck_hoststore::profile_path(&app, false).unwrap(),
        &app,
    )
    .unwrap()
    .sha256;
    let contract = DoctorContract {
        executable: ResolvedExecutable {
            path: executable.clone(),
            sha256: executable_sha256.clone(),
            verified_resources: vec![
                PinnedFile {
                    path: manifest.clone(),
                    sha256: arkdeck_contract::sha256_hex(&manifest_bytes),
                    byte_count: manifest_bytes.len() as u64,
                    require_executable: false,
                },
                PinnedFile {
                    path: executable.clone(),
                    sha256: executable_sha256.clone(),
                    byte_count: executable_bytes.len() as u64,
                    require_executable: true,
                },
            ],
            verified_trees: vec![PinnedTree {
                path: app.clone(),
                sha256: tree,
            }],
            canonical_namespace_root: Some(app.clone()),
        },
        product_version: "0.1.0".into(),
        timeout_seconds: 120,
        output_byte_budget: 256 * 1024,
    };
    let probe = ProductionDoctorProbe::new(Path::new(&home));

    let mut differences = Vec::new();
    for case in recorded["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let stdout = case["stdout"]
            .as_str()
            .unwrap()
            .replace("SHA", &executable_sha256);
        fs::write(format!("{ROOT}/stdout"), stdout).unwrap();
        fs::write(format!("{ROOT}/stderr"), case["stderr"].as_str().unwrap()).unwrap();
        match case["exit"].as_i64() {
            Some(code) => fs::write(format!("{ROOT}/exit"), format!("{code}\n")).unwrap(),
            None => {
                let _ = fs::remove_file(format!("{ROOT}/exit"));
            }
        }
        let _ = fs::remove_file(format!("{ROOT}/calls.log"));
        let alteration = case["alteration"].as_str();
        match alteration {
            Some("treeDrift") => write(&format!("{app}/Contents/drift.txt"), b"drift\n", 0o644),
            Some("resourceDrift") => write(&manifest, b"{\"parser\":\"drifted\"}\n", 0o644),
            Some("namespaceWritable") => {
                fs::set_permissions(&app, fs::Permissions::from_mode(0o775)).unwrap()
            }
            _ => {}
        }
        let result = probe.probe(&contract);
        match alteration {
            Some("treeDrift") => fs::remove_file(format!("{app}/Contents/drift.txt")).unwrap(),
            Some("resourceDrift") => write(&manifest, &manifest_bytes, 0o644),
            Some("namespaceWritable") => {
                fs::set_permissions(&app, fs::Permissions::from_mode(0o755)).unwrap()
            }
            _ => {}
        }
        let calls: Vec<Value> = fs::read_to_string(format!("{ROOT}/calls.log"))
            .unwrap_or_default()
            .lines()
            .map(|line| json!(line.replace(&executable_sha256, "SHA")))
            .collect();
        let actual = json!({"result": result, "calls": calls});
        let expected = json!({"result": case["result"], "calls": case["calls"]});
        if actual != expected {
            differences.push(format!("{name}:\n  swift {expected}\n  rust  {actual}"));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    let mut entries: Vec<String> = Vec::new();
    for directory in ["Library", "Library/Application Support", "Library/Caches"] {
        entries.push(directory.to_owned());
    }
    let home_tree: Vec<Value> = entries
        .iter()
        .map(|path| {
            let metadata = fs::symlink_metadata(format!("{home}/{path}")).unwrap();
            json!({"path": path, "kind": if metadata.is_dir() { "directory" } else { "other" },
                "mode": format!("{:o}", metadata.permissions().mode() & 0o7777)})
        })
        .collect();
    assert_eq!(Value::Array(home_tree), recorded["home"]);
    assert_eq!(
        fs::read_dir(&home).unwrap().count(),
        1,
        "the home holds only Library"
    );
    fs::remove_dir_all(ROOT).unwrap();
}
