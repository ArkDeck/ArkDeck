#![cfg(target_os = "macos")]

use arkdeck_platform::{ProcessLimits, VerifiedTool, random_bytes};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn verified(path: &str) -> VerifiedTool {
    let digest = format!("{:x}", Sha256::digest(fs::read(path).unwrap()));
    VerifiedTool::open(path, &digest).unwrap()
}

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-tool-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn copy_tool(&self) -> PathBuf {
        let path = self.0.join("echo");
        fs::copy("/bin/echo", &path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn argument_array_preserves_metacharacters_without_a_shell() {
    let output = verified("/bin/echo")
        .run_read_only(
            &[OsString::from("$HOME; $(id) `whoami` & | > ' \" \\")],
            ProcessLimits::default(),
        )
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"$HOME; $(id) `whoami` & | > ' \" \\\n");
    assert!(output.stderr.is_empty());
}

#[test]
fn hash_path_permissions_and_symlink_refusals_precede_spawn() {
    assert!(VerifiedTool::open("/bin/echo", &"0".repeat(64)).is_err());
    assert!(VerifiedTool::open("bin/echo", &"0".repeat(64)).is_err());
    let directory = Directory::new();
    let path = directory.copy_tool();
    let hash = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
    let link = directory.0.join("symlink");
    symlink(&path, &link).unwrap();
    assert!(VerifiedTool::open(&link, &hash).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o722)).unwrap();
    assert!(VerifiedTool::open(&path, &hash).is_err());
}

#[test]
fn replacing_or_modifying_retained_tool_fails_closed() {
    let directory = Directory::new();
    let path = directory.copy_tool();
    let hash = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
    let tool = VerifiedTool::open(&path, &hash).unwrap();
    fs::rename(&path, directory.0.join("previous")).unwrap();
    directory.copy_tool();
    assert!(tool.run_read_only(&[], ProcessLimits::default()).is_err());
    let tool = VerifiedTool::open(&path, &hash).unwrap();
    fs::write(&path, b"changed executable").unwrap();
    assert!(tool.run_read_only(&[], ProcessLimits::default()).is_err());
}

#[test]
fn output_overflow_kills_and_reaps_the_child() {
    let started = Instant::now();
    let error = verified("/usr/bin/yes")
        .run_read_only(
            &[],
            ProcessLimits {
                timeout: Duration::from_secs(2),
                max_output_bytes: 4096,
            },
        )
        .unwrap_err();
    assert_eq!(error.kind(), ErrorKind::FileTooLarge);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn timeout_kills_and_reaps_the_child() {
    let started = Instant::now();
    let error = verified("/bin/sleep")
        .run_read_only(
            &["10".into()],
            ProcessLimits {
                timeout: Duration::from_millis(80),
                max_output_bytes: 4096,
            },
        )
        .unwrap_err();
    assert_eq!(error.kind(), ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn child_environment_is_clean_and_only_accepts_the_typed_port_override() {
    let tool = verified("/usr/bin/printenv");
    let default = tool
        .run_read_only(&["OHOS_HDC_SERVER_PORT".into()], ProcessLimits::default())
        .unwrap();
    assert!(!default.status.success());
    let output = tool
        .run_read_only_with_environment(
            &["OHOS_HDC_SERVER_PORT".into()],
            &[("OHOS_HDC_SERVER_PORT".into(), "8710".into())],
            ProcessLimits::default(),
        )
        .unwrap();
    assert_eq!(output.stdout, b"8710\n");
    for environment in [
        vec![("PATH".into(), "/tmp".into())],
        vec![("OHOS_HDC_SERVER_PORT".into(), "0".into())],
        vec![("OHOS_HDC_SERVER_PORT".into(), "8710;id".into())],
    ] {
        assert!(
            tool.run_read_only_with_environment(&[], &environment, ProcessLimits::default())
                .is_err()
        );
    }
}
