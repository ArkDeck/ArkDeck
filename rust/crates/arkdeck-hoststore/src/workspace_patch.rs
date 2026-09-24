//! Swift `WorkspacePatchIntent`, `WorkspaceRevertIntent`,
//! `WorkspacePatchAttempt`, `WorkspacePatchAttemptStore` and the patch half of
//! `WorkspaceProviderSupport` (`WorkspaceOperationsProvider.swift`) for
//! `workspace.apply-patch@1` and `workspace.revert-patch@1` (TASK-XPA-015,
//! M3): the typed intents a patch Job persists before its write-ahead intent,
//! the unified diff's declared paths, the per-file snapshots that pin a patch
//! to the tree it was planned against, the durable attempts a revert and a
//! copy's adoption read, and the one tool both operations run.
//!
//! The tool is the patch preset's pinned executable (`/usr/bin/patch` in every
//! composed profile), started by argv with no shell: `-f [-R] -p1 -d <root>
//! -i <file>`. Its identity was hashed when the profile was composed; the
//! dispatch opens it by that digest and runs its retained inode, so an
//! executable that changed since is refused, never run.
//!
//! Differences from Swift, each on the refusing side: an attempt record and a
//! durable patch are written owner-only; an attempt that cannot be read is
//! named by its reference, never by a Foundation error carrying a host path.
use crate::workspace_support::{self as support, foundation_standardized, matches, swift_sort};
use serde_json::{Map, Value, json};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::sync::Mutex;

/// The durable attempts' directory below the state root.
pub(crate) const ATTEMPTS_DIRECTORY: &str = "workspace-patch-attempts";
/// Swift's bound on a patch Artifact's bytes.
pub(crate) const MAXIMUM_PATCH_BYTES: u64 = 4 * 1024 * 1024;
const MAXIMUM_ATTEMPT_BYTES: u64 = 4 * 1024 * 1024;
/// Swift `DescriptorBoundProcessDispatcher`'s per-stream capture.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;

/// A refusal detail, as Swift's `DeviceProviderError` describes itself.
pub(crate) type Detail = String;

fn detail(text: &str) -> Detail {
    text.to_owned()
}

// MARK: - The unified diff

/// Swift `Character`s of `text`: extended grapheme clusters.
fn characters(text: &str) -> Vec<&str> {
    crate::session_graphemes::graphemes(text).collect()
}

/// Swift `String.hasPrefix`, Character by Character.
fn has_prefix(characters: &[&str], prefix: &str) -> bool {
    let prefix: Vec<&str> = crate::session_graphemes::graphemes(prefix).collect();
    characters.len() >= prefix.len() && characters[..prefix.len()] == prefix[..]
}

/// Swift `split(separator:omittingEmptySubsequences:)` on one Character.
fn split<'a>(characters: &[&'a str], separator: &str, omitting: bool) -> Vec<Vec<&'a str>> {
    let mut parts = vec![Vec::new()];
    for character in characters {
        if *character == separator {
            parts.push(Vec::new());
        } else if let Some(last) = parts.last_mut() {
            last.push(*character);
        }
    }
    if omitting {
        parts.retain(|part| !part.is_empty());
    }
    parts
}

fn joined(characters: &[&str]) -> String {
    characters.concat()
}

/// Swift `normalizedPatchPath(_:prefix:)`: the path after `a/` or `b/`, when
/// it is relative, inside the tree and not the repository's metadata.
fn normalized_path(raw: &[&str], prefix: &str) -> Option<String> {
    if !has_prefix(raw, prefix) {
        return None;
    }
    let path = &raw[crate::session_graphemes::graphemes(prefix).count()..];
    // A backslash or NUL byte anywhere is refused, which is at least what a
    // backslash Character refuses.
    let text = joined(path);
    if path.is_empty() || has_prefix(path, "/") || text.contains('\\') {
        return None;
    }
    if split(path, "/", false)
        .iter()
        .any(|component| component.is_empty() || matches!(joined(component).as_str(), "." | ".."))
    {
        return None;
    }
    if has_prefix(path, ".git/") || text == ".git" {
        return None;
    }
    Some(text)
}

