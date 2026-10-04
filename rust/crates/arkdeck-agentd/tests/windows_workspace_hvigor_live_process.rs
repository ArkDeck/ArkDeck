//! The installed (account) Windows daemon builds a Runtime-owned copy of a
//! real OpenHarmony project with the host's DevEco Studio (TASK-XPA-011,
//! GJ-5), through the real CLI against a copy of the daemon signed with the
//! host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!
//! * `runtime tool register --kind deveco` measures and registers the
//!   DevEco Studio at `ARKDECK_LIVE_DEVECO_ROOT`;
//! * the repository's WaterFlow demo (`tests/waterflow-demo`, its tracked
//!   sources copied below the fake account) is registered with
//!   `workspace project register`, and an `openharmony.hvigor-build@1`
//!   preset pinning that toolchain with `workspace preset register`;
//! * the restarted daemon composes the preset; `workspace isolate` copies the
//!   project and `workspace build` runs the pinned Node and `hvigorw.js`
//!   (`assembleHap`) in the copy, its search path led by the toolchain's
//!   pinned JDK, landing its unsigned HAP as the Job's verified Artifact.
//!
//! The fake account's profile is empty, so Hvigor's wrapper bootstraps
//! itself on its first run (`npm install pnpm`, over the network), as it does
//! for a person who has never built with DevEco Studio.
//!
//! The daemon runs its account composition over a fake account, as
//! `windows_workspace_mutation_process.rs` runs it, holding the account's
//! daemon starters' turn throughout. Without either variable, or while an
//! account daemon serves, this test says so and checks nothing. No HDC,
//! device or credential is involved; nothing is signed or installed.
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_platform::{InstanceScope, StarterLock, default_user_endpoint, pipe_present};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(60);
const PROFILE: &str = "waterflow-openharmony@1";
const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
/// The WaterFlow profile's scope, which its revision measures.
const SCOPE: [&str; 4] = [
    "entry/src/main/ets/",
    "entry/src/main/cpp/",
    "entry/src/test/",
    "entry/src/ohosTest/",
];
const PRODUCT: &str = "entry/build/default/outputs/default/entry-default-unsigned.hap";

fn plain(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(text) => PathBuf::from(text),
        None => path,
    }
}

/// A fake account below the temporary directory, removed afterwards. Its
/// name is short: CMake below the copy's root keeps object paths within
/// 250 characters.
struct Account(PathBuf);

impl Account {
    fn new() -> Self {
        let nonce = u32::from_ne_bytes(arkdeck_platform::random_bytes::<4>().unwrap());
        let temporary = plain(std::env::temp_dir().canonicalize().unwrap());
        let profile = temporary.join(format!("ad-hv-{nonce:08x}"));
        std::fs::create_dir_all(profile.join("AppData").join("Local")).unwrap();
        Self(profile)
    }
    fn state(&self) -> PathBuf {
        self.0
            .join("AppData")
            .join("Local")
            .join("ArkDeck")
            .join("Agentd")
    }
    fn daemon_at(&self, executable: &Path) -> Command {
        let mut command = Command::new(executable);
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            if key.to_ascii_uppercase().starts_with("ARKDECK_")
                || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
            {
                command.env_remove(key);
            }
        }
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.0.join("daemon-stderr.log"))
            .unwrap();
        command
            .env("USERPROFILE", &self.0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log));
        command
    }
}

impl Drop for Account {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The account's daemon starters' turn, held until the test ends.
fn turn() -> StarterLock {
    StarterLock::acquire(&InstanceScope::account().unwrap(), DEADLINE * 10)
        .unwrap()
        .expect("another process held the account's daemon starters' turn for ten minutes")
}

fn account_free() -> bool {
    let endpoint = default_user_endpoint().unwrap();
    if pipe_present(&endpoint).unwrap() {
        eprintln!(
            "SKIPPED: an account daemon serves {} on this host, and a daemon over a fake \
             account takes the same guard and pipe; nothing was checked",
            endpoint.as_path().display()
        );
        return false;
    }
    true
}

/// After the test: no daemon serves the account's pipe.
fn assert_account_released() {
    let endpoint = default_user_endpoint().unwrap();
    let deadline = Instant::now() + DEADLINE;
    while pipe_present(&endpoint).unwrap() {
        assert!(
            Instant::now() < deadline,
            "a daemon still serves the account's pipe {}",
            endpoint.as_path().display()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// A running daemon, its stdout read line by line as it comes.
struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl Daemon {
    fn spawn(mut command: Command) -> Self {
        let mut child = command.spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self {
            child: Some(child),
            lines,
            seen: Vec::new(),
        }
    }

    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) => {
                    self.seen.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(error) => panic!(
                    "no line starting {prefix:?} ({error}); stdout so far {:?}",
                    self.seen
                ),
            }
        }
    }

    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    fn stop(&mut self) {
        let pid = self.child.as_ref().unwrap().id();
        InstanceScope::account().unwrap().request_stop(pid).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let mut child = self.child.take().unwrap();
        let status = child.wait().unwrap();
        assert!(status.success(), "{status:?}");
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// PowerShell 7, which signs the development daemon.
fn pwsh() -> PathBuf {
    if let Some(found) = std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|directory| directory.join("pwsh.exe"))
            .find(|candidate| candidate.exists())
    }) {
        return found;
    }
    let alias = PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
        .join("Microsoft/WindowsApps/pwsh.exe");
    assert!(
        alias.exists(),
        "PowerShell 7 is required to sign the development daemon"
    );
    alias
}

