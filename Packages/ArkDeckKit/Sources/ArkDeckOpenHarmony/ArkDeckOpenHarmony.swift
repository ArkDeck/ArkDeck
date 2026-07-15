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

// MARK: - Host-wide HDC server supervision

/// An endpoint is host-wide infrastructure, never a per-device connection
/// detail. The supervisor uses this type to keep all affected coordinators in
/// the same event and lifecycle domain.
public struct HDCServerEndpoint: Hashable, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "An HDC server endpoint must not be empty")
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum HDCServerOwnership: String, Sendable, Equatable {
    case external
    case arkDeckManaged
    case unknown
}

public enum HDCServerHealth: String, Sendable, Equatable {
    case healthy
    case unavailable
    case unknown
}

public struct HDCServerState: Sendable, Equatable {
    public let endpoint: HDCServerEndpoint
    public let health: HDCServerHealth
    public let version: HDCProbeValue<String>
    public let generation: Int
    public let ownership: HDCServerOwnership

    public init(
        endpoint: HDCServerEndpoint,
        health: HDCServerHealth,
        version: HDCProbeValue<String>,
        generation: Int,
        ownership: HDCServerOwnership
    ) {
        precondition(generation >= 0, "A server generation must not be negative")
        self.endpoint = endpoint
        self.health = health
        self.version = version
        self.generation = generation
        self.ownership = ownership
    }
}

/// Observations of an already-running server can only establish external or
/// unknown ownership. ArkDeck-managed ownership has a separate evidence gate.
public struct HDCExistingServerObservation: Sendable, Equatable {
    public let state: HDCServerState

    public init(state: HDCServerState) {
        precondition(state.ownership != .arkDeckManaged, "Managed ownership requires launch evidence")
        self.state = state
    }
}

public struct HDCManagedServerLaunchEvidence: Sendable, Equatable {
    public let endpoint: HDCServerEndpoint
    public let pid: Int32
    public let toolPath: URL
    public let generation: Int
    public let version: HDCProbeValue<String>

    public init(
        endpoint: HDCServerEndpoint,
        pid: Int32,
        toolPath: URL,
        generation: Int,
        version: HDCProbeValue<String>
    ) {
        self.endpoint = endpoint
        self.pid = pid
        self.toolPath = toolPath
        self.generation = generation
        self.version = version
    }
}

public enum HDCServerRecipientKind: String, Sendable, Equatable {
    case deviceCoordinator
    case job
}

public struct HDCServerRecipient: Hashable, Sendable, Equatable {
    public let id: String
    public let kind: HDCServerRecipientKind
    public let endpoint: HDCServerEndpoint

    public init(id: String, kind: HDCServerRecipientKind, endpoint: HDCServerEndpoint) {
        precondition(!id.isEmpty, "A host-wide event recipient must have an identifier")
        self.id = id
        self.kind = kind
        self.endpoint = endpoint
    }
}

public enum HDCServerCriticalState: Sendable, Equatable {
    case none
    case criticalNonInterruptible(stepID: String, safeBoundaryAction: String)
    case waitingForSafeBoundary(stepID: String, safeBoundaryAction: String)
}

public struct HDCServerCriticalJob: Sendable, Equatable {
    public let jobID: String
    public let stepID: String
    public let safeBoundaryAction: String

    public init(jobID: String, stepID: String, safeBoundaryAction: String) {
        self.jobID = jobID
        self.stepID = stepID
        self.safeBoundaryAction = safeBoundaryAction
    }
}

public enum HDCServerOtherClientDetection: Sendable, Equatable {
    case detected([String])
    case noneDetectedExternalClientsMayStillExist
    case unavailableExternalClientsMayStillExist

    fileprivate var canonicalValue: String {
        switch self {
        case .detected(let clients):
            return "detected:" + clients.sorted().joined(separator: ",")
        case .noneDetectedExternalClientsMayStillExist:
            return "none-detected-external-clients-may-still-exist"
        case .unavailableExternalClientsMayStillExist:
            return "unavailable-external-clients-may-still-exist"
        }
    }
}

