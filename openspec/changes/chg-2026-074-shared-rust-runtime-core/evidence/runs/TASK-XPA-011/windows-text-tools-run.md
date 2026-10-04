# TASK-XPA-011 — Windows code-owned grep, sed and patch (WM3 GJ-5, PR 3), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5, third PR. It implements the maintainer's ruling of
  2026-10-04 for the code-owned text tools: grep, sed and patch are reimplemented in Rust for
  exactly the argv the workspace provider builds, and they answer as the macOS tools answer.
  The PR also reshapes the code-owned tool table so that the trusted system tools (tar = System32
  `tar.exe`, git = Git for Windows; another agent's PR) plug into two named slots.
- Base: one commit on `origin/main` (see the PR head).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated. Nothing was
  installed, elevated or reconfigured. No board, `hdc`, DevEco, keystore or credential was used.

## What changed

| Area | Change |
| --- | --- |
| `arkdeck-hoststore` `workspace_text_tools.rs` (new) | `grep -r -n --include <glob> -- <pattern> <root>`: the root is walked in name order without following links, the glob is matched with `fnmatch`, the pattern is a POSIX BRE (literal bytes, `.`, brackets with classes, `*`, `^`, `$`; groups, intervals and back references are refused), output lines are `<path>:<n>:<line>`, and a file with a NUL in its first 32 KiB prints `Binary file … matches` once. `sed -n <a>,<b>p <file>`: lines `a` to `b`, only `a` when `b < a`, a missing final newline supplied; a missing file gives `sed: <file>: No such file or directory` and exit 1. `patch -f [-R] -p1 -d <root> -i <file>`: BSD patch's Plan A for unified diffs (exact line, then growing offsets after/before, then fuzz 1–2), BSD narration, a missing final newline kept, and for a hunk that does not apply its reject in BSD's unified form (`@@ -a,b +c,d @@`, both counts spelled out), a `.orig` backup of the original and exit 1. Any other argv is refused before anything is read |
| `arkdeck-agentd` `main.rs` | `--workspace-tool <grep\|sed\|patch> <argv>` (Windows): the daemon image is each tool, answered before any composition |
| `workspace_profile.rs` | `CodeOwnedTools { inspection, reader, patch, archive, source_control }` is the role table, documented with the macOS and Windows rows. On Windows the three text roles are the daemon's own image with `--workspace-tool <tool>`, pinned by digest. `external_tools(root)` holds the `archive`/`source_control` slots, which still refuse until the trusted system tools are composed, so a project still resolves to no profile, now with the reason `no trusted system archive (tar) or source-control (git) tool is composed on Windows yet`. `ark_deck` on Windows answers macOS's own SwiftPM-absent reason |

macOS behaviour and bytes are unchanged. The macOS table rows build the same presets from the
same fixed paths, and the text tools module is used on macOS only by tests.

## Proof against the macOS tools

| Check | Result |
| --- | --- |
| `workspace_text_tools_oracle`, the recorded read oracle | The reimplemented `grep -r -n --include '*.ets' -- build <root>` prints the recorded `/usr/bin/grep` artifact (`Index.ets:4:  build() {}`) with this host's root spelling. `NoSuchSymbol` prints the recorded empty artifact with exit 1. `sed -n 2,4p` prints the recorded `/usr/bin/sed` artifact byte for byte. The missing file fails the read, as the recorded Job did |
| `workspace_text_tools_oracle`, the recorded patch oracle | After the recorded unified diffs (old→new applied, stale→newer failing against `new`), the tree is `workspace-patch-oracle/tree.json` digest for digest: `App.txt`, `App.txt.orig`, the reject `App.txt.rej` (`e3e2501f…`, the BSD `@@ -1,1 +1,1 @@` form) and `Other.txt`. The applied diff then reverses cleanly |
| `workspace_text_tools_oracle`, macOS only (runs on the macOS CI lane) | The host's `/usr/bin/grep`, `sed` and `patch`, run in the oracles' closed environment, must answer 14 corpus cases exactly as the reimplementation does: exit status, stdout, stderr and the files after. The cases cover ranges, a reversed range, past the end, a missing final newline, a missing file, a match, a BRE and no match, a clean git diff, an offset, fuzz, an already applied patch, a reverse, and two files with a missing newline. Not run on this Windows host; CI's macOS lane runs it |
| `windows_workspace_provider_process` `the_daemon_image_is_the_code_owned_grep_sed_and_patch` | The built daemon run as each tool, with no environment and no stdin, answers exactly as the reimplementation (status, stdout, stderr), and its patch is applied in place. An unknown tool exits 2 |
| `workspace_text_tools` unit tests | sed, grep walk/glob/binary, the BRE matcher, and patch apply/reverse/offset/reject/missing newline |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| cross-check `cargo clippy -D warnings --workspace --all-targets` for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed `xcrun`/`ar`/`cc`) | exit 0, exit 0 |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | 267 `test result: ok`, 0 failed; only the two known wildcard-listener `SKIPPED` lines |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | 267 `test result: ok`, 0 failed |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |

## Delegated minor decisions, pending the next rulings batch

1. **"In-process" means the daemon's own image.** The workspace dispatch runs the daemon as a
   child (`--workspace-tool`), as it already runs the analyzers and the symbolizer. This keeps
   the plan's executable digest, the process bound, the timeout and the receipt. No external
   binary is trusted.
2. **grep's walk order.** grep walks directories in byte order of their names. The macOS walk
   follows the file system's order, so a multi-file answer is compared as a set in the macOS
   corpus (the corpus cases match one file).
3. **grep's pattern language** is POSIX BRE without groups, intervals or back references, which
   are refused (exit 2). The workspace inspection's symbol is the pattern.

## Left out, and why

- **The tar and git slots** (`external_tools`): another agent's PR provides `trusted_system`.
  Profiles resolve once it is wired; the next PR of this slice does that and covers the reads,
  the isolated copy, patching and checkpoints end to end.
- **Anything device-bound.** The Windows HDC tuple is not registered.
