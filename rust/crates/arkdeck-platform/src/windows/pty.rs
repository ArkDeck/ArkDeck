//! The PTY prompt/secret exchange on Windows (TASK-XPA-011, gate inventory
//! G19): the counterpart of the macOS `run_pty_exchange` (`pty_exchange.rs`,
//! SPK-6 phase 4), with the same request, interactions, bounds, errors and
//! result. The verified tool is attached to a pseudo console
//! (`CreatePseudoConsole`, `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`) and started
//! exactly as the tool runner starts it (`windows/tool.rs`): the argv array
//! through `CreateProcessW`, never a shell; suspended, admitted into a
//! kill-on-close Job object and resumed only once its image is proved to be
//! the retained file; the clean base environment with a validated overlay;
//! a child-only working directory. The secret travels only through the
//! console's input pipe, from a buffer wiped after the write, and never
//! through argv, the environment, a receipt or a log; nothing the console
//! renders is returned.
//!
//! Where Windows differs (each a decision recorded in the run record):
//!
//! - **Echo is detected, not prevented.** macOS clears `ECHO` on the slave
//!   before the child runs. A pseudo console's input mode belongs to the
//!   console host and only a process attached to that console can change it
//!   (`SetConsoleMode`); attaching the daemon to the child's console would
//!   change process-wide state. The console's echo is the child's own
//!   choice, as the signer's `readPassword` makes it, and any echo that does
//!   reach the rendered output ends the exchange as `SecretEchoDetected`
//!   before the next secret is written — the check macOS also makes.
//! - **The line ending is CR.** A console reads Enter as `\r`; macOS writes
//!   `\n` to a terminal that maps it.
//! - **A secret is UTF-8 text without control characters.** The console
//!   decodes its input pipe as UTF-8 and interprets control bytes (Ctrl-C
//!   raises a console control event, ESC opens an input sequence, DEL and
//!   backspace erase), so a secret that is not UTF-8 or holds a C0 control
//!   or DEL is `InvalidInteraction` before any child runs.
//! - **The prompts are matched in what the console renders.** A pseudo
//!   console re-renders its screen as VT text: prompts are matched there, a
//!   trailing space a console holds back is not part of what can match, and
//!   the child's own LF arrives as CRLF.
//! - **No TERM.** The budget, the deadline and a cancellation terminate the
//!   Job at once (the tool runner's T1 decision); the exchange also ends the
//!   Job once the child exits, so no descendant outlives it.
//! - **Output after the child's end is still judged.** The console is closed
//!   once the child has exited, which flushes what it has not rendered yet;
//!   that tail is read to its end (bounded) and checked like the rest, so a
//!   failure is classified from the signer's last diagnostic.
use super::process::{RunningChild, spawn_attached};
use super::tool::{child_working_directory, validate_environment};
use super::{Handle, bool_result};
use crate::VerifiedTool;
use crate::invalid;
use crate::process::pty_exchange::{
    MAX_INTERACTIONS, MAX_PROMPT_BYTES, MAX_SECRET_BYTES, MIN_OUTPUT_BUDGET, Zeroing,
    classify_failure, contains, count_occurrences,
};
use crate::process::{
    CLEANUP_TIMEOUT, PtyError, PtyExecution, PtyFailureCategory, PtyInteraction, PtyRequest,
    ToolTermination,
};
use std::fs::File;
use std::io::{self, Read, Write};
use std::ops::Range;
use std::os::windows::io::AsRawHandle;
use std::ptr::null_mut;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use windows_sys::Win32::System::Console::{COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON};
use windows_sys::Win32::System::IO::CancelSynchronousIo;
use windows_sys::Win32::System::Pipes::CreatePipe;

/// Wide enough that no prompt the bounds admit wraps, short enough to keep
/// the console host's screen small.
pub(super) const CONSOLE_SIZE: COORD = COORD { X: 1024, Y: 64 };
/// The input pipe holds every secret the bounds admit without blocking.
const INPUT_PIPE_BYTES: u32 = 64 * 1024;
/// What a console reads as Enter.
pub(super) const LINE_ENDING: u8 = b'\r';
/// How long one wait for rendered output lasts before the child, the
/// deadline and the cancellation are looked at again (the macOS poll).
const POLL: Duration = Duration::from_millis(25);