/// Swift `WorkspaceProviderSupport.patchPaths(from:)`: every path a unified
/// diff declares, sorted, when it is bounded UTF-8, touches 1...128 files and
/// carries no binary, rename or copy.
pub(crate) fn patch_paths(bytes: &[u8]) -> Result<Vec<String>, Detail> {
    // `String(data:encoding: .utf8)`: valid UTF-8, one leading byte order
    // mark dropped.
    let text = std::str::from_utf8(bytes)
        .ok()
        .map(|text| text.strip_prefix('\u{feff}').unwrap_or(text))
        .filter(|text| !text.contains('\0'))
        .ok_or_else(|| detail("workspace patch must be bounded UTF-8 unified diff"))?;
    let mut paths: Vec<String> = Vec::new();
    let mut insert = |path: String| {
        // Swift's `Set<String>` holds canonically equivalent paths once.
        let key = arkdeck_platform::host_canonical_text(&path).unwrap_or_else(|| path.clone());
        if !paths.iter().any(|held| {
            arkdeck_platform::host_canonical_text(held).unwrap_or_else(|| held.clone()) == key
        }) {
            paths.push(path);
        }
    };
    let all = characters(text);
    for line in split(&all, "\n", false) {
        if [
            "GIT binary patch",
            "Binary files ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to ",
        ]
        .iter()
        .any(|prefix| has_prefix(&line, prefix))
        {
            return Err(detail(
                "workspace binary/rename/copy patches are not supported",
            ));
        }
        if has_prefix(&line, "diff --git ") {
            let fields = split(&line, " ", true);
            let (Some(old), Some(new)) = (
                fields.get(2).and_then(|field| normalized_path(field, "a/")),
                fields.get(3).and_then(|field| normalized_path(field, "b/")),
            ) else {
                return Err(detail("workspace diff header carries an unsafe path"));
            };
            if fields.len() != 4 {
                return Err(detail("workspace diff header carries an unsafe path"));
            }
            insert(old);
            insert(new);
        } else if has_prefix(&line, "--- ") || has_prefix(&line, "+++ ") {
            let rest = &line[4..];
            let raw = split(rest, "\t", true)
                .into_iter()
                .next()
                .unwrap_or_default();
            if joined(&raw) != "/dev/null" {
                let prefix = if has_prefix(&line, "--- ") {
                    "a/"
                } else {
                    "b/"
                };
                let path = normalized_path(&raw, prefix)
                    .ok_or_else(|| detail("workspace unified diff carries an unsafe path"))?;
                insert(path);
            }
        }
    }
    if paths.is_empty() || paths.len() > 128 {
        return Err(detail("workspace patch must touch 1...128 declared files"));
    }
    swift_sort(&mut paths);
    Ok(paths)
}

// MARK: - The tree a patch touches

/// Swift `validatePath(_:root:)`: inside the root, through no symbolic link,
/// and a regular file when it exists.
fn validate_path(relative: &str, root: &str) -> Result<(), Detail> {
    let candidate = foundation_standardized(&format!("{root}/{relative}"));
    if !candidate.starts_with(&format!("{root}/")) {
        return Err(detail("workspace path escapes the ProjectProfile root"));
    }
    let components: Vec<&str> = relative.split('/').filter(|c| !c.is_empty()).collect();
    let mut cursor = root.to_owned();
    for component in &components[..components.len().saturating_sub(1)] {
        cursor = format!("{cursor}/{component}");
        // `fileExists` follows a link; a component that exists is refused
        // when it is one.
        if fs::metadata(&cursor).is_ok()
            && fs::symlink_metadata(&cursor).is_ok_and(|entry| entry.file_type().is_symlink())
        {
            return Err(detail("workspace path traverses a symbolic link"));
        }
    }
    if fs::metadata(&candidate).is_ok() {
        let regular = fs::symlink_metadata(&candidate).is_ok_and(|entry| entry.is_file());
        if !regular {
            return Err(detail("workspace patch target is not a regular file"));
        }
    }
    Ok(())
}

/// Swift `WorkspaceProviderSupport.validate(relativePaths:root:profileGlobs:
/// requestGlobs:)`: every declared path inside both the profile's scopes and
/// the request's, and each one a safe path below the root.
pub(crate) fn validate(
    paths: &[String],
    root: &str,
    profile_globs: &[String],
    request_globs: &[String],
) -> Result<(), Detail> {
    if request_globs.is_empty()
        || request_globs.len() > 64
        || !request_globs.iter().all(|glob| support::is_safe_glob(glob))
    {
        return Err(detail(
            "workspace patch allowedFileGlobs are empty or unsafe",
        ));
    }
    for path in paths {
        if !profile_globs.iter().any(|glob| matches(path, glob))
            || !request_globs.iter().any(|glob| matches(path, glob))
        {
            return Err(format!("workspace.patchScopeViolation:{path}"));
        }
        validate_path(path, root)?;
    }
    Ok(())
}

/// Swift `WorkspaceFileSnapshot`: a declared file's digest, or its absence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileSnapshot {
    pub(crate) relative_path: String,
    pub(crate) sha256: Option<String>,
}

impl FileSnapshot {
    fn value(&self) -> Value {
        let mut value = json!({"relativePath": self.relative_path});
        if let Some(sha256) = &self.sha256 {
            value["sha256"] = json!(sha256);
        }
        value
    }

    fn decode(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        Some(Self {
            relative_path: fields.get("relativePath")?.as_str()?.to_owned(),
            sha256: match fields.get("sha256") {
                None | Some(Value::Null) => None,
                Some(value) => Some(value.as_str()?.to_owned()),
            },
        })
    }
}

fn snapshot_values(snapshots: &[FileSnapshot]) -> Value {
    Value::Array(snapshots.iter().map(FileSnapshot::value).collect())
}

fn decode_snapshots(value: Option<&Value>) -> Option<Vec<FileSnapshot>> {
    value?
        .as_array()?
        .iter()
        .map(FileSnapshot::decode)
        .collect()
}

