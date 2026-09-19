import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckWorkflows

/// What of the Overview capability matrix stays in ArkDeckWorkflows: the Debug
/// workspace's window-inventory Job, which the App composes into the ClientKit
/// facade, and the Provider's Trace verdicts, which ClientKit mirrors by value.
final class DebugWindowInventoryJobRunnerContractTests: XCTestCase {
  func testTheAppComposesTheDebugWindowInventoryTemplateIntoTheOverview() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let runner = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DebugWindowInventoryJobRunner.swift"),
      encoding: .utf8)
    XCTAssertTrue(runner.contains("DebugTemplateJobExecution.run("))
    XCTAssertTrue(
      runner.contains("templateID: DebugRuntimeCommandTemplate.windowInventory.rawValue"))

    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"), encoding: .utf8)
    XCTAssertTrue(
      app.contains(
        "OverviewCapabilityApplicationFacade.make(\n      windowInventory: DebugWindowInventoryJobRunner())"))
  }

  func testOverviewTraceDispositionsMirrorTheProviderWireValues() {
    // Exhaustive on purpose: a new Provider verdict stops this compiling until
    // ClientKit decides how the Overview reads it.
    func mirrored(_ disposition: TraceRuntimeToolDisposition) -> OverviewTraceToolDisposition {
      switch disposition {
      case .captureEligible: .captureEligible
      case .probeOnly: .probeOnly
      case .unrecognized: .unrecognized
      case .probeFailed: .probeFailed
      }
    }
    let provider: [TraceRuntimeToolDisposition] = [
      .captureEligible, .probeOnly, .unrecognized, .probeFailed,
    ]
    for disposition in provider {
      XCTAssertEqual(mirrored(disposition).rawValue, disposition.rawValue)
    }
    XCTAssertEqual(
      Set(OverviewTraceToolDisposition.allCases.map(\.rawValue)),
      Set(provider.map(\.rawValue)))
  }
}
