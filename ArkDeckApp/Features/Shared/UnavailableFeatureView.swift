import SwiftUI

/// The honest state of a workspace whose Runtime surface this build does not
/// carry. It takes a title and a symbol only: it has no model, no fixture,
/// and no way to render a device, Job, Artifact, or progress value, so it
/// cannot make an unimplemented workflow look available.
struct UnavailableFeatureView: View {
  let titleKey: String
  let systemImageName: String

  var body: some View {
    ContentUnavailableView {
      Label {
        Text(LocalizedStringKey(titleKey))
          .accessibilityIdentifier("app.unavailable.title")
      } icon: {
        Image(systemName: systemImageName)
      }
    } description: {
      VStack(spacing: 8) {
        Text("app.unavailable.reason")
          .accessibilityIdentifier("app.unavailable.reason")
        Text("app.unavailable.noOperationSubmitted")
          .accessibilityIdentifier("app.unavailable.noOperationSubmitted")
      }
      .multilineTextAlignment(.center)
    }
    .accessibilityIdentifier("app.unavailable")
  }
}
