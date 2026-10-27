using Xunit;

namespace DeskBridge.Core.Tests;

public sealed class ConnectionOperationsTests
{
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    [Fact]
    public async Task SelectionChangeCancelsStartupButWaitsForItsCleanup()
    {
        var operations = new ConnectionOperations(default);
        var started = Signal(); var cleaning = Signal(); var finishCleanup = Signal();
        var startedSerials = new List<string>();
        var first = operations.RunAsync(async ct =>
        {
            startedSerials.Add("A"); started.SetResult();
            try { await Task.Delay(Timeout.Infinite, ct); }
            finally { cleaning.SetResult(); await finishCleanup.Task; }
        });
        await started.Task;
        var second = operations.RunAsync(_ => { startedSerials.Add("B"); return Task.CompletedTask; });
        await cleaning.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(new[] { "A" }, startedSerials);
        Assert.True(operations.Busy);
        finishCleanup.SetResult(); await Task.WhenAll(first, second);
        Assert.Equal(new[] { "A", "B" }, startedSerials);
        Assert.False(operations.Busy);
    }

    [Fact]
    public async Task RapidAToBToAChangeSkipsCancelledQueuedRequest()
    {
        var operations = new ConnectionOperations(default);
        var started = Signal(); var finish = Signal(); var calls = new List<string>();
        var first = operations.RunAsync(async ct =>
        {
            calls.Add("A1"); started.SetResult(); await finish.Task; ct.ThrowIfCancellationRequested();
        });
        await started.Task;
        var second = operations.RunAsync(_ => { calls.Add("B"); return Task.CompletedTask; });
        var third = operations.RunAsync(_ => { calls.Add("A2"); return Task.CompletedTask; });
        finish.SetResult(); await Task.WhenAll(first, second, third);
        Assert.Equal(new[] { "A1", "A2" }, calls);
    }

    [Fact]
    public async Task DiscoveryDoesNotSupersedeWirelessOperationAndDisconnectCancelsIt()
    {
        var operations = new ConnectionOperations(default);
        var started = Signal(); bool refreshed = false, disconnected = false;
        var wifi = operations.RunAsync(async ct => { started.SetResult(); await Task.Delay(Timeout.Infinite, ct); });
        await started.Task;
        await operations.RunAsync(_ => { refreshed = true; return Task.CompletedTask; }, supersede: false);
        Assert.False(refreshed); Assert.False(wifi.IsCompleted);
        await operations.RunAsync(_ => { disconnected = true; return Task.CompletedTask; });
        await wifi; Assert.True(disconnected);
    }

    [Fact]
    public async Task FailureDoesNotBlockNextRequestAndUnexpectedCancellationIsReported()
    {
        var operations = new ConnectionOperations(default);
        await Assert.ThrowsAsync<IOException>(() => operations.RunAsync(_ => throw new IOException()));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operations.RunAsync(_ => throw new OperationCanceledException()));
        bool ran = false;
        await operations.RunAsync(_ => { ran = true; return Task.CompletedTask; });
        Assert.True(ran);
    }
}
