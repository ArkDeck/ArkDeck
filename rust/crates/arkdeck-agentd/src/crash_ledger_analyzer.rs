//! `arkdeck-agentd --analyze-crash-ledger <absolute path>`: Swift's one-shot
//! crash-ledger analyzer mode (`ArkDeckAgentDaemonMain`), the executable an
//! installed service names as `ARKDECK_ANALYZER_PATH`. The Runtime runs it as
//! the analyzer child of `analyzer.extract-crash-signature@1` — the pinned
//! executable, no environment, the source Artifact's `/.vol` alias as the one
//! path — and publishes what it prints as the derived `crash-signature.json`,
//! with the source's identity beside it.
//!
//! It is answered before anything a daemon does: no environment is read, no
//! store opened, no socket bound and no device reached. It reads the one file
//! it is named and writes the canonical analysis to stdout
//! (`arkdeck_hoststore::analyze_crash_ledger`), exit 0, whatever the file
//! holds: bytes that are no listing are an `unreadable` analysis. Anything
//! else is Swift's: a usage refusal is its line and exit 64, before anything
//! is read; a file that cannot be read is exit 1 and a line naming the error.
//! That line never carries the path or the bytes, where Swift's Foundation
//! error text names the path.
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::AsFd;

pub(crate) const FLAG: &str = "--analyze-crash-ledger";
const USAGE: &str = "--analyze-crash-ledger requires one absolute artifact path\n";
const FAILED: &str = "crash-ledger analysis failed: ";

/// `arguments` are the daemon's after its own name; the first is `FLAG`.
pub(crate) fn run(arguments: &[OsString]) -> i32 {
    let values = arguments.get(1..).unwrap_or_default();
    let Some(path) = arkdeck_hoststore::crash_ledger_source(values) else {
        let _ = io::stderr().write_all(USAGE.as_bytes());
        return 64;
    };
    let answered = std::fs::read(&path)
        .and_then(|bytes| arkdeck_hoststore::analyze_crash_ledger(&bytes))
        .and_then(|document| {
            // Delivered, or the mode fails: written through its own handle on
            // stdout, where the standard library's would take a stdout that
            // is not open for writing as a stream to discard.
            File::from(io::stdout().as_fd().try_clone_to_owned()?).write_all(&document)
        });
    match answered {
        Ok(()) => 0,
        Err(error) => {
            let _ = io::stderr().write_all(format!("{FAILED}{error}\n").as_bytes());
            1
        }
    }
}