/// Swift `WorkspaceProviderSupport.snapshots(relativePaths:root:)`: each
/// declared file's digest, sorted, every path validated first.
pub(crate) fn snapshots(paths: &[String], root: &str) -> Result<Vec<FileSnapshot>, Detail> {
    let mut sorted = paths.to_vec();
    swift_sort(&mut sorted);
    sorted
        .into_iter()
        .map(|path| {
            validate_path(&path, root)?;
            let url = format!("{root}/{path}");
            if fs::metadata(&url).is_err() {
                return Ok(FileSnapshot {
                    relative_path: path,
                    sha256: None,
                });
            }
            let bytes = fs::read(&url)
                .map_err(|_| format!("workspace patch target {path} is unreadable"))?;
            Ok(FileSnapshot {
                relative_path: path,
                sha256: Some(support::sha256(&bytes)),
            })
        })
        .collect()
}

/// Swift `WorkspaceProviderSupport.require(snapshots:root:)`: the tree is
/// exactly what the snapshots say, right before a dispatch.
pub(crate) fn require(expected: &[FileSnapshot], root: &str) -> Result<(), Detail> {
    let paths: Vec<String> = expected
        .iter()
        .map(|snapshot| snapshot.relative_path.clone())
        .collect();
    if snapshots(&paths, root)? != expected {
        return Err(detail(
            "workspace revision drifted before descriptor-bound dispatch",
        ));
    }
    Ok(())
}

/// Swift `WorkspaceProviderSupport.revision(_:)`: the digest of the sorted
/// `path<TAB>sha256|absent` lines.
pub(crate) fn revision(snapshots: &[FileSnapshot]) -> String {
    let mut sorted = snapshots.to_vec();
    sorted.sort_by_cached_key(|snapshot| {
        arkdeck_platform::host_canonical_text(&snapshot.relative_path)
            .unwrap_or_else(|| snapshot.relative_path.clone())
    });
    let material: Vec<String> = sorted
        .iter()
        .map(|snapshot| {
            format!(
                "{}\t{}",
                snapshot.relative_path,
                snapshot.sha256.as_deref().unwrap_or("absent")
            )
        })
        .collect();
    support::sha256(material.join("\n").as_bytes())
}

// MARK: - The typed actions

/// Swift `WorkspaceResolvedInvocation`: the one preset command a patch step
/// runs, with the executable identity the profile pinned.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Invocation {
    pub(crate) operation: String,
    pub(crate) project_ref: String,
    pub(crate) project_root: String,
    pub(crate) preset_id: String,
    pub(crate) executable_path: String,
    pub(crate) executable_sha256: String,
    pub(crate) argument_zero: Option<String>,
    pub(crate) arguments: Vec<String>,
    pub(crate) timeout_seconds: i64,
}

impl Invocation {
    pub(crate) fn value(&self) -> Value {
        let mut value = json!({
            "operation": self.operation, "projectRef": self.project_ref,
            "projectRoot": self.project_root, "presetID": self.preset_id,
            "executable": {"path": self.executable_path, "sha256": self.executable_sha256},
            "arguments": self.arguments, "timeoutSeconds": self.timeout_seconds,
        });
        if let Some(zero) = &self.argument_zero {
            value["argumentZero"] = json!(zero);
        }
        value
    }

    pub(crate) fn decode(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        let text = |key: &str| Some(fields.get(key)?.as_str()?.to_owned());
        let executable = fields.get("executable")?.as_object()?;
        Some(Self {
            operation: text("operation")?,
            project_ref: text("projectRef")?,
            project_root: text("projectRoot")?,
            preset_id: text("presetID")?,
            executable_path: executable.get("path")?.as_str()?.to_owned(),
            executable_sha256: executable.get("sha256")?.as_str()?.to_owned(),
            argument_zero: match fields.get("argumentZero") {
                None | Some(Value::Null) => None,
                Some(value) => Some(value.as_str()?.to_owned()),
            },
            arguments: fields
                .get("arguments")?
                .as_array()?
                .iter()
                .map(|argument| argument.as_str().map(str::to_owned))
                .collect::<Option<_>>()?,
            timeout_seconds: fields.get("timeoutSeconds")?.as_i64()?,
        })
    }
}

/// Swift `WorkspacePatchIntent`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PatchIntent {
    pub(crate) invocation: Invocation,
    pub(crate) patch_attempt_ref: String,
    pub(crate) patch_artifact_id: String,
    pub(crate) patch_file_path: String,
    pub(crate) patch_sha256: String,
    pub(crate) allowed_file_globs: Vec<String>,
    pub(crate) before: Vec<FileSnapshot>,
    pub(crate) previous_workspace_revision: Option<String>,
}

impl PatchIntent {
    fn value(&self) -> Value {
        let mut value = json!({
            "invocation": self.invocation.value(),
            "patchAttemptRef": self.patch_attempt_ref,
            "patchArtifactID": self.patch_artifact_id,
            "patchFilePath": self.patch_file_path,
            "patchSHA256": self.patch_sha256,
            "allowedFileGlobs": self.allowed_file_globs,
            "before": snapshot_values(&self.before),
        });
        if let Some(previous) = &self.previous_workspace_revision {
            value["previousWorkspaceRevision"] = json!(previous);
        }
        value
    }

