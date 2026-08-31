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
      if !model.isHilogSummaryContext {
        capturePane
        Divider()
      }
      if model.isLoading {
        ProgressView(diagnosticsText("diagnostics.session.loading"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("diagnostics.session.loading")
      } else if let reason = model.loadError {
        ContentUnavailableView {
          Label(diagnosticsText(model.isHilogSummaryContext ? "diagnostics.hilog.failed" : "diagnostics.session.failed"), systemImage: "exclamationmark.triangle")
        } description: {
          if model.isHilogSummaryContext { Text(diagnosticsText("diagnostics.hilog.failed.detail")) }
          Text(reason).textSelection(.enabled)
        } actions: {
          Button(diagnosticsText("diagnostics.session.retry"), action: model.reload)
        }
        .accessibilityIdentifier("diagnostics.session.failed")
      } else if let summary = model.hilogSummary {
        hilogSummarySection(summary)
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
      if !model.isHilogSummaryContext {
        Divider()
        footer
      }
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
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.orange)
        Text(diagnosticsText("diagnostics.capture.unavailable.detail"))
          .font(WorkspaceFont.caption)
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
      // Only the HiLog context names itself here. The plain context's title
      // was the same words the window toolbar already shows, and spec §8 does
      // not allow a content area to repeat the toolbar's page title — so that
      // branch draws nothing and the reload control leads the strip instead.
      if model.isHilogSummaryContext {
        Text(diagnosticsText("diagnostics.hilog.title"))
          .font(WorkspaceFont.sectionTitle)
          .accessibilityIdentifier("diagnostics.workspace.title")
      }
      Spacer()
      if model.session != nil || model.hilogSummary != nil {
        Button(diagnosticsText("diagnostics.session.reload"), action: model.reload)
          .accessibilityIdentifier("diagnostics.session.reload")
      }
      // The alignment state is not decoration: it decides whether anything
      // below it can be lined up with what the device recorded.
      if !model.isHilogSummaryContext { Label(
        model.alignmentTitle,
        systemImage: model.alignmentIsRefusal ? "exclamationmark.triangle.fill" : "clock")
        .font(WorkspaceFont.caption)
        .foregroundStyle(model.alignmentIsRefusal ? .orange : .secondary)
        .accessibilityIdentifier("diagnostics.alignment") }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private func hilogSummarySection(_ summary: DiagnosticHilogSummaryPresentation) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(summary.jobID)
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
          .accessibilityIdentifier("diagnostics.hilog.job")
        Text(diagnosticsText("diagnostics.hilog.readOnly"))
          .font(.callout).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          Text(diagnosticsText("diagnostics.hilog.coverage.\(summary.headerCoverage)"))
            .font(.headline)
            .accessibilityIdentifier("diagnostics.hilog.coverage")
          Text(diagnosticsText("diagnostics.hilog.coverage.detail"))
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("diagnostics.hilog.boundary")
        }
        WorkspaceFactGrid {
          hilogCount("diagnostics.hilog.lines", value: summary.lineCount, id: "lines")
          ForEach(["D", "I", "W", "E", "F"], id: \.self) { level in
            hilogCount("diagnostics.hilog.level.\(level)", value: summary.levelCounts[level] ?? 0, id: level)
          }
          hilogCount("diagnostics.hilog.unrecognized", value: summary.unrecognizedLineCount, id: "unrecognized")
          hilogCount("diagnostics.hilog.blank", value: summary.blankLineCount, id: "blank")
        }
        Divider()
        Text(diagnosticsText("diagnostics.hilog.source"))
          .font(.headline).accessibilityAddTraits(.isHeader)
        Text(diagnosticsText("diagnostics.hilog.source.detail"))
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 10) {
          hilogFact("diagnostics.hilog.sourceJob", value: summary.sourceJobID, id: "sourceJob")
          hilogFact("diagnostics.hilog.sourceArtifact", value: summary.sourceArtifactID, id: "sourceArtifact")
          hilogFact("diagnostics.hilog.sourceBytes", value: String(summary.sourceByteCount), id: "sourceBytes")
        }
        DisclosureGroup(diagnosticsText("diagnostics.hilog.digests")) {
          VStack(alignment: .leading, spacing: 10) {
            hilogFact("diagnostics.hilog.sourceDigest", value: summary.sourceSHA256, id: "sourceDigest")
            hilogFact("diagnostics.hilog.toolDigest", value: summary.analyzerExecutableSHA256, id: "toolDigest")
            hilogFact("diagnostics.hilog.outputDigest", value: summary.analyzerOutputSHA256, id: "outputDigest")
            hilogFact("diagnostics.hilog.artifactDigest", value: summary.artifact.sha256, id: "artifactDigest")
          }
          .padding(.top, 8)
        }
        .accessibilityIdentifier("diagnostics.hilog.digests")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
    .accessibilityIdentifier("diagnostics.hilog.summary")
  }

  private func hilogCount(_ key: String, value: Int, id: String) -> WorkspaceFactRow {
    WorkspaceFactRow(
      name: Text(diagnosticsText(key)),
      value: Text(String(value)),
      isMonospaced: false,
      usesTabularDigits: true,
      identifier: "diagnostics.hilog.count.\(id)")
  }

  private func hilogFact(_ key: String, value: String, id: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(diagnosticsText(key)).font(.caption).foregroundStyle(.secondary)
      Text(value).font(WorkspaceFont.monospacedDense)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("diagnostics.hilog.\(id)")
    }
  }

  private func sessionSection(_ session: DiagnosticSessionPresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(session.reading.jobID).font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled).accessibilityIdentifier("diagnostics.session.job")
      Text(diagnosticsText("diagnostics.session.readOnly"))
        .font(WorkspaceFont.caption).foregroundStyle(.secondary)
      if let covered = session.ringHeldAnchor {
        Label(
          diagnosticsText(covered ? "diagnostics.ring.covered" : "diagnostics.ring.lost"),
          systemImage: covered ? "checkmark.circle" : "exclamationmark.triangle")
          .font(WorkspaceFont.caption).foregroundStyle(covered ? Color.secondary : Color.orange)
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
      Text(diagnosticsText("diagnostics.artifacts.title")).font(WorkspaceFont.sectionTitle)
      Text(diagnosticsText("diagnostics.artifacts.privacy"))
        .font(WorkspaceFont.caption).foregroundStyle(.secondary)
      if let context = model.traceContext {
        Button(diagnosticsText("diagnostics.artifacts.openTrace")) { onOpenTrace(context) }
          .help(diagnosticsText("diagnostics.artifacts.openTrace.privacy"))
          .accessibilityIdentifier("diagnostics.artifacts.openTrace")
      }
      ForEach(artifacts) { artifact in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(artifact.name).font(WorkspaceFont.monospacedDense)
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
        .font(WorkspaceFont.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("diagnostics.artifacts")
  }

  @ViewBuilder private var previewSection: some View {
    if let name = model.previewName {
      VStack(alignment: .leading, spacing: 6) {
        Text(name).font(WorkspaceFont.secondary)
        if model.isPreviewLoading { ProgressView() }
        if let error = model.previewError {
          Text(error).font(WorkspaceFont.caption).foregroundStyle(.orange)
            .accessibilityIdentifier("diagnostics.preview.failed")
        }
        if model.previewWasClipped {
          Text(diagnosticsText("diagnostics.preview.clipped")).font(WorkspaceFont.caption).foregroundStyle(.secondary)
        }
        if model.previewReplacedInvalidUTF8 {
          Label(diagnosticsText("diagnostics.preview.replacedInvalidUTF8"), systemImage: "exclamationmark.triangle")
            .font(WorkspaceFont.caption).foregroundStyle(.orange)
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
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.orange)
      Text(diagnosticsText("diagnostics.partial.detail"))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("diagnostics.partial")
  }

  // MARK: - Marks

  private var marksSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(diagnosticsText("diagnostics.marks.title"))
        .font(WorkspaceFont.sectionTitle)
      if model.marks.isEmpty {
        Text(diagnosticsText("diagnostics.marks.empty"))
          .font(WorkspaceFont.caption)
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
        Text(model.markTitle(mark)).font(WorkspaceFont.secondary)
        Spacer()
        Text(mark.atHostUTC.isEmpty ? diagnosticsText("diagnostics.mark.timeMissing") : mark.atHostUTC)
          .font(.system(size: 10))
          .monospaced()
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("diagnostics.mark.time.\(mark.ordinal)")
      }
      if let caption = model.screenshotCaption(mark) {
        VStack(alignment: .leading, spacing: 2) {
          Text(caption).font(WorkspaceFont.caption).foregroundStyle(.secondary)
          Text(diagnosticsText("diagnostics.shot.standsFor"))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("diagnostics.mark.screenshot")
      } else if let title = model.absenceTitle(mark) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(WorkspaceFont.caption).foregroundStyle(.orange)
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
    .clipShape(.rect(cornerRadius: 6))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("diagnostics.mark")
  }

  // MARK: - What nothing looked for

  private func notDerivedSection(_ kinds: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(diagnosticsText("diagnostics.notDerived.title"))
        .font(WorkspaceFont.secondary)
      Text(diagnosticsText("diagnostics.notDerived.detail"))
        .font(WorkspaceFont.caption)
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
        .font(WorkspaceFont.secondary)
      ForEach(products, id: \.name) { product in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(product.name).font(WorkspaceFont.caption).monospaced()
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
        .font(WorkspaceFont.caption)
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
