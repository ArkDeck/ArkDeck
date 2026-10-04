//! The Windows daemon's HDC tuple gate (TASK-XPA-005, CHG-2026-078), as the
//! real daemon decides it: the Windows daemon composes an HDC only for an
//! executable whose SHA-256 a registered `OPENHARMONY-HDC-WINDOWS-PROBES`
//! tuple holds; the registry holds DevEco's `hdc.exe` only, never the
//! stand-in these tests name.
//!
//! * A development root naming a stand-in HDC as its managed server is
//!   refused before the root is opened, naming the digest the registry
//!   would have to hold: nothing is created in the root, and nothing is
//!   launched (the stand-in is not an executable at all, and the refusal
//!   reads its bytes only).
//! * A development root naming it as a fixture is refused as such: the
//!   Windows daemon runs no fixture HDC.
//! * The private-endpoint foundation configured with the stand-in and its
//!   exact digest composes no read-only provider: its bytes verify, and the
//!   registry does not name them (`hdc.platformEvidenceUnavailable`).
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! the ones named here: nothing installed is read or written, and no device
//! or `hdc` is involved. The one daemon that serves is ended by this test.
#![cfg(windows)]

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

/// One test at a time: a child spawned while another test spawns inherits
/// that test's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
/// The stand-in's bytes: not an executable, and never run.
const STAND_IN: &[u8] = b"MZ a Windows HDC stand-in; the daemon only hashes it\r\n";

/// A fresh directory with an empty development root and, beside it, the
/// stand-in HDC; removed afterwards.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winhdcgate-{nonce:016x}"));
        let path = PathBuf::from(
            path.to_str()
                .unwrap()
                .strip_prefix(r"\\?\")
                .unwrap_or(path.to_str().unwrap()),
        );
        std::fs::create_dir(&path).unwrap();
        std::fs::create_dir(path.join("root")).unwrap();
        std::fs::write(path.join("hdc.exe"), STAND_IN).unwrap();
        Self(path)
    }
    fn root(&self) -> PathBuf {
        self.0.join("root")
    }
    fn hdc(&self) -> PathBuf {
        self.0.join("hdc.exe")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy().into_owned();
        if key.to_ascii_uppercase().starts_with("ARKDECK_")
            || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
        {
            command.env_remove(key);
        }
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// A start that is refused: its standard error, after checking that it
/// failed, printed nothing on stdout and created nothing in its root.
fn refused(scratch: &Scratch, command: &mut Command) -> String {
    let output = command.output().unwrap();
    assert!(!output.status.success(), "{output:?}");
    assert!(output.stdout.is_empty(), "{output:?}");
    assert_eq!(
        std::fs::read_dir(scratch.root()).unwrap().count(),
        0,
        "the refused start created nothing in its root"
    );
    assert_eq!(std::fs::read(scratch.hdc()).unwrap(), STAND_IN);
    String::from_utf8(output.stderr).unwrap()
}

#[test]
fn a_development_root_refuses_an_hdc_no_registered_tuple_names() {
    let _turn = turn();
    let scratch = Scratch::new();
    let sha256 = arkdeck_contract::sha256_hex(STAND_IN);
    let expected = format!(
        "arkdeck-agentd: the development HDC {} (SHA-256 {sha256}) is not a registered Windows \
         HDC: OPENHARMONY-HDC-WINDOWS-PROBES (CHG-2026-078) registers no tuple with that digest; \
         nothing was started\n",
        scratch.hdc().display()
    );
    // As its managed server, on the default endpoint or an inherited port:
    // the registry is asked first, and names no tuple.
    for port in [None, Some("18710")] {
        let mut command = daemon();
        command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", scratch.root())
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", scratch.hdc())
            .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed");
        if let Some(port) = port {
            command.env("OHOS_HDC_SERVER_PORT", port);
        }
        assert_eq!(refused(&scratch, &mut command), expected, "{port:?}");
    }
}

#[test]
fn a_development_root_runs_no_fixture_hdc() {
    let _turn = turn();
    let scratch = Scratch::new();
    let stderr = refused(
        &scratch,
        daemon()
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", scratch.root())
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", scratch.hdc()),
    );
    assert_eq!(
        stderr,
        "arkdeck-agentd: the Windows development root runs no fixture HDC: a registered HDC is \
         composed only as its managed server (ARKDECK_DEVELOPMENT_HDC_SERVER=managed); nothing \
         was started\n"
    );
    // A server mode other than managed, before the executable is read.
    let stderr = refused(
        &scratch,
        daemon()
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", scratch.root())
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", scratch.hdc())
            .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "external"),
    );
    assert_eq!(
        stderr,
        "arkdeck-agentd: ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed\n"
    );
}

/// One exchange on an open pipe handle.
fn request(pipe: &mut std::fs::File, method: &str, params: Value) -> Value {
    let request = serde_json::json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": method,
        "method": method,
        "params": params,
    });
    let mut frame = serde_json::to_vec(&request).unwrap();
    frame.push(b'\n');
    pipe.write_all(&frame).unwrap();
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while byte[0] != b'\n' {
        assert_eq!(pipe.read(&mut byte).unwrap(), 1, "the reply ended early");
        reply.push(byte[0]);
    }
    serde_json::from_slice(&reply).unwrap()
}

/// The serving daemon, ended when the test ends.
struct Serving(Child);
impl Drop for Serving {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn the_foundation_composes_no_provider_for_an_unregistered_windows_hdc() {
    let _turn = turn();
    let scratch = Scratch::new();
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let pipe = format!(r"\\.\pipe\arkdeck-agentd-hdcgate-{nonce:016x}");
    let mut child = Serving(
        daemon()
            .env("ARKDECK_ENDPOINT", &pipe)
            .env("ARKDECK_HDC_PATH", scratch.hdc())
            .env("ARKDECK_HDC_SHA256", arkdeck_contract::sha256_hex(STAND_IN))
            .spawn()
            .unwrap(),
    );
    // The foundation announces nothing: its pipe is opened once it exists,
    // while the daemon still runs.
    let started = std::time::Instant::now();
    let mut connection = loop {
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&pipe)
        {
            Ok(connection) => break connection,
            Err(error) => {
                assert!(
                    child.0.try_wait().unwrap().is_none(),
                    "the daemon ended before serving: {error}"
                );
                assert!(started.elapsed() < DEADLINE, "no pipe {pipe}: {error}");
                std::thread::yield_now();
            }
        }
    };
    let observed = request(&mut connection, "device.observations", json!({}));
    assert_eq!(observed["error"]["code"], "rejected", "{observed}");
    assert_eq!(
        observed["error"]["message"], "hdc.platformEvidenceUnavailable",
        "{observed}"
    );
    drop(connection);
    drop(child);
    assert_eq!(std::fs::read(Path::new(&scratch.hdc())).unwrap(), STAND_IN);
}
