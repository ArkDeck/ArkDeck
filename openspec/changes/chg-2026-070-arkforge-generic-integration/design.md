# Design — CHG-2026-070

## 1. One operation identity normalizer

`ArkForgeFlashOperation` in Core is the only operation-identity policy:

```swift
canonical = "flash.full-restore@1"
aliases = ["flash.dayu200"]
```

It answers whether a reference belongs to the family and returns the canonical
reference. Runtime consumers use it instead of string-prefix or literal checks.
The durable record retains the submitted reference; canonicalization selects
the implementation but does not rewrite history.

## 2. Catalog and adapter

The new operation has provider `arkforge`, the same reviewed step/effect ceiling
and complete-overwrite contract as the current operation, with generic inputs.
The compatibility descriptor declares `aliasFor: flash.full-restore@1` and is
also provider `arkforge`.

Provider registration contains one `ArkForgeFlashProviderAdapter`. It owns the
ArkForge lane handoff and delegates only typed managed-control requests back to
the existing host port. There is no second `RockchipFlashProviderAdapter`
lowering for the alias. Rockchip action vocabulary remains internal to managed
control and old durable-record decoding.

## 3. Swift SDK boundary

The ArkForge repository publishes a Swift package with two products:

- `ArkForgeProtocol`: protobuf framing/messages and deterministic codecs;
- `ArkForgeClient`: typed public and controller clients over a local endpoint.

It may depend on Foundation/Darwin (and WinSDK when Windows Swift is added), but
not on ArkDeck modules. It cannot mint permits or choose acknowledgements,
providers, profiles, target bindings or recovery classifications.

ArkDeck deletes its duplicate codec target after the package is consumed. The
existing cross-language golden frames remain byte-identical and move to SDK
contract tests plus a small ArkDeck integration set.

## 4. Single bundle configuration

`ARKDECK_ARKFORGE_BUNDLE_PATH` replaces the three lane-identity variables. The
reader resolves only manifest-declared relative members below the canonical
bundle root, then independently measures every file. A manifest digest is
recorded in the LaunchAgent receipt; the daemon digest remains the toolchain
identity used by plan admission.

Legacy three-key LaunchAgent receipts are read for one migration cycle and are
rewritten to the bundle form only when all three files resolve to the same
validated installed bundle. Partial or cross-bundle migration refuses.

## 5. Ordering

1. ArkForge publishes and tests the Swift SDK and bundle-manifest reader/writer.
2. ArkDeck consumes the pinned SDK and switches LaunchAgent composition to one
   bundle in TASK-AFG-001.
3. After CHG-2026-069 is merged and its digest window closed, generate the new
   operation descriptors and Core identity normalizer.
4. Add the generic adapter and switch all new App submissions.
5. Run alias parity, history/recovery and real-device cutover acceptance.

The catalog tasks are intentionally serial; generated catalog changes cannot
be rebased by accepting conflict markers or regenerating over an unreviewed
digest.
