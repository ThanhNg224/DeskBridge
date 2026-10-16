using System.Runtime.InteropServices;
using DeskBridge.Core;

namespace DeskBridge.Windows;

internal sealed record DisplayArea(Native.Rect Bounds, bool Primary, uint DpiX = 96, uint DpiY = 96);

internal static class DesktopGeometry
{
    public static IReadOnlyList<DisplayArea> Read()
    {
        var displays = new List<DisplayArea>();
        Native.MonitorProc callback = (nint monitor, nint _, ref Native.Rect bounds, nint data) =>
        {
            var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
            if (!Native.GetMonitorInfo(monitor, ref info)) throw new System.ComponentModel.Win32Exception();
            Marshal.ThrowExceptionForHR(Native.GetDpiForMonitor(monitor, 0, out uint dpiX, out uint dpiY));
            displays.Add(new(info.Monitor, (info.Flags & 1) != 0, dpiX, dpiY));
            return true;
        };
        if (!Native.EnumDisplayMonitors(0, 0, callback, 0)) throw new System.ComponentModel.Win32Exception();
        return displays;
    }

    public static DisplayArea? Crossing(IReadOnlyList<DisplayArea> displays, Native.Point p, Native.Point previous, Edge edge)
    {
        foreach (var display in displays)
        {
            var b = display.Bounds;
            if (p.X < b.Left || p.X >= b.Right || p.Y < b.Top || p.Y >= b.Bottom) continue;
            var crossing = edge switch
            {
                Edge.Left => p.X <= b.Left && p.X < previous.X,
                Edge.Right => p.X >= b.Right - 1 && p.X > previous.X,
                Edge.Top => display.Primary && p.Y <= b.Top && p.Y < previous.Y,
                Edge.Bottom => display.Primary && p.Y >= b.Bottom - 1 && p.Y > previous.Y,
                _ => false
            };
            if (!crossing) continue;
            var beyond = edge switch
            {
                Edge.Left => new Native.Point(b.Left - 1, p.Y),
                Edge.Right => new Native.Point(b.Right, p.Y),
                Edge.Top => new Native.Point(p.X, b.Top - 1),
                _ => new Native.Point(p.X, b.Bottom)
            };
            if (!displays.Any(d => Contains(d.Bounds, beyond))) return display;
        }
        return null;
    }

    internal static bool Contains(Native.Rect b, Native.Point p) => p.X >= b.Left && p.X < b.Right && p.Y >= b.Top && p.Y < b.Bottom;
    public static float Along(Native.Rect b, Native.Point p, Edge edge) => Math.Clamp(
        edge is Edge.Left or Edge.Right ? (float)(p.Y - b.Top) / b.Height : (float)(p.X - b.Left) / b.Width, 0, 1);
    public static Edge Opposite(Edge edge) => edge switch { Edge.Left => Edge.Right, Edge.Right => Edge.Left, Edge.Top => Edge.Bottom, _ => Edge.Top };
    public static Native.Point Return(Native.Rect b, Edge edge, float along) => edge switch
    {
        Edge.Left => new(b.Left + 12, b.Top + (int)(Math.Clamp(along, 0, 1) * (b.Height - 1))),
        Edge.Right => new(b.Right - 13, b.Top + (int)(Math.Clamp(along, 0, 1) * (b.Height - 1))),
        Edge.Top => new(b.Left + (int)(Math.Clamp(along, 0, 1) * (b.Width - 1)), b.Top + 12),
        _ => new(b.Left + (int)(Math.Clamp(along, 0, 1) * (b.Width - 1)), b.Bottom - 13)
    };
}