public enum HDCServerLifecycleAction: String, Sendable, Equatable {
    case startManaged
    case stopConfirmedGeneration
    case restartConfirmedGeneration
}

public enum HDCServerExpectedOwnership: String, Sendable, Equatable {
    case absent
    case arkDeckManaged
    case external
    case unknown

    fileprivate init(_ ownership: HDCServerOwnership) {
        switch ownership {
        case .external: self = .external
        case .arkDeckManaged: self = .arkDeckManaged
        case .unknown: self = .unknown
        }
    }
}

/// This mirrors the Core `mutateHDCServerLifecycle` argument contract. It is a
/// typed authorization object, not a command line and cannot contain argv.
public struct HDCServerLifecycleStep: Sendable, Equatable {
    public let id: UUID
    public let auditID: UUID
    public let action: HDCServerLifecycleAction
    public let endpoint: HDCServerEndpoint
    public let expectedGeneration: Int?
    public let expectedOwnership: HDCServerExpectedOwnership
    public let impactSnapshotHash: String
    public let confirmationID: UUID?

    public init(
        id: UUID,
        auditID: UUID,
        action: HDCServerLifecycleAction,
        endpoint: HDCServerEndpoint,
        expectedGeneration: Int?,
        expectedOwnership: HDCServerExpectedOwnership,
        impactSnapshotHash: String,
        confirmationID: UUID?
    ) {
        self.id = id
        self.auditID = auditID
        self.action = action
        self.endpoint = endpoint
        self.expectedGeneration = expectedGeneration
        self.expectedOwnership = expectedOwnership
        self.impactSnapshotHash = impactSnapshotHash
        self.confirmationID = confirmationID
    }
}

public struct HDCServerImpactSnapshot: Sendable, Equatable {
    public let action: HDCServerLifecycleAction
    public let endpoint: HDCServerEndpoint
    public let generation: Int
    public let ownership: HDCServerOwnership
    public let affectedDeviceCoordinators: [String]
    public let affectedJobs: [String]
    public let otherClientDetection: HDCServerOtherClientDetection
    public let expectedInterruption: String
    public let recoveryPath: String

    public init(
        action: HDCServerLifecycleAction,
        endpoint: HDCServerEndpoint,
        generation: Int,
        ownership: HDCServerOwnership,
        affectedDeviceCoordinators: [String],
        affectedJobs: [String],
        otherClientDetection: HDCServerOtherClientDetection,
        expectedInterruption: String,
        recoveryPath: String
    ) {
        self.action = action
        self.endpoint = endpoint
        self.generation = generation
        self.ownership = ownership
        self.affectedDeviceCoordinators = affectedDeviceCoordinators.sorted()
        self.affectedJobs = affectedJobs.sorted()
        self.otherClientDetection = otherClientDetection
        self.expectedInterruption = expectedInterruption
        self.recoveryPath = recoveryPath
    }

