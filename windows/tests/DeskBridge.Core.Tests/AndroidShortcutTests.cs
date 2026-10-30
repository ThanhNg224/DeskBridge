using DeskBridge.Windows;
using Xunit;

namespace DeskBridge.Core.Tests;

public sealed class AndroidShortcutTests
{
    [Theory]
    [InlineData(0x48u, 3)] [InlineData(0x42u, 4)] [InlineData(0x52u, 187)]
    [InlineData(0x4Cu, 223)] [InlineData(0x26u, 24)] [InlineData(0x28u, 25)]
    [InlineData(0x27u, 221)] [InlineData(0x25u, 220)] [InlineData(0x4Eu, 83)]
    [InlineData(0x4Du, 164)] [InlineData(0x50u, 85)]
    public void ShortcutRemainsPairedWhenAltReleasedFirst(uint key, int android)
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.True(router.Route(key, true, 0x12, false, true, result));
        Assert.Single(result); Assert.Equal(android, result[0].Code); Assert.True(result[0].Down); Assert.True(result[0].ShortcutStart);
        int id = result[0].ShortcutId; result.Clear();
        Assert.True(router.Route(key, false, 0, false, false, result));
        Assert.Single(result); Assert.Equal(android, result[0].Code); Assert.False(result[0].Down); Assert.Equal(id, result[0].ShortcutId);
    }

    [Fact]
    public void ComposedAltTabKeepsAltDownAcrossMultipleTabPresses()
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.True(router.Route(9, true, 0x12, true, false, result));
        Assert.Equal(new[] { 57, 61 }, result.Select(x => x.Code));
        Assert.All(result, x => Assert.True(x.Down)); Assert.True(result[0].ShortcutStart);
        int id = result[0].ShortcutId; Assert.All(result, x => Assert.Equal(id, x.ShortcutId)); result.Clear();
        Assert.True(router.Route(9, true, 0x12, true, false, result)); Assert.Empty(result);
        Assert.True(router.Route(9, false, 0x12, true, false, result)); Assert.Equal(61, result[0].Code); Assert.False(result[0].Down); result.Clear();
        Assert.True(router.Route(9, true, 0x12, true, false, result)); Assert.Single(result); Assert.Equal(61, result[0].Code); result.Clear();
        Assert.True(router.Route(0xA4, false, 0, true, false, result)); Assert.Single(result); Assert.Equal(57, result[0].Code); Assert.False(result[0].Down); result.Clear();
        Assert.True(router.Route(9, false, 0, true, false, result)); Assert.Single(result); Assert.Equal(61, result[0].Code); Assert.Equal(0, result[0].Meta);
    }

    [Fact]
    public void DirectAltTabUsesAlreadyForwardedAltAndLeavesOtherCombosAlone()
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.False(router.Route(0x48, true, 0x3012, false, true, result));
        Assert.False(router.Route(0x48, true, 0, false, true, result));
        Assert.True(router.Route(9, true, 0x12, false, true, result));
        Assert.Single(result); Assert.Equal(61, result[0].Code); Assert.True(result[0].ShortcutStart);
        router.Reset(); result.Clear();
        Assert.False(router.Route(9, false, 0, false, false, result));
    }
    [Fact]
    public void RightAltIsReleasedWithItsOriginalAndroidKey()
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.True(router.Route(9, true, 0x12, false, true, result)); result.Clear();
        Assert.True(router.Route(9, false, 0x12, false, true, result)); result.Clear();
        Assert.True(router.Route(0x12, false, 0, false, true, result, altAndroid: 58));
        Assert.Single(result); Assert.Equal(58, result[0].Code); Assert.False(result[0].Down);
    }

    [Theory]
    [InlineData(0x26u, 24)] [InlineData(0x28u, 25)]
    [InlineData(0x27u, 221)] [InlineData(0x25u, 220)]
    public void HoldingAdjustmentRepeatsWithoutStartingAnotherShortcut(uint key, int android)
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.True(router.Route(key, true, 0x12, false, true, result)); int id = result[0].ShortcutId; result.Clear();
        Assert.True(router.Route(key, true, 0x12, false, true, result));
        Assert.Single(result); Assert.Equal(android, result[0].Code); Assert.True(result[0].Down); Assert.False(result[0].ShortcutStart); Assert.Equal(id, result[0].ShortcutId);
    }

    [Theory]
    [InlineData(0x4Eu)] [InlineData(0x4Du)] [InlineData(0x50u)]
    public void HoldingToggleDoesNotRepeat(uint key)
    {
        var router = new AndroidShortcuts(); var result = new List<InputCommand>();
        Assert.True(router.Route(key, true, 0x12, false, true, result)); result.Clear();
        Assert.True(router.Route(key, true, 0x12, false, true, result)); Assert.Empty(result);
    }

}
