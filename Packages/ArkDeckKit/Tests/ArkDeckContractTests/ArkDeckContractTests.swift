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

final class ProcessAndHDCContractTests: XCTestCase {
    private let executor = FoundationProcessExecutor()

    func testProcessExecutorPassesSpecialArgumentsWithoutShellExpansion() async throws {
        let argument = "image with spaces/中文;$(do-not-run)&*.img"
        let result = try await executor.execute(
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", argument])
        )

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.stdout.data, as: UTF8.self), argument)
        XCTAssertEqual(result.stderr.totalByteCount, 0)
    }

    func testProcessExecutorSeparatesStreamsAndBoundsLargeOutput() async throws {
        let splitResult = try await executor.execute(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/awk"),
                arguments: ["BEGIN { print \"stdout-marker\"; print \"stderr-marker\" > \"/dev/stderr\" }"]
            )
        )
        XCTAssertEqual(splitResult.termination, .exited(0))
        XCTAssertTrue(String(decoding: splitResult.stdout.data, as: UTF8.self).contains("stdout-marker"))
        XCTAssertTrue(String(decoding: splitResult.stderr.data, as: UTF8.self).contains("stderr-marker"))

        let largeResult = try await executor.execute(
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: 0.15),
            captureLimit: 4 * 1024
        )
        XCTAssertEqual(largeResult.termination, .timedOut)
        XCTAssertGreaterThan(largeResult.stdout.totalByteCount, 4 * 1024)
        XCTAssertEqual(largeResult.stdout.data.count, 4 * 1024)
        XCTAssertTrue(largeResult.stdout.wasTruncated)
    }

    func testProcessExecutorCancellationTerminatesTheRunningProcess() async throws {
        let executor = FoundationProcessExecutor()
        let task = Task {
            try await executor.execute(
                ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.termination, .cancelled)
    }

    func testProcessExecutorKeepsNormalExitWhenTimeoutHasNotExpired() async throws {
        let result = try await executor.execute(
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 1)
        )

        XCTAssertEqual(result.termination, .exited(0))
    }

    func testProcessExecutorRejectsNULArgumentBeforeOpeningPipes() async {
        do {
            _ = try await executor.execute(
                ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["invalid\0argument"])
            )
            XCTFail("a NUL-containing argv element must not launch a process")
        } catch let error as ProcessExecutionError {
            XCTAssertEqual(error, .invalidArgumentContainsNUL)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testProcessExecutorCancellationTerminatesTheEntireProcessGroup() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else {
            throw XCTSkip("macOS Perl fixture is unavailable")
        }
        let executor = FoundationProcessExecutor()
        let startedAt = Date()
        let task = Task {
            try await executor.execute(
                ProcessRequest(
                    executable: perl,
                    arguments: ["-e", "my $child = fork(); if ($child == 0) { sleep 5; exit 0; } sleep 5;"]
                )
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let result = try await task.value
        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5, "a child retaining stdout/stderr must not survive cancellation")
    }

    func testExternalFirstDiscoveryAndJobSnapshotRemainStable() throws {
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        let report = HDCExternalFirstDiscovery.discover(
            HDCDiscoveryRequest(
                userConfiguredPaths: [printf],
                devecoSDKPaths: [printf, URL(fileURLWithPath: "/usr/bin/yes")],
                openHarmonySDKPaths: [try XCTUnwrap(URL(string: "relative/hdc"))]
            )
        )

        XCTAssertEqual(report.candidates.map(\.path.path), ["/usr/bin/printf", "/usr/bin/yes"])
        XCTAssertEqual(report.candidates.map(\.source), [.userConfigured, .devecoSDK])
        XCTAssertTrue(report.issues.contains(.pathMustBeAbsolute(path: "relative/hdc", source: .openHarmonySDK)))

        let details = HDCProbeDetails(
            platformTrust: .unknown(reason: "not inspected in this prototype"),
            clientVersion: .known("5.0.0"),
            serverVersion: .known("5.0.0"),
            daemonVersion: .known("5.0.0"),
            serverGeneration: .known(7)
        )
        let snapshot = HDCJobToolchainSnapshot(candidate: try XCTUnwrap(report.candidates.first), endpoint: "127.0.0.1:8710", details: details)

        XCTAssertEqual(snapshot.path, printf)
        XCTAssertEqual(snapshot.source, .userConfigured)
        XCTAssertEqual(snapshot.serverGeneration, .known(7))
        XCTAssertEqual(snapshot.clientVersion, .known("5.0.0"))
        XCTAssertEqual(snapshot.endpoint, "127.0.0.1:8710")
        XCTAssertEqual(snapshot.platformTrust, .unknown(reason: "not inspected in this prototype"))
    }

    func testSemanticParserRejectsExitZeroFailureFixtureAndStreamsLargeFixture() throws {
        var failureParser = HDCSemanticOutputParser()
        failureParser.consume(ProcessOutputChunk(stream: .stdout, bytes: HDCFixtures.exitZeroFailure))
        XCTAssertEqual(failureParser.finish(exitCode: 0), .failure(.unauthorized))

        var parser = HDCSemanticOutputParser()
        for _ in 0..<HDCFixtures.largeOutputRepeatCount {
            parser.consume(ProcessOutputChunk(stream: .stdout, bytes: HDCFixtures.largeOutputChunk))
        }
        parser.consume(ProcessOutputChunk(stream: .stderr, bytes: HDCFixtures.largeOutputFailureTail))
        XCTAssertGreaterThan(HDCFixtures.largeOutputChunk.count * HDCFixtures.largeOutputRepeatCount, 1_000_000)
        XCTAssertEqual(parser.finish(exitCode: 0), .failure(.offline))

        var unknownParser = HDCSemanticOutputParser()
        unknownParser.consume(ProcessOutputChunk(stream: .stdout, bytes: Data("unrecognised output".utf8)))
        XCTAssertEqual(unknownParser.finish(exitCode: 0), .unknownOutput)
    }

    func testSemanticParserFindsFailureInLargeChunkBeforeTrailingSuccess() {
        var parser = HDCSemanticOutputParser()
        let bytes = Data(("[Fail] E000003 Unauthorized" + String(repeating: "x", count: 300) + "[Success]").utf8)
        parser.consume(ProcessOutputChunk(stream: .stdout, bytes: bytes))

        XCTAssertEqual(parser.finish(exitCode: 0), .failure(.unauthorized))
    }

    func testSemanticParserRecognisesASCIIMarkerSplitAcrossChunks() {
        var parser = HDCSemanticOutputParser()
        parser.consume(ProcessOutputChunk(stream: .stdout, bytes: Data("prefix [Fa".utf8)))
        parser.consume(ProcessOutputChunk(stream: .stderr, bytes: Data("il] suffix".utf8)))

        XCTAssertEqual(parser.finish(exitCode: 0), .failure(.explicitFailureMarker))
    }

}
