# Tasks — CHG-2026-080

## TASK-KBI-001 — Deliver private keyboard input in Device

- Status:in-progress; no protected-main approval is claimed.
- Golden Journey:GJ-1/GJ-2 device interaction.
- Hardware required:no for implementation; real-device support remains unverified.
- Decision-Grade:D1 (new operation and typed Provider lowering).
- Acceptance:KBI-AC-1, KBI-AC-2, KBI-AC-3, KBI-AC-4, KBI-AC-5.
- Production reachability:Device or CLI → sensitive Import → typed Job → Runtime
  admission → exact Target HDC Provider → WAL outcome → Session/Job view.
- Scope:Catalog/step schema and generator, private Import validation, plan/run/
  no-replay recovery, authenticated App gate, ClientKit, Device UI and bilingual
  prototype, CLI leaves, contract consumers and focused verification.
- Exclusions:raw command surface, arbitrary key codes, modifier hold/release,
  other displays, clipboard read/restore, target focus guarantees, input replay,
  capability/coverage administration, destructive policy changes and hardware
  acceptance.
- Trusted facts:existing Target/binding/tool facts, owner-validated immutable
  Import bytes and hash, Runtime clock, actual bounded process receipt.
- Allowed paths:Catalog/**, rust/**, Packages/ArkDeckKit/**, ArkDeckApp/**,
  docs/design/**, openspec/contracts/**, spec/**, windows/** and this change.
- Forbidden paths:Constitution, accepted Core requirements, hardware evidence,
  live capability/trusted-fact/Provider coverage stores and device execution.

Deliver one reviewable implementation with targeted local checks, selected PR CI,
and a truthful run record. Do not mark the change approved or verified.
