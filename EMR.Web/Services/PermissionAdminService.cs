using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services;

/// <summary>A refusal raised by the authorization procedures, carried to the screen as-is.</summary>
public sealed class PermissionAdminException(string message, string code = "INVALID") : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>
/// Data access for the Settings > Security screens. Writes go straight to the database from the
/// authenticated, always-enforced web app - deliberately not through EMR.Api, which is still open.
/// Every rule is enforced by the procedures; after a save the caches of the affected users are dropped
/// so the change applies on their very next request.
/// </summary>
public interface IPermissionAdminService
{
    Task<AdminTree> GetTreeAsync(int companyId);
    Task<int> SaveMenuAsync(int companyId, AdminMenuRow menu, int userId);
    Task SetMenuActiveAsync(int companyId, int menuId, bool isActive, int userId);
    Task<int> SavePageAsync(int companyId, AdminPageRow page, bool confirmCodeChange, int userId);
    Task SetPageActiveAsync(int companyId, int pageId, bool isActive, int userId);
    Task<int> SaveControlAsync(int companyId, int pageId, int? controlId, string controlCode, string? title, int userId);
    Task SetControlActiveAsync(int companyId, int controlId, bool isActive, int userId);
    Task<(List<AdminEndpointRow> Rows, EndpointStats Stats)> GetEndpointsAsync(string filter, int? pageId);
    Task<int> MapEndpointsAsync(int companyId, IEnumerable<(int EndpointId, int PageId, string ControlCode)> mappings, int userId);
    Task UnmapEndpointAsync(int companyId, int endpointId);
    Task<List<EndpointProposal>> ProposeMappingsAsync(int companyId);

    Task<(List<GrantRow> Grants, RoleGrantsMeta Meta)> GetRoleGrantsAsync(int companyId, int roleId, int? branchId);
    Task<SaveGrantsResult> SaveRoleGrantsAsync(int companyId, SaveGrantsRequest request, PermissionSubject actor, string guardPageCode);
    Task CopyRoleGrantsAsync(int companyId, int fromRoleId, int toRoleId, PermissionSubject actor, string guardPageCode);

    Task<UserGrantsBundle> GetUserGrantsAsync(int companyId, int userId, int? branchId);
    Task<SaveGrantsResult> SaveUserGrantsAsync(int companyId, SaveGrantsRequest request, PermissionSubject actor, string guardPageCode);

    Task<List<EffectivePermissionRow>> GetEffectiveAsync(int companyId, int userId, int branchId, int? roleId, bool ignoreUserRows);
    Task<(List<ExplainRow> Rows, List<ExplainLevel> Levels)> ExplainAsync(int userId, int branchId, int? roleId, int pageId, int? controlId);
    Task<List<HistoryRow>> GetHistoryAsync(string entity, int targetId);
    Task<List<DecisionLogRow>> GetDecisionLogAsync(DateTime? from, int? userId);

    Task<List<LookupItem>> GetRolesAsync(int companyId);
    Task<List<LookupItem>> GetUsersAsync(int companyId);
    Task<List<LookupItem>> GetBranchesAsync(int companyId);
    Task<List<LookupItem>> GetSuperAdminsAsync(int companyId);
    Task<int?> ResolveRoleIdAsync(int companyId, string? roleName);
}

public sealed class UserGrantsBundle
{
    public UserGrantsHeader? User { get; set; }
    public List<GrantRow> Grants { get; set; } = new();
    public int Version { get; set; }
    public List<LookupItem> Branches { get; set; } = new();
    public List<UserRoleRow> Roles { get; set; } = new();
    /// <summary>What the roles alone give (every page and control), for the "From role" column.</summary>
    public List<EffectivePermissionRow> FromRole { get; set; } = new();
}

public sealed class PermissionAdminService(IDbConnectionFactory db, IPermissionService permissions) : IPermissionAdminService
{
    // ── Menu & Page Master ────────────────────────────────────────────────
    public async Task<AdminTree> GetTreeAsync(int companyId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_GetTree", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        return new AdminTree
        {
            Menus = (await multi.ReadAsync<AdminMenuRow>()).ToList(),
            Pages = (await multi.ReadAsync<AdminPageRow>()).ToList(),
            Controls = (await multi.ReadAsync<AdminControlRow>()).ToList(),
            Vocabulary = (await multi.ReadAsync<ControlVocabularyRow>()).ToList()
        };
    }

