import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import ArkDeckRuntime
import ArkDeckStorage
import ArkDeckWorkflows
import Foundation
import XCTest

/// Package-boundary contract tests. The tables below restate the dependency
/// contract from Package.swift and the app target; the tests enforce it by
/// scanning `import` statements in the source tree, so an undeclared
/// cross-module or UI-framework import fails here even if Package.swift is
/// edited to permit it.
final class ArkDeckContractTests: XCTestCase {
    private static let uiFrameworks: Set<String> = ["SwiftUI", "AppKit", "UIKit", "Cocoa"]

    private static let declaredPackageDependencies: [String: Set<String>] = [
        "ArkDeckCore": [],
        "ArkDeckProcess": ["ArkDeckCore"],
        "ArkDeckRuntime": ["ArkDeckCore"],
        "ArkDeckOpenHarmony": ["ArkDeckCore", "ArkDeckProcess"],
        "ArkDeckWorkflows": ["ArkDeckCore"],
        "ArkDeckStorage": ["ArkDeckCore"],
    ]

    func testPackageModulesRemainIndependentlyAddressable() {
        XCTAssertEqual(
            [
                ArkDeckCoreModule.identifier,
                ArkDeckProcessModule.identifier,
                ArkDeckRuntimeModule.identifier,
                ArkDeckOpenHarmonyModule.identifier,
                ArkDeckWorkflowsModule.identifier,
                ArkDeckStorageModule.identifier,
            ],
            [
                "ArkDeckCore",
                "ArkDeckProcess",
                "ArkDeckRuntime",
                "ArkDeckOpenHarmony",
                "ArkDeckWorkflows",
                "ArkDeckStorage",
            ]
        )
    }

    func testPackageTargetsImportOnlyDeclaredArkDeckModules() throws {
        for (target, allowed) in Self.declaredPackageDependencies.sorted(by: { $0.key < $1.key }) {
            for (file, modules) in try importsByFile(under: packageRoot.appending(path: "Sources/\(target)")) {
                for module in modules where module.hasPrefix("ArkDeck") && module != target {
                    XCTAssertTrue(
                        allowed.contains(module),
                        "\(target) imports \(module), which Package.swift does not declare (\(file))"
                    )
                }
            }
        }
    }

    func testPackageTargetsDoNotImportUIFrameworks() throws {
        for target in Self.declaredPackageDependencies.keys.sorted() {
            for (file, modules) in try importsByFile(under: packageRoot.appending(path: "Sources/\(target)")) {
                for module in modules where Self.uiFrameworks.contains(module) {
                    XCTFail("\(target) imports UI framework \(module) (\(file))")
                }
            }
        }
    }

    func testAppTargetImportsOnlyCoreFromArkDeckKit() throws {
        for (file, modules) in try importsByFile(under: repoRoot.appending(path: "ArkDeckApp")) {
            for module in modules where module.hasPrefix("ArkDeck") {
                XCTAssertEqual(module, "ArkDeckCore", "app shell imports \(module) (\(file))")
            }
        }
    }

    // MARK: - Source scanning

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArkDeckContractTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    private var repoRoot: URL {
        packageRoot
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    private func importsByFile(under directory: URL) throws -> [(file: String, modules: [String])] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        else {
            XCTFail("expected a source directory at \(directory.path)")
            return []
        }
        var results: [(file: String, modules: [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            results.append((file: url.lastPathComponent, modules: importedModules(in: source)))
        }
        XCTAssertFalse(results.isEmpty, "no Swift sources found under \(directory.path)")
        return results
    }

    /// Matches plain, attributed (`@testable`, `@preconcurrency`, …),
    /// access-level and declaration-kind imports, capturing the top-level
    /// module name.
    private func importedModules(in source: String) -> [String] {
        let pattern = #/^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_]\w*)/#
        return source.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = try? pattern.firstMatch(in: trimmed) else { return nil }
            return String(match.output.1)
        }
    }
}
