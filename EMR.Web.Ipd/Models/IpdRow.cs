using System.Text.Json;

namespace EMR.Web.ApiClients;

/// <summary>Reading IPD rows (JSON objects) in views and controllers.</summary>
public static class IpdRow
{
    public static JsonElement? Prop(this JsonElement row, string name) =>
        row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;

    public static string S(this JsonElement row, string name) => row.Prop(name) is { } v ? (v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : v.ToString()) : "";

    public static int I(this JsonElement row, string name) =>
        row.Prop(name) is { } v ? (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : int.TryParse(v.ToString(), out var j) ? j : 0) : 0;

    public static int? NI(this JsonElement row, string name) => row.Prop(name) is null ? null : row.I(name);

    public static decimal M(this JsonElement row, string name) =>
        row.Prop(name) is { } v ? (v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : decimal.TryParse(v.ToString(), out var d) ? d : 0m) : 0m;

    public static bool B(this JsonElement row, string name) =>
        row.Prop(name) is { } v && (v.ValueKind == JsonValueKind.True || (v.ValueKind == JsonValueKind.Number && v.GetInt32() != 0) || v.ToString() == "true");

    public static DateTime? D(this JsonElement row, string name) =>
        row.Prop(name) is { } v && v.ValueKind == JsonValueKind.String && DateTime.TryParse(v.GetString(), out var d) ? d : null;

    public static string Dt(this JsonElement row, string name, string format = "dd-MMM-yyyy hh:mm tt") => row.D(name)?.ToString(format) ?? "";

    public static string Rs(this decimal v) => "₹" + v.ToString("N2", System.Globalization.CultureInfo.GetCultureInfo("en-IN"));

    public static List<JsonElement> Items(this JsonElement set) =>
        set.ValueKind == JsonValueKind.Array ? set.EnumerateArray().ToList() : new List<JsonElement>();

    public static JsonElement First(this List<JsonElement> sets, int index) =>
        index < sets.Count && sets[index].ValueKind == JsonValueKind.Array && sets[index].GetArrayLength() > 0 ? sets[index][0] : default;

    public static bool Has(this JsonElement row) => row.ValueKind == JsonValueKind.Object;
}
