//! Frozen WorkflowStep argument and minimum-policy validation for offline
//! Session inventory. This module only reads historical JSON; it cannot
//! authorize, materialize or execute an operation.
use crate::session_graphemes::{graphemes, indices};
use crate::session_manifest::{ManifestError, Object, Result, hash, identifier, object, require};
use serde_json::Value;
use std::collections::BTreeSet;

pub(super) struct Policy {
    pub effect: usize,
    pub cancellation: usize,
    pub binding: usize,
    pub exact_binding: bool,
}
const HOST: Policy = Policy {
    effect: 0,
    cancellation: 0,
    binding: 0,
    exact_binding: false,
};
const HOST_BOUNDARY: Policy = Policy {
    effect: 0,
    cancellation: 1,
    binding: 0,
    exact_binding: false,
};
const READ: Policy = Policy {
    effect: 1,
    cancellation: 0,
    binding: 1,
    exact_binding: false,
};
const MUTATION: Policy = Policy {
    effect: 2,
    cancellation: 1,
    binding: 1,
    exact_binding: false,
};
const DESTRUCTIVE: Policy = Policy {
    effect: 3,
    cancellation: 2,
    binding: 1,
    exact_binding: false,
};

struct Reader<'a> {
    row: &'a Object,
    allowed: BTreeSet<&'static str>,
}
impl<'a> Reader<'a> {
    fn get(&mut self, key: &'static str) -> Result<&'a Value> {
        self.allowed.insert(key);
        self.row.get(key).ok_or(ManifestError::Invalid)
    }
    fn present(&mut self, key: &'static str) -> bool {
        self.allowed.insert(key);
        self.row.contains_key(key)
    }
    fn string(&mut self, key: &'static str, minimum: usize, maximum: usize) -> Result<&'a str> {
        let s = self.get(key)?.as_str().ok_or(ManifestError::Invalid)?;
        require((minimum..=maximum).contains(&s.chars().count()))?;
        Ok(s)
    }
    fn id(&mut self, key: &'static str) -> Result<()> {
        require(identifier(self.string(key, 1, 128)?))
    }
    fn ids(&mut self, names: &[&'static str]) -> Result<()> {
        names.iter().try_for_each(|key| self.id(key))
    }
    fn sha(&mut self, key: &'static str) -> Result<()> {
        require(hash(self.string(key, 64, 64)?))
    }
    fn choice(&mut self, key: &'static str, values: &[&str]) -> Result<&'a str> {
        let s = self.string(key, 0, usize::MAX)?;
        require(values.contains(&s))?;
        Ok(s)
    }
    fn integer(&mut self, key: &'static str, minimum: u64, maximum: u64) -> Result<()> {
        require(integer(self.get(key)?, minimum, maximum))
    }
    fn optional_integer(&mut self, key: &'static str, minimum: u64, maximum: u64) -> Result<()> {
        if self.present(key) && !self.row[key].is_null() {
            self.integer(key, minimum, maximum)?;
        }
        Ok(())
    }
    fn name(&mut self, key: &'static str, maximum: usize) -> Result<()> {
        let s = self.string(key, 1, maximum)?;
        require(
            s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)),
        )
    }
    fn remote(&mut self, key: &'static str) -> Result<()> {
        let s = self.string(key, 2, 1024)?;
        require(
            graphemes(s).next() == Some("/")
                && !s.chars().any(control)
                && !path_segments(s)
                    .into_iter()
                    .skip(1)
                    .any(|part| [".", ".."].contains(&part)),
        )
    }
    fn relative(&mut self, key: &'static str) -> Result<()> {
        let s = self.string(key, 1, 1024)?;
        require(
            graphemes(s).next() != Some("/")
                && path_segments(s).into_iter().all(|part| {
                    !part.is_empty()
                        && ![".", ".."].contains(&part)
                        && !graphemes(part)
                            .next_back()
                            .is_some_and(|last| [".", " "].contains(&last))
                        && !part
                            .chars()
                            .any(|c| control(c) || "<>:\"/\\|?*".contains(c))
                }),
        )
    }
    fn action(&mut self, key: &'static str) -> Result<()> {
        let s = self.string(key, 1, 128)?;
        require(
            s.as_bytes()[0].is_ascii_alphabetic()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".-".contains(&b))
                && !["runhdc", "runremotetool", "shell", "exec", "command"]
                    .contains(&s.to_ascii_lowercase().as_str()),
        )
    }
    fn options(&mut self, key: &'static str) -> Result<&'a Object> {
        let options = object(self.get(key)?)?;
        require(options.len() <= 128)?;
        for (key, value) in options {
            require(
                (1..=64).contains(&key.len())
                    && key.as_bytes()[0].is_ascii_alphabetic()
                    && key
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)),
            )?;
            if let Some(values) = value.as_array() {
                require(values.len() <= 256 && values.iter().all(|v| scalar(v, false)))?;
            } else {
                require(scalar(value, true))?;
            }
        }
        Ok(options)
    }
    fn identifier_array(&mut self, key: &'static str) -> Result<()> {
        let a = self.get(key)?.as_array().ok_or(ManifestError::Invalid)?;
        let mut seen = BTreeSet::new();
        require(!a.is_empty())?;
        for v in a {
            let s = v.as_str().ok_or(ManifestError::Invalid)?;
            require(identifier(s) && seen.insert(s))?;
        }
        Ok(())
    }
    fn globs(&mut self) -> Result<()> {
        let a = self
            .get("allowedFileGlobs")?
            .as_array()
            .ok_or(ManifestError::Invalid)?;
        require(
            (1..=64).contains(&a.len())
                && a.iter().all(|v| {
                    v.as_str()
                        .is_some_and(|s| !s.is_empty() && s.len() <= 512 && !s.contains('\0'))
                }),
        )
    }
}
fn integer(v: &Value, minimum: u64, maximum: u64) -> bool {
    v.as_u64().is_some_and(|n| (minimum..=maximum).contains(&n))
}
fn path_segments(s: &str) -> Vec<&str> {
    let mut result = Vec::new();
    let mut start = 0;
    for (index, character) in indices(s) {
        if character == "/" {
            result.push(&s[start..index]);
            start = index + 1;
        }
    }
    result.push(&s[start..]);
    result
}
fn control(c: char) -> bool {
    c <= '\u{1f}' || c == '\u{7f}'
}
fn scalar(v: &Value, null_allowed: bool) -> bool {
    match v {
        Value::Null => null_allowed,
        Value::Bool(_) | Value::Number(_) => true,
        Value::String(s) => s.chars().count() <= 4096,
        _ => false,
    }
}
fn safe_keys(v: &Value) -> bool {
    match v {
        Value::Object(row) => row.iter().all(|(key, v)| {
            ![
                "argv",
                "command",
                "commandline",
                "executable",
                "hdcarguments",
                "rawarguments",
                "shell",
            ]
            .contains(&key.to_lowercase().as_str())
                && safe_keys(v)
        }),
        Value::Array(a) => a.iter().all(safe_keys),
        _ => true,
    }
}

