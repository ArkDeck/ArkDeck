// Non-destructive flash preflight (TASK-AIN-019).
//
// Between 2026-08-03 and 2026-08-04, every campaign that died did so for a
// reason no attempt budget should have paid for: a host tool that could not
// survive its own spawn, an archive that did not match a published pin, a
// target that was not on the bus. Each of those burned a confirmed campaign
// and then required a merged PR to try again.
//
// This runs the same four facts before the confirmation phrase is printed, so
// a red host is refused while it is still free to fix. Every check is E0 —
// one pinned read-only `ld`, one read-only `hdc list targets`, a host-side
// digest and a USB registry read. Device mutation dispatch stays 0, no
// authority is minted, no reservation is taken and nothing here is an engine
// admission gate: the nine gates keep their exact semantics behind it.

import ArkDeckCore
import CryptoKit
import Foundation

/// Whether a host tool child reached its own exit. The distinction that
/// matters is *survival*, not success: `rkdeveloptool ld` with no device
/// attached exits non-zero and has still proven the binary can run, while a
/// child killed by a signal never executed its first instruction of work.
public enum RockchipFlashToolAliveness: Sendable, Equatable {
  case survivedSpawn(exitStatus: Int32?)
  case diedOnSignal(Int32)
  /// The tool could not be resolved, timed out, or was refused before spawn.
  case unavailable(String)
}

public struct RockchipFlashArchiveIdentity: Sendable, Equatable {
  public let sha256: String
  public let byteCount: Int

