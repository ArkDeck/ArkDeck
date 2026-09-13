#![cfg(target_os = "macos")]
use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::Shutdown,
    os::unix::{
        fs::{DirBuilderExt, PermissionsExt},
        net::UnixListener,
    },
    process::Command,
};

#[test]
fn actual_cli_sends_one_purge_and_never_reconnects_after_unconfirmed_answers() {
    for failure in ["closed", "malformed", "wrong-schema", "semantic"] {
        let root = std::path::PathBuf::from(format!(
            "/private/tmp/trace-purge-cli-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let path = root.join("a.sock");
        let listener = UnixListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let acceptor = listener.try_clone().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = acceptor.accept().unwrap();
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
            assert_eq!(request["method"], "trace.cache.purge");
            match failure {
                "closed" => (),
                "malformed" => {
                    reader.get_mut().write_all(b"not-json\n").unwrap();
                }
                "wrong-schema" => {
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":request["id"],"ok":true,"result":{}})
                    )
                    .unwrap();
                }
                _ => {
                    let inventory = json!({"entryCount":0,"activeEntryCount":0,"inactiveEntryCount":0,"totalByteCount":"00"});
                    writeln!(reader.get_mut(), "{}", json!({"id":request["id"],"ok":true,"result":{
                        "schemaVersion":"arkdeck.trace-cache-purge/1","purgeScope":"inactiveDerivedDatabases",
                        "before":inventory,"after":inventory,"removedEntryCount":0,"skippedActiveEntryCount":0,
                        "recoveredPrivateDirectoryCount":0,"removedOrphanOwnerMarkerCount":0,"originalTraceArtifactRemovalCount":0}})).unwrap();
                }
            }
            reader.get_mut().shutdown(Shutdown::Write).unwrap();
            let mut extra = Vec::new();
            reader.read_to_end(&mut extra).unwrap();
            assert!(
                extra.is_empty(),
                "purge must never replay on the same connection"
            );
        });
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(["trace", "cache", "purge", "--output", "json", "--socket"])
            .arg(&path)
            .output()
            .unwrap();
        server.join().unwrap();
        assert_eq!(
            output.status.code(),
            Some(75),
            "{failure}: {:?}",
            output.stderr
        );
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(envelope["error"]["code"], "outcomeUnknown", "{failure}");
        assert!(envelope.get("result").is_none());
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock),
            "purge must never reconnect"
        );
        drop(listener);
        fs::remove_dir_all(root).unwrap();
    }
}
