//! The PTY prompt/secret exchange (SPK-6 phase 4, TASK-XPA-016) driven by
//! shell scripts standing in for the OpenHarmony signer: exact prompts
//! answered in order over a terminal with echo off, the secret never in argv,
//! environment or result, and every deviation from the protocol closing the
//! exchange. Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{
    PtyError, PtyFailureCategory, PtyInteraction, PtyRequest, ToolTermination, VerifiedTool,
};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-pty-{name}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path.canonicalize().unwrap())
    }
    fn signer(&self, body: &str) -> VerifiedTool {
        let path = self.0.join("signer");
        let bytes = format!("#!/bin/sh\n{body}\n");
        std::fs::write(&path, &bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        VerifiedTool::open(path, &format!("{:x}", Sha256::digest(bytes.as_bytes()))).unwrap()
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn interaction(prompt: &str, secret: &str) -> PtyInteraction {
    PtyInteraction {
        expected_prompt: prompt.as_bytes().to_vec(),
        secret: secret.as_bytes().to_vec(),
    }
}

fn request<'a>(arguments: &'a [OsString], seconds: u64) -> PtyRequest<'a> {
    PtyRequest {
        arguments,
        environment: &[],
        working_directory: None,
        timeout: Duration::from_secs(seconds),
    }
}

const KEYSTORE: &str = "Enter keystore password:";
const KEY: &str = "Enter key password:";

#[test]
fn exact_prompts_are_answered_in_order_and_the_secret_never_comes_back() {
    let scratch = Scratch::new("happy");
    let signer = scratch.signer(&format!(
        "printf '{KEYSTORE} '; read -r a; printf '{KEY} '; read -r b; if [ \"$a\" = one ] && [ \"$b\" = two ]; then printf 'signed\\n'; exit 0; fi; printf 'Incorrect keystore password\\n'; exit 1"
    ));
    let arguments: Vec<OsString> = Vec::new();
    let execution = signer
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "one"), interaction(KEY, "two")],
            4096,
            &|| false,
        )
        .unwrap();
    assert_eq!(execution.termination, ToolTermination::Exited(0));
    assert_eq!(execution.completed_interactions, 2);
    assert_eq!(execution.failure_category, PtyFailureCategory::None);
    assert!(execution.observed_output_byte_count > 0);
    let wrong = signer
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "one"), interaction(KEY, "wrong")],
            4096,
            &|| false,
        )
        .unwrap();
    assert_eq!(wrong.termination, ToolTermination::Exited(1));
    assert_eq!(wrong.completed_interactions, 2);
    assert_eq!(
        wrong.failure_category,
        PtyFailureCategory::KeystorePasswordRejected
    );
}

#[test]
fn a_secret_echoed_back_ends_the_exchange() {
    let scratch = Scratch::new("echo");
    let signer = scratch.signer(&format!(
        "printf '{KEYSTORE} '; read -r a; printf 'you said %s\\n' \"$a\"; exit 0"
    ));
    let arguments: Vec<OsString> = Vec::new();
    let error = signer
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "s3cret")],
            4096,
            &|| false,
        )
        .unwrap_err();
    assert!(matches!(error, PtyError::SecretEchoDetected), "{error:?}");
}

#[test]
fn a_repeated_or_out_of_order_prompt_is_a_protocol_violation() {
    let scratch = Scratch::new("protocol");
    let arguments: Vec<OsString> = Vec::new();
    let twice = scratch.signer(&format!(
        "printf '{KEYSTORE} '; read -r a; printf '{KEYSTORE} '; read -r b; exit 0"
    ));
    let error = twice
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "s3cret-one")],
            4096,
            &|| false,
        )
        .unwrap_err();
    assert!(
        matches!(error, PtyError::PromptProtocolViolation),
        "{error:?}"
    );
    let scratch = Scratch::new("order");
    let reversed = scratch.signer(&format!(
        "printf '{KEY} '; read -r b; printf '{KEYSTORE} '; read -r a; exit 0"
    ));
    let error = reversed
        .run_pty_exchange(
            &request(&arguments, 20),
            &[
                interaction(KEYSTORE, "s3cret-one"),
                interaction(KEY, "s3cret-two"),
            ],
            4096,
            &|| false,
        )
        .unwrap_err();
    assert!(
        matches!(error, PtyError::PromptProtocolViolation),
        "{error:?}"
    );
    let scratch = Scratch::new("silent");
    let silent = scratch.signer("printf 'no prompt here\\n'; exit 0");
    let error = silent
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "s3cret-one")],
            4096,
            &|| false,
        )
        .unwrap_err();
    assert!(
        matches!(error, PtyError::PromptProtocolViolation),
        "{error:?}"
    );
}

#[test]
fn the_budget_the_timeout_and_a_cancellation_terminate_the_group() {
    let scratch = Scratch::new("bounds");
    let arguments: Vec<OsString> = Vec::new();
    let flood = scratch.signer("yes");
    let error = flood
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "s3cret-one")],
            1024,
            &|| false,
        )
        .unwrap_err();
    assert!(matches!(error, PtyError::OutputBudgetExceeded), "{error:?}");
    let scratch = Scratch::new("timeout");
    let stuck = scratch.signer("sleep 30");
    let started = Instant::now();
    let error = stuck
        .run_pty_exchange(
            &request(&arguments, 1),
            &[interaction(KEYSTORE, "s3cret-one")],
            4096,
            &|| false,
        )
        .unwrap_err();
    assert!(matches!(error, PtyError::TimedOut), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(10));
    let scratch = Scratch::new("cancel");
    let stuck = scratch.signer("sleep 30");
    let error = stuck
        .run_pty_exchange(
            &request(&arguments, 20),
            &[interaction(KEYSTORE, "s3cret-one")],
            4096,
            &|| true,
        )
        .unwrap_err();
    assert!(matches!(error, PtyError::Cancelled), "{error:?}");
}

#[test]
fn interactions_and_budgets_are_bounded_before_any_child_runs() {
    let scratch = Scratch::new("bounded");
    let marker = scratch.0.join("ran");
    let signer = scratch.signer(&format!("printf x > {}; exit 0", marker.display()));
    let arguments: Vec<OsString> = Vec::new();
    let too_many: Vec<PtyInteraction> = (0..5)
        .map(|_| interaction(KEYSTORE, "s3cret-one"))
        .collect();
    for (interactions, budget) in [
        (Vec::new(), 4096),
        (too_many, 4096),
        (vec![interaction("", "x")], 4096),
        (vec![interaction(KEYSTORE, "")], 4096),
        (vec![interaction(KEYSTORE, "with\nnewline")], 4096),
        (vec![interaction(KEYSTORE, "s3cret-one")], 1023),
    ] {
        let error = signer
            .run_pty_exchange(&request(&arguments, 20), &interactions, budget, &|| false)
            .unwrap_err();
        assert!(matches!(error, PtyError::InvalidInteraction), "{error:?}");
    }
    assert!(!marker.exists());
}
