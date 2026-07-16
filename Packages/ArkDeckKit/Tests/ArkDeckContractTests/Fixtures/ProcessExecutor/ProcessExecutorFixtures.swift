import Foundation

enum ProcessExecutorFixtures {
  static let semanticExitZeroFailure = Data(
    "STATUS=FAIL\nreason=fixture-declared-failure\n".utf8
  )
}
