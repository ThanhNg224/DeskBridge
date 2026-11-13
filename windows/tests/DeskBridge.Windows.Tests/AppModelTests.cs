using System.Collections.Concurrent;
using System.IO;
using System.Threading.Channels;
using System.Windows.Threading;
using DeskBridge.Core;
using Xunit;

namespace DeskBridge.Windows.Tests;

public sealed class AppModelTests
{
    [Fact]
    public void SelectingAnotherDeviceStopsTheOldSession() => Sta(async () =>
    {
        await using var app = new Harness();
        await app.Model.ConnectAsync(); Assert.True(app.Model.Connected);
        var old = app.Backends[0];
        await app.Model.SelectDeviceAsync("B");
        Assert.True(old.Lease.Disposed);
        Assert.Equal(new[] { "A", "B" }, app.Launched);
        Assert.Equal("B", app.Model.SelectedSerial); Assert.True(app.Model.Connected);
        await app.Model.DisconnectAsync();
        await app.Model.RefreshAsync();
        Assert.False(app.Model.Connected); Assert.Equal(2, app.Launched.Count);
    });

    [Fact]
    public void RapidSelectionChangesDoNotReviveAnOldStartup() => Sta(async () =>
    {
        await using var app = new Harness();
        var blocked = new Backend { LaunchGate = Signal() };
        app.NextBackend = blocked;
        var starting = app.Model.ConnectAsync();
        await blocked.Started.Task;
        var selectB = app.Model.SelectDeviceAsync("B");
        var selectA = app.Model.SelectDeviceAsync("A");
        blocked.LaunchGate.SetResult();
        await Task.WhenAll(starting, selectB, selectA);
        Assert.True(blocked.Lease.Disposed);
        Assert.Equal(new[] { "A", "A" }, app.Launched);
        Assert.Equal("A", app.Model.SelectedSerial); Assert.True(app.Model.Connected);
        Assert.Null(app.Model.Error);
    });

