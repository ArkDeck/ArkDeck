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
          Text(traceString("trace.configuration.custom"))
            .tag(TraceConfigurationMode.custom)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .accessibilityIdentifier("trace.configuration.mode")

        if model.configurationMode == .preset {
          VStack(alignment: .leading, spacing: 6) {
            Text(traceString("trace.preset.label"))
              .font(.subheadline.weight(.semibold))
            Picker(traceString("trace.preset.label"), selection: presetBinding) {
              ForEach(
                TracePresetCatalog.definitions.filter { $0.id != .custom },
                id: \.id.rawValue
              ) { preset in
                Text(traceString("trace.preset.\(preset.id.rawValue)"))
                  .tag(preset.id.rawValue)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
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
      if model.confirmedTags.isEmpty {
        traceNotice(
          traceString("trace.custom.empty"),
          systemImage: "tag.slash",
          color: .secondary,
          identifier: "trace.custom.empty")
      }
      Text(traceString("trace.custom.noFreeText"))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
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
        TextField(traceString("trace.bounds.duration"), text: durationBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
          .accessibilityIdentifier("trace.duration")
        Text(traceString("trace.bounds.seconds")).foregroundStyle(.secondary)
      }
      Text(validationMessage(model.durationValidation))
        .font(.footnote)
        .foregroundStyle(model.durationIsValid ? Color.secondary : Color.red)
        .accessibilityIdentifier("trace.duration.validation")
    }

    VStack(alignment: .leading, spacing: 5) {
      Text(traceString("trace.bounds.buffer"))
        .font(.subheadline.weight(.semibold))
      HStack(spacing: 6) {
        TextField(traceString("trace.bounds.buffer"), text: bufferBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
          .accessibilityIdentifier("trace.buffer")
        Text("KB").foregroundStyle(.secondary)
      }
      Text(validationMessage(model.bufferValidation))
        .font(.footnote)
        .foregroundStyle(model.bufferIsValid ? Color.secondary : Color.red)
        .accessibilityIdentifier("trace.buffer.validation")
    }
  }

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

  private var bufferBinding: Binding<String> {
    Binding(
      get: { model.bufferText },
      set: { model.setBufferText($0) })
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
