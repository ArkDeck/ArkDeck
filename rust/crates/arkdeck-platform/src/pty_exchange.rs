//! One exact prompt/secret exchange with a descriptor-bound child on a
//! pseudo-terminal, as Swift's `IdentityBoundPTYExecutor` runs the OpenHarmony
//! signer (SPK-6 phase 4, TASK-XPA-016). The secret is never part of a process
//! request, argv, environment or returned receipt, and no transcript comes
//! back: a password can therefore never reach a generic process receipt even
//! if an upstream terminal implementation starts echoing input. The parent
//! owns the privacy boundary — echo is disabled on the terminal before the
//! child runs, rather than trusting the signer to win a race between printing
//! its prompt and disabling echo itself.
use super::macos_process::spawn_pty;
use super::{ToolTermination, VerifiedTool, invalid};
use std::ffi::OsString;
use std::io;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::time::{Duration, Instant};

/// One prompt the child is expected to print, and the secret to answer it.
/// Callers clear their copy of the secret after the exchange.
#[derive(Clone)]
pub struct PtyInteraction {
    pub expected_prompt: Vec<u8>,
    pub secret: Vec<u8>,
}

/// Closed signer failure vocabulary derived in memory from the PTY stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PtyFailureCategory {
    None,
    KeystorePasswordRejected,
    KeyPasswordRejected,
    KeyAliasRejected,
    KeyMaterialRejected,
    KeystoreRejected,
    ProfileCertificateMismatch,
    CertificateChainRejected,
    CertificateRejected,
    ProfileRejected,
    InputArchiveUnreadable,
    InputArchiveFormatRejected,
    InputHapIntegrityRejected,
    InputDistributionRejected,
    InputHapRejected,
    SignerRejected,
}

impl PtyFailureCategory {
    /// Swift's `rawValue`, the spelling receipts carry.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::KeystorePasswordRejected => "keystorePasswordRejected",
            Self::KeyPasswordRejected => "keyPasswordRejected",
            Self::KeyAliasRejected => "keyAliasRejected",
            Self::KeyMaterialRejected => "keyMaterialRejected",
            Self::KeystoreRejected => "keystoreRejected",
            Self::ProfileCertificateMismatch => "profileCertificateMismatch",
            Self::CertificateChainRejected => "certificateChainRejected",
            Self::CertificateRejected => "certificateRejected",
            Self::ProfileRejected => "profileRejected",
            Self::InputArchiveUnreadable => "inputArchiveUnreadable",
            Self::InputArchiveFormatRejected => "inputArchiveFormatRejected",
            Self::InputHapIntegrityRejected => "inputHAPIntegrityRejected",
            Self::InputDistributionRejected => "inputDistributionRejected",
            Self::InputHapRejected => "inputHAPRejected",
            Self::SignerRejected => "signerRejected",
        }
    }
}

/// What the exchange established, and nothing of what was said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PtyExecution {
    pub termination: ToolTermination,
    pub completed_interactions: usize,
    pub observed_output_byte_count: usize,
    pub failure_category: PtyFailureCategory,
}

#[derive(Debug)]
pub enum PtyError {
    InvalidInteraction,
    /// Refused before any child ran: the tool, environment or working
    /// directory did not verify.
    Refused(io::Error),
    LaunchFailed(io::Error),
    PromptProtocolViolation,
    SecretEchoDetected,
    OutputBudgetExceeded,
    TimedOut,
    Cancelled,
    WaitFailed(io::Error),
}

/// What the child is launched with; the secrets travel separately and only
/// ever through the terminal.
pub struct PtyRequest<'a> {
    pub arguments: &'a [OsString],
    pub environment: &'a [(OsString, OsString)],
    pub working_directory: Option<&'a Path>,
    pub timeout: Duration,
}

const MAX_INTERACTIONS: usize = 4;
const MAX_PROMPT_BYTES: usize = 512;
const MAX_SECRET_BYTES: usize = 4096;
const MIN_OUTPUT_BUDGET: usize = 1024;
/// Swift `terminateProcessGroup` for the signer: TERM, 100 ms, KILL.
const TERMINATION_GRACE: Duration = Duration::from_millis(100);

