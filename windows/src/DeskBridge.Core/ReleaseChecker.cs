using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace DeskBridge.Core;

public static class ReleaseChecker
{
    public static Uri? NewerWindowsRelease(string json, string currentVersion)
    {
        string withoutBuild = currentVersion.Split('+')[0];
        string[] currentParts = withoutBuild.Split('-', 2);
        bool currentIsPrerelease = currentParts.Length == 2;
        if (!Version.TryParse(currentParts[0], out var current)) throw new InvalidDataException("Invalid version.");
        using var document = JsonDocument.Parse(json);
        Version? best = null; string? bestTag = null;
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            string? tag = release.GetProperty("tag_name").GetString();
            if (tag is null || !tag.StartsWith("windows-v", StringComparison.Ordinal)) continue;
            string raw = tag[9..];
            if (raw.Split('.').Length != 3 || raw.Any(c => c != '.' && (c < '0' || c > '9')) || !Version.TryParse(raw, out var version)) continue;
            if ((version > current || (version == current && currentIsPrerelease)) && (best is null || version > best))
            { best = version; bestTag = tag; }
        }
        return bestTag is null ? null : new Uri("https://github.com/ThanhNg224/DeskBridge/releases/tag/" + bestTag);
    }

    public static async Task<Uri?> CheckWindowsAsync(string currentVersion, CancellationToken ct = default)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("DeskBridge", "1.0"));
        using var response = await client.GetAsync("https://api.github.com/repos/ThanhNg224/DeskBridge/releases?per_page=100", HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests) throw new InvalidOperationException("GitHub limited or refused the request. Try again later.");
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > 2_000_000) throw new InvalidDataException("Release response is too large.");
        await using var input = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var output = new MemoryStream(); byte[] buffer = new byte[16384]; int count;
        while ((count = await input.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
        {
            if (output.Length + count > 2_000_000) throw new InvalidDataException("Release response is too large.");
            await output.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
        }
        return NewerWindowsRelease(Encoding.UTF8.GetString(output.ToArray()), currentVersion);
    }
}
