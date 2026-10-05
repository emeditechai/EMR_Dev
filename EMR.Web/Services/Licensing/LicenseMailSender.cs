using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Options;
using MimeKit;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// Sends one HTML e-mail from the eCare360 licensing mailbox (info@emeditechplus.com on webmail.emeditechplus.com), used only for licence OTP and
/// welcome e-mails and separate from the hospital's own mail settings. Server, account, sender and certificate are
/// compiled in (<see cref="LicensingPolicy.Mail"/>); the password comes from LicensingMail__Password when set, otherwise
/// from the vendor's central mail configuration (tbl_centralmailconfiguration), as in eRestoPOS.
/// </summary>
public interface ILicenseMailSender
{
    Task SendAsync(string toEmail, string subject, string htmlBody, CancellationToken ct = default);
}

public sealed class LicenseMailSender(IOptions<LicensingOptions> options, ICentralLicenseRepository central, ILogger<LicenseMailSender> logger) : ILicenseMailSender
{
    private static readonly HashSet<string> Pins = LicensingPolicy.Mail.CertificateSha256.Select(Normalize).ToHashSet();
    private readonly LicensingOptions _o = options.Value;

    public async Task SendAsync(string toEmail, string subject, string htmlBody, CancellationToken ct = default)
    {
        var message = new MimeMessage();
        message.From.Add(new MailboxAddress(LicensingPolicy.Mail.SenderName, LicensingPolicy.Mail.SenderEmail));
        message.ReplyTo.Add(new MailboxAddress(LicensingPolicy.Mail.SenderName, LicensingPolicy.Mail.SenderEmail));
        message.To.Add(MailboxAddress.Parse(toEmail));
        message.Subject = subject;
        message.Body = new BodyBuilder
        {
            HtmlBody = htmlBody,
            TextBody = System.Net.WebUtility.HtmlDecode(System.Text.RegularExpressions.Regex.Replace(htmlBody, "<[^>]+>", " "))
        }.ToMessageBody();

        using var client = new SmtpClient { Timeout = LicensingPolicy.Mail.TimeoutSeconds * 1000, LocalDomain = LicensingPolicy.Mail.LocalDomain };
        client.ServerCertificateValidationCallback = ValidateCertificate;
        await client.ConnectAsync(LicensingPolicy.Mail.Host, LicensingPolicy.Mail.Port, SecureSocketOptions.SslOnConnect, ct);
        // a configured password wins; otherwise the vendor's central mail configuration supplies it (no server setup)
        var password = !string.IsNullOrEmpty(_o.MailPassword) ? _o.MailPassword : await central.GetMailboxPasswordAsync(LicensingPolicy.Mail.Username);
        if (string.IsNullOrEmpty(password))
            throw new InvalidOperationException($"No password for {LicensingPolicy.Mail.Username} in the central mail configuration.");
        await client.AuthenticateAsync(LicensingPolicy.Mail.Username, password, ct);
        await client.SendAsync(message, ct);
        await client.DisconnectAsync(true, ct);
    }

    /// <summary>A publicly trusted certificate passes; otherwise only a pinned one (the server's self-signed certificate).</summary>
    private bool ValidateCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors errors)
    {
        if (errors == SslPolicyErrors.None) return true;
        if (certificate is null) return false;
        var actual = Convert.ToHexString(SHA256.HashData(certificate.GetRawCertData()));
        if (Pins.Contains(actual)) return true;
        logger.LogError("Licensing mail server {Host} presented an untrusted certificate ({Errors}) that is not pinned; SHA-256 {Fingerprint}, subject {Subject}, valid until {Expiry}. Add the fingerprint to LicensingPolicy.Mail.CertificateSha256 if the certificate is genuine.",
            LicensingPolicy.Mail.Host, errors, actual, certificate.Subject, (certificate as X509Certificate2)?.NotAfter ?? new X509Certificate2(certificate).NotAfter);
        return false;
    }

    private static string Normalize(string fingerprint) => new string(fingerprint.Where(Uri.IsHexDigit).ToArray()).ToUpperInvariant();
}
