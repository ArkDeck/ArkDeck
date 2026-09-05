# Live CLI HDC status

`arkdeck runtime hdc status --output json` defaults to the current v1 control contract and
reads the new `runtime.hdc.status` method. It returns
`arkdeck.runtime-hdc-status/1`, with the configured executable path/source,
expected and verified hashes, static signature, client/server/daemon versions,
endpoint reference, observed process generation, ownership and health. Unknown
facts are explicit null/unknown values, never guessed defaults.

The Runtime retains launch provenance at the existing identity-bound spawn
point: exact executable identity, complete arguments, PID and process start time.
Status compares that provenance with a fresh registered process/listener
observation and reuses the existing managed-process argv/listener predicate,
bracketed by process birth checks. A reused
PID, different start time, stopped owner or missing launch receipt cannot
establish `arkDeckManaged`; the status remains `unknown` even if an executable
with the same path owns the endpoint. Reading status never changes ownership.

The reader retains and revalidates the configured executable before and after
signature and native identity inspection. File replacement, permission changes
and change-and-restore races invalidate the observation. Invalid signatures or
unreadable identity return a structured unavailable result with no verified
hash or generation. The configured hash remains separately labeled; it is not
represented as a fresh measurement when validation fails.

The commandless observer uses only the existing published 3.2.0d or exact
3.2.0f identity family. It does not launch HDC, run `checkserver`/`-v`, probe
devices, create Jobs or publish lifecycle intents. Its `newDispatchCount` is
zero. A client version is diagnostic metadata from an exact published executable
digest match, explicitly labeled `publishedExecutableDigest`. Signature validity
does not grant OS execution permission or Provider support.

Native process/listener identity does not prove current server health or its
reported protocol version. Therefore `serverHealth` remains `unknown` and
`serverVersion` remains null on this read-only path; `startupVersions` contains
the old readiness values as historical diagnostics only. `availability:
available` means that the identity observation succeeded, not that a restart is
admitted or that the HDC service is healthy. Later control actions must obtain
their own complete fresh facts and cannot use this JSON projection as authority.

CLI and App use `runtime.hdc.status`. The startup-cache alias has been removed.
The current method rejects caller paths, generations and other parameters;
missing live observation remains unavailable.

This closes a status prerequisite for GJ-1 and the full CLI lifecycle surface.
Control-action previews, tool selection, impact-approval HAR consumption,
audited lifecycle dispatch and the App bridge remain separate unfinished work.
Host fixtures and the optional static SDK-copy inspection are not real-device
acceptance. The latter never executes its copied HDC and explicitly skips when
DevEco is absent.
