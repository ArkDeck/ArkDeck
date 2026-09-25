//! `arkdeck-agentd --summarize-hilog <absolute path>`: Swift's closed,
//! host-only HiLog analyzer mode (`ArkDeckAgentDaemonMain`). The Runtime runs
//! it as the analyzer child of `analyzer.summarize-hilog@1` — its own daemon
//! executable, pinned, with no environment and the source Artifact's `/.vol`
//! alias as the one path — and publishes what it prints, beside the source's
//! identity, as the derived `hilog-summary.json`.
//!
//! It is answered before anything a daemon does: no environment is read, no
//! store opened, no socket bound and no device reached. The one file it is
//! named is read as Swift's bounded reader reads it (`read_profile_file`: a
//! regular file through its physical path or its inode alias, no link
//! followed, unchanged while it is read, at most 512 MiB), and the canonical
//! summary is written to stdout, exit 0. Anything else is one of Swift's two
//! fixed lines, which never name the path or the bytes: a usage refusal and
//! exit 64 before anything is read, or a failure and exit 1.
use arkdeck_hoststore::{AnalyzerProfile, AnalyzerProfiles};
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::AsFd;
use std::path::Path;

pub(crate) const FLAG: &str = "--summarize-hilog";
const INVALID_ARGUMENTS: &str = "analyzer.hilogInvalidArguments\n";
const READ_FAILED: &str = "analyzer.hilogReadFailed\n";

/// `arguments` are the daemon's after its own name; the first is `FLAG`.
pub(crate) fn run(arguments: &[OsString]) -> i32 {
    let values = arguments.get(1..).unwrap_or_default();
    let Some(path) = arkdeck_hoststore::hilog_source(values) else {
        let _ = io::stderr().write_all(INVALID_ARGUMENTS.as_bytes());
        return 64;
    };
    let answered = arkdeck_hoststore::profile_path(&path, true)
        .and_then(|path| {
            arkdeck_platform::read_profile_file(&path, arkdeck_hoststore::HILOG_MAXIMUM_INPUT_BYTES)
        })
        .ok()
        .and_then(|snapshot| arkdeck_hoststore::analyze_hilog(&snapshot.bytes).ok())
        .and_then(|document| {
            // Delivered, or the mode fails: written through its own handle on
            // stdout, where the standard library's would take a stdout that
            // is not open for writing as a stream to discard.
            File::from(io::stdout().as_fd().try_clone_to_owned().ok()?)
                .write_all(&document)
                .ok()
        });
    match answered {
        Some(()) => 0,
        None => {
            let _ = io::stderr().write_all(READ_FAILED.as_bytes());
            1
        }
    }
}

/// Swift's daemon composition of its analyzers from `ARKDECK_ANALYZER_PATH`:
/// none unless a host names one, and a named path that is not an executable
/// fails startup. The named executable is the crash-ledger analyzer, and the
/// HiLog summary too when it is this daemon's own executable, hashed as
/// Swift's `FixedExecutableResolver` hashes `Bundle.main.executableURL`;
/// otherwise the HiLog summary is unavailable by name.
///
/// Without `ARKDECK_ARKTRACE_DESCRIPTOR` (`arktrace_descriptor` false), the
/// two ArkTrace analyzers are unavailable as Swift names them,
/// `analyzer.arktraceNotFound`. A named descriptor is not loaded here yet:
/// its analyzers stay without a profile and their operations without an
/// executor, and the production start names the variable as unread.
pub(crate) fn composed(
    path: Option<&Path>,
    arktrace_descriptor: bool,
) -> io::Result<Option<AnalyzerProfiles>> {
    let profiles = match path {
        None => AnalyzerProfiles::default(),
        Some(path) => {
            let analyzer = AnalyzerProfile::crash_signature(path)?;
            let own = std::env::current_exe()
                .ok()
                .and_then(|own| AnalyzerProfile::hilog_summary(&own).ok())
                .map(|own| own.executable_sha256);
            AnalyzerProfiles::for_daemon_analyzer(analyzer, own.as_deref())
        }
    };
    Ok(Some(if arktrace_descriptor {
        profiles
    } else {
        profiles.without_arktrace()
    }))
}
