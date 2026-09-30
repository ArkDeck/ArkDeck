//! The Windows counterpart of `terminal_secret.rs` (TASK-XPA-011, gate
//! inventory G13): bounded password input from the console without echo,
//! with the same errors, bound and exit codes as the macOS TTY reader.
//!
//! - Standard input must be a console input buffer (`GetConsoleMode`
//!   succeeds); redirected input is refused before any prompt, as macOS
//!   refuses without a TTY.
//! - The reader clears `ENABLE_ECHO_INPUT` and `ENABLE_LINE_INPUT`, so that
//!   no character is echoed and no line reaches the console's command
//!   history, and reads UTF-16 units with `ReadConsoleW`, converting to
//!   UTF-8 in a wiped fixed buffer. Backspace erases, as the macOS
//!   canonical-mode line discipline does. Unlike macOS, the prompt is written
//!   after echo is off, so it also marks the moment input becomes hidden.
//! - The original mode is restored on every return path by a guard, and on
//!   Ctrl-C, Ctrl-Break, console close, logoff and shutdown by a console
//!   control handler that restores it before the default handler ends the
//!   process; if the process survives the event, the entry ends as
//!   interrupted and nothing read is used. Only one entry runs at a time in
//!   a process.
//! - A refused entry (a control character, an unpaired surrogate or more than
//!   1024 bytes) is still read to its Enter, so that the rest of what was
//!   typed never reaches the next reader of the console.
use crate::{Secret, wipe};
use std::ffi::c_void;
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, Ordering};
use windows_sys::Win32::Foundation::{FALSE, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Console::{
    CONSOLE_MODE, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, GetConsoleMode, GetStdHandle, ReadConsoleW,
    STD_INPUT_HANDLE, SetConsoleCtrlHandler, SetConsoleMode,
};

const MAX_SECRET_BYTES: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct TerminalSecretError {
    pub exit_code: u8,
    pub message: &'static str,
}
fn error(exit_code: u8, message: &'static str) -> TerminalSecretError {
    TerminalSecretError { exit_code, message }
}

pub fn read_terminal_secret(prompt: &str) -> Result<Secret, TerminalSecretError> {
    // SAFETY: no preconditions; the handle is borrowed, never closed here.
    let input = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
    read_secret(input, prompt, &mut io::stderr().lock())
}

/// Set while one entry holds the console; the control handler reads the
/// armed handle and the mode to restore.
static BUSY: AtomicBool = AtomicBool::new(false);
static ARMED: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static ORIGINAL: AtomicU32 = AtomicU32::new(0);

/// Restores the armed console's mode and lets the next handler (by default
/// `ExitProcess`) run.
unsafe extern "system" fn restore_on_control(_event: u32) -> windows_sys::core::BOOL {
    let input = ARMED.swap(std::ptr::null_mut(), Ordering::AcqRel);
    if !input.is_null() {
        // SAFETY: the handle stays open while armed; the mode was stored
        // before the handle was published.
        unsafe { SetConsoleMode(input, ORIGINAL.load(Ordering::Acquire)) };
    }
    FALSE
}

struct Restore<'a> {
    input: HANDLE,
    original: CONSOLE_MODE,
    output: &'a mut dyn Write,
}

impl<'a> Restore<'a> {
    fn arm(
        input: HANDLE,
        original: CONSOLE_MODE,
        output: &'a mut dyn Write,
    ) -> Result<Self, TerminalSecretError> {
        if BUSY
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(error(1, "another signing password entry is in progress"));
        }
        ORIGINAL.store(original, Ordering::Release);
        // SAFETY: a static handler function that stays valid for the process.
        if unsafe { SetConsoleCtrlHandler(Some(restore_on_control), 1) } == 0 {
            BUSY.store(false, Ordering::Release);
            return Err(error(1, "could not guard the console mode"));
        }
        ARMED.store(input, Ordering::Release);
        // From here the guard restores and unregisters on every path.
        let restore = Self {
            input,
            original,
            output,
        };
        let hidden = original & !(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT);
        // SAFETY: a console input handle that GetConsoleMode accepted.
        if unsafe { SetConsoleMode(input, hidden) } == 0 {
            return Err(error(1, "could not disable terminal echo"));
        }
        Ok(restore)
    }
}

impl Drop for Restore<'_> {
    fn drop(&mut self) {
        ARMED.store(std::ptr::null_mut(), Ordering::Release);
        // SAFETY: the borrowed console handle outlives the guard.
        unsafe {
            SetConsoleMode(self.input, self.original);
            SetConsoleCtrlHandler(Some(restore_on_control), 0);
        }
        BUSY.store(false, Ordering::Release);
        let _ = self.output.write_all(b"\n");
        let _ = self.output.flush();
    }
}

/// The accepted UTF-8 bytes and the pending UTF-16 unit, wiped when dropped.
struct Input {
    bytes: [u8; MAX_SECRET_BYTES],
    count: usize,
    unit: u16,
}

impl Drop for Input {
    fn drop(&mut self) {
        wipe(&mut self.bytes);
        // SAFETY: an exclusive reference to a live field.
        unsafe { std::ptr::write_volatile(&mut self.unit, 0) };
    }
}