    [Fact]
    public void AnUnavailableSelectionDoesNotFallBackToAnotherPhone() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "B device";
        await app.Model.RefreshAsync();
        Assert.Equal("A", app.Model.SelectedSerial); Assert.False(app.Model.Connected);
        Assert.Equal("Selected device unavailable", app.Model.Status); Assert.Empty(app.Launched);
        app.Runner.Devices = "A device\nB device";
        await app.Model.RefreshAsync();
        Assert.Equal(new[] { "A" }, app.Launched); Assert.True(app.Model.Connected);
    });

    [Fact]
    public void MatchingWifiTakesOverAfterUsbDisappears() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        await app.Model.RefreshAsync();
        Assert.Single(app.Model.Devices); Assert.True(app.Model.Connected);
        var old = app.Backends[0];
        app.Runner.Devices = "10.0.0.2:5555 device";
        await app.Model.RefreshAsync();
        Assert.True(old.Lease.Disposed);
        Assert.Equal("10.0.0.2:5555", app.Model.SelectedSerial);
        Assert.Equal(new[] { "A", "10.0.0.2:5555" }, app.Launched);
        Assert.Equal("Switched to Wi-Fi", app.Model.Status);
    });

    [Fact]
    public void AutoWifiIsOptInAndKeepsUsbSessionWhenListenerExists() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        app.Runner.AutoAttachWifi = true;
        await app.Model.RefreshAsync();
        Assert.Equal(0, app.Runner.WifiConnects);
        var original = app.Backends[0];
        await app.Model.SetAutoWifiAsync(true);
        Assert.Equal(1, app.Runner.WifiConnects);
        Assert.False(original.Lease.Disposed);
        Assert.Equal("A", app.Model.SelectedSerial);
        Assert.True(app.Model.SelectedHasBothTransports);
    });

    [Fact]
    public void UsbInputRemainsAvailableDuringNonDisruptivePreparationButNotAfterDisconnect() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device";
        app.Runner.Identities["A"] = "PHONE-123";
        await app.Model.RefreshAsync();
        app.Runner.WifiGate = Signal();
        var preparing = app.Model.SetAutoWifiAsync(true);
        await app.Runner.WifiStarted.Task;
        Assert.True(app.Model.Connected);
        Assert.True(app.Model.InputAvailableDuringWork);
        var disconnect = app.Model.DisconnectAsync();
        Assert.False(app.Model.InputAvailableDuringWork);
        app.Runner.WifiGate.SetResult();
        await Task.WhenAll(preparing, disconnect);
        Assert.False(app.Model.Connected);
    });

    [Fact]
    public void AutoWifiWaitsWhilePhoneIsControlled() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device";
        app.Runner.Identities["A"] = "PHONE-123";
        await app.Model.RefreshAsync();
        await app.LastSession!.EnterAsync(Edge.Left, .5f, null);
        var original = app.Backends[0];
        await app.Model.SetAutoWifiAsync(true);
        Assert.Equal(0, app.Runner.WifiConnects);
        Assert.False(original.Lease.Disposed);
    });

    [Fact]
    public void AutoWifiFailureDoesNotRestartSharedAdbServer() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.NoWifi = true;
        await app.Model.RefreshAsync();
        await app.Model.SetAutoWifiAsync(true);
        Assert.Equal("Wi-Fi could not be prepared", app.Model.AutoWifiStatus);
        Assert.Equal(0, app.Runner.ServerRestartCalls);
        Assert.True(app.Model.Connected);
    });

    [Fact]
    public void ManualWifiDisconnectSuppressesAutomaticPreparationForThatPhone() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        await app.Model.RefreshAsync();
        await app.Model.SetAutoWifiAsync(true);
        await app.Model.SelectTransportAsync("10.0.0.2:5555");
        await app.Model.DisconnectWifiAsync();
        app.Runner.Devices = "A device";
        await app.Model.SelectDeviceAsync("A");
        Assert.Equal(0, app.Runner.WifiConnects);
        Assert.Equal(AdbClient.PhysicalId("PHONE-123"), app.Model.Settings.AutoWifiSuppressedPhysicalId);
        Assert.True(app.Model.CanResumeAutoWifi);
        app.Runner.AutoAttachWifi = true;
        await app.Model.ResumeAutoWifiAsync();
        Assert.Equal(1, app.Runner.WifiConnects);
        Assert.Null(app.Model.Settings.AutoWifiSuppressedPhysicalId);
    });

    [Fact]
    public void CanSelectBothTransportsWithoutChangingPhoneIdentity() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        await app.Model.RefreshAsync();
        var identity = app.Model.Settings.PreferredPhysicalId;
        Assert.Equal(2, app.Model.SelectedPhoneTransports.Count);
        var old = app.Backends[0];
        await app.Model.SelectTransportAsync("10.0.0.2:5555");
        Assert.True(old.Lease.Disposed);
        Assert.Equal("10.0.0.2:5555", app.Model.SelectedSerial);
        Assert.Equal(identity, app.Model.Settings.PreferredPhysicalId);
        await app.Model.SelectTransportAsync("A");
        Assert.Equal(new[] { "A", "10.0.0.2:5555", "A" }, app.Launched);
        Assert.Equal(identity, app.Model.Settings.PreferredPhysicalId);
    });

    [Fact]
    public void CannotSelectTransportFromAnotherOrStalePhone() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device\nB device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        app.Runner.Identities["B"] = "PHONE-456";
        await app.Model.RefreshAsync();
        var changePhone = app.Model.SelectDeviceAsync("B");
        await app.Model.SelectTransportAsync("10.0.0.2:5555");
        await changePhone;
        Assert.Equal("B", app.Model.SelectedSerial);
        Assert.DoesNotContain("10.0.0.2:5555", app.Launched);
    });

    [Fact]
    public void RapidTransportChangesDoNotReviveAnOldSession() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        await app.Model.RefreshAsync();
        var blocked = new Backend { LaunchGate = Signal() };
        app.NextBackend = blocked;
        var toWifi = app.Model.SelectTransportAsync("10.0.0.2:5555");
        await blocked.Started.Task;
        var toUsb = app.Model.SelectTransportAsync("A");
        blocked.LaunchGate.SetResult();
        await Task.WhenAll(toWifi, toUsb);
        Assert.True(blocked.Lease.Disposed);
        Assert.Equal("A", app.Model.SelectedSerial);
        Assert.True(app.Model.Connected);
    });

    [Fact]
    public void ExplicitDisconnectDoesNotFailOver() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device\n10.0.0.2:5555 device";
        app.Runner.Identities["A"] = "PHONE-123";
        app.Runner.Identities["10.0.0.2:5555"] = "PHONE-123";
        await app.Model.RefreshAsync();
        await app.Model.DisconnectAsync();
        app.Runner.Devices = "10.0.0.2:5555 device";
        await app.Model.RefreshAsync();
        Assert.Equal("A", app.Model.SelectedSerial);
        Assert.Single(app.Launched); Assert.False(app.Model.Connected);
    });

    [Fact]
    public void ExplicitConnectDoesNotTrustReusedSerial() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.Devices = "A device";
        app.Runner.Identities["A"] = "PHONE-123";
        await app.Model.RefreshAsync();
        await app.Model.DisconnectAsync();
        app.Runner.Identities["A"] = "OTHER-456";
        await app.Model.ConnectAsync();
        Assert.Single(app.Launched);
        Assert.False(app.Model.Connected);
        Assert.Equal("Selected device unavailable", app.Model.Status);
        Assert.True(app.Model.DetectedDifferentDevice);
        var detected = app.Model.DetectedPhone!.Value;
        await app.Model.UseDetectedDeviceAsync(detected.Serial, detected.Identity);
        Assert.Equal(2, app.Launched.Count);
        Assert.True(app.Model.Connected);
    });

    [Fact]
    public void CancelledWirelessResultCannotReplaceANewerDeviceSelection() => Sta(async () =>
    {
        await using var app = new Harness();
        app.Runner.WifiGate = Signal();
        var wireless = app.Model.ConnectWifiAsync("10.0.0.2", 5555);
        await app.Runner.WifiStarted.Task;
        int calls = app.Runner.ListCalls;
        await app.Model.RefreshAsync(); Assert.Equal(calls, app.Runner.ListCalls);
        var selection = app.Model.SelectDeviceAsync("B");
        app.Runner.WifiGate.SetResult();
        await Task.WhenAll(wireless, selection);
        Assert.Equal("B", app.Model.SelectedSerial);
        Assert.Equal(new[] { "B" }, app.Launched); Assert.True(app.Model.Connected);
    });

    [Fact]
    public void ShutdownFinishesAnInFlightDisconnectAndOrderedLeave() => Sta(async () =>
    {
        await using var app = new Harness();
        await app.Model.ConnectAsync();
        await app.LastSession!.EnterAsync(Edge.Left, .5f, null);
        var disconnect = app.Model.DisconnectAsync();
        await app.Model.DisposeAsync();
        await disconnect;
        Assert.True(app.Backends[0].Lease.Disposed);
    });

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Sta(Func<Task> test)
    {
        Exception? error = null;
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.BeginInvoke(async () =>
            {
                try { await test(); } catch (Exception e) { error = e; }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(20)), "Dispatcher test timed out.");
        if (error is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();
    }

    private sealed class Harness : IAsyncDisposable
    {
        private readonly string jar = Path.GetTempFileName();
        public readonly Runner Runner = new();
        public readonly List<Backend> Backends = [];
        public readonly List<string> Launched = [];
        public Backend? NextBackend;
        public DeviceSession? LastSession;
        public AppModel Model { get; }
        public Harness()
        {
            Model = new(new Settings { PreferredSerial = "A" }, new Input(), path => new AdbClient(path, Runner), _ =>
            {
                var backend = NextBackend ?? new Backend(); NextBackend = null;
                backend.OnLaunch = Launched.Add; Backends.Add(backend);
                return LastSession = new DeviceSession(backend, options: new() { HeartbeatInterval = TimeSpan.FromMinutes(1) });
            }, jar, Dispatcher.CurrentDispatcher, _ => { });
        }
        public async ValueTask DisposeAsync() { try { await Model.DisposeAsync(); } finally { File.Delete(jar); } }
    }
    private sealed class Input : IInputController
    {
        public bool Remote => false;
        public Task Ready => Task.CompletedTask;
        public event Action<DisplayArea, Native.Point>? Crossing { add { } remove { } }
        public event Action<InputCommand>? Command { add { } remove { } }
        public event Action? ReleaseRequested { add { } remove { } }
        public event Action? DisplaysChanged { add { } remove { } }
        public void Configure(Settings value, IReadOnlyList<DisplayArea> layout) { }
        public void Engage(bool useComposer, nint handle) { }
        public void Release() { }
        public void CancelCrossing() { }
        public void Dispose() { }
    }
    private sealed class Runner : IProcessRunner
    {
        public string Devices = "A device\nB device";
        public int ListCalls;
        public int WifiConnects;
        public bool AutoAttachWifi;
        public bool NoWifi;
        public int ServerRestartCalls;
        public readonly Dictionary<string, string> Identities = [];
        public TaskCompletionSource? WifiGate;
        public readonly TaskCompletionSource WifiStarted = Signal();
        public async Task<ProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, CancellationToken ct)
        {
            if (arguments[0] == "connect")
            {
                WifiConnects++;
                WifiStarted.TrySetResult();
                if (WifiGate is not null) await WifiGate.Task; // Deliberately late success after cancellation.
                if (AutoAttachWifi) Devices = "A device\n10.0.0.2:5555 device";
                return new(0, "connected to 10.0.0.2:5555");
            }
            ct.ThrowIfCancellationRequested();
            if (arguments[0] is "kill-server" or "start-server") { ServerRestartCalls++; return new(0, ""); }
            if (arguments[0] == "-s" && arguments.Count > 4 && arguments[2] == "shell")
            {
                if (arguments[3] == "ip") return new(0, NoWifi ? "" : "default dev wlan0 src 10.0.0.2");
                if (arguments[3] == "getprop" && arguments[4] == "service.adb.tcp.port") return new(0, "5555");
                return new(0, Identities.GetValueOrDefault(arguments[1], ""));
            }
            ListCalls++;
            return new(0, Devices);
        }
        public IRunningProcess Start(string executable, IReadOnlyList<string> arguments) => throw new NotSupportedException();
    }
    private sealed class Backend : ISessionBackend
    {
        public readonly Lease Lease = new();
        public readonly TestStream Stream = new();
        public readonly TaskCompletionSource Started = Signal();
        public TaskCompletionSource? LaunchGate;
        public Action<string>? OnLaunch;
        public async Task<IServerLease> LaunchAsync(string serial, string jar, CancellationToken ct)
        {
            OnLaunch?.Invoke(serial); Started.TrySetResult();
            if (LaunchGate is not null) await LaunchGate.Task;
            return Lease;
        }
        public Task<Stream> ConnectAsync(int port, CancellationToken ct) => Task.FromResult<Stream>(Stream);
    }
    private sealed class Lease : IServerLease
    {
        public int Port => 12345;
        public string Token => "0123456789abcdef0123456789abcdef";
        public bool Disposed;
        public bool HasExited => Disposed;
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
    private sealed class TestStream : Stream
    {
        private readonly Channel<byte[]> incoming = Channel.CreateUnbounded<byte[]>();
        public TestStream() => incoming.Writer.TryWrite([2, 0, 0, 4, 56, 0, 0, 7, 128, 0, 0, 0, 0]);
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        { var bytes = await incoming.Reader.ReadAsync(ct); bytes.CopyTo(buffer); return bytes.Length; }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        { ct.ThrowIfCancellationRequested(); return ValueTask.CompletedTask; }
        protected override void Dispose(bool disposing) { incoming.Writer.TryComplete(); base.Dispose(disposing); }
        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
