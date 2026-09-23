//! The legs of `capture.diagnostics@1` beyond its default request, as Swift's
//! HDC provider (`HDCObservationProviderAdapter`) chooses, lowers, runs and
//! judges them: the file products — a trace (`hitrace`, blocking or as an
//! armed ring with a coverage anchor), the component tree (`uitest
//! dumpLayout`), a screenshot (`snapshot_display`) and a bounded screen
//! sequence (`snapshot_display` per frame, `tar`) — each written to a
//! provider-owned path under `/data/local/tmp`, judged by its `ls -l`
//! readback rather than by the client's exit status, received onto the host
//! with `file recv` and judged by the bytes that landed, and cleaned up by
//! name; and the stdout legs the default request leaves unselected — the
//! device's crash ledger (`hidumper -s 1201`), the component detail dump
//! and the application liveness readback (`pidof`).
//!
//! What runs a lowered plan is an [`HdcDispatch`]; [`run`] is Swift's
//! sequence rule (stop at the first non-zero exit unless the invocation
//! continues past one) and its host landing (prepared before, inspected
//! after, whatever the exit). The default legs (`hilog -x`, the window
//! inventory), the storage preflight and the observe steps are
//! [`crate::Action`]'s; the Job's products, index and summary are the store
//! owner's.
use crate::{DispatchFailure, HdcDispatch, Outcome, Persisted, ProcessPlan, Receipt, RequestError};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::io::{self, Read};
#[cfg(unix)]
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Swift `DescriptorBoundProcessDispatcher`'s default capture: every leg
/// here leaves the dispatcher's own bound in place.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;
/// Swift's byte budget for the crash ledger reads.
pub const STDOUT_BUDGET: i64 = 8 * 1024 * 1024;
/// Swift's bound on a received artifact.
pub const RECEIVE_MAXIMUM_BYTES: i64 = 64 * 1024 * 1024;
/// The provider's fixed staging root on the device.
const STAGING_ROOT: &str = "/data/local/tmp";
/// Swift `HDCObservationProviderAdapter.traceMarkerPath` / `traceRingPath`.
const TRACE_MARKER_PATH: &str = "/sys/kernel/tracing/trace_marker";
const TRACE_RING_PATH: &str = "/sys/kernel/tracing/trace";
/// Swift `HDCFileMagic`: what `snapshot_display` writes for each type. The
/// JFIF prefix stops at four bytes because the two after it are the APP0
/// segment length, which is not fixed.
pub const PNG_MAGIC: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
pub const JFIF_MAGIC: [u8; 4] = [0xFF, 0xD8, 0xFF, 0xE0];
/// Swift `HDCTraceCaptureRequest`'s bounds.
const MAXIMUM_TRACE_SECONDS: i64 = 120;
const MAXIMUM_TRACE_CATEGORIES: usize = 24;
/// Swift `HDCScreenSequenceRequest.maximumFrames`.
const MAXIMUM_FRAMES: i64 = 300;
/// Swift `HDCUIDumpRequest`'s default budget, which its persisted form names.
const UI_DUMP_BUDGET: i64 = 8 * 1024 * 1024;

/// Swift `HDCScreenSequenceRequest.ImageType`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ImageType {
    Png,
    Jpeg,
}

impl ImageType {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "png" => Some(Self::Png),
            "jpeg" => Some(Self::Jpeg),
            _ => None,
        }
    }

    /// The leading bytes a received still of this type must begin with.
    pub fn magic(self) -> &'static [u8] {
        match self {
            Self::Png => &PNG_MAGIC,
            Self::Jpeg => &JFIF_MAGIC,
        }
    }
}

/// Swift's bounded path component: `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
fn bounded_component(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && value.len() <= 128
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn component_field(field: &'static str, value: &str) -> Result<(), RequestError> {
    if bounded_component(value) {
        Ok(())
    } else {
        Err(RequestError::Malformed {
            field,
            detail: "provider-owned path components must be bounded identifiers",
        })
    }
}

/// Swift `HDCOwnedRemotePath`: a provider-owned temporary file on the
/// device, minted from the Job, the producing step and a nonce — the caller
/// never supplies a device path — with the suffix the producer's tool
/// requires (`snapshot_display` refuses a name whose suffix disagrees with
/// the requested type).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnedRemotePath {
    pub job_id: String,
    pub step_id: String,
    pub nonce: String,
    pub remote_path: String,
}

impl OwnedRemotePath {
    pub fn new(
        job_id: &str,
        step_id: &str,
        nonce: &str,
        image_type: ImageType,
    ) -> Result<Self, RequestError> {
        component_field("jobID", job_id)?;
        component_field("stepID", step_id)?;
        component_field("nonce", nonce)?;
        let suffix = match step_id {
            "send-hap" => ".hap".to_owned(),
            "capture-trace" => ".htrace".to_owned(),
            "capture-ui-tree" => ".json".to_owned(),
            "capture-screenshot" => format!(".{}", image_type.raw()),
            "capture-screen-sequence" => ".tar".to_owned(),
            _ => String::new(),
        };
        let remote_path = format!("{STAGING_ROOT}/arkdeck-{job_id}-{step_id}-{nonce}{suffix}");
        if remote_path.len() > 255 {
            return Err(RequestError::OutOfBounds {
                field: "remotePath",
                detail: "provider-owned path must be at most 255 bytes".into(),
            });
        }
        Ok(Self {
            job_id: job_id.to_owned(),
            step_id: step_id.to_owned(),
            nonce: nonce.to_owned(),
            remote_path,
        })
    }

    /// Swift `mintStableOwnedRemotePath`: the reconstructible path of a
    /// durable Job recipe, so capture, receive and cleanup name one file.
    pub fn stable(
        job_id: &str,
        step_id: &str,
        image_type: ImageType,
    ) -> Result<Self, RequestError> {
        Self::new(job_id, step_id, "owned", image_type)
    }

    /// The remote file's name, which the host landing shares.
    pub fn basename(&self) -> &str {
        self.remote_path
            .rsplit('/')
            .next()
            .unwrap_or(&self.remote_path)
    }
}

/// Swift `HDCOwnedRemoteDirectory.Purpose`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DirectoryPurpose {
    Packages,
    Frames,
}

impl DirectoryPurpose {
    fn raw(self) -> &'static str {
        match self {
            Self::Packages => "packages",
            Self::Frames => "frames",
        }
    }
}

/// Swift `HDCOwnedRemoteDirectory`: a provider-owned temporary directory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnedRemoteDirectory {
    pub job_id: String,
    pub step_id: String,
    pub nonce: String,
    pub purpose: DirectoryPurpose,
    pub remote_path: String,
}

impl OwnedRemoteDirectory {
    pub fn new(
        job_id: &str,
        step_id: &str,
        nonce: &str,
        purpose: DirectoryPurpose,
    ) -> Result<Self, RequestError> {
        component_field("jobID", job_id)?;
        component_field("stepID", step_id)?;
        component_field("nonce", nonce)?;
        let remote_path = format!(
            "{STAGING_ROOT}/arkdeck-{job_id}-{step_id}-{nonce}-{}",
            purpose.raw()
        );
        if remote_path.len() > 255 {
            return Err(RequestError::OutOfBounds {
                field: "remotePath",
                detail: "provider-owned path must be at most 255 bytes".into(),
            });
        }
        Ok(Self {
            job_id: job_id.to_owned(),
            step_id: step_id.to_owned(),
            nonce: nonce.to_owned(),
            purpose,
            remote_path,
        })
    }

    /// Swift `mintStableOwnedFrameDirectory`.
    pub fn stable_frames(job_id: &str, step_id: &str) -> Result<Self, RequestError> {
        Self::new(job_id, step_id, "owned", DirectoryPurpose::Frames)
    }
}

/// Swift `HDCTraceCaptureRequest`: a bounded `hitrace` window over bounded
/// category identifiers, blocking or as an armed ring. A ring snapshot's
/// reach is proved by its coverage anchor — written into the device's own
/// `trace_marker` when the ring is armed, read back before the window, and
/// found in the dump by a string search rather than a trace decoder.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceRequest {
    pub duration_seconds: i64,
    pub categories: Vec<String>,
    pub buffer_kb: i64,
    pub ring_buffered: bool,
    pub coverage_anchor: Option<String>,
}

impl TraceRequest {
    pub fn new(
        duration_seconds: i64,
        categories: Vec<String>,
        buffer_kb: i64,
        ring_buffered: bool,
        coverage_anchor: Option<String>,
    ) -> Result<Self, RequestError> {
        if !(1..=MAXIMUM_TRACE_SECONDS).contains(&duration_seconds) {
            return Err(RequestError::OutOfBounds {
                field: "durationSeconds",
                detail: format!("1...{MAXIMUM_TRACE_SECONDS}"),
            });
        }
        if categories.is_empty() || categories.len() > MAXIMUM_TRACE_CATEGORIES {
            return Err(RequestError::OutOfBounds {
                field: "categories",
                detail: format!("1...{MAXIMUM_TRACE_CATEGORIES}"),
            });
        }
        if !categories.iter().all(|category| {
            !category.is_empty()
                && category.chars().count() <= 64
                && category
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        }) {
            return Err(RequestError::Malformed {
                field: "categories",
                detail: "categories are bounded identifiers",
            });
        }
        if !(1024..=65_536).contains(&buffer_kb) {
            return Err(RequestError::OutOfBounds {
                field: "bufferKB",
                detail: "1024...65536".into(),
            });
        }
        if let Some(anchor) = &coverage_anchor
            && (!ring_buffered
                || !(14..=64).contains(&anchor.chars().count())
                || !anchor.bytes().all(|byte| byte.is_ascii_alphanumeric()))
        {
            return Err(RequestError::Malformed {
                field: "coverageAnchor",
                detail: "a ring-only bounded identifier",
            });
        }
        Ok(Self {
            duration_seconds,
            categories,
            buffer_kb,
            ring_buffered,
            coverage_anchor,
        })
    }

    /// Swift `anchor(sessionID:stepID:)`: `ARKDECKANCHOR` and the last forty
    /// ASCII letters and digits of the session and step identifiers.
    pub fn anchor(session_id: &str, step_id: &str) -> String {
        let allowed: Vec<char> = format!("{session_id}{step_id}")
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .collect();
        let tail: String = allowed[allowed.len().saturating_sub(40)..].iter().collect();
        format!("ARKDECKANCHOR{tail}")
    }
}

/// Swift `HDCScreenSequenceRequest`: a bounded run of stills off one
/// display, collected into one archive.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScreenSequenceRequest {
    pub frame_count: i64,
    pub image_type: ImageType,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub display_id: Option<i64>,
}

impl ScreenSequenceRequest {
    pub fn new(
        frame_count: i64,
        image_type: ImageType,
        width: Option<i64>,
        height: Option<i64>,
        display_id: Option<i64>,
    ) -> Result<Self, RequestError> {
        if !(2..=MAXIMUM_FRAMES).contains(&frame_count) {
            return Err(RequestError::OutOfBounds {
                field: "frameCount",
                detail: format!("2...{MAXIMUM_FRAMES}"),
            });
        }
        match (width, height) {
            (None, None) => {}
            (Some(width), Some(height)) => {
                if !(1..=32_767).contains(&width) || !(1..=32_767).contains(&height) {
                    return Err(RequestError::OutOfBounds {
                        field: "width/height",
                        detail: "1...32767".into(),
                    });
                }
            }
            _ => {
                return Err(RequestError::Malformed {
                    field: "width/height",
                    detail: "a scaled sequence needs both dimensions",
                });
            }
        }
        if let Some(display_id) = display_id
            && !(0..=64).contains(&display_id)
        {
            return Err(RequestError::OutOfBounds {
                field: "displayID",
                detail: "0...64".into(),
            });
        }
        Ok(Self {
            frame_count,
            image_type,
            width,
            height,
            display_id,
        })
    }

    /// Swift `frameName(index:)`: zero-padded so the archive's own ordering
    /// is the capture order.
    pub fn frame_name(&self, index: i64) -> String {
        format!("{:04}.{}", index + 1, self.image_type.raw())
    }
}

/// Swift `HDCFaultLogName`: a Faultlogger entry name, never a path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FaultLogName(String);

impl FaultLogName {
    pub fn new(value: &str) -> Result<Self, RequestError> {
        let valid = value.chars().count() <= 200
            && value.split_once('-').is_some_and(|(kind, rest)| {
                !kind.is_empty()
                    && kind.bytes().all(|byte| byte.is_ascii_lowercase())
                    && (1..=180).contains(&rest.len())
                    && rest
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            });
        if !valid {
            return Err(RequestError::Malformed {
                field: "faultLogName",
                detail: "a Faultlogger entry name, never a path",
            });
        }
        Ok(Self(value.to_owned()))
    }

    pub fn value(&self) -> &str {
        &self.0
    }
}

