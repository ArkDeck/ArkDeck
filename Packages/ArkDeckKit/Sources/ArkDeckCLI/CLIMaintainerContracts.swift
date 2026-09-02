import ArkDeckCore
import Foundation

/// `arkdeck maintainer contracts export|check`: the §14 bundle's maintainer
/// entry point. The generator itself lives in `CLIMachineContracts`; this
/// file only reads the two directory options and renders the report, so the
/// handler-option scan sees exactly the options the registry declares.

extension RuntimeCLI {
  static func runMaintainerContracts(_ arguments: [String]) throws {
    guard let verb = arguments.first, verb == "export" || verb == "check" else {
      throw CLIRegistryError(
        code: .invalidCommand, message: "missing maintainer contracts subcommand (export|check)")
    }
    var rest = Array(arguments.dropFirst())
    let session = runtimeSession(
      &rest, command: "maintainer.contracts.\(verb)", connectsToRuntime: false)
    let options = try CLIOptions(rest)
    try options.validateAllowed(["--contracts-directory", "--fixtures-directory"])
    guard let contractsPath = options.value("--contracts-directory"),
      let fixturesPath = options.value("--fixtures-directory")
    else {
      throw session.fail(
        .invalidOption, "--contracts-directory and --fixtures-directory are both required")
    }
    let contracts = URL(fileURLWithPath: contractsPath).standardizedFileURL
    let fixtures = URL(fileURLWithPath: fixturesPath).standardizedFileURL
    do {
      if verb == "export" {
        let report = try CLIMachineContracts.export(
          contractsDirectory: contracts, fixturesDirectory: fixtures)
        session.emit(
          .object([
            "bundleVersion": .string(CLIProductVersion.machineContract),
            "contractsDirectory": .string(contracts.path),
            "fixturesDirectory": .string(fixtures.path),
            "written": .array(report.written.map(JSONValue.string)),
            "removed": .array(report.removed.map(JSONValue.string)),
          ]))
      } else {
        let report = try CLIMachineContracts.check(
          contractsDirectory: contracts, fixturesDirectory: fixtures)
        var document = report.document
        if case .object(var fields) = document {
          fields["bundleVersion"] = .string(CLIProductVersion.machineContract)
          fields["contractsDirectory"] = .string(contracts.path)
          fields["fixturesDirectory"] = .string(fixtures.path)
          document = .object(fields)
        }
        session.emit(document)
        guard report.isClean else {
          throw session.fail(
            .operationFailed,
            "the published machine contracts drifted from this build; run `arkdeck maintainer contracts export`",
            details: [
              "drifted": .array(report.drifted.map(JSONValue.string)),
              "missing": .array(report.missing.map(JSONValue.string)),
              "unexpected": .array(report.unexpected.map(JSONValue.string)),
            ])
        }
      }
    } catch let failure as CLIMachineContracts.Failure {
      throw session.fail(.internalError, failure.message)
    } catch let error as CLIRegistryError {
      throw error
    } catch {
      throw session.fail(.ioFailure, "the contract bundle could not be written or read: \(error)")
    }
  }
}
