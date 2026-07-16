import ArkDeckRuntime
import Foundation

private struct FixtureResult: Codable {
  let role: String
  let admission: String
  let activationDelivery: String?
  let writerInitializationCount: Int
  let activationCount: Int
  let jobInitializationProbeCount: Int
  let hdcInitializationProbeCount: Int
  let sessionWriterInitializationProbeCount: Int
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class WriterInitializationProbes: @unchecked Sendable {
  struct Snapshot {
    let writerInitializationCount: Int
    let jobInitializationProbeCount: Int
    let hdcInitializationProbeCount: Int
    let sessionWriterInitializationProbeCount: Int
  }

  private let lock = NSLock()
  private var writerInitializationCount = 0
  private var jobInitializationProbeCount = 0
  private var hdcInitializationProbeCount = 0
  private var sessionWriterInitializationProbeCount = 0

  func initializeWriterResources() {
    lock.lock()
    writerInitializationCount += 1
    jobInitializationProbeCount += 1
    hdcInitializationProbeCount += 1
    sessionWriterInitializationProbeCount += 1
    lock.unlock()
  }

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      writerInitializationCount: writerInitializationCount,
      jobInitializationProbeCount: jobInitializationProbeCount,
      hdcInitializationProbeCount: hdcInitializationProbeCount,
      sessionWriterInitializationProbeCount: sessionWriterInitializationProbeCount
    )
  }
}

private struct UnavailableActivationSender: ActivationRequestSending {
  func requestActivation() -> ActivationDelivery { .unavailable }
}

private func write<T: Encodable>(_ value: T, to url: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(value).write(to: url, options: .atomic)
}

private func runHolder(arguments: [String]) throws {
  guard arguments.count == 7 else { throw FixtureError.invalidArguments }
  let lockFile = URL(fileURLWithPath: arguments[2])
  let readyFile = URL(fileURLWithPath: arguments[3])
  let stopFile = URL(fileURLWithPath: arguments[4])
  let resultFile = URL(fileURLWithPath: arguments[5])
  let productIdentifier = arguments[6]

  let writerProbes = WriterInitializationProbes()
  let admission = RuntimeInstanceCoordinator(
    lockFile: lockFile,
    activationSender: UnavailableActivationSender()
  ).admit(initializingWriterResources: writerProbes.initializeWriterResources)
  guard case .writer(let guardToken) = admission else {
    throw FixtureError.holderWasNotAdmitted
  }
  let activationCount = Counter()
  let listener = MacOSActivationListener(productIdentifier: productIdentifier) {
    activationCount.increment()
    return true
  }
  try listener.start()
  try Data("ready".utf8).write(to: readyFile, options: .atomic)

  let timeout = Date().addingTimeInterval(15)
  while !FileManager.default.fileExists(atPath: stopFile.path), Date() < timeout {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
  }

  listener.stop()
  withExtendedLifetime(guardToken) {}
  let writerSnapshot = writerProbes.snapshot
  try write(
    FixtureResult(
      role: "holder",
      admission: "writer",
      activationDelivery: nil,
      writerInitializationCount: writerSnapshot.writerInitializationCount,
      activationCount: activationCount.count,
      jobInitializationProbeCount: writerSnapshot.jobInitializationProbeCount,
      hdcInitializationProbeCount: writerSnapshot.hdcInitializationProbeCount,
      sessionWriterInitializationProbeCount: writerSnapshot.sessionWriterInitializationProbeCount
    ),
    to: resultFile
  )
}

private func runContender(arguments: [String]) throws {
  guard arguments.count == 6 else { throw FixtureError.invalidArguments }
  let lockFile = URL(fileURLWithPath: arguments[2])
  let resultFile = URL(fileURLWithPath: arguments[3])
  let activationProductIdentifier = arguments[4]
  let requestID = arguments[5]
  let sender = MacOSActivationRequestSender(
    productIdentifier: activationProductIdentifier,
    requestID: requestID,
    timeout: 1
  )
  let writerProbes = WriterInitializationProbes()
  let admission = RuntimeInstanceCoordinator(
    lockFile: lockFile,
    activationSender: sender
  ).admit(initializingWriterResources: writerProbes.initializeWriterResources)
  let writerSnapshot = writerProbes.snapshot

  switch admission {
  case .writer:
    try write(
      FixtureResult(
        role: "contender",
        admission: "writer",
        activationDelivery: nil,
        writerInitializationCount: writerSnapshot.writerInitializationCount,
        activationCount: 0,
        jobInitializationProbeCount: writerSnapshot.jobInitializationProbeCount,
        hdcInitializationProbeCount: writerSnapshot.hdcInitializationProbeCount,
        sessionWriterInitializationProbeCount: writerSnapshot.sessionWriterInitializationProbeCount
      ),
      to: resultFile
    )
  case .secondary(let delivery):
    try write(
      FixtureResult(
        role: "contender",
        admission: "secondary",
        activationDelivery: delivery.rawValue,
        writerInitializationCount: writerSnapshot.writerInitializationCount,
        activationCount: 0,
        jobInitializationProbeCount: writerSnapshot.jobInitializationProbeCount,
        hdcInitializationProbeCount: writerSnapshot.hdcInitializationProbeCount,
        sessionWriterInitializationProbeCount: writerSnapshot.sessionWriterInitializationProbeCount
      ),
      to: resultFile
    )
  case .readOnlyDiagnostics:
    try write(
      FixtureResult(
        role: "contender",
        admission: "readOnlyDiagnostics",
        activationDelivery: nil,
        writerInitializationCount: writerSnapshot.writerInitializationCount,
        activationCount: 0,
        jobInitializationProbeCount: writerSnapshot.jobInitializationProbeCount,
        hdcInitializationProbeCount: writerSnapshot.hdcInitializationProbeCount,
        sessionWriterInitializationProbeCount: writerSnapshot.sessionWriterInitializationProbeCount
      ),
      to: resultFile
    )
  }
}

private enum FixtureError: Error {
  case invalidArguments
  case holderWasNotAdmitted
}

do {
  let arguments = CommandLine.arguments
  guard arguments.count >= 2 else { throw FixtureError.invalidArguments }
  switch arguments[1] {
  case "holder": try runHolder(arguments: arguments)
  case "contender": try runContender(arguments: arguments)
  default: throw FixtureError.invalidArguments
  }
} catch {
  FileHandle.standardError.write(Data("ArkDeckRuntimePortFixture: \(error)\n".utf8))
  exit(2)
}