/// Swift `HDCBundleReference`: a reverse-DNS bundle name.
fn bundle_name(value: &str) -> Result<(), RequestError> {
    let components: Vec<&str> = value.split('.').collect();
    let valid = !value.is_empty()
        && value.chars().count() <= 200
        && components.len() >= 2
        && components.iter().all(|component| {
            component
                .bytes()
                .next()
                .is_some_and(|first| first.is_ascii_alphabetic())
                && component
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        });
    if valid {
        Ok(())
    } else {
        Err(RequestError::Malformed {
            field: "bundleName",
            detail: "reverse-DNS identifier expected",
        })
    }
}

/// Swift `HDCApplicationLivenessRequest`: which process to look for, and
/// the deployed digest the evidence is bound to.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LivenessRequest {
    pub bundle_name: String,
    pub ability_name: Option<String>,
    pub process_name: String,
    pub expected_deployed_artifact_digest: Option<String>,
}

impl LivenessRequest {
    pub fn new(
        bundle: &str,
        ability_name: Option<&str>,
        process_name: Option<&str>,
        expected_deployed_artifact_digest: Option<&str>,
    ) -> Result<Self, RequestError> {
        bundle_name(bundle)?;
        if let Some(ability) = ability_name {
            let valid = !ability.is_empty()
                && ability.chars().count() <= 200
                && ability
                    .bytes()
                    .next()
                    .is_some_and(|first| first.is_ascii_alphabetic())
                && ability
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'_');
            if !valid {
                return Err(RequestError::Malformed {
                    field: "abilityName",
                    detail: "identifier expected",
                });
            }
        }
        let process = process_name.unwrap_or(bundle);
        let valid = !process.is_empty()
            && process.chars().count() <= 200
            && process
                .bytes()
                .next()
                .is_some_and(|first| first.is_ascii_alphabetic())
            && process
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._:".contains(&byte));
        if !valid {
            return Err(RequestError::Malformed {
                field: "processName",
                detail: "application process identifier expected",
            });
        }
        if let Some(digest) = expected_deployed_artifact_digest
            && (digest.len() != 64
                || !digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
        {
            return Err(RequestError::Malformed {
                field: "expectedDeployedArtifactDigest",
                detail: "lowercase SHA-256 expected",
            });
        }
        Ok(Self {
            bundle_name: bundle.to_owned(),
            ability_name: ability_name.map(str::to_owned),
            process_name: process.to_owned(),
            expected_deployed_artifact_digest: expected_deployed_artifact_digest.map(str::to_owned),
        })
    }
}

/// Swift `HDCOwnedRemoteArtifact`: the provider-owned file to receive, the
/// hash pinned for it (if any), the bound on its size and the magic it must
/// begin with (a still that is not the format it claims is a failure).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceiveArtifact {
    pub path: OwnedRemotePath,
    pub expected_sha256: Option<String>,
    pub maximum_bytes: i64,
    pub expected_leading_bytes: Option<Vec<u8>>,
}

/// Swift `TypedProviderAction.hdc` for these legs.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FileAction {
    /// Swift `.captureCrashIndex`: the device's own crash ledger.
    CaptureCrashIndex {
        byte_budget: i64,
    },
    /// Swift `.captureCrashLog`: one Faultlogger entry.
    CaptureCrashLog {
        name: FaultLogName,
        byte_budget: i64,
    },
    /// Swift `.captureUIDump` of scope `componentDetail`.
    CaptureComponentDetail {
        window_id: String,
        component_id: String,
    },
    /// Swift `.observeApplicationLiveness`: the `pidof` readback.
    ObserveApplicationLiveness(LivenessRequest),
    CaptureTrace {
        request: TraceRequest,
        path: OwnedRemotePath,
    },
    CaptureComponentTree {
        path: OwnedRemotePath,
    },
    CaptureScreenshot {
        image_type: ImageType,
        path: OwnedRemotePath,
    },
    CaptureScreenSequence {
        request: ScreenSequenceRequest,
        frames: OwnedRemoteDirectory,
        archive: OwnedRemotePath,
    },
    CleanupScreenSequence {
        request: ScreenSequenceRequest,
        frames: OwnedRemoteDirectory,
        archive: OwnedRemotePath,
    },
    ReceiveOwnedArtifact(ReceiveArtifact),
    CleanupOwnedRemotePath {
        path: OwnedRemotePath,
    },
}

/// Why a selected step has no action: Swift's
/// `DeviceProviderError.unsupportedAction` or an `HDCE0RequestError`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FileActionError {
    Unsupported(String),
    Request(RequestError),
}

impl fmt::Display for FileActionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(detail) => write!(formatter, "unsupportedAction(\"{detail}\")"),
            Self::Request(error) => write!(formatter, "{error}"),
        }
    }
}

impl From<RequestError> for FileActionError {
    fn from(error: RequestError) -> Self {
        Self::Request(error)
    }
}

/// Swift `fileProducerStepID(for:)`: which step wrote the file a receive or
/// cleanup step is talking about, so the two legs of a file product cannot
/// drift onto different paths.
pub fn file_producer_step_id(step_id: &str) -> &'static str {
    match step_id {
        "receive-ui-tree" | "cleanup-ui-tree-temp" => "capture-ui-tree",
        "receive-screenshot" | "cleanup-screenshot-temp" => "capture-screenshot",
        "receive-screen-sequence" => "capture-screen-sequence",
        _ => "capture-trace",
    }
}

/// Swift `screenshotImageType(inputs:)`: PNG unless the request asked
/// otherwise — the evidence format is what a caller gets by not choosing.
pub fn screenshot_image_type(inputs: &Map<String, Value>) -> ImageType {
    inputs
        .get("screenshotImageType")
        .and_then(Value::as_str)
        .and_then(ImageType::parse)
        .unwrap_or(ImageType::Png)
}

fn string_input<'a>(inputs: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    inputs.get(key).and_then(Value::as_str)
}

fn integer_input(inputs: &Map<String, Value>, key: &str) -> Option<i64> {
    inputs.get(key).and_then(Value::as_i64)
}

/// Swift `traceRequest(from:jobID:stepID:)`: the caller's own categories
/// (no invented default), a window of 1 to 120 s (else 10), a buffer of
/// 1024 to 65536 KiB (else 8192), and for a ring the anchor derived here.
fn trace_request(inputs: &Map<String, Value>, job_id: &str) -> Result<TraceRequest, RequestError> {
    let categories: Vec<String> = inputs
        .get("traceCategories")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let duration = integer_input(inputs, "durationSeconds")
        .map_or(10, |seconds| seconds.clamp(1, MAXIMUM_TRACE_SECONDS));
    let buffer = integer_input(inputs, "traceBufferKB")
        .map_or(8192, |kilobytes| kilobytes.clamp(1024, 65_536));
    let ring_buffered = inputs
        .get("ringBuffered")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    TraceRequest::new(
        duration,
        categories,
        buffer,
        ring_buffered,
        ring_buffered.then(|| TraceRequest::anchor(job_id, "capture-trace")),
    )
}

/// Swift `screenSequenceRequest(from:)`: the capture and its cleanup both
/// build this from the same inputs.
fn screen_sequence_request(
    inputs: &Map<String, Value>,
) -> Result<ScreenSequenceRequest, FileActionError> {
    let Some(frame_count) = integer_input(inputs, "frameCount") else {
        return Err(FileActionError::Unsupported(
            "screen sequence step selected without frameCount".into(),
        ));
    };
    let image_type = match string_input(inputs, "imageType") {
        None => ImageType::Jpeg,
        Some(requested) => ImageType::parse(requested).ok_or_else(|| {
            FileActionError::Unsupported(format!(
                "screen sequence asked for an unregistered image type {requested}"
            ))
        })?,
    };
    Ok(ScreenSequenceRequest::new(
        frame_count,
        image_type,
        integer_input(inputs, "width"),
        integer_input(inputs, "height"),
        integer_input(inputs, "displayId"),
    )?)
}

impl FileAction {
    /// Swift `HDCObservationProviderAdapter.action` for a
    /// `capture.diagnostics@1` step this module owns, with the request's
    /// inputs and the Job the owned paths are minted for. `None` is a step
    /// of another owner (the default legs, the observe and storage steps);
    /// an error is Swift's refusal of the request for it.
    pub fn for_step(
        step_id: &str,
        kind: &str,
        action_id: Option<&str>,
        inputs: &Map<String, Value>,
        job_id: &str,
    ) -> Result<Option<Self>, FileActionError> {
        let unsupported = |detail: String| Err(FileActionError::Unsupported(detail));
        match kind {
            "captureRemoteStdout" => match action_id {
                Some("componentDetail") => {
                    let (Some(window_id), Some(component_id)) = (
                        string_input(inputs, "windowId"),
                        string_input(inputs, "componentId"),
                    ) else {
                        return unsupported(
                            "componentDetail requires typed windowId and componentId inputs".into(),
                        );
                    };
                    Ok(Some(Self::component_detail(window_id, component_id)?))
                }
                Some("crashIndex") => Ok(Some(Self::CaptureCrashIndex {
                    byte_budget: STDOUT_BUDGET,
                })),
                Some("crashLog") => {
                    let Some(name) = string_input(inputs, "crashLogName") else {
                        return unsupported(
                            "crashLogName input is required to fetch one Faultlogger entry".into(),
                        );
                    };
                    Ok(Some(Self::CaptureCrashLog {
                        name: FaultLogName::new(name)?,
                        byte_budget: STDOUT_BUDGET,
                    }))
                }
                Some("componentTree") => unsupported(
                    "componentTree is a file product, not stdout: use the uiComponentTree \
                     input, which selects the capture-ui-tree file steps; a \
                     captureRemoteStdout step cannot carry it"
                        .into(),
                ),
                Some("windowInventory") | Some("boundedHilog") => Ok(None),
                Some(other) => {
                    unsupported(format!("unregistered stdout action {other} for {step_id}"))
                }
                None => unsupported(format!(
                    "{step_id} declares no catalog action; refusing to infer one"
                )),
            },
            "verifyRemoteState" if step_id == "observe-application-liveness" => {
                let Some(bundle) = string_input(inputs, "bundleName") else {
                    return unsupported("bundleName is required for application liveness".into());
                };
                Ok(Some(Self::ObserveApplicationLiveness(
                    LivenessRequest::new(
                        bundle,
                        string_input(inputs, "abilityName"),
                        string_input(inputs, "processName"),
                        string_input(inputs, "expectedDeployedArtifactDigest"),
                    )?,
                )))
            }
            "captureRemoteFile" => match step_id {
                "capture-screen-sequence" => Ok(Some(Self::CaptureScreenSequence {
                    request: screen_sequence_request(inputs)?,
                    frames: OwnedRemoteDirectory::stable_frames(job_id, "capture-screen-sequence")?,
                    archive: OwnedRemotePath::stable(
                        job_id,
                        "capture-screen-sequence",
                        ImageType::Png,
                    )?,
                })),
                "capture-screenshot" => {
                    let image_type = screenshot_image_type(inputs);
                    Ok(Some(Self::CaptureScreenshot {
                        image_type,
                        path: OwnedRemotePath::stable(job_id, "capture-screenshot", image_type)?,
                    }))
                }
                "capture-ui-tree" => Ok(Some(Self::CaptureComponentTree {
                    path: OwnedRemotePath::stable(job_id, "capture-ui-tree", ImageType::Png)?,
                })),
                _ => Ok(Some(Self::CaptureTrace {
                    request: trace_request(inputs, job_id)?,
                    path: OwnedRemotePath::stable(job_id, "capture-trace", ImageType::Png)?,
                })),
            },
            "receiveFile" => {
                // Each receive leg re-mints its producer's owned path, which
                // keeps the received bytes bound to the step that wrote them.
                let producer = file_producer_step_id(step_id);
                let received_type = screenshot_image_type(inputs);
                Ok(Some(Self::ReceiveOwnedArtifact(ReceiveArtifact {
                    path: OwnedRemotePath::stable(job_id, producer, received_type)?,
                    expected_sha256: None,
                    maximum_bytes: RECEIVE_MAXIMUM_BYTES,
                    expected_leading_bytes: (step_id == "receive-screenshot")
                        .then(|| received_type.magic().to_vec()),
                })))
            }
            "cleanupOwnedRemotePath" => {
                if step_id == "cleanup-screen-sequence-temp" {
                    return Ok(Some(Self::CleanupScreenSequence {
                        request: screen_sequence_request(inputs)?,
                        frames: OwnedRemoteDirectory::stable_frames(
                            job_id,
                            "capture-screen-sequence",
                        )?,
                        archive: OwnedRemotePath::stable(
                            job_id,
                            "capture-screen-sequence",
                            ImageType::Png,
                        )?,
                    }));
                }
                Ok(Some(Self::CleanupOwnedRemotePath {
                    path: OwnedRemotePath::stable(
                        job_id,
                        file_producer_step_id(step_id),
                        screenshot_image_type(inputs),
                    )?,
                }))
            }
            _ => Ok(None),
        }
    }

