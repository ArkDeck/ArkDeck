using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace ArkDeck.App.Core.Presentation;

/// <summary>Which step refused an archive: the reader (<c>GzipTarArchiveReaderError</c>), the
/// introspection (<c>RockchipArchiveIntrospectionFailure</c>) or the board
/// (<c>RockchipFlashProfileError</c>, and <c>DeviceProviderError.unsupportedAction</c> as the
/// Import policy's <c>forBuild</c> rethrew a nonconforming build).</summary>
public enum FlashArchiveErrorKind
{
    UnreadableFile,
    NotGzip,
    UnsupportedCompressionMethod,
    CorruptGzipHeader,
    DecompressionFailed,
    TruncatedArchive,
    CorruptTarHeader,
    PartitionTableMissing,
    PartitionTableUnparsable,
    SystemImageMissing,
    RuntimeBuildVersionUnreadable,
    InvalidProfileDefinition,
    ArchiveDoesNotConform,
    UnsupportedAction,
}

/// <summary>An archive refused by one of the macOS steps. <see cref="Description"/> is the
/// error as Swift's <c>String(describing:)</c> spells it, e.g.
/// <c>corruptTarHeader("header checksum mismatch")</c>.</summary>
public sealed class FlashArchiveException(FlashArchiveErrorKind kind, string? detail = null)
    : Exception(Describe(kind, detail))
{
    public FlashArchiveErrorKind Kind { get; } = kind;

    public string? Detail { get; } = detail;

    public string Description => Message;

    public bool IsReaderError => Kind <= FlashArchiveErrorKind.CorruptTarHeader;

    public bool IsIntrospectionFailure => Kind is >= FlashArchiveErrorKind.PartitionTableMissing and <= FlashArchiveErrorKind.RuntimeBuildVersionUnreadable;

    private static string Describe(FlashArchiveErrorKind kind, string? detail)
    {
        var name = kind switch
        {
            FlashArchiveErrorKind.UnreadableFile => "unreadableFile",
            FlashArchiveErrorKind.NotGzip => "notGzip",
            FlashArchiveErrorKind.UnsupportedCompressionMethod => "unsupportedCompressionMethod",
            FlashArchiveErrorKind.CorruptGzipHeader => "corruptGzipHeader",
            FlashArchiveErrorKind.DecompressionFailed => "decompressionFailed",
            FlashArchiveErrorKind.TruncatedArchive => "truncatedArchive",
            FlashArchiveErrorKind.CorruptTarHeader => "corruptTarHeader",
            FlashArchiveErrorKind.PartitionTableMissing => "partitionTableMissing",
            FlashArchiveErrorKind.PartitionTableUnparsable => "partitionTableUnparsable",
            FlashArchiveErrorKind.SystemImageMissing => "systemImageMissing",
            FlashArchiveErrorKind.RuntimeBuildVersionUnreadable => "runtimeBuildVersionUnreadable",
            FlashArchiveErrorKind.InvalidProfileDefinition => "invalidProfileDefinition",
            FlashArchiveErrorKind.ArchiveDoesNotConform => "archiveDoesNotConform",
            _ => null,
        };
        // `DeviceProviderError.unsupportedAction` describes itself as its reason.
        if (name is null) return detail ?? "";
        return detail is null ? name : name + "(" + SwiftText.Quoted(detail) + ")";
    }
}

/// <summary>One regular member of the tar stream (macOS <c>GzipTarMemberSummary</c>).</summary>
public sealed record FlashArchiveMember(string Name, long SizeBytes, string Sha256);

/// <summary>What a caller wants derived while the archive streams past (macOS
/// <c>GzipTarDerivationRequest</c>): members kept up to a byte bound, and one member scanned for
/// a key followed by a printable value run.</summary>
public sealed record FlashDerivationRequest(
    IReadOnlySet<string> CaptureMembers,
    int CaptureByteLimit = 1 << 20,
    string? ScanMember = null,
    string ScanKey = "");

/// <summary>The one streaming pass over an archive (macOS <c>GzipTarArchiveSummary</c>): its size
/// and digest, every regular member's, the members captured under the request's bound (a member
/// that overran it is absent) and the scanned value.</summary>
public sealed record FlashArchiveSummary(
    long ArchiveSizeBytes,
    string ArchiveSha256,
    IReadOnlyList<FlashArchiveMember> Members,
    IReadOnlyDictionary<string, byte[]> CapturedMembers,
    string? ScannedValue);

/// <summary>macOS <c>RockchipArchiveMemberClassification</c>.</summary>
public enum FlashMemberClassification
{
    MappedPartitionImage,
    OrphanImageWriteForbidden,
    PartitionTable,
    LoaderMaskromBranchOnly,
    NonPartitionMetadata,
}

/// <summary>An archive member with the board's classification of it (macOS
/// <c>RockchipImagesArchiveMember</c>).</summary>
public sealed record FlashClassifiedMember(string Name, long SizeBytes, string Sha256, FlashMemberClassification Classification)
{
    /// <summary>The classification's Swift raw value, e.g. <c>mappedPartitionImage</c>.</summary>
    public string ClassificationRawValue => Classification switch
    {
        FlashMemberClassification.MappedPartitionImage => "mappedPartitionImage",
        FlashMemberClassification.OrphanImageWriteForbidden => "orphanImageWriteForbidden",
        FlashMemberClassification.PartitionTable => "partitionTable",
        FlashMemberClassification.LoaderMaskromBranchOnly => "loaderMaskromBranchOnly",
        _ => "nonPartitionMetadata",
    };
}

/// <summary>One partition as the archive's own <c>parameter.txt</c> declares it (macOS
/// <c>RockchipDeclaredPartition</c>); a size of −1 is the grow marker <c>-</c>.</summary>
public sealed record FlashDeclaredPartition(string Name, long SizeSectors, long OffsetSectors);

/// <summary>Everything the archive states about the build it carries (macOS
/// <c>RockchipImageBuildDescriptor</c>).</summary>
public sealed record FlashBuildDescriptor(
    long ArchiveSizeBytes,
    string ArchiveSha256,
    IReadOnlyList<FlashClassifiedMember> Members,
    IReadOnlyList<FlashDeclaredPartition> DeclaredPartitions,
    string RuntimeBuildVersion);

