# TASK-XPA-010 — the Flash listing readers on the registered Windows HDC tuple

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2 (GJ-4 Flash), part 1.
Stacked on TASK-XPA-005's adoption layer (`windows-hdc-adoption-run.md`, PR #2486), which reads
the registered Windows tuple (CHG-2026-078, c2) by its own grammars for the candidate list, the
identity readback and `observe.device`, and left the Flash listing readers on the macOS grammar.
Host: the Windows 11 x64 reference host, non-elevated. No device was contacted and no `hdc` ran.
Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `arkdeck-provider-hdc` `live_mode` | The live probe's `hdc list targets -v` is read with `parse_host_target_list` at the version of the tuple the dispatch is pinned to (`HdcDispatch::registered_windows_tuple`), else Swift's `3.2.0f`. Under a Windows tuple a zero-byte list is not observable ("HDC target list is empty, which the registered Windows family never is"), never "not on HDC": the registry records zero bytes as never observed on Windows. |
| `arkdeck-provider-hdc` `rockchip_hdc` | `wait_for_hdc` and `wait_for_bound_hdc` read their polls the same way. An empty or unregistered read keeps polling and never proves a reconnect or a disconnect, as before. |

macOS dispatches name no Windows tuple, so their grammar, wording and bytes are unchanged.

## Tests on Windows

- `live_mode` (Windows-only unit tests over the c2 captures of #2472): the connected capture is
  `hdc` mode with its build and port; the removed (`Offline` row) and no-board (UART rows only)
  captures leave the mode to the Loader observer; the macOS five-column family, `[Empty]`, a UART
  row outside the sampled form, a sixth column other than `hdc` and zero bytes are not
  observable; an unpinned dispatch keeps the macOS family.
- `rockchip_hdc` `wait_for_hdc`: the connected capture proves a reconnect; the removed and
  no-board captures prove a disconnect; zero bytes, `[Empty]` and the macOS family never prove
  either before the deadline; an unpinned dispatch keeps the macOS family.

## Coverage

No leaf changes status: the Flash lane on the Windows daemon is part 2 of this slice.

## Local checks

See the commit message.
