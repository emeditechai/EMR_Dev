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
        address = string.Join(' ', (address ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (address.Length < 5) return null;
        var key = "geocode:" + address.ToLowerInvariant();
        if (cache.TryGetValue(key, out GeoPoint? hit)) return hit;

        GeoPoint? point = null;
        if (GoogleKey is not null)
        {
            try { point = await GoogleAsync(address, ct); }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
            {
                log.LogWarning(ex, "[GEOCODE] Google Places text search failed - using OpenStreetMap");
            }
        }
        if (point is null)
        {
            try { point = await OsmAsync(address, ct); }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
            {
                log.LogWarning(ex, "[GEOCODE] OpenStreetMap search failed");
            }
        }
        // a miss is cached for a short time only (the address may be corrected and tried again)
        cache.Set(key, point, point is null ? TimeSpan.FromMinutes(5) : TimeSpan.FromDays(1));
        return point;
    }

    private HttpClient Client()
    {
        var c = httpFactory.CreateClient("Geocoding");
        c.Timeout = TimeSpan.FromSeconds(8);
        if (!c.DefaultRequestHeaders.Contains("User-Agent")) c.DefaultRequestHeaders.Add("User-Agent", "eCare360-EMR/1.0 (clinic address lookup)");
        return c;
    }

    private async Task<GeoPoint?> GoogleAsync(string address, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://places.googleapis.com/v1/places:searchText")
        {
            Content = JsonContent.Create(new { textQuery = address, regionCode = "in", languageCode = "en", pageSize = 1 })
        };
        req.Headers.Add("X-Goog-Api-Key", GoogleKey);
        req.Headers.Add("X-Goog-FieldMask", "places.location,places.formattedAddress");
        using var res = await Client().SendAsync(req, ct);
        if (!res.IsSuccessStatusCode)
        {
            log.LogWarning("[GEOCODE] Google Places text search answered {Status}", (int)res.StatusCode);
            return null;
        }
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        if (!doc.RootElement.TryGetProperty("places", out var places) || places.GetArrayLength() == 0) return null;
        var p = places[0];
        if (!p.TryGetProperty("location", out var loc)) return null;
        return new GeoPoint(Round(loc.GetProperty("latitude").GetDouble()), Round(loc.GetProperty("longitude").GetDouble()),
            p.TryGetProperty("formattedAddress", out var f) ? f.GetString() ?? address : address, "GOOGLE");
    }

    private async Task<GeoPoint?> OsmAsync(string address, CancellationToken ct)
    {
        await OsmGate.WaitAsync(ct);
        try
        {
            var url = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&countrycodes=in&q=" + Uri.EscapeDataString(address);
            using var res = await Client().GetAsync(url, ct);
            if (!res.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0) return null;
            var p = doc.RootElement[0];
            return new GeoPoint(Round(double.Parse(p.GetProperty("lat").GetString()!, CultureInfo.InvariantCulture)),
                Round(double.Parse(p.GetProperty("lon").GetString()!, CultureInfo.InvariantCulture)),
                p.TryGetProperty("display_name", out var n) ? n.GetString() ?? address : address, "OSM");
        }
        finally
        {
            // Nominatim: at most one request a second
            _ = Task.Delay(1000, CancellationToken.None).ContinueWith(_ => OsmGate.Release(), TaskScheduler.Default);
        }
    }

    private static decimal Round(double v) => Math.Round((decimal)v, 7);
}