impl VerifiedTool {
    /// Runs the pinned executable attached to a pseudo console, answering
    /// each exact prompt in order with its secret, and reports only what
    /// the exchange established. `cancelled` is asked while the child runs.
    pub fn run_pty_exchange(
        &self,
        request: &PtyRequest<'_>,
        interactions: &[PtyInteraction],
        output_byte_budget: usize,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<PtyExecution, PtyError> {
        if !admissible(interactions, output_byte_budget) {
            return Err(PtyError::InvalidInteraction);
        }
        if request.timeout.is_zero() {
            return Err(PtyError::Refused(invalid("the exchange needs a timeout")));
        }
        validate_environment(request.environment).map_err(PtyError::Refused)?;
        let directory = request
            .working_directory
            .map(child_working_directory)
            .transpose()
            .map_err(PtyError::Refused)?;
        self.revalidate().map_err(PtyError::Refused)?;
        let mut console = Console::open().map_err(PtyError::LaunchFailed)?;
        // Suspended, image-proved and in its Job before any tool code runs;
        // a refusal there leaves no child.
        let mut child = spawn_attached(
            self,
            request.arguments,
            request.environment,
            directory.as_deref(),
            console.handle,
        )
        .map_err(PtyError::LaunchFailed)?;
        let mut exchange = Exchange {
            interactions,
            budget: output_byte_budget,
            output: Zeroing(Vec::new()),
            completed: 0,
        };
        let result = exchange.run(
            &mut child,
            &mut console,
            Instant::now() + request.timeout,
            cancelled,
        );
        // Every path ends the Job (the child's tree included) and then the
        // console, whose output the reader drains to its end.
        let cleanup = child.kill_and_wait();
        console.close();
        let status = result?;
        // The tail the console renders only once it closes, judged like
        // the rest; the child has ended, so no prompt is answered.
        exchange.drain(&console)?;
        cleanup.map_err(PtyError::WaitFailed)?;
        if exchange.completed != interactions.len() {
            return Err(PtyError::PromptProtocolViolation);
        }
        let termination = ToolTermination::Exited(status);
        let failure_category = if status == 0 {
            PtyFailureCategory::None
        } else {
            classify_failure(&exchange.output.0, interactions)
        };
        Ok(PtyExecution {
            termination,
            completed_interactions: exchange.completed,
            observed_output_byte_count: exchange.output.0.len(),
            failure_category,
        })
    }
}

/// The macOS bounds, and on Windows a secret the console can carry as
/// typed text: UTF-8 without a C0 control or DEL.
fn admissible(interactions: &[PtyInteraction], output_byte_budget: usize) -> bool {
    !interactions.is_empty()
        && interactions.len() <= MAX_INTERACTIONS
        && output_byte_budget >= MIN_OUTPUT_BUDGET
        && interactions.iter().all(|interaction| {
            !interaction.expected_prompt.is_empty()
                && interaction.expected_prompt.len() <= MAX_PROMPT_BYTES
                && !interaction.secret.is_empty()
                && interaction.secret.len() <= MAX_SECRET_BYTES
                && std::str::from_utf8(&interaction.secret).is_ok()
                && !interaction
                    .secret
                    .iter()
                    .any(|byte| *byte < 0x20 || *byte == 0x7f)
        })
}

/// The protocol state: what was rendered (wiped at the end) and how many
/// prompts were answered.
struct Exchange<'a> {
    interactions: &'a [PtyInteraction],
    budget: usize,
    output: Zeroing,
    completed: usize,
}