fn diagnostics(action: &str, options: &Object) -> Result<()> {
    let required: &[&str] = match action {
        "boundedHilog" => &["durationSeconds", "filters", "byteBudget"],
        "componentDetail" => &["byteBudget", "windowId", "componentId"],
        "crashLog" => &["byteBudget", "faultLogName"],
        _ => &["byteBudget"],
    };
    require(options.len() == required.len() && required.iter().all(|k| options.contains_key(*k)))?;
    require(integer(
        &options["byteBudget"],
        1024,
        if action == "boundedHilog" {
            134_217_728
        } else {
            67_108_864
        },
    ))?;
    match action {
        "boundedHilog" => {
            require(integer(&options["durationSeconds"], 1, 600))?;
            let filters = options["filters"]
                .as_array()
                .ok_or(ManifestError::Invalid)?;
            require(
                filters.len() <= 16
                    && filters.iter().all(|v| {
                        v.as_str().is_some_and(|s| {
                            (1..=200).contains(&s.len())
                                && s.bytes()
                                    .all(|b| b.is_ascii_alphanumeric() || b":*./_-".contains(&b))
                        })
                    }),
            )?;
        }
        "componentDetail" => {
            for key in ["windowId", "componentId"] {
                let s = options[key].as_str().ok_or(ManifestError::Invalid)?;
                require((1..=20).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit()))?;
            }
        }
        "crashLog" => {
            let s = options["faultLogName"]
                .as_str()
                .ok_or(ManifestError::Invalid)?;
            require(graphemes(s).take(201).count() <= 200)?;
            let (prefix, rest) = s.split_once('-').ok_or(ManifestError::Invalid)?;
            require(
                !prefix.is_empty()
                    && prefix.bytes().all(|b| b.is_ascii_lowercase())
                    && (1..=180).contains(&rest.len())
                    && rest
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)),
            )?;
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn validate(kind: &str, row: &Object) -> Result<Policy> {
    let mut r = Reader {
        row,
        allowed: BTreeSet::new(),
    };
    let policy = match kind {
        "probeHostTool" => {
            r.id("toolIdentity")?;
            r.string("candidatePath", 1, usize::MAX)?;
            if r.present("expectedSha256") {
                r.sha("expectedSha256")?;
            }
            HOST
        }
        "probeHDCServer" => {
            r.string("endpoint", 1, usize::MAX)?;
            r.id("clientIdentity")?;
            r.optional_integer("expectedServerGeneration", 0, u64::MAX)?;
            HOST
        }
        "mutateHDCServerLifecycle" => {
            let action = r.choice(
                "action",
                &[
                    "startManaged",
                    "stopConfirmedGeneration",
                    "restartConfirmedGeneration",
                ],
            )?;
            r.string("endpoint", 1, usize::MAX)?;
            r.sha("impactSnapshotHash")?;
            if action == "startManaged" {
                require(r.get("expectedGeneration")?.is_null())?;
                r.choice("expectedOwnership", &["absent"])?;
                require(r.get("confirmationId")?.is_null())?;
            } else {
                r.integer("expectedGeneration", 0, u64::MAX)?;
                r.choice(
                    "expectedOwnership",
                    &["arkDeckManaged", "external", "unknown"],
                )?;
                r.id("confirmationId")?;
            }
            Policy {
                effect: 3,
                cancellation: 1,
                binding: 0,
                exact_binding: true,
            }
        }
        "probeDevice" => {
            r.id("evidencePolicy")?;
            READ
        }
        "captureRemoteStdout" | "captureRemoteFile" => {
            let file = kind == "captureRemoteFile";
            let catalog = r.choice(
                "catalogId",
                if file {
                    &["arkui-ui-dump", "trace-presets"]
                } else {
                    &["arkui-ui-dump", "arkdeck-diagnostics"]
                },
            )?;
            let action = r.choice(
                "actionId",
                match catalog {
                    "arkui-ui-dump" => &[
                        "nodeSummary",
                        "elementTree",
                        "fullDefaultTree",
                        "componentDetail",
                        "renderTreeLegacy",
                    ],
                    "trace-presets" => &[
                        "attachmentPanorama",
                        "arkuiDeep",
                        "renderAnimation",
                        "schedulingIpc",
                        "io",
                        "custom",
                    ],
                    _ => &[
                        "boundedHilog",
                        "componentTree",
                        "componentDetail",
                        "crashIndex",
                        "crashLog",
                        "windowInventory",
                    ],
                },
            )?;
            let options = r.options("parameters")?;
            if catalog == "arkdeck-diagnostics" {
                diagnostics(action, options)?;
            }
            r.id("artifactId")?;
            if file {
                r.remote("ownedRemotePath")?;
                MUTATION
            } else {
                READ
            }
        }
        "stopRemoteCapture" => {
            r.ids(&["captureStepId", "stopPolicy"])?;
            MUTATION
        }
        "sendFile" => {
            r.id("sourceArtifactId")?;
            r.remote("remotePath")?;
            r.sha("sourceSha256")?;
            if r.present("overwritePolicy") {
                r.choice("overwritePolicy", &["forbid", "replaceOwnedPath"])?;
            }
            MUTATION
        }
        "receiveFile" => {
            r.remote("remotePath")?;
            r.id("artifactId")?;
            r.relative("localRelativePath")?;
            if r.present("expectedSha256") {
                r.sha("expectedSha256")?;
            }
            READ
        }
        "snapshotParameter" => {
            r.name("name", 255)?;
            READ
        }
        "setParameter" => {
            r.name("name", 255)?;
            r.string("value", 0, 4096)?;
            r.choice("readbackPolicy", &["required"])?;
            MUTATION
        }
        "restoreParameter" => {
            r.name("name", 255)?;
            r.id("snapshotStepId")?;
            r.choice(
                "restorePolicy",
                &["restoreKnownValue", "persistentChangeNoRestore"],
            )?;
            MUTATION
        }
        "waitForDisconnect" | "waitForReconnect" => {
            r.integer("deadlineMilliseconds", 1, 86_400_000)?;
            r.id("reason")?;
            READ
        }
        "verifyRemoteState" => {
            r.id("probeId")?;
            r.string("expectedState", 1, 256)?;
            READ
        }
        "verifyArtifact" | "hashFile" => {
            r.id("artifactId")?;
            if r.present("validationPolicy") {
                r.id("validationPolicy")?;
            }
            HOST
        }
        "preflightHostStorage" => {
            r.id("volumeIdentity")?;
            r.integer("requiredBytes", 0, u64::MAX)?;
            r.integer("metadataHeadroomBytes", 1, u64::MAX)?;
            r.choice("writerClass", &["light", "heavy", "unknown"])?;
            HOST
        }
        "preflightDeviceStorage" => {
            r.remote("remotePath")?;
            r.integer("requiredBytes", 0, u64::MAX)?;
            READ
        }
        "postprocessArtifact" => {
            r.identifier_array("inputArtifactIds")?;
            r.ids(&["outputArtifactId", "processorId"])?;
            r.options("parameters")?;
            HOST
        }
        "cleanupOwnedRemotePath" => {
            r.remote("remotePath")?;
            r.id("ownershipEvidenceId")?;
            // Current Swift metadata permits this key without a typed value
            // constraint; preserve that behavior and still check unsafe keys.
            r.present("framesDirectory");
            MUTATION
        }
        "requestConfirmation" => {
            r.ids(&["confirmationId", "promptKey"])?;
            r.choice(
                "riskClass",
                &[
                    "deviceMutation",
                    "destructive",
                    "serverLifecycle",
                    "recoveryAbandon",
                    "securityBoundary",
                ],
            )?;
            r.sha("scopeHash")?;
            HOST
        }
        "installPackage" | "uninstallPackage" => {
            r.string("packageName", 1, 255)?;
            if kind == "installPackage" {
                r.id("packageArtifactId")?;
                r.choice("replacePolicy", &["forbid", "allow"])?;
            }
            MUTATION
        }
        "startApplication" | "stopApplication" => {
            r.string("bundleName", 1, 255)?;
            r.string("abilityName", 1, 255)?;
            if r.present("parameters") {
                r.options("parameters")?;
            }
            MUTATION
        }
        "createPortForward" => {
            r.id("forwardId")?;
            r.string("hostEndpoint", 1, 255)?;
            r.string("deviceEndpoint", 1, 255)?;
            MUTATION
        }
        "removePortForward" => {
            r.id("forwardId")?;
            MUTATION
        }
        "injectPointerInput" => {
            let gesture = r.choice("gesture", &["tap", "longPress", "swipe"])?;
            r.integer("pointerX", 0, 32767)?;
            r.integer("pointerY", 0, 32767)?;
            if gesture == "swipe" {
                r.integer("pointerToX", 0, 32767)?;
                r.integer("pointerToY", 0, 32767)?;
                r.integer("durationMs", 80, 2000)?;
            } else {
                r.optional_integer("pointerToX", 0, 32767)?;
                r.optional_integer("pointerToY", 0, 32767)?;
                r.optional_integer("durationMs", 80, 2000)?;
            }
            r.optional_integer("displayId", 0, 64)?;
            r.optional_integer("displayWidth", 1, 32767)?;
            r.optional_integer("displayHeight", 1, 32767)?;
            MUTATION
        }
        "clearLogBuffer" => {
            r.ids(&["bufferId", "confirmationId"])?;
            MUTATION
        }
        "resizeLogBuffer" => {
            r.id("bufferId")?;
            r.integer("sizeBytes", 1, u64::MAX)?;
            r.choice(
                "restorePolicy",
                &["restoreSnapshot", "persistentChangeNoRestore"],
            )?;
            MUTATION
        }
        "startDeviceLogPersist" => {
            r.ids(&["profileId", "artifactSeriesId"])?;
            r.integer("rotationBytes", 1, u64::MAX)?;
            r.integer("retainedSegments", 1, 10_000)?;
            MUTATION
        }
        "runApprovedRemoteRead" | "runApprovedRemoteMutation" => {
            let mutation = kind == "runApprovedRemoteMutation";
            r.choice("catalogId", &["arkdeck-remote-operations"])?;
            r.choice(
                "actionId",
                if mutation {
                    &[
                        "requestRootMode",
                        "nativeLibraryBackup",
                        "nativeLibraryAtomicPublish",
                        "nativeLibraryRollback",
                    ]
                } else {
                    &[
                        "deviceSummary",
                        "systemProperties",
                        "processList",
                        "packageInfo",
                        "storageUsage",
                        "deviceModel",
                        "firmwareBuild",
                        "nativeLibraryInspection",
                        "debugTemplate",
                    ]
                },
            )?;
            r.options("parameters")?;
            r.id("artifactId")?;
            if r.present("semanticResultPolicy") {
                r.id("semanticResultPolicy")?;
            }
            if mutation {
                r.id("confirmationId")?;
                MUTATION
            } else {
                READ
            }
        }
        "rebootDevice" => {
            r.choice(
                "targetMode",
                &["normal", "recovery", "updater", "providerDefined"],
            )?;
            r.id("reason")?;
            MUTATION
        }
        "enterUpdater" => {
            r.action("providerOperationId")?;
            r.string("expectedMode", 1, 128)?;
            r.integer("reconnectDeadlineMilliseconds", 1, 86_400_000)?;
            MUTATION
        }
        "flashPartition" | "updatePackage" | "erasePartition" | "formatPartition"
        | "unlockDevice" => {
            r.action("providerOperationId")?;
            r.ids(&["confirmationId", "safeBoundaryId"])?;
            match kind {
                "flashPartition" => {
                    r.name("partition", 128)?;
                    r.id("imageArtifactId")?;
                    r.sha("imageSha256")?;
                    r.integer("imageSize", 1, u64::MAX)?;
                }
                "updatePackage" => {
                    r.id("packageArtifactId")?;
                    r.sha("packageSha256")?;
                    r.integer("packageSize", 1, u64::MAX)?;
                }
                "unlockDevice" => r.sha("scopeHash")?,
                _ => {
                    r.name("partition", 128)?;
                    if kind == "formatPartition" {
                        r.string("formatType", 1, 64)?;
                    }
                }
            }
            DESTRUCTIVE
        }
        "inspectWorkspaceSource" => {
            r.ids(&["projectRef", "artifactId"])?;
            r.string("symbol", 1, 200)?;
            r.string("fileScope", 1, 120)?;
            HOST
        }
        "prepareWorkspaceIsolation" => {
            r.ids(&["sourceProjectRef", "workspaceProjectRef", "artifactId"])?;
            for k in [
                "expectedWorkspaceRevision",
                "workspaceRevision",
                "allowedFileScopesDigest",
            ] {
                r.sha(k)?;
            }
            HOST_BOUNDARY
        }
        "sweepWorkspaceIsolation" => {
            r.integer("retainLatestCount", 0, 64)?;
            r.integer("minimumQuiescentSeconds", 0, 7_776_000)?;
            r.string("dryRun", 4, 5)?;
            r.id("artifactId")?;
            HOST_BOUNDARY
        }
        "inspectWorkspaceGitStatus" | "createWorkspaceCheckpoint" => {
            r.ids(&["projectRef", "artifactId"])?;
            if kind == "createWorkspaceCheckpoint" {
                HOST_BOUNDARY
            } else {
                HOST
            }
        }
        "inspectWorkspaceDiff" => {
            r.ids(&["projectRef", "artifactId"])?;
            r.string("baseRevision", 1, 120)?;
            r.string("pathScope", 1, 120)?;
            HOST
        }
        "readWorkspaceSourceRange" => {
            r.ids(&["projectRef", "artifactId"])?;
            r.string("filePath", 1, 240)?;
            r.integer("lineStart", 1, 1_000_000)?;
            r.integer("lineEnd", 1, 1_000_000)?;
            HOST
        }
        "runDeterministicAnalyzer" => {
            r.choice(
                "analyzerRef",
                &[
                    "crash-signature@1",
                    "hilog-summary@1",
                    "trace-summary@1",
                    "trace-analysis@1",
                ],
            )?;
            r.ids(&["inputArtifactId", "artifactId"])?;
            HOST
        }
        "applyWorkspacePatch" => {
            r.ids(&["projectRef", "patchArtifactId", "patchAttemptRef"])?;
            r.sha("patchSha256")?;
            r.globs()?;
            HOST_BOUNDARY
        }
        "buildWorkspaceOpenHarmony" => {
            r.ids(&["projectRef", "buildPresetRef"])?;
            HOST
        }
        "signWorkspaceOpenHarmonyHap" => {
            r.ids(&["projectRef", "inputArtifactId"])?;
            r.sha("inputSha256")?;
            let s = r.string("signingPresetRef", 1, usize::MAX)?;
            require(
                s == "openharmony-release@1"
                    || (s.starts_with("preset-") && s.len() > 7 && identifier(s)),
            )?;
            HOST_BOUNDARY
        }
        "runWorkspaceTests" => {
            r.ids(&["projectRef", "testPresetRef"])?;
            HOST
        }
        "symbolizeWorkspaceCrash" => {
            r.ids(&["projectRef", "dumpArtifactId", "symbolPresetRef"])?;
            r.sha("dumpSha256")?;
            HOST
        }
        "revertWorkspacePatch" => {
            r.ids(&["projectRef", "patchAttemptRef"])?;
            HOST_BOUNDARY
        }
        "finalizeSession" => {
            r.id("sessionId")?;
            r.choice("publicationPolicy", &["atomicAfterValidation"])?;
            HOST_BOUNDARY
        }
        _ => return Err(ManifestError::Invalid),
    };
    require(row.keys().all(|key| r.allowed.contains(key.as_str())) && row.values().all(safe_keys))?;
    Ok(policy)
}