    /// Swift `HDCUIDumpRequest(scope: .componentDetail, …)`: decimal
    /// identifiers of at most twenty digits.
    pub fn component_detail(window_id: &str, component_id: &str) -> Result<Self, RequestError> {
        let identifier = |value: &str| {
            (1..=20).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_digit())
        };
        if !identifier(window_id) || !identifier(component_id) {
            return Err(RequestError::Malformed {
                field: "componentDetail",
                detail: "windowID and componentID must be decimal identifiers",
            });
        }
        Ok(Self::CaptureComponentDetail {
            window_id: window_id.to_owned(),
            component_id: component_id.to_owned(),
        })
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::CaptureCrashIndex { .. }
            | Self::CaptureCrashLog { .. }
            | Self::CaptureComponentDetail { .. }
            | Self::ObserveApplicationLiveness(_)
            | Self::ReceiveOwnedArtifact(_) => "readOnly",
            Self::CaptureTrace { .. }
            | Self::CaptureComponentTree { .. }
            | Self::CaptureScreenshot { .. }
            | Self::CaptureScreenSequence { .. }
            | Self::CleanupScreenSequence { .. }
            | Self::CleanupOwnedRemotePath { .. } => "deviceMutation",
        }
    }

    /// Swift `PersistedTypedProviderAction`: the kind and arguments a Job
    /// record keeps before the action's intent can be dispatched.
    pub fn persisted(&self) -> (&'static str, Vec<(&'static str, Persisted)>) {
        let text = |value: &str| Persisted::Text(value.into());
        let path_arguments = |path: &OwnedRemotePath| {
            vec![
                ("jobId", text(&path.job_id)),
                ("stepId", text(&path.step_id)),
                ("nonce", text(&path.nonce)),
                ("remotePath", text(&path.remote_path)),
            ]
        };
        match self {
            Self::CaptureCrashIndex { byte_budget } => (
                "hdc.captureCrashIndex",
                vec![("byteBudget", Persisted::Integer(*byte_budget))],
            ),
            Self::CaptureCrashLog { name, byte_budget } => (
                "hdc.captureCrashLog",
                vec![
                    ("faultLogName", text(name.value())),
                    ("byteBudget", Persisted::Integer(*byte_budget)),
                ],
            ),
            Self::CaptureComponentDetail {
                window_id,
                component_id,
            } => (
                "hdc.captureUIDump",
                vec![
                    ("scope", text("componentDetail")),
                    ("byteBudget", Persisted::Integer(UI_DUMP_BUDGET)),
                    ("windowId", text(window_id)),
                    ("componentId", text(component_id)),
                ],
            ),
            Self::ObserveApplicationLiveness(request) => {
                let mut arguments = vec![
                    ("bundleName", text(&request.bundle_name)),
                    ("processName", text(&request.process_name)),
                ];
                if let Some(ability) = &request.ability_name {
                    arguments.push(("abilityName", text(ability)));
                }
                if let Some(digest) = &request.expected_deployed_artifact_digest {
                    arguments.push(("expectedDeployedArtifactDigest", text(digest)));
                }
                ("hdc.observeApplicationLiveness", arguments)
            }
            Self::CaptureTrace { request, path } => {
                let mut arguments = path_arguments(path);
                arguments.push((
                    "durationSeconds",
                    Persisted::Integer(request.duration_seconds),
                ));
                arguments.push(("categories", Persisted::Texts(request.categories.clone())));
                arguments.push(("bufferKB", Persisted::Integer(request.buffer_kb)));
                ("hdc.captureTrace", arguments)
            }
            Self::CaptureComponentTree { path } => {
                ("hdc.captureComponentTree", path_arguments(path))
            }
            Self::CaptureScreenshot { image_type, path } => {
                let mut arguments = path_arguments(path);
                arguments.push(("imageType", text(image_type.raw())));
                ("hdc.captureScreenshot", arguments)
            }
            Self::CaptureScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut arguments = path_arguments(archive);
                arguments.push(("framesDirectory", text(&frames.remote_path)));
                arguments.push(("frameCount", Persisted::Integer(request.frame_count)));
                arguments.push(("imageType", text(request.image_type.raw())));
                if let (Some(width), Some(height)) = (request.width, request.height) {
                    arguments.push(("width", Persisted::Integer(width)));
                    arguments.push(("height", Persisted::Integer(height)));
                }
                if let Some(display_id) = request.display_id {
                    arguments.push(("displayId", Persisted::Integer(display_id)));
                }
                ("hdc.captureScreenSequence", arguments)
            }
            Self::CleanupScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut arguments = path_arguments(archive);
                arguments.push(("framesDirectory", text(&frames.remote_path)));
                arguments.push(("frameCount", Persisted::Integer(request.frame_count)));
                ("hdc.cleanupScreenSequence", arguments)
            }
            Self::ReceiveOwnedArtifact(artifact) => {
                let mut arguments = path_arguments(&artifact.path);
                arguments.push(("maximumBytes", Persisted::Integer(artifact.maximum_bytes)));
                if let Some(expected) = &artifact.expected_sha256 {
                    arguments.push(("expectedSha256", text(expected)));
                }
                if let Some(magic) = &artifact.expected_leading_bytes {
                    arguments.push(("expectedLeadingBytes", text(&hex(magic))));
                }
                ("hdc.receiveOwnedArtifact", arguments)
            }
            Self::CleanupOwnedRemotePath { path } => {
                ("hdc.cleanupOwnedRemotePath", path_arguments(path))
            }
        }
    }

    /// Swift `lower`: the process or process sequence the executor runs, each
    /// invocation with its budget, and for a receive the host landing the
    /// bytes must reach. A device action names its target by the binding's
    /// connect key and has none without one.
    pub fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        host_receive_root: &Path,
    ) -> Result<FilePlan, String> {
        self.lower_in(step_id, connect_key, Some(host_receive_root))
    }

    /// Whether the leg lands a file on the host, and so lowers only where a
    /// host receive root names the landing.
    pub fn receives(&self) -> bool {
        matches!(self, Self::ReceiveOwnedArtifact(_))
    }

    /// [`Self::lower`] where the composition may name no host receive root:
    /// every leg but a receive lowers without one, since only a receive's
    /// argv names a host path.
    pub fn lower_in(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        host_receive_root: Option<&Path>,
    ) -> Result<FilePlan, String> {
        let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
            return Err(format!(
                "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
            ));
        };
        let device = |tail: Vec<String>| -> Vec<String> {
            let mut arguments = vec!["-t".to_owned(), key.to_owned()];
            arguments.extend(tail);
            arguments
        };
        let owned = |tail: &[&str]| device(tail.iter().map(|part| (*part).to_owned()).collect());
        let process = |arguments: Vec<String>, seconds: u64| {
            FilePlan::Process(ProcessPlan {
                arguments,
                timeout: Duration::from_secs(seconds),
                capture_bytes: CAPTURE_BYTES,
            })
        };
        let invocation =
            |arguments: Vec<String>, seconds: u64, continue_after_non_zero: bool| Invocation {
                arguments,
                timeout: Duration::from_secs(seconds),
                continue_after_non_zero,
            };
        let readback = |path: &str| invocation(owned(&["shell", "ls", "-l", path]), 15, false);
        Ok(match self {
            // The `-p …` payload is a single argv element after `-a`, exactly
            // as DEVICE-COMMAND-FACTS.md §6 records it; Faultlogger's SA id
            // is 1201.
            Self::CaptureCrashIndex { .. } => process(
                owned(&["shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger -l"]),
                30,
            ),
            Self::CaptureCrashLog { name, .. } => process(
                device(vec![
                    "shell".into(),
                    "hidumper".into(),
                    "-s".into(),
                    "1201".into(),
                    "-a".into(),
                    format!("-p Faultlogger -f {}", name.value()),
                ]),
                30,
            ),
            Self::CaptureComponentDetail {
                window_id,
                component_id,
            } => process(
                device(vec![
                    "shell".into(),
                    "hidumper".into(),
                    "-s".into(),
                    "WindowManagerService".into(),
                    "-a".into(),
                    format!("-w {window_id} -element -lastpage {component_id}"),
                ]),
                30,
            ),
            Self::ObserveApplicationLiveness(request) => {
                process(owned(&["shell", "pidof", &request.process_name]), 30)
            }
            Self::CaptureTrace { request, path } if request.ring_buffered => {
                // Arm, let the window pass, snapshot, stop. `--overwrite` is
                // deliberately absent: with it the newest traces are
                // discarded, and the default is what drops the oldest.
                let mut ring = vec![invocation(
                    device(
                        ["shell", "hitrace", "--trace_begin", "-b"]
                            .into_iter()
                            .map(str::to_owned)
                            .chain(std::iter::once(request.buffer_kb.to_string()))
                            .chain(request.categories.iter().cloned())
                            .collect(),
                    ),
                    30,
                    false,
                )];
                if let Some(anchor) = &request.coverage_anchor {
                    // One quoted line each rather than argv elements: passing
                    // the redirect as its own element does not redirect on
                    // this path. The anchor is letters and digits, so nothing
                    // in the line is a shell's to reinterpret.
                    ring.push(invocation(
                        device(vec![
                            "shell".into(),
                            format!("echo {anchor} > {TRACE_MARKER_PATH}"),
                        ]),
                        15,
                        false,
                    ));
                    ring.push(invocation(
                        device(vec![
                            "shell".into(),
                            format!("grep -c {anchor} {TRACE_RING_PATH}"),
                        ]),
                        15,
                        false,
                    ));
                }
                ring.push(invocation(
                    owned(&["shell", "sleep", &request.duration_seconds.to_string()]),
                    request.duration_seconds.unsigned_abs() + 30,
                    false,
                ));
                ring.push(invocation(
                    owned(&["shell", "hitrace", "--trace_dump", "-o", &path.remote_path]),
                    120,
                    true,
                ));
                // Stopping without a second dump: the snapshot above is the
                // product.
                ring.push(invocation(
                    owned(&["shell", "hitrace", "--trace_finish_nodump"]),
                    30,
                    true,
                ));
                ring.push(readback(&path.remote_path));
                FilePlan::Sequence(ring)
            }
            // hitrace's own exit status is the client's, not the remote
            // command's: the capture is judged by the file it was to write,
            // and `ls -l` runs even when hitrace reports non-zero — a partial
            // trace is still a fact the readback should report.
            Self::CaptureTrace { request, path } => FilePlan::Sequence(vec![
                invocation(
                    device(
                        ["shell", "hitrace", "-t"]
                            .into_iter()
                            .map(str::to_owned)
                            .chain([request.duration_seconds.to_string(), "-b".to_owned()])
                            .chain(std::iter::once(request.buffer_kb.to_string()))
                            .chain(request.categories.iter().cloned())
                            .chain(["-o".to_owned(), path.remote_path.clone()])
                            .collect(),
                    ),
                    request.duration_seconds.unsigned_abs() + 30,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // `uitest dumpLayout -p <file>` needs neither `-w` nor `-d` and
            // answers a status line; the file, read back, is the evidence.
            Self::CaptureComponentTree { path } => FilePlan::Sequence(vec![
                invocation(
                    owned(&["shell", "uitest", "dumpLayout", "-p", &path.remote_path]),
                    60,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // `-t` is mandatory: the device refuses a name whose suffix
            // disagrees with the type, so the flag and the suffix are one
            // decision made once.
            Self::CaptureScreenshot { image_type, path } => FilePlan::Sequence(vec![
                invocation(
                    owned(&[
                        "shell",
                        "snapshot_display",
                        "-t",
                        image_type.raw(),
                        "-f",
                        &path.remote_path,
                    ]),
                    60,
                    true,
                ),
                readback(&path.remote_path),
            ]),
            // One typed invocation per frame, never a device-side loop; a
            // frame that fails is a gap in the sequence, not the end of it.
            Self::CaptureScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut invocations = vec![invocation(
                    owned(&["shell", "mkdir", "-p", &frames.remote_path]),
                    30,
                    false,
                )];
                for index in 0..request.frame_count {
                    let mut capture: Vec<String> = ["shell", "snapshot_display", "-t"]
                        .into_iter()
                        .map(str::to_owned)
                        .collect();
                    capture.push(request.image_type.raw().to_owned());
                    if let (Some(width), Some(height)) = (request.width, request.height) {
                        capture.extend([
                            "-w".to_owned(),
                            width.to_string(),
                            "-h".to_owned(),
                            height.to_string(),
                        ]);
                    }
                    if let Some(display_id) = request.display_id {
                        capture.extend(["-i".to_owned(), display_id.to_string()]);
                    }
                    capture.push("-f".to_owned());
                    capture.push(format!(
                        "{}/{}",
                        frames.remote_path,
                        request.frame_name(index)
                    ));
                    invocations.push(invocation(device(capture), 60, true));
                }
                invocations.push(invocation(
                    owned(&[
                        "shell",
                        "tar",
                        "-c",
                        "-f",
                        &archive.remote_path,
                        "-C",
                        &frames.remote_path,
                        ".",
                    ]),
                    120,
                    true,
                ));
                invocations.push(readback(&archive.remote_path));
                FilePlan::Sequence(invocations)
            }
            // `rm -f` naming exactly the frames this provider wrote, then the
            // archive, then `rmdir` — never `rm -rf`; `ls -ld`, not `ls -d`,
            // because the presence parser accepts exactly one listing line
            // or the not-found grammar.
            Self::CleanupScreenSequence {
                request,
                frames,
                archive,
            } => {
                let mut remove: Vec<String> = ["shell", "rm", "-f"]
                    .into_iter()
                    .map(str::to_owned)
                    .collect();
                remove.extend(
                    (0..request.frame_count).map(|index| {
                        format!("{}/{}", frames.remote_path, request.frame_name(index))
                    }),
                );
                FilePlan::Sequence(vec![
                    invocation(device(remove), 60, true),
                    invocation(
                        owned(&["shell", "rm", "-f", &archive.remote_path]),
                        30,
                        true,
                    ),
                    invocation(owned(&["shell", "rmdir", &frames.remote_path]), 30, true),
                    invocation(
                        owned(&["shell", "ls", "-ld", &frames.remote_path]),
                        15,
                        true,
                    ),
                ])
            }
            // `file recv` takes both paths; the local name is the remote
            // basename so that both landing forms hdc builds use land on the
            // same path instead of on a guess.
            Self::ReceiveOwnedArtifact(artifact) => {
                let Some(host_receive_root) = host_receive_root else {
                    return Err(format!(
                        "{step_id} lowers only within a composition that names its host receive \
                         root"
                    ));
                };
                let destination = host_landing(host_receive_root, &artifact.path);
                FilePlan::Receive {
                    process: ProcessPlan {
                        arguments: device(vec![
                            "file".into(),
                            "recv".into(),
                            artifact.path.remote_path.clone(),
                            destination.to_string_lossy().into_owned(),
                        ]),
                        timeout: Duration::from_secs(60),
                        capture_bytes: CAPTURE_BYTES,
                    },
                    landing: HostLanding {
                        destination,
                        maximum_bytes: artifact.maximum_bytes,
                        expected_sha256: artifact.expected_sha256.clone(),
                    },
                }
            }
            Self::CleanupOwnedRemotePath { path } => {
                process(owned(&["shell", "rm", "-f", &path.remote_path]), 15)
            }
        })
    }

    /// Swift `verify` for these legs: a file product is judged by its
    /// readback, a received one by the bytes that landed, a cleanup by what
    /// the device still shows — never by the client's exit status, which is
    /// the transport's, not the remote command's.
    pub fn verify(&self, receipt: &FileReceipt, now_utc: &str) -> Outcome {
        match self {
            Self::CaptureCrashIndex { .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("crash index produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "crash index exceeded its budget");
                }
                let Ok(text) = std::str::from_utf8(&process.stdout) else {
                    return failed("invalidEncoding", "crash index is not UTF-8");
                };
                // An empty ledger is a truthful answer, not a failure.
                verified([
                    ("entryCount", fault_log_entries(text).len().to_string()),
                    ("byteCount", process.stdout.len().to_string()),
                ])
            }
            Self::CaptureCrashLog { name, .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("crash log produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "crash log exceeded its budget");
                }
                let Ok(text) = std::str::from_utf8(&process.stdout) else {
                    return failed("invalidEncoding", "crash log is not UTF-8");
                };
                if text.contains("invalid parameters.") {
                    // The device's answer for a name it does not have.
                    return Outcome::Failed {
                        code: "faultLogNotFound",
                        detail: format!("device has no entry named {}", name.value()),
                    };
                }
                if !text.contains("Generated by HiviewDFX") {
                    return Outcome::Unknown("crash log did not carry its HiviewDFX header".into());
                }
                verified([
                    ("faultLogName", name.value().to_owned()),
                    ("byteCount", process.stdout.len().to_string()),
                ])
            }
            Self::CaptureComponentDetail { .. } => {
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("UI dump produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "capture exceeded its byte budget");
                }
                if std::str::from_utf8(&process.stdout).is_err() {
                    return failed("invalidEncoding", "UI dump is not UTF-8");
                }
                if process.stdout.is_empty() {
                    return Outcome::Unknown("empty capture output".into());
                }
                verified([("byteCount", process.stdout.len().to_string())])
            }
            Self::ObserveApplicationLiveness(request) => liveness(request, receipt, now_utc),
            Self::CaptureTrace { request, path } => {
                // begin, [write anchor, read anchor,] window, dump, stop,
                // readback — or the blocking capture and its readback.
                let expected = if request.ring_buffered {
                    if request.coverage_anchor.is_none() {
                        5
                    } else {
                        7
                    }
                } else {
                    2
                };
                if receipt.subprocesses.len() != expected {
                    return Outcome::Unknown(
                        "trace capture did not produce its readback sequence".into(),
                    );
                }
                let Some(readback) = receipt.subprocesses.last() else {
                    return Outcome::Unknown(
                        "trace capture did not produce its readback sequence".into(),
                    );
                };
                // The anchor readback is in this receipt, so whether the ring
                // was holding it is a fact this verdict already has.
                let mut anchor_held = None;
                if request.coverage_anchor.is_some() && receipt.subprocesses.len() >= 3 {
                    let counted = String::from_utf8_lossy(&receipt.subprocesses[2].stdout);
                    let Ok(occurrences) = counted.trim().parse::<i64>() else {
                        return Outcome::Unknown(
                            "the ring did not answer whether it was holding the coverage anchor"
                                .into(),
                        );
                    };
                    anchor_held = Some(occurrences > 0);
                }
                let Some(byte_count) = remote_regular_file_byte_count(readback) else {
                    // Includes `ls: …: No such file or directory`: the
                    // mutation ran, so this is genuinely unknown.
                    return Outcome::Unknown(format!(
                        "trace readback did not describe {} as a regular file",
                        path.remote_path
                    ));
                };
                if byte_count <= 0 {
                    return Outcome::Failed {
                        code: "emptyTrace",
                        detail: format!("hitrace left a zero-byte file at {}", path.remote_path),
                    };
                }
                let mut summary = BTreeMap::new();
                summary.insert("remoteByteCount".to_owned(), byte_count.to_string());
                if let Some(held) = anchor_held {
                    summary.insert(
                        "ringHeldCoverageAnchor".to_owned(),
                        if held { "true" } else { "false" }.to_owned(),
                    );
                }
                if let Some(anchor) = &request.coverage_anchor {
                    summary.insert("coverageAnchor".to_owned(), anchor.clone());
                }
                Outcome::Verified(summary)
            }
            Self::CaptureComponentTree { path } => file_product(
                receipt,
                2,
                1,
                path,
                "component tree dump did not produce its readback sequence",
                "tree readback",
                "emptyComponentTree",
                "uitest",
            ),
            Self::CaptureScreenshot { path, .. } => file_product(
                receipt,
                2,
                1,
                path,
                "screenshot did not produce its readback sequence",
                "screenshot readback",
                "emptyScreenshot",
                "snapshot_display",
            ),
            Self::CaptureScreenSequence {
                request, archive, ..
            } => {
                // mkdir + N frames + tar + readback; the expected count is
                // tied to the shape the lowering emits.
                let expected = usize::try_from(request.frame_count)
                    .unwrap_or(usize::MAX)
                    .saturating_add(3);
                if receipt.subprocesses.len() != expected {
                    return Outcome::Unknown(format!(
                        "screen sequence did not produce its {expected}-step readback sequence"
                    ));
                }
                let Some(byte_count) =
                    remote_regular_file_byte_count(&receipt.subprocesses[expected - 1])
                else {
                    return Outcome::Unknown(format!(
                        "sequence readback did not describe {} as a regular file",
                        archive.remote_path
                    ));
                };
                if byte_count <= 0 {
                    return Outcome::Failed {
                        code: "emptyScreenSequence",
                        detail: format!("tar left a zero-byte archive at {}", archive.remote_path),
                    };
                }
                // A frame that failed is a gap, not a failure of the run: the
                // count actually captured travels as a fact, and each frame's
                // own duration with it.
                let frames = &receipt.subprocesses[1..expected - 2];
                let captured = frames.iter().filter(|frame| frame.exit_status == 0).count();
                let elapsed: f64 = frames
                    .iter()
                    .map(|frame| frame.duration.as_secs_f64())
                    .sum();
                let mut summary = BTreeMap::new();
                summary.insert("remoteByteCount".to_owned(), byte_count.to_string());
                summary.insert(
                    "requestedFrameCount".to_owned(),
                    request.frame_count.to_string(),
                );
                summary.insert("capturedFrameCount".to_owned(), captured.to_string());
                summary.insert(
                    "frameDurationsSeconds".to_owned(),
                    frames
                        .iter()
                        .map(|frame| format!("{:.3}", frame.duration.as_secs_f64()))
                        .collect::<Vec<_>>()
                        .join(","),
                );
                if captured > 0 && elapsed > 0.0 {
                    summary.insert(
                        "observedFramesPerSecond".to_owned(),
                        format!("{:.2}", captured as f64 / elapsed),
                    );
                }
                Outcome::Verified(summary)
            }
            Self::CleanupScreenSequence { frames, .. } => {
                // The directory being absent from the listing is the proof;
                // neither `rmdir`'s exit nor the readback's decides it.
                let Some(last) = receipt.subprocesses.last() else {
                    return Outcome::Unknown("sequence cleanup produced no readback".into());
                };
                let Some(present) = path_presence(last) else {
                    return Outcome::Unknown(format!(
                        "sequence cleanup readback did not answer whether {} is still there",
                        frames.remote_path
                    ));
                };
                if present {
                    return Outcome::Failed {
                        code: "sequenceCleanupResidue",
                        detail: format!("{} still exists after cleanup", frames.remote_path),
                    };
                }
                verified([("cleaned", "true".to_owned())])
            }
            Self::ReceiveOwnedArtifact(artifact) => {
                // `file recv` exits 0 on forms that transfer nothing and its
                // stdout is a progress line: only the landed bytes decide.
                let Some(landed) = &receipt.landed else {
                    return Outcome::Unknown(
                        "receive left no file at the declared destination".into(),
                    );
                };
                if landed.byte_count == 0 {
                    return Outcome::Failed {
                        code: "emptyArtifact",
                        detail: format!("received file for {} is empty", artifact.path.remote_path),
                    };
                }
                if landed.byte_count > artifact.maximum_bytes.unsigned_abs() {
                    return Outcome::Failed {
                        code: "oversizedArtifact",
                        detail: format!(
                            "received {} bytes over the {} byte budget",
                            landed.byte_count, artifact.maximum_bytes
                        ),
                    };
                }
                let Some(sha256) = &landed.sha256 else {
                    return Outcome::Unknown("received file could not be digested".into());
                };
                if artifact
                    .expected_sha256
                    .as_ref()
                    .is_some_and(|expected| expected != sha256)
                {
                    return failed(
                        "hashMismatch",
                        "received bytes do not match the pinned content hash",
                    );
                }
                if artifact
                    .expected_leading_bytes
                    .as_ref()
                    .is_some_and(|magic| !landed.leading.starts_with(magic))
                {
                    return failed(
                        "unexpectedFormat",
                        "received bytes do not begin with the pinned magic",
                    );
                }
                // The name, not the path: the summary is journalled and
                // published, and the host layout is not evidence.
                verified([
                    (
                        "localArtifact",
                        landed
                            .path
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                            .unwrap_or_default(),
                    ),
                    ("byteCount", landed.byte_count.to_string()),
                    ("sha256", sha256.clone()),
                ])
            }
            Self::CleanupOwnedRemotePath { path } => {
                // Cleanup failure is debt, never silently dropped.
                let Some(process) = receipt.subprocesses.first() else {
                    return Outcome::Unknown("remote cleanup produced no process result".into());
                };
                if process.exit_status != 0 {
                    return Outcome::Failed {
                        code: "cleanupDebt",
                        detail: format!("remote cleanup failed for {}", path.remote_path),
                    };
                }
                verified([("cleaned", path.remote_path.clone())])
            }
        }
    }
}

/// One invocation of a lowered sequence (Swift `TypedProcessInvocation`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Invocation {
    pub arguments: Vec<String>,
    pub timeout: Duration,
    /// The sequence goes on after this invocation exits non-zero (a capture
    /// whose readback must run regardless); otherwise it stops there.
    pub continue_after_non_zero: bool,
}

/// Where a received artifact must land on the host (Swift
/// `HostLandingExpectation`): provider-owned like the remote path it
/// mirrors — the basename carries the job/step/nonce tuple, so a fixed root
/// cannot collide across Jobs and no caller input reaches the path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostLanding {
    pub destination: PathBuf,
    pub maximum_bytes: i64,
    pub expected_sha256: Option<String>,
}

/// Swift `hostLandingURL(for:)`.
pub fn host_landing(host_receive_root: &Path, remote: &OwnedRemotePath) -> PathBuf {
    host_receive_root.join(remote.basename())
}

/// Bytes observed on the host after a transfer (Swift
/// `ProviderLandedArtifact`): every field measured from the file, never
/// copied from the request that asked for it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Landed {
    pub path: PathBuf,
    pub byte_count: u64,
    /// Absent when the file was empty or over budget: deliberately not hashed.
    pub sha256: Option<String>,
    /// The first bytes as they are on disk, so a format check needs no
    /// second read.
    pub leading: Vec<u8>,
}

