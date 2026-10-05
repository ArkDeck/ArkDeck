//! HDC registration on Windows (TASK-XPA-012, CHG-2026-078): the Bootstrap
//! tool owner captures `hdc.exe` into a private store on NTFS and admits it
//! only when a registered Windows HDC tuple names its executable.
//!
//! The tests' `hdc.exe` is no registered Windows tuple (`WINDOWS_HDC_TUPLES`
//! holds DevEco's `hdc.exe` only, CHG-2026-078), so a store
//! as the daemon composes it today refuses every `hdc.exe`, writing nothing.
//! The admitted path is exercised with an identity injected for a copy of a
//! `System32` program standing in for `hdc.exe`: a fixture identity, never a
//! registered one, and nothing is ever run.
#![cfg(windows)]

use arkdeck_bootstrap::ToolRegistryStore;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

const NOW: &str = "2026-10-01T00:00:00Z";

struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> Self {
        let base = arkdeck_platform::application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let base = base.to_str().unwrap();
        let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-test-{label}-{:032x}",
            u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
        ));
        arkdeck_platform::create_private_directory(&path).unwrap();
        Self(arkdeck_platform::host_resolved_path(&path).unwrap())
    }
    fn directory(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        arkdeck_platform::create_private_directory(&path).unwrap();
        path
    }
    fn file(&self, relative: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(relative);
        let _ = std::fs::remove_file(&path);
        arkdeck_platform::create_private_file(&path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn system(name: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(std::env::var_os("SystemRoot").unwrap())
            .join("System32")
            .join(name),
    )
    .unwrap()
}

fn names(path: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(path)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn fixture_identity() -> Value {
    json!({"version": "fixture", "profileReferences": []})
}

#[test]
fn with_no_registered_windows_tuple_every_hdc_is_refused_writing_nothing() {
    let scratch = Scratch::new("hdc-unregistered");
    scratch.directory("sdk");
    let hdc = scratch.file(r"sdk\hdc.exe", &system("whoami.exe"));
    let store_path = scratch.directory("bootstrap");
    // A store whose composer gave it no identities, and one whose identities
    // name no tuple for this `hdc.exe`, as the daemon's composition of
    // `WINDOWS_HDC_TUPLES` (DevEco's `hdc.exe` only) names none for it
    // (`windows_bootstrap_owners_process.rs` refuses through the daemon).
    for store in [
        ToolRegistryStore::open_existing(&store_path).unwrap(),
        ToolRegistryStore::open_existing(&store_path)
            .unwrap()
            .with_published_identities(Arc::new(|_: &str| None)),
    ] {
        let error = store.register(&hdc, NOW).unwrap_err();
        assert_eq!(error.code, "admissionDenied", "{error:?}");
        assert!(error.message.contains("CHG-2026-078"), "{}", error.message);
        assert_eq!(
            error.details.as_ref().unwrap()["newDispatchCount"],
            json!(0)
        );
        // Refused before the store was locked: not even the lock exists.
        assert!(names(&store_path).is_empty(), "{:?}", names(&store_path));
    }
    assert_eq!(std::fs::read(&hdc).unwrap(), system("whoami.exe"));
}

#[test]
fn the_captured_bytes_are_checked_again_and_a_refusal_retains_nothing() {
    let scratch = Scratch::new("hdc-recheck");
    scratch.directory("sdk");
    let hdc = scratch.file(r"sdk\hdc.exe", &system("whoami.exe"));
    let store_path = scratch.directory("bootstrap");
    // Admitted when the source is first read, not when the captured copy is
    // checked: the second check refuses, and nothing is published.
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    let store = ToolRegistryStore::open_existing(&store_path)
        .unwrap()
        .with_published_identities(Arc::new(move |_: &str| {
            (counted.fetch_add(1, Ordering::SeqCst) == 0).then(fixture_identity)
        }));
    let error = store.register(&hdc, NOW).unwrap_err();
    assert_eq!(error.code, "admissionDenied", "{error:?}");
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    // Only the store's lock and its two empty indexes: no retained content
    // and no staging copy.
    assert_eq!(names(&store_path), [".lock", "bundles.json", "tools.json"]);
    assert!(store.list().unwrap().is_empty());
}

#[test]
fn a_tuple_named_hdc_registers_inspects_lists_and_retires() {
    let scratch = Scratch::new("hdc-registered");
    scratch.directory("sdk");
    let bytes = system("whoami.exe");
    let hdc = scratch.file(r"sdk\hdc.exe", &bytes);
    // A sibling DLL the program does not import is not captured.
    scratch.file(r"sdk\libusb_shared.dll", &system("version.dll"));
    let store_path = scratch.directory("bootstrap");
    let expected = arkdeck_contract::sha256_hex(&bytes);
    let store = ToolRegistryStore::open_existing(&store_path)
        .unwrap()
        .with_published_identities(Arc::new(move |sha256: &str| {
            (sha256 == expected).then(fixture_identity)
        }));

    let receipt = store.register(&hdc, NOW).unwrap();
    let reference = receipt["toolRef"].as_str().unwrap().to_owned();
    assert!(reference.starts_with("tool:sha256:"), "{receipt}");
    assert_eq!(receipt["platform"], "windows");
    assert_eq!(receipt["kind"], "hdc");
    assert_eq!(receipt["state"], "available");
    assert_eq!(receipt["generation"], "1");
    assert_eq!(receipt["selected"], false);
    assert_eq!(receipt["relocatable"], true);
    assert_eq!(receipt["dependencies"], json!([]));
    assert_eq!(
        receipt["executableSHA256"],
        arkdeck_contract::sha256_hex(&bytes)
    );
    assert_eq!(receipt["trust"]["registeredIdentity"], true);
    assert_eq!(receipt["trust"]["toolVersion"], "fixture");
    assert_eq!(receipt["trust"]["executionAssessment"], "notPerformed");
    for method in ["runtime.tool.register", "runtime.tool.inspect"] {
        arkdeck_contract::validate_method_value(method, "result", &receipt)
            .unwrap_or_else(|error| panic!("{method}: {error:?}"));
    }
    let digest = reference.trim_start_matches("tool:sha256:");
    let retained = store_path.join(format!("tool-{digest}.hdc"));
    assert_eq!(names(&retained), ["hdc.exe"]);
    let index = std::fs::read(store_path.join("tools.json")).unwrap();
    let document: Value = serde_json::from_slice(&index).unwrap();
    assert_eq!(document["records"][0]["platform"], "windows");

    // The same content again is the same receipt and writes nothing.
    assert_eq!(store.register(&hdc, NOW).unwrap(), receipt);
    assert_eq!(std::fs::read(store_path.join("tools.json")).unwrap(), index);
    assert_eq!(store.inspect(&reference).unwrap(), receipt);
    assert_eq!(store.list().unwrap(), vec![receipt.clone()]);
    // The same store read back without the identity: the row stays, with no
    // registered identity.
    let reopened = ToolRegistryStore::open_existing(&store_path).unwrap();
    assert_eq!(
        reopened.inspect(&reference).unwrap()["trust"]["registeredIdentity"],
        false
    );

    // Refusals, before anything is written.
    for path in [
        Path::new(r"relative\hdc.exe"),
        Path::new("/usr/local/bin/hdc"),
        &scratch.0.join(r"sdk\..\sdk\hdc.exe"),
    ] {
        assert_eq!(
            store.register(path, NOW).unwrap_err().code,
            "invalidInput",
            "{}",
            path.display()
        );
    }
    // Another program is not the tuple's.
    let other = scratch.file(r"sdk\other.exe", &system("hostname.exe"));
    assert_eq!(
        store.register(&other, NOW).unwrap_err().code,
        "admissionDenied"
    );
    assert_eq!(std::fs::read(store_path.join("tools.json")).unwrap(), index);
    assert_eq!(
        names(&store_path),
        [
            ".lock".to_owned(),
            "bundles.json".to_owned(),
            format!("tool-{digest}.hdc"),
            "tools.json".to_owned()
        ]
    );
    assert_eq!(std::fs::read(&hdc).unwrap(), bytes);

    // Retirement: metadata only, once; the content stays retained.
    let retired = store.retire(&reference, "1").unwrap();
    assert_eq!(retired["state"], "removed");
    assert_eq!(retired["generation"], "2");
    assert_eq!(store.retire(&reference, "1").unwrap(), retired);
    assert!(retained.join("hdc.exe").is_file());
    assert_eq!(
        store.register(&hdc, NOW).unwrap_err().code,
        "resourceConflict"
    );

    // A retained copy that changed no longer verifies.
    std::fs::OpenOptions::new()
        .append(true)
        .open(retained.join("hdc.exe"))
        .unwrap()
        .write_all(b"tampered")
        .unwrap();
    assert!(store.inspect(&reference).is_err());
}

/// The selection ledger over the Windows store (TASK-XPA-012): a configured
/// `hdc.exe` a tuple names is adopted as the first selection, the startup
/// selection names the retained `hdc.exe`, a second registered tool is a
/// selection candidate and is prepared, failed and acknowledged as on macOS,
/// and an `hdc.exe` no tuple names is never adopted.
#[test]
fn a_tuple_named_hdc_is_adopted_selected_and_replaced_only_by_another() {
    let scratch = Scratch::new("hdc-selection");
    scratch.directory("first");
    scratch.directory("second");
    let first_bytes = system("whoami.exe");
    let second_bytes = system("hostname.exe");
    let first = scratch.file(r"first\hdc.exe", &first_bytes);
    let second = scratch.file(r"second\hdc.exe", &second_bytes);
    let other = scratch.file(r"first\other.exe", &system("where.exe"));
    let store_path = scratch.directory("bootstrap");
    let named = [
        arkdeck_contract::sha256_hex(&first_bytes),
        arkdeck_contract::sha256_hex(&second_bytes),
    ];
    let store = ToolRegistryStore::open_existing(&store_path)
        .unwrap()
        .with_published_identities(Arc::new(move |sha256: &str| {
            named.contains(&sha256.to_owned()).then(fixture_identity)
        }));

    // No selection, and an executable no tuple names: refused, unselected.
    assert_eq!(store.startup_selection().unwrap(), None);
    assert_eq!(
        store.adopt_installed_hdc(&other, NOW).unwrap_err().code,
        "admissionDenied"
    );
    assert_eq!(store.startup_selection().unwrap(), None);

    // The configured `hdc.exe` is registered and adopted as the first
    // selection; its startup executable is the retained `hdc.exe`.
    let adopted = store.adopt_installed_hdc(&first, NOW).unwrap();
    let selection = store.startup_selection().unwrap().unwrap();
    assert_eq!(selection.active_generation, 1);
    assert_eq!(selection.pending_action_id, None);
    assert_eq!(
        selection.executable_sha256,
        arkdeck_contract::sha256_hex(&first_bytes)
    );
    let digest = selection
        .tool_ref
        .trim_start_matches("tool:sha256:")
        .to_owned();
    assert_eq!(
        selection.executable,
        store_path
            .join(format!("tool-{digest}.hdc"))
            .join("hdc.exe")
    );
    assert_eq!(std::fs::read(&selection.executable).unwrap(), first_bytes);
    assert_eq!(adopted.active_tool["toolRef"], selection.tool_ref.as_str());
    assert_eq!(adopted.active_tool["platform"], "windows");
    // Once a selection exists, another configured file never replaces it.
    store.adopt_installed_hdc(&second, NOW).unwrap();
    assert_eq!(store.startup_selection().unwrap().unwrap(), selection);
    let second_ref = store
        .list()
        .unwrap()
        .into_iter()
        .find(|row| row["executableSHA256"] == arkdeck_contract::sha256_hex(&second_bytes))
        .unwrap()["toolRef"]
        .as_str()
        .unwrap()
        .to_owned();

    // The active tool is no candidate; the second is, and is prepared,
    // failed and acknowledged back to the first.
    assert_eq!(
        store
            .selection_candidate(&selection.tool_ref, "1", None)
            .unwrap_err()
            .code,
        "resourceConflict"
    );
    let candidate = store.selection_candidate(&second_ref, "1", None).unwrap();
    assert_eq!(candidate.new_tool["platform"], "windows");
    assert_eq!(candidate.new_tool["trust"]["registeredIdentity"], true);
    let action = "control-action-5f0c1a52-0b4e-4c8a-9d2e-2b7f3c6a9e10";
    store.prepare_selection(action, &second_ref, "1").unwrap();
    let pending = store.startup_selection().unwrap().unwrap();
    assert_eq!(pending.pending_action_id.as_deref(), Some(action));
    assert_eq!(pending.tool_ref, second_ref);
    assert!(pending.executable.ends_with("hdc.exe"));
    store
        .fail_pending_selection(action, "tool.selectedStartupVerificationFailed")
        .unwrap();
    store.acknowledge_selection_outcome(action).unwrap();
    assert_eq!(store.startup_selection().unwrap().unwrap(), selection);
}
