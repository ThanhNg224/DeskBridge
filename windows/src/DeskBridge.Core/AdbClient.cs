using System.Diagnostics;
using System.Globalization;

namespace DeskBridge.Core;

public record AdbDevice(string Serial, string State, string Description);
public record ProcessResult(int ExitCode, string Output);
public interface IRunningProcess : IAsyncDisposable { bool HasExited { get; } }
public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, CancellationToken cancellationToken);
    IRunningProcess Start(string executable, IReadOnlyList<string> arguments);
}
public sealed class ProcessRunner : IProcessRunner
{
    private static ProcessStartInfo Info(string executable, IReadOnlyList<string> arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        return info;
    }
    public async Task<ProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var process = new Process { StartInfo = Info(executable, arguments) };
        process.Start();
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            catch (AggregateException) { /* A descendant may already be exiting. */ }
        });
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await Task.WhenAny(process.WaitForExitAsync(), Task.Delay(TimeSpan.FromSeconds(5))).ConfigureAwait(false);
            await ObserveDrainAsync(output).ConfigureAwait(false);
            await ObserveDrainAsync(error).ConfigureAwait(false);
            throw;
        }
        // Never propagate arbitrary adb/server output: it can contain session credentials.
        await error.ConfigureAwait(false);
        return new(process.ExitCode, await output.ConfigureAwait(false));
    }

    private static async Task ObserveDrainAsync(Task<string> drain)
    {
        try { await drain.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }
    public IRunningProcess Start(string executable, IReadOnlyList<string> arguments)
    {
        var process = new Process { StartInfo = Info(executable, arguments) };
        process.Start();
        // Drain both streams without retaining or logging input/session data.
        _ = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null);
        _ = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
        return new Running(process);
    }
    private sealed class Running(Process process) : IRunningProcess
    {
        public bool HasExited => process.HasExited;
        public async ValueTask DisposeAsync()
        {
            try { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync().ConfigureAwait(false); }
            finally { process.Dispose(); }
        }
    }
}
public sealed class AdbClient(string executable, IProcessRunner runner, TimeSpan? commandTimeout = null)
{
    private readonly TimeSpan commandTimeout = commandTimeout ?? TimeSpan.FromSeconds(8);
    public AdbClient(string executable) : this(executable, new ProcessRunner()) { }
    private const string RemoteJar = "/data/local/tmp/deskbridge-server.jar";
    internal async Task<string> RunAsync(CancellationToken ct, params string[] arguments)
    {
        ct.ThrowIfCancellationRequested();
        using var timeout = new CancellationTokenSource(commandTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token);
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(executable, arguments, linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && timeout.IsCancellationRequested)
        {
            throw new TimeoutException("ADB command timed out.");
        }
        if (result.ExitCode != 0) throw new IOException("ADB command failed. Check the device connection and authorization.");
        return result.Output;
    }
    public async Task<IReadOnlyList<AdbDevice>> ListDevicesAsync(CancellationToken cancellationToken = default) => ParseDevices(await RunAsync(cancellationToken, "devices", "-l").ConfigureAwait(false));
    public static IReadOnlyList<AdbDevice> ParseDevices(string output)
    {
        List<AdbDevice> devices = [];
        foreach (var line in output.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.StartsWith('*') || line.StartsWith("List of devices", StringComparison.Ordinal)) continue;
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            string? model = parts.Skip(2).FirstOrDefault(x => x.StartsWith("model:", StringComparison.Ordinal));
            devices.Add(new(parts[0], parts[1], model is null ? parts[0] : model[6..].Replace('_', ' ')));
        }
        return devices;
    }
    public static string WifiTarget(string host, int port)
    {
        string[] parts = host.Trim().Split('.');
        if (parts.Length != 4 || parts.Any(p => p.Length == 0 || p.Any(c => c is < '0' or > '9') || !byte.TryParse(p, out _))) throw new ArgumentException("Enter a valid IPv4 address.", nameof(host));
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port), "Port must be between 1 and 65535.");
        return string.Join('.', parts.Select(p => byte.Parse(p, CultureInfo.InvariantCulture))) + ":" + port.ToString(CultureInfo.InvariantCulture);
    }
    public async Task<string> ConnectWifiAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        string target = WifiTarget(host, port);
        string output = await RunAsync(cancellationToken, "connect", target).ConfigureAwait(false);
        if (!(output.Contains("connected to", StringComparison.OrdinalIgnoreCase) || output.Contains("already connected", StringComparison.OrdinalIgnoreCase)) || output.Contains("failed", StringComparison.OrdinalIgnoreCase) || output.Contains("unable", StringComparison.OrdinalIgnoreCase)) throw new IOException("ADB could not connect over Wi-Fi.");
        var devices = await ListDevicesAsync(cancellationToken).ConfigureAwait(false);
        if (!devices.Any(d => d.Serial == target && d.State == "device")) throw new IOException("Wireless device is not ready or authorized.");
        return target;
    }
    public async Task DisconnectWifiAsync(string serial, CancellationToken cancellationToken = default)
    {
        if (!IsWirelessSerial(serial)) throw new ArgumentException("Select a wireless device.", nameof(serial));
        await RunAsync(cancellationToken, "disconnect", serial).ConfigureAwait(false);
    }
    public static bool IsWirelessSerial(string serial) => serial.Contains(':') ||
        serial.TrimEnd('.').EndsWith("_adb-tls-connect._tcp", StringComparison.Ordinal) ||
        serial.TrimEnd('.').EndsWith("_adb._tcp", StringComparison.Ordinal);
    public static string? ParseWifiAddress(string output)
    {
        foreach (var line in output.Split('\n'))
        {
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            int dev = Array.IndexOf(parts, "dev"), src = Array.IndexOf(parts, "src");
            string? address = dev >= 0 && dev + 1 < parts.Length && parts[dev + 1] == "wlan0" && src >= 0 && src + 1 < parts.Length ? parts[src + 1] : parts.Length > 1 && parts[0] == "inet" && parts.Contains("wlan0") ? parts[1].Split('/')[0] : null;
            if (address is null) continue;
            try { return WifiTarget(address, 5555).Split(':')[0]; } catch (ArgumentException) { }
        }
        return null;
    }
    public async Task<string> SwitchToWifiAsync(string usbSerial, CancellationToken cancellationToken = default)
    {
        if (IsWirelessSerial(usbSerial) || !(await ListDevicesAsync(cancellationToken).ConfigureAwait(false)).Any(d => d.Serial == usbSerial && d.State == "device")) throw new InvalidOperationException("Select a ready USB device.");
        string? ip = ParseWifiAddress(await RunAsync(cancellationToken, "-s", usbSerial, "shell", "ip", "route").ConfigureAwait(false));
        ip ??= ParseWifiAddress(await RunAsync(cancellationToken, "-s", usbSerial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0").ConfigureAwait(false));
        if (ip is null) throw new IOException("No Wi-Fi IPv4 address found on the device.");
        await RunAsync(cancellationToken, "-s", usbSerial, "tcpip", "5555").ConfigureAwait(false);
        await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        return await ConnectWifiAsync(ip, 5555, cancellationToken).ConfigureAwait(false);
    }
    public async Task<IServerLease> LaunchServerAsync(string serial, string jar, CancellationToken cancellationToken)
    {
        string token = ProtocolEncoder.MakeToken(), socket = "deskbridge-" + ProtocolEncoder.MakeToken()[..8];
        await RunAsync(cancellationToken, "-s", serial, "push", jar, RemoteJar).ConfigureAwait(false);
        string output = await RunAsync(cancellationToken, "-s", serial, "forward", "tcp:0", "localabstract:" + socket).ConfigureAwait(false);
        if (!int.TryParse(output.Trim(), out int port) || port is < 1 or > 65535) throw new IOException("ADB returned an invalid forward port.");
        try
        {
            // All shell tokens are constants or internally generated lowercase hexadecimal.
            var process = runner.Start(executable, ["-s", serial, "shell", $"CLASSPATH={RemoteJar} exec app_process / com.deskbridge.server.ServerMain {socket} {token}"]);
            return new ServerLease(this, serial, port, token, process);
        }
        catch
        {
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await RunAsync(cleanup.Token, "-s", serial, "forward", "--remove", "tcp:" + port).ConfigureAwait(false);
            throw;
        }
    }
    private sealed class ServerLease(AdbClient adb, string serial, int port, string token, IRunningProcess process) : IServerLease
    {
        public int Port => port;
        public string Token => token;
        public bool HasExited => process.HasExited;
        private int disposed;
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try { await process.DisposeAsync().ConfigureAwait(false); }
            finally
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await adb.RunAsync(timeout.Token, "-s", serial, "forward", "--remove", "tcp:" + port).ConfigureAwait(false);
            }
        }
    }
}
public interface IServerLease : IAsyncDisposable { int Port { get; } string Token { get; } bool HasExited { get; } }
