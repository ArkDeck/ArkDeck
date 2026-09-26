use super::{ArtifactFailure, ConsumerError, OperationError};
use crate::CliError;
use arkdeck_platform::UpdateDownloadError;

pub fn consumer_failure(error: ConsumerError, phase: &str) -> CliError {
    let (code, message) = match error {
        ConsumerError::Operation(OperationError::Store(error)) => {
            return super::failure(error, phase);
        }
        ConsumerError::Operation(OperationError::InvalidTransition) => (
            "resourceConflict",
            "the update lifecycle is not in a state that accepts this transition",
        ),
        ConsumerError::Operation(OperationError::ExplicitConsentRequired) => (
            "admissionDenied",
            "Finder handoff requires explicit --consent reveal-in-finder",
        ),
        ConsumerError::Operation(OperationError::Cancelled) => (
            "clientInterrupted",
            "the active update operation was cancelled",
        ),
        ConsumerError::ArtifactChanged => (
            "artifactIntegrityFailed",
            "the update artifact changed after verification",
        ),
        ConsumerError::Feed("replayStateCorrupt") => (
            "recordUnreadable",
            "the signed update replay record is not trustworthy",
        ),
        ConsumerError::Feed("replayStateWriteFailed") => (
            "ioFailure",
            "the signed update replay record could not be persisted",
        ),
        ConsumerError::Feed(_) => (
            "artifactIntegrityFailed",
            "the signed update feed failed verification",
        ),
        ConsumerError::Download(error) | ConsumerError::Artifact(ArtifactFailure::File(error)) => {
            match error {
                UpdateDownloadError::Io(_)
                | UpdateDownloadError::PublicationUnknown(_)
                | UpdateDownloadError::UnsafeDirectory => {
                    ("ioFailure", "the owner-only update cache is unavailable")
                }
                _ => (
                    "artifactIntegrityFailed",
                    "the downloaded update failed content verification",
                ),
            }
        }
        ConsumerError::Artifact(_) => (
            "artifactIntegrityFailed",
            "the downloaded update failed code-signing verification",
        ),
        ConsumerError::Network(_) => ("operationFailed", "the update network request failed"),
        ConsumerError::Handoff | ConsumerError::Host if phase == "handoff" => (
            "ioFailure",
            "Finder could not reveal the verified update artifact",
        ),
        ConsumerError::Handoff | ConsumerError::Host => {
            ("operationFailed", "the update operation failed")
        }
    };
    let mut error = CliError::new(code, message);
    error
        .details
        .insert("phase".into(), serde_json::json!(phase));
    error
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_error_text_and_private_paths_never_enter_cli_failures() {
        let cases = [
            (
                ConsumerError::Download(UpdateDownloadError::Io(std::io::Error::other(
                    "secret-path https://private.example/token",
                ))),
                "ioFailure",
                "the owner-only update cache is unavailable",
            ),
            (
                ConsumerError::Download(UpdateDownloadError::DigestMismatch),
                "artifactIntegrityFailed",
                "the downloaded update failed content verification",
            ),
            (
                ConsumerError::Artifact(ArtifactFailure::DifferentTeam),
                "artifactIntegrityFailed",
                "the downloaded update failed code-signing verification",
            ),
            (
                ConsumerError::Feed("replayStateCorrupt"),
                "recordUnreadable",
                "the signed update replay record is not trustworthy",
            ),
            (
                ConsumerError::Feed("replayStateWriteFailed"),
                "ioFailure",
                "the signed update replay record could not be persisted",
            ),
            (
                ConsumerError::Network(super::super::NetworkError::Transport(-1005)),
                "operationFailed",
                "the update network request failed",
            ),
            (
                ConsumerError::Operation(OperationError::Cancelled),
                "clientInterrupted",
                "the active update operation was cancelled",
            ),
        ];
        for (input, code, message) in cases {
            let error = consumer_failure(input, "download");
            assert_eq!(error.code, code);
            assert_eq!(error.message, message);
            assert_eq!(
                error.details,
                serde_json::Map::from_iter([("phase".into(), serde_json::json!("download"))])
            );
        }
    }
}
