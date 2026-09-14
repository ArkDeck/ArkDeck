//! The generic verified-tool runner (SPK-6 phase 2, TASK-XPA-016): a named
//! environment overlaid on the clean base, a child-only working directory,
//! `/dev/null` as stdin, per-stream capture with drain, the group-terminating
//! timeout and cancellation, and the receipt's duration. Spawning children,
//! these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedTool};
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-tool-{name}-{}-{}",
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
    fn directory(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir(&path).unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn limits() -> ToolLimits {
    ToolLimits {
        timeout: Duration::from_secs(10),
        capture_bytes: 1024,
    }
}

fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn env(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    pairs
        .iter()
        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
        .collect()
}

fn request<'a>(
    arguments: &'a [OsString],
    environment: &'a [(OsString, OsString)],
    working_directory: Option<&'a Path>,
) -> ToolRequest<'a> {
    ToolRequest {
        arguments,
        environment,
        working_directory,
        limits: limits(),
    }
}

#[test]
fn a_named_environment_is_overlaid_on_the_clean_base_and_nothing_else_is_inherited() {
    let scratch = Scratch::new("env");
    let tool = scratch.tool("printf '%s|%s|%s|%s' \"$FOO\" \"$PATH\" \"$LANG\" \"$ARKDECK_LEAK\"");
    // SAFETY: the test process only; the child must not see it.
    unsafe { std::env::set_var("ARKDECK_LEAK", "secret") };
    let arguments = args(&[]);
    let environment = env(&[("FOO", "bar baz")]);
    let execution = tool
        .run_tool(&request(&arguments, &environment, None), &|| false)
        .unwrap();
    assert_eq!(execution.termination, ToolTermination::Exited(0));
    assert_eq!(execution.stdout, b"bar baz|/usr/bin:/bin|C|");
    assert!(!execution.truncated);
    assert!(execution.duration > Duration::ZERO);
}

#[test]
fn the_search_path_the_loader_and_malformed_entries_are_refused_before_any_spawn() {
    let scratch = Scratch::new("badenv");
    let marker = scratch.0.join("ran");
    let tool = scratch.tool(&format!("printf x > {}; exit 0", marker.display()));
    let arguments = args(&[]);
    for pairs in [
        vec![("PATH", "/tmp")],
        vec![("DYLD_INSERT_LIBRARIES", "/tmp/x.dylib")],
        vec![("LD_PRELOAD", "/tmp/x.so")],
        vec![("LC_ALL", "en_US")],
        vec![("", "x")],
        vec![("A=B", "x")],
        vec![("A\0", "x")],
        vec![("A", "x\0y")],
    ] {
        let environment: Vec<(OsString, OsString)> = pairs
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect();
        let error = tool
            .run_tool(&request(&arguments, &environment, None), &|| false)
            .unwrap_err();
        assert!(matches!(error, ToolRunError::Refused(_)), "{pairs:?}");
    }
    assert!(!marker.exists());
}

#[test]
fn the_working_directory_binds_the_child_only_and_must_exist_canonically() {
    let scratch = Scratch::new("cwd");
    let tool = scratch.tool("pwd");
    let directory = scratch.directory("work");
    let arguments = args(&[]);
    let environment = env(&[]);
    let before = std::env::current_dir().unwrap();
    let execution = tool
        .run_tool(
            &request(&arguments, &environment, Some(&directory)),
            &|| false,
        )
        .unwrap();
    assert_eq!(
        execution.stdout,
        format!("{}\n", directory.display()).as_bytes()
    );
    assert_eq!(std::env::current_dir().unwrap(), before);
    let none = tool
        .run_tool(&request(&arguments, &environment, None), &|| false)
        .unwrap();
    assert_eq!(none.stdout, b"/\n");
    let link = scratch.0.join("link");
    std::os::unix::fs::symlink(&directory, &link).unwrap();
    for refused in [
        scratch.0.join("missing"),
        scratch.0.join("tool"),
        link,
        PathBuf::from("relative/dir"),
    ] {
        let error = tool
            .run_tool(&request(&arguments, &environment, Some(&refused)), &|| {
                false
            })
            .unwrap_err();
        assert!(
            matches!(error, ToolRunError::Refused(_)),
            "{}",
            refused.display()
        );
    }
}