    fn decode(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        let text = |key: &str| Some(fields.get(key)?.as_str()?.to_owned());
        Some(Self {
            invocation: Invocation::decode(fields.get("invocation")?)?,
            patch_attempt_ref: text("patchAttemptRef")?,
            patch_artifact_id: text("patchArtifactID")?,
            patch_file_path: text("patchFilePath")?,
            patch_sha256: text("patchSHA256")?,
            allowed_file_globs: fields
                .get("allowedFileGlobs")?
                .as_array()?
                .iter()
                .map(|glob| glob.as_str().map(str::to_owned))
                .collect::<Option<_>>()?,
            before: decode_snapshots(fields.get("before"))?,
            previous_workspace_revision: match fields.get("previousWorkspaceRevision") {
                None | Some(Value::Null) => None,
                Some(value) => Some(value.as_str()?.to_owned()),
            },
        })
    }

    /// Swift `journalStep`'s arguments for `applyWorkspacePatch`.
    pub(crate) fn journal_arguments(&self) -> Value {
        json!({
            "projectRef": self.invocation.project_ref,
            "patchArtifactId": self.patch_artifact_id,
            "patchSha256": self.patch_sha256,
            "allowedFileGlobs": self.allowed_file_globs,
            "patchAttemptRef": self.patch_attempt_ref,
        })
    }
}

/// Swift `WorkspaceRevertIntent`: the exact durable attempt it reverses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RevertIntent {
    pub(crate) invocation: Invocation,
    pub(crate) attempt: PatchAttempt,
}

/// Swift `WorkspaceProviderAction`'s two patch cases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PatchAction {
    Apply(PatchIntent),
    Revert(RevertIntent),
}

impl PatchAction {
    pub(crate) fn invocation(&self) -> &Invocation {
        match self {
            Self::Apply(intent) => &intent.invocation,
            Self::Revert(intent) => &intent.invocation,
        }
    }

