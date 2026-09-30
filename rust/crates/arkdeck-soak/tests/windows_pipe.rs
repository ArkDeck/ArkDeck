//! The Windows transport soak as an executable. The unsigned refusal runs
//! everywhere; the signed run needs the certificate this host trusts
//! (`rust/scripts/windows-dev-identity.ps1`), so it is ignored unless asked
//! for with `--ignored` and `ARKDECK_DEV_SIGNER_THUMBPRINT` set.
#![cfg(windows)]
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Root(PathBuf);
impl Root {
    fn new(label: &str) -> Self {
        let suffix: String = arkdeck_platform::random_bytes::<12>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        Self(std::env::temp_dir().join(format!("adksoak-{label}-{suffix}")))
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn soak(executable: &Path, state: &Path, pin: Option<&str>) -> std::process::Output {
    let mut command = Command::new(executable);
    command
        .args(["--state-directory"])
        .arg(state)
        .args([
            "--duration-seconds",
            "3",
            "--restart-interval-seconds",
            "1",
            "--jobs-per-cycle",
            "8",
        ])
        .env_remove(arkdeck_soak::SIGNER_VARIABLE);
    if let Some(pin) = pin {
        command.env(arkdeck_soak::SIGNER_VARIABLE, pin);
    }
    command.output().unwrap()
}

/// PowerShell 7, as `check-readonly.py` finds it: on PATH, or the App
/// Execution Alias of its Store installation.
fn pwsh() -> PathBuf {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join("pwsh.exe"))
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
                .join(r"Microsoft\WindowsApps\pwsh.exe")
        })
}

#[test]
fn an_unsigned_run_is_refused_before_any_state_is_created() {
    let root = Root::new("unsigned");
    let output = soak(Path::new(env!("CARGO_BIN_EXE_arkdeck-soak")), &root.0, None);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(arkdeck_soak::SIGNER_VARIABLE), "{stderr}");
    assert!(!root.0.exists());
    for flag in [
        "--measure-journal",
        "--seed-recovery",
        "--seed-artifact-bench",
    ] {
        let refused = Command::new(env!("CARGO_BIN_EXE_arkdeck-soak"))
            .arg(flag)
            .arg(&root.0)
            .output()
            .unwrap();
        assert!(!refused.status.success(), "{flag}");
        assert!(
            String::from_utf8_lossy(&refused.stderr).contains("G01"),
            "{flag}"
        );
    }
    assert!(!root.0.exists());
}

#[test]
#[ignore = "needs the host-trusted development signer: ARKDECK_DEV_SIGNER_THUMBPRINT"]
fn a_signed_run_drains_every_generation_within_the_growth_bounds() {
    let thumbprint = std::env::var("ARKDECK_DEV_SIGNER_THUMBPRINT")
        .expect("ARKDECK_DEV_SIGNER_THUMBPRINT names the development certificate");
    let bin = Root::new("bin");
    std::fs::create_dir(&bin.0).unwrap();
    let signed = bin.0.join("arkdeck-soak.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-soak"), &signed).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .args(["sign", "-Thumbprint", &thumbprint, "-Path"])
        .arg(&signed)
        .output()
        .unwrap();
    assert!(
        signing.status.success(),
        "{}",
        String::from_utf8_lossy(&signing.stderr)
    );
    let pin = serde_json::from_slice::<Value>(&signing.stdout).unwrap()["pin"]
        .as_str()
        .unwrap()
        .to_owned();

    let root = Root::new("signed");
    let output = soak(&signed, &root.0, Some(&pin));
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        stdout.contains("workload=windows-pipe-transport/v1"),
        "{stdout}"
    );
    let metrics: Value =
        serde_json::from_slice(&std::fs::read(root.0.join("runtime-soak-metrics.json")).unwrap())
            .unwrap();
    assert_eq!(metrics["schemaVersion"], "arkdeck-runtime-soak/v1");
    assert_eq!(metrics["phase"], "completed");
    assert_eq!(metrics["workload"], arkdeck_soak::WORKLOAD);
    assert_eq!(metrics["transportExchangesThisCycle"], 8);
    assert!(metrics["cycle"].as_u64().unwrap() >= 2, "{metrics}");
    assert_eq!(metrics["terminalJobCount"], 0, "no Job is claimed");
    assert!(metrics["residentSetGrowthBytes"].as_i64().unwrap() <= 32 * 1024 * 1024);
    assert!(metrics["openFileDescriptorGrowth"].as_i64().unwrap() <= 16);
    assert!(metrics["privateBytes"].as_u64().unwrap() > 0);

    // A second run continues its own marked state; a foreign root is refused.
    let again = soak(&signed, &root.0, Some(&pin));
    assert!(again.status.success());
    let foreign = Root::new("foreign");
    std::fs::create_dir(&foreign.0).unwrap();
    std::fs::write(foreign.0.join("unrelated"), b"retain").unwrap();
    let refused = soak(&signed, &foreign.0, Some(&pin));
    assert!(!refused.status.success());
    assert_eq!(
        std::fs::read(foreign.0.join("unrelated")).unwrap(),
        b"retain"
    );
    assert!(!foreign.0.join("runtime-soak-owner").exists());
}
