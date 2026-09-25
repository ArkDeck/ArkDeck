//! `runtime service status|verify|restart` against Swift's `LaunchAgentService`
//! and `runAgentDaemon` semantics.
//!
//! The service manager runs over a temporary home. launchd is always a fake:
//! library tests hand the service manager a recording `LaunchctlRunner`, and
//! the process tests relocate the home with `CFFIXED_USER_HOME`, which never
//! reaches `/bin/launchctl` — only a recording script named for that home, or
//! nothing at all. The daemon is a fake Runtime on the installed socket that
//! answers the published methods with schema-valid documents; `verify --job`
//! reopens the Swift-recorded `observe.device@1` Job of the agent-execution
//! oracle (`rust/tests/fixtures/agent-execution/cases.json`).
#![cfg(target_os = "macos")]

use arkdeck_cli::runtime_service::{
    LaunchAgentPaths, PlainFailure, ServiceAnswer, ServiceHost, restart_leaf, status_leaf,
    verify_leaf,
};
use arkdeck_cli::runtime_service_install::{
    ANALYZER_PROBE_ANSWER, ANALYZER_PROBE_LISTING, install_leaf, path_install_leaf, uninstall_leaf,
    update_leaf,
};
use arkdeck_contract::{CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION, validate_method_value};
use arkdeck_platform::launchd::{LaunchctlOutput, LaunchctlRunner};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

const DIGEST: &str = "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684";
const OTHER_DIGEST: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const JOB: &str = "job-73b1cb9a96d12a0ea736a065afdf5abd";
const REVISION: &str = "e17de5f6-fc4c-4bbf-9486-81b47431095a";

fn nonce() -> String {
    format!(
        "{:012x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap()) & 0xffff_ffff_ffff
    )
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
}

fn write_executable(path: &Path, bytes: &[u8]) {
    directory(path.parent().unwrap());
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

fn digest(path: &Path) -> String {
    arkdeck_contract::sha256_hex(&fs::read(path).unwrap())
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// A temporary account home, short enough for its daemon socket path.
struct Home {
    root: PathBuf,
    paths: LaunchAgentPaths,
}

impl Home {
    fn new() -> Self {
        let root = PathBuf::from(format!("/private/tmp/ads-{}", nonce()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let home = root.join("h");
        fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        Self {
            paths: LaunchAgentPaths::for_home(&home),
            root,
        }
    }

    fn hdc(&self) -> PathBuf {
        self.paths.home.join("Toolchains/hdc")
    }

    /// One installation as Swift's `install` leaves it: the helper bundle,
    /// a pinned HDC, the rendered plist, the receipt, the log and state
    /// directories.
    fn install(&self) -> BTreeMap<String, String> {
        let bundle = &self.paths.installed_daemon_bundle;
        directory(&bundle.join("Contents/MacOS"));
        fs::write(bundle.join("Contents/Info.plist"), INFO_PLIST).unwrap();
        write_executable(&self.paths.installed_daemon, b"#!/bin/sh\nexit 0\n");
        write_executable(&self.hdc(), b"hdc-v1");
        directory(&self.paths.log_directory);
        directory(&self.paths.state_directory);
        let environment = BTreeMap::from([
            ("ARKDECK_HDC_PATH".to_owned(), text(&self.hdc())),
            (
                "ARKDECK_ANALYZER_PATH".to_owned(),
                text(&self.paths.installed_daemon),
            ),
            (
                "ARKDECK_WORKSPACE_INSPECTOR".to_owned(),
                "/usr/bin/grep".to_owned(),
            ),
        ]);
        self.write_plist(&text(&self.paths.installed_daemon), &environment);
        self.write_receipt(&self.receipt());
        environment
    }

    fn receipt(&self) -> Value {
        json!({
            "schemaVersion": "arkdeck-launchagent-install/v1",
            "installedAtUTC": "2026-08-08T12:00:00Z",
            "daemonPath": text(&self.paths.installed_daemon),
            "daemonSHA256": digest(&self.paths.installed_daemon),
            "hdcPath": text(&self.hdc()),
            "hdcSHA256": digest(&self.hdc()),
        })
    }

    fn write_receipt(&self, receipt: &Value) {
        directory(self.paths.receipt.parent().unwrap());
        fs::write(
            &self.paths.receipt,
            serde_json::to_vec_pretty(receipt).unwrap(),
        )
        .unwrap();
    }

    fn write_plist(&self, program: &str, environment: &BTreeMap<String, String>) {
        directory(self.paths.plist.parent().unwrap());
        fs::write(
            &self.paths.plist,
            plist(
                program,
                environment,
                &text(&self.paths.standard_output),
                &text(&self.paths.standard_error),
            ),
        )
        .unwrap();
    }

    fn write_instance(&self, pid: i32) {
        fs::write(
            self.paths.state_directory.join("instance.json"),
            serde_json::to_vec(&json!({"pid": pid, "socketPath": text(&self.paths.socket),
                "protocolVersion": "1.0.0", "startedAtUTC": "2026-09-24T00:00:00Z"}))
            .unwrap(),
        )
        .unwrap();
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

const INFO_PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.arkdeck.agentd</string>
<key>CFBundleExecutable</key><string>arkdeck-agentd</string>
</dict></plist>
"#;

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The LaunchAgent template as Swift renders it (keys sorted, as
/// CoreFoundation writes them).
fn plist(
    program: &str,
    environment: &BTreeMap<String, String>,
    stdout: &str,
    stderr: &str,
) -> String {
    let mut variables = String::new();
    for (key, value) in environment {
        variables.push_str(&format!(
            "\t\t<key>{}</key>\n\t\t<string>{}</string>\n",
            escape(key),
            escape(value)
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
<plist version=\"1.0\">\n<dict>\n\
\t<key>EnvironmentVariables</key>\n\t<dict>\n{variables}\t</dict>\n\
\t<key>KeepAlive</key>\n\t<true/>\n\
\t<key>Label</key>\n\t<string>com.arkdeck.agentd</string>\n\
\t<key>LimitLoadToSessionType</key>\n\t<string>Aqua</string>\n\
\t<key>MachServices</key>\n\t<dict>\n\t\t<key>com.arkdeck.agentd</key>\n\t\t<true/>\n\t</dict>\n\
\t<key>ProcessType</key>\n\t<string>Standard</string>\n\
\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>{}</string>\n\t</array>\n\
\t<key>RunAtLoad</key>\n\t<true/>\n\
\t<key>StandardErrorPath</key>\n\t<string>{}</string>\n\
\t<key>StandardOutPath</key>\n\t<string>{}</string>\n\
\t<key>ThrottleInterval</key>\n\t<integer>5</integer>\n\
\t<key>Umask</key>\n\t<integer>63</integer>\n\
</dict>\n</plist>\n",
        escape(program),
        escape(stderr),
        escape(stdout)
    )
}

// MARK: - A recording launchd

type Hook = Box<dyn Fn() + Send>;

/// Records every argument array and answers as launchd would: `print` by
/// whether the service is loaded, `bootout` unloads it, `bootstrap` answers
/// the queued statuses (then 0) and loads it on success.
#[derive(Default)]
struct Launchd {
    calls: Mutex<Vec<Vec<String>>>,
    loaded: AtomicBool,
    bootstrap: Mutex<VecDeque<i32>>,
    on_bootout: Mutex<Option<Hook>>,
    on_bootstrap: Mutex<Option<Hook>>,
}

impl Launchd {
    fn loaded() -> Self {
        let launchd = Self::default();
        launchd.loaded.store(true, Ordering::SeqCst);
        launchd
    }

    fn calls(&self) -> Vec<String> {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .map(|call| call.join(" "))
            .collect()
    }
}

impl LaunchctlRunner for Launchd {
    fn run(&self, arguments: &[String]) -> io::Result<LaunchctlOutput> {
        self.calls.lock().unwrap().push(arguments.to_vec());
        let status = match arguments[0].as_str() {
            "print" => {
                if self.loaded.load(Ordering::SeqCst) {
                    0
                } else {
                    113
                }
            }
            "bootout" => {
                self.loaded.store(false, Ordering::SeqCst);
                if let Some(hook) = self.on_bootout.lock().unwrap().as_ref() {
                    hook();
                }
                0
            }
            "bootstrap" => {
                let status = self.bootstrap.lock().unwrap().pop_front().unwrap_or(0);
                if status == 0 {
                    self.loaded.store(true, Ordering::SeqCst);
                    if let Some(hook) = self.on_bootstrap.lock().unwrap().as_ref() {
                        hook();
                    }
                }
                status
            }
            "enable" => 0,
            other => panic!("unexpected launchctl subcommand {other}"),
        };
        Ok(LaunchctlOutput {
            status,
            stdout: Vec::new(),
            stderr: if status == 0 {
                Vec::new()
            } else {
                format!("Bootstrap failed: {status}: Input/output error\n").into_bytes()
            },
        })
    }
}

// MARK: - A fake Runtime on the installed socket

#[derive(Default)]
struct RuntimeState {
    up: bool,
    digest: String,
    /// `job.list` pages by cursor (`""` for the first page).
    pages: BTreeMap<String, Value>,
    answers: BTreeMap<String, Value>,
    requests: Vec<(String, Value)>,
}

struct Runtime {
    state: Arc<Mutex<RuntimeState>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

fn health(digest: &str) -> Value {
    json!({"status": "ok", "protocolVersion": PROTOCOL_VERSION,
        "contractIdentity": CONTRACT_IDENTITY, "catalogDigest": digest,
        "providers": ["hdc"], "publishedMethods": METHODS})
}

impl Runtime {
    fn start(socket: &Path) -> Self {
        let state = Arc::new(Mutex::new(RuntimeState {
            up: true,
            digest: DIGEST.into(),
            ..RuntimeState::default()
        }));
        let listener = UnixListener::bind(socket).unwrap();
        fs::set_permissions(socket, fs::Permissions::from_mode(0o600)).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (state, stop) = (state.clone(), stop.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((stream, _)) => serve(stream, &state),
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                        Err(error) => panic!("{error}"),
                    }
                }
            })
        };
        Self {
            state,
            stop,
            thread: Some(thread),
        }
    }

    fn answer(&self, method: &str, answer: Value) {
        self.state
            .lock()
            .unwrap()
            .answers
            .insert(method.into(), answer);
    }

    fn page(&self, cursor: &str, page: Value) {
        validate_method_value("job.list", "result", &page).expect("a published job.list page");
        self.state.lock().unwrap().pages.insert(cursor.into(), page);
    }

    fn methods(&self) -> Vec<String> {
        self.state
            .lock()
            .unwrap()
            .requests
            .iter()
            .map(|(method, _)| method.clone())
            .collect()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

fn serve(stream: std::os::unix::net::UnixStream, state: &Mutex<RuntimeState>) {
    stream.set_nonblocking(false).unwrap();
    if stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .is_err()
    {
        return;
    }
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let request: Value = serde_json::from_str(&line).unwrap();
        let method = request["method"].as_str().unwrap().to_owned();
        let answer = {
            let mut state = state.lock().unwrap();
            // A daemon that is down answers nothing: the connection closes.
            if !state.up {
                return;
            }
            state
                .requests
                .push((method.clone(), request["params"].clone()));
            match method.as_str() {
                "health" => json!({"ok": true, "result": health(&state.digest)}),
                "job.list" => {
                    let cursor = request["params"]["cursor"].as_str().unwrap_or("");
                    json!({"ok": true, "result": state.pages[cursor]})
                }
                other => state
                    .answers
                    .get(other)
                    .cloned()
                    .unwrap_or_else(|| panic!("no answer for {other}")),
            }
        };
        let mut answer = answer;
        answer["id"] = request["id"].clone();
        if writeln!(reader.get_mut(), "{answer}").is_err() {
            return;
        }
    }
}

// MARK: - Job pages

fn job_row(job: &str, state: &str, current: bool, unknown: bool, finished: Option<&str>) -> Value {
    json!({
        "actualEffect": "readOnly", "createdAtUtc": "2026-07-29T00:00:00Z", "current": current,
        "executionMode": "execute", "failure": null, "finishedAtUtc": finished, "jobId": job,
        "nextAction": {"kind": "wait", "owner": {"id": job, "kind": "job"},
            "reasonCode": "job.running", "resource": {"id": job, "kind": "job"}, "retryAfter": "250ms"},
        "operation": "observe.device@1", "outcome": state, "outcomeUnknown": unknown,
        "outstandingResidueCount": 0, "processProgress": null, "recoveryEpochId": null,
        "resolvedByTargetAliasResolutionId": null, "schemaVersion": "arkdeck.job-summary/1",
        "sessionId": format!("session-{job}"),
        "sessionPublication": {"catalogGeneration": null, "manifestSha256": null,
            "reasonCode": "noCurrentPublicationRecord", "state": "unavailable"},
        "startedAtUtc": null, "state": state, "supersededByRecoveryEpochId": null,
        "targetId": "TGT-PAGED-WIRE", "threadId": null, "timeline": null,
        "waitingForHuman": false, "workspaceKind": "viewer",
    })
}

fn page(items: Vec<Value>, next: Option<&str>) -> Value {
    json!({"hasMore": next.is_some(), "items": items,
        "nextCursor": next.map(|cursor| format!("{REVISION}.{cursor}")),
        "order": "createdAtDescJobIdAsc", "pageKind": "snapshot",
        "schemaVersion": "arkdeck.cli.page/1", "snapshotRevision": REVISION})
}

fn closed_unknown(job: &str) -> Value {
    job_row(
        job,
        "waitingForRecovery",
        true,
        true,
        Some("2026-09-01T00:00:00Z"),
    )
}

// MARK: - The service manager over a temporary home

fn canonical(bundle: &Path) -> Result<PathBuf, String> {
    bundle.canonicalize().map_err(|error| error.to_string())
}

fn signed(_: &Path) -> Result<(), String> {
    Ok(())
}

fn unsigned(_: &Path) -> Result<(), String> {
    Err("facade signature does not match ArkDeck".into())
}

fn fixed_now() -> String {
    "2026-09-24T00:00:00Z".into()
}

fn host<'a>(home: &Home, launchd: &'a Launchd) -> ServiceHost<'a> {
    ServiceHost {
        paths: home.paths.clone(),
        uid: arkdeck_platform::effective_user_id(),
        launchctl: launchd,
        validate_daemon_bundle: &canonical,
        validate_facade: &signed,
        now_utc: &fixed_now,
        connection_timeout: Duration::from_secs(5),
        poll_interval: Duration::from_millis(20),
        default_daemon_bundle: None,
        relocated_home: true,
        preflight_timeout: Duration::from_secs(30),
        spelling: "runtime service",
    }
}

fn domain() -> String {
    format!("gui/{}", arkdeck_platform::effective_user_id())
}

fn print_call() -> String {
    format!("print {}/com.arkdeck.agentd", domain())
}

fn launch_agent(answer: &ServiceAnswer) -> &Value {
    &answer.document.as_ref().expect("a document")["launchAgent"]
}

fn diagnostics(answer: &ServiceAnswer) -> Vec<String> {
    launch_agent(answer)["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|diagnostic| diagnostic.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn status_of_an_absent_service_reads_nothing_from_launchd() {
    let home = Home::new();
    let launchd = Launchd::default();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(answer.failure, None);
    let paths = &home.paths;
    assert_eq!(
        answer.document.unwrap(),
        json!({
            "launchAgent": {
                "installed": false, "loaded": false, "launchDomain": domain(),
                "plistPath": text(&paths.plist), "socketPath": text(&paths.socket),
                "socketPresent": false, "standardOutputPath": text(&paths.standard_output),
                "standardErrorPath": text(&paths.standard_error),
                "diagnostics": ["LaunchAgent is not installed"], "ready": false,
            },
            "daemonHealth": {"status": "socket_absent"},
        })
    );
    assert!(launchd.calls().is_empty(), "{:?}", launchd.calls());
}

#[test]
fn status_of_a_ready_service_pins_both_identities_and_asks_the_daemon_for_health() {
    let home = Home::new();
    let environment = home.install();
    let launchd = Launchd::loaded();
    let runtime = Runtime::start(&home.paths.socket);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    let paths = &home.paths;
    assert_eq!(answer.failure, None);
    assert_eq!(
        answer.document.unwrap(),
        json!({
            "launchAgent": {
                "installed": true, "loaded": true, "launchDomain": domain(),
                "plistPath": text(&paths.plist),
                "daemonPath": text(&paths.installed_daemon),
                "daemonSHA256": digest(&paths.installed_daemon),
                "hdcPath": environment["ARKDECK_HDC_PATH"],
                "hdcSHA256": digest(&home.hdc()),
                "socketPath": text(&paths.socket), "socketPresent": true,
                "standardOutputPath": text(&paths.standard_output),
                "standardErrorPath": text(&paths.standard_error),
                "diagnostics": [], "ready": true,
            },
            "daemonHealth": health(DIGEST),
        })
    );
    assert_eq!(launchd.calls(), [print_call()]);
    assert_eq!(runtime.methods(), ["health"]);
}

#[test]
fn status_names_each_drift_and_is_not_ready() {
    let home = Home::new();
    let environment = home.install();
    let launchd = Launchd::default();
    // Not loaded: launchd is asked, the daemon is not.
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer),
        [format!("LaunchAgent is not loaded in {}", domain())]
    );
    assert_eq!(launch_agent(&answer)["ready"], false);

    // Loaded, no socket yet.
    launchd.loaded.store(true, Ordering::SeqCst);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer),
        [
            "daemon socket is absent; service may still be starting; re-run status, then inspect the LaunchAgent error log"
        ]
    );
    assert_eq!(
        answer.document.as_ref().unwrap()["daemonHealth"],
        json!({"status": "socket_absent"})
    );

    // The HDC bytes change after installation.
    fs::write(home.hdc(), b"hdc-v2").unwrap();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "HDC identity drifted since installation"
    );
    assert_eq!(launch_agent(&answer)["hdcSHA256"], digest(&home.hdc()));
    home.write_receipt(&home.receipt());

    // A stale socket file answers nothing.
    let listener = UnixListener::bind(&home.paths.socket).unwrap();
    drop(listener);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(diagnostics(&answer), Vec::<String>::new());
    let daemon_health = &answer.document.as_ref().unwrap()["daemonHealth"];
    assert_eq!(daemon_health["status"], "unreachable");
    assert!(daemon_health["detail"].is_string());
    fs::remove_file(&home.paths.socket).unwrap();

    // The receipt is missing or of another schema.
    fs::remove_file(&home.paths.receipt).unwrap();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert!(
        diagnostics(&answer)[0].starts_with("install receipt is unavailable or invalid: "),
        "{:?}",
        diagnostics(&answer)
    );
    let mut receipt = home.receipt();
    receipt["schemaVersion"] = json!("arkdeck-launchagent-install/v2");
    home.write_receipt(&receipt);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "install receipt is unavailable or invalid: LaunchAgent configuration failed: unsupported install receipt schema"
    );
    home.write_receipt(&home.receipt());

    // The plist loses its lifecycle, or its analyzer names another daemon.
    let mut drifted = environment.clone();
    drifted.remove("ARKDECK_HDC_PATH");
    home.write_plist(&text(&home.paths.installed_daemon), &drifted);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: plist must keep the user-session lifecycle, Mach service, log paths, one daemon argument and an explicit ARKDECK_HDC_PATH"
    );
    assert_eq!(launch_agent(&answer).get("daemonPath"), None);
    let mut drifted = environment.clone();
    drifted.insert("ARKDECK_ANALYZER_PATH".into(), "/usr/bin/true".into());
    home.write_plist(&text(&home.paths.installed_daemon), &drifted);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: the analyzer path must be this installation's own daemon"
    );
    home.write_plist(&text(&home.paths.installed_daemon), &environment);

    // A daemon path other than the installed one must carry the paired Swift
    // daemon's digest, and must be the ArkDeck-managed transport.
    let other = home.paths.home.join("other/arkdeck-agentd");
    write_executable(&other, b"other");
    home.write_plist(&text(&other), &environment);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: paired Swift daemon identity drifted; run runtime service update"
    );
    let mut paired = environment.clone();
    paired.insert(
        "ARKDECK_SWIFT_SHA256".into(),
        digest(&home.paths.installed_daemon),
    );
    home.write_plist(&text(&other), &paired);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[..2],
        [
            "ProgramArguments does not name the ArkDeck-managed daemon path",
            "arkdeck-agentd identity drifted since installation"
        ]
    );
    home.write_plist(&text(&home.paths.installed_daemon), &environment);

    // An unsigned sibling facade throws out of the configuration checks.
    let facade = home
        .paths
        .installed_daemon_bundle
        .join("Contents/MacOS/arkdeck-facade");
    write_executable(&facade, b"facade");
    let mut unsigned_host = host(&home, &launchd);
    unsigned_host.validate_facade = &unsigned;
    let answer = status_leaf(&unsigned_host, "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: invalid executable: facade signature is invalid; run runtime service update"
    );
    // A valid facade is the transport the plist must name.
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "ProgramArguments does not name the ArkDeck-managed daemon path"
    );
    fs::remove_file(&facade).unwrap();

    // The installed helper fails its production validation.
    let refuse =
        |_: &Path| -> Result<PathBuf, String> { Err("helper signature does not match".into()) };
    let mut invalid_bundle_host = host(&home, &launchd);
    invalid_bundle_host.validate_daemon_bundle = &refuse;
    let answer = status_leaf(&invalid_bundle_host, "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "installed daemon helper bundle is invalid: helper signature does not match"
    );
    assert!(launchd.calls().iter().all(|call| *call == print_call()));
}

