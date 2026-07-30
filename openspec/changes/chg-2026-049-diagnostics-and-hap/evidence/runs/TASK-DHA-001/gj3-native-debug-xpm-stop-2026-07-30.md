# GJ-3 Native Debug — DAYU200 XPM stop (2026-07-30)

## Scope and target

- Catalog digest:
  `1ee1c1a68486f45f8406fd362770655eb9d5dc983e1da27a87235d95eeb01a94`
- Target: `TGT-958780b2ffb7`, binding revision `1`
- Stable identity SHA-256:
  `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Executor: Device Runtime Agent. Manual HDC commands: `0`.

## Real-device result

ArkDeck imported and host-validated an AArch64 ELF Artifact, bound its lease
to the target identity and binding, transferred it to the stable job-owned
staging directory, verified the remote hash, backed up the installed library,
published atomically, restarted the target application, and performed
hash/process/maps readback.

The final signed candidate was:

- Artifact:
  `ART-4b5727b231b69bf0bb971d1ef68a7e56`
- SHA-256:
  `ed39872d321043d77e438e4c5d7f3efcebe3b5ab344595db500983eebafffe03`
- Runtime Job:
  `job-1877a7482c86b0c012120903c7cfd173`

OpenHarmony rejected the published candidate with an executable-format
failure because XPM/fs-verity code signing had not been enabled for the
new file. A typed diagnostic capture
(`job-35e6560849011a5df4d2c04fb8c18c50`,
HiLog Artifact `ART-9b2ee629755373b7226336c251242522`) additionally confirmed
that the target application namespace cannot load the private
`libcode_sign_utils.z.so` enablement library.

The Job failed closed, automatically restored the previous library, restarted
the application, and proved the original library was loaded again.
`outcomeUnknown=false`; no mutation was automatically resent.

## Product correction and recovery result

Production `operation.list` now reports
`deploy.native-library.app-owned@1` as `unavailable` with the XPM/fs-verity
reason. A final real-target submit at `2026-07-30T13:24:20Z` was rejected
before Provider dispatch and before capability consumption:

- terminal state: `rejected`
- step kinds: empty
- artifacts: empty
- human actions: empty
- `outcomeUnknown=false`
- automatic E1 envelope consumption remained `3`; remaining uses remained
  `9997`

After rebuilding and restarting `arkdeck-agentd` against the same durable
state directory, `cleanupDebt.continue` rehydrated the persisted exact typed
actions, performed descriptor-bound readback, and settled both current and
legacy provider-owned paths. The final `cleanupDebt.list` result was empty.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter NativeLibraryDeploymentContractTests
```

Result: 8 tests passed. Coverage includes ELF/ABI/Build ID validation,
descriptor-bound argv, stable native paths, publish/readback/rollback,
outcome-unknown no-resend, exact-action restart recovery, cleanup debt
continuation, legacy closed-path rehydration, and pre-capability Runtime
Availability rejection.

After rebasing onto `main@4ae7798e`:

```text
CI=true swift test --package-path Packages/ArkDeckKit
bash scripts/check-sdd.sh
```

Both commands exited `0`; `check-sdd` reported `0 error(s), 0 warning(s)` and
the unchanged `114` acceptance IDs.

## Golden Journey conclusion

GJ-3 is `BLOCKED_BY_PRODUCT_DEFECT`, not `REAL_DEVICE_PASS`.
The single blocker is a production materializer that can enable OpenHarmony
XPM/fs-verity code signing for the exact published app-owned native library.
Until that exists, the operation stays unavailable and consumes no E1
capability.
