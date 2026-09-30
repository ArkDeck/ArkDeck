//! The Windows client starts the daemon it needs (CHG-2026-074 r12
//! decision 11; implementation choices proposed by the lead for maintainer
//! review, recorded in the TASK-XPA-002 client-started daemon run record).
//!
//! [`ensure_running`] starts a daemon only when its pipe is absent. It then
//! launches the pinned daemon image ([`StartTarget::identity`]: the path and
//! its signer certificate pin or package family) detached, with no console
//! window, as the image alone for its argument array, and waits a bounded
//! time for the pipe. What answers on the pipe is then checked as every
//! connection checks its daemon — the pipe owner SID, the server process's
//! image path and signer pin or package family — and a process that fails
//! that check is reported with the process id this client started, never
//! trusted. Starting never weakens or skips that check.
//!
//! Only one daemon ever runs for a state root: the daemon's own
//! single-instance guard decides that. Clients also take a starters' turn
//! (`StarterLock`) and look at the pipe again under it, so that concurrent
//! starters launch one daemon, and a pipe another starter brought up is
//! simply used. Nothing here sends a frame: no request is sent, so none can
//! be replayed, and a request lost later is never replayed by a restart.
use arkdeck_platform::{
    DetachedDaemon, InstanceScope, LocalConnection, LocalEndpoint, ServerIdentity, StarterLock,
    StateRoot, await_pipe_instance, default_user_endpoint, pipe_present,
};
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io;
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
    /// Its pipe was there; nothing was started.
    AlreadyServing,
    /// This client launched it, and it proved its identity.
    Launched { pid: u32 },
    /// Another starter's daemon serves (it proved its identity if this
    /// client launched a process meanwhile).
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
    /// The launched daemon exited with this code before its pipe appeared.
    DaemonExited(u32),
    /// No pipe appeared within the wait.
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
/// `wait` for a daemon that proves its identity (see the module's
/// documentation). A pipe that is already there is left to the caller's own
/// connection, which checks it as always.
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
    let server = connect_verified(&target.endpoint, &target.identity, deadline)
        .map(|connection| connection.authenticated_peer_pid())
        .map_err(|error| {
            failure(
                StartRefusal::IdentityRefused,
                format!(
                    "the daemon serving {} after this client started pid {} did not prove the \
                     installed identity and is not trusted: {error}",
                    target.endpoint.as_path().display(),
                    daemon.pid()
                ),
                pid,
            )
        })?;
    // The proving connection took the instance on offer: the caller's own
    // connection waits (bounded) for the next one rather than finding every
    // instance busy.
    let left = deadline.saturating_duration_since(Instant::now());
    if !left.is_zero() {
        let _ = await_pipe_instance(&target.endpoint, left);
    }
    drop(turn);
    Ok(if server == daemon.pid() {
        Started::Launched { pid: server }
    } else {
        Started::ServedByAnother
    })
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
