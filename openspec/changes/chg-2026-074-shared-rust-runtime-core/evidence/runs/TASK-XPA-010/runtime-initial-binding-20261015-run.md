# Runtime-owned initial DAYU200 binding

The installed Windows Runtime refused the selected revision-1 HDC-normal target with
`durable Rockchip binding is not installed`. The legacy `flash install-binding` leaf writes
the binding in the CLI process, whereas `flash bind-loader` previously required that document
to exist. No device operation was dispatched by this diagnostic.

The existing Runtime binding owner now installs an absent binding for the exact adopted
revision-1 HDC-normal target. It obtains the serial, topology and attachment identity from
two matching Runtime census reads, rechecks the unique target and its direct HDC key, then
publishes through the existing exclusive binding store and validates readback. The caller
still supplies only the target reference and expected revision. Loader bootstrap, advanced
targets, aliases, ambiguous or changed observations, and incomplete existing attestations
remain refused. A concurrent different document is preserved; an exact retry is idempotent.

Compatibility note: this moves the existing normal-mode bootstrap into the Runtime owner,
with narrower prerequisites, under POL-AGENT-002. It adds no operation, provider, profile,
capability input, recovery classification or destructive dispatch path. Catalog and control
schemas are unchanged. No hardware pass or platform qualification is claimed.

Local targeted checks: the official Cargo runner used the session's fixed cache and two build
jobs. The Windows batched equivalent of `cargo fmt --all --check` covered all 356 target roots
(exit 0). `cargo clippy --locked --workspace --all-targets -- -D warnings` exited 0.
`cargo test -p arkdeck-hoststore --lib loader_binding::initial_tests` passed four tests covering
successful installation/retry and 12 refusal variants; `--test loader_binding_jobs` passed two
tests; `cargo test -p arkdeck-agentd --bin arkdeck-agentd loader_binding` passed all three
existing oracle tests without fixture changes. The CLI `loader_binding` target exited 0 but
contains zero tests on Windows. Logs are retained locally under
`arkdeck-initial-binding-checks/{fmt,clippy,binding,binding-jobs,binding-oracle,cli-binding}.log`.
`sh scripts/check-sdd.sh` exited 0 with no errors or warnings
(`arkdeck-initial-binding-sdd.log`); `git diff --check` exited 0.

CI: pending this layer's PR. The parent Windows CI exposed the separate Git 2.56 installation
layout incompatibility; its repair is being synchronized from the bottom of the stack before
this layer is published. Local fake observations establish software behavior only.
