// The Rust CLI's copy of this CLI's command registry projection
// (TASK-XPA-018): `rust/crates/arkdeck-cli/src/command_registry.json` is what
// the Rust `arkdeck commands` answers from, filtered to the leaves the Rust
// parser serves. It must be `CLIRegistryProjection.result()` — the projection
// `arkdeck commands --output json` prints and
// `openspec/contracts/cli-command-registry.yaml` publishes — so a registry
// change fails here until the copy is written again from the published YAML.
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

final class CLIRustCommandRegistryCopyContractTests: XCTestCase {
  func testTheRustCopyIsThisBuildsRegistryProjection() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let copy = repository.appending(path: "rust/crates/arkdeck-cli/src/command_registry.json")
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: copy))
    XCTAssertEqual(
      decoded, CLIRegistryProjection.result(),
      "rust/crates/arkdeck-cli/src/command_registry.json is not this build's registry projection; "
        + "write it again from openspec/contracts/cli-command-registry.yaml as "
        + "{commandRegistrySchemaVersion: schemaVersion, commands: commands} "
        + "(TASK-XPA-018's cli-parity-audit-20260919.md gives the command)")
  }
}
