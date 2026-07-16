import ArkDeckProcess
import Darwin
import Foundation
import XCTest

final class ProcessExecutorContractTests: XCTestCase {
  private let executor = FoundationProcessExecutor()

  func testAbsoluteExecutableAndArgumentsArriveWithoutShellExpansion() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("argv probe 中文;$(shell)&[]")
    try FileManager.default.createSymbolicLink(
      at: executable,
      withDestinationURL: URL(fileURLWithPath: "/usr/bin/printf")
    )

    let expansionSentinel = directory.appendingPathComponent("shell-expanded")
    let arguments = [
      "image with spaces/中文;$(touch \(expansionSentinel.path))&*.img",
      "single' double\" backslash\\",
      "pipe|redirect<>background&;backtick`",
    ]
    let separator = String(UnicodeScalar(0x1f)!)
    let result = try await executor.execute(
      ProcessRequest(
        executable: executable,
        arguments: ["%s\(separator)%s\(separator)%s"] + arguments
      )
    )

    XCTAssertEqual(result.termination, .exited(0))
    XCTAssertEqual(result.processGroupTermination, .notRequested)
    XCTAssertEqual(
      String(decoding: result.stdout.data, as: UTF8.self), arguments.joined(separator: separator))
    XCTAssertEqual(result.stderr.totalByteCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: expansionSentinel.path))
    print(
      "M1_PROCESS argv_elements=4 direct_child_launch_count=1 shell_spawn_count=0 expansion_sentinel_count=0"
    )
  }

  func testPreflightRejectsInvalidRequestsBeforeChildLaunch() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let launchSentinel = directory.appendingPathComponent("launched")
    let touch = URL(fileURLWithPath: "/usr/bin/touch")

    try await assertRejected(
      ProcessRequest(
        executable: URL(string: "relative-tool")!,
        arguments: [launchSentinel.path]
      ),
      as: .executableMustBeAbsolute("relative-tool")
    )
    try await assertRejected(
      ProcessRequest(
        executable: URL(string: "file:///usr/bin/touch%00")!,
        arguments: [launchSentinel.path]
      ),
      as: .invalidExecutableContainsNUL
    )
    try await assertRejected(
      ProcessRequest(executable: touch, arguments: [launchSentinel.path, "invalid\0argument"]),
      as: .invalidArgumentContainsNUL
    )
    try await assertRejected(
      ProcessRequest(
        executable: touch,
        arguments: [launchSentinel.path],
        environment: ["INVALID=KEY": "value"]
      ),
      as: .invalidEnvironmentKey("INVALID=KEY")
    )
    try await assertRejected(
      ProcessRequest(
        executable: touch,
        arguments: [launchSentinel.path],
        environment: ["INVALID_VALUE": "value\0suffix"]
      ),
      as: .invalidEnvironmentValue("INVALID_VALUE")
    )
    for timeout in [0, -1, .infinity, .nan] {
      do {
        _ = try await executor.execute(
          ProcessRequest(executable: touch, arguments: [launchSentinel.path], timeout: timeout)
        )
        XCTFail("invalid timeout \(timeout) must be rejected")
      } catch let error as ProcessExecutionError {
        guard case .invalidTimeout = error else {
          XCTFail("unexpected timeout error: \(error)")
          continue
        }
      }
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: launchSentinel.path))
    print("M1_PROCESS rejected_preflight_cases=9 child_launch_count=0")
  }

  func testLaunchExitAndSignalHaveIndependentClassifications() async throws {
    let nonzeroExit = try await executor.execute(
      ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/false"))
    )
    XCTAssertEqual(nonzeroExit.termination, .exited(1))

    let perl = URL(fileURLWithPath: "/usr/bin/perl")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: perl.path),
      "macOS process fixture requires /usr/bin/perl")
    let signal = try await executor.execute(
      ProcessRequest(executable: perl, arguments: ["-e", "kill 9, $$;"])
    )
    XCTAssertEqual(signal.termination, .signalled(SIGKILL))

    do {
      _ = try await executor.execute(
        ProcessRequest(executable: URL(fileURLWithPath: "/private/tmp/arkdeck-does-not-exist"))
      )
      XCTFail("a missing absolute executable must report launch failure")
    } catch let error as ProcessExecutionError {
      guard case .launchFailed = error else {
        return XCTFail("unexpected launch error: \(error)")
      }
    }
  }

  func testStreamsRemainSeparatedAndInvalidUTF8RoundTrips() async throws {
    let bytes = LockedStreamBytes()
    let invalidUTF8 = try await executor.execute(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["\\377\\376A"]
      ),
      onOutput: { bytes.append($0) }
    )

    XCTAssertEqual(invalidUTF8.termination, .exited(0))
    XCTAssertEqual(invalidUTF8.stdout.data, Data([0xff, 0xfe, 0x41]))
    XCTAssertEqual(bytes.data(for: .stdout), Data([0xff, 0xfe, 0x41]))

    let split = try await executor.execute(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/awk"),
        arguments: [
          "BEGIN { printf \"stdout-marker\"; printf \"stderr-marker\" > \"/dev/stderr\" }"
        ]
      )
    )
    XCTAssertEqual(split.termination, .exited(0))
    XCTAssertEqual(String(decoding: split.stdout.data, as: UTF8.self), "stdout-marker")
    XCTAssertEqual(String(decoding: split.stderr.data, as: UTF8.self), "stderr-marker")
  }

  func testExitZeroCanStillBeASemanticFailure() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("semantic-exit-zero-failure.fixture")
    try ProcessExecutorFixtures.semanticExitZeroFailure.write(to: fixture)
    let result = try await executor.execute(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/bin/cat"),
        arguments: [fixture.path]
      ),
      evaluating: FailureMarkerEvaluator(marker: Data("STATUS=FAIL".utf8))
    )

    XCTAssertEqual(result.execution.termination, .exited(0))
    XCTAssertEqual(result.semantic, .failure("fixture-declared-failure"))
  }

  func testTimeoutTerminatesTheControlledProcessGroup() async throws {
    let result = try await executeIgnoringProcessTree(using: executor, timeout: 0.5)

    XCTAssertEqual(result.termination, .timedOut)
    XCTAssertEqual(result.processGroupTermination, .noSurvivingMembers(forcedKill: true))
    try assertRecordedProcessTreeHasNoSurvivors(result.stdout.data)
  }

  func testCancellationTerminatesTheControlledProcessGroup() async throws {
    let executor = FoundationProcessExecutor()
    let task = Task { try await executeIgnoringProcessTree(using: executor, timeout: nil) }
    try await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    let result = try await task.value

    XCTAssertEqual(result.termination, .cancelled)
    XCTAssertEqual(result.processGroupTermination, .noSurvivingMembers(forcedKill: true))
    try assertRecordedProcessTreeHasNoSurvivors(result.stdout.data)
  }

  func testTimeoutStillControlsGroupAfterLeaderExitWhileDescendantHoldsPipes() async throws {
    let startedAt = Date()
    let result = try await executeLeaderExitWithPipeHoldingChild(using: executor, timeout: 0.2)
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertEqual(result.termination, .timedOut)
    XCTAssertEqual(result.processGroupTermination, .noSurvivingMembers(forcedKill: true))
    XCTAssertLessThan(elapsed, 1.5)
    try assertRecordedProcessTreeHasNoSurvivors(result.stdout.data)
    print("M1_LEADER_EXIT timeout_elapsed_seconds=\(elapsed)")
  }

  func testCancellationStillControlsGroupAfterLeaderExitWhileDescendantHoldsPipes() async throws {
    let executor = FoundationProcessExecutor()
    let task = Task {
      try await executeLeaderExitWithPipeHoldingChild(using: executor, timeout: nil)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    let cancelledAt = Date()
    task.cancel()
    let result = try await task.value
    let elapsedAfterCancellation = Date().timeIntervalSince(cancelledAt)

    XCTAssertEqual(result.termination, .cancelled)
    XCTAssertEqual(result.processGroupTermination, .noSurvivingMembers(forcedKill: true))
    XCTAssertLessThan(elapsedAfterCancellation, 1.5)
    try assertRecordedProcessTreeHasNoSurvivors(result.stdout.data)
    print("M1_LEADER_EXIT cancellation_elapsed_seconds=\(elapsedAfterCancellation)")
  }

  func testOneGiBSparseFixtureUsesBoundedCaptureAndMemory() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sparseFixture = directory.appendingPathComponent("one-gib-sparse.fixture")
    try Data().write(to: sparseFixture)
    let writer = try FileHandle(forWritingTo: sparseFixture)
    try writer.truncate(atOffset: 1_073_741_824)
    try writer.close()

    let sizes = try fileSizes(at: sparseFixture)
    let streamCounter = LockedStreamCounter()
    let residentSetSampler = try PeakResidentSetSampler()
    let result = try await executor.execute(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/bin/cat"),
        arguments: [sparseFixture.path],
        timeout: 120
      ),
      onOutput: { chunk in
        if streamCounter.accept(chunk) {
          residentSetSampler.observe()
        }
      }
    )
    residentSetSampler.observe()
    let peakDelta = residentSetSampler.peakDelta

    XCTAssertEqual(result.termination, .exited(0))
    XCTAssertEqual(sizes.logical, 1_073_741_824)
    XCTAssertLessThanOrEqual(sizes.allocated, sizes.logical)
    XCTAssertEqual(result.stdout.totalByteCount, 1_073_741_824)
    XCTAssertEqual(streamCounter.byteCount(for: .stdout), 1_073_741_824)
    XCTAssertGreaterThan(streamCounter.dispatchCount(for: .stdout), 1)
    XCTAssertEqual(result.stdout.data.count, 64 * 1024)
    XCTAssertTrue(result.stdout.wasTruncated)
    XCTAssertEqual(result.stderr.totalByteCount, 0)
    XCTAssertEqual(residentSetSampler.failedSampleCount, 0)
    XCTAssertLessThanOrEqual(peakDelta, 64 * 1024 * 1024)

    print(
      "M1_BOUNDED_MEMORY logical_size=\(sizes.logical) allocated_size=\(sizes.allocated) "
        + "stdout_bytes=\(result.stdout.totalByteCount) stdout_dispatches=\(streamCounter.dispatchCount(for: .stdout)) "
        + "retained_stdout=\(result.stdout.data.count) retained_stderr=\(result.stderr.data.count) peak_rss_delta=\(peakDelta)"
    )
  }

  private func assertRecordedProcessTreeHasNoSurvivors(
    _ data: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let output = String(decoding: data, as: UTF8.self)
    let expression = try NSRegularExpression(pattern: #"\d+"#)
    let range = NSRange(output.startIndex..., in: output)
    let identifiers = Set(
      expression.matches(in: output, range: range).compactMap { match -> pid_t? in
        guard let matchRange = Range(match.range, in: output) else { return nil }
        guard let identifier = pid_t(output[matchRange]) else { return nil }
        return identifier
      })
    XCTAssertGreaterThanOrEqual(
      identifiers.count, 2, "fixture must report parent and descendant PIDs", file: file, line: line
    )

    for _ in 0..<100 {
      if identifiers.allSatisfy({ Darwin.kill($0, 0) == -1 && errno == ESRCH }) {
        print(
          "M1_PROCESS_TREE recorded_pids=\(identifiers.count) surviving_descendants=0 forced_kill_count=1"
        )
        return
      }
      usleep(10_000)
    }
    let survivors = identifiers.filter { Darwin.kill($0, 0) == 0 || errno != ESRCH }
    XCTFail(
      "process-group members survived controlled termination: \(survivors)", file: file, line: line)
  }

  private func assertRejected(
    _ request: ProcessRequest,
    as expected: ProcessExecutionError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    do {
      _ = try await executor.execute(request)
      XCTFail("invalid request must be rejected before launch", file: file, line: line)
    } catch let error as ProcessExecutionError {
      XCTAssertEqual(error, expected, file: file, line: line)
    }
  }
}