/// <summary>Which partition a flash covers and the member that fills it, in review order (macOS
/// <c>RockchipMappedPartition</c>).</summary>
public sealed record FlashMappedPartition(int WriteOrder, string PartitionName, string ImageMemberName);

/// <summary>A board prerequisite and whether the profile requires it (macOS
/// <c>RockchipPrerequisiteIdentifier</c>/<c>RockchipPrerequisiteRequirement</c> raw values).</summary>
public sealed record FlashPrerequisite(string Identifier, string Requirement);

/// <summary>The DAYU200 board carrying one archive's facts (macOS <c>RockchipFlashProfile</c> as
/// <c>withArchiveBuild</c> makes it).</summary>
public sealed record FlashBoardProfile(
    string CatalogReference,
    string FirmwareVersion,
    string RuntimeProductModel,
    string RuntimeBuildVersion,
    long ArchiveSizeBytes,
    string ArchiveSha256,
    IReadOnlyList<FlashClassifiedMember> Members,
    IReadOnlyList<FlashMappedPartition> MappedPartitions,
    IReadOnlyList<string> MembershiplessPartitionsWriteForbidden,
    IReadOnlyList<FlashPrerequisite> Prerequisites)
{
    /// <summary>Orphan images, in archive order: shipped, never written.</summary>
    public IReadOnlyList<string> WriteForbiddenMemberNames =>
        [.. Members.Where(m => m.Classification == FlashMemberClassification.OrphanImageWriteForbidden).Select(m => m.Name)];

    public FlashClassifiedMember? Member(string name) => Members.FirstOrDefault(m => SwiftText.Equal(m.Name, name));
}

/// <summary>The DAYU200 board layout (macOS <c>RockchipFlashProfile.dayu200</c>'s board facts
/// and its CHG-2026-056 r4 board-scoped rules). The seed archive's pinned digests are not
/// carried: every per-build fact is read from the archive under review.</summary>
public sealed class FlashBoard
{
    public const string PartitionTableMemberName = "parameter.txt";
    public const string LoaderMemberName = "MiniLoaderAll.bin";
    public const string RuntimeVersionKey = "const.ohos.fullname=";

    public static FlashBoard Dayu200 { get; } = new();

    private FlashBoard() { }

    public string CatalogReference => "dayu200";

    public string RuntimeProductModel => "ohos";

    /// <summary>The partition whose image carries the value the booted device reports as its build.</summary>
    public string RuntimeVersionPartitionName => "system";

    public IReadOnlyList<FlashMappedPartition> MappedPartitions { get; } =
    [
        new(1, "uboot", "uboot.img"),
        new(2, "resource", "resource.img"),
        new(3, "boot_linux", "boot_linux.img"),
        new(4, "ramdisk", "ramdisk.img"),
        new(5, "system", "system.img"),
        new(6, "vendor", "vendor.img"),
        new(7, "updater", "updater.img"),
        new(8, "chip_ckm", "chip_ckm.img"),
        new(9, "userdata", "userdata.img"),
    ];

    public IReadOnlyList<string> MembershiplessPartitionsWriteForbidden { get; } =
        ["misc", "bootctrl", "sys-prod", "chip-prod", "eng_system", "eng_chipset"];

    public IReadOnlyList<FlashPrerequisite> Prerequisites { get; } =
    [
        new("loader", "required"),
        new("recoveryPath", "required"),
        new("unlocked", "required"),
        new("stablePower", "optional"),
    ];

    public static FlashBoard? Board(string reference) => reference == Dayu200.CatalogReference ? Dayu200 : null;

    private string? SystemImageMemberName =>
        MappedPartitions.FirstOrDefault(m => m.PartitionName == RuntimeVersionPartitionName)?.ImageMemberName;

    /// <summary>What the reader must derive for <see cref="FlashArchive.Describe"/>: the partition
    /// table kept, the system image scanned for the runtime version.</summary>
    public FlashDerivationRequest DerivationRequest() =>
        new(new HashSet<string>([PartitionTableMemberName], SwiftText.Comparer), 1 << 20, SystemImageMemberName, RuntimeVersionKey);

    /// <summary>What a member is, from the board's facts and its name alone.</summary>
    public FlashMemberClassification Classify(string name)
    {
        if (SwiftText.Equal(name, PartitionTableMemberName)) return FlashMemberClassification.PartitionTable;
        if (SwiftText.Equal(name, LoaderMemberName)) return FlashMemberClassification.LoaderMaskromBranchOnly;
        if (MappedPartitions.Any(m => SwiftText.Equal(m.ImageMemberName, name))) return FlashMemberClassification.MappedPartitionImage;
        var characters = SwiftText.Characters(name);
        if (characters.Count >= 4 && characters[^4..].SequenceEqual([".", "i", "m", "g"]))
        {
            // `chip_prod.img` names the `chip-prod` partition.
            var partition = string.Concat(characters[..^4].Select(c => c == "_" ? "-" : c));
            if (MembershiplessPartitionsWriteForbidden.Any(p => SwiftText.Equal(p, partition)))
            {
                return FlashMemberClassification.OrphanImageWriteForbidden;
            }
        }
        return FlashMemberClassification.NonPartitionMetadata;
    }

    /// <summary>Every way a build does not fit this board, in the macOS order: mapped images
    /// missing, partitions the table declares that the board does not know (sorted), mapped
    /// partitions the table does not declare, an empty version.</summary>
    public IReadOnlyList<string> Conformance(FlashBuildDescriptor build)
    {
        var violations = new List<string>();
        var memberNames = new HashSet<string>(build.Members.Select(m => m.Name), SwiftText.Comparer);
        foreach (var mapped in MappedPartitions.Where(m => !memberNames.Contains(m.ImageMemberName)))
        {
            violations.Add("mappedPartitionImageMissing:" + mapped.PartitionName);
        }
        var declaredNames = new HashSet<string>(build.DeclaredPartitions.Select(p => p.Name), SwiftText.Comparer);
        var knownNames = new HashSet<string>(MappedPartitions.Select(m => m.PartitionName).Concat(MembershiplessPartitionsWriteForbidden), SwiftText.Comparer);
        foreach (var declared in declaredNames.Where(n => !knownNames.Contains(n)).Order(SwiftText.Order))
        {
            violations.Add("undeclaredPartitionInTable:" + declared);
        }
        foreach (var mapped in MappedPartitions.Where(m => !declaredNames.Contains(m.PartitionName)))
        {
            violations.Add("mappedPartitionAbsentFromTable:" + mapped.PartitionName);
        }
        if (build.RuntimeBuildVersion.Length == 0) violations.Add("runtimeBuildVersionUnreadable");
        return violations;
    }