impl VerifiedTool {
    /// Runs the pinned executable on a pseudo-terminal, answering each exact
    /// prompt in order with its secret, and reports only what the exchange
    /// established. `cancelled` is asked while the child runs.
    pub fn run_pty_exchange(
        &self,
        request: &PtyRequest<'_>,
        interactions: &[PtyInteraction],
        output_byte_budget: usize,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<PtyExecution, PtyError> {
        if interactions.is_empty()
            || interactions.len() > MAX_INTERACTIONS
            || output_byte_budget < MIN_OUTPUT_BUDGET
            || !interactions.iter().all(|interaction| {
                !interaction.expected_prompt.is_empty()
                    && interaction.expected_prompt.len() <= MAX_PROMPT_BYTES
                    && !interaction.secret.is_empty()
                    && interaction.secret.len() <= MAX_SECRET_BYTES
                    && !interaction
                        .secret
                        .iter()
                        .any(|byte| matches!(byte, 0 | b'\n' | b'\r'))
            })
        {
            return Err(PtyError::InvalidInteraction);
        }
        if request.timeout.is_zero() {
            return Err(PtyError::Refused(invalid("the exchange needs a timeout")));
        }
        super::tool_process::validate_environment(request.environment)
            .map_err(PtyError::Refused)?;
        let directory = request
            .working_directory
            .map(super::tool_process::validate_working_directory)
            .transpose()
            .map_err(PtyError::Refused)?;
        self.revalidate().map_err(PtyError::Refused)?;
        let (pid, master) = spawn_pty(
            self,
            request.arguments,
            request.environment,
            directory.as_deref(),
            true,
        )
        .map_err(PtyError::LaunchFailed)?;
        let mut child = ExchangeChild { pid, exited: false };
        let deadline = Instant::now() + request.timeout;
        let mut output = Zeroing(Vec::new());
        let mut completed = 0;
        let mut status = 0;
        while !child.exited {
            if cancelled() {
                child.terminate();
                return Err(PtyError::Cancelled);
            }
            if Instant::now() >= deadline {
                child.terminate();
                return Err(PtyError::TimedOut);
            }
            let mut descriptor = libc::pollfd {
                fd: master.as_raw_fd(),
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            };
            // SAFETY: one live descriptor; the wait is bounded to 25 ms.
            let polled = unsafe { libc::poll(&mut descriptor, 1, 25) };
            if polled < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    child.terminate();
                    return Err(PtyError::WaitFailed(error));
                }
            }
            if polled > 0 && descriptor.revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                let mut buffer = [0u8; 4096];
                // SAFETY: the buffer is writable for its whole length.
                let count = unsafe {
                    libc::read(master.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
                };
                if count > 0 {
                    output.0.extend_from_slice(&buffer[..count as usize]);
                    if output.0.len() > output_byte_budget {
                        child.terminate();
                        return Err(PtyError::OutputBudgetExceeded);
                    }
                    if interactions
                        .iter()
                        .any(|interaction| contains(&output.0, &interaction.secret))
                    {
                        child.terminate();
                        return Err(PtyError::SecretEchoDetected);
                    }
                    // Only the exact, closed prompts are protocol messages. The
                    // signer also uses "please input ..." prose in some error
                    // diagnostics; a second occurrence of a prompt is a
                    // violation, not a new question.
                    let occurrences: Vec<usize> = interactions
                        .iter()
                        .map(|interaction| {
                            count_occurrences(&output.0, &interaction.expected_prompt)
                        })
                        .collect();
                    if occurrences.iter().any(|count| *count > 1) {
                        child.terminate();
                        return Err(PtyError::PromptProtocolViolation);
                    }
                    while completed < interactions.len()
                        && contains(&output.0, &interactions[completed].expected_prompt)
                    {
                        if let Err(error) =
                            write_all(master.as_raw_fd(), &interactions[completed].secret)
                                .and_then(|()| write_all(master.as_raw_fd(), b"\n"))
                        {
                            child.terminate();
                            return Err(PtyError::WaitFailed(error));
                        }
                        completed += 1;
                    }
                    if occurrences
                        .iter()
                        .enumerate()
                        .any(|(index, count)| index > completed && *count > 0)
                    {
                        child.terminate();
                        return Err(PtyError::PromptProtocolViolation);
                    }
                } else if count < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::WouldBlock
                        && error.kind() != io::ErrorKind::Interrupted
                        && error.raw_os_error() != Some(libc::EIO)
                    {
                        child.terminate();
                        return Err(PtyError::WaitFailed(error));
                    }
                }
            }
            // SAFETY: only this child is queried, without blocking.
            let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            if waited == pid {
                child.exited = true;
            } else if waited < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    child.terminate();
                    return Err(PtyError::WaitFailed(error));
                }
            }
        }
        if completed != interactions.len() {
            return Err(PtyError::PromptProtocolViolation);
        }
        let termination = if libc::WIFEXITED(status) {
            ToolTermination::Exited(libc::WEXITSTATUS(status))
        } else if libc::WIFSIGNALED(status) {
            ToolTermination::Signalled(libc::WTERMSIG(status))
        } else {
            return Err(PtyError::WaitFailed(io::Error::other(
                "unrecognized child wait status",
            )));
        };
        let failure_category = if termination == ToolTermination::Exited(0) {
            PtyFailureCategory::None
        } else {
            classify_failure(&output.0, interactions)
        };
        Ok(PtyExecution {
            termination,
            completed_interactions: completed,
            observed_output_byte_count: output.0.len(),
            failure_category,
        })
    }
}

