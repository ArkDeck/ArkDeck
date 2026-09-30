using System.IO.Pipes;
using System.Security.Principal;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit.Tests;

/// <summary>
/// XPA-AC-6 on the client side, against fake pipe servers this test process creates: the
/// client refuses before writing anything, and the fake server observes zero bytes.
/// </summary>
[TestClass]
public sealed class PipeAuthenticationTests
{
    private static string NewEndpoint() => $@"\\.\pipe\arkdeck-clientkit-test-{Guid.NewGuid():N}";

    /// <summary>A same-account impostor: a pipe server in this test process. It counts the
    /// bytes it receives until the client goes away.</summary>
    private sealed class FakeServer : IAsyncDisposable
    {
        private readonly NamedPipeServerStream _server;
        private readonly Task<int> _received;

        public FakeServer(string endpoint)
        {
            var name = endpoint[@"\\.\pipe\".Length..];
            _server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            _received = CountAsync();
        }

        private async Task<int> CountAsync()
        {
            await _server.WaitForConnectionAsync();
            var total = 0;
            var buffer = new byte[4096];
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (true)
            {
                int count;
                try
                {
                    count = await _server.ReadAsync(buffer, timeout.Token);
                }
                catch (IOException)
                {
                    break;
                }
                if (count == 0) break;
                total += count;
            }
            return total;
        }

        public Task<int> BytesReceived => _received;

        public async ValueTask DisposeAsync()
        {
            await _server.DisposeAsync();
        }
    }

    private static DaemonIdentity OwnImage(string? pin = null) => new(Environment.ProcessPath!, pin);

    [TestMethod]
    public async Task APipeOwnedByAnotherSidIsRefusedWithZeroFrames()
    {
        var endpoint = NewEndpoint();
        await using var server = new FakeServer(endpoint);
        // A non-elevated account cannot create a pipe owned by another SID, so the refusal is
        // exercised by expecting another owner than the one the pipe has (this account).
        var other = new SecurityIdentifier("S-1-5-21-1-2-3-1001");
        var error = Assert.ThrowsExactly<ServerAuthenticationException>(() => PipeConnector.Connect(new PipeEndpoint(endpoint), OwnImage(), other));
        Assert.AreEqual(DaemonUnavailableReason.OwnerMismatch, error.Reason);
        StringAssert.Contains(error.Message, "zero frames sent");
        Assert.AreEqual(0, await server.BytesReceived);
    }

    [TestMethod]
    public async Task ASameAccountImpostorWithAnotherImageIsRefusedWithZeroFrames()
    {
        var endpoint = NewEndpoint();
        await using var server = new FakeServer(endpoint);
        var session = new ControlSession(new PipeEndpoint(endpoint),
            new DaemonIdentity(Path.Combine(Environment.SystemDirectory, "cmd.exe"), new string('a', 64)), TimeSpan.FromSeconds(10));
        var result = await session.HealthAsync();
        Assert.IsFalse(result.Succeeded);
        Assert.IsNull(result.Value, "no data from an impostor");
        Assert.AreEqual(ControlFailureKind.DaemonUnavailable, result.Failure!.Kind);
        Assert.AreEqual(DaemonUnavailableReason.InstanceMismatch, result.Failure.Reason);
        StringAssert.Contains(result.Failure.Message, "differs from installed daemon");
        var banner = result.Failure.Banner!;
        Assert.AreEqual(RecoveryBanner.BannerCode, banner.Code);
        StringAssert.Contains(banner.Message, "not the installed ArkDeck Runtime");
        Assert.AreEqual(0, await server.BytesReceived);
    }

    [TestMethod]
    public async Task TheRightImageWithoutItsSignerOrPackageIsRefusedWithZeroFrames()
    {
        foreach (var identity in new[] { OwnImage(), OwnImage(new string('0', 64)), OwnImage("NOT-A-PIN"), new DaemonIdentity(Environment.ProcessPath!, PackageFamily: "ArkDeck_0000000000000") })
        {
            var endpoint = NewEndpoint();
            await using var server = new FakeServer(endpoint);
            var error = Assert.ThrowsExactly<ServerAuthenticationException>(() => PipeConnector.Connect(new PipeEndpoint(endpoint), identity));
            Assert.AreEqual(DaemonUnavailableReason.InstanceMismatch, error.Reason, identity.ToString());
            StringAssert.Contains(error.Message, "signing identity");
            Assert.AreEqual(0, await server.BytesReceived);
        }
    }

    [TestMethod]
    public async Task NoServerIsDaemonUnavailable()
    {
        var session = new ControlSession(new PipeEndpoint(NewEndpoint()), OwnImage(), TimeSpan.FromSeconds(5));
        var result = await session.RequestAsync("doctor");
        Assert.AreEqual(DaemonUnavailableReason.EndpointUnavailable, result.Failure!.Reason);
        Assert.IsTrue(result.Failure.ShowsRecoveryBanner);
        StringAssert.Contains(result.Failure.Banner!.Remedy, "arkdeck-agentd");
    }

    [TestMethod]
    public void OnlyLocalArkDeckPipeNamesAreAccepted()
    {
        foreach (var name in new[] { @"\\.\pipe\other", @"\\server\pipe\arkdeck-x", @"\\.\pipe\arkdeck-a\b", @"\\.\pipe\arkdeck-a:b", @"\\.\pipe\arkdeck-a/b", @"\\.\pipe\arkdeck-" + new string('x', 240) })
        {
            Assert.AreEqual(DaemonUnavailableReason.EndpointInvalid, Assert.ThrowsExactly<ServerAuthenticationException>(() => new PipeEndpoint(name)).Reason, name);
        }
        StringAssert.StartsWith(PipeEndpoint.Default().Name, @"\\.\pipe\arkdeck-agentd-S-1-5-5-");
    }
}
