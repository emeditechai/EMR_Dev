using System.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Data;

/// <summary>
/// The connection to the vendor's central register (Central_Lic_DB: Central_Company, Central_Users), used by the API to
/// answer the mobile apps - which company a user belongs to (company ID) and which API address to call.
/// Built here in code, not read from appsettings.json: the server and database are fixed (the same ones as the web
/// application's licensing, EMR.Web LicensingPolicy.Central), so a client's appsettings cannot point it elsewhere.
/// The login is not written in the source either:
///   1. CENTRAL_LICENSE_REMOTE_USERNAME / CENTRAL_LICENSE_REMOTE_PASSWORD (environment) when set, else
///   2. the User Id / Password of this API's own DefaultConnection, but only when that connection is on the central
///      server itself (it is never sent to any other server).
/// When neither gives a login, <see cref="IsConfigured"/> is false and <see cref="CreateConnection"/> throws.
/// </summary>
public static class CentralLicDb
{
    public const string Server = "103.178.113.61,1232";
    public const string Database = "Central_Lic_DB";
#if DEBUG
    /// <summary>Debug builds only: CENTRAL_LICENSE_REMOTE_DATABASE=Dev_CentralLic_DB uses this test copy (as EMR.Web).</summary>
    public const string TestDatabase = "Dev_CentralLic_DB";
#endif
    public const int ConnectTimeoutSeconds = 10;

    private static string? _connectionString;
    private static string? _problem;

    /// <summary>True when a login for the central server was found.</summary>
    public static bool IsConfigured => _connectionString is not null;

    /// <summary>Why the central connection is not available (null when it is).</summary>
    public static string? Problem => _problem;

    /// <summary>Call once at start-up, after the connection strings are decrypted (Program.cs).</summary>
    public static void Initialize(IConfiguration config)
    {
        var database = Database;
#if DEBUG
        if (string.Equals(config["CENTRAL_LICENSE_REMOTE_DATABASE"]?.Trim(), TestDatabase, StringComparison.OrdinalIgnoreCase))
            database = TestDatabase;
#endif
        var user = config["CENTRAL_LICENSE_REMOTE_USERNAME"]?.Trim() ?? string.Empty;
        var password = config["CENTRAL_LICENSE_REMOTE_PASSWORD"] ?? string.Empty;
        if (string.IsNullOrWhiteSpace(user) && string.IsNullOrEmpty(password))
            TryLoginFromDefaultConnection(config, out user, out password);

        if (string.IsNullOrWhiteSpace(user) || string.IsNullOrEmpty(password))
        {
            _connectionString = null;
            _problem = $"No login for the central database: DefaultConnection is not on {Server}, so set CENTRAL_LICENSE_REMOTE_USERNAME and CENTRAL_LICENSE_REMOTE_PASSWORD.";
            return;
        }

        _connectionString = new SqlConnectionStringBuilder
        {
            DataSource = Server,
            InitialCatalog = database,
            UserID = user,
            Password = password,
            Encrypt = true,                    // always encrypted; the server's self-signed certificate is accepted
            TrustServerCertificate = true,
            ConnectTimeout = ConnectTimeoutSeconds,
            ApplicationName = "eCare360 API Central"
        }.ConnectionString;
        _problem = null;
    }

    /// <summary>A new (closed) connection to Central_Lic_DB, for Dapper.</summary>
    public static IDbConnection CreateConnection() =>
        new SqlConnection(_connectionString ?? throw new InvalidOperationException(_problem ?? "CentralLicDb.Initialize was not called."));

    private static void TryLoginFromDefaultConnection(IConfiguration config, out string user, out string password)
    {
        user = password = string.Empty;
        try
        {
            var cs = config.GetConnectionString("DefaultConnection");
            if (string.IsNullOrWhiteSpace(cs)) return;
            var b = new SqlConnectionStringBuilder(cs);
            if (b.IntegratedSecurity || string.IsNullOrWhiteSpace(b.UserID) || string.IsNullOrEmpty(b.Password)) return;
            if (NormalizeServer(b.DataSource) != NormalizeServer(Server)) return;
            user = b.UserID.Trim();
            password = b.Password;
        }
        catch { /* malformed DefaultConnection: no login from it */ }
    }

    private static string NormalizeServer(string? dataSource) =>
        new string((dataSource ?? string.Empty).Trim().ToLowerInvariant().Replace("tcp:", string.Empty)
                   .Where(c => !char.IsWhiteSpace(c)).ToArray());
}
