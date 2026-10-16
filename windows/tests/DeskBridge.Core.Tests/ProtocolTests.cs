using System.Text;
using Xunit;
namespace DeskBridge.Core.Tests;
public class ProtocolTests
{
    [Fact] public void GoldenHostPackets()
    {
        Assert.Equal("01013031323334353637383961626364656630313233343536373839616263646566", Convert.ToHexStringLower(ProtocolEncoder.Hello("0123456789abcdef0123456789abcdef")));
        Assert.Equal("04023f000000", Hex(ProtocolEncoder.Enter(Edge.Top, .5f)));
        Assert.Equal("06", Hex(ProtocolEncoder.Leave()));
        Assert.Equal("113f800000c0000000", Hex(ProtocolEncoder.Move(1, -2)));
        Assert.Equal("120100", Hex(ProtocolEncoder.Button(1, true)));
        Assert.Equal("120201", Hex(ProtocolEncoder.Button(2, false)));
        Assert.Equal("133f000000bf000000", Hex(ProtocolEncoder.Scroll(.5f, -.5f)));
        Assert.Equal("20000000420100001000", Hex(ProtocolEncoder.Key(66, false, 4096)));
        Assert.Equal("210000000541f09f9880", Hex(ProtocolEncoder.Text("A😀")));
        Assert.Equal("3000000000", Hex(ProtocolEncoder.Clipboard("")));
        Assert.Equal("fe", Hex(ProtocolEncoder.Ping()));
    }
    [Fact] public void LimitsCountUtf8Bytes()
    {
        Assert.Equal(4101, ProtocolEncoder.Text(new string('é', 2048)).Length);
        Assert.Throws<ArgumentOutOfRangeException>(() => ProtocolEncoder.Text(new string('é', 2049)));
        Assert.Throws<ArgumentOutOfRangeException>(() => ProtocolEncoder.Clipboard(new string('a', (1 << 20) + 1)));
        Assert.Throws<EncoderFallbackException>(() => ProtocolEncoder.Text("\ud800"));
    }
    [Theory] [InlineData("")] [InlineData("0123456789abcdef0123456789abcdeF01")] [InlineData("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")]
    public void RejectsInvalidToken(string token) => Assert.Throws<ArgumentException>(() => ProtocolEncoder.Hello(token));
    [Fact] public void TokenIsCryptographicHexShape()
    {
        string token = ProtocolEncoder.MakeToken(); Assert.Matches("^[0-9a-f]{32}$", token); Assert.NotEqual(token, ProtocolEncoder.MakeToken());
    }
    [Fact] public void ParsesEveryFragmentBoundaryAndCoalescedMessages()
    {
        byte[] bytes = [2, 0, 0, 4, 56, 0, 0, 7, 128, 0, 0, 0, 1, 5, 0x3f, 0, 0, 0, .. ProtocolEncoder.Clipboard("Việt😀"), 0xff];
        for (int boundary = 0; boundary <= bytes.Length; boundary++)
        {
            var parser = new ServerPacketParser(); var packets = parser.Feed(bytes.AsSpan(0, boundary)).Concat(parser.Feed(bytes.AsSpan(boundary))).ToArray(); parser.Complete();
            Assert.Equal(new ServerPacket[] { new HelloOkPacket(1080, 1920, 1), new ExitPacket(.5f), new ClipboardPacket("Việt😀"), new PongPacket() }, packets);
        }
        var oneByte = new ServerPacketParser(); Assert.Equal(4, bytes.SelectMany(b => oneByte.Feed([b])).Count());
    }
    [Theory] [InlineData("80")] [InlineData("30ffffffff")] [InlineData("3000100001")] [InlineData("3000000001ff")] [InlineData("057fc00000")] [InlineData("02000000000000000100000000")] [InlineData("02000000010000000100000004")]
    public void RejectsMalformedPackets(string hex) => Assert.Throws<InvalidDataException>(() => new ServerPacketParser().Feed(Convert.FromHexString(hex)));
    [Fact] public void RejectsTruncatedEof()
    {
        var parser = new ServerPacketParser(); parser.Feed([0x30, 0, 0, 0, 2, 65]); Assert.Throws<InvalidDataException>(parser.Complete);
    }
    [Fact] public void MaximumClipboardAndEmptyClipboard()
    {
        var parser = new ServerPacketParser(); string text = new('a', 1 << 20);
        Assert.Equal(new ClipboardPacket(text), Assert.Single(parser.Feed(ProtocolEncoder.Clipboard(text))));
        Assert.Equal(new ClipboardPacket(""), Assert.Single(parser.Feed(ProtocolEncoder.Clipboard(""))));
    }
    private static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);
}
