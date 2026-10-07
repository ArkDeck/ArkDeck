//! The Windows client starts the daemon it needs (CHG-2026-074 r12
//! decision 11; implementation choices proposed by the lead for maintainer
//! review, recorded in the TASK-XPA-002 client-started daemon run record).
//!
//! [`ensure_running`] starts a daemon only when its pipe is absent. It then
//! launches the pinned daemon image ([`StartTarget::identity`]: the path and
//! its signer certificate pin or package family) detached, with no console
//! window, as the image alone for its argument array, and waits a bounded
//! time for the pipe and a valid health answer. What answers on the pipe is
//! checked as every connection checks its daemon — the pipe owner SID, the server process's
//! image path and signer pin or package family — and a process that fails
//! that check is reported with the process id this client started, never
//! trusted. Starting never weakens or skips that check.
//!
//! Only one daemon ever runs for a state root: the daemon's own
//! single-instance guard decides that. Clients also take a starters' turn
//! (`StarterLock`) and look at the pipe again under it, so that concurrent
//! starters launch one daemon, and a pipe another starter brought up is
//! simply used. The authenticated proving connection sends one read-only
//! health frame within the original start deadline. No caller or business
//! request is sent, and a failed readiness exchange is never reconnected or
//! replayed. A request lost later is never replayed by a restart.
use crate::{BoundedConnection, Client};
use arkdeck_platform::{
    DetachedDaemon, InstanceScope, LocalConnection, LocalEndpoint, ServerIdentity, StarterLock,
    StateRoot, await_pipe_instance, default_user_endpoint, pipe_present,
};
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How often a starter looks at the pipe while its daemon comes up.
const LOOK: Duration = Duration::from_millis(25);

/// `ERROR_PIPE_BUSY`: every instance of an existing pipe is connected.
const PIPE_BUSY: i32 = 231;

/// The daemon a client may start: its scope, its pipe, the identity it
/// must prove and what it is started with.
#[derive(Clone, Debug)]
pub struct StartTarget {
    pub scope: InstanceScope,
    pub endpoint: LocalEndpoint,
    pub identity: ServerIdentity,
    /// An isolated development root the daemon is started over; `None` for
    /// the account's daemon.
    pub development_root: Option<PathBuf>,
    /// The daemon's whole environment; `None` inherits this process's (see
    /// `DetachedDaemon::launch`).
    pub environment: Option<Vec<(OsString, OsString)>>,
}

impl StartTarget {
    /// The daemon a client that reaches `endpoint` (its explicit endpoint,
    /// if any) may start: the account's daemon when nothing is named, or the
    /// daemon of an isolated development root, whose pipe is named after the
    /// root. `None` when the endpoint names a daemon no client starts (a
    /// private endpoint, or one that is not the development root's).
    pub fn resolve(
        endpoint: Option<&OsStr>,
        development_root: Option<&OsStr>,
        identity: ServerIdentity,
    ) -> io::Result<Option<Self>> {
        let (scope, derived, development_root) = match development_root {
            Some(root) => {
                let root = Path::new(root);
                let opened = StateRoot::development(root)?;
                (opened.scope()?, opened.endpoint()?, Some(root.to_owned()))
            }
            None => (InstanceScope::account()?, default_user_endpoint()?, None),
        };
        if endpoint.is_some_and(|endpoint| Path::new(endpoint) != derived.as_path()) {
            return Ok(None);
        }
        Ok(Some(Self {
            scope,
            endpoint: derived,
            identity,
            development_root,
            environment: None,
        }))
    }
}

/// How the daemon came to be serving.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Started {
    /// Its pipe was there and answered health; nothing was started.
    AlreadyServing,
    /// This client launched it, and it proved its identity and health.
    Launched { pid: u32 },
    /// Another starter's daemon serves (it proved its identity if this
    /// client launched a process meanwhile) and answers health.
    ServedByAnother,
}

