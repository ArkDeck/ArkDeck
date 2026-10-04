//! A daemon Bundle on Windows (TASK-XPA-012): a release-candidate package
//! tree, registered, inspected, listed and retired by the Bootstrap bundle
//! owner over a private store on NTFS.
//!
//! The fixture tree is laid out as `windows/scripts/package-rc.ps1` lays one
//! out: `arkdeck-agentd.exe`, `bin\arkdeck.exe`, `ArkDeck.exe` and
//! `rc-manifest.json` naming every other file with its size and SHA-256. The
//! daemon image is a copy of a `System32` executable signed by the
//! host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//! `rust/scripts/check-readonly.py` signs one); the store's policy pins it to
//! another copy signed the same way, standing in for the running Runtime's
//! own image. Without the signer this test says so and checks nothing.
#![cfg(windows)]

use arkdeck_bootstrap::BundleRegistryReadStore;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;

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
        Self(path)
    }
    fn file(&self, relative: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(relative);
        let mut ancestor = self.0.clone();
        for part in Path::new(relative)
            .parent()
            .into_iter()
            .flat_map(Path::iter)
        {
            ancestor.push(part);
            if !ancestor.exists() {
                arkdeck_platform::create_private_directory(&ancestor).unwrap();
            }
        }
        let _ = std::fs::remove_file(&path);
        arkdeck_platform::create_private_file(&path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
        path
    }
    fn system(&self, relative: &str, system: &str) -> PathBuf {
        let bytes = std::fs::read(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(system),
        )
        .unwrap();
        self.file(relative, &bytes)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn pwsh() -> PathBuf {
    if let Some(found) = std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|directory| directory.join("pwsh.exe"))
            .find(|candidate| candidate.exists())
    }) {
        return found;
    }
    PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
        .join(r"Microsoft\WindowsApps\pwsh.exe")
}

fn sign(thumbprint: &str, path: &Path) {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let output = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(thumbprint)
        .arg("-Path")
        .arg(path)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
}

/// A package tree at `<scratch>\<name>` whose manifest names its files.
fn package(scratch: &Scratch, name: &str, daemon: &Path) -> PathBuf {
    let root = scratch.0.join(name);
    let daemon_bytes = std::fs::read(daemon).unwrap();
    scratch.file(&format!(r"{name}\arkdeck-agentd.exe"), &daemon_bytes);
    scratch.system(&format!(r"{name}\bin\arkdeck.exe"), "whoami.exe");
    scratch.file(&format!(r"{name}\ArkDeck.exe"), b"fixture App; never run\n");
    manifest(scratch, name);
    root
}

/// `rc-manifest.json` naming every other file of the tree as it is now.
fn manifest(scratch: &Scratch, name: &str) {
    let root = scratch.0.join(name);
    let mut files = Vec::new();
    for relative in ["ArkDeck.exe", "arkdeck-agentd.exe", "bin/arkdeck.exe"] {
        let bytes = std::fs::read(root.join(relative.replace('/', "\\"))).unwrap();
        files.push(json!({"path": relative, "bytes": bytes.len(),
            "sha256": arkdeck_contract::sha256_hex(&bytes)}));
    }
    let document = json!({"schemaVersion": "arkdeck.windows-rc-package/1",
        "kind": "windows-rc-app-daemon-cli", "version": "0.1.0", "files": files});
    scratch.file(
        &format!(r"{name}\rc-manifest.json"),
        &serde_json::to_vec_pretty(&document).unwrap(),
    );
}

