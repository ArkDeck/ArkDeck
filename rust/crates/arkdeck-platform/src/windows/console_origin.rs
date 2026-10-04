//! The Windows foreground-console origin of a pipe client (TASK-XPA-005,
//! maintainer ruling 2026-10-04): the fact the Runtime reads, for each frame,
//! before it issues an interactive impact-approval challenge or accepts its
//! answer, where the macOS daemon reads its kernel's controlling-terminal
//! foreground group (`macos_control.rs`).
//!
//! It holds only when all of these hold, on the client process this exact
//! pipe instance named and the connection pinned when it authenticated it
//! (`ProcessIdentity`: the process object held open, its creation time
//! re-read, so a reused PID never stands for it):
//!
//! * (a) the client runs as the daemon's own user (`require_client_user`);
//! * (b) its session is the active console session: the session of its token
//!   and `ProcessIdToSessionId` of its PID both equal
//!   `WTSGetActiveConsoleSessionId`, so a client in a Remote Desktop or any
//!   other session, or a service, never qualifies, nor does any client while
//!   no session is attached to the console;
//! * the client is still the same live process after every fact is read.
//!
//! Anything that cannot be read is no console. The third part of the ruling,
//! (c), is the human: the challenge is answered at the client's console (the
//! CLI reads it only from a terminal stdin, `console_approval.rs`), and that
//! answer is the presence proof.
use super::identity::{ProcessIdentity, Token};
use windows_sys::Win32::System::RemoteDesktop::{
    ProcessIdToSessionId, WTSGetActiveConsoleSessionId,
};

/// What `WTSGetActiveConsoleSessionId` answers while no session is attached
/// to the physical console.
const NO_CONSOLE_SESSION: u32 = 0xFFFF_FFFF;

/// The facts of one reading, each `None` when it could not be read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ConsoleFacts {
    pub(crate) same_user: bool,
    pub(crate) token_session: Option<u32>,
    pub(crate) process_session: Option<u32>,
    pub(crate) active_console_session: Option<u32>,
}

impl ConsoleFacts {
    /// The ruling's (a) and (b): the daemon's own user, in the session the
    /// console is attached to, by both readings of that session.
    pub(crate) fn foreground_console(&self) -> bool {
        let Some(active) = self
            .active_console_session
            .filter(|session| *session != NO_CONSOLE_SESSION)
        else {
            return false;
        };
        self.same_user && self.token_session == Some(active) && self.process_session == Some(active)
    }
}

/// The session the console is attached to, if any.
fn active_console_session() -> Option<u32> {
    // SAFETY: no arguments; returns a session id or the no-console value.
    let session = unsafe { WTSGetActiveConsoleSessionId() };
    (session != NO_CONSOLE_SESSION).then_some(session)
}

fn process_session(pid: u32) -> Option<u32> {
    let mut session = 0;
    // SAFETY: valid output storage for the synchronous call.
    (unsafe { ProcessIdToSessionId(pid, &mut session) } != 0).then_some(session)
}

/// Whether the pinned client is the foreground console (see the module).
pub(crate) fn foreground_console(peer: &ProcessIdentity) -> bool {
    if peer.require_live().is_err() {
        return false;
    }
    let facts = ConsoleFacts {
        same_user: peer.require_client_user().is_ok(),
        token_session: Token::for_process(peer.process.raw())
            .and_then(|token| token.session())
            .ok(),
        process_session: process_session(peer.pid),
        active_console_session: active_console_session(),
    };
    // Every fact was read of this very process.
    facts.foreground_console() && peer.require_live().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(
        same_user: bool,
        token: Option<u32>,
        process: Option<u32>,
        active: Option<u32>,
    ) -> ConsoleFacts {
        ConsoleFacts {
            same_user,
            token_session: token,
            process_session: process,
            active_console_session: active,
        }
    }

    #[test]
    fn only_the_daemon_s_user_in_the_active_console_session_is_the_console() {
        assert!(facts(true, Some(1), Some(1), Some(1)).foreground_console());
        for (case, refused) in [
            (
                "another session (RDP)",
                facts(true, Some(2), Some(2), Some(1)),
            ),
            (
                "services' session 0",
                facts(true, Some(0), Some(0), Some(1)),
            ),
            ("another user", facts(false, Some(1), Some(1), Some(1))),
            ("no console session", facts(true, Some(1), Some(1), None)),
            (
                "the no-console value",
                facts(
                    true,
                    Some(NO_CONSOLE_SESSION),
                    Some(NO_CONSOLE_SESSION),
                    Some(NO_CONSOLE_SESSION),
                ),
            ),
            ("token session unread", facts(true, None, Some(1), Some(1))),
            (
                "process session unread",
                facts(true, Some(1), None, Some(1)),
            ),
            (
                "the readings disagree",
                facts(true, Some(1), Some(2), Some(1)),
            ),
        ] {
            assert!(!refused.foreground_console(), "{case}");
        }
    }
}
