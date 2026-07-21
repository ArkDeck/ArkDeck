# R2 element-tree output-family decision v1

## Decision

**NEGATIVE.** The human maintainer ran the fixed `uidump-derived-redaction-v1`
transform against the exact Phase A R2 sidecar origin pinned by PR #248. The
transform failed closed with stable error `INVALID_UNICODE` / exit `27` and
created neither a derived fixture nor a redaction receipt.

The failure means this task cannot establish a repository-safe positive R2
structural fixture. It therefore registers no success structural family, no
component-candidate locator, no candidate format, and no candidate cardinality.
The Phase A exact component token was neither recorded nor reused.

## Pinned provenance

- Capture evidence: `EVD-UD-CAP-MUT-DAYU200-20260721-003`.
- Capture merge: `79b795b7916c863376b3c1f9c37456b0089283dd`.
- Capture status merge: `d5aded75d30fbd7ae048005b692b7f4138b23055`.
- Target tuple: DAYU200 (RK3568), OpenHarmony 7.0.0.34, API 26.0.0,
  HDC 3.2.0d, USB.
- R2 raw origin: remote sidecar, sequence `16`, `866256` bytes, SHA-256
  `ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`.
- Approved argv template:
  `[<PINNED_HDC>, "-t", <SAME_SESSION_CONNECT_KEY>, "shell", "hidumper",
  "-s", "WindowManagerService", "-a",
  "-w <ASCII_DECIMAL_WINDOW_ID> -element -c"]`. The final `-a` payload remains
  exactly one argv element.

No controlled raw path, device serial, connect key, window identifier, page
text, component literal, raw fragment, derived bytes, token, nonce, or private
bundle is recorded by this decision.

## Classification precedence

1. A complete stdout or stderr stream matching the existing
   `option ... missed` error family is `failure`, irrespective of process exit
   code.
2. Every other R2 output remains `unknownOutput` because this decision
   registers no positive structural family.

Exit code zero and a raw byte digest cannot independently produce success.

## Selection and downstream gates

No deterministic locator exists under this decision; candidate cardinality is
`notEvaluated`, not zero. The same-session selection requirement remains in
force, but it cannot be implemented without a future approved positive
decision. `TASK-UD-R2-R4-SEAM-001` and `TASK-UD-CAP-R4-001` therefore remain
blocked, and R4 dispatch remains zero.

This decision closes only the truthful-negative branch of
`INT-UD-R2-DECISION-001`. It claims no Recipe success, canonical acceptance,
compatibility, support, conformance, hardware expansion, or release status.

## Privacy deviation

During coordination, the human operator pasted the controlled raw absolute
path into the task conversation despite the no-path instruction. The literal
is not repeated in repository evidence. No raw bytes, full manifest, exact
component token, nonce, connect key, or device serial were pasted. Agent raw
read count remains `0`.
