## Building with ArkDeck

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
| `--ad-planned` / `--ad-simulated` | the two execution-mode badges (purple solid / amber dashed) |
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

- **A button label names the complete action** — `刷写 rk3568-dev(2 个分区)…`, not
  `确定`. The label is the last thing read before something irreversible.
- **Danger is never color alone**: glyph + wording + border together (the components
  already do this; keep it if you add your own).
- **Destructive actions go through `DangerConfirmDialog`** — impact list, one checkbox
  per thing being certified, confirm button repeating the whole action.
- **No fake percentages.** Device work has no reliable byte total; use `PhaseTrack` and
  `IndeterminateBar`.
- **Classify every device-touching step** with `EffectBadge`:
  `hostOnly → readOnly → deviceMutation → destructive`.
- **`planned` / `simulated` badges are permanent** — they follow a session into history
  and exports, so a dry run can never be mistaken for a real one.

### Where to read more

`_ds/<folder>/styles.css` and its `@import`s are the real token and class definitions —
read them before styling anything. Per-component API and examples:
`components/general/<Name>/<Name>.prompt.md` and `<Name>.d.ts`.

### A screen, idiomatically

```jsx
const { WindowFrame, Card, DataTable, EffectBadge, Button, Chip } = window.ArkDeckDS;

<div className="ad-root" style={{ padding: 24 }}>
  <WindowFrame title="ArkDeck — OpenHarmony 设备工作台"
               toolbar={<Button>AC 标注</Button>}>
    <Card title="Exact Plan — rk3568-5.0-full"
          action={<Chip tone="planned">◇ PLANNED</Chip>}>
      <DataTable
        columns={[
          { key: 'n', header: '#', mono: true },
          { key: 'step', header: 'step', mono: true },
          { key: 'effect', header: 'effect' },
        ]}
        rows={[
          { id: '1', cells: { n: '1', step: 'enterUpdater',
              effect: <EffectBadge effect="deviceMutation" /> } },
          { id: '2', cells: { n: '2', step: 'flashPartition',
              effect: <EffectBadge effect="destructive" /> } },
        ]}
      />
      <p style={{ color: 'var(--ad-ink-2)', fontSize: 'var(--ad-text-sm)' }}>
        镜像原地引用,不复制进 Session;GB 级流式 hash。
      </p>
    </Card>
  </WindowFrame>
</div>
```
