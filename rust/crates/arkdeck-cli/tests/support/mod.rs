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

/// The CLI run with `argv` against a fake Runtime that serves exactly one
/// connection and answers the exchanges `replies` names, in order, each
/// request having to carry exactly that method and parameters. The first
/// exchange is the contract preflight, which is the leaf's own first request
/// when that request is `health`. A leaf that asks for anything else, or that
/// opens a second connection, fails the test.
pub fn run_session(argv: &[&str], replies: Vec<(String, Value, Value)>) -> (Output, Value) {
    let root = PathBuf::from(format!(
        "/private/tmp/arkdeck-cli-runtime-{:032x}",
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
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv)
        .args(["--output", "json", "--socket"])
        .arg(&path)
        .output()
        .unwrap();
    let unserved = server.join().unwrap();
    assert!(
        unserved.is_empty(),
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
    let root = PathBuf::from(format!(
        "/private/tmp/arkdeck-cli-runtime-{:032x}",
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
        let mut unserved = Vec::new();
        for (method, params, answer) in replies {
            // The CLI may have ended before this exchange: never wait for
            // it past a bound.
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
                unserved.push(method);
                continue;
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let health: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(health["method"], "health");
            let health = json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}});
            writeln!(reader.get_mut(), "{health}").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], method.as_str());
            assert_eq!(request["params"], params, "{method}");
            let mut answer = answer;
            answer["id"] = request["id"].clone();
            writeln!(reader.get_mut(), "{answer}").unwrap();
            // The CLI closes the connection once it has read the answer.
            // Closing it here first races the bounded client, which sets
            // its read timeout before every read: macOS refuses that
            // (EINVAL) on a socket whose peer has closed.
            let mut rest = String::new();
            let _ = reader.read_line(&mut rest);
        }
        unserved
    });
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv)
        .args(["--output", "json", "--socket"])
        .arg(&path)
        .output()
        .unwrap();
    let unserved = server.join().unwrap();
    assert!(
        unserved.is_empty(),
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