    /// <summary>macOS <c>withArchiveBuild</c>: this board carrying the build's facts, else
    /// <c>archiveDoesNotConform("flash bundle does not fit dayu200: …")</c>.</summary>
    public FlashBoardProfile WithArchiveBuild(FlashBuildDescriptor build) => Fit(build, FlashArchiveErrorKind.ArchiveDoesNotConform);

    /// <summary>The Import policy's <c>forBuild</c>: as <see cref="WithArchiveBuild"/>, a
    /// nonconforming build refused with the bare reason (<c>unsupportedAction</c>).</summary>
    public FlashBoardProfile ForBuild(FlashBuildDescriptor build) => Fit(build, FlashArchiveErrorKind.UnsupportedAction);

    private FlashBoardProfile Fit(FlashBuildDescriptor build, FlashArchiveErrorKind nonconforming)
    {
        var violations = Conformance(build);
        if (violations.Count > 0)
        {
            throw new FlashArchiveException(nonconforming, $"flash bundle does not fit {CatalogReference}: " + string.Join("; ", violations));
        }
        return Profile(build);
    }

    /// <summary>The <c>RockchipFlashProfile</c> initializer's own checks over the build's facts.</summary>
    private FlashBoardProfile Profile(FlashBuildDescriptor build)
    {
        static FlashArchiveException Invalid(string reason) => new(FlashArchiveErrorKind.InvalidProfileDefinition, reason);
        if (CatalogReference != "dayu200" || build.RuntimeBuildVersion.Length == 0 || RuntimeProductModel.Length == 0)
        {
            throw Invalid("profile reference must be dayu200 and firmware facts must be present");
        }
        var memberNames = new HashSet<string>(build.Members.Select(m => m.Name), SwiftText.Comparer);
        if (memberNames.Count != build.Members.Count) throw Invalid("duplicate archive member name");
        var mappedMemberNames = new HashSet<string>(
            build.Members.Where(m => m.Classification == FlashMemberClassification.MappedPartitionImage).Select(m => m.Name), SwiftText.Comparer);
        if (!mappedMemberNames.SetEquals(MappedPartitions.Select(m => m.ImageMemberName)))
        {
            throw Invalid("mapped partitions and mappedPartitionImage members must agree exactly");
        }
        if (!MappedPartitions.Select(m => m.WriteOrder).SequenceEqual(Enumerable.Range(1, MappedPartitions.Count)))
        {
            throw Invalid("write order must be contiguous starting at 1");
        }
        if (MappedPartitions.Any(m => MembershiplessPartitionsWriteForbidden.Any(p => SwiftText.Equal(p, m.PartitionName))))
        {
            throw Invalid("a partition cannot be both mapped and write-forbidden");
        }
        if (!MappedPartitions.All(m => memberNames.Contains(m.ImageMemberName)))
        {
            throw Invalid("mapped partition references an undeclared member");
        }
        return new FlashBoardProfile(
            CatalogReference,
            build.RuntimeBuildVersion,
            RuntimeProductModel,
            build.RuntimeBuildVersion,
            build.ArchiveSizeBytes,
            build.ArchiveSha256.ToLowerInvariant(),
            build.Members,
            MappedPartitions,
            MembershiplessPartitionsWriteForbidden,
            Prerequisites);
    }

    /// <summary>macOS <c>reviewingArchive(at:)</c>: one pass, described, fitted to this board.</summary>
    public FlashBoardProfile ReviewingArchive(string path) =>
        WithArchiveBuild(FlashArchive.Describe(FlashArchive.Summarize(path, DerivationRequest()), this));
}

/// <summary>macOS <c>FlashPlanFailureCode</c>.</summary>
public enum FlashReviewFailureCode
{
    FileAccessDenied,
    UnsupportedArchiveFormat,
    UnreadableArchive,
    InvalidArchive,
    UnsupportedBundle,
    PlanMaterializationFailed,
}

/// <summary>macOS <c>FlashDataImpactPresentation</c>.</summary>
public enum FlashDataImpactKind
{
    MappedPartitionsOverwritten,
    UserDataDestroyed,
    ForbiddenAreasPreserved,
}

/// <summary>One data impact the review states; <see cref="Count"/> only for
/// <see cref="FlashDataImpactKind.MappedPartitionsOverwritten"/>.</summary>
public sealed record FlashDataImpact(FlashDataImpactKind Kind, int? Count = null);

/// <summary>One partition row of the review (macOS <c>FlashPartitionPresentation</c>).</summary>
public sealed record FlashPartitionRow(int WriteOrder, string PartitionName, string ImageMemberName, long ImageSizeBytes, string ImageSha256);

/// <summary>What the Flash page shows for an archive that passed review: the archive's facts of
/// macOS <c>FlashPlanPresentationBuilder.presentation</c> (the catalog step list, digests and
/// Runtime admission are not the local review's).</summary>
public sealed record FlashReviewedArchive(
    string ProfileReference,
    string ImageFileName,
    string RuntimeBuildVersion,
    long ArchiveSizeBytes,
    string ArchiveSha256,
    int MappedPartitionCount,
    IReadOnlyList<FlashDataImpact> DataImpact,
    IReadOnlyList<FlashPartitionRow> Partitions,
    IReadOnlyList<string> WriteForbiddenMemberNames,
    IReadOnlyList<FlashPrerequisite> Prerequisites,
    FlashBoardProfile Profile)
{
    public bool UserDataDestroyed => DataImpact.Any(i => i.Kind == FlashDataImpactKind.UserDataDestroyed);
}

/// <summary>The local review of an archive: either <see cref="Reviewed"/>, or a failure code and
/// its detail (macOS <c>FlashPlanPreparationResult</c> before any Runtime call).</summary>
public sealed record FlashArchiveReview(FlashReviewedArchive? Reviewed, FlashReviewFailureCode? FailureCode = null, string? FailureDetail = null)
{
    public static FlashArchiveReview Failed(FlashReviewFailureCode code, string? detail = null) => new(null, code, detail);
}

