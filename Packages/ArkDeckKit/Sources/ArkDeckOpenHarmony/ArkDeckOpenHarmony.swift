import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Foundation

public enum ArkDeckOpenHarmonyModule {
    public static let identifier = "ArkDeckOpenHarmony"
}

/// Sources are ordered deliberately: a user-selected external HDC wins over
/// an SDK-discovered candidate, and the process `PATH` is never searched.
public enum HDCCandidateSource: String, Sendable, Equatable, CaseIterable {
    case userConfigured
    case devecoSDK
    case openHarmonySDK
}

public struct HDCDiscoveryRequest: Sendable, Equatable {
    public let userConfiguredPaths: [URL]
    public let devecoSDKPaths: [URL]
    public let openHarmonySDKPaths: [URL]

    public init(
        userConfiguredPaths: [URL] = [],
        devecoSDKPaths: [URL] = [],
        openHarmonySDKPaths: [URL] = []
    ) {
        self.userConfiguredPaths = userConfiguredPaths
        self.devecoSDKPaths = devecoSDKPaths
        self.openHarmonySDKPaths = openHarmonySDKPaths
    }
}

public struct HDCCandidate: Sendable, Equatable {
    public let path: URL
    public let source: HDCCandidateSource
    public let sha256: String

    public init(path: URL, source: HDCCandidateSource, sha256: String) {
        self.path = path
        self.source = source
        self.sha256 = sha256
    }
}

public enum HDCDiscoveryIssue: Sendable, Equatable {
    case pathMustBeAbsolute(path: String, source: HDCCandidateSource)
    case notAnExecutableFile(path: String, source: HDCCandidateSource)
    case hashFailed(path: String, source: HDCCandidateSource, reason: String)
}

public struct HDCDiscoveryReport: Sendable, Equatable {
    public let candidates: [HDCCandidate]
    public let issues: [HDCDiscoveryIssue]

    public init(candidates: [HDCCandidate], issues: [HDCDiscoveryIssue]) {
        self.candidates = candidates
        self.issues = issues
    }
}

/// Discovers only explicitly supplied external/SDK locations. It does not
/// execute a candidate and therefore cannot start, stop, or mutate an HDC
/// server.
public enum HDCExternalFirstDiscovery {
    public static func discover(_ request: HDCDiscoveryRequest) -> HDCDiscoveryReport {
        let orderedPaths: [(HDCCandidateSource, [URL])] = [
            (.userConfigured, request.userConfiguredPaths),
            (.devecoSDK, request.devecoSDKPaths),
            (.openHarmonySDK, request.openHarmonySDKPaths),
        ]
        var candidates: [HDCCandidate] = []
        var issues: [HDCDiscoveryIssue] = []
        var seenPaths = Set<String>()

        for (source, paths) in orderedPaths {
            for originalPath in paths {
                guard originalPath.isFileURL, originalPath.path.hasPrefix("/") else {
                    issues.append(.pathMustBeAbsolute(path: originalPath.path, source: source))
                    continue
                }
                let path = originalPath.resolvingSymlinksInPath().standardizedFileURL
                guard seenPaths.insert(path.path).inserted else { continue }
                guard FileManager.default.isExecutableFile(atPath: path.path) else {
                    issues.append(.notAnExecutableFile(path: path.path, source: source))
                    continue
                }
                do {
                    candidates.append(HDCCandidate(path: path, source: source, sha256: try sha256(of: path)))
                } catch {
                    issues.append(.hashFailed(path: path.path, source: source, reason: error.localizedDescription))
                }
            }
        }
        return HDCDiscoveryReport(candidates: candidates, issues: issues)
    }

