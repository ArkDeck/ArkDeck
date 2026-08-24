import Foundation

enum TraceTestRepositoryPaths {
    static let packageRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()  // ArkDeckTraceAppSupportTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ArkDeckKit

    static let repositoryRoot = packageRoot
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // ArkDeck

    static let appSourceURL = repositoryRoot.appending(
        path: "ArkDeckApp/App/ArkDeckApp.swift"
    )
    static let viewerSourceURL = repositoryRoot.appending(
        path: "ArkDeckApp/Features/Trace/TraceViewerWorkspaceView.swift"
    )
    static let settingsSourceURL = repositoryRoot.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"
    )
    static let traceCatalogURL = repositoryRoot.appending(
        path: "ArkDeckApp/Resources/TraceViewerLocalizable.xcstrings"
    )
    static let infoPlistURL = repositoryRoot.appending(path: "ArkDeckApp/Info.plist")
    static let traceStreamerHelperEntitlementsURL = repositoryRoot.appending(
        path: "ArkDeckApp/TraceStreamerHelper.entitlements"
    )
    static let traceRuntimeInputListURL = repositoryRoot.appending(
        path: "ArkDeckApp/TraceRuntimeResources.xcfilelist"
    )
    static let traceRuntimeOutputListURL = repositoryRoot.appending(
        path: "ArkDeckApp/TraceRuntimeOutputs.xcfilelist"
    )
    static let projectFileURL = repositoryRoot.appending(
        path: "ArkDeck.xcodeproj/project.pbxproj"
    )

    static func read(_ urls: [URL]) throws -> String {
        try urls.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    static func readAppAndViewerSource() throws -> String {
        try read([appSourceURL, viewerSourceURL])
    }

    static func readAllTraceAppSource() throws -> String {
        try read([appSourceURL, viewerSourceURL, settingsSourceURL])
    }
}
