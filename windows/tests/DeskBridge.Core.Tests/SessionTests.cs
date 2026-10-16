using System.Collections.Concurrent;
using System.Threading.Channels;
using Xunit;
namespace DeskBridge.Core.Tests;
public class SessionTests
{
    [Fact] public async Task HandshakeInputOrderingClipboardAndExit()
    {
        var backend = new FakeBackend(); await using var session = new DeviceSession(backend);
        var exit = new TaskCompletionSource<float>(TaskCreationOptions.RunContinuationsAsynchronously);
        var clipboard = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        session.Exited += value => exit.TrySetResult(value); session.ClipboardReceived += value => clipboard.TrySetResult(value);
        await session.StartAsync("usb", "server.jar"); Assert.True(session.Connected); Assert.False(session.Remote); Assert.Equal(1080, session.Width); Assert.Equal(1920, session.Height);
        await session.MoveAsync(99, 99); Assert.Single(backend.Stream.Writes);
        await session.EnterAsync(Edge.Right, .5f, "hi😀"); Assert.True(session.Remote);
        await session.ButtonAsync(1, true); await session.MoveAsync(1, 2); await session.TextAsync("Việt");
        Assert.Equal(ProtocolEncoder.Clipboard("hi😀"), backend.Stream.Writes.ElementAt(1)); Assert.Equal(ProtocolEncoder.Enter(Edge.Right, .5f), backend.Stream.Writes.ElementAt(2));
        backend.Stream.Feed([.. ProtocolEncoder.Clipboard("phone"), 5, 0x3f, 0, 0, 0]);
        Assert.Equal("phone", await clipboard.Task.WaitAsync(TimeSpan.FromSeconds(2))); Assert.Equal(.5f, await exit.Task.WaitAsync(TimeSpan.FromSeconds(2))); Assert.False(session.Remote);
        await session.StopAsync(); Assert.False(session.Connected); Assert.True(backend.Lease.Disposed); Assert.True(backend.Stream.Disposed);
    }
    [Fact] public async Task NoClipboardDeliveryWithoutOptIn()
    {
        var backend = new FakeBackend(); await using var session = new DeviceSession(backend); int received = 0;
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.ClipboardReceived += _ => received++; session.Exited += _ => exited.TrySetResult();
        await session.StartAsync("usb", "jar"); await session.EnterAsync(Edge.Left, 0, null);
        Assert.Equal(2, backend.Stream.Writes.Count);
        backend.Stream.Feed([.. ProtocolEncoder.Clipboard("private"), 5, 0, 0, 0, 0]); await exited.Task.WaitAsync(TimeSpan.FromSeconds(2)); Assert.Equal(0, received);
    }
    [Fact] public async Task HeartbeatRunsWhileLocalThenStaleCleansUp()
    {
        var backend = new FakeBackend(); var time = new ManualTimeProvider(); await using var session = new DeviceSession(backend, time, new() { HeartbeatInterval = TimeSpan.FromMilliseconds(20), StaleTimeout = TimeSpan.FromMilliseconds(90) });
        var ended = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously); session.Ended += reason => ended.TrySetResult(reason);
        await session.StartAsync("usb", "jar");
        await backend.Stream.FirstPing.Task.WaitAsync(TimeSpan.FromSeconds(2)); time.Advance(TimeSpan.FromMilliseconds(90));
        Assert.Contains("stopped responding", await ended.Task.WaitAsync(TimeSpan.FromSeconds(2))); Assert.Contains(backend.Stream.Writes, b => b.SequenceEqual(new byte[] { 0xfe })); Assert.True(backend.Lease.Disposed);
    }
    [Fact] public async Task StartupTimeoutCleansUp()
    {
        var backend = new FakeBackend(false); await using var session = new DeviceSession(backend, options: new() { StartupTimeout = TimeSpan.FromMilliseconds(40) });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.StartAsync("usb", "jar")); Assert.True(backend.Lease.Disposed); Assert.True(backend.Stream.Disposed); Assert.False(session.Connected);
    }
    [Fact] public async Task StopInterruptsStartupAndIsIdempotent()
    {
        var backend = new FakeBackend(false); await using var session = new DeviceSession(backend);
        var starting = session.StartAsync("usb", "jar"); await backend.Connected.Task;
        await session.StopAsync().WaitAsync(TimeSpan.FromSeconds(2)); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => starting); await session.StopAsync(); Assert.Equal(1, backend.Lease.DisposeCount);
    }
    [Fact] public async Task MalformedPacketEndsAndCleansSession()
    {
        var backend = new FakeBackend(); await using var session = new DeviceSession(backend);
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); session.Ended += _ => ended.TrySetResult();
        await session.StartAsync("usb", "jar"); backend.Stream.Feed([0x90]); await ended.Task.WaitAsync(TimeSpan.FromSeconds(2)); Assert.False(session.Connected); Assert.True(backend.Lease.Disposed);
    }
    [Fact] public async Task ConcurrentWritesRemainWholeAndInputStopsAfterLeave()
    {
        var backend = new FakeBackend(); await using var session = new DeviceSession(backend); await session.StartAsync("usb", "jar"); await session.EnterAsync(Edge.Left, .5f, "");
        await Task.WhenAll(Enumerable.Range(0, 50).Select(i => session.KeyAsync(i, true, 0))); await session.LeaveAsync(); int count = backend.Stream.Writes.Count;
        await session.TextAsync("ignored"); Assert.Equal(count, backend.Stream.Writes.Count); Assert.Equal(50, backend.Stream.Writes.Count(p => p[0] == 0x20));
    }
    [Fact] public async Task StartupRetriesForwardBeforeServerIsListening()
    {
        var backend = new FakeBackend { FailFirstConnection = true };
        await using var session = new DeviceSession(backend, options: new() { ConnectRetryDelay = TimeSpan.FromMilliseconds(1) });
        await session.StartAsync("usb", "jar"); Assert.True(session.Connected); Assert.Equal(2, backend.Attempts);
    }
    [Fact] public async Task PongsKeepLocalSessionAlive()
    {
        var backend = new FakeBackend();
        await using var session = new DeviceSession(backend, options: new() { HeartbeatInterval = TimeSpan.FromMilliseconds(10), StaleTimeout = TimeSpan.FromMilliseconds(100) });
        await session.StartAsync("usb", "jar");
        for (int i = 0; i < 8; i++) { backend.Stream.Feed([0xff]); await Task.Delay(20); }
        Assert.True(session.Connected); Assert.False(session.Remote);
    }
    [Fact] public async Task BlockedInputWriteCannotStarveTheWatchdog()
    {
        var backend = new FakeBackend();
        await using var session = new DeviceSession(backend, options: new() { HeartbeatInterval = TimeSpan.FromMilliseconds(20), StaleTimeout = TimeSpan.FromMilliseconds(100) });
        await session.StartAsync("usb", "jar"); await session.EnterAsync(Edge.Left, .5f, null);
        backend.Stream.BlockWrites = true;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.MoveAsync(1, 2).WaitAsync(TimeSpan.FromSeconds(2)));
        Assert.False(session.Connected); Assert.True(backend.Lease.Disposed);
    }
    [Fact] public async Task LocalControlNotificationPrecedesSlowServerTeardown()
    {
        var backend = new FakeBackend();
        backend.Lease.BlockDisposal = new(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var session = new DeviceSession(backend);
        await session.StartAsync("usb", "jar");
        var local = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.ConnectedChanged += () => { if (!session.Connected) local.TrySetResult(); };
        var stopping = session.StopAsync();
        try
        {
            await local.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.False(stopping.IsCompleted);
        }
        finally { backend.Lease.BlockDisposal.TrySetResult(); await stopping; }
    }
    private sealed class FakeBackend : ISessionBackend
    {
        public readonly FakeStream Stream = new(); public readonly FakeLease Lease = new(); public readonly TaskCompletionSource Connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool FailFirstConnection; public int Attempts;
        public FakeBackend(bool hello = true) { if (hello) Stream.Feed([2, 0, 0, 4, 56, 0, 0, 7, 128, 0, 0, 0, 0]); }
        public Task<IServerLease> LaunchAsync(string serial, string jar, CancellationToken ct) => Task.FromResult<IServerLease>(Lease);
        public Task<Stream> ConnectAsync(int port, CancellationToken ct) { Connected.TrySetResult(); Attempts++; if (FailFirstConnection && Attempts == 1) throw new System.Net.Sockets.SocketException(); return Task.FromResult<Stream>(Stream); }
    }
    private sealed class ManualTimeProvider : TimeProvider
    {
        private long timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Interlocked.Read(ref timestamp);
        public void Advance(TimeSpan amount) => Interlocked.Add(ref timestamp, amount.Ticks);
    }
    private sealed class FakeLease : IServerLease
    {
        public int Port => 12345; public string Token => "0123456789abcdef0123456789abcdef"; public bool HasExited => Disposed; public bool Disposed; public int DisposeCount;
        public TaskCompletionSource? BlockDisposal;
        public ValueTask DisposeAsync() { Disposed = true; DisposeCount++; return new ValueTask(BlockDisposal?.Task ?? Task.CompletedTask); }
    }
    private sealed class FakeStream : Stream
    {
        private readonly Channel<byte[]> incoming = Channel.CreateUnbounded<byte[]>(); public readonly ConcurrentQueue<byte[]> Writes = new(); public readonly TaskCompletionSource FirstPing = new(TaskCreationOptions.RunContinuationsAsynchronously); public bool Disposed, BlockWrites;
        public void Feed(byte[] bytes) => incoming.Writer.TryWrite(bytes);
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) { byte[] bytes = await incoming.Reader.ReadAsync(ct); bytes.CopyTo(buffer); return bytes.Length; }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            if (BlockWrites) return new ValueTask(Task.Delay(Timeout.Infinite, ct));
            var bytes = buffer.ToArray(); Writes.Enqueue(bytes); if (bytes.SequenceEqual(new byte[] { 0xfe })) FirstPing.TrySetResult(); return ValueTask.CompletedTask;
        }
        protected override void Dispose(bool disposing) { Disposed = true; incoming.Writer.TryComplete(); base.Dispose(disposing); }
        public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false; public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] b, int o, int c) => throw new NotSupportedException(); public override void Write(byte[] b, int o, int c) => throw new NotSupportedException(); public override void Flush() { } public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException(); public override void SetLength(long v) => throw new NotSupportedException();
    }
}
