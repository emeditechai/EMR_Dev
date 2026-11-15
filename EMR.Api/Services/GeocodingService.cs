using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Api.Services;

/// <summary>Where an address is on the map.</summary>
public sealed record GeoPoint(decimal Latitude, decimal Longitude, string FormattedAddress, string Source);

public interface IGeocodingService
{
    /// <summary>The point of an address in India, or null when it cannot be found (or the map services cannot be reached).</summary>
    Task<GeoPoint?> GeocodeAsync(string? address, CancellationToken ct = default);
    /// <summary>Up to <paramref name="limit"/> places matching what is typed so far (the address box of Add Doctor).</summary>
    Task<IReadOnlyList<GeoPoint>> SuggestAsync(string? text, int limit = 5, CancellationToken ct = default);
}

/// <summary>
/// Clinic addresses of the Marketing Executive App (SQLScripts/2459). With GoogleMaps:ApiKey configured (the key of EMR.Web's
/// address search, with "Places API (New)" enabled) it uses Google Places Text Search; without a key, or if Google finds
/// nothing or fails, the free OpenStreetMap Nominatim service (one request at a time, as its usage policy asks). The key
/// stays on the server. Answers are cached for a day, so the preview and the save of the same address cost one lookup.
/// </summary>
public sealed class GeocodingService(IHttpClientFactory httpFactory, IConfiguration config, IMemoryCache cache, ILogger<GeocodingService> log)
    : IGeocodingService
{
    private static readonly SemaphoreSlim OsmGate = new(1, 1);
    private string? GoogleKey => config["GoogleMaps:ApiKey"] is { Length: > 0 } k ? k : null;

    public async Task<GeoPoint?> GeocodeAsync(string? address, CancellationToken ct = default)
    {
        address = Clean(address);
        if (address.Length < 5) return null;
        var key = "geocode:" + address.ToLowerInvariant();
        if (cache.TryGetValue(key, out GeoPoint? hit)) return hit;
        var point = (await LookupAsync(address, 1, ct)).FirstOrDefault();
        // a miss is cached for a short time only (the address may be corrected and tried again)
        cache.Set(key, point, point is null ? TimeSpan.FromMinutes(5) : TimeSpan.FromDays(1));
        return point;
    }

    public async Task<IReadOnlyList<GeoPoint>> SuggestAsync(string? text, int limit = 5, CancellationToken ct = default)
    {
        text = Clean(text);
        if (text.Length < 4) return [];
        limit = Math.Clamp(limit, 1, 8);
        var key = $"geosuggest:{limit}:{text.ToLowerInvariant()}";
        if (cache.TryGetValue(key, out IReadOnlyList<GeoPoint>? hit) && hit is not null) return hit;
        var list = await LookupAsync(text, limit, ct);
        cache.Set(key, list, list.Count == 0 ? TimeSpan.FromMinutes(5) : TimeSpan.FromHours(6));
        // a picked suggestion is then saved as the address: its point is already known
        foreach (var p in list) cache.Set("geocode:" + Clean(p.FormattedAddress).ToLowerInvariant(), (GeoPoint?)p, TimeSpan.FromDays(1));
        return list;
    }

    private static string Clean(string? s) => string.Join(' ', (s ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    // Google first (when there is a key), OpenStreetMap when Google has nothing or fails
    private async Task<IReadOnlyList<GeoPoint>> LookupAsync(string text, int limit, CancellationToken ct)
    {
        if (GoogleKey is not null)
        {
            try
            {
                var g = await GoogleAsync(text, limit, ct);
                if (g.Count > 0) return g;
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
            {
                log.LogWarning(ex, "[GEOCODE] Google Places text search failed - using OpenStreetMap");
            }
        }
        try { return await OsmAsync(text, limit, ct); }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            log.LogWarning(ex, "[GEOCODE] OpenStreetMap search failed");
            return [];
        }
    }

    private HttpClient Client()
    {
        var c = httpFactory.CreateClient("Geocoding");
        c.Timeout = TimeSpan.FromSeconds(8);
        if (!c.DefaultRequestHeaders.Contains("User-Agent")) c.DefaultRequestHeaders.Add("User-Agent", "eCare360-EMR/1.0 (clinic address lookup)");
        return c;
    }

    private async Task<IReadOnlyList<GeoPoint>> GoogleAsync(string address, int limit, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://places.googleapis.com/v1/places:searchText")
        {
            Content = JsonContent.Create(new { textQuery = address, regionCode = "in", languageCode = "en", pageSize = limit })
        };
        req.Headers.Add("X-Goog-Api-Key", GoogleKey);
        req.Headers.Add("X-Goog-FieldMask", "places.location,places.formattedAddress,places.displayName");
        using var res = await Client().SendAsync(req, ct);
        if (!res.IsSuccessStatusCode)
        {
            log.LogWarning("[GEOCODE] Google Places text search answered {Status}", (int)res.StatusCode);
            return [];
        }
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        if (!doc.RootElement.TryGetProperty("places", out var places)) return [];
        var list = new List<GeoPoint>();
        foreach (var p in places.EnumerateArray())
        {
            if (!p.TryGetProperty("location", out var loc)) continue;
            var formatted = p.TryGetProperty("formattedAddress", out var f) ? f.GetString() ?? address : address;
            // a named place (a hospital, a clinic, a building) leads with its name
            var name = p.TryGetProperty("displayName", out var d) && d.TryGetProperty("text", out var t) ? t.GetString() : null;
            if (!string.IsNullOrWhiteSpace(name) && !formatted.StartsWith(name, StringComparison.OrdinalIgnoreCase)) formatted = name + ", " + formatted;
            list.Add(new GeoPoint(Round(loc.GetProperty("latitude").GetDouble()), Round(loc.GetProperty("longitude").GetDouble()), formatted, "GOOGLE"));
        }
        return list;
    }

    private async Task<IReadOnlyList<GeoPoint>> OsmAsync(string address, int limit, CancellationToken ct)
    {
        await OsmGate.WaitAsync(ct);
        try
        {
            var url = $"https://nominatim.openstreetmap.org/search?format=jsonv2&limit={limit}&countrycodes=in&q=" + Uri.EscapeDataString(address);
            using var res = await Client().GetAsync(url, ct);
            if (!res.IsSuccessStatusCode) return [];
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            return doc.RootElement.EnumerateArray().Select(p => new GeoPoint(
                Round(double.Parse(p.GetProperty("lat").GetString()!, CultureInfo.InvariantCulture)),
                Round(double.Parse(p.GetProperty("lon").GetString()!, CultureInfo.InvariantCulture)),
                p.TryGetProperty("display_name", out var n) ? n.GetString() ?? address : address, "OSM")).ToList();
        }
        finally
        {
            // Nominatim: at most one request a second
            _ = Task.Delay(1000, CancellationToken.None).ContinueWith(_ => OsmGate.Release(), TaskScheduler.Default);
        }
    }

    private static decimal Round(double v) => Math.Round((decimal)v, 7);
}