impl HostLanding {
    /// Swift `prepareDestination`: the landing directory owner-only, and a
    /// leftover from an earlier attempt removed so it cannot be inspected
    /// as though this transfer had produced it.
    pub fn prepare(&self) -> io::Result<()> {
        if let Some(parent) = self.destination.parent() {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            builder.mode(0o700);
            builder.create(parent)?;
        }
        match fs::symlink_metadata(&self.destination) {
            Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(&self.destination),
            Ok(_) => fs::remove_file(&self.destination),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    /// Swift `inspectLanded`: what is actually at the destination, or `None`
    /// when nothing usable is — no file, a symlink, a non-regular file, a
    /// file that changed while it was read. An empty or over-budget file is
    /// reported found with no digest: both are definite outcomes the verdict
    /// names, and hashing an over-budget file is what the budget forbids.
    pub fn inspect(&self) -> Option<Landed> {
        let metadata = fs::symlink_metadata(&self.destination).ok()?;
        if !metadata.is_file() {
            return None;
        }
        let mut file = fs::File::open(&self.destination).ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() {
            return None;
        }
        let byte_count = metadata.len();
        if byte_count == 0 || byte_count > self.maximum_bytes.unsigned_abs() {
            return Some(Landed {
                path: self.destination.clone(),
                byte_count,
                sha256: None,
                leading: Vec::new(),
            });
        }
        let mut hasher = Sha256::new();
        let mut leading = Vec::with_capacity(8);
        let mut buffer = vec![0u8; 256 * 1024];
        let mut hashed: u64 = 0;
        loop {
            let read = file.read(&mut buffer).ok()?;
            if read == 0 {
                break;
            }
            hashed += read as u64;
            if hashed > byte_count {
                return None;
            }
            if leading.len() < 8 {
                let wanted = (8 - leading.len()).min(read);
                leading.extend_from_slice(&buffer[..wanted]);
            }
            hasher.update(&buffer[..read]);
        }
        if hashed != byte_count {
            return None;
        }
        Some(Landed {
            path: self.destination.clone(),
            byte_count,
            sha256: Some(hex(&hasher.finalize())),
            leading,
        })
    }
}

/// What a lowered leg runs.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FilePlan {
    Process(ProcessPlan),
    Sequence(Vec<Invocation>),
    Receive {
        process: ProcessPlan,
        landing: HostLanding,
    },
}

/// What a leg returned (Swift `ProviderProcessReceipt` with its
/// `subprocesses` and `landedArtifact`): one receipt per process that ran,
/// in order, and for a receive the bytes the host holds afterwards.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileReceipt {
    pub subprocesses: Vec<Receipt>,
    pub landed: Option<Landed>,
}

