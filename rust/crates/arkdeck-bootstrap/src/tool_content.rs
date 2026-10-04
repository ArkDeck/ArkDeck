//! Actual registered HDC content inspection; no candidate execution or trust
//! derived from durable registry testimony. Published Provider matching belongs
//! to Runtime composition and is deliberately absent from this content owner.
#[cfg(target_os = "macos")]
use crate::tool_macho;
#[cfg(windows)]
use crate::tool_pe;
use arkdeck_contract::{canonical_json, sha256_hex};
use arkdeck_platform::NativeCodeSignature;
use arkdeck_platform::{BootstrapTree, inspect_bootstrap_tree, inspect_native_code_signature};
use serde_json::{Value, json};
use std::{io, path::Path};
const MAXIMUM_BYTES: u64 = 256 * 1024 * 1024;
const MAXIMUM_LIBRARY_BYTES: u64 = 32 * 1024 * 1024;
#[cfg(target_os = "macos")]
const USB: &str = "libusb_shared.dylib";
#[cfg(windows)]
const USB: &str = tool_pe::USB;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolDependency {
    pub name: String,
    pub sha256: String,
    pub byte_count: u64,
    pub quarantine_sha256: Option<String>,
    pub trust: NativeCodeSignature,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolContent {
    pub digest: String,
    pub sha256: String,
    pub byte_count: u64,
    pub quarantine_sha256: Option<String>,
    pub dependencies: Vec<ToolDependency>,
    pub trust: NativeCodeSignature,
    pub relocatable: bool,
}
fn refusal() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "registered tool content is unsafe, changed or incomplete",
    )
}
fn entries(tree: &BootstrapTree) -> Vec<Value> {
    tree.entries.iter().map(|e|json!({"path":e.path,"kind":if e.directory{"directory"}else{"file"},
        "executable":e.executable,"quarantineSHA256":e.quarantine_sha256,"byteCount":e.byte_count.to_string(),"sha256":e.sha256})).collect()
}
/// Inspect only the current closed hdc + optional sibling libusb layout. The
/// returned signature describes integrity, never permission to execute.
#[cfg(target_os = "macos")]
pub fn inspect_tool_content(path: &Path) -> io::Result<ToolContent> {
    let before = inspect_bootstrap_tree(path)?;
    let names: Vec<&str> = before
        .entries
        .iter()
        .skip(1)
        .map(|v| v.path.as_str())
        .collect();
    if !before.entries[0].directory
        || (names != ["hdc"] && names != ["hdc", USB])
        || before.byte_count > MAXIMUM_BYTES
    {
        return Err(refusal());
    }
    let main = &before.entries[1];
    if main.directory || !main.executable || main.byte_count == 0 {
        return Err(refusal());
    }
    let file = before.open_immediate_file(path, "hdc")?;
    let slices = tool_macho::inspect(&file).map_err(|_| refusal())?;
    if tool_macho::needs_usb(&slices) != names.contains(&USB) {
        return Err(refusal());
    }
    let mut relocatable = tool_macho::relocatable(&slices, false);
    let mut dependencies = Vec::new();
    if names.contains(&USB) {
        let entry = &before.entries[2];
        if entry.directory || entry.byte_count == 0 || entry.byte_count > MAXIMUM_LIBRARY_BYTES {
            return Err(refusal());
        }
        let library = before.open_immediate_file(path, USB)?;
        let slices = tool_macho::inspect(&library).map_err(|_| refusal())?;
        relocatable &= tool_macho::relocatable(&slices, true);
        let trust = inspect_native_code_signature(&path.join(USB))?;
        dependencies.push(ToolDependency {
            name: USB.into(),
            sha256: entry.sha256.clone().ok_or_else(refusal)?,
            byte_count: entry.byte_count,
            quarantine_sha256: entry.quarantine_sha256.clone(),
            trust,
        });
    }
    let trust = inspect_native_code_signature(&path.join("hdc"))?;
    if inspect_bootstrap_tree(path)? != before {
        return Err(refusal());
    }
    let content = json!({"schemaVersion":"arkdeck.tool-content/1","kind":"hdc","layout":"hdc-sibling-libusb/1","entries":entries(&before)});
    Ok(ToolContent {
        digest: sha256_hex(&canonical_json(&content).map_err(|_| refusal())?),
        sha256: main.sha256.clone().ok_or_else(refusal)?,
        byte_count: before.byte_count,
        quarantine_sha256: main.quarantine_sha256.clone(),
        dependencies,
        trust,
        relocatable,
    })
}