/// The transcript, wiped when the exchange is over.
struct Zeroing(Vec<u8>);

impl Drop for Zeroing {
    fn drop(&mut self) {
        for byte in self.0.iter_mut() {
            // SAFETY: a volatile write keeps the wipe from being optimised away.
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
    }
}

struct ExchangeChild {
    pid: libc::pid_t,
    exited: bool,
}

impl ExchangeChild {
    /// Swift `terminateProcessGroup`: TERM the child's own group, 100 ms, KILL,
    /// then reap the child.
    fn terminate(&mut self) {
        if self.exited {
            return;
        }
        // SAFETY: the child's group is its own (POSIX_SPAWN_SETPGROUP), so the
        // signals reach nothing else; the wait reaps only that child.
        unsafe {
            libc::kill(-self.pid, libc::SIGTERM);
        }
        std::thread::sleep(TERMINATION_GRACE);
        // SAFETY: as above.
        unsafe {
            libc::kill(-self.pid, libc::SIGKILL);
            let mut status = 0;
            libc::waitpid(self.pid, &mut status, 0);
        }
        self.exited = true;
    }
}

impl Drop for ExchangeChild {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn write_all(descriptor: i32, bytes: &[u8]) -> io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        // SAFETY: the slice is readable for the remaining length.
        let count = unsafe {
            libc::write(
                descriptor,
                bytes[written..].as_ptr().cast(),
                bytes.len() - written,
            )
        };
        if count > 0 {
            written += count as usize;
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted || error.kind() == io::ErrorKind::WouldBlock {
            continue;
        }
        return Err(error);
    }
    Ok(())
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && find(haystack, needle, 0).is_some()
}

fn count_occurrences(haystack: &[u8], needle: &[u8]) -> usize {
    if needle.is_empty() {
        return 0;
    }
    let mut count = 0;
    let mut cursor = 0;
    while let Some(found) = find(haystack, needle, cursor) {
        count += 1;
        cursor = found + needle.len();
    }
    count
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > haystack.len() || needle.len() > haystack.len() - from {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| from + offset)
}

/// Swift `classifyFailure`: the diagnostic is what followed the last prompt
/// (or everything, when no prompt was seen), lowercased and matched against
/// the closed signer vocabulary in Swift's order.
fn classify_failure(output: &[u8], interactions: &[PtyInteraction]) -> PtyFailureCategory {
    let diagnostic = interactions
        .last()
        .and_then(|interaction| {
            find(output, &interaction.expected_prompt, 0)
                .map(|found| &output[found + interaction.expected_prompt.len()..])
        })
        .unwrap_or(output);
    let text = String::from_utf8_lossy(diagnostic).to_lowercase();
    let has = |needle: &str| text.contains(needle);
    if has("incorrect keystore password")
        || has("keystore password was incorrect")
        || has("keystore tampered with")
    {
        return PtyFailureCategory::KeystorePasswordRejected;
    }
    if (has("key alias") && has("password error"))
        || has("unrecoverablekeyexception")
        || has("failed to decrypt safe contents entry")
    {
        return PtyFailureCategory::KeyPasswordRejected;
    }
    if has("key alias not found")
        || has("keyalias parameter is incorrect")
        || has("keyalias is not exist")
    {
        return PtyFailureCategory::KeyAliasRejected;
    }
    if has("profile certificate match failed")
        || has("input certificates do not match with profile")
    {
        return PtyFailureCategory::ProfileCertificateMismatch;
    }
    if has("cert must a cert chain") || has("certificate must be a cert chain") {
        return PtyFailureCategory::CertificateChainRejected;
    }
    if has("certificate format is incorrect")
        || has("certificate check failed")
        || has("certificate in keystore is invalid")
        || has("certificate is incorrect")
    {
        return PtyFailureCategory::CertificateRejected;
    }
    if has("verify profile failed") || has("profile is invalid") || has("profile content invalid") {
        return PtyFailureCategory::ProfileRejected;
    }
    if has("keystore") || has("key store") {
        return PtyFailureCategory::KeystoreRejected;
    }
    if has("keyalias") || has("key alias") || has("private key") || has("invalid key") {
        return PtyFailureCategory::KeyMaterialRejected;
    }
    if has("read zip file failed") {
        return PtyFailureCategory::InputArchiveUnreadable;
    }
    if has("zip format failed") || has("hap format error") || has("hap parse error") {
        return PtyFailureCategory::InputArchiveFormatRejected;
    }
    if has("verify input hap failed") {
        return PtyFailureCategory::InputHapIntegrityRejected;
    }
    if has("input file is not an enterprise application")
        || has("unsupported application distribution type")
    {
        return PtyFailureCategory::InputDistributionRejected;
    }
    if has("input hap") {
        return PtyFailureCategory::InputHapRejected;
    }
    PtyFailureCategory::SignerRejected
}

#[cfg(test)]
mod tests {
    use super::{PtyFailureCategory, PtyInteraction, classify_failure};

