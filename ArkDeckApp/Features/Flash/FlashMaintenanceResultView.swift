import ArkDeckClientKit
import SwiftUI

struct FlashMaintenanceResultView: View {
  let result: FlashMaintenanceResult
  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Text(String(format: flashText("flash.maintenance.result"), result.outcome, Int64(result.exitCode)))
        .font(.headline).accessibilityIdentifier("flash.maintenance.result")
      Text(result.sourceJobID).font(.caption.monospaced()).textSelection(.enabled)
      if let reason = result.reason {
        Text(flashText("flash.maintenance.stopped"))
        Text(reason).textSelection(.enabled)
      }
      if let verification = result.verification {
        Text(String(format: flashText("flash.maintenance.counts"), Int64(verification.verified), Int64(verification.skipped), Int64(verification.failed)))
        Text(verification.sourcePlanID).font(.caption.monospaced()).textSelection(.enabled)
        Text(verification.sourcePlanSHA256).font(.caption.monospaced()).textSelection(.enabled)
        ForEach(verification.targets) { target in
          DisclosureGroup("\(target.target): \(target.outcome)") {
            VStack(alignment: .leading, spacing: 4) {
              Text(String(format: flashText("flash.maintenance.range"), Int64(clamping: target.rangeStart), Int64(clamping: target.rangeLength)))
              Text(flashText("flash.maintenance.expected"))
              Text(target.expectedSHA256).font(.caption.monospaced())
              if let observed = target.observedSHA256 {
                Text(flashText("flash.maintenance.observed"))
                Text(observed).font(.caption.monospaced())
              }
              if let strength = target.verificationStrength { Text(strength) }
              if let reason = target.reason { Text(reason) }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
}
