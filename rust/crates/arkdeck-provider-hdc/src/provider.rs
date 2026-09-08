use std::ffi::OsString;
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::time::Duration;

use arkdeck_platform::{LoopbackServerLease, ProcessLimits, VerifiedTool};

use crate::{DeviceCandidate, ObservationFailure, ParseError, parse_target_list};

const ENDPOINT: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710);
const MAX_OUTPUT_BYTES: usize = 1_048_576;
const MAX_CANDIDATES: usize = 1_000;

/// A handle-bound HDC adapter with a closed read-only command vocabulary.
/// There is no caller-supplied argv, endpoint, shell, device command or
/// lifecycle action. The server must already exist at the registered endpoint.
pub struct HdcReadOnlyProvider {
    tool: VerifiedTool,
    version: &'static str,
}

impl HdcReadOnlyProvider {
    pub fn new(tool: VerifiedTool) -> Result<Self, ObservationFailure> {
        let version = registered_version(std::env::consts::OS, tool.sha256()).ok_or(
            ObservationFailure::Unavailable(
                "the selected platform and HDC executable have no published observation profile",
            ),
        )?;
        Ok(Self { tool, version })
    }

    pub fn tool_version(&self) -> &'static str {
        self.version
    }

    /// Observes once. An absent, ambiguous or changed server never produces a
    /// candidate snapshot. Probe errors do not trigger retry, cleanup or start.
    pub fn list_candidates(&self) -> Result<Vec<DeviceCandidate>, ObservationFailure> {
        observe_candidates(&PlatformBackend(&self.tool), self.version)
    }
}

/// These are facts published by Swift's current integration profiles, not a
/// version inferred from a filename or caller claim. Windows SPK-3 must provide
/// its own reviewed executable tuple; the macOS hashes cannot authorize it.
fn registered_version(platform: &str, digest: &str) -> Option<&'static str> {
    match (platform, digest) {
        ("macos", "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260") => {
            Some("3.2.0d")
        }
        ("macos", "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83") => {
            Some("3.2.0f")
        }
        _ => None,
    }
}

// A private seam tests dispatch ordering and exact lowering without exposing a
// production fixture backend or allowing a caller to synthesize a server lease.
trait ObservationBackend {
    type Lease;
    fn acquire_existing_server(&self) -> Result<Self::Lease, ObservationFailure>;
    fn execute(
        &self,
        args: &[OsString],
        env: &[(OsString, OsString)],
    ) -> Result<Capture, ObservationFailure>;
    fn revalidate(&self, lease: &Self::Lease) -> Result<(), ObservationFailure>;
}

#[derive(Clone)]
struct Capture {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    exit_code: Option<i32>,
}

struct PlatformBackend<'a>(&'a VerifiedTool);

impl ObservationBackend for PlatformBackend<'_> {
    type Lease = LoopbackServerLease;

    fn acquire_existing_server(&self) -> Result<Self::Lease, ObservationFailure> {
        LoopbackServerLease::acquire(self.0, ENDPOINT).map_err(|_| {
            ObservationFailure::Unavailable(
                "existing-server identity at the exact HDC endpoint could not be proved",
            )
        })
    }

    fn execute(
        &self,
        args: &[OsString],
        env: &[(OsString, OsString)],
    ) -> Result<Capture, ObservationFailure> {
        let output = self
            .0
            .run_read_only_with_environment(
                args,
                env,
                ProcessLimits {
                    timeout: Duration::from_secs(15),
                    max_output_bytes: MAX_OUTPUT_BYTES,
                },
            )
            .map_err(|error| match error.kind() {
                io::ErrorKind::TimedOut => {
                    ObservationFailure::Unavailable("device observation timed out")
                }
                io::ErrorKind::Interrupted => {
                    ObservationFailure::Unavailable("device observation was cancelled")
                }
                _ => ObservationFailure::Unknown(
                    "the bounded, identity-verified HDC observation did not complete",
                ),
            })?;
        Ok(Capture {
            stdout: output.stdout,
            stderr: output.stderr,
            exit_code: output.status.code(),
        })
    }

    fn revalidate(&self, lease: &Self::Lease) -> Result<(), ObservationFailure> {
        lease.revalidate().map_err(|_| {
            ObservationFailure::Unknown("HDC server identity changed across the observation")
        })
    }
}