/// A release unit as `ArkForgeBundleManifestWriter` writes one.
fn arkforge_bundle(root: &Path) -> PathBuf {
    let bundle = root.join("ArkForge.bundle");
    let members = [
        ("Contents/MacOS/arkforge", "cli", None, &b"arkforge"[..]),
        (
            "Contents/MacOS/arkforged",
            "daemon",
            None,
            &b"arkforged"[..],
        ),
        (
            "Contents/Resources/profiles/dayu200.json",
            "profile",
            Some("org.openharmony.dayu200"),
            &b"{}"[..],
        ),
    ];
    let mut declared = Vec::new();
    for (path, role, profile, bytes) in members {
        let file = bundle.join(path);
        directory(file.parent().unwrap());
        fs::write(&file, bytes).unwrap();
        let mut member = json!({"path": path, "sha256": arkdeck_contract::sha256_hex(bytes),
            "bytes": bytes.len(), "role": role});
        if let Some(profile) = profile {
            member["profileId"] = json!(profile);
        }
        declared.push(member);
    }
    let manifest = bundle.join("Contents/Resources/arkforge-bundle.json");
    fs::write(
        &manifest,
        serde_json::to_vec(
            &json!({"schema": "arkforge.release-bundle/v1", "version": "1.0.0",
            "members": declared}),
        )
        .unwrap(),
    )
    .unwrap();
    bundle
}

#[test]
fn status_measures_the_one_arkforge_release_unit_and_refuses_retired_lane_names() {
    let home = Home::new();
    let mut environment = home.install();
    let launchd = Launchd::loaded();
    let _runtime = Runtime::start(&home.paths.socket);
    let bundle = arkforge_bundle(&home.root);
    let lane = json!({
        "bundlePath": text(&bundle),
        "manifestSHA256": digest(&bundle.join("Contents/Resources/arkforge-bundle.json")),
        "daemonPath": text(&bundle.join("Contents/MacOS/arkforged")),
        "daemonSHA256": digest(&bundle.join("Contents/MacOS/arkforged")),
        "deviceProfilePath": text(&bundle.join("Contents/Resources/profiles/dayu200.json")),
        "campaign": "AFA-AC-7",
    });
    environment.insert("ARKDECK_ARKFORGE_BUNDLE_PATH".into(), text(&bundle));
    environment.insert("ARKDECK_ARKFORGE_CAMPAIGN".into(), " AFA-AC-7\t".into());
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let mut receipt = home.receipt();
    receipt["arkForgeLane"] = lane.clone();
    home.write_receipt(&receipt);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(diagnostics(&answer), Vec::<String>::new());
    assert_eq!(launch_agent(&answer)["arkForgeLane"], lane);
    assert_eq!(launch_agent(&answer)["ready"], true);

    // A member that changes after installation is named and drifts the lane.
    fs::write(bundle.join("Contents/MacOS/arkforged"), b"arkforged-2").unwrap();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer),
        [
            "ArkForge.bundle is invalid: ArkForge bundle member Contents/MacOS/arkforged is 11 bytes, expected 9",
            "ArkForge release bundle drifted since installation"
        ]
    );
    assert_eq!(launch_agent(&answer).get("arkForgeLane"), None);
    fs::write(bundle.join("Contents/MacOS/arkforged"), b"arkforged").unwrap();
    // Nothing undeclared may lie in the bundle.
    fs::write(bundle.join("Contents/Resources/extra"), b"x").unwrap();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "ArkForge.bundle is invalid: ArkForge bundle contains undeclared member: Contents/Resources/extra"
    );
    fs::remove_file(bundle.join("Contents/Resources/extra")).unwrap();

    // The retired three-key names are refused by name; the daemon and HDC
    // facts beside them are kept.
    environment.insert("ARKDECK_ARKFORGED_PATH".into(), "/x".into());
    environment.insert("ARKDECK_ARKFORGE_PROFILE_PATH".into(), "/y".into());
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "ARKDECK_ARKFORGED_PATH, ARKDECK_ARKFORGE_PROFILE_PATH is retired ArkForge lane configuration. Reconfigure this installation with `arkdeck runtime service update --arkforge-bundle <absolute ArkForge.bundle>`"
    );
    assert_eq!(
        launch_agent(&answer)["daemonSHA256"],
        digest(&home.paths.installed_daemon)
    );
}

