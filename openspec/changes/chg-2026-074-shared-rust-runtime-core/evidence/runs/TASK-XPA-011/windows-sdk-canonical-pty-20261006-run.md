# Windows SDK signer canonical-path ConPTY repair

Date: 2026-10-06. Base: protected main
`cfef5f7ec914c4cb5d493348f7c85a11925b78eb`.

The live acceptance coordinator reported the SDK release-profile signer failing
before its password exchange; the previous unavailable credential owner remained
unchanged and no replacement was published. The SDK toolchain itself was already
installed. A separate SHA-pinned host-only Java probe then compared the original ConPTY
launch with path-only and console-flag-only controls. The original Java version,
signer JAR help and fixed no-secret ConsoleProbe all exited 1. Lowering only the
eligible image and cwd to their ordinary Win32 spellings made all three exit 0;
version/help markers were seen and Java's console was available. Console flags
alone still exited 1. The combined control's harmless public output escaped to
the parent and reported console absence, so its capture is incomplete and its
flags are not used. No signing or hardware pass is claimed by those probes.

ConPTY now reuses the existing tool-runner spelling conversion for its child
image and requested cwd. A caller still supplies an existing canonical cwd; the
conversion preserves the exact canonical object. Ineligible spellings retain
the verbatim path. Executable retention/revalidation, suspended child-image
canonical/native identity proof, no handle inheritance, original console flags,
clean environment, kill-on-close Job and secret/echo/prompt bounds are unchanged.
The shared attached launch also serves persistent shell clients.

The Windows PTY regression starts a real fixture child with canonical inputs,
checks its actual argv[0] and current-directory ordinary spellings before both
password prompts, verifies the parent cwd did not change, and refuses an ordinary
caller cwd before a marker child can run. Its password values are fixed fixture
constants; it uses no Java signer, credential or device. The external helper's
separate canonical caller-cwd repair is frozen as utility `411acfa2…bef54`, built
against the old platform; it must be rebuilt after this fix is protected main
before any actual signing.

## Local targeted checks

Checks run from the isolated `rc-smoke-path` source using `rust/scripts/run-cargo.py`,
stable owner `signing-readiness`, fixed cache `D:/cargo-target/rc-smoke-path`,
runner locking and jobs 2. Heavy checks use `tools/gate_slot.py`; the actual
Runtime remains stopped. Logs are local under
`D:/src/ArkDeck-wt/tools/windows-sdk-canonical-pty/checks/`.

The clippy selection is `arkdeck-platform` and its ten direct consumers:
`arkdeck-provider-workspace`, `arkdeck-provider-hdc`, `arkdeck-soak`,
`arkdeck-rockchip-binding`, `arkdeck-hoststore`, `arkdeck-provider-arkforge`,
`arkdeck-bootstrap`, `arkdeck-agentd`, `arkdeck-client`, `arkdeck-cli`. Each is a
separate `-p` argument; the consumer test selection is the same without platform.

| Command | Result | Log |
| --- | --- | --- |
| `python rust/scripts/run-cargo.py fmt --all` | exit 1; Windows native argument-length error 206 before formatting | `fmt.log` |
| `python rust/scripts/run-cargo.py fmt -p arkdeck-platform` | exit 0 | `fmt-platform.log` |
| `python rust/scripts/run-cargo.py fmt --all --check` | exit 1; same error 206 | `fmt-all-check.log` |
| `python rust/scripts/run-cargo.py fmt -p arkdeck-platform --check` | exit 0 | `fmt-platform-check.log` |
| `python rust/scripts/run-cargo.py clippy --offline -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-provider-hdc -p arkdeck-soak -p arkdeck-rockchip-binding -p arkdeck-hoststore -p arkdeck-provider-arkforge -p arkdeck-bootstrap -p arkdeck-agentd -p arkdeck-client -p arkdeck-cli --all-targets -- -D warnings` | exit 0 | `clippy-platform-consumers.log` |
| `python rust/scripts/run-cargo.py build --offline -p arkdeck-cli` | exit 0; built before process tests | `build-cli.log` |
| `python rust/scripts/run-cargo.py test --offline -p arkdeck-platform -- --test-threads=2` | exit 0; includes all 10 PTY and 8 shell-channel cases | `test-platform.log` |
| `python rust/scripts/run-cargo.py test --offline -p arkdeck-provider-workspace -p arkdeck-provider-hdc -p arkdeck-soak -p arkdeck-rockchip-binding -p arkdeck-hoststore -p arkdeck-provider-arkforge -p arkdeck-bootstrap -p arkdeck-agentd -p arkdeck-client -p arkdeck-cli -- --test-threads=2` | exit 0 | `test-direct-consumers.log` |
| `python rust/scripts/run-cargo.py exec -- python D:/src/ArkDeck-wt/tools/windows-sdk-canonical-pty/check_workspace_format.py` | exit 0; `cargo fmt -p <member> --check` for all 13 workspace members | `fmt-workspace-distributed.log` |
| Git Bash `sh scripts/check-sdd.sh` | exit 0; 0 errors/warnings | `sdd-check.log` |
| `git diff --check` | exit 0 | `diff-check.log` |

The original full-format failures remain saved. The per-crate check supplies
the same workspace-member formatting coverage without one overlong rustfmt argv;
no formatter policy or source assertion was waived. Only explanatory comments
changed after the semantic tests, then the complete distributed format check
passed. The fresh cache and full direct-consumer compile/tests took longer than
the ten-minute target; that cache/owner is retained for subsequent tasks.

All inherited `ARKDECK_` and `OHOS_HDC_` inputs were removed before adding only
the runner controls. Live HDC/DevEco/signing opt-ins and the development signer
thumbprint were absent; tests gated on those prerequisites were disabled. These
checks use task-owned fixtures and supply no official SDK signing or real-device
evidence. No contract input or generated file changed, so generator checks are
not needed. Swift/App checks remain normal selected CI lanes for this Windows
Rust implementation increment.

## CI

Not yet pushed or run for this increment. Local checks and the host-only probe
do not constitute current-head CI success, maintainer approval or hardware
acceptance. Protected-main RC rebuild and official SDK/signing verification
remain coordinator work after publication.