#[test]
fn stdin_is_dev_null_and_each_stream_keeps_its_first_bytes_while_the_rest_drains() {
    let scratch = Scratch::new("streams");
    let tool = scratch.tool(
        "read -r line; printf 'stdin=[%s]' \"$line\"; i=0; while [ $i -lt 4000 ]; do printf 'abcdefghij'; i=$((i+1)); done; printf 'err' >&2",
    );
    let arguments = args(&[]);
    let environment = env(&[]);
    let execution = tool
        .run_tool(&request(&arguments, &environment, None), &|| false)
        .unwrap();
    assert_eq!(execution.termination, ToolTermination::Exited(0));
    assert_eq!(execution.stdout.len(), 1024);
    assert!(execution.stdout.starts_with(b"stdin=[]"));
    assert_eq!(execution.stderr, b"err");
    assert!(execution.truncated);
}

#[test]
fn a_timeout_terminates_the_process_group_and_keeps_partial_output() {
    let scratch = Scratch::new("timeout");
    let marker = scratch.0.join("printed");
    let tool = scratch.tool(&format!(
        "printf partial; printf x > {}; sleep 30",
        marker.display()
    ));
    let arguments = args(&[]);
    let environment = env(&[]);
    let started = Instant::now();
    let execution = tool
        .run_tool(
            &ToolRequest {
                arguments: &arguments,
                environment: &environment,
                working_directory: None,
                limits: ToolLimits {
                    timeout: Duration::from_secs(3),
                    capture_bytes: 1024,
                },
            },
            &|| false,
        )
        .unwrap();
    assert_eq!(execution.termination, ToolTermination::TimedOut);
    // A loaded host may time the child out before its shell printed; what it
    // did print before the termination is kept.
    if marker.exists() {
        assert_eq!(execution.stdout, b"partial");
    }
    assert!(execution.duration >= Duration::from_secs(3));
    assert!(started.elapsed() < Duration::from_secs(20));
}

#[test]
fn a_cancellation_seen_before_the_spawn_leaves_no_child_and_one_during_the_run_drains_the_group() {
    let scratch = Scratch::new("cancel");
    let marker = scratch.0.join("ran");
    let tool = scratch.tool(&format!("printf x > {}; sleep 30", marker.display()));
    let arguments = args(&[]);
    let environment = env(&[]);
    let execution = tool
        .run_tool(&request(&arguments, &environment, None), &|| true)
        .unwrap();
    assert_eq!(
        execution.termination,
        ToolTermination::Cancelled { drained: true }
    );
    assert_eq!(execution.duration, Duration::ZERO);
    assert!(!marker.exists());
    let asked = Cell::new(0);
    let execution = tool
        .run_tool(&request(&arguments, &environment, None), &|| {
            asked.set(asked.get() + 1);
            marker.exists() && asked.get() > 1
        })
        .unwrap();
    assert_eq!(
        execution.termination,
        ToolTermination::Cancelled { drained: true }
    );
    assert!(marker.exists());
}

#[test]
fn a_signal_death_and_a_nonzero_exit_are_reported_as_such() {
    let scratch = Scratch::new("exit");
    let arguments = args(&[]);
    let environment = env(&[]);
    let killed = scratch
        .tool("kill -9 $$")
        .run_tool(&request(&arguments, &environment, None), &|| false)
        .unwrap();
    assert_eq!(
        killed.termination,
        ToolTermination::Signalled(libc::SIGKILL)
    );
    let scratch = Scratch::new("exit7");
    let failed = scratch
        .tool("printf 'reason' >&2; exit 7")
        .run_tool(&request(&arguments, &environment, None), &|| false)
        .unwrap();
    assert_eq!(failed.termination, ToolTermination::Exited(7));
    assert_eq!(failed.stderr, b"reason");
}

#[test]
fn the_budget_is_bounded_before_any_spawn() {
    let scratch = Scratch::new("budget");
    let tool = scratch.tool("exit 0");
    let arguments = args(&[]);
    let environment = env(&[]);
    for limits in [
        ToolLimits {
            timeout: Duration::ZERO,
            capture_bytes: 1,
        },
        ToolLimits {
            timeout: Duration::from_secs(3601),
            capture_bytes: 1,
        },
        ToolLimits {
            timeout: Duration::from_secs(1),
            capture_bytes: 0,
        },
        ToolLimits {
            timeout: Duration::from_secs(1),
            capture_bytes: 64 * 1024 * 1024 + 1,
        },
    ] {
        let error = tool
            .run_tool(
                &ToolRequest {
                    arguments: &arguments,
                    environment: &environment,
                    working_directory: None,
                    limits,
                },
                &|| false,
            )
            .unwrap_err();
        assert!(matches!(error, ToolRunError::Refused(_)));
    }
}
