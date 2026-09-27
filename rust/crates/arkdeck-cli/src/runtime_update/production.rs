use super::{
    Cache, ConsumerError, DownloadedArtifact, Feed, OperationError, ProductIdentity, ReplayStore,
    RuntimeUpdateEffects, RuntimeUpdateEvent, State, StreamFailure, UpdateLogger,
    ValidatedArtifact,
};
use std::path::Path;

pub struct ProductionUpdateEffects {
    replay: ReplayStore,
    logger: Option<UpdateLogger>,
}
impl ProductionUpdateEffects {
    pub fn new(replay_directory: &Path, diagnostic_directory: Option<&Path>) -> Self {
        Self {
            replay: ReplayStore::new(replay_directory),
            logger: diagnostic_directory.and_then(UpdateLogger::open),
        }
    }
}

pub fn current_product_identity()
-> Result<(ProductIdentity, Option<std::path::PathBuf>), ConsumerError> {
    let context = arkdeck_platform::host_update_context().ok_or(ConsumerError::Host)?;
    Ok((
        ProductIdentity {
            app_version: normalized_application_version(
                context.bundle_version.as_deref().unwrap_or("0.0.0"),
            ),
            system_version: context.system_version,
            architecture: if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "unsupported"
            }
            .into(),
        },
        context
            .application_support
            .map(|path| path.join("ArkDeck/Diagnostics")),
    ))
}

fn normalized_application_version(value: &str) -> String {
    if crate::update_feed::semantic_version(value).is_some() {
        return value.into();
    }
    let candidate = format!("{value}.0");
    if value.split('.').count() == 2 && crate::update_feed::semantic_version(&candidate).is_some() {
        candidate
    } else {
        value.into()
    }
}

impl RuntimeUpdateEffects for ProductionUpdateEffects {
    fn attempt(&self, now: &str) -> Result<(), ConsumerError> {
        let seconds = crate::update_feed::canonical_timestamp(now).ok_or(ConsumerError::Host)?;
        if arkdeck_platform::host_update_record_attempt(seconds as f64) {
            Ok(())
        } else {
            Err(ConsumerError::Host)
        }
    }

    fn check(
        &self,
        identity: &ProductIdentity,
        now: &str,
        cancel: &(dyn Fn() -> bool + Sync),
    ) -> Result<State, ConsumerError> {
        let url = super::feed_url(identity).map_err(ConsumerError::Network)?;
        let mut bytes = Vec::new();
        super::stream_url(&url, 128 * 1024, cancel, |chunk| {
            if chunk.len() > 128 * 1024 - bytes.len() {
                return Err("feedTooLarge");
            }
            bytes.extend_from_slice(chunk);
            Ok(())
        })
        .map_err(|error| match error {
            StreamFailure::Network(error) => ConsumerError::Network(error),
            StreamFailure::Sink(error) => ConsumerError::Feed(error),
            StreamFailure::Cancelled => ConsumerError::Operation(OperationError::Cancelled),
        })?;
        if cancel() {
            return Err(OperationError::Cancelled.into());
        }
        let timestamp = crate::update_feed::canonical_timestamp(now).ok_or(ConsumerError::Host)?;
        super::verify_feed(&bytes, identity, timestamp, &self.replay).map_err(ConsumerError::Feed)
    }

    fn download(
        &self,
        cache: &Cache,
        feed: &Feed,
        cancel: &(dyn Fn() -> bool + Sync),
    ) -> Result<DownloadedArtifact, ConsumerError> {
        super::download_artifact(cache, &feed.payload.artifact, cancel).map_err(Into::into)
    }

    fn validate(
        &self,
        cache: &Cache,
        artifact: &DownloadedArtifact,
    ) -> Result<ValidatedArtifact, ConsumerError> {
        super::validate_artifact(cache, artifact).map_err(ConsumerError::Artifact)
    }

    fn reveal(&self, path: &Path) -> Result<(), ConsumerError> {
        if arkdeck_platform::host_update_reveal(path) {
            Ok(())
        } else {
            Err(ConsumerError::Handoff)
        }
    }

    fn event(&self, event: RuntimeUpdateEvent) {
        if let Some(logger) = &self.logger {
            logger.event(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn product_version_normalization_does_not_substitute_cli_package_version() {
        for (input, expected) in [
            ("1.2.3", "1.2.3"),
            ("1.2", "1.2.0"),
            ("01.2", "01.2"),
            ("1", "1"),
            ("1.2.3-beta", "1.2.3-beta"),
            ("", ""),
            ("0.0.0", "0.0.0"),
        ] {
            assert_eq!(normalized_application_version(input), expected);
        }
        let (identity, _) = current_product_identity().unwrap();
        assert!(crate::update_feed::semantic_version(&identity.system_version).is_some());
        assert_eq!(
            identity.architecture,
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "unsupported"
            }
        );
        // Only Bundle/ProcessInfo reads above: no preferences, logger, network
        // request, signing success or Finder operation is performed here.
    }
}
