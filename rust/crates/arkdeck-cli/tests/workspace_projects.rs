use arkdeck_cli::*;
use serde_json::{Value, json};
fn args(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).into()).collect()
}
#[test]
fn workspace_project_arguments_are_closed() {
    let invocation = parse(&args(&[
        "workspace",
        "project",
        "register",
        "--registration-request-id",
        "req-1",
        "--kind",
        "openharmony",
        "--root",
        "/private/tmp/project",
    ]))
    .unwrap();
    assert_eq!(invocation.method, "workspace.project.register");
    assert_eq!(invocation.params.unwrap(),serde_json::from_value::<serde_json::Map<String,Value>>(json!({"registrationRequestId":"req-1","kind":"openharmony","root":"/private/tmp/project"})).unwrap());
    for argv in [
        vec!["workspace", "project", "register"],
        vec!["workspace", "project", "show"],
        vec!["workspace", "project", "list", "--root", "/tmp"],
        vec![
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "req",
            "--kind",
            "unknown",
            "--root",
            "/tmp",
        ],
        vec![
            "workspace",
            "project",
            "show",
            "--project",
            "p",
            "--capability",
            "c",
        ],
    ] {
        assert!(parse(&args(&argv)).is_err(), "{argv:?}");
    }
}
#[cfg(target_os = "macos")]
mod runtime {
    use super::*;
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::Shutdown;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::process::{Command, Output};
    /// What the fake Runtime does once it has read the request.
    enum Reply {
        Answer(Value),
        Close,
    }

    /// The actual CLI run with `argv` against a fake Runtime. With an
    /// exchange, the Runtime answers health, reads exactly one request of
    /// that method and parameters and replies; without one, the CLI must not
    /// connect at all. It never accepts a replay or a second connection.
    fn run(argv: &[String], exchange: Option<(String, Value, Reply)>) -> (Output, Value) {
        let root = PathBuf::from(format!(
            "/private/tmp/workspace-project-cli-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let path = root.join("a.sock");
        let listener = UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let server = exchange.map(|(method, params, reply)| {
            let acceptor = listener.try_clone().unwrap();
            std::thread::spawn(move || {
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
                assert_eq!(request["method"], method);
                assert_eq!(request["params"], params, "the oracle's parameters");
                if let Reply::Answer(mut answer) = reply {
                    answer["id"] = request["id"].clone();
                    writeln!(reader.get_mut(), "{answer}").unwrap();
                }
                reader.get_mut().shutdown(Shutdown::Write).unwrap();
                let mut extra = Vec::new();
                reader.read_to_end(&mut extra).unwrap();
                assert!(extra.is_empty(), "the CLI never replays a request");
            })
        });
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(argv)
            .args(["--output", "json", "--socket"])
            .arg(&path)
            .output()
            .unwrap();
        if let Some(server) = server {
            server.join().unwrap();
        }
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
            "no connection beyond the exchange"
        );
        drop(listener);
        std::fs::remove_dir_all(root).unwrap();
        let envelope = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
        (output, envelope)
    }

    #[test]
    fn real_cli_consumes_resources_once_and_never_retries_registration() {
        let resource = json!({"schemaVersion":"arkdeck.workspace-project/1","projectRef":"project-one","generation":"1","kind":"openharmony","registeredAtUtc":"2026-09-19T00:00:00.000Z","updatedAtUtc":"2026-09-19T00:00:00.000Z","configurationStatus":"runtimeRestartRequired","availability":"unavailable","reasonCode":"workspace_runtime_restart_required","reason":"restart the Runtime to compose the registered root before submitting a workspace Job","allowedFileGlobs":[],"presetRefs":[],"operations":[]});
        let argv = args(&[
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "req-1",
            "--kind",
            "openharmony",
            "--root",
            "/private/tmp/project",
        ]);
        let params = json!({"registrationRequestId":"req-1","kind":"openharmony","root":"/private/tmp/project"});
        let (output, envelope) = run(
            &argv,
            Some((
                "workspace.project.register".into(),
                params.clone(),
                Reply::Answer(json!({"ok":true,"result":resource})),
            )),
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["result"], resource);
        let (output, envelope) = run(
            &argv,
            Some(("workspace.project.register".into(), params, Reply::Close)),
        );
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "outcomeUnknown");
        assert_eq!(envelope["error"]["controlRequestRetryable"], false);
        let (output, envelope) = run(
            &args(&["workspace", "project", "list"]),
            Some((
                "workspace.project.list".into(),
                json!({}),
                Reply::Answer(
                    json!({"ok":true,"result":{"schemaVersion":"arkdeck.workspace-project-list/1","projects":[resource]}}),
                ),
            )),
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        let show_valid =
            arkdeck_contract::validate_method_value("workspace.project.show", "result", &resource)
                .is_ok();
        let (output, envelope) = run(
            &args(&["workspace", "project", "show", "--project", "project-one"]),
            Some((
                "workspace.project.show".into(),
                json!({"projectRef":"project-one"}),
                Reply::Answer(json!({"ok":true,"result":resource})),
            )),
        );
        if show_valid {
            assert_eq!(output.status.code(), Some(0), "{envelope}");
        } else {
            assert_ne!(
                output.status.code(),
                Some(0),
                "old published view must reject its unsampled shape"
            );
        }
    }
}
