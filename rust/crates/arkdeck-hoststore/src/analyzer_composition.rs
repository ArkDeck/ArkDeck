//! Swift `AnalyzerProvider`'s composition: which analyzer each published
//! analyzer operation may name, which of them a host configured, and why an
//! analyzer it did not configure is unavailable. A Runtime admits an analyzer
//! Job only against the profile it would run it with; the plan, the
//! admission, the run and `operation.list` all read one composition.
use crate::job_plan::AnalyzerProfile;
use std::collections::BTreeMap;

pub(crate) const CRASH_SIGNATURE: &str = "analyzer.extract-crash-signature@1";
pub(crate) const HILOG_SUMMARY: &str = "analyzer.summarize-hilog@1";

/// The analyzer operations this Runtime plans, admits, runs, reconciles and
/// reads: each one's product is verified and published here.
pub(crate) const EXECUTED: [&str; 2] = [CRASH_SIGNATURE, HILOG_SUMMARY];

/// `AnalyzerProvider.analyzerForOperation`: the one analyzer an operation may
/// name. The mapping is the Runtime's; no request chooses another.
pub(crate) fn analyzer_for_operation(reference: &str) -> Option<&'static str> {
    match reference {
        CRASH_SIGNATURE => Some("crash-signature@1"),
        HILOG_SUMMARY => Some("hilog-summary@1"),
        "analyzer.summarize-trace@1" => Some("trace-summary@1"),
        "analyzer.analyze-trace@1" => Some("trace-analysis@1"),
        _ => None,
    }
}

/// The one step each analyzer operation declares in the Catalog.
pub(crate) fn step(reference: &str) -> Option<&'static str> {
    match reference {
        CRASH_SIGNATURE => Some("extract-crash-signature"),
        HILOG_SUMMARY => Some("summarize-hilog"),
        "analyzer.summarize-trace@1" => Some("summarize-trace"),
        "analyzer.analyze-trace@1" => Some("analyze-trace"),
        _ => None,
    }
}

/// `AnalyzerProvider.derivedArtifactName`.
pub(crate) fn derived_artifact_name(analyzer_ref: &str) -> &'static str {
    match analyzer_ref {
        "crash-signature@1" => "crash-signature.json",
        "hilog-summary@1" => "hilog-summary.json",
        "trace-summary@1" => "trace-summary.json",
        "trace-analysis@1" => "trace-analysis.json",
        _ => "analysis.json",
    }
}

/// The analyzers a host composed and the reasons it gave for those it did
/// not. A single profile composes exactly its own analyzer.
pub trait AnalyzerComposition: Sync {
    /// The profile the host configured for `analyzer_ref`.
    fn profile(&self, analyzer_ref: &str) -> Option<&AnalyzerProfile>;
    /// Why the host has no profile for `analyzer_ref`, when it said.
    fn unavailable_reason(&self, _analyzer_ref: &str) -> Option<&str> {
        None
    }
}

impl AnalyzerComposition for AnalyzerProfile {
    fn profile(&self, analyzer_ref: &str) -> Option<&AnalyzerProfile> {
        (self.analyzer_ref == analyzer_ref).then_some(self)
    }
}

/// Swift `AnalyzerProvider(profiles:unavailableReasons:)`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AnalyzerProfiles {
    profiles: Vec<AnalyzerProfile>,
    unavailable: BTreeMap<String, String>,
}

impl AnalyzerProfiles {
    pub fn new(profiles: Vec<AnalyzerProfile>, unavailable: BTreeMap<String, String>) -> Self {
        Self {
            profiles,
            unavailable,
        }
    }

    /// Swift's daemon composition from `ARKDECK_ANALYZER_PATH`: the
    /// crash-ledger analyzer that executable is, and the HiLog summary only
    /// when it is this daemon's own executable (Swift
    /// `HilogSummaryDerivedAnalyzer.profile`, which compares the two
    /// SHA-256s). Otherwise the HiLog summary is unavailable by that name.
    pub fn for_daemon_analyzer(analyzer: AnalyzerProfile, own_sha256: Option<&str>) -> Self {
        let mut unavailable = BTreeMap::new();
        let hilog = own_sha256
            .filter(|own| *own == analyzer.executable_sha256)
            .map(|_| AnalyzerProfile::hilog_summary_from(&analyzer));
        if hilog.is_none() {
            unavailable.insert(
                "hilog-summary@1".to_owned(),
                crate::hilog_summary::INCOMPATIBLE_EXECUTABLE.to_owned(),
            );
        }
        Self {
            profiles: std::iter::once(analyzer).chain(hilog).collect(),
            unavailable,
        }
    }

