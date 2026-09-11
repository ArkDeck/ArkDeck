# HDC capture primitive and native Swift readback — 2026-09-11

The platform `BootstrapToolCapture` owns a single newly created
`.tool-staging-<random>` directory under a held, identity-checked Bootstrap root.
Its capture callback reads retained file descriptors through the hoststore's
existing bounded Mach-O parser. The only copied roles are `hdc` and its optional
fixed sibling `libusb_shared.dylib`. Aggregate content is bounded to 256 MiB,
the library to 32 MiB and quarantine xattrs to 16 KiB. Source and copied bytes,
quarantine and descriptor/name identities are revalidated around native
inspection and before publication. No executable is launched.

Publication uses `RENAME_EXCL` to `tool-<digest>.hdc`, followed by directory
fsync. An existing file, directory or symlink is never replaced. The owner must
verify an existing destination. Failures after a successful rename report an
uncertain outcome and retain published content. Cleanup is limited to this
object's exact newly created staging inode and file inodes. Replaced entries,
unknown members or a replaced parent binding leave the stage untouched. There
is no general directory-removal API and no Session or existing retained-content
deletion.

The platform-focused tests passed:

- 7 integration tests: actual native `/usr/bin/true` bytes and signatures,
  unchanged quarantine copying, duplicate immutable publication, changed source,
  unsafe links/types/size, changed xattrs, replaced registry bindings and
  untouched pre-existing/foreign destination or staging entries.
- 1 private publication-interruption test: failure before rename cleans only
  its stage; failure after rename returns `OutcomeUnknown` and retains content.
- Platform all-target Clippy with `-D warnings`, rustfmt check and diff check.

The first sandboxed native signature check was denied by Security.framework;
the unchanged native test passed with normal host trust-service access. No
signature check or assertion was substituted. The final integration log is
`/private/tmp/xpa012-hdc-capture-tests.log`.

## Actual HDC and USB producer

The hoststore owner separately registered the existing native HDC plus its real
USB dependency into a fresh temporary registry without executing either file.
The actual producer result is the `nativeHDCRegistration=` line in
`/private/tmp/xpa012-hdc-registration-native-source.log`.
The readback input below is that entire JSON line with only the logging prefix
removed and a trailing newline retained; no JSON field was reconstructed:

`/private/tmp/xpa012-hdc-rust-native-registration-receipt.json`, SHA-256
`656c2c3f670e015533e1737075cb18a4fa0abb74065e0696fb3a01727e3741c4`.

The producer's existing Bootstrap root is
`/private/var/folders/kq/6vwvyjds2nx0tc3g0xt_19br0000gn/T/hdc-registration-a64284818d8942feeca930046eb4f883`.
Its reference is
`tool:sha256:adcf3a3c1fa05fdee3ca2523986bfcc128e8a2106c1ece3b7e018f81b6370f35`.

## Frozen Swift readback

`BootstrapInspectionControlContractTests.testExplicitRustHDCRegistryMatchesNativeSwiftReadbackWithoutWrites`
requires three explicit opt-in variables. Without them it skips and never
creates registry input. It calls the real Swift `BootstrapToolRegistry.inspect`
with `existingStoreOnly: true` and the production
`HeadlessHDCBootstrapIdentity.lookup` diagnostic composition. Native trust uses
the owner's actual Security.framework implementation. The actual Swift JSON
must equal the actual Rust producer's complete `result` object, including the
USB dependency and published-identity diagnostic fields.

The test compares recursive member names, byte SHA-256, device/inode, mode,
uid/gid, link count, size, mtime and ctime nanoseconds before and after reading.
The supplied `.lock`, `bundles.json`, `tools.json` and copied content must
already exist. No registration, selection, repair, default installed-registry
access or deletion of supplied data occurs.

```sh
ARKDECK_HDC_RUST_REGISTRY_ROOT=/private/var/folders/kq/6vwvyjds2nx0tc3g0xt_19br0000gn/T/hdc-registration-a64284818d8942feeca930046eb4f883 \
ARKDECK_HDC_RUST_TOOL_REFERENCE=tool:sha256:adcf3a3c1fa05fdee3ca2523986bfcc128e8a2106c1ece3b7e018f81b6370f35 \
ARKDECK_HDC_RUST_RECEIPT_PATH=/private/tmp/xpa012-hdc-rust-native-registration-receipt.json \
  sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test \
  --filter BootstrapInspectionControlContractTests.testExplicitRustHDCRegistryMatchesNativeSwiftReadbackWithoutWrites
```

The actual Swift readback passed on 2026-09-11: 1 test, 0 failures, 0 skips
(0.032 seconds). Its complete result matched the actual Rust receipt, including
the USB dependency, HDC version `3.2.0f` and published-identity diagnostic. All
recursive metadata and byte comparisons passed, and the dispatcher count was
zero. The log is `/private/tmp/xpa012-hdc-rust-swift-readback.log`, SHA-256
`874cd636322344567b35fecccca07ebf2796e91bdf8d323c8a3c8b7a6004e174`.

An initial attempt stopped in the test's temporary-path guard before invoking
the owner because Foundation resolves `/private/var` as `/var`. The guard now
normalizes the system aliases `/tmp`, `/var` and `/etc` to their physical
`/private` forms, matching the existing Bootstrap path handling. No production
owner, native trust behavior or readback assertion was weakened.

This is independent capture and registration library evidence. Runtime RPC/CLI
integration and the complete TASK-XPA-012 cutover remain pending. The parent
integration owns the final unified gate; this record does not mark the task
complete or provide device acceptance.

Final integration: the required selected unified gate passed on `b315f371`.
See [the registration phase run record](hdc-register-run.md) for the full log
and exact integration boundary.
