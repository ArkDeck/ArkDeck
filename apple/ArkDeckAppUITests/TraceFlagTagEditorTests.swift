import AppKit
import ArkTraceRendering
import Observation
import SwiftUI
import XCTest

/// Hosts the same editor source as the App. No trace file, parser, Runtime,
/// device or ArkDeck application process participates in these regressions.
@MainActor
final class TraceFlagTagEditorTests: XCTestCase {
    func testSwitchingFlagsCommitsOnlyTheDepartingDraftAndInitializesTheNewFlag() throws {
        let restoreAccessibility = enableHostedAccessibility()
        defer { restoreAccessibility() }
        let fixture = Fixture()
        let window = makeWindow(fixture)
        defer { window.close() }
        let firstField = try field(in: window)
        XCTAssertEqual(firstField.stringValue, "Flag A")
        edit(firstField, to: "Draft for A")
        fixture.changeColor(id: 1, colorIndex: 3)
        settle(window)
        XCTAssertEqual(try field(in: window).stringValue, "Draft for A")
        XCTAssertTrue(fixture.commits.isEmpty, "a color update must not commit or reset the draft")

        fixture.selectedID = 2
        settle(window)
        XCTAssertEqual(fixture.commits, [Commit(id: 1, label: "Draft for A")])
        XCTAssertEqual(fixture.flags[0].label, "Draft for A")
        XCTAssertEqual(fixture.flags[1].label, "Flag B")
        let secondField = try field(in: window)
        XCTAssertEqual(secondField.stringValue, "Flag B", "B must never inherit A's draft")
        edit(secondField, to: "Draft for B")
        settle(window)
        fixture.selectedID = nil
        settle(window)
        XCTAssertEqual(fixture.commits, [
            Commit(id: 1, label: "Draft for A"), Commit(id: 2, label: "Draft for B"),
        ])
    }

    func testReturnCommitsOnceAndRemovalDoesNotRenameTheDeletedFlag() throws {
        let restoreAccessibility = enableHostedAccessibility()
        defer { restoreAccessibility() }
        let fixture = Fixture()
        let window = makeWindow(fixture)
        defer { window.close() }
        let textField = try field(in: window)
        edit(textField, to: "Committed A")
        settle(window)
        textField.sendAction(textField.action, to: textField.target)
        settle(window)
        XCTAssertNil(fixture.selectedID)
        XCTAssertEqual(fixture.commits, [Commit(id: 1, label: "Committed A")])

        fixture.selectedID = 2
        settle(window)
        edit(try field(in: window), to: "Must not be saved")
        settle(window)
        let remove = try XCTUnwrap(accessibilityElement(
            identifiedBy: "trace.flag.editor.remove", in: window.contentView!))
        XCTAssertEqual(remove.accessibilityPerformPress?(), true)
        settle(window)
        XCTAssertEqual(fixture.removals, [2])
        XCTAssertEqual(fixture.flags.map(\.id), [1])
        XCTAssertEqual(fixture.commits, [Commit(id: 1, label: "Committed A")])
    }

    private func makeWindow(_ fixture: Fixture) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorHost(fixture: fixture))
        settle(window)
        return window
    }

    private func field(in window: NSWindow) throws -> NSTextField {
        settle(window)
        return try XCTUnwrap(descendants(of: window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.isEditable })
    }

    private func edit(_ field: NSTextField, to value: String) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func accessibilityElement(
        identifiedBy identifier: String, in root: AnyObject
    ) -> AnyObject? {
        var pending: [AnyObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            // SwiftUI.AccessibilityNode implements the public ObjC selectors
            // without declaring NSAccessibilityProtocol conformance. Dynamic
            // optional dispatch also preserves the Bool ABI of AXPress.
            if element.accessibilityIdentifier?() == identifier { return element }
            pending.append(contentsOf: (element.accessibilityChildren?() ?? []).map {
                $0 as AnyObject
            })
        }
        return nil
    }

    private func enableHostedAccessibility() -> @MainActor () -> Void {
        // An unqueried, hidden NSHostingView does not materialize SwiftUI's
        // virtual AX children. Request the same per-application enhancement
        // that an AX client requests, then restore it after this fixture. It
        // changes neither VoiceOver nor the user's accessibility preferences.
        // AppKit exposes this request only through the informal AX selectors;
        // the control traversal and AXPress below use the modern selectors.
        let application = NSApplication.shared
        let attribute = "AXEnhancedUserInterface"
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = application.perform(getter, with: attribute)?.takeUnretainedValue()
            ?? NSNumber(value: false)
        application.perform(setter, with: NSNumber(value: true), with: attribute)
        return {
            application.perform(setter, with: previous, with: attribute)
        }
    }

    private func settle(_ window: NSWindow) {
        let deadline = Date.now.addingTimeInterval(0.15)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
        } while Date.now < deadline
    }

    fileprivate struct Commit: Equatable {
        let id: Int
        let label: String
    }

    @MainActor
    @Observable
    fileprivate final class Fixture {
        var flags = [
            TimelineFlag(id: 1, timestampNs: 100, label: "Flag A", colorIndex: 0),
            TimelineFlag(id: 2, timestampNs: 200, label: "Flag B", colorIndex: 1),
        ]
        var selectedID: Int? = 1
        var commits: [Commit] = []
        var removals: [Int] = []

        func rename(id: Int, label: String) {
            commits.append(Commit(id: id, label: label))
            guard let index = flags.firstIndex(where: { $0.id == id }) else { return }
            flags[index].label = label
        }

        func changeColor(id: Int, colorIndex: Int) {
            guard let index = flags.firstIndex(where: { $0.id == id }) else { return }
            flags[index].colorIndex = colorIndex
        }

        func remove(id: Int) {
            removals.append(id)
            flags.removeAll { $0.id == id }
            selectedID = nil
        }
    }

    private struct EditorHost: View {
        var fixture: Fixture

        var body: some View {
            if let flag = fixture.flags.first(where: { $0.id == fixture.selectedID }) {
                TraceFlagTagEditor(
                    flag: flag, timestampText: "\(flag.timestampNs) ns",
                    rename: fixture.rename,
                    cycleColor: fixture.changeColor,
                    remove: fixture.remove,
                    dismiss: { fixture.selectedID = nil })
            }
        }
    }
}
