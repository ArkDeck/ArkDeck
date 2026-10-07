using System.Globalization;
using System.Security.Cryptography;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>A private in-memory upload. Nothing writes the payload to a file, a Job request, UI history or failure text.</summary>
internal sealed class DeviceKeyboardUpload(IControlChannel channel)
{
    public async Task<string?> UploadAsync(DeviceKeyboardCommand command, DeviceScreenTarget target)
    {
        if (!command.IsValid || target.BindingRevision < 1) return null;
        var bytes = command.Payload();
        var id = "app-import-" + Guid.NewGuid().ToString("D");
        var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
        long? generation = null;
        var committing = false;
        string Number(long number) => number.ToString(CultureInfo.InvariantCulture);
        try
        {
            var intent = SurfaceLoader.Params(("schemaVersion", new JsonString("arkdeck.import-intent/1")), ("importRequestId", new JsonString(id)),
                ("kind", new JsonString("keyboard-input")), ("targetId", new JsonString(target.TargetId)), ("bindingRevision", new JsonString(Number(target.BindingRevision))),
                ("deviceProfile", JsonNull.Instance), ("name", new JsonString("keyboard-input.json")), ("byteCount", new JsonString(Number(bytes.Length))), ("sha256", new JsonString(digest)));
            bool Same(ImportRecord record) => record.ImportRequestId == id && record.Kind == "keyboard-input" && record.Name == "keyboard-input.json"
                && record.TargetId == target.TargetId && record.BindingRevision == Number(target.BindingRevision) && record.ByteCount == bytes.Length && record.Sha256 == digest && record.DeviceProfile is null;
            async Task<ImportRecord> Call(string method, JsonObject parameters)
            {
                var result = await channel.RequestAsync(method, parameters).ConfigureAwait(false);
                if (result.Failure is not null) throw new InvalidDataException("Private upload was not confirmed");
                var record = ImportRecord.Parse(result.Value!);
                if (!Same(record)) throw new InvalidDataException("Private upload identity changed");
                return record;
            }
            generation = 1;
            var begun = await Call("artifact.import.begin", intent).ConfigureAwait(false);
            if (begun.State != "inProgress" || begun.Generation != 1 || begun.NextOffset != 0 || begun.MaximumChunkBytes < 1) return null;
            for (var offset = 0; offset < bytes.Length;)
            {
                var count = (int)Math.Min(begun.MaximumChunkBytes, bytes.Length - offset);
                var chunk = bytes.AsSpan(offset, count);
                var appended = await Call("artifact.import.append", SurfaceLoader.Params(("importId", new JsonString(begun.ImportId)), ("generation", new JsonString("1")),
                    ("offset", new JsonString(Number(offset))), ("byteCount", new JsonString(Number(count))),
                    ("sha256", new JsonString(Convert.ToHexStringLower(SHA256.HashData(chunk)))), ("base64", new JsonString(Convert.ToBase64String(chunk))))).ConfigureAwait(false);
                if (appended.ImportId != begun.ImportId || appended.State != "inProgress" || appended.Generation != 1 || appended.NextOffset != offset + count) throw new InvalidDataException("Private upload offset changed");
                offset += count;
            }
            // A commit may persist before an invalid/lost reply. Never abort or repeat after this point.
            committing = true;
            var committed = await Call("artifact.import.commit", SurfaceLoader.Params(("importId", new JsonString(begun.ImportId)), ("generation", new JsonString("1")))).ConfigureAwait(false);
            // Published commit advances the in-progress generation1 to committed generation2.
            return committed.ImportId == begun.ImportId && committed.Generation == 2 && committed.State == "committed" && committed.NextOffset == bytes.Length
                && committed.Receipt is { Privacy: "sensitive", ValidationKind: "keyboard-input", Lease: { Length: > 0 } lease } receipt && receipt.ArtifactDigest == digest
                ? lease : null;
        }
        catch (Exception error) when (error is ContractException or InvalidDataException or InvalidOperationException or KeyNotFoundException or FormatException or InvalidCastException)
        {
            return null;
        }
        finally
        {
            Array.Clear(bytes);
            if (!committing && generation is { } own)
                await channel.RequestAsync("artifact.import.abort", SurfaceLoader.Params(("importRequestId", new JsonString(id)), ("generation", new JsonString(Number(own))))).ConfigureAwait(false);
        }
    }
}
