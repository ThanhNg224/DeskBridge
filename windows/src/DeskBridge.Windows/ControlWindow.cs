using System.Text;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace DeskBridge.Windows;

internal sealed class ControlWindow : Window
{
    private readonly TextBox editor;
    private bool composing, clearing;
    private TextComposition? activeComposition;
    private readonly bool composedMode;
    private readonly Action<InputCommand> send;
    private readonly Dictionary<Key, int> forwardedKeys = new();
    private readonly HashSet<Key> localKeys = new();
    public nint Handle => new WindowInteropHelper(this).Handle;
    public event Action? FocusLost;

    public ControlWindow(bool composedMode, Action<InputCommand> send)
    {
        this.composedMode = composedMode; this.send = send;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        ShowInTaskbar = false; Topmost = true; ShowActivated = composedMode;
        Cursor = Cursors.None;
        editor = new TextBox
        {
            Width = 480, MaxHeight = 120, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(24), Padding = new Thickness(16), FontSize = 20,
            Cursor = Cursors.None, Visibility = composedMode ? Visibility.Visible : Visibility.Collapsed,
            IsUndoEnabled = false
        };
        Content = editor;
        editor.AddHandler(TextCompositionManager.PreviewTextInputStartEvent, new TextCompositionEventHandler((_, e) => { composing = true; activeComposition = e.TextComposition; }), true);
        editor.AddHandler(TextCompositionManager.PreviewTextInputUpdateEvent, new TextCompositionEventHandler((_, e) => { composing = true; activeComposition = e.TextComposition; }), true);
        // TextBox handles TextInput itself; observe handled events to finish IME composition.
        editor.AddHandler(TextCompositionManager.TextInputEvent, new TextCompositionEventHandler((_, _) =>
        {
            composing = false; activeComposition = null;
            Dispatcher.BeginInvoke(() => CommitDelimited());
        }), true);
        editor.TextChanged += (_, _) => { if (!clearing && !composing) CommitDelimited(); };
        editor.PreviewKeyDown += (_, e) => RouteKey(e, true);
        editor.PreviewKeyUp += (_, e) => RouteKey(e, false);
        Deactivated += (_, _) => { if (composedMode && IsVisible) FocusLost?.Invoke(); };
    }

    public void Place(Native.Rect bounds)
    {
        Show();
        if (!Native.SetWindowPos(Handle, new nint(-1), bounds.Left, bounds.Top, bounds.Width, bounds.Height, composedMode ? 0u : 0x10u))
            throw new System.ComponentModel.Win32Exception();
        if (composedMode)
        {
            Activate(); editor.Focus(); Keyboard.Focus(editor);
            if (Native.GetForegroundWindow() != Handle || !editor.IsKeyboardFocused)
                throw new InvalidOperationException("DeskBridge could not focus the text composer. Return to the app and try again.");
        }
    }

    private void CommitDelimited()
    {
        if (composing || clearing || editor.Text.Length == 0) return;
        char last = editor.Text[^1];
        if (char.IsWhiteSpace(last) || char.IsPunctuation(last)) Flush();
        else if (Encoding.UTF8.GetByteCount(editor.Text) > 4096)
        {
            // Do not submit a partial IME composition or exceed the server's TEXT boundary.
            Cancel(); FocusLost?.Invoke();
        }
    }

    public void Flush()
    {
        var text = TakePendingText();
        if (text is not null) send(new(CommandKind.Text, Text: text));
    }
    public string? TakePendingText()
    {
        if (!composedMode || editor.Text.Length == 0) return null;
        // Completing composition through the real input context is handled by WPF before normal commit keys.
        if (composing) { Cancel(); return null; }
        string text = editor.Text;
        if (Encoding.UTF8.GetByteCount(text) > 4096) { Cancel(); FocusLost?.Invoke(); return null; }
        Cancel();
        return text;
    }
    /// Complete a real IME composition before changing the target app. Never discard it on failure.
    public bool TryTakeShortcutText(out string? text)
    {
        text = null;
        if (composing)
        {
            if (activeComposition is null) return false;
            try { if (!TextCompositionManager.CompleteComposition(activeComposition)) return false; }
            catch (ArgumentException) { return false; }
            if (composing) return false;
        }
        text = TakePendingText();
        return true;
    }

    public void Cancel()
    {
        clearing = true; editor.Clear(); clearing = false; composing = false; activeComposition = null;
    }

    private void RouteKey(KeyEventArgs e, bool down)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.ImeProcessed or Key.DeadCharProcessed) return;
        if (!down)
        {
            if (forwardedKeys.Remove(key, out int forwarded))
            {
                send(new(CommandKind.Key, Code: forwarded, Down: false, Meta: CurrentMeta()));
                e.Handled = true;
            }
            else e.Handled = !localKeys.Remove(key);
            return;
        }
        if (key is Key.LeftAlt or Key.RightAlt) { localKeys.Add(key); e.Handled = true; return; }
        bool shortcut = (Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0;
        if (key == Key.Escape && editor.Text.Length > 0) { if (down) Cancel(); e.Handled = true; return; }
        bool editing = key == Key.Back && editor.Text.Length > 0;
        bool printable = key is >= Key.A and <= Key.Z or >= Key.D0 and <= Key.D9
            or >= Key.NumPad0 and <= Key.Divide or >= Key.Oem1 and <= Key.OemBackslash or Key.Space;
        if (!shortcut && (printable || editing)) { localKeys.Add(key); return; }
        if (key is Key.LeftShift or Key.RightShift && !shortcut) { localKeys.Add(key); return; }
        if (composing && key is Key.Enter or Key.Tab) { localKeys.Add(key); return; }
        if (down) Flush();
        int android = KeyboardMap.Android((uint)KeyInterop.VirtualKeyFromKey(key));
        if (android >= 0)
        {
            forwardedKeys[key] = android;
            send(new(CommandKind.Key, Code: android, Down: true, Meta: CurrentMeta()));
        }
        e.Handled = true;
    }
    private static int CurrentMeta()
    {
        int meta = 0;
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) meta |= 0x41;
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0) meta |= 0x3000;
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0) meta |= 0x12;
        if ((Keyboard.Modifiers & ModifierKeys.Windows) != 0) meta |= 0x30000;
        return meta;
    }
}