/// Swift `DescriptorBoundProcessDispatcher.execute` for these plans: a
/// sequence runs its invocations in order and stops at the first non-zero
/// exit an invocation does not continue past; a receive prepares its
/// landing before the transfer and inspects it afterwards whatever the
/// exit, because a partial file that landed is a fact the verdict needs and
/// a clean exit is not evidence that anything landed.
pub fn run(plan: &FilePlan, dispatch: &dyn HdcDispatch) -> Result<FileReceipt, DispatchFailure> {
    match plan {
        FilePlan::Process(process) => Ok(FileReceipt {
            subprocesses: vec![dispatch.dispatch(process)?],
            landed: None,
        }),
        FilePlan::Sequence(invocations) => {
            let mut subprocesses = Vec::with_capacity(invocations.len());
            for invocation in invocations {
                let receipt = dispatch.dispatch(&ProcessPlan {
                    arguments: invocation.arguments.clone(),
                    timeout: invocation.timeout,
                    capture_bytes: CAPTURE_BYTES,
                })?;
                let stop = receipt.exit_status != 0 && !invocation.continue_after_non_zero;
                subprocesses.push(receipt);
                if stop {
                    break;
                }
            }
            Ok(FileReceipt {
                subprocesses,
                landed: None,
            })
        }
        FilePlan::Receive { process, landing } => {
            landing.prepare().map_err(|error| {
                DispatchFailure::Refused(format!("host landing could not be prepared: {error}"))
            })?;
            let receipt = dispatch.dispatch(process)?;
            Ok(FileReceipt {
                subprocesses: vec![receipt],
                landed: landing.inspect(),
            })
        }
    }
}

