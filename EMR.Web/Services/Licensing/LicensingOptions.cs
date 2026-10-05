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

    /// <summary>The vendor's central licence database. Fixed: pointing the application at another server or database
    /// would be a way round the licence.</summary>
    public static class Central
    {
        public const string Server = "103.178.113.61,1232";
        public const string Database = "Central_Lic_DB";
#if DEBUG
        /// <summary>Debug builds only (developers' tests): CENTRAL_LICENSE_REMOTE_DATABASE may choose this test copy.
        /// A Release build (every publish) always uses <see cref="Database"/>.</summary>
        public const string TestDatabase = "Dev_CentralLic_DB";
#endif
    }

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
/// eCare360 licensing settings. The licence is enforced on every machine that runs the application - server or local,
/// any environment - and there is no switch to turn it off. Per installation ("Licensing" section of appsettings.json):
/// AppUrl, VendorContact, ExpiryWarningDays, RemoteConnectionTimeoutSeconds, CentralTrustServerCertificate, and in
/// Development only EmailPickupDirectory. The rules in <see cref="LicensingPolicy"/> are read-only here, so a value for
/// them in appsettings.json is ignored. Nothing has to be set on a server (as in eRestoPOS): the licence database login
/// is the application's own DefaultConnection login when that database is on the licence server, and the mailbox
/// password comes from the vendor's central mail configuration. Either can be overridden (environment / user-secrets):
///   CENTRAL_LICENSE_REMOTE_USERNAME, CENTRAL_LICENSE_REMOTE_PASSWORD, LicensingMail:Password (LicensingMail__Password).
/// The local signing and encryption keys are created per machine on first start (<see cref="LocalKeyStore"/>) unless
/// Licensing:LocalSigningKey / Licensing:LocalEncryptionKey are configured. A missing password does not stop the
/// application: every page shows "Licensing not configured" (ConfigurationMissing) until it is set.
/// </summary>
public sealed class LicensingOptions
{
    public const string Section = "Licensing";

    /// <summary>Always true: every machine must hold a registered licence.</summary>
    public bool Enabled => true;
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

    // licence server (fixed) and secrets (read by LoadSecretsAndValidate, not from the Licensing section)
    public string CentralServer => LicensingPolicy.Central.Server;
    public string CentralDatabase { get; private set; } = LicensingPolicy.Central.Database;
    public string CentralUsername { get; set; } = string.Empty;
    public string CentralPassword { get; set; } = string.Empty;
    public byte[] LocalSigningKey { get; set; } = Array.Empty<byte>();
    public byte[] LocalEncryptionKey { get; set; } = Array.Empty<byte>();
    public string MailPassword { get; set; } = string.Empty;
    /// <summary>Set when licensing cannot work on this machine (a password missing, a malformed setting, no place for
    /// the local keys): the gate then answers ConfigurationMissing with this text instead of the application failing.</summary>
    public string? ConfigurationProblem { get; private set; }
    /// <summary>"DefaultConnection" when the licence database login is the application's own database login.</summary>
    public string CentralLoginSource { get; private set; } = "configuration";
    /// <summary>Where this machine's generated local keys are kept (null when they come from configuration).</summary>
    public string? LocalKeyLocation { get; private set; }

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

