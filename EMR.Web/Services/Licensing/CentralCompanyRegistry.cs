using System.Data;
using Dapper;
using EMR.Shared.Security;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services.Licensing;

/// <summary>A company's place in the central company register (Central_Lic_DB.dbo.Central_Company, SQLScripts/2467).</summary>
public sealed class CentralCompanyStatus
{
    /// <summary>SYNCED (this company's row, same code, name and API address), OUTDATED (same code, older name / API address), CODE_CHANGED (this company's row holds an older code), NOT_PUSHED,
    /// CONFLICT (another installation / company holds the code) or UNAVAILABLE (central database not reachable).</summary>
    public string State { get; init; } = "UNAVAILABLE";
    public string Message { get; init; } = string.Empty;
    public string? CentralCompanyName { get; init; }
    public int? CentralCompanyId { get; init; }
    public string? ApiUrl { get; init; }
    /// <summary>The installation's web address stored centrally (SQLScripts/2473).</summary>
    public string? WebUrl { get; init; }
    /// <summary>The company's validity stored centrally (SQLScripts/2473).</summary>
    public DateTime? ValidFrom { get; init; }
    public DateTime? ValidTo { get; init; }
    public DateTime? CreatedDate { get; init; }
    public DateTime? ModifiedDate { get; init; }
    public bool CanPush => State is "NOT_PUSHED" or "CODE_CHANGED" or "OUTDATED";
}

/// <summary>Result of a push: Status CREATED / UPDATED / UNCHANGED / CONFLICT / UNAVAILABLE.</summary>
public sealed record CentralCompanyPushResult(string Status, string Message, int? CentralCompanyId = null)
{
    public bool Ok => Status is "CREATED" or "UPDATED" or "UNCHANGED";
}

/// <summary>
/// The central company register: every company of every eCare360 installation, Company Code unique across all of them.
/// Uses the licensing connection to the vendor's central database (same login, <see cref="LicensingOptions"/>) and only
/// its two procedures (usp_CentralCompany_Get / _Push). Never throws: when the central database cannot be reached the
/// application carries on and the company can be pushed later from its profile.
/// This installation is told apart by its DefaultConnection (server | database); the connection string is stored
/// ENC: encrypted (<see cref="ConnectionStringCrypto"/>) and, as asked, also decrypted (DecryptedConnectionString).
/// </summary>
public interface ICentralCompanyRegistry
{
    Task<CentralCompanyStatus> GetStatusAsync(int companyId, string companyCode, string? companyName = null);

    Task<CentralCompanyPushResult> PushAsync(int companyId, string companyCode, string companyName);

    /// <summary>For a new company: the message when another installation already holds the code; null when the code is
    /// free centrally or the central database cannot be reached (never blocks creation for that).</summary>
    Task<string?> CodeTakenElsewhereAsync(string companyCode);

    /// <summary>The Central_Company.ID of this installation's company (SQLScripts/2470 maps users to it). When the company
    /// is not registered yet (or its code / name / API address changed) and <paramref name="pushIfNeeded"/> is set, it is
    /// pushed first. Error is set when it cannot be mapped (code held by another installation, central DB unreachable).</summary>
    /// Unreachable is true when the central database could not be reached (as opposed to a company that cannot be mapped).
    Task<(int? CentralCompanyId, string? Error, bool Unreachable)> ResolveAsync(int companyId, string companyCode, string companyName, bool pushIfNeeded);

    /// <summary>This installation's key (server|database of DefaultConnection) - Central_Company.InstanceKey; central usernames
    /// are unique per installation (SQLScripts/2470).</summary>
    string InstanceKey { get; }
}

