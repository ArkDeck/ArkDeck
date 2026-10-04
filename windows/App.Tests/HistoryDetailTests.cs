using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>History's detail sections (macOS <c>RuntimeHistoryView</c> summary, timeline,
/// correlation, parameters with the Trace diff, recovery, and <c>decodeTraceEvidence</c>).</summary>
[TestClass]
public sealed class HistoryDetailTests
{
    private static string Probe(string target, long binding, Func<string, string> row) =>
        $$"""{"bindingRevision":{{binding}},"parameters":[{{string.Join(",", TraceOperations.ParameterNames.Select(row))}}],"supportedTags":["ace"],"targetId":"{{target}}"}""";

    private static JsonObject Evidence(string before, string after) =>
        (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes($$"""{"traceProbeAfter":{{after}},"traceProbeBefore":{{before}}}"""));

    [TestMethod]
    public void TheTraceParametersAreComparedNotJudged()
    {
        var before = Probe("TGT-1", 3, n => n.EndsWith("layout.enabled", StringComparison.Ordinal)
            ? $$"""{"name":"{{n}}","state":"value","value":"0"}"""
            : n.EndsWith("debug.enabled", StringComparison.Ordinal) && n.StartsWith("persist.ace.debug", StringComparison.Ordinal)
                ? $$"""{"name":"{{n}}","state":"unreadable"}"""
                : $$"""{"name":"{{n}}","state":"missing"}""");
        var after = Probe("TGT-1", 3, n => n.EndsWith("layout.enabled", StringComparison.Ordinal)
            ? $$"""{"name":"{{n}}","state":"value","value":"1"}"""
            : $$"""{"name":"{{n}}","state":"missing"}""");
        var changes = TraceParameterChange.FromEvidence(Evidence(before, after));
        CollectionAssert.AreEqual(TraceOperations.ParameterNames.ToArray(), changes.Select(c => c.Name).ToArray());
        Assert.AreEqual("changed", changes.Single(c => c.Name == "persist.ace.trace.layout.enabled").Comparison);
        Assert.AreEqual("unverified", changes.Single(c => c.Name == "persist.ace.debug.enabled").Comparison);
        Assert.AreEqual("unchanged", changes.Single(c => c.Name == "persist.ace.trace.build.enabled").Comparison);

        Assert.AreEqual(0, TraceParameterChange.FromEvidence(Evidence(before, after.Replace("TGT-1", "TGT-2", StringComparison.Ordinal))).Count, "another Target");
        Assert.AreEqual(0, TraceParameterChange.FromEvidence(Evidence(before, Probe("TGT-1", 4, n => $$"""{"name":"{{n}}","state":"missing"}"""))).Count, "another binding");
        Assert.AreEqual(0, TraceParameterChange.FromEvidence(Evidence(before, after.Replace("persist.rosen.animationtrace.enabled", "persist.other", StringComparison.Ordinal))).Count, "not the nine");
    }

    [TestMethod]
    public async Task TheDetailCarriesTheJournalAndTheTypedInputs()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var detail = await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId);
        Assert.IsNull(detail.Shown!.Unavailable, detail.Shown.Unavailable?.Detail);
        Assert.IsTrue(detail.Shown.Value!.Terminal.Timeline.Count > 0);
        Assert.AreEqual("session-" + ScriptedDaemon.TraceJobId, ((JsonString)detail.Shown.Value.Status["sessionId"]).Value);
        Assert.AreEqual(0, detail.Evidence.Value!.DisplayParameters.Count, "the scripted evidence reports {}");

        var typed = new JobEvidenceFacts("verified", "hdc", "d", 3, null, null, "succeeded", "execute", null, null, null, [], [],
            Parameters: (JsonObject)StrictJson.Parse("""{"b":true,"a":["x"],"c":null,"d":5}"""u8.ToArray()));
        CollectionAssert.AreEqual(new[] { "a=[\"x\"]", "b=true", "c=null", "d=5" }, typed.DisplayParameters.Select(p => $"{p.Name}={p.Value}").ToArray());
    }
}
