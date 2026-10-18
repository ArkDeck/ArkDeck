//! Windows ArkTrace loading and invocation. The reviewed descriptor selects one
//! signed versioned directory. A private captured generation serves both trace
//! analyzers, with every resource held against changes while a child runs.
use crate::arktrace_doctor_envelope::{DoctorEnvelopeContract, valid_envelope};
use crate::arktrace_pins::{
    ANALYSIS_REF, ArkTraceProfileError, PinnedFile, PinnedTree, SUMMARY_REF,
};
use crate::arktrace_windows_manifest::{self as wire, Descriptor, FilePin, Manifest};
use crate::job_plan::AnalyzerProfile;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{
    BootstrapBundleCapture, BootstrapBundlePublication, BootstrapTree, HostDirectory,
    ToolExecution, ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedSource,
    VerifiedTool, WindowsCodeNamespace, inspect_bootstrap_tree, read_host_file,
    validate_windows_private_file, verify_windows_publisher,
};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

type Refusal = ArkTraceProfileError;
fn drift(_: impl std::fmt::Debug) -> Refusal {
    Refusal::ManifestDrift
}

fn plain(path: &Path) -> Result<PathBuf, Refusal> {
    // Resolve no links or aliases: the native namespace checker compares the
    // supplied spelling with each actual directory handle.
    let text = path.to_str().ok_or(Refusal::DescriptorInvalid)?;
    if !path.is_absolute() || text.starts_with(r"\\") || text.contains('/') {
        return Err(Refusal::DescriptorInvalid);
    }
    Ok(path.to_owned())
}

fn records(tree: &BootstrapTree) -> Result<Vec<FilePin>, Refusal> {
    let directories = wire::directories()?;
    let mut folded = BTreeSet::new();
    let mut files = Vec::new();
    for entry in tree.entries.iter().skip(1) {
        if !wire::safe_relative(&entry.path) || !folded.insert(entry.path.to_ascii_lowercase()) {
            return Err(Refusal::ContractMismatch);
        }
        if entry.directory {
            if !directories.contains(&entry.path) {
                return Err(Refusal::ContractMismatch);
            }
        } else if entry.path != wire::MANIFEST {
            if entry.byte_count == 0 || entry.byte_count > 512 * 1024 * 1024 {
                return Err(Refusal::ContractMismatch);
            }
            files.push(FilePin {
                path: entry.path.clone(),
                byte_count: entry.byte_count,
                sha256: entry.sha256.clone().ok_or(Refusal::ManifestDrift)?,
            });
        }
    }
    if files.len() > 256 {
        return Err(Refusal::ContractMismatch);
    }
    Ok(files)
}

/// Only a native PE32+ x64 executable, not an architecture claim in JSON.
fn native_image(tree: &BootstrapTree, root: &Path, relative: &str) -> Result<(), Refusal> {
    if !tree
        .entries
        .iter()
        .any(|entry| entry.path == relative && !entry.directory && entry.executable)
    {
        return Err(Refusal::ToolDrift);
    }
    let mut file = tree.open_relative_file(root, relative).map_err(drift)?;
    let mut header = [0_u8; 64];
    file.read_exact(&mut header).map_err(drift)?;
    if &header[..2] != b"MZ" {
        return Err(Refusal::ToolDrift);
    }
    let offset = u32::from_le_bytes(header[60..64].try_into().map_err(drift)?) as u64;
    if !(64..=1_048_576).contains(&offset) {
        return Err(Refusal::ToolDrift);
    }
    file.seek(SeekFrom::Start(offset)).map_err(drift)?;
    let mut pe = [0_u8; 26];
    file.read_exact(&mut pe).map_err(drift)?;
    if &pe[..6] != b"PE\0\0\x64\x86"
        || &pe[24..26] != b"\x0b\x02"
        || u16::from_le_bytes([pe[22], pe[23]]) & 0x2002 != 0x0002
    {
        return Err(Refusal::ToolDrift);
    }
    Ok(())
}

fn read_tree_file(tree: &BootstrapTree, root: &Path, relative: &str) -> Result<Vec<u8>, Refusal> {
    let mut bytes = Vec::new();
    tree.open_relative_file(root, relative)
        .map_err(drift)?
        .take(65_537)
        .read_to_end(&mut bytes)
        .map_err(drift)?;
    if bytes.len() > 65_536 {
        return Err(Refusal::ContractMismatch);
    }
    Ok(bytes)
}

