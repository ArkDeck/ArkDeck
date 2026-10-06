using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Host-only observable Device behavior. Synthetic dispatch never represents hardware evidence.</summary>
[TestClass]
public sealed class DeviceScreenTests
{
    private static DeviceScreenTarget Target => new("target-fixture", 3, new string('a', 64), "Bench");
    private static DeviceScreenFrame Frame(bool historical = false) => new([], 400, 800, "job-capture", "artifact-image", new string('b', 64), Target, "2026-10-06T10:00:00Z", historical);

    [TestMethod]
    public void LetterboxingPressAnchorAndOutOfBoundsRelease()
    {
        var viewport = DeviceViewport.Fit(600, 600, 400, 800)!;
        Assert.AreEqual((150d, 0d, 300d, 600d), (viewport.X, viewport.Y, viewport.Width, viewport.Height));
        Assert.IsFalse(viewport.Contains(new(100, 300)));
        Assert.IsNull(DeviceGestureRequest.Classify(new(100, 300), new(200, 300), 100, 1, viewport));
        var hold = DeviceGestureRequest.Classify(new(300, 150), new(303, 154), 5, .8, viewport)!;
        Assert.AreEqual((DeviceGesture.LongPress, 200, 200, 800), (hold.Gesture, hold.X, hold.Y, hold.DurationMs));
        var swipe = DeviceGestureRequest.Classify(new(300, 150), new(double.MaxValue, -double.MaxValue), 40, 5, viewport)!;
        Assert.AreEqual((399, 0, 2000), (swipe.ToX, swipe.ToY, swipe.DurationMs));
        Assert.IsNull(DeviceViewport.Fit(double.NaN, 20, 400, 800));
        Assert.IsNull(DeviceGestureRequest.Classify(new(300, 150), new(300, 150), 0, double.NaN, viewport));
    }

    [TestMethod]
    public void OnlyAnExplicitCurrentCaptureEnablesOneInput()
    {
        var session = new DeviceScreenSession();
        session.Select(Target);
        Assert.IsFalse(session.CanInput);
        var generation = session.Begin()!.Value;
        Assert.IsNull(session.Begin());
        Assert.IsTrue(session.Captured(generation, Frame()));
        Assert.IsTrue(session.CanInput);
        generation = session.Begin(input: true)!.Value;
        Assert.IsFalse(session.CanInput);
        Assert.IsTrue(session.Settled(generation, DeviceInputVerdict.Failed));
        Assert.IsTrue(session.CanInput, "A known refusal changed no device state");
        generation = session.Begin(input: true)!.Value;
        session.Settled(generation, DeviceInputVerdict.Unknown);
        Assert.IsFalse(session.CanInput);
        Assert.IsNull(session.Begin(input: true));
        generation = session.Begin()!.Value;
        session.Captured(generation, Frame());
        generation = session.Begin(input: true)!.Value;
        session.Settled(generation, DeviceInputVerdict.Confirmed);
        Assert.IsFalse(session.CanInput);
    }

    [TestMethod]
    public void HistoricalFramesAndLateDifferentBindingCannotBecomeCurrent()
    {
        var session = new DeviceScreenSession();
        session.Select(Target);
        var generation = session.BeginHistory()!.Value;
        Assert.IsTrue(session.Captured(generation, Frame(historical: true)));
        Assert.IsFalse(session.CanInput);
        generation = session.Begin()!.Value;
        session.Select(Target with { BindingRevision = 4 });
        Assert.IsFalse(session.Captured(generation, Frame()));
        Assert.IsNull(session.Frame);
        Assert.IsFalse(session.CanInput);
        session.Select(Target with { Title = "Renamed" });
        generation = session.Begin()!.Value;
        Assert.IsTrue(session.Captured(generation, Frame()));
        session.Select(Target with { Title = "Another name" });
        Assert.IsTrue(session.CanInput, "A display name has no identity authority");
        session.Select(Target with { StableIdentitySha256 = new string('c', 64) });
        Assert.IsNull(session.Frame);
    }

