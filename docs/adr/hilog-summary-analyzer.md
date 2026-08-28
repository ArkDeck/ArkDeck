# HiLog summary implementation

This closes the missing implementation behind the already published
`analyzer.summarize-hilog@1`, `hilog-summary@1` and `workspace-host@1` profile.
It advances the collected-log analysis part of GJ-1/GJ-5; it adds no operation,
provider, integration profile, device command or admission authority.

## Availability and execution

The production daemon supplies the profile only when `ARKDECK_ANALYZER_PATH`
resolves to the same executable SHA-256 as the current daemon. The installer
already sets that path. An older or custom crash-only analyzer cannot inherit
HiLog availability: it reports `analyzer.hilogRequiresCurrentDaemon`. No configured
path reports `analyzer.profileUnavailable`; later pin drift remains unavailable.

The existing Analyzer Provider materializes the immutable Artifact lease and
dispatches the fixed one-shot mode through `DescriptorBoundProcessDispatcher`.
No caller selects an executable, arguments or a filesystem path. The analyzer
reads only that regular file (no symlink components, at most 512 MiB), returns at
most 8 KiB of canonical JSON and exits without starting the daemon or accessing
device transport. Its output repeats the measured source hash and byte count;
the Provider checks them against the invocation before publication.

The dispatcher replaces the input pathname with its retained Darwin
`/.vol/<device>/<inode>` alias. The child opens that exact kernel alias and
verifies its device/inode and regular-file type, then applies the same bounded
read and post-read identity checks. It never resolves the alias back to a
mutable pathname. Other profile/tool readers do not opt into this namespace.

## Summary meaning and privacy

The implementation counts D/I/W/E/F headers in the default HiLog time format,
including older unprefixed domains, current type-prefixed domains and
millisecond/microsecond/nanosecond precision. The format reference is
[OpenHarmony's HiLog documentation](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hilog.md#hilog日志格式说明)
and the older header example in the
[upstream HiLog README](https://github.com/openharmony/hiviewdfx_hilog/blob/master/README.md).

Only a 256-byte prefix of each physical line is retained for header recognition.
Bodies are opaque: no log text, tags, timestamps, PIDs, paths or secrets are
copied to the standard-privacy summary. The raw Artifact stays unchanged and
retains its original privacy classification. Blank and unrecognized lines are
counted explicitly. Wrapped continuation lines and nondefault formats are not
guessed. `headerCoverage` describes only recognition of those physical headers;
even `complete` does not establish capture completeness, valid body encoding,
absence of faults or device health. Zero error-level headers is not a pass verdict.

The Provider rejects unknown/duplicate JSON fields, noncanonical output,
inconsistent counts, wrong source/version and unexpected stderr. The stored
derived Artifact contains the validated result plus source Artifact ID,
analyzer executable hash and analyzer-output hash/size. Its own Runtime metadata
supplies the derived Artifact hash and Job/session identity. Repeating analysis
of the same source with the same analyzer produces identical derived bytes;
host-only analysis does not claim a new device binding revision.

## Verification boundary

Contract tests cover parser limits and privacy, source drift, malformed reports,
tool selection and publication. The process test
`AgentDaemonContractTests.testHilogAnalyzerRunsMultipleJobsInOneDaemonSession`
starts one isolated production daemon and runs three sequential typed Jobs,
checking unchanged PID, complete provenance, identical outputs and unchanged
source bytes. A separate configuration test refuses a mismatched executable.
These use synthetic local Artifacts and are not real-device evidence.

Observed on 2026-08-29: the focused run passed 22 tests with no failures. All
three `HILOG_CONTINUITY` records retained the same daemon PID. The first run
exposed the kernel-alias read defect; the second exposed a test decoding the
wire `artifactId` field as the storage model's `artifactID`. Both failures were
retained in local run logs. The final test reads the actual list/read wire
responses without changing the product protocol.

A local replay of a previously collected real HiLog Artifact also matched an
independent header count. Raw content, source identifiers and hashes remain
only in private local records and are not included in this delivery. This is
existing-Artifact replay, not a new device run or protected-main Runtime
acceptance. No device operation or Runtime installation was performed for it.

After this implementation is reviewed and merged, the protected-main Runtime
must analyze a real collected HiLog Artifact through the ordinary typed CLI
path before this gap can be called real-device validated. No unmerged Runtime
is installed for that purpose.

Compatibility: TASK-HFA-007 is used only as the existing path guard; its old
done/readiness records and accepted requirements are not changed. The currently
implemented action-specific executable resolver supersedes the historical
single-binary limitation noted in that task.