    /// Swift's synthesized encoding of the action enum.
    fn value(&self) -> Value {
        match self {
            Self::Apply(intent) => json!({"applyPatch": {"_0": intent.value()}}),
            Self::Revert(intent) => json!({"revertPatch": {"_0": {
                "invocation": intent.invocation.value(),
                "attempt": intent.attempt.value(),
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

    /// Swift `PersistedTypedProviderAction.materialize()` for a workspace
    /// patch action: the exact typed action a record persisted, or why it
    /// cannot be one.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, Detail> {
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
            .ok_or_else(|| detail("persisted workspace.action payload is unreadable"))?;
        let action = if let Some(apply) = payload.get("applyPatch") {
            PatchIntent::decode(&apply["_0"]).map(Self::Apply)
        } else if let Some(revert) = payload.get("revertPatch") {
            let fields = &revert["_0"];
            Invocation::decode(&fields["invocation"])
                .zip(PatchAttempt::decode(&fields["attempt"]))
                .map(|(invocation, attempt)| {
                    Self::Revert(RevertIntent {
                        invocation,
                        attempt,
                    })
                })
        } else {
            None
        };
        action.ok_or_else(|| detail("persisted workspace.action is not a patch action"))
    }
}

// MARK: - The durable attempts

/// Swift `WorkspacePatchAttempt`: what an applied patch changed, where its
/// durable bytes are, and whether it was reverted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PatchAttempt {
    pub(crate) patch_attempt_ref: String,
    pub(crate) project_ref: String,
    pub(crate) project_root: String,
    pub(crate) patch_artifact_id: String,
    pub(crate) patch_file_path: String,
    pub(crate) patch_sha256: String,
    pub(crate) allowed_file_globs: Vec<String>,
    pub(crate) before: Vec<FileSnapshot>,
    pub(crate) after: Vec<FileSnapshot>,
    pub(crate) workspace_revision_before: Option<String>,
    pub(crate) workspace_revision_after: Option<String>,
    pub(crate) applied_at_utc: String,
    pub(crate) reverted_at_utc: Option<String>,
}

impl PatchAttempt {
    fn value(&self) -> Value {
        let mut value = json!({
            "patchAttemptRef": self.patch_attempt_ref,
            "projectRef": self.project_ref,
            "projectRoot": self.project_root,
            "patchArtifactID": self.patch_artifact_id,
            "patchFilePath": self.patch_file_path,
            "patchSHA256": self.patch_sha256,
            "allowedFileGlobs": self.allowed_file_globs,
            "before": snapshot_values(&self.before),
            "after": snapshot_values(&self.after),
            "appliedAtUTC": self.applied_at_utc,
        });
        for (key, optional) in [
            ("workspaceRevisionBefore", &self.workspace_revision_before),
            ("workspaceRevisionAfter", &self.workspace_revision_after),
            ("revertedAtUTC", &self.reverted_at_utc),
        ] {
            if let Some(present) = optional {
                value[key] = json!(present);
            }
        }
        value
    }

    fn decode(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        let text = |key: &str| Some(fields.get(key)?.as_str()?.to_owned());
        let optional = |key: &str| match fields.get(key) {
            None | Some(Value::Null) => Some(None),
            Some(value) => value.as_str().map(|text| Some(text.to_owned())),
        };
        Some(Self {
            patch_attempt_ref: text("patchAttemptRef")?,
            project_ref: text("projectRef")?,
            project_root: text("projectRoot")?,
            patch_artifact_id: text("patchArtifactID")?,
            patch_file_path: text("patchFilePath")?,
            patch_sha256: text("patchSHA256")?,
            allowed_file_globs: fields
                .get("allowedFileGlobs")?
                .as_array()?
                .iter()
                .map(|glob| glob.as_str().map(str::to_owned))
                .collect::<Option<_>>()?,
            before: decode_snapshots(fields.get("before"))?,
            after: decode_snapshots(fields.get("after"))?,
            workspace_revision_before: optional("workspaceRevisionBefore")?,
            workspace_revision_after: optional("workspaceRevisionAfter")?,
            applied_at_utc: text("appliedAtUTC")?,
            reverted_at_utc: optional("revertedAtUTC")?,
        })
    }

    /// Swift `markingReverted(atUTC:)`.
    pub(crate) fn marking_reverted(&self, at: &str) -> Self {
        Self {
            reverted_at_utc: Some(at.to_owned()),
            ..self.clone()
        }
    }
}

/// Swift `EvolutionWorkspaceManager.lineageDerivedRevision(base:attempts:)`:
/// the revision the durable patch lineage says a copy measures now, or `None`
/// when the chain cannot vouch — a broken link, a fork, or a record whose
/// `before` does not extend the current state.
pub(crate) fn lineage_derived_revision(base: &str, attempts: &[PatchAttempt]) -> Option<String> {
    let mut ordered: Vec<&PatchAttempt> = attempts.iter().collect();
    ordered.sort_by(|left, right| left.applied_at_utc.cmp(&right.applied_at_utc));
    let mut current = base.to_owned();
    for attempt in ordered {
        let (Some(before), Some(after)) = (
            &attempt.workspace_revision_before,
            &attempt.workspace_revision_after,
        ) else {
            return None;
        };
        if *before != current {
            return None;
        }
        // A reverted attempt restored `before`, which is already `current`;
        // an applied one advanced the tree to `after`.
        if attempt.reverted_at_utc.is_none() {
            current = after.clone();
        }
    }
    Some(current)
}

/// Swift `WorkspacePatchAttemptStore`: one owner-only directory beside the
/// isolation manager's, content-addressed by attempt reference.
pub(crate) struct AttemptStore {
    /// The directory as the composition names it, which the durable patch
    /// paths carry.
    root: String,
    lock: Mutex<()>,
}

/// Swift `validate(_:)`: `patch-` and 32 lowercase hexadecimal digits.
pub(crate) fn valid_reference(reference: &str) -> bool {
    reference.len() == 38
        && reference.starts_with("patch-")
        && reference[6..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn read_bounded(path: &str, bound: u64) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let mut bytes = Vec::new();
    file.take(bound + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > bound {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "too large"));
    }
    Ok(bytes)
}

/// Written beside `destination`, synchronized, then renamed over it.
fn replace(destination: &str, bytes: &[u8], staged: &str) -> io::Result<()> {
    let written = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(staged)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(staged, destination)
    })();
    if written.is_err() {
        let _ = fs::remove_file(staged);
    }
    written
}

impl AttemptStore {
    pub(crate) fn open(root: &Path) -> io::Result<Self> {
        DirBuilder::new().recursive(true).mode(0o700).create(root)?;
        let root = root.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "attempt root is not UTF-8")
        })?;
        Ok(Self {
            root: root.to_owned(),
            lock: Mutex::new(()),
        })
    }

    fn record_path(&self, reference: &str) -> Result<String, Detail> {
        if !valid_reference(reference) {
            return Err(detail("workspace patch attempt ref is malformed"));
        }
        Ok(format!("{}/{reference}.json", self.root))
    }

    fn patch_path(&self, reference: &str) -> Result<String, Detail> {
        if !valid_reference(reference) {
            return Err(detail("workspace patch attempt ref is malformed"));
        }
        Ok(format!("{}/{reference}.patch", self.root))
    }

    fn read(path: &str) -> Option<PatchAttempt> {
        let bytes = read_bounded(path, MAXIMUM_ATTEMPT_BYTES).ok()?;
        PatchAttempt::decode(&serde_json::from_slice(&bytes).ok()?)
    }

    /// Swift `load(_:)`. An attempt that cannot be read is not an active one.
    pub(crate) fn load(&self, reference: &str) -> Result<PatchAttempt, Detail> {
        let path = self.record_path(reference)?;
        let _held = self
            .lock
            .lock()
            .map_err(|_| detail("workspace patch attempt store is unavailable"))?;
        Self::read(&path)
            .ok_or_else(|| detail("workspace patch attempt is not active in this ProjectProfile"))
    }

    /// Swift `save(_:)`: canonical pretty JSON, replaced atomically.
    pub(crate) fn save(&self, attempt: &PatchAttempt) -> Result<(), Detail> {
        let path = self.record_path(&attempt.patch_attempt_ref)?;
        let bytes = crate::session_json::encode_canonical_pretty(&attempt.value())
            .map_err(|_| detail("workspace patch attempt could not be encoded"))?;
        let _held = self
            .lock
            .lock()
            .map_err(|_| detail("workspace patch attempt store is unavailable"))?;
        let staged = format!(
            "{}/.{}.tmp.{}",
            self.root,
            attempt.patch_attempt_ref,
            std::process::id()
        );
        replace(&path, &bytes, &staged)
            .map_err(|_| detail("workspace patch attempt could not become durable"))
    }

    /// Swift `persistPatch(reference:sourceURL:expectedSHA256:)`: the leased
    /// bytes copied in once, content-addressed, so a revert needs nothing
    /// the lease may no longer hold.
    pub(crate) fn persist_patch(
        &self,
        reference: &str,
        source: &str,
        expected_sha256: &str,
    ) -> Result<String, Detail> {
        let destination = self.patch_path(reference)?;
        let _held = self
            .lock
            .lock()
            .map_err(|_| detail("workspace patch attempt store is unavailable"))?;
        if fs::symlink_metadata(&destination).is_ok() {
            let existing = read_bounded(&destination, MAXIMUM_PATCH_BYTES).map_err(|_| {
                detail("workspace durable patch bytes do not match the attempt digest")
            })?;
            if support::sha256(&existing) != expected_sha256 {
                return Err(detail(
                    "workspace durable patch bytes do not match the attempt digest",
                ));
            }
            return Ok(destination);
        }
        let bytes = read_bounded(source, MAXIMUM_PATCH_BYTES).map_err(|_| {
            detail("workspace leased patch bytes changed before durable persistence")
        })?;
        if support::sha256(&bytes) != expected_sha256 {
            return Err(detail(
                "workspace leased patch bytes changed before durable persistence",
            ));
        }
        let staged = format!(
            "{}/.{reference}.patch.tmp.{}",
            self.root,
            std::process::id()
        );
        let written = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&staged)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            // Swift moves without replacing: bytes that appeared meanwhile
            // are not overwritten.
            if fs::symlink_metadata(&destination).is_ok() {
                return Err(io::Error::from(io::ErrorKind::AlreadyExists));
            }
            fs::rename(&staged, &destination)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&staged);
        }
        written.map_err(|_| detail("workspace durable patch bytes could not become durable"))?;
        Ok(destination)
    }

    /// Swift `attemptRecords(forProjectRef:)`: every attempt record of one
    /// project, by `appliedAtUTC`. A record that cannot be read fails the
    /// whole lineage: one with unreadable links must not vouch.
    pub(crate) fn attempts_for(&self, project_ref: &str) -> Result<Vec<PatchAttempt>, Detail> {
        let _held = self
            .lock
            .lock()
            .map_err(|_| detail("workspace patch attempt store is unavailable"))?;
        let mut names: Vec<String> = match fs::read_dir(&self.root) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                .collect(),
            Err(_) => Vec::new(),
        };
        names.sort();
        let mut attempts = Vec::new();
        for name in names {
            if !name.starts_with("patch-") || !name.ends_with(".json") {
                continue;
            }
            let attempt = Self::read(&format!("{}/{name}", self.root))
                .ok_or_else(|| detail("workspace patch lineage has an unreadable link"))?;
            if attempt.project_ref == project_ref {
                attempts.push(attempt);
            }
        }
        attempts.sort_by(|left, right| left.applied_at_utc.cmp(&right.applied_at_utc));
        Ok(attempts)
    }
}

