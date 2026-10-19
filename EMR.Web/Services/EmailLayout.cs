using System.Net;
using System.Text.RegularExpressions;

namespace EMR.Web.Services;

/// <summary>
/// The one look of every email the application sends: the eCare360Plus+ header (brand plate on the purple-magenta
/// gradient, the hospital / branch name on the right), the content on a white card, a standard footer.
/// Templates build their content with <see cref="Wrap"/> and the small helpers below; anything else that reaches
/// <see cref="EmailService"/> (email templates kept in the database, the SMTP test mail) is put in the same layout by
/// <see cref="EnsureBranded"/>.
/// </summary>
public static partial class EmailLayout
{
    /// <summary>Marks a body that already carries the layout, so it is never wrapped twice.</summary>
    private const string Marker = "<!--ecare360-email-layout-->";

    public const string Purple = "#644098";
    public const string Magenta = "#ca2e6d";
    private const string Ink = "#1b1530";
    private const string Muted = "#6b6880";
    private const string Line = "#eeebf3";
    private const string Soft = "#faf9fc";

    private static string H(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);

    /// <summary>A complete email: header, optional heading, the content (already HTML) and the footer.</summary>
    /// <param name="organisation">Hospital / branch name shown at the right of the header (plain text).</param>
    /// <param name="footerHtml">Footer lines (HTML) above the standard "automated message" note.</param>
    /// <param name="headStyles">&lt;style&gt; blocks a wrapped legacy body relied on.</param>
    public static string Wrap(string contentHtml, string? heading = null, string? organisation = null,
                              string? footerHtml = null, string? headStyles = null) => $@"<!DOCTYPE html>
<html><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">{headStyles}</head>
<body style=""margin:0;padding:0;background:#f4f2f8;"">{Marker}
<table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:#f4f2f8;padding:24px 12px;font-family:'Segoe UI',Arial,Helvetica,sans-serif;"">
<tr><td align=""center"">
<table role=""presentation"" width=""600"" cellpadding=""0"" cellspacing=""0"" style=""max-width:600px;width:100%;background:#ffffff;border-radius:12px;overflow:hidden;border-collapse:separate;"">
  <tr><td style=""background-color:{Purple};background-image:linear-gradient(135deg,#4a2d75 0%,{Purple} 50%,#a8407a 100%);padding:22px 28px;"">
    <table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0""><tr>
      <td valign=""middle"">
        <span style=""display:inline-block;background:#ffffff;border-radius:8px;padding:6px 12px;font-size:20px;font-weight:800;line-height:1.2;font-family:'Segoe UI',Arial,Helvetica,sans-serif;"">
          <span style=""color:#1a6efd;"">eCare360</span><span style=""color:#f59e0b;"">Plus</span><span style=""color:#ec4899;"">+</span>
        </span>
      </td>
      {(string.IsNullOrWhiteSpace(organisation) ? "" : $@"<td valign=""middle"" align=""right"" style=""color:#ffffff;font-size:14px;font-weight:600;line-height:1.35;padding-left:12px;"">{H(organisation)}</td>")}
    </tr></table>
  </td></tr>
  <tr><td style=""padding:28px;color:{Ink};font-size:14px;line-height:1.6;"">
    {(string.IsNullOrWhiteSpace(heading) ? "" : $@"<h2 style=""margin:0 0 16px;font-size:20px;line-height:1.3;color:{Ink};"">{H(heading)}</h2>")}
    {contentHtml}
  </td></tr>
  <tr><td style=""padding:16px 28px;background:{Soft};border-top:1px solid {Line};color:{Muted};font-size:12px;line-height:1.6;"">
    {(string.IsNullOrWhiteSpace(footerHtml) ? "" : footerHtml + "<br/>")}
    <span style=""color:#8c86a3;"">This is an automated message sent by eCare360Plus+. Please do not reply to this email.</span>
  </td></tr>
</table>
</td></tr></table>
</body></html>";

    /// <summary>Puts a body that does not carry the layout yet into it; a full HTML document keeps its body content
    /// and its &lt;style&gt; blocks. Plain text (no tags) keeps its line breaks.</summary>
    public static string EnsureBranded(string? body)
    {
        body ??= string.Empty;
        if (body.Contains(Marker, StringComparison.Ordinal)) return body;

        if (!TagRegex().IsMatch(body))
            return Wrap($@"<p style=""margin:0;"">{H(body).Replace("\r\n", "\n").Replace("\n", "<br/>")}</p>");

        var styles = string.Concat(StyleRegex().Matches(body).Select(m => m.Value));
        var inner = BodyRegex().Match(body) is { Success: true } m ? m.Groups[1].Value : body;
        inner = StyleRegex().Replace(inner, "");
        inner = Regex.Replace(inner, @"<!DOCTYPE[^>]*>|</?html[^>]*>|<head\b.*?</head>", "", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        return Wrap(inner.Trim(), headStyles: styles.Length == 0 ? null : styles);
    }

    // ---- building blocks, so every template looks the same ------------------------------------------------------------

    public static string P(string html, bool muted = false) =>
        $@"<p style=""margin:0 0 12px;{(muted ? $"color:{Muted};font-size:13px;" : "")}"">{html}</p>";

    public static string Greeting(string name) => P($"Dear <strong>{H(name)}</strong>,");

    /// <summary>A call-to-action button (url and text are encoded here).</summary>
    public static string Button(string text, string url) => $@"
<p style=""margin:24px 0;text-align:center;"">
  <a href=""{H(url)}"" target=""_blank"" style=""display:inline-block;background:{Magenta};color:#ffffff;text-decoration:none;font-weight:600;font-size:15px;padding:12px 28px;border-radius:8px;"">{H(text)}</a>
</p>";

    /// <summary>Label / value rows in a soft box; values are HTML (encode them first).</summary>
    public static string Details(params (string Label, string ValueHtml)[] rows) => $@"
<table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:{Soft};border:1px solid {Line};border-radius:8px;margin:4px 0 18px;border-collapse:separate;"">
  {string.Concat(rows.Where(r => !string.IsNullOrEmpty(r.ValueHtml)).Select(r =>
      $@"<tr><td style=""padding:8px 16px;color:{Muted};font-size:13px;width:38%;vertical-align:top;"">{H(r.Label)}</td><td style=""padding:8px 16px;color:{Ink};font-size:14px;font-weight:600;"">{r.ValueHtml}</td></tr>"))}
</table>";

    /// <summary>A highlighted note; tone "info" (purple), "warn" (amber) or "danger" (red).</summary>
    public static string Callout(string html, string tone = "info")
    {
        var (bg, bar, fg) = tone switch
        {
            "warn" => ("#fffbeb", "#f59e0b", "#92400e"),
            "danger" => ("#fef2f2", "#dc2626", "#991b1b"),
            _ => ("#f5f1fa", Purple, "#3b2a5c")
        };
        return $@"<div style=""margin:0 0 16px;padding:12px 16px;background:{bg};border-left:4px solid {bar};border-radius:6px;color:{fg};font-size:13px;line-height:1.6;"">{html}</div>";
    }

    public static string SignOff(string from) => P($"Regards,<br/><strong>{H(from)}</strong>");

    [GeneratedRegex(@"<\s*[a-zA-Z!/][^>]*>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"<style\b[^>]*>.*?</style>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex StyleRegex();

    [GeneratedRegex(@"<body\b[^>]*>(.*)</body>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex BodyRegex();
}