/// <summary>The Import policy's answer for a flash bundle (macOS
/// <c>FlashBundleImportPolicy.production</c>): the archive's byte count and digest, or the one
/// refusal <c>flash bundle is not a usable DAYU200 images archive: …</c>.</summary>
public sealed record FlashImportVerdict(long? ByteCount, string? Sha256, string? Error);

/// <summary>
/// A DAYU200 <c>images.tar.gz</c> read on the host, as macOS reads it: one streaming pass
/// (<c>GzipTarArchiveReader</c>), the build it carries (<c>RockchipImageArchiveIntrospection</c>),
/// the board's structural fit (<c>RockchipFlashProfile</c>) and the Flash review built from it
/// (<c>FlashPlanPresentationBuilder.prepare</c>). Nothing in the archive is extracted, written out
/// or run; the gzip trailer is ignored, the member and archive SHA-256 are the integrity authority.
/// </summary>
public static class FlashArchive
{
    internal const int ChunkSizeBytes = 1 << 20;
    internal const int MaximumGzipHeaderBytes = 1 << 16;

    private static readonly string[] AllowedFilenameExtensions = ["tar.gz", "zip", "7z"];

    /// <summary>macOS <c>FlashImageArchiveSelectionPolicy.allows</c>: a <c>.tar.gz</c>, <c>.zip</c>
    /// or <c>.7z</c> name, else gzip, zip or 7z magic bytes (content-addressed Artifact files keep
    /// no suffix).</summary>
    public static bool IsSelectable(string path)
    {
        var filename = Path.GetFileName(Path.TrimEndingDirectorySeparator(path)).ToLowerInvariant();
        var length = new StringInfo(filename).LengthInTextElements;
        foreach (var extension in AllowedFilenameExtensions)
        {
            var suffix = "." + extension;
            if (length > suffix.Length && filename.EndsWith(suffix, StringComparison.Ordinal)) return true;
        }
        byte[] prefix;
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            prefix = new byte[6];
            prefix = prefix[..file.ReadAtLeast(prefix, prefix.Length, throwOnEndOfStream: false)];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
        ReadOnlySpan<byte> bytes = prefix;
        return bytes.StartsWith((ReadOnlySpan<byte>)[0x1F, 0x8B])
            || bytes.StartsWith((ReadOnlySpan<byte>)[0x50, 0x4B, 0x03, 0x04])
            || bytes.StartsWith((ReadOnlySpan<byte>)[0x50, 0x4B, 0x05, 0x06])
            || bytes.StartsWith((ReadOnlySpan<byte>)[0x50, 0x4B, 0x07, 0x08])
            || bytes.StartsWith((ReadOnlySpan<byte>)[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]);
    }

    /// <summary>macOS <c>FlashPlanPresentationBuilder.prepare</c>'s local half: selection policy,
    /// readability, board, the one-pass review, and the Flash page's facts.</summary>
    public static FlashArchiveReview Review(string path, string profileReference = "dayu200")
    {
        if (!IsSelectable(path)) return FlashArchiveReview.Failed(FlashReviewFailureCode.UnsupportedArchiveFormat);
        if (!IsReadable(path)) return FlashArchiveReview.Failed(FlashReviewFailureCode.FileAccessDenied);
        if (FlashBoard.Board(profileReference) is not { } board)
        {
            return FlashArchiveReview.Failed(FlashReviewFailureCode.UnsupportedBundle, profileReference);
        }
        FlashBoardProfile profile;
        try
        {
            profile = board.ReviewingArchive(path);
        }
        catch (FlashArchiveException failure) when (failure.IsReaderError)
        {
            return failure.Kind == FlashArchiveErrorKind.UnreadableFile
                ? FlashArchiveReview.Failed(FlashReviewFailureCode.UnreadableArchive)
                : FlashArchiveReview.Failed(FlashReviewFailureCode.InvalidArchive, failure.Description);
        }
        catch (FlashArchiveException failure) when (failure.IsIntrospectionFailure)
        {
            return FlashArchiveReview.Failed(FlashReviewFailureCode.UnsupportedBundle, failure.Description);
        }
        catch (FlashArchiveException failure)
        {
            return FlashArchiveReview.Failed(FlashReviewFailureCode.PlanMaterializationFailed, failure.Description);
        }
        var partitions = profile.MappedPartitions.Select(mapped =>
        {
            var member = profile.Member(mapped.ImageMemberName)
                ?? throw new InvalidOperationException("validated profile is missing mapped member " + mapped.ImageMemberName);
            return new FlashPartitionRow(mapped.WriteOrder, mapped.PartitionName, mapped.ImageMemberName, member.SizeBytes, member.Sha256);
        }).ToList();
        return new FlashArchiveReview(new FlashReviewedArchive(
            profile.CatalogReference,
            Path.GetFileName(Path.TrimEndingDirectorySeparator(path)),
            profile.RuntimeBuildVersion,
            profile.ArchiveSizeBytes,
            profile.ArchiveSha256,
            profile.MappedPartitions.Count,
            [
                new(FlashDataImpactKind.MappedPartitionsOverwritten, profile.MappedPartitions.Count),
                new(FlashDataImpactKind.UserDataDestroyed),
                new(FlashDataImpactKind.ForbiddenAreasPreserved),
            ],
            partitions,
            [.. profile.WriteForbiddenMemberNames.Order(SwiftText.Order)],
            profile.Prerequisites,
            profile));
    }

