# Local Rockchip development App

`rkdeveloptool` is a C++ program: the pinned source set contains eight `.cpp`
translation units. Both this local development path and the reproducible GitHub
two-builder release recipe pin rkdeveloptool to C++23. The selected Xcode
toolchain must accept the pinned standards before compilation begins:

- C23 for the statically linked libusb dependency;
- C++23 for rkdeveloptool itself.

Build a fresh local Debug App, including matching locally generated component
metadata, with one command:

```text
/usr/bin/python3 scripts/rockchip_component/local_app.py
```

The command verifies the same source sizes/SHA-256 values and libusb signature,
then denies network access during configure, compilation, linking, and inspection.
It stages the child with its fixed identifier, passes the child and local metadata
to Xcode through `ROCKCHIP_COMPONENT_INPUT` and
`ROCKCHIP_COMPONENT_METADATA_ROOT`, and verifies the resulting App bundle. The
fresh App and receipt are written under `.build/rockchip-local/`; the final path
is printed on success. Pass `--work-root <fresh-directory>` to choose another
output root.

Neither the build nor verification path launches ArkDeck, rkdeveloptool, HDC,
USB, or a device. This is intentionally not release evidence. The local child
uses an ad-hoc signature because no Developer ID credential is consumed. The
production Rockchip resolver therefore continues to reject it, preserving the
existing fail-closed destructive-operation boundary. The formal release packager
and its Developer ID/notarization gates are unchanged.