    public Task<int> SaveMenuAsync(int companyId, AdminMenuRow m, int userId) => Run(async con =>
    {
        var id = await con.QueryFirstAsync<int>("dbo.usp_Auth_Admin_SaveMenu", new
        {
            Menu_ID = m.Menu_ID, CompanyId = companyId, m.Parent_Menu_ID, m.Menu_Code, m.Title, m.Icon, m.Sort_Order, UserId = userId
        }, commandType: CommandType.StoredProcedure);
        permissions.InvalidateNavigation();
        return id;
    });

    public Task SetMenuActiveAsync(int companyId, int menuId, bool isActive, int userId) => Run(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Auth_Admin_SetMenuActive", new { Menu_ID = menuId, CompanyId = companyId, IsActive = isActive, UserId = userId },
            commandType: CommandType.StoredProcedure);
        AfterTreeChange();
        return 0;
    });

    public Task<int> SavePageAsync(int companyId, AdminPageRow p, bool confirmCodeChange, int userId) => Run(async con =>
    {
        var id = await con.QueryFirstAsync<int>("dbo.usp_Auth_Admin_SavePage", new
        {
            p.Page_ID, CompanyId = companyId, p.Menu_ID, p.Page_Code, p.Title, p.Controller, p.Action, p.Area, p.Show_In_Menu, p.Sort_Order,
            p.Icon, p.Route_Values, p.Link_Target, ConfirmCodeChange = confirmCodeChange, UserId = userId
        }, commandType: CommandType.StoredProcedure);
        AfterTreeChange();
        return id;
    });

    public Task SetPageActiveAsync(int companyId, int pageId, bool isActive, int userId) => Run(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Auth_Admin_SetPageActive", new { Page_ID = pageId, CompanyId = companyId, IsActive = isActive, UserId = userId },
            commandType: CommandType.StoredProcedure);
        AfterTreeChange();
        return 0;
    });

    public Task<int> SaveControlAsync(int companyId, int pageId, int? controlId, string controlCode, string? title, int userId) => Run(async con =>
    {
        var id = await con.QueryFirstAsync<int>("dbo.usp_Auth_Admin_SaveControl", new
        {
            Control_ID = controlId, Page_ID = pageId, CompanyId = companyId, Control_Code = controlCode, Title = title, UserId = userId
        }, commandType: CommandType.StoredProcedure);
        AfterTreeChange();
        return id;
    });

    public Task SetControlActiveAsync(int companyId, int controlId, bool isActive, int userId) => Run(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Auth_Admin_SetControlActive", new { Control_ID = controlId, CompanyId = companyId, IsActive = isActive, UserId = userId },
            commandType: CommandType.StoredProcedure);
        AfterTreeChange();
        return 0;
    });

    public async Task<(List<AdminEndpointRow> Rows, EndpointStats Stats)> GetEndpointsAsync(string filter, int? pageId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_GetEndpoints",
            new { App = "WEB", Filter = filter, Page_ID = pageId }, commandType: CommandType.StoredProcedure);
        var rows = (await multi.ReadAsync<AdminEndpointRow>()).ToList();
        var stats = await multi.ReadFirstOrDefaultAsync<EndpointStats>() ?? new EndpointStats();
        return (rows, stats);
    }

    public Task<int> MapEndpointsAsync(int companyId, IEnumerable<(int EndpointId, int PageId, string ControlCode)> mappings, int userId) => Run(async con =>
    {
        var json = JsonSerializer.Serialize(mappings.Select(m => new { e = m.EndpointId, p = m.PageId, c = m.ControlCode }));
        var n = await con.QueryFirstAsync<int>("dbo.usp_Auth_Admin_MapEndpoints", new { CompanyId = companyId, Json = json, UserId = userId },
            commandType: CommandType.StoredProcedure, commandTimeout: 120);
        AfterTreeChange();
        return n;
    });

    public Task UnmapEndpointAsync(int companyId, int endpointId) => Run(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Auth_Admin_UnmapEndpoint", new { Endpoint_ID = endpointId, CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        permissions.InvalidateEndpointMap();
        return 0;
    });

    /// <summary>
    /// Proposes a page and control for every unmapped endpoint. The page comes from the controller
    /// (its own screen, or the only screen that controller serves); the control from the action's verb
    /// and name. Anything not certain is marked for review, never guessed silently.
    /// </summary>
    public async Task<List<EndpointProposal>> ProposeMappingsAsync(int companyId)
    {
        var tree = await GetTreeAsync(companyId);
        var (unmapped, _) = await GetEndpointsAsync("UNMAPPED", null);
        var pagesByController = tree.Pages.Where(p => p.IsActive)
            .GroupBy(p => p.Controller, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var result = new List<EndpointProposal>();
        foreach (var e in unmapped)
        {
            var proposal = new EndpointProposal
            {
                EndpointId = e.Endpoint_ID, HttpMethod = e.Http_Method, Controller = e.Controller, Action = e.Action,
                ControlCode = GuessControl(e.Action, e.Http_Method), Refusals7d = e.Refusals7d
            };
            if (pagesByController.TryGetValue(e.Controller, out var candidates))
            {
                var exact = candidates.Where(p => string.Equals(p.Action, e.Action, StringComparison.OrdinalIgnoreCase)).ToList();
                var screens = candidates.GroupBy(p => p.Action, StringComparer.OrdinalIgnoreCase).ToList();
                List<AdminPageRow> chosen;
                if (exact.Count > 0) { chosen = exact; proposal.Confidence = "high"; proposal.Reason = "The screen's own action."; }
                else if (screens.Count == 1) { chosen = screens[0].ToList(); proposal.Confidence = "high"; proposal.Reason = "The only screen this controller serves."; }
                else
                {
                    chosen = (screens.FirstOrDefault(g => string.Equals(g.Key, "Index", StringComparison.OrdinalIgnoreCase)) ?? screens[0]).ToList();
                    proposal.Confidence = "review";
                    proposal.Reason = $"{e.Controller} serves {screens.Count} screens - check which one this action belongs to.";
                }
                proposal.PageIds = chosen.Select(p => p.Page_ID).ToList();
                proposal.PageTitle = string.Join(" / ", chosen.Select(p => p.Title).Distinct());
                proposal.PageCode = chosen[0].Page_Code;
            }
            else
            {
                proposal.Reason = $"No screen in the tree uses {e.Controller}. Add a page for it, or map it to the screen that calls it.";
            }
            result.Add(proposal);
        }
        return result;
    }

    /// <summary>
    /// Ordinary work (open, look up, create, edit, save, print, export) belongs to the page itself (VIEW), so anyone
    /// given the page can use it. Only money and report-integrity actions get their own control, ticked explicitly.
    /// Kept in step with Tools/Authorization/map_endpoints.py.
    /// </summary>
    internal static string GuessControl(string action, string method)
    {
        var a = action.ToLowerInvariant();
        var isGet = method.Equals("GET", StringComparison.OrdinalIgnoreCase);
        if (isGet && (a.StartsWith("get") || a.StartsWith("search") || a.StartsWith("print") || a.Contains("report")))
            return PermissionControls.View;     // reading about an action is not performing it
        if (a.Contains("unapprove") || a.Contains("unauthori")) return PermissionControls.Unauthorize;
        if (a.Contains("approve")) return PermissionControls.Approve;
        if (a.Contains("refund")) return PermissionControls.Refund;
        if (a.Contains("cancel")) return PermissionControls.Cancel;
        if (a.Contains("settle") || a.Contains("wallettopup")) return PermissionControls.Settle;
        if (a.Contains("discount")) return PermissionControls.Discount;
        if (!isGet && (a.StartsWith("delete") || a.StartsWith("remove"))) return PermissionControls.Delete;
        return PermissionControls.View;
    }

    // ── Role -> Page mapping ──────────────────────────────────────────────
    public async Task<(List<GrantRow> Grants, RoleGrantsMeta Meta)> GetRoleGrantsAsync(int companyId, int roleId, int? branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_GetRoleGrants",
            new { Role_ID = roleId, CompanyId = companyId, Branch_ID = branchId }, commandType: CommandType.StoredProcedure);
        var grants = (await multi.ReadAsync<GrantRow>()).ToList();
        var meta = await multi.ReadFirstOrDefaultAsync<RoleGrantsMeta>() ?? new RoleGrantsMeta();
        return (grants, meta);
    }

    public Task<SaveGrantsResult> SaveRoleGrantsAsync(int companyId, SaveGrantsRequest r, PermissionSubject actor, string guardPageCode) => Run(async con =>
    {
        var actorRole = await ResolveRoleIdAsync(companyId, actor.ActiveRoleName);
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_SaveRoleGrants", new
        {
            Role_ID = r.TargetId, CompanyId = companyId, Branch_ID = r.BranchId, Json = ChangesJson(r.Changes),
            r.ExpectedVersion, r.Confirmed, ChangedBy = actor.UserId, ActorBranchId = actor.BranchId, ActorRoleId = actorRole, GuardPageCode = guardPageCode
        }, commandType: CommandType.StoredProcedure, commandTimeout: 120);
        return await ReadSaveResult(multi);
    });

    public Task CopyRoleGrantsAsync(int companyId, int fromRoleId, int toRoleId, PermissionSubject actor, string guardPageCode) => Run(async con =>
    {
        var actorRole = await ResolveRoleIdAsync(companyId, actor.ActiveRoleName);
        var users = (await con.QueryAsync<int>("dbo.usp_Auth_Admin_CopyRoleGrants", new
        {
            FromRole_ID = fromRoleId, ToRole_ID = toRoleId, CompanyId = companyId, ChangedBy = actor.UserId,
            ActorBranchId = actor.BranchId, ActorRoleId = actorRole, GuardPageCode = guardPageCode
        }, commandType: CommandType.StoredProcedure, commandTimeout: 120)).ToList();
        foreach (var u in users) permissions.InvalidateUser(u);
        return 0;
    });

    // ── User Permissions ──────────────────────────────────────────────────
    public async Task<UserGrantsBundle> GetUserGrantsAsync(int companyId, int userId, int? branchId)
    {
        var bundle = new UserGrantsBundle();
        using (var con = db.CreateConnection())
        using (var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_GetUserGrants",
                   new { User_ID = userId, CompanyId = companyId, Branch_ID = branchId }, commandType: CommandType.StoredProcedure))
        {
            bundle.Grants = (await multi.ReadAsync<GrantRow>()).ToList();
            bundle.Version = await multi.ReadFirstAsync<int>();
            bundle.Branches = (await multi.ReadAsync<(int BranchId, string BranchName)>()).Select(b => new LookupItem { Id = b.BranchId, Name = b.BranchName }).ToList();
            bundle.Roles = (await multi.ReadAsync<UserRoleRow>()).ToList();
            bundle.User = await multi.ReadFirstOrDefaultAsync<UserGrantsHeader>();
        }
        // "From role" for an all-branches override is shown against the user's first branch.
        var evalBranch = branchId ?? bundle.Branches.FirstOrDefault()?.Id ?? 0;
        bundle.FromRole = await GetEffectiveAsync(companyId, userId, evalBranch, null, ignoreUserRows: true);
        return bundle;
    }

    public Task<SaveGrantsResult> SaveUserGrantsAsync(int companyId, SaveGrantsRequest r, PermissionSubject actor, string guardPageCode) => Run(async con =>
    {
        var actorRole = await ResolveRoleIdAsync(companyId, actor.ActiveRoleName);
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_SaveUserGrants", new
        {
            User_ID = r.TargetId, CompanyId = companyId, Branch_ID = r.BranchId, Json = ChangesJson(r.Changes),
            r.ExpectedVersion, r.Confirmed, ChangedBy = actor.UserId, ActorBranchId = actor.BranchId, ActorRoleId = actorRole, GuardPageCode = guardPageCode
        }, commandType: CommandType.StoredProcedure, commandTimeout: 120);
        return await ReadSaveResult(multi);
    });

    // ── Viewer ────────────────────────────────────────────────────────────
    public async Task<List<EffectivePermissionRow>> GetEffectiveAsync(int companyId, int userId, int branchId, int? roleId, bool ignoreUserRows)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<EffectivePermissionRow>("dbo.usp_Auth_GetEffectivePermissions",
            new { UserId = userId, BranchId = branchId, CompanyId = companyId, RoleId = roleId, IgnoreUserRows = ignoreUserRows },
            commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<(List<ExplainRow> Rows, List<ExplainLevel> Levels)> ExplainAsync(int userId, int branchId, int? roleId, int pageId, int? controlId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Auth_Admin_Explain",
            new { UserId = userId, BranchId = branchId, RoleId = roleId, Page_ID = pageId, Control_ID = controlId }, commandType: CommandType.StoredProcedure);
        return ((await multi.ReadAsync<ExplainRow>()).ToList(), (await multi.ReadAsync<ExplainLevel>()).ToList());
    }

    public async Task<List<HistoryRow>> GetHistoryAsync(string entity, int targetId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<HistoryRow>("dbo.usp_Auth_Admin_GetHistory", new { Entity = entity, Target_ID = targetId },
            commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<List<DecisionLogRow>> GetDecisionLogAsync(DateTime? from, int? userId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<DecisionLogRow>("dbo.usp_Auth_DecisionLog_Recent", new { FromDate = from, UserId = userId },
            commandType: CommandType.StoredProcedure)).ToList();
    }

    // ── Lookups ───────────────────────────────────────────────────────────
    public async Task<List<LookupItem>> GetRolesAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<LookupItem>(
            "SELECT r.Id, r.Name, CAST((SELECT COUNT(DISTINCT ur.UserId) FROM dbo.Userroles ur WHERE ur.RoleId = r.Id AND ur.IsActive = 1) AS NVARCHAR(10)) AS Extra " +
            "FROM dbo.roles r WHERE r.CompanyId = @CompanyId OR r.CompanyId IS NULL ORDER BY r.Name", new { CompanyId = companyId })).ToList();
    }

    public async Task<List<LookupItem>> GetUsersAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<LookupItem>(
            "SELECT u.Id, ISNULL(NULLIF(u.FullName, ''), u.Username) + ' (' + u.Username + ')' AS Name, " +
            "CASE WHEN u.IsSuperAdmin = 1 THEN 'SUPERADMIN' WHEN u.IsActive = 0 THEN 'INACTIVE' ELSE NULL END AS Extra " +
            "FROM dbo.Users u WHERE ISNULL(u.CompanyId, @CompanyId) = @CompanyId ORDER BY u.IsActive DESC, Name", new { CompanyId = companyId })).ToList();
    }

    public async Task<List<LookupItem>> GetBranchesAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<LookupItem>(
            "SELECT BranchID AS Id, BranchName AS Name, BranchCode AS Extra FROM dbo.Branchmaster WHERE IsActive = 1 AND ISNULL(CompanyId, @CompanyId) = @CompanyId ORDER BY BranchName",
            new { CompanyId = companyId })).ToList();
    }

    public async Task<List<LookupItem>> GetSuperAdminsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<LookupItem>(
            "SELECT Id, ISNULL(NULLIF(FullName, ''), Username) + ' (' + Username + ')' AS Name, CASE WHEN IsActive = 1 THEN 'Active' ELSE 'Inactive' END AS Extra " +
            "FROM dbo.Users WHERE IsSuperAdmin = 1 AND ISNULL(CompanyId, @CompanyId) = @CompanyId ORDER BY Username", new { CompanyId = companyId })).ToList();
    }

    public async Task<int?> ResolveRoleIdAsync(int companyId, string? roleName)
    {
        if (string.IsNullOrWhiteSpace(roleName)) return null;
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<int?>(
            "SELECT TOP 1 Id FROM dbo.roles WHERE Name = @Name AND (CompanyId = @CompanyId OR CompanyId IS NULL)", new { Name = roleName.Trim(), CompanyId = companyId });
    }

    // ── helpers ───────────────────────────────────────────────────────────
    private void AfterTreeChange()
    {
        permissions.InvalidateNavigation();
        permissions.InvalidateEndpointMap();
    }

    private static string ChangesJson(IEnumerable<GrantChange> changes)
        => JsonSerializer.Serialize(changes.Select(c => new { m = c.M, p = c.P, c = c.C, v = (c.V ?? string.Empty).ToUpperInvariant(), r = c.R }));

    private async Task<SaveGrantsResult> ReadSaveResult(SqlMapper.GridReader multi)
    {
        var result = await multi.ReadFirstAsync<SaveGrantsResult>();
        if (result.Status == "OK" && !multi.IsConsumed)
        {
            result.AffectedUserIds = (await multi.ReadAsync<int>()).ToList();
            foreach (var u in result.AffectedUserIds) permissions.InvalidateUser(u);
        }
        return result;
    }

    /// <summary>Runs a write and turns the procedures' refusals into a message the screen can show.</summary>
    private async Task<T> Run<T>(Func<IDbConnection, Task<T>> work)
    {
        try
        {
            using var con = db.CreateConnection();
            return await work(con);
        }
        catch (SqlException ex) when (ex.Number is 50000 or 50001 or 50002)
        {
            var msg = ex.Errors.Count > 0 ? ex.Errors[0].Message : ex.Message;
            var pipe = msg.IndexOf('|');
            if (pipe > 0 && msg[..pipe].All(ch => char.IsUpper(ch) || ch == '_'))
                throw new PermissionAdminException(msg[(pipe + 1)..], msg[..pipe]);
            throw new PermissionAdminException(msg);
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new PermissionAdminException("That already exists. Refresh and try again.", "DUPLICATE");
        }
    }
}
