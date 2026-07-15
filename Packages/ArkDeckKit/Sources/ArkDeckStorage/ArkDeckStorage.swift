import ArkDeckCore
import Darwin
import Foundation

public enum ArkDeckStorageModule {
    public static let identifier = "ArkDeckStorage"
}

public enum DurableStepEffect: String, Codable, Sendable, Equatable {
    case hostOnly
    case readOnly
    case deviceMutation
    case destructive
}

public enum DurableStepCancellation: String, Codable, Sendable, Equatable {
    case immediate
    case atSafeBoundary
    case criticalNonInterruptible
}

public enum DurableBindingRequirement: String, Codable, Sendable, Equatable {
    case none
    case confirmedDevice
}

/// This storage spike accepts one closed workflow-step variant. The workflow
/// module will own the full closed vocabulary; this keeps the journal from
/// accepting a free-form command during M0A.
public enum DurableStepKind: String, Codable, Sendable, Equatable {
    case probeHostTool
}

public struct DurableProbeHostToolArguments: Codable, Sendable, Equatable {
    public let toolIdentity: String
    public let candidatePath: String
    public let expectedSHA256: String?

    public init(toolIdentity: String, candidatePath: String, expectedSHA256: String? = nil) {
        self.toolIdentity = toolIdentity
        self.candidatePath = candidatePath
        self.expectedSHA256 = expectedSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case toolIdentity
        case candidatePath
        case expectedSHA256 = "expectedSha256"
    }
}

/// A schema-compatible typed step. Its arguments are a structured probe
/// request, never executable path/argv or a shell command.
public struct DurableStepDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let kind: DurableStepKind
    public let effect: DurableStepEffect
    public let cancellation: DurableStepCancellation
    public let bindingRequirement: DurableBindingRequirement
    public let arguments: DurableProbeHostToolArguments
    public let compensationDescriptors: [DurableCompensationDescriptor]

    public init(
        id: String,
        probeHostTool arguments: DurableProbeHostToolArguments,
        compensationDescriptors: [DurableCompensationDescriptor] = []
    ) {
        self.id = id
        kind = .probeHostTool
        effect = .hostOnly
        cancellation = .immediate
        bindingRequirement = .none
        self.arguments = arguments
        self.compensationDescriptors = compensationDescriptors
    }
}

/// M0A's supported host probe has no compensating action. The descriptor is
/// retained as an explicit typed field so later workflow-owned step variants
/// cannot erase compensation information from durable intent records.
public struct DurableCompensationDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let effect: DurableStepEffect
    public let cancellation: DurableStepCancellation
    public let bindingRequirement: DurableBindingRequirement
    public let trigger: String
    public let argumentsHash: String
}

public enum DurableJournalTargetScope: String, Codable, Sendable, Equatable {
    case host
    case server
    case device
}

public struct DurableJournalTarget: Codable, Sendable, Equatable {
    public let scope: DurableJournalTargetScope
    public let targetID: String
    public let connectKey: String?
    public let identitySnapshotHash: String?

    public init(
        scope: DurableJournalTargetScope,
        targetID: String,
        connectKey: String? = nil,
        identitySnapshotHash: String? = nil
    ) {
        self.scope = scope
        self.targetID = targetID
        self.connectKey = connectKey
        self.identitySnapshotHash = identitySnapshotHash
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case targetID = "targetId"
        case connectKey
        case identitySnapshotHash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(targetID, forKey: .targetID)
        // These are contract-required nullable fields, so absent identity data
        // must be represented as null rather than silently omitted.
        try container.encode(connectKey, forKey: .connectKey)
        try container.encode(identitySnapshotHash, forKey: .identitySnapshotHash)
    }
}

public enum DurableJournalEventKind: String, Codable, Sendable, Equatable {
    case stepIntent
    case stepOutcome
}

public enum DurableStepResult: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
    case cancelled
    case timedOut
}

public enum DurableOutcomeCertainty: String, Codable, Sendable, Equatable {
    case confirmed
    case outcomeUnknown
}

