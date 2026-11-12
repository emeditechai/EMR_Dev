using System.Globalization;
using System.Text.Json;
using QRCoder;

namespace EMR.Web.Services;

/// <summary>A branch's UPI QR setup (Settings > Payment QR Configuration, SQLScripts/2452).</summary>
public sealed record UpiQrConfig(string UpiId, string PayeeName, string? MerchantCode, string AmountMode, bool IncludeReference, string? Caption, bool IsActive)
{
    public static UpiQrConfig? From(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Object) return null;
        string? S(string n) => row.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        bool B(string n) => row.TryGetProperty(n, out var v) && (v.ValueKind == JsonValueKind.True || (v.ValueKind == JsonValueKind.Number && v.GetInt32() != 0));
        var upi = S("UpiId");
        return string.IsNullOrWhiteSpace(upi) ? null
            : new UpiQrConfig(upi!, S("PayeeName") ?? "", S("MerchantCode"), S("AmountMode") ?? "DUE", B("IncludeReference"), S("Caption"), B("IsActive"));
    }
}

/// <summary>A standard UPI payment QR (NPCI "upi://pay" link) that any UPI app scans, drawn as a PNG data URI.</summary>
public static class UpiQr
{
    /// <summary>upi://pay?pa=..&amp;pn=..[&amp;mc=..][&amp;am=..]&amp;cu=INR[&amp;tn=..]. The amount is set only in DUE mode and when above 0.</summary>
    public static string Link(UpiQrConfig c, decimal? amount, string? reference)
    {
        static string E(string v) => Uri.EscapeDataString(v);
        var parts = new List<string> { "pa=" + E(c.UpiId.Trim()), "pn=" + E(c.PayeeName.Trim()) };
        if (!string.IsNullOrWhiteSpace(c.MerchantCode)) parts.Add("mc=" + E(c.MerchantCode.Trim()));
        if (c.AmountMode == "DUE" && amount is > 0) parts.Add("am=" + amount.Value.ToString("0.00", CultureInfo.InvariantCulture));
        parts.Add("cu=INR");
        if (c.IncludeReference && !string.IsNullOrWhiteSpace(reference))
            parts.Add("tn=" + E(("Inv " + reference.Trim()).Length > 50 ? ("Inv " + reference.Trim())[..50] : "Inv " + reference.Trim()));
        return "upi://pay?" + string.Join("&", parts);
    }

    public static string PngDataUri(string text, int pixelsPerModule = 8)
    {
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        return "data:image/png;base64," + Convert.ToBase64String(new PngByteQRCode(data).GetGraphic(pixelsPerModule));
    }
}