#[test]
fn status_pins_an_owner_controlled_arktrace_descriptor_and_refuses_a_world_writable_one() {
    let home = Home::new();
    let mut environment = home.install();
    let launchd = Launchd::loaded();
    let _runtime = Runtime::start(&home.paths.socket);
    // The system temporary directory's ancestors are owner-controlled; a
    // descriptor below `/private/tmp` (world-writable) is not.
    let owned = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("arkdeck-descriptor-{}", nonce()));
    directory(&owned);
    let descriptor = owned.join("arktrace.json");
    let bytes = format!(
        "{{\"distributionRoot\":\"/Applications/ArkTrace.app\",\"formatVersion\":1,\"manifestSHA256\":\"{DIGEST}\"}}"
    );
    fs::write(&descriptor, &bytes).unwrap();
    fs::set_permissions(&descriptor, fs::Permissions::from_mode(0o600)).unwrap();
    environment.insert("ARKDECK_ARKTRACE_DESCRIPTOR".into(), text(&descriptor));
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let pinned = json!({"descriptorPath": text(&descriptor),
        "descriptorSHA256": arkdeck_contract::sha256_hex(bytes.as_bytes()),
        "descriptorByteCount": bytes.len()});
    let mut receipt = home.receipt();
    receipt["arkTraceDescriptor"] = pinned.clone();
    home.write_receipt(&receipt);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(diagnostics(&answer), Vec::<String>::new());
    assert_eq!(launch_agent(&answer)["arkTraceDescriptor"], pinned);

    // The closed three-member schema.
    fs::write(
        &descriptor,
        br#"{"distributionRoot":"/a","formatVersion":2,"manifestSHA256":"x"}"#,
    )
    .unwrap();
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: ArkTrace distribution descriptor schema is invalid"
    );
    // Below world-writable `/private/tmp`.
    let exposed = home.root.join("arktrace.json");
    fs::write(&exposed, &bytes).unwrap();
    environment.insert("ARKDECK_ARKTRACE_DESCRIPTOR".into(), text(&exposed));
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: ArkTrace distribution descriptor ancestors must be owner-controlled"
    );
    fs::remove_dir_all(&owned).unwrap();
}

#[test]
fn status_keeps_the_legacy_workspace_pair_only_when_it_is_the_closed_demo_profile() {
    let home = Home::new();
    let mut environment = home.install();
    let launchd = Launchd::loaded();
    let _runtime = Runtime::start(&home.paths.socket);
    let project = home.root.join("Developer/WaterFlow");
    directory(&project.join("entry/src/main"));
    fs::write(project.join("build-profile.json5"), b"{}").unwrap();
    fs::write(project.join("entry/src/main/module.json5"), b"{}").unwrap();
    let sdk = home.root.join("sdk");
    directory(&sdk.join("default/openharmony"));
    environment.insert(
        "ARKDECK_WORKSPACE_PROJECTS".into(),
        format!("demo-app={}", text(&project)),
    );
    environment.insert("ARKDECK_WORKSPACE_ACTIVE_PROJECT".into(), "demo-app".into());
    environment.insert("ARKDECK_DEVECO_SDK_HOME".into(), text(&sdk));
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let mut receipt = home.receipt();
    receipt["workspaceProjectPath"] = json!(text(&project));
    receipt["devecoSDKPath"] = json!(text(&sdk));
    home.write_receipt(&receipt);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(diagnostics(&answer), Vec::<String>::new());
    assert_eq!(
        launch_agent(&answer)["workspaceProjectPath"],
        text(&project)
    );
    assert_eq!(launch_agent(&answer)["devecoSDKPath"], text(&sdk));

    environment.insert("ARKDECK_WORKSPACE_ACTIVE_PROJECT".into(), "other".into());
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let answer = status_leaf(&host(&home, &launchd), "ctl-1");
    assert_eq!(
        diagnostics(&answer)[0],
        "configuration is invalid: LaunchAgent configuration failed: workspace environment must be the closed demo-app ProjectProfile configuration"
    );
}

// MARK: - verify --job

fn oracle_exchange(name: &str) -> Value {
    let cases: Value = serde_json::from_slice(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/agent-execution/cases.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let mut answer = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap_or_else(|| panic!("no {name} exchange"))["answer"]
        .clone();
    // The oracle records a fresh snapshot identity as a placeholder.
    if answer["result"]["snapshotRevision"] == "<snapshotRevision>" {
        answer["result"]["snapshotRevision"] = json!(REVISION);
    }
    answer
}

/// The recorded Job's status as `job.status` answers it once it succeeded.
fn persisted_status() -> Value {
    let status = json!({
        "actualEffect": "readOnly", "createdAtUtc": "2026-09-14T00:00:00Z",
        "executionMode": "execute", "failure": null, "finishedAtUtc": "2026-09-14T00:00:00Z",
        "jobId": JOB,
        "nextAction": {"kind": "readResult", "owner": {"id": JOB, "kind": "job"},
            "reasonCode": "job.resultAvailable", "resource": {"id": JOB, "kind": "job"}},
        "operation": "observe.device@1", "outcome": "succeeded", "outcomeUnknown": false,
        "outstandingResidueCount": 0, "processProgress": null, "recoveryEpochId": null,
        "resolvedByTargetAliasResolutionId": null, "schemaVersion": "arkdeck.job-status/1",
        "sessionId": format!("session-{JOB}"),
        "sessionPublication": {"catalogGeneration": null, "manifestSha256": null,
            "reasonCode": "noCurrentPublicationRecord", "state": "unavailable"},
        "startedAtUtc": "2026-09-14T00:00:00Z", "state": "succeeded",
        "supersededByRecoveryEpochId": null, "targetId": "TGT-3ba3f5f43b92", "threadId": null,
        "waitingForHuman": false, "workspaceKind": "viewer",
    });
    validate_method_value("job.status", "result", &status).expect("a published job.status");
    json!({"ok": true, "result": status})
}

fn ready_for_verify(home: &Home) -> (Launchd, Runtime) {
    home.install();
    let launchd = Launchd::loaded();
    let runtime = Runtime::start(&home.paths.socket);
    runtime.answer("job.status", persisted_status());
    runtime.answer("job.evidence", oracle_exchange("observed.evidence"));
    runtime.answer("artifact.list", oracle_exchange("observed.artifacts"));
    (launchd, runtime)
}

fn job_options(job: &str) -> Map<String, Value> {
    Map::from_iter([("jobId".to_owned(), json!(job))])
}

#[test]
fn verify_reopens_the_recorded_observe_job_through_durable_reads_only() {
    let home = Home::new();
    let (launchd, runtime) = ready_for_verify(&home);
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    assert_eq!(answer.failure, None, "{:?}", answer.document);
    let document = answer.document.unwrap();
    assert_eq!(document["runtimeVerified"], true);
    assert_eq!(document["launchAgent"]["ready"], true);
    let report = &document["runtime"];
    assert_eq!(
        report["schemaVersion"],
        "arkdeck-headless-runtime-reopen/v1"
    );
    assert_eq!(report["classification"], "persistedRuntimeReceipt");
    assert_eq!(report["daemonCatalogDigest"], DIGEST);
    assert_eq!(report["blockers"], json!([]));
    assert_eq!(report["runtimeVerified"], true);
    assert_eq!(
        report["checks"],
        json!({"udsHealthVerified": true, "terminalStatusVerified": true,
            "trustedEvidenceVerified": true, "artifactsVerified": true,
            "runtimePostflightVerified": true})
    );
    assert_eq!(
        report["status"],
        json!({"jobId": JOB, "operationReference": "observe.device@1",
            "targetId": "TGT-3ba3f5f43b92", "state": "succeeded", "waitingForHuman": false,
            "outcomeUnknown": false, "outstandingResidueCount": 0, "executionMode": "execute",
            "actualEffect": "readOnly", "startedAtUtc": "2026-09-14T00:00:00Z",
            "finishedAtUtc": "2026-09-14T00:00:00Z"})
    );
    // The trusted facts are the evidence as Swift decodes it: members it does
    // not model dropped, nulls omitted, counts as integers.
    let facts = &report["trustedFacts"];
    for dropped in [
        "schemaVersion",
        "status",
        "parameters",
        "inventoryAvailable",
        "missingRequiredArtifacts",
        "traceProbeAfter",
        "traceProbeBefore",
        "recoveryEpoch",
    ] {
        assert_eq!(facts.get(dropped), None, "{dropped}");
    }
    assert_eq!(
        facts["authority"],
        json!({"kind": "defaultReadOnlyPolicy", "reference": "default-read-only-policy",
            "admittedAtUtc": "2026-09-14T00:00:00Z"})
    );
    assert_eq!(facts["artifacts"][0]["byteCount"], 240);
    assert_eq!(
        facts["observation"]["preflightSteps"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    // Metadata only, in identity order.
    let inventory = report["artifactInventory"].as_array().unwrap();
    let ids: Vec<&str> = inventory
        .iter()
        .map(|a| a["artifactId"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        [
            "ART-5ab8ddce1b835cb95173c1a4b08a7e5d",
            "ART-e04cd422be1334393565566a35c7ff20",
            "ART-e52440fb7438dd09bd82755af4c243a9"
        ]
    );
    assert_eq!(
        inventory[0],
        json!({"artifactId": "ART-5ab8ddce1b835cb95173c1a4b08a7e5d", "jobId": JOB,
            "name": "tool-facts.json", "byteCount": 240,
            "sha256": "75eaaaac8879fd393e7ae2d38a22ee422c5aaec4b1c4384320b12d94d2ae022e",
            "status": "published", "sourceOperation": "observe.device@1",
            "targetId": "TGT-3ba3f5f43b92", "bindingRevision": 1,
            "stableIdentitySha256": "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"})
    );
    // Durable reads only; no submit, run, cancel or reconcile.
    let methods = runtime.methods();
    assert!(
        methods.iter().all(
            |m| ["health", "job.status", "job.evidence", "artifact.list"].contains(&m.as_str())
        ),
        "{methods:?}"
    );
    assert_eq!(launchd.calls(), [print_call()]);
}

#[test]
fn verify_reports_drift_as_blockers_and_fails_after_its_document() {
    let home = Home::new();
    let (launchd, runtime) = ready_for_verify(&home);
    // The evidence now pins another digest for one Artifact.
    let mut evidence = oracle_exchange("observed.evidence");
    evidence["result"]["artifacts"][0]["sha256"] = json!(OTHER_DIGEST);
    runtime.answer("job.evidence", evidence);
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    let report = &answer.document.as_ref().unwrap()["runtime"];
    assert_eq!(answer.document.as_ref().unwrap()["runtimeVerified"], false);
    assert_eq!(
        report["blockers"],
        json!([
            "artifacts:required immutable inventory is incomplete or drifted",
            "runtimePostflight:typed steps, evidence or Artifact closure is incomplete"
        ])
    );
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 1,
            message:
                "persisted Runtime status, evidence, Artifact or postflight verification failed"
                    .into()
        })
    );

    // Another catalog: the daemon's health no longer matches the evidence.
    runtime.answer("job.evidence", oracle_exchange("observed.evidence"));
    runtime.state.lock().unwrap().digest = OTHER_DIGEST.into();
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    assert_eq!(
        answer.document.as_ref().unwrap()["runtime"]["blockers"],
        json!(["udsHealth:catalog digest is missing or drifted"])
    );
    runtime.state.lock().unwrap().digest = DIGEST.into();

    // An unreadable inventory is a blocker of an otherwise complete report.
    runtime.answer(
        "artifact.list",
        json!({"ok": false, "error": {"code": "operationUnavailable", "message": "Artifact store is unavailable",
            "details": {"newDispatchCount": 0, "phase": "artifactOwner"}}}),
    );
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    let blockers = answer.document.as_ref().unwrap()["runtime"]["blockers"].clone();
    assert!(
        blockers.as_array().unwrap()[0]
            .as_str()
            .unwrap()
            .starts_with("artifactInventory:"),
        "{blockers}"
    );
}

#[test]
fn verify_fails_without_a_document_when_a_daemon_fact_is_unreadable() {
    let home = Home::new();
    let (launchd, runtime) = ready_for_verify(&home);
    let mut evidence = oracle_exchange("observed.evidence");
    evidence["result"]["artifacts"][0]["byteCount"] = json!("0240");
    runtime.answer("job.evidence", evidence);
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    assert_eq!(answer.document, None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 1,
            message: "job.evidence contains undecodable trusted Runtime facts: Evidence Artifact count is not canonical".into()
        })
    );
    for unsafe_id in ["", "job/../x", &"j".repeat(161)] {
        let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(unsafe_id));
        assert_eq!(answer.document, None);
        assert_eq!(
            answer.failure.unwrap().message,
            "persisted verification job id is unsafe"
        );
    }
}

