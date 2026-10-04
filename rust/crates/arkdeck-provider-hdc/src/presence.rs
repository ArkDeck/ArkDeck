use std::collections::HashSet;
use std::fmt;

use hmac::{Hmac, Mac};
use sha2::Sha256;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObservationTermination {
    Exited(i32),
    TimedOut,
    Cancelled,
    Signalled,
}

/// A parsing input contains no authority: passing fixture bytes never grants
/// permission to spawn a process or mint a Runtime observation reference.
pub struct ObservationInput<'a> {
    pub stdout: &'a [u8],
    pub stderr: &'a [u8],
    pub termination: ObservationTermination,
    pub stdout_truncated: bool,
}

impl<'a> ObservationInput<'a> {
    pub fn exited(stdout: &'a [u8], stderr: &'a [u8], exit_code: i32) -> Self {
        Self {
            stdout,
            stderr,
            termination: ObservationTermination::Exited(exit_code),
            stdout_truncated: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ObservationFailure {
    Unknown(&'static str),
    Unavailable(&'static str),
}

impl ObservationFailure {
    pub fn classification(&self) -> &'static str {
        match self {
            Self::Unknown(_) => "unknown",
            Self::Unavailable(_) => "unavailable",
        }
    }
}

impl fmt::Display for ObservationFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown(reason) | Self::Unavailable(reason) => f.write_str(reason),
        }
    }
}

impl std::error::Error for ObservationFailure {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PresenceSnapshot {
    ObservedEmpty,
    /// Sorted, per-session HMAC pseudonyms. Raw connect keys never leave this
    /// parser, and the result makes no cross-session identity claim.
    ObservedConnectedSet(Vec<String>),
}

/// The exact current `HDCDeviceObservationRawFamilyParser` grammar. Only the
/// registered CRLF marker is empty; a blank stdout is an unknown observation.
/// All-Offline rows also mean an empty connected set, because HDC retains rows
/// after departure. One malformed row invalidates the entire snapshot.
pub fn parse_registered_presence(
    execution: &ObservationInput<'_>,
    session_pseudonym_key: &[u8; 32],
) -> Result<PresenceSnapshot, ObservationFailure> {
    match execution.termination {
        ObservationTermination::TimedOut => {
            return Err(ObservationFailure::Unavailable(
                "device observation timed out",
            ));
        }
        ObservationTermination::Cancelled => {
            return Err(ObservationFailure::Unavailable(
                "device observation was cancelled",
            ));
        }
        _ => {}
    }
    if execution.termination != ObservationTermination::Exited(0)
        || !execution.stderr.is_empty()
        || execution.stdout_truncated
    {
        return Err(ObservationFailure::Unknown(
            "stderr was not empty, the exit was nonzero, or stdout truncated",
        ));
    }
    if execution.stdout.is_empty() {
        return Err(ObservationFailure::Unknown(
            "zero-byte stdout is outside the registered raw family",
        ));
    }
    if execution.stdout == b"[Empty]\r\n" {
        return Ok(PresenceSnapshot::ObservedEmpty);
    }
    let text = std::str::from_utf8(execution.stdout)
        .ok()
        .and_then(|text| text.strip_suffix('\n'))
        .ok_or(ObservationFailure::Unknown(
            "stdout is not a terminated UTF-8 row family",
        ))?;
    let mut keys = HashSet::new();
    let mut connected = Vec::new();
    for line in text.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.contains('\r') {
            return Err(ObservationFailure::Unknown(
                "residual carriage return inside a device row field",
            ));
        }
        let columns: Vec<_> = line.split('\t').collect();
        if columns.len() != 5 {
            return Err(ObservationFailure::Unknown(
                "device row column count is outside the registered family",
            ));
        }
        if columns[0].is_empty()
            || columns[2] != "USB"
            || !matches!(columns[3], "Connected" | "Offline")
            || columns[4] != "localhost"
        {
            return Err(ObservationFailure::Unknown(
                "device row literal is outside the registered closed sets",
            ));
        }
        if !keys.insert(columns[0]) {
            return Err(ObservationFailure::Unknown(
                "duplicate connect key rows are outside the registered family",
            ));
        }
        if columns[3] == "Connected" {
            connected.push(pseudonym(session_pseudonym_key, columns[0]));
        }
    }
    Ok(snapshot(connected))
}

/// The per-session pseudonym of a connect key: the raw key never leaves the
/// parser.
fn pseudonym(session_pseudonym_key: &[u8; 32], connect_key: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(session_pseudonym_key)
        .expect("HMAC-SHA-256 accepts a 32-byte key");
    mac.update(connect_key.as_bytes());
    let digest = mac.finalize().into_bytes();
    let mut identifier = String::from("redacted-device-");
    for byte in &digest[..12] {
        use std::fmt::Write;
        write!(identifier, "{byte:02x}").expect("formatting into String cannot fail");
    }
    identifier
}

fn snapshot(mut connected: Vec<String>) -> PresenceSnapshot {
    if connected.is_empty() {
        PresenceSnapshot::ObservedEmpty
    } else {
        connected.sort();
        PresenceSnapshot::ObservedConnectedSet(connected)
    }
}

/// The `deviceObservationSnapshot` grammar of the Windows registry
/// (`OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`, CHG-2026-078; maintainer ruling
/// 2026-10-04, item 2), as sampled from the registered `3.2.0g` tool:
///
/// - every row has six TAB columns, the sixth always `hdc`; LF or CR LF ends
///   a row, and no field may keep a CR;
/// - only `USB` rows are devices: `Connected` or `Offline`, hostTag
///   `localhost`; presence is the state column, and a removed device keeps
///   its row as `Offline`;
/// - a row of exactly the sampled UART form (`COM<digits>`, an empty name,
///   `UART`, `Ready`, `unknown...`, `hdc`) is a host serial port, not a
///   device, and is excluded, so a snapshot of only such rows is empty;
/// - the `[Empty]` marker and zero-byte stdout were never observed on
///   Windows and are `unknown`, as is any other form: another column count
///   or sixth column, any other UART row, an unknown literal, a duplicate
///   key, non-empty stderr, a non-zero exit or a truncated read. One such row
///   invalidates the whole snapshot.
///
/// It never applies to a macOS tool, and the macOS grammar
/// ([`parse_registered_presence`]) never applies to a Windows tool.
pub fn parse_registered_windows_presence(
    execution: &ObservationInput<'_>,
    session_pseudonym_key: &[u8; 32],
) -> Result<PresenceSnapshot, ObservationFailure> {
    match execution.termination {
        ObservationTermination::TimedOut => {
            return Err(ObservationFailure::Unavailable(
                "device observation timed out",
            ));
        }
        ObservationTermination::Cancelled => {
            return Err(ObservationFailure::Unavailable(
                "device observation was cancelled",
            ));
        }
        _ => {}
    }
    if execution.termination != ObservationTermination::Exited(0)
        || !execution.stderr.is_empty()
        || execution.stdout_truncated
    {
        return Err(ObservationFailure::Unknown(
            "stderr was not empty, the exit was nonzero, or stdout truncated",
        ));
    }
    let rows = windows_device_rows(execution.stdout).map_err(ObservationFailure::Unknown)?;
    Ok(snapshot(
        rows.iter()
            .filter(|row| row.state == "Connected")
            .map(|row| pseudonym(session_pseudonym_key, row.connect_key))
            .collect(),
    ))
}

/// One `USB` row of the registered Windows `list targets -v` family: a
/// device, `Connected` or `Offline`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WindowsDeviceRow<'a> {
    pub(crate) connect_key: &'a str,
    pub(crate) state: &'a str,
}

