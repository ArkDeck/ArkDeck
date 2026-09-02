---
id: CHG-2026-072-session-export-control
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-072 — Generation-bound Runtime Session export

> **This file does not approve itself.** The new control surface becomes
> approved only if a human maintainer reviews and merges the delivery PR into
> protected `main`.

> Four-category declaration: this change publishes two versioned Runtime
> control methods, `session.export.preview` and `session.export.apply`. They are
> host-only Session resource operations rather than Catalog device operations,
> but are treated as a new operation surface for fail-closed OpenSpec review.
> The change adds no provider, device profile, Catalog operation, capability
> administration, or destructive admission rule.

## Governance loop

1. **Concrete safety risk.** Export can disclose raw UI dumps, traces, HiLog,
   screenshots, device identifiers, and paths. A one-shot path copy would also
   permit destination substitution or ambiguous replay after publication.
2. **Why this is not only a defect fix.** The current Runtime has no typed,
   generation-bound Session export method. Publishing new control vocabulary
   requires review even though the effect remains host-only.
3. **Golden Journey advanced.** GJ-1 through GJ-5 all need an explicit way to
   take a bounded diagnostic copy after inspecting Session evidence. This
   closes that post-run resource step without another device dispatch.
4. **Why the scope is finite.** One task delivers the owner, protocol, CLI,
   privacy defaults, fault tests, and host evidence. Runtime support bundles,
   source/update lifecycle, Windows transport, and real-device acceptance stay
   outside this change.

## Observable behavior

Before this change, `session list/show/pin/unpin` and retention cleanup exist,
but exporting a complete Session requires App-private composition or direct
filesystem handling. After it, callers first request an immutable ten-minute
preview that binds the Session catalog generation, Artifact identities and
digests, privacy choices, redaction policy, and destination directory facts.
Apply accepts only the exact preview UUID and SHA-256 digest.

Sensitive raw/partial Artifacts are excluded by default. Including them needs
the explicit `--allow-sensitive` preview option. Every included file and the
manifest pass through the existing anchored diagnostic exporter with device
identifier redaction, bounded host-volume admission, checksum validation, and
atomic directory publication. The source Session and Artifacts remain
unchanged. The receipt labels the output as a derived export and reports zero
device dispatches.

## Non-goals

- no raw command, argv, executable, shell, HDC, remote path, or capability
  input;
- no overwrite mode, implicit destination creation, background export, or
  retry of an outcome-unknown publication;
- no new Catalog operation/provider/profile and no device interaction;
- no claim that host fixtures or exported data constitute real-device
  acceptance.