    pub fn profiles(&self) -> &[AnalyzerProfile] {
        &self.profiles
    }

    /// Swift's daemon composition of the two ArkTrace analyzers when no
    /// descriptor is named (`ARKDECK_ARKTRACE_DESCRIPTOR` unset): both
    /// unavailable as `analyzer.arktraceNotFound`.
    pub fn without_arktrace(mut self) -> Self {
        for analyzer_ref in [
            crate::arktrace_profile::SUMMARY_REF,
            crate::arktrace_profile::ANALYSIS_REF,
        ] {
            self.unavailable.insert(
                analyzer_ref.to_owned(),
                crate::arktrace_profile::ArkTraceProfileError::NotFound
                    .reason()
                    .to_owned(),
            );
        }
        self
    }
}

impl AnalyzerComposition for AnalyzerProfiles {
    fn profile(&self, analyzer_ref: &str) -> Option<&AnalyzerProfile> {
        self.profiles
            .iter()
            .find(|profile| profile.analyzer_ref == analyzer_ref)
    }

    fn unavailable_reason(&self, analyzer_ref: &str) -> Option<&str> {
        self.unavailable.get(analyzer_ref).map(String::as_str)
    }
}

/// Swift `AnalyzerProvider.runtimeAvailability` for an analyzer operation:
/// the profile a Job of it would run with, or the wire reason code and the
/// reason it is unavailable. An analyzer the host was not given is
/// `provider_tool_unavailable` with the host's reason, or Swift's
/// `analyzer.profileUnavailable`; a profile whose executable no longer holds
/// its pinned bytes is `tool_identity_drift`.
pub(crate) fn runtime_availability<'a>(
    composition: Option<&'a dyn AnalyzerComposition>,
    reference: &str,
) -> Result<&'a AnalyzerProfile, (&'static str, String)> {
    let Some(analyzer_ref) = analyzer_for_operation(reference) else {
        return Err((
            "operation_not_supported",
            "analyzer.unsupportedOperation".into(),
        ));
    };
    let Some(profile) = composition.and_then(|composition| composition.profile(analyzer_ref))
    else {
        let reason = composition
            .and_then(|composition| composition.unavailable_reason(analyzer_ref))
            .unwrap_or("analyzer.profileUnavailable");
        return Err(("provider_tool_unavailable", reason.to_owned()));
    };
    if !profile.still_matches() {
        return Err(("tool_identity_drift", "analyzer.toolIdentityDrift".into()));
    }
    if !profile.pins_still_match() {
        return Err((
            "tool_identity_drift",
            "analyzer.profileIdentityDrift".into(),
        ));
    }
    Ok(profile)
}