    [TestMethod]
    public void FailedRecaptureRetainsOnlyAStalePictureAndSuccessfulRecaptureRestoresInput()
    {
        var session = new DeviceScreenSession();
        session.Select(Target);
        Assert.IsTrue(session.Captured(session.Begin()!.Value, Frame()));
        var previous = session.Frame;
        Assert.IsTrue(session.CanInput);
        var generation = session.Begin()!.Value;
        Assert.IsFalse(session.Current, "A new capture invalidates local liveness immediately");
        Assert.IsFalse(session.Captured(generation, null), "Failed capture and failed native decode settle without a new frame");
        Assert.AreSame(previous, session.Frame, "The previous verified picture remains visible as stale");
        Assert.IsFalse(session.CanInput);
        Assert.IsNull(session.Begin(input: true));
        Assert.IsTrue(session.Captured(session.Begin()!.Value, Frame()));
        Assert.IsTrue(session.CanInput);
    }

    [TestMethod]
    public void PendingHistoricalSelectionSurvivesBusyAndRejectsTheOldCapture()
    {
        var session = new DeviceScreenSession();
        session.Select(Target);
        var oldGeneration = session.Begin()!.Value;
        session.RequestHistory();
        Assert.IsTrue(session.Generation > oldGeneration);
        Assert.IsFalse(session.Current);
        Assert.IsNull(session.BeginHistory());
        Assert.IsTrue(session.HistoryPending, "A busy operation must not consume the pending readonly history");
        Assert.IsFalse(session.Captured(oldGeneration, Frame()), "The old capture cannot restore input liveness");
        session.End();
        Assert.IsTrue(session.HistoryPending);
        var generation = session.BeginHistory()!.Value;
        Assert.IsFalse(session.HistoryPending, "Only an actual readonly history start consumes its pending selection");
        Assert.IsTrue(session.Captured(generation, Frame(historical: true)));
        Assert.IsFalse(session.CanInput);
        Assert.IsNull(session.Begin(input: true));
    }

