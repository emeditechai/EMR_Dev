using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace EMR.Web.Services;

/// <summary>A merge field of an email type: the code staff never have to type, a friendly name and a sample value.</summary>
public sealed record EmailField(string Code, string Label, string Sample);

/// <summary>An email the application sends from Utility > Email Templates, with the fields its sending code fills in.</summary>
public sealed record EmailType(string Name, string Description, string Icon, IReadOnlyList<EmailField> Fields, EmailTemplateDesign Default, string DefaultSubject);

/// <summary>The template as staff design it (SQLScripts/2298, EmailTemplates.DesignJson). HtmlBody is built from it.</summary>
public sealed class EmailTemplateDesign
{
    public string Heading { get; set; } = "";
    /// <summary>Rich text from the editor: p, br, strong, em, u, s, ol, ul, li, a - with {{Field}} merge codes.</summary>
    public string Message { get; set; } = "";
    public List<EmailDetailRow> Rows { get; set; } = [];
    public string NoteText { get; set; } = "";
    /// <summary>info, reminder or important.</summary>
    public string NoteStyle { get; set; } = "info";
    public string Closing { get; set; } = "";
    public string Signature { get; set; } = "";
}

public sealed class EmailDetailRow
{
    public string Label { get; set; } = "";
    public string Value { get; set; } = "";
    public bool Highlight { get; set; }
}

/// <summary>
/// Utility > Email Templates designer: the email types and their fields, the HTML built from a design (inside the
/// common eCare360Plus+ layout at send time, <see cref="EmailLayout"/>), the preview and the field filling.
/// </summary>
public static partial class EmailTemplateDesigner
{
    private static readonly EmailField PatientName = new("PatientName", "Patient Name", "Mr. Rahul Sharma");
    private static readonly EmailField DoctorName = new("DoctorName", "Doctor Name", "Dr. Anirban Sen");
    private static readonly EmailField VisitDate = new("VisitDate", "Visit Date", "20-Oct-2026");
    private static readonly EmailField SlotTime = new("SlotTime", "Slot Time", "10:30 AM");
    private static readonly EmailField TokenNo = new("TokenNo", "Token Number", "OPD-HO-0012");
    private static readonly EmailField TotalAmount = new("TotalAmount", "Amount Paid", "500.00");
    private static readonly EmailField HospitalName = new("HospitalName", "Hospital Name", "City Care Hospital");

    /// <summary>The emails the application sends with a template. The name is how the sending code finds it.</summary>
    public static readonly IReadOnlyList<EmailType> Types =
    [
        new("Booking Confirmation", "Sent to the patient when an OPD appointment is booked.", "bi-calendar-check",
            [PatientName, DoctorName, VisitDate, SlotTime, TokenNo, TotalAmount, HospitalName],
            new EmailTemplateDesign
            {
                Heading = "Booking Confirmation",
                Message = "<p>Dear <strong>{{PatientName}}</strong>,</p><p>Your appointment at <strong>{{HospitalName}}</strong> has been scheduled. Here are your booking details:</p>",
                Rows =
                [
                    new() { Label = "Consulting Doctor", Value = "{{DoctorName}}" },
                    new() { Label = "Appointment Date", Value = "{{VisitDate}}" },
                    new() { Label = "Slot Time", Value = "{{SlotTime}}" },
                    new() { Label = "Token Number", Value = "{{TokenNo}}", Highlight = true },
                    new() { Label = "Total Paid / Fee", Value = "Rs. {{TotalAmount}}" }
                ],
                NoteText = "Please arrive at least 15 minutes before your slot for registration and vitals checks.",
                NoteStyle = "info",
                Closing = "Warm regards,",
                Signature = "{{HospitalName}} Team"
            },
            "Booking Confirmation at {{HospitalName}}"),
        new("Prescription Delivery", "Sent to the patient with the prescription after the consultation.", "bi-file-earmark-medical",
            [PatientName, DoctorName, VisitDate, TokenNo, HospitalName],
            new EmailTemplateDesign
            {
                Heading = "Your prescription is ready",
                Message = "<p>Dear <strong>{{PatientName}}</strong>,</p><p>Thank you for visiting <strong>{{HospitalName}}</strong>. Your consultation is complete and your prescription is attached to this email.</p>",
                Rows =
                [
                    new() { Label = "Consulting Doctor", Value = "{{DoctorName}}" },
                    new() { Label = "Date of Visit", Value = "{{VisitDate}}" },
                    new() { Label = "Queue Token", Value = "{{TokenNo}}" }
                ],
                NoteText = "Keep the attached prescription for your records and future visits.",
                NoteStyle = "info",
                Closing = "Wishing you a speedy recovery,",
                Signature = "{{HospitalName}} Team"
            },
            "Your Prescription from {{HospitalName}}")
    ];

