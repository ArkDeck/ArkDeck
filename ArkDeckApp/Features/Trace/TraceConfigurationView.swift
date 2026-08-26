import ArkDeckWorkflows
import SwiftUI

struct TraceConfigurationView: View {
  var model: TraceWorkspaceViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
      targetControl
      profileControl
      durationControl
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(model.isSubmitting)
  }

  private var targetControl: some View {
    LabeledContent(traceString("trace.capture.device")) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        if model.targets.isEmpty {
          traceNotice(
            model.workspace.targetLoadFailure ?? traceString("trace.target.empty"),
            systemImage: "externaldrive.badge.questionmark",
            color: .secondary,
            identifier: "trace.target.empty")
        } else {
          Picker(traceString("trace.capture.device"), selection: targetBinding) {
            ForEach(model.targets) { target in
              Text(model.deviceTitle(target)).tag(target.id)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 440, alignment: .leading)
          .accessibilityLabel(traceString("trace.capture.device"))
          .accessibilityIdentifier("trace.target.picker")
        }

        if let target = model.selectedTarget,
          let summary = target.connectionSummary
        {
          Text(summary)
            .font(WorkspaceFont.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(target.accessibleConnectionSummary ?? summary)
            .accessibilityLabel(target.accessibleConnectionSummary ?? summary)
            .accessibilityIdentifier("trace.target.deviceSummary")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var profileControl: some View {
    LabeledContent(traceString("trace.capture.profile")) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Picker(traceString("trace.capture.profile"), selection: presetBinding) {
          ForEach(model.capturePresets, id: \.id.rawValue) { preset in
            Text(traceString("trace.preset.\(preset.id.rawValue)"))
              .tag(preset.id.rawValue)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel(traceString("trace.capture.profile"))
        .accessibilityIdentifier("trace.profile.picker")

        Text(profileDescription)
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: WorkspaceMetrics.proseMaxWidth, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var durationControl: some View {
    LabeledContent(traceString("trace.bounds.duration")) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          TextField(traceString("trace.bounds.duration"), text: durationBinding)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(WorkspaceFont.tabularValue)
            .frame(width: 72)
            .frame(minHeight: 28)
            .accessibilityLabel(traceString("trace.bounds.duration"))
            .accessibilityIdentifier("trace.duration.input")

          Picker(traceString("trace.duration.unit"), selection: durationUnitBinding) {
            ForEach(model.availableDurationUnits) { unit in
              Text(durationUnitTitle(unit)).tag(unit)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 190, minHeight: 28)
          .accessibilityLabel(traceString("trace.duration.unit"))
          .accessibilityIdentifier("trace.duration.unit")
        }

        Text(traceString("trace.duration.quick"))
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 64), spacing: WorkspaceMetrics.tightGap)],
          spacing: WorkspaceMetrics.tightGap
        ) {
          ForEach(model.durationUnit.quickValues, id: \.self) { value in
            quickDurationToggle(value)
          }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityIdentifier("trace.duration.quick")

        if !model.durationIsValid {
          Label(validationMessage, systemImage: "exclamationmark.circle")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("trace.duration.validation")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func quickDurationToggle(_ value: Int) -> some View {
    Toggle(
      isOn: Binding(
        get: { model.durationText == String(value) },
        set: { selected in
          if selected { model.selectQuickDuration(value) }
        }
      )
    ) {
      Text(quickDurationTitle(value))
        .monospacedDigit()
        .frame(maxWidth: .infinity)
    }
    .toggleStyle(.button)
    .frame(minHeight: 32)
    .disabled(!model.quickDurationIsAvailable(value))
    .help(quickDurationAccessibilityLabel(value))
    .accessibilityLabel(quickDurationAccessibilityLabel(value))
    .accessibilityIdentifier("trace.duration.quick.\(model.durationUnit.rawValue).\(value)")
  }

  private var targetBinding: Binding<String> {
    Binding(
      get: { model.selectedTargetID },
      set: { model.setTargetID($0) })
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

  private var durationUnitBinding: Binding<TraceDurationInputUnit> {
    Binding(
      get: { model.durationUnit },
      set: { model.setDurationUnit($0) })
  }

  private var profileDescription: String {
    switch model.selectedPresetID {
    case .arkuiDeep:
      traceString("trace.preset.arkuiDeep.detail")
    case .renderAnimation:
      traceString("trace.preset.renderAnimation.detail")
    case .schedulingIpc:
      traceString("trace.preset.schedulingIpc.detail")
    case .io:
      traceString("trace.preset.io.detail")
    case .attachmentPanorama:
      traceString("trace.preset.attachmentPanorama.detail")
    case .custom:
      traceString("trace.preset.arkuiDeep.detail")
    }
  }

  private func durationUnitTitle(_ unit: TraceDurationInputUnit) -> String {
    switch unit {
    case .seconds: traceString("trace.duration.seconds")
    case .minutes: traceString("trace.duration.minutes")
    }
  }

  private func quickDurationTitle(_ value: Int) -> String {
    "\(value)\(model.durationUnit == .seconds ? "s" : " min")"
  }

  private func quickDurationAccessibilityLabel(_ value: Int) -> String {
    switch (model.durationUnit, value) {
    case (.seconds, 5): traceString("trace.duration.set5Seconds")
    case (.seconds, 10): traceString("trace.duration.set10Seconds")
    case (.seconds, 15): traceString("trace.duration.set15Seconds")
    case (.seconds, 30): traceString("trace.duration.set30Seconds")
    case (.minutes, 1): traceString("trace.duration.set1Minute")
    case (.minutes, 2): traceString("trace.duration.set2Minutes")
    case (.minutes, 3): traceString("trace.duration.set3Minutes")
    default: traceString("trace.duration.setCustom")
    }
  }

  private var validationMessage: String {
    switch model.durationValidation {
    case .valid:
      return ""
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
