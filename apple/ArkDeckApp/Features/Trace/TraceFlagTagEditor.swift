import ArkTraceRendering
import SwiftUI

/// A marker's identity owns its draft, even when another flag replaces it at
/// the same position in the timeline overlay. Each departing editor keeps
/// callbacks bound to its original ID while it commits on disappearance.
struct TraceFlagTagEditor: View {
    let flag: TimelineFlag
    let timestampText: String
    let rename: @MainActor (Int, String) -> Void
    let cycleColor: @MainActor (Int, Int) -> Void
    let remove: @MainActor (Int) -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        let flagID = flag.id
        TraceFlagDraftEditor(
            flag: flag,
            timestampText: timestampText,
            rename: { rename(flagID, $0) },
            cycleColor: { cycleColor(flagID, flag.colorIndex + 1) },
            remove: { remove(flagID) },
            dismiss: dismiss
        )
        .id(flagID)
    }
}