public sealed class CentralCompanyRegistry(
    IOptions<LicensingOptions> options,
    IConfiguration configuration,
    IHttpContextAccessor httpContextAccessor,
    ILogger<CentralCompanyRegistry> logger) : ICentralCompanyRegistry
{
    private readonly LicensingOptions _o = options.Value;

    private bool Configured => !string.IsNullOrWhiteSpace(_o.CentralUsername) && !string.IsNullOrEmpty(_o.CentralPassword);

    private SqlConnection Open() => new(_o.CentralConnectionString);

    private int Timeout => Math.Max(5, _o.RemoteConnectionTimeoutSeconds * 2);

    /// <summary>server|database of this installation's application database, lower case.</summary>
    public string InstanceKey
    {
        get
        {
            var b = new SqlConnectionStringBuilder(configuration.GetConnectionString("DefaultConnection") ?? string.Empty);
            var server = new string((b.DataSource ?? string.Empty).Trim().ToLowerInvariant().Replace("tcp:", string.Empty)
                                    .Where(c => !char.IsWhiteSpace(c)).ToArray());
            return $"{server}|{(b.InitialCatalog ?? string.Empty).Trim().ToLowerInvariant()}";
        }
    }

    /// <summary>This instance's DefaultConnection in plain text (decrypted when appsettings holds it ENC:).</summary>
    private string DecryptedConnectionString
    {
        get
        {
            var cs = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
            if (!cs.StartsWith(ConnectionStringCrypto.Prefix, StringComparison.Ordinal)) return cs;
            try { return ConnectionStringCrypto.Decrypt(cs); } catch { return string.Empty; }
        }
    }

    private string EncryptedConnectionString
    {
        get
        {
            var cs = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
            return cs.StartsWith(ConnectionStringCrypto.Prefix, StringComparison.Ordinal) ? cs : ConnectionStringCrypto.Encrypt(cs);
        }
    }

    /// <summary>This instance's EMR.Api address (ApiSettings:BaseUrl - what this application calls), no trailing slash.</summary>
    private string? ApiUrl => configuration["ApiSettings:BaseUrl"]?.Trim().TrimEnd('/') is { Length: > 0 } u ? u : null;

    /// <summary>
    /// SQLScripts/2473: this installation's web address - Licensing:AppUrl when configured (the address the licence is bound
    /// to), else the address the current request reached the application at (scheme://host[:port][/base]); null when neither
    /// is known (a background sync), so a push keeps the address stored centrally. Lower case, no trailing slash.
    /// </summary>
    private string? WebUrl
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(_o.AppUrl)) return _o.AppUrl.Trim().TrimEnd('/').ToLowerInvariant();
            var req = httpContextAccessor.HttpContext?.Request;
            if (req is null || !req.Host.HasValue) return null;
            return $"{req.Scheme}://{req.Host.Value}{req.PathBase.Value}".TrimEnd('/').ToLowerInvariant();
        }
    }

    private sealed class ValidityRow { public DateTime? ValidFrom { get; set; } public DateTime? ValidTo { get; set; } }

    /// <summary>SQLScripts/2472 / 2474: the company's Valid From / Valid To in the application database (null when not readable,
    /// so a push keeps the dates stored centrally).</summary>
    private async Task<(DateTime? From, DateTime? To)> ValidityAsync(int companyId)
    {
        try
        {
            await using var app = new SqlConnection(configuration.GetConnectionString("DefaultConnection"));
            var v = await app.QueryFirstOrDefaultAsync<ValidityRow>("dbo.usp_Company_CentralGet", new { CompanyId = companyId },
                commandType: CommandType.StoredProcedure);
            return (v?.ValidFrom?.Date, v?.ValidTo?.Date);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central company register: validity of company {CompanyId} not read", companyId);
            return (null, null);
        }
    }

    private const string Unreachable = "The central company register could not be reached. The company works normally; push it again later.";

    private sealed class Row
    {
        public string Match { get; set; } = "";
        public int ID { get; set; }
        public string CompanyCode { get; set; } = "";
        public string CompanyName { get; set; } = "";
        public int ApplicationCompanyID { get; set; }
        public string? ApiUrl { get; set; }
        public string? WebUrl { get; set; }
        public DateTime? ValidFrom { get; set; }
        public DateTime? ValidTo { get; set; }
        public bool SameInstance { get; set; }
        public DateTime CreatedDate { get; set; }
        public DateTime? ModifiedDate { get; set; }
    }

    private sealed class PushRow
    {
        public string Status { get; set; } = "";
        public string Message { get; set; } = "";
        public int? ID { get; set; }
    }

    private async Task<List<Row>> GetRowsAsync(string code, int? companyId)
    {
        await using var cn = Open();
        return (await cn.QueryAsync<Row>("dbo.usp_CentralCompany_Get",
            new { CompanyCode = code, InstanceKey, ApplicationCompanyID = companyId },
            commandType: CommandType.StoredProcedure, commandTimeout: Timeout)).ToList();
    }

    public async Task<CentralCompanyStatus> GetStatusAsync(int companyId, string companyCode, string? companyName = null)
    {
        if (!Configured) return new CentralCompanyStatus { State = "UNAVAILABLE", Message = "The central licence database is not configured on this server." };
        var code = (companyCode ?? string.Empty).Trim().ToUpperInvariant();
        try
        {
            var rows = await GetRowsAsync(code, companyId);
            var byCode = rows.FirstOrDefault(r => r.Match == "CODE");
            var own = rows.FirstOrDefault(r => r.Match == "INSTANCE");
            if (byCode is not null && byCode.SameInstance && byCode.ApplicationCompanyID == companyId)
            {
                // the name, the API address or the web address changed here and was not pushed yet (e.g. the central server was down);
                // the web address only counts when it is known now (a request or Licensing:AppUrl)
                var web = WebUrl;
                var (from, to) = await ValidityAsync(companyId);
                var stale = (companyName is not null && !string.Equals(byCode.CompanyName, companyName.Trim(), StringComparison.Ordinal))
                            || !string.Equals(byCode.ApiUrl ?? "", ApiUrl ?? "", StringComparison.OrdinalIgnoreCase)
                            || (web is not null && !string.Equals(byCode.WebUrl ?? "", web, StringComparison.OrdinalIgnoreCase))
                            || (from is not null && byCode.ValidFrom?.Date != from) || (to is not null && byCode.ValidTo?.Date != to);
                return new CentralCompanyStatus { State = stale ? "OUTDATED" : "SYNCED", CentralCompanyName = byCode.CompanyName, ApiUrl = byCode.ApiUrl, WebUrl = byCode.WebUrl,
                    ValidFrom = byCode.ValidFrom, ValidTo = byCode.ValidTo,
                    CentralCompanyId = byCode.ID, CreatedDate = byCode.CreatedDate, ModifiedDate = byCode.ModifiedDate,
                    Message = stale ? "Registered centrally, but the name, validity, API or web address there is out of date. Push to update it." : "In the central company register." };
            }
            if (byCode is not null)
                return new CentralCompanyStatus { State = "CONFLICT", CentralCompanyName = byCode.CompanyName, CreatedDate = byCode.CreatedDate,
                    Message = byCode.SameInstance
                        ? $"Code {code} is registered centrally for another company of this installation ({byCode.CompanyName})."
                        : $"Code {code} is already registered centrally by another eCare360 installation ({byCode.CompanyName}). Change this company's code to push it." };
            if (own is not null)
                return new CentralCompanyStatus { State = "CODE_CHANGED", CentralCompanyId = own.ID, CentralCompanyName = own.CompanyName, WebUrl = own.WebUrl, CreatedDate = own.CreatedDate, ModifiedDate = own.ModifiedDate,
                    Message = $"Registered centrally under the old code {own.CompanyCode}. Push to update it to {code}." };
            return new CentralCompanyStatus { State = "NOT_PUSHED", Message = "Not in the central company register yet." };
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central company register: status of company {CompanyId} ({Code}) not read", companyId, code);
            return new CentralCompanyStatus { State = "UNAVAILABLE", Message = Unreachable };
        }
    }

    public async Task<CentralCompanyPushResult> PushAsync(int companyId, string companyCode, string companyName)
    {
        if (!Configured) return new("UNAVAILABLE", "The central licence database is not configured on this server.");
        var code = (companyCode ?? string.Empty).Trim().ToUpperInvariant();
        try
        {
            var (validFrom, validTo) = await ValidityAsync(companyId);
            await using var cn = Open();
            var r = await cn.QueryFirstAsync<PushRow>("dbo.usp_CentralCompany_Push",
                new { CompanyCode = code, CompanyName = (companyName ?? string.Empty).Trim(), ApplicationCompanyID = companyId,
                      ConnectionString = EncryptedConnectionString, InstanceKey, ApiUrl, DecryptedConnectionString, WebUrl,
                      ValidFrom = validFrom, ValidTo = validTo },
                commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
            if (r.Status == "CONFLICT")
                logger.LogWarning("Central company register: company {CompanyId} ({Code}) not pushed - {Message}", companyId, code, r.Message);
            return new(r.Status, r.Message, r.Status == "CONFLICT" ? null : r.ID);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central company register: company {CompanyId} ({Code}) not pushed", companyId, code);
            return new("UNAVAILABLE", Unreachable);
        }
    }

    public async Task<string?> CodeTakenElsewhereAsync(string companyCode)
    {
        if (!Configured) return null;
        var code = (companyCode ?? string.Empty).Trim().ToUpperInvariant();
        if (code.Length == 0) return null;
        try
        {
            var byCode = (await GetRowsAsync(code, null)).FirstOrDefault(r => r.Match == "CODE");
            return byCode is { SameInstance: false }
                ? $"This company code is already registered by another eCare360 installation ({byCode.CompanyName}). Company codes must be unique across all installations."
                : null;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central company register: code {Code} not checked", code);
            return null;
        }
    }

    public async Task<(int? CentralCompanyId, string? Error, bool Unreachable)> ResolveAsync(int companyId, string companyCode, string companyName, bool pushIfNeeded)
    {
        if (!Configured) return (null, "The central licence database is not configured on this server.", true);
        var st = await GetStatusAsync(companyId, companyCode, companyName);
        if (st.State == "SYNCED" && st.CentralCompanyId is > 0) return (st.CentralCompanyId, null, false);
        if (st.State == "UNAVAILABLE") return (null, st.Message, true);
        if (st.State == "CONFLICT") return (null, st.Message, false);
        if (!pushIfNeeded) return (st.CentralCompanyId, st.CentralCompanyId is > 0 ? null : st.Message, false);
        var r = await PushAsync(companyId, companyCode, companyName);
        return r.Ok && r.CentralCompanyId is > 0 ? (r.CentralCompanyId, null, false) : (null, r.Message, r.Status == "UNAVAILABLE");
    }
}