#[test]
fn a_release_candidate_package_registers_inspects_lists_and_retires() {
    let Some(thumbprint) = std::env::var("ARKDECK_DEV_SIGNER_THUMBPRINT")
        .ok()
        .filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the package's daemon; nothing was checked"
        );
        return;
    };
    let scratch = Scratch::new("bundle-windows");
    // The running Runtime's image, and a daemon signed as it is.
    let reference = scratch.system(r"runtime\arkdeck-agentd.exe", "hostname.exe");
    sign(&thumbprint, &reference);
    let daemon = scratch.system(r"built\arkdeck-agentd.exe", "hostname.exe");
    sign(&thumbprint, &daemon);
    let unsigned = scratch.system(r"built\unsigned.exe", "hostname.exe");
    let store_path = scratch.0.join("bootstrap");
    arkdeck_platform::create_private_directory(&store_path).unwrap();
    let pinned = reference.clone();
    let store = BundleRegistryReadStore::open_existing(&store_path)
        .unwrap()
        .with_bundle_validator(Arc::new(move |path: &Path| {
            arkdeck_platform::same_signer(&path.join("arkdeck-agentd.exe"), &pinned)?;
            Ok(path.to_path_buf())
        }));

    let source = package(&scratch, "package", &daemon);
    let receipt = store.register(&source, NOW).unwrap();
    let reference_text = receipt["bundleRef"].as_str().unwrap().to_owned();
    assert!(reference_text.starts_with("bundle:sha256:"), "{receipt}");
    assert_eq!(receipt["platform"], "windows");
    assert_eq!(receipt["kind"], "daemon-bundle");
    assert_eq!(receipt["version"], "0.1.0");
    assert_eq!(receipt["state"], "available");
    assert_eq!(receipt["generation"], "1");
    assert_eq!(receipt["contentRetained"], true);
    assert_eq!(
        receipt["trust"]["policy"],
        "arkdeck.windows-daemon-package/1"
    );
    assert_eq!(receipt["trust"]["signature"], "verified");
    assert_eq!(
        receipt["trust"]["teamIdentifier"],
        "ArkDeck Development Daemon (host-trusted only)"
    );
    assert_eq!(receipt["entryCount"], "6", "root, bin and four files");
    for method in ["runtime.bundle.register", "runtime.bundle.inspect"] {
        arkdeck_contract::validate_method_value(method, "result", &receipt)
            .unwrap_or_else(|error| panic!("{method}: {error:?}"));
    }
    let digest = reference_text.trim_start_matches("bundle:sha256:");
    assert!(store_path.join(format!("bundle-{digest}.rc")).is_dir());
    let index = std::fs::read(store_path.join("bundles.json")).unwrap();
    let document: Value = serde_json::from_slice(&index).unwrap();
    assert_eq!(document["records"][0]["platform"], "windows");

    // The same content again is the same receipt and writes nothing.
    assert_eq!(store.register(&source, NOW).unwrap(), receipt);
    assert_eq!(
        std::fs::read(store_path.join("bundles.json")).unwrap(),
        index
    );
    assert_eq!(store.inspect(&reference_text).unwrap(), receipt);
    assert_eq!(store.list().unwrap(), vec![receipt.clone()]);

    // The source may change afterwards: the retained copy is what counts.
    scratch.file(r"package\ArkDeck.exe", b"another App\n");
    assert_eq!(store.inspect(&reference_text).unwrap(), receipt);

    // Refusals, before anything is written.
    let refused = |path: &Path| store.register(path, NOW).unwrap_err().code;
    // The tree no longer matches its manifest.
    assert_eq!(refused(&source), "fileIdentityChanged");
    manifest(&scratch, "package");
    // A file the manifest does not name.
    scratch.file(r"package\extra.txt", b"extra");
    assert_eq!(refused(&source), "fileIdentityChanged");
    // An unsigned daemon, or one of another signer.
    let other = package(&scratch, "unsigned", &unsigned);
    assert_eq!(refused(&other), "admissionDenied");
    for path in [
        Path::new("relative\\package"),
        Path::new("/private/tmp/ArkDeckAgent.app"),
        &source.join("..").join("package"),
    ] {
        assert_eq!(refused(path), "invalidInput", "{}", path.display());
    }
    assert_eq!(
        std::fs::read(store_path.join("bundles.json")).unwrap(),
        index
    );
    // No refused capture left its staging copy behind.
    let mut names: Vec<String> = std::fs::read_dir(&store_path)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            ".lock".to_owned(),
            format!("bundle-{digest}.rc"),
            "bundles.json".to_owned()
        ]
    );

    // Retirement: metadata only, once; the content stays retained.
    assert_eq!(
        store.retire(&reference_text, "2").unwrap_err().code,
        "resourceConflict"
    );
    let retired = store.retire(&reference_text, "1").unwrap();
    assert_eq!(retired["state"], "removed");
    assert_eq!(retired["generation"], "2");
    assert_eq!(store.retire(&reference_text, "1").unwrap(), retired);
    assert_eq!(store.inspect(&reference_text).unwrap(), retired);
    assert!(store_path.join(format!("bundle-{digest}.rc")).is_dir());

    // A retained copy that changed no longer verifies.
    let retained = store_path
        .join(format!("bundle-{digest}.rc"))
        .join("ArkDeck.exe");
    std::fs::OpenOptions::new()
        .append(true)
        .open(&retained)
        .unwrap()
        .write_all(b"tampered")
        .unwrap();
    assert!(store.inspect(&reference_text).is_err());
}
