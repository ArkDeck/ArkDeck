using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

[TestClass]
public sealed class FlashMaintenanceTests
{
    private static JsonValue Document(string outcome, int? reportedExit = null)
    {
        var hash = new string('a', 64);
        return StrictJson.Parse(JsonSerializer.SerializeToUtf8Bytes(new {
            schema = "arkforge.flash-verification/v1", source_job_id = "JOB-1", source_plan_id = "PLAN-1", source_plan_sha256 = hash,
            exit_code = reportedExit ?? (outcome == "verified" ? 0 : outcome == "typedSkip" ? 9 : 7),
            outcome = outcome == "typedSkip" ? "partial" : outcome,
            verified = outcome == "verified" ? 1 : 0, skipped = outcome == "typedSkip" ? 1 : 0, failed = outcome == "failed" ? 1 : 0,
            targets = new[] { new { target = "userdata", range_start = 4096, range_length = 4096, expected_sha256 = hash,
                observed_sha256 = outcome == "verified" ? hash : null, outcome,
                verification_strength = outcome == "verified" ? "fullHash" : null,
                reason = outcome == "verified" ? null : outcome == "typedSkip" ? "mounted-writable-after-boot" : "content-mismatch" } }
        }));
    }
    [TestMethod]
    public async Task InvalidSourceOrBudgetNeverReachesTheRuntime()
    {
        var loader = new SurfaceLoader(new NoCalls());
        var target = new TargetSummary("target-1", "Board", "1", 1, "2026-10-17T00:00:00Z", "test");
        foreach (var (source, budget) in new[] { ("../source", 1000), ("source-1", 0) })
        {
            var result = await loader.FlashMaintenanceAsync(source, target, null, budget);
            Assert.IsNull(result.Status);
            StringAssert.Contains(result.Failure!, "exit 2");
        }
    }

    private sealed class NoCalls : IControlChannel
    {
        public Task<ControlResult> HealthAsync() => throw new AssertFailedException("Invalid input reached health");
        public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) => throw new AssertFailedException("Invalid input reached " + method);
    }

    [TestMethod]
    public void MatchSkipAndFailureRemainDistinct()
    {
        foreach (var (outcome, code) in new[] { ("verified", 0), ("typedSkip", 9), ("failed", 7) })
        {
            var result = FlashMaintenanceResult.Parse(Document(outcome));
            Assert.AreEqual(code, result.ExitCode);
            Assert.AreEqual(4096L, result.Verification!.Targets.Single().RangeLength);
        }
    }
    [TestMethod]
    public void InconsistentCountsAndUnsupportedSuccessAreRejected()
    {
        Assert.ThrowsExactly<ContractException>(() => FlashMaintenanceResult.Parse(Document("typedSkip", 0)));
        var missing = StrictJson.Parse(Encoding.UTF8.GetBytes("""
            {"schema":"arkforge.boot-loop-restoration/v1","source_job_id":"JOB-1","restoration_job_id":"JOB-2","exit_code":0,"outcome":"verified","outcome_unknown":false}
            """));
        Assert.ThrowsExactly<ContractException>(() => FlashMaintenanceResult.Parse(missing));
    }
    [TestMethod]
    public void UnknownRestorationIsStoppedAndNeverSuccess()
    {
        var value = StrictJson.Parse(Encoding.UTF8.GetBytes("""
            {"schema":"arkforge.boot-loop-restoration/v1","source_job_id":"JOB-1","exit_code":1,"outcome":"stopped","outcome_unknown":true,"reason":"identity changed"}
            """));
        var result = FlashMaintenanceResult.Parse(value);
        Assert.AreEqual(1, result.ExitCode);
        Assert.IsTrue(result.OutcomeUnknown);
        Assert.IsNull(result.Verification);
    }
}
