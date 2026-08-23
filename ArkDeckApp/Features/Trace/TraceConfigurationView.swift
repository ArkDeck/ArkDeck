import ArkDeckWorkflows
import Foundation
import SwiftUI

struct TraceConfigurationView: View {
  var model: TraceWorkspaceViewModel

  var body: some View {
    VStack(spacing: WorkspaceMetrics.blockGap) {
      presetAndTags
      captureBounds
      parameterSnapshots
      derivedFiltering
    }
  }

  private var presetAndTags: some View {
    WorkspaceSection(
      Text(traceString("trace.configuration.title")),
      accessory: {
        Picker(traceString("trace.configuration.mode"), selection: modeBinding) {
          Text(traceString("trace.configuration.preset"))
            .tag(TraceConfigurationMode.preset)
            .accessibilityIdentifier("trace.configuration.mode.preset")
          Text(traceString("trace.configuration.custom"))
            .tag(TraceConfigurationMode.custom)
            .accessibilityIdentifier("trace.configuration.mode.custom")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 200)
        .accessibilityIdentifier("trace.configuration.mode")
      }
    ) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        if model.configurationMode == .preset {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
            Text(traceString("trace.preset.label"))
              .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
              ForEach(
                TracePresetCatalog.definitions.filter { $0.id != .custom },
                id: \.id.rawValue
              ) { preset in
                presetRow(preset)
              }
            }
            .accessibilityIdentifier("trace.preset.picker")
            Text(traceString("trace.preset.logicalNote"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
        } else {
          customTags
        }

        if !model.requestedTags.isEmpty {
          requestedTagDiff
        }

        if model.selectedPresetID == .attachmentPanorama
          && model.configurationMode == .preset
        {
          traceNotice(
            traceString("trace.preset.attachmentWarning"),
            systemImage: "externaldrive.badge.exclamationmark",
            color: .orange,
            identifier: "trace.preset.resourceWarning")
        }

        DisclosureGroup(traceString("trace.probe.rawHelp.title")) {
          Text(model.selectedRuntimeProbe?.rawHelp ?? traceString("trace.probe.rawHelp.empty"))
            .font(WorkspaceFont.monospacedValue)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("trace.probe.rawHelp")
      }
    }
  }

  private var customTags: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      Text(traceString("trace.custom.title"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
      if model.selectedPreset.logicalTags.isEmpty {
        traceNotice(
          traceString("trace.custom.empty"),
          systemImage: "tag.slash",
          color: .secondary,
          identifier: "trace.custom.empty")
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: WorkspaceMetrics.tightGap)], spacing: WorkspaceMetrics.tightGap) {
          ForEach(model.selectedPreset.logicalTags, id: \.self) { tag in
            customTagToggle(tag)
          }
        }
        Text(
          LocalizedStringResource.TraceLocalizable.traceCustomCount(model.customTags.count)
        )
          .font(WorkspaceFont.monospacedDense.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("trace.custom.count")
      }
      Text(traceString("trace.custom.noFreeText"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
    }
  }