// MARK: - The tool

/// One run of a workspace preset's pinned executable, as Swift's
/// descriptor-bound dispatcher runs a workspace process plan.
pub struct ToolInvocation<'a> {
    /// The executable the profile pinned, and the digest it was pinned by.
    pub executable_path: &'a str,
    pub executable_sha256: &'a str,
    /// Swift `ProcessRequest.argumentZero`: the role a multi-call executable
    /// runs as; `None` names the executable itself.
    pub argument_zero: Option<&'a str>,
    pub arguments: &'a [String],
    /// Overlaid on the clean base environment: what Swift's composition names
    /// for this executable (`childEnvironmentByExecutablePath`) and the parts
    /// of its own base a build needs.
    pub environment: &'a [(String, String)],
    /// The files the executable reads, each opened by its pinned identity
    /// before the spawn and held until the child is gone (Swift's verified
    /// resources for this executable).
    pub resources: &'a [crate::workspace_profile::VerifiedResource],
    /// The project root the argv names; the child runs in it.
    pub working_directory: &'a str,
    pub timeout_seconds: i64,
}

/// What a tool child left: its status and both streams, as captured.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolReceipt {
    pub exit_status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Either stream produced more than it kept.
    pub truncated: bool,
}

/// Swift `RuntimeDispatchFailure` before a receipt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolFailure {
    /// The child never ran tool code, or ran and was proven not to matter:
    /// the step fails.
    Failed(String),
    /// What the child did cannot be observed: the intent stays outstanding.
    OutcomeUnknown(String),
}

/// The dispatch port a workspace patch step runs its tool through.
pub trait WorkspaceToolDispatch: Send + Sync {
    fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure>;
}

/// The production dispatch: the executable opened by the digest its profile
/// pinned and started from its retained inode, argv only, no shell, the
/// clean base environment plus the invocation's overlay, `/dev/null` as stdin
/// and each stream bounded; every verified resource opened by its pinned
/// identity first and held until the child is gone.
pub struct VerifiedToolDispatch;

