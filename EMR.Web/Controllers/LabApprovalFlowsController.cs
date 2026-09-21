using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings &gt; Pathologist Approval Flow. Configures how many approvals (1-3, sequential) a lab report needs
/// and which pathologists may give each one. Company-wise, with optional Branch / Department / Test Category scope.
/// Configuration only: no report or approval screen reads it yet.
/// </summary>
[Authorize]
public class LabApprovalFlowsController(
    ILabApprovalFlowApiClient flowApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private const string PageName = "Pathologist Approval Flow";

    // ── list ──────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index(int? branchScope = null, int? departmentId = null, bool? status = null, string? search = null)
    {
        if (!CanManage()) return Denied();

        var companyId = User.GetCompanyId();

        try
        {
            var filteredTask = flowApiClient.GetListAsync(companyId, branchScope, departmentId, null, status, search);
            var allTask = flowApiClient.GetListAsync(companyId);
            await Task.WhenAll(filteredTask, allTask);

            var all = (await allTask).ToList();

            var branchScopeOptions = new List<SelectListItem>
            {
                new() { Value = "0", Text = "All Branches (company-wide)", Selected = branchScope == 0 }
            };
            branchScopeOptions.AddRange(await GetBranchOptionsAsync(companyId, branchScope));

            return View(new LabApprovalFlowIndexViewModel
            {
                Flows = (await filteredTask).ToList(),
                SelectedBranchScope = branchScope,
                SelectedDepartmentId = departmentId,
                SelectedStatus = status,
                SearchTerm = search,
                BranchScopeOptions = branchScopeOptions,
                DepartmentOptions = await GetDepartmentOptionsAsync(companyId, departmentId),
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                },
                TotalCount = all.Count,
                ActiveCount = all.Count(f => f.Status),
                CompanyDefaultCount = all.Count(f => f.Branch_ID == null && f.Department_ID == null && f.Category_IDs == null),
                OverrideCount = all.Count(f => f.Branch_ID != null || f.Department_ID != null || f.Category_IDs != null),
                MultiLevelCount = all.Count(f => f.Required_Levels > 1)
            });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = PageName;
            return View("ApiDown");
        }
    }

    // ── create ────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        if (!CanManage()) return Denied();

        try
        {
            var model = new LabApprovalFlowFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
            await PopulateOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Create {PageName}";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabApprovalFlowFormViewModel model)
    {
        if (!CanManage()) return Denied();

        var companyId = User.GetCompanyId();
        NormalizeLevels(model);

        try
        {
            if (!ModelState.IsValid)
            {
                model.CompanyId = companyId;
                await PopulateOptionsAsync(model);
                return View(model);
            }

            var newId = await flowApiClient.CreateAsync(new LabApprovalFlowCreateRequestModel
            {
                Flow_Name = model.Flow_Name,
                Required_Levels = model.Required_Levels,
                Branch_ID = model.Branch_ID > 0 ? model.Branch_ID : null,
                Department_ID = model.Department_ID > 0 ? model.Department_ID : null,
                Category_IDs = model.Category_IDs.Where(c => c > 0).Distinct().ToList(),
                Allow_Same_Approver = model.Allow_Same_Approver,
                Levels = ToLevelInputs(model),
                CompanyId = companyId,
                UserId = User.GetUserId()
            });

            await auditLogService.LogActivityAsync(
                eventType: "Approval Flow", actionName: "LAB.ApprovalFlowCreated",
                description: $"Created Pathologist Approval Flow #{newId} \"{model.Flow_Name}\" ({model.Required_Levels} level(s)).",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId() ?? 1,
                moduleCode: "LAB", referenceId: newId,
                metadata: new { FlowId = newId, model.Flow_Name, model.Required_Levels, model.Branch_ID, model.Department_ID, Categories = string.Join(",", model.Category_IDs) });

            TempData["SuccessMessage"] = "Approval flow created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CompanyId = companyId;
            await PopulateOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Create {PageName}";
            return View("ApiDown");
        }
    }

    // ── edit ──────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        if (!CanManage()) return Denied();

        try
        {
            var detail = await GetOwnedAsync(id);
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Approval flow not found.";
                return RedirectToAction(nameof(Index));
            }

            var f = detail.Flow;
            var model = new LabApprovalFlowFormViewModel
            {
                Flow_ID = f.Flow_ID,
                CompanyId = f.CompanyId,
                Flow_Code = f.Flow_Code,
                Flow_Name = f.Flow_Name,
                Required_Levels = f.Required_Levels,
                Branch_ID = f.Branch_ID,
                Department_ID = f.Department_ID,
                Category_IDs = f.CategoryIdList.ToList(),
                Allow_Same_Approver = f.Allow_Same_Approver,
                Status = f.Status,
                Levels = Enumerable.Range(1, 3).Select(n => new LabApprovalFlowLevelForm
                {
                    LevelNo = n,
                    Title = detail.Levels.FirstOrDefault(l => l.Level_No == n)?.Level_Title,
                    ApproverIds = detail.Approvers.Where(a => a.Level_No == n).Select(a => a.UserId).ToList()
                }).ToList()
            };

            await PopulateOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Edit {PageName}";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabApprovalFlowFormViewModel model)
    {
        if (!CanManage()) return Denied();
        if (id != model.Flow_ID) return BadRequest();

        NormalizeLevels(model);

        try
        {
            var existing = await GetOwnedAsync(id);
            if (existing == null)
            {
                TempData["ErrorMessage"] = "Approval flow not found.";
                return RedirectToAction(nameof(Index));
            }

            model.CompanyId = existing.Flow.CompanyId;
            model.Flow_Code = existing.Flow.Flow_Code;

            if (!ModelState.IsValid)
            {
                await PopulateOptionsAsync(model);
                return View(model);
            }

            await flowApiClient.UpdateAsync(new LabApprovalFlowUpdateRequestModel
            {
                Flow_ID = model.Flow_ID,
                Flow_Name = model.Flow_Name,
                Required_Levels = model.Required_Levels,
                Branch_ID = model.Branch_ID > 0 ? model.Branch_ID : null,
                Department_ID = model.Department_ID > 0 ? model.Department_ID : null,
                Category_IDs = model.Category_IDs.Where(c => c > 0).Distinct().ToList(),
                Allow_Same_Approver = model.Allow_Same_Approver,
                Status = model.Status,
                Levels = ToLevelInputs(model),
                UserId = User.GetUserId()
            });

            await auditLogService.LogActivityAsync(
                eventType: "Approval Flow", actionName: "LAB.ApprovalFlowUpdated",
                description: $"Updated Pathologist Approval Flow #{model.Flow_ID} \"{model.Flow_Name}\" ({model.Required_Levels} level(s)).",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId() ?? 1,
                moduleCode: "LAB", referenceId: model.Flow_ID,
                metadata: new { FlowId = model.Flow_ID, model.Flow_Name, model.Required_Levels, model.Branch_ID, model.Department_ID, Categories = string.Join(",", model.Category_IDs), model.Status });

            TempData["SuccessMessage"] = "Approval flow updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Edit {PageName}";
            return View("ApiDown");
        }
    }

    // ── details / status / delete ─────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        if (!CanManage()) return Denied();

        try
        {
            var detail = await GetOwnedAsync(id);
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Approval flow not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(detail);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"{PageName} Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        if (!CanManage()) return Denied();

        try
        {
            if (await GetOwnedAsync(id) == null)
            {
                TempData["ErrorMessage"] = "Approval flow not found.";
                return RedirectToAction(nameof(Index));
            }

            await flowApiClient.ToggleStatusAsync(new LabApprovalFlowToggleStatusRequestModel
            {
                Flow_ID = id, Status = status, UserId = User.GetUserId()
            });

            await auditLogService.LogActivityAsync(
                eventType: "Approval Flow", actionName: "LAB.ApprovalFlowStatusChanged",
                description: $"Pathologist Approval Flow #{id} set to {(status ? "Active" : "Inactive")}.",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId() ?? 1,
                moduleCode: "LAB", referenceId: id, metadata: new { FlowId = id, Status = status });

            TempData["SuccessMessage"] = "Status updated successfully.";
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        if (!CanManage()) return Denied();

        try
        {
            var detail = await GetOwnedAsync(id);
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Approval flow not found.";
                return RedirectToAction(nameof(Index));
            }

            await flowApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogActivityAsync(
                eventType: "Approval Flow", actionName: "LAB.ApprovalFlowDeleted",
                description: $"Deleted Pathologist Approval Flow #{id} \"{detail.Flow.Flow_Name}\".",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId() ?? 1,
                moduleCode: "LAB", referenceId: id, metadata: new { FlowId = id, detail.Flow.Flow_Name });

            TempData["SuccessMessage"] = "Approval flow deleted successfully.";
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    // ── json: approvers for the chosen scope ─────────────────────────────────

    /// <summary>Pathologists eligible for a branch / department / category, used to refresh the level pickers.</summary>
    [HttpGet]
    public async Task<IActionResult> GetEligibleApproversJson(int? branchId, int? departmentId, string? categoryIds)
    {
        if (!CanManage()) return Json(new { success = false, message = "Access denied." });

        try
        {
            var all = (await flowApiClient.GetEligibleApproversAsync(
                User.GetCompanyId(),
                branchId > 0 ? branchId : null,
                departmentId > 0 ? departmentId : null,
                ParseIds(categoryIds),
                includeIneligible: true)).ToList();

            return Json(new
            {
                success = true,
                approvers = all.Where(a => a.IsEligible).Select(ToJson),
                notListed = all.Where(a => !a.IsEligible).Select(a => new { userId = a.UserId, fullName = a.FullName, reason = a.IneligibleReason })
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The lab service is unreachable. Please try again." });
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private static object ToJson(LabApprovalEligibleApproverModel a) => new
    {
        userId = a.UserId, fullName = a.FullName, registrationNo = a.RegistrationNo,
        departments = a.DepartmentNames, categories = a.CategoryNames
    };

    /// <summary>"3,7,11" -> [3, 7, 11], ignoring anything that is not a positive number.</summary>
    private static List<int> ParseIds(string? csv) =>
        string.IsNullOrWhiteSpace(csv)
            ? new List<int>()
            : csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                 .Select(x => int.TryParse(x, out var id) ? id : 0).Where(id => id > 0).Distinct().ToList();

    /// <summary>Configuration is for administrators only.</summary>
    private bool CanManage() => User.IsCompanyAdmin();

    private IActionResult Denied()
    {
        TempData["ErrorMessage"] = "Only an administrator can configure the Pathologist Approval Flow.";
        return RedirectToAction("Index", "Home");
    }

    /// <summary>The flow, only if it belongs to the signed-in user's company.</summary>
    private async Task<LabApprovalFlowDetailModel?> GetOwnedAsync(int id)
    {
        var detail = await flowApiClient.GetByIdAsync(id);
        return detail != null && detail.Flow.CompanyId == User.GetCompanyId() ? detail : null;
    }

    /// <summary>Three levels are always posted; keep exactly Required_Levels of them, numbered 1..N.</summary>
    private static void NormalizeLevels(LabApprovalFlowFormViewModel model)
    {
        model.Category_IDs = (model.Category_IDs ?? new()).Where(c => c > 0).Distinct().ToList();
        model.Levels ??= new();
        while (model.Levels.Count < 3)
            model.Levels.Add(new LabApprovalFlowLevelForm { LevelNo = model.Levels.Count + 1 });

        for (var i = 0; i < model.Levels.Count; i++)
        {
            model.Levels[i].LevelNo = i + 1;
            model.Levels[i].Title = model.Levels[i].Title?.Trim();
            model.Levels[i].ApproverIds = (model.Levels[i].ApproverIds ?? new()).Distinct().ToList();
        }
    }

    private static List<LabApprovalFlowLevelInput> ToLevelInputs(LabApprovalFlowFormViewModel model) =>
        model.Levels
            .Where(l => l.LevelNo <= model.Required_Levels)
            .Select(l => new LabApprovalFlowLevelInput { LevelNo = l.LevelNo, Title = l.Title, ApproverIds = l.ApproverIds })
            .ToList();

    private async Task PopulateOptionsAsync(LabApprovalFlowFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        model.BranchOptions = await GetBranchOptionsAsync(companyId, model.Branch_ID);
        model.DepartmentOptions = await GetDepartmentOptionsAsync(companyId, model.Department_ID);

        model.CategoryOptions = (await categoryApiClient.GetByDepartmentsAsync(null, companyId))
            .Select(c => new LabApprovalCategoryOption { CategoryId = c.CategoryId, CategoryName = c.CategoryName, DepartmentId = c.DepartmentId })
            .ToList();

        // Pathologists matching the scope (User Master: Assigned Department(s) + Test Categories sign-off scope), plus anyone
        // already selected who no longer matches (kept visible and flagged so a failed save does not lose the choice).
        var everyone = (await flowApiClient.GetEligibleApproversAsync(
            companyId,
            model.Branch_ID > 0 ? model.Branch_ID : null,
            model.Department_ID > 0 ? model.Department_ID : null,
            model.Category_IDs,
            includeIneligible: true)).ToList();

        var scoped = everyone.Where(a => a.IsEligible).ToList();
        var selected = model.Levels.SelectMany(l => l.ApproverIds).Distinct().ToHashSet();

        foreach (var user in everyone.Where(a => !a.IsEligible && selected.Contains(a.UserId)))
        {
            scoped.Add(user);
            model.IneligibleSelectedIds.Add(user.UserId);
        }

        model.NotListedApprovers = everyone.Where(a => !a.IsEligible && !selected.Contains(a.UserId)).ToList();

        model.Approvers = scoped.OrderBy(a => a.FullName).ToList();
    }

    private async Task<List<SelectListItem>> GetBranchOptionsAsync(int companyId, int? selectedId)
    {
        var branches = await dbContext.BranchMasters
            .AsNoTracking()
            .Where(b => b.CompanyId == companyId && b.IsActive)
            .OrderBy(b => b.BranchName)
            .Select(b => new { b.BranchId, b.BranchName, b.BranchCode })
            .ToListAsync();

        return branches.Select(b => new SelectListItem
        {
            Value = b.BranchId.ToString(),
            Text = string.IsNullOrWhiteSpace(b.BranchCode) ? b.BranchName : $"{b.BranchName} ({b.BranchCode})",
            Selected = selectedId.HasValue && selectedId.Value == b.BranchId
        }).ToList();
    }

    private async Task<List<SelectListItem>> GetDepartmentOptionsAsync(int companyId, int? selectedId)
    {
        var departments = await dbContext.DepartmentMasters
            .AsNoTracking()
            .Where(d => d.IsActive && d.DeptType.ToUpper() == "LAB")   // lab reports only; the entity has no company column, the stored procedure validates it
            .OrderBy(d => d.DeptName)
            .Select(d => new { d.DeptId, d.DeptName })
            .ToListAsync();

        return departments.Select(d => new SelectListItem
        {
            Value = d.DeptId.ToString(),
            Text = d.DeptName,
            Selected = selectedId.HasValue && selectedId.Value == d.DeptId
        }).ToList();
    }
}