impl Started {
    /// The machine name of the outcome.
    pub fn outcome(&self) -> &'static str {
        match self {
            Self::AlreadyServing => "alreadyServing",
            Self::Launched { .. } => "launched",
            Self::ServedByAnother => "servedByAnother",
        }
    }
}

/// Why no verified daemon serves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartRefusal {
    /// Another starter held the turn for the whole wait.
    StarterBusy,
    /// The image was not launched: no identity is configured, the image is
    /// not the pinned one, or the process could not be created.
    LaunchRefused,
    /// The launched daemon exited with this code before readiness was proved.
    DaemonExited(u32),
    /// The pipe or its completed health proof was unavailable within the wait.
    NotReady,
    /// What serves the pipe did not prove the pinned identity.
    IdentityRefused,
}

impl StartRefusal {
    pub fn code(&self) -> &'static str {
        match self {
            Self::StarterBusy => "starterBusy",
            Self::LaunchRefused => "launchRefused",
            Self::DaemonExited(_) => "daemonExited",
            Self::NotReady => "notReady",
            Self::IdentityRefused => "identityRefused",
        }
    }
}

#[derive(Debug)]
pub struct StartFailure {
    pub refusal: StartRefusal,
    pub message: String,
    /// The process this client launched, if it launched one.
    pub pid: Option<u32>,
}

impl fmt::Display for StartFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for StartFailure {}

fn failure(refusal: StartRefusal, message: impl Into<String>, pid: Option<u32>) -> StartFailure {
    StartFailure {
        refusal,
        message: message.into(),
        pid,
    }
}

/// Starts the target's daemon if its pipe is absent and waits at most
/// `wait` for a daemon that proves its identity and health. Every outcome
/// requires the same authenticated connection's completed readiness exchange;
/// the caller still checks its own connection as always.
pub fn ensure_running(target: &StartTarget, wait: Duration) -> Result<Started, StartFailure> {
    let deadline = Instant::now() + wait;
    let look = |pid: Option<u32>| {
        pipe_present(&target.endpoint).map_err(|error| {
            failure(
                StartRefusal::NotReady,
                format!("the daemon's pipe could not be looked at: {error}"),
                pid,
            )
        })
    };
    if look(None)? {
        serving_peer(target, deadline, None)?;
        return Ok(Started::AlreadyServing);
    }
    let turn = StarterLock::acquire(&target.scope, wait)
        .map_err(|error| {
            failure(
                StartRefusal::StarterBusy,
                format!("the daemon starters' turn is unusable: {error}"),
                None,
            )
        })?
        .ok_or_else(|| {
            failure(
                StartRefusal::StarterBusy,
                "another client is still starting the daemon",
                None,
            )
        })?;
    if look(None)? {
        serving_peer(target, deadline, None)?;
        drop(turn);
        return Ok(Started::ServedByAnother);
    }
    let daemon = DetachedDaemon::launch(
        &target.identity,
        target.development_root.as_deref(),
        target.environment.as_deref(),
    )
    .map_err(|error| {
        failure(
            StartRefusal::LaunchRefused,
            format!(
                "the daemon {} was not started: {error}",
                target.identity.executable.display()
            ),
            None,
        )
    })?;
    let pid = Some(daemon.pid());
    let mut exited = None;
    loop {
        if look(pid)? {
            break;
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(failure(
                StartRefusal::NotReady,
                format!(
                    "the daemon (pid {}) did not open {} within {}s",
                    daemon.pid(),
                    target.endpoint.as_path().display(),
                    wait.as_secs()
                ),
                pid,
            ));
        }
        let slice = LOOK.min(deadline - now);
        if exited.is_some() {
            // The launched daemon found the root held and left; the holder's
            // pipe is awaited within the same bound.
            std::thread::sleep(slice);
            continue;
        }
        match daemon.wait_exit(slice) {
            Ok(None) => {}
            Ok(Some(0)) => exited = Some(0),
            Ok(Some(code)) => {
                if look(pid)? {
                    break;
                }
                return Err(failure(
                    StartRefusal::DaemonExited(code),
                    format!(
                        "the daemon (pid {}) exited with status {code} before serving",
                        daemon.pid()
                    ),
                    pid,
                ));
            }
            Err(error) => {
                return Err(failure(
                    StartRefusal::NotReady,
                    format!("the started daemon could not be watched: {error}"),
                    pid,
                ));
            }
        }
    }
    let server = serving_peer(target, deadline, pid).map_err(|refusal| {
        preserve_launched_exit(refusal, daemon.pid(), deadline, |left| {
            daemon.wait_exit(left)
        })
    })?;
    drop(turn);
    Ok(if server == daemon.pid() {
        Started::Launched { pid: server }
    } else {
        Started::ServedByAnother
    })
}

