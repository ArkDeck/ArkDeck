//! One analyzer child as Swift's descriptor-bound analyzer dispatch runs it
//! (`DescriptorBoundProcessDispatcher` over `FoundationProcessExecutor`): the
//! generic verified-tool runner of `tool_process` with the source Artifact
//! retained across the run and handed over as the `/.vol` alias of a
//! descriptor bound to its digest. The child's environment is the clean one
//! every identity-bound spawn here gets; no ambient variable is inherited.
use super::tool_process::{MAX_CAPTURE_BYTES, MAX_TIMEOUT};
use super::{
    ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedTool, denied, hash_file,
    invalid, same_metadata,
};
use std::ffi::OsString;
use std::fs::{File, Metadata};
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::time::Duration;

#[derive(Clone, Copy, Debug)]
pub struct AnalyzerLimits {
    pub timeout: Duration,
    /// Each stream keeps this many bytes; the rest is read and dropped.
    pub capture_bytes: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnalyzerTermination {
    Exited(i32),
    Signalled(i32),
    /// The deadline passed; the process group was terminated.
    TimedOut,
    /// Cancelled before the child was spawned, or while it ran, when its
    /// process group was terminated. `drained` holds when no member of the
    /// group was left: Swift's positive proof that nothing survived.
    Cancelled {
        drained: bool,
    },
}

#[derive(Debug)]
pub struct AnalyzerExecution {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Either stream produced more than it kept.
    pub truncated: bool,
    pub termination: AnalyzerTermination,
}

#[derive(Debug)]
pub enum AnalyzerRunError {
    /// Refused before the child ran any executable code.
    Refused(io::Error),
    /// The child may have run; what it did cannot be observed.
    Unobservable(io::Error),
}

/// A regular file bound, through one retained descriptor, to its expected
/// length and SHA-256. A child reads it through the `/.vol` alias of that
/// descriptor's inode, so no later path lookup can select other bytes.
pub struct VerifiedSource {
    _file: File,
    metadata: Metadata,
}

impl VerifiedSource {
    pub fn open(path: &Path, sha256: &str, byte_count: u64) -> io::Result<Self> {
        if byte_count == 0 || sha256.len() != 64 {
            return Err(invalid("a verified source needs its length and SHA-256"));
        }
        let file = super::open_locked_file(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() != byte_count {
            return Err(denied(
                "source is not a regular file of its expected length",
            ));
        }
        if hash_file(&file, byte_count)? != sha256 {
            return Err(denied("source bytes do not match their SHA-256"));
        }
        if !same_metadata(&metadata, &file.metadata()?) {
            return Err(denied("source changed while hashing"));
        }
        Ok(Self {
            _file: file,
            metadata,
        })
    }

    pub fn inode_path(&self) -> String {
        format!("/.vol/{}/{}", self.metadata.dev(), self.metadata.ino())
    }
}

impl VerifiedTool {
    /// Run the pinned executable once with `arguments`; `source` stays open,
    /// keeping its inode alias valid, until the child has been reaped.
    /// `cancelled` is asked before the spawn and while the child runs.
    pub fn run_analyzer(
        &self,
        arguments: &[OsString],
        source: &VerifiedSource,
        limits: AnalyzerLimits,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<AnalyzerExecution, AnalyzerRunError> {
        if limits.timeout.is_zero()
            || limits.timeout > MAX_TIMEOUT
            || limits.capture_bytes == 0
            || limits.capture_bytes > MAX_CAPTURE_BYTES
        {
            return Err(AnalyzerRunError::Refused(invalid(
                "analyzer budget must be 1 s..1 h and 1 byte..64 MiB per stream",
            )));
        }
        let _source = source;
        let execution = self
            .run_tool(
                &ToolRequest {
                    arguments,
                    environment: &[],
                    working_directory: None,
                    limits: ToolLimits {
                        timeout: limits.timeout,
                        capture_bytes: limits.capture_bytes,
                    },
                },
                cancelled,
            )
            .map_err(|error| match error {
                ToolRunError::Refused(error) => AnalyzerRunError::Refused(error),
                ToolRunError::Unobservable(error) => AnalyzerRunError::Unobservable(error),
            })?;
        Ok(AnalyzerExecution {
            stdout: execution.stdout,
            stderr: execution.stderr,
            truncated: execution.truncated,
            termination: match execution.termination {
                ToolTermination::Exited(code) => AnalyzerTermination::Exited(code),
                ToolTermination::Signalled(signal) => AnalyzerTermination::Signalled(signal),
                ToolTermination::TimedOut => AnalyzerTermination::TimedOut,
                ToolTermination::Cancelled { drained } => {
                    AnalyzerTermination::Cancelled { drained }
                }
            },
        })
    }
}
