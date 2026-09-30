//! The client under the persistent device shell channel on Windows
//! (`shell_channel.rs`, TASK-XPA-016): what macOS gets from a pseudo-terminal
//! with echo and newline translation off, Windows gets from a pseudo console
//! (`CreatePseudoConsole`), because `hdc shell` refuses a plain pipe there
//! too. The client is started exactly as the PTY exchange starts its tool
//! (`windows/pty.rs`, G19): the argv array through `CreateProcessW`, never a
//! shell; suspended, admitted into a kill-on-close Job object and resumed
//! only once its image is proved to be the retained file; the clean base
//! environment with a validated overlay.
//!
//! Where Windows differs (each a decision recorded in the run record):
//!
//! - **The line ending is CR**, what a console reads as Enter (G19).
//! - **What comes back is the console's rendering, read as text.** A pseudo
//!   console re-renders its screen as VT text: its control sequences (cursor
//!   visibility, erasures, titles, modes) are removed before the frame is
//!   looked for, a cursor-forward over a run of blanks is read back as those
//!   blanks, and a line arrives with CRLF. The frame, the status and every
//!   bound are the macOS ones; the answer's bytes are the rendered text (T1),
//!   and a device answer that carries its own escape sequences loses them.
//! - **The shell "came up" only once it renders text.** The console host
//!   paints its initial modes and an empty screen before the client has
//!   written anything; those are control sequences and so do not count.
//! - **A flood is bounded by the console.** The host renders a screen per
//!   frame, not every byte the client writes, so a command that floods ends
//!   at its timeout, an unknown outcome as on macOS, before the overflow
//!   bound is reached.
//! - **No signal group.** Closing ends the client's Job, its whole tree
//!   included, and then the console; a client that has exited is not waited
//!   for twice.
use super::process::{RunningChild, spawn_attached};
use super::pty::{CONSOLE_SIZE, Console, LINE_ENDING};
use super::tool::validate_environment;
use crate::VerifiedTool;
use std::ffi::OsString;
use std::io::{self, Write};
use std::time::Instant;

/// What a console reads as Enter, closing each framed line.
pub(crate) const SHELL_LINE_ENDING: u8 = LINE_ENDING;

/// One `hdc shell` client on its own pseudo console.
pub(crate) struct ShellClient {
    child: Option<RunningChild>,
    console: Option<Console>,
    rendering: Rendering,
}

impl ShellClient {
    pub(crate) fn start(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
    ) -> io::Result<Self> {
        validate_environment(environment)?;
        let console = Console::open()?;
        // Suspended, image-proved and in its Job before any client code
        // runs; a refusal there leaves no child, and the console is closed
        // as it is dropped.
        let child = spawn_attached(tool, arguments, environment, None, console.handle)?;
        Ok(Self {
            child: Some(child),
            console: Some(console),
            rendering: Rendering::default(),
        })
    }

    /// Whether the client is still running. An exited client stays owned
    /// until `close` ends its Job, so no descendant outlives the channel.
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(
            self.child.as_ref().map(RunningChild::try_wait),
            Some(Ok(None))
        )
    }

    /// Ends the client's Job, its descendants included, then the console.
    pub(crate) fn close(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill_and_wait();
        }
        if let Some(mut console) = self.console.take() {
            console.close();
        }
    }

    /// Appends the text the console renders to `pending`, returning as soon
    /// as some has arrived, or at `deadline`. Control sequences alone do not
    /// end the wait.
    pub(crate) fn read(&mut self, deadline: Instant, pending: &mut Vec<u8>) {
        let Some(console) = self.console.as_ref() else {
            return;
        };
        let before = pending.len();
        while pending.len() == before {
            let wait = deadline.saturating_duration_since(Instant::now());
            match console.output.recv_timeout(wait) {
                Ok(chunk) => self.rendering.text(&chunk.0, pending),
                // The deadline passed, or the console's output ended.
                Err(_) => return,
            }
        }
    }

    pub(crate) fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        let input = self
            .console
            .as_mut()
            .and_then(|console| console.input.as_mut())
            .ok_or_else(|| io::Error::other("channel write failed"))?;
        input.write_all(bytes).and_then(|()| input.flush())
    }
}

impl Drop for ShellClient {
    fn drop(&mut self) {
        self.close();
    }
}

