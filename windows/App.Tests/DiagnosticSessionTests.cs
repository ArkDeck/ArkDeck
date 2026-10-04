using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Diagnostics workspace's offline half read as macOS reads it. The Swift oracle
/// <c>rust/tests/fixtures/diagnostics-inspect/cases.json</c> (recorded by
/// <c>CLIDiagnosticsInspectOracleContractTests</c> over <c>RuntimeCLI.runDiagnosticsResource</c>,
/// <c>DiagnosticSessionOfflineInspector</c>, <c>DiagnosticSessionReading</c> and
/// <c>DiagnosticArtifactTextPreview</c>) is replayed case by case: the scripted frames feed a
/// test-only copy of the CLI's transport glue (paging, ranges, envelope, outline), the reading and
/// every refusal come from <see cref="DiagnosticSessionOfflineInspector"/>, and stdout, stderr and
/// the exit status must be the golden bytes. The HiLog summary reader is checked against the real
/// <c>job-run-hilog</c> summary Artifact and the analyzer oracle's reports.
/// </summary>
[TestClass]
public sealed class DiagnosticSessionTests
{
    private static string Fixtures => RepoPaths.At("rust", "tests", "fixtures", "diagnostics-inspect");

    private const string Job = "job-6c545eb6042a9ea99e700467bbb77d06";

    // ---------------------------------------------------------------------------------------
    // The oracle replay
    // ---------------------------------------------------------------------------------------

