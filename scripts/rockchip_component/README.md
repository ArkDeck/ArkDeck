# Rockchip bundled component build

This directory implements `TASK-BRC-002`'s unsigned, source-pinned build. It is not
a general command runner and it never launches the produced `rkdeveloptool`.

The recipe:

- fetches only the four URLs pinned in
  `openspec/integrations/rockchip/bundled-component/1.0.0/recipe.json`;
- verifies exact size/SHA-256 and the libusb detached signature before extraction;
- rejects unsafe archive members and extracts into a fresh temporary root;
- builds with the exact macOS/Xcode/SDK/Clang envelope inside a deny-network
  `sandbox-exec` profile;
- compares two independent build roots without output normalization;
- emits sanitized receipts plus deterministic registry, SPDX 2.3 JSON, notices and
  source-distribution metadata.

No source archive, unsigned executable, build root, cache, absolute user path,
credential or GPG keyring is committed.

## Commands

```text
/usr/bin/python3 scripts/rockchip_component/test_build.py

/usr/bin/python3 scripts/rockchip_component/build.py build \
  --builder-id builder-a \
  --work-root /private/tmp/arkdeck-brc002-builder-a \
  --output-dir /private/tmp/arkdeck-brc002-output-a

/usr/bin/python3 scripts/rockchip_component/build.py compare \
  --builder-a /private/tmp/arkdeck-brc002-output-a \
  --builder-b /private/tmp/arkdeck-brc002-output-b \
  --output /private/tmp/arkdeck-brc002-reproducibility.json

/usr/bin/python3 scripts/rockchip_component/build.py materialize \
  --reference /private/tmp/arkdeck-brc002-output-a
```

`build` creates and owns the specified fresh roots. Existing non-empty roots fail
closed. Network is allowed only while fetching the pinned inputs; configure,
compilation, linking and inspection run without network. The binary remains in the
temporary output directory and is inspected as data only.
