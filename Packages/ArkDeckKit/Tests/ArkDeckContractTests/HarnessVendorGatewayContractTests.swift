// Vendor gateway contract tests (CHG-2026-055, TASK-HFA-011).
//
// Registered acceptance: HFA-AC-21 (adapters are replaceable, outbound stays
// bounded and credential-free, and the model-call budget stops the model
// path without stopping the task).
//
// No test here opens a socket. The transport is the seam, and what is being
// pinned is what an adapter puts *into* it: the same canonical context bytes
// the ModelRun digest is taken over, a credential that lives only in a
// header, and a vendor envelope that is decoded but never trusted.

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckAgentComposition
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private let secretKey = "sk-test-DO-NOT-LEAK-4c1f9b"

private actor RecordingTransport: HarnessModelTransport {
  private var reply: HarnessModelHTTPResponse
  private var seen: [HarnessModelHTTPRequest] = []

  init(reply: HarnessModelHTTPResponse) { self.reply = reply }

  var requests: [HarnessModelHTTPRequest] { seen }

  func send(_ request: HarnessModelHTTPRequest) async throws -> HarnessModelHTTPResponse {
    seen.append(request)
    return reply
  }
}

private actor FailingTransport: HarnessModelTransport {
  func send(_ request: HarnessModelHTTPRequest) async throws -> HarnessModelHTTPResponse {
    throw HarnessDecisionGatewayError.transportFailure("network down")
  }
}

private actor RecordingCLITransport: HarnessLocalAgentCLITransport {
  private let reply: Data
  private var seen: [HarnessLocalAgentCLIRequest] = []

  init(reply: String) { self.reply = Data(reply.utf8) }

  var requests: [HarnessLocalAgentCLIRequest] { seen }

  func send(_ request: HarnessLocalAgentCLIRequest) async throws -> Data {
    seen.append(request)
    return reply
  }
}

private actor VendorJobPort: HarnessRuntimeJobPort {
  private var observations: [String: HarnessJobObservation] = [:]
  private var submitted: [String] = []
  private var ordinal = 1

  var submittedOperations: [String] { submitted }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submitted.append(request.operation.reference)
    let jobID = "JOB-\(ordinal)"
    ordinal += 1
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    guard let observation = observations[jobID] else {
      throw HarnessJobPortError.unknownJob(jobID)
    }
    return observation
  }

  func requestCancel(jobID: String) async throws {}
}

