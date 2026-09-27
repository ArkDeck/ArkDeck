use super::{DownloadedArtifact, FileIdentity, State, StoreError};
use arkdeck_platform::{HostDirectory, HostFileIdentity, HostUpdateDownload, UpdateDownloadError};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub struct Cache {
    directory: PathBuf,
}

pub struct CacheDownload {
    directory: PathBuf,
    root_identity: (u64, u64),
    writer: HostUpdateDownload,
}

fn validate_directory(path: &Path, identity: (u64, u64)) -> Result<(), UpdateDownloadError> {
    use std::os::unix::fs::MetadataExt;
    let linked = std::fs::symlink_metadata(path)?;
    if !linked.is_dir()
        || (linked.dev(), linked.ino()) != identity
        || linked.uid() != arkdeck_platform::effective_user_id()
        || linked.mode() & 0o7777 != 0o700
    {
        return Err(UpdateDownloadError::UnsafeDirectory);
    }
    Ok(())
}

fn file_identity(value: HostFileIdentity) -> FileIdentity {
    FileIdentity {
        device: value.device,
        inode: value.inode,
        byte_length: value.size,
        mode: 0o400,
        modified_seconds: value.modified.0,
        modified_nanoseconds: value.modified.1,
        changed_seconds: value.changed.0,
        changed_nanoseconds: value.changed.1,
    }
}

impl CacheDownload {
    pub fn write_chunk(&mut self, bytes: &[u8]) -> Result<(), UpdateDownloadError> {
        self.writer.write_chunk(bytes)
    }

    pub fn seal(self, digest: &str) -> Result<DownloadedArtifact, UpdateDownloadError> {
        validate_directory(&self.directory, self.root_identity)?;
        let (name, identity) = self.writer.seal(digest)?;
        validate_directory(&self.directory, self.root_identity)?;
        let url = arkdeck_platform::host_file_url(&self.directory.join(name))
            .ok_or(UpdateDownloadError::UnsafeArtifact)?;
        Ok(DownloadedArtifact {
            url,
            byte_length: identity.size,
            sha256: digest.to_owned(),
            identity: file_identity(identity),
        })
    }
}

impl Cache {
    pub fn begin_download(&self, expected: u64) -> Result<CacheDownload, UpdateDownloadError> {
        let root = HostDirectory::open_update_store(&self.directory)?;
        let root_identity = root.directory_identity()?;
        validate_directory(&self.directory, root_identity)?;
        Ok(CacheDownload {
            directory: self.directory.clone(),
            root_identity,
            writer: root.begin_update_download(expected)?,
        })
    }

    pub fn verify_download(
        &self,
        artifact: &DownloadedArtifact,
    ) -> Result<FileIdentity, UpdateDownloadError> {
        let actual = self.rehash_download(artifact)?;
        if actual != artifact.identity {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        Ok(actual)
    }

    pub(super) fn rehash_download(
        &self,
        artifact: &DownloadedArtifact,
    ) -> Result<FileIdentity, UpdateDownloadError> {
        self.artifact_path(artifact)?;
        let name = self
            .name(&artifact.url)
            .ok_or(UpdateDownloadError::UnsafeArtifact)?;
        let root = HostDirectory::open_update_store(&self.directory)?;
        let root_identity = root.directory_identity()?;
        validate_directory(&self.directory, root_identity)?;
        let actual = root.verify_update_download(&name, artifact.byte_length, &artifact.sha256)?;
        validate_directory(&self.directory, root_identity)?;
        Ok(file_identity(actual))
    }

    /// Hashing is descriptor-relative while Security/Finder consume a path.
    /// Refuse spellings whose lexical parent normalization could hide an
    /// intermediate symlink (for example cache/alias/../artifact.dmg).
    pub(super) fn artifact_path(
        &self,
        artifact: &DownloadedArtifact,
    ) -> Result<PathBuf, UpdateDownloadError> {
        let name = self
            .name(&artifact.url)
            .ok_or(UpdateDownloadError::UnsafeArtifact)?;
        let input = file_path(&artifact.url).ok_or(UpdateDownloadError::UnsafeArtifact)?;
        let path = self.directory.join(name);
        if input.as_os_str() != path.as_os_str() {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        Ok(path)
    }

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

pub(super) fn file_path(url: &str) -> Option<PathBuf> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_contract::sha256_hex;
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn setup() -> (Root, Cache) {
        let root =
            Root(std::env::temp_dir().join(format!("arkdeck-cache-{}", crate::client_frame_id())));
        let cache = Cache::new(root.0.join("cache #百分比% ?"));
        (root, cache)
    }

    #[test]
    fn download_round_trips_escaped_file_url_and_rejects_changed_identity() {
        let (_root, cache) = setup();
        let data = b"verified artifact";
        let digest = sha256_hex(data);
        let mut writer = cache.begin_download(data.len() as u64).unwrap();
        writer.write_chunk(data).unwrap();
        let mut artifact = writer.seal(&digest).unwrap();
        assert!(artifact.url.contains("%23"));
        assert!(artifact.url.contains("%25"));
        assert!(!artifact.url.contains('?'));
        assert_eq!(
            file_path(&artifact.url).unwrap().parent().unwrap(),
            cache.directory
        );
        assert_eq!(cache.verify_download(&artifact).unwrap(), artifact.identity);
        artifact.identity.inode += 1;
        assert!(matches!(
            cache.verify_download(&artifact),
            Err(UpdateDownloadError::UnsafeArtifact)
        ));
    }

    #[test]
    fn abandoned_stream_removes_partial_and_replaced_directory_cannot_publish() {
        let (root, cache) = setup();
        let mut writer = cache.begin_download(3).unwrap();
        writer.write_chunk(b"a").unwrap();
        drop(writer);
        assert_eq!(std::fs::read_dir(&cache.directory).unwrap().count(), 0);
        let mut writer = cache.begin_download(3).unwrap();
        writer.write_chunk(b"abc").unwrap();
        let moved = root.0.join("moved");
        std::fs::rename(&cache.directory, &moved).unwrap();
        std::fs::create_dir(&cache.directory).unwrap();
        assert!(matches!(
            writer.seal(&sha256_hex(b"abc")),
            Err(UpdateDownloadError::UnsafeDirectory)
        ));
        assert_eq!(std::fs::read_dir(moved).unwrap().count(), 0);
        assert_eq!(std::fs::read_dir(&cache.directory).unwrap().count(), 0);
    }
}
