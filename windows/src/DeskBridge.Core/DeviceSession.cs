using System.Net;
using System.Net.Sockets;

namespace DeskBridge.Core;

public sealed record SessionOptions
{
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(8);
    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan StaleTimeout { get; init; } = TimeSpan.FromSeconds(6);
    public TimeSpan ConnectRetryDelay { get; init; } = TimeSpan.FromMilliseconds(250);
}
public interface ISessionBackend
{
    Task<IServerLease> LaunchAsync(string serial, string jar, CancellationToken cancellationToken);
    Task<Stream> ConnectAsync(int port, CancellationToken cancellationToken);
}
public sealed class AdbSessionBackend(AdbClient adb) : ISessionBackend
{
    public Task<IServerLease> LaunchAsync(string serial, string jar, CancellationToken cancellationToken) => adb.LaunchServerAsync(serial, jar, cancellationToken);
    public async Task<Stream> ConnectAsync(int port, CancellationToken cancellationToken)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try { await socket.ConnectAsync(IPAddress.Loopback, port, cancellationToken).ConfigureAwait(false); return new NetworkStream(socket, true); }
        catch { socket.Dispose(); throw; }
    }
}
public sealed class DeviceSession : IAsyncDisposable
{
    private readonly ISessionBackend backend;
    private readonly TimeProvider time;
    private readonly SessionOptions options;
    private readonly SemaphoreSlim gate = new(1, 1);
    private CancellationTokenSource? lifetime;
    private IServerLease? server;
    private Stream? stream;
    private bool shareClipboard;
    private long lastReceived;
    private volatile bool connected, remote;
    public bool Connected => connected;
    public bool Remote => remote;
    public int Width { get; private set; }
    public int Height { get; private set; }
    public int Rotation { get; private set; }
    public string? LastError { get; private set; }
    public event Action? ConnectedChanged;
    public event Action<float>? Exited;
    public event Action<string>? ClipboardReceived;
    public event Action<string>? Ended;
    public DeviceSession(AdbClient adb) : this(new AdbSessionBackend(adb)) { }
    public DeviceSession(ISessionBackend backend, TimeProvider? timeProvider = null, SessionOptions? options = null)
    {
        this.backend = backend; time = timeProvider ?? TimeProvider.System; this.options = options ?? new();
    }
    public async Task StartAsync(string serial, string jar, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (lifetime is not null) throw new InvalidOperationException("Session is already started.");
            LastError = null;
            var run = new CancellationTokenSource(); lifetime = run;
            using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, run.Token);
            startup.CancelAfter(options.StartupTimeout);
            try
            {
                server = await backend.LaunchAsync(serial, jar, startup.Token).ConfigureAwait(false);
                ServerPacketParser parser;
                while (true)
                {
                    parser = new ServerPacketParser();
                    try
                    {
                        stream = await backend.ConnectAsync(server.Port, startup.Token).ConfigureAwait(false);
                        await stream.WriteAsync(ProtocolEncoder.Hello(server.Token), startup.Token).ConfigureAwait(false);
                        byte[] buffer = new byte[8192]; bool greeted = false;
                        while (!greeted)
                        {
                            int n = await stream.ReadAsync(buffer, startup.Token).ConfigureAwait(false);
                            if (n == 0) throw new IOException("Device closed during startup.");
                            foreach (var packet in parser.Feed(buffer.AsSpan(0, n)))
                            {
                                if (!greeted)
                                {
                                    if (packet is not HelloOkPacket hello) throw new InvalidDataException("Expected HELLO_OK.");
                                    Width = hello.Width; Height = hello.Height; Rotation = hello.Rotation;
                                    greeted = true;
                                }
                                else HandlePacket(packet);
                            }
                        }
                        break;
                    }
                    catch (Exception e) when ((e is SocketException or IOException) && !server.HasExited)
                    {
                        if (stream is not null) { await stream.DisposeAsync().ConfigureAwait(false); stream = null; }
                        await Task.Delay(options.ConnectRetryDelay, time, startup.Token).ConfigureAwait(false);
                    }
                }
                Volatile.Write(ref lastReceived, time.GetTimestamp()); connected = true;
                await Task.Run(() => ConnectedChanged?.Invoke()).ConfigureAwait(false);
                // Task.Run ensures callbacks from background receive/heartbeat run off the UI thread.
                _ = Task.Run(() => ReceiveAsync(run, parser));
                _ = Task.Run(() => HeartbeatAsync(run));
            }
            catch
            {
                await CleanupAsync("Could not start device session.").ConfigureAwait(false);
                throw;
            }
        }
        finally { gate.Release(); }
    }
    private async Task ReceiveAsync(CancellationTokenSource run, ServerPacketParser parser)
    {
        byte[] buffer = new byte[8192];
        try
        {
            var active = stream!;
            while (!run.IsCancellationRequested)
            {
                int n = await active.ReadAsync(buffer, run.Token).ConfigureAwait(false);
                if (n == 0) { parser.Complete(); throw new IOException("Device disconnected."); }
                var packets = parser.Feed(buffer.AsSpan(0, n));
                await gate.WaitAsync(run.Token).ConfigureAwait(false);
                try
                {
                    if (lifetime != run) return;
                    // Only complete valid packets count as liveness.
                    if (packets.Count > 0) Volatile.Write(ref lastReceived, time.GetTimestamp());
                    foreach (var packet in packets) HandlePacket(packet);
                }
                finally { gate.Release(); }
            }
        }
        catch (OperationCanceledException) when (run.IsCancellationRequested) { }
        catch { await EndRunAsync(run, "Device connection ended.").ConfigureAwait(false); }
    }
    private void HandlePacket(ServerPacket packet)
    {
        switch (packet)
        {
            case HelloOkPacket: throw new InvalidDataException("Unexpected HELLO_OK.");
            case ExitPacket exit:
                if (remote) { remote = false; Exited?.Invoke(exit.Along); }
                break;
            case ClipboardPacket clipboard:
                if (shareClipboard) ClipboardReceived?.Invoke(clipboard.Text); break;
        }
    }
    private async Task HeartbeatAsync(CancellationTokenSource run)
    {
        try
        {
            while (true)
            {
                await Task.Delay(options.HeartbeatInterval, time, run.Token).ConfigureAwait(false);
                await gate.WaitAsync(run.Token).ConfigureAwait(false);
                try
                {
                    if (lifetime != run) return;
                    if (time.GetElapsedTime(Volatile.Read(ref lastReceived)) >= options.StaleTimeout) { await CleanupAsync("Device stopped responding.").ConfigureAwait(false); return; }
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(run.Token);
                    deadline.CancelAfter(options.StaleTimeout);
                    await stream!.WriteAsync(ProtocolEncoder.Ping(), deadline.Token).ConfigureAwait(false);
                }
                finally { gate.Release(); }
            }
        }
        catch (OperationCanceledException) when (run.IsCancellationRequested) { }
        catch { await EndRunAsync(run, "Device connection ended.").ConfigureAwait(false); }
    }
    private async Task EndRunAsync(CancellationTokenSource run, string reason)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { if (lifetime == run) await CleanupAsync(reason).ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    private async Task PerformAsync(Func<Stream, CancellationToken, Task> operation, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!connected || stream is null || lifetime is null) return;
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
            // A blocked peer must not hold the state gate and starve the heartbeat watchdog.
            linked.CancelAfter(options.StaleTimeout);
            try { await operation(stream, linked.Token).ConfigureAwait(false); }
            catch { await CleanupAsync("Device connection ended.").ConfigureAwait(false); throw; }
        }
        finally { gate.Release(); }
    }
    public Task EnterAsync(Edge androidEntryEdge, float along, string? clipboard, CancellationToken cancellationToken = default)
    {
        byte[] enter = ProtocolEncoder.Enter(androidEntryEdge, along);
        byte[]? clip = clipboard is null ? null : ProtocolEncoder.Clipboard(clipboard);
        return PerformAsync(async (s, ct) =>
        {
            if (remote) return;
            shareClipboard = clipboard is not null;
            if (clip is not null) await s.WriteAsync(clip, ct).ConfigureAwait(false);
            await s.WriteAsync(enter, ct).ConfigureAwait(false); remote = true;
        }, cancellationToken);
    }
    public Task LeaveAsync(CancellationToken cancellationToken = default) => PerformAsync(async (s, ct) =>
    {
        if (!remote) return; await s.WriteAsync(ProtocolEncoder.Leave(), ct).ConfigureAwait(false); remote = false;
    }, cancellationToken);
    private Task InputAsync(byte[] packet) => PerformAsync(async (s, ct) => { if (remote) await s.WriteAsync(packet, ct).ConfigureAwait(false); });
    public Task MoveAsync(float dx, float dy) => InputAsync(ProtocolEncoder.Move(dx, dy));
    public Task ButtonAsync(byte button, bool down) => InputAsync(ProtocolEncoder.Button(button, down));
    public Task ScrollAsync(float horizontal, float vertical) => InputAsync(ProtocolEncoder.Scroll(horizontal, vertical));
    public Task KeyAsync(int keyCode, bool down, int metaState) => InputAsync(ProtocolEncoder.Key(keyCode, down, metaState));
    public Task TextAsync(string text) => InputAsync(ProtocolEncoder.Text(text));
    public async Task StopAsync()
    {
        // Cancel before waiting so Stop interrupts an in-flight startup or write.
        lifetime?.Cancel();
        await gate.WaitAsync().ConfigureAwait(false);
        try { await CleanupAsync(null).ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    private async Task CleanupAsync(string? reason)
    {
        var run = lifetime; if (run is null) return;
        lifetime = null; run.Cancel();
        bool wasConnected = connected; connected = false; remote = false; shareClipboard = false;
        // Notify control adapters before potentially slow ADB teardown, so local input is restored promptly.
        if (wasConnected) await Task.Run(() => ConnectedChanged?.Invoke()).ConfigureAwait(false);
        var oldStream = stream; stream = null; var oldServer = server; server = null;
        try { if (oldStream is not null) await oldStream.DisposeAsync().ConfigureAwait(false); }
        finally
        {
            try { if (oldServer is not null) await oldServer.DisposeAsync().ConfigureAwait(false); }
            catch { reason ??= "Could not remove the device connection. Check ADB."; }
            LastError = reason;
            await Task.Run(() =>
            {
                Ended?.Invoke(reason ?? "Session stopped.");
            }).ConfigureAwait(false);
            // Workers retain the cancellation source until they observe cancellation.
        }
    }
    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);
}
