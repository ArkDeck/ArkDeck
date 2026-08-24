import Foundation
import XCTest

/// Source-level guard for the two Find commands and the fields they focus.
///
/// The app has two searches — the sidebar's process filter and the toolbar's
/// event search — so it has two Find items rather than one ⌘F that has to
/// guess. Both are wired through the controller, because SwiftUI's
/// `@FocusState` does not survive a menu command here: the state flips and the
/// key window hands first responder straight back, so the field opens without
/// the keyboard. `FocusableTextField` makes the request in AppKit instead, and
/// that is also where the focus ring is turned off. There is no UI harness for
/// any of this, so it is parsed out of ArkDeck's App composition root and
/// migrated Trace Viewer source, the way `ObservationBoundaryTests` does.
final class AppCommandTests: XCTestCase {
    private static let appSource: String = {
        (try? TraceTestRepositoryPaths.readAppAndViewerSource()) ?? ""
    }()

    private func source() throws -> String {
        let source = Self.appSource
        XCTAssertFalse(source.isEmpty, "app source is unreadable")
        return source
    }

    func testFindCommandsAreBoundAndReachTheController() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(
                #"Button("Filter Trace Processes") { models.traceDocument.focusProcessFilter() }"#
            ),
            "the sidebar's filter needs a Find item"
        )
        XCTAssertTrue(
            source.contains(#".keyboardShortcut("f")"#),
            "⌘F, unmodified, must open the sidebar's process filter"
        )
        XCTAssertTrue(
            source.contains(
                #"Button("Search Trace Events") { models.traceDocument.focusTraceSearch() }"#
            ),
            "the toolbar search needs a binding of its own, or ⌘F is ambiguous"
        )
        XCTAssertTrue(
            source.contains(#".keyboardShortcut("f", modifiers: [.command, .shift])"#),
            "⇧⌘F must reach the toolbar search"
        )
    }

    /// Both fields are AppKit-backed: it is the only way the menu's focus
    /// request lands, and the only place the ring can be switched off.
    func testBothSearchFieldsAreFocusableFromTheMenu() throws {
        let source = try source()
        for requestID in ["controller.processFilterFocusRequestID", "controller.searchFocusRequestID"] {
            XCTAssertTrue(
                source.contains("focusRequestID: \(requestID)"),
                "a field with no focus request cannot answer its menu item (\(requestID))"
            )
        }
        XCTAssertTrue(
            source.contains("window.makeFirstResponder(field)"),
            "the focus request has to reach AppKit; SwiftUI focus does not survive the menu"
        )
    }

    func testFocusedFieldsDrawNoRing() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains("field.focusRingType = .none"),
            "a focused field is shown by its caret, not by a blue ring"
        )
    }

    func testCaptureIsReachableFromMenuToolbarAndEmptyState() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains("models.requestTraceWorkspace()")
                && source.contains("openWindow(id: ArkDeckWindow.main)"),
            "capture must route back through ArkDeck's typed Trace workspace"
        )
        XCTAssertTrue(
            source.contains(#"Button("Capture Trace…") {"#)
                && source.contains(#".keyboardShortcut("n")"#),
            "Trace → Capture Trace… must have the native ⌘N command"
        )
        XCTAssertTrue(
            source.contains(#"Label("Capture", systemImage: "record.circle")"#),
            "the main toolbar must expose capture"
        )
        XCTAssertTrue(
            source.contains(#"Button("Capture Trace…", action: openCapture)"#),
            "the no-document state must offer capture without requiring the menu"
        )
    }
}