    /// <summary>Reads the passwords and the local keys (creating them on first start). Never throws: anything missing is
    /// recorded in <see cref="ConfigurationProblem"/>, which blocks every page until it is fixed.</summary>
    public static void LoadSecretsAndValidate(LicensingOptions o, IConfiguration config, string contentRootPath)
    {
        var errors = new List<string>();
#if DEBUG
        if (string.Equals(config["CENTRAL_LICENSE_REMOTE_DATABASE"]?.Trim(), LicensingPolicy.Central.TestDatabase, StringComparison.OrdinalIgnoreCase))
            o.CentralDatabase = LicensingPolicy.Central.TestDatabase;
#endif
        // licence database login: configured values win; otherwise the application's own DefaultConnection login is used,
        // but only when that connection is on the licence server itself (it is never sent to any other server)
        o.CentralUsername = config["CENTRAL_LICENSE_REMOTE_USERNAME"]?.Trim() ?? string.Empty;
        o.CentralPassword = config["CENTRAL_LICENSE_REMOTE_PASSWORD"] ?? string.Empty;
        if (string.IsNullOrWhiteSpace(o.CentralUsername) && string.IsNullOrEmpty(o.CentralPassword)
            && TryLoginFromDefaultConnection(config, out var user, out var password))
        {
            o.CentralUsername = user;
            o.CentralPassword = password;
            o.CentralLoginSource = "DefaultConnection";
        }
        if (string.IsNullOrWhiteSpace(o.CentralUsername) || string.IsNullOrEmpty(o.CentralPassword))
            errors.Add($"No login for the licence server: the application's database is not on {LicensingPolicy.Central.Server}, so set CENTRAL_LICENSE_REMOTE_USERNAME and CENTRAL_LICENSE_REMOTE_PASSWORD.");
        // the mailbox password is optional here: without it, it is read from the central mail configuration when sending
        o.MailPassword = config["LicensingMail:Password"] ?? string.Empty;

        if (!string.IsNullOrWhiteSpace(o.AppUrl))
        {
            if (!Uri.TryCreate(o.AppUrl.Trim(), UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https") || !string.IsNullOrEmpty(u.Query))
                errors.Add("Licensing:AppUrl must be scheme://host[:port][/path], e.g. https://ecare.hospital.in.");
            else o.AppUrl = o.AppUrl.Trim().TrimEnd('/').ToLowerInvariant();
        }

        // local keys: configured ones win (both or neither); otherwise this machine's own, created on first start
        var signing = Base64(config["Licensing:LocalSigningKey"], 32, "Licensing:LocalSigningKey", errors);
        var encryption = Base64(config["Licensing:LocalEncryptionKey"], 32, "Licensing:LocalEncryptionKey", errors);
        if (signing.Length == 32 && encryption.Length == 32) { o.LocalSigningKey = signing; o.LocalEncryptionKey = encryption; }
        else
        {
            var keys = LocalKeyStore.LoadOrCreate(contentRootPath, out var location, out var keyError);
            if (keys is null) errors.Add("The local licence keys could not be stored on this machine: " + keyError);
            else { o.LocalSigningKey = keys.Value.Signing; o.LocalEncryptionKey = keys.Value.Encryption; o.LocalKeyLocation = location; }
        }
        // the application still needs keys to run its pages, even while blocked
        if (o.LocalSigningKey.Length == 0) o.LocalSigningKey = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        if (o.LocalEncryptionKey.Length == 0) o.LocalEncryptionKey = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);

        o.ConfigurationProblem = errors.Count == 0 ? null : string.Join(" ", errors);
    }

    /// <summary>The User Id / Password of ConnectionStrings:DefaultConnection when that connection points at the licence
    /// server (same host and port), so a server whose database lives there needs no licensing setup at all.</summary>
    private static bool TryLoginFromDefaultConnection(IConfiguration config, out string user, out string password)
    {
        user = password = string.Empty;
        try
        {
            var cs = config.GetConnectionString("DefaultConnection");
            if (string.IsNullOrWhiteSpace(cs)) return false;
            var b = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(cs);
            if (b.IntegratedSecurity || string.IsNullOrWhiteSpace(b.UserID) || string.IsNullOrEmpty(b.Password)) return false;
            if (NormalizeServer(b.DataSource) != NormalizeServer(LicensingPolicy.Central.Server)) return false;
            user = b.UserID.Trim();
            password = b.Password;
            return true;
        }
        catch { return false; }
    }

    private static string NormalizeServer(string? dataSource) =>
        new string((dataSource ?? string.Empty).Trim().ToLowerInvariant().Replace("tcp:", string.Empty).Where(c => !char.IsWhiteSpace(c)).ToArray());

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
