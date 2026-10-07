using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>The new interactive fake-provider corpus is inspected without a transport or device.</summary>
[TestClass]
public sealed class DiagnosticCaptureReaderTests
{
    private static JsonObject Fixture() => (JsonObject)StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "diagnostic-session", "interactive.json")));
    private static string Text(JsonValue value) => ((JsonString)value).Value;
    private static JsonObject With(JsonObject o, string key, JsonValue value) => new(o.Members.Select(p => p.Key == key ? new KeyValuePair<string, JsonValue>(key, value) : p));
    private static DiagnosticSessionOfflineInput Input(JsonObject fixture, Func<JsonObject, JsonObject>? markers = null)
    {
        var inventory = ((JsonArray)fixture["inventory"]).Items.Cast<JsonObject>().Select(row => DiagnosticArtifactMetadata.Create(
            Text(row["artifactId"]), Text(row["name"]), Text(row["mediaType"]), Text(row["privacy"]), Text(row["status"]), null,
            Text(row["sourceOperation"]), (long)((JsonNumber)row["byteCount"]).AsDouble(), Text(row["artifactDigest"]))).ToList();
        var documents = new Dictionary<string, DiagnosticOfflineArtifact>(StringComparer.Ordinal);
        foreach (var name in new[] { "artifact-index.json", "capture-summary.json", "markers.json" })
        {
            var bytes = Encoding.UTF8.GetBytes(Text(fixture["documents"][name]));
            var index = inventory.FindIndex(m => m.Name == name);
            var metadata = inventory[index];
            if (name == "markers.json" && markers is not null)
            {
                bytes = Encoding.UTF8.GetBytes(markers((JsonObject)StrictJson.Parse(bytes)).ToString());
                metadata = DiagnosticArtifactMetadata.Create(metadata.ArtifactId, name, metadata.MediaType, metadata.Privacy, metadata.Status,
                    null, metadata.SourceOperation, bytes.Length, Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes)));
                inventory[index] = metadata;
            }
            documents.Add(name, DiagnosticOfflineArtifact.Bind(metadata, bytes));
        }
        return new(Text(fixture["jobId"]), Text(fixture["operationReference"]), (JsonObject)fixture["typedParameters"], inventory, documents);
    }

    [TestMethod]
    public void NewPublishedRolesAndVerifiedOptionalClockRemainCannotAlign()
    {
        var inspection = DiagnosticSessionOfflineInspector.Inspect(Input(Fixture()));
        Assert.AreEqual(DiagnosticCaptureProvider.Operation, inspection.OperationReference);
        Assert.AreEqual(7, inspection.Inventory.Count);
        Assert.AreEqual(0, inspection.Reading.MissingProducts.Count);
        Assert.AreEqual(1, inspection.Reading.Marks.Count);
        Assert.IsInstanceOfType<DiagnosticAlignment.CannotAlign>(inspection.Reading.Alignment);
        Assert.AreEqual("unvalidated", inspection.ClockObservation!.Status);
        Assert.AreEqual(8L, inspection.ClockObservation.WindowMilliseconds);
        Assert.AreEqual(inspection.ClockObservation, inspection.Reading.ClockObservation);
        foreach (var name in new[] { "trace.htrace", "hilog.txt" }) Assert.AreEqual("raw", DiagnosticArtifactRoles.Of(DiagnosticCaptureProvider.Operation, name));
        foreach (var name in new[] { "artifact-index.json", "capture-summary.json", "diagnostic-session.json", "markers.json" })
            Assert.AreEqual("derived", DiagnosticArtifactRoles.Of(DiagnosticCaptureProvider.Operation, name));
        Assert.AreEqual("log", DiagnosticArtifactRoles.Of(DiagnosticCaptureProvider.Operation, "capture.log"));
        Assert.IsNull(DiagnosticArtifactRoles.Of("capture.diagnostics@1", "diagnostic-session.json"));
        Assert.IsNull(DiagnosticArtifactRoles.Of("unpublished@1", "markers.json"));
    }

    [TestMethod]
    public void OptionalClockAbsenceIsHonestAndEveryInvalidClosedObservationRefuses()
    {
        var fixture = Fixture();
        var absent = DiagnosticSessionOfflineInspector.Inspect(Input(fixture, o => new(o.Members.Where(p => p.Key != "clockObservation"))));
        Assert.IsNull(absent.ClockObservation);
        Assert.IsInstanceOfType<DiagnosticAlignment.CannotAlign>(absent.Reading.Alignment);
        foreach (var drift in new[] { "job", "anchor", "unknown", "missing", "null", "nanos", "float", "fraction", "impossible-date", "status" })
        {
            var input = Input(fixture, o =>
            {
                var clock = (JsonObject)o["clockObservation"];
                JsonValue changed = drift switch
                {
                    "job" => With(clock, "jobId", new JsonString("different-job")),
                    "anchor" => With(clock, "anchor", new JsonString("different-anchor")),
                    "unknown" => new JsonObject(clock.Members.Append(new("calibration", JsonBool.True))),
                    "missing" => new JsonObject(clock.Members.Where(p => p.Key != "status")),
                    "null" => JsonNull.Instance,
                    "nanos" => With(clock, "elapsedNanoseconds", JsonNumber.FromInt64(120_000_000_001)),
                    "float" => With(clock, "elapsedNanoseconds", JsonNumber.FromDouble(7744375)),
                    "fraction" => With(clock, "startedAtHostUTC", new JsonString("2026-10-04T07:56:45.55Z")),
                    "impossible-date" => With(clock, "startedAtHostUTC", new JsonString("2026-02-30T07:56:45.551Z")),
                    _ => With(clock, "status", new JsonString("hostClockDiscontinuity")),
                };
                return With(o, "clockObservation", changed);
            });
            var refusal = Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticSessionOfflineInspector.Inspect(input));
            Assert.AreEqual("diagnostics_invalid_clock_observation", refusal.Reason, drift);
        }
    }

    [TestMethod]
    public void ClockDiscontinuityIsDisplayedWithoutPromotingCrossClockAccuracy()
    {
        var input = Input(Fixture(), o => With(o, "clockObservation", With(With((JsonObject)o["clockObservation"], "status", new JsonString("hostClockDiscontinuity")),
            "finishedAtHostUTC", new JsonString("2026-10-04T07:56:44.559Z"))));
        var inspection = DiagnosticSessionOfflineInspector.Inspect(input);
        Assert.AreEqual("hostClockDiscontinuity", inspection.ClockObservation!.Status);
        Assert.IsInstanceOfType<DiagnosticAlignment.CannotAlign>(inspection.Reading.Alignment);
    }

    [TestMethod]
    public void WholeBytesAndInventoryRemainRequiredForBothSupportedOperations()
    {
        var input = Input(Fixture());
        var marker = input.Documents["markers.json"];
        var bytes = marker.Bytes.ToArray(); bytes[^1] ^= 1;
        Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticOfflineArtifact.Bind(marker.Metadata, bytes));
        Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticOfflineArtifact.Bind(marker.Metadata, bytes[..^1]));
        Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticSessionOfflineInspector.Inspect(input with { OperationReference = "trace.capture@1" }));
        Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticSessionOfflineInspector.Inspect(input with { Inventory = [.. input.Inventory, input.Inventory[0]] }));
        Assert.ThrowsExactly<DiagnosticSessionException>(() => DiagnosticSessionOfflineInspector.Inspect(input with { JobId = "other-job" }));
    }
}
