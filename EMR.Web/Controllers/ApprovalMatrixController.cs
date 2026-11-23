using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Approval Matrix (SQLScripts/2277). Puts a master (Franchise Setup, Corporate Master, Investigation
/// Profile / Package) under approval, company-wise (approved in the head-office branch) or for one branch, and names
/// its approvers: active system users with a Manager role - never doctors, franchise or corporate logins. Branch-wise
/// approvers must also work in that branch.
/// </summary>
[Authorize]
public class ApprovalMatrixController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    /// <summary>Who may approve: shared with the Approval Dashboard, which checks it again when acting.</summary>
    internal const string EligibleApproversSql = @"
        SELECT u.Id, COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name, u.Username,
               STRING_AGG(r.Name, ', ') AS Roles
          FROM dbo.Users u
          JOIN dbo.UserRoles ur ON ur.UserId = u.Id AND ur.IsActive = 1
          JOIN dbo.Roles r      ON r.Id = ur.RoleId AND r.Name LIKE N'%Manager%'
         WHERE u.IsActive = 1 AND u.CompanyId = @companyId
           AND (@branchId IS NULL OR EXISTS (SELECT 1 FROM dbo.UserBranches ub
                                              WHERE ub.UserId = u.Id AND ub.BranchID = @branchId AND ub.IsActive = 1))
         GROUP BY u.Id, u.FullName, u.Username";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var companyId = User.GetCompanyId();
        using var con = db.CreateConnection();

        ViewBag.Modules = (await con.QueryAsync<(string Code, string Name)>(
            "SELECT Module_Code, Module_Name FROM dbo.ApprovalModule WHERE IsActive = 1 ORDER BY Sort_Order")).ToList();
        ViewBag.Branches = (await con.QueryAsync<(int Id, string Name, bool IsHO)>(
            @"SELECT BranchID, BranchName + ' (' + BranchCode + ')', ISNULL(IsHOBranch, 0)
                FROM dbo.Branchmaster WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY ISNULL(IsHOBranch, 0) DESC, BranchName",
            new { companyId })).ToList();

        var rows = (await con.QueryAsync<MatrixRow>(
            @"SELECT m.Matrix_ID, m.Module_Code, am.Module_Name, m.Scope, m.Branch_ID, b.BranchName,
                     ISNULL(m.ModifiedDate, m.CreatedDate) AS UpdatedOn,
                     (SELECT COUNT(*) FROM dbo.ApprovalRequest r WHERE r.Matrix_ID = m.Matrix_ID AND r.Status = 'P') AS PendingCount,
                     (SELECT STRING_AGG(CAST(a.UserId AS VARCHAR(12)), ',') FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = m.Matrix_ID) AS ApproverIds,
                     (SELECT STRING_AGG(COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username), ', ')
                        FROM dbo.ApprovalMatrixApprover a JOIN dbo.Users u ON u.Id = a.UserId WHERE a.Matrix_ID = m.Matrix_ID) AS ApproverNames
                FROM dbo.ApprovalMatrix m
                JOIN dbo.ApprovalModule am ON am.Module_Code = m.Module_Code
                LEFT JOIN dbo.Branchmaster b ON b.BranchID = m.Branch_ID
               WHERE m.CompanyId = @companyId AND m.IsActive = 1
               ORDER BY am.Sort_Order, m.Scope, b.BranchName",
            new { companyId })).ToList();

        return View(rows);
    }

    /// <summary>Managers who may be named for a company-wise matrix (no branch) or for one branch.</summary>
    [HttpGet]
    public async Task<IActionResult> Approvers(int? branchId)
    {
        using var con = db.CreateConnection();
        var users = await con.QueryAsync(EligibleApproversSql + " ORDER BY Name", new { companyId = User.GetCompanyId(), branchId });
        return Json(users);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(int? matrixId, string moduleCode, string scope, int? branchId, int[]? approverIds)
    {
        var companyId = User.GetCompanyId();
        var userId = User.GetUserId();
        approverIds = (approverIds ?? []).Distinct().ToArray();

        if (scope is not ("C" or "B")) return Fail("Choose company-wise or branch-wise approval.");
        if (scope == "C") branchId = null;
        else if (branchId is null or <= 0) return Fail("Choose the branch for a branch-wise approval.");
        if (approverIds.Length == 0) return Fail("Choose at least one approver.");

        using var con = db.CreateConnection();
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.ApprovalModule WHERE Module_Code = @moduleCode AND IsActive = 1", new { moduleCode }) == 0)
            return Fail("Choose a module.");
        if (branchId is not null && await con.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM dbo.Branchmaster WHERE BranchID = @branchId AND CompanyId = @companyId", new { branchId, companyId }) == 0)
            return Fail("That branch is not part of your company.");

        var eligible = (await con.QueryAsync<int>($"SELECT Id FROM ({EligibleApproversSql}) e", new { companyId, branchId })).ToHashSet();
        if (approverIds.Any(id => !eligible.Contains(id)))
            return Fail(scope == "B"
                ? "Approvers must be active system users with a Manager role who work in this branch."
                : "Approvers must be active system users with a Manager role.");

        con.Open();
        using var tx = con.BeginTransaction();

        // one active matrix per module and scope (and branch): saving the same combination edits it
        var existing = await con.ExecuteScalarAsync<int?>(
            @"SELECT Matrix_ID FROM dbo.ApprovalMatrix
               WHERE CompanyId = @companyId AND Module_Code = @moduleCode AND Scope = @scope AND IsActive = 1
                 AND ((@branchId IS NULL AND Branch_ID IS NULL) OR Branch_ID = @branchId)",
            new { companyId, moduleCode, scope, branchId }, tx);

        if (matrixId is > 0 && existing is not null && existing != matrixId)
            return Fail("This module already has an approval set up for that scope. Edit that one instead.");

        int id;
        if (existing is int found) id = found;
        else if (matrixId is int edit and > 0)
        {
            // the row being edited moves to the new module / scope / branch
            var moved = await con.ExecuteAsync(
                @"UPDATE dbo.ApprovalMatrix SET Module_Code = @moduleCode, Scope = @scope, Branch_ID = @branchId,
                         ModifiedBy = @userId, ModifiedDate = GETDATE()
                   WHERE Matrix_ID = @edit AND CompanyId = @companyId AND IsActive = 1",
                new { moduleCode, scope, branchId, userId, edit, companyId }, tx);
            if (moved == 0) return Fail("That approval set-up no longer exists. Reload the page.");
            id = edit;
        }
        else
        {
            id = await con.ExecuteScalarAsync<int>(
                @"INSERT dbo.ApprovalMatrix (CompanyId, Module_Code, Scope, Branch_ID, CreatedBy)
                  VALUES (@companyId, @moduleCode, @scope, @branchId, @userId);
                  SELECT CAST(SCOPE_IDENTITY() AS INT);",
                new { companyId, moduleCode, scope, branchId, userId }, tx);
        }

        await con.ExecuteAsync(
            "UPDATE dbo.ApprovalMatrix SET ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE Matrix_ID = @id; " +
            "DELETE dbo.ApprovalMatrixApprover WHERE Matrix_ID = @id;", new { id, userId }, tx);
        await con.ExecuteAsync(
            "INSERT dbo.ApprovalMatrixApprover (Matrix_ID, UserId, CreatedBy) VALUES (@id, @approver, @userId)",
            approverIds.Select(a => new { id, approver = a, userId }), tx);
        tx.Commit();

        await auditLogService.LogAsync("Approval Matrix", "Save",
            $"Approval for {moduleCode} ({(scope == "C" ? "company-wise" : $"branch #{branchId}")}) set with {approverIds.Length} approver(s) [Matrix #{id}]",
            userId, User.GetCurrentBranchId() ?? 1);

        return Json(new { success = true, message = "Approval set-up saved. New records and changes of this module now need approval." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Remove(int matrixId)
    {
        var companyId = User.GetCompanyId();
        using var con = db.CreateConnection();
        var done = await con.ExecuteAsync(
            @"UPDATE dbo.ApprovalMatrix SET IsActive = 0, ModifiedBy = @userId, ModifiedDate = GETDATE()
               WHERE Matrix_ID = @matrixId AND CompanyId = @companyId AND IsActive = 1",
            new { matrixId, companyId, userId = User.GetUserId() });
        if (done == 0) return Fail("That approval set-up no longer exists. Reload the page.");

        await auditLogService.LogAsync("Approval Matrix", "Remove", $"Approval set-up #{matrixId} removed",
            User.GetUserId(), User.GetCurrentBranchId() ?? 1);
        return Json(new { success = true, message = "Approval removed. Requests already waiting stay on the Approval Dashboard for its approvers." });
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });

    public class MatrixRow
    {
        public int Matrix_ID { get; set; }
        public string Module_Code { get; set; } = "";
        public string Module_Name { get; set; } = "";
        public string Scope { get; set; } = "C";
        public int? Branch_ID { get; set; }
        public string? BranchName { get; set; }
        public DateTime UpdatedOn { get; set; }
        public int PendingCount { get; set; }
        public string? ApproverIds { get; set; }
        public string? ApproverNames { get; set; }
    }
}
