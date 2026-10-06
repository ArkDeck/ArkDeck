using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

[TestClass]
public sealed class DiagnosticChannelTests
{
    [TestMethod]
    public async Task FixedControlsUseOneHealthFirstConnectionAndExactTypedParameters()
    {
        var peers = new List<Peer>();
        var channel = new StreamChannel(() => { var p = new Peer(); peers.Add(p); return p; }, TimeSpan.FromSeconds(10));
        Assert.IsTrue((await channel.StatusAsync("job-diagnostic-fixture")).Succeeded);
        Assert.IsTrue((await channel.MarkAsync("job-diagnostic-fixture", "mark-1")).Succeeded);
        Assert.IsTrue((await channel.StopAsync("job-diagnostic-fixture")).Succeeded);
        Assert.IsTrue((await channel.CancelPreparationAsync("job-diagnostic-fixture")).Succeeded);
        CollectionAssert.AreEqual(new[] { "diagnostic.session.status", "diagnostic.session.mark", "diagnostic.session.stop", "job.cancel" },
            peers.Select(p => ((JsonString)p.Frames[1]["method"]).Value).ToArray());
        foreach (var peer in peers)
        {
            Assert.AreEqual(2, peer.Frames.Count);
            Assert.AreEqual("health", ((JsonString)peer.Frames[0]["method"]).Value);
            Assert.AreEqual("job-diagnostic-fixture", ((JsonString)peer.Frames[1]["params"]["jobId"]).Value);
            Assert.IsTrue(peer.Closed);
        }
        var mark = (JsonObject)peers[1].Frames[1]["params"];
        CollectionAssert.AreEquivalent(new[] { "jobId", "markerId" }, mark.Keys.ToArray());
        Assert.AreEqual("mark-1", ((JsonString)mark["markerId"]).Value);
        Assert.IsFalse((await channel.MarkAsync("job-diagnostic-fixture", "")).Succeeded);
        Assert.IsFalse((await channel.StopAsync("")).Succeeded);
        Assert.AreEqual(4, peers.Count, "Invalid local identities open no connection");
    }

    [TestMethod]
    public async Task LostFixedStopReplyIsUnknownWithNoSecondRequestOrConnection()
    {
        var peer = new Peer { LoseBusinessReply = true };
        var connections = 0;
        var channel = new StreamChannel(() => { connections++; return peer; }, TimeSpan.FromSeconds(10));
        var result = await channel.StopAsync("job-diagnostic-fixture");
        Assert.AreEqual(ControlFailureKind.OutcomeUnknown, result.Failure!.Kind);
        Assert.AreEqual((1, 2), (connections, peer.Frames.Count));
        Assert.IsTrue(peer.Closed);
    }

    private sealed class Peer : Stream
    {
        private readonly MemoryStream incoming = new();
        private readonly Queue<byte> outgoing = [];
        private int consumed;
        public List<JsonObject> Frames { get; } = [];
        public bool LoseBusinessReply { get; init; }
        public bool Closed { get; private set; }
        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default)
        {
            incoming.Write(buffer.Span);
            var all = incoming.ToArray();
            var end = Array.IndexOf(all, (byte)'\n', consumed);
            if (end < 0) return ValueTask.CompletedTask;
            var frame = (JsonObject)StrictJson.Parse(all.AsSpan(consumed, end-consumed));
            consumed = end+1; Frames.Add(frame);
            var method = ((JsonString)frame["method"]).Value;
            if (method != "health" && LoseBusinessReply) return ValueTask.CompletedTask;
            JsonValue result = method == "health" ? new JsonObject([
                new("contractIdentity", new JsonString(ControlContract.ContractIdentity)), new("protocolVersion", new JsonString(ControlContract.ProtocolVersion)),
                new("catalogDigest", new JsonString(new string('a',64))), new("providers", new JsonArray([])),
                new("publishedMethods", new JsonArray(ControlContract.Methods.Select(m => (JsonValue)new JsonString(m)))), new("status", new JsonString("ok"))])
                : StrictJson.Parse(Encoding.UTF8.GetBytes(File.ReadLines(RepoPaths.At("Packages","ArkDeckKit","Tests","ArkDeckContractTests","Fixtures","ControlFrames",method+".jsonl")).First()))["result"];
            foreach (var b in Wire.EncodeFrame(new JsonObject([new("id",frame["id"]),new("ok",JsonBool.True),new("result",result)]),ControlContract.MaxResponseBytes)) outgoing.Enqueue(b);
            return ValueTask.CompletedTask;
        }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            var count = Math.Min(buffer.Length,outgoing.Count);
            for (var i=0;i<count;i++) buffer.Span[i]=outgoing.Dequeue();
            return ValueTask.FromResult(count);
        }
        protected override void Dispose(bool disposing) { Closed=true; incoming.Dispose(); base.Dispose(disposing); }
        public override int Read(byte[] buffer,int offset,int count) => ReadAsync(buffer.AsMemory(offset,count)).Result;
        public override void Write(byte[] buffer,int offset,int count) => WriteAsync(buffer.AsMemory(offset,count)).GetAwaiter().GetResult();
        public override void Flush() { }
        public override long Seek(long offset,SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
