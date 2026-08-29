import ArkDeckCore
import SwiftUI

/// A permanent outline marker for a job's execution mode, shared by History
/// and the job inspector: PLANNED wears a purple outline, SIMULATED an
/// orange dashed outline — the same vocabulary as the Flash mode badge, so
/// the same job reads the same everywhere. Execute renders no badge at all;
/// an unrecognized mode falls back to neutral uppercase text rather than
/// guessing a color semantics for it.
///
/// It lives beside the rest of the shared vocabulary rather than inside the
/// History workspace that happened to need it first: a component two features
/// already render is not History's private detail, and keeping it there is how
/// the next caller ends up writing a third copy.
struct RuntimeExecutionModeBadge: View {
  private let text: String
  private let tone: WorkspaceTone
  private let dashed: Bool

  init?(_ mode: String?) {
    switch mode {
    case nil, JobExecutionMode.execute.rawValue:
      return nil
    case JobExecutionMode.planOnly.rawValue:
      text = "PLANNED"
      tone = .planned
      dashed = false
    case "simulated":
      text = "SIMULATED"
      tone = .simulated
      dashed = true
    case let other?:
      text = other.uppercased()
      tone = .neutral
      dashed = false
    }
  }

  var body: some View {
    // The one chip shape in the App. Permanent, outline-only, and never a
    // filled control the user could mistake for something pressable
    // (spec §4.4).
    WorkspaceChip(text: Text(text), tone: tone, isDashed: dashed)
      .accessibilityLabel(text)
  }
}
