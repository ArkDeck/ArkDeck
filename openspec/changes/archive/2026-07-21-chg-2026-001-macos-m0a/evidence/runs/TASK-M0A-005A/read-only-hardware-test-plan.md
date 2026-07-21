# TASK-M0A-007 read-only hardware test plan

> Frozen by: TASK-M0A-005A
>
> Evidence class: plan-only; this document is not hardware-conformance evidence.
>
> Core baseline: CORE-1.0.0
> Prototype: the ad-hoc-signed Sandbox build recorded in `run.md`

## Purpose and limits

This plan lets a **human operator** exercise the Sandboxed prototype's USB,
UART, TCP, and user-selected file-access surfaces without dispatching a device
mutation. It is the only plan input for TASK-M0A-007. A result obtained with a
different app hash, entitlement dump, macOS build, or device/firmware tuple is
a different matrix cell and must be recorded as such.

The plan does not authorize Flash, erase, format, unlock, update, arbitrary
shell execution, HDC server lifecycle mutation, changing device trust state,
or changing host quarantine/xattr data. It does not make a claim about the
blocked non-Sandbox Developer ID prototype from TASK-M0A-005B.

## Preconditions

Before a human starts TASK-M0A-007, record all of the following in that task's
run evidence:

1. Human operator, date/time and physical target confirmation; model, serial
   number, firmware/build, transport address/port (where applicable), and
   current device-binding revision.
2. The exact Sandboxed app artifact path, SHA-256, `codesign --verify --deep
   --strict` result, and `codesign -d --entitlements :-` output. They must
   match the build evidence from TASK-M0A-005A or be captured again for the
   new artifact.
3. macOS version/build, architecture, Xcode version, and the exact HDC path,
   SHA-256, signature/trust assessment, client/server/daemon versions,
   endpoint, ownership, and generation. Unknown fields stay `unknown` or
   `unverified`; they are never inferred.
4. Three non-sensitive, disposable user-selected inputs: an image fixture, a
   non-private public-key fixture, and an empty output directory. The image
   and key must be selected as read-only inputs; only the output directory may
   be selected for writing. Do not copy, display, or persist a private key.
5. A read-only capability probe that uses the app's supervised integration.
   Until such an integration exists, the relevant matrix cell is `blocked`;
   running `hdc` directly in a Terminal does not test this Sandboxed app and
   must not be substituted as evidence.

## Execution protocol

1. Verify the artifact and record the preconditions above. Launch only the
   identified artifact.
2. For each cell below, perform one bounded read-only observation through the
   app's supervised probe. Capture the app diagnostic and system denial/error
   text, then record `allowed`, `blocked`, or `inconclusive` with its reason.
   `inconclusive` is not a pass and must not be retried by changing host or
   device state.
3. Confirm from the audit/journal and supervisor diagnostics that lifecycle
   dispatches and destructive dispatches are both zero. Any intent without a
   known outcome stops the run and is recorded as `outcomeUnknown`.
4. Quit the app and confirm the test inputs were not altered. The output
   directory may contain only the planned diagnostic artifact; its relative
   path, hash, and size are recorded.

## Matrix

| Surface | Read-only observation | Required result record | Never do |
| --- | --- | --- | --- |
| USB | Observe the pre-authorized physical device through the supervised read-only probe. | App result, device binding, Sandbox/permission diagnostic, supervisor endpoint/generation, dispatch counts. | Pair/unpair, authorize/reset trust, Flash, lifecycle command. |
| UART | Observe the pre-authorized serial endpoint without opening it for write. | Endpoint identifier, app result, Sandbox/permission diagnostic, dispatch counts. | Write bytes, change baud/flow settings, reset the device. |
| TCP | Query the explicit, pre-authorized endpoint with the supervised read-only probe. | Endpoint, channel-protection diagnostic, app result, supervisor ownership/generation, dispatch counts. | Discover/scan ports, alter host environment, start/stop/restart server. |
| Image fixture | Select the disposable image as an input and verify the app can retain only the required access reference. | Selection result, input hash, diagnostic, no mutation assertion. | Flash or upload the image. |
| Public-key fixture | Select the disposable public key and verify diagnostics without copying private material. | Selection result, public-key fingerprint, diagnostic, no private-key persistence assertion. | Select, copy, delete, or reset any private key. |
| Output directory | Select the empty directory and write only a bounded diagnostic artifact, if the probe supports it. | Selection result, artifact path/hash/size, diagnostic. | Write device data, replace existing files, or use a non-user-selected path. |

## Stop and reporting rules

- A missing or mismatched artifact hash/entitlement dump, uncertain binding,
  unknown server ownership, generation drift, an unexpected intent, or any
  non-zero lifecycle/destructive dispatch count stops the affected cell.
- Report unsupported/absent test surfaces as `blocked`, not `allowed` and not
  `notApplicable`. Do not weaken a Core requirement to complete the matrix.
- This Sandbox/ad-hoc column is independent of TASK-M0A-005B. The Developer
  ID + Hardened Runtime column remains `blocked` until its stated prerequisites
  are provided and that task is completed.
- TASK-M0A-007 evidence must be classified `realHardware` only when the human
  operator actually executes this protocol and records the required target and
  environment identity. This plan alone is only `plan-only` evidence.
