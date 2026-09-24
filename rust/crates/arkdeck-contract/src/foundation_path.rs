//! Foundation's path arithmetic, as Swift's reads of on-disk inputs rely on
//! it: `standardizingPath`'s lexical form and `resolvingSymlinksInPath`
//! without its `/private` rewrite.
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
