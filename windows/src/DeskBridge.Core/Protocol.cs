using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace DeskBridge.Core;

public enum Edge : byte { Left, Right, Top, Bottom }
public static class ProtocolEncoder
{
    public const int MaxTextBytes = 4096, MaxClipboardBytes = 1 << 20;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public static string MakeToken() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
    public static byte[] Hello(string token)
    {
        if (token.Length != 32 || token.Any(c => !(c is >= '0' and <= '9' or >= 'a' and <= 'f'))) throw new ArgumentException("Invalid session token.");
        return [1, 1, .. Encoding.ASCII.GetBytes(token)];
    }
    public static byte[] Enter(Edge edge, float along)
    {
        if ((byte)edge > 3 || !float.IsFinite(along) || along < 0 || along > 1) throw new ArgumentOutOfRangeException(nameof(along));
        byte[] b = [4, (byte)edge, 0, 0, 0, 0]; WriteFloat(b.AsSpan(2), along); return b;
    }
    public static byte[] Leave() => [6];
    public static byte[] Move(float dx, float dy) => Pair(0x11, dx, dy);
    public static byte[] Scroll(float horizontal, float vertical) => Pair(0x13, horizontal, vertical);
    public static byte[] Button(byte button, bool down) => button is 1 or 2 or 4 ? [0x12, button, down ? (byte)0 : (byte)1] : throw new ArgumentOutOfRangeException(nameof(button));
    public static byte[] Key(int code, bool down, int meta)
    {
        byte[] b = new byte[10]; b[0] = 0x20; BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(1), code); b[5] = down ? (byte)0 : (byte)1; BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(6), meta); return b;
    }
    public static byte[] Text(string value) => StringPacket(0x21, value, MaxTextBytes);
    public static byte[] Clipboard(string value) => StringPacket(0x30, value, MaxClipboardBytes);
    public static byte[] Ping() => [0xfe];
    private static byte[] StringPacket(byte type, string value, int max)
    {
        int length = Utf8.GetByteCount(value); if (length > max) throw new ArgumentOutOfRangeException(nameof(value), "Text exceeds protocol limit.");
        byte[] b = new byte[5 + length]; b[0] = type; BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(1), length); Utf8.GetBytes(value, b.AsSpan(5)); return b;
    }
    private static byte[] Pair(byte type, float a, float b)
    {
        byte[] result = new byte[9]; result[0] = type; WriteFloat(result.AsSpan(1), a); WriteFloat(result.AsSpan(5), b); return result;
    }
    private static void WriteFloat(Span<byte> target, float value)
    {
        if (!float.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        BinaryPrimitives.WriteInt32BigEndian(target, BitConverter.SingleToInt32Bits(value));
    }
}
public abstract record ServerPacket;
public sealed record HelloOkPacket(int Width, int Height, int Rotation) : ServerPacket;
public sealed record ExitPacket(float Along) : ServerPacket;
public sealed record ClipboardPacket(string Text) : ServerPacket;
public sealed record PongPacket : ServerPacket;
public sealed class ServerPacketParser
{
    private byte[] buffer = new byte[4096];
    private int count;
    public IReadOnlyList<ServerPacket> Feed(ReadOnlySpan<byte> data)
    {
        List<ServerPacket> packets = [];
        // Incremental append keeps allocation bounded even for large/coalesced network reads.
        foreach (byte next in data)
        {
            if (count == buffer.Length) Array.Resize(ref buffer, Math.Min(buffer.Length * 2, ProtocolEncoder.MaxClipboardBytes + 5));
            buffer[count++] = next;
            int size = buffer[0] switch { 2 => 13, 5 => 5, 0x30 => count < 5 ? 5 : ClipboardSize(), 0xff => 1, _ => throw new InvalidDataException("Unknown server packet.") };
            if (count != size) continue;
            packets.Add(Parse()); count = 0;
        }
        return packets;
    }
    public void Complete() { if (count != 0) throw new InvalidDataException("Truncated server packet."); }
    private int ClipboardSize()
    {
        int length = ReadInt(1); if (length < 0 || length > ProtocolEncoder.MaxClipboardBytes) throw new InvalidDataException("Invalid clipboard length."); return 5 + length;
    }
    private int ReadInt(int offset) => BinaryPrimitives.ReadInt32BigEndian(buffer.AsSpan(offset, 4));
    private ServerPacket Parse()
    {
        switch (buffer[0])
        {
            case 2:
                int width = ReadInt(1), height = ReadInt(5), rotation = ReadInt(9);
                if (width <= 0 || height <= 0 || rotation is < 0 or > 3) throw new InvalidDataException("Invalid display geometry.");
                return new HelloOkPacket(width, height, rotation);
            case 5:
                float along = BitConverter.Int32BitsToSingle(ReadInt(1));
                if (!float.IsFinite(along) || along < 0 || along > 1) throw new InvalidDataException("Invalid exit coordinate.");
                return new ExitPacket(along);
            case 0x30:
                try { return new ClipboardPacket(new UTF8Encoding(false, true).GetString(buffer, 5, count - 5)); }
                catch (DecoderFallbackException) { throw new InvalidDataException("Invalid clipboard encoding."); }
            default: return new PongPacket();
        }
    }
}