    /// <summary>Foundation's <c>isReadableFile(atPath:)</c>: a directory is readable, and then
    /// fails the review as <c>unreadableFile</c>.</summary>
    private static bool IsReadable(string path)
    {
        if (Directory.Exists(path)) return true;
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>macOS <c>FlashBundleImportPolicy.production</c>'s DAYU200 candidate.</summary>
    public static FlashImportVerdict ValidateForImport(string path)
    {
        try
        {
            var summary = Summarize(path, FlashBoard.Dayu200.DerivationRequest());
            FlashBoard.Dayu200.ForBuild(Describe(summary, FlashBoard.Dayu200));
            return new FlashImportVerdict(summary.ArchiveSizeBytes, summary.ArchiveSha256, null);
        }
        catch (FlashArchiveException failure)
        {
            return new FlashImportVerdict(null, null, "flash bundle is not a usable DAYU200 images archive: " + failure.Description);
        }
    }

    /// <summary>macOS <c>GzipTarArchiveReader.summarize(fileAt:derivation:)</c>. A failed read ends
    /// the input, as Swift's <c>try? read(upToCount:)</c> does.</summary>
    /// <exception cref="FlashArchiveException">A reader error.</exception>
    public static FlashArchiveSummary Summarize(string path, FlashDerivationRequest? derivation = null)
    {
        FileStream file;
        try
        {
            file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new FlashArchiveException(FlashArchiveErrorKind.UnreadableFile, path);
        }
        using (file)
        {
            return Summarize(file, path, derivation);
        }
    }

    /// <summary>The same pass over any stream; <paramref name="path"/> names it in <c>unreadableFile</c>.</summary>
    public static FlashArchiveSummary Summarize(Stream input, string path, FlashDerivationRequest? derivation = null)
    {
        using var archive = new ArchiveInput(input);
        var pending = new MemoryStream();
        var chunk = new byte[ChunkSizeBytes];
        int headerLength;
        while (true)
        {
            var count = archive.Fill(chunk);
            if (count == 0)
            {
                throw pending.Length == 0
                    ? new FlashArchiveException(FlashArchiveErrorKind.UnreadableFile, path)
                    : new FlashArchiveException(FlashArchiveErrorKind.CorruptGzipHeader);
            }
            pending.Write(chunk, 0, count);
            if (GzipHeaderLength(pending.GetBuffer().AsSpan(0, (int)pending.Length)) is { } length)
            {
                headerLength = length;
                break;
            }
            if (pending.Length > MaximumGzipHeaderBytes) throw new FlashArchiveException(FlashArchiveErrorKind.CorruptGzipHeader);
        }

        var tar = new TarStreamSummarizer(derivation);
        var payload = new PayloadStream(pending.GetBuffer().AsMemory(headerLength, (int)pending.Length - headerLength), archive);
        using (var inflate = new DeflateStream(payload, CompressionMode.Decompress, leaveOpen: true))
        {
            var output = new byte[ChunkSizeBytes];
            while (true)
            {
                int produced;
                try
                {
                    produced = inflate.Read(output);
                }
                catch (InvalidDataException)
                {
                    throw new FlashArchiveException(FlashArchiveErrorKind.DecompressionFailed);
                }
                if (produced == 0) break;
                tar.Consume(output.AsSpan(0, produced));
            }
        }
        // The decoder asked for input past the end: the DEFLATE stream never reached its final block.
        if (payload.Exhausted) throw new FlashArchiveException(FlashArchiveErrorKind.DecompressionFailed);
        archive.Drain(chunk);
        var members = tar.Finish();
        return new FlashArchiveSummary(archive.Size, archive.Sha256(), members, tar.CapturedMembers, tar.ScannedValue);
    }

    /// <summary>macOS <c>gzipHeaderLength(of:)</c>: the RFC 1952 header's length once buffered,
    /// null while more input is needed.</summary>
    internal static int? GzipHeaderLength(ReadOnlySpan<byte> data)
    {
        var bytes = data[..Math.Min(data.Length, MaximumGzipHeaderBytes)];
        if (bytes.Length < 10) return null;
        if (bytes[0] != 0x1f || bytes[1] != 0x8b) throw new FlashArchiveException(FlashArchiveErrorKind.NotGzip);
        if (bytes[2] != 8) throw new FlashArchiveException(FlashArchiveErrorKind.UnsupportedCompressionMethod);
        var flags = bytes[3];
        if ((flags & 0xe0) != 0) throw new FlashArchiveException(FlashArchiveErrorKind.CorruptGzipHeader);
        var index = 10;
        if ((flags & 0x04) != 0)
        {
            if (bytes.Length < index + 2) return null;
            index += 2 + (bytes[index] | bytes[index + 1] << 8);
            if (bytes.Length < index) return null;
        }
        foreach (var terminated in (ReadOnlySpan<bool>)[(flags & 0x08) != 0, (flags & 0x10) != 0])
        {
            if (!terminated) continue;
            var terminator = bytes[index..].IndexOf((byte)0);
            if (terminator < 0) return null;
            index += terminator + 1;
        }
        if ((flags & 0x02) != 0)
        {
            index += 2;
            if (bytes.Length < index) return null;
        }
        return index;
    }

    /// <summary>macOS <c>RockchipImageArchiveIntrospection.describe(summary:board:)</c>.</summary>
    /// <exception cref="FlashArchiveException">An introspection failure.</exception>
    public static FlashBuildDescriptor Describe(FlashArchiveSummary summary, FlashBoard board)
    {
        var members = summary.Members
            .Select(m => new FlashClassifiedMember(m.Name, m.SizeBytes, m.Sha256, board.Classify(m.Name)))
            .ToList();
        var table = summary.CapturedMembers
            .FirstOrDefault(entry => SwiftText.Equal(entry.Key, FlashBoard.PartitionTableMemberName)).Value
            ?? throw new FlashArchiveException(FlashArchiveErrorKind.PartitionTableMissing);
        var declared = Partitions(table);
        var systemImage = board.MappedPartitions.FirstOrDefault(m => m.PartitionName == board.RuntimeVersionPartitionName)?.ImageMemberName;
        if (systemImage is null || !members.Any(m => SwiftText.Equal(m.Name, systemImage)))
        {
            throw new FlashArchiveException(FlashArchiveErrorKind.SystemImageMissing, board.RuntimeVersionPartitionName);
        }
        if (summary.ScannedValue is not { Length: > 0 } version)
        {
            throw new FlashArchiveException(FlashArchiveErrorKind.RuntimeBuildVersionUnreadable);
        }
        return new FlashBuildDescriptor(summary.ArchiveSizeBytes, summary.ArchiveSha256.ToLowerInvariant(), members, declared, version);
    }

    /// <summary>macOS <c>partitions(inTable:)</c>: the <c>CMDLINE</c> line's Rockchip
    /// <c>mtdparts</c> list, <c>size@offset(name[:attribute])</c> in hexadecimal sectors, read over
    /// Characters (extended grapheme clusters) as Swift's <c>String</c> reads it.</summary>
    /// <exception cref="FlashArchiveException"><c>partitionTableUnparsable</c>.</exception>
    public static IReadOnlyList<FlashDeclaredPartition> Partitions(byte[] table)
    {
        static FlashArchiveException Unparsable(string detail) => new(FlashArchiveErrorKind.PartitionTableUnparsable, detail);
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(table);
        }
        catch (DecoderFallbackException)
        {
            throw Unparsable("not UTF-8");
        }
        var commandLine = Split(SwiftText.Characters(text), "\n")
            .FirstOrDefault(line => StartsWith(line, "CMDLINE"))
            ?? throw Unparsable("no mtdparts");
        var start = IndexOf(commandLine, "mtdparts=");
        if (start < 0) throw Unparsable("no mtdparts");
        var list = commandLine[(start + "mtdparts=".Length)..];
        var colon = list.IndexOf(":");
        if (colon < 0) throw Unparsable("no device prefix");
        var declared = new List<FlashDeclaredPartition>();
        foreach (var piece in Split(list[(colon + 1)..], ","))
        {
            var trimmed = SwiftText.TrimWhitespace(string.Concat(piece));
            var entry = SwiftText.Characters(trimmed);
            var open = entry.IndexOf("(");
            if (open < 0 || entry.Count == 0 || entry[^1] != ")") throw Unparsable(trimmed);
            var geometry = entry[..open];
            var rawName = entry[(open + 1)..^1];
            var nameParts = Split(rawName, ":");
            var name = string.Concat(nameParts.Count > 0 ? nameParts[0] : rawName);
            var at = geometry.IndexOf("@");
            if (at < 0) throw Unparsable(trimmed);
            var offset = HexSectors(geometry[(at + 1)..]) ?? throw Unparsable(trimmed);
            // `-` is the grow marker: the partition runs to the end of the device.
            var size = (at == 1 && geometry[0] == "-" ? -1 : HexSectors(geometry[..at])) ?? throw Unparsable(trimmed);
            if (name.Length == 0) throw Unparsable(trimmed);
            declared.Add(new FlashDeclaredPartition(name, size, offset));
        }
        if (declared.Count == 0) throw Unparsable("empty list");
        return declared;
    }

