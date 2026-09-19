use arkdeck_cli::{
    CliError, Invocation, failure_envelope, parse, render, success_envelope, valid_correlation,
};
use arkdeck_client::Client;
use arkdeck_platform::{LocalEndpoint, ServerIdentity, default_user_endpoint, random_bytes};
use serde_json::Value;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

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
    arkdeck_cli::validate_read_only_request(invocation)?;
    arkdeck_cli::validate_bootstrap_request(invocation)?;
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
    if matches!(invocation.command, "job.plan" | "job.submit") {
        // The request document is read before any connection is made.
        let submit = invocation.command == "job.submit";
        let params = if submit {
            arkdeck_cli::job_submit_params(invocation)?
        } else {
            arkdeck_cli::job_plan_params(invocation)?
        };
        if submit && !invocation.json && arkdeck_cli::generates_identity(invocation) {
            eprintln!(
                "note: no --idempotency-key was given, so this submit generated one and cannot be retried safely; pass one to make a repeat return the same job"
            );
        }
        // Nothing is sent before the connection is made, so a connect
        // failure maps as it does for a read.
        let mut client = Client::connect_bounded(
            &endpoint,
            &identity,
            Duration::from_millis(invocation.timeout_ms.unwrap_or(30_000)),
        )
        .map_err(|error| CliError::from_client(error, "job.plan"))?;
        let result = client
            .request(id, invocation.method, Some(params))
            .map_err(|error| CliError::from_client(error, invocation.method))?;
        if submit {
            arkdeck_cli::validate_acceptance(&result)?;
        } else {
            arkdeck_cli::validate_plan(&result)?;
        }
        return Ok(result);
    }
    if matches!(
        invocation.command,
        "agent.run" | "agent.resume" | "human-action.resume"
    ) {
        return run_agent(invocation, id, &endpoint, &identity);
    }
    if matches!(
        invocation.command,
        "agent.status"
            | "agent.list"
            | "agent.abandon"
            | "artifact.list"
            | "human-action.list"
            | "human-action.show"
    ) {
        if matches!(invocation.command, "agent.status" | "agent.abandon") {
            arkdeck_cli::require_execution_identity(
                invocation
                    .params
                    .as_ref()
                    .expect("parsed execution parameters"),
            )?;
        }
        let mut client = Client::connect_bounded(
            &endpoint,
            &identity,
            Duration::from_millis(invocation.timeout_ms.unwrap_or(30_000)),
        )
        .map_err(|error| CliError::from_client(error, invocation.method))?;
        let result = client
            .request(id, invocation.method, invocation.params.clone())
            .map_err(|error| CliError::from_client(error, invocation.method))?;
        match invocation.command {
            "agent.status" | "agent.abandon" => {
                arkdeck_cli::validate_execution(&result)?;
            }
            "artifact.list" => {
                let params = invocation
                    .params
                    .as_ref()
                    .expect("parsed Artifact list parameters");
                arkdeck_cli::validate_artifact_page(
                    &result,
                    &params["owner"],
                    params["pageSize"].as_u64().unwrap_or(100),
                )?;
            }
            // Swift passes execution pages and human-action resources on as the Runtime answers them.
            _ => (),
        }
        return Ok(result);
    }
    if invocation.command == "job.run" {
        // Nothing is sent before the connection is made, so a connect failure
        // maps as it does for a read; a reply lost after the request went out
        // leaves the run's outcome unknown.
        let mut client = Client::connect_bounded(
            &endpoint,
            &identity,
            Duration::from_millis(invocation.timeout_ms.unwrap_or(30_000)),
        )
        .map_err(|error| CliError::from_client(error, "job.status"))?;
        let result = client
            .request(id, "job.run", invocation.params.clone())
            .map_err(|error| CliError::from_client(error, "job.run"))?;
        arkdeck_cli::validate_read_only_response(invocation, &result)?;
        return Ok(result);
    }
    if invocation.command == "job.cancel" {
        // As for a run: a connect failure proves nothing was sent, and a reply
        // lost after the request went out leaves the cancellation unknown.
        let mut client = Client::connect(&endpoint, &identity, Duration::from_secs(20))
            .map_err(|error| CliError::from_client(error, "job.status"))?;
        let result = client
            .request(id, "job.cancel", invocation.params.clone())
            .map_err(|error| CliError::from_client(error, "job.cancel"))?;
        arkdeck_cli::validate_cancellation(&result)?;
        return Ok(result);
    }
    if invocation.command.starts_with("artifact.import.") {
        return arkdeck_cli::execute_import(invocation, |method, params, remaining| {
            let mut client =
                Client::connect_bounded(&endpoint, &identity, Duration::from_millis(remaining))
                    .map_err(|error| CliError::from_client(error, "artifact.import.inspect"))?;
            client
                .request(id, method, Some(params))
                .map_err(|error| CliError::from_client(error, method))
        });
    }
    if matches!(
        invocation.command,
        "artifact.inspect" | "artifact.read" | "artifact.export"
    ) {
        let mut client = Client::connect_bounded(
            &endpoint,
            &identity,
            Duration::from_millis(invocation.timeout_ms.unwrap_or(3_600_000)),
        )
        .map_err(|error| CliError::from_client(error, "artifact.inspect"))?;
        let params = invocation
            .params
            .as_ref()
            .expect("parsed Artifact parameters");
        let inspect_params = serde_json::Map::from_iter([
            ("owner".into(), params["owner"].clone()),
            ("artifactId".into(), params["artifactId"].clone()),
        ]);
        let metadata = client
            .request(id, "artifact.inspect", Some(inspect_params))
            .map_err(|error| CliError::from_client(error, "artifact.inspect"))?;
        arkdeck_cli::validate_artifact_metadata(params, &metadata)?;
        if invocation.command == "artifact.inspect" {
            return Ok(metadata);
        }
        if invocation.command == "artifact.export" {
            let params = arkdeck_cli::artifact_export_params(invocation)?;
            let result = client
                .request(id, "artifact.export", Some(params))
                .map_err(|error| CliError::from_client(error, "artifact.export"))?;
            arkdeck_cli::validate_artifact_export(invocation, &metadata, &result)?;
            return Ok(result);
        }
        let result = client
            .request(id, "artifact.read", invocation.params.clone())
            .map_err(|error| CliError::from_client(error, "artifact.read"))?;
        arkdeck_cli::validate_artifact_read(invocation, &metadata, &result)?;
        return Ok(result);
    }
    if matches!(
        invocation.command,
        "runtime.hdc.impact-preview"
            | "runtime.hdc.restart"
            | "runtime.tool.select"
            | "control-action.list"
            | "control-action.show"
            | "control-action.reconcile"
    ) {
        // Swift's handler checks the intent, the preview tuple or the control
        // action's identity first.
        // Nothing is sent before the connection is made, so a connect
        // failure maps as it does for a read.
        let params = arkdeck_cli::hdc_control_action_params(invocation)?;
        let mut client = Client::connect_bounded(
            &endpoint,
            &identity,
            Duration::from_millis(invocation.timeout_ms.unwrap_or(30_000)),
        )
        .map_err(|error| CliError::from_client(error, "runtime.hdc.status"))?;
        return client
            .request(id, invocation.method, Some(params))
            .map_err(|error| CliError::from_client(error, invocation.method));
    }
    let request = if let Some(timeout_ms) = invocation.timeout_ms {
        Client::connect_bounded(&endpoint, &identity, Duration::from_millis(timeout_ms))
            .and_then(|mut client| client.request(id, invocation.method, invocation.params.clone()))
    } else {
        Client::connect(&endpoint, &identity, Duration::from_secs(20))
            .and_then(|mut client| client.request(id, invocation.method, invocation.params.clone()))
    };
    let result = request.map_err(|error| {
        if matches!(
            invocation.command,
            "runtime.tool.register" | "runtime.bundle.register"
        ) && matches!(
            error,
            arkdeck_client::ClientError::Contract(_)
                | arkdeck_client::ClientError::ConnectionUnusable
        ) {
            CliError::new(
                "outcomeUnknown",
                "Runtime mutation response is unconfirmed; no request was replayed",
            )
        } else {
            CliError::from_client(error, invocation.method)
        }
    })?;
    arkdeck_cli::validate_workspace_project_response(invocation, &result)?;
    arkdeck_cli::validate_target_response(invocation, &result)?;
    arkdeck_cli::validate_session_response(invocation, &result)?;
    arkdeck_cli::validate_trace_cache_response(invocation, &result)?;
    arkdeck_cli::validate_bootstrap_response(invocation, &result)?;
    let result = arkdeck_cli::project_read_only_response(invocation, result)?;
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