final class HarnessVendorGatewayContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-vendor-gateway-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - What goes out

  func testProductionConfigurationIsOffByDefaultAndFailsClosedWhenPartial() throws {
    XCTAssertNil(try HarnessVendorConfiguration.gateway(environment: [:]))
    XCTAssertThrowsError(
      try HarnessVendorConfiguration.gateway(
        environment: [HarnessVendorConfiguration.apiKeyKey: secretKey])
    ) { error in
      XCTAssertEqual(error as? HarnessVendorConfigurationError, .providerRequired)
    }
    XCTAssertThrowsError(
      try HarnessVendorConfiguration.gateway(
        environment: [
          HarnessVendorConfiguration.providerKey: "openai",
          HarnessVendorConfiguration.modelKey: "gpt-test",
        ])) { error in
          XCTAssertEqual(error as? HarnessVendorConfigurationError, .missingCredential)
        }
    XCTAssertThrowsError(
      try HarnessVendorConfiguration.gateway(
        environment: [
          HarnessVendorConfiguration.providerKey: "openai",
          HarnessVendorConfiguration.apiKeyKey: secretKey,
          HarnessVendorConfiguration.modelKey: "gpt-test",
          HarnessVendorConfiguration.endpointKey: "http://model.invalid/v1",
        ])) { error in
          XCTAssertEqual(error as? HarnessVendorConfigurationError, .malformedEndpoint)
        }
  }

  func testProductionConfigurationSelectsOneAdapterWithoutExposingTheKey() throws {
    let gateway = try XCTUnwrap(
      HarnessVendorConfiguration.gateway(
        environment: [
          HarnessVendorConfiguration.providerKey: "gemini",
          HarnessVendorConfiguration.apiKeyKey: secretKey,
          HarnessVendorConfiguration.modelKey: "gemini-test",
        ]))
    XCTAssertEqual(gateway.producerID, "gemini-gateway@1")
    XCTAssertEqual(gateway.modelDescriptor.provider, "google")
    XCTAssertFalse(String(describing: gateway.modelDescriptor).contains(secretKey))
  }

  /// The local-CLI lane is a closed set of profiles, not one vendor. Every
  /// profile has to be selectable by name, report its own producer identity,
  /// and refuse the same misconfigurations — otherwise "which CLI" quietly
  /// becomes "whichever one the code was written against".
  func testProductionConfigurationSelectsAnyIdentityBoundLocalAgentCLIWithoutAnAPIKey() throws {
    let transport = RecordingCLITransport(reply: #"{"kind":"noSafeAction"}"#)
    let workdir = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    XCTAssertEqual(
      HarnessLocalAgentCLIProfile.all.map(\.profileID), ["codex", "claude-code"],
      "the closed profile set is what keeps argv out of the environment")

    for profile in HarnessLocalAgentCLIProfile.all {
      let gateway = try XCTUnwrap(
        HarnessVendorConfiguration.gateway(
          environment: [
            HarnessVendorConfiguration.providerKey: profile.profileID,
            HarnessVendorConfiguration.modelKey: "model-test",
            HarnessVendorConfiguration.cliPathKey: "/bin/echo",
            HarnessVendorConfiguration.cliWorkingDirectoryKey: workdir,
          ],
          cliTransport: transport))
      XCTAssertEqual(gateway.producerID, "\(profile.profileID)-cli-gateway@1")
      XCTAssertEqual(gateway.modelDescriptor.provider, profile.providerLabel)

      XCTAssertThrowsError(
        try HarnessVendorConfiguration.gateway(
          environment: [
            HarnessVendorConfiguration.providerKey: profile.profileID,
            HarnessVendorConfiguration.modelKey: "model-test",
            HarnessVendorConfiguration.cliPathKey: "/bin/echo",
          ],
          cliTransport: transport)
      ) { error in
        XCTAssertEqual(
          error as? HarnessVendorConfigurationError, .missingCLIWorkingDirectory,
          "\(profile.profileID) must refuse an unnamed working root")
      }

      XCTAssertThrowsError(
        try HarnessVendorConfiguration.gateway(
          environment: [
            HarnessVendorConfiguration.providerKey: profile.profileID,
            HarnessVendorConfiguration.modelKey: "model-test",
            HarnessVendorConfiguration.cliPathKey: "/bin/echo",
            HarnessVendorConfiguration.cliWorkingDirectoryKey: workdir,
            HarnessVendorConfiguration.apiKeyKey: secretKey,
          ],
          cliTransport: transport)
      ) { error in
        XCTAssertEqual(
          error as? HarnessVendorConfigurationError,
          .unexpectedConfiguration("localAgentCLIDoesNotAcceptVendorCredentialOrEndpoint"))
      }
    }
  }

  /// The retired keys named one CLI. Ignoring them would leave a host that
  /// still sets them starting with no gateway and looking unconfigured, which
  /// is the failure that is hardest to see.
  func testRetiredSingleVendorKeysAreRefusedRatherThanIgnored() throws {
    let workdir = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    for retired in HarnessVendorConfiguration.retiredKeys {
      XCTAssertThrowsError(
        try HarnessVendorConfiguration.gateway(
          environment: [
            HarnessVendorConfiguration.providerKey: "codex",
            HarnessVendorConfiguration.modelKey: "model-test",
            HarnessVendorConfiguration.cliPathKey: "/bin/echo",
            HarnessVendorConfiguration.cliWorkingDirectoryKey: workdir,
            retired: "/bin/echo",
          ])
      ) { error in
        guard case .unexpectedConfiguration(let detail)? =
          error as? HarnessVendorConfigurationError
        else { return XCTFail("\(retired) was not refused") }
        XCTAssertTrue(detail.hasPrefix(retired), detail)
        XCTAssertTrue(detail.contains(HarnessVendorConfiguration.cliPathKey), detail)
      }
    }
  }

  func testEveryLocalAgentCLIProfileSendsOnlyTheBoundedContextNonInteractively() async throws {
    let response =
      #"{"kind":"noSafeAction","hypothesis":"bounded","reasonCode":"bounded"}"#
    let workdir = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let canonical = String(decoding: sampleContext().transmittedBytes, as: UTF8.self)

    for profile in HarnessLocalAgentCLIProfile.all {
      let transport = RecordingCLITransport(reply: response)
      let gateway = try LocalAgentCLIDecisionGateway(
        profile: profile, executablePath: "/bin/echo", modelName: "model-test",
        workingDirectory: workdir, transport: transport)
      let bytes = try await gateway.propose(sampleContext())
      XCTAssertEqual(String(decoding: bytes, as: UTF8.self), response)

      let requests = await transport.requests
      let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(request.executablePath, "/bin/echo")
      XCTAssertEqual(request.executableSHA256.count, 64)
      XCTAssertEqual(request.workingDirectory, workdir)
      XCTAssertEqual(request.profile, profile)

      // The prompt is the only model payload, whichever CLI carries it.
      XCTAssertTrue(request.prompt.contains(canonical), profile.profileID)
      XCTAssertTrue(request.prompt.contains("Patch fields are top-level fields"))
      XCTAssertTrue(request.prompt.contains("For proposePatch, omit operationRef and inputs"))
      XCTAssertTrue(
        request.prompt.contains(
          "include baseWorkspaceRevision, patchSha256, unifiedDiff, touchedFiles, and "
            + "expectedChangedSymbols"))
      XCTAssertFalse(request.prompt.contains(secretKey))

      let arguments = profile.arguments(
        modelName: "model-test", workingDirectory: workdir, prompt: request.prompt,
        finalMessagePath: profile.responseChannel == .finalMessageFile ? "/tmp/out.json" : nil)
      XCTAssertEqual(arguments.last, request.prompt, "\(profile.profileID) must pass the prompt")
      let model = try XCTUnwrap(arguments.firstIndex(of: "--model"))
      XCTAssertEqual(arguments[model + 1], "model-test")

      switch profile.profileID {
      case "codex":
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        let sandbox = try XCTUnwrap(arguments.firstIndex(of: "--sandbox"))
        XCTAssertEqual(arguments[sandbox + 1], "read-only")
        let output = try XCTUnwrap(arguments.firstIndex(of: "--output-last-message"))
        XCTAssertEqual(arguments[output + 1], "/tmp/out.json")
        XCTAssertEqual(profile.inheritedEnvironmentKeys, [])
      case "claude-code":
        XCTAssertTrue(arguments.contains("--print"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        // No permission mode: print mode cannot answer a permission prompt,
        // so the default already denies every tool. See
        // testTheClaudeCodeProfileAsksForReasoningNotAnAgentWithTools for why
        // naming `plan` here was actively harmful.
        XCTAssertFalse(arguments.contains("--permission-mode"))
        XCTAssertFalse(arguments.contains("--output-last-message"))
        // The CLI resolves its stored credential through `USER`; nothing else
        // is inherited, and no credential value is ever named here.
        XCTAssertEqual(profile.inheritedEnvironmentKeys, ["USER"])
      default:
        XCTFail("unreviewed profile \(profile.profileID) has no invocation contract")
      }
    }
  }

  /// A fence is presentation. Refusing a fenced answer burns a round on
  /// formatting, so one surrounding fence is unwrapped — and nothing else is:
  /// the closed key set and every value check stay with the strict parser.
  func testOneSurroundingCodeFenceIsPresentationNotContent() {
    let object = #"{"kind":"noSafeAction"}"#
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced("```json\n\(object)\n```"), object)
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced("```\n\(object)\n```"), object)
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced("  \(object)  "), object)
    // An unterminated fence is not a fence; half-removing it would corrupt
    // bytes the parser is entitled to judge as they were returned.
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced("```json\n\(object)"), "```json\n\(object)")
    // A fence-looking prefix inside the payload is left where it is.
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced("``"), "``")
  }

  /// The same narration without the fence.
  ///
  /// `HTASK-7C12960C4B6E` round 7, on device: the producer stated its answer
  /// as bare JSON on the line after a sentence, and a complete, correct patch
  /// proposal — right base revision, right diff, right hash — was discarded as
  /// `malformedJson`. That was the one round where a proposal was possible,
  /// so the task stopped for a human holding the very patch it needed. The
  /// fenced variant of this was fixed on 2026-08-05; this is the unfenced one.
  func testTheAnswerIsFoundWhenNarrationPrecedesBareJSON() {
    let object = #"{"kind":"proposePatch","hypothesis":"h"}"#
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced(
        "Good, matches standard sha256 hex length. Now composing the final "
          + "JSON answer.\n\n\(object)"),
      object)

    // A unified diff travels inside a JSON string, and it contains braces and
    // escaped quotes. A scanner that counted those would cut the answer in
    // half — which is worse than refusing it, because the halves may still
    // parse.
    // The braces must be *unbalanced* inside the string for this to
    // discriminate: a diff that closes every brace it opens would be
    // extracted correctly even by a scanner that ignored strings entirely,
    // and such a case proves nothing. A lone `}` is what a real hunk removing
    // a closing brace looks like, and it is what cuts the answer in half.
    let withDiff =
      #"{"kind":"proposePatch","unifiedDiff":"@@ -3 +3 @@\#n-  }\#n+  })\#n"}"#
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced("Here it is:\n\n\(withDiff)"), withDiff)

    // And an escaped quote must not end the string early. Discriminating
    // again requires care: the brace has to sit *between* the escaped quotes,
    // so that mishandling the escape puts it outside the string and closes
    // the object early. A brace after them stays inside either way and proves
    // nothing.
    // Built with ordinary escapes rather than a raw string: getting JSON's
    // `\"` out of `#"…"#` needs `\#\"`, and writing `\#\#"` instead silently
    // produces a different byte sequence that tests something else.
    let withEscapedQuote =
      "{\"kind\":\"proposePatch\",\"hypothesis\":\"it prints \\\"}\\\" on exit\",\"x\":\"y\"}"
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced("Answer:\n\n\(withEscapedQuote)"),
      withEscapedQuote)

    // Last, not first: an agent that shows its work puts the answer at the
    // end, and an earlier object is a draft or an illustration.
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced(
        "First I considered {\"kind\":\"noSafeAction\"} but rejected it.\n\n\(object)"),
      object)

    // An unterminated object is left alone rather than half-taken, the same
    // way an unclosed fence is.
    let truncated = "Composing:\n\n{\"kind\":\"proposePatch\""
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced(truncated), truncated)

    // Text with no object at all is returned untouched for the parser to
    // refuse on its own terms.
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced("I could not determine a fix."),
      "I could not determine a fix.")
  }

  /// A CLI agent narrates: it says what it checked, shows the diff, then
  /// states its answer in a fenced block. A complete and correct patch
  /// proposal was discarded as malformed because two sentences preceded it
  /// (observed on device, 2026-08-05), and the round after it stopped the
  /// task for a human who had exactly that patch sitting in the record.
  func testTheAnswerIsFoundWhenTheAgentNarratesBeforeIt() {
    let object = #"{"kind":"proposePatch","hypothesis":"h"}"#
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced(
        "Good, the diff is confirmed correct.\n\nNow producing the JSON:\n\n```json\n\(object)\n```"
      ),
      object)
    // Trailing narration too, and a language tag that is absent.
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced("Here it is:\n```\n\(object)\n```\nThat is my answer."),
      object)

    // An agent that shows its work puts the answer last; an earlier block is
    // a draft or an illustration.
    let draft = #"{"kind":"noSafeAction","hypothesis":"draft"}"#
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced(
        "First attempt:\n```json\n\(draft)\n```\nOn reflection:\n```json\n\(object)\n```"),
      object)

    // A fenced block that is not an object is not an answer: a shown diff or
    // a shell transcript must not be handed to the parser as one.
    let diff = "--- a/A.ets\n+++ b/A.ets\n@@ -1 +1 @@\n-old\n+new"
    XCTAssertEqual(
      LocalAgentCLIProcessTransport.unfenced(
        "The change:\n```diff\n\(diff)\n```\nand the decision:\n```json\n\(object)\n```"),
      object)
    let onlyDiff = "The change:\n```diff\n\(diff)\n```"
    XCTAssertEqual(LocalAgentCLIProcessTransport.unfenced(onlyDiff), onlyDiff)
  }

  /// Print mode has nobody to answer a permission prompt, so the default
  /// already denies every tool. `plan` additionally made the CLI read a
  /// request for one JSON decision as an attempt to route around its own
  /// approval gate, and answer with prose about that instead.
  func testTheClaudeCodeProfileAsksForReasoningNotAnAgentWithTools() {
    let arguments = HarnessLocalAgentCLIProfile.claudeCode.arguments(
      modelName: "sonnet", workingDirectory: "/tmp", prompt: "p", finalMessagePath: nil)
    XCTAssertTrue(arguments.contains("--print"))
    XCTAssertTrue(arguments.contains("--strict-mcp-config"))
    XCTAssertFalse(arguments.contains("--permission-mode"))
    XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
    XCTAssertFalse(arguments.contains("--allow-dangerously-skip-permissions"))
  }

  func testSharedInstructionDoesNotTellPatchProposalsToSelectAnOperation() {
    XCTAssertTrue(
      HarnessVendorEnvelope.instruction.contains(
        "For invokeOperation, include exactly one operationRef chosen from availableOperations"))
    XCTAssertTrue(
      HarnessVendorEnvelope.instruction.contains(
        "For proposePatch, omit operationRef and inputs"))
  }

  func testEveryAdapterSendsExactlyTheCanonicalContextBytes() async throws {
    let context = sampleContext()
    for (gateway, transport) in try adapters(replying: claudeReply()) {
      _ = try? await gateway.propose(context)
      let requests = await transport.requests
      let request = try XCTUnwrap(requests.first)
      let body = String(decoding: request.body, as: UTF8.self)
      // The bytes the ModelRun digest is taken over have to be the bytes on
      // the wire, or the digest documents something that never happened.
      let canonical = String(decoding: context.transmittedBytes, as: UTF8.self)
      XCTAssertTrue(
        body.contains(escapedForJSON(canonical)),
        "\(gateway.producerID) must carry the canonical context")
    }
  }

  func testTheCredentialNeverLeavesTheHeaderSet() async throws {
    let context = sampleContext()
    for (gateway, transport) in try adapters(replying: claudeReply()) {
      _ = try? await gateway.propose(context)
      let requests = await transport.requests
      let request = try XCTUnwrap(requests.first)
      let body = String(decoding: request.body, as: UTF8.self)
      XCTAssertFalse(body.contains(secretKey), "\(gateway.producerID) leaked the key into the body")
      XCTAssertFalse(
        request.url.contains(secretKey), "\(gateway.producerID) leaked the key into the URL")
      XCTAssertTrue(
        request.headers.values.contains(where: { $0.contains(secretKey) }),
        "\(gateway.producerID) must send the key as a header")
      // And nothing about the model identity carries it either.
      XCTAssertFalse(gateway.modelDescriptor.provider.contains(secretKey))
      XCTAssertFalse(gateway.modelDescriptor.modelName.contains(secretKey))
      XCTAssertFalse(gateway.modelDescriptor.adapterVersion.contains(secretKey))
    }
  }

  func testTheOutboundContextCarriesNoDeviceIdentity() throws {
    let context = sampleContext()
    let body = String(decoding: context.transmittedBytes, as: UTF8.self)
    for marker in ["TGT-958780b2ffb7", "connectKey", "/data/local/tmp"] {
      XCTAssertFalse(body.localizedCaseInsensitiveContains(marker))
    }
  }

  // MARK: - What comes back

  func testEachVendorEnvelopeIsDecodedToTheSameProposalBytes() async throws {
    let context = sampleContext()
    let expected = #"{"kind":"invokeOperation","operationRef":"observe.device@1"}"#
    let replies: [(any HarnessDecisionGateway, RecordingTransport)] = [
      try claude(replying: claudeReply(text: expected)),
      try openAI(replying: openAIReply(text: expected)),
      try gemini(replying: geminiReply(text: expected)),
    ]
    for (gateway, _) in replies {
      let bytes = try await gateway.propose(context)
      XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected)
    }
  }

  func testAVendorErrorOrGarbageIsATransportFailureAndNotAProposal() async throws {
    let context = sampleContext()
    let broken: [(String, HarnessModelHTTPResponse)] = [
      ("http 500", HarnessModelHTTPResponse(statusCode: 500, body: Data("{}".utf8))),
      ("http 401", HarnessModelHTTPResponse(statusCode: 401, body: Data("{}".utf8))),
      ("not json", HarnessModelHTTPResponse(statusCode: 200, body: Data("<html>".utf8))),
      ("empty envelope", HarnessModelHTTPResponse(statusCode: 200, body: Data("{}".utf8))),
    ]
    for (label, reply) in broken {
      let (gateway, _) = try claude(replying: reply)
      do {
        _ = try await gateway.propose(context)
        XCTFail("\(label) must not produce a proposal")
      } catch let error as HarnessDecisionGatewayError {
        guard case .transportFailure = error else {
          return XCTFail("\(label) must read as a transport failure, got \(error)")
        }
      }
    }
  }

  func testATransportThatThrowsDoesNotBecomeAProposal() async throws {
    let gateway = ClaudeDecisionGateway(
      credential: credential(), transport: FailingTransport())
    do {
      _ = try await gateway.propose(sampleContext())
      XCTFail("a dead transport must not yield a decision")
    } catch {}
  }

  // MARK: - Replaceability and budget

  func testSwappingAdaptersDoesNotAffectDeterministicTypedRouting() async throws {
    // Mechanical routing does not consult any adapter. Swapping all three
    // configured vendors therefore leaves the exact typed dispatch unchanged
    // and sends no context off-host.
    let proposal =
      #"{"kind":"invokeOperation","operationRef":"observe.device@1","hypothesis":"Observe the target first.","reasonCode":"baselineTargetObservation"}"#
    var outcomes: [String] = []
    var dispatched: [[String]] = []
    let adapters = [
      try claude(replying: claudeReply(text: proposal)),
      try openAI(replying: openAIReply(text: proposal)),
      try gemini(replying: geminiReply(text: proposal)),
    ]
    for (gateway, transport) in adapters {
      let jobs = VendorJobPort()
      let (coordinator, _) = try makeStack(gateway: gateway, jobs: jobs)
      let task = try await coordinator.submit(submission())
      let outcome = try await coordinator.reconcile(task.htaskID)
      outcomes.append(outcome.action.rawValue)
      dispatched.append(await jobs.submittedOperations)
      let requests = await transport.requests
      XCTAssertTrue(requests.isEmpty)
      XCTAssertEqual(outcome.snapshot.consumedBudget.modelCalls, 0)
    }
    XCTAssertEqual(Set(outcomes), ["dispatched"])
    XCTAssertEqual(Set(dispatched.map { $0.joined() }), ["observe.device@1"])
  }

  func testAnExhaustedModelBudgetDoesNotStopAMechanicalTypedStep() async throws {
    let jobs = VendorJobPort()
    let (gateway, transport) = try claude(
      replying: claudeReply(
        text: #"{"kind":"invokeOperation","operationRef":"observe.device@1","hypothesis":"h","reasonCode":"baselineTargetObservation"}"#
      ))
    // Zero calls allowed: the deterministic handler must still converge, so
    // this is a ceiling on spend, not a halt.
    let (coordinator, _) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission(maxModelCalls: 0))
    let outcome = try await coordinator.reconcile(task.htaskID)

    XCTAssertEqual(outcome.action, .dispatched)
    let operations = await jobs.submittedOperations
    XCTAssertEqual(operations, [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(outcome.snapshot.consumedBudget.modelCalls, 0)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty, "an exhausted budget must not reach the vendor")
  }

  func testAModelCallIsChargedEvenWhenItsProposalIsRefused() async throws {
    let jobs = VendorJobPort()
    // `verdict` is a field the harness owns, so the parser refuses the whole
    // proposal - but the call happened and shipped a context.
    let (gateway, _) = try claude(
      replying: claudeReply(text: #"{"kind":"invokeOperation","verdict":"pass"}"#))
    let (coordinator, store) = try makePatchStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(patchSubmission())
    let outcome = try await coordinator.reconcile(task.htaskID)

    XCTAssertEqual(outcome.snapshot.consumedBudget.modelCalls, 1)
    XCTAssertTrue(outcome.reasonCode.contains("proposalRejected"))
    let runs = try await store.modelRuns(task.htaskID)
    XCTAssertEqual(runs.count, 1)
    XCTAssertGreaterThan(runs[0].responseBytes, 0)
    XCTAssertEqual(runs[0].descriptor.provider, "anthropic")
  }

  func testBudgetsPersistedBeforeThisCeilingStillLoad() throws {
    // A task written by an older daemon has no maxModelCalls. It must decode
    // to the default rather than failing to load.
    let legacy = Data(
      """
      {"maxRounds":8,"maxWallClockSeconds":900,"maxArtifactBytes":1048576,\
      "maxE1Mutations":0}
      """.utf8)
    let decoded = try JSONDecoder().decode(HarnessTaskBudgets.self, from: legacy)
    XCTAssertEqual(decoded.maxModelCalls, 24)
    let consumed = try JSONDecoder().decode(
      HarnessConsumedBudget.self,
      from: Data(
        #"{"rounds":1,"wallClockSeconds":2,"artifactBytes":3,"e1Mutations":0}"#.utf8))
    XCTAssertEqual(consumed.modelCalls, 0)
  }

  // MARK: - Helpers

  private func credential(model: String = "test-model") -> HarnessVendorCredential {
    HarnessVendorCredential(
      apiKey: secretKey, endpoint: "https://vendor.invalid/v1", modelName: model)
  }

  private func claude(
    replying reply: HarnessModelHTTPResponse
  ) throws -> (any HarnessDecisionGateway, RecordingTransport) {
    let transport = RecordingTransport(reply: reply)
    return (ClaudeDecisionGateway(credential: credential(), transport: transport), transport)
  }

  private func openAI(
    replying reply: HarnessModelHTTPResponse
  ) throws -> (any HarnessDecisionGateway, RecordingTransport) {
    let transport = RecordingTransport(reply: reply)
    return (OpenAIDecisionGateway(credential: credential(), transport: transport), transport)
  }

  private func gemini(
    replying reply: HarnessModelHTTPResponse
  ) throws -> (any HarnessDecisionGateway, RecordingTransport) {
    let transport = RecordingTransport(reply: reply)
    return (GeminiDecisionGateway(credential: credential(), transport: transport), transport)
  }

  private func adapters(
    replying reply: HarnessModelHTTPResponse
  ) throws -> [(any HarnessDecisionGateway, RecordingTransport)] {
    [try claude(replying: reply), try openAI(replying: reply), try gemini(replying: reply)]
  }

  private func claudeReply(text: String = "{}") -> HarnessModelHTTPResponse {
    HarnessModelHTTPResponse(
      statusCode: 200,
      body: HarnessVendorEnvelope.json([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])])
      ]))
  }

  private func openAIReply(text: String) -> HarnessModelHTTPResponse {
    HarnessModelHTTPResponse(
      statusCode: 200,
      body: HarnessVendorEnvelope.json([
        "choices": .array([.object(["message": .object(["content": .string(text)])])])
      ]))
  }

  private func geminiReply(text: String) -> HarnessModelHTTPResponse {
    HarnessModelHTTPResponse(
      statusCode: 200,
      body: HarnessVendorEnvelope.json([
        "candidates": .array([
          .object(["content": .object(["parts": .array([.object(["text": .string(text)])])])])
        ])
      ]))
  }

  private func escapedForJSON(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func budgets(maxModelCalls: Int = 24) -> HarnessTaskBudgets {
    HarnessTaskBudgets(
      maxRounds: 6, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
      maxE1Mutations: 0, maxModelCalls: maxModelCalls)
  }

  private func submission(maxModelCalls: Int = 24) -> HarnessTaskSubmission {
    HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
      goal: HarnessTaskGoal(summary: "No WaterFlow SIGABRT"),
      budgets: budgets(maxModelCalls: maxModelCalls),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
  }

  private func patchSubmission(maxModelCalls: Int = 2) -> HarnessTaskSubmission {
    HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
      goal: HarnessTaskGoal(summary: "Repair the bounded source failure"),
      budgets: budgets(maxModelCalls: maxModelCalls),
      policy: HarnessTaskPolicy(allowedOperations: [DebugCrashTaskHandler.applyPatch]))
  }

  private func makeStack(
    gateway: any HarnessDecisionGateway,
    jobs: VendorJobPort,
    budgets: HarnessTaskBudgets? = nil
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore) {
    let store = try HarnessTaskStore(rootURL: rootURL.appendingPathComponent(UUID().uuidString))
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:00Z" },
      decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(enabledProjects: ["demo-app"]))
    return (coordinator, store)
  }

  private func makePatchStack(
    gateway: any HarnessDecisionGateway,
    jobs: VendorJobPort
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore) {
    let store = try HarnessTaskStore(rootURL: rootURL.appendingPathComponent(UUID().uuidString))
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, handlers: [PatchQuestionHandler()],
      nowUTC: { "2026-07-31T00:00:00Z" }, decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(enabledProjects: ["demo-app"]))
    return (coordinator, store)
  }

  private func sampleContext() -> HarnessDecisionContext {
    HarnessDecisionContext(
      targetPseudonym: HarnessDecisionContext.pseudonym(forTargetID: "TGT-958780b2ffb7"),
      taskType: .debugCrash, status: .running, phase: .collecting, round: 1,
      goalSummary: "No WaterFlow SIGABRT", desiredState: [:], observedMeasurements: [:],
      observedSamples: [:], latestVerdict: nil, criterionResults: [], recentAttempts: [],
      unresolvedFailures: [], relevantMemory: [], artifacts: [],
      availableOperations: ["observe.device@1"],
      budget: HarnessContextBudget(
        roundsRemaining: 5, wallClockSecondsRemaining: 800, artifactBytesRemaining: 1 << 20,
        e1MutationsRemaining: 0),
      blockers: [], trimmed: [])
  }
}
