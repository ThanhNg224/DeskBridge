namespace DeskBridge.Windows;

internal static class KeyboardMap
{
    public static int Android(uint key, uint scan = 0, uint flags = 0)
    {
        if (key is >= 0x41 and <= 0x5A) return 29 + (int)(key - 0x41);
        if (key is >= 0x30 and <= 0x39) return 7 + (int)(key - 0x30);
        if (key is >= 0x60 and <= 0x69) return 144 + (int)(key - 0x60);
        if (key is >= 0x70 and <= 0x7B) return 131 + (int)(key - 0x70);
        return key switch
        {
            0x08 => 67, 0x09 => 61, 0x0D => (flags & 1) != 0 ? 160 : 66,
            0x10 => scan == 0x36 ? 60 : 59, 0xA0 => 59, 0xA1 => 60,
            0x11 => (flags & 1) != 0 ? 114 : 113, 0xA2 => 113, 0xA3 => 114,
            0x12 => (flags & 1) != 0 ? 58 : 57, 0xA4 => 57, 0xA5 => 58,
            0x13 => 121, 0x14 => 115, 0x1B => 111, 0x20 => 62,
            0x21 => 92, 0x22 => 93, 0x23 => 123, 0x24 => 122,
            0x25 => 21, 0x26 => 19, 0x27 => 22, 0x28 => 20,
            0x2C => 120, 0x2D => 124, 0x2E => 112, 0x5B => 117, 0x5C => 118,
            0x5D => 82, 0x6A => 155, 0x6B => 157, 0x6D => 156, 0x6E => 158, 0x6F => 154,
            0x90 => 143, 0x91 => 116,
            0xBA => 74, 0xBB => 70, 0xBC => 55, 0xBD => 69, 0xBE => 56,
            0xBF => 76, 0xC0 => 68, 0xDB => 71, 0xDC => 73, 0xDD => 72, 0xDE => 75,
            _ => -1
        };
    }

    public static int Meta(ISet<uint> pressed)
    {
        int state = 0;
        if (pressed.Contains(0x10) || pressed.Contains(0xA0) || pressed.Contains(0xA1)) state |= 0x1 | 0x40;
        if (pressed.Contains(0x11) || pressed.Contains(0xA2) || pressed.Contains(0xA3)) state |= 0x1000 | 0x2000;
        if (pressed.Contains(0x12) || pressed.Contains(0xA4) || pressed.Contains(0xA5)) state |= 0x2 | 0x10;
        if (pressed.Contains(0x5B) || pressed.Contains(0x5C)) state |= 0x10000 | 0x20000;
        return state;
    }
}
