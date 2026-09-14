//! A long-lived `hdc shell` bound to one device, as Swift's
//! `PersistentDeviceShellChannel` keeps it (SPK-6 phase 3, TASK-XPA-016).
//!
//! Spawning a client for every command costs a process launch on top of the
//! device round trip; an interactive gesture has to fit inside 400 ms end to
//! end. The channel is deliberately narrow: `hdc shell` refuses a plain pipe
//! ("Not support stdio TTY mode"), so the client rides a pseudo-terminal with
//! echo and newline translation off; each command is bracketed by a fresh
//! nonce, so an answer that arrives late can never be read as the next
//! command's answer, and the device shell reports the command's own status
//! inside the closing marker; anything unexpected closes the channel rather
//! than resynchronising a stream whose position is no longer trustworthy; and
//! a command whose frame never completes is an unknown outcome, never a
//! failure, because the device may well have carried it out.
use super::VerifiedTool;
use super::macos_process::spawn_pty;
use crate::random_bytes;
use std::ffi::OsString;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::time::{Duration, Instant};

/// What one command over a persistent device shell answered.
///
/// `device_exit_status` is the status of the command *on the device*. A
/// spawned `hdc shell` cannot report that at all; framing the command lets the
/// device shell report its own status, which is a stronger fact than text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceShellAnswer {
    pub stdout: Vec<u8>,
    pub device_exit_status: i32,
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceShellChannelError {
    /// The channel could not be established, or is no longer usable. Nothing
    /// was written to the device, so the caller may fall back to spawning.
    Unavailable(String),
    /// The command was written but its answer never arrived. Whether the
    /// device carried it out is not known and must not be guessed: the caller
    /// owns an unknown outcome from here.
    OutcomeUnknown(String),
}

/// Bytes read past the budget before the channel is abandoned. A command that
/// floods cannot be allowed to hold the channel until timeout, but nor should
/// a slightly-over-budget answer cost the channel.
const OVERFLOW_TOLERANCE_BYTES: usize = 4 * 1024 * 1024;

pub struct DeviceShellChannel {
    master: Option<OwnedFd>,
    child: libc::pid_t,
    closed: bool,
    pending: Vec<u8>,
}

impl DeviceShellChannel {
    /// Opens a shell on the device `arguments` name (`-t <connectKey> shell`).
    ///
    /// The executable's identity is verified exactly as a spawned dispatch
    /// verifies it, and the channel then rides that one verified process. The
    /// client discards anything written before its device shell is up, so the
    /// first write waits for the shell to say something, and opening is then
    /// proved by one framed no-op that has to come back with status 0.
    pub fn open(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
        settle: Duration,
    ) -> Result<Self, DeviceShellChannelError> {
        let unavailable = |what: &str, error: io::Error| {
            DeviceShellChannelError::Unavailable(format!("{what}: {error}"))
        };
        tool.revalidate()
            .map_err(|error| unavailable("channel executable identity refused", error))?;
        let (child, master) = spawn_pty(tool, arguments, environment)
            .map_err(|error| unavailable("cannot start the channel client", error))?;
        let mut channel = Self {
            master: Some(master),
            child,
            closed: false,
            pending: Vec::new(),
        };
        let ready = Instant::now() + settle;
        while channel.pending.is_empty() && Instant::now() < ready && channel.is_alive() {
            channel.drain(ready.min(Instant::now() + Duration::from_millis(100)));
        }
        if channel.pending.is_empty() {
            channel.close();
            return Err(DeviceShellChannelError::Unavailable(
                "the channel shell never came up".to_string(),
            ));
        }
        match channel.run(&["true"], settle, 4096) {
            Ok(answer) if answer.device_exit_status == 0 => Ok(channel),
            Ok(_) => {
                channel.close();
                Err(DeviceShellChannelError::Unavailable(
                    "the channel shell refused a no-op".to_string(),
                ))
            }
            Err(error) => {
                channel.close();
                Err(DeviceShellChannelError::Unavailable(format!(
                    "the channel never became ready: {error:?}"
                )))
            }
        }
    }

