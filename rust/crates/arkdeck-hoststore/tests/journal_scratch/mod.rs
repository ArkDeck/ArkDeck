//! Owner-only scratch roots and recorded Journals for the Journal owners'
//! tests on macOS and Windows.
#![allow(dead_code)]

use arkdeck_hoststore::{ReplayFacts, inspect_journal};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

pub fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

/// A Journal's records, in order.
pub fn records(journal: &[u8]) -> Vec<Value> {
    journal
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).unwrap())
        .collect()
}
/// Creates every missing level of `path` owner-only: mode 0700 on macOS, the
/// store's protected owner-only DACL on Windows.
pub fn private_directories(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .unwrap();
    }
    #[cfg(windows)]
    {
        arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
    }
}

pub struct Root(pub PathBuf);
impl Root {
    pub fn new(label: &str) -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("journal-{label}-{nonce:032x}"));
        private_directories(&path);
        Self(path)
    }
    pub fn private(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        private_directories(&path);
        path
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The facts the Rust replay derives from `journal`'s bytes as recorded.
pub fn recorded_facts(root: &Root, name: &str, journal: &[u8]) -> ReplayFacts {
    let directory = root.private(name);
    fs::write(directory.join("journal.jsonl"), journal).unwrap();
    inspect_journal(&directory).unwrap()
}
