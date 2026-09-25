//! `arkdeck-agentd --symbolize-crash <absolute source map> <absolute dump>`:
//! Swift's one-shot ArkTS crash symbolization mode (`ArkDeckAgentDaemonMain`),
//! the executable an installed service names as `ARKDECK_ANALYZER_PATH`. A
//! registered symbol preset runs it as `workspace.symbolize-crash@1`'s child:
//! the preset's fixed `--symbolize-crash <map>` and the crash dump's path the
//! operation appends, which is why the map comes first.
//!
//! It is answered before anything a daemon does: no environment is read, no
//! store opened, no socket bound and no device reached. It reads the map and
//! then the dump, and writes the report (`arkdeck_hoststore::symbolize_crash`)
//! to stdout, exit 0. Anything else is Swift's: a usage refusal is its line
//! and exit 64, before anything is read; a file that cannot be read, or a map
//! that is not a JSON object, is exit 1 and a line naming the error. That line
//! never carries a path or the bytes, where Swift's Foundation error text
//! names the path.
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;

pub(crate) const FLAG: &str = "--symbolize-crash";
const USAGE: &str = "--symbolize-crash requires an absolute source map path and dump path\n";
const FAILED: &str = "crash symbolization failed: ";

/// `arguments` are the daemon's after its own name; the first is `FLAG`.
pub(crate) fn run(arguments: &[OsString]) -> i32 {
    let values = arguments.get(1..).unwrap_or_default();
    let [map, dump] = values else {
        let _ = io::stderr().write_all(USAGE.as_bytes());
        return 64;
    };
    if ![map, dump]
        .iter()
        .all(|path| path.as_bytes().starts_with(b"/"))
    {
        let _ = io::stderr().write_all(USAGE.as_bytes());
        return 64;
    }
    let read = std::fs::read(map)
        .and_then(|map| std::fs::read(dump).map(|dump| (map, dump)))
        .map_err(|error| error.to_string());
    let answered = read.and_then(|(map, dump)| {
        arkdeck_hoststore::symbolize_crash(&map, &dump).map_err(|error| error.swift())
    });
    let report = match answered {
        Ok(report) => report,
        Err(error) => {
            let _ = io::stderr().write_all(format!("{FAILED}{error}\n").as_bytes());
            return 1;
        }
    };
    // Delivered, or the mode fails: written through its own handle on stdout,
    // where the standard library's would take a stdout that is not open for
    // writing as a stream to discard.
    let delivered = io::stdout()
        .as_fd()
        .try_clone_to_owned()
        .and_then(|stdout| File::from(stdout).write_all(report.as_bytes()));
    match delivered {
        Ok(()) => 0,
        Err(error) => {
            let _ = io::stderr().write_all(format!("{FAILED}{error}\n").as_bytes());
            1
        }
    }
}