#[test]
fn verify_of_an_unready_service_emits_its_state_and_opens_no_socket() {
    let home = Home::new();
    let launchd = Launchd::default();
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &job_options(JOB));
    let document = answer.document.unwrap();
    assert_eq!(document["runtime"], Value::Null);
    assert_eq!(document["runtimeVerified"], false);
    assert_eq!(document["launchAgent"]["installed"], false);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "LaunchAgent is not ready: LaunchAgent is not installed".into()
        })
    );
}

/// The requests a fake Runtime received, the per-connection `health`
/// preflights left out.
fn runtime_requests(runtime: &Runtime) -> Vec<(String, Value)> {
    runtime
        .state
        .lock()
        .unwrap()
        .requests
        .iter()
        .filter(|(method, _)| method != "health")
        .cloned()
        .collect()
}

fn fresh_options() -> Map<String, Value> {
    Map::from_iter([
        ("targetId".to_owned(), json!("TGT-3ba3f5f43b92")),
        ("executionId".to_owned(), json!("gj1-observe")),
    ])
}

#[test]
fn verify_without_a_job_runs_observe_through_the_daemon_and_reopens_its_job() {
    let home = Home::new();
    let (launchd, runtime) = ready_for_verify(&home);
    // The run is answered while its Job still runs; its status once it
    // completed, as the Swift-recorded GJ-1 execution.
    runtime.answer("agent.run", oracle_exchange("observed.running"));
    runtime.answer("agent.status", oracle_exchange("observed.status"));
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &fresh_options());
    assert_eq!(answer.failure, None, "{:?}", answer.document);
    let document = answer.document.unwrap();
    assert_eq!(document["runtimeVerified"], true);
    assert_eq!(document["runtime"]["status"]["jobId"], JOB);
    assert_eq!(
        document["runtime"]["schemaVersion"],
        "arkdeck-headless-runtime-reopen/v1"
    );
    assert_eq!(document["agentExecution"]["state"], "completed");
    assert_eq!(document["launchAgent"]["ready"], true);
    let requests = runtime_requests(&runtime);
    let methods: Vec<&str> = requests.iter().map(|(method, _)| method.as_str()).collect();
    assert_eq!(
        methods,
        [
            "agent.run",
            "agent.status",
            "job.status",
            "job.evidence",
            "artifact.list"
        ]
    );
    // The intent Swift's executor sends for the fresh observation.
    assert_eq!(
        requests[0].1,
        json!({"schemaVersion": "arkdeck.agent-execution-request/1",
            "executionId": "gj1-observe", "operation": "observe.device@1", "inputs": {},
            "maximumWaitMilliseconds": "90000", "target": {"targetId": "TGT-3ba3f5f43b92"}})
    );
    assert_eq!(requests[1].1, json!({"executionId": "gj1-observe"}));
}

#[test]
fn a_fresh_verify_that_needs_a_person_or_is_refused_answers_as_swift_does() {
    let home = Home::new();
    let (launchd, runtime) = ready_for_verify(&home);
    // An execution waiting for its published physical action.
    let mut waiting = oracle_exchange("observed.running");
    let result = waiting["result"].as_object_mut().unwrap();
    for key in ["jobId", "jobState", "targetId", "bindingRevision"] {
        result.insert(key.into(), Value::Null);
    }
    result.remove("job");
    let owner = json!({"kind": "agentExecution", "id": "gj1-observe"});
    result.insert("state".into(), json!("waitingForHuman"));
    result.insert("failureCode".into(), Value::Null);
    result.insert(
        "humanAction".into(),
        json!({"schemaVersion": "arkdeck.human-action/1", "actionId": "har-1", "owner": owner,
            "status": "waiting", "resumeReference": "resume-1", "category": "physicalAssistance",
            "choices": [], "createdAt": "2026-09-14T00:00:00Z",
            "minimumAction": "enter recovery mode", "newDispatchCount": 0,
            "selectionSchema": null, "expiresAt": "2026-09-14T00:05:00Z",
            "reasonCode": "device.recoveryModeRequired"}),
    );
    result.insert(
        "nextAction".into(),
        json!({"kind": "humanAction", "owner": owner,
            "resource": {"kind": "humanAction", "id": "har-1"},
            "reasonCode": "device.recoveryModeRequired", "resumeReference": "resume-1",
            "expiresAt": "2026-09-14T00:05:00Z"}),
    );
    runtime.answer("agent.run", waiting.clone());
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &fresh_options());
    let document = answer
        .document
        .unwrap_or_else(|| panic!("{:?}", answer.failure));
    assert_eq!(document["runtimeVerified"], false);
    assert_eq!(document["humanAction"]["resumeReference"], "resume-1");
    assert_eq!(document["runtimeReceipt"], waiting["result"]);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 75,
            message: "paused for physical assistance; resume with: arkdeck agent resume \
                      --resume-reference resume-1"
                .into()
        })
    );
    // A run the daemon refuses before admission is a plain failure.
    runtime.answer("agent.run", oracle_exchange("unadopted.run"));
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &fresh_options());
    assert_eq!(answer.document, None);
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 1);
    assert!(
        failure.message.contains("not registered"),
        "{}",
        failure.message
    );
    // An unready service answers its state and runs nothing.
    let unready = Home::new();
    let launchd = Launchd::default();
    let answer = verify_leaf(&host(&unready, &launchd), "ctl-1", &fresh_options());
    assert_eq!(answer.document.unwrap()["runtime"], Value::Null);
    assert_eq!(answer.failure.unwrap().exit_code, 69);
}

// MARK: - restart

struct Restartable {
    home: Home,
    launchd: Arc<Launchd>,
    runtime: Arc<Runtime>,
}

/// A ready service whose launchd restarts the daemon as a new process: the
/// bootout takes it down and the bootstrap brings it back with another PID.
fn restartable() -> Restartable {
    let home = Home::new();
    home.install();
    home.write_instance(100);
    let launchd = Arc::new(Launchd::loaded());
    let runtime = Arc::new(Runtime::start(&home.paths.socket));
    runtime.page("", page(vec![], None));
    {
        let state = runtime.state.clone();
        *launchd.on_bootout.lock().unwrap() = Some(Box::new(move || {
            state.lock().unwrap().up = false;
        }));
    }
    {
        let state = runtime.state.clone();
        let instance = home.paths.state_directory.join("instance.json");
        let socket = text(&home.paths.socket);
        *launchd.on_bootstrap.lock().unwrap() = Some(Box::new(move || {
            fs::write(
                &instance,
                serde_json::to_vec(&json!({"pid": 200, "socketPath": socket,
                    "protocolVersion": "1.0.0", "startedAtUTC": "2026-09-24T00:00:01Z"}))
                .unwrap(),
            )
            .unwrap();
            state.lock().unwrap().up = true;
        }));
    }
    Restartable {
        home,
        launchd,
        runtime,
    }
}

impl Restartable {
    fn restart(&self, wait: Option<u64>) -> ServiceAnswer {
        restart_leaf(&host(&self.home, &self.launchd), "ctl-1", wait)
    }

    fn launchd_verbs(&self) -> Vec<String> {
        self.launchd
            .calls()
            .iter()
            .map(|call| call.split(' ').next().unwrap().to_owned())
            .collect()
    }
}

#[test]
fn restart_proves_a_new_process_with_the_same_catalog_and_the_same_closed_unknown_jobs() {
    let service = restartable();
    service.runtime.page(
        "",
        page(
            vec![
                closed_unknown("job-parked"),
                job_row(
                    "job-old",
                    "succeeded",
                    false,
                    false,
                    Some("2026-09-01T00:00:00Z"),
                ),
            ],
            None,
        ),
    );
    let answer = service.restart(None);
    assert_eq!(answer.failure, None, "{:?}", answer.document);
    let document = answer.document.unwrap();
    let paths = &service.home.paths;
    assert_eq!(
        document["restart"],
        json!({"schemaVersion": "arkdeck-launchagent-restart/v1",
            "restartedAtUTC": "2026-09-24T00:00:00Z", "launchDomain": domain(),
            "plistPath": text(&paths.plist), "daemonPath": text(&paths.installed_daemon),
            "daemonSHA256": digest(&paths.installed_daemon),
            "hdcSHA256": digest(&service.home.hdc()),
            "preservedStateDirectory": text(&paths.state_directory),
            "preservedLogDirectory": text(&paths.log_directory)})
    );
    let proof = &document["restartProof"];
    assert_eq!(
        proof["schemaVersion"],
        "arkdeck-launchagent-restart-proof/v1"
    );
    assert_eq!(proof["beforeInstance"]["pid"], 100);
    assert_eq!(proof["afterInstance"]["pid"], 200);
    assert_eq!(proof["catalogDigestBefore"], DIGEST);
    assert_eq!(proof["catalogDigestAfter"], DIGEST);
    assert_eq!(proof["blockingJobCountBefore"], 0);
    assert_eq!(proof["preservedUnknownJobIds"], json!(["job-parked"]));
    assert_eq!(document["launchAgent"]["ready"], true);
    assert_eq!(document["daemonHealth"], health(DIGEST));
    // launchd: status, the restart's own status, bootout, bootstrap, the
    // replacement's status. Never kickstart.
    assert_eq!(
        service.launchd.calls(),
        [
            print_call(),
            print_call(),
            format!("bootout {}/com.arkdeck.agentd", domain()),
            format!("bootstrap {} {}", domain(), text(&paths.plist)),
            print_call(),
        ]
    );
    // Before: health, then the complete current-Job snapshot; after: health
    // and the snapshot again. Each request is its own connection with its own
    // contract preflight (`health`), as Swift's `AgentClient` makes it.
    assert_eq!(
        service.runtime.methods(),
        [
            "health", "health", "job.list", "health", "health", "job.list"
        ]
    );
    let requests = service.runtime.state.lock().unwrap().requests.clone();
    assert_eq!(
        requests[2].1,
        json!({"pageSize": 1000, "order": "createdAtDescJobIdAsc", "includeTimeline": false,
            "includeCurrent": true})
    );
}

#[test]
fn restart_is_refused_while_a_current_job_is_active_or_unclosed() {
    let service = restartable();
    let mut waiting_for_human = closed_unknown("job-human");
    waiting_for_human["waitingForHuman"] = json!(true);
    let mut unfinished = closed_unknown("job-open");
    unfinished["finishedAtUtc"] = Value::Null;
    service.runtime.page(
        "",
        page(
            vec![
                job_row("job-running", "running", true, false, None),
                waiting_for_human,
                unfinished,
                closed_unknown("job-parked"),
            ],
            None,
        ),
    );
    let answer = service.restart(None);
    assert_eq!(answer.document, None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 75,
            message: "runtime service restart refused while Runtime Jobs are active or unclosed: job-human, job-open, job-running".into()
        })
    );
    assert_eq!(service.launchd_verbs(), ["print"]);
}

#[test]
fn restart_reads_every_page_of_one_snapshot() {
    let service = restartable();
    service
        .runtime
        .page("", page(vec![closed_unknown("job-a")], Some("page-2")));
    service.runtime.page(
        &format!("{REVISION}.page-2"),
        page(vec![job_row("job-b", "running", true, false, None)], None),
    );
    let answer = service.restart(None);
    assert_eq!(answer.failure.unwrap().exit_code, 75);
    // Another snapshot revision on a later page is an incomplete snapshot.
    let mut other = page(vec![closed_unknown("job-b")], None);
    other["snapshotRevision"] = json!("0e7de5f6-fc4c-4bbf-9486-81b47431095a");
    service.runtime.page(&format!("{REVISION}.page-2"), other);
    let answer = service.restart(None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "daemon did not return its complete current Job snapshot".into()
        })
    );
    // A cursor that repeats.
    service.runtime.page(
        &format!("{REVISION}.page-2"),
        page(vec![closed_unknown("job-b")], Some("page-2")),
    );
    let answer = service.restart(None);
    assert_eq!(
        answer.failure.unwrap().message,
        "daemon repeated a Job snapshot page"
    );
    assert_eq!(service.launchd_verbs(), ["print", "print", "print"]);
}

