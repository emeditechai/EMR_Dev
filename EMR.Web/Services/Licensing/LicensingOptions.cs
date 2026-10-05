namespace EMR.Web.Services.Licensing;

/// <summary>
/// The licensing rules and the licensing mailbox, compiled into the application on purpose: appsettings.json sits on
/// the client's server and anyone with access to it could otherwise send the approval OTP to their own address, lengthen
/// the offline grace, loosen the OTP limits or point the mail at another server. They change only with a new release.
/// </summary>
public static class LicensingPolicy
{
    public const string ProductType = "eCare360";
    public const string ProductDisplayName = "eCare360";

    /// <summary>The vendor approvers who receive every registration and hardware-renewal OTP.</summary>
    public static readonly IReadOnlyList<string> ApproverEmails = new[] { "ap.porel27@gmail.com", "purojit2010@gmail.com" };

    public const int OtpLength = 6;
    public const int OtpLifetimeSeconds = 120;
    public const int OtpMaxAttempts = 5;
    public const int OtpSendsPerIpPer15Min = 3;
    public const int OtpSendsPerSessionPer15Min = 3;
    public const int OtpSendsPerServerPerHour = 20;
    public const int DefaultTermDays = 365;
    public const int MaxTermDays = 366;
    public const int OfflineGraceDays = 0;

    /// <summary>The licensing mailbox (MailEnable on Plesk). 465 with SSL from the first byte is the only SMTP port open.</summary>
    public static class Mail
    {
        public const string Host = "webmail.emeditechplus.com";
        public const int Port = 465;
        public const string Username = "info@emeditechplus.com";
        public const string SenderName = "eMeditech Plus";
        public const string SenderEmail = "info@emeditechplus.com";
        public const string LocalDomain = "emeditechplus.com";
        public const int TimeoutSeconds = 30;
        /// <summary>The server's self-signed certificate is accepted only if its SHA-256 fingerprint is listed here
        /// (current one valid until 10 Nov 2026). When it is renewed, add the new fingerprint, which is logged.</summary>
        public static readonly IReadOnlyList<string> CertificateSha256 = new[]
        {
            "4C3D648E9F3A2004FE19E84684E739EDEB709F81DA00DFD417B5FE094CD391D8"
        };
    }
}

/// <summary>
/// eCare360 licensing settings that may differ per installation ("Licensing" section of appsettings.json): AppUrl,
/// VendorContact, ExpiryWarningDays, RemoteConnectionTimeoutSeconds, CentralTrustServerCertificate, and in Development
/// only Enabled and EmailPickupDirectory. The rules in <see cref="LicensingPolicy"/> are read-only here, so a value for
/// them in appsettings.json is ignored. Secrets come from environment variables or user-secrets only:
///   CENTRAL_LICENSE_REMOTE_SERVER, CENTRAL_LICENSE_REMOTE_USERNAME, CENTRAL_LICENSE_REMOTE_PASSWORD,
///   CENTRAL_LICENSE_REMOTE_DATABASE, Licensing:LocalSigningKey, Licensing:LocalEncryptionKey (32 random bytes,
///   base64 each), LicensingMail:Password (environment variable LicensingMail__Password).
/// Outside Development the licence is always enforced (Enabled is forced on); a missing secret stops startup.
/// </summary>
public sealed class LicensingOptions
{
    public const string Section = "Licensing";

    public bool Enabled { get; set; }
    public string? VendorContact { get; set; }
    public int ExpiryWarningDays { get; set; } = 15;
    public int RemoteConnectionTimeoutSeconds { get; set; } = 10;
    /// <summary>The address the licence is bound to, e.g. https://ecare.hospital.in (recommended in production). Empty:
    /// taken from each request, which trusts the browser's Host header.</summary>
    public string? AppUrl { get; set; }
    /// <summary>Accept the licence server's self-signed TLS certificate. Set false once the server has a trusted certificate.</summary>
    public bool CentralTrustServerCertificate { get; set; } = true;
    /// <summary>Development only: write licence e-mails to this folder (.eml) instead of sending them.</summary>
    public string? EmailPickupDirectory { get; set; }

    // fixed rules (LicensingPolicy): read-only, so configuration binding cannot change them
    public string ProductType => LicensingPolicy.ProductType;
    public string ProductDisplayName => LicensingPolicy.ProductDisplayName;
    public IReadOnlyList<string> ApproverEmails => LicensingPolicy.ApproverEmails;
    public int OtpLength => LicensingPolicy.OtpLength;
    public int OtpLifetimeSeconds => LicensingPolicy.OtpLifetimeSeconds;
    public int OtpMaxAttempts => LicensingPolicy.OtpMaxAttempts;
    public int OtpSendsPerIpPer15Min => LicensingPolicy.OtpSendsPerIpPer15Min;
    public int OtpSendsPerSessionPer15Min => LicensingPolicy.OtpSendsPerSessionPer15Min;
    public int OtpSendsPerServerPerHour => LicensingPolicy.OtpSendsPerServerPerHour;
    public int DefaultTermDays => LicensingPolicy.DefaultTermDays;
    public int MaxTermDays => LicensingPolicy.MaxTermDays;
    public int OfflineGraceDays => LicensingPolicy.OfflineGraceDays;