fn preserve_launched_exit(
    mut refusal: StartFailure,
    pid: u32,
    deadline: Instant,
    observe: impl FnOnce(Duration) -> io::Result<Option<u32>>,
) -> StartFailure {
    // Composition can close its reserved pipe before the process exit is
    // signaled. Observe our retained child within the original start deadline;
    // never reconnect or send another frame. Identity refusals remain immediate.
    let left = if refusal.refusal == StartRefusal::NotReady {
        deadline.saturating_duration_since(Instant::now())
    } else {
        Duration::ZERO
    };
    if let Ok(Some(code)) = observe(left)
        && code != 0
    {
        refusal.refusal = StartRefusal::DaemonExited(code);
        refusal.message = format!(
            "the daemon (pid {pid}) exited with status {code} before readiness: {}",
            refusal.message
        );
    }
    refusal
}

/// The pipe is reserved before backend composition. Image identity alone is
/// therefore insufficient: use that very connection to prove serving readiness.
fn serving_peer(
    target: &StartTarget,
    deadline: Instant,
    launched: Option<u32>,
) -> Result<u32, StartFailure> {
    let connection = connect_verified(&target.endpoint, &target.identity, deadline).map_err(|error| {
        failure(
            StartRefusal::IdentityRefused,
            format!(
                "the daemon serving {} did not prove the installed identity and is not trusted: {error}",
                target.endpoint.as_path().display()
            ),
            launched,
        )
    })?;
    let server = connection.authenticated_peer_pid();
    let mut client = Client::<BoundedConnection>::from_authenticated(connection, deadline)
        .map_err(|error| readiness_failure(error, launched))?;
    verify_readiness(&mut client, launched)?;
    Ok(server)
}

fn readiness_failure(error: crate::ClientError, launched: Option<u32>) -> StartFailure {
    failure(
        StartRefusal::NotReady,
        format!(
            "the daemon did not complete its startup health proof; no caller request was sent or replayed: {error}"
        ),
        launched,
    )
}

fn verify_readiness<S: Read + Write>(
    client: &mut Client<S>,
    launched: Option<u32>,
) -> Result<(), StartFailure> {
    client
        .health("daemon-start-readiness")
        .map(|_| ())
        .map_err(|error| readiness_failure(error, launched))
}

