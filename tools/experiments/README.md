# Experiments

These trees are off the product layout. CI still executes the two Python
packages. The Windows spike is kept because Dependabot tracks its NuGet
manifest; the WinUI client does not build it.

| Path | Why it is still here |
| --- | --- |
| `host_loop/` | SDD Guard and the Linux pool guard smoke discover this package |
| `gj_record/` | SDD Guard discovers this package. It judges Golden Journey records |
| `windows-spikes/` | Former `windows/spikes`. Dependabot directory `/tools/experiments/windows-spikes/spk4` |

One-off capture directories that nothing in `.github/workflows` or product
code imported were removed: `m0b_capture`, `ud_capture`, `manual_ui_flash`,
`archive_characterization`, `ui_dump_diagnosis`, `partition_decode`, and
`trace_capture`.
