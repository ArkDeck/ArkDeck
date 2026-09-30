# `spec/ui-semantics/` — shared UI semantics of the ArkDeck App

Language-neutral data the macOS and the Windows App both present (design
`docs/design/cross-platform/rust-core-cross-platform-architecture.md` §590: the Apps map
semantics to platform components and derive no state). Started by TASK-XPA-007 with the
surfaces of the Windows walking skeleton; later surfaces add their entries here.

| File | Contract | Consumers and gate |
| --- | --- | --- |
| `strings.json` | Bilingual strings (`en`, `zh-Hans`). An entry with a `table` is the macOS App's entry of the same key in `ArkDeckApp/Resources/<table>.xcstrings`, values unchanged; `table: null` marks a Windows-only surface (keys `windows.*`, e.g. the daemon-unavailable recovery banner, which has no macOS counterpart) | `windows/scripts/generate-ui-strings.py` writes `windows/App/Strings/{en-US,zh-Hans}/Resources.resw` and the key constants, and keeps the `.xcstrings` entries equal (`--check` fails on any drift in either direction); `windows/App.Tests` checks both again |
| `surfaces.json` | UI semantic snapshots: per page and daemon state, the elements found by stable identifier with their role, accessible name (catalogue keys, formatted in each language) and live-region setting. An identifier with `origin: macos` is the macOS App's accessibility identifier of the same element | `windows/App.UITests` compares the running Windows App's UIA tree against each snapshot in both languages (XPA-AC-8); `windows/App.Tests` checks every key and role it names |

Format placeholders stay in the macOS printf form (`%@`, `%d`, `%lld`, `%1$@`); each App
formats them. The macOS App still reads its `.xcstrings` directly; making those tables fully
generated from here is a later step and needs no value change.
