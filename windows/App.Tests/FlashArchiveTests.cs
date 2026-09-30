using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ArkDeck.App.Core.Presentation;

namespace ArkDeck.App.Tests;

/// <summary>
/// The DAYU200 flash bundle read as macOS reads it (FlashArchive). The Swift oracle
/// <c>rust/tests/fixtures/flash-archive/oracle/cases.json</c> (recorded by
/// <c>FlashBundleArchiveOracleContractTests</c> over the archives <c>make-archives.py</c> wrote,
/// and replayed by the Rust port too) is replayed step by step: the summary, the build, the
/// board's fit and the Import policy's answer must be Swift's for every archive.
/// </summary>
[TestClass]
public sealed class FlashArchiveTests
{
    private static string Archives => RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "archives");

    private static string Archive(string name) => Path.Combine(Archives, name);

    [TestMethod]
    public void EveryOracleArchiveReadsAsSwiftReadsIt()
    {
        using var oracle = JsonDocument.Parse(File.ReadAllBytes(RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "oracle", "cases.json")));
        var cases = oracle.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.AreEqual(41, cases.Count);
        var board = FlashBoard.Dayu200;
        var mismatches = new List<string>();
        foreach (var @case in cases)
        {
            var name = @case.GetProperty("archive").GetString()!;
            // The path an error quotes is `/`-joined, as the oracle records it.
            var path = Archives + "/" + name;

            FlashArchiveSummary? summary = null;
            JsonNode? summaryAnswer;
            try
            {
                summary = FlashArchive.Summarize(path, board.DerivationRequest());
                summaryAnswer = SummaryJson(summary);
            }
            catch (FlashArchiveException failure)
            {
                summaryAnswer = Failure(failure.Description);
            }

            FlashBuildDescriptor? build = null;
            JsonNode? buildAnswer = null;
            if (summary is not null)
            {
                try
                {
                    build = FlashArchive.Describe(summary, board);
                    buildAnswer = BuildJson(build);
                }
                catch (FlashArchiveException failure)
                {
                    buildAnswer = Failure(failure.Description);
                }
            }

            JsonNode? profileAnswer = null;
            if (build is not null)
            {
                try
                {
                    var profile = board.ForBuild(build);
                    profileAnswer = new JsonObject
                    {
                        ["archiveSizeBytes"] = profile.ArchiveSizeBytes,
                        ["archiveSha256"] = profile.ArchiveSha256,
                        ["firmwareVersion"] = profile.FirmwareVersion,
                        ["runtimeBuildVersion"] = profile.RuntimeBuildVersion,
                        ["writeForbiddenMemberNames"] = new JsonArray([.. profile.WriteForbiddenMemberNames.Select(n => (JsonNode?)n)]),
                    };
                }
                catch (FlashArchiveException failure)
                {
                    profileAnswer = Failure(failure.Description);
                }
            }

            var verdict = FlashArchive.ValidateForImport(path);
            JsonNode policyAnswer = verdict.Error is { } error
                ? Failure(error)
                : new JsonObject { ["byteCount"] = verdict.ByteCount, ["sha256"] = verdict.Sha256 };

            Compare(mismatches, name, "summary", summaryAnswer, @case.GetProperty("summary"));
            Compare(mismatches, name, "build", buildAnswer, @case.GetProperty("build"));
            Compare(mismatches, name, "profile", profileAnswer, @case.GetProperty("profile"));
            Compare(mismatches, name, "importPolicy", policyAnswer, @case.GetProperty("importPolicy"));
        }
        Assert.AreEqual(0, mismatches.Count, string.Join("\n", mismatches));
    }

    private static void Compare(List<string> mismatches, string archive, string field, JsonNode? actual, JsonElement expected)
    {
        var mine = JsonNode.Parse(actual?.ToJsonString() ?? "null");
        var swift = JsonNode.Parse(expected.GetRawText());
        if (!JsonNode.DeepEquals(mine, swift))
        {
            mismatches.Add($"{archive} {field}: expected {swift?.ToJsonString() ?? "null"}, got {mine?.ToJsonString() ?? "null"}");
        }
    }

    /// <summary>A refusal with the archives' directory in the oracle's placeholder, spelled also
    /// with the backslashes Swift's quoting doubles.</summary>
    private static JsonObject Failure(string error) =>
        new() { ["error"] = error.Replace(Archives.Replace("\\", "\\\\"), "<archives>").Replace(Archives, "<archives>") };

    private static JsonObject SummaryJson(FlashArchiveSummary summary)
    {
        var captured = new JsonObject();
        foreach (var (name, bytes) in summary.CapturedMembers)
        {
            captured[name] = new JsonObject
            {
                ["byteCount"] = bytes.Length,
                ["sha256"] = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes)),
            };
        }
        return new JsonObject
        {
            ["archiveSizeBytes"] = summary.ArchiveSizeBytes,
            ["archiveSha256"] = summary.ArchiveSha256,
            ["members"] = new JsonArray([.. summary.Members.Select(m => (JsonNode?)new JsonObject
            {
                ["name"] = m.Name,
                ["sizeBytes"] = m.SizeBytes,
                ["sha256"] = m.Sha256,
            })]),
            ["captured"] = captured,
            ["scannedValue"] = summary.ScannedValue,
        };
    }

    private static JsonObject BuildJson(FlashBuildDescriptor build) => new()
    {
        ["archiveSizeBytes"] = build.ArchiveSizeBytes,
        ["archiveSha256"] = build.ArchiveSha256,
        ["runtimeBuildVersion"] = build.RuntimeBuildVersion,
        ["declaredPartitions"] = new JsonArray([.. build.DeclaredPartitions.Select(p => (JsonNode?)new JsonObject
        {
            ["name"] = p.Name,
            ["sizeSectors"] = p.SizeSectors,
            ["offsetSectors"] = p.OffsetSectors,
        })]),
        ["members"] = new JsonArray([.. build.Members.Select(m => (JsonNode?)new JsonObject
        {
            ["name"] = m.Name,
            ["classification"] = m.ClassificationRawValue,
        })]),
    };

    [TestMethod]
    public void ACompleteArchiveReviewsIntoTheFlashPagesFacts()
    {
        var path = Archive("complete.tar.gz");
        var review = FlashArchive.Review(path);
        Assert.IsNull(review.FailureCode, review.FailureDetail);
        var reviewed = review.Reviewed!;
        var summary = FlashArchive.Summarize(path);

        Assert.AreEqual("dayu200", reviewed.ProfileReference);
        Assert.AreEqual("complete.tar.gz", reviewed.ImageFileName);
        Assert.AreEqual("OpenHarmony-7.0.0.36", reviewed.RuntimeBuildVersion);
        Assert.AreEqual(new FileInfo(path).Length, reviewed.ArchiveSizeBytes);
        Assert.AreEqual(summary.ArchiveSha256, reviewed.ArchiveSha256);
        Assert.AreEqual(9, reviewed.MappedPartitionCount);
        CollectionAssert.AreEqual(
            new[] { "uboot", "resource", "boot_linux", "ramdisk", "system", "vendor", "updater", "chip_ckm", "userdata" },
            reviewed.Partitions.Select(p => p.PartitionName).ToArray());
        CollectionAssert.AreEqual(Enumerable.Range(1, 9).ToArray(), reviewed.Partitions.Select(p => p.WriteOrder).ToArray());
        foreach (var row in reviewed.Partitions)
        {
            var member = summary.Members.Single(m => m.Name == row.ImageMemberName);
            Assert.AreEqual(member.SizeBytes, row.ImageSizeBytes, row.ImageMemberName);
            Assert.AreEqual(member.Sha256, row.ImageSha256, row.ImageMemberName);
        }
        CollectionAssert.AreEqual(new[] { "chip_prod.img", "sys_prod.img" }, reviewed.WriteForbiddenMemberNames.ToArray());
        CollectionAssert.AreEqual(
            new[] { new FlashDataImpact(FlashDataImpactKind.MappedPartitionsOverwritten, 9), new FlashDataImpact(FlashDataImpactKind.UserDataDestroyed), new FlashDataImpact(FlashDataImpactKind.ForbiddenAreasPreserved) },
            reviewed.DataImpact.ToArray());
        Assert.IsTrue(reviewed.UserDataDestroyed);
        CollectionAssert.AreEqual(new[] { "loader", "recoveryPath", "unlocked", "stablePower" }, reviewed.Prerequisites.Select(p => p.Identifier).ToArray());
    }

    [TestMethod]
    public void ReviewFailuresAreClassifiedAsTheMacOSFacadeClassifiesThem()
    {
        void Expect(string path, FlashReviewFailureCode code, string? detail, string profile = "dayu200")
        {
            var review = FlashArchive.Review(path, profile);
            Assert.IsNull(review.Reviewed, path);
            Assert.AreEqual(code, review.FailureCode, path);
            Assert.AreEqual(detail, review.FailureDetail, path);
        }

        Expect(Archive("plain.tar"), FlashReviewFailureCode.UnsupportedArchiveFormat, null);
        Expect(Archive("method-7.tar.gz"), FlashReviewFailureCode.InvalidArchive, "unsupportedCompressionMethod");
        Expect(Archive("truncated-deflate.tar.gz"), FlashReviewFailureCode.InvalidArchive, "decompressionFailed");
        Expect(Archive("truncated-tar.tar.gz"), FlashReviewFailureCode.InvalidArchive, "truncatedArchive");
        Expect(Archive("bad-checksum.tar.gz"), FlashReviewFailureCode.InvalidArchive, "corruptTarHeader(\"header checksum mismatch\")");
        Expect(Archive("empty.gz"), FlashReviewFailureCode.UnsupportedArchiveFormat, null);
        var folder = Directory.CreateTempSubdirectory("arkdeck-flash-");
        try
        {
            Expect(Directory.CreateDirectory(Path.Combine(folder.FullName, "folder.tar.gz")).FullName, FlashReviewFailureCode.UnreadableArchive, null);
        }
        finally
        {
            folder.Delete(recursive: true);
        }
        Expect(Archive("no-parameter.tar.gz"), FlashReviewFailureCode.UnsupportedBundle, "partitionTableMissing");
        Expect(Archive("no-system-image.tar.gz"), FlashReviewFailureCode.UnsupportedBundle, "systemImageMissing(\"system\")");
        Expect(Archive("nonconforming.tar.gz"), FlashReviewFailureCode.PlanMaterializationFailed,
            "archiveDoesNotConform(\"flash bundle does not fit dayu200: mappedPartitionImageMissing:vendor; undeclaredPartitionInTable:extra; mappedPartitionAbsentFromTable:updater\")");
        Expect(Archive("duplicate-member.tar.gz"), FlashReviewFailureCode.PlanMaterializationFailed, "invalidProfileDefinition(\"duplicate archive member name\")");
        Expect(Archive("complete.tar.gz"), FlashReviewFailureCode.UnsupportedBundle, "rk3588", "rk3588");
        Expect(Archive("make-archives.py"), FlashReviewFailureCode.UnsupportedArchiveFormat, null);
        Expect(Archive("absent.tar.gz"), FlashReviewFailureCode.FileAccessDenied, null);
    }

    [TestMethod]
    public void TheSelectionPolicyTakesArchiveSuffixesOrArchiveMagic()
    {
        var directory = Directory.CreateTempSubdirectory("arkdeck-flash-");
        try
        {
            string Write(string name, byte[] bytes)
            {
                var path = Path.Combine(directory.FullName, name);
                File.WriteAllBytes(path, bytes);
                return path;
            }

            Assert.IsTrue(FlashArchive.IsSelectable(Path.Combine(directory.FullName, "images.tar.gz")), "a suffix needs no file");
            Assert.IsTrue(FlashArchive.IsSelectable(Path.Combine(directory.FullName, "IMAGES.ZIP")));
            Assert.IsTrue(FlashArchive.IsSelectable(Path.Combine(directory.FullName, "a.7z")));
            Assert.IsFalse(FlashArchive.IsSelectable(Path.Combine(directory.FullName, ".7z")), "a bare suffix is not a name");
            Assert.IsFalse(FlashArchive.IsSelectable(Path.Combine(directory.FullName, "images.tgz")));
            Assert.IsTrue(FlashArchive.IsSelectable(Write("ART-gzip", [0x1F, 0x8B, 0x08])));
            Assert.IsTrue(FlashArchive.IsSelectable(Write("ART-zip", [0x50, 0x4B, 0x05, 0x06])));
            Assert.IsTrue(FlashArchive.IsSelectable(Write("ART-7z", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00])));
            Assert.IsFalse(FlashArchive.IsSelectable(Write("ART-7z-short", [0x37, 0x7A, 0xBC, 0xAF, 0x27])));
            Assert.IsFalse(FlashArchive.IsSelectable(Write("ART-text", "hello"u8.ToArray())));
            Assert.IsFalse(FlashArchive.IsSelectable(Write("ART-empty", [])));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [TestMethod]
    public void TheMtdpartsListIsReadFromTheCommandLine()
    {
        var table = Encoding.UTF8.GetBytes(
            "FIRMWARE_VER: 11.0\nCMDLINE: mtdparts=rk29xxnand:0x00002000@0x00002000(uboot), 0x00030000@0x00008000(boot_linux:bootable),-@0x005b3000(userdata:grow)\nuuid:system=1\n");
        CollectionAssert.AreEqual(
            new[]
            {
                new FlashDeclaredPartition("uboot", 0x2000, 0x2000),
                new FlashDeclaredPartition("boot_linux", 0x30000, 0x8000),
                new FlashDeclaredPartition("userdata", -1, 0x5b3000),
            },
            FlashArchive.Partitions(table).ToArray());

        string Refusal(string text) =>
            Assert.ThrowsExactly<FlashArchiveException>(() => FlashArchive.Partitions(Encoding.UTF8.GetBytes(text))).Description;
        Assert.AreEqual("partitionTableUnparsable(\"no mtdparts\")", Refusal("CMDLINE: console=ttyFIQ0\n"));
        Assert.AreEqual("partitionTableUnparsable(\"no mtdparts\")", Refusal("TYPE: GPT\r\nCMDLINE: mtdparts=x:0x1@0x2(uboot)\r\n"),
            "\\r\\n is one Character, so a CRLF table has no line after the first");
        Assert.AreEqual("partitionTableUnparsable(\"no device prefix\")", Refusal("CMDLINE: mtdparts=0x1@0x2(uboot)\n"));
        Assert.AreEqual("partitionTableUnparsable(\"empty list\")", Refusal("CMDLINE: mtdparts=rk:,,\n"));
        Assert.AreEqual("partitionTableUnparsable(\"+0x2000@-10(uboot)\")", Refusal("CMDLINE: mtdparts=rk:+0x2000@-10(uboot)\n"));
        Assert.AreEqual("partitionTableUnparsable(\"0x1@0x2()\")", Refusal("CMDLINE: mtdparts=rk:0x1@0x2()\n"));
        Assert.AreEqual("partitionTableUnparsable(\"0x11111111111111111@0x2(a)\")", Refusal("CMDLINE: mtdparts=rk:0x11111111111111111@0x2(a)\n"));
        Assert.AreEqual(-16, FlashArchive.Partitions(Encoding.UTF8.GetBytes("CMDLINE: mtdparts=rk:0x1@-10(a)\n"))[0].OffsetSectors,
            "Int64(_:radix: 16) takes a sign");
        Assert.AreEqual("partitionTableUnparsable(\"not UTF-8\")",
            Assert.ThrowsExactly<FlashArchiveException>(() => FlashArchive.Partitions([0x43, 0xFF, 0x0A])).Description);
    }

    [TestMethod]
    public void TheValueScannerFindsAValueAcrossAnyChunkBoundary()
    {
        var stream = Encoding.ASCII.GetBytes("\0\0const.ohos.fullnamX const.ohos.fullname=OpenHarmony-7.0.0.36\nconst.product.model=ohos\n");
        for (var split = 0; split <= stream.Length; split++)
        {
            var scanner = new FlashValueScanner(FlashBoard.RuntimeVersionKey);
            var value = scanner.Consume(stream.AsSpan(0, split)) ?? scanner.Consume(stream.AsSpan(split));
            Assert.AreEqual("OpenHarmony-7.0.0.36", value, $"split at {split}");
        }

        var byByte = new FlashValueScanner(FlashBoard.RuntimeVersionKey);
        string? found = null;
        foreach (var b in stream)
        {
            found ??= byByte.Consume([b]);
        }
        Assert.AreEqual("OpenHarmony-7.0.0.36", found);

        var noise = new FlashValueScanner(FlashBoard.RuntimeVersionKey);
        Assert.IsNull(noise.Consume(Encoding.ASCII.GetBytes("const.ohos.fullname=" + new string('a', 300) + "\n")), "a run over 256 bytes is noise");
        Assert.AreEqual("v2", noise.Consume(Encoding.ASCII.GetBytes("const.ohos.fullname=v2 ")));

        var unterminated = new FlashValueScanner(FlashBoard.RuntimeVersionKey);
        Assert.IsNull(unterminated.Consume(Encoding.ASCII.GetBytes("const.ohos.fullname=OpenHarmony")), "a run still open has not ended");

        Assert.IsTrue(FlashValueScanner.IsValueByte((byte)'_'));
        Assert.IsFalse(FlashValueScanner.IsValueByte((byte)'='));
        Assert.IsFalse(FlashValueScanner.IsValueByte((byte)' '));
    }

    [TestMethod]
    public void MembersAreClassifiedByTheBoardsNamingRule()
    {
        var board = FlashBoard.Dayu200;
        Assert.AreEqual(FlashMemberClassification.PartitionTable, board.Classify("parameter.txt"));
        Assert.AreEqual(FlashMemberClassification.LoaderMaskromBranchOnly, board.Classify("MiniLoaderAll.bin"));
        Assert.AreEqual(FlashMemberClassification.MappedPartitionImage, board.Classify("system.img"));
        Assert.AreEqual(FlashMemberClassification.OrphanImageWriteForbidden, board.Classify("chip_prod.img"));
        Assert.AreEqual(FlashMemberClassification.NonPartitionMetadata, board.Classify("eng_system.img"),
            "the rule spells `_` as `-`, so this names `eng-system`, which the board does not forbid");
        Assert.AreEqual(FlashMemberClassification.NonPartitionMetadata, board.Classify("updater_binary"));
        Assert.AreEqual(FlashMemberClassification.NonPartitionMetadata, board.Classify("other.img"));
    }
}