private struct FailureMarkerEvaluator: ProcessSemanticEvaluating {
  let marker: Data
  private var carry = Data()
  private var foundFailure = false

  init(marker: Data) {
    self.marker = marker
  }

  mutating func consume(_ chunk: ProcessOutputChunk) {
    guard !foundFailure else { return }
    var searchable = carry
    searchable.append(chunk.bytes)
    foundFailure = searchable.range(of: marker) != nil
    carry = Data(searchable.suffix(max(0, marker.count - 1)))
  }

  mutating func finish(execution: ProcessExecutionResult) -> ProcessSemanticResult<String> {
    if foundFailure {
      return .failure("fixture-declared-failure")
    }
    return execution.termination == .exited(0) ? .success : .indeterminate
  }
}

private final class LockedStreamBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ProcessStream: Data] = [:]

  func append(_ chunk: ProcessOutputChunk) {
    lock.lock()
    storage[chunk.stream, default: Data()].append(chunk.bytes)
    lock.unlock()
  }

  func data(for stream: ProcessStream) -> Data {
    lock.lock()
    defer { lock.unlock() }
    return storage[stream, default: Data()]
  }
}

private final class LockedStreamCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var byteCounts: [ProcessStream: Int64] = [:]
  private var dispatchCounts: [ProcessStream: Int] = [:]

  /// Returns true every 128 stdout dispatches so the caller can sample RSS
  /// without adding one Mach call to every pipe read.
  func accept(_ chunk: ProcessOutputChunk) -> Bool {
    lock.lock()
    byteCounts[chunk.stream, default: 0] += Int64(chunk.bytes.count)
    dispatchCounts[chunk.stream, default: 0] += 1
    let shouldSample =
      chunk.stream == .stdout && dispatchCounts[chunk.stream, default: 0] % 128 == 0
    lock.unlock()
    return shouldSample
  }

  func byteCount(for stream: ProcessStream) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return byteCounts[stream, default: 0]
  }

  func dispatchCount(for stream: ProcessStream) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return dispatchCounts[stream, default: 0]
  }
}

