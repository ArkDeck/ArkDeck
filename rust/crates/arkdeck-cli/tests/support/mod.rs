//! A fake Runtime the CLI tests serve recorded answers from: over a private
//! socket it answers each connection's health and then one request, which
//! must carry exactly the method and parameters the test names.
// Each test binary compiles this module on its own and uses the harness its
// leaves need; the other one is dead code there.
#![allow(dead_code)]
use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The CLI, asked for the machine answer unless the test names its own output
/// mode (the two streaming leaves serve `jsonl`, and one of them no `json`).
fn invoke(argv: &[&str], socket: &PathBuf) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
    command.args(argv);
    if !argv.contains(&"--output") {
        command.args(["--output", "json"]);
    }
    command.arg("--socket").arg(socket).output().unwrap()
}

/// The CLI run with `argv` against a fake Runtime that serves exactly one
/// connection and answers the exchanges `replies` names, in order, each
/// request having to carry exactly that method and parameters. The first
/// exchange is the contract preflight, which is the leaf's own first request
/// when that request is `health`. A leaf that asks for anything else, or that
/// opens a second connection, fails the test.
pub fn run_session(argv: &[&str], replies: Vec<(String, Value, Value)>) -> (Output, Value) {
    session(argv, replies, true)
}

/// The same, for a leaf whose own deadline may end the wait before it asks for
/// every answer the test offers: the trailing replies it never asks for are
/// allowed.
pub fn run_session_partial(argv: &[&str], replies: Vec<(String, Value, Value)>) -> (Output, Value) {
    session(argv, replies, false)
}

fn session(argv: &[&str], replies: Vec<(String, Value, Value)>, exact: bool) -> (Output, Value) {
    let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
        "arkdeck-cli-runtime-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    let path = root.join("a.sock");
    let listener = UnixListener::bind(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let acceptor = listener.try_clone().unwrap();
    acceptor.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let stream = loop {
            match acceptor.accept() {
                Ok((stream, _)) => break Some(stream),
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(_) => break None,
            }
        };
        let Some(stream) = stream else {
            return replies.into_iter().map(|(method, _, _)| method).collect();
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut reader = BufReader::new(stream);
        let mut unserved = Vec::new();
        for (method, params, answer) in replies {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                unserved.push(method);
                continue;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], method.as_str());
            assert_eq!(request["params"], params, "{method}");
            let mut answer = answer;
            answer["id"] = request["id"].clone();
            writeln!(reader.get_mut(), "{answer}").unwrap();
        }
        let mut rest = String::new();
        let read = reader.read_line(&mut rest).unwrap_or(0);
        assert_eq!(read, 0, "one exchange beyond those named: {rest}");
        unserved
    });
    let output = invoke(argv, &path);
    let unserved = server.join().unwrap();
    assert!(
        !exact || unserved.is_empty(),
        "the CLI never asked for {unserved:?}: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    listener.set_nonblocking(true).unwrap();
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "no connection beyond the first"
    );
    drop(listener);
    std::fs::remove_dir_all(root).unwrap();
    let envelope = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
    (output, envelope)
}

/// The actual CLI run with `argv` against a fake Runtime that answers,
/// one connection each, health and then the next request, which must be
/// the method and parameters `replies` names, with its answer. The CLI
/// may make no other connection.
pub fn run(argv: &[&str], replies: Vec<(String, Value, Value)>) -> (Output, Value) {
    connections(argv, replies, true)
}

/// The same, for a leaf whose own deadline may end its wait before it asks for
/// every answer the test offers: the trailing exchanges it never asks for are
/// allowed. How many it asks for is the leaf's own deadline's to decide, so
/// the fake Runtime waits for the next exchange until the CLI has exited, never
/// for a guess at its pace.
pub fn run_partial(argv: &[&str], replies: Vec<(String, Value, Value)>) -> (Output, Value) {
    connections(argv, replies, false)
}

fn connections(
    argv: &[&str],
    replies: Vec<(String, Value, Value)>,
    exact: bool,
) -> (Output, Value) {
    let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
        "arkdeck-cli-runtime-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    let path = root.join("a.sock");
    let listener = UnixListener::bind(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let acceptor = listener.try_clone().unwrap();
    acceptor.set_nonblocking(true).unwrap();
    let exited = Arc::new(AtomicBool::new(false));
    let cli_exited = Arc::clone(&exited);
    let server = std::thread::spawn(move || {
        let mut unserved = Vec::new();
        let mut ended = false;
        for (method, params, answer) in replies {
            if ended {
                unserved.push(method);
                continue;
            }
            // The CLI may have ended before this exchange. Once it has exited,
            // every connection it made is already queued, so an accept that
            // finds none after that is the end of its exchanges; the bound
            // only keeps a CLI that hangs from hanging the test.
            let bound = std::time::Instant::now()
                + std::time::Duration::from_secs(if exact { 10 } else { 60 });
            let stream = loop {
                let gone = cli_exited.load(Ordering::SeqCst);
                match acceptor.accept() {
                    Ok((stream, _)) => break Some(stream),
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && !gone
                            && std::time::Instant::now() < bound =>
                    {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Err(_) => break None,
                }
            };
            let Some(stream) = stream else {
                unserved.push(method);
                ended = !exact;
                continue;
            };
            // A peer that has already closed refuses these on macOS (EINVAL),
            // which is one way a leaf whose deadline ended shows up here.
            if stream.set_nonblocking(false).is_err()
                || stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .is_err()
            {
                unserved.push(method);
                ended = !exact;
                continue;
            }
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            // A leaf whose own deadline ended may close this connection at any
            // point: an exchange it walked away from is one it never asked for.
            let mut walked_away = reader.read_line(&mut line).unwrap_or(0) == 0;
            if !walked_away {
                let health: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(health["method"], "health");
                let health = json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                    "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}});
                walked_away = writeln!(reader.get_mut(), "{health}").is_err();
            }
            line.clear();
            if !walked_away {
                walked_away = reader.read_line(&mut line).unwrap_or(0) == 0;
            }
            if walked_away {
                unserved.push(method);
                ended = !exact;
                continue;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], method.as_str());
            assert_eq!(request["params"], params, "{method}");
            let mut answer = answer;
            answer["id"] = request["id"].clone();
            if writeln!(reader.get_mut(), "{answer}").is_err() {
                ended = !exact;
                continue;
            }
            // The CLI closes the connection once it has read the answer.
            // Closing it here first races the bounded client, which sets
            // its read timeout before every read: macOS refuses that
            // (EINVAL) on a socket whose peer has closed.
            let mut rest = String::new();
            let _ = reader.read_line(&mut rest);
        }
        unserved
    });
    let output = invoke(argv, &path);
    exited.store(true, Ordering::SeqCst);
    let unserved = server.join().unwrap();
    assert!(
        !exact || unserved.is_empty(),
        "the CLI never asked for {unserved:?}: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    listener.set_nonblocking(true).unwrap();
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "no connection beyond the exchanges"
    );
    drop(listener);
    std::fs::remove_dir_all(root).unwrap();
    let envelope = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
    (output, envelope)
}