    /// Runs one command and returns what the device answered.
    ///
    /// `arguments` are joined into a single shell line, so every element must
    /// be a bare token. A caller that cannot promise that must spawn instead:
    /// this refuses rather than quoting, because a quoting rule that differs
    /// from the spawned path by one character would make the two dispatch
    /// shapes run different commands.
    pub fn run(
        &mut self,
        arguments: &[&str],
        timeout: Duration,
        output_byte_budget: usize,
    ) -> Result<DeviceShellAnswer, DeviceShellChannelError> {
        if arguments.is_empty() || !arguments.iter().all(|value| Self::is_bare_token(value)) {
            return Err(DeviceShellChannelError::Unavailable(
                "the channel carries bare tokens only; this command needs a spawn".to_string(),
            ));
        }
        if self.closed || !self.is_alive() {
            return Err(DeviceShellChannelError::Unavailable(
                "the channel is not open".to_string(),
            ));
        }
        let nonce = match random_bytes::<16>() {
            Ok(bytes) => format!(
                "ARKDECK{}",
                bytes
                    .iter()
                    .map(|byte| format!("{byte:02X}"))
                    .collect::<String>()
            ),
            Err(error) => {
                return Err(DeviceShellChannelError::Unavailable(format!(
                    "cannot frame the command: {error}"
                )));
            }
        };
        // The opening marker separates the command's output from the prompt
        // and echo that precede it; the closing one is written by the shell
        // only once the command has returned, and carries its own status.
        let line = format!("echo {nonce}B; {}; echo {nonce}:$?\n", arguments.join(" "));
        // Anything still buffered belongs to the previous command's trailing
        // prompt. It is dropped before writing so it cannot be read as output.
        self.pending.clear();
        if let Err(error) = self.write_all(line.as_bytes()) {
            self.close();
            return Err(DeviceShellChannelError::Unavailable(format!(
                "cannot write to the channel: {error}"
            )));
        }
        let deadline = Instant::now() + timeout;
        let mut scanner = FrameScanner::new(&nonce);
        loop {
            if let FrameReading::Complete { body, status } = scanner.advance(&self.pending) {
                self.pending.clear();
                // The budget bounds what comes back, not what has to be read
                // to find the frame: the command still has to be accounted
                // for, so the answer is trimmed rather than the frame dropped.
                let truncated = body.len() > output_byte_budget;
                let mut stdout = body;
                stdout.truncate(output_byte_budget);
                return Ok(DeviceShellAnswer {
                    stdout,
                    device_exit_status: status,
                    truncated,
                });
            }
            // A command that answers without ever framing it cannot be
            // allowed to hold the channel, or the memory, until its timeout.
            if self.pending.len() > output_byte_budget.saturating_add(OVERFLOW_TOLERANCE_BYTES) {
                self.close();
                return Err(DeviceShellChannelError::OutcomeUnknown(
                    "the channel answered past every bound before framing its answer".to_string(),
                ));
            }
            if Instant::now() >= deadline {
                self.close();
                return Err(DeviceShellChannelError::OutcomeUnknown(
                    "the channel did not answer within its timeout".to_string(),
                ));
            }
            if !self.is_alive() {
                self.close();
                return Err(DeviceShellChannelError::OutcomeUnknown(
                    "the channel client exited before answering".to_string(),
                ));
            }
            self.drain(deadline.min(Instant::now() + Duration::from_millis(50)));
        }
    }

    /// Whether the client is still running; a reaped client is gone for good.
    pub fn is_alive(&mut self) -> bool {
        if self.child <= 0 {
            return false;
        }
        let mut status = 0;
        // SAFETY: only this channel's own child is queried, without blocking.
        let reaped = unsafe { libc::waitpid(self.child, &mut status, libc::WNOHANG) };
        if reaped == self.child {
            self.child = -1;
            return false;
        }
        reaped == 0
    }

