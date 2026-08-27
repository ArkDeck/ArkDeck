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
  let onOpenTrace: (RuntimeHistoryWorkspaceContext) -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      capturePane
      Divider()
      if model.isLoading {
        ProgressView(diagnosticsText("diagnostics.session.loading"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("diagnostics.session.loading")
      } else if let reason = model.loadError {
        ContentUnavailableView {
          Label(diagnosticsText("diagnostics.session.failed"), systemImage: "exclamationmark.triangle")
        } description: {
          Text(reason).textSelection(.enabled)
        } actions: {
          Button(diagnosticsText("diagnostics.session.retry"), action: model.reload)
        }
        .accessibilityIdentifier("diagnostics.session.failed")
      } else if model.reading == nil {
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
            if let session = model.session { sessionSection(session) }
            marksSection
            if let reading = model.reading, !reading.notDerived.isEmpty {
              notDerivedSection(reading.notDerived)
            }
            if let reading = model.reading, !reading.missingProducts.isEmpty {
              missingSection(reading.missingProducts)
            }
            if let session = model.session { artifactsSection(session.artifacts) }
            previewSection
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
        }
      }
      Divider()
      footer
    }
  }

  // MARK: - Capture

  /// Keep the missing visible without pretending a local state change starts
  /// a Runtime recording. Interactive session controls are not connected.
  private var capturePane: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button {} label: {
          Label(diagnosticsText("diagnostics.capture.arm"), systemImage: "record.circle")
        }
        .disabled(true)
        .help(diagnosticsText("diagnostics.capture.unavailable.detail"))
        .accessibilityIdentifier("diagnostics.capture.arm")

        Button {} label: {
          Label(diagnosticsText("diagnostics.capture.mark"), systemImage: "bookmark")
        }
        .keyboardShortcut("m", modifiers: .command)
        .disabled(true)
        .accessibilityIdentifier("diagnostics.capture.mark")

        Spacer()
      }
      VStack(alignment: .leading, spacing: 4) {
        Label(
          diagnosticsText("diagnostics.capture.unavailable"),
          systemImage: "exclamationmark.triangle")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.orange)
        Text(diagnosticsText("diagnostics.capture.unavailable.detail"))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(model.captureUnavailableReasonCode)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("diagnostics.capture.unavailable")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: 12) {
      Text(diagnosticsText("diagnostics.title"))
        .font(.system(size: 13, weight: .semibold))
        .accessibilityIdentifier("diagnostics.workspace.title")
      Spacer()
      if model.session != nil {
        Button(diagnosticsText("diagnostics.session.reload"), action: model.reload)
          .accessibilityIdentifier("diagnostics.session.reload")
      }
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

  private func sessionSection(_ session: DiagnosticSessionPresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(session.reading.jobID).font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled).accessibilityIdentifier("diagnostics.session.job")
      Text(diagnosticsText("diagnostics.session.readOnly"))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if let covered = session.ringHeldAnchor {
        Label(
          diagnosticsText(covered ? "diagnostics.ring.covered" : "diagnostics.ring.lost"),
          systemImage: covered ? "checkmark.circle" : "exclamationmark.triangle")
          .font(.system(size: 11)).foregroundStyle(covered ? Color.secondary : Color.orange)
      }
      DisclosureGroup(diagnosticsText("diagnostics.session.timeline")) {
        Text(session.timeline.joined(separator: "\n"))
          .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func artifactsSection(_ artifacts: [RuntimeArtifactPresentation]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(diagnosticsText("diagnostics.artifacts.title")).font(.system(size: 13, weight: .semibold))
      Text(diagnosticsText("diagnostics.artifacts.privacy"))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if let context = model.traceContext {
        Button(diagnosticsText("diagnostics.artifacts.openTrace")) { onOpenTrace(context) }
          .help(diagnosticsText("diagnostics.artifacts.openTrace.privacy"))
          .accessibilityIdentifier("diagnostics.artifacts.openTrace")
      }
      ForEach(artifacts) { artifact in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(artifact.name).font(.system(size: 11, design: .monospaced))
            Text("\(artifact.status) · \(artifact.byteCount) B · \(artifact.privacy)")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
          Spacer()
          if artifact.status == "published",
            artifact.mediaType == "text/plain" || artifact.mediaType == "application/json"
          {
            Button(diagnosticsText(
              artifact.privacy == "sensitive" ? "diagnostics.artifacts.readSensitive" : "diagnostics.artifacts.read")) {
              model.preview(artifact)
            }
            .disabled(model.isPreviewLoading)
            .accessibilityIdentifier("diagnostics.artifact.read.\(artifact.name)")
          }
        }
      }
      Text(diagnosticsText("diagnostics.artifacts.openElsewhere"))
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("diagnostics.artifacts")
  }

  @ViewBuilder private var previewSection: some View {
    if let name = model.previewName {
      VStack(alignment: .leading, spacing: 6) {
        Text(name).font(.system(size: 12, weight: .medium))
        if model.isPreviewLoading { ProgressView() }
        if let error = model.previewError {
          Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            .accessibilityIdentifier("diagnostics.preview.failed")
        }
        if model.previewWasClipped {
          Text(diagnosticsText("diagnostics.preview.clipped")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if model.previewReplacedInvalidUTF8 {
          Label(diagnosticsText("diagnostics.preview.replacedInvalidUTF8"), systemImage: "exclamationmark.triangle")
            .font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("diagnostics.preview.encodingWarning")
        }
        if let text = model.previewText {
          Text(text).font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("diagnostics.preview.text")
        }
      }
    }
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
        Text(mark.atHostUTC.isEmpty ? diagnosticsText("diagnostics.mark.timeMissing") : mark.atHostUTC)
          .font(.system(size: 10))
          .monospaced()
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("diagnostics.mark.time.\(mark.ordinal)")
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
    .accessibilityElement(children: .contain)
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