/// A closed tree and each of its files pinned with no-write/no-delete sharing.
/// Held directory barriers prevent ancestor replacement through the run.
struct BoundDistribution {
    _namespace: WindowsCodeNamespace,
    _files: Vec<VerifiedSource>,
    manifest: Manifest,
    manifest_bytes: Vec<u8>,
}

impl BoundDistribution {
    fn open(root: &Path, expected_manifest: Option<&str>, private: bool) -> Result<Self, Refusal> {
        let namespace = WindowsCodeNamespace::open(root, private).map_err(drift)?;
        let before = inspect_bootstrap_tree(root).map_err(drift)?;
        let manifest_bytes = read_tree_file(&before, root, wire::MANIFEST)?;
        if expected_manifest.is_some_and(|expected| sha256_hex(&manifest_bytes) != expected) {
            return Err(Refusal::ManifestDrift);
        }
        let manifest = Manifest::read(&manifest_bytes)?;
        if !manifest.matches_files(&records(&before)?) {
            return Err(Refusal::ManifestDrift);
        }
        let mut files = Vec::new();
        for entry in before.entries.iter().filter(|entry| !entry.directory) {
            let expected = entry.sha256.as_deref().ok_or(Refusal::ManifestDrift)?;
            files.push(
                VerifiedSource::open(
                    &root.join(entry.path.replace('/', "\\")),
                    expected,
                    entry.byte_count,
                )
                .map_err(drift)?,
            );
        }
        manifest.validate_contents(|relative| read_tree_file(&before, root, relative))?;
        for executable in wire::EXECUTABLES {
            native_image(&before, root, executable)?;
            verify_windows_publisher(
                &root.join(executable.replace('/', "\\")),
                manifest.publisher(),
                manifest.timestamped(),
            )
            .map_err(|_| Refusal::ToolDrift)?;
        }
        namespace.revalidate().map_err(drift)?;
        if inspect_bootstrap_tree(root).map_err(drift)? != before {
            return Err(Refusal::ManifestDrift);
        }
        Ok(Self {
            _namespace: namespace,
            _files: files,
            manifest,
            manifest_bytes,
        })
    }
}

/// The Windows invocation storage is a sibling of the private snapshot store,
/// owned by this Runtime. It never opens the standalone ArkTrace cache.
fn invocation_storage(root: &Path) -> Result<PathBuf, Refusal> {
    let state = root
        .parent()
        .and_then(Path::parent)
        .ok_or(Refusal::DescriptorInvalid)?;
    Ok(state.join("arktrace-invocation-storage"))
}

/// Capture and doctor-probe one operator-reviewed Windows CLI distribution.
/// Errors become the established ArkTrace unavailable reasons; none grants
/// permission to try an unreviewed executable or a development-pinned package.
pub struct WindowsArkTraceProfileLoader<'a> {
    pub state: &'a Path,
}

