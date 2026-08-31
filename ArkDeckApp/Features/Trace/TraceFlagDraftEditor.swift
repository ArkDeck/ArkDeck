import AppKit
import ArkTraceRendering
import SwiftUI

/// Writes the tag where its flag stands. Draft edits remain local until
/// Return or dismissal because each commit persists the annotation sidecar.
struct TraceFlagDraftEditor: View {
    let flag: TimelineFlag
    let timestampText: String
    let rename: @MainActor (String) -> Void
    let cycleColor: @MainActor () -> Void
    let remove: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    @State private var text: String
    @State private var shouldCommitDraft = true
    @FocusState private var fieldIsFocused: Bool

    init(
        flag: TimelineFlag,
        timestampText: String,
        rename: @escaping @MainActor (String) -> Void,
        cycleColor: @escaping @MainActor () -> Void,
        remove: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        self.flag = flag
        self.timestampText = timestampText
        self.rename = rename
        self.cycleColor = cycleColor
        self.remove = remove
        self.dismiss = dismiss
        _text = State(initialValue: flag.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(editorText("Tag"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($fieldIsFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("trace.flag.editor.name")
            HStack(spacing: 10) {
                Button(action: cycleColor) {
                    Label(editorText("Change Colour"), systemImage: "circle.fill")
                        .foregroundStyle(
                            Color(cgColor: TimelineAnnotationColor.cgColor(at: flag.colorIndex))
                        )
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(editorText("Change Colour"))
                .arktraceAccessibleTarget()
                .accessibilityIdentifier("trace.flag.editor.color")
                Text(timestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(editorText("Remove"), role: .destructive, action: removeFlag)
                    .arktraceAccessibleTarget()
                    .accessibilityIdentifier("trace.flag.editor.remove")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(radius: 10, y: 3)
        .onExitCommand(perform: dismiss)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldIsFocused = true
        }
        // Return saves once. Removing a flag must not generate a late rename
        // when SwiftUI subsequently removes the editor from the hierarchy.
        .onDisappear(perform: commitDraft)
    }

    private func submit() {
        commitDraft()
        dismiss()
    }

    private func commitDraft() {
        guard shouldCommitDraft else { return }
        shouldCommitDraft = false
        rename(text)
    }

    private func removeFlag() {
        shouldCommitDraft = false
        remove()
    }

    private func editorText(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "TraceViewerLocalizable")
    }
}