impl Exchange<'_> {
    /// Waits for the child, answering prompts as they are rendered; its exit
    /// code once it has ended.
    fn run(
        &mut self,
        child: &mut RunningChild,
        console: &mut Console,
        deadline: Instant,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<i32, PtyError> {
        loop {
            if cancelled() {
                return Err(PtyError::Cancelled);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(PtyError::TimedOut);
            }
            // Wakes as soon as the console renders anything.
            match console.output.recv_timeout(POLL.min(deadline - now)) {
                Ok(chunk) => {
                    let due = self.observe(&chunk.0)?;
                    for interaction in &self.interactions[due] {
                        console.answer(&interaction.secret)?;
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(PtyError::WaitFailed(io::Error::other(
                        "the pseudo console's output ended while its child ran",
                    )));
                }
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    return status.code().ok_or_else(|| {
                        PtyError::WaitFailed(io::Error::other("unrecognized child exit status"))
                    });
                }
                Ok(None) => {}
                Err(error) => return Err(PtyError::WaitFailed(error)),
            }
        }
    }

    /// Takes one rendered chunk: the budget, then an echoed secret, then the
    /// prompt protocol, in the macOS order. The prompts that became due, in
    /// order, are counted as answered and returned for the caller to answer;
    /// a later prompt rendered before its turn refuses them all.
    fn observe(&mut self, bytes: &[u8]) -> Result<Range<usize>, PtyError> {
        self.output.0.extend_from_slice(bytes);
        if self.output.0.len() > self.budget {
            return Err(PtyError::OutputBudgetExceeded);
        }
        let output = &self.output.0;
        if self
            .interactions
            .iter()
            .any(|interaction| contains(output, &interaction.secret))
        {
            return Err(PtyError::SecretEchoDetected);
        }
        let occurrences: Vec<usize> = self
            .interactions
            .iter()
            .map(|interaction| count_occurrences(output, &interaction.expected_prompt))
            .collect();
        if occurrences.iter().any(|count| *count > 1) {
            return Err(PtyError::PromptProtocolViolation);
        }
        let start = self.completed;
        while self.completed < self.interactions.len()
            && contains(output, &self.interactions[self.completed].expected_prompt)
        {
            self.completed += 1;
        }
        if occurrences
            .iter()
            .enumerate()
            .any(|(index, count)| index > self.completed && *count > 0)
        {
            return Err(PtyError::PromptProtocolViolation);
        }
        Ok(start..self.completed)
    }

    /// Everything the closed console still delivers, checked as it comes;
    /// an output that does not end within the cleanup budget fails closed.
    fn drain(&mut self, console: &Console) -> Result<(), PtyError> {
        let deadline = Instant::now() + CLEANUP_TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match console.output.recv_timeout(left) {
                Ok(chunk) => {
                    self.observe(&chunk.0)?;
                }
                Err(RecvTimeoutError::Disconnected) => return Ok(()),
                Err(RecvTimeoutError::Timeout) => {
                    return Err(PtyError::WaitFailed(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "the pseudo console's output did not end after it closed",
                    )));
                }
            }
        }
    }
}

/// One pseudo console: its input pipe (written only with a secret and its
/// Enter, or with the persistent shell channel's framed lines), its output
/// pipe (read by a thread that forwards each rendered chunk and, once
/// nobody listens, reads on and discards, so the console host never blocks
/// on a full pipe), and its host, closed on every path.
pub(super) struct Console {
    pub(super) handle: HPCON,
    open: bool,
    pub(super) input: Option<File>,
    pub(super) output: Receiver<Zeroing>,
    reader: Option<JoinHandle<()>>,
}

