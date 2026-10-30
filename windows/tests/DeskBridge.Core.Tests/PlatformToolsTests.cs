using System.IO.Compression;
using DeskBridge.Core;
using Xunit;

namespace DeskBridge.Core.Tests;

public sealed class PlatformToolsTests
{
    private static byte[] Pe(int machine = 0x8664)
    {
        var bytes = new byte[128]; bytes[0] = 0x4D; bytes[1] = 0x5A; bytes[0x3c] = 64;
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = (byte)machine; bytes[69] = (byte)(machine >> 8);
        return bytes;
    }
    private static void Add(ZipArchive zip, string name, byte[] content)
    {
        using var stream = zip.CreateEntry(name).Open(); stream.Write(content);
    }
    private static string Archive(string dir, bool traversal = false, bool wrongArch = false, bool duplicate = false)
    {
        string path = Path.Combine(dir, Guid.NewGuid() + ".zip");
        using var stream = File.Create(path); using var zip = new ZipArchive(stream, ZipArchiveMode.Create);
        Add(zip, "platform-tools/adb.exe", Pe(wrongArch ? 0x14c : 0x8664));
        Add(zip, "platform-tools/AdbWinApi.dll", Pe()); Add(zip, "platform-tools/AdbWinUsbApi.dll", Pe());
        if (traversal) Add(zip, "../escape", [1]);
        if (duplicate) Add(zip, "platform-tools/adb.exe", Pe());
        return path;
    }
    [Fact]
    public async Task ExtractsOnlyValidatedFilesAndKeepsOldInstallOnFailure()
    {
        string dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")); Directory.CreateDirectory(dir);
        try
        {
            string root = Path.Combine(dir, "managed"); string zip = Archive(dir);
            var verified = new List<string>();
            string path = await PlatformToolsArchive.InstallAsync(zip, root, (file, _) => { verified.Add(Path.GetFileName(file)); return Task.CompletedTask; }, (_, _) => Task.CompletedTask);
            Assert.Equal(3, verified.Count); Assert.True(File.Exists(path));
            foreach (var bad in new[] { Archive(dir, traversal: true), Archive(dir, wrongArch: true), Archive(dir, duplicate: true) })
            {
                await Assert.ThrowsAsync<InvalidDataException>(() => PlatformToolsArchive.InstallAsync(bad, root, (_, _) => Task.CompletedTask, (_, _) => Task.CompletedTask));
                Assert.True(File.Exists(path));
            }
            await Assert.ThrowsAsync<InvalidDataException>(() => PlatformToolsArchive.InstallAsync(zip, root, (_, _) => throw new InvalidDataException(), (_, _) => Task.CompletedTask));
            Assert.True(File.Exists(path)); Assert.Empty(Directory.GetDirectories(root, ".install-*"));
        }
        finally { Directory.Delete(dir, true); }
    }
    [Fact]
    public void UpdatesSelectOnlyNewStableWindowsVersions()
    {
        const string json = """
        [{"tag_name":"v9.0.0","draft":false,"prerelease":false},
         {"tag_name":"windows-v0.2.0","draft":false,"prerelease":false},
         {"tag_name":"windows-v0.10.0","draft":false,"prerelease":false},
         {"tag_name":"windows-v9.0.0","draft":false,"prerelease":true},
         {"tag_name":"windows-v9.0.0/evil","draft":false,"prerelease":false}]
        """;
        Assert.Equal("https://github.com/ThanhNg224/DeskBridge/releases/tag/windows-v0.10.0", ReleaseChecker.NewerWindowsRelease(json, "0.1.0")?.AbsoluteUri);
        Assert.Null(ReleaseChecker.NewerWindowsRelease(json, "0.10.0"));
        const string stable = "[{\"tag_name\":\"windows-v0.1.0\",\"draft\":false,\"prerelease\":false}]";
        Assert.NotNull(ReleaseChecker.NewerWindowsRelease(stable, "0.1.0-alpha.1+build"));
        Assert.Null(ReleaseChecker.NewerWindowsRelease(stable, "0.1.0+build"));
    }
}
