using System.IO.Compression;

namespace DeskBridge.Core;

/// Extracts only the three Windows ADB binaries into a new private installation directory.
public static class PlatformToolsArchive
{
    private const long MaxArchive = 128L * 1024 * 1024, MaxEntry = 64L * 1024 * 1024, MaxTotal = 512L * 1024 * 1024;
    private static readonly string[] Required = ["adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll"];

    private static void ValidateX64(string file)
    {
        using var stream = File.OpenRead(file); using var reader = new BinaryReader(stream);
        if (stream.Length < 64 || reader.ReadUInt16() != 0x5A4D) throw new InvalidDataException("Android tool is not a Windows executable.");
        stream.Position = 0x3C; int offset = reader.ReadInt32();
        if (offset < 64 || offset > stream.Length - 6) throw new InvalidDataException("Invalid Windows executable.");
        stream.Position = offset;
        if (reader.ReadUInt32() != 0x00004550 || reader.ReadUInt16() != 0x8664)
            throw new InvalidDataException("Android tools must be for Windows x64.");
    }

    public static async Task<string> InstallAsync(string zipPath, string root,
        Func<string, CancellationToken, Task> verify, Func<string, CancellationToken, Task> checkServer,
        CancellationToken ct = default)
    {
        var source = new FileInfo(zipPath);
        if (!source.Exists || source.Length is <= 0 or > MaxArchive || (source.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Invalid Platform Tools ZIP.");
        Directory.CreateDirectory(root);
        string stage = Path.Combine(root, ".install-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            using var stream = source.OpenRead();
            using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
            Dictionary<string, ZipArchiveEntry> selected = new(StringComparer.Ordinal);
            long total = 0;
            if (archive.Entries.Count > 1000) throw new InvalidDataException("Invalid Platform Tools ZIP.");
            foreach (var entry in archive.Entries)
            {
                var path = entry.FullName;
                int unixType = (entry.ExternalAttributes >> 16) & 0xF000;
                if (path.StartsWith('/') || path.Contains('\\') || path.Contains(':') || path.Contains('\0') ||
                    path.Split('/').Any(part => part is "." or "..") || unixType == 0xA000 ||
                    (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0 ||
                    entry.Length < 0 || entry.Length > MaxEntry || total > MaxTotal - entry.Length)
                    throw new InvalidDataException("Invalid Platform Tools ZIP.");
                total += entry.Length;
                foreach (string name in Required)
                    if (path == "platform-tools/" + name && !selected.TryAdd(name, entry))
                        throw new InvalidDataException("Duplicate Platform Tools entry.");
            }
            if (selected.Count != Required.Length) throw new InvalidDataException("Platform Tools ZIP is missing ADB files.");
            foreach (string name in Required)
            {
                ct.ThrowIfCancellationRequested();
                var entry = selected[name];
                if (entry.Length <= 0) throw new InvalidDataException("Empty ADB file.");
                string output = Path.Combine(stage, name);
                await using var input = entry.Open();
                await using var destination = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                var buffer = new byte[65536]; long written = 0; int count;
                while ((count = await input.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
                {
                    written += count;
                    if (written > entry.Length || written > MaxEntry) throw new InvalidDataException("ADB file exceeds its declared size.");
                    await destination.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
                }
                if (written != entry.Length) throw new InvalidDataException("ADB file is truncated.");
            }
            foreach (string name in Required)
            {
                string file = Path.Combine(stage, name);
                ValidateX64(file);
                await verify(file, ct).ConfigureAwait(false);
            }
            string adb = Path.Combine(stage, "adb.exe");
            await checkServer(adb, ct).ConfigureAwait(false);
            string destinationDir = Path.Combine(root, "tools-" + Guid.NewGuid().ToString("N"));
            Directory.Move(stage, destinationDir);
            return Path.Combine(destinationDir, "adb.exe");
        }
        finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
    }
}