fn stopped() -> CliError {
    CliError::new(
        "clientTimeout",
        "client stopped waiting; the Runtime execution and Job were not cancelled",
    )
}

/// Swift `runRuntimeExecution` for run and physical resume: parameters are built and
/// checked before any connection, then the execution is read with
/// `agent.status`, backing off from 100 ms to 2 s, until it settles or
/// `--timeout` ends the client's wait (never the execution or its Job).
fn run_agent(
    invocation: &Invocation,
    id: &str,
    endpoint: &LocalEndpoint,
    identity: &ServerIdentity,
) -> Result<Value, CliError> {
    let params = if invocation.command == "agent.run" {
        arkdeck_cli::execution_intent(invocation)?
    } else {
        arkdeck_cli::resume_params(invocation)?
    };
    let deadline = invocation
        .timeout_ms
        .map(|milliseconds| Instant::now() + Duration::from_millis(milliseconds));
    // Each request waits for what is left of the client's deadline, or 30 s.
    let remaining = || match deadline {
        None => Ok(Duration::from_secs(30)),
        Some(deadline) => deadline
            .checked_duration_since(Instant::now())
            .filter(|left| !left.is_zero())
            .ok_or_else(stopped),
    };
    let request = |method: &str, body: serde_json::Map<String, Value>| {
        let wait = remaining()?;
        // Nothing is sent before the connection is made, so a connect
        // failure maps as it does for a read.
        let mut client = Client::connect_bounded(endpoint, identity, wait)
            .map_err(|error| CliError::from_client(error, "agent.status"))?;
        client
            .request(id, method, Some(body))
            .map_err(|error| CliError::from_client(error, method))
    };
    let mut execution = params.get("executionId").cloned().unwrap_or(Value::Null);
    let attach = |mut error: CliError, execution: &Value| {
        if execution.is_string() {
            error
                .details
                .insert("executionId".into(), execution.clone());
        }
        error
    };
    let mut answer =
        request(invocation.method, params).map_err(|error| attach(error, &execution))?;
    if invocation.command == "human-action.resume"
        && (answer["schemaVersion"] == "arkdeck.impact-approval-challenge/1"
            || answer["owner"]["kind"] == "controlAction")
    {
        let mut error = CliError::new(
            "humanActionRequired",
            "impact approval requires its supported foreground interactive console",
        );
        error.details.insert("humanAction".into(), answer);
        return Err(error);
    }
    let mut interval = 100;
    loop {
        let fields =
            arkdeck_cli::validate_execution(&answer).map_err(|error| attach(error, &execution))?;
        execution = fields["executionId"].clone();
        match arkdeck_cli::settle_execution(&fields).map_err(|error| attach(error, &execution))? {
            arkdeck_cli::Settlement::Settled(result) => return Ok(result),
            arkdeck_cli::Settlement::Pending => (),
        }
        let left = remaining().map_err(|error| attach(error, &execution))?;
        std::thread::sleep(Duration::from_millis(interval).min(left));
        remaining().map_err(|error| attach(error, &execution))?;
        let body = serde_json::Map::from_iter([("executionId".to_owned(), execution.clone())]);
        answer = request("agent.status", body).map_err(|error| attach(error, &execution))?;
        interval = (interval * 2).min(2000);
    }
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
            "ArkDeck commands:\n  doctor [--deep] [--require-healthy]\n  operation list\n  operation describe|example --operation <reference>\n  job status|show|evidence|result --job <id> [--timeout <duration>]\n  job timeline --job <id> [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  job events --job <id> [--page-size <n>] [--after-cursor <cursor>] [--timeout <duration>]\n  job plan --request-file <path> | --target <id> --operation <reference> [--inputs-file <path>] [--expected-binding-revision <n>] [--request-id <id>] [--idempotency-key <key>] [--timeout <duration>]\n  job submit --request-file <path> | --target <id> --operation <reference> [--inputs-file <path>] [--expected-binding-revision <n>] [--request-id <id>] [--idempotency-key <key>] [--timeout <duration>]\n  job run --job <id> [--timeout <duration>]\n  job cancel --job <id>\n  capability list\n  capability inspect --capability <id>\n  job list [--page-size <n>] [--cursor <cursor>] [--order <order>] [--include-current] [--include-timeline] [--state <state>] [--operation <reference>] [--target <id>] [--thread <id>] [--timeout <duration>]\n  artifact import hap|native-library|workspace-patch|flash-bundle --import-request-id <id> --target <id> --file <path> [--timeout <duration>]\n  artifact import list [--target <id>] [--state <state>] [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  artifact import abort --import-request-id <id> --expected-generation <n> [--timeout <duration>]\n  artifact import release --import <id> --generation <n> [--timeout <duration>]\n  artifact import inspect --import-request-id <id>|--import <id> [--timeout <duration>]\n  artifact inspect --job <id>|--import <id> --artifact <id> [--timeout <duration>]\n  artifact read --job <id>|--import <id> --artifact <id> [--offset <n>] [--max-bytes <n>] [--allow-sensitive] [--raw] [--timeout <duration>]\n  artifact export --job <id>|--import <id> --artifact <id> --destination <directory> [--allow-sensitive] [--overwrite] [--timeout <duration>]\n  artifact quota\n  artifact list --job <id>|--import <id> [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  agent run --operation <reference> [--target <id>] [--expected-binding-revision <n>] [--inputs-file <path>] [--request-id <id>] [--idempotency-key <key>] [--capability <id>] [--reviewed-plan-digest <sha256>] | --request-file <path>, [--execution-id <id>] [--maximum-wait <duration>] [--timeout <duration>]\n  agent status --execution-id <id> [--timeout <duration>]\n  agent list [--state <state>] [--operation <reference>] [--target <id>] [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  agent abandon --execution-id <id> --expected-generation <n> [--timeout <duration>]\n  human-action list [--owner-kind agentExecution|controlAction --owner <id>] [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  human-action show --human-action <id> [--timeout <duration>]\n  agent resume --resume-reference <ref>|--resume-token <ref> [--selection <choice>|--selection-file <path>] [--timeout <duration>]\n  human-action resume --human-action <id> --resume-reference <ref> [--selection <choice>|--selection-file <path>] [--timeout <duration>]\n  device candidates\n  target adopt --candidate <key> --observation <id> --observation-generation <n> [--timeout <duration>]\n  target list\n  target show --target <id> [--timeout <duration>]\n  target availability --target <id> [--timeout <duration>]\n  target display-name set|clear --target <id> --expected-generation <n> [--name <text>]\n  device display-name set|clear --candidate <key> --observation <id> --observation-generation <n> [--name <text>]\n  trace cache status|purge\n  history filter list\n  history filter save --expected-generation <n> [--search <text>] [--status <status>] [--mode <mode>] [--session <id>] [--target <id>] [--time <range>] [--activity <activity>]\n  history filter delete --expected-generation <n>\n  runtime tool register --kind deveco --root <absolute-path>\n  runtime tool register --kind hdc --file <absolute-path>\n  runtime tool list [--page-size <n>] [--cursor <cursor>]\n  runtime tool remove --tool <reference> --expected-generation <n>\n  runtime tool inspect --tool <reference>\n  runtime tool select --tool <reference> --expected-active-generation <n> --action-request-id <id> [--timeout <duration>]\n  runtime bundle register --kind daemon-bundle --file <absolute-path>\n  runtime bundle inspect --bundle <reference>\n  runtime bundle list [--page-size <n>] [--cursor <cursor>]\n  runtime bundle remove --bundle <reference> --expected-generation <n>\n  runtime hdc status\n  runtime hdc impact-preview --action restart --server-endpoint-ref <ref> --expected-server-generation <n> --action-request-id <id> [--timeout <duration>]\n  runtime hdc restart --control-action <id> --preview-id <id> --preview-digest <sha256> [--timeout <duration>]\n  control-action list [--kind hdcLifecycle] [--state <state>] [--page-size <n>] [--cursor <cursor>] [--timeout <duration>]\n  control-action show|reconcile --control-action <id> [--timeout <duration>]\n  runtime storage status\n  runtime storage policy --expected-generation <n> --total-quota-bytes <bytes> --safety-margin-bytes <bytes> --retention-days <days>\n  runtime storage root --expected-generation <n> (--root <path> | --default)\n  session list [--page-size <n>] [--cursor <cursor>]\n  session show --session <id>\n  session pin|unpin --session <id> --expected-generation <n>\n  session cleanup preview\n  session cleanup apply --preview-id <uuid> --preview-digest <sha256>\n  session export preview --session <id> --destination <path> [--allow-sensitive]\n  session export apply --preview-id <uuid> --preview-digest <sha256>\n  workspace project register --registration-request-id <id> --kind arkdeck|openharmony --root <absolute-path>\n  workspace project list\n  workspace project show --project <ref>\n  workspace project update --project <ref> --expected-generation <n> --kind arkdeck|openharmony --root <absolute-path>\n  workspace project remove --project <ref> --expected-generation <n>\n  workspace preset list --project <ref> [--kind build|test|signing|symbol]\n  workspace preset show --project <ref> --preset <ref>\n  workspace preset register --registration-request-id <id> --project <ref> <definition>\n  workspace preset update --mutation-request-id <id> --project <ref> --preset <ref> --expected-generation <n> <definition>\n  workspace preset remove --mutation-request-id <id> --project <ref> --preset <ref> --expected-generation <n>\n    <definition>: --kind build|test|signing|symbol --template <ref> --timeout-seconds <1-3600> [--toolchain <ref> --toolchain-generation <n>] [--credential <ref>] [--module <name> --product <name> --build-mode <mode>] [--relative-source-map <path>]\n\nOptions: --output human|json, --control-request-id <id>\nA private local Runtime must be running. Windows requires the installed daemon identity."
        );
        return 0.into();
    }
    let id = invocation
        .control_request_id
        .as_deref()
        .unwrap_or(&fallback_id);
    match execute(&invocation, id) {
        Ok(result) => {
            // Evidence and a result are successful queries even when their
            // verification or outcome needs attention: only the validated
            // Runtime answer determines the process exit code. A run's terminal
            // state and a result's attention are reported after it is emitted.
            let attention: Option<(u8, String)> = match invocation.command {
                "job.run" => {
                    arkdeck_cli::run_exit(&result).map(|(code, reason)| (code, reason.to_owned()))
                }
                "job.result" => Some(arkdeck_cli::result_exit(&result))
                    .filter(|code| *code != 0)
                    .map(|code| {
                        (
                            code,
                            "Job outcome or evidence requires attention".to_owned(),
                        )
                    }),
                "agent.run" | "agent.resume" | "human-action.resume" => {
                    arkdeck_cli::agent_exit(&result)
                }
                _ => None,
            };
            let exit: u8 = if invocation.command == "job.evidence" {
                arkdeck_cli::evidence_exit(&result)
            } else {
                attention.as_ref().map_or(0, |(code, _)| *code)
            };
            if invocation.raw {
                let bytes = arkdeck_cli::artifact_bytes(&result).expect("validated Artifact bytes");
                if io::stdout().lock().write_all(&bytes).is_err() {
                    return 74.into();
                }
            } else if invocation.json {
                if write_document(&success_envelope(invocation.command, result, id)).is_err() {
                    return 74.into();
                }
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&result).expect("validated result")
                );
            }
            if let Some((_, reason)) = attention {
                eprintln!("arkdeck: {reason}");
            }
            exit.into()
        }
        Err(error) => {
            if invocation.json {
                if write_document(&failure_envelope(invocation.command, &error, id, true)).is_err()
                {
                    return 74.into();
                }
            } else {
                if let Some(progress) = arkdeck_cli::human_action_progress(&error) {
                    eprintln!("{progress}");
                }
                eprintln!("arkdeck: {}", error.message);
            }
            error.exit_code().into()
        }
    }
}
