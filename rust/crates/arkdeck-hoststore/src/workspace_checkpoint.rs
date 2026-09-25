//! Swift `WorkspaceOperationsProvider` for `workspace.create-checkpoint@1`
//! (TASK-XPA-015, M3): the typed action a checkpoint materializes, how it is
//! persisted, lowered and judged, and the provider-owned archive a project
//! that is not a git checkout is sealed into.
//!
//! A profile with a pinned source-control tool checkpoints with
//! `git -C <root> stash create`, which writes one commit object and moves no
//! ref, index or working file; the object id on stdout is the checkpoint,
//! and no id means none exists. A profile without one, but with a pinned
//! archive writer, seals exactly the profile-scoped files the request names
//! into `checkpoint-<sha256(job)>.tar` in the patch attempt store, which only
//! this Job can name; the archive is read back — complete, footer and size —
//! and the declared files must still be what the step was lowered against.
use crate::workspace_composition::PatchVerdict;
use crate::workspace_patch::{
    self as patch, FileSnapshot, Invocation, ToolReceipt, decode_snapshots, snapshot_values,
};
use crate::workspace_support as support;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;

pub(crate) const CHECKPOINT: &str = "workspace.create-checkpoint@1";
pub(crate) const CHECKPOINT_STEP: &str = "create-checkpoint";
pub(crate) const CHECKPOINT_KIND: &str = "createWorkspaceCheckpoint";
pub(crate) const CHECKPOINT_PRODUCT: &str = "checkpoint.txt";
/// Swift `requireBoundedCheckpointSources`: what the declared files may
/// weigh together.
const MAXIMUM_SOURCE_BYTES: u64 = 60 * 1024 * 1024;
/// Swift `sealedArchiveEvidence`'s bound on the archive itself.
const MAXIMUM_ARCHIVE_BYTES: u64 = 64 * 1024 * 1024;

/// Swift `WorkspaceArchiveCheckpointIntent`: the archive command, the
/// provider-owned destination derived from the Job, and the declared files
/// as they were when the step was materialized.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ArchiveCheckpoint {
    pub(crate) invocation: Invocation,
    pub(crate) archive_path: String,
    pub(crate) source_snapshots: Vec<FileSnapshot>,
}

/// Swift `WorkspaceProviderAction`'s two checkpoint cases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum CheckpointAction {
    Git(Invocation),
    Archive(ArchiveCheckpoint),
}

impl CheckpointAction {
    pub(crate) fn invocation(&self) -> &Invocation {
        match self {
            Self::Git(invocation) => invocation,
            Self::Archive(archive) => &archive.invocation,
        }
    }

    /// Swift's synthesized encoding of the action enum.
    fn value(&self) -> Value {
        match self {
            Self::Git(invocation) => json!({"createCheckpoint": {"_0": invocation.value()}}),
            Self::Archive(archive) => json!({"createArchiveCheckpoint": {"_0": {
                "invocation": archive.invocation.value(),
                "archivePath": archive.archive_path,
                "sourceSnapshots": snapshot_values(&archive.source_snapshots),
            }}}),
        }
    }