    /// Closes the terminal and takes the client's whole process group with it.
    pub fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.master = None;
        if self.child > 0 {
            // SAFETY: the child's group is its own (POSIX_SPAWN_SETPGROUP), so
            // the signal reaches nothing else; the wait reaps only that child.
            unsafe {
                libc::kill(-self.child, libc::SIGKILL);
                let mut status = 0;
                libc::waitpid(self.child, &mut status, 0);
            }
            self.child = -1;
        }
        self.pending.clear();
    }

    /// A token that a shell would read back exactly as written: digits,
    /// letters and a short set of punctuation that carries no meaning to it.
    pub fn is_bare_token(value: &str) -> bool {
        !value.is_empty()
            && value.len() <= 256
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_./:=+,@".contains(&byte))
    }

    /// Reads whatever is available, returning as soon as it has read
    /// something: waiting out the rest of a window after the answer has
    /// already arrived would add that window to every command.
    fn drain(&mut self, deadline: Instant) {
        let Some(master) = self.master.as_ref() else {
            return;
        };
        let master = master.as_raw_fd();
        while Instant::now() < deadline {
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .as_millis()
                .max(1)
                .min(i32::MAX as u128) as i32;
            let mut descriptor = libc::pollfd {
                fd: master,
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            };
            // SAFETY: one live descriptor; the wait is bounded by `remaining`.
            let polled = unsafe { libc::poll(&mut descriptor, 1, remaining) };
            if polled <= 0 {
                return;
            }
            let mut buffer = [0u8; 8192];
            // SAFETY: the buffer is writable for its whole length.
            let count = unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count > 0 {
                self.pending.extend_from_slice(&buffer[..count as usize]);
                return;
            }
            if count == 0 {
                return;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock
                && error.kind() != io::ErrorKind::Interrupted
            {
                return;
            }
        }
    }

    fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
        let master = self
            .master
            .as_ref()
            .ok_or_else(|| io::Error::other("channel write failed"))?
            .as_raw_fd();
        let mut written = 0;
        while written < bytes.len() {
            // SAFETY: the slice is readable for the remaining length.
            let count = unsafe {
                libc::write(
                    master,
                    bytes[written..].as_ptr().cast(),
                    bytes.len() - written,
                )
            };
            if count > 0 {
                written += count as usize;
                continue;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock
                || error.kind() == io::ErrorKind::Interrupted
            {
                continue;
            }
            return Err(io::Error::other("channel write failed"));
        }
        Ok(())
    }
}

impl Drop for DeviceShellChannel {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum FrameReading {
    /// The frame is closed and carries the command's own status.
    Complete { body: Vec<u8>, status: i32 },
    /// Part of the frame is there but not all of it. Reading on is correct;
    /// treating this as malformed would abandon a live channel over nothing
    /// more than where a read boundary happened to fall.
    Incomplete,
    /// The frame has not started arriving yet.
    Absent,
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from > haystack.len() || needle.is_empty() || needle.len() > haystack.len() - from {
        return None;
    }
    let first = needle[0];
    let mut at = from;
    while let Some(offset) = haystack[at..=haystack.len() - needle.len()]
        .iter()
        .position(|byte| *byte == first)
    {
        let candidate = at + offset;
        if &haystack[candidate..candidate + needle.len()] == needle {
            return Some(candidate);
        }
        at = candidate + 1;
        if at > haystack.len() - needle.len() {
            return None;
        }
    }
    None
}

/// Finds the command's own frame in what has been read so far, resuming
/// where the previous look left off so a flood is scanned once, not once
/// per read.
///
/// The command is bracketed rather than merely terminated, because what
/// precedes its output is not predictable: the shell prints a prompt whose
/// shape is its own business, and the device's shell also echoes the line it
/// was given. Both land before the opening marker and are excluded by where
/// the frame starts. Both markers also appear inside the echoed command line;
/// they are told apart by what follows: the echoed opening marker is followed
/// by `;` and the printed one by a newline, the echoed closing marker by `:$?`
/// and the printed one by the status digits.
pub(crate) struct FrameScanner {
    begin: Vec<u8>,
    end: Vec<u8>,
    begin_from: usize,
    saw_begin: bool,
    body_start: Option<usize>,
    end_from: usize,
}

impl FrameScanner {
    pub(crate) fn new(nonce: &str) -> Self {
        Self {
            begin: format!("{nonce}B").into_bytes(),
            end: format!("{nonce}:").into_bytes(),
            begin_from: 0,
            saw_begin: false,
            body_start: None,
            end_from: 0,
        }
    }

