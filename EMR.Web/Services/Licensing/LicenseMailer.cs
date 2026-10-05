using System.Net;
using Microsoft.Extensions.Options;
using MimeKit;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// eCare360 licence e-mails, sent only through the separate licensing mailbox (ILicenseMailSender, LicensingMail section):
/// the registration and hardware-renewal OTPs go to the vendor's approvers only, never to the client; the welcome
/// e-mail goes to the client. In Development, Licensing:EmailPickupDirectory writes them to .eml files instead.
/// </summary>
public interface ILicenseMailer
{
    Task<(bool Ok, string Message)> SendRegistrationOtpAsync(RegistrationRequest request, MachineFingerprint fp, string appUrl, string otp, DateTime expiresAt);
    Task<(bool Ok, string Message)> SendRenewalOtpAsync(LicenseRecord license, MachineFingerprint fp, string appUrl, string otp, DateTime expiresAt);
    Task SendWelcomeAsync(LicenseRecord license);
}

/// <summary>What the client entered on the registration form.</summary>
public sealed class RegistrationRequest
{
    public string ClientName { get; set; } = string.Empty;
    public string ContactNumber { get; set; } = string.Empty;
    public string? EmailID { get; set; }
    public DateTime EndDate { get; set; }
    public DateTime? AmcDate { get; set; }
}

