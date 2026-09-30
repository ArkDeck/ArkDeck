//! The Windows HDC tuples the Runtime composes an HDC for: the executables
//! `OPENHARMONY-HDC-WINDOWS-PROBES` registers (CHG-2026-078, TASK-WHR-002).
//!
//! A tuple is an executable's SHA-256 and the exact `hdc -v` bytes observed
//! with it, and the one loopback endpoint its server was observed listening
//! on. Nothing is inferred between two builds, or from a macOS tuple, even
//! when `-v` prints the same version text: a macOS hash never matches here,
//! and a Windows hash never matches the macOS tables.
//!
//! [`WINDOWS_HDC_TUPLES`] is empty until the maintainer's Windows samples are
//! processed and the registry is registered: then each registered candidate
//! becomes one entry here, copied from `windows-probes.yaml`, and the
//! Windows daemon composes an HDC for it with no other change. Until then
//! every Windows HDC is refused before anything is launched or dispatched.
use std::net::{Ipv4Addr, SocketAddrV4};

/// One registered Windows HDC tuple.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowsHdcTuple {
    /// The registry entry's candidate label (`c1`, `c2`), for the record.
    pub candidate: &'static str,
    /// The registered `hdc.exe` bytes' SHA-256, lowercase hex.
    pub executable_sha256: &'static str,
    /// The `Ver: X` text of `hdc -v`, as observed with that hash.
    pub reported_version: &'static str,
    /// The exact stdout bytes of `hdc -v`, terminator included.
    pub version_stdout: &'static [u8],
    /// The one loopback endpoint the registered server was observed on.
    pub endpoint: SocketAddrV4,
}

/// The registered Windows HDC tuples. None yet: CHG-2026-078 is a draft whose
/// every sample-derived value is `TBD(sample)`.
pub const WINDOWS_HDC_TUPLES: &[WindowsHdcTuple] = &[];

/// The registered tuple of `executable_sha256`, if the registry holds one.
pub fn windows_tuple(executable_sha256: &str) -> Option<&'static WindowsHdcTuple> {
    tuple_in(WINDOWS_HDC_TUPLES, executable_sha256)
}

/// The tuple of `executable_sha256` in `table`: an exact match of the
/// lowercase hex digest, never a prefix, a case fold or a version match.
pub fn tuple_in<'a>(
    table: &'a [WindowsHdcTuple],
    executable_sha256: &str,
) -> Option<&'a WindowsHdcTuple> {
    table
        .iter()
        .find(|tuple| tuple.executable_sha256 == executable_sha256)
}

/// Why a tuple is not one the Windows daemon may compose an HDC for; `None`
/// when it is well formed: a lowercase 64-hex digest that is not a macOS
/// tool's, a version, `-v` bytes spelling that version, and a loopback
/// endpoint with a port.
pub fn malformed(tuple: &WindowsHdcTuple) -> Option<&'static str> {
    let hex = tuple.executable_sha256.len() == 64
        && tuple
            .executable_sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if !hex {
        return Some("the executable SHA-256 is not 64 lowercase hex digits");
    }
    if crate::provider::registered_version("macos", tuple.executable_sha256).is_some() {
        return Some("a macOS tool's hash cannot register a Windows tuple");
    }
    if tuple.candidate.is_empty() || tuple.reported_version.is_empty() {
        return Some("the candidate and the reported version are required");
    }
    let spelled = format!("Ver: {}", tuple.reported_version);
    let stdout = std::str::from_utf8(tuple.version_stdout).unwrap_or("");
    if stdout.trim_end_matches(['\r', '\n']) != spelled
        || !(stdout.ends_with('\n') || stdout.ends_with("\r\n"))
    {
        return Some("the -v bytes do not spell the reported version with one terminator");
    }
    if *tuple.endpoint.ip() != Ipv4Addr::LOCALHOST || tuple.endpoint.port() == 0 {
        return Some("the endpoint is not a loopback address with a port");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: WindowsHdcTuple = WindowsHdcTuple {
        candidate: "c1",
        executable_sha256: "f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b",
        reported_version: "3.2.0x",
        version_stdout: b"Ver: 3.2.0x\r\n",
        endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
    };

    /// Every registered tuple is well formed and names one executable; this
    /// holds for any table TASK-WHR-002 registers.
    #[test]
    fn every_registered_tuple_is_well_formed_and_unique() {
        for tuple in WINDOWS_HDC_TUPLES {
            assert_eq!(malformed(tuple), None, "{tuple:?}");
            assert_eq!(
                WINDOWS_HDC_TUPLES
                    .iter()
                    .filter(|other| other.executable_sha256 == tuple.executable_sha256)
                    .count(),
                1
            );
        }
    }

    #[test]
    fn only_the_exact_digest_selects_a_tuple() {
        let table = [SAMPLE];
        assert_eq!(tuple_in(&table, SAMPLE.executable_sha256), Some(&SAMPLE));
        assert_eq!(
            tuple_in(&table, &SAMPLE.executable_sha256.to_uppercase()),
            None
        );
        assert_eq!(tuple_in(&table, &SAMPLE.executable_sha256[..63]), None);
        assert_eq!(tuple_in(&[], SAMPLE.executable_sha256), None);
        assert_eq!(malformed(&SAMPLE), None);
    }

    #[test]
    fn a_malformed_tuple_is_named() {
        let macos = WindowsHdcTuple {
            executable_sha256: "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83",
            ..SAMPLE
        };
        assert!(malformed(&macos).is_some());
        let upper = WindowsHdcTuple {
            executable_sha256: "F6D6C47551D976F33B0F22B17A74F345C0788E59131873AA5F75D356F5141D9B",
            ..SAMPLE
        };
        assert!(malformed(&upper).is_some());
        let wrong_version = WindowsHdcTuple {
            version_stdout: b"Ver: 3.2.0d\r\n",
            ..SAMPLE
        };
        assert!(malformed(&wrong_version).is_some());
        let no_terminator = WindowsHdcTuple {
            version_stdout: b"Ver: 3.2.0x",
            ..SAMPLE
        };
        assert!(malformed(&no_terminator).is_some());
        let wildcard = WindowsHdcTuple {
            endpoint: SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 8710),
            ..SAMPLE
        };
        assert!(malformed(&wildcard).is_some());
    }
}
