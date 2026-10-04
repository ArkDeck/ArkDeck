---
id: CHG-2026-080-private-keyboard-input
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# Private keyboard input through the Runtime

This change proposes `input.keyboard@1` on the existing HDC provider and the
`injectKeyboardInput` typed step. Maintenance review and protected-main merge
are required before execution. Host fixtures do not establish hardware support.
No provider, device profile, capability administration or destructive admission
rule is added. Existing profiles gain the candidate operation reference.

Device currently offers pointer gestures but cannot send a key or text to the
focused application. This GJ-1/GJ-2 slice provides ten closed navigation/editing
keys and one explicit UTF-8 text submission of at most 512 bytes. Text may use
OpenHarmony's device clipboard; each text submission requires an explicit App
checkbox (or `allowDeviceClipboard: true` in the imported typed payload).

Inputs use a target-bound immutable sensitive `keyboard-input` Import. Jobs and
journals contain only its lease/identity/hash and intent timestamp. They never
contain text, key sequences, encoded payloads or tool streams. Import publication
reuses the existing private storage, quota and binding checks. Default sensitive
read/export restrictions continue to apply. The raw Import is retained locally;
this is not a claim of encryption or automatic erasure.

The Runtime resolves and hashes the full plan before its existing mutation
admission. Keyboard inputs keep the exact plan and Artifact subject; they do not
join the reusable pointer-session subject. A ten-second decision deadline is
checked at materialization and action construction. The timestamp is an input
expiry, not proof of current application focus or screenshot time.

One exact UiTest positive acknowledgement means injector acceptance only. Missing,
partial, unexpected or failed replies preserve an unknown outcome; no reconcile
or App retry can inject again. App input marks the existing picture stale after a
confirmed or uncertain response. The five real-device journeys remain outside
this requested implementation run.

Compatibility: ordinary implementation, verification and PR delivery follow
PRODUCT-LOOP and the current AGENTS guide; this proposed change travels with its
implementation rather than creating a separate readiness/status PR.
