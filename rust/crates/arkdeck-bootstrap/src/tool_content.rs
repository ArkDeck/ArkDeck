//! Actual registered HDC content inspection; no candidate execution or trust
//! derived from durable registry testimony. Published Provider matching belongs
//! to Runtime composition and is deliberately absent from this content owner.
use crate::tool_macho;
use arkdeck_contract::{canonical_json, sha256_hex};
use arkdeck_platform::{
    BootstrapTree, NativeCodeSignature, inspect_bootstrap_tree, inspect_native_code_signature,
};
use serde_json::{Value, json};
use std::{io, path::Path};
const MAXIMUM_BYTES: u64 = 256 * 1024 * 1024;
const MAXIMUM_LIBRARY_BYTES: u64 = 32 * 1024 * 1024;
const USB: &str = "libusb_shared.dylib";
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

#[cfg(test)]
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
