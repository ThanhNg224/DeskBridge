using System.Diagnostics;
using System.Text.Json;
using DeskBridge.Core;
using Forms = System.Windows.Forms;

namespace DeskBridge.Windows;

public partial class App : Application
{
    private Mutex? singleInstance;
    private Forms.NotifyIcon? tray;
    private AppModel? model;
    public bool Exiting { get; private set; }
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (!Environment.Is64BitProcess || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        { MessageBox.Show("DeskBridge requires Windows 11 x64."); Shutdown(1); return; }
        try
        {
            if (e.Args.Contains("--diagnostics")) { await DiagnosticsAsync(Argument(e.Args, "--diagnostics")); Shutdown(); return; }
            if (e.Args.Contains("--device-smoke")) { await DeviceSmokeAsync(e.Args); Shutdown(); return; }
            singleInstance = new Mutex(true, @"Local\DeskBridge.Windows", out bool created);
            if (!created) { MessageBox.Show("DeskBridge is already running. Open it from the system tray."); Shutdown(); return; }
            Settings settings;
            try { settings = SettingsStore.Load(); }
            catch (Exception error) when (error is IOException or JsonException or InvalidDataException)
            { MessageBox.Show($"Could not load settings: {error.Message}\nEdit or remove {SettingsStore.FilePath} and restart."); Shutdown(1); return; }
            model = new AppModel(settings);
            var window = new MainWindow(model); MainWindow = window;
            var menu = new Forms.ContextMenuStrip();
            var open = menu.Items.Add(settings.Language == "vi" ? "Mở DeskBridge" : "Open DeskBridge");
            open.Click += (_, _) => ShowMain();
            var toggle = new Forms.ToolStripMenuItem(settings.Language == "vi" ? "Bật DeskBridge" : "Enable DeskBridge") { Checked = settings.Enabled };
            toggle.Click += async (_, _) =>
            {
                try { await model.ApplyAsync(model.Settings with { Enabled = !model.Settings.Enabled }); toggle.Checked = model.Settings.Enabled; }
                catch (Exception error) { model.Report(error); }
            };
            menu.Items.Add(toggle);
            var restore = menu.Items.Add(settings.Language == "vi" ? "Trả điều khiển về PC" : "Return control to PC", null, (_, _) => model.ReturnLocal());
            var quit = menu.Items.Add(settings.Language == "vi" ? "Thoát" : "Quit", null, async (_, _) => await QuitAsync());
            tray = new Forms.NotifyIcon { Icon = (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone(), Text = "DeskBridge · experimental", ContextMenuStrip = menu, Visible = true };
            tray.MouseClick += (_, args) => { if (args.Button == Forms.MouseButtons.Left) ShowMain(); };
            model.Changed += () =>
            {
                bool vi = model.Settings.Language == "vi";
                open.Text = vi ? "Mở DeskBridge" : "Open DeskBridge";
                toggle.Text = vi ? "Bật DeskBridge" : "Enable DeskBridge"; toggle.Checked = model.Settings.Enabled;
                restore.Text = vi ? "Trả điều khiển về PC" : "Return control to PC";
                quit.Text = vi ? "Thoát" : "Quit";
            };
            if (!e.Args.Contains("--background")) window.Show();
            await model.InitializeAsync();
        }
        catch (Exception error)
        {
            AppLog.Write("startup-failed", error);
            if (e.Args.Contains("--diagnostics") || e.Args.Contains("--device-smoke"))
            {
                try
                {
                    string option = e.Args.Contains("--diagnostics") ? "--diagnostics" : "--device-smoke";
                    await File.WriteAllTextAsync(Argument(e.Args, option), JsonSerializer.Serialize(new { Result = "failed", Error = error.GetType().Name, Timestamp = DateTimeOffset.UtcNow }));
                }
                catch (Exception reportError) when (reportError is IOException or ArgumentException or UnauthorizedAccessException) { AppLog.Write("report-write-failed", reportError); }
            }
            else MessageBox.Show(error.Message, "DeskBridge");
            await QuitAsync(1);
        }
    }
    private void ShowMain() { MainWindow?.Show(); if (MainWindow is not null) { MainWindow.WindowState = WindowState.Normal; MainWindow.Activate(); } }
    private async Task QuitAsync(int code = 0)
    {
        if (Exiting) return; Exiting = true;
        if (model is not null) await model.DisposeAsync();
        if (tray is not null) { tray.Visible = false; tray.Icon?.Dispose(); tray.ContextMenuStrip?.Dispose(); tray.Dispose(); }
        singleInstance?.Dispose(); Shutdown(code);
    }
    private static string Argument(string[] args, string name)
    {
        int index = Array.IndexOf(args, name);
        if (index < 0 || index + 1 >= args.Length) throw new ArgumentException($"{name} requires a value.");
        return Path.GetFullPath(args[index + 1]);
    }
    private static async Task DiagnosticsAsync(string path)
    {
        var settings = SettingsStore.Load();
        string? adbVersion = null, error = null;
        IReadOnlyList<AdbDevice> devices = [];
        try
        {
            using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var version = await new ProcessRunner().RunAsync(settings.AdbPath, ["version"], ct.Token);
            adbVersion = version.Output.Split('\n').FirstOrDefault()?.Trim();
            devices = await new AdbClient(settings.AdbPath).ListDevicesAsync(ct.Token);
        }
        catch (Exception e) { error = e.GetType().Name; }
        var report = new
        {
            Timestamp = DateTimeOffset.UtcNow, OS = Environment.OSVersion.VersionString,
            Architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            AdbVersion = adbVersion, Devices = devices, Error = error,
            Displays = DesktopGeometry.Read().Select(d => new { d.Primary, d.Bounds.Left, d.Bounds.Top, d.Bounds.Right, d.Bounds.Bottom, d.DpiX, d.DpiY }),
            SourceCommit = File.Exists(Path.Combine(AppContext.BaseDirectory, "SOURCE_COMMIT")) ? File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "SOURCE_COMMIT")).Trim() : "local-unpackaged",
            Acceptance = "pending-windows-device"
        };
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static async Task DeviceSmokeAsync(string[] args)
    {
        if (Environment.GetEnvironmentVariable("DESKBRIDGE_DEVICE") != "1") throw new InvalidOperationException("Set DESKBRIDGE_DEVICE=1 to opt in to the device smoke test.");
        string output = Argument(args, "--device-smoke");
        int index = Array.IndexOf(args, "--serial");
        if (index < 0 || index + 1 >= args.Length) throw new ArgumentException("--serial is required.");
        var settings = SettingsStore.Load();
        using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await using var session = new DeviceSession(new AdbClient(settings.AdbPath));
        var watch = Stopwatch.StartNew();
        var jar = Environment.GetEnvironmentVariable("DESKBRIDGE_SERVER_JAR") ?? Path.Combine(AppContext.BaseDirectory, "deskbridge-server.jar");
        await session.StartAsync(args[index + 1], jar, ct.Token);
        long handshakeMs = watch.ElapsedMilliseconds;
        await session.EnterAsync(Edge.Left, 0.5f, null, ct.Token);
        await session.MoveAsync(96, 0);
        await session.LeaveAsync(ct.Token);
        await Task.Delay(2500, ct.Token); // Exercises heartbeat while local; no keyboard or clipboard changes.
        if (!session.Connected) throw new IOException("Session ended during heartbeat check.");
        await session.StopAsync();
        await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { Timestamp = DateTimeOffset.UtcNow, session.Width, session.Height, HandshakeMs = handshakeMs, Result = "protocol-smoke-pass", InteractiveAcceptance = "pending" }, new JsonSerializerOptions { WriteIndented = true }));
    }
}
