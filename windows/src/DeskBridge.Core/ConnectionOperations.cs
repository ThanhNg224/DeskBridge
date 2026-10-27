namespace DeskBridge.Core;

// Called from the UI dispatcher: a new user request cancels older work, but waits
// for its teardown before touching ADB or starting another session.
public sealed class ConnectionOperations(CancellationToken lifetime)
{
    private CancellationTokenSource? current;
    private Task tail = Task.CompletedTask;
    public bool Busy => !tail.IsCompleted;
    public Task Completion => tail;

    public Task RunAsync(Func<CancellationToken, Task> action, bool supersede = true)
    {
        if (!supersede && Busy) return Task.CompletedTask;
        current?.Cancel();
        var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        current = request;
        return tail = ExecuteAsync(tail, request, action);
    }

    public void Cancel() => current?.Cancel();

    private async Task ExecuteAsync(Task previous, CancellationTokenSource request, Func<CancellationToken, Task> action)
    {
        try
        {
            try { await previous; } catch { /* A failed request must not block later requests. */ }
            request.Token.ThrowIfCancellationRequested();
            await action(request.Token);
        }
        catch (Exception) when (request.IsCancellationRequested)
        {
            // A superseded operation may fail while closing its socket/process;
            // its stale error must not replace the latest request's status.
        }
        finally
        {
            if (current == request) current = null;
            request.Dispose();
        }
    }
}