fn observe_candidates(
    backend: &impl ObservationBackend,
    version: &str,
) -> Result<Vec<DeviceCandidate>, ObservationFailure> {
    let lease = backend.acquire_existing_server()?;
    let args = ["list", "targets", "-v"].map(OsString::from);
    let env = [(
        OsString::from("OHOS_HDC_SERVER_PORT"),
        OsString::from("8710"),
    )];
    let captured = backend.execute(&args, &env);
    // Check even when process execution failed. No interpretation of captured
    // bytes can turn an unproved server bracket into an observed-empty result.
    backend.revalidate(&lease)?;
    let captured = captured?;
    if captured.exit_code != Some(0) || !captured.stderr.is_empty() {
        return Err(ObservationFailure::Unknown(
            "HDC candidate enumeration had a nonzero exit or nonempty stderr",
        ));
    }
    let candidates =
        parse_target_list(&captured.stdout, version, false).map_err(|error| match error {
            ParseError::UnsupportedVersion(_) => {
                ObservationFailure::Unavailable("unregistered HDC observation version")
            }
            ParseError::InvalidEncoding => {
                ObservationFailure::Unknown("HDC observation is not valid UTF-8")
            }
            ParseError::Empty => ObservationFailure::Unknown("HDC observation output is empty"),
            ParseError::Truncated => {
                ObservationFailure::Unknown("HDC observation exceeded its byte budget")
            }
            ParseError::Malformed(reason) => ObservationFailure::Unknown(reason),
        })?;
    if candidates.len() > MAX_CANDIDATES {
        return Err(ObservationFailure::Unknown(
            "HDC candidate snapshot exceeds its row limit",
        ));
    }
    Ok(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeBackend {
        before: Result<(), ObservationFailure>,
        after: Result<(), ObservationFailure>,
        output: Result<Capture, ObservationFailure>,
        calls: RefCell<Vec<&'static str>>,
    }

    impl FakeBackend {
        fn stdout(bytes: &[u8]) -> Self {
            Self {
                before: Ok(()),
                after: Ok(()),
                output: Ok(Capture {
                    stdout: bytes.to_vec(),
                    stderr: Vec::new(),
                    exit_code: Some(0),
                }),
                calls: RefCell::new(Vec::new()),
            }
        }
    }

    impl ObservationBackend for FakeBackend {
        type Lease = ();

        fn acquire_existing_server(&self) -> Result<(), ObservationFailure> {
            self.calls.borrow_mut().push("existing-server");
            self.before.clone()
        }

        fn execute(
            &self,
            args: &[OsString],
            env: &[(OsString, OsString)],
        ) -> Result<Capture, ObservationFailure> {
            self.calls.borrow_mut().push("execute");
            assert_eq!(args, ["list", "targets", "-v"].map(OsString::from));
            assert_eq!(
                env,
                [(
                    OsString::from("OHOS_HDC_SERVER_PORT"),
                    OsString::from("8710")
                )]
            );
            self.output.clone()
        }

        fn revalidate(&self, _: &()) -> Result<(), ObservationFailure> {
            self.calls.borrow_mut().push("revalidate");
            self.after.clone()
        }
    }

    #[test]
    fn supported_mac_hashes_cannot_be_borrowed_by_windows_or_unknown_tools() {
        let mac_hash = "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83";
        assert_eq!(registered_version("macos", mac_hash), Some("3.2.0f"));
        assert_eq!(registered_version("windows", mac_hash), None);
        assert_eq!(registered_version("linux", mac_hash), None);
        assert_eq!(registered_version("macos", &"0".repeat(64)), None);
    }

    #[test]
    fn server_precondition_blocks_every_dispatch() {
        let mut fake = FakeBackend::stdout(b"[Empty]\n");
        fake.before = Err(ObservationFailure::Unavailable("server absent"));
        assert_eq!(
            observe_candidates(&fake, "3.2.0f")
                .unwrap_err()
                .classification(),
            "unavailable"
        );
        assert_eq!(*fake.calls.borrow(), ["existing-server"]);
    }

    #[test]
    fn exact_read_only_lowering_is_bracketed_before_publication() {
        let fake = FakeBackend::stdout(b"device-key\t\tUSB\tOffline\tlocalhost\n");
        let candidates = observe_candidates(&fake, "3.2.0f").unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].state, "Offline");
        assert_eq!(
            *fake.calls.borrow(),
            ["existing-server", "execute", "revalidate"]
        );
    }

    #[test]
    fn server_drift_invalidates_empty_output_and_all_captured_candidates() {
        for stdout in [
            b"[Empty]\n".as_slice(),
            b"device-key\t\tUSB\tConnected\tlocalhost\n",
        ] {
            let mut fake = FakeBackend::stdout(stdout);
            fake.after = Err(ObservationFailure::Unknown("server identity drift"));
            assert_eq!(
                observe_candidates(&fake, "3.2.0f")
                    .unwrap_err()
                    .classification(),
                "unknown"
            );
            assert_eq!(fake.calls.borrow().len(), 3);
        }
    }

    #[test]
    fn failed_process_is_still_postchecked_and_is_never_replayed() {
        let mut fake = FakeBackend::stdout(b"[Empty]\n");
        fake.output = Err(ObservationFailure::Unavailable("timeout"));
        assert!(observe_candidates(&fake, "3.2.0f").is_err());
        assert_eq!(
            *fake.calls.borrow(),
            ["existing-server", "execute", "revalidate"]
        );
    }

    #[test]
    fn invalid_execution_cannot_publish_empty_snapshot() {
        for output in [
            (Vec::new(), Vec::new(), Some(0)),
            (b"[Empty]\n".to_vec(), b"warning".to_vec(), Some(0)),
            (b"[Empty]\n".to_vec(), Vec::new(), Some(1)),
            (b"[Empty]\n".to_vec(), Vec::new(), None),
            (vec![0xff], Vec::new(), Some(0)),
        ] {
            let mut fake = FakeBackend::stdout(b"");
            fake.output = Ok(Capture {
                stdout: output.0,
                stderr: output.1,
                exit_code: output.2,
            });
            assert_eq!(
                observe_candidates(&fake, "3.2.0f")
                    .unwrap_err()
                    .classification(),
                "unknown"
            );
        }
    }

    #[test]
    fn malformed_tail_and_excess_rows_cannot_publish_partial_sets() {
        let fake = FakeBackend::stdout(b"key\t\tUSB\tConnected\tlocalhost\nmalformed\n");
        assert!(observe_candidates(&fake, "3.2.0f").is_err());
        let oversized = (0..=MAX_CANDIDATES)
            .map(|index| format!("key-{index}\t\tUSB\tConnected\tlocalhost\n"))
            .collect::<String>();
        let fake = FakeBackend::stdout(oversized.as_bytes());
        assert!(observe_candidates(&fake, "3.2.0f").is_err());
    }
}
