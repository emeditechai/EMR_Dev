using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.Services;

/// <summary>One address suggestion for the Home Collection Address box (LAB B2C / B2B booking).</summary>
public class GeoAddressSuggestion
{
    public string Name { get; set; } = "";
    public string Secondary { get; set; } = "";
    public string FullAddress { get; set; } = "";
    /// <summary>0 for a Google suggestion until it is picked (the coordinates come from <see cref="GeoAddressService.PlaceDetailsAsync"/>).</summary>
    public double Latitude { get; set; }
    public double Longitude { get; set; }
    public string City { get; set; } = "";
    public string District { get; set; } = "";
    public string State { get; set; } = "";
    public string Postcode { get; set; } = "";
    public string Country { get; set; } = "";
    /// <summary>Google place id (Google suggestions only).</summary>
    public string? PlaceId { get; set; }
    public string Source { get; set; } = "";
    internal int Score { get; set; }
}

/// <summary>
/// Address search for home collection. With GoogleMaps:ApiKey configured (Google Cloud key with the "Places API (New)"
/// enabled) it uses Google Places Autocomplete - India only, biased to the selected district / city, one billing session
/// per address (autocomplete + the details of the picked place), which keeps normal clinic use inside Google's monthly
/// free allowance. Without a key, or if Google fails, it uses the free OpenStreetMap services (Photon and Nominatim) in
/// parallel, biased the same way, merged and ranked by how well they match the words typed. Answers are cached.
/// The key stays on the server.
/// </summary>
public class GeoAddressService(IHttpClientFactory httpFactory, IConfiguration config, IMemoryCache cache, ILogger<GeoAddressService> log)
{
    private string? GoogleKey => config["GoogleMaps:ApiKey"] is { Length: > 0 } k ? k : null;
    public bool GoogleEnabled => GoogleKey is not null;

    private static readonly HashSet<string> Filler = new(StringComparer.OrdinalIgnoreCase)
    {
        "road", "rd", "street", "st", "lane", "ln", "near", "opp", "opposite", "beside", "behind", "po", "ps", "dist",
        "district", "vill", "village", "flat", "floor", "house", "hno", "no", "india", "the", "and"
    };

    private HttpClient Client(int seconds = 6)
    {
        var c = httpFactory.CreateClient("GeoAddress");
        c.Timeout = TimeSpan.FromSeconds(seconds);
        if (!c.DefaultRequestHeaders.Contains("User-Agent")) c.DefaultRequestHeaders.Add("User-Agent", "eCare360-EMR/1.0 (home collection address search)");
        return c;
    }

    public async Task<List<GeoAddressSuggestion>> SearchAsync(string query, string? country, string? state, string? district, string? city,
        string? sessionToken, CancellationToken ct, bool allowGoogle = true)
    {
        query = (query ?? "").Trim();
        var useGoogle = allowGoogle && GoogleEnabled;
        if (query.Length < 3) return [];
        state = Clean(state); district = Clean(district); city = Clean(city);
        var key = $"geo:q:{query.ToLowerInvariant()}|{state}|{district}|{city}|{useGoogle}";
        if (cache.TryGetValue(key, out List<GeoAddressSuggestion>? cached) && cached is not null) return cached;

        var bias = await BiasAsync(state, district, city, ct);
        List<GeoAddressSuggestion> result = [];
        if (useGoogle)
        {
            try { result = await GoogleAutocompleteAsync(query, bias, sessionToken, ct); }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
            {
                log.LogWarning(ex, "Google Places autocomplete failed - using OpenStreetMap");
            }
        }
        if (result.Count == 0) result = await OsmSearchAsync(query, state, district, city, bias, ct);

        // Google suggestions are not cached (session billing); free results are, for an hour
        if (result.Count > 0 && result.All(r => r.PlaceId is null))
            cache.Set(key, result, TimeSpan.FromHours(1));
        return result;
    }

