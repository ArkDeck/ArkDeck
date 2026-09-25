//! `ui-dump inspect|hit-test` replayed through the CLI process against
//! Swift's recorded runs (`rust/tests/fixtures/ui-dump-inspect`,
//! `CLIUIDumpInspectOracleContractTests`, whose owners are
//! `RuntimeCLI.emitUIDumpDerivation`, `UIDumpOfflineInspector`,
//! `ViewerCaptureParser`, `ViewerHitTesting` and `CLIOfflineDerivation`).
//!
//! A fake Runtime on a private socket answers as the Swift test's scripted
//! peer did: each connection's `health` preflight as the current Runtime
//! answers it, and each business frame from the script, whose next entry must
//! name its method. The CLI must send the same frames over as many
//! connections, use the whole script, and end as Swift's CLI ended: the same
//! exit status, and in a machine mode the same bytes on stdout and stderr. A
//! human rendering is Swift's outline and this CLI's pretty JSON (T2).
#![cfg(target_os = "macos")]

use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Map, Value, json};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

fn cases() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/ui-dump-inspect/cases.json");
    serde_json::from_slice::<Value>(&std::fs::read(path).unwrap())
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// Swift's label for a random frame identity.
fn label(id: &str) -> String {
    let uuid = id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte)
            }
        });
    if uuid { "<UUID>".into() } else { id.into() }
}

fn health() -> Value {
    json!({"status": "ok", "protocolVersion": PROTOCOL_VERSION,
        "contractIdentity": CONTRACT_IDENTITY, "publishedMethods": METHODS,
        "catalogDigest": CATALOG_DIGEST, "providers": []})
}

/// What the fake Runtime saw.
#[derive(Default)]
struct Seen {
    sent: Vec<Value>,
    connections: usize,
    unused: Vec<String>,
}

/// A private directory, removed however the test ends.
struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn private_root() -> Root {
    // A Unix socket path is short: the system temporary directory, not the
    // per-user one.
    let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
        "arkdeck-cli-uidump-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    Root(root)
}

/// Serves `script` on `socket` until the CLI has exited, one connection at a
/// time, as the scripted peer answered.
fn serve(
    socket: &Path,
    script: Vec<Value>,
    exited: Arc<AtomicBool>,
) -> std::thread::JoinHandle<Seen> {
    let listener = UnixListener::bind(socket).unwrap();
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        let mut script: VecDeque<Value> = script.into();
        let mut seen = Seen::default();
        loop {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if exited.load(Ordering::SeqCst) {
                        // Every connection the CLI made is already queued.
                        match listener.accept() {
                            Ok((stream, _)) => stream,
                            Err(_) => break,
                        }
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                        continue;
                    }
                }
                Err(error) => panic!("{error}"),
            };
            seen.connections += 1;
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                let frame: Value = serde_json::from_str(&line).unwrap();
                let (id, method) = (
                    frame["id"].as_str().unwrap().to_owned(),
                    frame["method"].as_str().unwrap().to_owned(),
                );
                let mut logged = Map::from_iter([
                    ("method".to_owned(), json!(method)),
                    ("id".to_owned(), json!(label(&id))),
                ]);
                if let Some(params) = frame.get("params") {
                    logged.insert("params".into(), params.clone());
                }
                seen.sent.push(Value::Object(logged));
                let reply = if method == "health" {
                    Some(json!({"id": id, "ok": true, "result": health()}))
                } else if script.front().is_some_and(|next| next["method"] == method) {
                    let entry = script.pop_front().unwrap();
                    if let Some(result) = entry.get("result") {
                        Some(json!({"id": id, "ok": true, "result": result}))
                    } else {
                        entry
                            .get("error")
                            .map(|error| json!({"id": id, "ok": false, "error": error}))
                    }
                } else {
                    seen.sent.push(json!({"unscripted": method}));
                    None
                };
                let Some(reply) = reply else { break };
                if writeln!(reader.get_mut(), "{reply}").is_err() {
                    break;
                }
            }
        }
        seen.unused = script
            .iter()
            .map(|entry| entry["method"].as_str().unwrap().to_owned())
            .collect();
        seen
    })
}

/// One recorded run replayed, or how it differs.
fn replay(case: &Value) -> Result<(), String> {
    let name = case["name"].as_str().unwrap();
    let root = private_root();
    let socket = root.0.join("s");
    let exited = Arc::new(AtomicBool::new(false));
    let server = serve(
        &socket,
        case["script"].as_array().unwrap().clone(),
        exited.clone(),
    );
    let argv: Vec<&str> = case["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|argument| argument.as_str().unwrap())
        .collect();
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(&argv)
        .arg("--socket")
        .arg(&socket)
        .output()
        .unwrap();
    exited.store(true, Ordering::SeqCst);
    let seen = server.join().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let context = format!("{name}: stdout {stdout} stderr {stderr}");
    let check = |same: bool, what: &str| {
        if same {
            Ok(())
        } else {
            Err(format!("{what} differs: {context}"))
        }
    };
    check(Value::Array(seen.sent) == case["sent"], "frames")?;
    check(
        case["connections"].as_u64() == Some(seen.connections as u64),
        "connections",
    )?;
    check(json!(seen.unused) == case["unusedScript"], "unused script")?;
    check(
        case["exit"].as_i64() == output.status.code().map(i64::from),
        "exit",
    )?;
    if argv.contains(&"--output") {
        check(case["stdout"] == stdout.as_str(), "stdout")?;
        check(case["stderr"] == stderr.as_str(), "stderr")
    } else {
        // The human rendering is Swift's key-value outline and this CLI's
        // pretty JSON (T2): the same status and diagnostics.
        check(
            !stdout.is_empty() && case["stderr"] == stderr.as_str(),
            "human rendering",
        )
    }
}

#[test]
fn every_recorded_run_replays_through_the_cli() {
    let cases = cases();
    let failures: Vec<String> = cases.iter().filter_map(|case| replay(case).err()).collect();
    assert_eq!(cases.len(), 19);
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}
