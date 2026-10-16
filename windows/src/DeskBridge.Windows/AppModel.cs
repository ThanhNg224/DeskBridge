using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal sealed class AppModel : IAsyncDisposable
{
    private readonly Dispatcher dispatcher = Application.Current.Dispatcher;
    private readonly InputController input = new();
    private readonly InputMailbox mailbox = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer discovery = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly DispatcherTimer desktopWatch = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Task inputPump;
    private DeviceSession? session;
    private ControlWindow? shield;
    private DisplayArea? returnDisplay;
    private nint previousForeground;
    private int generation;
    private int endingGeneration = -1;
    private int failures;
    private DateTimeOffset nextAttempt;
    private bool busy, disposing;
    private Task releaseVisit = Task.CompletedTask;
    public Settings Settings { get; private set; }
    public IReadOnlyList<AdbDevice> Devices { get; private set; } = [];
    public string? SelectedSerial { get; set; }
    public string Status { get; private set; } = "Starting";
    public string? Error { get; private set; }
    public bool Connected => session?.Connected == true;
    public bool Remote => input.Remote;
    public event Action? Changed;
    public AppModel(Settings settings)
    {
        Settings = settings; SelectedSerial = settings.PreferredSerial;
        input.Crossing += (display, point) =>
        {
            if (!Connected) { input.CancelCrossing(); return; }
            dispatcher.BeginInvoke(() => EnterAsync(display, point));
        };
        input.Command += Queue;
        input.ReleaseRequested += () => dispatcher.BeginInvoke(ReturnLocal);
        input.DisplaysChanged += () => dispatcher.BeginInvoke(() =>
        {
            ReturnLocal();
            try { input.Configure(Settings, DesktopGeometry.Read()); }
            catch (Exception error) { Report(error); }
        });
        discovery.Tick += async (_, _) => await RefreshAsync();
        desktopWatch.Tick += (_, _) => CheckDesktop();
        Microsoft.Win32.SystemEvents.SessionSwitch += OnSessionSwitch;
        Microsoft.Win32.SystemEvents.PowerModeChanged += OnPowerChange;
        inputPump = Task.Run(PumpAsync);
    }

    public async Task InitializeAsync()
    {
        await input.Ready;
        input.Configure(Settings, DesktopGeometry.Read());
        discovery.Start(); desktopWatch.Start();
        await RefreshAsync();
    }
    private void Notify() => Changed?.Invoke();
    public void Report(Exception error)
    {
        Error = error.Message; Status = "Error";
        AppLog.Write("operation-failed", error); Notify();
    }
    public async Task RefreshAsync()
    {
        if (busy || disposing) return;
        busy = true;
        try
        {
            if (!Connected)
            {
                Devices = await new AdbClient(Settings.AdbPath).ListDevicesAsync(lifetime.Token);
                var ready = Devices.Where(d => d.State == "device").ToArray();
                if (SelectedSerial is null && ready.Length == 1) SelectedSerial = ready[0].Serial;
                Status = !Settings.Enabled ? "Disabled" : ready.Length == 0 ? "No authorized device" : "Ready";
                if (Settings.Enabled && ready.Any(d => d.Serial == SelectedSerial) && DateTimeOffset.UtcNow >= nextAttempt)
                    await ConnectCoreAsync();
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e)
        {
            nextAttempt = DateTimeOffset.UtcNow.AddSeconds(Math.Min(30, 2 << Math.Min(failures++, 4)));
            Report(e);
        }
        finally { busy = false; Notify(); }
    }
    public async Task ConnectAsync()
    {
        if (busy || disposing || Connected) return;
        busy = true;
        try { await ConnectCoreAsync(); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e) { Report(e); }
        finally { busy = false; Notify(); }
    }
    private async Task ConnectCoreAsync()
    {
        if (!Settings.Enabled) throw new InvalidOperationException("Enable DeskBridge first.");
        if (string.IsNullOrWhiteSpace(SelectedSerial)) throw new InvalidOperationException("Select an authorized device.");
        var jar = Environment.GetEnvironmentVariable("DESKBRIDGE_SERVER_JAR") ?? Path.Combine(AppContext.BaseDirectory, "deskbridge-server.jar");
        if (!File.Exists(jar)) throw new FileNotFoundException("deskbridge-server.jar is missing. Use the packaged build or set DESKBRIDGE_SERVER_JAR.");
        var active = new DeviceSession(new AdbClient(Settings.AdbPath));
        session = active;
        active.ConnectedChanged += () => { if (session == active && !active.Connected) input.Release(); };
        active.Exited += along =>
        {
            if (session == active) input.Release();
            dispatcher.BeginInvoke(() => { if (session == active) RestoreLocal(along); });
        };
        active.ClipboardReceived += text => dispatcher.BeginInvoke(() =>
        {
            if (session != active || !Settings.ShareClipboard) return;
            try { System.Windows.Clipboard.SetText(text); }
            catch (ExternalException e) { Report(e); }
        });
        active.Ended += _ => dispatcher.BeginInvoke(() =>
        {
            if (session != active) return;
            RestoreLocal(); Status = "Disconnected"; Notify();
        });
        try
        {
            Status = "Connecting"; Error = null; Notify();
            var watch = Stopwatch.StartNew();
            await active.StartAsync(SelectedSerial, jar, lifetime.Token);
            AppLog.Write($"session-connected duration-ms={watch.ElapsedMilliseconds}");
            Status = "Connected"; failures = 0; nextAttempt = DateTimeOffset.MinValue;
        }
        catch
        {
            if (session == active) session = null;
            await active.DisposeAsync(); throw;
        }
    }

    private async void EnterAsync(DisplayArea display, Native.Point point)
    {
        var active = session;
        if (disposing || busy || active?.Connected != true || active.Remote || !Settings.Enabled)
        { input.CancelCrossing(); return; }
        try
        {
            await releaseVisit;
            if (session != active || !active.Connected) { input.CancelCrossing(); return; }
            previousForeground = Native.GetForegroundWindow(); returnDisplay = display;
            Interlocked.Increment(ref generation);
            shield = new ControlWindow(Settings.ComposedText, Queue);
            shield.FocusLost += ReturnLocal;
            shield.Place(display.Bounds);
            string? clipboard = null;
            if (Settings.ShareClipboard)
                clipboard = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : "";
            await active.EnterAsync(DesktopGeometry.Opposite(Settings.Edge), DesktopGeometry.Along(display.Bounds, point, Settings.Edge), clipboard, lifetime.Token);
            if (session != active || !active.Remote || disposing) { RestoreLocal(); return; }
            var park = new Native.Point(display.Bounds.Left + display.Bounds.Width / 2, display.Bounds.Top + display.Bounds.Height / 2);
            Native.SetCursorPos(park.X, park.Y);
            var clip = new Native.Rect { Left = park.X, Top = park.Y, Right = park.X + 1, Bottom = park.Y + 1 };
            if (!Native.ClipCursor(ref clip)) throw new System.ComponentModel.Win32Exception();
            input.Engage(Settings.ComposedText, shield.Handle);
            Status = "Controlling Android"; AppLog.Write("remote-enter"); Notify();
        }
        catch (Exception e) { ReturnLocal(); Report(e); }
    }
    public void ReturnLocal()
    {
        if (Volatile.Read(ref endingGeneration) >= 0) { input.Release(); return; }
        var active = session;
        var pending = shield?.TakePendingText();
        int ending = Volatile.Read(ref generation);
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (active?.Remote == true)
        {
            Volatile.Write(ref endingGeneration, ending);
            if (pending is not null) mailbox.Add(new(CommandKind.Text, Text: pending, Generation: ending, Target: active));
            mailbox.Add(new(CommandKind.Leave, Generation: ending, Target: active, Completion: completed));
            releaseVisit = completed.Task;
        }
        RestoreLocal();
    }
    private void RestoreLocal(float? along = null)
    {
        input.Release(); Interlocked.Increment(ref generation);
        var old = shield; shield = null;
        if (old is not null) { old.FocusLost -= ReturnLocal; old.Cancel(); old.Close(); }
        if (returnDisplay is not null)
        {
            var point = DesktopGeometry.Return(returnDisplay.Bounds, Settings.Edge, along ?? 0.5f);
            Native.SetCursorPos(point.X, point.Y); returnDisplay = null;
        }
        if (previousForeground != 0) { Native.SetForegroundWindow(previousForeground); previousForeground = 0; }
        Status = Connected ? "Connected" : "Disconnected";
        AppLog.Write("local-control-restored"); Notify();
    }

    private void Queue(InputCommand command)
    {
        if (disposing) return;
        mailbox.Add(command with { Generation = Volatile.Read(ref generation), Target = session });
    }
    private async Task PumpAsync()
    {
        try
        {
            while (true)
            {
                var command = await mailbox.TakeAsync(lifetime.Token).ConfigureAwait(false);
                var active = session;
                try
                {
                    if (active?.Connected != true || command.Target != active) continue;
                    bool finishingText = command.Generation == Volatile.Read(ref endingGeneration)
                        && command.Kind is CommandKind.Text or CommandKind.Leave;
                    if (command.Generation != Volatile.Read(ref generation) && !finishingText) continue;
                    if (command.Kind is CommandKind.Move or CommandKind.Button or CommandKind.Scroll)
                    {
                        // Finish an uncommitted word before pointer movement can cause Android EXIT.
                        var text = await dispatcher.InvokeAsync(() =>
                            command.Generation == Volatile.Read(ref generation) && command.Target == session
                                ? shield?.TakePendingText() : null);
                        if (text is not null && active.Remote && command.Generation == Volatile.Read(ref generation)) await active.TextAsync(text);
                    }
                    if ((!finishingText && command.Generation != Volatile.Read(ref generation)) || !active.Remote) continue;
                    switch (command.Kind)
                    {
                        case CommandKind.Move: await active.MoveAsync(command.X * (float)Settings.PointerSpeed, command.Y * (float)Settings.PointerSpeed); break;
                        case CommandKind.Button: await active.ButtonAsync((byte)command.Code, command.Down); break;
                        case CommandKind.Scroll:
                            float factor = (float)Settings.ScrollSpeed * (Settings.InvertScroll ? -1 : 1);
                            await active.ScrollAsync(command.X * factor, command.Y * factor); break;
                        case CommandKind.Key: await active.KeyAsync(command.Code, command.Down, command.Meta); break;
                        case CommandKind.Text: await active.TextAsync(command.Text!); break;
                        case CommandKind.Leave: if (active.Remote) await active.LeaveAsync(); break;
                    }
                }
                catch (Exception e) { _ = dispatcher.BeginInvoke(() => { RestoreLocal(); Report(e); }); }
                finally
                {
                    if (command.Kind == CommandKind.Leave)
                    {
                        Interlocked.CompareExchange(ref endingGeneration, -1, command.Generation);
                        command.Completion?.TrySetResult();
                    }
                }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    public async Task DisconnectAsync()
    {
        ReturnLocal();
        await releaseVisit;
        var active = session; session = null;
        if (active is not null) await active.DisposeAsync();
        nextAttempt = DateTimeOffset.MaxValue; Status = "Disconnected"; Notify();
    }
    public async Task ApplyAsync(Settings value)
    {
        value.Validate();
        await DisconnectAsync();
        SettingsStore.SetStartup(value.StartWithWindows); SettingsStore.Save(value);
        Settings = value; SelectedSerial = value.PreferredSerial;
        input.Configure(value, DesktopGeometry.Read());
        nextAttempt = DateTimeOffset.MinValue;
        await RefreshAsync();
    }
    public async Task ConnectWifiAsync(string host, int port)
    {
        await DisconnectAsync();
        SelectedSerial = await new AdbClient(Settings.AdbPath).ConnectWifiAsync(host, port, lifetime.Token);
        await ConnectAsync();
    }
    public async Task SwitchWifiAsync()
    {
        var serial = SelectedSerial ?? throw new InvalidOperationException("Select a USB device.");
        await DisconnectAsync();
        SelectedSerial = await new AdbClient(Settings.AdbPath).SwitchToWifiAsync(serial, lifetime.Token);
        await ConnectAsync();
    }
    public async Task DisconnectWifiAsync()
    {
        var serial = SelectedSerial ?? throw new InvalidOperationException("Select a Wi-Fi device.");
        if (!serial.Contains(':')) throw new InvalidOperationException("The selected device is not a Wi-Fi endpoint.");
        await DisconnectAsync();
        await new AdbClient(Settings.AdbPath).DisconnectWifiAsync(serial, lifetime.Token);
    }
    private void CheckDesktop()
    {
        if (!Remote) return;
        var desktop = Native.OpenInputDesktop(0, false, 0x100);
        if (desktop == 0) ReturnLocal(); else Native.CloseDesktop(desktop);
    }
    private void OnSessionSwitch(object sender, Microsoft.Win32.SessionSwitchEventArgs e)
    {
        if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionLock) dispatcher.BeginInvoke(ReturnLocal);
    }
    private void OnPowerChange(object sender, Microsoft.Win32.PowerModeChangedEventArgs e)
    {
        if (e.Mode == Microsoft.Win32.PowerModes.Suspend) dispatcher.BeginInvoke(ReturnLocal);
    }
    public async ValueTask DisposeAsync()
    {
        if (disposing) return;
        discovery.Stop(); desktopWatch.Stop();
        Microsoft.Win32.SystemEvents.SessionSwitch -= OnSessionSwitch;
        Microsoft.Win32.SystemEvents.PowerModeChanged -= OnPowerChange;
        RestoreLocal(); disposing = true; lifetime.Cancel();
        var active = session; session = null;
        if (active is not null) await active.DisposeAsync();
        input.Dispose();
        await inputPump;
        mailbox.Dispose(); lifetime.Dispose();
    }
}
