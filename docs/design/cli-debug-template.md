# Debug command templates

Task: TASK-AIN-021 (delivered with `CHG-2026-073-debug-template-operation`)

`arkdeck debug template list` and `arkdeck debug template run` give the closed
read-only Debug command templates a CLI surface that satisfies the product
spec's rule for device workflows: a user-selected template is executed only
through a published Catalog operation and the Runtime Job path, never by a
direct daemon method.

`debug.template@1` is the operation. Its single input `templateId` is an enum
of the closed set (`device.packageInventory`, `device.debugParameterRead`,
`device.windowInventory`, `device.uptime`). The HDC provider owns the remote
command tokens, the per-template stdout budget and the 30-second timeout;
`DebugRuntimeCommandTemplate` is the one table that the provider, the legacy
direct probe and the CLI listing all read, so the three cannot drift. The
operation is `readOnly`, `defaultReadOnly`, bound to the confirmed device, and
confirms the binding identity against the live device before the template
step. It is deliberately not evidence-eligible: the execution kernel names no
new operation, and a caller who needs model/firmware facts runs
`target observe`. It publishes two required Artifacts: `template-output.txt`,
the raw stdout marked `sensitive`, and `template-report.json`, a standard
derived report with the template identity, the disclosed remote command, exit
status, duration, byte counts and the Catalog digest. The connect key never
appears in either.

A truncated answer, a non-zero exit or an HDC transport/authorization marker
fails the step and publishes no output under the template's name. An identity
outside the enum is refused at admission before any dispatch. Re-observation
is safe, so an unknown outcome reconciles as not executed.

`debug template list` is a local projection: it reads the closed table,
checks it against the published descriptor's enum and prints, for each
template, its identity, title, effect, remote command disclosure (tokens after
the connect-key selector), output byte budget and the exact `inputs` object to
pass to `debug template run --inputs-file`. It opens no control connection and
reports the Catalog digest it was built from. `debug template run` is the
generic domain leaf for `debug.template@1`: `--target`, `--inputs-file`,
`--capability` and `--execution-id`, with the typed inputs coming from
`operation describe` rather than from hand-copied flags.

The legacy `debug.template.run` control method remains for the App's Debug
workspace and Overview capability matrix; the CLI never calls it. Migrating
those App paths onto the Job operation is a separate change.

The contract fixtures cover registry and parser shape, a real `arkdeck`
subprocess listing, and a scripted engine run: admission of the enum, the
exact lowered argv and budget, both Artifacts and their privacy, the report
fields, the refusal of a non-zero exit, and durable persistence of the typed
action. No device was connected; these tests do not claim real-device
acceptance.
