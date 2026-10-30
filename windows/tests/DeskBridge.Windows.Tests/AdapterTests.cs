using System.Runtime.ExceptionServices;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using DeskBridge.Core;
using Xunit;

namespace DeskBridge.Windows.Tests;

public sealed class AdapterTests
{
    [Fact]
    public void InteropLayoutsMatchWindowsX64()
    {
        Assert.Equal(24, Marshal.SizeOf<Native.RawHeader>());
        Assert.Equal(24, Marshal.SizeOf<Native.RawMouse>());
        Assert.Equal(24, Marshal.SizeOf<Native.KeyboardData>());
        Assert.Equal(32, Marshal.SizeOf<Native.MouseData>());
        Assert.Equal(12, Marshal.OffsetOf<Native.RawMouse>(nameof(Native.RawMouse.X)).ToInt32());
        Assert.Equal(16, Marshal.OffsetOf<Native.RawMouse>(nameof(Native.RawMouse.Y)).ToInt32());
    }
    [Theory]
    [InlineData(0x41, 29)] [InlineData(0x5A, 54)] [InlineData(0x30, 7)] [InlineData(0x39, 16)]
    [InlineData(0x70, 131)] [InlineData(0x7B, 142)] [InlineData(0x08, 67)] [InlineData(0x2E, 112)]
    [InlineData(0x25, 21)] [InlineData(0x28, 20)] [InlineData(0xBA, 74)] [InlineData(0xDE, 75)]
    [InlineData(0xA3, 114)] [InlineData(0x5B, 117)] [InlineData(0x60, 144)] [InlineData(0xFF, -1)]
    public void KeyMappingUsesAndroidCodes(uint key, int expected) => Assert.Equal(expected, KeyboardMap.Android(key));
    [Fact]
    public void ExtendedKeysAndReleaseChordModifiers()
    {
        Assert.Equal(60, KeyboardMap.Android(0x10, 0x36));
        Assert.Equal(114, KeyboardMap.Android(0x11, 0, 1));
        Assert.Equal(160, KeyboardMap.Android(0x0D, 0, 1));
        Assert.Equal(0x3053, KeyboardMap.Meta(new HashSet<uint> { 0x10, 0x11, 0x12 }));
    }
    private static DisplayArea Display(int l, int t, int r, int b, bool primary = false) =>
        new(new Native.Rect { Left = l, Top = t, Right = r, Bottom = b }, primary);
    [Fact]
    public void InternalEdgesDoNotCrossAndNegativeCoordinatesWork()
    {
        var main = Display(0, 0, 1920, 1080, true); var left = Display(-1280, 0, 0, 1024);
        Assert.Null(DesktopGeometry.Crossing([main, left], new(0, 500), new(1, 500), Edge.Left));
        Assert.Equal(left, DesktopGeometry.Crossing([main, left], new(-1280, 500), new(-1279, 500), Edge.Left));
        Assert.Equal(main, DesktopGeometry.Crossing([main, left], new(0, 1050), new(1, 1050), Edge.Left));
        Assert.Null(DesktopGeometry.Crossing([main, left], new(-500, 0), new(-500, 1), Edge.Top));
    }
    [Fact]
    public void ReturnCoordinatesAndOppositeEdgeAreNormalized()
    {
        var b = Display(-1920, -100, 0, 980).Bounds;
        Assert.Equal(0.5f, DesktopGeometry.Along(b, new(-1920, 440), Edge.Left));
        Assert.Equal(Edge.Right, DesktopGeometry.Opposite(Edge.Left));
        var point = DesktopGeometry.Return(b, Edge.Left, 1);
        Assert.Equal(-1908, point.X); Assert.Equal(979, point.Y);
    }
    [Fact]
    public async Task MailboxCoalescesOnlyWithinAVisitAndPreservesButtons()
    {
        using var queue = new InputMailbox();
        queue.Add(new(CommandKind.Move, 2, 3, Generation: 1)); queue.Add(new(CommandKind.Move, 4, 5, Generation: 1));
        queue.Add(new(CommandKind.Button, Code: 1, Down: true, Generation: 1));
        queue.Add(new(CommandKind.Move, 8, 9, Generation: 1)); queue.Add(new(CommandKind.Move, 1, 1, Generation: 2));
        var merged = await queue.TakeAsync(default); Assert.Equal(6, merged.X); Assert.Equal(8, merged.Y);
        Assert.Equal(CommandKind.Button, (await queue.TakeAsync(default)).Kind);
        Assert.Equal(8, (await queue.TakeAsync(default)).X);
        Assert.Equal(2, (await queue.TakeAsync(default)).Generation);
    }
    [Fact]
    public void SettingsRejectCorruptionAtThePersistenceBoundary()
    {
        new Settings().Validate();
        Assert.Throws<InvalidDataException>(() => (new Settings { PointerSpeed = double.NaN }).Validate());
        Assert.Throws<InvalidDataException>(() => (new Settings { ScrollSpeed = 0 }).Validate());
        Assert.Throws<InvalidDataException>(() => (new Settings { Edge = (Edge)255 }).Validate());
    }
    [Fact]
    public void ComposerCollectsEditedUnicodeAndCommitsOnceAtDelimiter() => Sta(() =>
    {
        var sent = new List<InputCommand>();
        var composer = new ControlWindow(true, sent.Add);
        var editor = (TextBox)composer.Content;
        editor.Text = "tieengs"; editor.Text = "tiếng";
        Assert.Empty(sent);
        editor.Text = "tiếng ";
        Assert.Single(sent); Assert.Equal("tiếng ", sent[0].Text);
        Assert.Null(composer.TakePendingText());
        editor.Text = "Việt";
        Assert.Equal("Việt", composer.TakePendingText()); Assert.Null(composer.TakePendingText());
        composer.Close();
    });
    [Fact]
    public void ShortcutTakesPendingComposedTextExactlyOnce() => Sta(() =>
    {
        var sent = new List<InputCommand>(); var composer = new ControlWindow(true, sent.Add);
        var editor = (TextBox)composer.Content; editor.Text = "tiếng Việt";
        Assert.True(composer.TryTakeShortcutText(out var text)); Assert.Equal("tiếng Việt", text);
        Assert.True(composer.TryTakeShortcutText(out var again)); Assert.Null(again); Assert.Empty(sent);
        composer.Close();
    });
    [Fact]
    public void ComposerCancellationDoesNotSendAndOversizeFailsClosed() => Sta(() =>
    {
        var sent = new List<InputCommand>(); var composer = new ControlWindow(true, sent.Add);
        var editor = (TextBox)composer.Content;
        editor.Text = "chưa gửi"; composer.Cancel(); Assert.Null(composer.TakePendingText()); Assert.Empty(sent);
        bool released = false; composer.FocusLost += () => released = true;
        editor.Text = new string('ế', 1400);
        Assert.True(released); Assert.Empty(sent); Assert.Null(composer.TakePendingText());
        composer.Close();
    });
    [Fact]
    public void ComposerObservesCompletionEvenWhenTextBoxHasHandledTextInput() => Sta(() =>
    {
        var sent = new List<InputCommand>(); var composer = new ControlWindow(true, sent.Add);
        var editor = (TextBox)composer.Content;
        var composition = new TextComposition(InputManager.Current, editor, "tiếng");
        editor.RaiseEvent(new TextCompositionEventArgs(Keyboard.PrimaryDevice, composition) { RoutedEvent = TextCompositionManager.PreviewTextInputStartEvent, Handled = true });
        editor.Text = "tiếng "; Assert.Empty(sent);
        editor.RaiseEvent(new TextCompositionEventArgs(Keyboard.PrimaryDevice, composition) { RoutedEvent = TextCompositionManager.TextInputEvent, Handled = true });
        Assert.Equal("tiếng ", composer.TakePendingText());
        composer.Close();
    });
    [Fact]
    public void LocalBackspaceUpDoesNotBecomeAnUnmatchedAndroidKeyUp() => Sta(() =>
    {
        var sent = new List<InputCommand>(); var composer = new ControlWindow(true, sent.Add);
        var editor = (TextBox)composer.Content;
        using var source = new HwndSource(new HwndSourceParameters("DeskBridge test") { Width = 1, Height = 1, WindowStyle = 0 });
        editor.Text = "a";
        editor.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Back) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        editor.Clear();
        editor.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 1, Key.Back) { RoutedEvent = Keyboard.PreviewKeyUpEvent });
        Assert.Empty(sent);
        composer.Close();
    });
    private static void Sta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { action(); } catch (Exception error) { failure = error; } });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