#[test]
fn restart_of_an_unready_service_touches_nothing() {
    let home = Home::new();
    let launchd = Launchd::default();
    let answer = restart_leaf(&host(&home, &launchd), "ctl-1", None);
    assert_eq!(
        answer,
        ServiceAnswer {
            document: None,
            failure: Some(PlainFailure {
                exit_code: 69,
                message: "LaunchAgent is not ready: LaunchAgent is not installed".into()
            })
        }
    );
    assert!(launchd.calls().is_empty());
}

#[test]
fn restart_retries_only_launchds_transient_eio_and_enables_once_after_three() {
    let service = restartable();
    *service.launchd.bootstrap.lock().unwrap() = VecDeque::from([5, 5, 5, 5, 0]);
    let answer = service.restart(None);
    assert_eq!(answer.failure, None, "{:?}", answer.document);
    assert_eq!(
        service.launchd_verbs(),
        [
            "print",
            "print",
            "bootout",
            "bootstrap",
            "bootstrap",
            "bootstrap",
            "enable",
            "bootstrap",
            "bootstrap",
            "print"
        ]
    );

    // Any other status fails on its first answer.
    let service = restartable();
    *service.launchd.bootstrap.lock().unwrap() = VecDeque::from([1]);
    let answer = service.restart(None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 1,
            message:
                "launchctl failed: bootstrap exited 1: Bootstrap failed: 1: Input/output error"
                    .into()
        })
    );
    assert_eq!(
        service.launchd_verbs(),
        ["print", "print", "bootout", "bootstrap"]
    );
}

#[test]
fn restart_fails_when_the_replacement_is_the_same_process_or_speaks_another_catalog() {
    let service = restartable();
    // The bootstrap brings the same process back.
    *service.launchd.on_bootstrap.lock().unwrap() = Some(Box::new({
        let state = service.runtime.state.clone();
        move || state.lock().unwrap().up = true
    }));
    let answer = service.restart(Some(1));
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "replacement daemon did not become ready within 1s: daemon instance PID has not changed".into()
        })
    );

    let service = restartable();
    let previous = service.launchd.on_bootstrap.lock().unwrap().take().unwrap();
    *service.launchd.on_bootstrap.lock().unwrap() = Some(Box::new({
        let state = service.runtime.state.clone();
        move || {
            previous();
            state.lock().unwrap().digest = OTHER_DIGEST.into();
        }
    }));
    let answer = service.restart(None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "daemon catalog changed across a configuration-preserving restart".into()
        })
    );
}

#[test]
fn restart_fails_when_the_current_job_closure_changes_across_it() {
    let service = restartable();
    service
        .runtime
        .page("", page(vec![closed_unknown("job-parked")], None));
    let previous = service.launchd.on_bootstrap.lock().unwrap().take().unwrap();
    *service.launchd.on_bootstrap.lock().unwrap() = Some(Box::new({
        let state = service.runtime.state.clone();
        move || {
            previous();
            state
                .lock()
                .unwrap()
                .pages
                .insert(String::new(), page(vec![], None));
        }
    }));
    let answer = service.restart(None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "Runtime current Job closure changed across daemon restart".into()
        })
    );
}

// MARK: - update, install and uninstall

/// How a helper's daemon answers `--cutover-preflight`: Swift's refuses the
/// argument, the Rust daemon answers its lock-free and held documents.
enum Daemon {
    Swift,
    /// Neither: it fails the argument some other way.
    Other,
    /// `busy`, when given, answers the first held pass only.
    Rust {
        first: Value,
        held: Value,
        busy: Option<Value>,
        analyzer: Analyzer,
    },
}

/// How a Rust helper's daemon answers `--analyze-crash-ledger`, which the
/// update asks before a plist names it as the analyzer.
#[derive(Clone, Copy)]
enum Analyzer {
    /// Swift's recorded answer, and only to the probe listing.
    Answers,
    /// As the Rust daemon did before the mode: every argument refused.
    Absent,
    /// Exit 0 with another document.
    Misanswers,
}

/// The recorded Swift oracle's case the update's analyzer probe is.
fn probe_case() -> Value {
    let oracle: Value = serde_json::from_slice(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/crash-ledger-analyzer/oracle.json"),
        )
        .unwrap(),
    )
    .unwrap();
    oracle["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "runtime-service-probe")
        .unwrap()
        .clone()
}

/// A helper bundle below the test root (outside the home) whose daemon logs
/// every run's arguments and environment to `log` (`USER`, which every
/// session sets, shows the environment was cleared).
struct Helper {
    bundle: PathBuf,
    log: PathBuf,
}

impl Helper {
    fn new(home: &Home, name: &str, daemon: &Daemon) -> Self {
        let root = home.root.join(name);
        let bundle = root.join("ArkDeckAgent.app");
        directory(&bundle.join("Contents/MacOS"));
        fs::write(bundle.join("Contents/Info.plist"), INFO_PLIST).unwrap();
        let log = root.join("daemon.log");
        let record = format!(
            "printf '%s|%s|%s|%s|%s\\n' \"$*\" \"$HOME\" \"$CFFIXED_USER_HOME\" \
             \"$ARKDECK_RUNTIME_COMPOSITION\" \"$USER\" >> '{}'\n",
            log.display()
        );
        let answer = match daemon {
            Daemon::Swift => "if [ \"$1\" = --cutover-preflight ]; then\n\
                 printf 'unknown argument %s\\n' \"$1\" >&2\nexit 64\nfi\nexit 0\n"
                .to_owned(),
            Daemon::Other => "printf 'usage: another daemon\\n' >&2\nexit 64\n".to_owned(),
            Daemon::Rust {
                first,
                held,
                busy,
                analyzer,
            } => {
                let analyzes = match analyzer {
                    Analyzer::Answers => {
                        let (listing, answer) = (root.join("probe.txt"), root.join("answer.json"));
                        fs::write(&listing, ANALYZER_PROBE_LISTING).unwrap();
                        fs::write(&answer, ANALYZER_PROBE_ANSWER).unwrap();
                        format!(
                            "[ \"$#\" -eq 2 ] && /usr/bin/cmp -s \"$2\" '{}' || exit 65\n\
                             /bin/cat '{}'\nexit 0",
                            listing.display(),
                            answer.display()
                        )
                    }
                    Analyzer::Absent => "printf 'arkdeck-agentd: arkdeck-agentd takes no device, \
                         command, path or authority arguments; configure the local host \
                         environment\\n' >&2\nexit 69"
                        .to_owned(),
                    Analyzer::Misanswers => {
                        "printf '%s' '{\"status\":\"answered\"}'\nexit 0".to_owned()
                    }
                };
                let analyzes =
                    format!("if [ \"$1\" = --analyze-crash-ledger ]; then\n{analyzes}\nfi\n");
                let (first_path, held_path) = (root.join("first.json"), root.join("held.json"));
                fs::write(&first_path, serde_json::to_vec(first).unwrap()).unwrap();
                fs::write(&held_path, serde_json::to_vec(held).unwrap()).unwrap();
                let busy = busy.as_ref().map_or_else(String::new, |busy| {
                    let (busy_path, marker) = (root.join("busy.json"), root.join("busy.done"));
                    fs::write(&busy_path, serde_json::to_vec(busy).unwrap()).unwrap();
                    format!(
                        "if [ \"$2\" = --hold-instance-lock ] && [ ! -e '{marker}' ]; then \
                         : > '{marker}'; /bin/cat '{busy}'; exit 0; fi\n",
                        marker = marker.display(),
                        busy = busy_path.display()
                    )
                });
                format!(
                    "{analyzes}{busy}if [ \"$2\" = --hold-instance-lock ]; then /bin/cat '{}'; \
                     else /bin/cat '{}'; fi\nexit 0\n",
                    held_path.display(),
                    first_path.display()
                )
            }
        };
        write_executable(
            &bundle.join("Contents/MacOS/arkdeck-agentd"),
            format!("#!/bin/sh\n{record}{answer}").as_bytes(),
        );
        Self { bundle, log }
    }

    fn runs(&self) -> Vec<String> {
        fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

/// A preflight answer of the Rust daemon for `home`.
fn preflight_document(home: &Home, blocks: Value, held: bool) -> Value {
    let state = text(&home.paths.state_directory);
    let snapshot = held.then(|| {
        json!({"schemaVersion": "arkdeck.cutover-snapshot/1", "stateDirectory": state,
            "stateDirectoryPresent": true, "takenAtUtc": "2026-09-24T00:00:00Z",
            "entries": [{"path": "instance.lock", "kind": "file", "byteCount": 0,
                "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}],
            "fileCount": 1, "byteCount": 0,
            "rootSha256": "9a2e3f2bb5e2b1b10a7f1f5d0d7c5a4e2b6f8e1c3d5a7b9c0e2f4a6b8c0d2e4f"})
    });
    json!({"schemaVersion": "arkdeck.cutover-preflight/1", "stateDirectory": state,
        "instanceLockHeld": held, "clear": blocks.as_array().unwrap().is_empty(),
        "blocks": blocks,
        "carriedOver": {"parkedJobIds": [], "terminalJobCount": 2, "outcomeUnknownUseCount": 0},
        "counts": {"jobs": 2, "agentExecutions": 0, "capabilityUses": 0},
        "snapshot": snapshot})
}

fn update_options(helper: &Helper, home: &Home) -> Map<String, Value> {
    Map::from_iter([
        ("daemon".to_owned(), json!(text(&helper.bundle))),
        ("hdc".to_owned(), json!(text(&home.hdc()))),
    ])
}

/// Every entry below the home: its path, and a file's bytes.
fn tree(root: &Path) -> Vec<(String, Option<Vec<u8>>)> {
    let mut entries = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            let metadata = fs::symlink_metadata(&path).unwrap();
            if metadata.is_dir() {
                pending.push(path.clone());
            }
            entries.push((
                text(&path),
                metadata.is_file().then(|| fs::read(&path).unwrap()),
            ));
        }
    }
    entries.sort();
    entries
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

fn swift_environment(home: &Home) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("ARKDECK_HDC_PATH".to_owned(), text(&home.hdc())),
        (
            "ARKDECK_ANALYZER_PATH".to_owned(),
            text(&home.paths.installed_daemon),
        ),
        (
            "ARKDECK_WORKSPACE_INSPECTOR".to_owned(),
            "/usr/bin/grep".to_owned(),
        ),
    ])
}

#[test]
fn update_installs_a_swift_helper_as_swift_does_and_keeps_the_one_it_replaces() {
    let home = Home::new();
    home.install();
    let replaced = fs::read(&home.paths.installed_daemon).unwrap();
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    assert_eq!(answer.failure, None);
    // launchd: Swift's status read, the loaded check, bootout and bootstrap.
    let domain = domain();
    assert_eq!(
        launchd.calls(),
        [
            print_call(),
            print_call(),
            format!("bootout {domain}/com.arkdeck.agentd"),
            format!("bootstrap {domain} {}", text(&home.paths.plist)),
        ]
    );
    // The helper is the source's, the one it replaced kept one generation.
    let installed = &home.paths.installed_daemon;
    let source_daemon = helper.bundle.join("Contents/MacOS/arkdeck-agentd");
    assert_eq!(
        fs::read(installed).unwrap(),
        fs::read(&source_daemon).unwrap()
    );
    assert_eq!(mode(installed), 0o700);
    assert_eq!(
        fs::read(
            home.paths
                .rollback_bundle
                .join("Contents/MacOS/arkdeck-agentd")
        )
        .unwrap(),
        replaced
    );
    // The plist is Swift's rendering byte for byte, owner-only.
    assert_eq!(
        fs::read_to_string(&home.paths.plist).unwrap(),
        plist(
            &text(installed),
            &swift_environment(&home),
            &text(&home.paths.standard_output),
            &text(&home.paths.standard_error),
        )
    );
    assert_eq!(mode(&home.paths.plist), 0o600);
    // The receipt is Swift's `JSONEncoder` output, and the answer.
    let daemon_sha256 = digest(&source_daemon);
    assert_eq!(
        fs::read_to_string(&home.paths.receipt).unwrap(),
        format!(
            "{{\n  \"daemonPath\" : \"{}\",\n  \"daemonSHA256\" : \"{daemon_sha256}\",\n  \
             \"hdcPath\" : \"{}\",\n  \"hdcSHA256\" : \"{}\",\n  \
             \"installedAtUTC\" : \"2026-09-24T00:00:00Z\",\n  \
             \"schemaVersion\" : \"arkdeck-launchagent-install/v1\"\n}}",
            text(installed),
            text(&home.hdc()),
            digest(&home.hdc())
        )
    );
    assert_eq!(mode(&home.paths.receipt), 0o600);
    assert_eq!(
        answer.document.unwrap(),
        serde_json::from_slice::<Value>(&fs::read(&home.paths.receipt).unwrap()).unwrap()
    );
    // What was written reads back as a consistent installation.
    let status = host(&home, &launchd).status().unwrap();
    assert_eq!(
        status.daemon_sha256.as_deref(),
        Some(daemon_sha256.as_str())
    );
    assert!(
        status
            .diagnostics
            .iter()
            .all(|diagnostic| !diagnostic.contains("drift") && !diagnostic.contains("plist")),
        "{:?}",
        status.diagnostics
    );
    // The daemon was asked the preflight once, with only the home and the
    // composition, and refused it as Swift's daemon does.
    assert_eq!(
        helper.runs(),
        [format!(
            "--cutover-preflight|{home}|{home}|production|",
            home = text(&home.paths.home)
        )]
    );
    // Nothing is left staged beside the helper.
    let helpers = home.paths.installed_daemon_bundle.parent().unwrap();
    let mut names: Vec<String> = fs::read_dir(helpers)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, [".rollback", "ArkDeckAgent.app"]);
}

