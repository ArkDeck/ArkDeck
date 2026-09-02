# Debug logs preset

Task: TASK-AIN-021 (delivered with `CHG-2026-073-debug-template-operation`)

`arkdeck debug logs` captures one bounded HiLog window. It publishes no new
operation: it is the HiLog-only typed preset of `capture.diagnostics@1`, the
same request the App's Debug workspace submits, and both now read one owner,
`DiagnosticCapturePreset.logs(durationSeconds:filters:)`.

The leaf is a generic domain leaf bound to `capture.diagnostics@1`, so it
takes `--target`, `--inputs-file`, `--capability` and `--execution-id` and no
hand-copied flags. The inputs file may carry only `durationSeconds` (1...600
seconds) and an optional `hilogFilters` array of at most 16 typed component
filters, each at most 200 characters drawn from letters, digits, dot,
underscore, colon and hyphen. Every other diagnostics leg (UI dump, component
tree, screenshot, crash logs, trace) is fixed off by the preset, so the
effective effect stays read-only under the default read-only policy. Any other
field, an out-of-range window or a filter that could read as a shell fragment
is refused on the client before a control connection is opened.

The Job publishes `hilog.txt` (raw, sensitive) plus the capture index and
summary that every diagnostics capture publishes; `job result`, `artifact
read --allow-sensitive` and `analyze hilog-summary` consume it like any other
diagnostics run. Callers who need HiLog together with other legs use
`diagnostics capture` or the generic `agent run --operation
capture.diagnostics@1` with descriptor-validated inputs.

The contract fixtures cover the projection equality with the shared preset,
the closed input set, the bounds and filter refusals, and the registry and
parser shape. No device was connected; these tests do not claim real-device
acceptance.