/// A contract-compatible `journal-event-1.0.0` record. Each event is encoded
/// as one JSONL line so an unterminated final record remains recoverable.
public struct DurableJournalEvent: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let eventID: String
    public let sequence: Int
    public let sessionID: String
    public let jobID: String
    public let timestamp: String
    public let kind: DurableJournalEventKind
    public let stepID: String?
    public let attempt: Int?
    public let bindingRevision: Int?
    public let argumentsHash: String?
    private let payload: DurableJournalPayload

    public var correlatesToIntentEventID: String? {
        payload.correlatesToIntentEventID
    }

    private init(
        eventID: String,
        sequence: Int,
        sessionID: String,
        jobID: String,
        timestamp: String,
        kind: DurableJournalEventKind,
        stepID: String?,
        attempt: Int?,
        bindingRevision: Int?,
        argumentsHash: String?,
        payload: DurableJournalPayload
    ) {
        schemaVersion = "1.0.0"
        self.eventID = eventID
        self.sequence = sequence
        self.sessionID = sessionID
        self.jobID = jobID
        self.timestamp = timestamp
        self.kind = kind
        self.stepID = stepID
        self.attempt = attempt
        self.bindingRevision = bindingRevision
        self.argumentsHash = argumentsHash
        self.payload = payload
    }

    public static func stepIntent(
        eventID: String,
        sequence: Int,
        sessionID: String,
        jobID: String,
        timestamp: String,
        step: DurableStepDescriptor,
        target: DurableJournalTarget,
        attempt: Int,
        bindingRevision: Int?,
        argumentsHash: String
    ) throws -> DurableJournalEvent {
        let event = DurableJournalEvent(
            eventID: eventID,
            sequence: sequence,
            sessionID: sessionID,
            jobID: jobID,
            timestamp: timestamp,
            kind: .stepIntent,
            stepID: step.id,
            attempt: attempt,
            bindingRevision: bindingRevision,
            argumentsHash: argumentsHash,
            payload: DurableJournalPayload(step: step, target: target)
        )
        try event.validate()
        return event
    }

    public static func stepOutcome(
        eventID: String,
        sequence: Int,
        sessionID: String,
        jobID: String,
        timestamp: String,
        stepID: String,
        attempt: Int,
        correlatesToIntentEventID: String,
        result: DurableStepResult,
        outcomeCertainty: DurableOutcomeCertainty,
        semanticCode: String? = nil,
        summary: String? = nil
    ) throws -> DurableJournalEvent {
        let event = DurableJournalEvent(
            eventID: eventID,
            sequence: sequence,
            sessionID: sessionID,
            jobID: jobID,
            timestamp: timestamp,
            kind: .stepOutcome,
            stepID: stepID,
            attempt: attempt,
            bindingRevision: nil,
            argumentsHash: nil,
            payload: DurableJournalPayload(
                correlatesToIntentEventID: correlatesToIntentEventID,
                result: result,
                outcomeCertainty: outcomeCertainty,
                semanticCode: semanticCode,
                summary: summary
            )
        )
        try event.validate()
        return event
    }

    public func validate() throws {
        guard schemaVersion == "1.0.0", !eventID.isEmpty, sequence >= 0,
              !sessionID.isEmpty, !jobID.isEmpty,
              ISO8601DateFormatter().date(from: timestamp) != nil
        else {
            throw DurableJournalError.invalidEvent
        }

        switch kind {
        case .stepIntent:
            guard let step = payload.step, let target = payload.target,
                  stepID == step.id, !step.id.isEmpty,
                  !step.arguments.toolIdentity.isEmpty, !step.arguments.candidatePath.isEmpty,
                  step.compensationDescriptors.isEmpty,
                  attempt.map({ $0 > 0 }) ?? false,
                  let argumentsHash, isLowercaseSHA256(argumentsHash),
                  payload.isOutcomePayloadEmpty,
                  validTarget(target, for: step, bindingRevision: bindingRevision)
            else {
                throw DurableJournalError.invalidEvent
            }
        case .stepOutcome:
            guard let stepID, !stepID.isEmpty,
                  attempt.map({ $0 > 0 }) ?? false,
                  bindingRevision == nil, argumentsHash == nil,
                  payload.step == nil, payload.target == nil,
                  let correlatesToIntentEventID = payload.correlatesToIntentEventID,
                  !correlatesToIntentEventID.isEmpty,
                  payload.result != nil, payload.outcomeCertainty != nil
            else {
                throw DurableJournalError.invalidEvent
            }
        }
    }

    private func validTarget(
        _ target: DurableJournalTarget,
        for step: DurableStepDescriptor,
        bindingRevision: Int?
    ) -> Bool {
        guard !target.targetID.isEmpty else { return false }
        switch step.bindingRequirement {
        case .none:
            return bindingRevision == nil
        case .confirmedDevice:
            return bindingRevision.map({ $0 > 0 }) ?? false
                && target.scope == .device
                && !(target.connectKey?.isEmpty ?? true)
                && target.identitySnapshotHash.map(isLowercaseSHA256) == true
        }
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID = "eventId"
        case sequence
        case sessionID = "sessionId"
        case jobID = "jobId"
        case timestamp
        case kind
        case stepID = "stepId"
        case attempt
        case bindingRevision
        case argumentsHash
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        eventID = try container.decode(String.self, forKey: .eventID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        jobID = try container.decode(String.self, forKey: .jobID)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        kind = try container.decode(DurableJournalEventKind.self, forKey: .kind)
        stepID = try container.decodeIfPresent(String.self, forKey: .stepID)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        bindingRevision = try container.decodeIfPresent(Int.self, forKey: .bindingRevision)
        argumentsHash = try container.decodeIfPresent(String.self, forKey: .argumentsHash)
        payload = try container.decode(DurableJournalPayload.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(kind, forKey: .kind)
        try container.encode(payload, forKey: .payload)

        switch kind {
        case .stepIntent:
            try container.encode(stepID, forKey: .stepID)
            try container.encode(attempt, forKey: .attempt)
            try container.encode(bindingRevision, forKey: .bindingRevision)
            try container.encode(argumentsHash, forKey: .argumentsHash)
        case .stepOutcome:
            try container.encode(stepID, forKey: .stepID)
            try container.encode(attempt, forKey: .attempt)
        }
    }
}

private struct DurableJournalPayload: Codable, Sendable, Equatable {
    let step: DurableStepDescriptor?
    let target: DurableJournalTarget?
    let correlatesToIntentEventID: String?
    let result: DurableStepResult?
    let outcomeCertainty: DurableOutcomeCertainty?
    let semanticCode: String?
    let summary: String?

    init(step: DurableStepDescriptor, target: DurableJournalTarget) {
        self.step = step
        self.target = target
        correlatesToIntentEventID = nil
        result = nil
        outcomeCertainty = nil
        semanticCode = nil
        summary = nil
    }

    init(
        correlatesToIntentEventID: String,
        result: DurableStepResult,
        outcomeCertainty: DurableOutcomeCertainty,
        semanticCode: String?,
        summary: String?
    ) {
        step = nil
        target = nil
        self.correlatesToIntentEventID = correlatesToIntentEventID
        self.result = result
        self.outcomeCertainty = outcomeCertainty
        self.semanticCode = semanticCode
        self.summary = summary
    }

    var isOutcomePayloadEmpty: Bool {
        correlatesToIntentEventID == nil
            && result == nil
            && outcomeCertainty == nil
            && semanticCode == nil
            && summary == nil
    }

    private enum CodingKeys: String, CodingKey {
        case step
        case target
        case correlatesToIntentEventID = "correlatesToIntentEventId"
        case result
        case outcomeCertainty
        case semanticCode
        case summary
    }
}

public enum DurableJournalError: Error, Equatable, LocalizedError {
    case journalPathMustBeAbsolute(String)
    case createFailed
    case invalidEvent
    case intentNotDurable
    case fullSyncFailed(errno: Int32)
    case tornJournalTail
    case malformedJournalRecord

    public var errorDescription: String? {
        switch self {
        case let .journalPathMustBeAbsolute(path): "Journal path must be absolute: \(path)"
        case .createFailed: "Journal file could not be created"
        case .invalidEvent: "Journal event does not satisfy the durable intent contract"
        case .intentNotDurable: "Journal intent was not durably persisted; the external step was not dispatched"
        case let .fullSyncFailed(errno): "Journal full sync failed (errno \(errno))"
        case .tornJournalTail: "Journal has an unterminated final record"
        case .malformedJournalRecord: "Journal contains a malformed completed record"
        }
    }
}

public protocol DurableJournalAppending: Sendable {
    func appendAndSynchronize(_ event: DurableJournalEvent) throws
}

/// Append-only JSONL journal. A successful call writes a complete event and
/// performs both the filesystem synchronization and macOS `F_FULLFSYNC`
/// hardware-cache flush before returning to the caller.
public final class FileDurableJournal: DurableJournalAppending, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DurableJournalError.journalPathMustBeAbsolute(url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw DurableJournalError.createFailed
        }
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func appendAndSynchronize(_ event: DurableJournalEvent) throws {
        try event.validate()
        var bytes = try encoder.encode(event)
        bytes.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard Darwin.fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else {
            throw DurableJournalError.fullSyncFailed(errno: errno)
        }
    }
}