/// Where the rendering reader is inside the console's VT stream.
#[derive(Default)]
enum Sequence {
    #[default]
    Text,
    /// After ESC, possibly after intermediate bytes.
    Escape,
    /// Inside `ESC [`, with the parameter bytes read so far.
    Control(Vec<u8>),
    /// Inside `ESC ]`, until BEL or `ESC \`.
    Command,
    CommandEscape,
}

/// The longest parameter string kept for a control sequence; the console
/// host writes a few digits, and anything longer is not a cursor move.
const MAX_PARAMETER_BYTES: usize = 16;

/// Reads a pseudo console's rendering back as the text it shows, across
/// chunk boundaries.
#[derive(Default)]
pub(crate) struct Rendering {
    sequence: Sequence,
}

impl Rendering {
    pub(crate) fn text(&mut self, bytes: &[u8], out: &mut Vec<u8>) {
        for &byte in bytes {
            self.sequence = match std::mem::take(&mut self.sequence) {
                Sequence::Text if byte == 0x1b => Sequence::Escape,
                Sequence::Text => {
                    out.push(byte);
                    Sequence::Text
                }
                Sequence::Escape => match byte {
                    b'[' => Sequence::Control(Vec::new()),
                    b']' => Sequence::Command,
                    // Intermediate bytes (a character set designation).
                    0x20..=0x2f => Sequence::Escape,
                    _ => Sequence::Text,
                },
                Sequence::Control(mut parameters) => {
                    if (0x40..=0x7e).contains(&byte) {
                        // Cursor forward: the console host moves over a run
                        // of blanks rather than painting it.
                        if byte == b'C' {
                            out.resize(out.len() + cursor_forward(&parameters), b' ');
                        }
                        Sequence::Text
                    } else {
                        if parameters.len() < MAX_PARAMETER_BYTES {
                            parameters.push(byte);
                        }
                        Sequence::Control(parameters)
                    }
                }
                Sequence::Command => match byte {
                    0x07 => Sequence::Text,
                    0x1b => Sequence::CommandEscape,
                    _ => Sequence::Command,
                },
                Sequence::CommandEscape if byte == b'\\' => Sequence::Text,
                Sequence::CommandEscape => Sequence::Command,
            };
        }
    }
}

/// `ESC [ n C` moves n columns, 1 when n is absent or 0, never past the
/// console's width; anything but digits is not a plain move and adds nothing.
fn cursor_forward(parameters: &[u8]) -> usize {
    if parameters.is_empty() {
        return 1;
    }
    if !parameters.iter().all(u8::is_ascii_digit) {
        return 0;
    }
    std::str::from_utf8(parameters)
        .ok()
        .and_then(|digits| digits.parse::<usize>().ok())
        .map_or(CONSOLE_SIZE.X as usize, |count| count.max(1))
        .min(CONSOLE_SIZE.X as usize)
}

#[cfg(test)]
mod tests {
    use super::Rendering;

    fn render(chunks: &[&[u8]]) -> Vec<u8> {
        let mut rendering = Rendering::default();
        let mut out = Vec::new();
        for chunk in chunks {
            rendering.text(chunk, &mut out);
        }
        out
    }

    #[test]
    fn the_console_hosts_control_sequences_are_not_text() {
        assert_eq!(
            render(&[
                b"\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J\x1b[m\x1b[H\x1b]0;hdc.exe\x07\x1b[?25h"
            ]),
            b""
        );
        assert_eq!(
            render(&[b"\x1b[?25lA\x1b[1;1HB\x1b[KC\x1b(BD\x1b]0;t\x1b\\E\r\n"]),
            b"ABCDE\r\n"
        );
    }

    #[test]
    fn a_sequence_split_across_reads_is_still_removed() {
        assert_eq!(
            render(&[b"AR", b"K\x1b", b"[?2", b"5h", b"DECK"]),
            b"ARKDECK"
        );
        assert_eq!(render(&[b"x\x1b]0;ti", b"tle\x1b", b"\\y"]), b"xy");
    }

    #[test]
    fn a_cursor_forward_over_blanks_reads_back_as_the_blanks() {
        assert_eq!(render(&[b"a\x1b[5X\x1b[5Cb"]), b"a     b");
        assert_eq!(render(&[b"a\x1b[Cb\x1b[0Cc"]), b"a b c");
        assert_eq!(render(&[b"a\x1b[1;2Cb"]), b"ab");
        assert_eq!(render(&[b"\x1b[99999999999999999999C"]).len(), 1024);
    }
}
