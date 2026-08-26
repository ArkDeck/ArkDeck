import ArkDeckWorkflows
import Observation
import SwiftUI

/// Diagnostics · session reader.
///
/// Everything here is arranged so a person can tell what the session can and
/// cannot prove. The alignment state sits in the toolbar because every other
/// reading depends on it; a mark with no usable picture says which of the
/// three reasons applies rather than showing an older frame; and what nothing
/// looked for is listed, so an empty track is not read as a quiet all-clear.
struct DiagnosticsWorkspaceView: View {
  var model: DiagnosticsWorkspaceViewModel

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if model.reading == nil {
        ContentUnavailableView {
          Label(diagnosticsText("diagnostics.session.none"), systemImage: "waveform.path")
        } description: {
          Text(diagnosticsText("diagnostics.session.none.detail"))
        }
        .accessibilityIdentifier("diagnostics.session.empty")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if model.isPartial { partialNotice }
            marksSection
            if let reading = model.reading, !reading.notDerived.isEmpty {
              notDerivedSection(reading.notDerived)
            }
            if let reading = model.reading, !reading.missingProducts.isEmpty {
              missingSection(reading.missingProducts)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
        }
      }
      Divider()
      footer
    }
    .task { await model.refresh() }
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: 12) {
      Text(diagnosticsText("diagnostics.title"))
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      // The alignment state is not decoration: it decides whether anything
      // below it can be lined up with what the device recorded.
      Label(
        model.alignmentTitle,
        systemImage: model.alignmentIsRefusal ? "exclamationmark.triangle.fill" : "clock")
        .font(.system(size: 11))
        .foregroundStyle(model.alignmentIsRefusal ? .orange : .secondary)
        .accessibilityIdentifier("diagnostics.alignment")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var partialNotice: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(diagnosticsText("diagnostics.partial"), systemImage: "exclamationmark.circle")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.orange)
      Text(diagnosticsText("diagnostics.partial.detail"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("diagnostics.partial")
  }

  // MARK: - Marks

  private var marksSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(diagnosticsText("diagnostics.marks.title"))
        .font(.system(size: 13, weight: .semibold))
      if model.marks.isEmpty {
        Text(diagnosticsText("diagnostics.marks.empty"))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.marks, id: \.ordinal) { mark in markRow(mark) }
      }
    }
  }

  private func markRow(_ mark: DiagnosticSessionReading.Mark) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        // A mark a person made and one the runtime derived are told apart by
        // shape, not only by colour.
        Image(systemName: mark.isAutomatic ? "sparkle" : "bookmark.fill")
          .foregroundStyle(mark.isAutomatic ? .purple : .accentColor)
          .accessibilityHidden(true)
        Text(model.markTitle(mark)).font(.system(size: 12, weight: .medium))
        Spacer()
        Text(mark.atHostUTC)
          .font(.system(size: 10))
          .monospaced()
          .foregroundStyle(.secondary)
      }
      if let caption = model.screenshotCaption(mark) {
        VStack(alignment: .leading, spacing: 2) {
          Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
          Text(diagnosticsText("diagnostics.shot.standsFor"))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("diagnostics.mark.screenshot")
      } else if let title = model.absenceTitle(mark) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 11)).foregroundStyle(.orange)
          if let detail = model.absenceDetail(mark) {
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("diagnostics.mark.noScreenshot")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityIdentifier("diagnostics.mark")
  }

  // MARK: - What nothing looked for

  private func notDerivedSection(_ kinds: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(diagnosticsText("diagnostics.notDerived.title"))
        .font(.system(size: 12, weight: .medium))
      Text(diagnosticsText("diagnostics.notDerived.detail"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(kinds.joined(separator: " · "))
        .font(.system(size: 10))
        .monospaced()
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("diagnostics.notDerived")
  }

  private func missingSection(
    _ products: [DiagnosticSessionReading.MissingProduct]
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(diagnosticsText("diagnostics.missing.title"))
        .font(.system(size: 12, weight: .medium))
      ForEach(products, id: \.name) { product in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(product.name).font(.system(size: 11)).monospaced()
          Text(product.reason).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("diagnostics.missing")
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Text(model.selectionSummary)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("diagnostics.selection")
      Spacer()
      if let detail = model.alignmentDetail {
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }
}