    private static func sha256(of path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A diagnostic has a value only when a probe established it. Missing probe
/// fields are retained as explicit unknowns rather than omitted or guessed.
public enum HDCProbeValue<Value: Sendable & Equatable>: Sendable, Equatable {
    case known(Value)
    case unknown(reason: String)
}

public struct HDCProbeDetails: Sendable, Equatable {
    public let platformTrust: HDCProbeValue<String>
    public let clientVersion: HDCProbeValue<String>
    public let serverVersion: HDCProbeValue<String>
    public let daemonVersion: HDCProbeValue<String>
    public let serverGeneration: HDCProbeValue<Int>

    public init(
        platformTrust: HDCProbeValue<String>,
        clientVersion: HDCProbeValue<String>,
        serverVersion: HDCProbeValue<String>,
        daemonVersion: HDCProbeValue<String>,
        serverGeneration: HDCProbeValue<Int>
    ) {
        self.platformTrust = platformTrust
        self.clientVersion = clientVersion
        self.serverVersion = serverVersion
        self.daemonVersion = daemonVersion
        self.serverGeneration = serverGeneration
    }

    public static let unprobed = HDCProbeDetails(
        platformTrust: .unknown(reason: "ToolTrustInspector has not run"),
        clientVersion: .unknown(reason: "HDC version probe has not run"),
        serverVersion: .unknown(reason: "HDC server probe has not run"),
        daemonVersion: .unknown(reason: "HDC daemon probe has not run"),
        serverGeneration: .unknown(reason: "HDCServerSupervisor has not run")
    )
}

/// This is a value snapshot, not a reference to Settings. A Job can retain it
/// unchanged when the candidate list later changes.
public struct HDCJobToolchainSnapshot: Sendable, Equatable {
    public let path: URL
    public let source: HDCCandidateSource
    public let sha256: String
    public let endpoint: String
    public let platformTrust: HDCProbeValue<String>
    public let clientVersion: HDCProbeValue<String>
    public let serverVersion: HDCProbeValue<String>
    public let daemonVersion: HDCProbeValue<String>
    public let serverGeneration: HDCProbeValue<Int>

    public init(candidate: HDCCandidate, endpoint: String, details: HDCProbeDetails) {
        self.path = candidate.path
        self.source = candidate.source
        self.sha256 = candidate.sha256
        self.endpoint = endpoint
        self.platformTrust = details.platformTrust
        self.clientVersion = details.clientVersion
        self.serverVersion = details.serverVersion
        self.daemonVersion = details.daemonVersion
        self.serverGeneration = details.serverGeneration
    }
}

public enum HDCCommandSemanticResult: Sendable, Equatable {
    case success
    case failure(HDCCommandFailure)
    case unknownOutput
}

public enum HDCCommandFailure: Sendable, Equatable {
    case nonZeroExit(Int32)
    case explicitFailureMarker
    case unauthorized
    case offline
}

/// A bounded streaming parser for the currently declared fixture family. An
/// exit status of zero is necessary but deliberately insufficient for success.
/// Future output families must be added through an integration-profile change.
public struct HDCSemanticOutputParser: Sendable {
    private static let failureMarkers: [[UInt8]] = [
        Array("unauthorized".utf8),
        Array("e000002".utf8),
        Array("e000003".utf8),
        Array("offline".utf8),
        Array("[fail]".utf8),
        Array("errorcode".utf8),
    ]
    private static let successMarker = Array("[success]".utf8)
    private static let carryLength = max(
        successMarker.count,
        failureMarkers.map(\.count).max() ?? 0
    ) - 1

    /// ASCII-only marker matching keeps protocol markers intact across a UTF-8
    /// chunk boundary. Raw output itself remains available through the Process
    /// output stream and is not decoded or rewritten here.
    private var carry: [UInt8] = []
    private var hasSuccessMarker = false
    private var failure: HDCCommandFailure?

    public init() {}

    public mutating func consume(_ chunk: ProcessOutputChunk) {
        let normalizedChunk = chunk.bytes.map(asciiLowercased)
        let searchable = carry + normalizedChunk

        // Search the complete new chunk before retaining only a boundary carry.
        // A pipe may deliver 4–64 KiB at once, so truncating before this step
        // would allow an early failure marker to be hidden by later output.
        if contains(searchable, marker: Array("unauthorized".utf8))
            || contains(searchable, marker: Array("e000002".utf8))
            || contains(searchable, marker: Array("e000003".utf8)) {
            failure = .unauthorized
        } else if contains(searchable, marker: Array("offline".utf8)) {
            if failure == nil || failure == .explicitFailureMarker {
                failure = .offline
            }
        } else if contains(searchable, marker: Array("[fail]".utf8))
            || contains(searchable, marker: Array("errorcode".utf8)) {
            if failure == nil {
                failure = .explicitFailureMarker
            }
        }
        hasSuccessMarker = hasSuccessMarker || contains(searchable, marker: Self.successMarker)
        carry = Array(searchable.suffix(Self.carryLength))
    }

    public func finish(exitCode: Int32) -> HDCCommandSemanticResult {
        if exitCode != 0 {
            return .failure(.nonZeroExit(exitCode))
        }
        if let failure {
            return .failure(failure)
        }
        return hasSuccessMarker ? .success : .unknownOutput
    }

    private func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private func contains(_ bytes: [UInt8], marker: [UInt8]) -> Bool {
        guard !marker.isEmpty, bytes.count >= marker.count else { return false }
        return bytes.indices.contains { start in
            guard start + marker.count <= bytes.endIndex else { return false }
            return bytes[start..<(start + marker.count)].elementsEqual(marker)
        }
    }
}
