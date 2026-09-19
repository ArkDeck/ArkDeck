# macOS workspace project registration owner

Status: implementation pending verification. This record does not claim Task,
workspace integration, installation cutover, or hardware acceptance completion.

## Scope and compatibility

The Rust owner implements `workspace.project.register`, `.list`, and `.show`
using the existing Swift `RuntimeWorkspaceProjectStore` registration identity,
root identity, private document, request idempotency, and resource projection.
The Control host and CLI consume this actual durable owner. No workspace Job,
preset mutation, toolchain/credential recovery, signing, or device execution is
added. Registering a root does not authorize execution on it.

A registered project is a real persisted resource. Since this slice does not
compose a workspace execution provider, its configuration remains
`runtimeRestartRequired`, with unavailable operation configuration and empty
operation/preset references, matching Swift's uncomposed resource branch. A
restart preserves the registration; it does not claim to activate a provider.

Existing schema 1–3 project documents and fully validated preset records are
preserved. Definition, registration, and last-mutation digests remain checked.
A pending toolchain mutation requires the missing dependency owners and returns
`operationUnavailable` without rewriting its document. It is not discarded,
completed, or represented as recovered.

## Planned verification and precise limits

The added owner tests cover nonempty registration/list/show after reopening,
request identity and root replacement conflicts, concurrent identical
registration, symlink/private-file/duplicate-JSON refusal, retained preset
validation, and byte-preserving pending mutation refusal. CLI process tests
cover closed arguments, actual framed requests, nonempty resources, and a lost
registration response with no replay. Actual daemon Control/Host tests exercise
the durable owner rather than substituting a canned resource.

The new Swift contract test invokes the existing production handler and owner
for successful registration/show, deterministic parameter/identity/conflict/
quota/unreadable/dependency failures, and staging/rename storage failures using
the existing injected clock and test-owned files. No production fault hook or
hardware fact is added. These tests have not yet run; frames and generated
schemas are not yet updated.

`factsDrifted` during root inspection requires an actual concurrent identity
change. No probabilistic CI race or encoder-only frame is introduced to pretend
this was observed. The owner retains this failure; until a real dispatched
Swift frame extends the sampled vocabulary, the external contract validator
continues its strict `internalError` fallback for the unsupported wire shape.
This is an explicit sampling/observable-error gap, never a success response.

All tests are host filesystem/client fixtures. They provide no real-device or
GJ acceptance evidence. Full repository validation is pending a coordinated
build window; static formatting and diff checks alone are not acceptance.