impl WorkspaceToolDispatch for VerifiedToolDispatch {
    fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
        use arkdeck_platform::{
            ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedSource, VerifiedTool,
        };
        use std::os::unix::fs::PermissionsExt;
        let refused = |error: &dyn std::fmt::Display| {
            ToolFailure::Failed(format!("dispatch refused: {error}"))
        };
        // Swift opens every resource before the spawn; one that no longer
        // measures as pinned refuses the dispatch, and nothing runs.
        let held = invocation
            .resources
            .iter()
            .map(|resource| {
                let source = VerifiedSource::open(
                    Path::new(&resource.path),
                    &resource.sha256,
                    resource.byte_count,
                )
                .ok()?;
                let executable = fs::metadata(&resource.path)
                    .is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0);
                (!resource.require_executable || executable).then_some(source)
            })
            .collect::<Option<Vec<VerifiedSource>>>()
            .ok_or_else(|| ToolFailure::Failed("dispatch resource identity refused".into()))?;
        let mut tool = VerifiedTool::open(invocation.executable_path, invocation.executable_sha256)
            .map_err(|error| refused(&error))?;
        if let Some(zero) = invocation.argument_zero {
            tool = tool.with_argument_zero(zero);
        }
        let environment: Vec<(std::ffi::OsString, std::ffi::OsString)> = invocation
            .environment
            .iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect();
        // The child runs in the directory the argv names; the spawn needs its
        // physical spelling.
        let directory =
            fs::canonicalize(invocation.working_directory).map_err(|error| refused(&error))?;
        let arguments: Vec<std::ffi::OsString> = invocation
            .arguments
            .iter()
            .map(std::ffi::OsString::from)
            .collect();
        let timeout = u64::try_from(invocation.timeout_seconds.max(1)).unwrap_or(1);
        let request = ToolRequest {
            arguments: &arguments,
            environment: &environment,
            working_directory: Some(&directory),
            limits: ToolLimits {
                timeout: std::time::Duration::from_secs(timeout),
                capture_bytes: CAPTURE_BYTES,
            },
        };
        // A workspace step is cancelled at its safe boundaries, never
        // mid-child.
        let ran = tool.run_tool(&request, &|| false);
        drop(held);
        match ran {
            Err(ToolRunError::Refused(error)) => Err(refused(&error)),
            Err(ToolRunError::Unobservable(error)) => Err(ToolFailure::OutcomeUnknown(format!(
                "dispatch outcome unobservable: {error}"
            ))),
            Ok(execution) => match execution.termination {
                ToolTermination::Exited(status) => Ok(ToolReceipt {
                    exit_status: status,
                    stdout: execution.stdout,
                    stderr: execution.stderr,
                    truncated: execution.truncated,
                }),
                ToolTermination::TimedOut => Err(ToolFailure::OutcomeUnknown(
                    "process timed out before completion".into(),
                )),
                ToolTermination::Signalled(signal) => Err(ToolFailure::OutcomeUnknown(format!(
                    "process died on signal {signal}; the child never reached its own semantic \
                     boundary. Its crash report is in ~/Library/Logs/DiagnosticReports/ (look for \
                     a same-second entry named after the executable)."
                ))),
                ToolTermination::Cancelled { .. } => Err(ToolFailure::OutcomeUnknown(
                    "dispatch task cancellation carried no process-group drain proof".into(),
                )),
            },
        }
    }
}

/// Swift `outputSummary(_:)`.
pub(crate) fn output_summary(receipt: &ToolReceipt) -> Map<String, Value> {
    Map::from_iter([
        ("exitStatus".into(), json!(receipt.exit_status.to_string())),
        (
            "stdoutByteCount".into(),
            json!(receipt.stdout.len().to_string()),
        ),
        (
            "stderrByteCount".into(),
            json!(receipt.stderr.len().to_string()),
        ),
        (
            "stdoutSHA256".into(),
            json!(support::sha256(&receipt.stdout)),
        ),
        (
            "stderrSHA256".into(),
            json!(support::sha256(&receipt.stderr)),
        ),
    ])
}

