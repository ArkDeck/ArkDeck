@testable import ArkDeckOpenHarmony

enum HDCServerFixtures {
  static let sharedEndpoint = HDCServerEndpoint("127.0.0.1:8710")
  static let isolatedEndpoint = HDCServerEndpoint("127.0.0.1:9710")

  static func externalServer(generation: Int) -> HDCExistingServerObservation {
    HDCExistingServerObservation(
      state: HDCServerState(
        endpoint: sharedEndpoint,
        health: .healthy,
        version: .known("5.0.0"),
        generation: generation,
        ownership: .external
      )
    )
  }

  static func unknownServer(generation: Int) -> HDCExistingServerObservation {
    HDCExistingServerObservation(
      state: HDCServerState(
        endpoint: sharedEndpoint,
        health: .healthy,
        version: .unknown(reason: "HDC ownership probe did not establish a process owner"),
        generation: generation,
        ownership: .unknown
      )
    )
  }

  static func unavailableExternalServer(generation: Int) -> HDCExistingServerObservation {
    HDCExistingServerObservation(
      state: HDCServerState(
        endpoint: sharedEndpoint,
        health: .unavailable,
        version: .known("5.0.0"),
        generation: generation,
        ownership: .external
      )
    )
  }

  static let deviceA = HDCServerRecipient(
    id: "device-a", kind: .deviceCoordinator, endpoint: sharedEndpoint)
  static let deviceB = HDCServerRecipient(
    id: "device-b", kind: .deviceCoordinator, endpoint: sharedEndpoint)
  static let job = HDCServerRecipient(id: "job-flash-a", kind: .job, endpoint: sharedEndpoint)
  static let isolatedDevice = HDCServerRecipient(
    id: "device-isolated", kind: .deviceCoordinator, endpoint: isolatedEndpoint)
}
