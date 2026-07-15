import ArkDeckCore
import Darwin
import Foundation

public enum ArkDeckRuntimeModule {
    public static let identifier = "ArkDeckRuntime"
}

/// `PORT-INSTANCE-001` macOS implementation. `open(2)` atomically obtains a
/// non-blocking BSD advisory lock and the file descriptor keeps it alive for
/// the writable-instance lifetime.
public final class SingleInstanceGuard: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    public static func acquire(at lockFile: URL) throws -> SingleInstanceGuard {
        guard lockFile.isFileURL, lockFile.path.hasPrefix("/") else {
            throw SingleInstanceGuardError.lockPathMustBeAbsolute(lockFile.path)
        }
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = lockFile.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw SingleInstanceGuardError.alreadyHeld
            }
            throw SingleInstanceGuardError.lockUnavailable(errno: lockError)
        }
        return SingleInstanceGuard(fileDescriptor: descriptor)
    }

    public static func defaultLockFileURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "ArkDeck", directoryHint: .isDirectory)
            .appending(path: "single-writer.lock", directoryHint: .notDirectory)
    }
}

public enum SingleInstanceGuardError: Error, Equatable, LocalizedError {
    case lockPathMustBeAbsolute(String)
    case alreadyHeld
    case lockUnavailable(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case let .lockPathMustBeAbsolute(path):
            "Single-instance lock path must be absolute: \(path)"
        case .alreadyHeld:
            "Another ArkDeck writer already holds the single-instance lock"
        case let .lockUnavailable(errno):
            "Single-instance lock is unavailable (errno \(errno))"
        }
    }
}

/// The backend is injectable so release behavior can be tested without
/// changing the host sleep policy.
public protocol PowerActivityBackend: AnyObject {
    func beginIdleSleepPrevention(reason: String) -> AnyObject
    func endIdleSleepPrevention(_ activity: AnyObject)
}

/// macOS `PORT-POWER-001` backend. It prevents only idle sleep; it makes no
/// claim about lid closure or explicit user-initiated sleep.
public final class ProcessInfoPowerActivityBackend: PowerActivityBackend, @unchecked Sendable {
    public init() {}

    public func beginIdleSleepPrevention(reason: String) -> AnyObject {
        ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: reason
        ) as AnyObject
    }

    public func endIdleSleepPrevention(_ activity: AnyObject) {
        guard let activity = activity as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}

/// A reference-counted owner of exactly one underlying idle-sleep assertion.
/// A lease is idempotent and also releases itself on deinitialization.
public final class PowerActivityController: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: any PowerActivityBackend
    private var activeLeases = 0
    private var activity: AnyObject?

    public init(backend: any PowerActivityBackend = ProcessInfoPowerActivityBackend()) {
        self.backend = backend
    }

    deinit {
        lock.lock()
        let activityToEnd = activity
        activeLeases = 0
        activity = nil
        lock.unlock()
        if let activityToEnd {
            backend.endIdleSleepPrevention(activityToEnd)
        }
    }

    public func acquire(reason: String) -> PowerActivityLease {
        lock.lock()
        if activeLeases == 0 {
            activity = backend.beginIdleSleepPrevention(reason: reason)
        }
        activeLeases += 1
        lock.unlock()
        return PowerActivityLease(controller: self)
    }

    public func withActivity<T>(reason: String, operation: () throws -> T) throws -> T {
        let lease = acquire(reason: reason)
        defer { lease.end() }
        return try operation()
    }

    public func withActivity<T>(reason: String, operation: () async throws -> T) async throws -> T {
        let lease = acquire(reason: reason)
        defer { lease.end() }
        return try await operation()
    }

    public var activeLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeases
    }

    fileprivate func releaseLease() {
        lock.lock()
        guard activeLeases > 0 else {
            lock.unlock()
            return
        }
        activeLeases -= 1
        let activityToEnd = activeLeases == 0 ? activity : nil
        if activeLeases == 0 {
            activity = nil
        }
        lock.unlock()
        if let activityToEnd {
            backend.endIdleSleepPrevention(activityToEnd)
        }
    }
}

public final class PowerActivityLease: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: PowerActivityController
    private var hasEnded = false

    fileprivate init(controller: PowerActivityController) {
        self.controller = controller
    }

    deinit {
        end()
    }

    public func end() {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        lock.unlock()
        controller.releaseLease()
    }
}
