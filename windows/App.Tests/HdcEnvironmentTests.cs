using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Overview's HDC environment and capability matrix (macOS
/// <c>HDCClientDiagnosticsDecoding</c> and <c>OverviewCapabilityProductionProvider</c>).</summary>
[TestClass]
public sealed class HdcEnvironmentTests
{
    private const string Status = """{"availability":"available","clientVersion":"3.2.0f","daemonVersion":null,"endpoint":"127.0.0.1:8710","endpointSource":"default","executableSHA256":"1111111111111111111111111111111111111111111111111111111111111111","generation":"7","ownership":"external","reasonCode":"hdc.available","schemaVersion":"arkdeck.runtime-hdc-status/1","serverHealth":"healthy","serverVersion":null}""";

    private static Loaded<JsonObject> Read(string json) => Loaded<JsonObject>.Of((JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(json)));

    private static DeviceCandidate Candidate(string state, string? target = null, long? binding = null) =>
        DeviceCandidate.ParseAll(StrictJson.Parse(Encoding.UTF8.GetBytes($$"""
            {"health":"current","observations":[{"adoptedTargetId":{{(target is null ? "null" : $"\"{target}\"")}},"authorizationState":"{{state}}","bindingRevision":{{(binding?.ToString() ?? "null")}},"candidateKey":"k-{{state}}","deviceInformation":null,"displayName":null,"displayNameGeneration":"0","observationContinuity":"generationScoped","observationId":"o-{{state}}","observedFacts":null}],"observedAtUtc":"2026-10-05T00:00:00Z","schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1"}
            """)))[0];

    private static Loaded<IReadOnlyList<DeviceCandidate>> Devices(params DeviceCandidate[] candidates) => Loaded<IReadOnlyList<DeviceCandidate>>.Of(candidates);

    [TestMethod]
    public void AStatusIsShownOnlyWhenItsIdentityIsComplete()
    {
        var hdc = HdcEnvironment.From(Read(Status), Devices(Candidate("Connected", "TGT-1", 2)));
        Assert.AreEqual(("healthy", "127.0.0.1:8710", "3.2.0f", "not currently observed", "7", "external", "default", "ready"),
            (hdc.Health, hdc.Endpoint, hdc.ClientVersion, hdc.ServerVersion, hdc.Generation, hdc.Ownership, hdc.EndpointSource, hdc.Trust));
        Assert.IsNull(hdc.LoadFailure);
        foreach (var (from, to) in new[] { ("\"127.0.0.1:8710\"", "\"10.0.0.2:8710\""), ("\"7\"", "\"07\""), ("\"external\"", "\"managed\""), ("\"default\"", "\"elsewhere\""), ("111111", "11111G") })
        {
            Assert.AreEqual("Runtime returned incomplete HDC identity or health facts. Refresh to check again.",
                HdcEnvironment.From(Read(Status.Replace(from, to, StringComparison.Ordinal)), null).LoadFailure, to);
        }
        Assert.AreEqual("Runtime reports HDC unavailable: hdc.notConfigured",
            HdcEnvironment.From(Read(Status.Replace("\"available\"", "\"unavailable\"", StringComparison.Ordinal).Replace("hdc.available", "hdc.notConfigured", StringComparison.Ordinal)), null).LoadFailure);
        var refused = HdcEnvironment.From(Loaded<JsonObject>.Not(new Unavailable("rejected", "no observer", "arkdeck runtime hdc status", null)), null);
        Assert.AreEqual("no observer", refused.LoadFailure);
        Assert.AreEqual("unavailable — no observer", refused.AuthorizationText);
    }

