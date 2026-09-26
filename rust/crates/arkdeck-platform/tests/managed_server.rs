//! `ManagedServer` (SPK-6, TASK-XPA-016): a launched process kept without a
//! budget, its launch recorded from the kernel, its streams captured, ended
//! by its owner or on its own. Every child is a shell script under a scratch
//! directory. Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{ManagedServer, ServerExit, VerifiedTool};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-managed-{name}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path.canonicalize().unwrap())
    }

    fn tool(&self, body: &str) -> VerifiedTool {
        let path = self.0.join("tool");
        let bytes = format!("#!/bin/sh\n{body}\n");
        std::fs::write(&path, &bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        VerifiedTool::open(path, &format!("{:x}", Sha256::digest(bytes.as_bytes()))).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

/// A script's own word that it has written what the test reads back: under
/// load `/bin/sh` may take longer to start than any fixed wait, so the test
/// waits for the fact, not the clock.
fn wait_for(marker: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !marker.exists() {
        assert!(
            Instant::now() < deadline,
            "the server never reached {}",
            marker.display()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_launched_server_is_recorded_kept_and_stopped_with_its_output() {
    let scratch = Scratch::new("kept");
    let marker = scratch.0.join("written");
    let tool = scratch.tool(&format!(
        r#"printf 'started %s\n' "$1"; printf 'noted\n' >&2; : > '{}'; sleep 600"#,
        marker.display()
    ));
    let mut server = ManagedServer::launch(&tool, &args(&["x"]), &[], 4096).unwrap();
    let launch = server.launch_record().clone();
    assert!(launch.pid > 0);
    assert!(launch.start_seconds > 0);
    assert!(launch.start_microseconds < 1_000_000);
    assert_eq!(launch.executable_path, scratch.0.join("tool"));
    assert_eq!(launch.executable_sha256, tool.sha256());
    assert_eq!(launch.arguments, args(&["x"]));
    assert!(server.same_birth());
    wait_for(&marker);
    assert_eq!(server.exit().unwrap(), None);
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.stdout, b"started x\n");
    assert_eq!(stopped.stderr, b"noted\n");
    assert!(!stopped.truncated);
    assert!(
        matches!(stopped.exit, ServerExit::Signalled(signal) if signal == libc::SIGTERM || signal == libc::SIGKILL),
        "{:?}",
        stopped.exit
    );
    // The launch's PID no longer carries its birth once the process is gone.
    assert!(!process_alive(launch.pid));
}

#[test]
fn a_server_that_ends_on_its_own_reports_its_exit_once() {
    let scratch = Scratch::new("ended");
    let tool = scratch.tool("printf 'bye'; exit 7");
    let mut server = ManagedServer::launch(&tool, &[], &[], 4096).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let exit = loop {
        if let Some(exit) = server.exit().unwrap() {
            break exit;
        }
        assert!(Instant::now() < deadline, "the server never ended");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(exit, ServerExit::Exited(7));
    assert_eq!(server.exit().unwrap(), Some(exit));
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.exit, ServerExit::Exited(7));
    assert_eq!(stopped.stdout, b"bye");
}

#[test]
fn output_past_the_capture_is_kept_to_the_limit_and_noted() {
    let scratch = Scratch::new("capture");
    let marker = scratch.0.join("written");
    let tool = scratch.tool(&format!(
        "head -c 8192 /dev/zero | tr '\\0' a; : > '{}'; sleep 600",
        marker.display()
    ));
    let mut server = ManagedServer::launch(&tool, &[], &[], 1024).unwrap();
    wait_for(&marker);
    assert_eq!(server.exit().unwrap(), None);
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.stdout.len(), 1024);
    assert!(stopped.truncated);
}

#[test]
fn a_refused_environment_or_capture_launches_nothing() {
    let scratch = Scratch::new("refused");
    let witness = scratch.0.join("ran");
    let tool = scratch.tool(&format!("printf ran > '{}'; sleep 600", witness.display()));
    let path = [(OsString::from("PATH"), OsString::from("/nowhere"))];
    assert!(ManagedServer::launch(&tool, &[], &path, 4096).is_err());
    assert!(ManagedServer::launch(&tool, &[], &[], 0).is_err());
    std::thread::sleep(Duration::from_millis(200));
    assert!(!witness.exists());
}

/// A paired server (Swift's `IdentityBoundDaemonLauncher`, which launches
/// `arkforged`) its owner drops without stopping it is ended as its stop ends
/// it, as Swift's `DaemonLifecycle` stops its generation when it is released:
/// its end of input first, then TERM to its group, and KILL only once TERM's
/// half second has passed; then it is reaped, its group with it. This stand-in
/// ignores TERM and outlives its end of input, noting it: only that order lets
/// it note the end, and only KILL ends it.
#[test]
fn a_dropped_paired_server_gets_its_end_of_input_then_term_then_kill() {
    let scratch = Scratch::new("paired-drop");
    let (secret, ended) = (scratch.0.join("secret"), scratch.0.join("input-ended"));
    let tool = scratch.tool(&format!(
        "trap '' TERM\nhead -c 32 > '{}'\ncat > /dev/null\n: > '{}'\nwhile :; do sleep 1; done",
        secret.display(),
        ended.display()
    ));
    let server = ManagedServer::launch_paired(&tool, &[], &[], &scratch.0, &[7; 32], 4096).unwrap();
    let pid = server.launch_record().pid;
    wait_for_bytes(&secret, 32);
    let started = Instant::now();
    drop(server);
    let took = started.elapsed();
    assert!(
        ended.exists(),
        "its end of input never reached it: its group was killed first"
    );
    assert!(
        took >= Duration::from_millis(500),
        "the drop ended {took:?} after it began, within TERM's grace: KILL came early"
    );
    assert_group_gone(pid);
}

/// The same drop sends TERM before any KILL: a stand-in that ends on TERM,
/// noting it, is ended by it. It catches TERM itself, as a daemon may: it
/// starts with TERM ignored (the next case), which `/bin/sh` cannot undo, so
/// the stand-in is Perl. Perl runs a handler between its operations, so the
/// stand-in waits in short steps: a TERM that lands just before a long
/// sleep would wait for that sleep to end.
#[test]
fn a_dropped_paired_server_is_sent_term_before_kill() {
    let scratch = Scratch::new("paired-term");
    let (secret, termed) = (scratch.0.join("secret"), scratch.0.join("term"));
    let tool = scratch.tool(&format!(
        "exec /usr/bin/perl -e '$SIG{{TERM}} = sub {{ open(my $f, \">\", $ARGV[0]); exit 21 }}; \
         read(STDIN, my $s, 32); open(my $o, \">\", $ARGV[1]); print $o $s; close($o); \
         1 while <STDIN>; select(undef, undef, undef, 0.01) while 1' '{}' '{}'",
        termed.display(),
        secret.display()
    ));
    let server = ManagedServer::launch_paired(&tool, &[], &[], &scratch.0, &[7; 32], 4096).unwrap();
    let pid = server.launch_record().pid;
    wait_for_bytes(&secret, 32);
    drop(server);
    assert!(
        termed.exists(),
        "TERM never reached it before it was killed"
    );
    assert_group_gone(pid);
}

/// Swift's daemon ignores SIGINT and SIGTERM before it starts any child
/// (`main.swift` 377-378) and its launcher resets no disposition, so the
/// `arkforged` it pairs starts with both ignored: TERM to its group, the
/// second step of its stop, does nothing, and its end of input ends it. A
/// paired server starts so, as the kernel's record of it shows and as it
/// meets both signals, with this thread's signal mask and no descriptor
/// but its three; this process keeps its own handling of both, and a
/// server launched unpaired ignores only what this process ignores.
#[test]
fn a_paired_server_starts_with_sigint_and_sigterm_ignored_and_ends_at_its_end_of_input() {
    let scratch = Scratch::new("paired-ignoring");
    let [secret, mask, ready, leaked] =
        ["secret", "mask", "ready", "leaked"].map(|name| scratch.0.join(name));
    // A descriptor this process leaves open across `exec`, which the server
    // must not receive.
    // SAFETY: opens /dev/null for reading, without close-on-exec on purpose.
    let open = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY) };
    assert!(open > 2);
    // The shell hands over to Perl, which reports its mask and then reads
    // its input to the end.
    let tool = scratch.tool(&format!(
        "head -c 32 > '{}'\nif [ -e /dev/fd/{open} ]; then : > '{}'; fi\n\
         exec /usr/bin/perl -e 'use POSIX (); my $m = POSIX::SigSet->new; \
         POSIX::sigprocmask(POSIX::SIG_BLOCK(), undef, $m); open(my $f, \">\", $ARGV[0]); \
         print $f join(\",\", grep {{ $m->ismember($_) }} 1..31); close($f); \
         open(my $r, \">\", $ARGV[1]); close($r); 1 while <STDIN>; exit 0' '{}' '{}'",
        secret.display(),
        leaked.display(),
        mask.display(),
        ready.display()
    ));
    let own = [disposition(libc::SIGINT), disposition(libc::SIGTERM)];
    let server = ManagedServer::launch_paired(&tool, &[], &[], &scratch.0, &[7; 32], 4096).unwrap();
    // SAFETY: closes the descriptor opened above, which nothing else owns.
    unsafe { libc::close(open) };
    assert_eq!([disposition(libc::SIGINT), disposition(libc::SIGTERM)], own);
    let pid = server.launch_record().pid;
    assert_eq!(ignored(pid), [true, true]);
    wait_for(&ready);
    for signal in [libc::SIGINT, libc::SIGTERM] {
        // SAFETY: signals only this test's own server's process group.
        assert_eq!(unsafe { libc::kill(-pid, signal) }, 0);
    }
    assert_eq!(server.stop().unwrap().exit, ServerExit::Exited(0));
    assert_eq!(std::fs::read_to_string(&mask).unwrap(), blocked_here());
    assert!(
        !leaked.exists(),
        "a descriptor this process leaves open reached the server"
    );
    assert_group_gone(pid);

    // Unpaired, a server ignores only what this process ignores, as it would
    // inherit it: nothing, unless this test itself was started so.
    let scratch = Scratch::new("unpaired-inherited");
    let tool = scratch.tool("exec /bin/sleep 600");
    let server = ManagedServer::launch(&tool, &[], &[], 4096).unwrap();
    assert_eq!(
        ignored(server.launch_record().pid),
        own.map(|handler| handler == libc::SIG_IGN)
    );
    server.stop().unwrap();
}

/// The signals this thread blocks, as Perl lists its own: their numbers
/// from 1 to 31, joined by commas.
fn blocked_here() -> String {
    // SAFETY: zero is a valid sigset to receive this thread's mask into.
    let mut mask: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: reads this thread's mask, and changes nothing.
    assert_eq!(
        unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, std::ptr::null(), &mut mask) },
        0
    );
    (1..32)
        // SAFETY: a valid sigset and a signal number in range.
        .filter(|&signal| unsafe { libc::sigismember(&mask, signal) } == 1)
        .map(|signal| signal.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

/// This process's own disposition of `signal`.
fn disposition(signal: libc::c_int) -> libc::sighandler_t {
    // SAFETY: zero is a valid sigaction to receive the current one into.
    let mut current: libc::sigaction = unsafe { std::mem::zeroed() };
    // SAFETY: reads, and changes nothing.
    assert_eq!(
        unsafe { libc::sigaction(signal, std::ptr::null(), &mut current) },
        0
    );
    current.sa_sigaction
}

/// Whether the kernel's record of `pid` (`struct kinfo_proc`) has SIGINT and
/// SIGTERM among the signals it ignores (`kp_proc.p_sigignore`, at byte 232
/// of the 648 the SDK declares).
fn ignored(pid: i32) -> [bool; 2] {
    let mut record = [0u8; 648];
    let mut size = record.len();
    let mut name = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
    // SAFETY: a live four-entry MIB and a writable buffer of the declared size.
    let status = unsafe {
        libc::sysctl(
            name.as_mut_ptr(),
            4,
            record.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    assert_eq!((status, size), (0, record.len()), "pid {pid} is not listed");
    let ignoring = u32::from_ne_bytes(record[232..236].try_into().unwrap());
    [libc::SIGINT, libc::SIGTERM].map(|signal| ignoring & (1 << (signal - 1)) != 0)
}

/// Waits for a stand-in to have written `bytes` to `file`: the paired
/// secret, read whole before its owner may stop it.
fn wait_for_bytes(file: &std::path::Path, bytes: u64) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::fs::metadata(file).map_or(true, |metadata| metadata.len() < bytes) {
        assert!(Instant::now() < deadline, "the secret never arrived");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The dropped server is gone and reaped, and nothing of its process group
/// runs.
fn assert_group_gone(pid: i32) {
    assert!(
        !process_alive(pid),
        "the dropped server (pid {pid}) still runs"
    );
    let group = std::process::Command::new("/usr/bin/pgrep")
        .args(["-g", &pid.to_string()])
        .output()
        .unwrap();
    assert!(
        group.stdout.is_empty(),
        "its group left: {}",
        String::from_utf8_lossy(&group.stdout)
    );
}

fn process_alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks whether the PID exists and may be signalled.
    unsafe { libc::kill(pid, 0) == 0 }
}
