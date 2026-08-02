// Isolated Evolution candidate target (CHG-2026-025 r8, TASK-AIN-019).
//
// This target deliberately has no ArkDeck target dependency.  It cannot
// import Runtime, Workflows, a device provider or an authority store.  Its
// only product is one closed JSON strategy written to stdout.

import Foundation

struct CandidateInput: Decodable {
  let operationReference: String
  let deviceProfileReference: String
  let archiveDigestSHA256: String
  let stepSetDigestSHA256: String
  let userdataImpact: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operationReference
    case deviceProfileReference
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case userdataImpact
  }

  init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: CandidateDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .operationReference, in: container,
        debugDescription: "candidate request must have a closed shape")
    }
    operationReference = try container.decode(String.self, forKey: .operationReference)
    deviceProfileReference = try container.decode(String.self, forKey: .deviceProfileReference)
    archiveDigestSHA256 = try container.decode(String.self, forKey: .archiveDigestSHA256)
    stepSetDigestSHA256 = try container.decode(String.self, forKey: .stepSetDigestSHA256)
    userdataImpact = try container.decode(String.self, forKey: .userdataImpact)
  }
}

private struct CandidateDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

struct CandidateOutput: Encodable {
  let operationReference: String
  let deviceProfileReference: String
  let archiveDigestSHA256: String
  let stepSetDigestSHA256: String
  let allowedStartingModes: [String]
  let userdataImpact: String
}

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("candidate rejected: \(message)\n".utf8))
  exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--request",
  arguments[1].hasPrefix("/"), !arguments[1].contains("..")
else { fail("closed request path required") }

let input: CandidateInput
do {
  let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
  input = try JSONDecoder().decode(CandidateInput.self, from: data)
} catch {
  fail("request unreadable")
}

guard input.operationReference == "flash.dayu200@1",
  input.deviceProfileReference == "dayu200@2",
  input.archiveDigestSHA256.range(
    of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
  input.stepSetDigestSHA256.range(
    of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
  input.userdataImpact == "ERASE-USERDATA"
else { fail("request outside published strategy") }

let output = CandidateOutput(
  operationReference: input.operationReference,
  deviceProfileReference: input.deviceProfileReference,
  archiveDigestSHA256: input.archiveDigestSHA256,
  stepSetDigestSHA256: input.stepSetDigestSHA256,
  // Candidate code may narrow this set in a future attempt.  It cannot add a
  // mode because the broker decodes the closed enum and independently checks
  // the live mode before destructive admission.
  allowedStartingModes: ["hdcNormal", "loader"],
  userdataImpact: input.userdataImpact)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
do {
  FileHandle.standardOutput.write(try encoder.encode(output))
  FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
  fail("strategy encoding failed")
}
