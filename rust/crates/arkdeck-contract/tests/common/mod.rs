use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

pub fn load_json(relative: &str) -> Value {
    serde_json::from_slice(&fs::read(repo_root().join(relative)).unwrap()).unwrap()
}
