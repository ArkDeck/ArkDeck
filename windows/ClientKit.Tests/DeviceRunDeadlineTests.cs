using System.Diagnostics;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit.Tests;

[TestClass]
public sealed class DeviceRunDeadlineTests
{
    [TestMethod]
    public async Task ARunCanOutlastTheOrdinaryDeadlineOnOneConnection()
    {
        var now = Stopwatch.GetTimestamp();
        var peer = new ScriptedPeer((_, frame) =>
        {
            if (((JsonString)frame["method"]).Value == "health") return ScriptedPeer.Success(frame, Corpus.HealthResult());
            now += 11 * Stopwatch.Frequency;
            return ScriptedPeer.Success(frame, Corpus.RecordedResult("job.run"));
        });
        // The Device descriptor chooses this bounded deadline. Fake time advances beyond the
        // ordinary ten seconds while the original client stays on its sole authenticated stream.
        using var client = new ControlClient(peer, TimeSpan.FromSeconds(910), () => now);
        await client.RequestAsync("device-run", "job.run", new JsonObject([new("jobId", new JsonString("job-fixture"))]));
        CollectionAssert.AreEqual(new[] { "health", "job.run" }, peer.Frames.Select(f => ((JsonString)f["method"]).Value).ToArray());
    }

    [TestMethod]
    public async Task ARunPastItsOwnDeadlineIsUnknownAndNeverReconnectedOrReplayed()
    {
        var now = Stopwatch.GetTimestamp();
        var peer = new ScriptedPeer((_, frame) =>
        {
            if (((JsonString)frame["method"]).Value == "health") return ScriptedPeer.Success(frame, Corpus.HealthResult());
            now += 911 * Stopwatch.Frequency;
            return ScriptedReply.Hang;
        });
        using var client = new ControlClient(peer, TimeSpan.FromSeconds(910), () => now);
        var parameters = new JsonObject([new("jobId", new JsonString("job-fixture"))]);
        var lost = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("device-run", "job.run", parameters));
        Assert.AreEqual(ControlFailureKind.OutcomeUnknown, lost.Failure.Kind);
        var replay = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("device-run", "job.run", parameters));
        Assert.AreEqual(ControlFailureKind.ConnectionUnusable, replay.Failure.Kind);
        Assert.AreEqual(2, peer.Frames.Count);
    }

    [TestMethod]
    public async Task ALongDeadlineDoesNotBypassHealthIdentityOrLocalBounds()
    {
        var peer = new ScriptedPeer((_, frame) => ScriptedPeer.Success(frame, Corpus.HealthResult(new string('0', 64))));
        using var client = new ControlClient(peer, TimeSpan.FromSeconds(910));
        var refused = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("device-run", "job.run", new JsonObject([new("jobId", new JsonString("job-fixture"))])));
        Assert.AreEqual(DaemonUnavailableReason.ContractMismatch, refused.Failure.Reason);
        Assert.AreEqual(1, peer.Frames.Count);
        // Invalid caller values fail before even trying to open the missing endpoint.
        var session = new ControlSession(null!, null!, TimeSpan.FromSeconds(10));
        foreach (var seconds in new[] { 0, 10, 911 })
        {
            var bad = await session.RunJobOnceAsync("job-fixture", TimeSpan.FromSeconds(seconds));
            Assert.AreEqual(ControlFailureKind.InvalidRequest, bad.Failure!.Kind);
        }
    }

    [TestMethod]
    [DataRow("diagnostic.session.status")]
    [DataRow("diagnostic.session.mark")]
    [DataRow("diagnostic.session.stop")]
    [DataRow("job.cancel")]
    public async Task FixedDiagnosticDeadlineHasOneExchangeAndRemainsBounded(string method)
    {
        foreach (var elapsed in new[] {11,121})
        {
            var now=Stopwatch.GetTimestamp();
            var peer=new ScriptedPeer((_,frame) =>
            {
                if (frame["method"] is JsonString { Value: "health" }) return ScriptedPeer.Success(frame,Corpus.HealthResult());
                now+=elapsed*Stopwatch.Frequency;
                return ScriptedPeer.Success(frame,Corpus.RecordedResult(method));
            });
            using var client=new ControlClient(peer,TimeSpan.FromSeconds(120),()=>now);
            var parameters=new JsonObject(method=="diagnostic.session.mark"
                ? [new("jobId",new JsonString("job-diagnostic-fixture")),new("markerId",new JsonString("mark-1"))]
                : [new("jobId",new JsonString("job-diagnostic-fixture"))]);
            if (elapsed==11) await client.RequestAsync("fixed-control",method,parameters);
            else
            {
                var lost=await Assert.ThrowsExactlyAsync<ControlClientException>(()=>client.RequestAsync("fixed-control",method,parameters));
                Assert.AreEqual(ControlFailureKind.OutcomeUnknown,lost.Failure.Kind);
                var replay=await Assert.ThrowsExactlyAsync<ControlClientException>(()=>client.RequestAsync("fixed-control",method,parameters));
                Assert.AreEqual(ControlFailureKind.ConnectionUnusable,replay.Failure.Kind);
            }
            CollectionAssert.AreEqual(new[] {"health",method},peer.Frames.Select(f=>((JsonString)f["method"]).Value).ToArray());
        }
    }
}
