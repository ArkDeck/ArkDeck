using System.Reflection;
using System.Security.Cryptography;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Contract;

/// <summary>
/// The method schemas <c>spec/control/methods/*.json</c>, embedded at build time. Each one
/// must have the SHA-256 the generator recorded in <see cref="ControlContract.MethodSchemaSha256"/>
/// and the set must equal <see cref="ControlContract.Methods"/>; otherwise the client refuses
/// to validate anything (fail closed), so an edited schema without a regeneration cannot
/// change what the client accepts.
/// </summary>
public static class ContractSchemas
{
    private const string Prefix = "ArkDeck.ClientKit.methods/";
    private static readonly Lazy<IReadOnlyDictionary<string, JsonObject>> Definitions = new(Load);

    public static bool TryGetDefinition(string method, string part, out JsonValue schema)
    {
        schema = JsonNull.Instance;
        if (!Definitions.Value.TryGetValue(method, out var definitions)) return false;
        return definitions.TryGetValue(part, out schema);
    }

    /// <summary>Loads and verifies every embedded schema now instead of on first use.</summary>
    public static int Verify() => Definitions.Value.Count;

    private static IReadOnlyDictionary<string, JsonObject> Load()
    {
        var assembly = typeof(ContractSchemas).Assembly;
        var names = assembly.GetManifestResourceNames().Where(n => n.StartsWith(Prefix, StringComparison.Ordinal)).ToArray();
        var expected = ControlContract.Methods.Select(m => Prefix + m + ".json").ToHashSet(StringComparer.Ordinal);
        if (names.Length != expected.Count || !names.All(expected.Contains))
        {
            throw new ContractException(ContractErrorKind.ContractMismatch, "embedded method schemas differ from the generated method list");
        }
        var result = new Dictionary<string, JsonObject>(StringComparer.Ordinal);
        foreach (var method in ControlContract.Methods)
        {
            var bytes = Read(assembly, Prefix + method + ".json");
            var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
            if (digest != ControlContract.MethodSchemaSha256[method])
            {
                throw new ContractException(ContractErrorKind.ContractMismatch,
                    $"embedded schema {method} differs from the generated bindings; run windows/scripts/generate-clientkit.py --write");
            }
            var document = StrictJson.Parse(bytes);
            if (document["$defs"] is not JsonObject definitions
                || document["x-arkdeck-contractIdentity"] is not JsonString { Value: ControlContract.ContractIdentity })
            {
                throw new ContractException(ContractErrorKind.ContractMismatch, $"schema identity drift: {method}");
            }
            result[method] = definitions;
        }
        return result;
    }

    private static byte[] Read(Assembly assembly, string name)
    {
        using var stream = assembly.GetManifestResourceStream(name)
                           ?? throw new ContractException(ContractErrorKind.ContractMismatch, $"missing embedded schema {name}");
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    }
}
