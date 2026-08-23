using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class LabUnitsController(
    ILabUnitApiClient unitApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var units = (await unitApiClient.GetListAsync(branchId, status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(branchId, companyId, "LabUnits");

            var model = new LabUnitIndexViewModel
            {
                Units = units,
                SelectedBranchId = branchId,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = dashboard,
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                }
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Unit Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new LabUnitFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId() ?? 1,
            Display_Order = 1,
            Conversion_Factor = 1.0m,
            Status = true
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabUnitFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabUnitCreateRequestModel
            {
                Unit_Name = model.Unit_Name,
                Unit_Symbol = model.Unit_Symbol,
                Conversion_Factor = model.Conversion_Factor,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                BranchId = branchId,
                UserId = User.GetUserId()
            };

            var newId = await unitApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Unit",
                "Create",
                $"Created Unit '{model.Unit_Name}' with ID #{newId}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Unit '{model.Unit_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Unit";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await unitApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Unit not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabUnitFormViewModel
            {
                Unit_ID = item.Unit_ID,
                CompanyId = item.CompanyId,
                BranchId = item.BranchId,
                Unit_Name = item.Unit_Name,
                Unit_Code = item.Unit_Code,
                Unit_Symbol = item.Unit_Symbol,
                Conversion_Factor = item.Conversion_Factor,
                Display_Order = item.Display_Order,
                Status = item.Status
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Unit";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabUnitFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (id != model.Unit_ID)
            return BadRequest();

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabUnitUpdateRequestModel
            {
                Unit_ID = model.Unit_ID,
                Unit_Name = model.Unit_Name,
                Unit_Symbol = model.Unit_Symbol,
                Conversion_Factor = model.Conversion_Factor,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await unitApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Unit",
                "Edit",
                $"Updated Unit #{model.Unit_ID} ('{model.Unit_Name}')",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Unit '{model.Unit_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Unit";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await unitApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Unit not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Unit Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            var req = new LabUnitToggleStatusRequestModel
            {
                Unit_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await unitApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Unit Status",
                "ToggleStatus",
                $"Toggled status for Unit #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(),
                branchId
            );

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
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await unitApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Unit",
                "Delete",
                $"Deleted Unit #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Unit deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }
}