    /// Swift `PersistedTypedProviderAction` of the typed action: the
    /// workspace action's canonical JSON, base64.
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let bytes = crate::session_json::encode(&self.value()).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for a checkpoint:
    /// the exact typed action a record persisted, or why it cannot be one.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, String> {
        let kind = persisted["kind"].as_str().unwrap_or_default();
        if kind != "workspace.action" {
            return Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            ));
        }
        let payload = persisted["arguments"]["payload"]
            .as_str()
            .and_then(crate::agent_execution::unbase64)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .ok_or("persisted workspace.action payload is unreadable")?;
        let action = if let Some(git) = payload.get("createCheckpoint") {
            Invocation::decode(&git["_0"]).map(Self::Git)
        } else if let Some(archive) = payload.get("createArchiveCheckpoint") {
            let fields = &archive["_0"];
            Invocation::decode(&fields["invocation"])
                .zip(fields["archivePath"].as_str())
                .zip(decode_snapshots(fields.get("sourceSnapshots")))
                .map(|((invocation, archive_path), source_snapshots)| {
                    Self::Archive(ArchiveCheckpoint {
                        invocation,
                        archive_path: archive_path.to_owned(),
                        source_snapshots,
                    })
                })
        } else {
            None
        };
        action.ok_or_else(|| "persisted workspace.action is not a checkpoint action".to_owned())
    }

    /// Swift `journalStep`'s arguments for `createWorkspaceCheckpoint`: the
    /// project and the product, never the host root.
    pub(crate) fn journal_arguments(&self) -> Value {
        json!({
            "projectRef": self.invocation().project_ref,
            "artifactId": CHECKPOINT_PRODUCT,
        })
    }

    /// Swift `WorkspaceOperationsProvider.verify` for a checkpoint. `owned`
    /// is the archive destination this Job's attempt store derives, `root`
    /// the profile's root.
    pub(crate) fn verify(&self, receipt: &ToolReceipt, owned: &str, root: &str) -> PatchVerdict {
        if receipt.truncated {
            return PatchVerdict::Failed(
                "workspace.outputTruncated",
                "bounded output was truncated; semantic result is incomplete".into(),
            );
        }
        if receipt.exit_status != 0 {
            return PatchVerdict::Failed(
                "workspace.checkpointFailed",
                patch::failed_detail(receipt),
            );
        }
        let mut summary: BTreeMap<String, String> = patch::output_summary(receipt)
            .into_iter()
            .filter_map(|(key, value)| Some((key, value.as_str()?.to_owned())))
            .collect();
        match self {
            Self::Git(_) => {
                // No object id on stdout means no checkpoint exists, and
                // calling that success would let a repair believe it can
                // roll back.
                let stdout = String::from_utf8_lossy(&receipt.stdout);
                let oid = stdout.trim_matches(char::is_whitespace);
                if oid.chars().count() != 40
                    || !oid
                        .chars()
                        .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
                {
                    return PatchVerdict::Failed(
                        "workspace.checkpointEmpty",
                        "git produced no checkpoint object for this workspace".into(),
                    );
                }
                summary.insert("checkpointObject".into(), oid.to_owned());
                summary.insert("checkpointKind".into(), "gitObject".into());
                PatchVerdict::Verified(summary)
            }
            Self::Archive(archive) => {
                if archive.archive_path != owned {
                    return PatchVerdict::Failed(
                        "workspace.checkpointReadbackFailed",
                        "checkpoint archive path is not provider-owned".into(),
                    );
                }
                let evidence = synchronize(&archive.archive_path)
                    .and_then(|()| sealed_archive_evidence(&archive.archive_path));
                let (byte_count, sha256) = match evidence {
                    Ok(evidence) => evidence,
                    Err(error) => {
                        return PatchVerdict::Failed(
                            "workspace.checkpointReadbackFailed",
                            format!(
                                "checkpoint archive is absent, unsafe, incomplete or oversized: \
                                 {error}"
                            ),
                        );
                    }
                };
                if let Err(error) = patch::require(&archive.source_snapshots, root) {
                    return PatchVerdict::Failed(
                        "workspace.checkpointSourceDrift",
                        format!(
                            "declared source changed while the checkpoint was written: {error}"
                        ),
                    );
                }
                summary.insert("checkpointObject".into(), sha256);
                summary.insert("checkpointKind".into(), "sealedArchive".into());
                summary.insert("checkpointByteCount".into(), byte_count.to_string());
                PatchVerdict::Verified(summary)
            }
        }
    }
}

