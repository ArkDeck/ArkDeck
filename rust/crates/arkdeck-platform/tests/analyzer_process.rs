//! The analyzer child runner: each stream kept to its first bytes while the
//! rest drains, the group-terminating timeout, signal deaths, and the source
//! handed over as the `/.vol` alias of its verified descriptor. Spawning
//! children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{
    AnalyzerLimits, AnalyzerRunError, AnalyzerTermination, VerifiedSource, VerifiedTool,
};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-analyzer-{name}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path.canonicalize().unwrap())
    }
    fn file(&self, name: &str, bytes: &[u8], mode: u32) -> (PathBuf, String) {
        let path = self.0.join(name);
        std::fs::write(&path, bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        (path, format!("{:x}", Sha256::digest(bytes)))
    }
    fn tool(&self, body: &str) -> VerifiedTool {
        let (path, digest) =
            self.file("analyzer", format!("#!/bin/sh\n{body}\n").as_bytes(), 0o700);
        VerifiedTool::open(path, &digest).unwrap()
    }
    fn source(&self, bytes: &[u8]) -> VerifiedSource {
        let (path, digest) = self.file("source", bytes, 0o400);
        VerifiedSource::open(&path, &digest, bytes.len() as u64).unwrap()
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn limits(timeout: Duration, capture_bytes: usize) -> AnalyzerLimits {
    AnalyzerLimits {
        timeout,
        capture_bytes,
    }
}

fn run(
    tool: &VerifiedTool,
    source: &VerifiedSource,
    arguments: &[&str],
    limits: AnalyzerLimits,
) -> Result<arkdeck_platform::AnalyzerExecution, AnalyzerRunError> {
    let arguments: Vec<OsString> = arguments.iter().map(OsString::from).collect();
    tool.run_analyzer(&arguments, source, limits)
}

#[test]
fn the_child_reads_its_source_through_the_inode_alias() {
    let scratch = Scratch::new("alias");
    let tool =
        scratch.tool(r#"printf 'out:%s|%s' "$1" "$(/bin/cat "$2")"; printf err >&2; exit 7"#);
    let source = scratch.source(b"source bytes\n");
    let alias = source.inode_path();
    assert!(alias.starts_with("/.vol/"), "{alias}");
    let execution = run(
        &tool,
        &source,
        &["--analyze-crash-ledger", &alias],
        limits(Duration::from_secs(10), 1024),
    )
    .unwrap();
    assert_eq!(execution.termination, AnalyzerTermination::Exited(7));
    assert_eq!(
        String::from_utf8(execution.stdout).unwrap(),
        "out:--analyze-crash-ledger|source bytes"
    );
    assert_eq!(execution.stderr, b"err");
    assert!(!execution.truncated);
}

#[test]
fn each_stream_keeps_its_first_bytes_and_the_rest_drains() {
    let scratch = Scratch::new("capture");
    let tool = scratch.tool("/usr/bin/head -c 300000 /dev/zero; printf done >&2");
    let source = scratch.source(b"x");
    let started = Instant::now();
    let execution = run(&tool, &source, &[], limits(Duration::from_secs(10), 1000)).unwrap();
    assert_eq!(execution.termination, AnalyzerTermination::Exited(0));
    assert_eq!(execution.stdout, vec![0; 1000]);
    assert_eq!(execution.stderr, b"done");
    assert!(execution.truncated);
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn a_timeout_terminates_the_whole_process_group() {
    let scratch = Scratch::new("timeout");
    let tool = scratch.tool(r#"/bin/sleep 60 & echo $! > "$1"; exec /bin/sleep 60"#);
    let source = scratch.source(b"x");
    let pid_file = scratch.0.join("member");
    let started = Instant::now();
    let execution = run(
        &tool,
        &source,
        &[pid_file.to_str().unwrap()],
        limits(Duration::from_secs(2), 1024),
    )
    .unwrap();
    assert_eq!(execution.termination, AnalyzerTermination::TimedOut);
    assert!(started.elapsed() >= Duration::from_secs(2));
    // A loaded host may time the child out before it started its member;
    // any member it did start belongs to the terminated group. A killed
    // member stays a zombie until launchd reaps it, so wait for that.
    if let Ok(text) = std::fs::read_to_string(&pid_file)
        && let Ok(pid) = text.trim().parse::<libc::pid_t>()
    {
        let deadline = Instant::now() + Duration::from_secs(30);
        // SAFETY: signal 0 only probes whether the process still exists.
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(Instant::now() < deadline, "member {pid} survived its group");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

#[test]
fn a_signal_death_is_reported_as_such() {
    let scratch = Scratch::new("signal");
    let tool = scratch.tool(r#"kill -KILL "$$""#);
    let source = scratch.source(b"x");
    let execution = run(&tool, &source, &[], limits(Duration::from_secs(10), 1024)).unwrap();
    assert_eq!(
        execution.termination,
        AnalyzerTermination::Signalled(libc::SIGKILL)
    );
}

#[test]
fn unverified_sources_and_budgets_are_refused_before_any_spawn() {
    let scratch = Scratch::new("refusal");
    let (path, digest) = scratch.file("source", b"bytes", 0o400);
    assert!(VerifiedSource::open(&path, &"0".repeat(64), 5).is_err());
    assert!(VerifiedSource::open(&path, &digest, 4).is_err());
    let tool = scratch.tool("exit 0");
    let source = VerifiedSource::open(&path, &digest, 5).unwrap();
    for budget in [
        limits(Duration::ZERO, 1024),
        limits(Duration::from_secs(10), 0),
        limits(Duration::from_secs(7200), 1024),
    ] {
        assert!(matches!(
            run(&tool, &source, &[], budget),
            Err(AnalyzerRunError::Refused(_))
        ));
    }
    assert!(Path::new(&source.inode_path()).exists());
}
