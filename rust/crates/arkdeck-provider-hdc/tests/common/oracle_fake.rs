//! `HDCOracleFake` in process, for a Windows host (TASK-XPA-008/009): the
//! shared fake HDC of the Swift oracles answers from a POSIX shell fragment
//! (`hdc-answers.sh`) the driver sources, which a Windows host cannot run. The
//! debug-hap and deploy-native-library fragments, and the Flash host facts
//! oracle's own (`flash-host-facts/hdc-answers.sh`), are ported here, case
//! for case and in their order, over the same root: the call log the driver
//! appends to (`hdc-invocations.log`, U+001F after every argument), the mode
//! file it reads (`hdc-mode`), and the device state it keeps as marker files.
//! It reports its tool identity current, as the macOS dispatch over the fake's
//! verified script does. Test-only; no production binary contains it.
#![allow(dead_code)]

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The fake's fixed macOS root, which every recorded host path names.
pub const ORACLE_ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const BUNDLE: &str = "com.example.demo";

/// Which oracle's answers the fake gives.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Answers {
    DebugHap,
    NativeLibrary,
    FlashHostFacts,
}

impl Answers {
    /// The answers a fragment's first line names.
    pub fn of(fragment: &str) -> Self {
        match fragment.lines().next().unwrap_or_default() {
            line if line.starts_with("# debug.hap@1 answers") => Self::DebugHap,
            line if line.starts_with("# deploy.native-library.app-owned@1 answers") => {
                Self::NativeLibrary
            }
            line if line.starts_with("# flash.prerequisites answers") => Self::FlashHostFacts,
            other => panic!("no in-process port of the fake's answers {other:?}"),
        }
    }
}

pub struct OracleFake {
    root: PathBuf,
    answers: Answers,
}

/// What one call answered: its exit status and both streams.
struct Answer {
    status: i32,
    stdout: String,
    stderr: String,
}

impl Answer {
    fn out(stdout: impl Into<String>) -> Self {
        Self {
            status: 0,
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }
    fn exit(status: i32) -> Self {
        Self {
            status,
            stdout: String::new(),
            stderr: String::new(),
        }
    }
    fn unregistered() -> Self {
        Self {
            status: 23,
            stdout: String::new(),
            stderr: "unregistered fixture output\n".into(),
        }
    }
}

impl OracleFake {
    pub fn new(root: &Path, answers: Answers) -> Self {
        Self {
            root: root.to_owned(),
            answers,
        }
    }

    /// `marker "$path"`: the device path's state file below the root.
    fn marker(&self, path: &str) -> PathBuf {
        self.root
            .join(format!("device-path-{}", path.replace('/', "_")))
    }

    fn touch(path: &Path) {
        fs::write(path, b"").unwrap();
    }

    fn mode(&self) -> String {
        fs::read_to_string(self.root.join("hdc-mode"))
            .ok()
            .and_then(|text| text.lines().next().map(str::to_owned))
            .unwrap_or_else(|| "normal".into())
    }

