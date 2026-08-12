# ArkDeck v0.5 visual references

These images pin the adopted-device detail at the design reference size, 1180×760:

- `device-detail-zh-Hans.jpg`
- `device-detail-en.jpg`

They are generated from `docs/design/prototype.html?reference=1&lang=<locale>` with the
ready device's context menu open. All values are explicitly prototype data. The images
are layout and copy references, not Runtime output or hardware evidence.

Product UI regression remains structural: `AppShellUITests` checks the default window
geometry, single-title hierarchy, adaptive device columns, compact Exact Plan table, and
attaches fresh localized window screenshots. It deliberately does not pixel-compare
system accent, materials, font rasterization, or other macOS-owned rendering.