impl Console {
    pub(super) fn open() -> io::Result<Self> {
        let (input_read, input_write) = pipe(INPUT_PIPE_BYTES)?;
        let (output_read, output_write) = pipe(0)?;
        let mut handle: HPCON = 0;
        // SAFETY: live pipe ends and out value; the console duplicates the
        // two ends it keeps.
        let status = unsafe {
            CreatePseudoConsole(
                CONSOLE_SIZE,
                input_read.raw(),
                output_write.raw(),
                0,
                &mut handle,
            )
        };
        if status < 0 {
            return Err(io::Error::other(format!(
                "CreatePseudoConsole failed: {status:#010x}"
            )));
        }
        drop((input_read, output_write));
        let (sender, output) = mpsc::channel();
        let mut pipe = output_read.into_file();
        let reader = std::thread::spawn(move || {
            let mut sender = Some(sender);
            let mut buffer = Zeroing(vec![0; 4096]);
            loop {
                match pipe.read(&mut buffer.0) {
                    Ok(0) => break,
                    Ok(count) => {
                        let chunk = Zeroing(buffer.0[..count].to_vec());
                        if sender
                            .as_ref()
                            .is_some_and(|sender| sender.send(chunk).is_err())
                        {
                            sender = None;
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    // The console closed (a broken pipe), or the owner
                    // cancelled a read that outlived the cleanup budget.
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            handle,
            open: true,
            input: Some(input_write.into_file()),
            output,
            reader: Some(reader),
        })
    }

    /// Writes one secret and its Enter in a single write from a buffer that
    /// is wiped afterwards.
    fn answer(&mut self, secret: &[u8]) -> Result<(), PtyError> {
        let mut line = Zeroing(Vec::with_capacity(secret.len() + 1));
        line.0.extend_from_slice(secret);
        line.0.push(LINE_ENDING);
        let input = self
            .input
            .as_mut()
            .ok_or_else(|| PtyError::WaitFailed(io::Error::other("console input closed")))?;
        input
            .write_all(&line.0)
            .and_then(|()| input.flush())
            .map_err(PtyError::WaitFailed)
    }

    /// Closes the console host (which ends any client still attached) and
    /// its input; the reader then meets the end of the output.
    pub(super) fn close(&mut self) {
        if self.open {
            self.open = false;
            // SAFETY: the console is closed exactly once; the reader drains
            // its output meanwhile, so the host never blocks on a full pipe.
            unsafe { ClosePseudoConsole(self.handle) };
        }
        self.input.take();
    }
}

impl Drop for Console {
    fn drop(&mut self) {
        self.close();
        let Some(reader) = self.reader.take() else {
            return;
        };
        let deadline = Instant::now() + CLEANUP_TIMEOUT;
        while !reader.is_finished() {
            if Instant::now() >= deadline {
                // SAFETY: the thread is live or has just ended (its handle
                // stays valid while the JoinHandle is held); with no read
                // pending this cancels nothing.
                unsafe { CancelSynchronousIo(reader.as_raw_handle()) };
                if Instant::now() >= deadline + CLEANUP_TIMEOUT {
                    // Detached: it ends with its pipe; nothing is waited for.
                    return;
                }
            }
            // Anything still arriving is wiped as it is dropped.
            let _ = self.output.recv_timeout(POLL);
        }
        let _ = reader.join();
    }
}

/// An anonymous pipe whose ends are not inherited; `size` 0 is the default.
fn pipe(size: u32) -> io::Result<(Handle, Handle)> {
    let (mut read, mut write) = (null_mut(), null_mut());
    // SAFETY: live out values; no security attributes, so nothing inherits.
    bool_result(unsafe { CreatePipe(&mut read, &mut write, std::ptr::null(), size) })?;
    Ok((Handle::new(read)?, Handle::new(write)?))
}

#[cfg(test)]
mod tests {
    use super::{Exchange, admissible};
    use crate::process::pty_exchange::Zeroing;
    use crate::process::{PtyError, PtyInteraction};

    fn interaction(prompt: &str, secret: &[u8]) -> PtyInteraction {
        PtyInteraction {
            expected_prompt: prompt.as_bytes().to_vec(),
            secret: secret.to_vec(),
        }
    }

    #[test]
    fn a_console_secret_is_utf8_text_without_controls() {
        let ok = |secret: &[u8]| admissible(&[interaction("Prompt:", secret)], 4096);
        assert!(ok(b"fixture"));
        assert!(ok("p\u{e4}ss\u{20ac}wort".as_bytes()));
        for refused in [
            &b"with\x03ctrl-c"[..],
            b"with\x1bescape",
            b"with\x7fdelete",
            b"with\x08backspace",
            b"with\ttab",
            b"not\xffutf8",
        ] {
            assert!(!ok(refused), "{refused:?}");
        }
    }

    #[test]
    fn prompts_become_due_in_order_and_out_of_order_refuses_them_all() {
        let interactions = [
            interaction("First:", b"fixture-one"),
            interaction("Second:", b"fixture-two"),
        ];
        let mut exchange = Exchange {
            interactions: &interactions,
            budget: 4096,
            output: Zeroing(Vec::new()),
            completed: 0,
        };
        assert_eq!(exchange.observe(b"\x1b[?25lFir").unwrap(), 0..0);
        assert_eq!(exchange.observe(b"st:").unwrap(), 0..1);
        assert_eq!(exchange.observe(b"\r\nSecond:").unwrap(), 1..2);
        assert!(matches!(
            exchange.observe(b"Second:"),
            Err(PtyError::PromptProtocolViolation)
        ));

        let mut skipped = Exchange {
            interactions: &interactions,
            budget: 4096,
            output: Zeroing(Vec::new()),
            completed: 0,
        };
        assert!(matches!(
            skipped.observe(b"Second:"),
            Err(PtyError::PromptProtocolViolation)
        ));
        assert_eq!(skipped.completed, 0);
    }
}
