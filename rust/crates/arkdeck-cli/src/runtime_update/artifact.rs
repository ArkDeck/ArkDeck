use super::{Cache, DownloadedArtifact, ValidatedArtifact};
use arkdeck_platform::{HostUpdateSigningError, UpdateDownloadError};
use std::path::Path;

#[derive(Debug)]
pub enum ArtifactFailure {
    File(UpdateDownloadError),
    RunningApplicationUnsigned,
    InvalidRunningApplicationTeam,
    StaticCodeUnavailable,
    UnsignedOrInvalidArtifact,
    DifferentTeam,
    ArtifactReplaced,
}
impl From<HostUpdateSigningError> for ArtifactFailure {
    fn from(value: HostUpdateSigningError) -> Self {
        match value {
            HostUpdateSigningError::RunningApplicationUnsigned => Self::RunningApplicationUnsigned,
            HostUpdateSigningError::InvalidRequirement => Self::InvalidRunningApplicationTeam,
            HostUpdateSigningError::StaticCodeUnavailable => Self::StaticCodeUnavailable,
            HostUpdateSigningError::UnsignedOrInvalidArtifact => Self::UnsignedOrInvalidArtifact,
            HostUpdateSigningError::RequirementFailed => Self::DifferentTeam,
        }
    }
}

fn developer_requirement(team: &str) -> Result<String, ArtifactFailure> {
    if team.len() != 10
        || !team
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        return Err(ArtifactFailure::InvalidRunningApplicationTeam);
    }
    Ok(format!(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{team}\""
    ))
}

trait CodeSigning {
    fn running_team(&self) -> Result<Option<String>, HostUpdateSigningError>;
    fn running_requirement(&self, source: &str) -> Result<(), HostUpdateSigningError>;
    fn artifact_requirement(
        &self,
        path: &Path,
        source: &str,
    ) -> Result<Option<String>, HostUpdateSigningError>;
}
struct SystemCodeSigning;
impl CodeSigning for SystemCodeSigning {
    fn running_team(&self) -> Result<Option<String>, HostUpdateSigningError> {
        arkdeck_platform::running_update_team()
    }
    fn running_requirement(&self, source: &str) -> Result<(), HostUpdateSigningError> {
        arkdeck_platform::validate_running_update_code(source)
    }
    fn artifact_requirement(
        &self,
        path: &Path,
        source: &str,
    ) -> Result<Option<String>, HostUpdateSigningError> {
        arkdeck_platform::validate_update_code(path, source)
    }
}

pub fn validate_artifact(
    cache: &Cache,
    artifact: &DownloadedArtifact,
) -> Result<ValidatedArtifact, ArtifactFailure> {
    validate_using(cache, artifact, &SystemCodeSigning)
}

