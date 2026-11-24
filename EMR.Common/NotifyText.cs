namespace EMR.Common;

/// <summary>A notification text of the patient's language (SQLScripts/2543, NotifyTemplate): Subject / Heading for e-mail, Body.</summary>
public sealed class NotifyTemplateText
{
    public string? Subject { get; set; }
    public string? Heading { get; set; }
    public string Body { get; set; } = string.Empty;
    public string? LanguageName { get; set; }
    public string? LanguageCode { get; set; }
}

/// <summary>
/// Notifications in the patient's language (SQLScripts/2543): fills the {Placeholders} of a template, and builds the e-mail in
/// the common e-mail layout (same look as the English e-mails). Template text is plain text - paragraphs separated by a blank
/// line, line breaks kept - so the e-mail is HTML-encoded here.
/// </summary>
public static class NotifyText
{
    /// <summary>The event codes (NotifyEvent).</summary>
    public const string LabBill = "LAB_BILL", LabReport = "LAB_REPORT", LabEstimate = "LAB_ESTIMATE", OpdBill = "OPD_BILL", OpdBooking = "OPD_BOOKING",
        OpdFollowUp = "OPD_FOLLOWUP", OpdVideo = "OPD_VIDEO", Certificate = "CERTIFICATE", MemPoints = "MEM_POINTS", MemCard = "MEM_CARD",
        MemRenewal = "MEM_RENEWAL", PhBill = "PH_BILL", PhLoyalty = "PH_LOYALTY", PhRefill = "PH_REFILL", PhWalletExpiry = "PH_WALLET_EXPIRY",
        PortalLogin = "PORTAL_LOGIN", MemRedeemOtp = "MEM_REDEEM_OTP", PhLoyaltyOtp = "PH_LOYALTY_OTP", PatientAppOtp = "PATIENT_APP_OTP",
        HomeCollectionOtp = "HOME_COLLECTION_OTP";
    public const string WhatsApp = "WHATSAPP";
    public const string Email = "EMAIL";

    /// <summary>
    /// {Key} -> value, for WhatsApp / subjects (no encoding). Unknown placeholders are left as they are.
    /// Optional parts: {#Key}...{/Key} is kept only when Key has a value (not empty, not "0"); {^Key}...{/Key} only when it has none.
    /// </summary>
    public static string Fill(string? template, IReadOnlyDictionary<string, string?> values)
    {
        var s = Sections(template ?? string.Empty, values);
        foreach (var (k, v) in values) s = s.Replace("{" + k + "}", v ?? string.Empty);
        return s.Trim();
    }

    private static readonly System.Text.RegularExpressions.Regex SectionRx =
        new(@"\{([#^])(\w+)\}(.*?)\{/\2\}", System.Text.RegularExpressions.RegexOptions.Singleline | System.Text.RegularExpressions.RegexOptions.Compiled);

    private static string Sections(string s, IReadOnlyDictionary<string, string?> values)
    {
        for (var guard = 0; guard < 10 && s.Contains("{/"); guard++)
        {
            var next = SectionRx.Replace(s, m =>
            {
                var has = values.TryGetValue(m.Groups[2].Value, out var v) && !string.IsNullOrWhiteSpace(v) && v != "0";
                return (m.Groups[1].Value == "#") == has ? m.Groups[3].Value : string.Empty;
            });
            if (next == s) break;
            s = next;
        }
        return s;
    }

    private static readonly System.Text.RegularExpressions.Regex UrlRx =
        new(@"https?://[^\s<]+", System.Text.RegularExpressions.RegexOptions.Compiled);

    /// <summary>The e-mail body: each paragraph of the template (blank-line separated) in the layout, values HTML-encoded, links clickable.</summary>
    public static string EmailHtml(NotifyTemplateText t, IReadOnlyDictionary<string, string?> values, string? hospitalName, string? address)
    {
        static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
        var encoded = values.ToDictionary(kv => kv.Key, kv => (string?)H(kv.Value));
        // optional sections first, on the whole text - a section may span paragraphs
        var text = Sections(H(t.Body).Replace("\r\n", "\n"), encoded);
        var paragraphs = text.Split("\n\n", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(p => Fill(p, encoded))
            .Where(p => p.Length > 0)
            .Select(p => EmailLayout.P(UrlRx.Replace(p, m => $"<a href=\"{m.Value}\">{m.Value}</a>").Replace("\n", "<br/>")));
        var hospital = string.IsNullOrWhiteSpace(hospitalName) ? "" : hospitalName.Trim();
        return EmailLayout.Wrap(string.Concat(paragraphs),
            heading: string.IsNullOrWhiteSpace(t.Heading) ? null : Fill(t.Heading, values),
            organisation: hospital,
            footerHtml: hospital.Length == 0 ? null : $"&copy; {DateTime.Now.Year} {H(hospital)}." + (string.IsNullOrWhiteSpace(address) ? "" : $"<br/>{H(address)}"));
    }

    /// <summary>The placeholders of a LAB bill (NotifyEvent LAB_BILL).</summary>
    public static Dictionary<string, string?> LabBillValues(string? patientName, string? hospitalName, string? billNo, string? tokenNo, decimal amount, DateTime billDate, string? address) =>
        new()
        {
            ["PatientName"] = patientName, ["HospitalName"] = hospitalName, ["BillNo"] = billNo, ["TokenNo"] = string.IsNullOrWhiteSpace(tokenNo) ? "—" : tokenNo,
            ["Amount"] = amount.ToString("N2"), ["BillDate"] = billDate.ToString("dd MMM yyyy"), ["HospitalAddress"] = address
        };
}
