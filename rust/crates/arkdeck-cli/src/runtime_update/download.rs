use super::{
    Cache, CacheDownload, DownloadedArtifact, NetworkError, StreamFailure, artifact_url, stream_url,
};
use crate::update_feed::signed::Artifact;
use arkdeck_platform::UpdateDownloadError;

#[derive(Debug)]
pub enum DownloadFailure {
    Network(NetworkError),
    Artifact(UpdateDownloadError),
    Cancelled,
}

pub fn download_artifact<C: FnMut() -> bool + Send>(
    cache: &Cache,
    artifact: &Artifact,
    cancel: C,
) -> Result<DownloadedArtifact, DownloadFailure> {
    download_using(cache, artifact, cancel, |url, maximum, cancel, writer| {
        stream_url(url, maximum, cancel, |bytes| writer.write_chunk(bytes)).map_err(|error| {
            match error {
                StreamFailure::Network(error) => DownloadFailure::Network(error),
                StreamFailure::Sink(error) => DownloadFailure::Artifact(error),
                StreamFailure::Cancelled => DownloadFailure::Cancelled,
            }
        })
    })
}

fn download_using<C, S>(
    cache: &Cache,
    artifact: &Artifact,
    mut cancel: C,
    stream: S,
) -> Result<DownloadedArtifact, DownloadFailure>
where
    C: FnMut() -> bool + Send,
    S: FnOnce(&str, u64, &mut C, &mut CacheDownload) -> Result<(), DownloadFailure>,
{
    let url = artifact_url(&artifact.url).map_err(DownloadFailure::Network)?;
    if cancel() {
        return Err(DownloadFailure::Cancelled);
    }
    let mut writer = cache
        .begin_download(artifact.byte_length)
        .map_err(DownloadFailure::Artifact)?;
    // The first transport or sink error exits and drops the partial. Neither
    // the transport nor publication is replayed, even after uncertain I/O.
    stream(&url, artifact.byte_length, &mut cancel, &mut writer)?;
    if cancel() {
        return Err(DownloadFailure::Cancelled);
    }
    writer
        .seal(&artifact.sha256)
        .map_err(DownloadFailure::Artifact)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::PathBuf,
        sync::atomic::{AtomicBool, Ordering},
    };
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn setup() -> (Root, Cache, Artifact) {
        let root = Root(std::env::temp_dir().join(format!(
            "arkdeck-download-flow-{}",
            crate::client_frame_id()
        )));
        let cache = Cache::new(root.0.join("cache"));
        let artifact = Artifact {
            url: "https://github.com/ArkDeck/ArkDeck/releases/download/v1/a.dmg".into(),
            byte_length: 3,
            sha256: arkdeck_contract::sha256_hex(b"abc"),
        };
        (root, cache, artifact)
    }
    #[test]
    fn cancellation_before_start_and_before_seal_never_publishes() {
        let (root, cache, artifact) = setup();
        assert!(matches!(
            download_using(
                &cache,
                &artifact,
                || true,
                |_, _, _, _| panic!("must not stream")
            ),
            Err(DownloadFailure::Cancelled)
        ));
        assert!(!root.0.exists());
        let cancelled = AtomicBool::new(false);
        let result = download_using(
            &cache,
            &artifact,
            || cancelled.load(Ordering::SeqCst),
            |_, _, _, writer| {
                writer
                    .write_chunk(b"abc")
                    .map_err(DownloadFailure::Artifact)?;
                cancelled.store(true, Ordering::SeqCst);
                Ok(())
            },
        );
        assert!(matches!(result, Err(DownloadFailure::Cancelled)));
        assert_eq!(std::fs::read_dir(root.0.join("cache")).unwrap().count(), 0);
    }
    #[test]
    fn first_stream_failure_discards_partial_and_success_retains_verifiable_artifact() {
        let (root, cache, artifact) = setup();
        let result = download_using(
            &cache,
            &artifact,
            || false,
            |_, _, _, writer| {
                writer
                    .write_chunk(b"a")
                    .map_err(DownloadFailure::Artifact)?;
                Err(DownloadFailure::Network(NetworkError::Transport(-1005)))
            },
        );
        assert!(matches!(
            result,
            Err(DownloadFailure::Network(NetworkError::Transport(-1005)))
        ));
        assert_eq!(std::fs::read_dir(root.0.join("cache")).unwrap().count(), 0);
        let value = download_using(
            &cache,
            &artifact,
            || false,
            |url, maximum, _, writer| {
                assert_eq!(url, artifact.url);
                assert_eq!(maximum, 3);
                writer
                    .write_chunk(b"abc")
                    .map_err(DownloadFailure::Artifact)
            },
        )
        .unwrap();
        assert_eq!(cache.verify_download(&value).unwrap(), value.identity);
    }
}