fn validate_using(
    cache: &Cache,
    artifact: &DownloadedArtifact,
    signing: &impl CodeSigning,
) -> Result<ValidatedArtifact, ArtifactFailure> {
    let before = cache
        .rehash_download(artifact)
        .map_err(ArtifactFailure::File)?;
    if before != artifact.identity {
        return Err(ArtifactFailure::ArtifactReplaced);
    }
    let team = signing
        .running_team()?
        .ok_or(ArtifactFailure::RunningApplicationUnsigned)?;
    let source = developer_requirement(&team)?;
    signing.running_requirement(&source)?;
    let path = cache
        .artifact_path(artifact)
        .map_err(ArtifactFailure::File)?;
    let artifact_team = signing.artifact_requirement(&path, &source)?;
    if artifact_team.as_deref() != Some(team.as_str()) {
        return Err(ArtifactFailure::DifferentTeam);
    }
    let after = cache
        .rehash_download(artifact)
        .map_err(ArtifactFailure::File)?;
    if before != after {
        return Err(ArtifactFailure::ArtifactReplaced);
    }
    Ok(ValidatedArtifact {
        downloaded: artifact.clone(),
        team_identifier: team,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, os::unix::fs::PermissionsExt, path::PathBuf};
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    struct FixtureSigning {
        team: &'static str,
        artifact_team: &'static str,
        mutate: bool,
        calls: RefCell<Vec<&'static str>>,
    }
    impl CodeSigning for FixtureSigning {
        fn running_team(&self) -> Result<Option<String>, HostUpdateSigningError> {
            self.calls.borrow_mut().push("team");
            Ok(Some(self.team.into()))
        }
        fn running_requirement(&self, source: &str) -> Result<(), HostUpdateSigningError> {
            self.calls.borrow_mut().push("running");
            assert_eq!(source, developer_requirement(self.team).unwrap());
            Ok(())
        }
        fn artifact_requirement(
            &self,
            path: &Path,
            source: &str,
        ) -> Result<Option<String>, HostUpdateSigningError> {
            self.calls.borrow_mut().push("artifact");
            assert_eq!(source, developer_requirement(self.team).unwrap());
            if self.mutate {
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
                std::fs::write(path, b"xyz").unwrap();
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o400)).unwrap();
            }
            Ok(Some(self.artifact_team.into()))
        }
    }
    fn setup() -> (Root, Cache, DownloadedArtifact) {
        let root = Root(
            std::env::temp_dir().join(format!("arkdeck-artifact-{}", crate::client_frame_id())),
        );
        let cache = Cache::new(root.0.join("cache"));
        let mut writer = cache.begin_download(3).unwrap();
        writer.write_chunk(b"abc").unwrap();
        let artifact = writer.seal(&arkdeck_contract::sha256_hex(b"abc")).unwrap();
        (root, cache, artifact)
    }
    fn signing() -> FixtureSigning {
        FixtureSigning {
            team: "ABCDEFGHIJ",
            artifact_team: "ABCDEFGHIJ",
            mutate: false,
            calls: RefCell::new(Vec::new()),
        }
    }
    #[test]
    fn requirement_rejects_noncanonical_or_injected_team_identifiers() {
        for team in [
            "",
            "ABCDEFGHI",
            "ABCDEFGHIJK",
            "abcdefghij",
            "ABCDEF\"HIJ",
            "ABCDEＦGHIJ",
            "ABCDE\nGHIJ",
        ] {
            assert!(matches!(
                developer_requirement(team),
                Err(ArtifactFailure::InvalidRunningApplicationTeam)
            ));
        }
        assert_eq!(
            developer_requirement("ABC1234567").unwrap(),
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ABC1234567\""
        );
    }
    #[test]
    fn fixture_signing_binds_both_requirements_to_running_team_and_rechecks_bytes() {
        let (_root, cache, artifact) = setup();
        let mut checker = signing();
        let result = validate_using(&cache, &artifact, &checker).unwrap();
        assert_eq!(result.downloaded, artifact);
        assert_eq!(result.team_identifier, "ABCDEFGHIJ");
        assert_eq!(*checker.calls.borrow(), ["team", "running", "artifact"]);
        checker.artifact_team = "1234567890";
        assert!(matches!(
            validate_using(&cache, &artifact, &checker),
            Err(ArtifactFailure::DifferentTeam)
        ));
        checker.artifact_team = checker.team;
        checker.mutate = true;
        assert!(matches!(
            validate_using(&cache, &artifact, &checker),
            Err(ArtifactFailure::File(UpdateDownloadError::DigestMismatch))
        ));
    }
    #[test]
    fn changed_identity_refuses_before_signing_or_native_effects() {
        let (_root, cache, mut artifact) = setup();
        artifact.identity.inode += 1;
        let checker = signing();
        assert!(matches!(
            validate_using(&cache, &artifact, &checker),
            Err(ArtifactFailure::ArtifactReplaced)
        ));
        assert!(checker.calls.borrow().is_empty());
    }

    #[test]
    fn symlink_parent_alias_and_encoded_dot_segments_never_reach_signing() {
        use std::os::unix::fs::symlink;
        let (root, cache, artifact) = setup();
        let path = cache.artifact_path(&artifact).unwrap();
        let name = path.file_name().unwrap();
        let other = root.0.join("other");
        std::fs::create_dir_all(other.join("child")).unwrap();
        std::fs::write(other.join(name), b"different target").unwrap();
        symlink(other.join("child"), path.parent().unwrap().join("alias")).unwrap();
        let alias = path.parent().unwrap().join("alias/..").join(name);
        assert_eq!(std::fs::read(&alias).unwrap(), b"different target");
        assert_eq!(std::fs::read(&path).unwrap(), b"abc");
        let (parent, name) = artifact.url.rsplit_once('/').unwrap();
        for middle in ["alias/..", "alias/%2E%2E", "alias/.%2e", "./", "%2e"] {
            let mut changed = artifact.clone();
            changed.url = format!("{parent}/{middle}/{name}");
            let checker = signing();
            assert!(
                matches!(
                    validate_using(&cache, &changed, &checker),
                    Err(ArtifactFailure::File(UpdateDownloadError::UnsafeArtifact))
                ),
                "{middle}"
            );
            assert!(checker.calls.borrow().is_empty());
        }
    }
}