    /// <summary>macOS <c>hexSectors</c>: an optional <c>0x</c>, then at most 16 characters
    /// <c>Int64(_:radix: 16)</c> reads, its optional sign included.</summary>
    private static long? HexSectors(List<string> text)
    {
        var body = text.Count >= 2 && text[0] == "0" && text[1] is "x" or "X" ? text[2..] : text;
        if (body.Count == 0 || body.Count > 16) return null;
        var joined = string.Concat(body);
        var negative = joined[0] == '-';
        var digits = joined[0] is '-' or '+' ? joined[1..] : joined;
        if (digits.Length == 0 || !digits.All(char.IsAsciiHexDigit)) return null;
        var magnitude = Int128.Parse(digits, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
        var value = negative ? -magnitude : magnitude;
        return value < long.MinValue || value > long.MaxValue ? null : (long)value;
    }

    /// <summary>Swift <c>split(separator:)</c> over Characters, empty pieces omitted.</summary>
    private static List<List<string>> Split(List<string> characters, string separator)
    {
        var pieces = new List<List<string>>();
        var current = new List<string>();
        foreach (var character in characters)
        {
            if (character == separator)
            {
                if (current.Count > 0) pieces.Add(current);
                current = [];
            }
            else
            {
                current.Add(character);
            }
        }
        if (current.Count > 0) pieces.Add(current);
        return pieces;
    }

    private static bool StartsWith(List<string> characters, string ascii) =>
        characters.Count >= ascii.Length && ascii.Select((c, i) => characters[i] == c.ToString()).All(same => same);

    private static int IndexOf(List<string> characters, string ascii)
    {
        for (var start = 0; start + ascii.Length <= characters.Count; start++)
        {
            if (StartsWith(characters[start..], ascii)) return start;
        }
        return -1;
    }

    /// <summary>The archive bytes as Swift reads them: hashed and counted as they pass, a failed
    /// read taken as the end of the input.</summary>
    private sealed class ArchiveInput(Stream input) : IDisposable
    {
        private readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        private bool ended;

        public long Size { get; private set; }

        public int Read(Span<byte> buffer)
        {
            if (ended || buffer.IsEmpty) return 0;
            int count;
            try
            {
                count = input.Read(buffer);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                count = 0;
            }
            if (count == 0)
            {
                ended = true;
                return 0;
            }
            hash.AppendData(buffer[..count]);
            Size += count;
            return count;
        }

        public int Fill(byte[] buffer)
        {
            var filled = 0;
            while (filled < buffer.Length)
            {
                var count = Read(buffer.AsSpan(filled));
                if (count == 0) break;
                filled += count;
            }
            return filled;
        }

        public void Drain(byte[] buffer)
        {
            while (Read(buffer) > 0) { }
        }

        public string Sha256() => Convert.ToHexStringLower(hash.GetHashAndReset());

        public void Dispose() => hash.Dispose();
    }

    /// <summary>The DEFLATE payload: what followed the gzip header in the buffered chunk, then the
    /// rest of the archive.</summary>
    private sealed class PayloadStream(ReadOnlyMemory<byte> head, ArchiveInput rest) : Stream
    {
        private ReadOnlyMemory<byte> head = head;

        /// <summary>A read found the end of the archive.</summary>
        public bool Exhausted { get; private set; }

        public override int Read(Span<byte> buffer)
        {
            if (!head.IsEmpty)
            {
                var take = Math.Min(head.Length, buffer.Length);
                head.Span[..take].CopyTo(buffer);
                head = head[take..];
                return take;
            }
            var count = rest.Read(buffer);
            if (count == 0 && !buffer.IsEmpty) Exhausted = true;
            return count;
        }

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    /// <summary>macOS <c>TarStreamSummarizer</c>.</summary>
    private sealed class TarStreamSummarizer(FlashDerivationRequest? derivation)
    {
        private enum State { Header, MemberContent, SkipContent, Finished }

        private readonly byte[] header = new byte[512];
        private readonly List<FlashArchiveMember> members = [];
        private State state = State.Header;
        private int headerCount;
        private string memberName = "";
        private long memberSizeBytes;
        private long remainingBytes;
        private long paddingAfterContent;
        private IncrementalHash memberHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        private int zeroBlockCount;
        private MemoryStream? capturing;
        private bool capturingOverflowed;
        private FlashValueScanner? scanner;

        public Dictionary<string, byte[]> CapturedMembers { get; } = new(SwiftText.Comparer);

        public string? ScannedValue { get; private set; }

        public void Consume(ReadOnlySpan<byte> input)
        {
            var offset = 0;
            while (offset < input.Length)
            {
                switch (state)
                {
                    case State.Finished:
                        return;
                    case State.Header:
                        var take = Math.Min(512 - headerCount, input.Length - offset);
                        input.Slice(offset, take).CopyTo(header.AsSpan(headerCount));
                        headerCount += take;
                        offset += take;
                        if (headerCount == 512)
                        {
                            headerCount = 0;
                            ParseHeaderBlock();
                        }
                        break;
                    default:
                        var count = (int)Math.Min(remainingBytes, input.Length - offset);
                        if (state == State.MemberContent && count > 0)
                        {
                            var slice = input.Slice(offset, count);
                            memberHasher.AppendData(slice);
                            if (capturing is not null)
                            {
                                if (capturing.Length + count <= (derivation?.CaptureByteLimit ?? 0)) capturing.Write(slice);
                                else capturingOverflowed = true;
                            }
                            if (scanner is not null && ScannedValue is null) ScannedValue = scanner.Consume(slice);
                        }
                        offset += count;
                        remainingBytes -= count;
                        if (remainingBytes == 0)
                        {
                            if (state == State.MemberContent)
                            {
                                FinishMember();
                                // The 512-byte alignment padding after the content is not in the digest.
                                remainingBytes = paddingAfterContent;
                                paddingAfterContent = 0;
                                state = remainingBytes == 0 ? State.Header : State.SkipContent;
                            }
                            else
                            {
                                state = State.Header;
                            }
                        }
                        break;
                }
            }
        }

        public IReadOnlyList<FlashArchiveMember> Finish() => state switch
        {
            State.Finished => members,
            // Tolerates archives whose trailing zero blocks were trimmed by the writer.
            State.Header when headerCount == 0 => members,
            _ => throw new FlashArchiveException(FlashArchiveErrorKind.TruncatedArchive),
        };

        private void ParseHeaderBlock()
        {
            ReadOnlySpan<byte> block = header;
            if (!block.ContainsAnyExcept((byte)0))
            {
                zeroBlockCount++;
                if (zeroBlockCount >= 2) state = State.Finished;
                return;
            }
            zeroBlockCount = 0;

            var storedChecksum = ParseNumericField(block[148..156], "checksum");
            long computedChecksum = 0;
            for (var index = 0; index < 512; index++) computedChecksum += index is >= 148 and < 156 ? 0x20 : block[index];
            if (storedChecksum != computedChecksum) throw Corrupt("header checksum mismatch");

            var name = NulTerminatedString(block[..100]);
            var isPosixFormat = block[257..262].SequenceEqual("ustar"u8) && block[262] == 0 && block[263..265].SequenceEqual("00"u8);
            if (isPosixFormat)
            {
                var prefix = NulTerminatedString(block[345..500]);
                if (prefix.Length > 0) name = prefix + "/" + name;
            }
            if (name.Length == 0) throw Corrupt("empty member name");

            var size = ParseNumericField(block[124..136], "size");
            // A size within one alignment block of the largest integer describes no real member,
            // and the padding added below would overflow on it: refused, never trapped.
            if (size > long.MaxValue - 511) throw Corrupt("member size does not leave room for its 512-byte alignment");
            var typeFlag = block[156];
            var padding = (512 - size % 512) % 512;
            // Regular files only: pax/global/long-name records and every other type are skipped
            // as opaque content, and an archive relying on them fails validation downstream.
            if (typeFlag is 0x30 or 0x00)
            {
                memberName = name;
                memberSizeBytes = size;
                memberHasher.Dispose();
                memberHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                BeginDerivation(name);
                remainingBytes = size;
                paddingAfterContent = padding;
                if (remainingBytes == 0)
                {
                    FinishMember();
                    remainingBytes = paddingAfterContent;
                    paddingAfterContent = 0;
                    state = remainingBytes == 0 ? State.Header : State.SkipContent;
                }
                else
                {
                    state = State.MemberContent;
                }
            }
            else
            {
                remainingBytes = size + padding;
                state = remainingBytes == 0 ? State.Header : State.SkipContent;
            }
        }

        private void FinishMember()
        {
            members.Add(new FlashArchiveMember(memberName, memberSizeBytes, Convert.ToHexStringLower(memberHasher.GetHashAndReset())));
            // A member that overran the capture bound is not kept at all: half a partition table
            // would parse into half a plan.
            if (capturing is not null && !capturingOverflowed) CapturedMembers[memberName] = capturing.ToArray();
            capturing = null;
            capturingOverflowed = false;
            scanner = null;
        }

        private void BeginDerivation(string name)
        {
            if (derivation is null) return;
            if (derivation.CaptureMembers.Any(m => SwiftText.Equal(m, name))) capturing = new MemoryStream();
            if (derivation.ScanMember is { } scanMember && SwiftText.Equal(scanMember, name) && derivation.ScanKey.Length > 0)
            {
                scanner = new FlashValueScanner(derivation.ScanKey);
            }
        }

        private static FlashArchiveException Corrupt(string detail) => new(FlashArchiveErrorKind.CorruptTarHeader, detail);

        /// <summary>Swift <c>String(decoding:as: UTF8.self)</c> of the bytes before the first NUL.</summary>
        private static string NulTerminatedString(ReadOnlySpan<byte> bytes)
        {
            var end = bytes.IndexOf((byte)0);
            return Encoding.UTF8.GetString(end < 0 ? bytes : bytes[..end]);
        }

        /// <summary>GNU base-256 when the first byte's high bit is set, octal otherwise.</summary>
        private static long ParseNumericField(ReadOnlySpan<byte> bytes, string field)
        {
            if (bytes.IsEmpty) throw Corrupt("empty numeric field " + field);
            if ((bytes[0] & 0x80) != 0)
            {
                long base256 = bytes[0] & 0x7f;
                foreach (var b in bytes[1..])
                {
                    if (base256 > long.MaxValue >> 8) throw Corrupt("numeric overflow in " + field);
                    base256 = base256 << 8 | b;
                }
                return base256;
            }
            long value = 0;
            var seenDigit = false;
            foreach (var b in bytes)
            {
                if (b is 0x20 or 0)
                {
                    if (seenDigit) break;
                    continue;
                }
                if (b is < 0x30 or > 0x37) throw Corrupt("invalid octal digit in " + field);
                if (value > (long.MaxValue - 7) / 8) throw Corrupt("numeric overflow in " + field);
                seenDigit = true;
                value = value * 8 + (b - 0x30);
            }
            return value;
        }
    }
}

/// <summary>
/// macOS <c>RockchipImageArchiveIntrospection.StreamingValueScanner</c>: the first run of value
/// bytes after a key, found across any number of chunks, since the decoder owes nobody a chunk
/// boundary. A run longer than 256 bytes is noise, not a value, and the search resumes after it.
/// </summary>
public sealed class FlashValueScanner(string key)
{
    private readonly byte[] key = Encoding.UTF8.GetBytes(key);
    private readonly List<byte> value = [];
    private int matched;
    private bool collecting;

    /// <summary>The value once its run ends, null while more input is needed.</summary>
    public string? Consume(ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes)
        {
            if (collecting)
            {
                if (IsValueByte(b))
                {
                    value.Add(b);
                    if (value.Count > 256)
                    {
                        collecting = false;
                        value.Clear();
                        matched = 0;
                    }
                    continue;
                }
                collecting = false;
                if (value.Count > 0) return Encoding.UTF8.GetString([.. value]);
                matched = 0;
                continue;
            }
            if (b == key[matched])
            {
                matched++;
                if (matched == key.Length)
                {
                    collecting = true;
                    value.Clear();
                    matched = 0;
                }
            }
            else
            {
                // Restart, the mismatched byte allowed to open a new match.
                matched = b == key[0] ? 1 : 0;
            }
        }
        return null;
    }

    /// <summary>Version values are ASCII words: letters, digits, dot, dash, underscore.</summary>
    public static bool IsValueByte(byte b) =>
        b is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A or >= 0x61 and <= 0x7A or 0x2E or 0x2D or 0x5F;
}

/// <summary>Swift <c>String</c> semantics the macOS reader relies on: Characters are extended
/// grapheme clusters, equality is canonical equivalence, ordering is by the NFC scalars, and an
/// error payload is interpolated as <c>debugDescription</c>.</summary>
internal static class SwiftText
{
    public static IEqualityComparer<string> Comparer { get; } = new CanonicalComparer();