/// A connection to the daemon serving `endpoint` once it proved `identity`
/// (`LocalConnection::connect`); no frame is sent. While every instance of
/// the pipe is busy (its server has not yet offered the next one), the
/// kernel's wait for a free instance is taken, within `deadline`.
pub fn connect_verified(
    endpoint: &LocalEndpoint,
    identity: &ServerIdentity,
    deadline: Instant,
) -> io::Result<LocalConnection> {
    loop {
        match LocalConnection::connect(endpoint, identity) {
            Err(error) if error.raw_os_error() == Some(PIPE_BUSY) => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() || !await_pipe_instance(endpoint, left)? {
                    return Err(error);
                }
            }
            answer => return answer,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_contract::{
        CATALOG_DIGEST, CONTRACT_IDENTITY, MAX_RESPONSE_BYTES, METHODS, PROTOCOL_VERSION,
        encode_frame,
    };
    use serde_json::{Value, json};
    use std::io::Cursor;
    use std::sync::{Arc, Mutex, mpsc};

    fn health() -> Value {
        json!({"id":"daemon-start-readiness","ok":true,"result":{
            "status":"ok","protocolVersion":PROTOCOL_VERSION,
            "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,
            "providers":[],"publishedMethods":METHODS}})
    }

    struct Stream {
        input: Cursor<Vec<u8>>,
        sent: Arc<Mutex<Vec<u8>>>,
        failure: Option<io::ErrorKind>,
    }
    impl Read for Stream {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            if let Some(kind) = self.failure {
                return Err(io::Error::new(kind, "fixture initialization failed"));
            }
            self.input.read(bytes)
        }
    }
    impl Write for Stream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.sent.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    fn client(
        bytes: Vec<u8>,
        failure: Option<io::ErrorKind>,
    ) -> (Client<Stream>, Arc<Mutex<Vec<u8>>>) {
        let sent = Arc::new(Mutex::new(Vec::new()));
        (
            Client::new(Stream {
                input: Cursor::new(bytes),
                sent: Arc::clone(&sent),
                failure,
            }),
            sent,
        )
    }
    fn frames(sent: &Arc<Mutex<Vec<u8>>>) -> Vec<Value> {
        String::from_utf8(sent.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|frame| serde_json::from_str(frame).unwrap())
            .collect()
    }
    fn assert_one_read_only_frame(sent: &Arc<Mutex<Vec<u8>>>) {
        let frames = frames(sent);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["id"], "daemon-start-readiness");
        assert_eq!(frames[0]["method"], "health");
        assert!(frames[0].get("params").is_none());
    }

    #[test]
    fn an_early_proving_connection_waits_for_its_only_health_reply() {
        struct Gated {
            sent: Arc<Mutex<Vec<u8>>>,
            input: Cursor<Vec<u8>>,
            awaiting: Option<mpsc::Sender<()>>,
            release: mpsc::Receiver<Vec<u8>>,
        }
        impl Read for Gated {
            fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
                if let Some(awaiting) = self.awaiting.take() {
                    awaiting.send(()).unwrap();
                    self.input =
                        Cursor::new(self.release.recv_timeout(Duration::from_secs(10)).unwrap());
                }
                self.input.read(bytes)
            }
        }
        impl Write for Gated {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.sent.lock().unwrap().extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let sent = Arc::new(Mutex::new(Vec::new()));
        let (awaiting, waiting) = mpsc::channel();
        let (release, reply) = mpsc::channel();
        let (completed, completion) = mpsc::channel();
        let writes = Arc::clone(&sent);
        let worker = std::thread::spawn(move || {
            let mut client = Client::new(Gated {
                sent: writes,
                input: Cursor::new(Vec::new()),
                awaiting: Some(awaiting),
                release: reply,
            });
            completed
                .send(verify_readiness(&mut client, Some(7)))
                .unwrap();
        });
        waiting.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_one_read_only_frame(&sent);
        assert!(matches!(
            completion.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        release
            .send(encode_frame(&health(), MAX_RESPONSE_BYTES).unwrap())
            .unwrap();
        assert!(
            completion
                .recv_timeout(Duration::from_secs(10))
                .unwrap()
                .is_ok()
        );
        worker.join().unwrap();
        assert_one_read_only_frame(&sent);
    }

    #[test]
    fn initialization_eof_timeout_and_broken_pipe_refuse_without_replay() {
        for fault in [
            None,
            Some(io::ErrorKind::TimedOut),
            Some(io::ErrorKind::BrokenPipe),
        ] {
            let (mut client, sent) = client(Vec::new(), fault);
            let failure = verify_readiness(&mut client, Some(7)).unwrap_err();
            assert_eq!(failure.refusal, StartRefusal::NotReady);
            assert_eq!(failure.pid, Some(7));
            assert!(failure.message.contains("startup health proof"));
            assert!(
                failure
                    .message
                    .contains("no caller request was sent or replayed")
            );
            assert!(verify_readiness(&mut client, Some(7)).is_err());
            assert_one_read_only_frame(&sent);
        }
    }

    #[test]
    fn every_incompatible_health_refuses_before_any_business_frame() {
        for (field, value) in [
            ("status", json!("starting")),
            ("contractIdentity", json!("wrong")),
            ("protocolVersion", json!("2.0.0")),
            ("catalogDigest", json!("invalid")),
            ("publishedMethods", json!(["health"])),
            ("providers", json!([""])),
        ] {
            let mut reply = health();
            reply["result"][field] = value;
            let (mut client, sent) =
                client(encode_frame(&reply, MAX_RESPONSE_BYTES).unwrap(), None);
            assert_eq!(
                verify_readiness(&mut client, None).unwrap_err().refusal,
                StartRefusal::NotReady
            );
            assert!(verify_readiness(&mut client, None).is_err());
            assert_one_read_only_frame(&sent);
        }
        for bytes in [b"{}\n".to_vec(), b"partial".to_vec()] {
            let (mut client, sent) = client(bytes, None);
            assert!(verify_readiness(&mut client, None).is_err());
            assert!(verify_readiness(&mut client, None).is_err());
            assert_one_read_only_frame(&sent);
        }
    }

    #[test]
    fn the_original_expired_start_deadline_sends_no_health_frame() {
        let (mut client, sent) = client(encode_frame(&health(), MAX_RESPONSE_BYTES).unwrap(), None);
        client.deadline = Some(Instant::now() - Duration::from_secs(1));
        assert_eq!(
            verify_readiness(&mut client, Some(7)).unwrap_err().refusal,
            StartRefusal::NotReady
        );
        assert!(frames(&sent).is_empty());
    }

    #[test]
    fn initialization_eof_preserves_the_child_exit_after_the_pipe_closes() {
        let (mut client, sent) = client(Vec::new(), None);
        let refusal = verify_readiness(&mut client, Some(7)).unwrap_err();
        let deadline = Instant::now() + Duration::from_secs(10);
        let refusal = preserve_launched_exit(refusal, 7, deadline, |left| {
            assert!(!left.is_zero());
            assert!(left <= Duration::from_secs(10));
            // The retained native handle becomes signaled after pipe EOF.
            Ok(Some(69))
        });
        assert_eq!(refusal.refusal, StartRefusal::DaemonExited(69));
        assert_eq!(refusal.pid, Some(7));
        assert!(refusal.message.contains("exited with status 69"));
        assert!(refusal.message.contains("startup health proof"));
        assert_one_read_only_frame(&sent);
    }

    #[test]
    fn child_observation_never_extends_the_deadline_or_delays_identity_refusal() {
        for (kind, deadline) in [
            (StartRefusal::NotReady, Instant::now()),
            (
                StartRefusal::IdentityRefused,
                Instant::now() + Duration::from_secs(10),
            ),
        ] {
            let refusal = failure(kind, "original refusal", Some(7));
            let refusal = preserve_launched_exit(refusal, 7, deadline, |left| {
                assert!(left.is_zero());
                Ok(None)
            });
            assert_eq!(refusal.refusal, kind);
            assert_eq!(refusal.message, "original refusal");
            assert_eq!(refusal.pid, Some(7));
        }
    }

    #[test]
    fn an_unproved_or_successful_exit_does_not_replace_the_readiness_failure() {
        for observation in [
            Ok(None),
            Ok(Some(0)),
            Err(io::Error::other("exit unavailable")),
        ] {
            let refusal = failure(StartRefusal::NotReady, "original refusal", Some(7));
            let refusal = preserve_launched_exit(refusal, 7, Instant::now(), |_| observation);
            assert_eq!(refusal.refusal, StartRefusal::NotReady);
            assert_eq!(refusal.message, "original refusal");
            assert_eq!(refusal.pid, Some(7));
        }
    }
}
