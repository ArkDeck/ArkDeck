# OpenHarmony native code-sign helper

This auditable, libc-only helper parses the bounded OpenHarmony V1 ELF
code-sign block and passes its existing signature to
`FS_IOC_ENABLE_CODE_SIGN`. It never creates or obtains a signature.
For publish, it copies the verified staging file beside the target, preserves
the target owner and mode, enables and reads back code signing, and only then
performs the atomic rename. A failed enable cannot replace the live library.

The checked-in arm64 resource is reproducibly built with the OpenHarmony SDK:

```sh
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang \
  -O2 -g0 -static -Wl,--build-id=sha1,--strip-all \
  -o Sources/ArkDeckWorkflows/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable \
  Tools/OpenHarmonyNativeCodeSignHelper/main.c
chmod 644 Sources/ArkDeckWorkflows/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable
```

The `chmod` is not optional. The linker leaves the file executable, the host
bundle must carry it as data, and SwiftPM copies the mode through — so skipping
it turns the resource executable on the host and
`testBundledCodeSignHelperIsAValidatedStaticArm64Executable` refuses the build.
The device copy is made executable by the typed send plan, not here.

ArkDeck validates the resource as an arm64 ELF and pins its build ID, SHA-256,
and byte count into every materialized and persisted deployment action. Static
linking is required because supported DAYU200 firmware does not expose the
SDK's `/lib/ld-musl-aarch64.so.1` interpreter to HDC-launched helpers.