/// The repository's tracked WaterFlow demo below `destination`, without
/// what a build or a dependency install leaves beside it.
fn copy_demo(source: &Path, destination: &Path) {
    std::fs::create_dir_all(destination).unwrap();
    for entry in std::fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name();
        let name = name.to_str().unwrap();
        if [
            "build",
            ".hvigor",
            ".cxx",
            "oh_modules",
            ".idea",
            "local.properties",
        ]
        .contains(&name)
        {
            continue;
        }
        let kind = entry.file_type().unwrap();
        assert!(!kind.is_symlink(), "{}", entry.path().display());
        if kind.is_dir() {
            copy_demo(&entry.path(), &destination.join(name));
        } else {
            std::fs::copy(entry.path(), destination.join(name)).unwrap();
        }
    }
}

/// Every regular file below `root`, as `/`-separated relative paths.
fn files(root: &Path, relative: &str, found: &mut Vec<String>) {
    for entry in std::fs::read_dir(root.join(relative)).unwrap() {
        let entry = entry.unwrap();
        let path = format!("{relative}{}", entry.file_name().to_str().unwrap());
        if entry.file_type().unwrap().is_dir() {
            files(root, &format!("{path}/"), found);
        } else {
            found.push(path);
        }
    }
}

/// The revision Swift's provider measures for the WaterFlow profile over the
/// files below `scopes` (no git working copy).
fn revision(root: &Path, scopes: &[&str]) -> String {
    let mut found = Vec::new();
    for scope in scopes {
        if root.join(scope).is_dir() {
            files(root, scope, &mut found);
        }
    }
    found.sort();
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for path in found {
        let bytes = std::fs::read(root.join(&path)).unwrap();
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(&bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// The tail of every text file below `directory` (the Hvigor logs a build
/// left, the logs the Job published), for a failure's message.
fn log_tails(directory: &Path) -> String {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return format!("nothing at {}\n", directory.display());
    };
    let mut tail = String::new();
    for entry in entries.flatten() {
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            tail.push_str(&log_tails(&entry.path()));
            continue;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else {
            continue;
        };
        let text = String::from_utf8_lossy(&bytes);
        let lines: Vec<&str> = text.lines().collect();
        let start = lines.len().saturating_sub(40);
        tail.push_str(&format!(
            "== {}\n{}\n",
            entry.path().display(),
            lines[start..].join("\n")
        ));
    }
    tail
}

#[test]
fn the_account_daemon_builds_a_copy_with_the_host_s_deveco_through_the_cli() {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the daemon the CLI must verify \
             (rust/scripts/windows-dev-identity.ps1 create); nothing was checked"
        );
        return;
    };
    let Some(deveco) = std::env::var("ARKDECK_LIVE_DEVECO_ROOT")
        .ok()
        .filter(|value| !value.is_empty())
    else {
        eprintln!(
            "ARKDECK_LIVE_DEVECO_ROOT is not set: the live Hvigor build with the host's DevEco \
             Studio was not run"
        );
        return;
    };
    let _turn = turn();
    if !account_free() {
        return;
    }
    let account = Account::new();
    let signed = account.0.join("bin");
    std::fs::create_dir(&signed).unwrap();
    let daemon = signed.join("arkdeck-agentd.exe");
    std::fs::copy(DAEMON, &daemon).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(&thumbprint)
        .arg("-Path")
        .arg(&daemon)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(signing.status.success(), "{signing:?}");
    let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
    let pin = pin["pin"].as_str().unwrap().to_owned();
    let project = account.0.join("p");
    copy_demo(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/waterflow-demo"),
        &project,
    );

    let cli = |pipe: &str, arguments: &[&str]| -> (Option<i32>, Value) {
        let cli = Path::new(DAEMON).with_file_name("arkdeck.exe");
        let mut command = Command::new(&cli);
        for (key, _) in std::env::vars_os() {
            if key
                .to_string_lossy()
                .to_ascii_uppercase()
                .starts_with("ARKDECK_")
            {
                command.env_remove(key);
            }
        }
        let output = command
            .args(arguments)
            .args(["--output", "json"])
            .env("USERPROFILE", &account.0)
            .env("ARKDECK_ENDPOINT", pipe)
            .env("ARKDECK_DAEMON_PATH", &daemon)
            .env("ARKDECK_DAEMON_SIGNER_SHA256", &pin)
            .stdin(Stdio::null())
            .output()
            .unwrap_or_else(|error| {
                panic!(
                    "the arkdeck CLI beside the daemon ({}): {error}; run the workspace \
                     tests, or `cargo build -p arkdeck-cli` before testing this crate alone",
                    cli.display()
                )
            });
        let envelope = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
        (output.status.code(), envelope)
    };
    let run = |pipe: &str, arguments: &[&str]| -> Value {
        let (status, envelope) = cli(pipe, arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        envelope["result"].clone()
    };
    let inputs = |name: &str, value: Value| {
        let path = account.0.join(format!("{name}.json"));
        std::fs::write(&path, value.to_string()).unwrap();
        path.to_str().unwrap().to_owned()
    };

    // The toolchain, the project and its build preset, registered.
    let mut running = Daemon::spawn(account.daemon_at(&daemon));
    let pipe = running.serving();
    let toolchain = run(
        &pipe,
        &[
            "runtime", "tool", "register", "--kind", "deveco", "--root", &deveco,
        ],
    )["toolRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let registered = run(
        &pipe,
        &[
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "hvigor-live-project",
            "--kind",
            "openharmony",
            "--root",
            project.to_str().unwrap(),
        ],
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let preset = run(
        &pipe,
        &[
            "workspace",
            "preset",
            "register",
            "--registration-request-id",
            "hvigor-live-build",
            "--project",
            &registered,
            "--kind",
            "build",
            "--template",
            "openharmony.hvigor-build@1",
            "--timeout-seconds",
            "600",
            "--toolchain",
            &toolchain,
            "--toolchain-generation",
            "1",
            "--module",
            "entry",
            "--product",
            "default",
            "--build-mode",
            "debug",
        ],
    )["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    running.stop();

    // Composed by the next start: the copy, then its build.
    let mut running = Daemon::spawn(account.daemon_at(&daemon));
    let pipe = running.serving();
    let allowed = "entry/src/main/ets/";
    let copied = run(
        &pipe,
        &[
            "workspace",
            "isolate",
            "--inputs-file",
            &inputs(
                "isolate",
                json!({"projectRef": registered,
                    "expectedWorkspaceRevision": revision(&project, &SCOPE),
                    "allowedFileGlobs": [format!("{allowed}**")]}),
            ),
            "--execution-id",
            "exec-windows-hvigor-isolate",
        ],
    );
    assert_eq!(copied["terminalState"], "succeeded", "{copied}");
    let job = copied["jobID"].as_str().unwrap().to_owned();
    let base = revision(&project, &[allowed]);
    let digest = sha256_hex(format!("runtime-{job}|{registered}|{base}").as_bytes());
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let copy_root = account
        .state()
        .join("evolution-workspaces")
        .join(&workspace_id)
        .join("workspace");
    assert!(copy_root.join("build-profile.json5").is_file());

    let started = Instant::now();
    let (status, envelope) = cli(
        &pipe,
        &[
            "workspace",
            "build",
            "--inputs-file",
            &inputs(
                "build",
                json!({"projectRef": copy, "buildPresetRef": preset}),
            ),
            "--execution-id",
            "exec-windows-hvigor-build",
        ],
    );
    let elapsed = started.elapsed();
    let built = &envelope["result"];
    assert!(
        status == Some(0) && built["terminalState"] == "succeeded",
        "workspace build ({status:?}, {elapsed:?}): {envelope}\n{}",
        log_tails(&copy_root.join(".hvigor").join("outputs").join("build-logs"))
            + &log_tails(&account.state().join("artifacts"))
    );
    eprintln!("workspace build succeeded in {elapsed:?}");
    assert_eq!(built["providerID"], "workspace", "{built}");
    assert_eq!(built["evidenceBlockers"], json!([]), "{built}");
    // The HAP Hvigor produced in the copy is published as the Job's
    // verified Artifact, beside the build log: a ZIP archive whose bytes the
    // store holds under the digest the result names.
    let produced = built["artifacts"].as_array().unwrap();
    assert_eq!(produced.len(), 2, "{built}");
    let stored = |artifact: &Value| -> Vec<u8> {
        let reference = artifact["reference"].as_str().unwrap();
        let (job, id) = reference
            .strip_prefix("arkdeck-artifact://")
            .and_then(|rest| rest.split_once('/'))
            .unwrap();
        std::fs::read(account.state().join("artifacts").join(job).join(id)).unwrap()
    };
    let hap = produced
        .iter()
        .find(|artifact| stored(artifact).starts_with(b"PK"))
        .unwrap_or_else(|| panic!("the build publishes its HAP: {built}"));
    assert_eq!(hap["bytesVerified"], true, "{built}");
    let bytes = stored(hap);
    assert_eq!(hap["sha256"], sha256_hex(&bytes).as_str(), "{built}");
    assert_eq!(hap["byteCount"], bytes.len(), "{built}");
    assert!(
        bytes
            .windows(b"module.json".len())
            .any(|window| window == b"module.json"),
        "the HAP carries its module.json"
    );
    assert!(
        !project.join(PRODUCT).exists(),
        "the person's own tree is never built"
    );
    running.stop();
    assert_account_released();
    drop(account);
    // What this measured is what the coverage manifest counts.
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .unwrap();
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    let statuses: Vec<&Value> = coverage["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["feature"] == "workspace.build-openharmony@1")
        .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
        .collect();
    assert_eq!(statuses, [&json!("implemented")]);
}
