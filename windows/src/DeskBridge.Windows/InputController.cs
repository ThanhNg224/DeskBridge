using System.ComponentModel;
using System.Runtime.InteropServices;
using DeskBridge.Core;
using Forms = System.Windows.Forms;

namespace DeskBridge.Windows;

internal sealed class InputController : IDisposable
{
    private readonly Thread thread;
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Native.HookProc mouseCallback, keyboardCallback;
    private readonly HashSet<uint> pressed = new();
    private nint mouseHook, keyboardHook;
    private RawWindow? window;
    private volatile bool remote, composed;
    private nint composerHandle;
    private IReadOnlyList<DisplayArea> displays = [];
    private int crossingPending;
    private Native.Point previous;
    private Settings settings = new();
    public bool Remote => remote;
    public event Action<DisplayArea, Native.Point>? Crossing;
    public event Action<InputCommand>? Command;
    public event Action? ReleaseRequested;
    public event Action? DisplaysChanged;

    public InputController()
    {
        mouseCallback = MouseHook;
        keyboardCallback = KeyboardHook;
        thread = new Thread(Run) { IsBackground = true, Name = "DeskBridge input" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }
    public Task Ready => ready.Task;
    public void Configure(Settings value, IReadOnlyList<DisplayArea> layout)
    {
        settings = value; displays = layout;
    }
    public void Engage(bool useComposer, nint handle)
    {
        composerHandle = handle; composed = useComposer; remote = true;
    }
    public void Release()
    {
        remote = false;
        var handle = Interlocked.Exchange(ref composerHandle, 0);
        Native.UnclipCursor(0);
        if (handle != 0) Native.ShowWindowAsync(handle, 0);
        Interlocked.Exchange(ref crossingPending, 0);
    }
    public void CancelCrossing() => Interlocked.Exchange(ref crossingPending, 0);

    private void Run()
    {
        try
        {
            window = new RawWindow(this);
            var devices = new[] { new Native.RawDevice { Page = 1, Usage = 2, Flags = 0x100, Target = window.Handle } };
            if (!Native.RegisterRawInputDevices(devices, 1, (uint)Marshal.SizeOf<Native.RawDevice>())) throw new Win32Exception();
            var module = Native.GetModuleHandle(null);
            mouseHook = Native.SetWindowsHookEx(14, mouseCallback, module, 0);
            keyboardHook = Native.SetWindowsHookEx(13, keyboardCallback, module, 0);
            if (mouseHook == 0 || keyboardHook == 0) throw new Win32Exception();
            Native.GetCursorPos(out previous);
            ready.TrySetResult();
            Forms.Application.Run();
        }
        catch (Exception error) { ready.TrySetException(error); ReleaseRequested?.Invoke(); AppLog.Write("input-thread-failed", error); }
        finally
        {
            Release();
            if (mouseHook != 0) Native.UnhookWindowsHookEx(mouseHook);
            if (keyboardHook != 0) Native.UnhookWindowsHookEx(keyboardHook);
            window?.DestroyHandle();
        }
    }

    private nint MouseHook(int code, nint wParam, nint lParam)
    {
        if (code < 0) return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
        var data = Marshal.PtrToStructure<Native.MouseData>(lParam);
        if (remote)
        {
            switch ((int)wParam)
            {
                case 0x201: Command?.Invoke(new(CommandKind.Button, Code: 1, Down: true)); break;
                case 0x202: Command?.Invoke(new(CommandKind.Button, Code: 1)); break;
                case 0x204: Command?.Invoke(settings.RightClickIsBack ? new(CommandKind.Key, Code: 4, Down: true) : new(CommandKind.Button, Code: 2, Down: true)); break;
                case 0x205: Command?.Invoke(settings.RightClickIsBack ? new(CommandKind.Key, Code: 4) : new(CommandKind.Button, Code: 2)); break;
                case 0x207: Command?.Invoke(new(CommandKind.Button, Code: 4, Down: true)); break;
                case 0x208: Command?.Invoke(new(CommandKind.Button, Code: 4)); break;
                case 0x20A: Command?.Invoke(new(CommandKind.Scroll, Y: (short)(data.Data >> 16) / 120f)); break;
                case 0x20E: Command?.Invoke(new(CommandKind.Scroll, X: (short)(data.Data >> 16) / 120f)); break;
            }
            return 1;
        }
        if ((int)wParam == 0x200 && (data.Flags & 1) == 0 && settings.Enabled)
        {
            var display = DesktopGeometry.Crossing(displays, data.Point, previous, settings.Edge);
            if (display is not null && Interlocked.CompareExchange(ref crossingPending, 1, 0) == 0)
                Crossing?.Invoke(display, data.Point);
            previous = data.Point;
        }
        return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    private nint KeyboardHook(int code, nint wParam, nint lParam)
    {
        if (code < 0) return Native.CallNextHookEx(keyboardHook, code, wParam, lParam);
        var data = Marshal.PtrToStructure<Native.KeyboardData>(lParam);
        bool down = (int)wParam is 0x100 or 0x104;
        if (down) pressed.Add(data.Key); else pressed.Remove(data.Key);
        int meta = KeyboardMap.Meta(pressed);
        if (remote && down && data.Key == 0x1B && (meta & 0x1003) == 0x1003)
        {
            Release(); ReleaseRequested?.Invoke(); return 1;
        }
        if (!remote) return Native.CallNextHookEx(keyboardHook, code, wParam, lParam);
        if (composed)
        {
            // The real events must reach the focused native text control for IME/UniKey composition.
            if (Native.GetForegroundWindow() == composerHandle)
                return Native.CallNextHookEx(keyboardHook, code, wParam, lParam);
            Release(); ReleaseRequested?.Invoke();
            return Native.CallNextHookEx(keyboardHook, code, wParam, lParam);
        }
        int android = KeyboardMap.Android(data.Key, data.Scan, data.Flags);
        if (android >= 0) Command?.Invoke(new(CommandKind.Key, Code: android, Down: down, Meta: meta));
        return 1;
    }

    private void RawInput(nint handle)
    {
        if (!remote) return;
        uint header = (uint)Marshal.SizeOf<Native.RawHeader>(), size = 0;
        if (Native.GetRawInputData(handle, 0x10000003, 0, ref size, header) == uint.MaxValue || size < header || size > 65536) return;
        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (Native.GetRawInputData(handle, 0x10000003, buffer, ref size, header) == uint.MaxValue) return;
            var rawHeader = Marshal.PtrToStructure<Native.RawHeader>(buffer);
            if (rawHeader.Type != 0 || size < header + 24) return;
            var mouse = Marshal.PtrToStructure<Native.RawMouse>(buffer + (int)header);
            if ((mouse.Flags & 1) == 0 && (mouse.X != 0 || mouse.Y != 0))
                Command?.Invoke(new(CommandKind.Move, mouse.X, mouse.Y));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public void Dispose()
    {
        Release();
        window?.Stop();
        if (thread.IsAlive) thread.Join(TimeSpan.FromSeconds(2));
    }
    private sealed class RawWindow : Forms.NativeWindow
    {
        private readonly InputController owner;
        public RawWindow(InputController owner)
        {
            this.owner = owner;
            CreateHandle(new Forms.CreateParams { Caption = "DeskBridge input" });
        }
        public void Stop() => Native.PostMessage(Handle, 0x8001, 0, 0);
        protected override void WndProc(ref Forms.Message message)
        {
            if (message.Msg == 0xFF) owner.RawInput(message.LParam);
            if (message.Msg == 0x7E) owner.DisplaysChanged?.Invoke();
            if (message.Msg == 0x8001) Forms.Application.ExitThread();
            base.WndProc(ref message);
        }
    }
}
