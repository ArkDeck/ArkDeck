//! `arkdeck runtime support-bundle preview|export`: Swift's
//! `RuntimeCLI.runRuntimeSupportBundle` over its production provider
//! (`RuntimeSupportBundleApplicationFacade`) and `LocalDiagnosticBundle`.
//!
//! The bundle is a directory of three documents at exactly the destination
//! the caller names: `metadata.json` (this CLI's name, version and host
//! platform), `hdc/tool-placeholder.json` (redacted and unverified states
//! only; HDC is never probed) and `bundle.json` (the manifest). It reads no
//! Runtime storage, no log and no file: no device data, Session, journal,
//! Artifact or secret can reach it. `preview` writes nothing and names the
//! scope's digest, which binds the destination, its parent directory's
//! identity and every entry's bytes; `export` recomputes it and publishes only
//! when the caller hands that exact digest back.
// The publication is macOS's (`arkdeck_platform::publish_bundle`); elsewhere
// both leaves refuse before it, leaving its preparation unused.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
use crate::CliError;
use serde_json::{Map, Value, json};

/// Swift's fixed warning, as it ships (its words name App logs and Job
/// summaries this bundle does not hold; they are Swift's, kept as they are).
pub const SENSITIVE_DATA_WARNING: &str =
    "诊断包包含 App 日志和结构化 Job 摘要；设备 raw 默认排除，分享前仍应检查预览。";
/// Swift `LocalDiagnosticBundleExporter.defaultMaximumBundleBytes`.
pub const MAXIMUM_BUNDLE_BYTES: u64 = 32 * 1024 * 1024;

fn fail(code: &'static str, message: &str) -> CliError {
    CliError::new(code, message)
}

/// Swift `URL(filePath:).standardizedFileURL.path` for an absolute path
/// (`arkdeck_contract::foundation_path::standardized`): lexical, and a leading
/// `/private` dropped only where what remains exists.
pub fn standardized(path: &str) -> String {
    arkdeck_contract::foundation_path::standardized(std::path::Path::new(path))
        .to_string_lossy()
        .into_owned()
}

/// The document `metadata.json` holds: Swift's `DiagnosticBundleMetadata`
/// for this executable, which carries no bundle version, so both versions are
/// Swift's fallback.
fn metadata() -> Option<Value> {
    #[cfg(target_os = "macos")]
    let platform = arkdeck_platform::operating_system_version()
        .map(|(major, minor, patch)| format!("macOS {major}.{minor}.{patch}"))?;
    #[cfg(not(target_os = "macos"))]
    let platform: String = None?;
    let architecture = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else {
        "unknown"
    };
    Some(json!({"appName": "ArkDeck", "appVersion": "development",
        "buildVersion": "development", "platform": platform, "architecture": architecture}))
}

/// The redacted HDC tool placeholder the production provider hands the
/// writer.
fn tool() -> Value {
    json!({"path": "redacted", "version": "unverified", "serverEndpoint": "redacted",
        "serverOwnership": "unverified"})
}

fn canonical(value: &Value) -> Vec<u8> {
    arkdeck_contract::canonical_json(value).expect("a bundle document")
}

fn sha256(bytes: &[u8]) -> String {
    arkdeck_contract::sha256_hex(bytes)
}

/// Swift `ISO8601Timestamps.string(from:includingFractionalSeconds: true)`:
/// UTC to the millisecond.
fn generated_at() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let whole = crate::utc_now_at(now.as_secs());
    format!(
        "{}.{:03}Z",
        whole.trim_end_matches('Z'),
        now.subsec_millis()
    )
}

