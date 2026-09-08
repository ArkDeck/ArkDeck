use arkdeck_cli::{
    CliError, Invocation, failure_envelope, parse, render, success_envelope, valid_correlation,
};
use arkdeck_client::Client;
use arkdeck_platform::{LocalEndpoint, ServerIdentity, default_user_endpoint, random_bytes};
use serde_json::Value;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;

fn correlation() -> io::Result<String> {
    Ok(format!(
        "ctl-{}",
        random_bytes::<16>()?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    ))
}

fn execute(invocation: &Invocation, id: &str) -> Result<Value, CliError> {
    let endpoint = match invocation
        .socket
        .clone()
        .map(Into::into)
        .or_else(|| std::env::var_os("ARKDECK_ENDPOINT"))
    {
        Some(path) => LocalEndpoint::new(path),
        None => default_user_endpoint().map_err(|_| {
            CliError::new(
                "runtimeUnavailable",
                "the private local Runtime endpoint is unavailable",
            )
        })?,
    };
    let daemon = std::env::var_os("ARKDECK_DAEMON_PATH")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe().ok().map(|path| {
                path.with_file_name(if cfg!(windows) {
                    "arkdeck-agentd.exe"
                } else {
                    "arkdeck-agentd"
                })
            })
        })
        .ok_or_else(|| {
            CliError::new(
                "runtimeUnavailable",
                "the installed daemon identity is unavailable",
            )
        })?;
    let identity = ServerIdentity {
        executable: daemon,
        authenticode_sha256: std::env::var("ARKDECK_DAEMON_SIGNER_SHA256").ok(),
        package_family: std::env::var("ARKDECK_DAEMON_PACKAGE_FAMILY").ok(),
    };
    let mut client = Client::connect(&endpoint, &identity, Duration::from_secs(20))
        .map_err(|error| CliError::from_client(error, invocation.method))?;
    let result = client
        .request(id, invocation.method, invocation.params.clone())
        .map_err(|error| CliError::from_client(error, invocation.method))?;
    if invocation.command == "doctor" {
        if result["schemaVersion"] != "arkdeck.doctor-report/1" || !result["ready"].is_boolean() {
            return Err(CliError::new(
                "recordUnreadable",
                "Runtime returned a doctor report without its versioned readiness contract",
            ));
        }
        if invocation.require_healthy && result["ready"] == false {
            let mut error = CliError::new(
                "healthRequirementFailed",
                "doctor completed and found one or more blocking health findings",
            );
            error.details.insert("report".into(), result);
            return Err(error);
        }
    }
    Ok(result)
}

fn write_document(value: &Value) -> io::Result<()> {
    let bytes = render(value).map_err(io::Error::other)?;
    io::stdout().lock().write_all(&bytes)
}

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let fallback_id = correlation().unwrap_or_else(|_| "ctl-unavailable".into());
    // Invalid ids never reach output. An invalid/duplicate output selector does
    // not claim machine mode, matching the current argv bootstrap contract.
    let output_values: Vec<_> = args
        .windows(2)
        .filter(|p| p[0] == "--output")
        .map(|p| p[1].as_str())
        .collect();
    let machine = output_values == ["json"];
    let id_values: Vec<_> = args
        .windows(2)
        .filter(|p| p[0] == "--control-request-id")
        .map(|p| p[1].as_str())
        .collect();
    let parse_id = if id_values.len() == 1 && valid_correlation(id_values[0]) {
        id_values[0]
    } else {
        &fallback_id
    };
    let invocation = match parse(&args) {
        Ok(invocation) => invocation,
        Err(error) => {
            if machine {
                if write_document(&failure_envelope("registry.parse", &error, parse_id, false))
                    .is_err()
                {
                    return 74.into();
                }
            } else {
                eprintln!("arkdeck: {}", error.message);
            }
            return error.exit_code().into();
        }
    };
    if invocation.help {
        println!(
            "ArkDeck read-only commands:\n  doctor [--deep] [--require-healthy]\n  operation list\n  device candidates\n\nOptions: --output human|json, --control-request-id <id>\nA private local Runtime must be running. Windows requires the installed daemon identity."
        );
        return 0.into();
    }
    let id = invocation
        .control_request_id
        .as_deref()
        .unwrap_or(&fallback_id);
    match execute(&invocation, id) {
        Ok(result) => {
            if invocation.json {
                if write_document(&success_envelope(invocation.command, result, id)).is_err() {
                    return 74.into();
                }
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&result).expect("validated result")
                );
            }
            0.into()
        }
        Err(error) => {
            if invocation.json {
                if write_document(&failure_envelope(invocation.command, &error, id, true)).is_err()
                {
                    return 74.into();
                }
            } else {
                eprintln!("arkdeck: {}", error.message);
            }
            error.exit_code().into()
        }
    }
}
