## Building with ArkDeck — design v1.6

> v1.6 current-surface audit: `docs/design/implementation-audit-2026-08-27.md`.
> Eight App destinations include Device and Diagnostics, not Automation; Settings has seven tabs.
> App JobInspector now reads exact Job details and standard log tails and requests bounded cancellation.
> Recovery rebind/archive controls remain unconnected; old Harness examples are retired (CHG-2026-064).
> Diagnostics reads saved bounded sessions with verified artifacts; interactive arm/append/stop is unavailable.
> Overview prepares new drafts only for validated read-only captures; no old authority or Session identity is reused.
> Local single-file and read-only SSH artifact import are implemented; SMB/WSL/batch/abc are not.

> Current design: **draft v1.6, 2026-08-27**. Authority order for design work is
> `docs/design/macos-ux-interaction-spec.md` → `docs/design/prototype.html` →
> `docs/design/arkdeck-ds` → `.design-sync/previews`. If a preview conflicts with
> the spec or prototype, the preview is stale. v0.9 keeps the v0.6 Flash and v0.8
> Viewer decisions, and makes artifact replacement the primary Debug workflow.

ArkDeck is a **macOS desktop workbench for OpenHarmony devices** — flashing firmware,
capturing traces, dumping UI trees, reading logs. Screens are dense, factual, and
mostly Chinese. The design language exists to make one thing legible: *what is about
to happen to a physical device I cannot see.*

### No provider — but do set a surface

There is no context provider, theme provider, or root wrapper you must mount. Every
component pins its own fonts and reads its colors from CSS custom properties on
`:root`, so `<Chip>` dropped anywhere renders correctly.

What you *should* do is give the page a surface, because the tokens define the ground
the components sit on:

```jsx
<div className="ad-root" style={{ minHeight: '100vh', padding: 24 }}>
  {/* your screen */}
</div>
```

`.ad-root` sets `background: var(--ad-ground)`, `color: var(--ad-ink)`, and the UI type
stack. Without it, cards float on the host page's background — usually white, which
works in light mode and looks broken in dark.

**Theme:** tokens follow the viewer's OS by default. Force one with `data-theme="dark"`
or `data-theme="light"` on `:root`. Both themes are fully specified — never hardcode a
hex value, or the page will only work in one of them.

### The styling idiom: tokens for your own layout, classes only via components

You do **not** hand-write `ad-` classes. They are internal to the components; compose
components and use the tokens for the glue between them.

Colors — semantic, and deliberately independent of the accent:

