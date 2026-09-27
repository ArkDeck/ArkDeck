//! Swift CLI `readTTYSecret`: bounded password input with echo disabled and
//! terminal attributes restored on every ordinary return path.
use crate::{Secret, wipe};
use std::{
    io::{self, Write},
    os::fd::{AsFd, AsRawFd, BorrowedFd},
};

#[derive(Debug, PartialEq, Eq)]
pub struct TerminalSecretError {
    pub exit_code: u8,
    pub message: &'static str,
}
fn error(exit_code: u8, message: &'static str) -> TerminalSecretError {
    TerminalSecretError { exit_code, message }
}

pub fn read_terminal_secret(prompt: &str) -> Result<Secret, TerminalSecretError> {
    let stdin = io::stdin();
    read_secret(stdin.as_fd(), prompt, &mut io::stderr().lock())
}

fn read_secret(
    fd: BorrowedFd<'_>,
    prompt: &str,
    output: &mut dyn Write,
) -> Result<Secret, TerminalSecretError> {
    // SAFETY: fd remains borrowed/live for the whole transaction.
    if unsafe { libc::isatty(fd.as_raw_fd()) } != 1 {
        return Err(error(64, "signing passwords require an interactive TTY"));
    }
    output
        .write_all(prompt.as_bytes())
        .map_err(|_| error(1, "could not write signing password prompt"))?;
    // SAFETY: initialized storage for tcgetattr to fill.
    let mut original: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd.as_raw_fd(), &mut original) } != 0 {
        return Err(error(1, "could not read terminal attributes"));
    }
    let mut hidden = original;
    hidden.c_lflag &= !libc::ECHO;
    // SAFETY: fd and termios are valid throughout this call.
    if unsafe { libc::tcsetattr(fd.as_raw_fd(), libc::TCSAFLUSH, &hidden) } != 0 {
        return Err(error(1, "could not disable terminal echo"));
    }
    struct Restore<'a> {
        fd: BorrowedFd<'a>,
        original: libc::termios,
        output: &'a mut dyn Write,
    }
    impl Drop for Restore<'_> {
        fn drop(&mut self) {
            // SAFETY: the borrowed descriptor outlives the guard.
            unsafe { libc::tcsetattr(self.fd.as_raw_fd(), libc::TCSAFLUSH, &self.original) };
            let _ = self.output.write_all(b"\n");
        }
    }
    let _restore = Restore {
        fd,
        original,
        output,
    };
    struct Input([u8; 1025]);
    impl Drop for Input {
        fn drop(&mut self) {
            wipe(&mut self.0);
        }
    }
    let mut input = Input([0; 1025]);
    let mut count = 0;
    while count <= 1024 {
        // SAFETY: one writable byte inside the fixed bounded buffer.
        let read = unsafe { libc::read(fd.as_raw_fd(), input.0[count..].as_mut_ptr().cast(), 1) };
        if read == 0 {
            break;
        }
        if read < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error(1, "could not read signing password"));
        }
        let byte = input.0[count];
        if matches!(byte, b'\n' | b'\r') {
            break;
        }
        if byte < 32 || byte == 127 {
            return Err(error(64, "signing password contains control bytes"));
        }
        count += 1;
    }
    if count == 0 || count > 1024 {
        return Err(error(64, "signing password is empty or too long"));
    }
    Ok(Secret::from_slice(&input.0[..count]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs::File,
        os::fd::{FromRawFd, OwnedFd},
        thread,
        time::{Duration, Instant},
    };
    #[test]
    fn redirected_input_is_refused_without_reading_or_prompting() {
        let file = File::open("/dev/null").unwrap();
        let mut output = Vec::new();
        assert_eq!(
            read_secret(file.as_fd(), "fixture prompt", &mut output).unwrap_err(),
            error(64, "signing passwords require an interactive TTY")
        );
        assert!(output.is_empty());
    }
    #[test]
    fn terminal_echo_is_restored_after_success_empty_and_overlong_input() {
        for input in [
            b"fixture-password\n".to_vec(),
            b"\n".to_vec(),
            vec![b'x'; 1025].into_iter().chain(*b"\n").collect(),
        ] {
            let (mut master, mut slave) = (-1, -1);
            // SAFETY: valid output slots; optional outputs are null.
            assert_eq!(
                unsafe {
                    libc::openpty(
                        &mut master,
                        &mut slave,
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                    )
                },
                0
            );
            // SAFETY: newly owned descriptors from successful openpty.
            let (master, slave) =
                unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
            let mut original: libc::termios = unsafe { std::mem::zeroed() };
            assert_eq!(
                unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut original) },
                0
            );
            original.c_lflag |= libc::ECHO;
            // Raw input avoids terminal canonical line limits, while leaving
            // echo enabled so the production reader must suppress it.
            original.c_lflag &= !libc::ICANON;
            assert_eq!(
                unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &original) },
                0
            );
            let watched = slave.as_raw_fd();
            let child = thread::spawn(move || {
                let mut output = Vec::new();
                let answer = read_secret(slave.as_fd(), "Password: ", &mut output);
                let mut restored: libc::termios = unsafe { std::mem::zeroed() };
                assert_eq!(
                    unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut restored) },
                    0
                );
                (answer, output, restored.c_lflag)
            });
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let mut mode: libc::termios = unsafe { std::mem::zeroed() };
                assert_eq!(unsafe { libc::tcgetattr(watched, &mut mode) }, 0);
                if mode.c_lflag & libc::ECHO == 0 {
                    break;
                }
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
            let mut writer = File::from(master);
            writer.write_all(&input).unwrap();
            let (answer, output, flags) = child.join().unwrap();
            assert_eq!(flags, original.c_lflag);
            assert_eq!(output, b"Password: \n");
            if input.len() == 17 {
                assert_eq!(answer.unwrap().as_bytes(), b"fixture-password");
            } else {
                assert_eq!(answer.unwrap_err().exit_code, 64);
            }
        }
    }
}