    // secrets (bound by LicensingSecrets.Load, not from the Licensing section of appsettings.json)
    public string CentralServer { get; set; } = string.Empty;
    public string CentralUsername { get; set; } = string.Empty;
    public string CentralPassword { get; set; } = string.Empty;
    public string CentralDatabase { get; set; } = string.Empty;
    public byte[] LocalSigningKey { get; set; } = Array.Empty<byte>();
    public byte[] LocalEncryptionKey { get; set; } = Array.Empty<byte>();
    public string MailPassword { get; set; } = string.Empty;

    public string CentralConnectionString => new Microsoft.Data.SqlClient.SqlConnectionStringBuilder
    {
        DataSource = CentralServer,
        InitialCatalog = CentralDatabase,
        UserID = CentralUsername,
        Password = CentralPassword,
        Encrypt = true,                  // always encrypted; self-signed certificate accepted unless switched off
        TrustServerCertificate = CentralTrustServerCertificate,
        ConnectTimeout = Math.Max(3, RemoteConnectionTimeoutSeconds),
        ApplicationName = "eCare360 Licensing"
    }.ConnectionString;

    /// <summary>Reads the secrets into the options and, when licensing is enabled, refuses to start without them.</summary>
    public static void LoadSecretsAndValidate(LicensingOptions o, IConfiguration config)
    {
        o.CentralServer = config["CENTRAL_LICENSE_REMOTE_SERVER"] ?? string.Empty;
        o.CentralUsername = config["CENTRAL_LICENSE_REMOTE_USERNAME"] ?? string.Empty;
        o.CentralPassword = config["CENTRAL_LICENSE_REMOTE_PASSWORD"] ?? string.Empty;
        o.CentralDatabase = config["CENTRAL_LICENSE_REMOTE_DATABASE"] ?? string.Empty;
        o.MailPassword = config["LicensingMail:Password"] ?? string.Empty;
        var errors = new List<string>();
        o.LocalSigningKey = Base64(config["Licensing:LocalSigningKey"], 32, "Licensing:LocalSigningKey", errors);
        o.LocalEncryptionKey = Base64(config["Licensing:LocalEncryptionKey"], 32, "Licensing:LocalEncryptionKey", errors);
        if (!o.Enabled) return;

        if (string.IsNullOrWhiteSpace(o.CentralServer)) errors.Add("CENTRAL_LICENSE_REMOTE_SERVER is not set.");
        if (string.IsNullOrWhiteSpace(o.CentralUsername)) errors.Add("CENTRAL_LICENSE_REMOTE_USERNAME is not set.");
        if (string.IsNullOrWhiteSpace(o.CentralPassword)) errors.Add("CENTRAL_LICENSE_REMOTE_PASSWORD is not set.");
        if (string.IsNullOrWhiteSpace(o.CentralDatabase)) errors.Add("CENTRAL_LICENSE_REMOTE_DATABASE is not set.");
        if (string.IsNullOrWhiteSpace(o.MailPassword)) errors.Add("LicensingMail:Password is not set (environment variable LicensingMail__Password).");
        if (!string.IsNullOrWhiteSpace(o.AppUrl))
        {
            if (!Uri.TryCreate(o.AppUrl.Trim(), UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https") || !string.IsNullOrEmpty(u.Query))
                errors.Add("Licensing:AppUrl must be scheme://host[:port][/path], e.g. https://ecare.hospital.in.");
            else o.AppUrl = o.AppUrl.Trim().TrimEnd('/').ToLowerInvariant();
        }

        // a key that is set but malformed is reported by Base64 above; a missing one only matters when enabled
        if (errors.Count > 0 || o.LocalSigningKey.Length == 0 || o.LocalEncryptionKey.Length == 0)
        {
            if (o.LocalSigningKey.Length == 0 && !errors.Any(e => e.Contains("LocalSigningKey"))) errors.Add("Licensing:LocalSigningKey is not set.");
            if (o.LocalEncryptionKey.Length == 0 && !errors.Any(e => e.Contains("LocalEncryptionKey"))) errors.Add("Licensing:LocalEncryptionKey is not set.");
            throw new InvalidOperationException("eCare360 licensing is enabled but not configured: " + string.Join(" ", errors));
        }
    }

    private static byte[] Base64(string? value, int length, string name, List<string> errors)
    {
        if (string.IsNullOrWhiteSpace(value)) return Array.Empty<byte>();
        try
        {
            var bytes = Convert.FromBase64String(value.Trim());
            if (bytes.Length == length) return bytes;
            errors.Add($"{name} must be {length} bytes (base64).");
        }
        catch (FormatException) { errors.Add($"{name} is not valid base64."); }
        return Array.Empty<byte>();
    }
}