impl Input {
    fn push(&mut self, character: char) -> bool {
        let length = character.len_utf8();
        if self.count + length > MAX_SECRET_BYTES {
            return false;
        }
        character.encode_utf8(&mut self.bytes[self.count..self.count + length]);
        self.count += length;
        true
    }

    fn erase(&mut self) {
        while self.count > 0 {
            self.count -= 1;
            let byte = std::mem::take(&mut self.bytes[self.count]);
            if byte & 0xC0 != 0x80 {
                break;
            }
        }
    }
}

fn read_secret(
    input: HANDLE,
    prompt: &str,
    output: &mut dyn Write,
) -> Result<Secret, TerminalSecretError> {
    let mut original: CONSOLE_MODE = 0;
    // SAFETY: GetConsoleMode fails for any handle that is not a console
    // buffer, including null and invalid ones.
    if input.is_null()
        || input == INVALID_HANDLE_VALUE
        || unsafe { GetConsoleMode(input, &mut original) } == 0
    {
        return Err(error(64, "signing passwords require an interactive TTY"));
    }
    let restore = Restore::arm(input, original, output)?;
    restore
        .output
        .write_all(prompt.as_bytes())
        .and_then(|()| restore.output.flush())
        .map_err(|_| error(1, "could not write signing password prompt"))?;
    let mut entry = Input {
        bytes: [0; MAX_SECRET_BYTES],
        count: 0,
        unit: 0,
    };
    let mut high_surrogate = None;
    let mut refusal = None;
    loop {
        let mut read = 0u32;
        // SAFETY: one writable UTF-16 unit and a live count.
        let ok = unsafe {
            ReadConsoleW(
                input,
                (&raw mut entry.unit).cast(),
                1,
                &mut read,
                std::ptr::null(),
            )
        };
        if ok == 0 {
            return Err(error(1, "could not read signing password"));
        }
        // A console read in this mode never ends without a unit; zero units,
        // or a control handler that has already restored the mode, mean the
        // entry was interrupted, and nothing read so far is used.
        if read == 0 || ARMED.load(Ordering::Acquire).is_null() {
            return Err(error(1, "signing password entry was interrupted"));
        }
        let unit = std::mem::take(&mut entry.unit);
        if refusal.is_some() {
            // Drain the refused entry up to its Enter.
            if matches!(unit, 0x0D | 0x0A) {
                break;
            }
            continue;
        }
        let character = match (high_surrogate.take(), unit) {
            (None, 0xD800..=0xDBFF) => {
                high_surrogate = Some(unit);
                continue;
            }
            (Some(high), 0xDC00..=0xDFFF) => char::decode_utf16([high, unit]).next(),
            (None, _) => char::decode_utf16([unit]).next(),
            (Some(_), _) => None,
        };
        let Some(Ok(character)) = character else {
            refusal = Some(error(64, "signing password contains control bytes"));
            continue;
        };
        match character {
            '\r' | '\n' => break,
            '\u{8}' | '\u{7f}' => entry.erase(),
            character if (character as u32) < 32 => {
                refusal = Some(error(64, "signing password contains control bytes"));
            }
            character => {
                if !entry.push(character) {
                    refusal = Some(error(64, "signing password is empty or too long"));
                }
            }
        }
    }
    if high_surrogate.is_some() {
        refusal.get_or_insert(error(64, "signing password contains control bytes"));
    }
    if let Some(refusal) = refusal {
        return Err(refusal);
    }
    if entry.count == 0 {
        return Err(error(64, "signing password is empty or too long"));
    }
    let secret = Secret::from_slice(&entry.bytes[..entry.count]);
    drop(restore);
    Ok(secret)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::windows::io::AsRawHandle;

    #[test]
    fn redirected_input_is_refused_without_reading_or_prompting() {
        let file = std::fs::File::open("NUL").unwrap();
        let mut output = Vec::new();
        assert_eq!(
            read_secret(file.as_raw_handle(), "fixture prompt", &mut output).unwrap_err(),
            error(64, "signing passwords require an interactive TTY")
        );
        for handle in [std::ptr::null_mut(), INVALID_HANDLE_VALUE] {
            assert_eq!(
                read_secret(handle, "fixture prompt", &mut output)
                    .unwrap_err()
                    .exit_code,
                64
            );
        }
        assert!(output.is_empty());
        assert!(!BUSY.load(Ordering::Acquire));
    }

    #[test]
    fn erase_removes_one_whole_character() {
        let mut entry = Input {
            bytes: [0; MAX_SECRET_BYTES],
            count: 0,
            unit: 0,
        };
        for character in "aé€😀".chars() {
            assert!(entry.push(character));
        }
        entry.erase();
        assert_eq!(&entry.bytes[..entry.count], "aé€".as_bytes());
        entry.erase();
        entry.erase();
        assert_eq!(&entry.bytes[..entry.count], b"a");
        assert!(entry.bytes[1..].iter().all(|byte| *byte == 0));
        entry.erase();
        entry.erase();
        assert_eq!(entry.count, 0);
    }

    #[test]
    fn the_bound_is_utf8_bytes() {
        let mut entry = Input {
            bytes: [0; MAX_SECRET_BYTES],
            count: 0,
            unit: 0,
        };
        for _ in 0..MAX_SECRET_BYTES - 1 {
            assert!(entry.push('x'));
        }
        assert!(!entry.push('é'));
        assert!(entry.push('x'));
        assert!(!entry.push('x'));
    }
}
