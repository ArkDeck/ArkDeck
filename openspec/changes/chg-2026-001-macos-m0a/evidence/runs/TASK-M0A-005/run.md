# TASK-M0A-005 run record — 2026-07-15

- Evidence class: `environmentInventory` (blocked before prototype construction;
  no hardware)
- Core baseline: `CORE-1.0.0`
- Integration profile: `OPENHARMONY-TOOLS@0.1.0`
- Scope: `MAC-M0A-TRUST-001` through `MAC-M0A-TRUST-004`; read-only plan input
  for `TASK-M0A-007`

## Ready check

- Change `CHG-2026-001-macos-m0a` is approved.
- Dependencies `TASK-M0A-001`, `TASK-M0A-002`, and `TASK-M0A-003` are merged
  into protected `main` and recorded done.
- The required clean-VM and code-signing prerequisites are unavailable, so the
  task is blocked before any prototype or trust-matrix action.

## Environment observations

| Check | Result |
| --- | --- |
| `security find-identity -v -p codesigning` | `0 valid identities found` |
| Project Debug/Release signing | `CODE_SIGN_IDENTITY = -`, manual ad-hoc signing |
| Hardened Runtime | `ENABLE_HARDENED_RUNTIME = NO` in both current configurations |
| Sandbox / non-Sandbox configurations | No dedicated pair exists in the project |
| Clean-VM controllers | No executable UTM, VirtualBox, Parallels, or VMware controller was found at the standard local paths checked |

The macOS profile requires a restored clean VM snapshot for the Safari download
and Archive Utility quarantine-propagation matrix. It also requires actual
signed entitlement dumps for both a Sandboxed and a Developer ID + Hardened
Runtime prototype. The current development host cannot substitute for either
evidence class.

## Commands and results

| Command | Result |
| --- | --- |
| `security find-identity -v -p codesigning` | Completed: no valid signing identity is available. |
| Read-only inspection of `ArkDeck.xcodeproj/project.pbxproj` | Confirmed ad-hoc signing and disabled Hardened Runtime in current Debug/Release settings. |
| Read-only standard-path probe for UTM, VirtualBox, Parallels, and VMware controllers | Completed: no controller found. |

## Result and unblock conditions

`TASK-M0A-005` is **blocked**. No Sandbox/non-Sandbox prototype was built, no
HDC was invoked, no browser download occurred, no quarantine xattr was read or
modified, no VM was started, and no USB/UART/TCP or device operation occurred.
Consequently every clean-VM trust-matrix row remains pending; this record is
not platform or hardware conformance evidence.

To resume, the maintainer must provide:

1. A clean macOS 14+ VM snapshot with an approved way to restore and operate
   it for the Safari → Archive Utility quarantine scenarios;
2. an authorized Developer ID signing identity available to the build
   environment, plus the intended signing/provisioning setup;
3. approved inputs for both prototype configurations, including the external
   HDC provenance and the exact user-selected image/key/output test inputs.

Once available, the task must create the two separate configurations, build
the signed artifacts, capture entitlement and Gatekeeper evidence in the clean
VM, and freeze the read-only USB/UART/TCP plan for `TASK-M0A-007`.

## Residual risk

Completion of `TASK-M0A-003` does not by itself unblock
`MAC-M0A-HDC-001`. The installed-tool observation remains blocked until a
concrete tool integration routes the probe through the supervisor and captures
host-wide ownership/lifecycle evidence; the in-memory supervisor prototype is
not such an integration.

The task state is drafted as `blocked` on this agent branch. It takes effect
only after maintainer review and merge; the Agent does not mark any change or
acceptance case verified.

## Maintainer decision — 2026-07-15

After reviewing this record, the maintainer split the original task through
the same reviewed PR: `TASK-M0A-005A` (Sandboxed prototype with honest
signing-level disclosure, plus the frozen read-only plan for `TASK-M0A-007`)
is executable now; `TASK-M0A-005B` (Developer ID + Hardened Runtime prototype
and the clean-VM trust matrix) stays blocked, and the maintainer chose not to
provision the missing prerequisites for now. `MAC-M0A-TRUST-001…004` enter
the `TASK-M0A-006` rollup as blocked rows; the distribution ADR must state
the evidence basis lost to this blocker.
