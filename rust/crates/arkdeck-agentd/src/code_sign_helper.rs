//! Where the bundled OpenHarmony code-sign helper comes from, and what a
//! composition proves about it before `deploy.native-library.app-owned@1`
//! is available.
//!
//! Swift's `HDCNativeCodeSignHelperArtifact.bundled()` finds the helper in
//! ArkDeckWorkflows' resource bundle and verifies it: an arm64 ELF the
//! library validator accepts, carrying no mutable input signature, and a
//! static executable. Without one the operation is `unavailable`
//! (`provider_tool_unavailable`, "bundled arm64 OpenHarmony code-sign helper
//! cannot be verified") and its plan is refused, which is what this daemon
//! answered for every composition until now.
//!
//! The same resource layout is looked up here, relative to this executable,
//! because the Rust daemon ships in the same helper bundle the Swift daemon
//! does: its `Resources` beside `MacOS`, the bundle directory beside the
//! executable, and the directory above it. An isolated development root may
//! name the helper outright with [`DEVELOPMENT_HELPER`]; the standalone
//! daemon and the facade do not read it, as they read no other development
//! variable. Whatever the source, the bytes are verified here and the facts
//! the device actions carry (ABI, build id, SHA-256, byte count) are this
//! file's, so naming a path pins exactly what it holds.
use arkdeck_provider_hdc::CodeSignHelper;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Names the helper an isolated development root composes.
pub(crate) const DEVELOPMENT_HELPER: &str = "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER";
const RESOURCE_BUNDLE: &str = "ArkDeckKit_ArkDeckWorkflows.bundle";
const RESOURCE: &str = "OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable";
/// The helper is a small static executable; Swift's validator bounds the
/// libraries it reads the same way.
const MAXIMUM_BYTES: u64 = 16 * 1024 * 1024;

/// The paths a composition looks in, in Swift's order: an app's sealed
/// resources, the bundle beside the executable, and the one above it.
pub(crate) fn candidates(executable: &Path) -> Vec<PathBuf> {
    let Some(directory) = executable.parent() else {
        return Vec::new();
    };
    let mut candidates = Vec::new();
    for base in [
        directory.join("../Resources"),
        directory.to_path_buf(),
        directory.join(".."),
    ] {
        let path = base.join(RESOURCE_BUNDLE).join(RESOURCE);
        if !candidates.contains(&path) {
            candidates.push(path);
        }
    }
    candidates
}

/// The helper at `path`, verified as Swift verifies the bundled one.
pub(crate) fn verified(path: &Path) -> Result<CodeSignHelper, String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("code-sign helper is unreadable: {error}"))?;
    if !metadata.is_file() {
        return Err("code-sign helper is not a regular file".into());
    }
    if metadata.len() > MAXIMUM_BYTES {
        return Err("code-sign helper is larger than a helper can be".into());
    }
    let data =
        std::fs::read(path).map_err(|error| format!("code-sign helper is unreadable: {error}"))?;
    CodeSignHelper::verified(&data, path.to_path_buf())
}

/// The development override's path: an explicit absolute one, or none.
pub(crate) fn development(value: Option<&OsStr>) -> Result<Option<PathBuf>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(format!(
            "{DEVELOPMENT_HELPER} must be an explicit absolute path"
        ));
    }
    Ok(Some(path))
}

/// The bundled helper of this executable's composition. `Ok(None)` is a
/// composition with no helper beside it, which is not a failure: the
/// operation stays unavailable, as it was. A helper that is there and does
/// not verify is reported, and the daemon serves without it.
pub(crate) fn bundled() -> Result<Option<CodeSignHelper>, String> {
    let Ok(executable) = std::env::current_exe() else {
        return Ok(None);
    };
    for candidate in candidates(&executable) {
        if candidate.exists() {
            return verified(&candidate).map(Some);
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bounded arm64 ELF the library validator accepts, with the program
    /// headers the static-executable check reads.
    fn elf(kind: u16, segments: &[u32]) -> Vec<u8> {
        let header = 64;
        let entry = 56;
        let mut data = vec![0_u8; header + segments.len() * entry + 64];
        data[..4].copy_from_slice(&[0x7f, b'E', b'L', b'F']);
        data[4] = 2; // 64-bit
        data[5] = 1; // little-endian
        data[16..18].copy_from_slice(&kind.to_le_bytes());
        data[18..20].copy_from_slice(&183_u16.to_le_bytes()); // aarch64
        data[32..40].copy_from_slice(&(header as u64).to_le_bytes());
        data[54..56].copy_from_slice(&(entry as u16).to_le_bytes());
        data[56..58].copy_from_slice(&(segments.len() as u16).to_le_bytes());
        for (index, segment) in segments.iter().enumerate() {
            let at = header + index * entry;
            data[at..at + 4].copy_from_slice(&segment.to_le_bytes());
        }
        // A GNU build-id note the validator requires, in its own section-less
        // note segment the header above does not cover.
        data
    }

    #[test]
    fn the_candidates_are_the_resource_layouts_swift_looks_in() {
        let paths = candidates(Path::new("/App.app/Contents/MacOS/arkdeck-agentd"));
        let spelled: Vec<String> = paths
            .iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            spelled,
            [
                format!("/App.app/Contents/MacOS/../Resources/{RESOURCE_BUNDLE}/{RESOURCE}"),
                format!("/App.app/Contents/MacOS/{RESOURCE_BUNDLE}/{RESOURCE}"),
                format!("/App.app/Contents/MacOS/../{RESOURCE_BUNDLE}/{RESOURCE}"),
            ]
        );
        assert!(candidates(Path::new("/")).is_empty());
    }

    #[test]
    fn the_development_helper_is_an_explicit_absolute_path() {
        assert_eq!(development(None), Ok(None));
        assert_eq!(
            development(Some(OsStr::new("/tmp/helper"))),
            Ok(Some(PathBuf::from("/tmp/helper")))
        );
        assert_eq!(
            development(Some(OsStr::new("helper"))),
            Err(format!(
                "{DEVELOPMENT_HELPER} must be an explicit absolute path"
            ))
        );
    }

    #[test]
    fn a_named_helper_is_verified_as_swift_verifies_the_bundled_one() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "code-sign-helper-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("arkdeck-code-sign-enable");
        // Not a file, then a file that is not an ELF at all.
        assert!(verified(&path).unwrap_err().contains("unreadable"));
        std::fs::write(&path, b"not an ELF").unwrap();
        assert!(verified(&path).unwrap_err().contains("invalid"));
        // An ELF with an interpreter is not the static executable the device
        // runs, and neither is a shared object.
        for (kind, segments) in [(2_u16, vec![1_u32, 3]), (3, vec![1])] {
            std::fs::write(&path, elf(kind, &segments)).unwrap();
            let refusal = verified(&path).unwrap_err();
            assert!(
                refusal.contains("static arm64 executable") || refusal.contains("invalid"),
                "{kind}: {refusal}"
            );
        }
        std::fs::remove_dir_all(&root).unwrap();
    }
}