impl WindowsArkTraceProfileLoader<'_> {
    pub fn load_profiles(&self, descriptor_path: &Path) -> Result<Vec<AnalyzerProfile>, Refusal> {
        let descriptor_path = plain(descriptor_path)?;
        let _descriptor_namespace =
            validate_windows_private_file(&descriptor_path).map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Refusal::NotFound
                } else {
                    Refusal::DescriptorInvalid
                }
            })?;
        let descriptor_bytes =
            read_host_file(&descriptor_path, 16 * 1024).map_err(|_| Refusal::DescriptorInvalid)?;
        let _descriptor = VerifiedSource::open(
            &descriptor_path,
            &sha256_hex(&descriptor_bytes),
            descriptor_bytes.len() as u64,
        )
        .map_err(|_| Refusal::DescriptorInvalid)?;
        let descriptor = Descriptor::read(&descriptor_bytes)?;
        let source = plain(Path::new(&descriptor.distribution_root))?;
        let _source_distribution =
            BoundDistribution::open(&source, Some(&descriptor.manifest_sha256), false)?;
        let state = plain(self.state)?;
        let _state = WindowsCodeNamespace::open(&state, true).map_err(drift)?;
        let state_directory = HostDirectory::open(&state).map_err(drift)?;
        let snapshots = state_directory
            .private_child("arktrace-profile-snapshots")
            .map_err(drift)?;
        let snapshot_root = state.join("arktrace-profile-snapshots");
        snapshots.validate_path(&snapshot_root).map_err(drift)?;
        let mut capture =
            BootstrapBundleCapture::capture(&snapshot_root, &source).map_err(drift)?;
        capture.revalidate_sources().map_err(drift)?;
        // The manifest digest already includes the complete tree identity.
        // One full digest retains exact versioning without duplicating 65 path
        // characters, which can exceed native trust-provider caller limits.
        let name = format!("arktrace-{}", descriptor.manifest_sha256);
        let generation = match capture.publish_as(&name).map_err(drift)? {
            BootstrapBundlePublication::Published(path)
            | BootstrapBundlePublication::AlreadyExists(path) => path,
        };
        // The capture owns a DELETE-capable staging handle until dropped.
        // Close it after exclusive publication, before holding the published
        // namespace without delete sharing. No staged code has executed.
        drop(capture);
        let bound = BoundDistribution::open(&generation, Some(&descriptor.manifest_sha256), true)?;
        let storage = invocation_storage(&generation)?;
        state_directory
            .private_child("arktrace-invocation-storage")
            .map_err(drift)?;
        let _storage = WindowsCodeNamespace::open(&storage, true).map_err(drift)?;
        let executable_path = generation.join(wire::EXECUTABLES[0]);
        let tool_sha256 = bound.manifest.tool_sha256().to_owned();
        let pinned_files = profile_pins(&bound, &generation);
        let summary = AnalyzerProfile {
            analyzer_ref: SUMMARY_REF.into(),
            analyzer_version: "0.1.0+1".into(),
            executable_path,
            executable_sha256: tool_sha256,
            fixed_arguments: [
                "summary",
                "--json",
                "--no-cache",
                "--timeout-ms",
                "30000",
                "--max-rows",
                "1000",
                "--max-events",
                "10000",
                "--max-output-bytes",
                "8388608",
            ]
            .map(str::to_owned)
            .to_vec(),
            timeout_seconds: 30,
            output_byte_budget: 8 * 1024 * 1024,
            canonical_namespace_root: Some(generation.to_string_lossy().into_owned()),
            pinned_files,
            pinned_trees: vec![PinnedTree {
                path: generation.to_string_lossy().into_owned(),
                sha256: bound.manifest.tree_sha256().into(),
            }],
            arktrace_summary: Some(bound.manifest.contract()),
            arktrace_analysis: None,
        };
        let doctor_arguments: Vec<_> = [
            "doctor",
            "--self-test",
            "--json",
            "--no-cache",
            "--timeout-ms",
            "120000",
            "--max-output-bytes",
            "262144",
        ]
        .map(OsString::from)
        .to_vec();
        let execution = run_profile(
            &summary,
            &doctor_arguments,
            Duration::from_secs(125),
            256 * 1024,
            &|| false,
        )
        .map_err(|_| Refusal::SelfTestFailed)?;
        let doctor = DoctorEnvelopeContract {
            executable_sha256: summary.executable_sha256.clone(),
            product_version: "0.1.0".into(),
            timeout_seconds: 120,
            output_byte_budget: 256 * 1024,
        };
        if execution.termination != ToolTermination::Exited(0)
            || execution.truncated
            || !execution.stderr.is_empty()
            || !valid_envelope(&execution.stdout, &doctor)
        {
            return Err(Refusal::SelfTestFailed);
        }
        let analysis = AnalyzerProfile {
            analyzer_ref: ANALYSIS_REF.into(),
            fixed_arguments: Vec::new(),
            timeout_seconds: 120,
            output_byte_budget: 64 * 1024 * 1024,
            arktrace_summary: None,
            arktrace_analysis: summary.arktrace_summary.clone(),
            ..summary.clone()
        };
        Ok(vec![summary, analysis])
    }
}