| Token | Use |
| --- | --- |
| `--ad-ground` / `--ad-panel` / `--ad-panel-2` | page ground / card surface / sidebar + inset surface. `--ad-panel-2` and `--ad-chrome` are **translucent** — put them over a real background, never over nothing. `--ad-panel-solid` is the opaque variant for popovers and anything that must not show through. |
| `--ad-ink` / `--ad-ink-2` / `--ad-ink-3` | primary text / labels and secondary text / tertiary, placeholder |
| `--ad-line` | every 1px border and divider (translucent — it tints, it doesn't paint) |
| `--ad-accent` | selected & interactive **only** — never "safe" or "success" |
| `--ad-accent-fill` + `--ad-accent-ink` | a **filled** accent control. Use this pair, not `--ad-accent` with white text: in dark mode `--ad-accent` is a light blue that white text cannot sit on. `--ad-danger-fill` + `--ad-accent-ink` is the destructive equivalent. |
| `--ad-ok` / `--ad-warn` / `--ad-danger` | semantic state; `--ad-danger-weak` / `--ad-accent-weak` / `--ad-accent-sel` are the tinted fills |
| `--ad-planned` / `--ad-simulated` | history/internal-runtime execution-mode badges (purple solid / amber dashed); v0.6 does not expose them as a Flash page mode switch |
| `--ad-shadow` / `--ad-control-shadow` | window elevation / the much softer lift on a resting control |

Type: `--ad-font-ui` for everything, `--ad-font-mono` for **paths, hashes, versions,
serials, commands, device IDs, log lines** — anything a user might compare character by
character. Sizes `--ad-text-xs | -sm | -md | -lg | -title`.

Space `--ad-space-1 … -6` (4/8/10/14/16/20px), radius `--ad-radius-sm | -md | -lg | -xl`
(6/8/10/12px — nest concentrically: an inner control's radius is smaller than its container's).

**Why these are hex at all.** The shipping ArkDeck app is SwiftUI/AppKit and uses
*system semantic* colors (`windowBackgroundColor`, `Color.accentColor`, system
green/orange/red) so it follows the user's own accent choice. These tokens are the web
stand-in for those roles — matched to the spec's fallback column. Practical consequence:
**stay on the token names**, because the values are expected to track the platform, and
anything you hardcode will drift the first time they do.

```jsx
<div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--ad-space-4)' }}>
```

### Rules this product's screens follow

- **A button label names the complete action** — `擦除数据并开始刷机`, not `确定`.
  The label is the last thing read before something irreversible.
- **Danger is never color alone**: glyph + wording + border together (the components
  already do this; keep it if you add your own).
- **Flash is the deliberate no-sheet exception.** Its page keeps target, image,
  userdata impact and one explicit destructive button together. Runtime capability,
  fresh target facts and the materialized plan remain the authority; do not add a
  checkbox, typed phrase, or second confirmation sheet. Other destructive actions
  still use `DangerConfirmDialog` when their current spec requires it.
- **No fake percentages.** Use `DeterminateProgress` only for Runtime-confirmed written
  bytes divided by the materialized image/partition total, and label it `镜像写入估算`.
  Preparation, Loader entry, reboot and verification use stage text plus
  `IndeterminateBar`. A 100% write is not a successful Flash; success waits for
  postflight verification.
- **Classify every device-touching step** with `EffectBadge`:
  `hostOnly → readOnly → deviceMutation → destructive`.
- **The normal Flash page is real execution only.** Do not draw Execute / Plan only /
  Simulated controls there. If internal or historical planned/simulated sessions are
  shown in History or Job Inspector, their badges remain permanent so they cannot be
  mistaken for real execution.
- **Flash has one calm reading path:** current device → selected image → destructive
  action; after submission the same region becomes progress, then the verified result.
  Target binding, image SHA, prerequisites and exact-plan summary live under the native
  `刷机详情` disclosure instead of becoming a wall of cards.
- **Debug has one bounded feedback loop:** explicit device → SSH / local directory / SMB /
  WSL build source → registered build root → searched and selected artifacts →
  compatibility preflight → backup and atomic publish → explicit restart → Logs. SSH
  supports password or private-key authentication; SSH/SMB secrets stay in Keychain and
  never appear in lists, Jobs, logs or evidence. Source roots are user-managed; device
  destination paths are never editable. ABI/ABC validation prevents an invalid
  replacement, while backup enables rollback — never collapse those into one promise.
- **Keep the production boundary visible in Debug.** The current Catalog publishes a
  single app-owned `.so` deployment with restartAbility in its typed plan. Batch source
  browsing, `.abc` deployment, and a separate device restart are v0.9 design inputs and
  remain unavailable until their own closed operations and Provider readbacks ship.

### Where to read more

`_ds/<folder>/styles.css` and its `@import`s are the real token and class definitions —
read them before styling anything. Per-component API and examples:
`components/general/<Name>/<Name>.prompt.md` and `<Name>.d.ts`.

### A screen, idiomatically

```jsx
const { WindowFrame, Card, Button, Chip, DeterminateProgress } = window.ArkDeckDS;

<div className="ad-root" style={{ padding: 24 }}>
  <WindowFrame title="ArkDeck — 刷机" toolbar={<Button>AC 标注</Button>}>
    <h1 style={{ margin: 0 }}>刷机</h1>
    <p style={{ margin: 0, color: "var(--ad-ink-2)" }}>
      选择镜像后开始刷机；进行中只突出进度，完成后直接显示结果。
    </p>
    <Card title="正在写入镜像" action={<Chip tone="ok">DAYU200 · 设备已就绪</Chip>}>
      <DeterminateProgress
        label="镜像写入估算"
        value={2_000_000_000}
        max={6_400_000_000}
        valueText="已确认写入 2 GB / 6.4 GB"
      />
      <p style={{ margin: 0, color: "var(--ad-ink-2)", fontSize: 12 }}>
        准备 ✓　写入镜像 ●　重启与验证 ○
      </p>
    </Card>
    <details><summary>查看刷机详情</summary>{/* target / SHA / exact-plan summary */}</details>
  </WindowFrame>
</div>
```
