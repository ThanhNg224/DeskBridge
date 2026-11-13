using Xunit;
namespace DeskBridge.Core.Tests;
public class AdbTests
{
    [Fact] public void GroupsAndFailsOverOnlyUnambiguousIdentityMatches()
    {
        var usb = new AdbDevice("usb", "device", "Phone", "one");
        var wifi = new AdbDevice("10.0.0.2:5555", "device", "Phone", "one");
        var unknown = new AdbDevice("other", "device", "Phone");
        Assert.Equal(new[] { wifi }, AdbClient.GroupPhones([usb, wifi], wifi.Serial));
        Assert.Equal(2, AdbClient.GroupPhones([usb, wifi, unknown], null).Count);
        Assert.Equal(wifi, AdbClient.Alternate(usb.Serial, "one", [wifi]));
        Assert.Null(AdbClient.Alternate(usb.Serial, null, [wifi]));
        Assert.Null(AdbClient.Alternate(usb.Serial, "one", [wifi, usb with { Serial = "usb2" }]));
    }
    [Theory] [InlineData("")] [InlineData("unknown")] [InlineData("0123456789ABCDEF")] [InlineData("invalid space")]
    public void InvalidPhysicalIdentitiesAreNotMatched(string value) => Assert.Null(AdbClient.PhysicalId(value));
    [Fact] public void PhysicalIdentityIsStableAcrossTransports()
    {
        Assert.Equal(AdbClient.PhysicalId("RF8NA2EZKZK"), AdbClient.PhysicalId("RF8NA2EZKZK\n"));
        Assert.NotNull(AdbClient.PhysicalId("RF8NA2EZKZK"));
    }
    [Fact] public async Task ReadsIdentityOnlyFromReadyTransports()
    {
        var runner = new FakeRunner();
        runner.Outputs.Enqueue("RF8NA2EZKZK\n");
        var adb = new AdbClient("adb", runner);
        var result = await adb.ReadDeviceIdentitiesAsync([new("usb", "device", "Phone"), new("offline", "offline", "Phone")]);
        Assert.Equal(AdbClient.PhysicalId("RF8NA2EZKZK"), result[0].PhysicalId);
        Assert.Null(result[1].PhysicalId);
        Assert.Equal(new[] { "-s", "usb", "shell", "getprop", "ro.serialno" }, Assert.Single(runner.Calls));
    }
    [Fact] public void ParsesDevicesAndModels()
    {
        var devices = AdbClient.ParseDevices("* daemon started successfully *\nList of devices attached\nusb1 device product:p model:Pixel_8 transport_id:1\nusb2 unauthorized\n10.0.0.2:5555 offline\n");
        Assert.Equal(new[] { new AdbDevice("usb1", "device", "Pixel 8"), new AdbDevice("usb2", "unauthorized", "usb2"), new AdbDevice("10.0.0.2:5555", "offline", "10.0.0.2:5555") }, devices);
    }
    [Theory] [InlineData("127.0.0.1;whoami", 5555)] [InlineData("localhost", 5555)] [InlineData("256.1.1.1", 5555)] [InlineData("1.2.3", 5555)] [InlineData("1.2.3.4", 0)] [InlineData("1.2.3.4", 65536)]
    public void RejectsUntrustedEndpoint(string host, int port) => Assert.ThrowsAny<ArgumentException>(() => AdbClient.WifiTarget(host, port));
    [Fact] public void NormalizesIpv4() => Assert.Equal("192.168.1.2:5555", AdbClient.WifiTarget(" 192.168.001.002 ", 5555));
    [Theory] [InlineData("192.168.1.2:5555", true)] [InlineData("adb-phone._adb-tls-connect._tcp", false)] [InlineData("256.1.1.1:5555", false)] [InlineData("192.168.1.2:0", false)]
    public void ReconnectEndpointRequiresIpv4AndValidPort(string serial, bool expected) => Assert.Equal(expected, AdbClient.TryWifiEndpoint(serial, out _, out _));
    [Theory] [InlineData("10.0.0.2:5555", true)] [InlineData("adb-123._adb-tls-connect._tcp", true)] [InlineData("adb-123._adb._tcp.", true)] [InlineData("usb-123", false)]
    public void ClassifiesWirelessSerials(string serial, bool expected) => Assert.Equal(expected, AdbClient.IsWirelessSerial(serial));
    [Theory] [InlineData("default via 192.168.1.1 dev wlan0 src 192.168.1.12", "192.168.1.12")] [InlineData("inet 10.0.0.2/24 brd 10.0.0.255 scope global wlan0", "10.0.0.2")] [InlineData("default dev rmnet0 src 10.0.0.2", null)]
    public void OnlySelectsWifiAddress(string output, string? expected) => Assert.Equal(expected, AdbClient.ParseWifiAddress(output));
    [Fact] public async Task RejectedServerGuardDoesNotLaunchAdb()
    {
        var runner = new FakeRunner();
        var adb = new AdbClient("managed-adb", runner, guard: _ => throw new InvalidOperationException("incompatible"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => adb.ListDevicesAsync());
        Assert.Empty(runner.Calls);
    }
    [Fact] public async Task CommandsUseArgumentListAndWirelessRequiresReadyDevice()
    {
        var runner = new FakeRunner(); runner.Outputs.Enqueue("connected to 10.0.0.2:5555"); runner.Outputs.Enqueue("List of devices attached\n10.0.0.2:5555 device model:Pixel_8");
        var adb = new AdbClient("C:/Program Files/adb.exe", runner);
        Assert.Equal("10.0.0.2:5555", await adb.ConnectWifiAsync("10.0.0.2", 5555));
        Assert.Equal(new[] { "connect", "10.0.0.2:5555" }, runner.Calls[0]);
        Assert.Equal(new[] { "devices", "-l" }, runner.Calls[1]);
        runner.Outputs.Enqueue("connected to 10.0.0.2:5555"); runner.Outputs.Enqueue("10.0.0.2:5555 unauthorized");
        await Assert.ThrowsAsync<IOException>(() => adb.ConnectWifiAsync("10.0.0.2", 5555));
    }
    [Fact] public async Task AdbExitZeroFailureTextIsFailure()
    {
        var runner = new FakeRunner(); runner.Outputs.Enqueue("failed to connect to 10.0.0.2:5555");
        await Assert.ThrowsAsync<IOException>(() => new AdbClient("adb", runner).ConnectWifiAsync("10.0.0.2", 5555));
    }
    [Fact] public async Task LaunchAndDisposeOnlyOwnForwardAndProcess()
    {
        var runner = new FakeRunner(); runner.Outputs.Enqueue(""); runner.Outputs.Enqueue("54321\n");
        var adb = new AdbClient("adb", runner); var server = await adb.LaunchServerAsync("usb", "C:/path with spaces/server.jar", default);
        Assert.Equal(new[] { "-s", "usb", "push", "C:/path with spaces/server.jar", "/data/local/tmp/deskbridge-server.jar" }, runner.Calls[0]);
        Assert.Equal("tcp:0", runner.Calls[1][3]); Assert.StartsWith("localabstract:deskbridge-", runner.Calls[1][4]);
        Assert.Equal(54321, server.Port); Assert.Matches("^[0-9a-f]{32}$", server.Token);
        Assert.Contains("exec app_process / com.deskbridge.server.ServerMain deskbridge-", runner.Calls[2][3]);
        await server.DisposeAsync(); await server.DisposeAsync();
        Assert.True(runner.Process.Disposed); Assert.Equal(new[] { "-s", "usb", "forward", "--remove", "tcp:54321" }, runner.Calls[3]); Assert.Equal(4, runner.Calls.Count);
    }
    [Fact] public async Task FailedSpawnRemovesOwnForward()
    {
        var runner = new FakeRunner { FailStart = true }; runner.Outputs.Enqueue(""); runner.Outputs.Enqueue("12345");
        await Assert.ThrowsAsync<IOException>(() => new AdbClient("adb", runner).LaunchServerAsync("usb", "server.jar", default));
        Assert.Equal(new[] { "-s", "usb", "forward", "--remove", "tcp:12345" }, runner.Calls[^1]);
    }
    [Fact] public async Task UsbToWifiChecksReadyTargetAndUsesScopedArguments()
    {
        var runner = new FakeRunner();
        foreach (var output in new[] { "usb device", "default via 10.0.0.1 dev wlan0 src 10.0.0.2", "restarting in TCP mode port: 5555", "connected to 10.0.0.2:5555", "10.0.0.2:5555 device" }) runner.Outputs.Enqueue(output);
        var adb = new AdbClient("adb", runner);
        Assert.Equal("10.0.0.2:5555", await adb.SwitchToWifiAsync("usb"));
        Assert.Equal(new[] { "-s", "usb", "tcpip", "5555" }, runner.Calls[2]);
        await adb.DisconnectWifiAsync("10.0.0.2:5555");
        Assert.Equal(new[] { "disconnect", "10.0.0.2:5555" }, runner.Calls[^1]);
        await Assert.ThrowsAsync<ArgumentException>(() => adb.DisconnectWifiAsync("usb"));
    }
    [Fact] public async Task WirelessSerialCannotBeSwitchedAsUsb()
    {
        var runner = new FakeRunner();
        await Assert.ThrowsAsync<InvalidOperationException>(() => new AdbClient("adb", runner).SwitchToWifiAsync("host._adb-tls-connect._tcp"));
        Assert.Empty(runner.Calls);
    }
    [Fact] public async Task BackgroundPreparationReusesAnExistingPortWithoutRestartingAdbd()
    {
        var runner = new FakeRunner();
        foreach (var output in new[] { "default dev wlan0 src 10.0.0.2", "7777", "connected to 10.0.0.2:7777", "10.0.0.2:7777 device" }) runner.Outputs.Enqueue(output);
        var adb = new AdbClient("adb", runner);
        Assert.Equal("10.0.0.2:7777", await adb.PrepareWifiAsync("usb", false));
        Assert.DoesNotContain(runner.Calls, c => c.Contains("tcpip"));
    }
    [Fact] public async Task BackgroundPreparationRejectsListenerChangeWhenRestartIsForbidden()
    {
        var runner = new FakeRunner(); runner.Outputs.Enqueue("default dev wlan0 src 10.0.0.2"); runner.Outputs.Enqueue("0");
        await Assert.ThrowsAsync<IOException>(() => new AdbClient("adb", runner).PrepareWifiAsync("usb", false));
        Assert.DoesNotContain(runner.Calls, c => c.Contains("tcpip"));
    }
    [Fact] public async Task BackgroundPreparationEnablesTcpOnlyWhenNeeded()
    {
        var runner = new FakeRunner();
        foreach (var output in new[] { "default dev wlan0 src 10.0.0.2", "0", "restarting in TCP mode port: 5555", "connected to 10.0.0.2:5555", "10.0.0.2:5555 device" }) runner.Outputs.Enqueue(output);
        Assert.Equal("10.0.0.2:5555", await new AdbClient("adb", runner).PrepareWifiAsync("usb", true));
        Assert.Single(runner.Calls, c => c.Contains("tcpip"));
        Assert.DoesNotContain(runner.Calls, c => c.Contains("kill-server"));
    }
    [Fact] public async Task ConfirmedRestartStartsServerEvenIfCallerCancelsAfterStop()
    {
        using var caller = new CancellationTokenSource();
        var runner = new FakeRunner { OnCall = args => { if (args[0] == "kill-server") caller.Cancel(); } };
        await new AdbClient("adb", runner).RestartServerAsync(caller.Token);
        Assert.Equal(new[] { "kill-server", "start-server" }, runner.Calls.Select(c => c[0]));
        runner.Calls.Clear();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new AdbClient("adb", runner).RestartServerAsync(caller.Token));
        Assert.Empty(runner.Calls);
    }
    [Fact] public async Task FailedStopStillAttemptsToRestoreServer()
    {
        var runner = new FakeRunner { FailKill = true };
        await Assert.ThrowsAsync<IOException>(() => new AdbClient("adb", runner).RestartServerAsync());
        Assert.Equal(new[] { "kill-server", "start-server" }, runner.Calls.Select(c => c[0]));
    }
    [Fact] public async Task PreflightFailsWithoutWifiAddress()
    {
        var runner = new FakeRunner(); runner.Outputs.Enqueue(""); runner.Outputs.Enqueue("");
        await Assert.ThrowsAsync<IOException>(() => new AdbClient("adb", runner).WifiPreparationNeedsRestartAsync("usb"));
        Assert.DoesNotContain(runner.Calls, c => c.Contains("tcpip"));
    }
    [Fact] public async Task CommandTimeoutAndCancellationAreDistinguished()
    {
        var runner = new FakeRunner { Hang = true };
        var adb = new AdbClient("adb", runner, TimeSpan.FromMilliseconds(30));
        await Assert.ThrowsAsync<TimeoutException>(() => adb.ListDevicesAsync());
        Assert.Single(runner.Calls);

        runner.Calls.Clear();
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => adb.ListDevicesAsync(cancelled.Token));
        Assert.Empty(runner.Calls);

        runner.Hang = true;
        var callerAdb = new AdbClient("adb", runner);
        using var caller = new CancellationTokenSource();
        var pending = callerAdb.ListDevicesAsync(caller.Token);
        Assert.Single(runner.Calls);
        caller.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }
    internal sealed class FakeRunner : IProcessRunner
    {
        public readonly List<string[]> Calls = []; public readonly Queue<string> Outputs = []; public readonly FakeProcess Process = new(); public bool FailStart; public bool FailKill; public bool Hang;
        public Action<string[]>? OnCall;
        public async Task<ProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, CancellationToken ct) { ct.ThrowIfCancellationRequested(); var args = arguments.ToArray(); Calls.Add(args); OnCall?.Invoke(args); if (Hang) await Task.Delay(Timeout.Infinite, ct); return new ProcessResult(FailKill && args[0] == "kill-server" ? 1 : 0, Outputs.TryDequeue(out var value) ? value : ""); }
        public IRunningProcess Start(string executable, IReadOnlyList<string> arguments) { Calls.Add(arguments.ToArray()); if (FailStart) throw new IOException(); return Process; }
    }
    internal sealed class FakeProcess : IRunningProcess { public bool Disposed; public bool HasExited => Disposed; public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; } }
}
