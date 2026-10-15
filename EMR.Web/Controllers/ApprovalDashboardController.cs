using System.Text.Json;
using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Approval Dashboard (SQLScripts/2277). Company-wise approvals are worked in the head-office branch,
/// branch-wise ones in their branch. A user sees the requests they can approve and the ones they submitted
/// (company admins see all of the branch, read-only unless also an approver). Approve applies the change;
/// Send Back returns it to the maker with a reason.
/// </summary>
[Authorize]
public class ApprovalDashboardController(
    IDbConnectionFactory db,
    ILabFranchiseApiClient franchiseApiClient,
    ICorporateApiClient corporateApiClient,
    ILabInvestigationProfileApiClient profileApiClient,
    ILoginCredentialsMailer credentialsMailer,
    IAuditLogService auditLogService,
    ILogger<ApprovalDashboardController> logger) : Controller
{
    private const string VisibleSql = @"
        r.CompanyId = @companyId AND r.Status <> 'X'
        AND ((r.Scope = 'C' AND @isHo = 1) OR (r.Scope = 'B' AND r.Branch_ID = @branchId))
        AND (@admin = 1 OR r.Requested_By = @userId
             OR EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = r.Matrix_ID AND a.UserId = @userId))";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        using var con = db.CreateConnection();
        ViewBag.Modules = (await con.QueryAsync<(string Code, string Name)>(
            "SELECT Module_Code, Module_Name FROM dbo.ApprovalModule WHERE IsActive = 1 ORDER BY Sort_Order")).ToList();
        ViewBag.IsHo = await IsHoAsync(con);
        ViewBag.BranchName = await con.ExecuteScalarAsync<string?>(
            "SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @branchId", new { branchId = User.GetCurrentBranchId() ?? 0 });
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Data(string? status, string? module, DateTime? fromDate, DateTime? toDate)
    {
        using var con = db.CreateConnection();
        var p = await ScopeAsync(con);
        p.Add("module", string.IsNullOrWhiteSpace(module) ? null : module);
        p.Add("fromDate", fromDate?.Date);
        p.Add("toDate", toDate?.Date.AddDays(1));

        var rows = (await con.QueryAsync<RequestRow>($@"
            SELECT r.Request_ID, r.Module_Code, am.Module_Name, r.Entity_ID, r.Entity_Name, r.Action_Type, r.Status, r.Scope,
                   b.BranchName, r.Requested_Date, r.Actioned_Date, r.Remarks, r.Requested_By,
                   COALESCE(NULLIF(rb.FullName, ''), rb.Username) AS Requested_By_Name,
                   COALESCE(NULLIF(ab.FullName, ''), ab.Username) AS Actioned_By_Name,
                   CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = r.Matrix_ID AND a.UserId = @userId)
                             THEN 1 ELSE 0 END AS BIT) AS IsApprover
              FROM dbo.ApprovalRequest r
              JOIN dbo.ApprovalModule am ON am.Module_Code = r.Module_Code
              LEFT JOIN dbo.Branchmaster b ON b.BranchID = r.Branch_ID
              LEFT JOIN dbo.Users rb ON rb.Id = r.Requested_By
              LEFT JOIN dbo.Users ab ON ab.Id = r.Actioned_By
             WHERE {VisibleSql}
               AND (@module IS NULL OR r.Module_Code = @module)
               AND (@fromDate IS NULL OR r.Requested_Date >= @fromDate)
               AND (@toDate IS NULL OR r.Requested_Date < @toDate)
             ORDER BY CASE r.Status WHEN 'P' THEN 0 ELSE 1 END, r.Request_ID DESC", p)).ToList();

        var summary = new
        {
            total = rows.Count,
            pending = rows.Count(r => r.Status == "P"),
            approved = rows.Count(r => r.Status == "A"),
            sentBack = rows.Count(r => r.Status == "S")
        };
        var list = string.IsNullOrWhiteSpace(status) ? rows : rows.Where(r => r.Status == status).ToList();
        return Json(new { success = true, summary, rows = list }, AsDeclared);
    }

    [HttpGet]
    public async Task<IActionResult> Detail(int id)
    {
        using var con = db.CreateConnection();
        var r = await LoadAsync(con, id);
        if (r is null) return Json(new { success = false, message = "This request is not on your dashboard." });

        var approvers = await con.QueryAsync<string>(
            @"SELECT COALESCE(NULLIF(u.FullName, ''), u.Username) FROM dbo.ApprovalMatrixApprover a JOIN dbo.Users u ON u.Id = a.UserId
               WHERE a.Matrix_ID = @Matrix_ID ORDER BY 1", new { r.Matrix_ID });
        var history = await con.QueryAsync(
            @"SELECT h.Request_ID, h.Status, h.Remarks, h.Requested_Date, h.Actioned_Date,
                     COALESCE(NULLIF(rb.FullName, ''), rb.Username) AS Requested_By_Name,
                     COALESCE(NULLIF(ab.FullName, ''), ab.Username) AS Actioned_By_Name
                FROM dbo.ApprovalRequest h
                LEFT JOIN dbo.Users rb ON rb.Id = h.Requested_By
                LEFT JOIN dbo.Users ab ON ab.Id = h.Actioned_By
               WHERE h.Module_Code = @Module_Code AND h.Entity_ID = @Entity_ID AND h.Request_ID <> @Request_ID
               ORDER BY h.Request_ID DESC", new { r.Module_Code, r.Entity_ID, r.Request_ID });

        var oldValues = Parse(r.Old_Values);
        var newValues = Parse(r.New_Values) ?? [];
        var fields = newValues.Select((f, i) =>
        {
            var old = oldValues?.FirstOrDefault(o => o.Field == f.Field)?.Value;
            return new { field = f.Field, oldValue = oldValues is null ? null : old, newValue = f.Value, changed = oldValues is not null && old != f.Value };
        }).ToList();

        var (canAct, why) = await CanActAsync(con, r);
        return Json(new
        {
            success = true,
            request = new
            {
                r.Request_ID, r.Module_Name, r.Entity_Name, r.Action_Type, r.Status, r.Remarks, r.BranchName, r.Scope,
                r.Requested_By_Name, r.Requested_Date, r.Actioned_By_Name, r.Actioned_Date
            },
            fields,
            changedCount = fields.Count(f => f.changed),
            approvers,
            history,
            canAct,
            cannotActReason = why
        }, AsDeclared);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks)
    {
        using var con = db.CreateConnection();
        var r = await LoadAsync(con, id);
        if (r is null) return Fail("This request is not on your dashboard.");
        var (canAct, why) = await CanActAsync(con, r);
        if (!canAct) return Fail(why!);

        // claim it first, so two approvers cannot apply the same change
        var claimed = await con.ExecuteAsync(
            @"UPDATE dbo.ApprovalRequest SET Status = 'A', Actioned_By = @userId, Actioned_Date = GETDATE(), Remarks = @remarks
               WHERE Request_ID = @id AND Status = 'P'",
            new { id, userId = User.GetUserId(), remarks = Trim(remarks) });
        if (claimed == 0) return Fail("This request was already acted on. Reload the dashboard.");

        string? note;
        try
        {
            note = r.Action_Type == "CREATE" ? await ActivateAsync(con, r) : await ApplyChangeAsync(r);
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException or JsonException)
        {
            await con.ExecuteAsync(
                "UPDATE dbo.ApprovalRequest SET Status = 'P', Actioned_By = NULL, Actioned_Date = NULL, Remarks = NULL WHERE Request_ID = @id", new { id });
            logger.LogWarning(ex, "Approval request {Id} could not be applied", id);
            return Fail("The change could not be applied: " + (ex is HttpRequestException ? "the service is not reachable." : ex.Message));
        }

        await auditLogService.LogAsync("Approval Dashboard", "Approve",
            $"Approved {r.Action_Type.ToLower()} of {r.Module_Name} '{r.Entity_Name}' #{r.Entity_ID} [Request #{id}]",
            User.GetUserId(), User.GetCurrentBranchId() ?? 1);
        return Json(new { success = true, message = "Approved. " + (note ?? "The change is now in effect.") });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendBack(int id, string? reason)
    {
        reason = Trim(reason);
        if (reason is null || reason.Length < 5) return Fail("Give the reason for sending it back (at least 5 characters).");

        using var con = db.CreateConnection();
        var r = await LoadAsync(con, id);
        if (r is null) return Fail("This request is not on your dashboard.");
        var (canAct, why) = await CanActAsync(con, r);
        if (!canAct) return Fail(why!);

        var done = await con.ExecuteAsync(
            @"UPDATE dbo.ApprovalRequest SET Status = 'S', Actioned_By = @userId, Actioned_Date = GETDATE(), Remarks = @reason
               WHERE Request_ID = @id AND Status = 'P'",
            new { id, userId = User.GetUserId(), reason });
        if (done == 0) return Fail("This request was already acted on. Reload the dashboard.");

        await auditLogService.LogAsync("Approval Dashboard", "SendBack",
            $"Sent back {r.Action_Type.ToLower()} of {r.Module_Name} '{r.Entity_Name}' #{r.Entity_ID} [Request #{id}]: {reason}",
            User.GetUserId(), User.GetCurrentBranchId() ?? 1);
        return Json(new
        {
            success = true,
            message = r.Action_Type == "CREATE"
                ? "Sent back. The record stays inactive; the maker sees your reason when opening it, and can correct and resubmit it."
                : "Sent back. The record keeps its current details; the maker sees your reason when opening it."
        });
    }

    // ── applying an approval ─────────────────────────────────────────────────────────────────────────

    /// <summary>A new record: switched on as the maker asked, and its login (franchise / corporate) enabled and mailed.</summary>
    private async Task<string?> ActivateAsync(System.Data.IDbConnection con, RequestRow r)
    {
        var active = r.Requested_Active ?? true;
        var userId = User.GetUserId();
        int rows;
        string? loginType = null;
        int? loginBranch = null;

        switch (r.Module_Code)
        {
            case ApprovalModules.Franchise:
                rows = await con.ExecuteAsync(
                    "UPDATE dbo.LabFranchiseMaster SET IsActive = @active, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE Franchise_ID = @id AND IsDeleted = 0",
                    new { active, userId, id = r.Entity_ID });
                loginType = "F";
                loginBranch = await con.ExecuteScalarAsync<int?>("SELECT Parent_Branch_ID FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @id", new { id = r.Entity_ID });
                break;
            case ApprovalModules.Corporate:
                rows = await con.ExecuteAsync(
                    "UPDATE dbo.CorporateMaster SET Status = @active, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE Corporate_ID = @id",
                    new { active, userId, id = r.Entity_ID });
                loginType = "C";
                loginBranch = await con.ExecuteScalarAsync<int?>("SELECT Branch_ID FROM dbo.CorporateMaster WHERE Corporate_ID = @id", new { id = r.Entity_ID });
                break;
            case ApprovalModules.Package:
                rows = await con.ExecuteAsync(
                    "UPDATE dbo.LabInvestigationProfileHeader SET Status = @active, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE Profile_ID = @id AND IsDeleted = 0",
                    new { active, userId, id = r.Entity_ID });
                break;
            default:
                throw new InvalidOperationException("Unknown module " + r.Module_Code);
        }
        if (rows == 0) throw new InvalidOperationException("the record no longer exists.");
        if (loginType is null) return active ? "It is now available." : "It was approved as inactive, as saved.";

        // the login made disabled when the record was saved
        var l = await con.QueryFirstOrDefaultAsync<LoginRow>(
            "SELECT TOP 1 Id, Username, FullName FROM dbo.Users WHERE User_Type = @loginType AND ReferenceUserID = @id AND IsActive = 0",
            new { loginType, id = r.Entity_ID });
        if (l is null) return "It is now available.";

        await con.ExecuteAsync("UPDATE dbo.Users SET IsActive = 1, LastModifiedDate = GETDATE() WHERE Id = @Id", new { l.Id });
        var (sent, reason) = await credentialsMailer.SendAsync(loginBranch ?? User.GetCurrentBranchId() ?? 1, User.GetCurrentBranchId(),
            l.FullName ?? r.Entity_Name ?? l.Username, l.Username, LoginCredentialsMailer.DefaultPassword, $"{Request.Scheme}://{Request.Host}");
        return sent
            ? $"It is now available, and its login {l.Username} is enabled and its details were emailed."
            : $"It is now available and its login {l.Username} is enabled, but the login details could not be emailed ({reason}). Please share them.";
    }

    /// <summary>A change to an approved record: the save the maker made is applied now.</summary>
    private async Task<string?> ApplyChangeAsync(RequestRow r)
    {
        if (string.IsNullOrWhiteSpace(r.Payload)) throw new InvalidOperationException("the submitted change was not stored.");
        switch (r.Module_Code)
        {
            case ApprovalModules.Franchise:
                var franchise = JsonSerializer.Deserialize<LabFranchiseUpdateRequestModel>(r.Payload)!;
                franchise.Franchise_ID = r.Entity_ID;
                franchise.UserId = r.Requested_By;
                await franchiseApiClient.UpdateAsync(franchise);
                break;
            case ApprovalModules.Corporate:
                var corporate = JsonSerializer.Deserialize<CorporateFormViewModel>(r.Payload)!;
                corporate.Corporate_ID = r.Entity_ID;
                await corporateApiClient.UpdateAsync(r.Entity_ID, corporate, r.Requested_By);
                break;
            case ApprovalModules.Package:
                var profile = JsonSerializer.Deserialize<LabInvestigationProfileSaveRequestModel>(r.Payload)!;
                profile.Profile_ID = r.Entity_ID;
                profile.UserId = r.Requested_By;
                await profileApiClient.SaveAsync(profile);
                break;
            default:
                throw new InvalidOperationException("Unknown module " + r.Module_Code);
        }
        return null;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────

    private async Task<bool> IsHoAsync(System.Data.IDbConnection con) =>
        await con.ExecuteScalarAsync<bool?>("SELECT IsHOBranch FROM dbo.Branchmaster WHERE BranchID = @branchId",
            new { branchId = User.GetCurrentBranchId() ?? 0 }) ?? false;

    private async Task<DynamicParameters> ScopeAsync(System.Data.IDbConnection con)
    {
        var p = new DynamicParameters();
        p.Add("companyId", User.GetCompanyId());
        p.Add("branchId", User.GetCurrentBranchId() ?? 0);
        p.Add("userId", User.GetUserId());
        p.Add("isHo", await IsHoAsync(con) ? 1 : 0);
        p.Add("admin", User.IsCompanyAdmin() ? 1 : 0);
        return p;
    }

    private async Task<RequestRow?> LoadAsync(System.Data.IDbConnection con, int id)
    {
        var p = await ScopeAsync(con);
        p.Add("id", id);
        return await con.QueryFirstOrDefaultAsync<RequestRow>($@"
            SELECT r.*, am.Module_Name, b.BranchName,
                   COALESCE(NULLIF(rb.FullName, ''), rb.Username) AS Requested_By_Name,
                   COALESCE(NULLIF(ab.FullName, ''), ab.Username) AS Actioned_By_Name
              FROM dbo.ApprovalRequest r
              JOIN dbo.ApprovalModule am ON am.Module_Code = r.Module_Code
              LEFT JOIN dbo.Branchmaster b ON b.BranchID = r.Branch_ID
              LEFT JOIN dbo.Users rb ON rb.Id = r.Requested_By
              LEFT JOIN dbo.Users ab ON ab.Id = r.Actioned_By
             WHERE r.Request_ID = @id AND {VisibleSql}", p);
    }

    /// <summary>Only a pending request, by an approver named for it who is still an active Manager (of the branch,
    /// for branch-wise), and never by the user who submitted it.</summary>
    private async Task<(bool, string?)> CanActAsync(System.Data.IDbConnection con, RequestRow r)
    {
        if (r.Status != "P") return (false, "This request has already been acted on.");
        var userId = User.GetUserId();
        var named = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM dbo.ApprovalMatrixApprover WHERE Matrix_ID = @Matrix_ID AND UserId = @userId", new { r.Matrix_ID, userId });
        if (named == 0) return (false, "You are not an approver for this request.");
        if (r.Requested_By == userId) return (false, "You submitted this request, so another approver must act on it.");

        var branchId = r.Scope == "B" ? r.Branch_ID : (int?)null;
        var eligible = await con.ExecuteScalarAsync<int>(
            $"SELECT COUNT(*) FROM ({ApprovalMatrixController.EligibleApproversSql}) e WHERE e.Id = @userId",
            new { companyId = User.GetCompanyId(), branchId, userId });
        return eligible == 0
            ? (false, "Only an active system user with a Manager role" + (branchId is null ? "" : " in this branch") + " can approve.")
            : (true, null);
    }

    private static List<ApprovalField>? Parse(string? json) =>
        string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<List<ApprovalField>>(json);

    private static string? Trim(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim()[..Math.Min(s.Trim().Length, 500)];

    private JsonResult Fail(string message) => Json(new { success = false, message });

    /// <summary>Field names as declared (Request_ID, Module_Name ...), not camel-cased.</summary>
    private static readonly JsonSerializerOptions AsDeclared = new(JsonSerializerDefaults.Web) { PropertyNamingPolicy = null };

    private sealed class LoginRow
    {
        public int Id { get; set; }
        public string Username { get; set; } = "";
        public string? FullName { get; set; }
    }

    public class RequestRow
    {
        public int Request_ID { get; set; }
        public int CompanyId { get; set; }
        public int Branch_ID { get; set; }
        public int Matrix_ID { get; set; }
        public string Scope { get; set; } = "C";
        public string Module_Code { get; set; } = "";
        public string? Module_Name { get; set; }
        public int Entity_ID { get; set; }
        public string? Entity_Name { get; set; }
        public string Action_Type { get; set; } = "";
        public bool? Requested_Active { get; set; }
        public string? Old_Values { get; set; }
        public string? New_Values { get; set; }
        public string? Payload { get; set; }
        public string Status { get; set; } = "";
        public int Requested_By { get; set; }
        public string? Requested_By_Name { get; set; }
        public DateTime Requested_Date { get; set; }
        public string? Actioned_By_Name { get; set; }
        public DateTime? Actioned_Date { get; set; }
        public string? Remarks { get; set; }
        public string? BranchName { get; set; }
        public bool IsApprover { get; set; }
    }
}