    public static IComparer<string> Order { get; } = Comparer<string>.Create((a, b) =>
        Encoding.UTF8.GetBytes(Nfc(a)).AsSpan().SequenceCompareTo(Encoding.UTF8.GetBytes(Nfc(b))));

    public static bool Equal(string a, string b) => string.Equals(Nfc(a), Nfc(b), StringComparison.Ordinal);

    private static string Nfc(string text) => text.IsNormalized(NormalizationForm.FormC) ? text : text.Normalize(NormalizationForm.FormC);

    public static List<string> Characters(string text)
    {
        var characters = new List<string>();
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext()) characters.Add(elements.GetTextElement());
        return characters;
    }

    /// <summary>Foundation's <c>trimmingCharacters(in: .whitespaces)</c>: space separators and tab.</summary>
    public static string TrimWhitespace(string text)
    {
        static bool IsWhitespace(Rune rune) => rune.Value == '\t' || Rune.GetUnicodeCategory(rune) == UnicodeCategory.SpaceSeparator;
        var runes = text.EnumerateRunes().ToList();
        var start = 0;
        var end = runes.Count;
        while (start < end && IsWhitespace(runes[start])) start++;
        while (end > start && IsWhitespace(runes[end - 1])) end--;
        return string.Concat(runes.Skip(start).Take(end - start).Select(r => r.ToString()));
    }