    fn debug_hap(&self, argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        let arg = |n: usize| argv.get(n - 1).map(String::as_str).unwrap_or_default();
        let installed = self.root.join("device-installed");
        let running = self.root.join("device-running");
        let shell = format!("-t {KEY} shell ");
        if all == "list targets -v" {
            return Answer::out(format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"));
        }
        if all == format!("{shell}param get const.product.name") {
            return Answer::out("OpenHarmony Reference Device\n");
        }
        if all == format!("{shell}param get const.ohos.fullname") {
            return Answer::out("OpenHarmony-4.1-release\n");
        }
        if all.starts_with(&format!("{shell}mkdir -p /data/local/tmp/arkdeck-")) {
            Self::touch(&self.marker(arg(6)));
            return Answer::out("");
        }
        if all.starts_with(&format!("-t {KEY} file send ")) {
            Self::touch(&self.marker(arg(6)));
            return Answer::out("FileTransfer finish\n");
        }
        if all.starts_with(&format!("{shell}bm install -p ")) && all.ends_with(" -r") {
            if mode != "notInstalled" {
                Self::touch(&installed);
            }
            return Answer::out("install bundle successfully.\n");
        }
        if all == format!("{shell}bm dump -n {BUNDLE}") {
            if installed.exists() {
                return Answer::out(format!(
                    "{BUNDLE}:\n{{\"applicationInfo\":{{\"nativeLibraryPath\":\"libs/arm64\",\"cpuAbi\":\"arm64-v8a\"}},\"hapModuleInfos\":[{{\"nativeLibraryFileNames\":[\"libentry.so\"]}}]}}\n"
                ));
            }
            return Answer::out("");
        }
        if all == format!("{shell}aa start -b {BUNDLE} -a EntryAbility") {
            if mode == "startFailed" {
                return Answer::exit(1);
            }
            Self::touch(&running);
            return Answer::out("start ability successfully\n");
        }
        if all == format!("{shell}pidof {BUNDLE}") {
            if !running.exists() {
                return Answer::exit(1);
            }
            return Answer::out("3421\n");
        }
        if all == format!("{shell}hilog -x") {
            return Answer::out(if mode == "emptyHilog" {
                ""
            } else {
                "01-01 00:00:00 I app: hello\n"
            });
        }
        if all == format!("{shell}aa force-stop {BUNDLE}") {
            if mode != "stillRunning" {
                let _ = fs::remove_file(&running);
            }
            return Answer::out("");
        }
        if all == format!("-t {KEY} uninstall {BUNDLE}") {
            if mode != "stillInstalled" {
                let _ = fs::remove_file(&installed);
            }
            return Answer::out("uninstall bundle successfully\n");
        }
        if all.starts_with(&format!("{shell}rm -f /data/local/tmp/arkdeck-")) {
            if mode == "cleanupDebt" {
                return Answer {
                    status: 1,
                    stdout: String::new(),
                    stderr: format!("rm: {}: Permission denied\n", arg(6)),
                };
            }
            let _ = fs::remove_file(self.marker(arg(6)));
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}rmdir /data/local/tmp/arkdeck-")) {
            let _ = fs::remove_file(self.marker(arg(5)));
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}ls -ld /data/local/tmp/arkdeck-")) {
            let path = arg(6);
            return Answer::out(if !self.marker(path).exists() {
                format!("ls: {path}: No such file or directory\n")
            } else if path.ends_with("-packages") {
                format!("drwxr-xr-x 2 shell shell 3452 2026-09-14 00:00 {path}\n")
            } else {
                format!("-rw-r--r-- 1 shell shell 24 2026-09-14 00:00 {path}\n")
            });
        }
        Answer::unregistered()
    }