    // ── Google Places (New) ─────────────────────────────────────────────────────────────────────────────────
    private async Task<List<GeoAddressSuggestion>> GoogleAutocompleteAsync(string query, (double Lat, double Lon)? bias, string? session, CancellationToken ct)
    {
        var body = new Dictionary<string, object?>
        {
            ["input"] = query,
            ["includedRegionCodes"] = new[] { "in" },
            ["languageCode"] = "en",
            ["sessionToken"] = string.IsNullOrWhiteSpace(session) ? null : session
        };
        if (bias is { } b)
            body["locationBias"] = new { circle = new { center = new { latitude = b.Lat, longitude = b.Lon }, radius = 30000.0 } };

        using var req = new HttpRequestMessage(HttpMethod.Post, "https://places.googleapis.com/v1/places:autocomplete") { Content = JsonContent.Create(body) };
        req.Headers.Add("X-Goog-Api-Key", GoogleKey);
        using var res = await Client().SendAsync(req, ct);
        if (!res.IsSuccessStatusCode)
        {
            log.LogWarning("Google Places autocomplete answered {Status}: {Body}", (int)res.StatusCode, Trunc(await res.Content.ReadAsStringAsync(ct), 300));
            return [];
        }
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var list = new List<GeoAddressSuggestion>();
        if (doc.RootElement.TryGetProperty("suggestions", out var sugs))
            foreach (var s in sugs.EnumerateArray())
            {
                if (!s.TryGetProperty("placePrediction", out var p)) continue;
                var main = Str(p, "structuredFormat", "mainText", "text") ?? Str(p, "text", "text") ?? "";
                var sec = Str(p, "structuredFormat", "secondaryText", "text") ?? "";
                list.Add(new GeoAddressSuggestion
                {
                    PlaceId = Str(p, "placeId"), Name = main, Secondary = sec,
                    FullAddress = Str(p, "text", "text") ?? (sec.Length > 0 ? $"{main}, {sec}" : main), Source = "google"
                });
            }
        return list;
    }

    /// <summary>The picked Google place: coordinates and the formatted address (closes the billing session).</summary>
    public async Task<GeoAddressSuggestion?> PlaceDetailsAsync(string placeId, string? session, CancellationToken ct)
    {
        if (!GoogleEnabled || string.IsNullOrWhiteSpace(placeId)) return null;
        var key = "geo:p:" + placeId;
        if (cache.TryGetValue(key, out GeoAddressSuggestion? hit) && hit is not null) return hit;
        var url = $"https://places.googleapis.com/v1/places/{Uri.EscapeDataString(placeId)}" +
                  (string.IsNullOrWhiteSpace(session) ? "" : "?sessionToken=" + Uri.EscapeDataString(session));
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Add("X-Goog-Api-Key", GoogleKey);
        req.Headers.Add("X-Goog-FieldMask", "id,displayName,formattedAddress,location,addressComponents");
        try
        {
            using var res = await Client().SendAsync(req, ct);
            if (!res.IsSuccessStatusCode) { log.LogWarning("Google place details answered {Status}", (int)res.StatusCode); return null; }
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            var r = doc.RootElement;
            string Comp(string type)
            {
                if (!r.TryGetProperty("addressComponents", out var comps)) return "";
                foreach (var c in comps.EnumerateArray())
                    if (c.TryGetProperty("types", out var t) && t.EnumerateArray().Any(x => x.GetString() == type))
                        return c.TryGetProperty("longText", out var lt) ? lt.GetString() ?? "" : "";
                return "";
            }
            var item = new GeoAddressSuggestion
            {
                PlaceId = placeId, Name = Str(r, "displayName", "text") ?? "", FullAddress = Str(r, "formattedAddress") ?? "",
                Latitude = r.TryGetProperty("location", out var loc) ? loc.GetProperty("latitude").GetDouble() : 0,
                Longitude = r.TryGetProperty("location", out var loc2) ? loc2.GetProperty("longitude").GetDouble() : 0,
                City = Comp("locality"), District = Comp("administrative_area_level_3") is { Length: > 0 } d3 ? d3 : Comp("administrative_area_level_2"),
                State = Comp("administrative_area_level_1"), Postcode = Comp("postal_code"), Country = Comp("country"), Source = "google"
            };
            cache.Set(key, item, TimeSpan.FromDays(7));
            return item;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException)
        {
            log.LogWarning(ex, "Google place details failed");
            return null;
        }
    }