#[test]
fn update_refuses_its_options_and_a_signing_preset_before_anything_changes() {
    let home = Home::new();
    home.install();
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let before = tree(&home.paths.home);
    let base = update_options(&helper, &home);
    let with = |pairs: &[(&str, &str)]| {
        let mut options = base.clone();
        for (key, value) in pairs {
            options.insert((*key).to_owned(), json!(value));
        }
        options
    };
    let cases: Vec<(Map<String, Value>, u8, &str)> = vec![
        (
            with(&[("daemon", "ArkDeckAgent.app")]),
            64,
            "runtime service update requires an absolute ArkDeckAgent.app path",
        ),
        (
            with(&[("hdc", "hdc")]),
            64,
            "runtime service update requires --hdc with an absolute executable path",
        ),
        (
            with(&[("workspaceProject", "/p")]),
            64,
            "runtime service update requires --workspace-project and --deveco-sdk together",
        ),
        (
            with(&[("harnessCli", "x")]),
            64,
            "--harness-cli was removed by CHG-2026-064: decisions come from external agents \
             through the published caller surface; re-run without it",
        ),
        (
            with(&[("arktraceDescriptor", "descriptor.json")]),
            64,
            "--arktrace-descriptor must be an absolute path or none",
        ),
        (
            with(&[("arkforgedSha256", "x")]),
            64,
            "--arkforged-sha256 is retired; pass one validated ArkForge.bundle to --arkforge-bundle",
        ),
        (
            with(&[("arkforgeBundle", "none"), ("arkforgeCampaign", "c")]),
            64,
            "--arkforge-bundle none cannot authorize an ArkForge campaign",
        ),
        (
            with(&[("arkforgeCampaign", "c")]),
            64,
            "--arkforge-campaign requires an explicit --arkforge-bundle",
        ),
    ];
    for (options, exit_code, message) in cases {
        let launchd = Launchd::loaded();
        let answer = update_leaf(&host(&home, &launchd), &options);
        assert_eq!(answer.document, None);
        assert_eq!(
            answer.failure,
            Some(PlainFailure {
                exit_code,
                message: message.into()
            })
        );
        assert!(
            launchd
                .calls()
                .iter()
                .all(|call| call.starts_with("print "))
        );
    }
    // An installed signing preset: its receipt pins the daemon identity this
    // CLI cannot re-record (ruling 3).
    directory(home.paths.signing_receipt.parent().unwrap());
    fs::write(&home.paths.signing_receipt, b"{}").unwrap();
    let before_signing = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &base);
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 69);
    assert!(
        failure.message.contains("signing preset") && failure.message.contains("Q8"),
        "{}",
        failure.message
    );
    assert!(
        launchd
            .calls()
            .iter()
            .all(|call| call.starts_with("print "))
    );
    assert_eq!(tree(&home.paths.home), before_signing);
    fs::remove_file(&home.paths.signing_receipt).unwrap();
    fs::remove_dir_all(
        home.paths
            .home
            .join("Library/Application Support/ArkDeck/Signing"),
    )
    .unwrap();
    assert_eq!(tree(&home.paths.home), before);
    // No daemon was ever asked anything.
    assert!(helper.runs().is_empty());
}

#[test]
fn update_refuses_a_helper_whose_daemon_is_neither_runtime() {
    let home = Home::new();
    home.install();
    let helper = Helper::new(&home, "src", &Daemon::Other);
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 69,
            message: "the helper's daemon neither answers the cutover preflight nor refuses it \
                      as Swift's daemon does (exit 64): usage: another daemon"
                .into()
        })
    );
    assert_eq!(launchd.calls(), [print_call()]);
    assert_eq!(tree(&home.paths.home), before);
}

/// An installation that carries the closed demo workspace pair, one ArkForge
/// release unit and an ArkTrace descriptor, as the status tests write them.
/// The descriptor lies in `descriptors`, an owner-controlled directory the
/// caller removes.
fn install_with_workspace_and_lane(home: &Home, descriptors: &Path) -> (PathBuf, PathBuf) {
    let mut environment = home.install();
    let descriptor = descriptors.join(format!("arktrace-{}.json", nonce()));
    let bytes = format!(
        "{{\"distributionRoot\":\"/Applications/ArkTrace.app\",\"formatVersion\":1,\"manifestSHA256\":\"{DIGEST}\"}}"
    );
    fs::write(&descriptor, &bytes).unwrap();
    fs::set_permissions(&descriptor, fs::Permissions::from_mode(0o600)).unwrap();
    environment.insert("ARKDECK_ARKTRACE_DESCRIPTOR".into(), text(&descriptor));
    let project = home.root.join("Developer/WaterFlow");
    directory(&project.join("entry/src/main"));
    fs::write(project.join("build-profile.json5"), b"{}").unwrap();
    fs::write(project.join("entry/src/main/module.json5"), b"{}").unwrap();
    let sdk = home.root.join("sdk");
    directory(&sdk.join("default/openharmony"));
    environment.insert(
        "ARKDECK_WORKSPACE_PROJECTS".into(),
        format!("demo-app={}", text(&project)),
    );
    environment.insert("ARKDECK_WORKSPACE_ACTIVE_PROJECT".into(), "demo-app".into());
    environment.insert("ARKDECK_DEVECO_SDK_HOME".into(), text(&sdk));
    let bundle = arkforge_bundle(&home.root);
    environment.insert("ARKDECK_ARKFORGE_BUNDLE_PATH".into(), text(&bundle));
    environment.insert("ARKDECK_ARKFORGE_CAMPAIGN".into(), "AFA-AC-7".into());
    home.write_plist(&text(&home.paths.installed_daemon), &environment);
    let mut receipt = home.receipt();
    receipt["workspaceProjectPath"] = json!(text(&project));
    receipt["devecoSDKPath"] = json!(text(&sdk));
    receipt["arkTraceDescriptor"] = json!({"descriptorPath": text(&descriptor),
        "descriptorSHA256": arkdeck_contract::sha256_hex(bytes.as_bytes()),
        "descriptorByteCount": bytes.len()});
    home.write_receipt(&receipt);
    (project, sdk)
}

fn agentd_host<'a>(home: &Home, launchd: &'a Launchd) -> ServiceHost<'a> {
    ServiceHost {
        spelling: "agentd",
        ..host(home, launchd)
    }
}

fn installed_receipt(home: &Home) -> Value {
    serde_json::from_slice(&fs::read(&home.paths.receipt).unwrap()).unwrap()
}

/// Swift `runAgentDaemon` spelled `agentd`: `update` keeps the installed
/// legacy workspace pair the `runtime service` spelling drops, and `install`
/// is the path install that carries nothing of an installed service over.
#[test]
fn agentd_update_keeps_the_legacy_workspace_pair_and_agentd_install_carries_nothing_over() {
    // The system temporary directory's ancestors are owner-controlled, as a
    // pinned descriptor's must be.
    let descriptors = Removed(
        std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("arkdeck-agentd-descriptors-{}", nonce())),
    );
    directory(&descriptors.0);
    // `runtime service update` without the pair installs none.
    let home = Home::new();
    install_with_workspace_and_lane(&home, &descriptors.0);
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    assert_eq!(answer.failure, None);
    let receipt = installed_receipt(&home);
    assert_eq!(receipt.get("workspaceProjectPath"), None);
    assert!(receipt.get("arkForgeLane").is_some(), "{receipt}");

    // `agentd update` without `--hdc` or the pair keeps both, and the lane.
    let home = Home::new();
    let (project, sdk) = install_with_workspace_and_lane(&home, &descriptors.0);
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let launchd = Launchd::loaded();
    let options = Map::from_iter([("daemon".to_owned(), json!(text(&helper.bundle)))]);
    let answer = update_leaf(&agentd_host(&home, &launchd), &options);
    assert_eq!(answer.failure, None);
    let receipt = installed_receipt(&home);
    assert_eq!(receipt["hdcPath"], text(&home.hdc()));
    assert_eq!(receipt["workspaceProjectPath"], text(&project));
    assert_eq!(receipt["devecoSDKPath"], text(&sdk));
    assert!(receipt.get("arkForgeLane").is_some(), "{receipt}");
    assert!(receipt.get("arkTraceDescriptor").is_some(), "{receipt}");

    // `agentd install` never reads the installed service: without `--hdc` it
    // is refused before launchd is asked anything.
    let home = Home::new();
    install_with_workspace_and_lane(&home, &descriptors.0);
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = path_install_leaf(&agentd_host(&home, &launchd), &options);
    assert_eq!(answer.document, None);
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 64,
            message: "agentd install requires --hdc with an absolute executable path".into()
        })
    );
    assert!(launchd.calls().is_empty());
    assert_eq!(tree(&home.paths.home), before);
    // With it, the installation is the named inputs only: no workspace pair,
    // no ArkForge lane.
    let answer = path_install_leaf(
        &agentd_host(&home, &launchd),
        &update_options(&helper, &home),
    );
    assert_eq!(answer.failure, None);
    let receipt = installed_receipt(&home);
    assert_eq!(receipt.get("workspaceProjectPath"), None);
    assert_eq!(receipt.get("arkForgeLane"), None);
    assert_eq!(receipt.get("arkTraceDescriptor"), None);
    let plist = fs::read_to_string(&home.paths.plist).unwrap();
    assert!(!plist.contains("ARKDECK_ARKFORGE_BUNDLE_PATH"), "{plist}");
    assert!(!plist.contains("ARKDECK_ARKTRACE_DESCRIPTOR"), "{plist}");
}

/// A directory removed however the test ends.
struct Removed(PathBuf);