/// Swift `remoteRegularFileByteCount`: the size of a remote regular file from
/// one `ls -l` line, or `None` when the line does not describe one (`ls: …:
/// No such file or directory`, a directory, truncated output). Read from
/// stdout, never from the exit status: `hdc shell` reports the client's
/// status, so a missing file can still arrive with exit 0. The size column
/// is field 5 of the pinned order (`-rw-r--r-- 1 user group <size> …`).
pub fn remote_regular_file_byte_count(receipt: &Receipt) -> Option<i64> {
    if receipt.truncated {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let fields: Vec<&str> = text
        .split(char::is_whitespace)
        .filter(|field| !field.is_empty())
        .collect();
    if fields.len() < 5 || !fields[0].starts_with('-') {
        return None;
    }
    fields[4].parse().ok()
}

/// Swift `pathPresence`: whether a `ls -ld` readback shows the path —
/// exactly one listing line (a mode string) means present, exactly the
/// not-found grammar means absent, anything else answers nothing.
pub fn path_presence(receipt: &Receipt) -> Option<bool> {
    if receipt.exit_status != 0 || receipt.truncated || !receipt.stderr.is_empty() {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let bytes = &receipt.stdout;
    if bytes.len() >= 2 && b"-dlbcps".contains(&bytes[0]) && (bytes[1] == b'r' || bytes[1] == b'-')
    {
        return Some(true);
    }
    let lines: Vec<&str> = text
        .split(swift_newline)
        .filter(|line| !line.is_empty())
        .collect();
    let [line] = lines.as_slice() else {
        return None;
    };
    if line.starts_with("ls: ") && line.ends_with(": No such file or directory") {
        return Some(false);
    }
    None
}

/// Swift `faultLogEntries(in:)`: the lines between the first and the last
/// `******` separator of a Faultlogger listing, trimmed, blanks dropped.
pub fn fault_log_entries(text: &str) -> Vec<String> {
    let lines: Vec<&str> = text
        .split(swift_newline)
        .filter(|line| !line.is_empty())
        .map(|line| line.trim_matches([' ', '\t']))
        .collect();
    let Some(first) = lines.iter().position(|line| *line == "******") else {
        return Vec::new();
    };
    let Some(last) = lines.iter().rposition(|line| *line == "******") else {
        return Vec::new();
    };
    if last <= first {
        return Vec::new();
    }
    lines[first + 1..last]
        .iter()
        .filter(|line| !line.is_empty())
        .map(|line| (*line).to_owned())
        .collect()
}

/// Swift `Character.isNewline`.
fn swift_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Swift's verdict of the application liveness readback: always verified,
/// the facts saying what was observed — a running process, a stopped one,
/// an unreadable or ambiguous answer — bound to the deployed digest.
fn liveness(request: &LivenessRequest, receipt: &FileReceipt, now_utc: &str) -> Outcome {
    let identity = format!(
        "{}|{}|{}",
        request.bundle_name,
        request.ability_name.as_deref().unwrap_or(""),
        request.process_name
    );
    let mut summary = BTreeMap::new();
    summary.insert(
        "applicationRef".to_owned(),
        hex(&Sha256::digest(identity.as_bytes())),
    );
    summary.insert("abilityState".to_owned(), "UNKNOWN".to_owned());
    summary.insert("observedAtUtc".to_owned(), now_utc.to_owned());
    if let Some(digest) = &request.expected_deployed_artifact_digest {
        summary.insert("deployedArtifactDigest".to_owned(), digest.clone());
    }
    let mut answer = |state: &str, process_state: &str, observed: bool, reason: &str| {
        summary.insert("state".to_owned(), state.to_owned());
        summary.insert("processState".to_owned(), process_state.to_owned());
        summary.insert(
            "pidObserved".to_owned(),
            if observed { "true" } else { "false" }.to_owned(),
        );
        summary.insert("reasonCode".to_owned(), reason.to_owned());
    };
    let process = receipt.subprocesses.first();
    let text = process
        .filter(|process| process.exit_status == 0 && !process.truncated)
        .and_then(|process| std::str::from_utf8(&process.stdout).ok());
    let Some(text) = text else {
        let truncated = process.is_some_and(|process| process.truncated);
        answer(
            "UNKNOWN",
            "UNKNOWN",
            false,
            if truncated {
                "processReadbackTruncated"
            } else {
                "processReadbackUnavailable"
            },
        );
        return Outcome::Verified(summary);
    };
    let tokens: Vec<&str> = text
        .split(char::is_whitespace)
        .filter(|token| !token.is_empty())
        .collect();
    if tokens.is_empty() {
        answer("UNHEALTHY", "STOPPED", false, "targetProcessNotRunning");
    } else if tokens
        .iter()
        .all(|token| token.parse::<u32>().is_ok_and(|value| value > 0))
    {
        answer("HEALTHY", "RUNNING", true, "targetProcessRunning");
    } else {
        answer("UNKNOWN", "UNKNOWN", false, "processReadbackAmbiguous");
    }
    Outcome::Verified(summary)
}

/// The tree, screenshot and archive verdicts share one shape: the expected
/// number of processes, the readback at its index, a regular file of more
/// than zero bytes.
#[allow(clippy::too_many_arguments)]
fn file_product(
    receipt: &FileReceipt,
    expected: usize,
    readback: usize,
    path: &OwnedRemotePath,
    no_sequence: &str,
    readback_name: &str,
    empty_code: &'static str,
    tool: &str,
) -> Outcome {
    if receipt.subprocesses.len() != expected {
        return Outcome::Unknown(no_sequence.into());
    }
    let Some(byte_count) = remote_regular_file_byte_count(&receipt.subprocesses[readback]) else {
        return Outcome::Unknown(format!(
            "{readback_name} did not describe {} as a regular file",
            path.remote_path
        ));
    };
    if byte_count <= 0 {
        return Outcome::Failed {
            code: empty_code,
            detail: format!("{tool} left a zero-byte file at {}", path.remote_path),
        };
    }
    verified([("remoteByteCount", byte_count.to_string())])
}

fn failed(code: &'static str, detail: &str) -> Outcome {
    Outcome::Failed {
        code,
        detail: detail.to_owned(),
    }
}

fn verified<const N: usize>(facts: [(&str, String); N]) -> Outcome {
    Outcome::Verified(
        facts
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "150100424a544e4600";

    fn inputs(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    fn sub(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(10),
        }
    }

    fn sequence(receipts: Vec<Receipt>) -> FileReceipt {
        FileReceipt {
            subprocesses: receipts,
            landed: None,
        }
    }

    fn trace() -> FileAction {
        FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, false, None).unwrap(),
            path: OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png)
                .unwrap(),
        }
    }

    fn arguments(plan: &FilePlan) -> Vec<Vec<String>> {
        match plan {
            FilePlan::Process(process) | FilePlan::Receive { process, .. } => {
                vec![process.arguments.clone()]
            }
            FilePlan::Sequence(invocations) => invocations
                .iter()
                .map(|invocation| invocation.arguments.clone())
                .collect(),
        }
    }

    fn strings(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_owned()).collect()
    }

    /// The owned path: the job/step/nonce tuple under the staging root, the
    /// suffix the producer's tool requires, bounded components only.
    #[test]
    fn owned_paths_carry_the_producer_s_suffix_and_refuse_unbounded_components() {
        let trace = OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap();
        assert_eq!(
            trace.remote_path,
            "/data/local/tmp/arkdeck-job-1-capture-trace-owned.htrace"
        );
        assert_eq!(trace.basename(), "arkdeck-job-1-capture-trace-owned.htrace");
        for (image_type, suffix) in [(ImageType::Png, ".png"), (ImageType::Jpeg, ".jpeg")] {
            let still =
                OwnedRemotePath::stable("job-enc", "capture-screenshot", image_type).unwrap();
            assert!(still.remote_path.ends_with(suffix), "{}", still.remote_path);
        }
        assert!(
            OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Jpeg)
                .unwrap()
                .remote_path
                .ends_with(".json")
        );
        assert!(
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png)
                .unwrap()
                .remote_path
                .ends_with(".tar")
        );
        assert_eq!(
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence")
                .unwrap()
                .remote_path,
            "/data/local/tmp/arkdeck-job-1-capture-screen-sequence-owned-frames"
        );
        assert!(OwnedRemotePath::new("../x", "capture-trace", "n", ImageType::Png).is_err());
        assert!(OwnedRemotePath::new("job", "capture trace", "n", ImageType::Png).is_err());
        assert!(OwnedRemotePath::new("job", "capture-trace", "", ImageType::Png).is_err());
        assert!(
            OwnedRemotePath::new(&"j".repeat(128), &"s".repeat(128), "n", ImageType::Png).is_err()
        );
    }

    /// The trace request's bounds, and the anchor derived for a ring.
    #[test]
    fn trace_requests_are_bounded_and_a_ring_carries_its_anchor() {
        assert!(TraceRequest::new(0, vec!["ohos".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(121, vec!["ohos".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec![], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec!["oh os".into()], 8192, false, None).is_err());
        assert!(TraceRequest::new(5, vec!["ohos".into()], 512, false, None).is_err());
        assert!(
            TraceRequest::new(
                5,
                vec!["ohos".into()],
                8192,
                false,
                Some("ARKDECKANCHORab".into())
            )
            .is_err(),
            "an anchor is ring-only"
        );
        assert!(
            TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some("short".into())).is_err()
        );
        let anchor = TraceRequest::anchor("JOB-abc_123", "capture-trace");
        assert_eq!(anchor, "ARKDECKANCHORJOBabc123capturetrace");
        assert!(TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor)).is_ok());
        let long = TraceRequest::anchor(&"x".repeat(60), "capture-trace");
        assert_eq!(long.len(), "ARKDECKANCHOR".len() + 40);
    }

    /// The other request types' bounds.
    #[test]
    fn the_request_types_refuse_what_swift_refuses() {
        assert!(ScreenSequenceRequest::new(1, ImageType::Jpeg, None, None, None).is_err());
        assert!(ScreenSequenceRequest::new(301, ImageType::Jpeg, None, None, None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(720), None, None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(0), Some(1), None).is_err());
        assert!(ScreenSequenceRequest::new(2, ImageType::Jpeg, None, None, Some(65)).is_err());
        let request =
            ScreenSequenceRequest::new(12, ImageType::Png, Some(720), Some(1280), Some(0)).unwrap();
        assert_eq!(request.frame_name(0), "0001.png");
        assert_eq!(request.frame_name(11), "0012.png");
        assert!(FaultLogName::new("cppcrash-com.example.demo-20260731").is_ok());
        assert!(FaultLogName::new("Cppcrash-x").is_err());
        assert!(FaultLogName::new("cppcrash").is_err());
        assert!(FaultLogName::new("cppcrash-../etc").is_err());
        assert!(LivenessRequest::new("com.example.demo", None, None, None).is_ok());
        assert!(LivenessRequest::new("demo", None, None, None).is_err());
        assert!(LivenessRequest::new("com.9example", None, None, None).is_err());
        assert!(LivenessRequest::new("com.example.demo", Some("1Ability"), None, None).is_err());
        assert!(
            LivenessRequest::new(
                "com.example.demo",
                None,
                Some("com.example.demo:worker"),
                None
            )
            .is_ok()
        );
        assert!(LivenessRequest::new("com.example.demo", None, Some("bad name"), None).is_err());
        assert!(LivenessRequest::new("com.example.demo", None, None, Some("ABCD")).is_err());
        assert!(FileAction::component_detail("12", "345").is_ok());
        assert!(FileAction::component_detail("12a", "345").is_err());
        assert!(FileAction::component_detail("", "345").is_err());
    }

    /// Swift `action(for:…)`: the steps this module owns, from the request's
    /// inputs, minting the same owned path for capture, receive and cleanup.
    #[test]
    fn steps_map_to_actions_that_name_one_file_across_their_legs() {
        let empty = Map::new();
        let tree = FileAction::for_step(
            "capture-ui-tree",
            "captureRemoteFile",
            None,
            &empty,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::CaptureComponentTree { path } = &tree else {
            panic!("{tree:?}")
        };
        let receive = FileAction::for_step("receive-ui-tree", "receiveFile", None, &empty, "job-1")
            .unwrap()
            .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(&artifact.path, path);
        assert_eq!(artifact.maximum_bytes, RECEIVE_MAXIMUM_BYTES);
        assert_eq!(artifact.expected_leading_bytes, None);
        let cleanup = FileAction::for_step(
            "cleanup-ui-tree-temp",
            "cleanupOwnedRemotePath",
            None,
            &empty,
            "job-1",
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            cleanup,
            FileAction::CleanupOwnedRemotePath { path: path.clone() }
        );
        // A JPEG still: the type reaches the path, the receive's magic and
        // the cleanup alike.
        let jpeg = inputs(json!({"screenshotImageType": "jpeg"}));
        let still = FileAction::for_step(
            "capture-screenshot",
            "captureRemoteFile",
            None,
            &jpeg,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::CaptureScreenshot { image_type, path } = &still else {
            panic!("{still:?}")
        };
        assert_eq!(*image_type, ImageType::Jpeg);
        assert!(path.remote_path.ends_with(".jpeg"));
        let receive =
            FileAction::for_step("receive-screenshot", "receiveFile", None, &jpeg, "job-1")
                .unwrap()
                .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(&artifact.path, path);
        assert_eq!(
            artifact.expected_leading_bytes.as_deref(),
            Some(&JFIF_MAGIC[..])
        );
        let receive =
            FileAction::for_step("receive-screenshot", "receiveFile", None, &empty, "job-1")
                .unwrap()
                .unwrap();
        let FileAction::ReceiveOwnedArtifact(artifact) = &receive else {
            panic!("{receive:?}")
        };
        assert_eq!(
            artifact.expected_leading_bytes.as_deref(),
            Some(&PNG_MAGIC[..])
        );
        // The trace: the caller's categories, a ring's anchor.
        let ring = inputs(
            json!({"traceCategories": ["ohos", "ace"], "durationSeconds": 500,
            "traceBufferKB": 100, "ringBuffered": true}),
        );
        let trace =
            FileAction::for_step("capture-trace", "captureRemoteFile", None, &ring, "JOB-7")
                .unwrap()
                .unwrap();
        let FileAction::CaptureTrace { request, path } = &trace else {
            panic!("{trace:?}")
        };
        assert_eq!(request.duration_seconds, 120);
        assert_eq!(request.buffer_kb, 1024);
        assert!(request.ring_buffered);
        assert_eq!(
            request.coverage_anchor.as_deref(),
            Some("ARKDECKANCHORJOB7capturetrace")
        );
        assert!(path.remote_path.ends_with("-capture-trace-owned.htrace"));
        assert!(
            FileAction::for_step("capture-trace", "captureRemoteFile", None, &empty, "job-1")
                .is_err(),
            "no invented categories"
        );
        // The stdout legs.
        assert_eq!(
            FileAction::for_step(
                "capture-crash-index",
                "captureRemoteStdout",
                Some("crashIndex"),
                &empty,
                "job-1"
            )
            .unwrap(),
            Some(FileAction::CaptureCrashIndex {
                byte_budget: STDOUT_BUDGET
            })
        );
        assert!(
            FileAction::for_step(
                "capture-crash-log",
                "captureRemoteStdout",
                Some("crashLog"),
                &empty,
                "job-1"
            )
            .is_err()
        );
        let detail = inputs(json!({"windowId": "7", "componentId": "42"}));
        assert_eq!(
            FileAction::for_step(
                "capture-advanced-ui-dump",
                "captureRemoteStdout",
                Some("componentDetail"),
                &detail,
                "job-1"
            )
            .unwrap(),
            Some(FileAction::CaptureComponentDetail {
                window_id: "7".into(),
                component_id: "42".into()
            })
        );
        assert!(
            FileAction::for_step(
                "x",
                "captureRemoteStdout",
                Some("componentTree"),
                &empty,
                "job-1"
            )
            .is_err()
        );
        assert_eq!(
            FileAction::for_step(
                "capture-hilog",
                "captureRemoteStdout",
                Some("boundedHilog"),
                &empty,
                "job-1"
            )
            .unwrap(),
            None,
            "the default legs are another owner's"
        );
        assert_eq!(
            FileAction::for_step("probe-device", "probeDevice", None, &empty, "job-1").unwrap(),
            None
        );
        let live = inputs(
            json!({"bundleName": "com.example.demo", "abilityName": "EntryAbility",
            "processName": "com.example.demo:worker",
            "expectedDeployedArtifactDigest": "d".repeat(64)}),
        );
        let liveness = FileAction::for_step(
            "observe-application-liveness",
            "verifyRemoteState",
            None,
            &live,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let FileAction::ObserveApplicationLiveness(request) = &liveness else {
            panic!("{liveness:?}")
        };
        assert_eq!(request.process_name, "com.example.demo:worker");
        assert_eq!(request.ability_name.as_deref(), Some("EntryAbility"));
        // The sequence and its cleanup name the same frames.
        let frames = inputs(json!({"frameCount": 3, "imageType": "png", "displayId": 1}));
        let capture = FileAction::for_step(
            "capture-screen-sequence",
            "captureRemoteFile",
            None,
            &frames,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let cleanup = FileAction::for_step(
            "cleanup-screen-sequence-temp",
            "cleanupOwnedRemotePath",
            None,
            &frames,
            "job-1",
        )
        .unwrap()
        .unwrap();
        let (
            FileAction::CaptureScreenSequence {
                frames: a,
                archive: b,
                request: r1,
            },
            FileAction::CleanupScreenSequence {
                frames: c,
                archive: d,
                request: r2,
            },
        ) = (&capture, &cleanup)
        else {
            panic!("{capture:?} {cleanup:?}")
        };
        assert_eq!((a, b, r1), (c, d, r2));
        assert!(
            FileAction::for_step(
                "capture-screen-sequence",
                "captureRemoteFile",
                None,
                &empty,
                "job-1"
            )
            .is_err()
        );
    }

    /// The exact argv of every leg, with the `-t <key>` prefix, and no argv
    /// at all without a connect key.
    #[test]
    fn the_legs_lower_to_swift_s_exact_arguments() {
        let root = Path::new("/private/tmp/arkdeck-receive-tests/abc");
        let path =
            OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let blocking = trace().lower("capture-trace", Some(KEY), root).unwrap();
        assert_eq!(
            arguments(&blocking),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "-t",
                    "5",
                    "-b",
                    "8192",
                    "ohos",
                    "-o",
                    &path.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &path.remote_path]),
            ]
        );
        let FilePlan::Sequence(invocations) = &blocking else {
            panic!()
        };
        assert_eq!(invocations[0].timeout, Duration::from_secs(35));
        assert!(invocations[0].continue_after_non_zero);
        assert_eq!(invocations[1].timeout, Duration::from_secs(15));
        assert!(!invocations[1].continue_after_non_zero);
        let anchor = TraceRequest::anchor("job-receive-1", "capture-trace");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor.clone()))
                .unwrap(),
            path: path.clone(),
        };
        let lowered = ring.lower("capture-trace", Some(KEY), root).unwrap();
        assert_eq!(
            arguments(&lowered),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "--trace_begin",
                    "-b",
                    "8192",
                    "ohos"
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    &format!("echo {anchor} > {TRACE_MARKER_PATH}")
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    &format!("grep -c {anchor} {TRACE_RING_PATH}")
                ]),
                strings(&["-t", KEY, "shell", "sleep", "5"]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "hitrace",
                    "--trace_dump",
                    "-o",
                    &path.remote_path
                ]),
                strings(&["-t", KEY, "shell", "hitrace", "--trace_finish_nodump"]),
                strings(&["-t", KEY, "shell", "ls", "-l", &path.remote_path]),
            ]
        );
        let FilePlan::Sequence(invocations) = &lowered else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![30, 15, 15, 35, 120, 30, 15]
        );
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.continue_after_non_zero)
                .collect::<Vec<_>>(),
            vec![false, false, false, false, true, true, false]
        );
        let tree = OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap();
        assert_eq!(
            arguments(
                &FileAction::CaptureComponentTree { path: tree.clone() }
                    .lower("capture-ui-tree", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "uitest",
                    "dumpLayout",
                    "-p",
                    &tree.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &tree.remote_path]),
            ]
        );
        let still =
            OwnedRemotePath::stable("job-1", "capture-screenshot", ImageType::Jpeg).unwrap();
        assert_eq!(
            arguments(
                &FileAction::CaptureScreenshot {
                    image_type: ImageType::Jpeg,
                    path: still.clone()
                }
                .lower("capture-screenshot", Some(KEY), root)
                .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-f",
                    &still.remote_path
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &still.remote_path]),
            ]
        );
        let request =
            ScreenSequenceRequest::new(2, ImageType::Jpeg, Some(720), Some(1280), Some(0)).unwrap();
        let frames =
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png).unwrap();
        let sequence = FileAction::CaptureScreenSequence {
            request: request.clone(),
            frames: frames.clone(),
            archive: archive.clone(),
        };
        assert_eq!(
            arguments(
                &sequence
                    .lower("capture-screen-sequence", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&["-t", KEY, "shell", "mkdir", "-p", &frames.remote_path]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-w",
                    "720",
                    "-h",
                    "1280",
                    "-i",
                    "0",
                    "-f",
                    &format!("{}/0001.jpeg", frames.remote_path)
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "snapshot_display",
                    "-t",
                    "jpeg",
                    "-w",
                    "720",
                    "-h",
                    "1280",
                    "-i",
                    "0",
                    "-f",
                    &format!("{}/0002.jpeg", frames.remote_path)
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "tar",
                    "-c",
                    "-f",
                    &archive.remote_path,
                    "-C",
                    &frames.remote_path,
                    "."
                ]),
                strings(&["-t", KEY, "shell", "ls", "-l", &archive.remote_path]),
            ]
        );
        let cleanup = FileAction::CleanupScreenSequence {
            request,
            frames: frames.clone(),
            archive: archive.clone(),
        };
        assert_eq!(
            arguments(
                &cleanup
                    .lower("cleanup-screen-sequence-temp", Some(KEY), root)
                    .unwrap()
            ),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "rm",
                    "-f",
                    &format!("{}/0001.jpeg", frames.remote_path),
                    &format!("{}/0002.jpeg", frames.remote_path)
                ]),
                strings(&["-t", KEY, "shell", "rm", "-f", &archive.remote_path]),
                strings(&["-t", KEY, "shell", "rmdir", &frames.remote_path]),
                strings(&["-t", KEY, "shell", "ls", "-ld", &frames.remote_path]),
            ]
        );
        // `file recv` names both paths; the host file is the remote basename.
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: None,
        });
        let lowered = receive
            .lower("receive-trace-artifact", Some(KEY), root)
            .unwrap();
        let FilePlan::Receive { process, landing } = &lowered else {
            panic!("{lowered:?}")
        };
        // The host path is the receive root joined by the platform, so its
        // separator is the platform's (Windows CI compiles these tests too).
        let destination = root.join("arkdeck-job-receive-1-capture-trace-n1.htrace");
        let destination_text = destination.to_string_lossy().into_owned();
        assert_eq!(
            process.arguments,
            strings(&[
                "-t",
                KEY,
                "file",
                "recv",
                &path.remote_path,
                &destination_text
            ])
        );
        assert_eq!(process.timeout, Duration::from_secs(60));
        assert_eq!(landing.destination, destination);
        assert_eq!(landing.maximum_bytes, RECEIVE_MAXIMUM_BYTES);
        assert_eq!(
            arguments(
                &FileAction::CleanupOwnedRemotePath { path: path.clone() }
                    .lower("cleanup-remote-temp", Some(KEY), root)
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "rm",
                "-f",
                &path.remote_path
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::CaptureCrashIndex {
                    byte_budget: STDOUT_BUDGET
                }
                .lower("capture-crash-index", Some(KEY), root)
                .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "1201",
                "-a",
                "-p Faultlogger -l"
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::CaptureCrashLog {
                    name: FaultLogName::new("cppcrash-demo-1").unwrap(),
                    byte_budget: STDOUT_BUDGET
                }
                .lower("capture-crash-log", Some(KEY), root)
                .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "1201",
                "-a",
                "-p Faultlogger -f cppcrash-demo-1"
            ])]
        );
        assert_eq!(
            arguments(
                &FileAction::component_detail("7", "42")
                    .unwrap()
                    .lower("capture-advanced-ui-dump", Some(KEY), root)
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "WindowManagerService",
                "-a",
                "-w 7 -element -lastpage 42"
            ])]
        );
        let liveness = FileAction::ObserveApplicationLiveness(
            LivenessRequest::new(
                "com.example.demo",
                Some("EntryAbility"),
                Some("com.example.demo:worker"),
                None,
            )
            .unwrap(),
        );
        let lowered = liveness
            .lower("observe-application-liveness", Some(KEY), root)
            .unwrap();
        assert_eq!(
            arguments(&lowered),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "pidof",
                "com.example.demo:worker"
            ])]
        );
        let FilePlan::Process(process) = &lowered else {
            panic!()
        };
        assert_eq!(process.timeout, Duration::from_secs(30));
        assert!(
            trace()
                .lower("capture-trace", None, root)
                .unwrap_err()
                .contains("factsUnavailable")
        );
        assert!(trace().lower("capture-trace", Some(""), root).is_err());
    }

    /// The trace verdict reads the listing, never hitrace's exit status.
    #[test]
    fn a_trace_is_judged_by_its_listing() {
        let verdict = trace().verify(
            &sequence(vec![
                sub("", 1),
                sub(
                    "-rw-r--r-- 1 root root 4096 2026-07-31 00:00 /data/local/tmp/t.htrace\n",
                    0,
                ),
            ]),
            "",
        );
        assert_eq!(verdict, verified([("remoteByteCount", "4096".into())]));
        let none = trace().verify(
            &sequence(vec![
                sub("", 0),
                sub(
                    "ls: /data/local/tmp/t.htrace: No such file or directory\n",
                    0,
                ),
            ]),
            "",
        );
        assert!(matches!(none, Outcome::Unknown(_)), "{none:?}");
        let empty = trace().verify(
            &sequence(vec![
                sub("", 0),
                sub(
                    "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/t.htrace\n",
                    0,
                ),
            ]),
            "",
        );
        assert!(
            matches!(
                empty,
                Outcome::Failed {
                    code: "emptyTrace",
                    ..
                }
            ),
            "{empty:?}"
        );
        for listing in [
            "drwxr-xr-x 2 root root 4096 2026-07-31 00:00 /data/local/tmp\n",
            "\n",
            "-rw-r--r-- 1 root root\n",
        ] {
            let verdict = trace().verify(&sequence(vec![sub("", 0), sub(listing, 0)]), "");
            assert!(
                matches!(verdict, Outcome::Unknown(_)),
                "{listing:?} gave {verdict:?}"
            );
        }
        assert!(matches!(
            trace().verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let mut truncated = sub("-rw-r--r-- 1 root root 4096 2026", 0);
        truncated.truncated = true;
        assert!(matches!(
            trace().verify(&sequence(vec![sub("", 0), truncated]), ""),
            Outcome::Unknown(_)
        ));
    }

    /// A ring capture is judged by its last process, and reports whether the
    /// ring held the anchor; a ring that did not answer is unknown.
    #[test]
    fn a_ring_capture_reports_its_anchor_from_the_readback_it_already_has() {
        let anchor = TraceRequest::anchor("job-1", "capture-trace");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, Some(anchor.clone()))
                .unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let listing = "-rw-r--r-- 1 root root 8192 2026-07-31 00:00 /data/local/tmp/t.htrace\n";
        let receipts = |count: &str| {
            sequence(vec![
                sub("", 0),
                sub("", 0),
                sub(count, 0),
                sub("", 0),
                sub("", 1),
                sub("", 0),
                sub(listing, 0),
            ])
        };
        let held = ring.verify(&receipts("1\n"), "");
        let Outcome::Verified(summary) = &held else {
            panic!("{held:?}")
        };
        assert_eq!(summary["remoteByteCount"], "8192");
        assert_eq!(summary["ringHeldCoverageAnchor"], "true");
        assert_eq!(summary["coverageAnchor"], anchor);
        let Outcome::Verified(summary) = ring.verify(&receipts("0\n"), "") else {
            panic!()
        };
        assert_eq!(summary["ringHeldCoverageAnchor"], "false");
        assert!(matches!(
            ring.verify(&receipts("grep: no\n"), ""),
            Outcome::Unknown(_)
        ));
        assert!(matches!(
            ring.verify(&sequence(vec![sub("", 0), sub(listing, 0)]), ""),
            Outcome::Unknown(_)
        ));
        let plain = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, None).unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let Outcome::Verified(summary) = plain.verify(
            &sequence(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(listing, 0),
            ]),
            "",
        ) else {
            panic!()
        };
        assert_eq!(summary.len(), 1);
    }

    /// The tree and the still: two processes, the second a regular file of
    /// more than zero bytes.
    #[test]
    fn the_tree_and_the_still_are_judged_by_their_readbacks() {
        let tree = FileAction::CaptureComponentTree {
            path: OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap(),
        };
        let listing = "-rw-r--r-- 1 root root 12 2026-07-31 00:00 /data/local/tmp/x\n";
        assert_eq!(
            tree.verify(
                &sequence(vec![
                    sub("DumpLayout saved to:/data/local/tmp/x\n", 0),
                    sub(listing, 0)
                ]),
                ""
            ),
            verified([("remoteByteCount", "12".into())])
        );
        let zero = "-rw-r--r-- 1 root root 0 2026-07-31 00:00 /data/local/tmp/x\n";
        assert!(matches!(
            tree.verify(&sequence(vec![sub("", 0), sub(zero, 0)]), ""),
            Outcome::Failed {
                code: "emptyComponentTree",
                ..
            }
        ));
        assert!(matches!(
            tree.verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let still = FileAction::CaptureScreenshot {
            image_type: ImageType::Png,
            path: OwnedRemotePath::stable("job-1", "capture-screenshot", ImageType::Png).unwrap(),
        };
        assert!(matches!(
            still.verify(&sequence(vec![sub("", 0), sub(zero, 0)]), ""),
            Outcome::Failed {
                code: "emptyScreenshot",
                ..
            }
        ));
        assert!(matches!(
            still.verify(
                &sequence(vec![
                    sub("", 0),
                    sub("ls: x: No such file or directory\n", 0)
                ]),
                ""
            ),
            Outcome::Unknown(_)
        ));
    }

    /// The sequence: the archive's listing decides, failed frames are gaps
    /// counted as facts, the cleanup is proved by the directory's absence.
    #[test]
    fn a_screen_sequence_reports_its_gaps_and_its_cleanup_needs_the_directory_gone() {
        let request = ScreenSequenceRequest::new(3, ImageType::Jpeg, None, None, None).unwrap();
        let frames =
            OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence").unwrap();
        let archive =
            OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png).unwrap();
        let capture = FileAction::CaptureScreenSequence {
            request: request.clone(),
            frames: frames.clone(),
            archive: archive.clone(),
        };
        let frame = |exit: i32, millis: u64| Receipt {
            duration: Duration::from_millis(millis),
            ..sub("", exit)
        };
        let listing = "-rw-r--r-- 1 root root 30720 2026-08-26 00:00 /data/local/tmp/a.tar\n";
        let verdict = capture.verify(
            &sequence(vec![
                sub("", 0),
                frame(0, 500),
                frame(1, 250),
                frame(0, 500),
                sub("", 0),
                sub(listing, 0),
            ]),
            "",
        );
        let Outcome::Verified(summary) = &verdict else {
            panic!("{verdict:?}")
        };
        assert_eq!(summary["remoteByteCount"], "30720");
        assert_eq!(summary["requestedFrameCount"], "3");
        assert_eq!(summary["capturedFrameCount"], "2");
        assert_eq!(summary["frameDurationsSeconds"], "0.500,0.250,0.500");
        assert_eq!(summary["observedFramesPerSecond"], "1.60");
        assert!(matches!(
            capture.verify(&sequence(vec![sub("", 0), sub("", 0), sub(listing, 0)]), ""),
            Outcome::Unknown(_)
        ));
        let cleanup = FileAction::CleanupScreenSequence {
            request,
            frames: frames.clone(),
            archive,
        };
        let gone = format!("ls: {}: No such file or directory\n", frames.remote_path);
        assert_eq!(
            cleanup.verify(
                &sequence(vec![sub("", 0), sub("", 0), sub("", 0), sub(&gone, 0)]),
                ""
            ),
            verified([("cleaned", "true".into())])
        );
        assert!(matches!(
            cleanup.verify(
                &sequence(vec![
                    sub("", 0),
                    sub("", 0),
                    sub("", 1),
                    sub("drwxr-xr-x 2 root root 4096 2026 x\n", 0)
                ]),
                ""
            ),
            Outcome::Failed {
                code: "sequenceCleanupResidue",
                ..
            }
        ));
        assert!(matches!(
            cleanup.verify(
                &sequence(vec![sub("", 0), sub("", 0), sub("", 0), sub("", 0)]),
                ""
            ),
            Outcome::Unknown(_)
        ));
        let mut noisy = sub(&gone, 0);
        noisy.stderr = b"warning".to_vec();
        assert_eq!(path_presence(&noisy), None);
        assert_eq!(path_presence(&sub(&gone, 1)), None);
        assert_eq!(
            path_presence(&sub("-rw-r--r-- 1 root root 1 2026 x\n", 0)),
            Some(true)
        );
        assert_eq!(path_presence(&sub(&format!("{gone}{gone}"), 0)), None);
    }

    /// The received bytes decide: none is unknown, empty and over-budget
    /// fail without a digest, a pinned hash and a pinned magic are checked,
    /// and the summary names the file, never the host directory.
    #[test]
    fn a_receive_is_judged_by_the_bytes_that_landed() {
        let root =
            std::env::temp_dir().join(format!("arkdeck-capture-files-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let path =
            OwnedRemotePath::new("job-receive-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let artifact = |expected: Option<&str>, maximum: i64, magic: Option<&[u8]>| {
            FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
                path: path.clone(),
                expected_sha256: expected.map(str::to_owned),
                maximum_bytes: maximum,
                expected_leading_bytes: magic.map(<[u8]>::to_vec),
            })
        };
        let landing = |maximum: i64| HostLanding {
            destination: host_landing(&root, &path),
            maximum_bytes: maximum,
            expected_sha256: None,
        };
        let receipt = |landing: &HostLanding| FileReceipt {
            subprocesses: vec![sub("FileTransfer finish, Size:0\n", 0)],
            landed: landing.inspect(),
        };
        let landing_64k = landing(64 * 1024);
        landing_64k.prepare().unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Unknown(_)
        ));
        fs::write(&landing_64k.destination, b"").unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "emptyArtifact",
                ..
            }
        ));
        let payload = b"htrace-fixture-bytes";
        fs::write(&landing_64k.destination, payload).unwrap();
        let digest = hex(&Sha256::digest(payload));
        let Outcome::Verified(summary) =
            artifact(None, 64 * 1024, None).verify(&receipt(&landing_64k), "")
        else {
            panic!()
        };
        assert_eq!(summary["byteCount"], payload.len().to_string());
        assert_eq!(summary["sha256"], digest);
        assert_eq!(
            summary["localArtifact"],
            "arkdeck-job-receive-1-capture-trace-n1.htrace"
        );
        assert!(
            summary
                .values()
                .all(|value| !value.contains(&root.to_string_lossy().into_owned()))
        );
        assert!(matches!(
            artifact(Some(&digest), 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Verified(_)
        ));
        assert!(matches!(
            artifact(Some(&"0".repeat(64)), 64 * 1024, None).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "hashMismatch",
                ..
            }
        ));
        assert!(matches!(
            artifact(None, 64 * 1024, Some(&PNG_MAGIC)).verify(&receipt(&landing_64k), ""),
            Outcome::Failed {
                code: "unexpectedFormat",
                ..
            }
        ));
        fs::write(&landing_64k.destination, [&PNG_MAGIC[..], b"rest"].concat()).unwrap();
        assert!(matches!(
            artifact(None, 64 * 1024, Some(&PNG_MAGIC)).verify(&receipt(&landing_64k), ""),
            Outcome::Verified(_)
        ));
        let landing_8 = landing(8);
        fs::write(&landing_8.destination, [0x61u8; 4096]).unwrap();
        let landed = landing_8.inspect().unwrap();
        assert_eq!(landed.byte_count, 4096);
        assert_eq!(
            landed.sha256, None,
            "an over-budget file must not be digested"
        );
        assert!(matches!(
            artifact(None, 8, None).verify(&receipt(&landing_8), ""),
            Outcome::Failed {
                code: "oversizedArtifact",
                ..
            }
        ));
        // A stale file from an earlier attempt is cleared by the preparation;
        // a symlink or a directory at the destination is never inspected.
        landing_64k.prepare().unwrap();
        assert_eq!(landing_64k.inspect(), None);
        fs::create_dir(&landing_64k.destination).unwrap();
        assert_eq!(landing_64k.inspect(), None);
        #[cfg(unix)]
        {
            landing_64k.prepare().unwrap();
            std::os::unix::fs::symlink("/etc/hosts", &landing_64k.destination).unwrap();
            assert_eq!(landing_64k.inspect(), None);
        }
        let _ = fs::remove_dir_all(&root);
    }

    /// The crash ledger and one entry of it.
    #[test]
    fn the_crash_ledger_is_read_as_swift_reads_it() {
        let index = FileAction::CaptureCrashIndex {
            byte_budget: STDOUT_BUDGET,
        };
        let listing =
            "Faultlog list:\n******\ncppcrash-com.example.demo-20260731\n\njscrash-x-1\n******\n";
        assert_eq!(
            index.verify(&sequence(vec![sub(listing, 0)]), ""),
            verified([
                ("entryCount", "2".into()),
                ("byteCount", listing.len().to_string())
            ])
        );
        assert_eq!(
            index.verify(&sequence(vec![sub("no entries\n", 0)]), ""),
            verified([("entryCount", "0".into()), ("byteCount", "11".into())])
        );
        // Between the first and the last separator, whatever lies there: a
        // middle separator is an entry too, as Swift keeps it.
        assert_eq!(
            fault_log_entries("******\n  a \n******\nb\n******\n"),
            vec!["a", "******", "b"]
        );
        assert_eq!(fault_log_entries("******\n"), Vec::<String>::new());
        let mut truncated = sub(listing, 0);
        truncated.truncated = true;
        assert!(matches!(
            index.verify(&sequence(vec![truncated]), ""),
            Outcome::Failed {
                code: "truncated",
                ..
            }
        ));
        let log = FileAction::CaptureCrashLog {
            name: FaultLogName::new("cppcrash-com.example.demo-20260731").unwrap(),
            byte_budget: STDOUT_BUDGET,
        };
        assert_eq!(
            log.verify(
                &sequence(vec![sub("Generated by HiviewDFX@OpenHarmony\nPid:1\n", 0)]),
                ""
            ),
            verified([
                ("faultLogName", "cppcrash-com.example.demo-20260731".into()),
                ("byteCount", "41".into()),
            ])
        );
        assert!(matches!(
            log.verify(&sequence(vec![sub("invalid parameters.\n", 0)]), ""),
            Outcome::Failed {
                code: "faultLogNotFound",
                ..
            }
        ));
        assert!(matches!(
            log.verify(&sequence(vec![sub("something else\n", 0)]), ""),
            Outcome::Unknown(_)
        ));
        let mut binary = sub("", 0);
        binary.stdout = vec![0xFF, 0xFE];
        assert!(matches!(
            log.verify(&sequence(vec![binary]), ""),
            Outcome::Failed {
                code: "invalidEncoding",
                ..
            }
        ));
    }

    /// Liveness is always a verified fact: running, stopped, unreadable or
    /// ambiguous, bound to the application and the deployed digest.
    #[test]
    fn application_liveness_is_a_fact_in_every_case() {
        let request = LivenessRequest::new(
            "com.example.demo",
            Some("EntryAbility"),
            Some("com.example.demo:worker"),
            Some(&"d".repeat(64)),
        )
        .unwrap();
        let action = FileAction::ObserveApplicationLiveness(request.clone());
        let now = "2026-07-29T00:00:00Z";
        let expect = |stdout: &str,
                      exit: i32,
                      state: &str,
                      process_state: &str,
                      observed: &str,
                      reason: &str| {
            let Outcome::Verified(summary) = action.verify(&sequence(vec![sub(stdout, exit)]), now)
            else {
                panic!()
            };
            assert_eq!(summary["state"], state, "{stdout:?}");
            assert_eq!(summary["processState"], process_state);
            assert_eq!(summary["pidObserved"], observed);
            assert_eq!(summary["reasonCode"], reason);
            assert_eq!(summary["abilityState"], "UNKNOWN");
            assert_eq!(summary["observedAtUtc"], now);
            assert_eq!(summary["deployedArtifactDigest"], "d".repeat(64));
            assert_eq!(
                summary["applicationRef"],
                hex(&Sha256::digest(
                    b"com.example.demo|EntryAbility|com.example.demo:worker"
                ))
            );
        };
        expect(
            "3421 3422\n",
            0,
            "HEALTHY",
            "RUNNING",
            "true",
            "targetProcessRunning",
        );
        expect(
            "\n",
            0,
            "UNHEALTHY",
            "STOPPED",
            "false",
            "targetProcessNotRunning",
        );
        expect(
            "3421 abc\n",
            0,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackAmbiguous",
        );
        expect(
            "0\n",
            0,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackAmbiguous",
        );
        expect(
            "3421\n",
            1,
            "UNKNOWN",
            "UNKNOWN",
            "false",
            "processReadbackUnavailable",
        );
        let mut truncated = sub("3421", 0);
        truncated.truncated = true;
        let Outcome::Verified(summary) = action.verify(
            &FileReceipt {
                subprocesses: vec![truncated],
                landed: None,
            },
            now,
        ) else {
            panic!()
        };
        assert_eq!(summary["reasonCode"], "processReadbackTruncated");
        let bare = FileAction::ObserveApplicationLiveness(
            LivenessRequest::new("com.example.demo", None, None, None).unwrap(),
        );
        let Outcome::Verified(summary) = bare.verify(&sequence(vec![sub("1\n", 0)]), now) else {
            panic!()
        };
        assert!(!summary.contains_key("deployedArtifactDigest"));
        assert_eq!(
            summary["applicationRef"],
            hex(&Sha256::digest(b"com.example.demo||com.example.demo"))
        );
    }

    /// The persisted forms Swift journals, and the remaining verdicts.
    #[test]
    fn persisted_forms_and_the_stdout_and_cleanup_verdicts_follow_swift() {
        let path = OwnedRemotePath::new("job-1", "capture-trace", "n1", ImageType::Png).unwrap();
        let (kind, arguments) = trace().persisted();
        assert_eq!(kind, "hdc.captureTrace");
        assert!(arguments.contains(&(
            "remotePath",
            Persisted::Text("/data/local/tmp/arkdeck-job-receive-1-capture-trace-n1.htrace".into())
        )));
        assert!(arguments.contains(&("categories", Persisted::Texts(vec!["ohos".into()]))));
        assert!(arguments.contains(&("bufferKB", Persisted::Integer(8192))));
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: Some(JFIF_MAGIC.to_vec()),
        });
        let (kind, arguments) = receive.persisted();
        assert_eq!(kind, "hdc.receiveOwnedArtifact");
        assert!(arguments.contains(&("expectedLeadingBytes", Persisted::Text("ffd8ffe0".into()))));
        assert!(arguments.contains(&("maximumBytes", Persisted::Integer(RECEIVE_MAXIMUM_BYTES))));
        assert!(!arguments.iter().any(|(key, _)| *key == "expectedSha256"));
        assert_eq!(
            FileAction::CleanupOwnedRemotePath { path: path.clone() }
                .persisted()
                .0,
            "hdc.cleanupOwnedRemotePath"
        );
        assert_eq!(
            FileAction::component_detail("1", "2")
                .unwrap()
                .persisted()
                .0,
            "hdc.captureUIDump"
        );
        assert_eq!(
            FileAction::CaptureCrashIndex { byte_budget: 1 }.effect(),
            "readOnly"
        );
        assert_eq!(trace().effect(), "deviceMutation");
        let cleanup = FileAction::CleanupOwnedRemotePath { path: path.clone() };
        assert_eq!(
            cleanup.verify(&sequence(vec![sub("", 0)]), ""),
            verified([("cleaned", path.remote_path.clone())])
        );
        assert!(matches!(
            cleanup.verify(&sequence(vec![sub("", 1)]), ""),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        let detail = FileAction::component_detail("7", "42").unwrap();
        assert_eq!(
            detail.verify(&sequence(vec![sub("<window/>", 0)]), ""),
            verified([("byteCount", "9".into())])
        );
        assert!(matches!(
            detail.verify(&sequence(vec![sub("", 0)]), ""),
            Outcome::Unknown(_)
        ));
    }

    /// The runner: a sequence stops at the first non-zero exit an invocation
    /// does not continue past; a receive prepares and inspects its landing.
    #[test]
    fn the_runner_follows_swift_s_sequence_and_landing_rules() {
        use std::cell::RefCell;
        struct Scripted {
            exits: Vec<i32>,
            seen: RefCell<Vec<Vec<String>>>,
            write: Option<(PathBuf, Vec<u8>)>,
        }
        impl HdcDispatch for Scripted {
            fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
                let index = self.seen.borrow().len();
                self.seen.borrow_mut().push(plan.arguments.clone());
                if let Some((path, bytes)) = &self.write {
                    fs::write(path, bytes).unwrap();
                }
                Ok(sub("", self.exits.get(index).copied().unwrap_or(0)))
            }
        }
        let root = Path::new("/tmp");
        let ring = FileAction::CaptureTrace {
            request: TraceRequest::new(5, vec!["ohos".into()], 8192, true, None).unwrap(),
            path: OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap(),
        };
        let plan = ring.lower("capture-trace", Some(KEY), root).unwrap();
        // begin fails: nothing else runs.
        let stopped = Scripted {
            exits: vec![1],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        assert_eq!(run(&plan, &stopped).unwrap().subprocesses.len(), 1);
        // dump fails but continues: the stop and the readback still run.
        let continued = Scripted {
            exits: vec![0, 0, 1, 0, 0],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        assert_eq!(run(&plan, &continued).unwrap().subprocesses.len(), 5);
        assert_eq!(continued.seen.borrow().len(), 5);
        let landing_root =
            std::env::temp_dir().join(format!("arkdeck-capture-run-{}", std::process::id()));
        let _ = fs::remove_dir_all(&landing_root);
        let path = OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap();
        let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
            path: path.clone(),
            expected_sha256: None,
            maximum_bytes: RECEIVE_MAXIMUM_BYTES,
            expected_leading_bytes: None,
        });
        let plan = receive
            .lower("receive-ui-tree", Some(KEY), &landing_root)
            .unwrap();
        let destination = host_landing(&landing_root, &path);
        fs::create_dir_all(&landing_root).unwrap();
        fs::write(&destination, b"stale-bytes-from-attempt-1").unwrap();
        let nothing = Scripted {
            exits: vec![0],
            seen: RefCell::new(Vec::new()),
            write: None,
        };
        let receipt = run(&plan, &nothing).unwrap();
        assert_eq!(
            receipt.landed, None,
            "the stale file is cleared before the transfer"
        );
        let writes = Scripted {
            exits: vec![0],
            seen: RefCell::new(Vec::new()),
            write: Some((destination.clone(), b"{\"tree\":1}".to_vec())),
        };
        let receipt = run(&plan, &writes).unwrap();
        let landed = receipt.landed.unwrap();
        assert_eq!(landed.byte_count, 10);
        assert_eq!(
            landed.leading,
            b"{\"tree\":".to_vec(),
            "the first eight bytes"
        );
        assert_eq!(landed.sha256, Some(hex(&Sha256::digest(b"{\"tree\":1}"))));
        let _ = fs::remove_dir_all(&landing_root);
    }
}