    // ── OpenStreetMap (free): Photon + Nominatim in parallel ────────────────────────────────────────────────
    private async Task<List<GeoAddressSuggestion>> OsmSearchAsync(string query, string? state, string? district, string? city,
        (double Lat, double Lon)? bias, CancellationToken ct)
    {
        // the typed words only: the chosen area biases the search (it would filter results out if added to the words)
        var all = await OsmQueryAsync(query, bias, includeNominatim: true, ct);

        // few hits: Indian locality spellings - "Kachari para" is mapped as "Kacharipara" (para / pally / nagar / pur / gram
        // joined to the word before), and the most distinctive word alone
        if (all.Count < 3)
        {
            var variants = new List<string>();
            var joined = System.Text.RegularExpressions.Regex.Replace(query, @"(?i)\b(\w{3,})\s+(para|pally|palli|nagar|pur|gram|ganj|bagan|tala|danga)\b", "$1$2");
            if (!joined.Equals(query, StringComparison.OrdinalIgnoreCase)) variants.Add(joined);
            var longest = query.Split([' ', ',', '-', '/', '.'], StringSplitOptions.RemoveEmptyEntries)
                .Where(t => t.Length >= 4 && !Filler.Contains(t)).OrderByDescending(t => t.Length).FirstOrDefault();
            if (longest is not null && !longest.Equals(query, StringComparison.OrdinalIgnoreCase)) variants.Add(longest);
            var more = await Task.WhenAll(variants.Distinct(StringComparer.OrdinalIgnoreCase).Take(2).Select(v => OsmQueryAsync(v, bias, includeNominatim: false, ct)));
            all.AddRange(more.SelectMany(x => x));
        }

        // rank: how many typed words match, then the chosen state / district, then nearness to the area
        var tokens = query.Split([' ', ',', '-', '/', '.'], StringSplitOptions.RemoveEmptyEntries)
            .Where(t => t.Length >= 3 && !Filler.Contains(t)).Select(t => t.ToLowerInvariant()).Distinct().ToList();
        foreach (var s in all)
        {
            var hay = (s.Name + " " + s.Secondary).ToLowerInvariant();
            s.Score = tokens.Count(t => hay.Contains(t)) * 10
                      + tokens.Count(t => s.Name.ToLowerInvariant().Contains(t)) * 5
                      + (state is not null && s.State.Equals(state, StringComparison.OrdinalIgnoreCase) ? 4 : 0)
                      + (district is not null && hay.Contains(district.ToLowerInvariant()) ? 3 : 0)
                      + (bias is { } bb && Math.Abs(s.Latitude - bb.Lat) < 0.3 && Math.Abs(s.Longitude - bb.Lon) < 0.3 ? 3 : 0);
        }
        return all
            .Where(s => s.Latitude != 0 && s.Longitude != 0)
            .GroupBy(s => $"{s.Name.ToLowerInvariant()}|{Math.Round(s.Latitude, 3)}|{Math.Round(s.Longitude, 3)}")
            .Select(g => g.OrderByDescending(x => x.Secondary.Length).First())
            .OrderByDescending(s => s.Score)
            .Take(8)
            .ToList();
    }

    private async Task<List<GeoAddressSuggestion>> OsmQueryAsync(string q, (double Lat, double Lon)? bias, bool includeNominatim, CancellationToken ct)
    {
        var photonUrl = $"https://photon.komoot.io/api/?q={Uri.EscapeDataString(q)}&limit=12&lang=en" +
                        (bias is { } b ? $"&lat={F(b.Lat)}&lon={F(b.Lon)}&location_bias_scale=0.3&zoom=12" : "");
        var nomUrl = $"https://nominatim.openstreetmap.org/search?q={Uri.EscapeDataString(q)}" +
                     "&format=jsonv2&addressdetails=1&countrycodes=in&limit=8&accept-language=en" +
                     (bias is { } v ? $"&viewbox={F(v.Lon - 0.4)},{F(v.Lat + 0.4)},{F(v.Lon + 0.4)},{F(v.Lat - 0.4)}" : "");

        var photonTask = SafeGetAsync(photonUrl, ct);
        var nomTask = includeNominatim ? SafeGetAsync(nomUrl, ct) : Task.FromResult<string?>(null);
        await Task.WhenAll(photonTask, nomTask);

        var all = new List<GeoAddressSuggestion>();
        if (photonTask.Result is { } pj)
        {
            using var doc = JsonDocument.Parse(pj);
            if (doc.RootElement.TryGetProperty("features", out var feats))
                foreach (var f in feats.EnumerateArray())
                {
                    var p = f.GetProperty("properties");
                    if (Str(p, "countrycode") is { } cc && !cc.Equals("IN", StringComparison.OrdinalIgnoreCase)) continue;
                    var coords = f.GetProperty("geometry").GetProperty("coordinates");
                    var name = Str(p, "name") ?? Str(p, "street") ?? "";
                    var street = Str(p, "street") is { } st ? (Str(p, "housenumber") is { } hn ? $"{hn} {st}" : st) : null;
                    all.Add(Build(name, street, Str(p, "locality") ?? Str(p, "district"), Str(p, "city"), Str(p, "county"), Str(p, "state"),
                        Str(p, "postcode"), Str(p, "country") ?? "India", coords[1].GetDouble(), coords[0].GetDouble(), "osm"));
                }
        }
        if (nomTask.Result is { } nj)
        {
            using var doc = JsonDocument.Parse(nj);
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
                foreach (var n in doc.RootElement.EnumerateArray())
                {
                    var a = n.TryGetProperty("address", out var aa) ? aa : default;
                    string? A(string k) => a.ValueKind == JsonValueKind.Object ? Str(a, k) : null;
                    var name = Str(n, "name") is { Length: > 0 } nm ? nm : (Str(n, "display_name") ?? "").Split(',')[0];
                    all.Add(Build(name, A("road"), A("suburb") ?? A("neighbourhood") ?? A("village"), A("city") ?? A("town"),
                        A("state_district") ?? A("county"), A("state"), A("postcode"), A("country") ?? "India",
                        double.Parse(Str(n, "lat") ?? "0", CultureInfo.InvariantCulture), double.Parse(Str(n, "lon") ?? "0", CultureInfo.InvariantCulture), "osm"));
                }
        }

        return all;
    }