/// The reason the host gave for an analyzer operation's analyzer it has no
/// profile for — Swift's own answer for it, whatever this Runtime executes.
pub(crate) fn host_unavailable_reason(
    composition: Option<&dyn AnalyzerComposition>,
    reference: &str,
) -> Option<(&'static str, String)> {
    let analyzer_ref = analyzer_for_operation(reference)?;
    let composition = composition?;
    if composition.profile(analyzer_ref).is_some() {
        return None;
    }
    composition
        .unavailable_reason(analyzer_ref)
        .map(|reason| ("provider_tool_unavailable", reason.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operation_catalog::CatalogOperation;

    #[test]
    fn every_analyzer_operation_names_its_catalog_step_and_product() {
        for (id, analyzer_ref) in [
            ("analyzer.extract-crash-signature", "crash-signature@1"),
            ("analyzer.summarize-hilog", "hilog-summary@1"),
            ("analyzer.summarize-trace", "trace-summary@1"),
            ("analyzer.analyze-trace", "trace-analysis@1"),
        ] {
            let descriptor = CatalogOperation::lookup(id, Some(1)).unwrap();
            let reference = descriptor.reference();
            assert_eq!(analyzer_for_operation(&reference), Some(analyzer_ref));
            let [catalog_step] = descriptor.steps.as_slice() else {
                panic!("{reference}")
            };
            assert_eq!(step(&reference), Some(catalog_step.step_id.as_str()));
            assert_eq!(
                descriptor
                    .artifacts
                    .iter()
                    .map(|artifact| artifact.name.as_str())
                    .collect::<Vec<_>>(),
                [derived_artifact_name(analyzer_ref)]
            );
        }
    }

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn scratch() -> Scratch {
        let path = std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-analyzer-composition-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&path).unwrap();
        Scratch(path)
    }

    fn write(path: &std::path::Path, bytes: &[u8], mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path, bytes).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn without_arktrace_names_both_trace_analyzers_not_found() {
        let composition = AnalyzerProfiles::default().without_arktrace();
        for reference in ["analyzer.summarize-trace@1", "analyzer.analyze-trace@1"] {
            assert_eq!(
                host_unavailable_reason(Some(&composition), reference),
                Some((
                    "provider_tool_unavailable",
                    "analyzer.arktraceNotFound".to_owned()
                ))
            );
            assert_eq!(
                runtime_availability(Some(&composition), reference).err(),
                Some((
                    "provider_tool_unavailable",
                    "analyzer.arktraceNotFound".to_owned()
                ))
            );
        }
        // No reason for an analyzer the host said nothing about.
        assert_eq!(
            host_unavailable_reason(Some(&composition), CRASH_SIGNATURE),
            None
        );
        assert_eq!(
            host_unavailable_reason(
                Some(&AnalyzerProfiles::default()),
                "analyzer.summarize-trace@1"
            ),
            None
        );
        assert_eq!(
            host_unavailable_reason(None, "analyzer.summarize-trace@1"),
            None
        );
    }

    /// Swift `runtimeAvailability`: the executable, then every pinned file
    /// and tree, each measured again at every read.
    #[test]
    fn pinned_files_and_trees_drift_by_name() {
        let scratch = scratch();
        let root = &scratch.0;
        let analyzer = root.join("analyzer");
        write(&analyzer, b"#!/bin/sh\nexit 64\n", 0o755);
        let pinned = root.join("pinned.json");
        write(&pinned, b"{}\n", 0o644);
        let tree = root.join("tree");
        std::fs::create_dir(&tree).unwrap();
        write(&tree.join("leaf"), b"leaf\n", 0o644);
        let tree_path = tree.to_str().unwrap().to_owned();
        let tree_digest = arkdeck_platform::tree_snapshot(
            &crate::hilog_summary::profile_path(&tree_path, false).unwrap(),
            &tree_path,
        )
        .unwrap()
        .sha256;
        let mut profile = AnalyzerProfile::crash_signature(&analyzer).unwrap();
        profile.pinned_files = vec![crate::arktrace_profile::PinnedFile {
            path: pinned.to_str().unwrap().to_owned(),
            sha256: arkdeck_contract::sha256_hex(b"{}\n"),
            byte_count: 3,
            require_executable: false,
        }];
        profile.pinned_trees = vec![crate::arktrace_profile::PinnedTree {
            path: tree_path,
            sha256: tree_digest,
        }];
        let available = |profile: &AnalyzerProfile| {
            runtime_availability(Some(profile), CRASH_SIGNATURE)
                .map(|_| ())
                .map_err(|(code, reason)| format!("{code} {reason}"))
        };
        assert_eq!(available(&profile), Ok(()));
        write(&pinned, b"[]\n", 0o644);
        assert_eq!(
            available(&profile),
            Err("tool_identity_drift analyzer.profileIdentityDrift".into())
        );
        write(&pinned, b"{}\n", 0o644);
        write(&tree.join("leaf"), b"drift\n", 0o644);
        assert_eq!(
            available(&profile),
            Err("tool_identity_drift analyzer.profileIdentityDrift".into())
        );
        write(&tree.join("leaf"), b"leaf\n", 0o644);
        assert_eq!(available(&profile), Ok(()));
        write(&analyzer, b"#!/bin/sh\nexit 65\n", 0o755);
        assert_eq!(
            available(&profile),
            Err("tool_identity_drift analyzer.toolIdentityDrift".into())
        );
    }
}
