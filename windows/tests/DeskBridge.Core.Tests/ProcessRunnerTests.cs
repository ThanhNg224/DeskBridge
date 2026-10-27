using System.Diagnostics;
using DeskBridge.Core;
using Xunit;

namespace DeskBridge.Core.Tests;

public sealed class ProcessRunnerTests
{
    [Fact]
    public async Task RunAsync_CancellationWaitsForChildProcessToExit()
    {
        string marker = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".pid");
        var (executable, arguments) = CreateLongRunningProcess(marker);
        using var cancellation = new CancellationTokenSource();
        var run = new ProcessRunner().RunAsync(executable, arguments, cancellation.Token);
        try
        {
            int pid = await WaitForPidAsync(marker);
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
            Assert.True(HasExited(pid));
        }
        finally
        {
            cancellation.Cancel();
            try { await run; } catch (OperationCanceledException) { }
            File.Delete(marker);
        }
    }

    [Fact]
    public async Task RunAsync_PreCanceledTokenDoesNotStartProcess()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new ProcessRunner().RunAsync("missing-process-runner-test-executable", [], cancellation.Token));
    }

    private static (string Executable, string[] Arguments) CreateLongRunningProcess(string marker)
    {
        if (OperatingSystem.IsWindows())
        {
            string script = "$PID | Set-Content -LiteralPath '" + marker.Replace("'", "''") + "'; Start-Sleep -Seconds 30";
            return ("powershell.exe", ["-NoProfile", "-Command", script]);
        }

        return ("/bin/sh", ["-c", "echo $$ > \"$1\"; exec sleep 30", "DeskBridgeProcessTest", marker]);
    }

    private static async Task<int> WaitForPidAsync(string marker)
    {
        var timeout = Stopwatch.StartNew();
        while (timeout.Elapsed < TimeSpan.FromSeconds(10))
        {
            if (File.Exists(marker) && int.TryParse(await File.ReadAllTextAsync(marker), out int pid))
                return pid;
            await Task.Delay(25);
        }
        throw new TimeoutException("The helper process did not write its PID marker.");
    }

    private static bool HasExited(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return process.HasExited; }
        catch (ArgumentException) { return true; }
    }
}
