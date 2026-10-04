//! `HDCOracleFake` in process, for a Windows host (TASK-XPA-008/009): the
//! shared fake HDC of the Swift oracles answers from a POSIX shell fragment
//! (`hdc-answers.sh`) the driver sources, which a Windows host cannot run. The
//! debug-hap and deploy-native-library fragments, the Flash host facts
//! oracle's own (`flash-host-facts/hdc-answers.sh`), and `observe.device@1`'s
//! and `capture.diagnostics@1`'s (`ArkDeckFakeHDCFixture`'s tables, and the
//! read, file and Trace legs' fragments) and the Debug probe oracle's
//! (`debug-probe/hdc-answers.sh`), and the GJ-1 pointer inputs'
//! (`pointer-input/hdc-answers.sh`) are ported here, case for case and in
//! their order, over the same root: the call log the driver
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
    ObserveDevice,
    CaptureDiagnostics,
    ReadLegs,
    FileLegs,
    TraceLegs,
    HumanAction,
    DebugProbe,
    PointerInput,
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
            line if line.starts_with("# observe.device@1 answers of ArkDeckFakeHDCFixture") => {
                Self::ObserveDevice
            }
            line if line.starts_with(
                "# capture.diagnostics@1 answers of ArkDeckFakeHDCFixture and the scripted",
            ) =>
            {
                Self::CaptureDiagnostics
            }
            line if line.starts_with("# capture.diagnostics@1 read-leg answers") => Self::ReadLegs,
            line if line.starts_with("# capture.diagnostics@1 file-leg answers") => Self::FileLegs,
            line if line.starts_with("# capture.diagnostics@1 Trace-leg answers") => {
                Self::TraceLegs
            }
            line if line.starts_with("# Physical assistance: the device list") => Self::HumanAction,
            line if line.starts_with("# debug.probe and debug.template.run answers") => {
                Self::DebugProbe
            }
            line if line.starts_with("# input.tap@1, input.long-press@1 and input.swipe@1") => {
                Self::PointerInput
            }
            other => panic!("no in-process port of the fake's answers {other:?}"),
        }
    }
}

pub struct OracleFake {
    root: PathBuf,
    answers: Answers,
}

/// What one call answered: its exit status and both streams, or an outcome
/// nothing observes (a child that outlived its plan's budget, or died on a
/// signal), reported as the process dispatch reports it.
struct Answer {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    unobservable: Option<String>,
}

