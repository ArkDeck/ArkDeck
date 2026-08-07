import ArkDeckWorkflows
import Foundation
import SwiftUI

struct TraceConfigurationView: View {
  @ObservedObject var model: TraceWorkspaceViewModel

  var body: some View {
    VStack(spacing: 18) {
      presetAndTags
      captureBounds
      parameterSnapshots
      derivedFiltering
    }
  }

  private var presetAndTags: some View {
    GroupBox(traceString("trace.configuration.title")) {
      VStack(alignment: .leading, spacing: 14) {
        Picker(traceString("trace.configuration.mode"), selection: modeBinding) {
          Text(traceString("trace.configuration.preset"))
            .tag(TraceConfigurationMode.preset)
            .accessibilityIdentifier("trace.configuration.mode.preset")
          Text(traceString("trace.configuration.custom"))
            .tag(TraceConfigurationMode.custom)
            .accessibilityIdentifier("trace.configuration.mode.custom")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .accessibilityIdentifier("trace.configuration.mode")

        if model.configurationMode == .preset {
          VStack(alignment: .leading, spacing: 6) {
            Text(traceString("trace.preset.label"))
              .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
              ForEach(
                TracePresetCatalog.definitions.filter { $0.id != .custom },
                id: \.id.rawValue
              ) { preset in
                presetRow(preset)
              }
            }
            .accessibilityIdentifier("trace.preset.picker")
            Text(traceString("trace.preset.logicalNote"))
              .font(.footnote)
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
          Text(traceString("trace.probe.rawHelp.empty"))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("trace.probe.rawHelp")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var customTags: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(traceString("trace.custom.title"))
        .font(.subheadline.weight(.semibold))
      if model.selectedPreset.logicalTags.isEmpty {
        traceNotice(
          traceString("trace.custom.empty"),
          systemImage: "tag.slash",
          color: .secondary,
          identifier: "trace.custom.empty")
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
          ForEach(model.selectedPreset.logicalTags, id: \.self) { tag in
            customTagToggle(tag)
          }
        }
        Text(String(format: traceString("trace.custom.count"), model.customTags.count))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("trace.custom.count")
      }
      Text(traceString("trace.custom.noFreeText"))
        .font(.footnote)
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
        .font(.callout.monospaced())
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          selected
            ? AnyShapeStyle(Color.accentColor.opacity(0.14))
            : AnyShapeStyle(.quaternary.opacity(0.5)),
          in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(isLastSelected ? traceString("trace.custom.minimumOne") : "")
    .accessibilityValue(
      selected ? traceString("trace.value.selected") : traceString("trace.value.notSelected"))
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
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(traceString("trace.preset.\(preset.id.rawValue)"))
            .font(.callout.weight(.semibold))
          Text(preset.logicalTags.joined(separator: " "))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(
      selected ? traceString("trace.value.selected") : traceString("trace.value.notSelected"))
    .accessibilityIdentifier("trace.preset.option.\(preset.id.rawValue)")
  }

  private var requestedTagDiff: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(traceString("trace.tags.title"))
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 12)
        Text(traceString("trace.tags.unverifiedCount") + " \(model.requestedTags.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.orange)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
        ForEach(model.requestedTags, id: \.self) { tag in
          Label(tag, systemImage: "questionmark.circle")
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .accessibilityLabel("\(tag), \(traceString("trace.tags.unverified"))")
        }
      }
      Text(traceString("trace.tags.unverifiedNote"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var captureBounds: some View {
    GroupBox(traceString("trace.bounds.title")) {
      VStack(alignment: .leading, spacing: 12) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 24) { boundFields }
          VStack(alignment: .leading, spacing: 12) { boundFields }
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
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var boundFields: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(traceString("trace.bounds.duration"))
        .font(.subheadline.weight(.semibold))
      HStack(spacing: 6) {
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
      Text(validationMessage(model.durationValidation))
        .font(.footnote)
        .foregroundStyle(model.durationIsValid ? Color.secondary : Color.red)
        .accessibilityIdentifier("trace.duration.validation")
    }

    // The buffer is a fact the capability probe converges, not a value a
    // person types; the request preview stays read-only so no affordance
    // suggests re-trying a larger buffer against the device.
    VStack(alignment: .leading, spacing: 5) {
      Text(traceString("trace.bounds.buffer"))
        .font(.subheadline.weight(.semibold))
      HStack(spacing: 6) {
        Text(model.bufferText)
          .font(.body.monospacedDigit().weight(.semibold))
          .accessibilityIdentifier("trace.buffer")
        Text("KB").foregroundStyle(.secondary)
      }
      Text(traceString("trace.bounds.bufferConverged"))
        .font(.footnote)
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
    GroupBox(traceString("trace.parameters.title")) {
      VStack(alignment: .leading, spacing: 12) {
        Text(traceString("trace.parameters.description"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Table(parameterRows) {
          TableColumn(traceString("trace.parameters.name")) { row in
            Text(row.name).font(.caption.monospaced()).textSelection(.enabled)
          }
          TableColumn(traceString("trace.parameters.desired")) { row in
            Text(row.desiredValue).font(.callout.monospaced())
          }
          TableColumn(traceString("trace.parameters.before")) { _ in
            Text(traceString("trace.parameters.notObserved"))
              .foregroundStyle(.secondary)
          }
          TableColumn(traceString("trace.parameters.probe")) { _ in
            Text(traceString("trace.value.unverified"))
              .foregroundStyle(.secondary)
          }
          TableColumn(traceString("trace.parameters.restore")) { _ in
            Text(traceString("trace.value.unavailable"))
              .foregroundStyle(.secondary)
          }
        }
        .frame(minHeight: 230)
        .accessibilityIdentifier("trace.parameters.table")

        VStack(alignment: .leading, spacing: 8) {
          parameterModeRow(.unchanged)
          parameterModeRow(.temporaryRestore)
          parameterModeRow(.persistentChange)
        }

        Toggle(isOn: persistentConfirmationBinding) {
          VStack(alignment: .leading, spacing: 2) {
            Text(traceString("trace.parameters.persistConfirm"))
              .font(.callout.weight(.semibold))
            Text(traceString("trace.parameters.persistConfirmDetail"))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(model.parameterMode != .persistentChange || !model.canUsePersistentChange)
        .accessibilityIdentifier("trace.parameters.persistConfirm")
        .padding(.leading, 28)

        traceNotice(
          traceString("trace.parameters.snapshotGap"),
          systemImage: "lock.trianglebadge.exclamationmark",
          color: .orange,
          identifier: "trace.parameters.snapshotGap")

        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "arrow.trianglehead.2.clockwise")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(traceString("trace.parameters.rebootTitle"))
              .font(.callout.weight(.semibold))
            Text(traceString("trace.parameters.rebootUnchanged"))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var derivedFiltering: some View {
    GroupBox(traceString("trace.filter.title")) {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(traceString("trace.filter.createFileAsset"), isOn: filterBinding)
          .accessibilityIdentifier("trace.filter.createFileAsset")
        Text(traceString("trace.filter.description"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        traceNotice(
          traceString("trace.filter.rawImmutable"),
          systemImage: "lock.doc",
          color: .green,
          identifier: "trace.filter.rawImmutable")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var parameterRows: [TraceParameterTableRow] {
    TraceDebugParameterCatalog.definitions.map {
      TraceParameterTableRow(name: $0.name, desiredValue: $0.profileValue)
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
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(traceString("trace.parameters.mode.\(mode.rawValue)"))
            .font(.callout.weight(.semibold))
          Text(traceString("trace.parameters.mode.\(mode.rawValue).detail"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if !enabled {
          Text(traceString("trace.value.unavailable"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
      .overlay {
        RoundedRectangle(cornerRadius: 8)
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
        format: traceString("trace.validation.range"), range.lowerBound, range.upperBound)
    }
  }
}

private struct TraceParameterTableRow: Identifiable {
  let name: String
  let desiredValue: String
  var id: String { name }
}
