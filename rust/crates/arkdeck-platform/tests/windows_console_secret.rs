//! `read_terminal_secret` on a real Windows console (TASK-XPA-011, G13): each
//! case runs this binary as a child attached to a pseudo console
//! (`CreatePseudoConsole`), types into the console's input pipe as a
//! terminal would, and reads everything the console renders.
//!
//! The child proves, from inside the console, that the reader returned what
//! was typed and restored the exact console mode; for Ctrl-C a control
//! handler registered before the entry (so it runs after the reader's own)
//! proves the mode was restored before the process ended. The parent proves
//! that nothing typed was rendered. Synchronisation is the console's own
//! output: the reader writes its prompt only once echo is off, and the
//! parent types only after it has seen the prompt.
//!
//! This is a `harness = false` target: run as `<exe> --child <case>` it is the
//! console child, otherwise the test runner.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "--child") {
        windows::child(arguments.get(2).map_or("", String::as_str));
    }
    windows::run();
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::os::windows::io::{FromRawHandle, IntoRawHandle, OwnedHandle};
    use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering};
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Console::{
        COORD, ClosePseudoConsole, CreatePseudoConsole, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT,
        ENABLE_PROCESSED_INPUT, GetConsoleMode, HPCON, STD_ERROR_HANDLE, STD_INPUT_HANDLE,
        SetConsoleCtrlHandler, SetConsoleMode, SetStdHandle,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CreateProcessW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, ExitProcess,
        GetExitCodeProcess, InitializeProcThreadAttributeList, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        PROCESS_INFORMATION, STARTUPINFOEXW, UpdateProcThreadAttribute, WaitForSingleObject,
    };

    const PROMPT: &str = "Password: ";
    const RESTORED_ON_CONTROL: u32 = 70;
    const NOT_RESTORED_ON_CONTROL: u32 = 71;
    const NOT_RESTORED: u32 = 3;
    const WRONG_SECRET: u32 = 4;
    const DEADLINE: Duration = Duration::from_secs(60);

    struct Case {
        name: &'static str,
        typed: Vec<u8>,
        /// The secret the child must receive, or the reader's exit code.
        expected: Result<&'static str, u32>,
        /// Typed text that must never be rendered.
        hidden: &'static [&'static str],
    }

    fn cases() -> Vec<Case> {
        vec![
            Case {
                name: "plain",
                typed: b"fixture-password\r".to_vec(),
                expected: Ok("fixture-password"),
                hidden: &["fixture-password", "fixture"],
            },
            Case {
                name: "unicode",
                typed: "p\u{e4}ss\u{20ac}\u{1f600}wort\r".as_bytes().to_vec(),
                expected: Ok("p\u{e4}ss\u{20ac}\u{1f600}wort"),
                hidden: &["wort", "\u{20ac}"],
            },
            Case {
                name: "erase",
                typed: b"fixture-passwordXY\x7f\x08\r".to_vec(),
                expected: Ok("fixture-password"),
                hidden: &["fixture", "XY"],
            },
            Case {
                name: "empty",
                typed: b"\r".to_vec(),
                expected: Err(64),
                hidden: &[],
            },
            Case {
                name: "overlong",
                typed: [vec![b'x'; 1025], b"\r".to_vec()].concat(),
                expected: Err(64),
                hidden: &["xxxxxxxx"],
            },
            Case {
                name: "control",
                typed: b"abcdef\x01ghijkl\r".to_vec(),
                expected: Err(64),
                hidden: &["abcdef", "ghijkl"],
            },
            Case {
                name: "ctrl-c",
                typed: b"fixture\x03".to_vec(),
                expected: Err(RESTORED_ON_CONTROL),
                hidden: &["fixture"],
            },
        ]
    }

    // ---- the console child ------------------------------------------------

    static CONSOLE_INPUT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static MODE_BEFORE: AtomicU32 = AtomicU32::new(0);

    fn console_mode(input: HANDLE) -> u32 {
        let mut mode = 0;
        // SAFETY: a live console input handle and a live out value.
        assert_ne!(unsafe { GetConsoleMode(input, &mut mode) }, 0);
        mode
    }

    /// Runs after the reader's own control handler, which returns FALSE.
    unsafe extern "system" fn check_restored(_event: u32) -> windows_sys::core::BOOL {
        let input = CONSOLE_INPUT.load(Ordering::Acquire);
        let mut mode = 0;
        // SAFETY: the console input handle stays open for the process.
        let read = unsafe { GetConsoleMode(input, &mut mode) } != 0;
        let code = if read && mode == MODE_BEFORE.load(Ordering::Acquire) {
            RESTORED_ON_CONTROL
        } else {
            NOT_RESTORED_ON_CONTROL
        };
        // SAFETY: ends this child process.
        unsafe { ExitProcess(code) }
    }

    pub fn child(name: &str) -> ! {
        let case = cases()
            .into_iter()
            .find(|case| case.name == name)
            .expect("known case");
        let open = |path| {
            OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)
                .expect("console handle")
                .into_raw_handle()
        };
        let (input, output) = (open("CONIN$"), open("CONOUT$"));
        // SAFETY: the console's own handles, kept open for the process; Ctrl-C
        // processing is re-enabled in case it was inherited as ignored.
        unsafe {
            assert_ne!(SetStdHandle(STD_INPUT_HANDLE, input), 0);
            assert_ne!(SetStdHandle(STD_ERROR_HANDLE, output), 0);
            assert_ne!(SetConsoleCtrlHandler(None, 0), 0);
            // The ordinary cooked mode, so the reader has echo to suppress.
            let mode = console_mode(input)
                | ENABLE_ECHO_INPUT
                | ENABLE_LINE_INPUT
                | ENABLE_PROCESSED_INPUT;
            assert_ne!(SetConsoleMode(input, mode), 0);
        }
        let before = console_mode(input);
        CONSOLE_INPUT.store(input, Ordering::Release);
        MODE_BEFORE.store(before, Ordering::Release);
        if name == "ctrl-c" {
            // SAFETY: a static handler registered before the reader's.
            assert_ne!(unsafe { SetConsoleCtrlHandler(Some(check_restored), 1) }, 0);
        }
        let answer = arkdeck_platform::read_terminal_secret(PROMPT);
        let code = if console_mode(input) != before {
            NOT_RESTORED
        } else {
            match (answer, case.expected) {
                (Ok(secret), Ok(expected)) if secret.as_bytes() == expected.as_bytes() => 0,
                (Ok(_), _) => WRONG_SECRET,
                (Err(error), _) => u32::from(error.exit_code),
            }
        };
        std::process::exit(code as i32)
    }

    // ---- the terminal ---------------------------------------------------

    struct Rendered {
        bytes: Mutex<Vec<u8>>,
        changed: Condvar,
    }

    fn pipe() -> (OwnedHandle, OwnedHandle) {
        let (mut read, mut write) = (std::ptr::null_mut(), std::ptr::null_mut());
        // SAFETY: live out values; no inheritance.
        assert_ne!(
            unsafe { CreatePipe(&mut read, &mut write, std::ptr::null(), 0) },
            0
        );
        // SAFETY: two new handles owned from here on.
        unsafe {
            (
                OwnedHandle::from_raw_handle(read),
                OwnedHandle::from_raw_handle(write),
            )
        }
    }

    fn run_case(case: &Case) -> (u32, String) {
        use std::os::windows::io::AsRawHandle;
        let (input_read, input_write) = pipe();
        let (output_read, output_write) = pipe();
        let mut console: HPCON = 0;
        // SAFETY: live pipe ends and out value.
        let status = unsafe {
            CreatePseudoConsole(
                COORD { X: 200, Y: 50 },
                input_read.as_raw_handle(),
                output_write.as_raw_handle(),
                0,
                &mut console,
            )
        };
        assert_eq!(status, 0, "CreatePseudoConsole");

        let rendered = Arc::new(Rendered {
            bytes: Mutex::new(Vec::new()),
            changed: Condvar::new(),
        });
        let reader = {
            let rendered = Arc::clone(&rendered);
            let mut output = File::from(output_read);
            std::thread::spawn(move || {
                let mut buffer = [0u8; 4096];
                while let Ok(count @ 1..) = output.read(&mut buffer) {
                    rendered
                        .bytes
                        .lock()
                        .unwrap()
                        .extend_from_slice(&buffer[..count]);
                    rendered.changed.notify_all();
                }
            })
        };

        let mut size = 0usize;
        // SAFETY: the documented size query; it fails with the size set.
        unsafe { InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size) };
        let mut list = vec![0usize; size.div_ceil(size_of::<usize>())];
        let attributes = list.as_mut_ptr().cast::<c_void>();
        // SAFETY: a buffer of the queried size; the pseudo console handle
        // value is passed as the attribute, as documented.
        unsafe {
            assert_ne!(
                InitializeProcThreadAttributeList(attributes, 1, 0, &mut size),
                0
            );
            assert_ne!(
                UpdateProcThreadAttribute(
                    attributes,
                    0,
                    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                    console as *const c_void,
                    size_of::<HPCON>(),
                    std::ptr::null_mut(),
                    std::ptr::null(),
                ),
                0
            );
        }
        let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.lpAttributeList = attributes;
        let executable = std::env::current_exe().unwrap();
        let mut command: Vec<u16> = format!("\"{}\" --child {}", executable.display(), case.name)
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: every pointer is live for the call; no handle is inherited.
        let created = unsafe {
            CreateProcessW(
                std::ptr::null(),
                command.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                EXTENDED_STARTUPINFO_PRESENT,
                std::ptr::null(),
                std::ptr::null(),
                &startup.StartupInfo,
                &mut process,
            )
        };
        assert_ne!(created, 0, "CreateProcessW");
        // SAFETY: the new process and thread handles are owned from here on.
        let (child, _thread) = unsafe {
            (
                OwnedHandle::from_raw_handle(process.hProcess),
                OwnedHandle::from_raw_handle(process.hThread),
            )
        };
        // The console holds its own copies of these ends.
        drop(input_read);
        drop(output_write);

        // Type only once the prompt, written after echo is off, is rendered.
        {
            let deadline = Instant::now() + DEADLINE;
            let mut bytes = rendered.bytes.lock().unwrap();
            while !String::from_utf8_lossy(&bytes).contains(PROMPT.trim_end()) {
                let left = deadline
                    .checked_duration_since(Instant::now())
                    .unwrap_or_else(|| panic!("{}: no prompt was rendered", case.name));
                bytes = rendered.changed.wait_timeout(bytes, left).unwrap().0;
            }
        }
        let mut input = File::from(input_write);
        input.write_all(&case.typed).unwrap();
        input.flush().unwrap();

        // SAFETY: a live process handle.
        let waited =
            unsafe { WaitForSingleObject(child.as_raw_handle(), DEADLINE.as_millis() as u32) };
        assert_eq!(waited, WAIT_OBJECT_0, "{}: child did not end", case.name);
        let mut code = 0;
        // SAFETY: a live process handle and out value.
        assert_ne!(
            unsafe { GetExitCodeProcess(child.as_raw_handle(), &mut code) },
            0
        );
        // Closing the console ends its output; the reader then sees EOF.
        // SAFETY: the console is closed exactly once; the attribute list is
        // deleted after the process that used it has ended.
        unsafe {
            ClosePseudoConsole(console);
            DeleteProcThreadAttributeList(attributes);
        }
        drop(input);
        reader.join().unwrap();
        let rendered = String::from_utf8_lossy(&rendered.bytes.lock().unwrap()).into_owned();
        (code, rendered)
    }

    pub fn run() -> ! {
        let mut failures = 0;
        for case in cases() {
            let (code, rendered) = run_case(&case);
            let expected = match case.expected {
                Ok(_) => 0,
                Err(code) => code,
            };
            let leaked: Vec<_> = case
                .hidden
                .iter()
                .filter(|text| rendered.contains(**text))
                .collect();
            if code == expected && leaked.is_empty() {
                println!("test {} ... ok", case.name);
            } else {
                failures += 1;
                println!(
                    "test {} ... FAILED (exit {code}, expected {expected}, rendered typed text {leaked:?})",
                    case.name
                );
            }
        }
        let passed = cases().len() - failures;
        let verdict = if failures == 0 { "ok" } else { "FAILED" };
        println!("test result: {verdict}. {passed} passed; {failures} failed");
        std::process::exit(if failures == 0 { 0 } else { 1 })
    }
}