    public static EmailType? Find(string? name) => Types.FirstOrDefault(t => string.Equals(t.Name, name?.Trim(), StringComparison.OrdinalIgnoreCase));

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public static string ToJson(EmailTemplateDesign d) => JsonSerializer.Serialize(d, Json);
    public static EmailTemplateDesign? FromJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try { return JsonSerializer.Deserialize<EmailTemplateDesign>(json, Json); } catch (JsonException) { return null; }
    }

    // ── building the email body ─────────────────────────────────────────────────────────────────────────────────

    private const string Ink = "#1b1530", Muted = "#6b6880", Line = "#eeebf3", Soft = "#faf9fc", Brand = "#644098", Accent = "#ca2e6d";
    private static string H(string? s) => WebUtility.HtmlEncode(s ?? "");

    /// <summary>The email content (heading, message, details, note, closing) as stored in EmailTemplates.HtmlBody;
    /// the common layout (brand header, footer) is put around it when it is sent.</summary>
    public static string Build(EmailTemplateDesign d)
    {
        var sb = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(d.Heading))
            sb.Append($"<h2 style=\"margin:0 0 16px;font-size:20px;line-height:1.3;color:{Ink};\">{H(d.Heading.Trim())}</h2>\n");

        var message = Sanitize(d.Message);
        if (message.Length > 0) sb.Append(message).Append('\n');

        var rows = d.Rows.Where(r => !string.IsNullOrWhiteSpace(r.Label) || !string.IsNullOrWhiteSpace(r.Value)).ToList();
        if (rows.Count > 0)
        {
            sb.Append($"<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:{Soft};border:1px solid {Line};border-radius:8px;margin:4px 0 18px;border-collapse:separate;\">\n");
            foreach (var r in rows)
                sb.Append($"  <tr><td style=\"padding:8px 16px;color:{Muted};font-size:13px;width:38%;\">{H(r.Label.Trim())}</td>")
                  .Append($"<td style=\"padding:8px 16px;color:{(r.Highlight ? Accent : Ink)};font-size:{(r.Highlight ? 16 : 14)}px;font-weight:{(r.Highlight ? 700 : 600)};\">{H(r.Value.Trim())}</td></tr>\n");
            sb.Append("</table>\n");
        }

        if (!string.IsNullOrWhiteSpace(d.NoteText))
        {
            var (bg, bar, fg) = d.NoteStyle switch
            {
                "reminder" => ("#fffbeb", "#f59e0b", "#92400e"),
                "important" => ("#fef2f2", "#dc2626", "#991b1b"),
                _ => ("#f5f1fa", Brand, "#3b2a5c")
            };
            sb.Append($"<div style=\"margin:0 0 16px;padding:12px 16px;background:{bg};border-left:4px solid {bar};border-radius:6px;color:{fg};font-size:13px;line-height:1.6;\">")
              .Append(H(d.NoteText.Trim()).Replace("\r\n", "\n").Replace("\n", "<br/>")).Append("</div>\n");
        }

        if (!string.IsNullOrWhiteSpace(d.Closing) || !string.IsNullOrWhiteSpace(d.Signature))
            sb.Append("<p style=\"margin:0 0 12px;\">").Append(H(d.Closing?.Trim()))
              .Append(!string.IsNullOrWhiteSpace(d.Closing) && !string.IsNullOrWhiteSpace(d.Signature) ? "<br/>" : "")
              .Append(string.IsNullOrWhiteSpace(d.Signature) ? "" : $"<strong>{H(d.Signature.Trim())}</strong>").Append("</p>");
        return sb.ToString();
    }

    /// <summary>Only the formatting the editor offers survives (paragraphs, bold, italic, underline, strike, lists, links);
    /// every other tag and attribute is dropped, and the kept tags get email-safe inline styles.</summary>
    public static string Sanitize(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return "";
        var s = Regex.Replace(html, @"<(script|style|iframe|object|embed)\b.*?</\1\s*>", "", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        s = TagRegex().Replace(s, m =>
        {
            var close = m.Groups[1].Value == "/";
            var tag = m.Groups[2].Value.ToLowerInvariant();
            var attrs = m.Groups[3].Value;
            tag = tag switch { "b" => "strong", "i" => "em", "strike" or "del" => "s", "div" => "p", _ => tag };
            if (close) return tag is "p" or "strong" or "em" or "u" or "s" or "ol" or "ul" or "li" or "a" ? $"</{tag}>" : "";
            return tag switch
            {
                "p" => "<p style=\"margin:0 0 12px;\">",
                "br" => "<br/>",
                "strong" or "em" or "u" or "s" or "li" => $"<{tag}>",
                "ol" or "ul" => $"<{tag} style=\"margin:0 0 12px;padding-left:22px;\">",
                "a" => HrefRegex().Match(attrs) is { Success: true } h && SafeHref(WebUtility.HtmlDecode(h.Groups[2].Value)) is { } href
                    ? $"<a href=\"{H(href)}\" style=\"color:{Brand};\">" : "<a>",
                _ => ""
            };
        });
        // a message ending in empty paragraphs
        s = Regex.Replace(s, @"(<p style=""margin:0 0 12px;""><br/></p>\s*)+$", "");
        return s.Trim();
    }

    private static string? SafeHref(string href)
    {
        href = href.Trim();
        return href.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || href.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            || href.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase) || href.StartsWith("tel:", StringComparison.OrdinalIgnoreCase)
            ? href : null;
    }

    /// <summary>Fills the merge fields of a subject or body; a field without a value becomes empty.</summary>
    public static string Fill(string? text, IReadOnlyDictionary<string, string?> values) =>
        FieldRegex().Replace(text ?? "", m => values.TryGetValue(m.Groups[1].Value, out var v) ? v ?? "" : m.Value);

    /// <summary>Merge codes in the text that the email type does not fill (they would be sent as typed).</summary>
    public static List<string> UnknownFields(string? text, EmailType type) =>
        FieldRegex().Matches(text ?? "").Select(m => m.Groups[1].Value).Distinct()
            .Where(c => type.Fields.All(f => !string.Equals(f.Code, c, StringComparison.Ordinal))).ToList();

    /// <summary>Sample values of the type; with <paramref name="asNames"/> each field shows as a highlighted name.</summary>
    public static Dictionary<string, string?> Samples(EmailType type, bool asNames, bool html) =>
        type.Fields.ToDictionary(f => f.Code, f => (string?)(asNames
            ? (html ? $"<span style=\"background:#ede9fe;color:#5b21b6;border-radius:4px;padding:0 4px;font-weight:600;\">{H(f.Label)}</span>" : $"[{f.Label}]")
            : (html ? H(f.Sample) : f.Sample)));

    [GeneratedRegex(@"<\s*(/?)\s*([a-zA-Z0-9]+)([^>]*)>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"href\s*=\s*(['""])(.*?)\1", RegexOptions.IgnoreCase)]
    private static partial Regex HrefRegex();

    [GeneratedRegex(@"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}")]
    private static partial Regex FieldRegex();
}