impl Drop for Removed {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Every diagnostic of the `agentd` spelling names the command the caller
/// typed.
#[test]
fn agentd_diagnostics_name_the_agentd_spelling() {
    let home = Home::new();
    home.install();
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    let launchd = Launchd::loaded();
    let mut options = update_options(&helper, &home);
    options.insert("workspaceProject".to_owned(), json!("/p"));
    assert_eq!(
        update_leaf(&agentd_host(&home, &launchd), &options).failure,
        Some(PlainFailure {
            exit_code: 64,
            message: "agentd update requires --workspace-project and --deveco-sdk together".into()
        })
    );
    assert_eq!(
        verify_leaf(
            &agentd_host(&home, &launchd),
            "ctl-1",
            &job_options(JOB)
                .into_iter()
                .chain([("targetId".to_owned(), json!("TGT-1"))])
                .collect()
        )
        .failure,
        Some(PlainFailure {
            exit_code: 64,
            message: "agentd verify --job cannot be combined with execution options".into()
        })
    );
    assert_eq!(
        restart_leaf(&agentd_host(&home, &launchd), "ctl-1", Some(0)).failure,
        Some(PlainFailure {
            exit_code: 64,
            message: "agentd restart --maximum-wait-seconds must be between 1 and 300".into()
        })
    );
}

/// The update's analyzer probe is the Swift oracle's `runtime-service-probe`
/// case: the listing it hands the daemon, and the answer it requires.
#[test]
fn the_analyzer_probe_is_the_recorded_swift_case() {
    let case = probe_case();
    assert_eq!(
        case["arguments"],
        json!(["--analyze-crash-ledger", "{inputVolume}"])
    );
    assert_eq!(case["exitStatus"], 0);
    assert_eq!(
        case["input"].as_str().unwrap(),
        base64(ANALYZER_PROBE_LISTING)
    );
    assert_eq!(
        case["stdout"].as_str().unwrap().as_bytes(),
        ANALYZER_PROBE_ANSWER
    );
}

fn base64(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::new();
    for group in bytes.chunks(3) {
        let value = group.iter().enumerate().fold(0u32, |value, (index, byte)| {
            value | u32::from(*byte) << (16 - 8 * index)
        });
        for index in 0..4 {
            text.push(if index <= group.len() {
                DIGITS[(value >> (18 - 6 * index) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    text
}

/// One logged run of a helper's daemon: its arguments, then `HOME`,
/// `CFFIXED_USER_HOME`, `ARKDECK_RUNTIME_COMPOSITION` and `USER`.
fn is_analyzer_probe(run: &str) -> bool {
    // The Runtime's analyzer child: the listing's `/.vol` alias, and no
    // environment at all.
    run.strip_prefix("--analyze-crash-ledger /.vol/")
        .and_then(|rest| rest.strip_suffix("||||"))
        .and_then(|alias| alias.split_once('/'))
        .is_some_and(|(device, inode)| {
            [device, inode]
                .iter()
                .all(|number| !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
        })
}

#[test]
fn update_to_a_rust_daemon_that_does_not_analyze_crash_ledgers_is_refused_by_name() {
    for (analyzer, reason) in [
        (
            Analyzer::Absent,
            "(exit 69: arkdeck-agentd: arkdeck-agentd takes no device, command, path or \
             authority arguments; configure the local host environment)",
        ),
        (
            Analyzer::Misanswers,
            "(it answered other than Swift's analyzer)",
        ),
    ] {
        let home = Home::new();
        home.install();
        let helper = Helper::new(
            &home,
            "src",
            &Daemon::Rust {
                first: preflight_document(&home, json!([]), false),
                held: preflight_document(&home, json!([]), true),
                busy: None,
                analyzer,
            },
        );
        let before = tree(&home.paths.home);
        let launchd = Launchd::loaded();
        let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
        let failure = answer.failure.unwrap();
        assert_eq!(failure.exit_code, 69);
        assert!(
            failure.message.contains("ARKDECK_ANALYZER_PATH")
                && failure.message.contains("--analyze-crash-ledger")
                && failure.message.contains(reason)
                && failure.message.ends_with("nothing was changed"),
            "{}",
            failure.message
        );
        assert_eq!(launchd.calls(), [print_call()]);
        assert_eq!(tree(&home.paths.home), before);
        // The lock-free pass, then the probe, as the Runtime runs its analyzer.
        let runs = helper.runs();
        assert_eq!(runs.len(), 2, "{runs:?}");
        assert!(runs[0].starts_with("--cutover-preflight|"), "{runs:?}");
        assert!(is_analyzer_probe(&runs[1]), "{runs:?}");
    }
}

/// An installed signing preset refuses the update before the new helper's
/// daemon is asked anything, whether or not it would analyze crash ledgers.
#[test]
fn a_signing_preset_refuses_the_cutover_before_the_helper_runs() {
    let home = Home::new();
    home.install();
    let helper = Helper::new(
        &home,
        "src",
        &Daemon::Rust {
            first: preflight_document(&home, json!([]), false),
            held: preflight_document(&home, json!([]), true),
            busy: None,
            analyzer: Analyzer::Answers,
        },
    );
    directory(home.paths.signing_receipt.parent().unwrap());
    fs::write(&home.paths.signing_receipt, b"{}").unwrap();
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 69);
    assert!(
        failure.message.contains("signing preset") && failure.message.contains("Q8"),
        "{}",
        failure.message
    );
    assert!(
        launchd
            .calls()
            .iter()
            .all(|call| call.starts_with("print "))
    );
    assert_eq!(tree(&home.paths.home), before);
    assert_eq!(helper.runs(), Vec::<String>::new());
}

/// The held pass while the old daemon still holds its instance lock.
fn running(home: &Home) -> Value {
    let mut held = preflight_document(
        home,
        json!([{"kind": "runtimeRunning",
            "reason": "another Runtime holds the instance lock of the state directory"}]),
        true,
    );
    held["instanceLockHeld"] = json!(false);
    held["snapshot"] = Value::Null;
    held
}

#[test]
fn the_cutover_takes_both_preflight_passes_and_records_the_old_state() {
    let home = Home::new();
    home.install();
    let replaced = fs::read(&home.paths.installed_daemon).unwrap();
    let held = preflight_document(&home, json!([]), true);
    let helper = Helper::new(
        &home,
        "src",
        &Daemon::Rust {
            first: preflight_document(&home, json!([]), false),
            held: held.clone(),
            busy: Some(running(&home)),
            analyzer: Analyzer::Answers,
        },
    );
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    assert_eq!(answer.failure, None);
    let domain = domain();
    assert_eq!(
        launchd.calls(),
        [
            print_call(),
            print_call(),
            format!("bootout {domain}/com.arkdeck.agentd"),
            format!("bootstrap {domain} {}", text(&home.paths.plist)),
        ]
    );
    // First lock-free, then the analyzer probe as the Runtime runs its
    // analyzer, then holding the instance lock once the old service is out,
    // asked again while the old daemon still held it.
    let runs = helper.runs();
    assert!(is_analyzer_probe(&runs[1]), "{runs:?}");
    let runs: Vec<&str> = runs
        .iter()
        .map(|run| run.split('|').next().unwrap())
        .collect();
    assert_eq!(
        [runs[0], runs[2], runs[3]],
        [
            "--cutover-preflight",
            "--cutover-preflight --hold-instance-lock",
            "--cutover-preflight --hold-instance-lock"
        ],
        "{runs:?}"
    );
    assert_eq!(runs.len(), 4, "{runs:?}");
    // The snapshot summary, owner-only, as the held pass answered it.
    let snapshot = home
        .paths
        .cutover_snapshots
        .join("cutover-20260924T000000Z-9a2e3f2bb5e2.json");
    let mut expected = arkdeck_contract::canonical_json(&held["snapshot"]).unwrap();
    expected.push(b'\n');
    assert_eq!(fs::read(&snapshot).unwrap(), expected);
    assert_eq!(mode(&snapshot), 0o600);
    let document = answer.document.unwrap();
    assert_eq!(
        document["cutover"],
        json!({"snapshotPath": text(&snapshot),
            "snapshotRootSha256": held["snapshot"]["rootSha256"],
            "carriedOver": held["carriedOver"],
            "rollbackBundlePath": text(&home.paths.rollback_bundle)})
    );
    assert_eq!(
        fs::read(
            home.paths
                .rollback_bundle
                .join("Contents/MacOS/arkdeck-agentd")
        )
        .unwrap(),
        replaced
    );
    // The plist asks for the production composition.
    let mut environment = swift_environment(&home);
    environment.insert(
        "ARKDECK_RUNTIME_COMPOSITION".to_owned(),
        "production".to_owned(),
    );
    assert_eq!(
        fs::read_to_string(&home.paths.plist).unwrap(),
        plist(
            &text(&home.paths.installed_daemon),
            &environment,
            &text(&home.paths.standard_output),
            &text(&home.paths.standard_error),
        )
    );
}

#[test]
fn a_cutover_the_first_pass_refuses_changes_nothing() {
    let home = Home::new();
    home.install();
    let blocks = json!([{"kind": "jobState", "jobId": "job-a", "state": "preflight"},
        {"kind": "pendingToolSelection", "controlActionId": "select-b"}]);
    let helper = Helper::new(
        &home,
        "src",
        &Daemon::Rust {
            first: preflight_document(&home, blocks, false),
            held: preflight_document(&home, json!([]), true),
            busy: None,
            analyzer: Analyzer::Answers,
        },
    );
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    assert_eq!(
        answer.failure,
        Some(PlainFailure {
            exit_code: 75,
            message: "runtime service update refused: the Runtime state cannot be carried over \
                      as it is (Job job-a is preflight; HDC tool selection select-b is pending); \
                      nothing was changed"
                .into()
        })
    );
    assert_eq!(launchd.calls(), [print_call()]);
    assert_eq!(tree(&home.paths.home), before);
    // The lock-free pass and the analyzer probe; nothing held.
    let runs = helper.runs();
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(is_analyzer_probe(&runs[1]), "{runs:?}");
}

#[test]
fn a_cutover_the_held_pass_refuses_starts_the_old_service_again() {
    let home = Home::new();
    home.install();
    let held = running(&home);
    let helper = Helper::new(
        &home,
        "src",
        &Daemon::Rust {
            first: preflight_document(&home, json!([]), false),
            held,
            busy: None,
            analyzer: Analyzer::Answers,
        },
    );
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = update_leaf(&host(&home, &launchd), &update_options(&helper, &home));
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 75);
    // Asked again while the old daemon may still be letting its lock go.
    let held_runs = helper
        .runs()
        .iter()
        .filter(|run| run.starts_with("--cutover-preflight --hold-instance-lock|"))
        .count();
    assert_eq!(held_runs, 50);
    assert!(
        failure
            .message
            .contains("another Runtime holds the instance lock")
            && failure
                .message
                .ends_with("the previous service was started again from its unchanged plist"),
        "{}",
        failure.message
    );
    let domain = domain();
    assert_eq!(
        launchd.calls(),
        [
            print_call(),
            print_call(),
            format!("bootout {domain}/com.arkdeck.agentd"),
            format!("bootstrap {domain} {}", text(&home.paths.plist)),
        ]
    );
    // The owned directories exist; nothing installed changed.
    let after: Vec<_> = tree(&home.paths.home)
        .into_iter()
        .filter(|(path, bytes)| bytes.is_some() || before.iter().any(|(old, _)| old == path))
        .collect();
    assert_eq!(after, before);
    assert!(!home.paths.cutover_snapshots.exists());
}

#[test]
fn uninstall_removes_the_service_as_swift_does_unless_the_registry_pins_it() {
    let home = Home::new();
    home.install();
    // The registry pins a bundle for the service installation.
    let index = &home.paths.bootstrap_bundle_index;
    directory(index.parent().unwrap());
    let pinned = json!({"schemaVersion": "arkdeck.bootstrap-bundles/1", "records": [
        {"reference": "bundle:sha256:aa", "references": [
            {"kind": "installation", "id": "runtime-service-installation"}]},
        {"reference": "bundle:sha256:bb", "references": []}]});
    fs::write(index, serde_json::to_vec(&pinned).unwrap()).unwrap();
    let before = tree(&home.paths.home);
    let launchd = Launchd::loaded();
    let answer = uninstall_leaf(&host(&home, &launchd));
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 69);
    assert!(
        failure.message.contains("bundle:sha256:aa"),
        "{}",
        failure.message
    );
    assert!(launchd.calls().is_empty());
    assert_eq!(tree(&home.paths.home), before);
    // An index that cannot be read proves nothing either.
    fs::write(index, b"{").unwrap();
    let answer = uninstall_leaf(&host(&home, &launchd));
    assert_eq!(answer.failure.unwrap().exit_code, 69);
    assert!(launchd.calls().is_empty());

    // With nothing pinned, the service is booted out and removed; the state
    // and logs stay.
    fs::write(
        index,
        serde_json::to_vec(&json!({"schemaVersion": "arkdeck.bootstrap-bundles/1",
            "records": [{"reference": "bundle:sha256:bb", "references": []}]}))
        .unwrap(),
    )
    .unwrap();
    let answer = uninstall_leaf(&host(&home, &launchd));
    assert_eq!(answer.failure, None);
    assert_eq!(
        answer.document.unwrap(),
        json!({"removedPlist": true, "removedDaemon": true, "removedReceipt": true,
            "preservedStateDirectory": text(&home.paths.state_directory),
            "preservedLogDirectory": text(&home.paths.log_directory)})
    );
    let domain = domain();
    assert_eq!(
        launchd.calls(),
        [print_call(), format!("bootout {domain}/com.arkdeck.agentd")]
    );
    assert!(!home.paths.plist.exists() && !home.paths.receipt.exists());
    assert!(!home.paths.installed_daemon_bundle.exists());
    assert!(home.paths.state_directory.exists() && home.paths.log_directory.exists());
    // Again: nothing to remove, nothing loaded.
    let answer = uninstall_leaf(&host(&home, &launchd));
    assert_eq!(answer.document.unwrap()["removedDaemon"], false);
}

#[test]
fn the_typed_install_is_refused_by_name_before_anything_is_read() {
    let home = Home::new();
    let launchd = Launchd::default();
    let options = Map::from_iter([
        ("bundle".to_owned(), json!("bundle:sha256:aa")),
        ("bundleGeneration".to_owned(), json!("1")),
        ("tool".to_owned(), json!("tool:sha256:bb")),
        ("toolGeneration".to_owned(), json!("1")),
    ]);
    let answer = install_leaf(&host(&home, &launchd), &options);
    assert_eq!(answer.document, None);
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 69);
    assert!(
        failure.message.contains("installation references"),
        "{}",
        failure.message
    );
    assert!(launchd.calls().is_empty());
}

// MARK: - The CLI process over a relocated home

/// The CLI with its home relocated to `home`; `launchctl`, when given, is the
/// recording script named for that home.
fn cli(home: &Home, launchctl: Option<&Path>, argv: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
    command
        .args(argv)
        .env("CFFIXED_USER_HOME", &home.paths.home)
        .env_remove("ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME")
        .env_remove("ARKDECK_ENDPOINT");
    if let Some(launchctl) = launchctl {
        command.env("ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME", launchctl);
    }
    command.output().unwrap()
}

/// A recording stand-in for launchd: each call appends its arguments to a
/// log; `print` answers "not found".
fn recording_launchctl(home: &Home) -> (PathBuf, PathBuf) {
    let log = home.root.join("launchctl.log");
    let script = home.root.join("launchctl");
    write_executable(
        &script,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n[ \"$1\" = print ] && exit 113\nexit 1\n",
            log.display()
        )
        .as_bytes(),
    );
    (script, log)
}

fn stdout_json(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "{} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn the_cli_answers_status_in_swifts_envelope_and_never_reaches_the_accounts_launchd() {
    let home = Home::new();
    let output = cli(
        &home,
        None,
        &["runtime", "service", "status", "--output", "json"],
    );
    assert_eq!(output.status.code(), Some(0));
    let envelope = stdout_json(&output);
    assert_eq!(envelope["schemaVersion"], "arkdeck.cli.result/1");
    assert_eq!(envelope["command"], "runtime.service.status");
    assert_eq!(envelope["ok"], true);
    assert_eq!(envelope["meta"]["controlProtocolVersion"], PROTOCOL_VERSION);
    assert_eq!(envelope["result"]["launchAgent"]["installed"], false);
    assert_eq!(
        envelope["result"]["daemonHealth"],
        json!({"status": "socket_absent"})
    );
    // Canonical, one document.
    assert_eq!(arkdeck_cli::render(&envelope).unwrap(), output.stdout);

    // Installed: a relocated home without its own launchd control executable
    // refuses before any runs.
    home.install();
    let output = cli(
        &home,
        None,
        &["runtime", "service", "status", "--output", "json"],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("never drives the account's launchd domain"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    // With the recording script, launchd is asked exactly one fixed question.
    let (script, log) = recording_launchctl(&home);
    let output = cli(
        &home,
        Some(&script),
        &["runtime", "service", "status", "--output", "json"],
    );
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let envelope = stdout_json(&output);
    let status = &envelope["result"]["launchAgent"];
    assert_eq!(status["loaded"], false);
    // The unsigned test helper fails the production validation, honestly.
    let diagnostics = status["diagnostics"].as_array().unwrap();
    assert!(
        diagnostics[0]
            .as_str()
            .unwrap()
            .starts_with("installed daemon helper bundle is invalid: "),
        "{diagnostics:?}"
    );
    assert_eq!(
        diagnostics.last().unwrap(),
        &json!(format!("LaunchAgent is not loaded in {}", domain()))
    );
    assert_eq!(
        fs::read_to_string(&log).unwrap(),
        format!("print {}/com.arkdeck.agentd\n", domain())
    );

    // The legacy rendering is the bare document.
    let output = cli(
        &home,
        Some(&script),
        &["runtime", "service", "status", "--json"],
    );
    assert_eq!(output.status.code(), Some(0));
    let document = stdout_json(&output);
    assert_eq!(document["launchAgent"]["installed"], true);
    assert_eq!(document.get("schemaVersion"), None);
}

#[test]
fn the_cli_refuses_restart_with_an_empty_stdout_and_verify_answers_an_absent_service() {
    let home = Home::new();
    let (script, log) = recording_launchctl(&home);
    let output = cli(
        &home,
        Some(&script),
        &["runtime", "service", "restart", "--output", "json"],
    );
    assert_eq!(output.status.code(), Some(69));
    assert!(output.stdout.is_empty());
    // `verify`, with or without `--job`, of an absent service emits its
    // state, then exits 69.
    for argv in [
        &["runtime", "service", "verify", "--output", "json"][..],
        &[
            "runtime", "service", "verify", "--job", JOB, "--output", "json",
        ][..],
    ] {
        let output = cli(&home, Some(&script), argv);
        assert_eq!(output.status.code(), Some(69), "{argv:?}");
        let envelope = stdout_json(&output);
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["result"]["runtime"], Value::Null);
        assert_eq!(envelope["result"]["runtimeVerified"], false);
    }
    // Nothing was installed, so launchd was never asked anything.
    assert!(!log.exists());
}

#[test]
fn the_cli_installs_nothing_it_cannot_validate_and_uninstalls_an_absent_service() {
    let home = Home::new();
    let helper = Helper::new(&home, "src", &Daemon::Swift);
    write_executable(&home.hdc(), b"hdc-v1");
    // The production validation refuses the unsigned test helper before
    // anything is changed or anyone is asked.
    let output = cli(
        &home,
        None,
        &[
            "runtime",
            "service",
            "update",
            "--daemon",
            &text(&helper.bundle),
            "--hdc",
            &text(&home.hdc()),
            "--arktrace-descriptor",
            "none",
            "--output",
            "json",
        ],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(helper.runs().is_empty());
    assert!(!home.paths.plist.exists() && !home.paths.installed_daemon_bundle.exists());
    // An installed signing preset refuses first (ruling 3).
    directory(home.paths.signing_receipt.parent().unwrap());
    fs::write(&home.paths.signing_receipt, b"{}").unwrap();
    let output = cli(
        &home,
        None,
        &[
            "runtime",
            "service",
            "update",
            "--daemon",
            &text(&helper.bundle),
            "--hdc",
            &text(&home.hdc()),
            "--arktrace-descriptor",
            "none",
        ],
    );
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("signing preset"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // The typed install is refused by name.
    let output = cli(
        &home,
        None,
        &[
            "runtime",
            "service",
            "install",
            "--bundle",
            "bundle:sha256:aa",
            "--bundle-generation",
            "1",
            "--tool",
            "tool:sha256:bb",
            "--tool-generation",
            "1",
        ],
    );
    assert_eq!(output.status.code(), Some(69));
    assert!(output.stdout.is_empty());
    // Uninstall asks launchd only through the relocated home's own recording
    // executable, and removes nothing that is not there.
    let output = cli(
        &home,
        None,
        &["runtime", "service", "uninstall", "--output", "json"],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let (script, log) = recording_launchctl(&home);
    let output = cli(
        &home,
        Some(&script),
        &["runtime", "service", "uninstall", "--output", "json"],
    );
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let envelope = stdout_json(&output);
    assert_eq!(envelope["command"], "runtime.service.uninstall");
    assert_eq!(
        envelope["result"],
        json!({"removedPlist": false, "removedDaemon": false, "removedReceipt": false,
            "preservedStateDirectory": text(&home.paths.state_directory),
            "preservedLogDirectory": text(&home.paths.log_directory)})
    );
    assert_eq!(
        fs::read_to_string(&log).unwrap(),
        format!("print {}/com.arkdeck.agentd\n", domain())
    );
    // The leaves are listed.
    let output = cli(&home, None, &["commands", "--output", "json"]);
    let listed: Vec<String> = stdout_json(&output)["result"]["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["command"].as_str().unwrap().to_owned())
        .filter(|command| command.starts_with("runtime.service."))
        .collect();
    assert_eq!(
        listed,
        [
            "runtime.service.install",
            "runtime.service.update",
            "runtime.service.restart",
            "runtime.service.status",
            "runtime.service.verify",
            "runtime.service.uninstall"
        ]
    );
}

/// `agentd …` is `runtime service …` under its superseded name: the same
/// answers, reported as the leaf the caller typed, deprecated in
/// `meta.lifecycle` or, in the human rendering, on stderr.
#[test]
fn the_cli_answers_the_agentd_spelling_as_deprecated() {
    let home = Home::new();
    let output = cli(&home, None, &["agentd", "status", "--output", "json"]);
    assert_eq!(output.status.code(), Some(0));
    assert!(output.stderr.is_empty());
    let envelope = stdout_json(&output);
    assert_eq!(envelope["command"], "agentd.status");
    assert_eq!(
        envelope["meta"]["lifecycle"],
        json!({"status": "deprecated",
            "replacementArgvPattern": "arkdeck runtime service status", "removalVersion": null})
    );
    assert_eq!(envelope["result"]["launchAgent"]["installed"], false);
    // The current spelling carries no lifecycle.
    let output = cli(
        &home,
        None,
        &["runtime", "service", "status", "--output", "json"],
    );
    assert_eq!(stdout_json(&output)["meta"].get("lifecycle"), None);
    // Human: the warning first, then the document.
    let output = cli(&home, None, &["agentd", "status"]);
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "warning: `agentd status` is deprecated; use `arkdeck runtime service status`\n"
    );
    assert_eq!(
        stdout_json(&output)["daemonHealth"]["status"],
        "socket_absent"
    );
    // The legacy rendering is the bare document, and warns nowhere.
    let output = cli(&home, None, &["agentd", "status", "--json"]);
    assert!(output.stderr.is_empty());
    assert_eq!(stdout_json(&output).get("schemaVersion"), None);
    // `agentd install` takes `update`'s path inputs, never the typed
    // bootstrap's, and refuses a missing `--hdc` as a usage error.
    let output = cli(&home, None, &["agentd", "install", "--output", "json"]);
    assert_eq!(output.status.code(), Some(64));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("agentd install requires --hdc with an absolute executable path"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    for argv in [
        &["agentd", "install", "--bundle", "b"][..],
        &["agentd", "status", "--control-request-id", "ctl-1"][..],
        &["agentd", "restart", "--maximum-wait-seconds", "0"][..],
    ] {
        let output = cli(&home, None, argv);
        assert_eq!(output.status.code(), Some(64), "{argv:?}");
        assert!(output.stdout.is_empty(), "{argv:?}");
    }
    // All six are listed.
    let output = cli(&home, None, &["commands", "--output", "json"]);
    let listed: Vec<String> = stdout_json(&output)["result"]["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["command"].as_str().unwrap().to_owned())
        .filter(|command| command.starts_with("agentd."))
        .collect();
    assert_eq!(
        listed,
        [
            "agentd.install",
            "agentd.update",
            "agentd.restart",
            "agentd.status",
            "agentd.verify",
            "agentd.uninstall"
        ]
    );
}

#[test]
fn the_cli_refuses_the_options_these_leaves_do_not_take() {
    let home = Home::new();
    for argv in [
        &[
            "runtime",
            "service",
            "status",
            "--control-request-id",
            "ctl-1",
        ][..],
        &[
            "runtime",
            "service",
            "status",
            "--socket",
            "/private/tmp/a.sock",
        ][..],
        &[
            "runtime",
            "service",
            "restart",
            "--maximum-wait-seconds",
            "301",
        ][..],
        &[
            "runtime",
            "service",
            "restart",
            "--maximum-wait-seconds",
            "030",
        ][..],
        &[
            "runtime", "service", "verify", "--job", JOB, "--target", "TGT-1",
        ][..],
        &[
            "runtime",
            "service",
            "verify",
            "--job",
            JOB,
            "--maximum-wait-seconds",
            "5",
        ][..],
        &["runtime", "service", "status", "--timeout", "5s"][..],
        &["runtime", "service", "uninstall", "--hdc", "/h"][..],
        &["runtime", "service", "update", "--bundle", "b"][..],
        &[
            "runtime",
            "service",
            "install",
            "--bundle",
            "b",
            "--bundle-generation",
            "01",
            "--tool",
            "t",
            "--tool-generation",
            "1",
        ][..],
        &["runtime", "service", "install", "--bundle", "b"][..],
    ] {
        let output = cli(&home, None, argv);
        assert_eq!(output.status.code(), Some(64), "{argv:?}");
        assert!(output.stdout.is_empty(), "{argv:?}");
    }
    // In machine mode a parse refusal is the parse failure's envelope.
    for argv in [
        &[
            "runtime",
            "service",
            "restart",
            "--maximum-wait-seconds",
            "0",
            "--output",
            "json",
        ][..],
        &["runtime", "service", "status", "--json", "--output", "json"][..],
    ] {
        let output = cli(&home, None, argv);
        assert_eq!(output.status.code(), Some(64), "{argv:?}");
        assert_eq!(
            stdout_json(&output)["error"]["code"],
            "invalidOption",
            "{argv:?}"
        );
    }
}