    fn native_library(&self, argv: &[String], mode: &str) -> Answer {
        const DIRECTORY: &str = "/data/app/el1/bundle/public/com.example.demo/libs/arm";
        const LOADER: &str = "/data/storage/el1/bundle/libs/arm/libexample.so";
        const REPLACED: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const LIBRARY: &str = "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53";
        const HELPER: &str = "86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1";
        let target = format!("{DIRECTORY}/libexample.so");
        let all = argv.join(" ");
        let arg = |n: usize| argv.get(n - 1).map(String::as_str).unwrap_or_default();
        let running = self.root.join("device-running");
        let published = self.root.join("device-published");
        let shell = format!("-t {KEY} shell ");
        // `listed "$path"`: the `ls` line of a device path.
        let listed = |path: &str| {
            let nested = path
                .split_once("/arkdeck-native/")
                .is_some_and(|(_, rest)| rest.contains('/'));
            if nested {
                format!("-rw------- 1 20010050 20010050 256 2026-09-14 00:00 {path}\n")
            } else if path == DIRECTORY
                || path.ends_with("/libs")
                || path.contains("/arkdeck-native/")
            {
                format!("drwx------ 2 20010050 20010050 3452 2026-09-14 00:00 {path}\n")
            } else {
                format!("-rw------- 1 20010050 20010050 256 2026-09-14 00:00 {path}\n")
            }
        };
        // `present "$path"`.
        let present = |path: &str| {
            if path == DIRECTORY || path == target || path.ends_with("/libs") {
                mode != "targetAbsent"
            } else {
                self.marker(path).exists()
            }
        };
        if all.starts_with(&format!("{shell}mkdir -p ")) {
            Self::touch(&self.marker(arg(6)));
            return Answer::out("");
        }
        if all.starts_with(&format!("-t {KEY} file send ")) {
            Self::touch(&self.marker(arg(6)));
            return Answer::out("FileTransfer finish\n");
        }
        if all.starts_with(&format!("{shell}chmod 700 ")) {
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}sha256sum ")) {
            let path = arg(5);
            if !present(path) {
                return Answer::out(format!("sha256sum: {path}: No such file or directory\n"));
            }
            let digest = if path.ends_with(".staging") {
                LIBRARY
            } else if path.ends_with("/arkdeck-code-sign-enable") {
                HELPER
            } else if path == target {
                if published.exists() {
                    LIBRARY
                } else {
                    REPLACED
                }
            } else {
                REPLACED
            };
            return Answer::out(format!("{digest}  {path}\n"));
        }
        if all.starts_with(&format!("{shell}ls -la ")) {
            let path = arg(6);
            return Answer::out(if present(path) {
                format!("total 4\n{}", listed(&format!("{path}/arm")))
            } else {
                format!("ls: {path}: No such file or directory\n")
            });
        }
        if ["ls -l ", "ls -ld ", "ls -ln "]
            .iter()
            .any(|command| all.starts_with(&format!("{shell}{command}")))
        {
            let path = arg(6);
            return Answer::out(if present(path) {
                listed(path)
            } else {
                format!("ls: {path}: No such file or directory\n")
            });
        }
        if all.starts_with(&format!("{shell}rm -f ")) {
            if mode != "cleanupFailure" {
                let _ = fs::remove_file(self.marker(arg(6)));
            }
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}rmdir ")) {
            if mode != "cleanupFailure" {
                let _ = fs::remove_file(self.marker(arg(5)));
            }
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}ln ")) {
            Self::touch(&self.marker(arg(6)));
            return Answer::out("");
        }
        if all.starts_with(&format!("{shell}mv -f ")) {
            let _ = fs::remove_file(self.marker(arg(6)));
            let _ = fs::remove_file(&published);
            return Answer::out("");
        }
        if all.starts_with(&shell) && all.contains("/arkdeck-code-sign-enable verify ") {
            return Answer::out(if mode == "unattested" {
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n".to_owned()
            } else {
                format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n")
            });
        }
        if all.starts_with(&shell) && all.contains("/arkdeck-code-sign-enable publish ") {
            Self::touch(&published);
            return Answer::out(if mode == "unattested" {
                "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED replaced-file-had-none\n".to_owned()
            } else {
                format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n")
            });
        }
        if all == format!("{shell}aa force-stop {BUNDLE}") {
            let _ = fs::remove_file(&running);
            return Answer::out("");
        }
        if all == format!("{shell}aa start -b {BUNDLE} -a EntryAbility") {
            Self::touch(&running);
            return Answer::out("");
        }
        if all == format!("{shell}pidof {BUNDLE}") {
            if !running.exists() {
                return Answer::exit(1);
            }
            return Answer::out("4321\n");
        }
        if all == format!("{shell}sleep 2") {
            return Answer::out("");
        }
        if all == format!("{shell}grep -F {LOADER} /proc/*/maps") {
            if mode == "loaderFailure" && published.exists() {
                return Answer::exit(1);
            }
            return Answer::out(format!("/proc/4321/maps:7f000 {LOADER}\n"));
        }
        Answer::unregistered()
    }
}

