import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import Darwin
import Foundation
import Security

public protocol HDCStatusObserving: Sendable {
  func snapshot() async -> JSONValue
}

/// In-memory provenance recorded at the existing identity-bound spawn point.
/// A status reader cannot manufacture it from an observed PID or endpoint.
package struct HDCManagedProcessLaunch: Sendable, Equatable {
  let pid: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let executablePath: String
  let executableSHA256: String
  let arguments: [String]

  static func capture(pid: Int32, executable: ProcessExecutableIdentityReceipt, request: ProcessRequest) -> Self? {
    var info = proc_bsdinfo()
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
      info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
    return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
      executablePath: executable.authorizedPath, executableSHA256: executable.sha256, arguments: request.arguments)
  }

  func matches(_ receipt: HDCServerProcessIdentityReceipt) -> Bool {
    pid == receipt.pid && startSeconds == receipt.startSeconds && startMicroseconds == receipt.startMicroseconds &&
      executablePath == receipt.executablePath.path && executableSHA256 == receipt.executableSHA256
  }
}

/// Fresh commandless status for protocol 2. Startup readiness is preserved
/// separately as historical diagnostics and can never become current health.
package struct HeadlessHDCStatusObserver: HDCStatusObserving {
  private let executable: ResolvedExecutable
  private let startup: HDCManagedRuntimeDiagnostics
  private let daemonVersion: String?
  private let managedLaunch: @Sendable () -> HDCManagedProcessLaunch?
  private let supervisor: HDCServerSupervisor?
  private let observeIdentity: @Sendable (HDCCandidate, HDCServerEndpoint) async -> HDCSupervisorObservationResult
  private let inspectSignature: @Sendable (URL) throws -> JSONValue
  private let validateManagedProcess: @Sendable (HDCServerProcessIdentityReceipt, [String]) -> Bool
  private let nowUTC: @Sendable () -> String

  package init(executable: ResolvedExecutable, startup: HDCManagedRuntimeDiagnostics,
    daemonVersion: String?, managedLaunch: @escaping @Sendable () -> HDCManagedProcessLaunch?,
    supervisor: HDCServerSupervisor? = nil) {
    self.init(executable: executable, startup: startup, daemonVersion: daemonVersion, managedLaunch: managedLaunch,
      supervisor: supervisor,
      observeIdentity: { await HDCCommandlessServerIdentity.observe(toolchain: $0, endpoint: $1) },
      inspectSignature: Self.signature,
      validateManagedProcess: HDCCommandlessServerIdentity.verifiesManagedProcess,
      nowUTC: { ISO8601DateFormatter().string(from: Date()) })
  }

  // Module-internal test seam, not a daemon caller or configuration input.
  init(executable: ResolvedExecutable, startup: HDCManagedRuntimeDiagnostics, daemonVersion: String?,
    managedLaunch: @escaping @Sendable () -> HDCManagedProcessLaunch?,
    supervisor: HDCServerSupervisor? = nil,
    observeIdentity: @escaping @Sendable (HDCCandidate, HDCServerEndpoint) async -> HDCSupervisorObservationResult,
    inspectSignature: @escaping @Sendable (URL) throws -> JSONValue,
    validateManagedProcess: @escaping @Sendable (HDCServerProcessIdentityReceipt, [String]) -> Bool,
    nowUTC: @escaping @Sendable () -> String) {
    self.executable = executable; self.startup = startup; self.daemonVersion = daemonVersion
    self.managedLaunch = managedLaunch; self.observeIdentity = observeIdentity
    self.supervisor = supervisor
    self.inspectSignature = inspectSignature; self.nowUTC = nowUTC
    self.validateManagedProcess = validateManagedProcess
  }

  package func snapshot() async -> JSONValue {
    var fields = Self.empty(daemonVersion: daemonVersion)
    fields["observedAt"] = .string(nowUTC())
    fields["executablePath"] = .string(executable.path)
    fields["executableSource"] = .string("runtimeConfiguration")
    fields["configuredExecutableSHA256"] = .string(executable.sha256)
    fields["endpoint"] = .string(startup.endpoint)
    fields["endpointSource"] = .string(startup.endpointSource)
    fields["serverEndpointRef"] = .string("hdc-endpoint:" + SHA256Hex.string(of: Data(startup.endpoint.utf8)))
    fields["startupVersions"] = .object(["client": .string(startup.clientVersion), "server": .string(startup.serverVersion)])
    do {
      let path = URL(filePath: executable.path)
      let pinned = try VerifiedRegularFileDescriptor.open(path: path, expectedSHA256: executable.sha256,
        maximumBytes: 256 * 1024 * 1024, requireExecutable: true)
      let signature = try inspectSignature(path)
      try pinned.revalidate()
      let launchedBefore = managedLaunch()
      let endpoint = HDCServerEndpoint(startup.endpoint)
      let supervisedBefore: HDCServerState? = if let supervisor {
        await supervisor.state(for: endpoint)
      } else { nil }
      let result = await observeIdentity(HDCCandidate(path: path, source: .userConfigured, sha256: executable.sha256), endpoint)
      let supervisedAfter: HDCServerState? = if let supervisor {
        await supervisor.state(for: endpoint)
      } else { nil }
      try pinned.revalidate()
      fields["executableSHA256"] = .string(executable.sha256)
      fields["signature"] = signature
      let clientVersion = HDCCommandlessServerIdentity.clientVersion(sha256: executable.sha256)
      fields["clientVersion"] = clientVersion.map(JSONValue.string) ?? .null
      fields["clientVersionSource"] = clientVersion == nil ? .null : .string("publishedExecutableDigest")
      switch result.classification {
      case .observed(let generation):
        guard let receipt = result.identity, generation > 0, receipt.stableGeneration == generation,
          receipt.executableSHA256 == executable.sha256, receipt.executablePath.path == executable.path,
          receipt.endpoint.rawValue == startup.endpoint else {
          fields["reasonCode"] = .string("hdc.identityMismatch"); break
        }
        fields["availability"] = .string("available")
        fields["generation"] = .string(String(generation))
        fields["processId"] = .integer(Int64(receipt.pid))
        // Equality with the original spawn receipt, not tool path/PID alone.
        let launchedAfter = managedLaunch()
        let managed: Bool
        if let launch = launchedBefore, launch == launchedAfter, launch.matches(receipt) {
          managed = validateManagedProcess(receipt, launch.arguments) && managedLaunch() == launch
        } else if let supervisedBefore, supervisedBefore == supervisedAfter,
          supervisedBefore.endpoint == endpoint,
          supervisedBefore.health == .healthy,
          supervisedBefore.generation == generation,
          supervisedBefore.ownership == .arkDeckManaged
        { managed = true }
        else { managed = false }
        try pinned.revalidate()
        fields["ownership"] = .string(managed ? "arkDeckManaged" : "unknown")
        fields["reasonCode"] = .string(managed ? "hdc.identityObserved" : "hdc.ownershipUnproven")
      case .unavailable:
        fields["availability"] = .string("unavailable"); fields["reasonCode"] = .string("hdc.selectedServerNotObserved")
      case .unsupported:
        fields["availability"] = .string("unavailable"); fields["reasonCode"] = .string("hdc.identityFamilyUnavailable")
      case .timedOut: fields["reasonCode"] = .string("hdc.identityObservationTimedOut")
      case .cancelled: fields["reasonCode"] = .string("hdc.identityObservationCancelled")
      case .unknown: fields["reasonCode"] = .string("hdc.identityUnknown")
      }
    } catch {
      fields["availability"] = .string("unavailable")
      fields["reasonCode"] = .string("hdc.toolIdentityOrSignatureInvalid")
      for key in ["executableSHA256", "signature", "clientVersion", "clientVersionSource", "generation", "processId"] { fields[key] = .null }
      fields["ownership"] = .string("unknown")
    }
    return .object(fields)
  }

  package static func unconfigured(daemonVersion: String? = nil) -> JSONValue {
    var fields = empty(daemonVersion: daemonVersion)
    fields["availability"] = .string("unavailable")
    return .object(fields)
  }
  private static func empty(daemonVersion: String?) -> [String: JSONValue] {
    ["schemaVersion": .string("arkdeck.runtime-hdc-status/1"), "availability": .string("unknown"),
      "observedAt": .null, "executablePath": .null, "executableSource": .null,
      "configuredExecutableSHA256": .null, "executableSHA256": .null, "signature": .null,
      "clientVersion": .null, "clientVersionSource": .null, "serverVersion": .null, "daemonVersion": daemonVersion.map(JSONValue.string) ?? .null,
      "endpoint": .null, "endpointSource": .null, "serverEndpointRef": .null,
      "ownership": .string("unknown"), "generation": .null, "processId": .null,
      "serverHealth": .string("unknown"), "healthReasonCode": .string("hdc.commandlessIdentityDoesNotProveHealth"),
      "startupVersions": .null, "reasonCode": .string("hdc.notConfigured"), "newDispatchCount": .integer(0)]
  }

  package static func signature(_ path: URL) throws -> JSONValue {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(path as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
      throw AgentExecutionControlFailure("recordUnreadable", "native code identity is unavailable")
    }
    let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil)
    var fields: [String: JSONValue] = ["state": .string("unsigned"), "identifier": .null, "teamIdentifier": .null,
      "platformTrust": .string("unverified"), "executionAssessment": .string("notPerformed")]
    if status == errSecCSUnsigned { return .object(fields) }
    guard status == errSecSuccess else { throw AgentExecutionControlFailure("recordUnreadable", "native signature validation failed") }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
      let info = raw as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? NSNumber else {
      throw AgentExecutionControlFailure("recordUnreadable", "native signature metadata is unavailable")
    }
    fields["state"] = .string(flags.uint32Value & 0x2 != 0 ? "adHoc" : "verified")
    for (key, output) in [(kSecCodeInfoIdentifier as String, "identifier"), (kSecCodeInfoTeamIdentifier as String, "teamIdentifier")] {
      if let value = info[key] as? String {
        guard !value.isEmpty, value.utf8.count <= 256, value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
          throw AgentExecutionControlFailure("recordUnreadable", "native signature metadata exceeds its bounds")
        }
        fields[output] = .string(value)
      }
    }
    return .object(fields)
  }
}
