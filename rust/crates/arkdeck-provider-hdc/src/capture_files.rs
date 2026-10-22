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
use crate::debug_hap::{HapAction, PersistedArguments};
use crate::native_library::Reconcile;
use crate::operation::device_arguments;
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
    /// A reviewed interactive session. Its host wait requires a live Runtime
    /// owner; generic process-sequence execution refuses it before dispatch.
    CaptureDiagnosticTrace {
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

// FileAction execution. Included so this stays the same module.
include!("capture_file_parts/actions.rs");

/// Swift's answer for a readback that saw nothing definite.
const INDEFINITE: &str = "dedicated readback did not produce a definite presence";

/// A screen sequence's capture or cleanup that a Job parked on, as its
/// reconcile reads it back: the provider-owned archive and frames directory
/// the persisted action names. Rust only, a declared difference from Swift
/// (the maintainer's rule of 2026-09-20, applied by the coordinating session
/// on 2026-09-24): Swift's `materialize()` has no case for either kind, so a
/// reconcile of such a Job begins and then fails, forever. Here the parked
/// step is concluded the way a capture file leg is (`ls -ld` of what it
/// wrote) and never resent: the capture by its archive, which it writes
/// last, and its frames directory, which it writes first; the cleanup by the
/// frames directory, whose absence is what it proves.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParkedScreenSequence {
    /// The cleanup rather than the capture.
    pub cleanup: bool,
    pub frames: OwnedRemoteDirectory,
    pub archive: OwnedRemotePath,
}

impl ParkedScreenSequence {
    /// The owned paths a persisted `hdc.captureScreenSequence` or
    /// `hdc.cleanupScreenSequence` names, rebuilt through their constructors
    /// as Swift's materialization rebuilds every owned path, each required to
    /// be exactly the recorded one; the capture's request checked again as a
    /// capture checks it, and the cleanup's frame count, all it persists of
    /// the request, within the same bound. `None` is any other kind.
    pub fn from_persisted(
        kind: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let cleanup = match kind {
            "hdc.captureScreenSequence" => false,
            "hdc.cleanupScreenSequence" => true,
            _ => return Ok(None),
        };
        let persisted = PersistedArguments { kind, arguments };
        let archive = persisted.owned_path(ImageType::Png)?;
        if archive.step_id != "capture-screen-sequence" {
            return persisted.refuse("does not name a screen sequence archive");
        }
        let frames = OwnedRemoteDirectory::new(
            &archive.job_id,
            &archive.step_id,
            &archive.nonce,
            DirectoryPurpose::Frames,
        )?;
        if persisted.string("framesDirectory")? != frames.remote_path {
            return persisted.refuse("frames directory does not match its owned components");
        }
        let frame_count = persisted.integer("frameCount")?;
        if cleanup {
            if !(2..=MAXIMUM_FRAMES).contains(&frame_count) {
                return Err(RequestError::OutOfBounds {
                    field: "frameCount",
                    detail: format!("2...{MAXIMUM_FRAMES}"),
                }
                .into());
            }
        } else {
            let requested = persisted.string("imageType")?;
            let Some(image_type) = ImageType::parse(requested) else {
                return persisted.refuse("carries an unregistered image type");
            };
            ScreenSequenceRequest::new(
                frame_count,
                image_type,
                persisted.optional_integer("width")?,
                persisted.optional_integer("height")?,
                persisted.optional_integer("displayId")?,
            )?;
        }
        Ok(Some(Self {
            cleanup,
            frames,
            archive,
        }))
    }

    /// The read-only probes that conclude it, in the order they are
    /// dispatched, each once: the capture's archive, then its frames
    /// directory; the cleanup's frames directory.
    pub fn readbacks(&self) -> Vec<HapAction> {
        let frames = HapAction::ReadOwnedDirectoryPresence(self.frames.clone());
        if self.cleanup {
            vec![frames]
        } else {
            vec![
                HapAction::ReadOwnedPathPresence {
                    path: self.archive.clone(),
                },
                frames,
            ]
        }
    }

    /// The verdict on what the probes read, one presence per probe in
    /// [`Self::readbacks`] order, each definite or not. Nothing is concluded
    /// unless every probe answered definitely. A capture whose archive is
    /// there completed; one that left neither its archive nor its frames
    /// directory was not executed; one that left its frames without their
    /// archive ran in part — the state its own verdict leaves unknown — so it
    /// stays unknown. A cleanup whose frames directory is gone completed; one
    /// whose directory remains was not executed, as a capture leg's cleanup
    /// is read.
    pub fn reconcile(&self, presences: &[Option<bool>]) -> Reconcile {
        let completed = |present: bool| {
            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                "postconditionPresent".to_owned(),
                present.to_string(),
            )]))
        };
        match (self.cleanup, presences) {
            (true, [Some(false)]) => completed(false),
            (true, [Some(true)]) => Reconcile::ConfirmedNotExecuted,
            (false, [Some(true), Some(_)]) => completed(true),
            (false, [Some(false), Some(false)]) => Reconcile::ConfirmedNotExecuted,
            (false, [Some(false), Some(true)]) => Reconcile::StillUnknown(format!(
                "frames directory {} remains without its archive {}; original not resent",
                self.frames.remote_path, self.archive.remote_path
            )),
            _ => Reconcile::StillUnknown(INDEFINITE.into()),
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
    /// All device invocations are materialized before admission. Only the
    /// intervening host wait can be shortened by a Runtime stop request.
    DiagnosticTrace {
        arm: Vec<Invocation>,
        finalize: Vec<Invocation>,
        maximum_seconds: u64,
    },
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
        FilePlan::DiagnosticTrace { .. } => Err(DispatchFailure::Refused(
            "interactive trace requires its live Runtime session owner".into(),
        )),
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

/// Swift's reading of a persisted `expectedLeadingBytes`: two characters at
/// a time while two remain, each pair a byte when it is hexadecimal and
/// skipped when it is not.
fn lenient_hex(text: &str) -> Vec<u8> {
    let characters: Vec<char> = text.chars().collect();
    characters
        .as_chunks::<2>()
        .0
        .iter()
        .filter_map(|pair| u8::from_str_radix(&pair.iter().collect::<String>(), 16).ok())
        .collect()
}

#[cfg(test)]
// Tests. Included so they stay in this module.
include!("capture_file_parts/tests.rs");