impl OracleFake {
    /// `flash-host-facts/hdc-answers.sh`: the Rockchip facts probe's list of
    /// targets, by mode, and the product's full name for either key.
    fn flash_host_facts(argv: &[String], mode: &str) -> Answer {
        const HDC_KEY: &str = "1501ffff00000000000000000000cafe";
        const NEW_KEY: &str = "1501ffff0000000000000000000beef1";
        let all = argv.join(" ");
        if all == "list targets -v" {
            return match mode {
                "hdcKey" => Answer::out(format!("{HDC_KEY}\t\tUSB\tConnected\tlocalhost\n")),
                "newKey" => Answer::out(format!("{NEW_KEY}\t\tUSB\tConnected\tlocalhost\n")),
                "offline" => Answer::out(format!("{HDC_KEY}\t\tUSB\tOffline\tlocalhost\n")),
                "empty" => Answer::out("[Empty]\r\n"),
                "malformed" => Answer::out("no device table here\n"),
                _ => Answer {
                    status: 1,
                    stdout: String::new(),
                    stderr: "list targets failed\n".into(),
                },
            };
        }
        if [HDC_KEY, NEW_KEY]
            .iter()
            .any(|key| all == format!("-t {key} shell param get const.ohos.fullname"))
        {
            return Answer::out("OpenHarmony-7.0.0.36\n");
        }
        Answer::unregistered()
    }
}

impl HdcDispatch for OracleFake {
    fn mutation_identity_current(&self) -> bool {
        true
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        // The driver logs every call before it answers it.
        let mut line = String::new();
        for argument in &plan.arguments {
            line.push_str(argument);
            line.push('\u{1f}');
        }
        line.push('\n');
        OpenOptions::new()
            .append(true)
            .create(true)
            .open(self.root.join("hdc-invocations.log"))
            .unwrap()
            .write_all(line.as_bytes())
            .unwrap();
        let mode = self.mode();
        let answer = match self.answers {
            Answers::DebugHap => self.debug_hap(&plan.arguments, &mode),
            Answers::NativeLibrary => self.native_library(&plan.arguments, &mode),
            Answers::FlashHostFacts => Self::flash_host_facts(&plan.arguments, &mode),
        };
        Ok(Receipt {
            exit_status: answer.status,
            stdout: answer.stdout.into_bytes(),
            stderr: answer.stderr.into_bytes(),
            truncated: false,
            duration: Duration::from_millis(1),
        })
    }
}

/// `text` with every host path below `root` spelled as the oracle recorded
/// it: the fake's fixed macOS root and `/` between components. On macOS the
/// root is the oracle's and nothing changes. A path ends at a U+001F argument
/// separator, a line break or a quote.
pub fn oracle_spelling(text: &str, root: &Path) -> String {
    let root = root.to_string_lossy().into_owned();
    if root == ORACLE_ROOT {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(&root) {
        out.push_str(&rest[..at]);
        out.push_str(ORACLE_ROOT);
        let tail = &rest[at + root.len()..];
        let end = tail.find(['\u{1f}', '\n', '"', ' ']).unwrap_or(tail.len());
        out.push_str(&tail[..end].replace('\\', "/"));
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

/// As [`oracle_spelling`], for JSON text, where each `\` of a host path is
/// written `\\`: the root in that spelling becomes the oracle's, and each
/// escaped separator after it `/`. A path ends at a quote.
pub fn oracle_spelling_json(text: &str, root: &Path) -> String {
    let root = root.to_string_lossy().into_owned();
    if root == ORACLE_ROOT {
        return text.to_owned();
    }
    let escaped = root.replace('\\', "\\\\");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(&escaped) {
        out.push_str(&rest[..at]);
        out.push_str(ORACLE_ROOT);
        let tail = &rest[at + escaped.len()..];
        let end = tail.find('"').unwrap_or(tail.len());
        out.push_str(&tail[..end].replace("\\\\", "/"));
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}
