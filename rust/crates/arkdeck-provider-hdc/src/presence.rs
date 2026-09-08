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
            let mut mac = Hmac::<Sha256>::new_from_slice(session_pseudonym_key)
                .expect("HMAC-SHA-256 accepts a 32-byte key");
            mac.update(columns[0].as_bytes());
            let digest = mac.finalize().into_bytes();
            let mut identifier = String::from("redacted-device-");
            for byte in &digest[..12] {
                use std::fmt::Write;
                write!(identifier, "{byte:02x}").expect("formatting into String cannot fail");
            }
            connected.push(identifier);
        }
    }
    if connected.is_empty() {
        Ok(PresenceSnapshot::ObservedEmpty)
    } else {
        connected.sort();
        Ok(PresenceSnapshot::ObservedConnectedSet(connected))
    }
}