    /// <summary>Centre of the chosen city / district / state (geocoded once, cached a week) to bias the search.</summary>
    private async Task<(double Lat, double Lon)?> BiasAsync(string? state, string? district, string? city, CancellationToken ct)
    {
        var place = string.Join(", ", new[] { city, district, state }.Where(x => !string.IsNullOrWhiteSpace(x)));
        if (place.Length == 0) return null;
        var key = "geo:b:" + place.ToLowerInvariant();
        if (cache.TryGetValue(key, out (double, double)? hit)) return hit;
        (double, double)? result = null;
        var json = await SafeGetAsync($"https://photon.komoot.io/api/?q={Uri.EscapeDataString(place + ", India")}&limit=1&lang=en", ct);
        if (json is not null)
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("features", out var f) && f.GetArrayLength() > 0)
            {
                var c = f[0].GetProperty("geometry").GetProperty("coordinates");
                result = (c[1].GetDouble(), c[0].GetDouble());
            }
        }
        cache.Set(key, result, TimeSpan.FromDays(7));
        return result;
    }

    private async Task<string?> SafeGetAsync(string url, CancellationToken ct)
    {
        try
        {
            using var res = await Client().GetAsync(url, ct);
            return res.IsSuccessStatusCode ? await res.Content.ReadAsStringAsync(ct) : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            log.LogDebug(ex, "Address lookup failed: {Url}", url);
            return null;
        }
    }

    private static GeoAddressSuggestion Build(string name, string? street, string? locality, string? city, string? district, string? state,
        string? postcode, string country, double lat, double lon, string source)
    {
        var parts = new List<string>();
        void Add(string? v) { if (!string.IsNullOrWhiteSpace(v) && !v.Equals(name, StringComparison.OrdinalIgnoreCase) && !parts.Contains(v)) parts.Add(v); }
        Add(street); Add(locality); Add(city); Add(district);
        Add(string.IsNullOrWhiteSpace(state) ? null : (string.IsNullOrWhiteSpace(postcode) ? state : $"{state} {postcode}"));
        Add(country);
        var secondary = string.Join(", ", parts);
        return new GeoAddressSuggestion
        {
            Name = string.IsNullOrWhiteSpace(name) ? secondary : name, Secondary = secondary,
            FullAddress = secondary.Length > 0 ? $"{name}, {secondary}" : name,
            Latitude = lat, Longitude = lon, City = city ?? "", District = district ?? "", State = state ?? "", Postcode = postcode ?? "",
            Country = country, Source = source
        };
    }

    private static string? Str(JsonElement e, params string[] path)
    {
        foreach (var p in path)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(p, out e)) return null;
        }
        return e.ValueKind == JsonValueKind.String ? e.GetString() : e.ValueKind is JsonValueKind.Number ? e.ToString() : null;
    }

    private static string? Clean(string? v) => string.IsNullOrWhiteSpace(v) || v.Trim().StartsWith("--") ? null : v.Trim();
    private static string F(double d) => d.ToString("0.#####", CultureInfo.InvariantCulture);
    private static string Trunc(string s, int n) => s.Length <= n ? s : s[..n];
}