    public var scopeHash: String {
        let canonical = [
            action.rawValue,
            endpoint.rawValue,
            String(generation),
            ownership.rawValue,
            affectedDeviceCoordinators.joined(separator: ","),
            affectedJobs.joined(separator: ","),
            otherClientDetection.canonicalValue,
            expectedInterruption,
            recoveryPath,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HDCServerLifecycleImpactPreview: Sendable, Equatable {
    public let id: UUID
    public let auditID: UUID
    public let snapshot: HDCServerImpactSnapshot

    public init(id: UUID, auditID: UUID, snapshot: HDCServerImpactSnapshot) {
        self.id = id
        self.auditID = auditID
        self.snapshot = snapshot
    }
}

public struct HDCServerLifecycleConfirmation: Sendable, Equatable {
    public let id: UUID
    public let auditID: UUID
    public let previewID: UUID
    public let action: HDCServerLifecycleAction
    public let endpoint: HDCServerEndpoint
    public let generation: Int
    public let ownership: HDCServerOwnership
    public let scopeHash: String

    public init(id: UUID, preview: HDCServerLifecycleImpactPreview) {
        self.id = id
        auditID = preview.auditID
        previewID = preview.id
        action = preview.snapshot.action
        endpoint = preview.snapshot.endpoint
        generation = preview.snapshot.generation
        ownership = preview.snapshot.ownership
        scopeHash = preview.snapshot.scopeHash
    }
}

public enum HDCServerLifecycleExecutionOutcome: Sendable, Equatable {
    case succeeded(resultingGeneration: Int)
    case failed(reason: String)
    case outcomeUnknown(reason: String)
}

public protocol HDCServerLifecycleExecutor: Sendable {
    func execute(_ step: HDCServerLifecycleStep) async -> HDCServerLifecycleExecutionOutcome
}

public enum HDCServerLifecycleAuditEvent: Sendable, Equatable {
    case impactPreview(HDCServerLifecycleImpactPreview)
    case confirmation(HDCServerLifecycleConfirmation)
    case intent(HDCServerLifecycleStep)
    case outcome(stepID: UUID, auditID: UUID, outcome: HDCServerLifecycleExecutionOutcome)
}

/// Production wiring must provide durable storage. The prototype accepts this
/// narrow sink so that a failed intent write can block an executor dispatch.
public protocol HDCServerLifecycleAuditStore: Sendable {
    func append(_ event: HDCServerLifecycleAuditEvent) async throws
}

public actor InMemoryHDCServerLifecycleAuditStore: HDCServerLifecycleAuditStore {
    private var entries: [HDCServerLifecycleAuditEvent] = []

    public init() {}

    public func append(_ event: HDCServerLifecycleAuditEvent) {
        entries.append(event)
    }

    public func events() -> [HDCServerLifecycleAuditEvent] { entries }
}

public struct HDCServerGenerationChange: Sendable, Equatable {
    public let endpoint: HDCServerEndpoint
    public let previousGeneration: Int
    public let currentGeneration: Int
    public let ownership: HDCServerOwnership
    public let reason: String

    public init(
        endpoint: HDCServerEndpoint,
        previousGeneration: Int,
        currentGeneration: Int,
        ownership: HDCServerOwnership,
        reason: String
    ) {
        self.endpoint = endpoint
        self.previousGeneration = previousGeneration
        self.currentGeneration = currentGeneration
        self.ownership = ownership
        self.reason = reason
    }
}

public struct HDCServerHealthChange: Sendable, Equatable {
    public let endpoint: HDCServerEndpoint
    public let generation: Int
    public let ownership: HDCServerOwnership
    public let previousHealth: HDCServerHealth
    public let currentHealth: HDCServerHealth
    public let reason: String

    public init(
        endpoint: HDCServerEndpoint,
        generation: Int,
        ownership: HDCServerOwnership,
        previousHealth: HDCServerHealth,
        currentHealth: HDCServerHealth,
        reason: String
    ) {
        self.endpoint = endpoint
        self.generation = generation
        self.ownership = ownership
        self.previousHealth = previousHealth
        self.currentHealth = currentHealth
        self.reason = reason
    }
}

public struct HDCServerLifecycleBroadcast: Sendable, Equatable {
    public let stepID: UUID
    public let auditID: UUID
    public let endpoint: HDCServerEndpoint
    public let outcome: HDCServerLifecycleExecutionOutcome
    public let requiresReconcile: Bool

    public init(
        stepID: UUID,
        auditID: UUID,
        endpoint: HDCServerEndpoint,
        outcome: HDCServerLifecycleExecutionOutcome,
        requiresReconcile: Bool
    ) {
        self.stepID = stepID
        self.auditID = auditID
        self.endpoint = endpoint
        self.outcome = outcome
        self.requiresReconcile = requiresReconcile
    }
}

public enum HDCServerEvent: Sendable, Equatable {
    case generationChanged(HDCServerGenerationChange)
    case healthChanged(HDCServerHealthChange)
    case lifecycleOutcome(HDCServerLifecycleBroadcast)
    case diagnostic(endpoint: HDCServerEndpoint, reason: String)
}

public enum HDCServerLifecycleDispatchBlock: Sendable, Equatable {
    case startManagedRequiresAbsentEndpointPrecondition
    case endpointStateUnknown
    case impactCannotBeReliablyDetermined
    case previewNotFound
    case confirmationNotFound
    case confirmationStale(HDCServerLifecycleImpactPreview)
    case criticalJobs([HDCServerCriticalJob])
    case auditPersistenceFailed
}

public enum HDCServerImpactPreviewResult: Sendable, Equatable {
    case ready(HDCServerLifecycleImpactPreview)
    case blocked(HDCServerLifecycleDispatchBlock)
}

public enum HDCServerConfirmationResult: Sendable, Equatable {
    case accepted(HDCServerLifecycleConfirmation)
    case blocked(HDCServerLifecycleDispatchBlock)
}

public enum HDCServerLifecycleDispatchResult: Sendable, Equatable {
    case completed(HDCServerLifecycleExecutionOutcome)
    case blocked(HDCServerLifecycleDispatchBlock)
}

public struct HDCManagedStartAuthorization: Sendable, Equatable, Hashable {
    public let id: UUID
    public let endpoint: HDCServerEndpoint

    public init(id: UUID, endpoint: HDCServerEndpoint) {
        self.id = id
        self.endpoint = endpoint
    }
}

/// The only host-wide owner of HDC server state. It deliberately has no
/// automatic lifecycle executor: automatic diagnostic/recovery paths can only
/// publish diagnostics, never stop, restart, or move an external/unknown HDC
/// server. Manual mutation is gated by a typed step, impact snapshot,
/// confirmation, revalidation, critical-job gate, and audit sink.
public actor HDCServerSupervisor {
    private let auditStore: any HDCServerLifecycleAuditStore
    private var endpoints: [HDCServerEndpoint: HDCServerState] = [:]
    private var recipients: [HDCServerRecipient: HDCServerCriticalState] = [:]
    private var deliveredEvents: [HDCServerRecipient: [HDCServerEvent]] = [:]
    private var otherClientDetection: [HDCServerEndpoint: HDCServerOtherClientDetection] = [:]
    private var impactReliability: [HDCServerEndpoint: Bool] = [:]
    private var previews: [UUID: HDCServerLifecycleImpactPreview] = [:]
    private var confirmations: [UUID: HDCServerLifecycleConfirmation] = [:]
    private var managedStartAuthorizations: [UUID: HDCManagedStartAuthorization] = [:]

    public init(auditStore: any HDCServerLifecycleAuditStore) {
        self.auditStore = auditStore
    }

    public func register(_ recipient: HDCServerRecipient) {
        recipients[recipient] = recipients[recipient] ?? HDCServerCriticalState.none
        deliveredEvents[recipient] = deliveredEvents[recipient] ?? []
    }

    public func unregister(_ recipient: HDCServerRecipient) {
        recipients.removeValue(forKey: recipient)
        deliveredEvents.removeValue(forKey: recipient)
    }

    public func updateCriticalState(_ state: HDCServerCriticalState, for recipient: HDCServerRecipient) {
        // Only a registered Job participates in the host-wide critical gate.
        // Ignoring stale device/unregistered notifications prevents an unknown
        // sender from manufacturing a blocker for an unrelated endpoint.
        guard recipient.kind == .job, recipients[recipient] != nil else { return }
        recipients[recipient] = state
    }

    public func setOtherClientDetection(_ detection: HDCServerOtherClientDetection, for endpoint: HDCServerEndpoint) {
        otherClientDetection[endpoint] = detection
    }

    /// This control models a failed host-wide inspection. It is intentionally
    /// separate from best-effort external-client discovery, which remains a
    /// visible uncertainty but does not make the HDC endpoint unknowable.
    public func setImpactReliability(_ isReliable: Bool, for endpoint: HDCServerEndpoint) {
        impactReliability[endpoint] = isReliable
    }

    public func state(for endpoint: HDCServerEndpoint) -> HDCServerState? {
        endpoints[endpoint]
    }

    public func takeDeliveredEvents(for recipient: HDCServerRecipient) -> [HDCServerEvent] {
        let events = deliveredEvents[recipient] ?? []
        deliveredEvents[recipient] = []
        return events
    }

    /// Automatic paths are diagnostics-only by construction. There is no
    /// executor parameter and therefore no reachable automatic kill/restart.
    public func recordAutomaticDiagnosticFailure(endpoint: HDCServerEndpoint, reason: String) {
        broadcast(.diagnostic(endpoint: endpoint, reason: reason), endpoint: endpoint)
    }

    public func observeExistingServer(_ observation: HDCExistingServerObservation, reason: String) {
        let next = observation.state
        let previous = endpoints[next.endpoint]
        endpoints[next.endpoint] = next

        guard let previous else { return }
        if previous.generation != next.generation {
            broadcast(
                .generationChanged(
                    HDCServerGenerationChange(
                        endpoint: next.endpoint,
                        previousGeneration: previous.generation,
                        currentGeneration: next.generation,
                        ownership: next.ownership,
                        reason: reason
                    )
                ),
                endpoint: next.endpoint
            )
        } else if previous.health != next.health {
            broadcast(
                .healthChanged(
                    HDCServerHealthChange(
                        endpoint: next.endpoint,
                        generation: next.generation,
                        ownership: next.ownership,
                        previousHealth: previous.health,
                        currentHealth: next.health,
                        reason: reason
                    )
                ),
                endpoint: next.endpoint
            )
        }
    }

    /// A managed server cannot be claimed merely because it is healthy or uses
    /// the expected port. The endpoint must have been absent when authorization
    /// was created, and the recorded PID, absolute tool path, and endpoint must
    /// all verify after the managed launch.
    public func authorizeManagedStart(at endpoint: HDCServerEndpoint) -> HDCManagedStartAuthorization? {
        guard endpoints[endpoint] == nil else { return nil }
        let authorization = HDCManagedStartAuthorization(id: UUID(), endpoint: endpoint)
        managedStartAuthorizations[authorization.id] = authorization
        return authorization
    }

    @discardableResult
    public func recordManagedStart(
        authorization: HDCManagedStartAuthorization,
        evidence: HDCManagedServerLaunchEvidence
    ) -> Bool {
        guard managedStartAuthorizations.removeValue(forKey: authorization.id) == authorization,
              endpoints[authorization.endpoint] == nil,
              evidence.endpoint == authorization.endpoint,
              evidence.pid > 0,
              evidence.generation >= 0,
              evidence.toolPath.isFileURL,
              evidence.toolPath.path.hasPrefix("/")
        else {
            return false
        }

        endpoints[authorization.endpoint] = HDCServerState(
            endpoint: authorization.endpoint,
            health: .healthy,
            version: evidence.version,
            generation: evidence.generation,
            ownership: .arkDeckManaged
        )
        return true
    }

    public func createImpactPreview(
        action: HDCServerLifecycleAction,
        endpoint: HDCServerEndpoint
    ) async -> HDCServerImpactPreviewResult {
        guard action != .startManaged else { return .blocked(.startManagedRequiresAbsentEndpointPrecondition) }
        guard let snapshot = currentImpactSnapshot(action: action, endpoint: endpoint) else {
            return .blocked(impactReliability[endpoint] == false ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
        }
        return await persistPreview(snapshot)
    }

    public func confirm(_ previewID: UUID) async -> HDCServerConfirmationResult {
        guard let preview = previews[previewID] else { return .blocked(.previewNotFound) }
        guard let snapshot = currentImpactSnapshot(action: preview.snapshot.action, endpoint: preview.snapshot.endpoint) else {
            return .blocked(impactReliability[preview.snapshot.endpoint] == false ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
        }
        guard snapshot.scopeHash == preview.snapshot.scopeHash else {
            return await staleConfirmation(for: snapshot)
        }

        let confirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
        do {
            try await auditStore.append(.confirmation(confirmation))
        } catch {
            return .blocked(.auditPersistenceFailed)
        }
        confirmations[confirmation.id] = confirmation
        return .accepted(confirmation)
    }

    public func dispatch(
        confirmationID: UUID,
        using executor: any HDCServerLifecycleExecutor
    ) async -> HDCServerLifecycleDispatchResult {
        guard let confirmation = confirmations.removeValue(forKey: confirmationID) else { return .blocked(.confirmationNotFound) }
        guard let snapshot = currentImpactSnapshot(action: confirmation.action, endpoint: confirmation.endpoint) else {
            return .blocked(impactReliability[confirmation.endpoint] == false ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
        }
        guard snapshot.scopeHash == confirmation.scopeHash else {
            let stale = await staleConfirmation(for: snapshot)
            if case .blocked(let block) = stale { return .blocked(block) }
            return .blocked(.auditPersistenceFailed)
        }

        let blockers = criticalJobs(for: confirmation.endpoint)
        guard blockers.isEmpty else { return .blocked(.criticalJobs(blockers)) }

        let step = HDCServerLifecycleStep(
            id: UUID(),
            auditID: confirmation.auditID,
            action: confirmation.action,
            endpoint: confirmation.endpoint,
            expectedGeneration: confirmation.generation,
            expectedOwnership: HDCServerExpectedOwnership(confirmation.ownership),
            impactSnapshotHash: confirmation.scopeHash,
            confirmationID: confirmation.id
        )
        do {
            try await auditStore.append(.intent(step))
        } catch {
            return .blocked(.auditPersistenceFailed)
        }

        // `auditStore.append` is a suspension point. A Job coordinator or a
        // fresh server observation can update this actor while the intent is
        // being persisted, so this is deliberately the final non-suspending
        // scope/gate validation before dispatch reaches the executor.
        guard let postIntentSnapshot = currentImpactSnapshot(action: confirmation.action, endpoint: confirmation.endpoint) else {
            let block: HDCServerLifecycleDispatchBlock = impactReliability[confirmation.endpoint] == false
                ? .impactCannotBeReliablyDetermined
                : .endpointStateUnknown
            return await recordPostIntentBlock(step: step, block: block)
        }
        guard postIntentSnapshot.scopeHash == confirmation.scopeHash else {
            let staleResult = await staleConfirmation(for: postIntentSnapshot)
            guard case .blocked(let block) = staleResult else {
                return await recordPostIntentBlock(step: step, block: .auditPersistenceFailed)
            }
            return await recordPostIntentBlock(step: step, block: block)
        }

        let postIntentBlockers = criticalJobs(for: confirmation.endpoint)
        guard postIntentBlockers.isEmpty else {
            return await recordPostIntentBlock(step: step, block: .criticalJobs(postIntentBlockers))
        }

        let outcome = await executor.execute(step)
        do {
            try await auditStore.append(.outcome(stepID: step.id, auditID: step.auditID, outcome: outcome))
        } catch {
            let unknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(reason: "Lifecycle outcome audit could not be persisted")
            broadcastLifecycleOutcome(step: step, outcome: unknown)
            return .completed(unknown)
        }

        if case .succeeded(let resultingGeneration) = outcome,
           let current = endpoints[step.endpoint] {
            endpoints[step.endpoint] = HDCServerState(
                endpoint: current.endpoint,
                health: .healthy,
                version: current.version,
                generation: resultingGeneration,
                ownership: current.ownership
            )
        }
        broadcastLifecycleOutcome(step: step, outcome: outcome)
        return .completed(outcome)
    }

    /// This helper is only called after a durable intent exists but before an
    /// executor is invoked. It closes the audit record and broadcasts the
    /// failed lifecycle result; no caller can continue to external dispatch.
    private func recordPostIntentBlock(
        step: HDCServerLifecycleStep,
        block: HDCServerLifecycleDispatchBlock
    ) async -> HDCServerLifecycleDispatchResult {
        let outcome = HDCServerLifecycleExecutionOutcome.failed(reason: "blocked after intent persistence")
        do {
            try await auditStore.append(.outcome(stepID: step.id, auditID: step.auditID, outcome: outcome))
        } catch {
            let unknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(reason: "Lifecycle block outcome audit could not be persisted")
            broadcastLifecycleOutcome(step: step, outcome: unknown)
            return .blocked(.auditPersistenceFailed)
        }
        broadcastLifecycleOutcome(step: step, outcome: outcome)
        return .blocked(block)
    }

    private func currentImpactSnapshot(
        action: HDCServerLifecycleAction,
        endpoint: HDCServerEndpoint
    ) -> HDCServerImpactSnapshot? {
        guard impactReliability[endpoint] != false,
              let state = endpoints[endpoint],
              state.health == .healthy
        else {
            return nil
        }
        let affected = recipients.keys.filter { $0.endpoint == endpoint }
        return HDCServerImpactSnapshot(
            action: action,
            endpoint: endpoint,
            generation: state.generation,
            ownership: state.ownership,
            affectedDeviceCoordinators: affected.filter { $0.kind == .deviceCoordinator }.map(\.id),
            affectedJobs: affected.filter { $0.kind == .job }.map(\.id),
            otherClientDetection: otherClientDetection[endpoint] ?? .unavailableExternalClientsMayStillExist,
            expectedInterruption: "HDC requests using this endpoint will be interrupted.",
            recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job."
        )
    }

    private func criticalJobs(for endpoint: HDCServerEndpoint) -> [HDCServerCriticalJob] {
        recipients.compactMap { recipient, state in
            guard recipient.endpoint == endpoint, recipient.kind == .job else { return nil }
            switch state {
            case .none:
                return nil
            case .criticalNonInterruptible(let stepID, let safeBoundaryAction),
                    .waitingForSafeBoundary(let stepID, let safeBoundaryAction):
                return HDCServerCriticalJob(
                    jobID: recipient.id,
                    stepID: stepID,
                    safeBoundaryAction: safeBoundaryAction
                )
            }
        }.sorted { $0.jobID < $1.jobID }
    }

    private func persistPreview(_ snapshot: HDCServerImpactSnapshot) async -> HDCServerImpactPreviewResult {
        let preview = HDCServerLifecycleImpactPreview(id: UUID(), auditID: UUID(), snapshot: snapshot)
        do {
            try await auditStore.append(.impactPreview(preview))
        } catch {
            return .blocked(.auditPersistenceFailed)
        }
        previews[preview.id] = preview
        return .ready(preview)
    }

    private func staleConfirmation(for snapshot: HDCServerImpactSnapshot) async -> HDCServerConfirmationResult {
        switch await persistPreview(snapshot) {
        case .ready(let preview):
            return .blocked(.confirmationStale(preview))
        case .blocked(let block):
            return .blocked(block)
        }
    }

    private func broadcastLifecycleOutcome(
        step: HDCServerLifecycleStep,
        outcome: HDCServerLifecycleExecutionOutcome
    ) {
        let requiresReconcile: Bool
        switch outcome {
        case .succeeded:
            requiresReconcile = false
        case .failed, .outcomeUnknown:
            requiresReconcile = true
        }
        broadcast(
            .lifecycleOutcome(
                HDCServerLifecycleBroadcast(
                    stepID: step.id,
                    auditID: step.auditID,
                    endpoint: step.endpoint,
                    outcome: outcome,
                    requiresReconcile: requiresReconcile
                )
            ),
            endpoint: step.endpoint
        )
    }

    private func broadcast(_ event: HDCServerEvent, endpoint: HDCServerEndpoint) {
        for recipient in recipients.keys where recipient.endpoint == endpoint {
            deliveredEvents[recipient, default: []].append(event)
        }
    }
}
