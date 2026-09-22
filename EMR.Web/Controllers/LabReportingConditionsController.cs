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
/// Master &gt; Lab Master &gt; Conditions of Reporting. Company-wise and branch-wise; the conditions are
/// printed on the last page of the Lab Report PDF.
/// </summary>
[Authorize]
public class LabReportingConditionsController(
    ILabReportingConditionApiClient conditionApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private const string PageName = "Conditions of Reporting";

    [HttpGet]
    public async Task<IActionResult> Index(int? branchScope = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var filteredTask = conditionApiClient.GetListAsync(status, branchScope, search, companyId);
            var allTask = conditionApiClient.GetListAsync(companyId: companyId);
            await Task.WhenAll(filteredTask, allTask);

            var all = (await allTask).ToList();
            var branchScopeOptions = new List<SelectListItem>
            {
                new() { Value = "0", Text = "All Branches (company-wide)", Selected = branchScope == 0 }
            };
            branchScopeOptions.AddRange((await GetBranchOptionsAsync(companyId, branchScope)));

            var model = new LabReportingConditionIndexViewModel
            {
                Conditions = (await filteredTask).ToList(),
                SelectedBranchScope = branchScope,
                SelectedStatus = status,
                SearchTerm = search,
                BranchScopeOptions = branchScopeOptions,
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                },
                TotalCount = all.Count,
                ActiveCount = all.Count(c => c.Status),
                CompanyWideCount = all.Count(c => c.Branch_ID == null),
                BranchSpecificCount = all.Count(c => c.Branch_ID != null),
                BranchesWithOwnSet = all.Where(c => c.Branch_ID != null && c.Status).Select(c => c.Branch_ID).Distinct().Count()
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = PageName;
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();

        var model = new LabReportingConditionFormViewModel
        {
            CompanyId = companyId,
            Display_Order = await NextDisplayOrderAsync(companyId),
            Status = true,
            BranchOptions = await GetBranchOptionsAsync(companyId, null)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabReportingConditionFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            model.BranchOptions = await GetBranchOptionsAsync(companyId, model.Branch_ID);
            return View(model);
        }

        try
        {
            var newId = await conditionApiClient.CreateAsync(new LabReportingConditionCreateRequestModel
            {
                Condition_Text = model.Condition_Text,
                Branch_ID = model.Branch_ID > 0 ? model.Branch_ID : null,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                UserId = User.GetUserId()
            });

            await auditLogService.LogAsync(
                "Create Condition of Reporting", "Create",
                $"Created Condition of Reporting #{newId} ({(model.Branch_ID > 0 ? $"branch {model.Branch_ID}" : "company-wide")})",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Condition of Reporting created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.BranchOptions = await GetBranchOptionsAsync(companyId, model.Branch_ID);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Create {PageName}";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var item = await GetOwnedAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Condition of Reporting not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(new LabReportingConditionFormViewModel
            {
                Condition_ID = item.Condition_ID,
                CompanyId = item.CompanyId,
                Condition_Code = item.Condition_Code,
                Branch_ID = item.Branch_ID,
                Condition_Text = item.Condition_Text,
                Display_Order = item.Display_Order,
                Status = item.Status,
                BranchOptions = await GetBranchOptionsAsync(companyId, item.Branch_ID)
            });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Edit {PageName}";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabReportingConditionFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        if (id != model.Condition_ID)
            return BadRequest();

        try
        {
            if (await GetOwnedAsync(id) == null)
            {
                TempData["ErrorMessage"] = "Condition of Reporting not found.";
                return RedirectToAction(nameof(Index));
            }

            if (!ModelState.IsValid)
            {
                model.BranchOptions = await GetBranchOptionsAsync(companyId, model.Branch_ID);
                return View(model);
            }

            await conditionApiClient.UpdateAsync(new LabReportingConditionUpdateRequestModel
            {
                Condition_ID = model.Condition_ID,
                Condition_Text = model.Condition_Text,
                Branch_ID = model.Branch_ID > 0 ? model.Branch_ID : null,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            });

            await auditLogService.LogAsync(
                "Update Condition of Reporting", "Edit",
                $"Updated Condition of Reporting #{model.Condition_ID}",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Condition of Reporting updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.BranchOptions = await GetBranchOptionsAsync(companyId, model.Branch_ID);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = $"Edit {PageName}";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await GetOwnedAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Condition of Reporting not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
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
        try
        {
            if (await GetOwnedAsync(id) == null)
            {
                TempData["ErrorMessage"] = "Condition of Reporting not found.";
                return RedirectToAction(nameof(Index));
            }

            await conditionApiClient.ToggleStatusAsync(new LabReportingConditionToggleStatusRequestModel
            {
                Condition_ID = id,
                Status = status,
                UserId = User.GetUserId()
            });

            await auditLogService.LogAsync(
                "Toggle Condition of Reporting Status", "ToggleStatus",
                $"Toggled status for Condition of Reporting #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            if (await GetOwnedAsync(id) == null)
            {
                TempData["ErrorMessage"] = "Condition of Reporting not found.";
                return RedirectToAction(nameof(Index));
            }

            await conditionApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync(
                "Delete Condition of Reporting", "Delete",
                $"Deleted Condition of Reporting #{id}",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Condition of Reporting deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// <summary>The record, only if it belongs to the signed-in user's company.</summary>
    private async Task<LabReportingConditionModel?> GetOwnedAsync(int id)
    {
        var item = await conditionApiClient.GetByIdAsync(id);
        return item != null && item.CompanyId == User.GetCompanyId() ? item : null;
    }

    /// <summary>Active branches of the company (the "All Branches" choice is the empty option in the form).</summary>
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

    /// <summary>Next number in the company-wide sequence, so new conditions land at the end of the list by default.</summary>
    private async Task<int> NextDisplayOrderAsync(int companyId)
    {
        try
        {
            var all = await conditionApiClient.GetListAsync(companyId: companyId);
            return all.Any() ? all.Max(c => c.Display_Order) + 1 : 1;
        }
        catch
        {
            return 1;
        }
    }
}
