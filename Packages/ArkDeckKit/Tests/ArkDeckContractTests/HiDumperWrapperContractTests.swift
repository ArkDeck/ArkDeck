import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation
import XCTest

/// TEST-INT-UD-WRAPPER-001: fixed HiDumper argv and fail-closed output semantics. All output is
/// in-memory fake/adversarial data; this test never discovers or launches HDC or HiDumper.
final class HiDumperWrapperContractTests: XCTestCase {
  func testCanonicalRecipesHaveExactFixedArgumentArrays() throws {
    let expected: [(HiDumperRecipe, String?, [String])] = [
      (
        .nodeSummary, nil,
        ["-s", "WindowManagerService", "-a", "-w window-42 -default"]
      ),
      (
        .elementTree, nil,
        ["-s", "WindowManagerService", "-a", "-w window-42 -element -c"]
      ),
      (
        .fullDefaultTree, nil,
        ["-s", "WindowManagerService", "-a", "-w window-42 -default -all"]
      ),
      (
        .componentDetail, "component_7",
        [
          "-s", "WindowManagerService", "-a",
          "-w window-42 -element -lastpage component_7",
        ]
      ),
    ]

    XCTAssertEqual(HiDumperRecipe.allCases.count, expected.count)
    for (recipe, componentID, arguments) in expected {
      let invocation = try HiDumperWrapper.invocation(
        for: recipe,
        windowID: "window-42",
        componentID: componentID
      )
      XCTAssertEqual(invocation.remoteExecutable, "hidumper", recipe.rawValue)
      XCTAssertEqual(invocation.arguments, arguments, recipe.rawValue)
      XCTAssertEqual(invocation.outputFamily, .unregistered, recipe.rawValue)
    }

    XCTAssertEqual(
      HiDumperWrapper.windowInventory.arguments,
      ["-s", "WindowManagerService", "-a", "-a"]
    )
    XCTAssertEqual(HiDumperWrapper.windowInventory.outputFamily, .unregistered)
    XCTAssertEqual(HiDumperWrapper.systemAbilityListProbe.arguments, ["-ls"])
    XCTAssertEqual(HiDumperWrapper.systemAbilityListProbe.outputFamily, .systemAbilityList)
  }

  func testOnlyValidatedIdentifierTokensCanEnterFixedServiceArgument() throws {
    let accepted = try HiDumperWrapper.invocation(
      for: .componentDetail,
      windowID: "12:A.window-1",
      componentID: "component_7"
    )
    XCTAssertEqual(
      accepted.arguments.last,
      "-w 12:A.window-1 -element -lastpage component_7"
    )

    let rejected = [
      "", " window", "window id", "window;touch", "window|tool", "window&&tool",
      "window$(tool)", "window`tool`", "window'quoted", "window\"quoted", "window\\path",
      "window\nnext", "界面42", String(repeating: "a", count: 129),
    ]
    for identifier in rejected {
      XCTAssertThrowsError(
        try HiDumperWrapper.invocation(for: .nodeSummary, windowID: identifier),
        "identifier must never become a free-form service argument: \(identifier.debugDescription)"
      ) { error in
        XCTAssertEqual(
          error as? HiDumperInvocationValidationError,
          .invalidIdentifier(field: "windowID")
        )
      }
    }

    XCTAssertThrowsError(
      try HiDumperWrapper.invocation(
        for: .componentDetail,
        windowID: "42",
        componentID: "7;tool"
      )
    ) { error in
      XCTAssertEqual(
        error as? HiDumperInvocationValidationError,
        .invalidIdentifier(field: "componentID")
      )
    }
  }

  func testComponentIDPresenceIsPinnedByRecipeType() {
    XCTAssertThrowsError(
      try HiDumperWrapper.invocation(for: .componentDetail, windowID: "42")
    ) { error in
      XCTAssertEqual(error as? HiDumperInvocationValidationError, .missingComponentID)
    }
    XCTAssertThrowsError(
      try HiDumperWrapper.invocation(
        for: .nodeSummary,
        windowID: "42",
        componentID: "7"
      )
    ) { error in
      XCTAssertEqual(error as? HiDumperInvocationValidationError, .unexpectedComponentID)
    }
  }

  func testExitZeroTrapUsesMarkersForSuccessFailureAndUnknown() {
    var registeredSuccess = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    registeredSuccess.consume(stdout("noise\nSystem ability "))
    registeredSuccess.consume(stdout("list:\nWindowManagerService\n"))
    XCTAssertEqual(registeredSuccess.finish(exitCode: 0), .success)

    var observedFailure = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    observedFailure.consume(stdout("hidumper: option pid missed. help\n"))
    XCTAssertEqual(
      observedFailure.finish(exitCode: 0),
      .failure(.explicitFailureMarker),
      "the M0B exit-zero help trap must be an explicit failure"
    )

    var markerAbsent = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    markerAbsent.consume(stdout("WindowManagerService\n"))
    XCTAssertEqual(markerAbsent.finish(exitCode: 0), .unknownOutput)
  }

  func testFailurePrecedesSuccessAndWorksAcrossChunksAndStreams() {
    var parser = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    parser.consume(stdout("System ability list:\n"))
    parser.consume(stderr("HIDUMPER: OPTION window"))
    parser.consume(stderr(" MISSED. usage\n"))
    XCTAssertEqual(parser.finish(exitCode: 0), .failure(.explicitFailureMarker))
  }

  func testNonzeroExitCannotBecomeSuccess() {
    var parser = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    parser.consume(stdout("System ability list:\n"))
    XCTAssertEqual(parser.finish(exitCode: 23), .failure(.nonZeroExit(23)))
  }

  func testUnregisteredFamilyCannotBorrowRegisteredSuccessMarker() {
    var parser = HiDumperSemanticOutputParser(outputFamily: .unregistered)
    parser.consume(stdout("System ability list:\nWindowManagerService\n"))
    XCTAssertEqual(parser.finish(exitCode: 0), .unknownOutput)
  }

  private func stdout(_ value: String) -> ProcessOutputChunk {
    ProcessOutputChunk(stream: .stdout, bytes: Data(value.utf8))
  }

  private func stderr(_ value: String) -> ProcessOutputChunk {
    ProcessOutputChunk(stream: .stderr, bytes: Data(value.utf8))
  }
}