    [TestMethod]
    public void KeyboardConsentBoundsAndPrivateJobInputs()
    {
        Assert.IsFalse(new DeviceKeyboardCommand(Text: "hello").IsValid);
        Assert.IsTrue(new DeviceKeyboardCommand(Text: "中文", ClipboardConsent: true).IsValid);
        Assert.IsFalse(new DeviceKeyboardCommand(Text: new string('中', 171), ClipboardConsent: true).IsValid);
        Assert.IsFalse(new DeviceKeyboardCommand(Text: "hidden\nline", ClipboardConsent: true).IsValid);
        Assert.IsFalse(new DeviceKeyboardCommand(Key: "exec").IsValid);
        Assert.IsFalse(new DeviceKeyboardCommand(Key: "enter", Text: "hidden").IsValid);
        Assert.IsTrue(DeviceKeyboardCommand.Keys.All(k => new DeviceKeyboardCommand(Key: k).IsValid));
        var gesture = DeviceOperations.Gesture(Target, new(DeviceGesture.Swipe, 1, 2, 400, 800, 30, 40, 500));
        var document = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(gesture.Json));
        Assert.AreEqual("ArkDeckApp.Toolkit.DeviceControl", ((JsonString)document["clientContext"]["clientName"]).Value);
        Assert.AreEqual(3L, ((JsonNumber)document["target"]["expectedBindingRevision"]).AsDouble());
        Assert.IsInstanceOfType<JsonNull>(document["authorization"]);
        Assert.IsInstanceOfType<JsonNull>(document["campaignMember"]);
        Assert.IsInstanceOfType<JsonNull>(document["inputs"]["inputEpochUtc"]);
        Assert.AreEqual(500L, ((JsonNumber)document["inputs"]["durationMs"]).AsDouble());
    }

    [TestMethod]
    public void RunDeadlineUsesOnlyTheMatchingPublishedAvailableDescriptor()
    {
        OperationFacts Facts(string op, long timeout, bool available = true) => new(op, op, "readOnly", timeout, 1,
            new(available ? AvailabilityKind.Available : AvailabilityKind.Unavailable, []), []);
        Assert.AreEqual(TimeSpan.FromSeconds(910), DeviceOperations.RunCallBudget(Facts(DeviceOperations.Recording, 900), DeviceOperations.Recording));
        Assert.AreEqual(TimeSpan.FromSeconds(11), DeviceOperations.RunCallBudget(Facts("input.tap@1", 1), "input.tap@1"));
        Assert.IsNull(DeviceOperations.RunCallBudget(Facts(DeviceOperations.Recording, 901), DeviceOperations.Recording));
        Assert.IsNull(DeviceOperations.RunCallBudget(Facts(DeviceOperations.Recording, 0), DeviceOperations.Recording));
        Assert.IsNull(DeviceOperations.RunCallBudget(Facts(DeviceOperations.Capture, 10), DeviceOperations.Recording));
        Assert.IsNull(DeviceOperations.RunCallBudget(Facts(DeviceOperations.Recording, 900, false), DeviceOperations.Recording));
        Assert.IsNull(DeviceOperations.RunCallBudget(Facts("flash.full-restore@1", 900), "flash.full-restore@1"));
    }

    [TestMethod]
    public async Task WholeScreenshotAndReadonlySameJobHistory()
    {
        var channel = new DeviceChannel();
        var loader = new SurfaceLoader(channel);
        var gate = await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId);
        Assert.IsNull(gate.Refusal, gate.Refusal);
        var captured = await loader.CaptureDeviceScreenAsync(gate.Target!);
        Assert.IsNull(captured.Failure, captured.Failure);
        Assert.AreEqual((400, 800, false), (captured.Frame!.Width, captured.Frame.Height, captured.Frame.Historical));
        Assert.AreEqual(1, channel.RunCount);
        Assert.AreEqual(1, channel.SubmitCount);
        Assert.IsTrue(channel.RunBudget > DaemonConfiguration.CallBudget);
        var before = channel.SubmitCount;
        var history = new HistoryWorkspaceContext(captured.Frame.JobId, DeviceOperations.Capture, captured.Frame.Target.TargetId, "succeeded", null, null,
            WorkspaceKind.Device, 3, null, []);
        var reopened = await loader.LoadDeviceHistoryAsync(history);
        Assert.IsNull(reopened.Failure, reopened.Failure);
        Assert.IsTrue(reopened.Frame!.Historical);
        CollectionAssert.AreEqual(captured.Frame.Bytes, reopened.Frame.Bytes);
        Assert.AreEqual(before, channel.SubmitCount);
        Assert.AreEqual(1, channel.RunCount, "History must never run a recorded request");
        channel.CorruptImage = true;
        Assert.IsNull((await loader.LoadDeviceHistoryAsync(history)).Frame);
    }

    [TestMethod]
    public async Task UnknownInputNeverRepeatsRunAndInvalidAcceptedRequestNeverRuns()
    {
        var channel = new DeviceChannel { LostRun = true };
        var loader = new SurfaceLoader(channel);
        var target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
        var result = await loader.SendDeviceGestureAsync(target, new(DeviceGesture.Tap, 10, 20, 400, 800));
        Assert.AreEqual(DeviceInputVerdict.Unknown, result.Verdict);
        Assert.AreEqual(1, channel.RunCount);
        Assert.AreEqual(1, channel.SubmitCount);
        Assert.IsNotNull(result.JobId);
        var invalid = new DeviceChannel { WrongAcceptedIdentity = true };
        var invalidLoader = new SurfaceLoader(invalid);
        target = (await invalidLoader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
        result = await invalidLoader.SendDeviceGestureAsync(target, new(DeviceGesture.Tap, 10, 20, 400, 800));
        Assert.AreEqual(DeviceInputVerdict.Unknown, result.Verdict);
        Assert.AreEqual(0, invalid.RunCount);
        Assert.AreEqual(1, invalid.SubmitCount);
    }

    [TestMethod]
    public async Task ConfirmedInputRequiresVerifiedInjectorAndMaterializedBinding()
    {
        var channel = new DeviceChannel();
        var loader = new SurfaceLoader(channel);
        var target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
        var result = await loader.SendDeviceGestureAsync(target, new(DeviceGesture.LongPress, 10, 20, 400, 800, DurationMs: 600));
        Assert.AreEqual(DeviceInputVerdict.Confirmed, result.Verdict);
        channel.NoInjectorProof = true;
        result = await loader.SendDeviceGestureAsync(target, new(DeviceGesture.Tap, 10, 20, 400, 800));
        Assert.AreEqual(DeviceInputVerdict.Unknown, result.Verdict);
        var wrongBinding = target with { BindingRevision = 4 };
        var before = channel.SubmitCount;
        result = await loader.SendDeviceGestureAsync(wrongBinding, new(DeviceGesture.Tap, 10, 20, 400, 800));
        Assert.AreEqual(DeviceInputVerdict.Failed, result.Verdict);
        Assert.AreEqual(before, channel.SubmitCount);
    }

    [TestMethod]
    public void CompleteRequestMatchesIndependentRecordedRustShowAndOmittedNilFields()
    {
        var document = (JsonObject)StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "job-publication-current", "published", "show.json")));
        // Independent literal in another key order, not an echo of the fixture's request.
        var request = new RuntimeRequest("""{"target":{"targetId":"TGT-PUBLICATION","expectedBindingRevision":7},"schemaVersion":"1.0.0","requestedOutputs":["derivedArtifacts"],"requestId":"req-device-session","operation":{"version":1,"id":"observe.device"},"inputs":{},"idempotencyKey":"idem-device-session","documentType":"runtime-operation-request"}""");
        var target = new DeviceScreenTarget("TGT-PUBLICATION", 7, "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547", "Recorded");
        Assert.IsTrue(DeviceOperations.RequestMatches(document, request, "job-a9fda911411280791d18df748a6d3d84", target, "observe.device@1"));
        Assert.IsFalse(DeviceOperations.AcceptedRequest(document, request, "job-a9fda911411280791d18df748a6d3d84", target, "observe.device@1"), "A terminal historical Job never grants another run");
    }

    [TestMethod]
    public async Task ReorderedCompleteRequestRunsOnceAndUnselectedFieldDriftNeverRuns()
    {
        foreach (var drift in new[] { "none", "outputs", "client", "provenance", "budget", "schema" })
        {
            var channel = new DeviceChannel { StoredRequestDrift = drift };
            var loader = new SurfaceLoader(channel);
            var target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
            var result = await loader.SendDeviceGestureAsync(target, new(DeviceGesture.Tap, 10, 20, 400, 800));
            Assert.AreEqual(drift == "none" ? DeviceInputVerdict.Confirmed : DeviceInputVerdict.Unknown, result.Verdict, drift);
            Assert.AreEqual(drift == "none" ? 1 : 0, channel.RunCount, drift);
            Assert.AreEqual(1, channel.SubmitCount, drift);
        }
    }

    [TestMethod]
    public async Task FinalMaterializedScopeDriftIsUnknownAndNeverRunsAgain()
    {
        foreach (var drift in new[] { "identity", "revision", "plan", "catalog", "provider", "outputs" })
        {
            var channel = new DeviceChannel { FinalDrift = drift };
            var loader = new SurfaceLoader(channel);
            var target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
            var result = await loader.SendDeviceGestureAsync(target, new(DeviceGesture.Tap, 10, 20, 400, 800));
            Assert.AreEqual(DeviceInputVerdict.Unknown, result.Verdict, drift);
            Assert.AreEqual((1, 1), (channel.SubmitCount, channel.RunCount), drift);
        }
    }

    [TestMethod]
    public async Task KeyboardUploadUsesLeaseOnlyAndAmbiguousCommitIsNeverAbortedOrReplayed()
    {
        const string privateText = "device-private-canary-中文";
        var channel = new DeviceChannel();
        var loader = new SurfaceLoader(channel);
        var target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
        var result = await loader.SendDeviceKeyboardAsync(target, new(Text: privateText, ClipboardConsent: true));
        Assert.AreEqual(DeviceInputVerdict.Confirmed, result.Verdict);
        Assert.AreEqual(1, channel.CommitCount);
        Assert.AreEqual(0, channel.AbortCount);
        Assert.AreEqual(1, channel.RunCount);
        var submitted = channel.LastRequest!;
        Assert.AreEqual("lease-fixture-private", ((JsonString)submitted["inputs"]["keyboardArtifactLease"]).Value);
        Assert.IsTrue(((JsonString)submitted["inputs"]["inputEpochUtc"]).Value.EndsWith('Z'));
        Assert.IsFalse(submitted.ToString().Contains(privateText, StringComparison.Ordinal));
        var unknown = new DeviceChannel { CommitUnknown = true };
        loader = new SurfaceLoader(unknown);
        target = (await loader.DeviceScreenGateAsync(ScriptedDaemon.FixtureTargetId)).Target!;
        result = await loader.SendDeviceKeyboardAsync(target, new(Text: privateText, ClipboardConsent: true));
        Assert.AreEqual(DeviceInputVerdict.Failed, result.Verdict, "No input was submitted after an ambiguous local commit");
        Assert.IsFalse(result.Detail.Contains(privateText, StringComparison.Ordinal));
        Assert.AreEqual((1, 0, 0, 0), (unknown.CommitCount, unknown.AbortCount, unknown.SubmitCount, unknown.RunCount));
    }

    [TestMethod]
    public void ADispatchedFailedJobAlsoInvalidatesTheLocalPicture()
    {
        var session = new DeviceScreenSession();
        session.Select(Target);
        var generation = session.Begin()!.Value;
        session.Captured(generation, Frame());
        generation = session.Begin(input: true)!.Value;
        session.Settled(generation, DeviceInputVerdict.Failed, failedMayHaveEffect: true);
        Assert.IsFalse(session.CanInput, "Only a clean pre-dispatch refusal keeps the picture current");
    }

    /// <summary>A source-shaped fake with genuine recorded screenshot bytes; it does not reach Runtime or hardware.</summary>
    private sealed class DeviceChannel : IControlChannel, IRuntimeJobChannel
    {
        private readonly IControlChannel reads = ScriptedDaemon.Channel(ScriptedDaemon.Viewer);
        private readonly Dictionary<string, JsonObject> requests = [];
        private readonly HashSet<string> completed = [];
        public int RunCount { get; private set; }
        public int SubmitCount { get; private set; }
        public TimeSpan RunBudget { get; private set; }
        public bool LostRun { get; init; }
        public bool WrongAcceptedIdentity { get; init; }
        public string StoredRequestDrift { get; init; } = "none";
        public string? FinalDrift { get; init; }
        public bool NoInjectorProof { get; set; }
        public bool CorruptImage { get; set; }
        public bool CommitUnknown { get; init; }
        public int CommitCount { get; private set; }
        public int AbortCount { get; private set; }
        public JsonObject? LastRequest { get; private set; }
        private JsonObject? importIntent;
        private long importOffset;
        private string? identity;
        private readonly JsonObject imageRow;
        private readonly byte[] image;
        public DeviceChannel()
        {
            var recorded = (JsonObject)StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("windows", "App.Core", "Testing", "Recorded", "viewer-workspace.json")));
            imageRow = ((JsonArray)recorded["uiDump"]["artifacts"]).Items.Cast<JsonObject>().Single(r => ((JsonString)r["name"]).Value == "screenshot.png");
            image = Convert.FromBase64String(((JsonString)recorded["uiDump"]["bytes"][((JsonString)imageRow["artifactId"]).Value]).Value);
        }
        public Task<ControlResult> HealthAsync() => reads.HealthAsync();
        private static ControlResult Ok(string json) => ControlResult.Success(StrictJson.Parse(Encoding.UTF8.GetBytes(json)));
        private static string Text(JsonValue value) => ((JsonString)value).Value;
        public async Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null)
        {
            parameters ??= new JsonObject();
            if (method == "operation.list") return Ok("[" + string.Join(',', DeviceOperations.All.Select(op => $$"""{"reference":"{{op}}","availability":"available","reasons":[]}""")) + "]");
            if (method == "operation.describe")
            {
                var reference = Text(parameters["reference"]);
                var name = reference.Split('@')[0];
                var catalog = (JsonObject)StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("Catalog", "operations", name + ".v1.json")));
                return Ok($$"""{"reference":"{{reference}}","title":"Device fixture","minimumEffect":"readOnly","timeoutSeconds":{{catalog["timeoutSeconds"]}},"outputByteBudget":1,"steps":[]}""");
            }
            if (method == "target.show")
            {
                var result = await reads.RequestAsync(method, parameters);
                identity = Text(result.Value!["stablePhysicalIdentitySha256"]);
                return result;
            }
            if (method == "job.submit")
            {
                SubmitCount++;
                var id = "job-" + SubmitCount.ToString("x32", CultureInfo.InvariantCulture);
                requests.Add(id, (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(Text(parameters["requestJson"]))));
                LastRequest = requests[id];
                return Ok($$"""{"schemaVersion":"arkdeck.job-acceptance/1","jobId":"{{id}}","deduplicated":false,"newDispatchCount":0}""");
            }
            if (method == "job.show")
            {
                var id = Text(parameters["jobId"]);
                var request = requests[id];
                var operation = Text(request["operation"]["id"]) + "@1";
                var state = completed.Contains(id) ? "succeeded" : LostRun && RunCount > 0 ? "running" : "queued";
                var drift = completed.Contains(id) && FinalDrift == "outputs" ? "outputs" : StoredRequestDrift;
                var stored = new JsonObject(request.Members.Where(m => drift != "schema" || m.Key != "schemaVersion").Select(m => m.Key switch
                {
                    "requestedOutputs" when drift == "outputs" => new(m.Key, new JsonArray([new JsonString("derivedArtifacts")])),
                    "clientContext" when drift == "client" => new(m.Key, new JsonObject([new("clientName", new JsonString("another-client")), new("provenance", request["clientContext"]["provenance"])])),
                    "clientContext" when drift == "provenance" => new(m.Key, new JsonObject([new("clientName", request["clientContext"]["clientName"]), new("provenance", new JsonObject([new("arkdeck.threadId", new JsonString("another-thread"))]))])),
                    _ => m,
                }).Concat(drift == "budget" ? [new KeyValuePair<string, JsonValue>("budget", new JsonObject([new("timeoutSeconds", JsonNumber.FromInt64(900))]))] : []));
                var finalDrift = completed.Contains(id) ? FinalDrift : null;
                var proof = NoInjectorProof || !operation.StartsWith("input.", StringComparison.Ordinal) ? "jobCreated" : "verified "
                    + (operation == "input.keyboard@1" ? "inject-keyboard-input" : "inject-pointer-input") + " acknowledgement";
                return Ok($$$"""{"schemaVersion":"arkdeck.job/1","request":{{{Reordered(stored)}}},"catalogDigest":"{{{new string(finalDrift == "catalog" ? 'f' : 'c', 64)}}}","providerId":"{{{(finalDrift == "provider" ? "another-provider" : "hdc")}}}","materializedPlanDigest":"{{{new string(finalDrift == "plan" ? 'f' : 'b', 64)}}}","materializedBindingRevision":{{{(finalDrift == "revision" ? 4 : 3)}}},"materializedStableIdentitySha256":"{{{(WrongAcceptedIdentity || finalDrift == "identity" ? new string('e', 64) : identity)}}}","job":{"jobId":"{{{id}}}","targetId":"{{{ScriptedDaemon.FixtureTargetId}}}","operation":"{{{operation}}}","state":"{{{state}}}","outcomeUnknown":false,"waitingForHuman":false,"outstandingResidueCount":0},"timeline":{"kind":"inline","entries":["{{{proof}}}"]}}""");
            }
            if (method == "artifact.list")
            {
                var owner = Text(parameters["owner"]["id"]);
                var row = new JsonObject(imageRow.Members.Select(m => m.Key switch
                {
                    "owner" => new KeyValuePair<string, JsonValue>(m.Key, new JsonObject([new("kind", new JsonString("job")), new("id", new JsonString(owner))])),
                    "binding" => new(m.Key, new JsonObject([new("targetId", new JsonString(ScriptedDaemon.FixtureTargetId)), new("bindingRevision", JsonNumber.FromInt64(3)), new("stableIdentitySha256", new JsonString(identity!))])),
                    _ => m,
                }));
                return Ok($$"""{"schemaVersion":"arkdeck.cli.page/1","items":[{{row}}],"hasMore":false,"nextCursor":null,"snapshotRevision":"fixture","order":"createdAtDescArtifactIdAsc","pageKind":"snapshot"}""");
            }
            if (method == "artifact.read")
            {
                var offset = (int)((JsonNumber)parameters["offset"]).AsDouble();
                var count = Math.Min(image.Length - offset, (int)((JsonNumber)parameters["maxBytes"]).AsDouble());
                var bytes = image.AsSpan(offset, count).ToArray();
                if (CorruptImage) bytes[0] ^= 1;
                return Ok($$"""{"artifactId":{{parameters["artifactId"]}},"artifactDigest":{{imageRow["artifactDigest"]}},"offset":{{offset}},"byteCount":{{count}},"totalByteCount":{{image.Length}},"nextOffset":{{offset+count}},"eof":{{(offset+count==image.Length ? "true" : "false")}},"base64":"{{Convert.ToBase64String(bytes)}}"}""");
            }
            if (method == "artifact.import.begin") { importIntent = parameters; return ImportAnswer(committed: false); }
            if (method == "artifact.import.append")
            {
                var chunk = Convert.FromBase64String(Text(parameters["base64"]));
                Assert.AreEqual(Convert.ToHexStringLower(SHA256.HashData(chunk)), Text(parameters["sha256"]));
                Assert.AreEqual(importOffset.ToString(CultureInfo.InvariantCulture), Text(parameters["offset"]));
                importOffset += chunk.Length;
                return ImportAnswer(committed: false);
            }
            if (method == "artifact.import.commit")
            {
                CommitCount++;
                return CommitUnknown ? ControlResult.Failed(new(ControlFailureKind.OutcomeUnknown, "fixture private commit lost reply")) : ImportAnswer(committed: true);
            }
            if (method == "artifact.import.abort") { AbortCount++; return Ok("{}"); }
            return await reads.RequestAsync(method, parameters);
        }
        private ControlResult ImportAnswer(bool committed)
        {
            var metadata = new JsonObject(importIntent!.Members.Where(m => m.Key is not ("schemaVersion" or "importRequestId")));
            var receipt = committed ? $$$"""{"artifactId":"artifact-fixture-private","artifactDigest":{{{importIntent["sha256"]}}},"mediaType":"application/json","privacy":"sensitive","lease":"lease-fixture-private","validation":{"kind":"keyboard-input"}}""" : "null";
            return Ok($$"""{"schemaVersion":"arkdeck.import/1","importId":"import-fixture-private","importRequestId":{{importIntent["importRequestId"]}},"metadata":{{metadata}},"generation":"{{(committed ? "2" : "1")}}","state":"{{(committed ? "committed" : "inProgress")}}","nextOffset":"{{importOffset}}","maximumChunkBytes":"32","createdAtUtc":"2026-10-06T10:00:00Z","receipt":{{receipt}}}""");
        }
        private static string Reordered(JsonValue value) => value switch
        {
            JsonObject o => "{" + string.Join(',', o.Members.Reverse().Select(m => new JsonString(m.Key) + ":" + Reordered(m.Value))) + "}",
            JsonArray a => "[" + string.Join(',', a.Items.Select(Reordered)) + "]",
            _ => value.ToString(),
        };
        public Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget)
        {
            RunCount++; RunBudget = callBudget;
            if (LostRun) return Task.FromResult(ControlResult.Failed(new ControlFailure(ControlFailureKind.OutcomeUnknown, "fixture lost reply")));
            completed.Add(jobId);
            return Task.FromResult(Ok("{}"));
        }
    }
}
