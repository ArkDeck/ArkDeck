namespace ArkDeck.ClientKit.Contract;

/// <summary>The Rust contract's <c>ContractError</c> variants, same names and meaning.</summary>
public enum ContractErrorKind
{
    Malformed,
    DuplicateKey,
    UnsupportedVersion,
    ContractMismatch,
    UnknownMethod,
    SchemaMismatch,
    IntegerBeyondExactRange,
}

public sealed class ContractException(ContractErrorKind kind, string? detail = null)
    : Exception(detail is null ? kind.ToString() : $"{kind}: {detail}")
{
    public ContractErrorKind Kind { get; } = kind;
}
