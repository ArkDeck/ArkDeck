# Device list ClientKit extraction

Base: protected main `94b2896609c549177fa052512aa2b800dfc4e25e`.
TASK-XPA-019 / SPK-8 remain incomplete.

The App-facing DeviceList facade, candidate/history decoration models, bounded
read-only authorization wait, response decoder and UI fixture move from Workflows
to ClientKit. ClientKit retains only its existing Core package dependency.
The Devices SwiftUI surface imports ClientKit instead of Workflows; the other
consumers explicitly import the actual model owner. There is no re-export shim.

The only Provider-owned exposed type was HDCAuthorizationState. A display-only
DeviceAuthorizationPresentation keeps its seven case shapes, without importing
Provider retry policy or HDC execution. This enum is not Runtime authorization.
The existing HDC diagnostics facade still consumes the shared read transport via
package access and remains in Workflows; none of its execution behavior moves.

A normalized comparison of the complete production facade against main is
identical after accounting for imports, the presentation enum name and package
access for the existing shared read transport. The request remains
`device.observations`; this change does not adopt, submit, cancel or manage HDC.
No transport allowlist or standalone Rust availability claim changes.

Five existing decode, stale-state, target-fact binding, bounded wait and closed
surface tests move into the independent Core/ClientKit test target. The closed
surface test additionally checks forbidden imports and the Devices App import.
Runtime owner integration tests remain in ArkDeckContractTests with an explicit
ClientKit import. The History architecture source lookup follows the new file.

Completed: static dependency review, normalized production comparison and diff
whitespace check. Compilation/tests intentionally await the coordinated build
window. Planned focused suite: ArkDeckClientKitTests, DeviceCandidatesContractTests,
HDCRuntimeDiagnosticsProjectionContractTests, RuntimeHistoryApplicationContractTests,
ArchitectureBoundaryContractTests and affected candidate-model consumers.
The final unified entry must also build the App for testing. Signed standalone
Rust UI acceptance, installed activation and physical-device acceptance are not
claimed by this extraction.