    /// <summary>Swift's <c>String.debugDescription</c>: <c>\0 \t \n \r \" \' \\</c>, other ASCII
    /// controls as <c>\u{XX}</c>, anything else as itself unless it would make one Character with
    /// the quote or an escape beside it.</summary>
    public static string Quoted(string text)
    {
        var quoted = new StringBuilder("\"");
        var afterEscape = true;
        string? last = "\"";
        foreach (var rune in text.EnumerateRunes())
        {
            if (AsciiEscape(rune) is { } escape)
            {
                quoted.Append(escape);
                afterEscape = true;
                last = escape[^1..];
            }
            else if (afterEscape && Joins(last, rune.ToString()))
            {
                var unicode = UnicodeEscape(rune);
                quoted.Append(unicode);
                last = "}";
            }
            else
            {
                quoted.Append(rune.ToString());
                afterEscape = false;
                last = rune.ToString();
            }
        }
        // Nor may the last scalar left as itself join what follows it: the closing quote, then
        // the escape that took its successor's place.
        var runes = quoted.ToString().EnumerateRunes().ToList();
        var tail = new StringBuilder();
        var next = "\"";
        while (runes.Count > 0 && Joins(runes[^1].ToString(), next))
        {
            tail.Insert(0, UnicodeEscape(runes[^1]));
            runes.RemoveAt(runes.Count - 1);
            next = "\\";
        }
        return string.Concat(runes.Select(r => r.ToString())) + tail + "\"";
    }

    private static string? AsciiEscape(Rune rune) => rune.Value switch
    {
        '\\' => "\\\\",
        '\'' => "\\'",
        '"' => "\\\"",
        >= ' ' and <= '~' => null,
        0 => "\\0",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        < 0x80 => $"\\u{{{rune.Value:X2}}}",
        _ => null,
    };

    private static string UnicodeEscape(Rune rune) =>
        rune.Value <= 0xFFFF ? $"\\u{{{rune.Value:X4}}}" : $"\\u{{{rune.Value:X8}}}";

    private static bool Joins(string? left, string right) =>
        left is not null && new StringInfo(left + right).LengthInTextElements == 1;

    private sealed class CanonicalComparer : IEqualityComparer<string>
    {
        public bool Equals(string? x, string? y) => x is null || y is null ? ReferenceEquals(x, y) : Equal(x, y);

        public int GetHashCode(string obj) => StringComparer.Ordinal.GetHashCode(Nfc(obj));
    }
}
