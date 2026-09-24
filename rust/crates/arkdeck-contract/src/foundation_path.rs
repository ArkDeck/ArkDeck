//! Foundation's path arithmetic, as Swift's reads of on-disk inputs rely on
//! it: `standardizingPath`'s lexical form, its `/private` rewrite, and
//! `resolvingSymlinksInPath` without that rewrite.
use std::path::{Component, Path, PathBuf};

/// The path with `.` components dropped and `..` taken lexically, never
/// consulting the file system.
pub fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Foundation's `resolvingSymlinksInPath` without its `/private` rewrite: the
/// longest existing prefix resolved by `realpath`, the rest appended.
pub fn resolved(path: &Path) -> PathBuf {
    let path = lexical(path);
    let mut tail = Vec::new();
    let mut head = path.as_path();
    loop {
        if let Ok(canonical) = head.canonicalize() {
            let mut out = canonical;
            for component in tail.iter().rev() {
                out.push(component);
            }
            return out;
        }
        match (head.parent(), head.file_name()) {
            (Some(parent), Some(name)) => {
                tail.push(name.to_owned());
                head = parent;
            }
            _ => return path,
        }
    }
}

/// Foundation's `standardizedFileURL.path` of an absolute path: the lexical
/// form, then an initial `/private/var/automount`, `/var/automount` or
/// `/private` removed when what is left still names something on disk. So
/// `/private/tmp/x` standardizes to `/tmp/x` once `/tmp/x` exists.
pub fn standardized(path: &Path) -> PathBuf {
    let path = lexical(path);
    for prefix in ["/private/var/automount", "/var/automount", "/private"] {
        if let Ok(rest) = path.strip_prefix(prefix)
            && !rest.as_os_str().is_empty()
        {
            let shorter = Path::new("/").join(rest);
            if std::fs::symlink_metadata(&shorter).is_ok() {
                return shorter;
            }
        }
    }
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standardizing_reduces_the_path_lexically() {
        assert_eq!(
            standardized(Path::new("/Users/x/./y/../z")),
            Path::new("/Users/x/z")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn standardizing_drops_private_only_when_the_rest_exists() {
        let unique = format!("arkdeck-standardized-{}", std::process::id());
        let private = Path::new("/private/tmp").join(&unique);
        std::fs::create_dir_all(&private).unwrap();
        assert_eq!(standardized(&private), Path::new("/tmp").join(&unique));
        assert_eq!(
            standardized(&Path::new("/tmp").join(&unique)),
            Path::new("/tmp").join(&unique)
        );
        assert_eq!(
            standardized(&private.join("./missing/..")),
            Path::new("/tmp").join(&unique)
        );
        std::fs::remove_dir(&private).unwrap();
        assert_eq!(standardized(&private), private);
    }
}
