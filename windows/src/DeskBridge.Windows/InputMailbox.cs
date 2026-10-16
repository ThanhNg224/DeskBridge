namespace DeskBridge.Windows;

internal enum CommandKind { Move, Button, Scroll, Key, Text, Leave }
internal sealed record InputCommand(CommandKind Kind, float X = 0, float Y = 0, int Code = 0, bool Down = false, int Meta = 0, string? Text = null, int Generation = 0, DeskBridge.Core.DeviceSession? Target = null, TaskCompletionSource? Completion = null);

internal sealed class InputMailbox : IDisposable
{
    private readonly LinkedList<InputCommand> commands = new();
    private readonly SemaphoreSlim available = new(0);
    public void Add(InputCommand command)
    {
        lock (commands)
        {
            if (command.Kind == CommandKind.Move && commands.Last?.Value is { Kind: CommandKind.Move } last && last.Generation == command.Generation)
            {
                commands.Last.Value = last with { X = last.X + command.X, Y = last.Y + command.Y };
                return;
            }
            commands.AddLast(command);
            available.Release();
        }
    }
    public async Task<InputCommand> TakeAsync(CancellationToken ct)
    {
        await available.WaitAsync(ct).ConfigureAwait(false);
        lock (commands)
        {
            var result = commands.First!.Value;
            commands.RemoveFirst();
            return result;
        }
    }
    public void Dispose() => available.Dispose();
}
