using System.Text;
using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Security: Menu & Page Master, Role Permissions, User Permissions, Effective Permissions.
/// Enforced whatever the global authorization mode: these screens decide everyone else's access, so they
/// are never open to everyone - only to Super Admin and whoever is granted these pages.
/// Every action names its page and control in code; the endpoint scanner maps them from here.
/// </summary>
[Authorize]
[AlwaysEnforce]
public class SecurityController(
    IPermissionAdminService admin,
    IPermissionService permissions,
    IAuditLogService auditLogService,
    IOptionsMonitor<EmrAuthorizationOptions> authzOptions) : Controller
{
    private const string MenuPagesPage = "SETTINGS.SECURITY.MENUPAGES";
    private const string RolePage = "SETTINGS.SECURITY.ROLEPERMISSIONS";
    private const string UserPage = "SETTINGS.SECURITY.USERPERMISSIONS";
    private const string ViewerPage = "SETTINGS.SECURITY.EFFECTIVEPERMISSIONS";

    private int CompanyId => User.GetCompanyId();
    private int UserId => User.GetUserId();
    private PermissionSubject Actor => PermissionSubjectReader.FromPrincipal(User)!;

    // ════════════════════════════ Screen 1 · Menu & Page Master ════════════════════════════
    [HttpGet, RequiresPermission(MenuPagesPage)]
    public async Task<IActionResult> MenuPages() => View(await Shell("MenuPages", MenuPagesPage, PermissionControls.Edit));

    [HttpGet, RequiresPermission(MenuPagesPage)]
    public async Task<IActionResult> GetTreeJson()
    {
        var tree = await admin.GetTreeAsync(CompanyId);
        var (_, stats) = await admin.GetEndpointsAsync("PAGE", 0);
        return Json(new { success = true, tree, stats });
    }

    [HttpGet, RequiresPermission(MenuPagesPage)]
    public async Task<IActionResult> GetEndpointsJson(string filter = "UNMAPPED", int? pageId = null)
    {
        filter = filter?.ToUpperInvariant() is "ORPHANED" or "PAGE" or "ALL" ? filter.ToUpperInvariant() : "UNMAPPED";
        var (rows, stats) = await admin.GetEndpointsAsync(filter, pageId);
        return Json(new { success = true, rows, stats });
    }

    [HttpGet, RequiresPermission(MenuPagesPage)]
    public async Task<IActionResult> GetProposalsJson()
        => Json(new { success = true, proposals = await admin.ProposeMappingsAsync(CompanyId) });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SaveMenuJson([FromBody] AdminMenuRow menu) => Write(async () =>
    {
        var id = await admin.SaveMenuAsync(CompanyId, menu, UserId);
        await Audit("SEC.MenuSaved", $"Menu item '{menu.Title}' ({menu.Menu_Code}) {(menu.Menu_ID > 0 ? "updated" : "created")}.", new { id, menu.Menu_Code, menu.Parent_Menu_ID });
        return new { id };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SetMenuActiveJson(int id, bool isActive) => Write(async () =>
    {
        await admin.SetMenuActiveAsync(CompanyId, id, isActive, UserId);
        await Audit("SEC.MenuStatus", $"Menu item #{id} {(isActive ? "activated" : "deactivated")}.", new { id, isActive });
        return new { };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SavePageJson([FromBody] SavePageRequest req) => Write(async () =>
    {
        var id = await admin.SavePageAsync(CompanyId, req.Page, req.ConfirmCodeChange, UserId);
        await Audit("SEC.PageSaved", $"Page '{req.Page.Title}' ({req.Page.Page_Code}) {(req.Page.Page_ID > 0 ? "updated" : "created")}.", new { id, req.Page.Page_Code, req.Page.Controller, req.Page.Action });
        return new { id };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SetPageActiveJson(int id, bool isActive) => Write(async () =>
    {
        await admin.SetPageActiveAsync(CompanyId, id, isActive, UserId);
        await Audit("SEC.PageStatus", $"Page #{id} {(isActive ? "activated" : "deactivated")}.", new { id, isActive });
        return new { };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SaveControlJson(int pageId, int? controlId, string controlCode, string? title) => Write(async () =>
    {
        var id = await admin.SaveControlAsync(CompanyId, pageId, controlId, controlCode, title, UserId);
        await Audit("SEC.ControlSaved", $"Control {controlCode} saved on page #{pageId}.", new { id, pageId, controlCode });
        return new { id };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> SetControlActiveJson(int id, bool isActive) => Write(async () =>
    {
        await admin.SetControlActiveAsync(CompanyId, id, isActive, UserId);
        await Audit("SEC.ControlStatus", $"Control #{id} {(isActive ? "activated" : "deactivated")}.", new { id, isActive });
        return new { };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> MapEndpointsJson([FromBody] List<EndpointMappingRequest> mappings) => Write(async () =>
    {
        if (mappings is not { Count: > 0 }) throw new PermissionAdminException("Choose at least one endpoint to map.");
        var n = await admin.MapEndpointsAsync(CompanyId, mappings.Select(m => (m.EndpointId, m.PageId, m.ControlCode ?? PermissionControls.View)), UserId);
        await Audit("SEC.EndpointsMapped", $"{n} endpoint mapping(s) saved.", new { count = n, mappings = mappings.Take(50) });
        return new { mapped = n };
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(MenuPagesPage, PermissionControls.Edit)]
    public Task<IActionResult> UnmapEndpointJson(int endpointId) => Write(async () =>
    {
        await admin.UnmapEndpointAsync(CompanyId, endpointId);
        await Audit("SEC.EndpointUnmapped", $"Endpoint mapping #{endpointId} removed.", new { endpointId });
        return new { };
    });

    // ════════════════════════════ Screen 2 · Role Permissions ════════════════════════════
    [HttpGet, RequiresPermission(RolePage)]
    public async Task<IActionResult> RolePermissions(int? role) => View(await Shell("RolePermissions", RolePage, PermissionControls.Edit, role));

    [HttpGet, RequiresPermission(RolePage)]
    public async Task<IActionResult> GetRoleGrantsJson(int roleId, int? branchId)
    {
        var (grants, meta) = await admin.GetRoleGrantsAsync(CompanyId, roleId, branchId);
        var tree = await admin.GetTreeAsync(CompanyId);
        return Json(new { success = true, grants, meta, tree });
    }

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(RolePage, PermissionControls.Edit)]
    public Task<IActionResult> SaveRoleGrantsJson([FromBody] SaveGrantsRequest req) => Write(async () =>
    {
        var result = await admin.SaveRoleGrantsAsync(CompanyId, req, Actor, RolePage);
        if (result.Status == "OK")
            await Audit("SEC.RolePermissionsSaved", $"Role #{req.TargetId}: {result.Changes} permission change(s) saved, affecting {result.AffectedUsers} user(s).",
                new { roleId = req.TargetId, req.BranchId, result.Changes, result.AffectedUsers });
        return result;
    });

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(RolePage, PermissionControls.Edit)]
    public Task<IActionResult> CopyRoleGrantsJson(int fromRoleId, int toRoleId) => Write(async () =>
    {
        await admin.CopyRoleGrantsAsync(CompanyId, fromRoleId, toRoleId, Actor, RolePage);
        await Audit("SEC.RolePermissionsCopied", $"Permissions of role #{fromRoleId} copied onto role #{toRoleId}.", new { fromRoleId, toRoleId });
        return new { };
    });

    [HttpGet, RequiresPermission(RolePage)]
    public async Task<IActionResult> GetRoleHistoryJson(int roleId) => Json(new { success = true, rows = await admin.GetHistoryAsync("ROLE", roleId) });

    // ════════════════════════════ Screen 3 · User Permissions ════════════════════════════
    [HttpGet, RequiresPermission(UserPage)]
    public async Task<IActionResult> UserPermissions(int? user, int? branch)
    {
        var shell = await Shell("UserPermissions", UserPage, PermissionControls.Edit, user);
        shell.PreselectBranchId = branch;
        return View(shell);
    }

    [HttpGet, RequiresPermission(UserPage)]
    public async Task<IActionResult> GetUserGrantsJson(int userId, int? branchId)
    {
        var bundle = await admin.GetUserGrantsAsync(CompanyId, userId, branchId);
        if (bundle.User is null) return Json(new { success = false, message = "User not found." });
        var tree = await admin.GetTreeAsync(CompanyId);
        return Json(new { success = true, bundle, tree });
    }

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(UserPage, PermissionControls.Edit)]
    public Task<IActionResult> SaveUserGrantsJson([FromBody] SaveGrantsRequest req) => Write(async () =>
    {
        var result = await admin.SaveUserGrantsAsync(CompanyId, req, Actor, UserPage);
        if (result.Status == "OK")
            await Audit("SEC.UserPermissionsSaved", $"User #{req.TargetId}: {result.Changes} permission override(s) saved.",
                new { userId = req.TargetId, req.BranchId, result.Changes });
        return result;
    });

    [HttpGet, RequiresPermission(UserPage)]
    public async Task<IActionResult> GetUserHistoryJson(int userId) => Json(new { success = true, rows = await admin.GetHistoryAsync("USER", userId) });

    // ════════════════════════════ Screen 4 · Effective Permissions ════════════════════════════
    [HttpGet, RequiresPermission(ViewerPage)]
    public async Task<IActionResult> EffectivePermissions(int? user, int? branch)
    {
        var shell = await Shell("EffectivePermissions", ViewerPage, PermissionControls.Export, user);
        shell.PreselectBranchId = branch;
        return View(shell);
    }

    [HttpGet, RequiresPermission(ViewerPage)]
    public async Task<IActionResult> GetEffectiveJson(int userId, int branchId, int? roleId)
    {
        var rows = await admin.GetEffectiveAsync(CompanyId, userId, branchId, roleId, ignoreUserRows: false);
        var bundle = await admin.GetUserGrantsAsync(CompanyId, userId, branchId);
        var tree = await admin.GetTreeAsync(CompanyId);
        return Json(new { success = true, rows, user = bundle.User, roles = bundle.Roles, branches = bundle.Branches, tree });
    }

    [HttpGet, RequiresPermission(ViewerPage)]
    public async Task<IActionResult> ExplainJson(int userId, int branchId, int? roleId, int pageId, int? controlId)
    {
        var (rows, levels) = await admin.ExplainAsync(userId, branchId, roleId, pageId, controlId);
        return Json(new { success = true, rows, levels });
    }

    [HttpGet, RequiresPermission(ViewerPage)]
    public async Task<IActionResult> GetDecisionLogJson(int days = 7, int? userId = null)
        => Json(new { success = true, rows = await admin.GetDecisionLogAsync(DateTime.Now.AddDays(-Math.Clamp(days, 1, 90)), userId) });

    [HttpGet, RequiresPermission(ViewerPage)]
    public async Task<IActionResult> GetSuperAdminsJson() => Json(new { success = true, rows = await admin.GetSuperAdminsAsync(CompanyId) });

    [HttpGet, RequiresPermission(ViewerPage, PermissionControls.Export)]
    public async Task<IActionResult> ExportEffectiveCsv(int userId, int branchId, int? roleId)
    {
        var rows = await admin.GetEffectiveAsync(CompanyId, userId, branchId, roleId, ignoreUserRows: false);
        var tree = await admin.GetTreeAsync(CompanyId);
        var titles = tree.Pages.ToDictionary(p => p.Page_ID, p => p.Title);
        var sb = new StringBuilder("Page,Page Code,Control,Result,Decided At,Decided By\r\n");
        foreach (var r in rows)
            sb.Append(Csv(titles.GetValueOrDefault(r.Page_ID, r.Page_Code))).Append(',').Append(Csv(r.Page_Code)).Append(',')
              .Append(Csv(r.Control_Code)).Append(',').Append(r.Permission == "A" ? "Allow" : "Deny").Append(',')
              .Append(Csv(ScopeName(r.Decided_At_Scope))).Append(',').Append(Csv(r.Decided_By)).Append("\r\n");
        await Audit("SEC.EffectiveExported", $"Effective permissions of user #{userId} (branch #{branchId}) exported.", new { userId, branchId, roleId });
        return File(Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray(), "text/csv",
            $"EffectivePermissions_User{userId}_Branch{branchId}_{DateTime.Now:yyyyMMdd_HHmm}.csv");
    }

    // ════════════════════════════ helpers ════════════════════════════
    private async Task<SecurityPageViewModel> Shell(string screen, string pageCode, string actionControl, int? preselect = null)
    {
        var set = await permissions.GetPermissionSetAsync(Actor);
        var opts = authzOptions.CurrentValue;
        ViewData["Title"] = screen switch
        {
            "MenuPages" => "Menu & Page Master",
            "RolePermissions" => "Role Permissions",
            "UserPermissions" => "User Permissions",
            _ => "Effective Permissions"
        };
        return new SecurityPageViewModel
        {
            Screen = screen,
            Roles = await admin.GetRolesAsync(CompanyId),
            Users = await admin.GetUsersAsync(CompanyId),
            Branches = await admin.GetBranchesAsync(CompanyId),
            Mode = opts.Mode.ToString(),
            EnforceModules = opts.EnforceModules,
            CanEdit = set.Can(pageCode, actionControl == PermissionControls.Export ? PermissionControls.View : actionControl),
            CanExport = set.Can(pageCode, PermissionControls.Export),
            PreselectId = preselect
        };
    }

    private async Task<IActionResult> Write(Func<Task<object>> work)
    {
        try
        {
            var data = await work();
            return Json(new { success = true, data });
        }
        catch (PermissionAdminException ex)
        {
            return Json(new { success = false, code = ex.Code, message = ex.Message });
        }
    }

    private Task Audit(string action, string description, object metadata)
        => auditLogService.LogActivityAsync("Security", action, description, UserId, User.GetCurrentBranchId(), "SEC", metadata: metadata);

    internal static string ScopeName(int scope) => scope switch
    {
        5 => "Control",
        4 => "Page",
        3 => "Sub-menu",
        2 => "Menu",
        1 => "Nav bar item",
        99 => "Super admin",
        _ => "No row at any scope"
    };

    private static string Csv(string? v) => v is null ? "" : v.Contains(',') || v.Contains('"') ? "\"" + v.Replace("\"", "\"\"") + "\"" : v;
}

public sealed class SavePageRequest
{
    public AdminPageRow Page { get; set; } = new();
    public bool ConfirmCodeChange { get; set; }
}

public sealed class EndpointMappingRequest
{
    public int EndpointId { get; set; }
    public int PageId { get; set; }
    public string? ControlCode { get; set; }
}
