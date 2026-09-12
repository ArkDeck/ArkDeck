//! Read-only destination facts for an explicit Session export preview.
use crate::snapshot_pager::failure;
use arkdeck_contract::WireError;
use arkdeck_platform::{HostDirectory, host_control_character, host_whitespace_or_newline};
use serde_json::{Value, json};
use std::{
    io,
    path::{Component, Path, PathBuf},
};

pub(crate) fn physical(path: &Path) -> Result<PathBuf, WireError> {
    let mut clean = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                clean.pop();
            }
            Component::Normal(part) => clean.push(part),
            Component::Prefix(_) => {
                return Err(failure("invalidInput", "Session export path is not local"));
            }
        }
    }
    for prefix in ["/var", "/tmp", "/etc"] {
        if let Ok(tail) = clean.strip_prefix(prefix) {
            return Ok(Path::new("/private")
                .join(prefix.trim_start_matches('/'))
                .join(tail));
        }
    }
    Ok(clean)
}

pub fn session_export_destination_facts(
    path: &str,
    owner_root: &Path,
    source_root: &Path,
) -> Result<Value, WireError> {
    let invalid = || {
        failure(
            "invalidInput",
            "Session export destination must be an absent path outside Runtime storage with an owned physical parent",
        )
    };
    if !path.starts_with('/')
        || path.len() > 4096
        || path.chars().next().is_some_and(host_whitespace_or_newline)
        || path
            .chars()
            .next_back()
            .is_some_and(host_whitespace_or_newline)
        || path.chars().any(host_control_character)
        || !owner_root.is_absolute()
        || !source_root.is_absolute()
    {
        return Err(invalid());
    }
    let destination = physical(Path::new(path))?;
    let name = destination
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && s.len() <= 255)
        .ok_or_else(invalid)?;
    for protected in [owner_root, source_root] {
        if destination.starts_with(physical(protected)?) {
            return Err(invalid());
        }
    }
    let parent_path = destination.parent().ok_or_else(invalid)?;
    let parent = HostDirectory::open_export_parent(parent_path).map_err(|_| invalid())?;
    match parent.kind_and_size(name) {
        Ok(_) => {
            return Err(failure(
                "resourceConflict",
                "Session export destination already exists",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(_) => {
            return Err(failure(
                "recordUnreadable",
                "Session export destination cannot be inspected",
            ));
        }
    }
    let facts = parent.export_facts().map_err(|_| {
        failure(
            "operationUnavailable",
            "Session export destination volume is unavailable",
        )
    })?;
    parent.validate_path(parent_path).map_err(|_| {
        failure(
            "resourceConflict",
            "Session export destination parent changed",
        )
    })?;
    Ok(
        json!({"path":destination,"parentDevice":facts.device.to_string(),"parentInode":facts.inode.to_string(),
        "volumeIdentity":facts.volume_identity,"expectedState":"absent"}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, symlink},
    };
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let random = u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("export-destination-{random:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            for name in ["owner", "sessions", "output"] {
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(path.join(name))
                    .unwrap();
            }
            Self(path)
        }
        fn facts(&self, path: &Path) -> Result<Value, WireError> {
            session_export_destination_facts(
                path.to_str().unwrap(),
                &self.0.join("owner"),
                &self.0.join("sessions"),
            )
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn preview_observes_absence_without_creating_destination_and_refuses_existing_entries() {
        let root = Root::new();
        let path = root.0.join("output/package");
        let facts = root.facts(&path).unwrap();
        assert_eq!(facts["path"], path.to_str().unwrap());
        assert_eq!(facts["expectedState"], "absent");
        assert!(!path.exists());
        fs::write(&path, b"preserve").unwrap();
        assert_eq!(root.facts(&path).unwrap_err().code, "resourceConflict");
        assert_eq!(fs::read(&path).unwrap(), b"preserve");
    }
    #[test]
    fn protected_roots_aliases_missing_parents_and_malformed_paths_are_refused() {
        let root = Root::new();
        for path in [
            root.0.join("owner/export"),
            root.0.join("sessions/export"),
            root.0.join("missing/export"),
        ] {
            assert_eq!(root.facts(&path).unwrap_err().code, "invalidInput");
        }
        symlink(root.0.join("output"), root.0.join("alias")).unwrap();
        assert_eq!(
            root.facts(&root.0.join("alias/export")).unwrap_err().code,
            "invalidInput"
        );
        assert!(session_export_destination_facts("relative", &root.0, &root.0).is_err());
        assert!(session_export_destination_facts("/tmp/with\ncontrol", &root.0, &root.0).is_err());
        let normalized = root.facts(&root.0.join("output/../sessions/export"));
        assert_eq!(normalized.unwrap_err().code, "invalidInput");
    }
}