public sealed class LicenseMailer(
    IOptions<LicensingOptions> options,
    ILicenseMailSender sender,
    IWebHostEnvironment env,
    ILogger<LicenseMailer> logger) : ILicenseMailer
{
    private readonly LicensingOptions _o = options.Value;
    private static string E(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);

    public Task<(bool Ok, string Message)> SendRegistrationOtpAsync(RegistrationRequest r, MachineFingerprint fp, string appUrl, string otp, DateTime expiresAt)
    {
        var rows = new (string, string)[]
        {
            ("Client name", r.ClientName), ("Contact number", r.ContactNumber), ("E-mail", r.EmailID ?? "—"),
            ("Licence end date", r.EndDate.ToString("dd MMM yyyy")), ("AMC end date", r.AmcDate?.ToString("dd MMM yyyy") ?? "—"),
            ("Product", _o.ProductType), ("Application URL", appUrl),
            ("Server MAC", fp.ServerMacID), ("Hard disk", fp.HardDiskNumber), ("Motherboard", fp.MotherboardNumber), ("Server", Environment.MachineName)
        };
        return SendToApproversAsync($"{_o.ProductDisplayName} licence registration OTP - {otp}",
            "New licence registration", "A client is registering a new installation. Share this OTP with them only if you approve the details below.",
            otp, expiresAt, rows);
    }

    public Task<(bool Ok, string Message)> SendRenewalOtpAsync(LicenseRecord l, MachineFingerprint fp, string appUrl, string otp, DateTime expiresAt)
    {
        var rows = new (string, string)[]
        {
            ("Client code", l.ClientCode), ("Client name", l.ClientName), ("Contact number", l.ContactNumber ?? "—"),
            ("Licence end date", l.ExpiryDate.ToString("dd MMM yyyy")), ("Product", _o.ProductType), ("Application URL", appUrl),
            ("Registered MAC → new", $"{l.ServerMacID} → {fp.ServerMacID}"),
            ("Registered disk → new", $"{l.HardDiskNumber} → {fp.HardDiskNumber}"),
            ("Registered board → new", $"{l.MotherboardNumber} → {fp.MotherboardNumber}"), ("Server", Environment.MachineName)
        };
        return SendToApproversAsync($"{_o.ProductDisplayName} hardware renewal OTP - {otp}",
            "Hardware renewal", "A licensed installation moved to different hardware. Share this OTP only if you approve moving the licence.",
            otp, expiresAt, rows);
    }

    private async Task<(bool, string)> SendToApproversAsync(string subject, string title, string intro, string otp, DateTime expiresAt, (string, string)[] rows)
    {
        var body = $@"<div style=""font-family:Segoe UI,Arial,sans-serif;max-width:560px;color:#0f172a"">
<h2 style=""color:#4c2a8f;margin:0 0 6px"">{E(_o.ProductDisplayName)} · {E(title)}</h2><p>{E(intro)}</p>
<div style=""font-size:30px;font-weight:800;letter-spacing:6px;background:#f3edff;border-radius:10px;padding:14px;text-align:center;color:#4c2a8f"">{E(otp)}</div>
<p style=""color:#64748b;font-size:13px"">Valid until {expiresAt:dd MMM yyyy hh:mm:ss tt} (server time).</p>
<table style=""border-collapse:collapse;width:100%;font-size:14px"">{string.Concat(rows.Select(x => $@"<tr><td style=""padding:6px 8px;border-bottom:1px solid #e2e8f0;color:#64748b"">{E(x.Item1)}</td><td style=""padding:6px 8px;border-bottom:1px solid #e2e8f0;font-weight:600"">{E(x.Item2)}</td></tr>"))}</table></div>";
        var sent = 0;
        string? lastError = null;
        foreach (var to in _o.ApproverEmails.Where(e => !string.IsNullOrWhiteSpace(e)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var (ok, error) = await SendAsync(to.Trim(), subject, body);
            if (ok) sent++; else lastError = error;
        }
        if (sent == 0) logger.LogError("Licence OTP e-mail could not be sent to any approver: {Error}", lastError);
        return sent > 0 ? (true, "OTP sent to the vendor's approvers.") : (false, "The OTP e-mail could not be sent. Try again in a few minutes or contact the vendor.");
    }

    public async Task SendWelcomeAsync(LicenseRecord l)
    {
        if (string.IsNullOrWhiteSpace(l.EmailID)) return;
        try
        {
            var body = $@"<div style=""font-family:Segoe UI,Arial,sans-serif;max-width:560px;color:#0f172a"">
<h2 style=""color:#4c2a8f"">Welcome to {E(_o.ProductDisplayName)}</h2><p>Dear {E(l.ClientName)}, your licence is registered. Keep this e-mail: the licence key is needed if the server hardware ever changes.</p>
<table style=""border-collapse:collapse;width:100%;font-size:14px"">
<tr><td style=""padding:6px 8px;color:#64748b"">Client code</td><td style=""padding:6px 8px;font-weight:700"">{E(l.ClientCode)}</td></tr>
<tr><td style=""padding:6px 8px;color:#64748b"">Licence key</td><td style=""padding:6px 8px;font-weight:700;font-family:monospace"">{E(l.LicenseKey)}</td></tr>
<tr><td style=""padding:6px 8px;color:#64748b"">Valid from</td><td style=""padding:6px 8px"">{l.StartDate:dd MMM yyyy}</td></tr>
<tr><td style=""padding:6px 8px;color:#64748b"">Valid until</td><td style=""padding:6px 8px"">{l.ExpiryDate:dd MMM yyyy}</td></tr>
<tr><td style=""padding:6px 8px;color:#64748b"">AMC until</td><td style=""padding:6px 8px"">{(l.AmcExpiredDate.HasValue ? l.AmcExpiredDate.Value.ToString("dd MMM yyyy") : "—")}</td></tr>
<tr><td style=""padding:6px 8px;color:#64748b"">Application</td><td style=""padding:6px 8px"">{E(l.AppUrl)}</td></tr></table></div>";
            await SendAsync(l.EmailID.Trim(), $"Welcome to {_o.ProductDisplayName} - licence registered ({l.ClientCode})", body);
        }
        catch (Exception ex) { logger.LogWarning(ex, "Welcome e-mail for licence {ClientCode} failed.", l.ClientCode); }
    }

    private async Task<(bool, string?)> SendAsync(string to, string subject, string html)
    {
        try
        {
            if (env.IsDevelopment() && !string.IsNullOrWhiteSpace(_o.EmailPickupDirectory))
            {
                var message = new MimeMessage();
                message.From.Add(new MailboxAddress(_o.ProductDisplayName, "licence@localhost"));
                message.To.Add(MailboxAddress.Parse(to));
                message.Subject = subject;
                message.Body = new BodyBuilder { HtmlBody = html }.ToMessageBody();
                Directory.CreateDirectory(_o.EmailPickupDirectory);
                await message.WriteToAsync(Path.Combine(_o.EmailPickupDirectory, $"{DateTime.Now:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}.eml"));
                return (true, null);
            }
            await sender.SendAsync(to, subject, html);
            return (true, null);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Licence e-mail to {To} failed.", to);
            return (false, ex.Message);
        }
    }
}