/// The only M0A path from durable intent preparation to an external effect.
/// A failed append or synchronization is converted to a clear failure state
/// and the supplied operation is never invoked.
public final class WriteAheadIntentGate: @unchecked Sendable {
    private let journal: any DurableJournalAppending

    public init(journal: any DurableJournalAppending) {
        self.journal = journal
    }

    public func dispatch(intent: DurableJournalEvent, operation: () throws -> Void) throws {
        guard intent.kind == .stepIntent else { throw DurableJournalError.invalidEvent }
        do {
            try journal.appendAndSynchronize(intent)
        } catch {
            throw DurableJournalError.intentNotDurable
        }
        try operation()
    }
}

public struct JournalRecoveryReport: Sendable, Equatable {
    public let hasTornTail: Bool
    public let incompleteIntentEventIDs: [String]

    public var requiresRecovery: Bool {
        hasTornTail || !incompleteIntentEventIDs.isEmpty
    }
}

public enum DurableJournalRecovery {
    public static func inspect(url: URL) throws -> JournalRecoveryReport {
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty else {
            return JournalRecoveryReport(hasTornTail: false, incompleteIntentEventIDs: [])
        }

        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        let hasTerminatingNewline = bytes.last == 0x0A
        // The final element is either the empty newline sentinel or an
        // unterminated record. In the latter case it is deliberately ignored
        // and reported as torn rather than treated as a completed effect.
        let completedLines = lines.dropLast()
        let decoder = JSONDecoder()
        var intents: [String] = []
        var outcomes = Set<String>()

        for line in completedLines {
            guard !line.isEmpty else { throw DurableJournalError.malformedJournalRecord }
            let event: DurableJournalEvent
            do {
                event = try decoder.decode(DurableJournalEvent.self, from: Data(line))
                try event.validate()
            } catch {
                throw DurableJournalError.malformedJournalRecord
            }
            switch event.kind {
            case .stepIntent:
                intents.append(event.eventID)
            case .stepOutcome:
                if let correlatesToIntentEventID = event.correlatesToIntentEventID {
                    outcomes.insert(correlatesToIntentEventID)
                }
            }
        }

        return JournalRecoveryReport(
            hasTornTail: !hasTerminatingNewline,
            incompleteIntentEventIDs: intents.filter { !outcomes.contains($0) }
        )
    }
}

