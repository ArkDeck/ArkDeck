//! SPK-10 host probe (TASK-XPA-015): Hvigor through a registered DevEco
//! toolchain reference, not a bare path. The Rust DevEco registry owner
//! registers an installed DevEco Studio into a scratch registry root; the
//! record's pinned `node` and `hvigor` children then launch
//! `node <hvigorw.js> --version` through the verified tool runner — Node by
//! its retained inode and SHA-256, the script held open and re-hashed, the
//! clean base environment plus `DEVECO_SDK_HOME`, as Swift's daemon composes
//! a registered Hvigor preset. Run by hand on the reference host:
//!
//! ```text
//! spk10_hvigor <scratch registry root> <DevEco Studio .app/Contents> [<project>]
//! ```
//!
//! With a project, it also runs Swift's registered build preset command there:
//! `assembleHap --mode module -p module=entry@default -p product=default
//! -p buildMode=debug --analyze=normal --parallel --incremental --no-daemon`.
#[cfg(target_os = "macos")]
fn main() {
    use arkdeck_hoststore::DevEcoRegistryStore;
    use arkdeck_platform::{ToolLimits, ToolRequest, VerifiedSource, VerifiedTool};
    use serde_json::{Value, json};
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    let fail = |message: String| -> ! {
        eprintln!("spk10_hvigor: {message}");
        std::process::exit(1);
    };
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if !(2..=3).contains(&arguments.len()) {
        fail(
            "usage: spk10_hvigor <scratch registry root> <DevEco .app/Contents> [<project>]".into(),
        );
    }
    let project = arguments.get(2).map(PathBuf::from);
    let registry = PathBuf::from(&arguments[0]);
    std::fs::create_dir_all(&registry).unwrap_or_else(|error| fail(error.to_string()));
    std::fs::set_permissions(&registry, std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|error| fail(error.to_string()));
    let registry = registry
        .canonicalize()
        .unwrap_or_else(|error| fail(error.to_string()));
    let store = DevEcoRegistryStore::open_existing(&registry)
        .unwrap_or_else(|error| fail(error.to_string()));
    let registered = store
        .register(Path::new(&arguments[1]), "2026-09-19T00:00:00Z")
        .unwrap_or_else(|error| fail(format!("{}: {}", error.code, error.message)));

    // What a resolution reads: the record's root and its pinned children. The
    // scratch registry holds this one available record.
    let index: Value = serde_json::from_slice(
        &std::fs::read(registry.join("deveco-toolchains.json"))
            .unwrap_or_else(|error| fail(error.to_string())),
    )
    .unwrap_or_else(|error| fail(error.to_string()));
    let records = index["records"].as_array().cloned().unwrap_or_default();
    if records.len() != 1 || records[0]["state"] != "available" {
        fail("the scratch registry must hold exactly the one registered record".into());
    }
    let record = &records[0];
    let reference = record["reference"].as_str().unwrap_or_default().to_owned();
    let root = PathBuf::from(record["root"]["path"].as_str().unwrap_or_default());
    let child = |role: &str| {
        record["children"]
            .as_array()
            .and_then(|children| children.iter().find(|child| child["role"] == role))
            .unwrap_or_else(|| fail(format!("no {role} child")))
            .clone()
    };
    let (node, hvigor) = (child("node"), child("hvigor"));
    let node_tool = VerifiedTool::open(
        root.join(node["relativePath"].as_str().unwrap_or_default()),
        node["sha256"].as_str().unwrap_or_default(),
    )
    .unwrap_or_else(|error| fail(format!("node: {error}")));
    let script = root.join(hvigor["relativePath"].as_str().unwrap_or_default());
    let _pinned_script = VerifiedSource::open(
        &script,
        hvigor["sha256"].as_str().unwrap_or_default(),
        hvigor["byteCount"].as_u64().unwrap_or_default(),
    )
    .unwrap_or_else(|error| fail(format!("hvigor: {error}")));
    // Node resolves the script's own modules beside it, so the script is
    // named by its canonical path while its descriptor stays open.
    let arguments = [script.clone().into_os_string(), OsString::from("--version")];
    // Swift's child base inherits PATH, HOME, TMPDIR and LANG from the daemon;
    // the Rust runner's base is fixed and has no HOME or TMPDIR, without which
    // Hvigor cannot create its state directory. They are named here as the
    // Swift base would supply them (`with-home` mode), or left out.
    let mut environment = vec![(
        OsString::from("DEVECO_SDK_HOME"),
        root.join("sdk").into_os_string(),
    )];
    if std::env::var_os("SPK10_WITH_HOME").is_some() {
        environment.push((
            OsString::from("HOME"),
            OsString::from(arkdeck_platform::runtime_home().unwrap_or_default()),
        ));
        if let Some(temporary) = std::env::var_os("TMPDIR") {
            environment.push((OsString::from("TMPDIR"), temporary));
        }
    }
    let working_directory = registry.join("work");
    std::fs::create_dir_all(&working_directory).unwrap_or_else(|error| fail(error.to_string()));
    let execution = node_tool
        .run_tool(
            &ToolRequest {
                arguments: &arguments,
                environment: &environment,
                // Swift runs a Hvigor preset in the project root; Hvigor
                // creates its state relative to it and fails in `/`.
                working_directory: Some(&working_directory),
                limits: ToolLimits {
                    timeout: Duration::from_secs(60),
                    capture_bytes: 64 * 1024,
                },
            },
            &|| false,
        )
        .unwrap_or_else(|error| fail(format!("{error:?}")));
    let build = project.map(|project| {
        let project = project.canonicalize().unwrap_or_else(|error| fail(error.to_string()));
        let mut build_arguments = vec![script.clone().into_os_string(), OsString::from("assembleHap")];
        for argument in [
            "--mode", "module", "-p", "module=entry@default", "-p", "product=default",
            "-p", "buildMode=debug", "--analyze=normal", "--parallel", "--incremental", "--no-daemon",
        ] {
            build_arguments.push(OsString::from(argument));
        }
        let execution = node_tool
            .run_tool(
                &ToolRequest {
                    arguments: &build_arguments,
                    environment: &environment,
                    working_directory: Some(&project),
                    limits: ToolLimits {
                        timeout: Duration::from_secs(1_800),
                        capture_bytes: 1024 * 1024,
                    },
                },
                &|| false,
            )
            .unwrap_or_else(|error| fail(format!("{error:?}")));
        let product = project.join("entry/build/default/outputs/default/entry-default-unsigned.hap");
        let product = std::fs::read(&product).ok().map(|bytes| {
            use sha2::{Digest, Sha256};
            json!({
                "byteCount": bytes.len(),
                "sha256": Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect::<String>(),
            })
        });
        let tail = |bytes: &[u8]| {
            let text = String::from_utf8_lossy(bytes);
            let lines: Vec<&str> = text.lines().collect();
            lines[lines.len().saturating_sub(12)..].join("\n")
        };
        json!({
            "termination": format!("{:?}", execution.termination),
            "seconds": execution.duration.as_secs_f64(),
            "unsignedHap": product,
            "stdoutTail": tail(&execution.stdout),
            "stderrTail": tail(&execution.stderr),
        })
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "build": build,
            "reference": reference,
            "registration": registered,
            "nodeSha256": node["sha256"],
            "hvigorSha256": hvigor["sha256"],
            "environmentKeys": environment.iter().map(|(key, _)| key.to_string_lossy().into_owned()).collect::<Vec<_>>(),
            "termination": format!("{:?}", execution.termination),
            "stdout": String::from_utf8_lossy(&execution.stdout).trim(),
            "stderr": String::from_utf8_lossy(&execution.stderr).trim(),
            "seconds": execution.duration.as_secs_f64(),
        }))
        .unwrap()
    );
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("spk10_hvigor runs on macOS only");
    std::process::exit(2);
}
