namespace DeskBridge.Windows;

/// Tracks shortcut key releases even when Alt is released before the main key.
internal sealed class AndroidShortcuts
{
    private readonly Dictionary<uint, (int Code, int Id)> held = new();
    private int nextId, switchId;
    private bool switching, tabHeld, syntheticAlt;
    private const int AltMeta = 0x12;

    public void Reset() { held.Clear(); switching = false; tabHeld = false; }

    public bool Route(uint key, bool down, int meta, bool composed, bool altForwarded, List<InputCommand> result, int altAndroid = 0)
    {
        bool alt = (meta & 0x2) != 0;
        bool onlyAlt = alt && (meta & (0x1 | 0x1000 | 0x10000)) == 0;
        if (key is 0x12 or 0xA4 or 0xA5)
        {
            if (!down && switching && !alt)
            {
                switching = false;
                int releasedAlt = syntheticAlt ? 57 : altAndroid is 57 or 58 ? altAndroid : key == 0xA5 ? 58 : 57;
                result.Add(new(CommandKind.Key, Code: releasedAlt, Meta: 0, ShortcutId: switchId));
                return true;
            }
            return false;
        }
        if (key == 0x09)
        {
            if (!down)
            {
                if (!tabHeld) return false;
                tabHeld = false;
                result.Add(new(CommandKind.Key, Code: 61, Meta: switching ? AltMeta : 0, ShortcutId: switchId));
                return true;
            }
            if (tabHeld) return true;
            if (!switching && !onlyAlt) return false;
            bool start = !switching;
            if (start)
            {
                switching = true; switchId = ++nextId;
                syntheticAlt = composed || !altForwarded;
                if (syntheticAlt)
                {
                    result.Add(new(CommandKind.Key, Code: 57, Down: true, Meta: AltMeta, ShortcutId: switchId, ShortcutStart: true));
                    start = false;
                }
            }
            tabHeld = true;
            result.Add(new(CommandKind.Key, Code: 61, Down: true, Meta: AltMeta, ShortcutId: switchId, ShortcutStart: start));
            return true;
        }
        if (!down)
        {
            if (!held.Remove(key, out var existing)) return false;
            result.Add(new(CommandKind.Key, Code: existing.Code, ShortcutId: existing.Id));
            return true;
        }
        if (held.TryGetValue(key, out var repeat))
        {
            if (key is 0x25 or 0x26 or 0x27 or 0x28)
                result.Add(new(CommandKind.Key, Code: repeat.Code, Down: true, ShortcutId: repeat.Id));
            return true;
        }
        if (!onlyAlt) return false;
        int code = key switch { 0x48 => 3, 0x42 => 4, 0x52 => 187, 0x4C => 223,
            0x26 => 24, 0x28 => 25, 0x27 => 221, 0x25 => 220,
            0x4E => 83, 0x4D => 164, 0x50 => 85, _ => -1 };
        if (code < 0) return false;
        int id = ++nextId; held[key] = (code, id);
        result.Add(new(CommandKind.Key, Code: code, Down: true, ShortcutId: id, ShortcutStart: true));
        return true;
    }
}