/// What `prepare` and `makePreview` produce: the entries, the scope digest,
/// the preview and the manifest the preview's size was solved against.
struct Prepared {
    entries: Vec<(&'static str, Vec<u8>)>,
    preview: Value,
    manifest: Vec<u8>,
}

/// Swift `prepare` and `makePreview`: the entries, the digest over the
/// destination, its parent's identity and every entry, and the size of the
/// whole bundle, the manifest included, solved to a fixed point.
fn prepare(destination: &str, device: u64, inode: u64, quota: u64) -> Result<Prepared, CliError> {
    let metadata = metadata().ok_or_else(|| {
        fail(
            "operationUnavailable",
            "the local support-bundle service is unavailable",
        )
    })?;
    let entries = vec![
        ("metadata.json", canonical(&metadata)),
        ("hdc/tool-placeholder.json", canonical(&tool())),
    ];
    let mut scope = format!(
        "{}\nparent-device:{device}\nparent-inode:{inode}\n",
        standardized(destination)
    )
    .into_bytes();
    let mut sorted: Vec<&(&str, Vec<u8>)> = entries.iter().collect();
    sorted.sort_by(|left, right| left.0.cmp(right.0));
    for (path, bytes) in sorted {
        scope.extend_from_slice(path.as_bytes());
        scope.push(0);
        scope.extend_from_slice(sha256(bytes).as_bytes());
        scope.push(b'\n');
    }
    let scope = sha256(&scope);
    let generated = generated_at();
    let entry_bytes: u64 = entries.iter().map(|(_, bytes)| bytes.len() as u64).sum();
    let mut included: Vec<&str> = entries.iter().map(|(path, _)| *path).collect();
    included.push("bundle.json");
    included.sort_unstable();
    let mut estimated = entry_bytes;
    for _ in 0..8 {
        let preview = json!({"scopeSHA256": scope, "includedEntries": included,
            "estimatedBytes": estimated, "deviceRawExcluded": true,
            "sensitiveDataWarning": SENSITIVE_DATA_WARNING});
        let manifest = canonical(&json!({"schemaVersion": "1.0.0", "generatedAt": generated,
            "preview": preview, "tool": tool(), "automaticUploadEnabled": false}));
        let total = entry_bytes + manifest.len() as u64;
        if total == estimated {
            if estimated > quota {
                return Err(fail(
                    "quotaExceeded",
                    "the support bundle exceeds its bounded export quota",
                ));
            }
            return Ok(Prepared {
                entries,
                preview,
                manifest,
            });
        }
        estimated = total;
    }
    Err(fail(
        "invalidInput",
        "the support-bundle destination is unsafe or invalid",
    ))
}

/// Swift `RuntimeSupportBundlePreview`.
fn presented(preview: &Value) -> Value {
    let mut presented = preview.as_object().cloned().unwrap_or_default();
    presented.insert(
        "schemaVersion".into(),
        json!("arkdeck.runtime-support-bundle-preview/1"),
    );
    Value::Object(presented)
}

/// The caller's `--destination`, as Swift's handler requires it: absolute
/// and already canonical.
fn destination(options: &Map<String, Value>) -> Result<String, CliError> {
    options
        .get("destinationPath")
        .and_then(Value::as_str)
        .filter(|path| path.starts_with('/') && standardized(path) == *path)
        .map(str::to_owned)
        .ok_or_else(|| {
            fail(
                "invalidInput",
                "runtime support-bundle requires a canonical absolute --destination",
            )
        })
}

#[cfg(target_os = "macos")]
fn service_error(failure: arkdeck_platform::BundleFailure) -> CliError {
    use arkdeck_platform::BundleFailure;
    match failure {
        BundleFailure::InvalidInput(_) => fail(
            "invalidInput",
            "the support-bundle destination is unsafe or invalid",
        ),
        BundleFailure::DestinationAlreadyExists => fail(
            "resourceConflict",
            "the support-bundle destination already exists",
        ),
        BundleFailure::OutcomeUnknown => fail(
            "outcomeUnknown",
            "support-bundle publication outcome is unknown; inspect the destination before retrying",
        ),
        BundleFailure::FileOperation { .. } | BundleFailure::InvalidRelativePath(_) => fail(
            "ioFailure",
            "the support bundle could not be read or written safely",
        ),
    }
}

/// `runtime support-bundle preview`: the scope the caller must approve;
/// nothing is written.
pub fn preview(options: &Map<String, Value>) -> Result<Value, CliError> {
    let destination = destination(options)?;
    #[cfg(target_os = "macos")]
    {
        let parent = arkdeck_platform::bundle_parent(&destination).map_err(service_error)?;
        let prepared = prepare(
            &destination,
            parent.device,
            parent.inode,
            MAXIMUM_BUNDLE_BYTES,
        )?;
        Ok(presented(&prepared.preview))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = destination;
        Err(unavailable())
    }
}

#[cfg(not(target_os = "macos"))]
fn unavailable() -> CliError {
    fail(
        "operationUnavailable",
        "the local support-bundle service is unavailable",
    )
}

/// `runtime support-bundle export`: the bundle published at the destination
/// when its scope is still the approved one.
pub fn export(options: &Map<String, Value>) -> Result<Value, CliError> {
    export_with(options, MAXIMUM_BUNDLE_BYTES, &|_| Ok(()))
}

/// `export` with Swift's quota and fault injector, for tests.
#[cfg(target_os = "macos")]
pub fn export_with(
    options: &Map<String, Value>,
    quota: u64,
    fault: &dyn Fn(
        arkdeck_platform::BundleFaultPoint,
    ) -> Result<(), arkdeck_platform::BundleFailure>,
) -> Result<Value, CliError> {
    let destination = destination(options)?;
    let approved = options
        .get("previewDigest")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            fail(
                "invalidInput",
                "runtime support-bundle export requires --preview-digest",
            )
        })?;
    let parent = arkdeck_platform::bundle_parent(&destination).map_err(service_error)?;
    let current = prepare(&destination, parent.device, parent.inode, quota)?;
    if current.preview["scopeSHA256"] != approved {
        return Err(fail(
            "previewDrifted",
            "the support-bundle scope differs from the approved preview; preview it again",
        ));
    }
    // The writer's own pass: the destination and the scope again, then the
    // bundle solved against a manifest of this moment.
    let parent = arkdeck_platform::bundle_parent(&destination).map_err(service_error)?;
    let prepared = prepare(&destination, parent.device, parent.inode, quota)?;
    if prepared.preview != current.preview {
        return Err(fail(
            "previewDrifted",
            "the support-bundle scope differs from the approved preview; preview it again",
        ));
    }
    let uuid = crate::job_plan::uuid()?.to_uppercase();
    let mut entries: Vec<(&str, &[u8])> = prepared
        .entries
        .iter()
        .map(|(path, bytes)| (*path, bytes.as_slice()))
        .collect();
    entries.push(("bundle.json", &prepared.manifest));
    arkdeck_platform::publish_bundle(&destination, parent, &entries, &uuid, fault)
        .map_err(service_error)?;
    Ok(
        json!({"schemaVersion": "arkdeck.runtime-support-bundle-export/1", "status": "exported",
        "destination": standardized(&destination), "scopeSHA256": prepared.preview["scopeSHA256"],
        "exportedBytes": prepared.preview["estimatedBytes"], "deviceRawExcluded": true}),
    )
}

#[cfg(not(target_os = "macos"))]
pub fn export_with(
    options: &Map<String, Value>,
    _quota: u64,
    _fault: &dyn Fn(()) -> Result<(), ()>,
) -> Result<Value, CliError> {
    destination(options)?;
    Err(unavailable())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_is_standardized_as_foundation_standardizes_a_file_url() {
        for (path, standard) in [
            ("/tmp/x/support", "/tmp/x/support"),
            ("/tmp/x/support/", "/tmp/x/support"),
            ("/tmp/x/./support", "/tmp/x/support"),
            ("/tmp/x/y/../support", "/tmp/x/support"),
            // `/private` stays where what remains does not exist.
            (
                "/private/tmp/arkdeck-absent-2c1f/x",
                "/private/tmp/arkdeck-absent-2c1f/x",
            ),
            ("/private/other/x", "/private/other/x"),
            // And goes where it does.
            ("/private/tmp", "/tmp"),
            ("//tmp//x", "/tmp/x"),
            ("/", "/"),
        ] {
            assert_eq!(standardized(path), standard, "{path}");
        }
    }
}