impl Answer {
    fn out(stdout: impl Into<String>) -> Self {
        Self::bytes(stdout.into().into_bytes())
    }
    fn bytes(stdout: Vec<u8>) -> Self {
        Self {
            status: 0,
            stdout,
            stderr: Vec::new(),
            unobservable: None,
        }
    }
    fn exit(status: i32) -> Self {
        Self {
            status,
            stdout: Vec::new(),
            stderr: Vec::new(),
            unobservable: None,
        }
    }
    /// Exits `status` after printing `stdout`.
    fn failing(status: i32, stdout: impl Into<String>) -> Self {
        Self {
            status,
            ..Self::out(stdout)
        }
    }
    /// Exits `status` after printing `stderr`.
    fn refusing(status: i32, stderr: impl Into<String>) -> Self {
        Self {
            status,
            stdout: Vec::new(),
            stderr: stderr.into().into_bytes(),
            unobservable: None,
        }
    }
    fn unregistered() -> Self {
        Self::refusing(23, "unregistered fixture output\n")
    }
    /// `exec /bin/sleep <seconds>` past the plan's budget: the dispatch's
    /// timeout, as `ProcessDispatch` reports it.
    fn hangs() -> Self {
        Self {
            unobservable: Some("process timed out before completion".into()),
            ..Self::exit(0)
        }
    }
    /// `kill -9 $$`: the dispatch's signal death, as `ProcessDispatch` reports
    /// it.
    fn killed() -> Self {
        Self {
            unobservable: Some(arkdeck_provider_hdc::signal_death(9)),
            ..Self::exit(0)
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
                return Answer::refusing(1, format!("rm: {}: Permission denied\n", arg(6)));
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
        // The Swift oracle's Jobs never listed the device; the CLI's domain
        // leaf observes it first (`debug native deploy`), as `debug hap`
        // does over the debug HAP table: the fixture's one target.
        if all == "list targets -v" {
            return Self::fixture_device(&all, mode).unwrap();
        }
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
                _ => Answer::refusing(1, "list targets failed\n"),
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

impl OracleFake {
    /// `observe-device/hdc-answers.sh`: `ArkDeckFakeHDCFixture`'s
    /// `observe.device@1` table, by mode.
    fn observe_device(argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        if all == "-v" {
            return Answer::out(if mode == "emptyVersion" {
                ""
            } else {
                "Ver: 3.2.0d\n"
            });
        }
        if all == "checkserver" {
            let server = if mode == "serverMismatch" {
                "3.2.0f"
            } else {
                "3.2.0d"
            };
            return Answer::out(format!(
                "Client version:Ver: 3.2.0d, server version:Ver: {server}\n"
            ));
        }
        Self::fixture_device(&all, mode).unwrap_or_else(Answer::unregistered)
    }

    /// `capture-diagnostics/hdc-answers.sh`: the same fixture's
    /// `capture.diagnostics@1` table and the scripted dispatcher's, by mode.
    fn capture_diagnostics(argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        let shell = format!("-t {KEY} shell ");
        if all == "-v" {
            return Answer::out("Ver: 3.2.0d\n");
        }
        if all == "checkserver" {
            return Answer::out("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n");
        }
        if let Some(answer) = Self::fixture_device(&all, mode) {
            return answer;
        }
        if all == format!("{shell}df -k /data/local/tmp") {
            let available = if mode == "lowStorage" {
                "16"
            } else {
                "1047552"
            };
            return Answer::out(format!(
                "Filesystem 1K-blocks Used Available Use% Mounted on\n\
                 /dev/block/data 1048576 1024 {available} 1% /data\n"
            ));
        }
        if all == format!("{shell}hilog -x") {
            return Answer::out(if mode == "emptyHilog" {
                ""
            } else {
                "01-01 00:00:00 I app: hello\n"
            });
        }
        if all == format!("{shell}hidumper -s WindowManagerService -a -a") {
            return Answer::out("{\"windows\":[]}\n");
        }
        Answer::unregistered()
    }

    /// The fixture's device rows and property reads, which both tables share:
    /// the one target (another device's in `otherDevice`), its product name
    /// and its full build.
    fn fixture_device(all: &str, mode: &str) -> Option<Answer> {
        if all == "list targets -v" {
            let row = if mode == "otherDevice" {
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            } else {
                KEY
            };
            return Some(Answer::out(format!("{row}\t\tUSB\tConnected\tlocalhost\n")));
        }
        if all == format!("-t {KEY} shell param get const.product.name") {
            return Some(Answer::out("OpenHarmony Reference Device\n"));
        }
        if all == format!("-t {KEY} shell param get const.ohos.fullname") {
            return Some(Answer::out("OpenHarmony-4.1-release\n"));
        }
        None
    }
}

/// The devices the file and Trace legs' fixtures adopted: the first is the
/// default a call names.
const FILE_LEG_KEYS: [&str; 4] = [
    KEY,
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "cccccccccccccccccccccccccccccccc",
    "dddddddddddddddddddddddddddddddd",
];
const TRACE_LEG_KEYS: [&str; 2] = [KEY, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"];

impl OracleFake {
    /// `capture-diagnostics-read-legs/hdc-answers.sh`: the legs that only
    /// read the device, by mode.
    fn read_legs(argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        let shell = format!("-t {KEY} shell ");
        if all == "list targets -v" {
            return Answer::out(format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"));
        }
        if let Some(answer) = Self::device_basics(&all, KEY) {
            return answer;
        }
        if all == format!("{shell}hilog -x") {
            return Answer::out("01-01 00:00:00 I app: hello\n");
        }
        if all == format!("{shell}hidumper -s WindowManagerService -a -a") {
            return Answer::out("{\"windows\":[]}\n");
        }
        if all == format!("{shell}hidumper -s WindowManagerService -a -w 7 -element -lastpage 42") {
            return match mode {
                "degraded" => Answer::bytes(b"ComponentInfo \xff\xfe\n".to_vec()),
                "hang" => Answer::hangs(),
                _ => Answer::out("WindowId: 7\nComponentId: 42\ntype: Button\ntext: Sign in\n"),
            };
        }
        if all == format!("{shell}hidumper -s 1201 -a -p Faultlogger -l") {
            return match mode {
                "degraded" => Answer::failing(
                    1,
                    "\nFault log list:\n******\n******\nNo fault log exist.\n",
                ),
                "truncated" => Answer::bytes(vec![b'x'; 8_400_000]),
                "large" => {
                    let mut stdout = vec![b'y'; 1_100_000];
                    stdout.push(b'\n');
                    Answer::bytes(stdout)
                }
                // The fragment's `HiviewService` banner is a `printf` whose
                // format starts with `-`, which the oracle's `/bin/sh` read as
                // an invalid option: it never reached stdout, and Swift's
                // ledger does not carry it.
                _ => Answer::out(
                    "\n-------------------------------[ability]-------------------------------\n\n\
                     Fault log list:\n******\n\
                     cppcrash-com.example.demo-20010039-20260914000000\n\
                     jscrash-com.example.demo-20010039-20260913235959\n******\n",
                ),
            };
        }
        if all.starts_with(&format!("{shell}hidumper -s 1201 -a -p Faultlogger -f ")) {
            return match mode {
                "degraded" => Answer::out("invalid parameters.\n"),
                "headerless" => Answer::out("Fault log list:\n"),
                _ => Answer::out(format!(
                    "Generated by HiviewDFX@OpenHarmony\n\
                     ================================================================\n\
                     Device info:OpenHarmony 3.2\nModule name:com.example.demo\n\
                     Process name:{}\n",
                    last_word(argv, 8)
                )),
            };
        }
        if all.starts_with(&format!("{shell}pidof ")) {
            return match mode {
                "degraded" => Answer::out(""),
                "ambiguous" => Answer::out("1234 render\n"),
                "unavailable" => {
                    Answer::failing(127, "/bin/sh: pidof: inaccessible or not found\n")
                }
                "killed" => Answer::killed(),
                _ => Answer::out("1234\n"),
            };
        }
        Answer::unregistered()
    }

    /// `capture-diagnostics-file-legs/hdc-answers.sh`: the component tree and
    /// the screenshot, each written to a provider-owned path, read back,
    /// received and removed, by mode, on the device the call names.
    fn file_legs(&self, argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        let key = adopted(argv, &FILE_LEG_KEYS);
        let shell = format!("-t {key} shell ");
        let arg = |n: usize| argv.get(n - 1).map(String::as_str).unwrap_or_default();
        fs::create_dir_all(self.root.join("device-tmp")).unwrap();
        if all == "list targets -v" {
            return Answer::out(
                FILE_LEG_KEYS
                    .iter()
                    .map(|adopted| format!("{adopted}\t\tUSB\tConnected\tlocalhost\n"))
                    .collect::<String>(),
            );
        }
        if let Some(answer) = Self::device_basics(&all, key) {
            return answer;
        }
        if all.starts_with(&format!(
            "{shell}uitest dumpLayout -p /data/local/tmp/arkdeck-"
        )) {
            match mode {
                "emptyTree" => fs::write(self.device(arg(7)), b"").unwrap(),
                "treeMissing" => return Answer::failing(1, "DumpLayout failed: no window\n"),
                _ => fs::write(
                    self.device(arg(7)),
                    b"{\"attributes\":{\"text\":\"Sign in\",\"hint\":\"/private/tmp/arkdeck-hdc-oracle/home/Documents/draft.txt\"},\"children\":[]}\n",
                )
                .unwrap(),
            }
            return Answer::out(format!("DumpLayout saved to:{}\n", arg(7)));
        }
        if all.starts_with(&format!("{shell}snapshot_display -t ")) {
            return self.snapshot(arg(6), arg(8), arg(6) == "jpeg" || mode == "notPNG");
        }
        if let Some(answer) = self.owned_file(&all, &shell, key, argv, mode) {
            return answer;
        }
        if all.starts_with(&format!("{shell}rm -f /data/local/tmp/arkdeck-")) {
            return match mode {
                "cleanupRefused" => {
                    Answer::failing(1, format!("rm: {}: Read-only file system\n", arg(6)))
                }
                "cleanupTimeout" => Answer::hangs(),
                _ => {
                    let _ = fs::remove_file(self.device(arg(6)));
                    Answer::out("")
                }
            };
        }
        Answer::unregistered()
    }

    /// `capture-diagnostics-trace/hdc-answers.sh`: the Trace legs, blocking and
    /// ring-buffered, and the Trace Runtime probe's reads, by mode. Each call
    /// also appends its own line to `hdc-calls.log`, since the probe's reads
    /// run concurrently.
    fn trace_legs(&self, argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        OpenOptions::new()
            .append(true)
            .create(true)
            .open(self.root.join("hdc-calls.log"))
            .unwrap()
            .write_all(format!("{all}\n").as_bytes())
            .unwrap();
        let key = adopted(argv, &TRACE_LEG_KEYS);
        let shell = format!("-t {key} shell ");
        let arg = |n: usize| argv.get(n - 1).map(String::as_str).unwrap_or_default();
        let resource = |name: &str| fs::read(self.root.join("resources").join(name)).unwrap();
        let ring = self.root.join("device-ring");
        fs::create_dir_all(self.root.join("device-tmp")).unwrap();
        if all == "list targets -v" {
            return Answer::out(
                TRACE_LEG_KEYS
                    .iter()
                    .map(|adopted| format!("{adopted}\t\tUSB\tConnected\tlocalhost\n"))
                    .collect::<String>(),
            );
        }
        if all == format!("{shell}param get const.product.name") {
            return Answer::out("OpenHarmony Reference Device\n");
        }
        if all == format!("{shell}param get const.ohos.fullname") {
            return Answer::out("OpenHarmony-4.1-release\n");
        }
        if all.starts_with(&format!("{shell}param get ")) {
            return trace_parameter(arg(6), mode);
        }
        if let Some(answer) = Self::device_basics(&all, key) {
            return answer;
        }
        if all == format!("{shell}hitrace --help") {
            return Answer::bytes(resource("hitrace-help.stdout.bin"));
        }
        if all == format!("{shell}bytrace --help") {
            return Answer::bytes(resource("bytrace-help.stdout.bin"));
        }
        if all == format!("{shell}hitrace -l") {
            let lost = "[Fail]ExecuteCommand need connect-key?\n";
            return match mode {
                "tagListLost" => Answer::out(lost),
                "afterTagListLost" if self.root.join("tag-list-read").exists() => Answer::out(lost),
                "afterTagListLost" => {
                    Self::touch(&self.root.join("tag-list-read"));
                    Answer::bytes(resource("hitrace-tags.stdout.bin"))
                }
                _ => Answer::bytes(resource("hitrace-tags.stdout.bin")),
            };
        }
        if all.starts_with(&format!("{shell}pidof ")) {
            return Answer::out("1234\n");
        }
        if all == format!("{shell}hilog -x") {
            return Answer::out("01-01 00:00:00 I app: hello\n");
        }
        if all == format!("{shell}hidumper -s WindowManagerService -a -a") {
            return Answer::out("{\"windows\":[]}\n");
        }
        if all == format!("{shell}hidumper -s WindowManagerService -a -w 7 -element -lastpage 42") {
            return Answer::out("WindowId: 7\nComponentId: 42\ntype: Button\ntext: Sign in\n");
        }
        if all == format!("{shell}hidumper -s 1201 -a -p Faultlogger -l") {
            return Answer::out(
                "Fault log list:\n******\ncppcrash-com.example.demo-20010039-20260914000000\n******\n",
            );
        }
        if all.starts_with(&format!("{shell}hidumper -s 1201 -a -p Faultlogger -f ")) {
            return Answer::out(format!(
                "Generated by HiviewDFX@OpenHarmony\nProcess name:{}\n",
                last_word(argv, 8)
            ));
        }
        if all.starts_with(&format!(
            "{shell}uitest dumpLayout -p /data/local/tmp/arkdeck-"
        )) {
            fs::write(
                self.device(arg(7)),
                b"{\"attributes\":{\"text\":\"Sign in\"},\"children\":[]}\n",
            )
            .unwrap();
            return Answer::out(format!("DumpLayout saved to:{}\n", arg(7)));
        }
        if all.starts_with(&format!("{shell}snapshot_display -t ")) {
            return self.snapshot(arg(6), arg(8), false);
        }
        if all.starts_with(&format!("{shell}hitrace -t ")) {
            // The owned path is the last argument, after `-o`.
            let owned = self.device(argv.last().map(String::as_str).unwrap_or_default());
            match mode {
                "emptyTrace" => fs::write(owned, b"").unwrap(),
                "traceMissing" => return Answer::failing(1, "hitrace: capture failed\n"),
                _ => fs::write(
                    owned,
                    b"# tracer: nop\n  hitrace-1 [000] ....  1.000000: tracing_mark_write: B|1|capture\n",
                )
                .unwrap(),
            }
            return Answer::out("hitrace enter, running_state is RECORDING_SHORT_TEXT\n");
        }
        if all.starts_with(&format!("{shell}hitrace --trace_begin -b ")) {
            fs::write(&ring, b"").unwrap();
            return Answer::out("hitrace enter, running_state is RECORDING_LONG_BEGIN\n");
        }
        if let Some(command) = all.strip_prefix(&format!("{shell}echo ARKDECKANCHOR")) {
            let marker = format!("ARKDECKANCHOR{}", first_word(command));
            OpenOptions::new()
                .append(true)
                .create(true)
                .open(&ring)
                .unwrap()
                .write_all(format!("{marker}\n").as_bytes())
                .unwrap();
            return Answer::out("");
        }
        if let Some(command) = all.strip_prefix(&format!("{shell}grep -c ARKDECKANCHOR")) {
            if mode == "ringNotHeld" {
                return Answer::out("0\n");
            }
            let marker = format!("ARKDECKANCHOR{}", first_word(command));
            let held = fs::read_to_string(&ring)
                .unwrap_or_default()
                .lines()
                .filter(|line| line.contains(&marker))
                .count();
            // `grep -c` prints its count and exits 1 when nothing matched.
            return Answer::failing(i32::from(held == 0), format!("{held}\n"));
        }
        if all.starts_with(&format!("{shell}sleep ")) {
            return Answer::out("");
        }
        if all.starts_with(&format!(
            "{shell}hitrace --trace_dump -o /data/local/tmp/arkdeck-"
        )) {
            let mut dump = String::from("# tracer: nop\n");
            for line in fs::read_to_string(&ring).unwrap_or_default().lines() {
                dump.push_str(&format!(
                    "  <...>-1 [000] ....  1.000000: tracing_mark_write: {line}\n"
                ));
            }
            fs::write(self.device(arg(7)), dump).unwrap();
            return Answer::out("hitrace enter, running_state is SNAPSHOT_DUMP\n");
        }
        if all == format!("{shell}hitrace --trace_finish_nodump") {
            return Answer::out("hitrace enter, running_state is RECORDING_LONG_FINISH_NODUMP\n");
        }
        // The Trace legs' receive always copies; only the cleanup has modes.
        if let Some(answer) = self.owned_file(&all, &shell, key, argv, "normal") {
            return answer;
        }
        if all.starts_with(&format!("{shell}rm -f /data/local/tmp/arkdeck-")) {
            if mode == "cleanupRefused" {
                return Answer::failing(1, format!("rm: {}: Read-only file system\n", arg(6)));
            }
            let _ = fs::remove_file(self.device(arg(6)));
            return Answer::out("");
        }
        Answer::unregistered()
    }

    /// `agent-human-action/hdc-answers.sh`: the physical assistance an agent
    /// execution waits on (the device list offline, unauthorized or with two
    /// devices, and a Job held at its server check until `released` exists
    /// below the root), then `capture.diagnostics@1`'s table.
    fn human_action(&self, argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        if all == "list targets -v" {
            let row = |key: &str, state: &str| format!("{key}\t\tUSB\t{state}\tlocalhost\n");
            match mode {
                "offline" => return Answer::out(row(KEY, "Offline")),
                "unauthorized" => return Answer::out(row(KEY, "Unauthorized")),
                "twoDevices" => {
                    return Answer::out(
                        row(KEY, "Connected")
                            + &row("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "Connected"),
                    );
                }
                _ => {}
            }
        }
        if mode == "heldServer" && all == "checkserver" {
            while !self.root.join("released").exists() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        Self::capture_diagnostics(argv, mode)
    }

    /// The reads every leg's table shares, on device `key`: its product name,
    /// its full build and the free space under `/data/local/tmp`.
    fn device_basics(all: &str, key: &str) -> Option<Answer> {
        if all == format!("-t {key} shell param get const.product.name") {
            return Some(Answer::out("OpenHarmony Reference Device\n"));
        }
        if all == format!("-t {key} shell param get const.ohos.fullname") {
            return Some(Answer::out("OpenHarmony-4.1-release\n"));
        }
        if all == format!("-t {key} shell df -k /data/local/tmp") {
            return Some(Answer::out(
                "Filesystem 1K-blocks Used Available Use% Mounted on\n\
                 /dev/block/data 1048576 1024 1047552 1% /data\n",
            ));
        }
        None
    }

    /// `device "$path"`: a device path below `/data/local/tmp`, kept in the
    /// fake's `device-tmp` so that a Job's owned files outlive its calls.
    fn device(&self, path: &str) -> PathBuf {
        let name = path.strip_prefix("/data/local/tmp/").unwrap_or(path);
        self.root.join("device-tmp").join(name)
    }

    /// `snapshot_display -t <type> -f <path>`: a still written at `path`, a
    /// JPEG one when `jpeg`, a PNG one otherwise.
    fn snapshot(&self, image_type: &str, path: &str, jpeg: bool) -> Answer {
        let still: &[u8] = if jpeg {
            b"\xff\xd8\xff\xe0JFIF still"
        } else {
            b"\x89PNG\r\n\x1a\nIHDR still"
        };
        fs::write(self.device(path), still).unwrap();
        Answer::out(format!(
            "process: display 0, file type: {image_type}, width: 720, height: 1280\n"
        ))
    }

    /// An owned file's readback (`ls -l`) and receive (`file recv`), which the
    /// file and Trace legs share: the receive lands the device's bytes at the
    /// host path the call names, empty when `emptyLanding`, and nothing when
    /// `nothingLanded`.
    fn owned_file(
        &self,
        all: &str,
        shell: &str,
        key: &str,
        argv: &[String],
        mode: &str,
    ) -> Option<Answer> {
        let arg = |n: usize| argv.get(n - 1).map(String::as_str).unwrap_or_default();
        if all.starts_with(&format!("{shell}ls -l /data/local/tmp/arkdeck-")) {
            let path = arg(6);
            return Some(Answer::out(match fs::metadata(self.device(path)) {
                Ok(metadata) if metadata.is_file() => format!(
                    "-rw-rw-rw- 1 shell shell {} 2026-09-14 00:00 {path}\n",
                    metadata.len()
                ),
                _ => format!("ls: {path}: No such file or directory\n"),
            }));
        }
        if all.starts_with(&format!("-t {key} file recv /data/local/tmp/arkdeck-")) {
            match mode {
                "emptyLanding" => fs::write(arg(6), b"").unwrap(),
                "nothingLanded" => {}
                _ => {
                    let _ = fs::copy(self.device(arg(5)), arg(6));
                }
            }
            return Some(Answer::out("FileTransfer finish\n"));
        }
        None
    }
}

/// The adopted device a call names (`-t <key>`), or the first one.
fn adopted<'a>(argv: &[String], keys: &[&'a str]) -> &'a str {
    match (argv.first().map(String::as_str), argv.get(1)) {
        (Some("-t"), Some(named)) => keys
            .iter()
            .copied()
            .find(|key| *key == named)
            .unwrap_or(keys[0]),
        _ => keys[0],
    }
}

/// `${n##* }`: the last word of argument `n`.
fn last_word(argv: &[String], n: usize) -> String {
    let argument = argv.get(n - 1).map(String::as_str).unwrap_or_default();
    argument.rsplit(' ').next().unwrap_or_default().to_owned()
}

/// The first word of `text`: `${marker%% *}`.
fn first_word(text: &str) -> &str {
    text.split(' ').next().unwrap_or_default()
}

/// The Trace legs' `parameter "$6"`: each probed parameter's answer, the
/// animation trace's unreadable while the ring is not held.
fn trace_parameter(name: &str, mode: &str) -> Answer {
    if mode == "ringNotHeld" && name == "persist.rosen.animationtrace.enabled" {
        return Answer::failing(1, "device offline\n");
    }
    match name {
        "persist.ace.trace.syntax.enabled" => Answer::out("false\n"),
        "persist.ace.trace.layout.enabled" => Answer::out(format!("{name} = true\n")),
        "persist.ace.trace.build.enabled" => {
            Answer::out(format!("Get parameter \"{name}\" fail! errNum is:106!\n"))
        }
        "persist.ace.trace.measure.debug.enabled" => Answer::out(format!("{name}=1\n")),
        "persist.ace.trace.sync.debug.enabled" => Answer::out(""),
        "persist.ace.debug.enabled" => Answer::out("0\n"),
        "persist.ace.performance.monitor.enabled" => Answer::out("\n  true  \n\n"),
        "persist.sys.graphic.openDebugTrace" => Answer::out("1\n"),
        "persist.rosen.animationtrace.enabled" => Answer::out("false\n"),
        _ => Answer::refusing(24, "unregistered fixture parameter\n"),
    }
}

impl OracleFake {
    /// `debug-probe/hdc-answers.sh`: the Debug probe's three reads and the
    /// four read-only templates, by mode. Each call is also recorded as one
    /// line of its arguments in `hdc-calls.log`, as the fragment records it.
    fn debug_probe(&self, argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        OpenOptions::new()
            .append(true)
            .create(true)
            .open(self.root.join("hdc-calls.log"))
            .unwrap()
            .write_all(format!("{all}\n").as_bytes())
            .unwrap();
        let key = KEY;
        match all.as_str() {
            command if command == format!("-t {key} shell bm dump -a") => match mode {
                "packagesUnavailable" | "allUnavailable" => Answer::exit(1),
                "packagesUnparseable" => Answer::out("no bundle is installed\n"),
                _ => Answer::out("Bundle names:\n\tcom.example.alpha\n\tcom.example.zeta\n"),
            },
            command if command == format!("-t {key} fport ls") => match mode {
                "forwardUnavailable" | "allUnavailable" => Answer::exit(1),
                _ => Answer::out("tcp:9000 tcp:9001    [Forward]\n"),
            },
            command if command == format!("-t {key} rport ls") => match mode {
                "reverseUnavailable" | "allUnavailable" => {
                    Answer::refusing(0, "[Fail]Device not founded or connected\n")
                }
                _ => Answer::out("tcp:9100 tcp:9101    [Reverse]\n"),
            },
            command if command == format!("-t {key} shell param get persist.ace.debug.enabled") => {
                match mode {
                    "templateTruncated" => {
                        Answer::out("persist.ace.debug.enabled=true\n".repeat(600))
                    }
                    // `printf '...\377\n'`: one byte that is not UTF-8.
                    "templateBinary" => Answer::bytes(b"persist.ace.debug.enabled=\xff\n".to_vec()),
                    _ => Answer::out("true\n"),
                }
            }
            command
                if command == format!("-t {key} shell hidumper -s WindowManagerService -a -a") =>
            {
                Answer::out("WindowManagerService\n----------\nfocus window: com.example.alpha\n")
            }
            command if command == format!("-t {key} shell uptime") => match mode {
                "templateFailure" => Answer::refusing(7, "uptime: cannot read /proc/uptime\n"),
                // `kill -9 $$`.
                "templateKilled" => Answer::killed(),
                _ => Answer::out(" 10:00:00 up 1 day,  2:03,  0 users\n"),
            },
            _ => Answer::unregistered(),
        }
    }
}

impl OracleFake {
    /// `pointer-input/hdc-answers.sh`: the fixture's device and the pointer
    /// gestures `uinput` injects, by mode: a tap's click, a long press's touch
    /// down and up, a swipe's move, each followed by `uinput`'s boundary
    /// hint; a refusal (`rejected`), nothing (`silent`) or another gesture's
    /// echo (`otherGesture`) in place of any of them.
    fn pointer_input(argv: &[String], mode: &str) -> Answer {
        let all = argv.join(" ");
        if let Some(answer) = Self::fixture_device(&all, "normal") {
            return answer;
        }
        if !all.starts_with(&format!("-t {KEY} shell uinput ")) {
            return Answer::unregistered();
        }
        match mode {
            "rejected" => return Answer::out("parameter error, unable to run\n"),
            "silent" => return Answer::exit(0),
            "otherGesture" => {
                return Answer::out("startX:100, startY:2200, endX:100, endY:1200\n");
            }
            _ => {}
        }
        // `shift 4`, and `shift 2` past a display (`-D <id>`): `$1` is then
        // `-T`, `$2` the gesture.
        let mut rest = &argv[4..];
        if rest.first().map(String::as_str) == Some("-D") {
            rest = rest.get(2..).unwrap_or_default();
        }
        let arg = |n: usize| rest.get(n - 1).map(String::as_str).unwrap_or_default();
        let gesture = match arg(2) {
            "-c" => format!(
                "   click coordinate: ({}, {})\nclick interval time: 100ms\n",
                arg(3),
                arg(4)
            ),
            "-d" => format!(
                "touch down {} {}\ntouch up {} {}\n",
                arg(3),
                arg(4),
                arg(8),
                arg(9)
            ),
            "-m" => format!(
                "startX:{}, startY:{}, endX:{}, endY:{}\n",
                arg(3),
                arg(4),
                arg(5),
                arg(6)
            ),
            _ => String::new(),
        };
        Answer::out(
            gesture
                + "If the command does not work as expected, check whether the specified \
                   coordinates exceed the screen boundary\n",
        )
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
        let mut answer = match self.answers {
            Answers::DebugHap => self.debug_hap(&plan.arguments, &mode),
            Answers::NativeLibrary => self.native_library(&plan.arguments, &mode),
            Answers::FlashHostFacts => Self::flash_host_facts(&plan.arguments, &mode),
            Answers::ObserveDevice => Self::observe_device(&plan.arguments, &mode),
            Answers::CaptureDiagnostics => Self::capture_diagnostics(&plan.arguments, &mode),
            Answers::ReadLegs => Self::read_legs(&plan.arguments, &mode),
            Answers::FileLegs => self.file_legs(&plan.arguments, &mode),
            Answers::TraceLegs => self.trace_legs(&plan.arguments, &mode),
            Answers::HumanAction => self.human_action(&plan.arguments, &mode),
            Answers::DebugProbe => self.debug_probe(&plan.arguments, &mode),
            Answers::PointerInput => Self::pointer_input(&plan.arguments, &mode),
        };
        if let Some(reason) = answer.unobservable {
            return Err(DispatchFailure::Unobservable(reason));
        }
        // The runner keeps each stream's first `capture_bytes` bytes and says
        // whether either went past them (`tool_process::capture`).
        let truncated =
            answer.stdout.len() > plan.capture_bytes || answer.stderr.len() > plan.capture_bytes;
        answer.stdout.truncate(plan.capture_bytes);
        answer.stderr.truncate(plan.capture_bytes);
        Ok(Receipt {
            exit_status: answer.status,
            stdout: answer.stdout,
            stderr: answer.stderr,
            truncated,
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