public struct JournalCheckpoint: Codable, Sendable, Equatable {
    public let sessionID: String
    public let jobID: String
    public let journalSequence: Int
    public let state: String
    public let updatedAt: String

    public init(sessionID: String, jobID: String, journalSequence: Int, state: String, updatedAt: String) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.journalSequence = journalSequence
        self.state = state
        self.updatedAt = updatedAt
    }
}

public protocol JournalCheckpointSaving: Sendable {
    func save(_ checkpoint: JournalCheckpoint) throws
}

/// Snapshot publication uses Foundation's atomic replacement option. The
/// append-only journal remains the recovery authority if publication fails.
public final class AtomicJournalCheckpointStore: JournalCheckpointSaving, @unchecked Sendable {
    public let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DurableJournalError.journalPathMustBeAbsolute(url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.url = url
        encoder.outputFormatting = [.sortedKeys]
    }

    public func save(_ checkpoint: JournalCheckpoint) throws {
        let bytes = try encoder.encode(checkpoint)
        try bytes.write(to: url, options: .atomic)
    }

    public func load() throws -> JournalCheckpoint {
        try decoder.decode(JournalCheckpoint.self, from: Data(contentsOf: url))
    }
}

/// The completion half of REQ-JOB-002. A checkpoint is not published until
/// its outcome record has been durably appended.
public final class DurableOutcomeCheckpointGate: @unchecked Sendable {
    private let journal: any DurableJournalAppending
    private let checkpointStore: any JournalCheckpointSaving

    public init(journal: any DurableJournalAppending, checkpointStore: any JournalCheckpointSaving) {
        self.journal = journal
        self.checkpointStore = checkpointStore
    }

    public func record(outcome: DurableJournalEvent, checkpoint: JournalCheckpoint) throws {
        guard outcome.kind == .stepOutcome else { throw DurableJournalError.invalidEvent }
        try journal.appendAndSynchronize(outcome)
        try checkpointStore.save(checkpoint)
    }
}