private final class PeakResidentSetSampler: @unchecked Sendable {
  private let lock = NSLock()
  private let baseline: UInt64
  private var storedPeakDelta: UInt64 = 0
  private var storedFailedSampleCount = 0

  init() throws {
    baseline = try currentResidentSetSize()
  }

  func observe() {
    do {
      let residentSetSize = try currentResidentSetSize()
      lock.lock()
      storedPeakDelta = max(
        storedPeakDelta, residentSetSize > baseline ? residentSetSize - baseline : 0)
      lock.unlock()
    } catch {
      lock.lock()
      storedFailedSampleCount += 1
      lock.unlock()
    }
  }

  var peakDelta: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return storedPeakDelta
  }

  var failedSampleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedFailedSampleCount
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("arkdeck-process-contract-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}

private func executeIgnoringProcessTree(
  using executor: FoundationProcessExecutor,
  timeout: TimeInterval?
) async throws -> ProcessExecutionResult {
  let perl = URL(fileURLWithPath: "/usr/bin/perl")
  guard FileManager.default.isExecutableFile(atPath: perl.path) else {
    throw POSIXTestError(operation: "missing /usr/bin/perl fixture", code: ENOENT)
  }
  let program = #"""
    $| = 1;
    $SIG{TERM} = 'IGNORE';
    my $child = fork();
    die "fork failed" unless defined $child;
    if ($child == 0) {
        $SIG{TERM} = 'IGNORE';
        print "child=$$\n";
        sleep 30;
        exit 0;
    }
    print "parent=$$ child=$child\n";
    sleep 30;
    """#
  return try await executor.execute(
    ProcessRequest(executable: perl, arguments: ["-e", program], timeout: timeout)
  )
}

private func executeLeaderExitWithPipeHoldingChild(
  using executor: FoundationProcessExecutor,
  timeout: TimeInterval?
) async throws -> ProcessExecutionResult {
  let perl = URL(fileURLWithPath: "/usr/bin/perl")
  guard FileManager.default.isExecutableFile(atPath: perl.path) else {
    throw POSIXTestError(operation: "missing /usr/bin/perl fixture", code: ENOENT)
  }
  let program = #"""
    $| = 1;
    my $child = fork();
    die "fork failed" unless defined $child;
    if ($child == 0) {
        $SIG{TERM} = 'IGNORE';
        print "child=$$\n";
        sleep 3;
        exit 0;
    }
    print "leader=$$ child=$child\n";
    exit 0;
    """#
  return try await executor.execute(
    ProcessRequest(executable: perl, arguments: ["-e", program], timeout: timeout)
  )
}

private func fileSizes(at url: URL) throws -> (logical: Int64, allocated: Int64) {
  var metadata = stat()
  guard url.path.withCString({ lstat($0, &metadata) }) == 0 else {
    throw POSIXTestError(operation: "stat", code: errno)
  }
  return (logical: metadata.st_size, allocated: metadata.st_blocks * 512)
}

private func currentResidentSetSize() throws -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &info) { infoPointer in
    infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
      task_info(
        mach_task_self_,
        task_flavor_t(MACH_TASK_BASIC_INFO),
        reboundPointer,
        &count
      )
    }
  }
  guard result == KERN_SUCCESS else {
    throw POSIXTestError(operation: "task_info", code: result)
  }
  return UInt64(info.resident_size)
}

private struct POSIXTestError: Error {
  let operation: String
  let code: Int32
}