    fn prompt() -> Vec<PtyInteraction> {
        vec![PtyInteraction {
            expected_prompt: b"Enter keystore password:".to_vec(),
            secret: b"s3cret".to_vec(),
        }]
    }

    #[test]
    fn the_signer_vocabulary_is_classified_from_the_diagnostic_after_the_last_prompt() {
        let cases: [(&str, PtyFailureCategory); 8] = [
            (
                "Enter keystore password: Incorrect keystore password\n",
                PtyFailureCategory::KeystorePasswordRejected,
            ),
            (
                "Enter keystore password: key alias password error\n",
                PtyFailureCategory::KeyPasswordRejected,
            ),
            (
                "Enter keystore password: keyAlias is not exist\n",
                PtyFailureCategory::KeyAliasRejected,
            ),
            (
                "Enter keystore password: profile certificate match failed\n",
                PtyFailureCategory::ProfileCertificateMismatch,
            ),
            (
                "Enter keystore password: Verify profile failed\n",
                PtyFailureCategory::ProfileRejected,
            ),
            (
                "Enter keystore password: read zip file failed\n",
                PtyFailureCategory::InputArchiveUnreadable,
            ),
            (
                "Enter keystore password: input hap is broken\n",
                PtyFailureCategory::InputHapRejected,
            ),
            (
                "Enter keystore password: something else\n",
                PtyFailureCategory::SignerRejected,
            ),
        ];
        for (output, expected) in cases {
            assert_eq!(
                classify_failure(output.as_bytes(), &prompt()),
                expected,
                "{output:?}"
            );
        }
        // Text before the last prompt is not the diagnostic.
        assert_eq!(
            classify_failure(
                b"keystore warning\nEnter keystore password: nothing\n",
                &prompt()
            ),
            PtyFailureCategory::SignerRejected
        );
        assert_eq!(
            classify_failure(b"keystore warning only", &prompt()),
            PtyFailureCategory::KeystoreRejected
        );
        assert_eq!(
            PtyFailureCategory::InputHapIntegrityRejected.as_str(),
            "inputHAPIntegrityRejected"
        );
    }
}