  /// The vocabulary is the current preset's logical family; a member can be
  /// trimmed and restored, and the last selected member refuses to toggle off
  /// because a capture always carries one tag.
  private func customTagToggle(_ tag: String) -> some View {
    let selected = model.customTags.contains(tag)
    let isLastSelected = selected && model.customTags.count == 1
    return Button {
      model.toggleCustomTag(tag)
    } label: {
      Label(tag, systemImage: selected ? "checkmark.circle.fill" : "circle")
        .font(WorkspaceFont.monospacedValue)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
        .padding(.vertical, WorkspaceMetrics.tightGap)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
          selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.clear),
          in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius, style: .continuous)
            .stroke(
              selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isLastSelected ? traceString("trace.custom.minimumOne") : "")
    .accessibilityValue(
      selected ? traceString("trace.value.selected") : traceString("trace.value.notSelected")
    )
    .accessibilityIdentifier("trace.custom.tag.\(tag)")
  }

  /// A preset row carries its own tag family in monospace: choosing a preset
  /// is choosing that request, so the reader matches name and members before
  /// the review section, not in a tooltip afterwards.
  private func presetRow(_ preset: TracePresetDefinition) -> some View {
    let selected =
      model.configurationMode == .preset && model.selectedPresetID == preset.id
    return Button {
      model.setPreset(preset.id)
    } label: {
      HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(traceString("trace.preset.\(preset.id.rawValue)"))
            .font(WorkspaceFont.body.weight(.semibold))
          Text(preset.logicalTags.joined(separator: " "))
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WorkspaceMetrics.tightGap)
      .padding(.vertical, WorkspaceMetrics.tightGap)
      // `.radio` in the prototype is a radio and a label, not a card: six
      // bordered boxes stacked down a column read as six separate objects and
      // spend most of the page's height on chrome.
      .background(
        selected ? Color.accentColor.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(
      selected ? traceString("trace.value.selected") : traceString("trace.value.notSelected")
    )
    .accessibilityIdentifier("trace.preset.option.\(preset.id.rawValue)")
  }

  private var requestedTagDiff: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      HStack {
        Text(traceString("trace.tags.title"))
          .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(
          String(
            localized: LocalizedStringResource.TraceLocalizable.traceTagsVerifiedCount(
              Int32(clamping: model.requestedTags.count - model.unsupportedRequestedTags.count),
              Int32(clamping: model.requestedTags.count)))
        )
        .font(WorkspaceFont.monospacedDense.monospacedDigit())
        .foregroundStyle(model.unsupportedRequestedTags.isEmpty ? Color.green : Color.orange)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: WorkspaceMetrics.tightGap)], spacing: WorkspaceMetrics.tightGap) {
        ForEach(model.requestedTags, id: \.self) { tag in
          let supported = model.confirmedTags.contains(tag)
          Label(tag, systemImage: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(WorkspaceFont.monospacedValue)
            .foregroundStyle(supported ? Color.green : Color.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .accessibilityLabel(
              "\(tag), \(traceString(supported ? "trace.tags.supported" : "trace.tags.unsupported"))"
            )
        }
      }
      Text(traceString("trace.tags.verifiedNote"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var captureBounds: some View {
    WorkspaceSection(Text(traceString("trace.bounds.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: WorkspaceMetrics.sectionGap) { boundFields }
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) { boundFields }
        }

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
          traceReviewRow(
            traceString("trace.bounds.maxTags"),
            model.workspace.operation.maximumTraceTagCount.map { String($0) }
              ?? traceString("trace.value.unavailable"),
            monospaced: true)
          traceReviewRow(
            traceString("trace.bounds.remoteStop"),
            traceString("trace.value.unverified"))
          traceReviewRow(
            traceString("trace.bounds.total"),
            traceString("trace.progress.indeterminate"))
        }

        traceNotice(
          traceString("trace.bounds.progressNote"),
          systemImage: "timer",
          color: .secondary,
          identifier: "trace.progress.honest")
      }
    }
  }

  @ViewBuilder
  private var boundFields: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Text(traceString("trace.bounds.duration"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
      HStack(spacing: WorkspaceMetrics.tightGap) {
        Picker(traceString("trace.bounds.duration"), selection: durationBinding) {
          ForEach(TraceConfigurationView.durationChoicesSeconds, id: \.self) { seconds in
            Text("\(seconds) s").tag(String(seconds))
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 200)
        .accessibilityIdentifier("trace.duration")
      }
      Label {
        Text(validationMessage(model.durationValidation))
      } icon: {
        Image(systemName: model.durationIsValid ? "checkmark.circle" : "exclamationmark.triangle")
      }
      .labelStyle(.titleAndIcon)
      .font(WorkspaceFont.secondary)
      .foregroundStyle(model.durationIsValid ? Color.secondary : Color.red)
      .accessibilityIdentifier("trace.duration.validation")
    }

    // The buffer is a fact the capability probe converges, not a value a
    // person types; the request preview stays read-only so no affordance
    // suggests re-trying a larger buffer against the device.
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Text(traceString("trace.bounds.buffer"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
      HStack(spacing: WorkspaceMetrics.tightGap) {
        Text(model.bufferText)
          .font(WorkspaceFont.tabularValue.weight(.semibold))
          .accessibilityIdentifier("trace.buffer")
        Text("KB").foregroundStyle(.secondary)
      }
      Text(traceString("trace.bounds.bufferConverged"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("trace.buffer.validation")
    }
  }

  /// The three closed duration steps the design vocabulary offers. A step
  /// outside the catalog range still fails validation below, so a narrowed
  /// range cannot be bypassed by the segmented control.
  static let durationChoicesSeconds = [10, 15, 30]

  private var parameterSnapshots: some View {
    WorkspaceSection(Text(traceString("trace.parameters.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        Text(traceString("trace.parameters.description"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Table(parameterRows) {
          TableColumn(traceString("trace.parameters.name")) { row in
            Text(row.name).font(WorkspaceFont.monospacedDense).textSelection(.enabled)
          }
          TableColumn(traceString("trace.parameters.desired")) { row in
            Text(row.desiredValue).font(WorkspaceFont.monospacedValue)
          }
          TableColumn(traceString("trace.parameters.before")) { row in
            Text(parameterBeforeValue(row.name))
              .font(WorkspaceFont.monospacedValue)
              .foregroundStyle(.primary)
          }
          TableColumn(traceString("trace.parameters.after")) { row in
            Text(parameterAfterValue(row.name))
              .font(WorkspaceFont.monospacedValue)
              .foregroundStyle(.secondary)
          }
          TableColumn(traceString("trace.parameters.restore")) { _ in
            Text(traceString("trace.parameters.notChanged"))
              .foregroundStyle(.secondary)
          }
        }
        .frame(minHeight: 26 * CGFloat(max(parameterRows.count, 1)) + 28)
        .accessibilityIdentifier("trace.parameters.table")

        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          parameterModeRow(.unchanged)
          parameterModeRow(.temporaryRestore)
          parameterModeRow(.persistentChange)
        }

        Toggle(isOn: persistentConfirmationBinding) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(traceString("trace.parameters.persistConfirm"))
              .font(.callout.weight(.semibold))
            Text(traceString("trace.parameters.persistConfirmDetail"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(model.parameterMode != .persistentChange || !model.canUsePersistentChange)
        .accessibilityIdentifier("trace.parameters.persistConfirm")
        .padding(.leading, 28)

        if model.hasParameterSnapshotFacts {
          traceNotice(
            traceString("trace.parameters.snapshotReady"),
            systemImage: "checkmark.shield",
            color: .green,
            identifier: "trace.parameters.snapshotReady")
        } else {
          traceNotice(
            model.workspace.probeFailure ?? traceString("trace.parameters.snapshotGap"),
            systemImage: "lock.trianglebadge.exclamationmark",
            color: .orange,
            identifier: "trace.parameters.snapshotGap")
        }

        HStack(alignment: .top, spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: "arrow.trianglehead.2.clockwise")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(traceString("trace.parameters.rebootTitle"))
              .font(.callout.weight(.semibold))
            Text(traceString("trace.parameters.rebootUnchanged"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var derivedFiltering: some View {
    WorkspaceSection(Text(traceString("trace.filter.title"))) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        Toggle(traceString("trace.filter.createFileAsset"), isOn: filterBinding)
          .disabled(!model.workspace.operation.supportsFilteredTraceArtifact)
          .accessibilityIdentifier("trace.filter.createFileAsset")
        Text(traceString("trace.filter.description"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        traceNotice(
          traceString("trace.filter.rawImmutable"),
          systemImage: "lock.doc",
          color: .green,
          identifier: "trace.filter.rawImmutable")
      }
    }
  }

  private var parameterRows: [TraceParameterTableRow] {
    TraceDebugParameterCatalog.definitions.map {
      TraceParameterTableRow(name: $0.name, desiredValue: $0.profileValue)
    }
  }

  private func parameterBeforeValue(_ name: String) -> String {
    if let evidence = model.traceParameterEvidence(name: name) {
      return parameterEvidenceValue(state: evidence.beforeState, value: evidence.beforeValue)
    }
    guard let observation = model.parameterObservation(name: name) else {
      return traceString("trace.parameters.notObserved")
    }
    return switch observation.state {
    case .value: observation.value ?? traceString("trace.value.unavailable")
    case .missing: traceString("trace.parameters.missing")
    case .unreadable: traceString("trace.parameters.unreadable")
    }
  }

  private func parameterAfterValue(_ name: String) -> String {
    guard let evidence = model.traceParameterEvidence(name: name) else {
      return traceString("trace.value.unverified")
    }
    return parameterEvidenceValue(state: evidence.afterState, value: evidence.afterValue)
  }

  private func parameterEvidenceValue(state: String, value: String?) -> String {
    switch state {
    case "value": value ?? traceString("trace.value.unavailable")
    case "missing": traceString("trace.parameters.missing")
    case "unreadable": traceString("trace.parameters.unreadable")
    default: traceString("trace.value.unverified")
    }
  }

  private var modeBinding: Binding<TraceConfigurationMode> {
    Binding(
      get: { model.configurationMode },
      set: { model.setConfigurationMode($0) })
  }

  private var presetBinding: Binding<String> {
    Binding(
      get: { model.selectedPresetID.rawValue },
      set: { value in
        if let preset = TracePresetID(rawValue: value) {
          model.setPreset(preset)
        }
      })
  }

  private var durationBinding: Binding<String> {
    Binding(
      get: { model.durationText },
      set: { model.setDurationText($0) })
  }

  private var persistentConfirmationBinding: Binding<Bool> {
    Binding(
      get: { model.persistentChangeConfirmed },
      set: { model.setPersistentChangeConfirmed($0) })
  }

  private var filterBinding: Binding<Bool> {
    Binding(
      get: { model.filtersCreateFileAsset },
      set: { model.setFiltersCreateFileAsset($0) })
  }

  private func parameterModeRow(_ mode: TraceParameterUISelection) -> some View {
    let selected = model.parameterMode == mode
    let enabled =
      mode == .unchanged
      || (mode == .temporaryRestore && model.canUseTemporaryRestore)
      || (mode == .persistentChange && model.canUsePersistentChange)
    return Button {
      model.setParameterMode(mode)
    } label: {
      HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(traceString("trace.parameters.mode.\(mode.rawValue)"))
            .font(.callout.weight(.semibold))
          Text(traceString("trace.parameters.mode.\(mode.rawValue).detail"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if !enabled {
          Text(traceString("trace.value.unavailable"))
            .font(WorkspaceFont.label)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WorkspaceMetrics.contentGap)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
          .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityValue(
      selected ? traceString("trace.value.selected") : traceString("trace.value.notSelected")
    )
    .accessibilityIdentifier("trace.parameters.mode.\(mode.rawValue)")
  }

  private func validationMessage(_ validation: TraceNumericInputValidation) -> String {
    switch validation {
    case .valid:
      return traceString("trace.validation.valid")
    case .invalid(.missing):
      return traceString("trace.validation.missing")
    case .invalid(.notDecimal):
      return traceString("trace.validation.decimal")
    case .invalid(.outsideRange(let range)):
      return String(
        localized: LocalizedStringResource.TraceLocalizable.traceValidationRange(
          Int32(clamping: range.lowerBound), Int32(clamping: range.upperBound)))
    }
  }
}

private struct TraceParameterTableRow: Identifiable {
  let name: String
  let desiredValue: String
  var id: String { name }
}
