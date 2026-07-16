import ArkDeckCore
import ArkDeckStorage
import Darwin
import Foundation

enum CrashWindow: String {
  case beforeIntent
  case afterDurableIntent
  case afterSyntheticSideEffectBeforeOutcome
  case afterDurableOutcomeBeforeFinalize
}

guard CommandLine.arguments.count == 3,
  let window = CrashWindow(rawValue: CommandLine.arguments[1])
else {
  FileHandle.standardError.write(
    Data("usage: ArkDeckJournalCrashFixture <window> <directory>\n".utf8))
  exit(64)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let journal = try FileDurableJournal(url: directory.appending(path: "journal.jsonl"))
let timestamp = "2026-07-16T00:00:00Z"

try journal.appendAndSynchronize(
  JournalEvent.jobCreated(
    eventID: "job-created", sequence: 0, sessionID: "session-crash", jobID: "job-crash",
    timestamp: timestamp, executionMode: "execute"))
try journal.appendAndSynchronize(
  JournalEvent.stateTransition(
    eventID: "to-preflight", sequence: 1, sessionID: "session-crash", jobID: "job-crash",
    timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture"))
try journal.appendAndSynchronize(
  JournalEvent.stateTransition(
    eventID: "to-running", sequence: 2, sessionID: "session-crash", jobID: "job-crash",
    timestamp: timestamp, from: .preflight, to: .running, reason: "fixture"))

func persistFixtureState(hostSyntheticEffectCount: Int) throws {
  let counters = Data(
    "{\"deviceDispatchCount\":0,\"destructiveDispatchCount\":0,\"hostSyntheticEffectCount\":\(hostSyntheticEffectCount)}\n"
      .utf8)
  let url = directory.appending(path: "counters.json")
  try counters.write(to: url)
  let handle = try FileHandle(forWritingTo: url)
  try handle.synchronize()
  try handle.close()
  let ready = directory.appending(path: "ready")
  try Data(window.rawValue.utf8).write(to: ready)
  let readyHandle = try FileHandle(forWritingTo: ready)
  try readyHandle.synchronize()
  try readyHandle.close()
}

func stopForParent(hostSyntheticEffectCount: Int) throws -> Never {
  try persistFixtureState(hostSyntheticEffectCount: hostSyntheticEffectCount)
  Darwin.raise(SIGSTOP)
  while true { Darwin.pause() }
}

if window == .beforeIntent { try stopForParent(hostSyntheticEffectCount: 0) }

let step = try WorkflowStep(
  id: "flash-step",
  kind: .flashPartition,
  declaredEffect: .destructive,
  declaredCancellation: .criticalNonInterruptible,
  declaredBindingRequirement: .confirmedDevice,
  arguments: [
    "providerOperationId": .string("fixtureFlash"),
    "partition": .string("system"),
    "imageArtifactId": .string("image-1"),
    "imageSha256": .string(String(repeating: "a", count: 64)),
    "imageSize": .integer(1),
    "confirmationId": .string("confirm-1"),
    "safeBoundaryId": .string("boundary-1"),
  ])
let intent = try JournalEvent.stepIntent(
  eventID: "flash-intent", sequence: 3, sessionID: "session-crash", jobID: "job-crash",
  timestamp: timestamp, step: step,
  target: JournalTarget(
    scope: "device", targetID: "synthetic-device", connectKey: "fixture-only",
    identitySnapshotHash: String(repeating: "b", count: 64)),
  attempt: 1, bindingRevision: 1)
try journal.appendAndSynchronize(intent)

if window == .afterDurableIntent { try stopForParent(hostSyntheticEffectCount: 0) }

let marker = directory.appending(path: "synthetic-host-side-effect")
try Data("fixture-only".utf8).write(to: marker)
let markerHandle = try FileHandle(forWritingTo: marker)
try markerHandle.synchronize()
try markerHandle.close()

if window == .afterSyntheticSideEffectBeforeOutcome {
  try stopForParent(hostSyntheticEffectCount: 1)
}

try journal.appendAndSynchronize(
  JournalEvent.stepOutcome(
    eventID: "flash-outcome", sequence: 4, sessionID: "session-crash", jobID: "job-crash",
    timestamp: timestamp, stepID: "flash-step", attempt: 1,
    correlatesToIntentEventID: "flash-intent", result: "succeeded",
    outcomeCertainty: .confirmed))
try stopForParent(hostSyntheticEffectCount: 1)
