using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal static class ManagedAdb
{
    internal static string Root => Path.Combine(SettingsStore.DirectoryPath, "platform-tools");
    internal static bool IsManaged(string path)
    {
        if (!Path.IsPathFullyQualified(path)) return false;
        string prefix = Path.GetFullPath(Root) + Path.DirectorySeparatorChar;
        return Path.GetFullPath(path).StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }
    internal static AdbClient Client(string path) => IsManaged(path)
        ? new AdbClient(path, new ProcessRunner(), guard: ct => EnsureCompatibleAsync(path, ct))
        : new AdbClient(path);

    internal static bool ExistingAdb(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        if (Path.IsPathFullyQualified(path) || path.Contains(Path.DirectorySeparatorChar) || path.Contains(Path.AltDirectorySeparatorChar))
            return File.Exists(path);
        string name = Path.HasExtension(path) ? path : path + ".exe";
        if (File.Exists(Path.Combine(AppContext.BaseDirectory, name)) || File.Exists(Path.Combine(Environment.CurrentDirectory, name))) return true;
        return (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(dir => File.Exists(Path.Combine(dir.Trim('"'), name)));
    }

    /// Authenticode verification is performed by Windows; the ZIP's own metadata is never trusted.
    internal static async Task VerifyGoogleAsync(string file, CancellationToken ct)
    {
        const string script = "$s=Get-AuthenticodeSignature -LiteralPath $env:DESKBRIDGE_VERIFY_FILE; " +
            "if ($s.Status -ne 'Valid' -or $null -eq $s.SignerCertificate -or " +
            "$s.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne 'Google LLC' -or " +
            "$s.SignerCertificate.Subject -notmatch '(?:^|,\\s*)O=Google LLC(?:,|$)') { exit 1 }";
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        var info = new ProcessStartInfo(powershell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        info.ArgumentList.Add("-NoProfile"); info.ArgumentList.Add("-NonInteractive"); info.ArgumentList.Add("-EncodedCommand");
        info.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
        info.Environment["DESKBRIDGE_VERIFY_FILE"] = file;
        using var process = Process.Start(info) ?? throw new InvalidDataException("Could not verify Android tools.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { try { process.Kill(true); } catch (InvalidOperationException) { } throw; }
        if (process.ExitCode != 0) throw new InvalidDataException("Could not verify the Android tools signature. Download the ZIP from Google.");
    }

    internal static async Task EnsureCompatibleAsync(string adb, CancellationToken ct)
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET")))
            throw new InvalidOperationException("The existing Android tools use an unsupported server. Close the other tools and try again.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        var result = await new ProcessRunner().RunAsync(adb, ["version"], timeout.Token).ConfigureAwait(false);
        var line = result.Output.Split('\n').FirstOrDefault();
        const string prefix = "Android Debug Bridge version 1.0.";
        if (result.ExitCode != 0 || line is null || !line.StartsWith(prefix, StringComparison.Ordinal) ||
            !int.TryParse(line[prefix.Length..].Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out int clientVersion))
            throw new InvalidDataException("Could not read the Android tools version.");
        int port = int.TryParse(Environment.GetEnvironmentVariable("ANDROID_ADB_SERVER_PORT"), out var configured) && configured is > 0 and <= 65535 ? configured : 5037;
        using var socket = new TcpClient();
        try { await socket.ConnectAsync(IPAddress.Loopback, port, timeout.Token).ConfigureAwait(false); }
        catch (SocketException e) when (e.SocketErrorCode == SocketError.ConnectionRefused) { return; }
        using var stream = socket.GetStream();
        await stream.WriteAsync("000chost:version"u8.ToArray(), timeout.Token).ConfigureAwait(false);
        byte[] response = new byte[12];
        await stream.ReadExactlyAsync(response, timeout.Token).ConfigureAwait(false);
        if (Encoding.ASCII.GetString(response, 0, 8) != "OKAY0004" ||
            !int.TryParse(Encoding.ASCII.GetString(response, 8, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int serverVersion) || serverVersion != clientVersion)
            throw new InvalidOperationException("The existing Android tools are incompatible. Close the other tools and try again.");
    }
}