    [TestMethod]
    public void TheAuthorizationIsTheCurrentObservations()
    {
        string Trust(params DeviceCandidate[] c) => HdcEnvironment.From(Read(Status), Devices(c)).AuthorizationText;
        Assert.AreEqual("ready", Trust(Candidate("Unauthorized"), Candidate("Connected", "TGT-1", 2)));
        Assert.AreEqual("unauthorized — unlock and trust the device, then retry", Trust(Candidate("Unauthorized")));
        Assert.AreEqual("unavailable — HDC reported the target offline", Trust(Candidate("Offline")));
        Assert.AreEqual("unavailable — No HDC device candidate is visible", Trust());
        Assert.AreEqual("unavailable — Runtime device authorization could not be read", HdcEnvironment.From(Read(Status), null).AuthorizationText);
    }

    [TestMethod]
    public void TheMatrixDescribesOnlyTheDeviceInScope()
    {
        var operations = Loaded<JsonArray>.Of((JsonArray)StrictJson.Parse("""[{"availability":"unavailable","reasons":["lane absent"],"reference":"flash.full-restore@1"}]"""u8.ToArray()));
        var none = CapabilityMatrix.For([], null, operations, null);
        Assert.AreEqual("No adopted target is available for device capability probing", none.Failure);
        Assert.AreEqual(("rockusb-flash", "unavailable", "lane absent"), (none.Items.Single().Id, none.Items.Single().State, none.Items.Single().Evidence));

        var a = new OverviewTarget("TGT-A", 3, Candidate("Connected", "TGT-A", 3));
        var b = new OverviewTarget("TGT-B", 1, Candidate("Connected", "TGT-B", 1));
        Assert.AreEqual("2 adopted targets are available; choose which one to describe", CapabilityMatrix.For([a, b], null, operations, null).Failure);

        var probe = Read("""{"bindingRevision":3,"supportedTags":["ace","app","graphic"],"targetId":"TGT-A","tools":[{"disposition":"captureEligible","family":"hitrace-v2","rawHelpSha256":"abcdef0123456789","tool":"hitrace"},{"disposition":"probeOnly","family":"bytrace","rawHelpSha256":null,"tool":"bytrace"}]}""");
        var matrix = CapabilityMatrix.For([a, b], a, operations, probe);
        CollectionAssert.AreEqual(new[] { "hidumper", "hitrace", "bytrace", "rockusb-flash" }, matrix.Items.Select(i => i.Id).ToArray());
        Assert.AreEqual(("available", "hitrace-v2 · tags × 3 · help sha256 abcdef012345…"), (matrix.Items[1].State, matrix.Items[1].Evidence));
        Assert.AreEqual(("limited", "bytrace · probe-only"), (matrix.Items[2].State, matrix.Items[2].Evidence));
        Assert.AreEqual("unknown", matrix.Items[0].State, "not probed until asked");
        Assert.AreEqual("available", matrix.WithWindowInventory("job-1", "succeeded", false).Items[0].State);
        Assert.AreEqual("unknown", matrix.WithWindowInventory("job-1", "succeeded", true).Items[0].State);

        var other = CapabilityMatrix.For([a, b], b, operations, probe);
        Assert.IsTrue(other.Items.Where(i => i.Id is "hitrace" or "bytrace").All(i => i.State == "unknown" && i.Evidence == "Runtime returned mismatched Trace facts"), "another Target's facts");
    }

    [TestMethod]
    public async Task OverviewReadsTheEnvironmentOfTheDeviceInScope()
    {
        var overview = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs)).OverviewAsync();
        Assert.AreEqual(("healthy", "arkDeckManaged", "ready"), (overview.Hdc!.Health, overview.Hdc.Ownership, overview.Hdc.Trust));
        Assert.AreEqual((ScriptedDaemon.FixtureTargetId, (long?)3), (overview.Capabilities!.TargetId, overview.Capabilities.BindingRevision));
        Assert.AreEqual(ScriptedDaemon.TraceProbeRefusal, overview.Capabilities.Items.Single(i => i.Id == "hitrace").Evidence);

        var foundation = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Foundation)).OverviewAsync();
        Assert.IsNotNull(foundation.Hdc!.LoadFailure);
        Assert.IsNull(foundation.Capabilities!.TargetId);
    }
}
