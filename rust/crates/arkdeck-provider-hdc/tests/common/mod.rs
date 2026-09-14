//! The shared fake HDC driver of the Swift oracles (`HDCOracleFake`), at its
//! fixed root and under its lock, driven as a real subprocess through
//! `ProcessDispatch`. The driver never changes: each test installs the answers
//! fragment it needs — the observe fixture's recorded one, or its own — and
//! reads the argv the driver logged (one call per line, U+001F after every
//! argument).
#![allow(dead_code)]

use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
pub const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
pub const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";
/// The observe fixture's one device.
pub const CONNECT_KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

pub fn observe_fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/observe-device")
}

/// The shared fake at its fixed root, in the named answer mode, under the
/// fake's lock for the life of the value.
pub struct SharedFake {
    _lock: File,
    pub root: PathBuf,
    pub dispatch: ProcessDispatch,
}

impl SharedFake {
    /// The observe fixture's recorded answers.
    pub fn from_fixture(mode: Option<&str>) -> Self {
        let answers = fs::read_to_string(observe_fixture().join("hdc-answers.sh")).unwrap();
        Self::with_answers(&answers, mode)
    }

    /// An answers fragment of the test's own (sourced by the driver with
    /// `$root`, `$mode` and `"$@"` set).
    pub fn with_answers(answers: &str, mode: Option<&str>) -> Self {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(LOCK)
            .unwrap();
        lock.lock().unwrap();
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::copy(observe_fixture().join("hdc"), root.join("hdc")).unwrap();
        fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(root.join("hdc-answers.sh"), answers).unwrap();
        File::create(root.join("hdc-invocations.log")).unwrap();
        if let Some(mode) = mode {
            fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        let digest = format!("{:x}", Sha256::digest(fs::read(root.join("hdc")).unwrap()));
        let dispatch =
            ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
        Self {
            _lock: lock,
            root,
            dispatch,
        }
    }

    pub fn set_mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }

    pub fn invocations(&self) -> Vec<u8> {
        fs::read(self.root.join("hdc-invocations.log")).unwrap()
    }

    pub fn clear_invocations(&self) {
        File::create(self.root.join("hdc-invocations.log")).unwrap();
    }
}

impl Drop for SharedFake {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