  public init(sha256: String, byteCount: Int) {
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

/// Everything preflight learns while one exact archive stream passes by.
/// Identity and build remain separate facts so their agreement is checked at
/// the product boundary, but production derives both from the same summary —
/// never from two decompression passes over a large images bundle.
public struct RockchipFlashArchiveSnapshot: Sendable, Equatable {
  public let identity: RockchipFlashArchiveIdentity
  public let build: RockchipImageBuildDescriptor

  public init(
    identity: RockchipFlashArchiveIdentity,
    build: RockchipImageBuildDescriptor
  ) {
    self.identity = identity
    self.build = build
  }
}

public enum RockchipFlashPreflightCheck: String, Sendable, CaseIterable {
  case rockUSBToolAliveness
  case hdcToolAliveness
  case archiveIntegrity
  case targetPresence
}

public struct RockchipFlashPreflightFinding: Sendable, Equatable {
  public let check: RockchipFlashPreflightCheck
  public let passed: Bool
  public let summary: String
  /// Executable next steps. Empty when the check is green; a red finding
  /// without a remediation line is a report the operator cannot act on, which
  /// is the failure mode this preflight exists to end.
  public let remediation: [String]

  public init(
    check: RockchipFlashPreflightCheck,
    passed: Bool,
    summary: String,
    remediation: [String] = []
  ) {
    self.check = check
    self.passed = passed
    self.summary = summary
    self.remediation = remediation
  }
}

public struct RockchipFlashPreflightReceipt: Sendable, Equatable {
  public let findings: [RockchipFlashPreflightFinding]
  /// Stated, not assumed: a preflight that ever dispatched a mutation would
  /// be a flash, and this receipt is printed before any confirmation exists.
  public let deviceMutationDispatchCount = 0

  public init(findings: [RockchipFlashPreflightFinding]) {
    self.findings = findings
  }

  public var isGreen: Bool { findings.allSatisfy(\.passed) }

  public var failedChecks: [RockchipFlashPreflightCheck] {
    findings.filter { !$0.passed }.map(\.check)
  }

  public func renderedLines() -> [String] {
    var lines = ["flash preflight (device mutation dispatch: \(deviceMutationDispatchCount))"]
    for finding in findings {
      lines.append("  [\(finding.passed ? "ok" : "RED")] \(finding.check.rawValue): \(finding.summary)")
      for step in finding.remediation {
        lines.append("        → \(step)")
      }
    }
    return lines
  }
}

/// The four read-only observations, as one injectable seam. Contract tests
/// substitute closures so every branch is provable with zero spawn and zero
/// device.
public struct RockchipFlashPreflightProbes: Sendable {
  public var rockUSBAliveness: @Sendable () async -> RockchipFlashToolAliveness
  public var hdcAliveness: @Sendable () async -> RockchipFlashToolAliveness
  /// Identity and build derived from one stream of the archive's bytes. A seam
  /// like every other observation here: the preflight decides what the answer
  /// means, and contract tests substitute it without a 730 MB file.
  public var archiveSnapshot:
    @Sendable (URL, RockchipFlashProfile) throws -> RockchipFlashArchiveSnapshot
  /// The stable identity the durable binding names — what the target readback
  /// must match. Kept separate from the readback so the identity comparison
  /// stays in the preflight, where it is visible and testable.
  public var boundTargetIdentitySHA256: @Sendable () throws -> String
  /// The one HDC-normal alias the binding's confirmed lineage accepts besides
  /// its current identity, or nil when the lineage carries no valid edge. A
  /// DAYU200 changes its USB serial between Loader and HDC-normal, and the
  /// campaign's allowed starting modes include hdcNormal — a preflight that
  /// only knows the current identity refuses the bound board in the very mode
  /// a flash is allowed to start from (observed 2026-08-04). Defaults to no
  /// alias, which is the fail-closed posture.
  public var boundTargetHDCNormalAlias:
    @Sendable () throws -> (identitySHA256: String, usbTopology: String)?
  public var targetReadback: @Sendable () throws -> RockchipEvolutionTargetReadback

  public init(
    rockUSBAliveness: @escaping @Sendable () async -> RockchipFlashToolAliveness,
    hdcAliveness: @escaping @Sendable () async -> RockchipFlashToolAliveness,
    archiveSnapshot:
      @escaping @Sendable (URL, RockchipFlashProfile) throws
      -> RockchipFlashArchiveSnapshot,
    boundTargetIdentitySHA256: @escaping @Sendable () throws -> String,
    boundTargetHDCNormalAlias:
      @escaping @Sendable () throws -> (identitySHA256: String, usbTopology: String)? =
      { nil },
    targetReadback: @escaping @Sendable () throws -> RockchipEvolutionTargetReadback
  ) {
    self.rockUSBAliveness = rockUSBAliveness
    self.hdcAliveness = hdcAliveness
    self.archiveSnapshot = archiveSnapshot
    self.boundTargetIdentitySHA256 = boundTargetIdentitySHA256
    self.boundTargetHDCNormalAlias = boundTargetHDCNormalAlias
    self.targetReadback = targetReadback
  }
}

public struct RockchipFlashPreflight: Sendable {
  private let probes: RockchipFlashPreflightProbes

  public init(probes: RockchipFlashPreflightProbes = .production()) {
    self.probes = probes
  }

  public func run(archiveURL: URL) async -> RockchipFlashPreflightReceipt {
    var findings: [RockchipFlashPreflightFinding] = []
    findings.append(
      Self.aliveness(
        check: .rockUSBToolAliveness, tool: "rkdeveloptool",
        argv: RockchipDiscoveryIntegrationProfile.pinnedReadOnlyDiscovery.exactArguments
          .joined(separator: " "),
        result: await probes.rockUSBAliveness()))
    findings.append(
      Self.aliveness(
        check: .hdcToolAliveness, tool: "hdc",
        argv: Self.hdcReadOnlyArguments.joined(separator: " "),
        result: await probes.hdcAliveness()))
    findings.append(archiveIntegrity(archiveURL: archiveURL))
    findings.append(targetPresence())
    return RockchipFlashPreflightReceipt(findings: findings)
  }

  /// The read-only HDC surface the live-mode probe already uses. It is named
  /// here so the preflight and the runtime observe the same command.
  static let hdcReadOnlyArguments = ["list", "targets", "-v"]

  private static func aliveness(
    check: RockchipFlashPreflightCheck,
    tool: String,
    argv: String,
    result: RockchipFlashToolAliveness
  ) -> RockchipFlashPreflightFinding {
    switch result {
    case .survivedSpawn(let exitStatus):
      // A non-zero exit is a device-absent answer, not a dead tool. Treating
      // it as red would refuse every preflight run with the board unplugged.
      return RockchipFlashPreflightFinding(
        check: check, passed: true,
        summary: "\(tool) \(argv) ran and exited "
          + "\(exitStatus.map(String.init) ?? "unknown")")
    case .diedOnSignal(let signal):
      return RockchipFlashPreflightFinding(
        check: check, passed: false,
        summary: "\(tool) \(argv) was killed by signal \(signal) before it could run",
        remediation: [
          "read the crash report in "
            + "\(RockchipHostProcessDiagnostics.diagnosticReportsDirectory)\(tool)-*.ips",
          "check that the \(tool) binary carries an empty entitlement dictionary: "
            + "com.apple.security.app-sandbox with inherit traps the child inside "
            + "libsecinit before main (docs/release/rockchip-component-packaging.md)",
          "re-sign or re-deploy the component, then run this preflight again",
        ])
    case .unavailable(let detail):
      return RockchipFlashPreflightFinding(
        check: check, passed: false,
        summary: "\(tool) is unavailable to this host: \(detail)",
        remediation: [
          "confirm the \(tool) binary is deployed where the product resolves it "
            + "and that its identity still matches the reviewed pin"
        ])
    }
  }

  private func archiveIntegrity(archiveURL: URL) -> RockchipFlashPreflightFinding {
    // Whether this archive can be flashed on this board is decided by reading
    // it, not by recognising its digest. Matching against the builds compiled
    // into the product refused a firmware daily published after the last
    // release — measured with `7.0.0.37` on 2026-08-05, which fits the board
    // with no structural violation.
    let board = RockchipFlashProfile.dayu200
    let snapshot: RockchipFlashArchiveSnapshot
    do {
      snapshot = try probes.archiveSnapshot(archiveURL, board)
      _ = try board.forBuild(snapshot.build)
    } catch {
      return RockchipFlashPreflightFinding(
        check: .archiveIntegrity, passed: false,
        summary: "archive does not read as a usable \(board.catalogReference) images "
          + "bundle: \(error)",
        remediation: [
          "point --images at a DAYU200 images archive whose partition table and "
            + "member set fit this board"
        ])
    }
    guard snapshot.build.archiveSHA256 == snapshot.identity.sha256,
      snapshot.build.archiveSizeBytes == Int64(snapshot.identity.byteCount)
    else {
      return RockchipFlashPreflightFinding(
        check: .archiveIntegrity, passed: false,
        summary: "archive bytes changed while they were being measured",
        remediation: ["re-run the preflight against a stable copy of the archive"])
    }
    return RockchipFlashPreflightFinding(
      check: .archiveIntegrity, passed: true,
      summary: "archive fits \(board.catalogReference) and declares "
        + "\(snapshot.build.runtimeBuildVersion)")
  }

  private func targetPresence() -> RockchipFlashPreflightFinding {
    let expected: String
    do {
      expected = try probes.boundTargetIdentitySHA256()
    } catch {
      return RockchipFlashPreflightFinding(
        check: .targetPresence, passed: false,
        summary: "the durable target binding is unavailable: \(error)",
        remediation: ["run `arkdeck flash install-binding` with the board attached"])
    }
    let readback: RockchipEvolutionTargetReadback
    do {
      readback = try probes.targetReadback()
    } catch {
      return RockchipFlashPreflightFinding(
        check: .targetPresence, passed: false,
        summary: "the USB readback failed: \(error)",
        remediation: ["re-attach the board and run this preflight again"])
    }
    guard let observed = readback.stableIdentitySHA256 else {
      return RockchipFlashPreflightFinding(
        check: .targetPresence, passed: false,
        summary: "no single Rockchip target answered on USB",
        remediation: [
          "attach the bound DAYU200 (and detach any second Rockchip device), "
            + "then run this preflight again"
        ])
    }
    var identityNote = ""
    if observed != expected {
      // The binding may carry one confirmed HDC-normal alias: the previous
      // personality of this same board, recorded with its topology and the
      // explicit rebind confirmation when a later revision adopted the Loader
      // identity. A DAYU200 changes its USB serial between modes, and
      // hdcNormal is an allowed starting mode — so exactly that alias, in
      // that mode, at that topology, is the bound target too. Anything else
      // stays a mismatch, and a lineage that fails to validate provides no
      // alias at all.
      let alias = (try? probes.boundTargetHDCNormalAlias()) ?? nil
      guard let alias,
        observed == alias.identitySHA256,
        readback.registeredMode == .hdcNormal,
        readback.usbTopology == alias.usbTopology
      else {
        return RockchipFlashPreflightFinding(
          check: .targetPresence, passed: false,
          summary: "the attached target identity \(observed.prefix(12)) is not the bound "
            + "target \(expected.prefix(12))",
          remediation: [
            "attach the bound target, or re-run `arkdeck flash install-binding` if "
              + "this board is genuinely the new one"
          ])
      }
      identityNote = " via its confirmed hdc-normal alias \(observed.prefix(12))"
    }
    guard let mode = readback.registeredMode else {
      return RockchipFlashPreflightFinding(
        check: .targetPresence, passed: false,
        summary: "the bound target is on USB but not in a registered mode "
          + "(neither hdcNormal nor loader)",
        remediation: [
          "return the board to normal HDC mode or to Loader; Maskrom and other "
            + "personalities are not a flashable starting mode"
        ])
    }
    return RockchipFlashPreflightFinding(
      check: .targetPresence, passed: true,
      summary: "bound target readable in \(mode.rawValue) mode at USB topology "
        + "\(readback.usbTopology ?? "unknown")" + identityNote)
  }
}

extension RockchipFlashPreflightProbes {
  /// Production composition. Both tool probes go through the same identity-
  /// bound runner the runtime dispatches with, resolved by the same product
  /// resolvers — a preflight that spawned differently from the runtime could
  /// pass while the runtime still died.
  ///
  /// One honest limit: this runs in the CLI process and the flash runs in the
  /// daemon, so what it proves is "this binary can survive a spawn from an
  /// unsandboxed user process", not "the daemon's own spawn will survive". For
  /// the fault it was built to catch that is the same statement — a child
  /// declaring App Sandbox inheritance aborts under either parent — but a
  /// posture that differed between the two processes would escape it.
  ///
  /// The runner is bound to the same product-owned tool runtime directory the
  /// runtime spawns in, so the probe cannot drop the tool's implicit `log/`
  /// into the directory the CLI was invoked from. A directory that cannot be
  /// prepared makes both tool probes `unavailable` with the concrete reason;
  /// it never degrades to an unscoped spawn.
  public static func production(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RockchipFlashPreflightProbes {
    let runner = Result {
      FoundationRockchipRuntimeCommandRunner(
        workingDirectory: try RockchipProductToolRuntimeDirectory.prepare(
          root: try applicationSupportArkDeckRoot()))
    }
    return RockchipFlashPreflightProbes(
      rockUSBAliveness: {
        await aliveness(
          resolve: { try BundledRockchipExecutableResolver().resolveExecutable(
            providerID: "rockchip") },
          arguments: RockchipDiscoveryIntegrationProfile.pinnedReadOnlyDiscovery
            .exactArguments,
          runner: runner)
      },
      hdcAliveness: {
        await aliveness(
          resolve: {
            guard let path = environment[ArkDeckEnvironmentKey.hdcPath], !path.isEmpty else {
              throw RockchipFlashPreflightError.hdcPathUnset
            }
            return try FixedExecutableResolver.hashing(path: path, providerID: "hdc")
              .resolveExecutable(providerID: "hdc")
          },
          arguments: RockchipFlashPreflight.hdcReadOnlyArguments,
          runner: runner)
      },
      archiveSnapshot: { url, board in
        // One streaming pass provides the compressed-byte identity, member
        // inventory, partition table and runtime build. Preflight used to
        // decompress the same 730 MB bundle once for identity and again for
        // build introspection before any Runtime import began.
        let summary = try GzipTarArchiveReader.summarize(
          fileAt: url,
          derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
        return RockchipFlashArchiveSnapshot(
          identity: RockchipFlashArchiveIdentity(
            sha256: summary.archiveSHA256, byteCount: Int(summary.archiveSizeBytes)),
          build: try RockchipImageArchiveIntrospection.describe(
            summary: summary, board: board))
      },
      boundTargetIdentitySHA256: {
        let binding = try RockchipProductBindingStore(
          rootURL: try applicationSupportArkDeckRoot()
        ).loadExisting()
        return SHA256Hex.string(of: Data(binding.serial.utf8))
      },
      boundTargetHDCNormalAlias: {
        try RockchipProductBindingStore(
          rootURL: try applicationSupportArkDeckRoot()
        ).loadExisting().confirmedHDCNormalAlias()
      },
      targetReadback: { try ProductRockchipEvolutionTargetReadback().readDurableTarget() })
  }

  private static func aliveness(
    resolve: @Sendable () throws -> ResolvedExecutable,
    arguments: [String],
    runner: Result<FoundationRockchipRuntimeCommandRunner, any Error>
  ) async -> RockchipFlashToolAliveness {
    let commandRunner: FoundationRockchipRuntimeCommandRunner
    do {
      commandRunner = try runner.get()
    } catch {
      return .unavailable(
        "the product-owned Rockchip tool runtime directory is unavailable: \(error)")
    }
    let executable: ResolvedExecutable
    do {
      executable = try resolve()
    } catch {
      return .unavailable("\(error)")
    }
    do {
      let receipt = try await commandRunner.run(
        executable: executable, arguments: arguments,
        timeoutSeconds: 15, outputByteBudget: 64 * 1024,
        criticalNonInterruptible: false)
      return .survivedSpawn(exitStatus: receipt.exitStatus)
    } catch {
      let description = "\(error)"
      if let signal = RockchipHostProcessDiagnostics.signalNumber(
        inFailureDescription: description)
      {
        return .diedOnSignal(signal)
      }
      return .unavailable(description)
    }
  }

  private static func applicationSupportArkDeckRoot() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appending(path: "ArkDeck", directoryHint: .isDirectory)
  }
}

public enum RockchipFlashPreflightError: Error, Sendable, Equatable, CustomStringConvertible {
  case hdcPathUnset

  public var description: String {
    switch self {
    case .hdcPathUnset:
      return "no HDC executable is configured (set ARKDECK_HDC_PATH); the runtime "
        + "refuses HDC dispatch without it, so the Loader transition cannot run"
    }
  }
}
