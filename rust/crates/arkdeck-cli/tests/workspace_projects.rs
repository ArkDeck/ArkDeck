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
/// The four leaves the Rust owner gained first with the mutation oracle, as
/// the Swift argv samples spell them, and their closed refusals.
#[test]
fn workspace_mutation_and_preset_arguments_are_closed() {
    for (argv, method, params) in [
        (
            vec![
                "workspace",
                "project",
                "update",
                "--project",
                "sample",
                "--expected-generation",
                "1",
                "--kind",
                "arkdeck",
                "--root",
                "/private/tmp/project",
            ],
            "workspace.project.update",
            json!({"projectRef": "sample", "expectedGeneration": "1", "kind": "arkdeck",
                   "root": "/private/tmp/project"}),
        ),
        (
            vec![
                "workspace",
                "project",
                "remove",
                "--project",
                "sample",
                "--expected-generation",
                "1",
            ],
            "workspace.project.remove",
            json!({"projectRef": "sample", "expectedGeneration": "1"}),
        ),
        (
            vec!["workspace", "preset", "list", "--project", "sample"],
            "workspace.preset.list",
            json!({"projectRef": "sample"}),
        ),
        (
            vec![
                "workspace",
                "preset",
                "list",
                "--project",
                "sample",
                "--kind",
                "symbol",
            ],
            "workspace.preset.list",
            json!({"projectRef": "sample", "kind": "symbol"}),
        ),
        (
            vec![
                "workspace",
                "preset",
                "show",
                "--project",
                "sample",
                "--preset",
                "preset-sample",
            ],
            "workspace.preset.show",
            json!({"projectRef": "sample", "presetRef": "preset-sample"}),
        ),
    ] {
        let invocation = parse(&args(&argv)).unwrap();
        assert_eq!(invocation.method, method, "{argv:?}");
        assert_eq!(
            Value::Object(invocation.params.unwrap()),
            params,
            "{argv:?}"
        );
    }
    for argv in [
        vec![
            "workspace",
            "project",
            "update",
            "--project",
            "sample",
            "--expected-generation",
            "1",
            "--kind",
            "arkdeck",
        ],
        vec![
            "workspace",
            "project",
            "update",
            "--project",
            "sample",
            "--expected-generation",
            "1",
            "--kind",
            "sideways",
            "--root",
            "/tmp",
        ],
        vec!["workspace", "project", "remove", "--project", "sample"],
        vec!["workspace", "preset", "list"],
        vec![
            "workspace",
            "preset",
            "list",
            "--project",
            "sample",
            "--kind",
            "sideways",
        ],
        vec!["workspace", "preset", "show", "--project", "sample"],
        vec![
            "workspace",
            "preset",
            "show",
            "--project",
            "sample",
            "--preset",
            "p",
            "--root",
            "/tmp",
        ],
    ] {
        assert!(parse(&args(&argv)).is_err(), "{argv:?}");
    }
}
/// The three preset mutation leaves as the Swift argv samples spell them:
/// each dispatches, renders its help, and refuses an unknown or repeated
/// option, a missing required one and `--output jsonl`; `--socket` is kept.
#[test]
fn workspace_preset_mutation_arguments_follow_the_swift_samples() {
    let register = [
        "workspace",
        "preset",
        "register",
        "--registration-request-id",
        "sample",
        "--project",
        "sample",
        "--kind",
        "build",
        "--template",
        "sample",
        "--timeout-seconds",
        "1",
    ];
    let update = [
        "workspace",
        "preset",
        "update",
        "--mutation-request-id",
        "sample",
        "--project",
        "sample",
        "--preset",
        "sample",
        "--expected-generation",
        "1",
        "--kind",
        "build",
        "--template",
        "sample",
        "--timeout-seconds",
        "1",
    ];
    let remove = [
        "workspace",
        "preset",
        "remove",
        "--mutation-request-id",
        "sample",
        "--project",
        "sample",
        "--preset",
        "sample",
        "--expected-generation",
        "1",
    ];
    for (valid, method, duplicate, params) in [
        (
            &register[..],
            "workspace.preset.register",
            "--registration-request-id",
            json!({"registrationRequestId":"sample", "projectRef":"sample", "kind":"build",
                   "templateRef":"sample", "timeoutSeconds":"1"}),
        ),
        (
            &update[..],
            "workspace.preset.update",
            "--mutation-request-id",
            json!({"mutationRequestId":"sample", "projectRef":"sample", "presetRef":"sample",
                   "expectedGeneration":"1", "kind":"build", "templateRef":"sample",
                   "timeoutSeconds":"1"}),
        ),
        (
            &remove[..],
            "workspace.preset.remove",
            "--mutation-request-id",
            json!({"mutationRequestId":"sample", "projectRef":"sample", "presetRef":"sample",
                   "expectedGeneration":"1"}),
        ),
    ] {
        let invocation = parse(&args(valid)).unwrap();
        assert_eq!(invocation.method, method);
        assert_eq!(
            Value::Object(invocation.params.unwrap()),
            params,
            "{method}"
        );
        assert!(
            parse(&args(&[&valid[..3], &["--help"]].concat()))
                .unwrap()
                .help
        );
        // `--socket` is the macOS compatibility option; elsewhere it is refused.
        let with_socket = parse(&args(&[valid, &["--socket", "sample"]].concat()));
        if cfg!(target_os = "macos") {
            assert_eq!(with_socket.unwrap().method, method);
        } else {
            assert_eq!(with_socket.unwrap_err().code, "unsupportedOnPlatform");
        }
        for extra in [
            vec!["--no-such-option"],
            vec![duplicate, "sample"],
            vec!["--output", "jsonl"],
        ] {
            let error = parse(&args(&[valid, &extra[..]].concat())).unwrap_err();
            assert_eq!(error.code, "invalidOption", "{method} {extra:?}");
        }
        let missing = parse(&args(&valid[..3])).unwrap_err();
        assert_eq!(missing.code, "invalidOption", "{method}");
    }
    // Every definition option maps to the typed field Swift's handler reads.
    let full = parse(&args(&[
        "workspace",
        "preset",
        "register",
        "--registration-request-id",
        "preset-signing",
        "--project",
        "project-a",
        "--kind",
        "signing",
        "--template",
        "openharmony.local-sign@1",
        "--toolchain",
        "toolchain:sha256:b",
        "--toolchain-generation",
        "1",
        "--credential",
        "credential:sha256-c",
        "--timeout-seconds",
        "3600",
        "--module",
        "entry",
        "--product",
        "default",
        "--build-mode",
        "debug",
        "--relative-source-map",
        "entry/a.map",
    ]))
    .unwrap();
    assert_eq!(
        Value::Object(full.params.unwrap()),
        json!({"registrationRequestId":"preset-signing", "projectRef":"project-a",
               "kind":"signing", "templateRef":"openharmony.local-sign@1",
               "toolchainRef":"toolchain:sha256:b", "toolchainGeneration":"1",
               "credentialRef":"credential:sha256-c", "timeoutSeconds":"3600",
               "module":"entry", "product":"default", "buildMode":"debug",
               "relativeSourceMap":"entry/a.map"})
    );
    // The registry's value grammars refuse before any request is sent.
    for (valid, option, value) in [
        (&register[..], "--kind", "sideways"),
        (&register[..], "--timeout-seconds", "3601"),
        (&register[..], "--timeout-seconds", "0600"),
        (&update[..], "--expected-generation", "0"),
        (&remove[..], "--expected-generation", "01"),
    ] {
        let mut argv = valid.to_vec();
        let at = argv.iter().position(|a| *a == option).unwrap();
        argv[at + 1] = value;
        assert_eq!(
            parse(&args(&argv)).unwrap_err().code,
            "invalidOption",
            "{option} {value}"
        );
    }
    let mut generation = register.to_vec();
    generation.extend(["--toolchain-generation", "0"]);
    assert_eq!(parse(&args(&generation)).unwrap_err().code, "invalidOption");
    let mut project = vec![
        "workspace",
        "project",
        "update",
        "--project",
        "sample",
        "--expected-generation",
        "0",
        "--kind",
        "arkdeck",
        "--root",
        "/tmp",
    ];
    assert_eq!(parse(&args(&project)).unwrap_err().code, "invalidOption");
    project[6] = "1";
    assert!(parse(&args(&project)).is_ok());
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
                // The CLI may already have read the answer and closed its end;
                // only a failure other than that is the fake's.
                if let Err(error) = reader.get_mut().shutdown(Shutdown::Write) {
                    assert_eq!(error.kind(), std::io::ErrorKind::NotConnected, "{error}");
                }
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
