# TASK-SVC-003 residual outside the Task allowlist (not applied)

One single-v1 cleanup in the evidence vocabulary could not be completed inside
the TASK-SVC-003 Allowed paths, and is recorded here for maintainer review
instead of being worked around.

## Retired authority labels remain in the Swift vocabulary

`RuntimeHardwareEvidenceAuthorityKind` in
`Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
still declares `standingAuthorization` and `evolutionCampaignConfirmation`.
The current Runtime never issues or emits them: the daemon's evidence encoder
(`AgentDaemon.encodeEvidence`) writes only `defaultReadOnlyPolicy` and
`runtimeCapability`, SVC-001 removed the request-side authority expressions and
SVC-002 removed the durable authority readers. In this delivery the two labels
are refusal-only: the projector refuses them by name
(`retired authority kind cannot be emitted as hardware evidence`), the schema
enum does not admit them, and the strict reader refuses any document that
carries them.

Removing the two cases also requires one line in
`Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HeadlessRuntimeVerifier.swift`,
which is outside the TASK-SVC-003 Allowed paths:

```diff
--- a/Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HeadlessRuntimeVerifier.swift
+++ b/Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HeadlessRuntimeVerifier.swift
@@ persistedAuthorityVerified
       return true
-    case .standingAuthorization, .evolutionCampaignConfirmation:
-      return false
     }
```

together with the allowed-path half:

```diff
--- a/Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift
+++ b/Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift
@@ package enum RuntimeHardwareEvidenceAuthorityKind
   case defaultReadOnlyPolicy
   case runtimeCapability
-  /// Retired authority labels. ... refuse them by name ...
-  case standingAuthorization
-  case evolutionCampaignConfirmation
 }
@@ HardwareEvidenceProjector.project
-      if authority.kind == .standingAuthorization
-        || authority.kind == .evolutionCampaignConfirmation
-      {
-        reasons.append("retired authority kind cannot be emitted as hardware evidence")
-      }
```

and the corresponding test vectors in
`HardwareEvidenceProjectionContractTests` becoming raw-JSON decode refusals
(`{"kind":"standingAuthorization"}` fails to decode as
`RuntimeHardwareEvidenceTrustedFacts`) instead of enum-valued receipts.

Either shape fails closed. The difference is only whether a foreign label is
refused with a named reason or with a decode failure. Applying the diff needs a
maintainer decision on the one out-of-scope file; if accepted, it travels as a
follow-up PR under TASK-SVC-003 (or through the SVC-004 residual rule) and does
not widen any Allowed paths in this delivery.
