use super::{State, StoreError};
use arkdeck_platform::HostDirectory;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub struct Cache {
    directory: PathBuf,
}

impl Cache {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    pub fn retained(&self, state: &State) -> BTreeSet<String> {
        let url = match state {
            State::Verifying { artifact } => Some(&artifact.url),
            State::AwaitingConsent { artifact, .. } => Some(&artifact.downloaded.url),
            State::HandedOff { url } => Some(url),
            _ => None,
        };
        url.and_then(|url| self.name(url)).into_iter().collect()
    }

    fn name(&self, url: &str) -> Option<String> {
        let path = file_path(url)?;
        let parent = path.parent()?.to_str()?;
        if crate::update_feed::standardized_file(parent)
            != crate::update_feed::standardized_file(self.directory.to_str()?)
        {
            return None;
        }
        path.file_name()?.to_str().map(str::to_owned)
    }

    /// Swift's interrupted-artifact removal is best effort. The following
    /// bounded cache sweep reports remaining unlink failures to the caller.
    pub fn remove_interrupted(&self, state: &State) {
        let Some(name) = self.retained(state).into_iter().next() else {
            return;
        };
        if let Ok(root) = HostDirectory::open_update_store(&self.directory) {
            let _ = root.unlink_update_entry(&name);
        }
    }

    pub fn remove_partials(&self) -> Result<(), StoreError> {
        self.sweep(|name| name.ends_with(".part"))?;
        Ok(())
    }

    pub fn remove_unreferenced(&self, retained: &BTreeSet<String>) -> Result<usize, StoreError> {
        self.sweep(|name| verified_name(name) && !retained.contains(name))
    }

    fn sweep(&self, should_remove: impl Fn(&str) -> bool) -> Result<usize, StoreError> {
        use std::os::unix::fs::MetadataExt;
        let root = HostDirectory::open_update_store(&self.directory)
            .map_err(|_| StoreError::CacheUnavailable)?;
        let names = root
            .names(65_536)
            .map_err(|_| StoreError::CacheUnavailable)?;
        let mut count = 0;
        for name in names {
            if should_remove(&name)
                && root
                    .unlink_update_entry(&name)
                    .map_err(|_| StoreError::CacheUnavailable)?
            {
                count += 1;
            }
        }
        root.sync().map_err(|_| StoreError::CacheUnavailable)?;
        let linked =
            std::fs::symlink_metadata(&self.directory).map_err(|_| StoreError::CacheUnavailable)?;
        if !linked.is_dir()
            || root
                .directory_identity()
                .map_err(|_| StoreError::CacheUnavailable)?
                != (linked.dev(), linked.ino())
        {
            return Err(StoreError::CacheUnavailable);
        }
        Ok(count)
    }
}

fn verified_name(name: &str) -> bool {
    let Some(stem) = name.strip_suffix(".dmg") else {
        return false;
    };
    stem.len() == 36
        && stem.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn file_path(url: &str) -> Option<PathBuf> {
    let path = url.strip_prefix("file://")?;
    let path = path.strip_prefix("localhost").unwrap_or(path);
    if !path.starts_with('/') || path.contains(['?', '#']) {
        return None;
    }
    let mut decoded = Vec::new();
    let mut bytes = path.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            decoded.push(
                (char::from(bytes.next()?).to_digit(16)? * 16
                    + char::from(bytes.next()?).to_digit(16)?) as u8,
            );
        } else {
            decoded.push(byte);
        }
    }
    let text = String::from_utf8(decoded).ok()?;
    if text.contains('\0') {
        return None;
    }
    Some(Path::new(&text).to_owned())
}
