using System.Diagnostics;
using System.Text;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit.Tests;

/// <summary>The connection semantics of the Rust <c>arkdeck-client</c> (its <c>bounded</c>
/// and <c>no_replay</c> tests), against a scripted peer that records every byte sent.</summary>
[TestClass]
public sealed class ClientTests
{
    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(10);

    private static ScriptedPeer HealthyPeer(Func<int, JsonObject, ScriptedReply>? business = null) => new((index, frame) =>
        ((JsonString)frame["method"]).Value == "health"
            ? ScriptedPeer.Success(frame, Corpus.HealthResult())
            : business?.Invoke(index, frame) ?? ScriptedPeer.Success(frame, Corpus.RecordedResult(((JsonString)frame["method"]).Value)));

    [TestMethod]
    public async Task HealthIsVerifiedFirstOnTheSameConnectionAndOnlyOnce()
    {
        var peer = HealthyPeer();
        using var client = new ControlClient(peer, Budget);
        var doctor = await client.RequestAsync("r1", "doctor", new JsonObject([new("deep", JsonBool.False)]));
        TypedMethods.ParseDoctorResult(doctor);
        await client.RequestAsync("r2", "operation.list");
        var identity = ControlContract.ContractIdentity;
        var expected =
            $"{{\"protocolVersion\":\"1.0.0\",\"contractIdentity\":\"{identity}\",\"id\":\"health\",\"method\":\"health\"}}\n" +
            $"{{\"protocolVersion\":\"1.0.0\",\"contractIdentity\":\"{identity}\",\"id\":\"r1\",\"method\":\"doctor\",\"params\":{{\"deep\":false}}}}\n" +
            $"{{\"protocolVersion\":\"1.0.0\",\"contractIdentity\":\"{identity}\",\"id\":\"r2\",\"method\":\"operation.list\"}}\n";
        Assert.AreEqual(expected, Encoding.UTF8.GetString(peer.Received));
    }

    [TestMethod]
    public async Task HealthItselfIsTheOnlyExchangeWhenHealthIsRead()
    {
        var peer = HealthyPeer();
        using var client = new ControlClient(peer, Budget);
        TypedMethods.ParseHealthResult(await client.HealthAsync("h"));
        Assert.AreEqual(1, peer.Frames.Count);
        await client.RequestAsync("r", "doctor");
        Assert.AreEqual(2, peer.Frames.Count, "a verified connection does not repeat health");
    }

    [TestMethod]
    public async Task AMismatchedHealthSendsZeroBusinessFramesAndShowsTheBanner()
    {
        var peer = new ScriptedPeer((_, frame) => ScriptedPeer.Success(frame, Corpus.HealthResult(new string('0', 64))));
        using var client = new ControlClient(peer, Budget);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor"));
        Assert.AreEqual(ControlFailureKind.DaemonUnavailable, error.Failure.Kind);
        Assert.AreEqual(DaemonUnavailableReason.ContractMismatch, error.Failure.Reason);
        Assert.AreEqual(RecoveryBanner.BannerCode, error.Failure.Banner!.Code);
        Assert.AreEqual(1, peer.Frames.Count, "only the health frame was sent");
        var again = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor"));
        Assert.AreEqual(ControlFailureKind.ConnectionUnusable, again.Failure.Kind);
        Assert.AreEqual(1, peer.Frames.Count);
    }

