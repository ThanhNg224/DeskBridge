using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal sealed class AppModel : IAsyncDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly IInputController input;
    private readonly Func<string, AdbClient> makeAdb;
    private readonly Func<AdbClient, DeviceSession> makeSession;
    private readonly string serverJar;
    private readonly Action<Settings> saveSelection;
    private readonly InputMailbox mailbox = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer discovery = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly DispatcherTimer desktopWatch = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Task inputPump;
    private readonly ConnectionOperations operations;
    private DeviceSession? session;
    private ControlWindow? shield;
    private DisplayArea? returnDisplay;
    private nint previousForeground;
    private int generation;
    private int endingGeneration = -1;
    private int shortcutGeneration = -1;
    private readonly HashSet<int> rejectedShortcuts = new();
    private int failures;
    private DateTimeOffset nextAttempt;
    private bool disposing;
    private bool entering;
    private Task releaseVisit = Task.CompletedTask;
    private Task enterVisit = Task.CompletedTask;
    public Settings Settings { get; private set; }
    public IReadOnlyList<AdbDevice> Devices { get; private set; } = [];
    public string? SelectedSerial { get; private set; }
    public bool SelectedHasBothTransports { get; private set; }
    public bool DetectedDifferentDevice => pendingDeviceIdentity is not null;
    public (string Serial, string Identity)? DetectedPhone => pendingDeviceIdentity is { } identity && SelectedSerial is { } serial ? (serial, identity) : null;
    public string Status { get; private set; } = "Starting";
    public string? Error { get; private set; }
    public bool Connected => session?.Connected == true && sessionSerial == SelectedSerial;
    private string? sessionSerial;
    private string? selectedPhysicalId;
    private string? pendingDeviceIdentity;
    public bool Remote => input.Remote;
    public event Action? Changed;
    public AppModel(Settings settings) : this(settings, new InputController(), ManagedAdb.Client, adb => new DeviceSession(adb),
        Environment.GetEnvironmentVariable("DESKBRIDGE_SERVER_JAR") ?? Path.Combine(AppContext.BaseDirectory, "deskbridge-server.jar"), Application.Current.Dispatcher) { }

    internal AppModel(Settings settings, IInputController input, Func<string, AdbClient> makeAdb,
        Func<AdbClient, DeviceSession> makeSession, string serverJar, Dispatcher dispatcher,
        Action<Settings>? saveSelection = null)
    {
        this.input = input; this.makeAdb = makeAdb; this.makeSession = makeSession;
        this.serverJar = serverJar; this.dispatcher = dispatcher;
        this.saveSelection = saveSelection ?? SettingsStore.Save;
        operations = new(lifetime.Token);
        Settings = settings; SelectedSerial = settings.PreferredSerial;
        selectedPhysicalId = settings.PreferredPhysicalId;
        input.Crossing += (display, point) =>
        {
            if (!Connected) { input.CancelCrossing(); return; }
            dispatcher.BeginInvoke(() => { enterVisit = EnterAsync(display, point); });
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
    private async Task RunConnectionAsync(Func<CancellationToken, Task> action, bool supersede = true)
    {
        if (disposing) return;
        try
        {
            await operations.RunAsync(action, supersede);
        }
        catch (Exception e)
        {
            nextAttempt = DateTimeOffset.UtcNow.AddSeconds(Math.Min(30, 2 << Math.Min(failures++, 4)));
            Report(e);
        }
        finally { Notify(); }
    }
    public Task RefreshAsync() => RunConnectionAsync(RefreshCoreAsync, supersede: false);
    private async Task RefreshCoreAsync(CancellationToken ct)
    {
        var adb = makeAdb(Settings.AdbPath);
        var rawDevices = await adb.ListDevicesAsync(ct);
        ct.ThrowIfCancellationRequested();
        if (session is not null && !rawDevices.Any(d => d.Serial == sessionSerial && d.State == "device")) ReturnLocal();
        var devices = await adb.ReadDeviceIdentitiesAsync(rawDevices, ct);
        ct.ThrowIfCancellationRequested();
        var phones = AdbClient.GroupPhones(devices, SelectedSerial);
        if (SelectedSerial is null && phones.Count == 1) SelectedSerial = phones[0].Serial;
        var selected = devices.FirstOrDefault(d => d.Serial == SelectedSerial && d.State == "device");
        if (selectedPhysicalId is null && selected?.PhysicalId is not null) selectedPhysicalId = selected.PhysicalId;
        bool verified = selected is not null && (selectedPhysicalId is null || selected.PhysicalId == selectedPhysicalId);
        pendingDeviceIdentity = selected?.PhysicalId is { } observed && selectedPhysicalId is not null && observed != selectedPhysicalId ? observed : null;
        string? switched = null;
        if (!verified && session is not null)
        {
            ReturnLocal();
            await DisconnectCoreAsync();
            ct.ThrowIfCancellationRequested();
        }
        if (!verified && Settings.Enabled && nextAttempt != DateTimeOffset.MaxValue && SelectedSerial is not null)
        {
            var alternate = AdbClient.Alternate(SelectedSerial, selectedPhysicalId, devices);
            if (alternate is not null)
            {
                SelectedSerial = alternate.Serial;
                pendingDeviceIdentity = null;
                verified = true;
                nextAttempt = DateTimeOffset.MinValue;
                switched = AdbClient.IsWirelessSerial(alternate.Serial) ? "Switched to Wi-Fi" : "Switched to USB";
            }
        }
        if (!verified && Settings.Enabled && SelectedSerial is { } endpoint && DateTimeOffset.UtcNow >= nextAttempt &&
            !rawDevices.Any(d => d.Serial == endpoint && d.State == "device") &&
            AdbClient.TryWifiEndpoint(endpoint, out var host, out var port))
        {
            Status = "Reconnecting"; Notify();
            await adb.ConnectWifiAsync(host, port, ct);
            ct.ThrowIfCancellationRequested();
            await RefreshCoreAsync(ct);
            return;
        }
        var checkedDevices = devices.Select(d => d.Serial == SelectedSerial && !verified ? d with { State = "offline" } : d).ToArray();
        var samePhone = checkedDevices.Where(d => d.State == "device" && d.PhysicalId is not null && d.PhysicalId == selectedPhysicalId).ToArray();
        SelectedHasBothTransports = samePhone.Length == 2 && samePhone.Count(d => AdbClient.IsWirelessSerial(d.Serial)) == 1 && samePhone.Any(d => d.Serial == SelectedSerial);
        Devices = AdbClient.GroupPhones(checkedDevices, SelectedSerial).Concat(checkedDevices.Where(d => d.State != "device")).ToArray();
        if (Settings.PreferredSerial != SelectedSerial || Settings.PreferredPhysicalId != selectedPhysicalId)
        {
            Settings = Settings with { PreferredSerial = SelectedSerial, PreferredPhysicalId = selectedPhysicalId };
            saveSelection(Settings);
        }
        var ready = Devices.Where(d => d.State == "device").ToArray();
        if (!Connected)
        {
            Status = !Settings.Enabled ? "Disabled" : SelectedSerial is not null && !ready.Any(d => d.Serial == SelectedSerial)
                ? "Selected device unavailable" : ready.Length == 0 ? "No authorized device" : "Ready";
            if (Settings.Enabled && ready.Any(d => d.Serial == SelectedSerial) && DateTimeOffset.UtcNow >= nextAttempt)
            {
                await DisconnectCoreAsync();
                await ConnectCoreAsync(ct);
                if (switched is not null) Status = switched;
            }
        }
    }
    public Task SelectDeviceAsync(string? serial)
    {
        if (serial == SelectedSerial) return Task.CompletedTask;
        SelectedSerial = serial; selectedPhysicalId = null; pendingDeviceIdentity = null; nextAttempt = DateTimeOffset.MinValue;
        ReturnLocal(); Notify();
        return RunConnectionAsync(async ct => { await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested(); await RefreshCoreAsync(ct); });
    }
    public Task UseDetectedDeviceAsync(string serial, string identity)
    {
        if (SelectedSerial != serial || pendingDeviceIdentity != identity) return Task.CompletedTask;
        selectedPhysicalId = identity; pendingDeviceIdentity = null; nextAttempt = DateTimeOffset.MinValue;
        ReturnLocal();
        return RunConnectionAsync(async ct => { await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested(); await RefreshCoreAsync(ct); });
    }
    public Task ConnectAsync() => RunConnectionAsync(async ct =>
    {
        if (Connected) return;
        nextAttempt = DateTimeOffset.MinValue;
        await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested();
        await RefreshCoreAsync(ct);
    });
    private async Task ConnectCoreAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Settings.Enabled) throw new InvalidOperationException("Enable DeskBridge first.");
        if (string.IsNullOrWhiteSpace(SelectedSerial)) throw new InvalidOperationException("Select an authorized device.");
        if (!File.Exists(serverJar)) throw new FileNotFoundException("deskbridge-server.jar is missing. Use the packaged build or set DESKBRIDGE_SERVER_JAR.");
        string serial = SelectedSerial;
        var active = makeSession(makeAdb(Settings.AdbPath));
        session = active; sessionSerial = serial;
        active.ConnectedChanged += () => { if (session == active && !active.Connected) input.Release(); };
        active.Exited += along =>
        {
            if (session == active) input.Release();
            dispatcher.BeginInvoke(() => { if (session == active) RestoreLocal(along); });
        };
        active.ClipboardReceived += text => dispatcher.BeginInvoke(() =>
        {
            if (session != active || sessionSerial != SelectedSerial || !Settings.ShareClipboard) return;
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
            await active.StartAsync(serial, serverJar, ct);
            ct.ThrowIfCancellationRequested();
            if (session != active || SelectedSerial != serial) throw new OperationCanceledException(ct);
            AppLog.Write($"session-connected duration-ms={watch.ElapsedMilliseconds}");
            Status = "Connected"; failures = 0; nextAttempt = DateTimeOffset.MinValue;
        }
        catch
        {
            if (session == active) { session = null; sessionSerial = null; }
            await active.DisposeAsync(); throw;
        }
    }

    private async Task EnterAsync(DisplayArea display, Native.Point point)
    {
        var active = session;
        if (disposing || operations.Busy || entering || active?.Connected != true || active.Remote || !Settings.Enabled)
        { input.CancelCrossing(); return; }
        entering = true;
        int visit = Interlocked.Increment(ref generation);
        try
        {
            await releaseVisit;
            if (visit != Volatile.Read(ref generation) || session != active || !Connected || !Settings.Enabled)
            { input.CancelCrossing(); return; }
            previousForeground = Native.GetForegroundWindow(); returnDisplay = display;
            shield = new ControlWindow(Settings.ComposedText, Queue);
            shield.FocusLost += ReturnLocal;
            shield.Place(display.Bounds);
            string? clipboard = null;
            if (Settings.ShareClipboard)
                clipboard = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : "";
            await active.EnterAsync(DesktopGeometry.Opposite(Settings.Edge), DesktopGeometry.Along(display.Bounds, point, Settings.Edge), clipboard, lifetime.Token);
            if (visit != Volatile.Read(ref generation) || session != active || !active.Remote || disposing || shield is null)
            {
                // ReturnLocal may have run while ENTER was awaiting the socket. Balance
                // that ENTER before another visit/session can take over.
                if (active.Remote) await active.LeaveAsync();
                return;
            }
            var park = new Native.Point(display.Bounds.Left + display.Bounds.Width / 2, display.Bounds.Top + display.Bounds.Height / 2);
            Native.SetCursorPos(park.X, park.Y);
            var clip = new Native.Rect { Left = park.X, Top = park.Y, Right = park.X + 1, Bottom = park.Y + 1 };
            if (!Native.ClipCursor(ref clip)) throw new System.ComponentModel.Win32Exception();
            input.Engage(Settings.ComposedText, shield.Handle);
            Status = "Controlling Android"; AppLog.Write("remote-enter"); Notify();
        }
        catch (Exception e) { ReturnLocal(); Report(e); }
        finally { entering = false; input.CancelCrossing(); }
    }
    public void ReturnLocal()
    {
        if (Volatile.Read(ref endingGeneration) >= 0)
        {
            // Also invalidate an entry that is waiting for the previous LEAVE.
            Interlocked.Increment(ref generation); input.Release(); return;
        }
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
                    if (command.ShortcutId != 0)
                    {
                        if (shortcutGeneration != command.Generation)
                        {
                            shortcutGeneration = command.Generation; rejectedShortcuts.Clear();
                        }
                        if (command.ShortcutStart && Settings.ComposedText)
                        {
                            var pending = await dispatcher.InvokeAsync(() =>
                            {
                                if (command.Generation != Volatile.Read(ref generation) || command.Target != session || shield is null)
                                    return (Success: false, Text: (string?)null);
                                bool success = shield.TryTakeShortcutText(out var text);
                                return (Success: success, Text: text);
                            });
                            if (!pending.Success) rejectedShortcuts.Add(command.ShortcutId);
                            else if (pending.Text is not null && active.Remote && command.Generation == Volatile.Read(ref generation))
                                await active.TextAsync(pending.Text);
                        }
                        if (rejectedShortcuts.Contains(command.ShortcutId)) continue;
                    }
                    if (Settings.ComposedText && command.Kind is CommandKind.Move or CommandKind.Button or CommandKind.Scroll)
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

    private async Task DisconnectCoreAsync()
    {
        ReturnLocal();
        await enterVisit;
        await releaseVisit;
        var active = session; session = null; sessionSerial = null;
        if (active is not null) await active.DisposeAsync();
        Status = "Disconnected";
    }
    public Task DisconnectAsync()
    {
        // Release local input synchronously, even when an ADB command is still stopping.
        ReturnLocal(); nextAttempt = DateTimeOffset.MaxValue;
        return RunConnectionAsync(_ => DisconnectCoreAsync());
    }
    public Task ApplyAsync(Settings value)
    {
        if (value.PreferredSerial != SelectedSerial) value = value with { PreferredPhysicalId = null };
        value.Validate();
        ReturnLocal();
        return RunConnectionAsync(async ct =>
        {
            await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested();
            SettingsStore.SetStartup(value.StartWithWindows); SettingsStore.Save(value);
            Settings = value; SelectedSerial = value.PreferredSerial; selectedPhysicalId = value.PreferredPhysicalId;
            input.Configure(value, DesktopGeometry.Read());
            nextAttempt = DateTimeOffset.MinValue;
            await RefreshCoreAsync(ct);
        });
    }
    public Task ConnectWifiAsync(string host, int port)
    {
        // Validate before changing a working connection.
        AdbClient.WifiTarget(host, port);
        ReturnLocal();
        return RunConnectionAsync(async ct =>
        {
            await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested();
            var serial = await makeAdb(Settings.AdbPath).ConnectWifiAsync(host, port, ct);
            ct.ThrowIfCancellationRequested(); SelectedSerial = serial; selectedPhysicalId = null;
            nextAttempt = DateTimeOffset.MinValue;
            await RefreshCoreAsync(ct);
        });
    }
    public Task SwitchWifiAsync()
    {
        var serial = SelectedSerial ?? throw new InvalidOperationException("Select a USB device.");
        if (AdbClient.IsWirelessSerial(serial)) throw new InvalidOperationException("Select a USB device.");
        ReturnLocal();
        return RunConnectionAsync(async ct =>
        {
            await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested();
            var endpoint = await makeAdb(Settings.AdbPath).SwitchToWifiAsync(serial, ct);
            ct.ThrowIfCancellationRequested(); SelectedSerial = endpoint;
            nextAttempt = DateTimeOffset.MinValue;
            await RefreshCoreAsync(ct);
        });
    }
    public Task DisconnectWifiAsync()
    {
        var serial = SelectedSerial ?? throw new InvalidOperationException("Select a Wi-Fi device.");
        if (!AdbClient.IsWirelessSerial(serial)) throw new InvalidOperationException("The selected device is not a Wi-Fi endpoint.");
        ReturnLocal(); nextAttempt = DateTimeOffset.MaxValue;
        return RunConnectionAsync(async ct =>
        {
            await DisconnectCoreAsync(); ct.ThrowIfCancellationRequested();
            await makeAdb(Settings.AdbPath).DisconnectWifiAsync(serial, ct);
            ct.ThrowIfCancellationRequested();
            var devices = await makeAdb(Settings.AdbPath).ListDevicesAsync(ct);
            ct.ThrowIfCancellationRequested(); Devices = devices;
        });
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
        ReturnLocal(); disposing = true;
        operations.Cancel();
        try { await operations.Completion; } catch { /* The request's caller reports failures. */ }
        await enterVisit;
        // Keep the input pump alive until any ordered TEXT/LEAVE has finished.
        // DisconnectCoreAsync may itself be waiting for this completion.
        await releaseVisit;
        var active = session; session = null;
        if (active is not null) await active.DisposeAsync();
        lifetime.Cancel();
        input.Dispose();
        await inputPump;
        mailbox.Dispose(); lifetime.Dispose();
    }
}
