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
use arkdeck_hoststore::{
    AnalyzerProfile, AnalyzerProfiles, ArkTraceProfileLoader, ProductionDistributionTrust,
    ProductionDoctorProbe,
};
use std::ffi::{OsStr, OsString};
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
/// Then the two ArkTrace analyzers from `ARKDECK_ARKTRACE_DESCRIPTOR`
/// (`arktrace_descriptor`), as Swift's `ArkTraceSummaryAnalyzerProfileLoader`
/// loads it in `state`: the production trust checker, the doctor's private
/// home `arktrace-availability-home` and the snapshot generations of
/// `arktrace-profile-snapshots`. A descriptor that loads composes both
/// profiles; one that does not leaves both unavailable for the loader's
/// reason, and no descriptor for `analyzer.arktraceNotFound`. The load runs
/// the reviewed CLI's own self-test, so a named descriptor spawns a child.
pub(crate) fn composed(
    path: Option<&Path>,
    arktrace_descriptor: Option<&OsStr>,
    state: &Path,
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
    let Some(descriptor) = arktrace_descriptor else {
        return Ok(Some(profiles.without_arktrace()));
    };
    let descriptor = file_url_path(
        &descriptor.to_string_lossy(),
        &std::env::current_dir()?.to_string_lossy(),
        arkdeck_platform::runtime_home().as_deref(),
    );
    let doctor = ProductionDoctorProbe::new(&state.join("arktrace-availability-home"));
    let loader = ArkTraceProfileLoader {
        doctor: &doctor,
        trust: &ProductionDistributionTrust,
        snapshot_root: Some(
            state
                .join("arktrace-profile-snapshots")
                .to_string_lossy()
                .into_owned(),
        ),
        hooks: None,
    };
    Ok(Some(match loader.load_profiles(&descriptor) {
        Ok(loaded) => profiles.with_arktrace(loaded),
        Err(error) => profiles.with_arktrace_unavailable(error.reason()),
    }))
}

/// Swift `URL(filePath:).path` of a daemon setting: `~/` names the home
/// directory `NSHomeDirectory()` reports, a relative path is resolved against
/// the current directory with its `.` and `..` segments removed, and no
/// trailing solidus is kept but the root's. A repeated solidus stays, as
/// Swift keeps it.
fn file_url_path(value: &str, current: &str, home: Option<&str>) -> String {
    let path = match (value.strip_prefix("~/"), home) {
        (Some(rest), Some(home)) => format!("{}/{rest}", home.trim_end_matches('/')),
        _ if value.starts_with('/') => value.to_owned(),
        _ => {
            let merged = format!("{}/{value}", current.trim_end_matches('/'));
            let mut kept: Vec<&str> = Vec::new();
            let segments: Vec<&str> = merged.split('/').skip(1).collect();
            for (index, segment) in segments.iter().enumerate() {
                let last = index + 1 == segments.len();
                match *segment {
                    "." => {}
                    ".." => {
                        kept.pop();
                    }
                    segment => kept.push(segment),
                }
                // A final dot segment leaves its directory.
                if last && matches!(*segment, "." | "..") {
                    kept.push("");
                }
            }
            format!("/{}", kept.join("/"))
        }
    };
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::file_url_path;

    /// What Swift's `URL(filePath:).path` answered for each setting, with
    /// the current directory `/private/tmp/cwd/sub` and the home
    /// `/Users/someone`.
    #[test]
    fn a_descriptor_setting_names_the_path_swift_s_url_names() {
        for (value, path) in [
            ("/a/b.json", "/a/b.json"),
            ("/a//b.json", "/a//b.json"),
            ("/a/b.json/", "/a/b.json"),
            ("/a/b.json//", "/a/b.json"),
            ("/a/./b.json", "/a/./b.json"),
            ("/a/../b.json", "/a/../b.json"),
            ("//x.json", "//x.json"),
            ("/", "/"),
            ("/~/x.json", "/~/x.json"),
            ("rel/x.json", "/private/tmp/cwd/sub/rel/x.json"),
            ("./x.json", "/private/tmp/cwd/sub/x.json"),
            ("a/./b.json", "/private/tmp/cwd/sub/a/b.json"),
            ("a/../b.json", "/private/tmp/cwd/sub/b.json"),
            ("../x.json", "/private/tmp/cwd/x.json"),
            ("a//b.json", "/private/tmp/cwd/sub/a//b.json"),
            ("a/b.json/", "/private/tmp/cwd/sub/a/b.json"),
            ("", "/private/tmp/cwd/sub"),
            (".", "/private/tmp/cwd/sub"),
            ("./", "/private/tmp/cwd/sub"),
            ("..", "/private/tmp/cwd"),
            ("~", "/private/tmp/cwd/sub/~"),
            ("~root/x.json", "/private/tmp/cwd/sub/~root/x.json"),
            ("a/~/x", "/private/tmp/cwd/sub/a/~/x"),
            ("~/x.json", "/Users/someone/x.json"),
            ("~/", "/Users/someone"),
        ] {
            assert_eq!(
                file_url_path(value, "/private/tmp/cwd/sub", Some("/Users/someone")),
                path,
                "{value}"
            );
        }
    }
}