/// Swift `failed(_:_:)`'s detail.
pub(crate) fn failed_detail(receipt: &ToolReceipt) -> String {
    format!(
        "real process exit={} stdoutBytes={} stderrBytes={}",
        receipt.exit_status,
        receipt.stdout.len(),
        receipt.stderr.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_unified_diff_declares_its_paths_as_swift_reads_them() {
        let diff = b"--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1 @@\n-old\n+new\n";
        assert_eq!(patch_paths(diff).unwrap(), ["Sources/App.txt"]);
        let git = b"diff --git a/b.txt b/a.txt\n--- a/b.txt\t2026\n+++ b/a.txt\n";
        assert_eq!(patch_paths(git).unwrap(), ["a.txt", "b.txt"]);
        let created = b"--- /dev/null\n+++ b/New.txt\n";
        assert_eq!(patch_paths(created).unwrap(), ["New.txt"]);
        let bom = "\u{feff}--- a/x\n+++ b/x\n".as_bytes();
        assert_eq!(patch_paths(bom).unwrap(), ["x"]);
        for (diff, refusal) in [
            (
                &b"no header\n"[..],
                "workspace patch must touch 1...128 declared files",
            ),
            (
                b"--- a/../x\n",
                "workspace unified diff carries an unsafe path",
            ),
            (
                b"--- a//x\n",
                "workspace unified diff carries an unsafe path",
            ),
            (
                b"--- a/.git/config\n",
                "workspace unified diff carries an unsafe path",
            ),
            (
                b"--- x/y\n",
                "workspace unified diff carries an unsafe path",
            ),
            (
                b"--- a/x\\y\n",
                "workspace unified diff carries an unsafe path",
            ),
            (
                b"diff --git a/x b/y c\n",
                "workspace diff header carries an unsafe path",
            ),
            (
                b"rename from x\n",
                "workspace binary/rename/copy patches are not supported",
            ),
            (
                b"--- a/x\0\n",
                "workspace patch must be bounded UTF-8 unified diff",
            ),
            (
                b"--- a/\xff\n",
                "workspace patch must be bounded UTF-8 unified diff",
            ),
        ] {
            assert_eq!(patch_paths(diff).unwrap_err(), refusal, "{diff:?}");
        }
        // A carriage return and its line feed are one Character, so a CRLF
        // diff is one line to Swift, whose one declared path no scope glob
        // matches: `**` stops at a line terminator.
        assert_eq!(
            patch_paths(b"--- a/x\r\n+++ b/x\r\n").unwrap(),
            ["x\r\n+++ b/x\r\n"]
        );
        assert!(!matches("x\r\n+++ b/x\r\n", "**"));
    }

    #[test]
    fn the_snapshot_revision_is_swifts() {
        let snapshots = vec![
            FileSnapshot {
                relative_path: "b".into(),
                sha256: None,
            },
            FileSnapshot {
                relative_path: "a".into(),
                sha256: Some("0".repeat(64)),
            },
        ];
        assert_eq!(
            revision(&snapshots),
            support::sha256(format!("a\t{}\nb\tabsent", "0".repeat(64)).as_bytes())
        );
    }

    fn attempt(before: &str, after: &str, applied: &str, reverted: bool) -> PatchAttempt {
        PatchAttempt {
            patch_attempt_ref: format!("patch-{}", "0".repeat(32)),
            project_ref: "evolution-x".into(),
            project_root: "/tmp/x".into(),
            patch_artifact_id: "ART-x".into(),
            patch_file_path: "/tmp/x.patch".into(),
            patch_sha256: "0".repeat(64),
            allowed_file_globs: vec!["a".into()],
            before: Vec::new(),
            after: Vec::new(),
            workspace_revision_before: Some(before.into()),
            workspace_revision_after: Some(after.into()),
            applied_at_utc: applied.into(),
            reverted_at_utc: reverted.then(|| applied.to_owned()),
        }
    }

    #[test]
    fn the_lineage_vouches_only_for_an_unbroken_chain() {
        let applied = attempt("r0", "r1", "2026-09-20T00:00:01Z", false);
        let reverted = attempt("r0", "r1", "2026-09-20T00:00:01Z", true);
        let next = attempt("r1", "r2", "2026-09-20T00:00:02Z", false);
        assert_eq!(lineage_derived_revision("r0", &[]).as_deref(), Some("r0"));
        assert_eq!(
            lineage_derived_revision("r0", std::slice::from_ref(&applied)).as_deref(),
            Some("r1")
        );
        assert_eq!(
            lineage_derived_revision("r0", &[reverted]).as_deref(),
            Some("r0")
        );
        assert_eq!(
            lineage_derived_revision("r0", &[next.clone(), applied.clone()]).as_deref(),
            Some("r2"),
            "ordered by when each was applied"
        );
        assert_eq!(
            lineage_derived_revision("r0", &[next]),
            None,
            "a broken link"
        );
        let mut unmeasured = applied;
        unmeasured.workspace_revision_after = None;
        assert_eq!(lineage_derived_revision("r0", &[unmeasured]), None);
    }

    #[test]
    fn an_action_round_trips_its_persisted_form() {
        let intent = PatchIntent {
            invocation: Invocation {
                operation: "workspace.apply-patch@1".into(),
                project_ref: "evolution-x".into(),
                project_root: "/tmp/x".into(),
                preset_id: "patch".into(),
                executable_path: "/usr/bin/patch".into(),
                executable_sha256: "0".repeat(64),
                argument_zero: None,
                arguments: vec!["-f".into()],
                timeout_seconds: 120,
            },
            patch_attempt_ref: format!("patch-{}", "1".repeat(32)),
            patch_artifact_id: "ART-x".into(),
            patch_file_path: "/tmp/p".into(),
            patch_sha256: "2".repeat(64),
            allowed_file_globs: vec!["a".into()],
            before: vec![FileSnapshot {
                relative_path: "a".into(),
                sha256: None,
            }],
            previous_workspace_revision: None,
        };
        let action = PatchAction::Apply(intent);
        let persisted = action.persisted().unwrap();
        assert_eq!(PatchAction::materialize(&persisted).unwrap(), action);
        let revert = PatchAction::Revert(RevertIntent {
            invocation: action.invocation().clone(),
            attempt: attempt("r0", "r1", "t", false),
        });
        assert_eq!(
            PatchAction::materialize(&revert.persisted().unwrap()).unwrap(),
            revert
        );
        assert!(PatchAction::materialize(&json!({"kind": "analyzer.analyze"})).is_err());
    }
}