    pub(crate) fn advance(&mut self, buffer: &[u8]) -> FrameReading {
        if self.body_start.is_none() {
            let mut from = self.begin_from;
            loop {
                let Some(found) = find(buffer, &self.begin, from) else {
                    // Bytes that cannot start a marker need no second look.
                    self.begin_from = buffer.len().saturating_sub(self.begin.len() - 1).max(from);
                    return if self.saw_begin {
                        FrameReading::Incomplete
                    } else {
                        FrameReading::Absent
                    };
                };
                self.saw_begin = true;
                let mut index = found + self.begin.len();
                while index < buffer.len() && buffer[index] == 0x0D {
                    index += 1;
                }
                if index >= buffer.len() {
                    // The newline may still be on its way.
                    self.begin_from = found;
                    return FrameReading::Incomplete;
                }
                if buffer[index] == 0x0A {
                    self.body_start = Some(index + 1);
                    self.end_from = index + 1;
                    break;
                }
                from = found + self.begin.len();
            }
        }
        let body_start = self.body_start.expect("frame body located");
        let mut from = self.end_from;
        loop {
            let Some(found) = find(buffer, &self.end, from) else {
                self.end_from = buffer
                    .len()
                    .saturating_sub(self.end.len() - 1)
                    .max(from)
                    .max(body_start);
                return FrameReading::Incomplete;
            };
            let digits_start = found + self.end.len();
            let mut index = digits_start;
            while index < buffer.len() && buffer[index].is_ascii_digit() {
                index += 1;
            }
            if index == digits_start {
                if index >= buffer.len() {
                    self.end_from = found;
                    return FrameReading::Incomplete;
                }
                from = found + self.end.len();
                continue;
            }
            // A status still being written must not be read as a shorter one.
            if index >= buffer.len() {
                self.end_from = found;
                return FrameReading::Incomplete;
            }
            let Some(status) = std::str::from_utf8(&buffer[digits_start..index])
                .ok()
                .and_then(|digits| digits.parse::<i32>().ok())
            else {
                self.end_from = found;
                return FrameReading::Incomplete;
            };
            return FrameReading::Complete {
                body: buffer[body_start..found].to_vec(),
                status,
            };
        }
    }
}

/// One look at a whole buffer.
#[cfg(test)]
pub(crate) fn frame(buffer: &[u8], nonce: &str) -> FrameReading {
    FrameScanner::new(nonce).advance(buffer)
}

#[cfg(test)]
mod tests {
    use super::{DeviceShellChannel, FrameReading, FrameScanner, frame};

    const NONCE: &str = "ARKDECK0123456789ABCDEF0123456789ABCDEF";

    #[test]
    fn a_complete_frame_excludes_the_prompt_the_echo_and_the_trailing_prompt() {
        let buffer =
            format!("$ echo {NONCE}B; printf hi; echo {NONCE}:$?\r\n{NONCE}B\r\nhi{NONCE}:0\r\n$ ");
        assert_eq!(
            frame(buffer.as_bytes(), NONCE),
            FrameReading::Complete {
                body: b"hi".to_vec(),
                status: 0
            }
        );
    }

    #[test]
    fn a_status_still_being_written_is_incomplete_and_a_missing_frame_is_absent() {
        let opened = format!("{NONCE}B\nout{NONCE}:12");
        assert_eq!(frame(opened.as_bytes(), NONCE), FrameReading::Incomplete);
        let closed = format!("{NONCE}B\nout{NONCE}:12\n");
        assert_eq!(
            frame(closed.as_bytes(), NONCE),
            FrameReading::Complete {
                body: b"out".to_vec(),
                status: 12
            }
        );
        let echo_only = format!("echo {NONCE}B; true; echo {NONCE}:$?\n");
        assert_eq!(frame(echo_only.as_bytes(), NONCE), FrameReading::Incomplete);
        assert_eq!(frame(b"prompt$ ", NONCE), FrameReading::Absent);
    }

    #[test]
    fn an_incremental_scan_across_reads_agrees_with_one_look_at_the_whole_buffer() {
        let whole = format!(
            "$ echo {NONCE}B; seq 3; echo {NONCE}:$?\r\n{NONCE}B\r\n1\n2\n3\n{NONCE}:0\n$ "
        );
        let bytes = whole.as_bytes();
        let mut scanner = FrameScanner::new(NONCE);
        let mut seen = 0;
        let mut last = FrameReading::Absent;
        for chunk in 1..=bytes.len() {
            seen = chunk;
            last = scanner.advance(&bytes[..seen]);
            if matches!(last, FrameReading::Complete { .. }) {
                break;
            }
        }
        assert_eq!(last, frame(&bytes[..seen], NONCE));
        assert_eq!(
            last,
            FrameReading::Complete {
                body: b"1\n2\n3\n".to_vec(),
                status: 0
            }
        );
    }

    #[test]
    fn bare_tokens_carry_no_shell_meaning() {
        for token in ["uinput", "-t", "0x1F", "a.b/c:d=e+f,g@h", "ARKDECK_1"] {
            assert!(DeviceShellChannel::is_bare_token(token), "{token}");
        }
        for token in [
            "",
            "a b",
            "a;b",
            "$HOME",
            "a\"b",
            "`x`",
            "a\nb",
            "é",
            &"a".repeat(257),
        ] {
            assert!(!DeviceShellChannel::is_bare_token(token), "{token:?}");
        }
    }
}
