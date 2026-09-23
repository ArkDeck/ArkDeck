// Tearing down a test's own fake `hdc`, included by each test that compiles
// one (`mod fake_hdc_servers { include!(..) }`).
//
// A fake's `kill -r` starts the replacement server in a session of its own,
// as HDC does, so that server is nobody's child: no handle the test holds
// ends it, and once the test's directory is removed it can never see the
// marker that stops it. It then listens until the machine restarts, on a port
// of the range the tests take theirs from. The fake therefore appends the PID
// of every such server to `servers` in its directory before the command that
// started it returns, and the test's guard calls `tear_down` on drop.

use std::collections::BTreeSet;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

/// Ends every server the fake in `directory` recorded, then removes the
/// directory. `executable` is the fake's own path in that directory. A
/// failure fails the test, or is printed when the test is already failing.
pub fn tear_down(directory: &Path, executable: &Path) {
    let ended = reap(directory, executable).and_then(|()| {
        std::fs::remove_dir_all(directory)
            .map_err(|error| format!("{} stays: {error}", directory.display()))
    });
    match ended {
        Err(reason) if std::thread::panicking() => eprintln!("{reason}"),
        Err(reason) => panic!("{reason}"),
        Ok(()) => {}
    }
}

/// The command path (argv[0]) the kernel keeps for a live PID, from its
/// launch record; `None` once no process of this user has the PID. A server
/// forked but not yet executed still has its launcher's record, and every
/// launch of the fake names the fake's own path first.
fn command_path(pid: i32) -> Option<Vec<u8>> {
    let record = arkdeck_platform::process_argument_record(pid)?;
    // The argument count, the executable path and its NUL padding, argv[0].
    let rest = record.get(std::mem::size_of::<i32>()..)?;
    let rest = &rest[rest.iter().position(|byte| *byte == 0)?..];
    let rest = &rest[rest.iter().position(|byte| *byte != 0)?..];
    let end = rest.iter().position(|byte| *byte == 0).unwrap_or(rest.len());
    Some(rest[..end].to_vec())
}

/// Kills every recorded server that still runs as `executable` and returns
/// once none of them does. A recorded PID the kernel has since handed to any
/// other process is never signalled. The deadline only keeps a test from
/// hanging: a killed server ends at once.
fn reap(directory: &Path, executable: &Path) -> Result<(), String> {
    let recorded = match std::fs::read_to_string(directory.join("servers")) {
        Ok(recorded) => recorded,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("the fake's server record is unreadable: {error}")),
    };
    let pids = recorded
        .lines()
        .map(|line| {
            line.parse::<i32>()
                .ok()
                .filter(|pid| *pid > 0)
                .ok_or_else(|| format!("the fake recorded a malformed server line {line:?}"))
        })
        .collect::<Result<BTreeSet<_>, _>>()?;
    let command = executable.as_os_str().as_bytes();
    let running = || -> Vec<i32> {
        pids.iter()
            .copied()
            .filter(|pid| command_path(*pid).as_deref() == Some(command))
            .collect()
    };
    for pid in running() {
        // Checked just now to run as this test's own fake. The kernel hands
        // PIDs out in turn, so one freed since is not reissued in between.
        let _ = std::process::Command::new("/bin/kill")
            .args(["-KILL", &pid.to_string()])
            .status();
    }
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let left = running();
        if left.is_empty() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "fake HDC servers {left:?} still run as {} after SIGKILL",
                executable.display()
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