/// Swift's `FileHandle(forWritingTo:)` then `synchronize()` over the archive
/// before it is read back: an archive that cannot be opened for writing, or
/// is a link, is refused here.
fn synchronize(path: &str) -> Result<(), String> {
    let file = fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("the archive cannot be opened: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("the archive cannot be synchronized: {error}"))
}

/// Swift `WorkspaceProviderSupport.sealedArchiveEvidence(at:)`: a regular,
/// non-link file of 1 KiB to 64 MiB in whole 512-byte records whose last two
/// records are zero — the footer that tells a completed archive from a
/// partial write — with its size and digest.
pub(crate) fn sealed_archive_evidence(path: &str) -> Result<(u64, String), String> {
    let unsafe_metadata = || "workspace checkpoint archive metadata is unsafe".to_owned();
    let metadata = fs::symlink_metadata(path).map_err(|_| unsafe_metadata())?;
    let byte_count = metadata.len();
    if !metadata.file_type().is_file()
        || !(1_024..=MAXIMUM_ARCHIVE_BYTES).contains(&byte_count)
        || byte_count % 512 != 0
    {
        return Err(unsafe_metadata());
    }
    let mut bytes = Vec::new();
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .and_then(|file| file.take(MAXIMUM_ARCHIVE_BYTES + 1).read_to_end(&mut bytes))
        .map_err(|_| "workspace checkpoint archive footer is incomplete".to_owned())?;
    if bytes.len() as u64 != byte_count || bytes[bytes.len() - 1_024..].iter().any(|&b| b != 0) {
        return Err("workspace checkpoint archive footer is incomplete".into());
    }
    Ok((byte_count, support::sha256(&bytes)))
}

/// Swift `requireBoundedCheckpointSources(relativePaths:root:)`: the
/// declared files, in request order, weigh no more than 60 MiB together.
pub(crate) fn require_bounded_sources(paths: &[String], root: &str) -> Result<(), String> {
    let mut total: u64 = 0;
    for path in paths {
        // Swift reads each size through the link, as `resourceValues` does.
        let size = fs::metadata(format!("{root}/{path}"))
            .map(|metadata| metadata.len())
            .map_err(|error| {
                format!("workspace checkpoint source {path} is unreadable: {error}")
            })?;
        total = total.saturating_add(size);
        if total > MAXIMUM_SOURCE_BYTES {
            return Err("workspace checkpoint sources exceed the 60 MiB bound".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invocation() -> Invocation {
        Invocation {
            operation: CHECKPOINT.into(),
            project_ref: "Project".into(),
            project_root: "/tmp/project".into(),
            preset_id: "git".into(),
            executable_path: "/usr/bin/git".into(),
            executable_sha256: "0".repeat(64),
            argument_zero: None,
            arguments: vec![
                "-C".into(),
                "/tmp/project".into(),
                "stash".into(),
                "create".into(),
            ],
            timeout_seconds: 30,
        }
    }

    fn receipt(exit_status: i32, stdout: &[u8]) -> ToolReceipt {
        ToolReceipt {
            exit_status,
            stdout: stdout.to_vec(),
            stderr: Vec::new(),
            truncated: false,
        }
    }

    #[test]
    fn a_git_checkpoint_is_an_object_id_or_nothing() {
        let action = CheckpointAction::Git(invocation());
        let oid = "f905a8249ae25101ce98dccd49cf0b1dd17478f0";
        let PatchVerdict::Verified(summary) =
            action.verify(&receipt(0, format!("{oid}\n").as_bytes()), "", "")
        else {
            panic!("an object id verifies");
        };
        assert_eq!(summary["checkpointObject"], oid);
        assert_eq!(summary["checkpointKind"], "gitObject");
        for stdout in [
            &b""[..],
            b"F905A8249AE25101CE98DCCD49CF0B1DD17478F0\n",
            b"f905\n",
        ] {
            assert!(matches!(
                action.verify(&receipt(0, stdout), "", ""),
                PatchVerdict::Failed("workspace.checkpointEmpty", _)
            ));
        }
        assert!(matches!(
            action.verify(&receipt(1, oid.as_bytes()), "", ""),
            PatchVerdict::Failed("workspace.checkpointFailed", _)
        ));
    }

    #[test]
    fn the_persisted_action_is_the_action() {
        let git = CheckpointAction::Git(invocation());
        assert_eq!(
            CheckpointAction::materialize(&git.persisted().unwrap()).unwrap(),
            git
        );
        let archive = CheckpointAction::Archive(ArchiveCheckpoint {
            invocation: invocation(),
            archive_path: "/tmp/attempts/checkpoint-0.tar".into(),
            source_snapshots: vec![
                FileSnapshot {
                    relative_path: "a".into(),
                    sha256: Some("1".repeat(64)),
                },
                FileSnapshot {
                    relative_path: "b".into(),
                    sha256: None,
                },
            ],
        });
        assert_eq!(
            CheckpointAction::materialize(&archive.persisted().unwrap()).unwrap(),
            archive
        );
        assert!(
            CheckpointAction::materialize(&json!({"kind": "workspace.action",
                "arguments": {"payload": crate::agent_execution::base64(b"{\"applyPatch\":{}}")}}))
            .is_err()
        );
    }

    #[test]
    fn a_sealed_archive_has_its_footer() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-checkpoint-archive-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("checkpoint.tar");
        let text = path.to_str().unwrap();
        let mut bytes = vec![7_u8; 512];
        bytes.extend([0_u8; 1_024]);
        fs::write(&path, &bytes).unwrap();
        assert_eq!(
            sealed_archive_evidence(text).unwrap(),
            (1_536, support::sha256(&bytes))
        );
        bytes[1_535] = 1;
        fs::write(&path, &bytes).unwrap();
        assert!(sealed_archive_evidence(text).is_err());
        fs::write(&path, [0_u8; 1_000]).unwrap();
        assert!(sealed_archive_evidence(text).is_err());
        fs::remove_dir_all(&root).unwrap();
    }
}