/// The device rows of a registered Windows `list targets -v` stdout
/// (CHG-2026-078, maintainer ruling 2026-10-04, item 2), or why the whole
/// output is outside the family. The excluded UART rows are not returned.
/// Shared by the presence feed ([`parse_registered_windows_presence`]) and
/// the candidate list (`parse_windows_target_list`), so the two can never
/// read the same bytes differently.
pub(crate) fn windows_device_rows(
    stdout: &[u8],
) -> Result<Vec<WindowsDeviceRow<'_>>, &'static str> {
    if stdout.is_empty() {
        return Err("zero-byte stdout is outside the registered Windows raw family");
    }
    let text = std::str::from_utf8(stdout)
        .ok()
        .and_then(|text| text.strip_suffix('\n'))
        .ok_or("stdout is not a terminated UTF-8 row family")?;
    let mut keys = HashSet::new();
    let mut rows = Vec::new();
    for line in text.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.contains('\r') {
            return Err("residual carriage return inside a device row field");
        }
        let columns: Vec<_> = line.split('\t').collect();
        if columns.len() != 6 || columns[5] != "hdc" {
            return Err("row is not the registered Windows six-column family");
        }
        if !keys.insert(columns[0]) {
            return Err("duplicate connect key rows are outside the registered family");
        }
        match columns[2] {
            "UART" => {
                let port = columns[0]
                    .strip_prefix("COM")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
                if !port
                    || !columns[1].is_empty()
                    || columns[3] != "Ready"
                    || columns[4] != "unknown..."
                {
                    return Err("UART row is outside the registered non-device form");
                }
            }
            "USB" => {
                if columns[0].is_empty()
                    || !matches!(columns[3], "Connected" | "Offline")
                    || columns[4] != "localhost"
                {
                    return Err("device row literal is outside the registered closed sets");
                }
                if columns[0].len() > 128
                    || !columns[0]
                        .chars()
                        .all(|c| c.is_ascii() && !c.is_whitespace())
                {
                    return Err("connect key length out of bounds");
                }
                rows.push(WindowsDeviceRow {
                    connect_key: columns[0],
                    state: columns[3],
                });
            }
            _ => return Err("row transport is outside the registered closed set"),
        }
    }
    Ok(rows)
}
