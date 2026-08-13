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
  let strategy: CandidateStrategy

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operationReference
    case deviceProfileReference
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case userdataImpact
    case strategy
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
    strategy = try container.decode(CandidateStrategy.self, forKey: .strategy)
  }
}

private struct CandidateDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

struct CandidateStrategy: Codable {
  let operationReference: String
  let deviceProfileReference: String
  let archiveDigestSHA256: String
  let stepSetDigestSHA256: String
  let allowedStartingModes: [String]
  let loaderDiscoveryTimeoutSeconds: Int
  let loaderPollIntervalMilliseconds: Int
  let hdcCommandTimeoutSeconds: Int
  let readOnlyCommandTimeoutSeconds: Int
  let userdataImpact: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operationReference
    case deviceProfileReference
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case allowedStartingModes
    case loaderDiscoveryTimeoutSeconds
    case loaderPollIntervalMilliseconds
    case hdcCommandTimeoutSeconds
    case readOnlyCommandTimeoutSeconds
    case userdataImpact
  }

  init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: CandidateDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .operationReference, in: container,
        debugDescription: "candidate strategy must have a closed shape")
    }
    operationReference = try container.decode(String.self, forKey: .operationReference)
    deviceProfileReference = try container.decode(String.self, forKey: .deviceProfileReference)
    archiveDigestSHA256 = try container.decode(String.self, forKey: .archiveDigestSHA256)
    stepSetDigestSHA256 = try container.decode(String.self, forKey: .stepSetDigestSHA256)
    allowedStartingModes = try container.decode([String].self, forKey: .allowedStartingModes)
    loaderDiscoveryTimeoutSeconds = try container.decode(
      Int.self, forKey: .loaderDiscoveryTimeoutSeconds)
    loaderPollIntervalMilliseconds = try container.decode(
      Int.self, forKey: .loaderPollIntervalMilliseconds)
    hdcCommandTimeoutSeconds = try container.decode(Int.self, forKey: .hdcCommandTimeoutSeconds)
    readOnlyCommandTimeoutSeconds = try container.decode(
      Int.self, forKey: .readOnlyCommandTimeoutSeconds)
    userdataImpact = try container.decode(String.self, forKey: .userdataImpact)
  }
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
  let data = try Data(contentsOf: URL(filePath: arguments[1]))
  input = try JSONDecoder().decode(CandidateInput.self, from: data)
} catch {
  fail("request unreadable")
}

guard input.operationReference == "flash.dayu200",
  input.deviceProfileReference == "dayu200",
  input.archiveDigestSHA256.range(
    of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
  input.stepSetDigestSHA256.range(
    of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
  input.userdataImpact == "ERASE-USERDATA",
  input.strategy.operationReference == input.operationReference,
  input.strategy.deviceProfileReference == input.deviceProfileReference,
  input.strategy.archiveDigestSHA256 == input.archiveDigestSHA256,
  input.strategy.stepSetDigestSHA256 == input.stepSetDigestSHA256,
  Set(input.strategy.allowedStartingModes).isSubset(of: ["hdcNormal", "loader"]),
  !input.strategy.allowedStartingModes.isEmpty,
  (15...120).contains(input.strategy.loaderDiscoveryTimeoutSeconds),
  (100...2_000).contains(input.strategy.loaderPollIntervalMilliseconds),
  (5...60).contains(input.strategy.hdcCommandTimeoutSeconds),
  (5...60).contains(input.strategy.readOnlyCommandTimeoutSeconds),
  input.strategy.userdataImpact == input.userdataImpact
else { fail("request outside published strategy") }

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
do {
  FileHandle.standardOutput.write(try encoder.encode(input.strategy))
  FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
  fail("strategy encoding failed")
}
