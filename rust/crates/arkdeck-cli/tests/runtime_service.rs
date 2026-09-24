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

#[test]
fn verify_without_a_job_is_refused_by_name_before_anything_is_read() {
    let home = Home::new();
    home.install();
    let launchd = Launchd::loaded();
    let answer = verify_leaf(&host(&home, &launchd), "ctl-1", &Map::new());
    assert_eq!(answer.document, None);
    let failure = answer.failure.unwrap();
    assert_eq!(failure.exit_code, 69);
    assert!(failure.message.contains("agent run"), "{}", failure.message);
    assert!(launchd.calls().is_empty());
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
fn the_cli_refuses_restart_and_a_fresh_verify_with_an_empty_stdout() {
    let home = Home::new();
    let (script, log) = recording_launchctl(&home);
    for (argv, code) in [
        (
            &["runtime", "service", "restart", "--output", "json"][..],
            69,
        ),
        (
            &["runtime", "service", "verify", "--output", "json"][..],
            69,
        ),
    ] {
        let output = cli(&home, Some(&script), argv);
        assert_eq!(output.status.code(), Some(code), "{argv:?}");
        assert!(output.stdout.is_empty(), "{argv:?}");
    }
    // `verify --job` of an absent service emits its state, then exits 69.
    let output = cli(
        &home,
        Some(&script),
        &[
            "runtime", "service", "verify", "--job", JOB, "--output", "json",
        ],
    );
    assert_eq!(output.status.code(), Some(69));
    let envelope = stdout_json(&output);
    assert_eq!(envelope["ok"], true);
    assert_eq!(envelope["result"]["runtime"], Value::Null);
    assert_eq!(envelope["result"]["runtimeVerified"], false);
    // Nothing was installed, so launchd was never asked anything.
    assert!(!log.exists());
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
