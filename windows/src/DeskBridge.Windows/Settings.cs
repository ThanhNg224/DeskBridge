using System.Text.Json;
using System.Text.Json.Serialization;
using DeskBridge.Core;
using Microsoft.Win32;

namespace DeskBridge.Windows;

internal sealed record Settings
{
    public string AdbPath { get; init; } = "adb.exe";
    public string? PreferredSerial { get; init; }
    public Edge Edge { get; init; } = Edge.Right;
    public double PointerSpeed { get; init; } = 2;
    public double ScrollSpeed { get; init; } = 1;
    public bool InvertScroll { get; init; }
    public bool RightClickIsBack { get; init; } = true;
    public bool ShareClipboard { get; init; } = true;
    public bool Enabled { get; init; } = true;
    public bool ComposedText { get; init; }
    public bool StartWithWindows { get; init; }
    public string Language { get; init; } = "en";

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(AdbPath) || !Enum.IsDefined(Edge)
            || !double.IsFinite(PointerSpeed) || PointerSpeed is < 0.1 or > 10
            || !double.IsFinite(ScrollSpeed) || ScrollSpeed is < 0.1 or > 10
            || Language is not ("en" or "vi"))
            throw new InvalidDataException("Invalid settings. Speeds must be between 0.1 and 10.");
    }
}

internal static class SettingsStore
{
    internal static readonly string DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeskBridge");
    internal static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static Settings Load()
    {
        if (!File.Exists(FilePath)) return new();
        var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Options)
            ?? throw new InvalidDataException("Empty settings file.");
        settings.Validate();
        return settings;
    }

    public static void Save(Settings settings)
    {
        settings.Validate();
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(settings, Options));
        File.Move(FilePath + ".tmp", FilePath, true);
    }

    public static void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("DeskBridge", $"\"{Environment.ProcessPath}\" --background");
        else key.DeleteValue("DeskBridge", false);
    }
}

internal static class AppLog
{
    // Deliberately accepts operation names, never user text, process arguments or exception messages.
    public static void Write(string operation, Exception? error = null)
    {
        try
        {
            Directory.CreateDirectory(SettingsStore.DirectoryPath);
            var path = Path.Combine(SettingsStore.DirectoryPath, "session.log");
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.Move(path, path + ".previous", true);
            File.AppendAllText(path, $"{DateTimeOffset.UtcNow:O} {operation} {error?.GetType().Name}\n");
        }
        catch (IOException) { /* Logging must not prevent local input restoration. */ }
        catch (UnauthorizedAccessException) { }
    }
}
