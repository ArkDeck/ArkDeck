import XCTest
@testable import ArkDeckCore

final class ArkDeckCoreTests: XCTestCase {
    func testShellNavigationContainsOnlyDeclaredMVPSections() {
        XCTAssertEqual(
            ArkDeckNavigationItem.allCases.map(\.rawValue),
            ["overview", "flash", "debug", "uiDump", "trace", "history"]
        )
    }

    func testShellNavigationUsesStableLocalizationKeys() {
        XCTAssertEqual(ArkDeckNavigationItem.uiDump.localizationKey, "app.navigation.uiDump")
        XCTAssertEqual(ArkDeckNavigationItem.uiDump.systemImageName, "rectangle.3.group")
    }
}
