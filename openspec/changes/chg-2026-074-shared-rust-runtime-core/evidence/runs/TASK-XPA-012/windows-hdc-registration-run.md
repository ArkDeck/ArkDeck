# TASK-XPA-012 — HDC registration on Windows, over the empty Windows HDC tuple table

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2-B, part B2, on top of the
Windows daemon Bundle (#2451, `windows-daemon-bundle-run.md`) and the Bootstrap registry owners
(#2428, `windows-bootstrap-owners-run.md`). Host: the Windows 11 x64 reference host,
non-elevated, NTFS. No device was contacted, no `hdc` ran, no HDC was installed or used, and
nothing installed was read or written. Host tests are not Windows acceptance.

Basis: CHG-2026-078 (a Windows HDC is its `hdc.exe` SHA-256 and exact `hdc -v` bytes; its
registry, `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`, is a draft whose sample values are
`TBD(sample)`), the Windows HDC tuple gate of TASK-XPA-005 (#2426: `WINDOWS_HDC_TUPLES`, empty),
maintainer ruling 24 (who counts as a trusted owner on NTFS), the maintainer's delegation of
2026-09-30 (non-major choices follow the agent's recommendation, as rulings 18–55 record;
ruling 51 keeps the tuple table a Rust constant TASK-WHR-002 fills, ruling 52 refuses HDC
registration until a Windows HDC tuple is registered, which this part keeps), and
the delegated minor decisions below. The lead's direction: build HDC registration over #2426's
table exactly as it is, add no entry, and prove that with the table empty registering `hdc.exe`
still refuses. The tool-selection owner is S1's and is not part of this slice.

## What

| Where | What |
| --- | --- |
| `arkdeck-platform` `windows::bootstrap_tree` | The capture internals (private staging directory, created-entry tracking, removal of exactly what was created, exclusive publication) are one `Stage`, shared by the Bundle capture and a new `BootstrapToolCapture`: the macOS HDC capture's API and order — the program at the source path, then, only when it imports it, the fixed sibling `libusb_shared.dll` of the same directory, each opened relative to the held directory, never through a reparse point, owned by the user or a trusted principal and changeable by nobody else, copied into `.tool-staging-<nonce>` as `hdc.exe` and `libusb_shared.dll`, re-read and re-hashed on every revalidation, and published exclusively as `tool-<digest>.hdc`. |
| `arkdeck-bootstrap` `tool_pe` | Bounded, read-only PE inspection (the counterpart of `tool_macho`): MZ and PE headers, x64 (`AMD64`), PE32+, program or DLL, and the import descriptors' DLL names. A PE import names a DLL, never a path, and the loader searches the image's own directory first, so the layout is relocatable by construction. |
| `arkdeck-bootstrap` `tool_content` | `inspect_tool_content` on Windows: exactly `hdc.exe`, or `hdc.exe` and `libusb_shared.dll` when the program imports it; a program and a DLL; each file's Authenticode signature recorded as integrity (`verified` with the signer's name and leaf SHA-256, or `unsigned`), never as permission to execute; the content digest over the entries with `"platform":"windows"`, so no Windows reference equals a macOS one. |
| `arkdeck-bootstrap` `tool_registration`, `registry` | The macOS registration owner, built on Windows, with a `X:\…` source path, the PE callback, and the admission gate below. The Windows record adds `"platform":"windows"` and names the `.dll` sibling; each host reads only its own record form, and the projection answers the record's platform. |
| `arkdeck-agentd` `bootstrap_readers` | The Windows daemon composes `arkdeck_provider_hdc::windows_tuple` into the tool store's published identities (`version` the tuple's reported version, no profile reference): the table exactly as #2426 holds it. |

### The admission gate

On macOS a registered HDC need not be a published identity: its projection says
`registeredIdentity: false`. On Windows an HDC is admitted only when a registered Windows tuple
names its executable, because CHG-2026-078 makes the tuple the Windows HDC's identity and the lead
asked for nothing to be admitted that a registered entry does not name. The gate is the store's
published identities, checked twice:

1. on the source, read once and bounded, before the store is locked: refused with
   `admissionDenied`, "no registered Windows HDC tuple names this hdc.exe (CHG-2026-078); nothing
   was retained", and nothing is written, not even the store's lock; an absent or unreadable
   source is `fileIdentityChanged`, also writing nothing;
2. on the captured bytes, after the content and signature inspection and before anything is
   published: the same refusal, the staging copy removed.

`WINDOWS_HDC_TUPLES` is empty, so the daemon refuses every `hdc.exe`. When TASK-WHR-002 adds a
registered entry, that executable registers with no other change.

## Delegated minor decisions (pending the next rulings batch)

1. **The Windows admission gate is the store's published identities**, checked on the source
   and on the captured bytes (above), not a second table in `arkdeck-bootstrap`, which does not
   depend on the provider; a store its composer gives no identities admits nothing.
2. **A Windows tuple's projected identity names no profile** (`profileReferences: []`): the
   tuple comes from the probe registry, not a published profile.
3. **The Windows HDC record and content digest are host-tagged** (`"platform":"windows"`), as
   the Windows daemon Bundle's are; no schema widens (`platform` is a string there).
4. **The sibling is captured only when `hdc.exe` imports it**, as on macOS; a `libusb_shared.dll`
   beside a program that does not import it is left out, and a retained tree holding one is
   refused.

## Tests on Windows

- **`arkdeck-platform` `windows::bootstrap_tree`**: an HDC capture reads the program, and the
  sibling only when the program's inspection asks for it, copies both privately and nothing else,
  refuses a malformed digest, publishes once, meets its published copy on a second capture
  without touching it, passes an inspection's refusal through, refuses a source changed after
  capture, and removes every unpublished stage; a program that needs an absent sibling, an empty
  program and a relative path are refused with nothing staged. The Bundle capture's tests are
  unchanged.
- **`arkdeck-bootstrap` `tool_pe`, `tool_content`, `registry`**: a program and a DLL told apart
  with their imports; anything else refused; a copied `System32` program is stable, host-tagged
  content, not the untagged digest; a DLL as `hdc.exe`, a script, an unimported sibling and an
  extra file are refused; each host reads only its own tool record form.
- **`arkdeck-bootstrap/tests/windows_tool_registration.rs`**: with no identity (a store as
  composed over an empty table, and one with none) an `hdc.exe` is `admissionDenied` citing
  CHG-2026-078 with the store left empty; an identity that admits the source but not the captured
  bytes is refused with no retained content or staging; under an injected fixture identity a copy
  of a `System32` program registers (`platform: windows`, conforming to the published
  `runtime.tool.register|inspect` schemas), again with no write, inspects, lists, reads back
  without the identity as `registeredIdentity: false`, refuses relative, `/`-spelled and `..`
  paths and another program, retires once, is not registered again, and no longer verifies once
  its retained copy changes.
- **`arkdeck-agentd/tests/windows_bootstrap_owners_process.rs`**: over the real daemon's pipe an
  absent `hdc.exe` is `fileIdentityChanged` and a real one `admissionDenied` citing CHG-2026-078,
  writing nothing; through the signed CLI the same refusal.

## Coverage

`runtime.tool.register --kind hdc` does not join `WINDOWS_MEASURED_LEAVES`: with the table empty
no HDC registers end to end on Windows.

## Local checks

See the commit message.