    [TestMethod]
    public void EveryOracleCaseEndsAsTheSwiftCliEnded()
    {
        using var oracle = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Fixtures, "cases.json")));
        var cases = oracle.RootElement.EnumerateArray().ToList();
        Assert.AreEqual(15, cases.Count);
        using var provenance = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Fixtures, "provenance.json")));
        Assert.AreEqual("CLIDiagnosticsInspectOracleContractTests", provenance.RootElement.GetProperty("producer").GetString());

        var mismatches = new List<string>();
        var replayed = 0;
        foreach (var @case in cases)
        {
            var name = @case.GetProperty("name").GetString()!;
            var argv = @case.GetProperty("argv").EnumerateArray().Select(a => a.GetString()!).ToList();
            var script = new Script(@case.GetProperty("script"));
            var (stdout, stderr, exit) = Cli.Run(argv, script);
            replayed++;
            if (script.Unexpected is { } unexpected) mismatches.Add($"{name}: {unexpected}");
            if (script.Remaining > 0) mismatches.Add($"{name}: {script.Remaining} scripted frames unused");
            if (exit != @case.GetProperty("exit").GetInt32()) mismatches.Add($"{name}: exit {exit}, expected {@case.GetProperty("exit").GetInt32()}");
            if (stdout != @case.GetProperty("stdout").GetString()) mismatches.Add($"{name}: stdout\n{stdout}\nexpected\n{@case.GetProperty("stdout").GetString()}");
            if (stderr != @case.GetProperty("stderr").GetString()) mismatches.Add($"{name}: stderr {stderr}");
        }
        Assert.AreEqual(15, replayed);
        Assert.AreEqual(0, mismatches.Count, string.Join("\n", mismatches));
    }

    /// <summary>The scripted peer: each business frame answered in order, its method named.</summary>
    private sealed class Script
    {
        private readonly Queue<(string Method, JsonValue? Result, JsonValue? Error)> _frames = new();

        public Script(JsonElement frames)
        {
            foreach (var frame in frames.EnumerateArray())
            {
                JsonValue? Member(string key) =>
                    frame.TryGetProperty(key, out var v) ? StrictJson.Parse(Encoding.UTF8.GetBytes(v.GetRawText())) : null;
                _frames.Enqueue((frame.GetProperty("method").GetString()!, Member("result"), Member("error")));
            }
        }

        public int Remaining => _frames.Count;

        public string? Unexpected { get; private set; }

        public JsonValue Request(string method)
        {
            if (!_frames.TryPeek(out var next) || next.Method != method)
            {
                Unexpected ??= $"unscripted {method}";
                throw new CliFailure("recordUnreadable", $"unscripted {method}");
            }
            _frames.Dequeue();
            if (next.Error is JsonObject error)
            {
                throw new CliFailure(((JsonString)error["code"]).Value, ((JsonString)error["message"]).Value);
            }
            return next.Result!;
        }
    }

    private sealed class CliFailure(string code, string message) : Exception(message)
    {
        public string Code { get; } = code;
    }

    /// <summary>A test-only copy of the CLI leaf's glue (Swift <c>runDiagnosticsResource</c>, the
    /// Rust <c>diagnostics_resources::run</c>): inventory paging, the Job's typed request, whole
    /// reads over bounded ranges, the result envelope and the human outline. The reading and the
    /// inspector's refusals are <see cref="DiagnosticSessionOfflineInspector"/>'s.</summary>
    private static class Cli
    {
        private const long ReadMaximumBytes = 4_194_304;

        public static (string Stdout, string Stderr, int Exit) Run(List<string> argv, Script script)
        {
            string? Option(string flag) => argv.IndexOf(flag) is var at and >= 0 && at + 1 < argv.Count ? argv[at + 1] : null;
            var verb = argv[1];
            var command = $"diagnostics.{verb}";
            var machine = Option("--output") == "json";
            var meta = Obj(("cliVersion", S("0.1.0")), ("controlProtocolVersion", S("1.0.0")),
                ("controlRequestId", Option("--control-request-id") is { } id ? S(id) : JsonNull.Instance));
            try
            {
                var result = verb == "inspect"
                    ? Inspect(Option("--job")!, script)
                    : Preview(Option("--job")!, Option("--artifact")!, Option("--max-characters"), argv.Contains("--allow-sensitive"), script);
                var stdout = machine
                    ? Encoding.UTF8.GetString(CanonicalJson.Encode(Obj(("command", S(command)), ("meta", meta), ("ok", JsonBool.True),
                        ("result", result), ("schemaVersion", S("arkdeck.cli.result/1"))))) + "\n"
                    : Outline(result, 0) + "\n";
                return (stdout, "", 0);
            }
            catch (Exception error) when (error is CliFailure or DiagnosticSessionException)
            {
                var code = error is CliFailure failure ? failure.Code : CodeOf((DiagnosticSessionException)error);
                var (exit, attention) = code switch
                {
                    "recordUnreadable" or "artifactIntegrityFailed" => (2, true),
                    "resourceNotFound" or "inputTooLarge" or "invalidInput" => (65, false),
                    "sensitiveAccessDenied" or "factsDrifted" => (77, true),
                    _ => (1, true),
                };
                if (!machine) return ("", $"{code}: {error.Message}\n", exit);
                var document = Obj(("command", S(command)),
                    ("error", Obj(("attentionRequired", JsonBool.Of(attention)), ("code", S(code)), ("controlRequestRetryable", JsonBool.False), ("message", S(error.Message)))),
                    ("meta", meta), ("ok", JsonBool.False), ("schemaVersion", S("arkdeck.cli.result/1")));
                return (Encoding.UTF8.GetString(CanonicalJson.Encode(document)) + "\n", "", exit);
            }
        }

        // Swift's mapping of DiagnosticSessionOfflineInspectorError to CLI codes.
        private static string CodeOf(DiagnosticSessionException error) => error.Failure switch
        {
            DiagnosticSessionFailure.ByteCountMismatch or DiagnosticSessionFailure.DigestMismatch => "artifactIntegrityFailed",
            DiagnosticSessionFailure.ContentTooLarge => "inputTooLarge",
            DiagnosticSessionFailure.SensitiveContentRequiresExplicitAccess => "sensitiveAccessDenied",
            _ => "recordUnreadable",
        };

        private static List<DiagnosticArtifactMetadata> Inventory(string job, Script script)
        {
            var rows = new List<ArtifactSummary>();
            string? cursor = null;
            string? revision = null;
            do
            {
                var page = (JsonObject)script.Request("artifact.list");
                IReadOnlyList<ArtifactSummary> items;
                try
                {
                    (items, cursor) = ArtifactSummary.ParsePage(page, job);
                }
                catch (Exception error) when (error is ArkDeck.ClientKit.Contract.ContractException or InvalidCastException or KeyNotFoundException)
                {
                    throw new CliFailure("recordUnreadable", "Artifact inventory page is malformed");
                }
                var snapshot = page.TryGetValue("snapshotRevision", out var s) && s is JsonString text ? text.Value : "";
                if (revision is not null && revision != snapshot) throw new CliFailure("factsDrifted", "diagnostic Artifact snapshot changed while paging");
                revision = snapshot;
                rows.AddRange(items);
            }
            while (cursor is not null);
            if (rows.Count == 0) throw new CliFailure("resourceNotFound", $"diagnostic Job {job} published no Artifacts");
            return rows.Select(r => DiagnosticArtifactMetadata.Create(r.ArtifactId, r.Name, r.MediaType, r.Privacy, r.Status, null,
                r.SourceOperation, r.ByteCount, r.Digest)).ToList();
        }

        private static JsonObject TypedInputs(string job, Script script)
        {
            var show = (JsonObject)script.Request("job.show");
            var status = (JsonObject)show["job"];
            if (((JsonString)status["jobId"]).Value != job || ((JsonString)status["operation"]).Value != DiagnosticSessionOfflineInspector.OperationReference
                || !show.TryGetValue("request", out var r) || r is not JsonObject request)
            {
                throw new CliFailure("recordUnreadable", "Job is not an exact diagnostics capture");
            }
            var operation = (JsonObject)request["operation"];
            var version = ((JsonNumber)operation["version"]).TryGetInt64(out var v) ? v.ToString(CultureInfo.InvariantCulture) : "";
            if ($"{((JsonString)operation["id"]).Value}@{version}" != DiagnosticSessionOfflineInspector.OperationReference
                || ((JsonString)((JsonObject)request["target"])["targetId"]).Value != ((JsonString)status["targetId"]).Value)
            {
                throw new CliFailure("recordUnreadable", "diagnostic Job request does not match its status");
            }
            return request.TryGetValue("inputs", out var inputs) && inputs is JsonObject o ? o : new JsonObject();
        }

        /// <summary>Every bounded range of one published Artifact, bound to its metadata.</summary>
        private static byte[] ReadWhole(DiagnosticArtifactMetadata metadata, long maximum, bool allowSensitive, Script script)
        {
            if (metadata.Status != "published" || metadata.ByteCount > maximum || metadata.Sha256 is null)
            {
                throw new CliFailure("inputTooLarge", "diagnostic Artifact exceeds the bounded read or is unpublished");
            }
            _ = allowSensitive;
            var bytes = new List<byte>();
            long offset = 0;
            while (true)
            {
                var range = Range(script.Request("artifact.read"));
                if (range.Id != metadata.ArtifactId || range.Digest != metadata.Sha256 || range.Total != metadata.ByteCount || range.Offset != offset)
                {
                    throw new CliFailure("recordUnreadable", "diagnostic Artifact range changed identity");
                }
                bytes.AddRange(range.Bytes);
                if (range.Next == range.Total) break;
                if (range.Next <= offset) throw new CliFailure("recordUnreadable", "diagnostic Artifact read stopped advancing");
                offset = range.Next;
            }
            var whole = bytes.ToArray();
            if (whole.Length != metadata.ByteCount || Convert.ToHexStringLower(SHA256.HashData(whole)) != metadata.Sha256)
            {
                throw new CliFailure("artifactIntegrityFailed", "diagnostic Artifact bytes do not match immutable metadata");
            }
            return whole;
        }

        private static (string Id, string Digest, long Offset, long Next, long Total, byte[] Bytes) Range(JsonValue value)
        {
            static CliFailure Malformed() => new("recordUnreadable", "Artifact range identity, bounds or bytes are malformed");
            if (value is not JsonObject o) throw Malformed();
            string[] expected = ["artifactDigest", "artifactId", "base64", "byteCount", "eof", "nextOffset", "offset", "totalByteCount"];
            long? Count(string key) => o.TryGetValue(key, out var v) && v is JsonNumber n && n.TryGetInt64(out var c) && c is >= 0 and <= 9_007_199_254_740_991 ? c : null;
            if (!o.Keys.SequenceEqual(expected)
                || o["artifactId"] is not JsonString { Value.Length: > 0 } id
                || o["artifactDigest"] is not JsonString digest || !ArtifactSummaryDigest(digest.Value)
                || Count("offset") is not { } offset || Count("nextOffset") is not { } next || Count("totalByteCount") is not { } total
                || Count("byteCount") is not { } count || o["eof"] is not JsonBool eof || o["base64"] is not JsonString base64
                || offset > total || next < offset || next > total || count != next - offset || count > ReadMaximumBytes
                || eof.Value != (next == total) || (count == 0 && next != total))
            {
                throw Malformed();
            }
            byte[] bytes;
            try
            {
                bytes = Convert.FromBase64String(base64.Value);
            }
            catch (FormatException)
            {
                throw Malformed();
            }
            if (bytes.Length != count) throw Malformed();
            return (id.Value, digest.Value, offset, next, total, bytes);
        }

        private static bool ArtifactSummaryDigest(string value) => value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

        private static JsonValue Inspect(string job, Script script)
        {
            var inventory = Inventory(job, script);
            var inputs = TypedInputs(job, script);
            var documents = new Dictionary<string, DiagnosticOfflineArtifact>(StringComparer.Ordinal);
            foreach (var name in new[] { DiagnosticSessionOfflineInspector.IndexArtifactName, DiagnosticSessionOfflineInspector.SummaryArtifactName, DiagnosticSessionOfflineInspector.MarkersArtifactName })
            {
                var metadata = inventory.FirstOrDefault(m => m.Name == name && m.Status == "published");
                if (metadata is null)
                {
                    if (name == DiagnosticSessionOfflineInspector.MarkersArtifactName) continue;
                    throw new CliFailure("resourceNotFound", $"diagnostic Job {job} did not publish {name}");
                }
                if (metadata.MediaType != "application/json" || metadata.Privacy != "standard" || metadata.ByteCount == 0
                    || metadata.ByteCount > DiagnosticSessionOfflineInspector.DocumentMaximumBytes)
                {
                    throw new CliFailure("recordUnreadable", $"diagnostic document {name} has unsafe metadata");
                }
                var bytes = ReadWhole(metadata, DiagnosticSessionOfflineInspector.DocumentMaximumBytes, false, script);
                documents[name] = DiagnosticOfflineArtifact.Bind(metadata, bytes);
            }
            return InspectionJson(DiagnosticSessionOfflineInspector.Inspect(new DiagnosticSessionOfflineInput(
                job, DiagnosticSessionOfflineInspector.OperationReference, inputs, inventory, documents)));
        }

        private static JsonValue Preview(string job, string artifactId, string? maximum, bool explicitAccess, Script script)
        {
            var inventory = Inventory(job, script);
            var metadata = inventory.FirstOrDefault(m => m.ArtifactId == artifactId)
                ?? throw new CliFailure("resourceNotFound", $"diagnostic Job {job} has no selected Artifact");
            var characters = maximum is not null && int.TryParse(maximum, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed)
                ? parsed
                : DiagnosticSessionOfflineInspector.PreviewMaximumCharacters;
            if (metadata.Privacy == "sensitive" && !explicitAccess)
            {
                throw new CliFailure("sensitiveAccessDenied", "sensitive diagnostics preview requires --allow-sensitive");
            }
            var bytes = ReadWhole(metadata, DiagnosticSessionOfflineInspector.PreviewMaximumBytes, explicitAccess, script);
            var preview = DiagnosticSessionOfflineInspector.Preview(DiagnosticOfflineArtifact.Bind(metadata, bytes), explicitAccess, characters);
            return Obj(("schemaVersion", S(preview.SchemaVersion)), ("derivation", ProvenanceJson(preview.Provenance)), ("text", S(preview.Text)),
                ("replacedInvalidUtf8", JsonBool.Of(preview.ReplacedInvalidUtf8)), ("clipped", JsonBool.Of(preview.WasClipped)));
        }

        /// <summary>Swift <c>RuntimeCLI.humanRendering(of:)</c>: <c>key: value</c> lines in key
        /// order, an array as <c>- item</c> lines or <c>(none)</c>, null as <c>-</c>, each nested
        /// rendering indented two spaces a level and trimmed of spaces at its ends.</summary>
        private static string Outline(JsonValue value, int indent)
        {
            var pad = new string(' ', indent * 2);
            static string Trimmed(string text) => text.Trim('\t', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ',
                ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', '　');
            return value switch
            {
                JsonObject o => string.Join("\n", o.Members.Select(m => $"{pad}{m.Key}: {Trimmed(Outline(m.Value, indent + 1))}")),
                JsonArray { Items.Count: 0 } => pad + "(none)",
                JsonArray a => string.Join("\n", a.Items.Select(i => $"{pad}- {Trimmed(Outline(i, indent + 1))}")),
                JsonString s => pad + s.Value,
                JsonNull => pad + "-",
                _ => pad + value,
            };
        }
    }

    // The CLI's JSON encoding of the inspector's types (Swift diagnosticsInspectionValue).

    private static JsonString S(string value) => new(value);

    private static JsonValue S(string? value, bool nullable) => nullable && value is null ? JsonNull.Instance : new JsonString(value!);

    private static JsonObject Obj(params (string Key, JsonValue Value)[] members) =>
        new(members.Select(m => new KeyValuePair<string, JsonValue>(m.Key, m.Value)));

    private static JsonValue MetadataJson(DiagnosticArtifactMetadata m) => Obj(
        ("artifactDigest", S(m.Sha256, true)), ("artifactId", S(m.ArtifactId)), ("byteCount", JsonNumber.FromInt64(m.ByteCount)),
        ("mediaType", S(m.MediaType)), ("name", S(m.Name)), ("privacy", S(m.Privacy)), ("sourceOperation", S(m.SourceOperation)),
        ("status", S(m.Status)), ("statusDetail", S(m.StatusDetail, true)));

    private static JsonValue ProvenanceJson(DiagnosticSessionProvenance p) => Obj(
        ("kind", S(p.Kind)), ("parser", S(p.Parser)), ("parserVersion", S(p.ParserVersion)), ("sources", new JsonArray(p.Sources.Select(MetadataJson))));

    private static JsonValue Optional(int? value) => value is { } v ? JsonNumber.FromInt64(v) : JsonNull.Instance;

    private static JsonValue AlignmentJson(DiagnosticAlignment alignment) => alignment switch
    {
        DiagnosticAlignment.SameClock => Obj(("kind", S("sameClock")), ("reason", JsonNull.Instance), ("toleranceMs", JsonNull.Instance)),
        DiagnosticAlignment.Calibrated c => Obj(("kind", S("calibrated")), ("reason", JsonNull.Instance), ("toleranceMs", Optional(c.ToleranceMs))),
        DiagnosticAlignment.CannotAlign c => Obj(("kind", S("cannotAlign")), ("reason", S(c.Reason)), ("toleranceMs", JsonNull.Instance)),
        _ => throw new ArgumentOutOfRangeException(nameof(alignment)),
    };

    private static JsonValue AbsenceJson(DiagnosticScreenshotAbsence? absence) => absence switch
    {
        null => JsonNull.Instance,
        DiagnosticScreenshotAbsence.TakenTooFarFromTheMark t => Obj(("kind", S("takenTooFarFromTheMark")), ("milliseconds", Optional(t.OffsetMs)), ("reason", JsonNull.Instance)),
        DiagnosticScreenshotAbsence.ShutterWindowWiderThanTheRule w => Obj(("kind", S("shutterWindowWiderThanTheRule")), ("milliseconds", Optional(w.WindowMs)), ("reason", JsonNull.Instance)),
        DiagnosticScreenshotAbsence.CaptureFailed f => Obj(("kind", S("captureFailed")), ("milliseconds", JsonNull.Instance), ("reason", S(f.Reason))),
        _ => Obj(("kind", S("notCaptured")), ("milliseconds", JsonNull.Instance), ("reason", JsonNull.Instance)),
    };

    private static JsonValue MarkJson(DiagnosticMark mark) => Obj(
        ("atHostUtc", S(mark.AtHostUtc)), ("kind", S(mark.IsAutomatic ? "automatic" : "manual")), ("label", S(mark.Label, true)),
        ("ordinal", JsonNumber.FromInt64(mark.Ordinal)),
        ("screenshot", mark.Screenshot is { } shot
            ? Obj(("artifactName", S(shot.ArtifactName)), ("capturedAtUtc", S(shot.CapturedAtUtc)), ("takenAfterMarkMs", JsonNumber.FromInt64(shot.TakenAfterMarkMs)))
            : JsonNull.Instance),
        ("screenshotAbsence", AbsenceJson(mark.ScreenshotAbsence)), ("trigger", S(mark.Trigger, true)));

    /// <summary>The members of the inspection a reading carries (shared by the CLI rendering and
    /// the App binding check).</summary>
    private static JsonObject ReadingJson(DiagnosticSessionReading reading, bool? ringHeldAnchor) => Obj(
        ("alignment", AlignmentJson(reading.Alignment)),
        ("markers", new JsonArray(reading.Marks.Select(MarkJson))),
        ("missingProducts", new JsonArray(reading.MissingProducts.Select(p => (JsonValue)Obj(("name", S(p.Name)), ("reason", S(p.Reason)))))),
        ("notDerived", new JsonArray(reading.NotDerived.Select(n => (JsonValue)S(n)))),
        ("partial", JsonBool.Of(reading.IsPartial)),
        ("ringHeldAnchor", ringHeldAnchor is { } anchor ? JsonBool.Of(anchor) : JsonNull.Instance));

    private static JsonValue InspectionJson(DiagnosticSessionInspection inspection)
    {
        var reading = ReadingJson(inspection.Reading, inspection.RingHeldAnchor);
        return new JsonObject(reading.Members.Concat(
        [
            new("artifacts", new JsonArray(inspection.Inventory.Select(MetadataJson))),
            new("derivation", ProvenanceJson(inspection.Provenance)),
            new("jobId", S(inspection.JobId)),
            new("operationReference", S(inspection.OperationReference)),
            new("schemaVersion", S(inspection.SchemaVersion)),
        ]));
    }

    // ---------------------------------------------------------------------------------------
    // The App binding (DiagnosticSessionApplicationReader) over the same recorded Job
    // ---------------------------------------------------------------------------------------

    /// <summary>One recorded case as the App reads it: its rows, correlation, typed inputs and
    /// the verified bytes of each Artifact.</summary>
    private sealed record Recorded(JsonElement Case, List<DiagnosticJobArtifact> Rows, string TargetId, string SessionId,
        JsonObject? Inputs, Dictionary<string, byte[]> Bytes)
    {
        public static Recorded Load(string name)
        {
            using var oracle = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Fixtures, "cases.json")));
            var @case = oracle.RootElement.EnumerateArray().Single(c => c.GetProperty("name").GetString() == name).Clone();
            var rows = new List<DiagnosticJobArtifact>();
            string target = "", session = "";
            JsonObject? inputs = null;
            var bytes = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            foreach (var frame in @case.GetProperty("script").EnumerateArray())
            {
                var result = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(frame.GetProperty("result").GetRawText()));
                switch (frame.GetProperty("method").GetString())
                {
                    case "artifact.list":
                        rows.AddRange(ArtifactSummary.ParsePage(result, Job).Items.Select(r => DiagnosticJobArtifact.From(r, DiagnosticSessionOfflineInspector.OperationReference)));
                        break;
                    case "job.show":
                        var status = (JsonObject)result["job"];
                        var correlation = DiagnosticJobCorrelation.FromStatus(status, Job, DiagnosticSessionOfflineInspector.OperationReference)!;
                        target = correlation.TargetId;
                        session = correlation.SessionId;
                        inputs = (JsonObject)((JsonObject)result["request"])["inputs"];
                        break;
                    case "artifact.read":
                        bytes[((JsonString)result["artifactId"]).Value] = Convert.FromBase64String(((JsonString)result["base64"]).Value);
                        break;
                }
            }
            return new(@case, rows, target, session, inputs, bytes);
        }

        public DiagnosticJobContext Context => new(Job, DiagnosticSessionOfflineInspector.OperationReference, TargetId, SessionId, "succeeded", "execute");

        public DiagnosticJobDetail Detail(IReadOnlyList<DiagnosticJobArtifact>? rows = null, bool evidence = true) =>
            new(Job, new DiagnosticJobCorrelation(Job, DiagnosticSessionOfflineInspector.OperationReference, TargetId, SessionId),
                rows ?? Rows, ["jobCreated"], evidence ? new DiagnosticJobEvidence("succeeded", "execute", "deviceMutation", "hdc", 1, Inputs) : null);

        public DiagnosticArtifactReader Reader(List<string>? log = null) => (artifact, maximum, sensitive) =>
        {
            log?.Add($"{artifact.Name}:{maximum}:{sensitive}");
            return Task.FromResult(Bytes.TryGetValue(artifact.ArtifactId, out var b) && b.Length <= maximum
                ? DiagnosticArtifactRead.Loaded(b)
                : DiagnosticArtifactRead.Failed("fixture_artifact_unavailable"));
        };

        public JsonObject GoldenResult()
        {
            using var golden = JsonDocument.Parse(Case.GetProperty("stdout").GetString()!);
            return (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(golden.RootElement.GetProperty("result").GetRawText()));
        }
    }

    [TestMethod]
    public async Task TheAppBindingReadsTheRecordedSessionsAsTheCliDid()
    {
        foreach (var name in new[] { "inspectComplete", "inspectWithoutMarkers" })
        {
            var recorded = Recorded.Load(name);
            var log = new List<string>();
            var load = await DiagnosticSessionApplication.LoadAsync(recorded.Context, recorded.Detail(), recorded.Reader(log));
            Assert.IsNull(load.UnavailableReason, name);
            var presentation = load.Presentation!;
            var golden = recorded.GoldenResult();
            var expected = new JsonObject(golden.Members.Where(m => m.Key is "alignment" or "markers" or "missingProducts" or "notDerived" or "partial" or "ringHeldAnchor"));
            Assert.AreEqual(expected.ToString(), ReadingJson(presentation.Reading, presentation.RingHeldAnchor).ToString(), name);
            Assert.AreEqual(recorded.Rows.Count, presentation.Artifacts.Count);
            CollectionAssert.AreEqual(new[] { "jobCreated" }, presentation.Timeline.ToArray());
            var documents = name == "inspectComplete" ? 3 : 2;
            Assert.AreEqual(documents, log.Count, name);
            Assert.IsTrue(log.All(l => l.EndsWith(":1048576:False", StringComparison.Ordinal)), string.Join(",", log));
        }
    }

    [TestMethod]
    public async Task TheAppBindingRefusesWithTheSwiftReasons()
    {
        var recorded = Recorded.Load("inspectComplete");
        async Task<string?> Reason(DiagnosticJobContext? context = null, DiagnosticJobDetail? detail = null, DiagnosticArtifactReader? reader = null) =>
            (await DiagnosticSessionApplication.LoadAsync(context ?? recorded.Context, detail ?? recorded.Detail(), reader ?? recorded.Reader())).UnavailableReason;
        List<DiagnosticJobArtifact> With(string name, Func<DiagnosticJobArtifact, DiagnosticJobArtifact> change) =>
            recorded.Rows.Select(r => r.Name == name ? change(r) : r).ToList();

        Assert.AreEqual("diagnostics_unsupported_operation", await Reason(recorded.Context with { OperationReference = "trace.capture@1" }));
        Assert.AreEqual("diagnostics_job_correlation_unavailable", await Reason(recorded.Context with { TargetId = "TGT-other" }));
        Assert.AreEqual("diagnostics_job_correlation_unavailable", await Reason(recorded.Context with { SessionId = null }));
        Assert.AreEqual("diagnostics_job_correlation_unavailable", await Reason(detail: recorded.Detail() with { Correlation = null }));
        Assert.AreEqual("diagnostics_job_correlation_unavailable", await Reason(detail: recorded.Detail() with { Artifacts = null }));
        Assert.AreEqual("diagnostics_job_correlation_unavailable", await Reason(detail: recorded.Detail() with { JobId = "job-other" }));
        Assert.AreEqual("diagnostics_invalid_artifact_metadata", await Reason(detail: recorded.Detail(With("hilog.txt", r => r with { Sha256 = "" }))));
        Assert.AreEqual("diagnostics_invalid_artifact_metadata", await Reason(detail: recorded.Detail(With("hilog.txt", r => r with { Privacy = "secret" }))));
        Assert.AreEqual("diagnostics_ambiguous_artifact_inventory", await Reason(detail: recorded.Detail(With("hilog.txt", r => r with { Name = "markers.json" }))));
        Assert.AreEqual("diagnostics_ambiguous_artifact_inventory", await Reason(detail: recorded.Detail(With("hilog.txt", r => r with { SourceOperation = "trace.capture@1" }))));
        Assert.AreEqual("diagnostics_missing_or_unreadable_artifact-index.json",
            await Reason(detail: recorded.Detail(With("artifact-index.json", r => r with { Role = "raw" }))));
        Assert.AreEqual("diagnostics_missing_or_unreadable_capture-summary.json",
            await Reason(detail: recorded.Detail(With("capture-summary.json", r => r with { Privacy = "sensitive" }))));
        Assert.AreEqual("diagnostics_missing_or_unreadable_artifact-index.json",
            await Reason(detail: recorded.Detail(recorded.Rows.Where(r => r.Name != "artifact-index.json").ToList())));
        Assert.AreEqual("fixture_artifact_unavailable", await Reason(reader: (_, _, _) => Task.FromResult(DiagnosticArtifactRead.Failed("fixture_artifact_unavailable"))));
        Assert.AreEqual("diagnostics_artifact_byte_count_mismatch", await Reason(reader: (_, _, _) => Task.FromResult(DiagnosticArtifactRead.Loaded("{}"u8.ToArray()))));
        Assert.AreEqual("diagnostics_artifact_integrity_mismatch", await Reason(reader: async (artifact, maximum, sensitive) =>
        {
            var bytes = (await recorded.Reader()(artifact, maximum, sensitive)).Bytes!.ToArray();
            bytes[^2] ^= 0x01;
            return DiagnosticArtifactRead.Loaded(bytes);
        }));
        Assert.AreEqual("diagnostics_unreadable_session_document", await Reason(reader: (_, _, _) => throw new IOException("transport gone")));

        // Without reported typed parameters the reading names them as a missing product.
        var load = await DiagnosticSessionApplication.LoadAsync(recorded.Context, recorded.Detail(evidence: false), recorded.Reader());
        Assert.AreEqual("parameters: typed capture inputs were not reported",
            string.Join("|", load.Presentation!.Reading.MissingProducts.Select(p => $"{p.Name}: {p.Reason}")));
    }

    [TestMethod]
    public async Task TheInspectorsOwnRefusalsPassThroughTheAppBinding()
    {
        foreach (var (name, reason) in new[] { ("inspectSummaryMismatch", "diagnostics_index_summary_mismatch"), ("inspectUnknownMarker", "diagnostics_unknown_marker_kind") })
        {
            var recorded = Recorded.Load(name);
            var load = await DiagnosticSessionApplication.LoadAsync(recorded.Context, recorded.Detail(), recorded.Reader());
            Assert.AreEqual(reason, load.UnavailableReason, name);
        }
    }

    [TestMethod]
    public void TheCatalogRolesAreTheOnesTheTableDeclares()
    {
        foreach (var (file, reference) in new[] { ("capture.diagnostics.v1.json", DiagnosticSessionOfflineInspector.OperationReference), ("analyzer.summarize-hilog.v1.json", DiagnosticHilogSummary.OperationReference) })
        {
            using var operation = JsonDocument.Parse(File.ReadAllBytes(RepoPaths.At("Catalog", "operations", file)));
            var declared = operation.RootElement.GetProperty("artifacts").EnumerateArray()
                .ToDictionary(a => a.GetProperty("name").GetString()!, a => a.GetProperty("role").GetString()!);
            var table = DiagnosticArtifactRoles.Declared[reference];
            Assert.AreEqual(declared.Count, table.Count, file);
            foreach (var (name, role) in declared) Assert.AreEqual(role, DiagnosticArtifactRoles.Of(reference, name), $"{file} {name}");
        }
    }

    // ---------------------------------------------------------------------------------------
    // The reading, selection, preview and metadata rules
    // ---------------------------------------------------------------------------------------

    [TestMethod]
    public void TheTextPreviewClipsCharactersAndDisclosesReplacedBytes()
    {
        Assert.AreEqual(new DiagnosticArtifactTextPreview("éa", false, true), DiagnosticArtifactTextPreview.Create("éabc"u8, "text/plain", 2));
        Assert.AreEqual(new DiagnosticArtifactTextPreview("a�", true, false), DiagnosticArtifactTextPreview.Create([(byte)'a', 0xFF], "text/plain", 10));
        Assert.AreEqual(new DiagnosticArtifactTextPreview("abc", false, false), DiagnosticArtifactTextPreview.Create("abc"u8, "application/json", 3));
        Assert.IsNull(DiagnosticArtifactTextPreview.Create([(byte)'a', 0xFF], "application/json", 10));
        Assert.IsNull(DiagnosticArtifactTextPreview.Create("a"u8, "text/plain", 0));
        Assert.IsNull(DiagnosticArtifactTextPreview.Create("a"u8, "text/plain", 120_001));
        Assert.IsNull(DiagnosticArtifactTextPreview.Create("a"u8, "image/png", 10));
        Assert.IsNull(DiagnosticArtifactTextPreview.Create(new byte[DiagnosticArtifactTextPreview.MaximumBytes + 1], "text/plain", 10));
    }

    [TestMethod]
    public void ThePreviewRefusesBeforeItDecodes()
    {
        var text = "hello"u8.ToArray();
        DiagnosticOfflineArtifact Artifact(string privacy, string mediaType = "text/plain", string operation = DiagnosticSessionOfflineInspector.OperationReference) =>
            DiagnosticOfflineArtifact.Bind(DiagnosticArtifactMetadata.Create("ART-1", "a.txt", mediaType, privacy, "published", null, operation, text.Length,
                Convert.ToHexStringLower(SHA256.HashData(text))), text);
        string Refusal(Action action)
        {
            try
            {
                action();
                return "none";
            }
            catch (DiagnosticSessionException error)
            {
                return error.Reason;
            }
        }
        Assert.AreEqual("diagnostics_sensitive_preview_requires_explicit_access", Refusal(() => DiagnosticSessionOfflineInspector.Preview(Artifact("sensitive"), false)));
        Assert.AreEqual("hello", DiagnosticSessionOfflineInspector.Preview(Artifact("sensitive"), true).Text);
        Assert.AreEqual("diagnostics_artifact_is_not_previewable_text", Refusal(() => DiagnosticSessionOfflineInspector.Preview(Artifact("standard", "image/png"), false)));
        Assert.AreEqual("diagnostics_artifact_is_not_previewable_text", Refusal(() => DiagnosticSessionOfflineInspector.Preview(Artifact("standard", operation: "trace.capture@1"), false)));
        Assert.AreEqual("diagnostics_invalid_structured_text", Refusal(() => DiagnosticSessionOfflineInspector.Preview(Artifact("standard"), false, 0)));
        Assert.AreEqual("diagnostics_invalid_artifact_metadata",
            Refusal(() => DiagnosticArtifactMetadata.Create("ART-​1", "a", "text/plain", "standard", "missing", null, "x", 0, null)));
        Assert.AreEqual("diagnostics_invalid_artifact_metadata",
            Refusal(() => DiagnosticArtifactMetadata.Create("ART-1", "a", "text/plain", "standard", "missing", null, "x", 0, new string('a', 64))));
        Assert.AreEqual("diagnostics_invalid_artifact_metadata",
            Refusal(() => DiagnosticArtifactMetadata.Create("ART-1", "a", "text/plain", "standard", "published", null, "x", DiagnosticSessionOfflineInspector.MaximumSafeInteger + 1, new string('a', 64))));
    }

    [TestMethod]
    public void AMarkOnlyGetsAPictureTakenCloseEnoughToStandForIt()
    {
        var document = (JsonObject)StrictJson.Parse("""
            {"jobId":"job-1","markers":[
              {"kind":"manual","atHostUTC":"2026-09-10T00:00:01Z","label":"near"},
              {"kind":"manual","atHostUTC":"2026-09-10T00:00:05Z"},
              {"kind":"auto","trigger":"anr","atHostUTC":"2026-09-10T00:00:10Z"},
              {"kind":"manual","atHostUTC":"2026-09-10T00:00:20Z"},
              {"kind":"manual","atHostUTC":"2026-09-10T00:00:30Z"},
              {"kind":"auto","trigger":"crash"}],
             "notDerived":[{"kind":"frameDrops","reason":"not sampled"}]}
            """u8);
        var reading = DiagnosticSessionReading.Make(document,
            screenshots: [("a.png", "2026-09-10T00:00:01.120Z"), ("b.png", "2026-09-10T00:00:05.400Z")],
            observedScreenshots: [new("c.png", "2026-09-10T00:00:10.100Z", "2026-09-10T00:00:10.650Z"), new("d.png", "2026-09-10T00:00:19.950Z", "2026-09-10T00:00:20.050Z")],
            failedScreenshots: [new("2026-09-10T00:00:30.100Z", "screencap failed")]);
        // Without a nearer picture, a failure at the mark is its answer.
        var failures = DiagnosticSessionReading.Make(document, failedScreenshots: [new("2026-09-10T00:00:30.100Z", "screencap failed")]);
        Assert.AreEqual("job-1", reading.JobId);
        Assert.IsInstanceOfType<DiagnosticAlignment.CannotAlign>(reading.Alignment);
        Assert.IsFalse(reading.IsPartial);
        CollectionAssert.AreEqual(new[] { "frameDrops" }, reading.NotDerived.ToArray());
        var marks = reading.Marks;
        Assert.AreEqual(new DiagnosticScreenshot("a.png", "2026-09-10T00:00:01.120Z", 120), marks[0].Screenshot);
        Assert.AreEqual("near", marks[0].Label);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.TakenTooFarFromTheMark(400), marks[1].ScreenshotAbsence);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.ShutterWindowWiderThanTheRule(550), marks[2].ScreenshotAbsence);
        Assert.IsTrue(marks[2].IsAutomatic);
        Assert.AreEqual("anr", marks[2].Trigger);
        Assert.AreEqual(new DiagnosticScreenshot("d.png", "2026-09-10T00:00:19.950Z", -50), marks[3].Screenshot);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.TakenTooFarFromTheMark(-24600), marks[4].ScreenshotAbsence);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.CaptureFailed("screencap failed"), failures.Marks[4].ScreenshotAbsence);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.NotCaptured(), failures.Marks[0].ScreenshotAbsence);
        Assert.AreEqual(new DiagnosticScreenshotAbsence.NotCaptured(), marks[5].ScreenshotAbsence);
        Assert.AreEqual("", marks[5].AtHostUtc);
        CollectionAssert.AreEqual(new[] { 1, 2, 3, 4, 5, 6 }, marks.Select(m => m.Ordinal).ToArray());
    }

    [TestMethod]
    public void ASelectedEventSurvivesTheCursorMovingAway()
    {
        var selection = new DiagnosticReaderSelection("2026-09-10T00:00:00Z");
        Assert.IsNull(selection.CursorOffsetFromEventMs());
        selection.Select(new DiagnosticReaderEvent("e1", "vsync", "2026-09-10T00:00:01.000Z"));
        Assert.AreEqual("2026-09-10T00:00:01.000Z", selection.CursorUtc);
        Assert.AreEqual(0, selection.CursorOffsetFromEventMs());
        selection.MoveCursor("2026-09-10T08:00:01.250+08:00");
        Assert.AreEqual("e1", selection.Event!.Identity);
        Assert.AreEqual(250, selection.CursorOffsetFromEventMs());
        selection.MoveCursor("not a time");
        Assert.IsNull(selection.CursorOffsetFromEventMs());
    }

    // ---------------------------------------------------------------------------------------
    // The HiLog summary (DiagnosticHilogSummaryReader, HilogSummaryArtifactContract)
    // ---------------------------------------------------------------------------------------

    private const string HilogJob = "job-ce57f7b014978fe39492cf64043a8fc9";
    private const string HilogArtifact = "ART-4b509be8295099e86ab78921a82cb214";
    private const string Lease = "lease-v1:job-oracle-source:ART-bfdf1c6973a8e0f2917400119782e8c5";

    private static byte[] HilogBytes() =>
        File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "job-run-hilog", "artifacts", HilogJob, HilogArtifact));

    private static DiagnosticJobArtifact HilogRow(byte[] bytes)
    {
        using var index = JsonDocument.Parse(File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "job-run-hilog", "artifacts", HilogJob, "index.json")));
        var row = index.RootElement.GetProperty("artifacts").EnumerateArray().Single();
        Assert.AreEqual(HilogArtifact, row.GetProperty("artifactID").GetString());
        return new DiagnosticJobArtifact(HilogArtifact, row.GetProperty("name").GetString()!,
            DiagnosticArtifactRoles.Of(DiagnosticHilogSummary.OperationReference, row.GetProperty("name").GetString()!),
            row.GetProperty("mediaType").GetString()!, bytes.Length, Convert.ToHexStringLower(SHA256.HashData(bytes)),
            row.GetProperty("privacy").GetString()!, "published", null, row.GetProperty("sourceOperation").GetString()!,
            row.GetProperty("createdAtUTC").GetString()!);
    }

    private static readonly DiagnosticJobContext HilogContext =
        new(HilogJob, DiagnosticHilogSummary.OperationReference, "TGT-ORACLE", $"session-{HilogJob}", "succeeded", "execute");

    private static DiagnosticJobEvidence HilogEvidence(string lease = Lease) =>
        new("succeeded", "execute", "hostOnly", "analyzer", null, new JsonObject([new("sourceArtifactRef", new JsonString(lease))]));

    private static DiagnosticJobDetail HilogDetail(DiagnosticJobArtifact row, DiagnosticJobEvidence? evidence = null) =>
        new(HilogJob, new DiagnosticJobCorrelation(HilogJob, DiagnosticHilogSummary.OperationReference, "TGT-ORACLE", $"session-{HilogJob}"),
            [row], ["jobCreated"], evidence ?? HilogEvidence());

    private static DiagnosticArtifactReader Serve(byte[] bytes) => (_, maximum, sensitive) =>
        Task.FromResult(!sensitive && bytes.Length <= maximum ? DiagnosticArtifactRead.Loaded(bytes) : DiagnosticArtifactRead.Failed("refused"));

    /// <summary>The summary with its bytes changed and the Artifact row rebound to them, so the
    /// row's digest holds and the document's own checks decide.</summary>
    private static Task<DiagnosticHilogSummaryLoad> Rebound(byte[] bytes, DiagnosticJobEvidence? evidence = null) =>
        DiagnosticHilogSummary.LoadAsync(HilogContext, HilogDetail(HilogRow(bytes), evidence), Serve(bytes));

    [TestMethod]
    public async Task TheRealSummaryArtifactVerifies()
    {
        var bytes = HilogBytes();
        var load = await DiagnosticHilogSummary.LoadAsync(HilogContext, HilogDetail(HilogRow(bytes)), Serve(bytes));
        Assert.IsNull(load.UnavailableReason);
        var summary = load.Presentation!;
        Assert.AreEqual(HilogJob, summary.JobId);
        Assert.AreEqual("job-oracle-source", summary.SourceJobId);
        Assert.AreEqual("ART-bfdf1c6973a8e0f2917400119782e8c5", summary.SourceArtifactId);
        Assert.AreEqual("a4bc1c6c2557176d1f54edbd6a990b087233d87ce1ef0f17ab1b48d0e0772ede", summary.SourceSha256);
        Assert.AreEqual(149, summary.SourceByteCount);
        Assert.AreEqual("88e62115a59da350e4d072a850ab7c6a3bf1693dc039d6c7fce91d4e0c19c1d3", summary.AnalyzerExecutableSha256);
        Assert.AreEqual("b8e2baabb82b69e611f004d3465632bd3e1f70b86ecc35471c5a3afeef5c2e41", summary.AnalyzerOutputSha256);
        Assert.AreEqual("partial", summary.HeaderCoverage);
        Assert.AreEqual(5, summary.LineCount);
        Assert.AreEqual(1, summary.BlankLineCount);
        Assert.AreEqual(2, summary.UnrecognizedLineCount);
        Assert.AreEqual("D=0,E=1,F=0,I=1,W=0", string.Join(",", summary.LevelCounts.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value}")));
        Assert.AreEqual(HilogArtifact, summary.Artifact.ArtifactId);
        // The recorded analyzer output is the source artifact's: its digest is the fixture source's.
        var source = File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "job-run-hilog", "artifacts", "job-oracle-source", "ART-bfdf1c6973a8e0f2917400119782e8c5"));
        Assert.AreEqual(summary.SourceSha256, Convert.ToHexStringLower(SHA256.HashData(source)));
    }

    [TestMethod]
    public async Task EveryChangedSummaryIsAnIntegrityMismatch()
    {
        var bytes = HilogBytes();
        var row = HilogRow(bytes);
        const string Integrity = "diagnostics_hilog_summary_integrity_mismatch";

        // Each byte flipped under the published digest.
        for (var i = 0; i < bytes.Length; i += 17)
        {
            var flipped = bytes.ToArray();
            flipped[i] ^= 0x20;
            Assert.AreEqual(Integrity, (await DiagnosticHilogSummary.LoadAsync(HilogContext, HilogDetail(row), Serve(flipped))).UnavailableReason, $"byte {i}");
        }
        // A short read.
        Assert.AreEqual(Integrity, (await DiagnosticHilogSummary.LoadAsync(HilogContext, HilogDetail(row), Serve(bytes[..^1]))).UnavailableReason);

        var text = Encoding.UTF8.GetString(bytes);
        string Replace(string from, string to)
        {
            Assert.IsTrue(text.Contains(from, StringComparison.Ordinal), from);
            return text.Replace(from, to, StringComparison.Ordinal);
        }
        // Non-canonical re-encodings of the same document, each rebound to its own digest.
        var variants = new Dictionary<string, string>
        {
            ["pretty"] = JsonSerializer.Serialize(JsonDocument.Parse(bytes).RootElement, new JsonSerializerOptions { WriteIndented = true }),
            ["trailing newline"] = text + "\n",
            ["leading space"] = " " + text,
            ["escaped slash-free key"] = Replace("\"result\"", "\"r\\u0065sult\""),
            ["float count"] = Replace("\"lineCount\":5", "\"lineCount\":5.0"),
            ["unsorted keys"] = "{\"sourceArtifactID\":\"ART-bfdf1c6973a8e0f2917400119782e8c5\"," + text[1..].Replace(",\"sourceArtifactID\":\"ART-bfdf1c6973a8e0f2917400119782e8c5\"", "", StringComparison.Ordinal),
            ["unknown member"] = Replace("{\"analyzerExecutableSHA256\"", "{\"extra\":1,\"analyzerExecutableSHA256\""),
            ["missing member"] = Replace(",\"redaction\":\"content-and-identifiers-omitted\"", ""),
            ["wrong output digest"] = Replace("b8e2baabb82b69e611f004d3465632bd3e1f70b86ecc35471c5a3afeef5c2e41", new string('0', 64)),
            ["wrong output byte count"] = Replace("\"analyzerOutputByteCount\":402", "\"analyzerOutputByteCount\":401"),
            ["uppercase executable digest"] = Replace("88e62115a59da350e4d072a850ab7c6a3bf1693dc039d6c7fce91d4e0c19c1d3", "88E62115A59DA350E4D072A850AB7C6A3BF1693DC039D6C7FCE91D4E0C19C1D3"),
            ["another source artifact"] = Replace("\"sourceArtifactID\":\"ART-bfdf1c6973a8e0f2917400119782e8c5\"", "\"sourceArtifactID\":\"ART-0b72741235e0ba2f16141531374a7080\""),
            ["changed report"] = Replace("\"unrecognizedLineCount\":2", "\"unrecognizedLineCount\":3"),
        };
        foreach (var (name, variant) in variants)
        {
            Assert.AreNotEqual(text, variant, name);
            Assert.AreEqual(Integrity, (await Rebound(Encoding.UTF8.GetBytes(variant))).UnavailableReason, name);
        }
        // The lease naming another source Artifact than the summary records.
        Assert.AreEqual(Integrity, (await DiagnosticHilogSummary.LoadAsync(HilogContext,
            HilogDetail(row, HilogEvidence("lease-v1:job-oracle-source:ART-0b72741235e0ba2f16141531374a7080")), Serve(bytes))).UnavailableReason);
    }

    [TestMethod]
    public async Task TheSummaryReaderRefusesWrongJobFactsWithTheSwiftReasons()
    {
        var bytes = HilogBytes();
        var row = HilogRow(bytes);
        async Task<string?> Reason(DiagnosticJobContext? context = null, DiagnosticJobDetail? detail = null, DiagnosticArtifactReader? reader = null) =>
            (await DiagnosticHilogSummary.LoadAsync(context ?? HilogContext, detail ?? HilogDetail(row), reader ?? Serve(bytes))).UnavailableReason;

        const string NotCompleted = "diagnostics_hilog_summary_not_completed";
        Assert.AreEqual(NotCompleted, await Reason(HilogContext with { State = "failed" }));
        Assert.AreEqual(NotCompleted, await Reason(HilogContext with { ExecutionMode = "planOnly" }));
        Assert.AreEqual(NotCompleted, await Reason(HilogContext with { OperationReference = "capture.diagnostics@1" }));

        const string Correlation = "diagnostics_hilog_summary_correlation_mismatch";
        var evidence = HilogEvidence();
        Assert.AreEqual(Correlation, await Reason(HilogContext with { TargetId = "TGT-OTHER" }));
        Assert.AreEqual(Correlation, await Reason(HilogContext with { SessionId = "session-other" }));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row) with { Correlation = null }));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row) with { Evidence = null }));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { TerminalState = "failed" })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { ExecutionMode = "planOnly" })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { ActualEffect = "readOnly" })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { ProviderId = "hdc" })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { BindingRevision = 1 })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { TypedParameters = null })));
        Assert.AreEqual(Correlation, await Reason(detail: HilogDetail(row, evidence with { TypedParameters = new JsonObject([new("sourceArtifactRef", JsonNumber.FromInt64(1))]) })));

        const string Source = "diagnostics_hilog_summary_source_unavailable";
        foreach (var lease in new[] { "lease-v2:job-oracle-source:ART-1", "lease-v1:job-oracle-source", "lease-v1::ART-1", "lease-v1:job/x:ART-1", "lease-v1:a:b:c" })
        {
            Assert.AreEqual(Source, await Reason(detail: HilogDetail(row, HilogEvidence(lease))), lease);
        }

        const string Unavailable = "diagnostics_hilog_summary_artifact_unavailable";
        foreach (var changed in new[]
        {
            row with { Role = "raw" }, row with { Role = null }, row with { Privacy = "sensitive" }, row with { Status = "missing" },
            row with { MediaType = "text/plain" }, row with { ByteCount = 0 }, row with { ByteCount = 16 * 1024 + 1 },
            row with { Sha256 = "" }, row with { Name = "summary.json" }, row with { SourceOperation = "capture.diagnostics@1" },
        })
        {
            Assert.AreEqual(Unavailable, await Reason(detail: HilogDetail(changed)), changed.ToString());
        }
        Assert.AreEqual(Unavailable, await Reason(detail: HilogDetail(row) with { Artifacts = null }));
        Assert.AreEqual(Unavailable, await Reason(detail: HilogDetail(row) with { Artifacts = [row, row with { Name = "other.json" }] }));

        Assert.AreEqual("diagnostics_hilog_summary_read_failed", await Reason(reader: (_, _, _) => Task.FromResult(DiagnosticArtifactRead.Failed("gone"))));
        var asked = new List<string>();
        await Reason(reader: (artifact, maximum, sensitive) =>
        {
            asked.Add($"{artifact.ArtifactId}:{maximum}:{sensitive}");
            return Serve(bytes)(artifact, maximum, sensitive);
        });
        CollectionAssert.AreEqual(new[] { $"{HilogArtifact}:16384:False" }, asked);
    }

    [TestMethod]
    public void EveryAnalyzerReportValidatesForItsOwnSource()
    {
        using var oracle = JsonDocument.Parse(File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "hilog-summary-analyzer", "oracle.json")));
        var reports = 0;
        var valid = 0;
        foreach (var @case in oracle.RootElement.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("exitStatus").GetInt32() == 0))
        {
            var name = @case.GetProperty("name").GetString()!;
            var report = Encoding.UTF8.GetBytes(@case.GetProperty("stdout").GetString()!);
            var input = Convert.FromBase64String(@case.GetProperty("input").GetString()!);
            var sha = Convert.ToHexStringLower(SHA256.HashData(input));
            var lines = JsonDocument.Parse(report).RootElement.GetProperty("lineCount").GetInt64();
            reports++;
            // The contract admits no empty source: an analyzer report over zero bytes never verifies.
            var expected = input.Length > 0 && lines >= 1;
            Assert.AreEqual(expected, DiagnosticHilogSummary.ValidateReport(report, sha, input.Length), name);
            if (!expected) continue;
            valid++;
            Assert.IsFalse(DiagnosticHilogSummary.ValidateReport(report, new string('0', 64), input.Length), name);
            Assert.IsFalse(DiagnosticHilogSummary.ValidateReport(report, sha, input.Length + 1), name);
            Assert.IsFalse(DiagnosticHilogSummary.ValidateReport([.. report, (byte)'\n'], sha, input.Length), name);
        }
        Assert.AreEqual(39, reports);
        Assert.AreEqual(38, valid);
    }
}