/// Inspect only the Windows HDC layout: `hdc.exe` and, exactly when it
/// imports it, the sibling `libusb_shared.dll`, both bounded x64 PE images
/// (a program and a DLL). A PE import names a DLL, never a path, and the
/// loader searches the image's own directory first, so the layout is
/// relocatable by construction. The digest is host-tagged, so no Windows
/// reference equals a macOS one. The returned Authenticode signature
/// describes integrity, never permission to execute; which HDC may be used
/// is the registered Windows tuple's (CHG-2026-078), not this owner's.
#[cfg(windows)]
pub fn inspect_tool_content(path: &Path) -> io::Result<ToolContent> {
    const HDC: &str = "hdc.exe";
    let before = inspect_bootstrap_tree(path)?;
    let names: Vec<&str> = before
        .entries
        .iter()
        .skip(1)
        .map(|v| v.path.as_str())
        .collect();
    if !before.entries[0].directory
        || (names != [HDC] && names != [HDC, USB])
        || before.byte_count > MAXIMUM_BYTES
    {
        return Err(refusal());
    }
    let main = &before.entries[1];
    if main.directory || main.byte_count == 0 {
        return Err(refusal());
    }
    let file = before.open_immediate_file(path, HDC)?;
    let image = tool_pe::inspect(&file).map_err(|_| refusal())?;
    if image.dll || tool_pe::needs_usb(&image) != names.contains(&USB) {
        return Err(refusal());
    }
    let mut dependencies = Vec::new();
    if names.contains(&USB) {
        let entry = &before.entries[2];
        if entry.directory || entry.byte_count == 0 || entry.byte_count > MAXIMUM_LIBRARY_BYTES {
            return Err(refusal());
        }
        let library = before.open_immediate_file(path, USB)?;
        if !tool_pe::inspect(&library).map_err(|_| refusal())?.dll {
            return Err(refusal());
        }
        let trust = inspect_native_code_signature(&path.join(USB))?;
        dependencies.push(ToolDependency {
            name: USB.into(),
            sha256: entry.sha256.clone().ok_or_else(refusal)?,
            byte_count: entry.byte_count,
            quarantine_sha256: None,
            trust,
        });
    }
    let trust = inspect_native_code_signature(&path.join(HDC))?;
    if inspect_bootstrap_tree(path)? != before {
        return Err(refusal());
    }
    let content = json!({"schemaVersion":"arkdeck.tool-content/1","kind":"hdc",
        "layout":"hdc-sibling-libusb/1","platform":"windows","entries":entries(&before)});
    Ok(ToolContent {
        digest: sha256_hex(&canonical_json(&content).map_err(|_| refusal())?),
        sha256: main.sha256.clone().ok_or_else(refusal)?,
        byte_count: before.byte_count,
        quarantine_sha256: None,
        dependencies,
        trust,
        relocatable: true,
    })
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    fn fixture() -> std::path::PathBuf {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("tool-content-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        root
    }
    #[test]
    fn actual_native_content_is_stable_without_executing_it() {
        let root = fixture();
        fs::copy("/usr/bin/true", root.join("hdc")).unwrap();
        fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        let before = fs::read(root.join("hdc")).unwrap();
        let content = inspect_tool_content(&root).unwrap();
        assert_eq!(content.sha256, sha256_hex(&before));
        assert_eq!(content.byte_count, before.len() as u64);
        assert!(content.relocatable);
        assert!(content.dependencies.is_empty());
        assert_ne!(content.trust.signature, "unsigned");
        assert_eq!(content, inspect_tool_content(&root).unwrap());
        assert_eq!(before, fs::read(root.join("hdc")).unwrap());
        fs::write(root.join("unexpected"), b"extra").unwrap();
        assert!(inspect_tool_content(&root).is_err());
    }
    #[test]
    fn scripts_and_missing_dependency_are_not_native_tool_content() {
        let root = fixture();
        fs::write(root.join("hdc"), b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        assert!(inspect_tool_content(&root).is_err());
        fs::copy("/usr/bin/true", root.join("hdc")).unwrap();
        fs::write(root.join(USB), b"unexpected library").unwrap();
        assert!(inspect_tool_content(&root).is_err());
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use std::{fs, io::Write, path::PathBuf};

    /// A private fixture directory: the host `%TEMP%` lets other principals
    /// change what is in it, which the tree reader refuses.
    fn fixture() -> PathBuf {
        let base = arkdeck_platform::application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let base = base.to_str().unwrap();
        let root = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-tool-content-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        arkdeck_platform::create_private_directory(&root).unwrap();
        root
    }
    fn copy(from: &Path, to: &Path) {
        let bytes = fs::read(from).unwrap();
        arkdeck_platform::create_private_file(to)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
    }
    fn system(name: &str) -> PathBuf {
        PathBuf::from(std::env::var_os("SystemRoot").unwrap())
            .join("System32")
            .join(name)
    }

    #[test]
    fn a_native_program_is_stable_host_tagged_content_without_executing_it() {
        let root = fixture();
        copy(&system("whoami.exe"), &root.join("hdc.exe"));
        let before = fs::read(root.join("hdc.exe")).unwrap();
        let content = inspect_tool_content(&root).unwrap();
        assert_eq!(content.sha256, sha256_hex(&before));
        assert_eq!(content.byte_count, before.len() as u64);
        assert!(content.relocatable);
        assert!(content.dependencies.is_empty());
        assert_eq!(content, inspect_tool_content(&root).unwrap());
        // The digest is over the host-tagged entries, never the macOS form.
        let tree = inspect_bootstrap_tree(&root).unwrap();
        let untagged = json!({"schemaVersion":"arkdeck.tool-content/1","kind":"hdc",
            "layout":"hdc-sibling-libusb/1","entries":entries(&tree)});
        assert_ne!(
            content.digest,
            sha256_hex(&canonical_json(&untagged).unwrap())
        );
        fs::write(root.join("unexpected"), b"extra").unwrap();
        assert!(inspect_tool_content(&root).is_err());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_dll_a_non_image_or_an_unimported_sibling_is_not_hdc_content() {
        let root = fixture();
        copy(&system("version.dll"), &root.join("hdc.exe"));
        assert!(inspect_tool_content(&root).is_err());
        fs::remove_file(root.join("hdc.exe")).unwrap();
        arkdeck_platform::create_private_file(&root.join("hdc.exe"))
            .unwrap()
            .write_all(b"@echo off")
            .unwrap();
        assert!(inspect_tool_content(&root).is_err());
        fs::remove_file(root.join("hdc.exe")).unwrap();
        copy(&system("whoami.exe"), &root.join("hdc.exe"));
        copy(&system("version.dll"), &root.join(USB));
        assert!(inspect_tool_content(&root).is_err());
        let _ = fs::remove_dir_all(&root);
    }
}
