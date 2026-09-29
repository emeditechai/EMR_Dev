using System.Data;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;

namespace EMR.Shared.Security;

/// <summary>The only place the authorization tables are read or written from application code.</summary>
public interface IPermissionDataSource
{
    Task<UserSecurityState?> GetUserStateAsync(int userId);
    Task<IReadOnlyList<EffectivePermissionRow>> GetEffectivePermissionsAsync(int userId, int branchId, int companyId, int? roleId);
    Task<IReadOnlyList<EndpointMapRow>> GetEndpointMapAsync(string app);
    Task<IReadOnlyDictionary<string, int>> GetRoleIdsAsync(int companyId);
    Task<(int Found, int Unmapped, int Orphaned, int Public)> RegisterDiscoveredEndpointsAsync(string app, IEnumerable<DiscoveredEndpoint> endpoints);
    Task WriteDecisionLogAsync(IReadOnlyCollection<DecisionLogEntry> entries);
    Task<NavTree> GetNavTreeAsync(int companyId);
}

public sealed record DiscoveredEndpoint(string HttpMethod, string Controller, string Action, string? Route, bool IsPublic,
    string? PageCode = null, string? ControlCode = null);

public sealed class DecisionLogEntry
{
    public DateTime LoggedOn { get; init; } = DateTime.Now;
    public string App { get; init; } = "WEB";
    public string Mode { get; init; } = "AUDIT";
    public string Outcome { get; init; } = "DENIED";
    public int? UserId { get; init; }
    public int? BranchId { get; init; }
    public int? RoleId { get; init; }
    public string HttpMethod { get; init; } = "GET";
    public string Controller { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public string? Path { get; init; }
    public string? PageCode { get; init; }
    public string? ControlCode { get; init; }
    public int? DecidedAtScope { get; init; }
    public string? DecidedBy { get; init; }
}

public sealed class NavMenuRow
{
    public int Menu_ID { get; set; }
    public int? Parent_Menu_ID { get; set; }
    public string Menu_Type { get; set; } = "NAV";
    public string Menu_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Icon { get; set; }
    public int Sort_Order { get; set; }
}

public sealed class NavPageRow
{
    public int Page_ID { get; set; }
    public int? Menu_ID { get; set; }
    public string Page_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string? Area { get; set; }
    public string? Icon { get; set; }
    public string? Route_Values { get; set; }
    public string? Link_Target { get; set; }
    public int Sort_Order { get; set; }
}

public sealed record NavTree(IReadOnlyList<NavMenuRow> Menus, IReadOnlyList<NavPageRow> Pages);

public sealed class SqlPermissionDataSource(string connectionString) : IPermissionDataSource
{
    private IDbConnection Open() => new SqlConnection(connectionString);

    public async Task<UserSecurityState?> GetUserStateAsync(int userId)
    {
        using var con = Open();
        return await con.QueryFirstOrDefaultAsync<UserSecurityState>(
            "dbo.usp_Auth_GetPermissionVersion", new { UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<EffectivePermissionRow>> GetEffectivePermissionsAsync(int userId, int branchId, int companyId, int? roleId)
    {
        using var con = Open();
        var rows = await con.QueryAsync<EffectivePermissionRow>(
            "dbo.usp_Auth_GetEffectivePermissions",
            new { UserId = userId, BranchId = branchId, CompanyId = companyId, RoleId = roleId },
            commandType: CommandType.StoredProcedure);
        return rows.ToList();
    }

    public async Task<IReadOnlyList<EndpointMapRow>> GetEndpointMapAsync(string app)
    {
        using var con = Open();
        var rows = await con.QueryAsync<EndpointMapRow>(
            "SELECT e.App, e.Http_Method, e.Controller, e.Action, p.Page_Code, c.Control_Code, e.Is_Public " +
            "FROM dbo.PageEndpointMap e " +
            "LEFT JOIN dbo.PageMaster p ON p.Page_ID = e.Page_ID AND p.IsActive = 1 " +
            "LEFT JOIN dbo.PageControlMaster c ON c.Control_ID = e.Control_ID AND c.IsActive = 1 " +
            "WHERE e.IsActive = 1 AND e.App = @App", new { App = app });
        return rows.ToList();
    }

    public async Task<IReadOnlyDictionary<string, int>> GetRoleIdsAsync(int companyId)
    {
        using var con = Open();
        var rows = await con.QueryAsync<(int Id, string Name)>(
            "SELECT Id, Name FROM dbo.roles WHERE CompanyId = @CompanyId OR CompanyId IS NULL", new { CompanyId = companyId });
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, name) in rows) map.TryAdd(name, id);
        return map;
    }

    public async Task<(int Found, int Unmapped, int Orphaned, int Public)> RegisterDiscoveredEndpointsAsync(string app, IEnumerable<DiscoveredEndpoint> endpoints)
    {
        var json = JsonSerializer.Serialize(endpoints.Select(e => new { m = e.HttpMethod, c = e.Controller, a = e.Action, r = e.Route, p = e.IsPublic, pc = e.PageCode, cc = e.ControlCode }));
        using var con = Open();
        var r = await con.QueryFirstAsync<(int Found, int Unmapped, int Orphaned, int PublicEndpoints)>(
            "dbo.usp_Auth_PageEndpointMap_RegisterDiscoveredBulk", new { App = app, Json = json },
            commandType: CommandType.StoredProcedure, commandTimeout: 120);
        return (r.Found, r.Unmapped, r.Orphaned, r.PublicEndpoints);
    }

    public async Task WriteDecisionLogAsync(IReadOnlyCollection<DecisionLogEntry> entries)
    {
        if (entries.Count == 0) return;
        using var con = Open();
        await con.ExecuteAsync("dbo.usp_Auth_DecisionLog_InsertBulk",
            new { Json = JsonSerializer.Serialize(entries) }, commandType: CommandType.StoredProcedure);
    }

    public async Task<NavTree> GetNavTreeAsync(int companyId)
    {
        using var con = Open();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_GetNavTree", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        var menus = (await multi.ReadAsync<NavMenuRow>()).ToList();
        var pages = (await multi.ReadAsync<NavPageRow>()).ToList();
        return new NavTree(menus, pages);
    }
}