pub(crate) fn pins_match(profile: &AnalyzerProfile) -> bool {
    let Some(root) = profile.canonical_namespace_root.as_deref().map(Path::new) else {
        return profile.arktrace_summary.is_none()
            && profile.arktrace_analysis.is_none()
            && !matches!(profile.analyzer_ref.as_str(), SUMMARY_REF | ANALYSIS_REF)
            && profile.pinned_files.is_empty()
            && profile.pinned_trees.is_empty();
    };
    let Ok(bound) = BoundDistribution::open(root, None, true) else {
        return false;
    };
    pins_match_bound(profile, &bound, root)
}

fn profile_pins(bound: &BoundDistribution, root: &Path) -> Vec<PinnedFile> {
    let mut pins: Vec<_> = bound
        .manifest
        .files()
        .iter()
        .map(|pin| PinnedFile {
            path: root
                .join(pin.path.replace('/', "\\"))
                .to_string_lossy()
                .into_owned(),
            sha256: pin.sha256.clone(),
            byte_count: pin.byte_count,
            require_executable: wire::EXECUTABLES.contains(&pin.path.as_str()),
        })
        .collect();
    pins.push(PinnedFile {
        path: root.join(wire::MANIFEST).to_string_lossy().into_owned(),
        sha256: sha256_hex(&bound.manifest_bytes),
        byte_count: bound.manifest_bytes.len() as u64,
        require_executable: false,
    });
    pins.sort_by(|a, b| a.path.as_bytes().cmp(b.path.as_bytes()));
    pins
}

fn pins_match_bound(profile: &AnalyzerProfile, bound: &BoundDistribution, root: &Path) -> bool {
    let contract = bound.manifest.contract();
    profile.pinned_trees
        == [PinnedTree {
            path: root.to_string_lossy().into_owned(),
            sha256: bound.manifest.tree_sha256().into(),
        }]
        && profile.pinned_files == profile_pins(bound, root)
        && profile.executable_sha256 == bound.manifest.tool_sha256()
        && profile.executable_path == root.join(wire::EXECUTABLES[0])
        && match profile.analyzer_ref.as_str() {
            SUMMARY_REF => {
                profile.arktrace_summary.as_ref() == Some(&contract)
                    && profile.arktrace_analysis.is_none()
            }
            ANALYSIS_REF => {
                profile.arktrace_analysis.as_ref() == Some(&contract)
                    && profile.arktrace_summary.is_none()
            }
            _ => false,
        }
}

/// Called with the Artifact source held for its entire lifetime. The established
/// Windows verified-tool runner supplies NUL stdin, minimal environment,
/// suspended launch identity proof, cancellation and Job Object tree cleanup.
pub(crate) fn run_profile(
    profile: &AnalyzerProfile,
    arguments: &[OsString],
    timeout: Duration,
    capture_bytes: usize,
    cancelled: &dyn Fn() -> bool,
) -> Result<ToolExecution, ToolRunError> {
    let refused = || ToolRunError::Refused(io::Error::other("analyzer process identity refused"));
    let root = profile
        .canonical_namespace_root
        .as_deref()
        .map(Path::new)
        .ok_or_else(refused)?;
    let bound = BoundDistribution::open(root, None, true).map_err(|_| refused())?;
    if !pins_match_bound(profile, &bound, root) {
        return Err(refused());
    }
    let storage = invocation_storage(root).map_err(|_| refused())?;
    let _storage = WindowsCodeNamespace::open(&storage, true).map_err(|_| refused())?;
    let environment = [(
        OsString::from("ARKTRACE_STORAGE_ROOT"),
        storage.into_os_string(),
    )];
    let tool = VerifiedTool::open(&profile.executable_path, &profile.executable_sha256)
        .map_err(|_| refused())?;
    tool.run_tool(
        &ToolRequest {
            arguments,
            environment: &environment,
            working_directory: None,
            limits: ToolLimits {
                timeout,
                capture_bytes,
            },
        },
        cancelled,
    )
}

pub(crate) fn reviewed_revision(profile: &AnalyzerProfile) -> Result<String, Refusal> {
    let root = profile
        .canonical_namespace_root
        .as_deref()
        .map(Path::new)
        .ok_or(Refusal::DescriptorInvalid)?;
    let bound = BoundDistribution::open(root, None, true)?;
    if !pins_match_bound(profile, &bound, root) {
        return Err(Refusal::ManifestDrift);
    }
    Ok(bound.manifest.source_revision().to_owned())
}

#[cfg(test)]
#[path = "arktrace_windows_tests.rs"]
mod tests;
