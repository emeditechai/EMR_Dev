using System.Text.RegularExpressions;

namespace EMR.Web.Services;

/// <summary>
/// The patient's Pincode is kept in PatientMaster.Pincode and also at the end of the address as ", PIN: nnnnnn"
/// (SQLScripts/2339), so every bill, print and report shows it. Forms edit the two separately.
/// </summary>
public static partial class PatientAddress
{
    [GeneratedRegex(@"\s*,?\s*PIN\s*:\s*(\d{6})\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex PinSuffix();

    /// <summary>The address as saved: with a pincode, the address (any old PIN removed) then ", PIN: nnnnnn"; without one,
    /// the address exactly as given (a form without a Pincode field keeps the PIN already in the address).</summary>
    public static string? Compose(string? address, string? pincode)
    {
        var pin = (pincode ?? "").Trim();
        if (pin.Length == 0) return address?.Trim();
        var addr = Split(address).Address;
        return string.IsNullOrWhiteSpace(addr) ? $"PIN: {pin}" : $"{addr}, PIN: {pin}";
    }

    /// <summary>A saved address split back into the address and the pincode at its end (if any).</summary>
    public static (string? Address, string? Pincode) Split(string? address)
    {
        if (string.IsNullOrWhiteSpace(address)) return (address, null);
        var m = PinSuffix().Match(address);
        if (!m.Success) return (address.Trim(), null);
        var rest = address[..m.Index].Trim().TrimEnd(',').Trim();
        return (rest.Length == 0 ? null : rest, m.Groups[1].Value);
    }
}