    [TestMethod]
    public async Task AFailedHealthReplyIsAContractMismatch()
    {
        var peer = new ScriptedPeer((_, frame) => ScriptedPeer.Failure(frame, "internalError", "down"));
        using var client = new ControlClient(peer, Budget);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.HealthAsync());
        Assert.AreEqual(DaemonUnavailableReason.ContractMismatch, error.Failure.Reason);
    }

    [TestMethod]
    public async Task ALostReplyIsNeverReplayed()
    {
        var peer = HealthyPeer((_, _) => ScriptedReply.Close);
        using var client = new ControlClient(peer, Budget);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "job.status", new JsonObject([new("jobId", new JsonString("JOB-1"))])));
        Assert.AreEqual(ControlFailureKind.OutcomeUnknown, error.Failure.Kind);
        Assert.IsFalse(error.Failure.ShowsRecoveryBanner);
        var again = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r2", "job.status", new JsonObject([new("jobId", new JsonString("JOB-1"))])));
        Assert.AreEqual(ControlFailureKind.ConnectionUnusable, again.Failure.Kind);
        Assert.AreEqual(2, peer.Frames.Count, "health and the one business frame; nothing replayed");
    }

    [TestMethod]
    public async Task AMalformedReplyLeavesTheOutcomeUnknown()
    {
        var peer = HealthyPeer((_, _) => ScriptedReply.Of("{\"id\":\"other\",\"ok\":true,\"result\":{}}\n"));
        using var client = new ControlClient(peer, Budget);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor"));
        Assert.AreEqual(ControlFailureKind.OutcomeUnknown, error.Failure.Kind);
    }

    [TestMethod]
    public async Task AWireErrorKeepsTheConnectionUsable()
    {
        var calls = 0;
        var peer = HealthyPeer((_, frame) => calls++ == 0
            ? ScriptedPeer.Failure(frame, "invalidParams", "bad deep")
            : ScriptedPeer.Success(frame, Corpus.RecordedResult("doctor")));
        using var client = new ControlClient(peer, Budget);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor", new JsonObject([new("deep", new JsonString("x"))])));
        Assert.AreEqual(ControlFailureKind.Remote, error.Failure.Kind);
        Assert.AreEqual("invalidParams", error.Failure.Remote!.Code);
        await client.RequestAsync("r2", "doctor");
        Assert.AreEqual(3, peer.Frames.Count);
    }

    [TestMethod]
    public async Task AMalformedLocalRequestSendsNoByteAtAll()
    {
        var peer = HealthyPeer();
        using var client = new ControlClient(peer, Budget);
        foreach (var (id, method, parameters) in new (string, string, JsonObject?)[]
                 {
                     ("r", "no.such.method", null),
                     ("bad\u0001id", "doctor", null),
                     ("r", "doctor", new JsonObject([new("deep", new JsonString(new string('x', ControlContract.MaxRequestBytes)))])),
                 })
        {
            var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync(id, method, parameters));
            Assert.AreEqual(ControlFailureKind.InvalidRequest, error.Failure.Kind);
        }
        Assert.AreEqual(0, peer.Received.Length);
        await client.RequestAsync("r", "doctor");
        Assert.AreEqual(2, peer.Frames.Count, "a local refusal does not make the connection unusable");
    }

    [TestMethod]
    public async Task TheBudgetBoundsTheWaitAndALateReplyCannotSucceed()
    {
        var peer = new ScriptedPeer((_, _) => ScriptedReply.Hang);
        using var client = new ControlClient(peer, TimeSpan.FromMilliseconds(300));
        var started = DateTime.UtcNow;
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor"));
        Assert.IsTrue(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
        Assert.AreEqual(ControlFailureKind.DaemonUnavailable, error.Failure.Kind);
        Assert.AreEqual(DaemonUnavailableReason.DeadlineExceeded, error.Failure.Reason);
        Assert.AreEqual(1, peer.Frames.Count, "no business frame after a health that never answered");
    }

    [TestMethod]
    public async Task ABusinessRequestPastTheBudgetIsOutcomeUnknown()
    {
        // The budget runs out on the client's own clock only once the peer has read the business
        // frame, so the health exchange can never be the step that times out on a loaded runner.
        var now = Stopwatch.GetTimestamp();
        var budget = TimeSpan.FromMilliseconds(300);
        var peer = HealthyPeer((_, _) =>
        {
            now += (long)(budget.TotalSeconds * Stopwatch.Frequency) + 1;
            return ScriptedReply.Hang;
        });
        using var client = new ControlClient(peer, budget, () => now);
        var error = await Assert.ThrowsExactlyAsync<ControlClientException>(() => client.RequestAsync("r", "doctor"));
        Assert.AreEqual(ControlFailureKind.OutcomeUnknown, error.Failure.Kind);
        Assert.AreEqual(2, peer.Frames.Count);
    }
}
