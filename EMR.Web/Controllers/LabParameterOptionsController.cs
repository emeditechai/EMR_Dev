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
public class LabParameterOptionsController(
    ILabParameterOptionApiClient apiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null, int? test_ID = null)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var items = (await apiClient.GetListAsync(status, search, companyId, test_ID)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabParameterOptions");
            var model = new LabParameterOptionIndexViewModel
            {
                Items = items,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = dashboard,
                StatusOptions =
                [
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                ]
            };
            var testsFilter = await apiClient.LookupTestsAsync(companyId);
            model.SelectedTest_ID = test_ID;
            model.Test_IDFilterOptions = testsFilter.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == test_ID }).ToList();
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Parameter Option Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabParameterOptionFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Parameter Option";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabParameterOptionFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabParameterOptionCreateRequestModel
            {
                Test_ID = model.Test_ID,
                Option_Text = model.Option_Text.Trim(),
                Display_Order = model.Display_Order,
                Is_Abnormal = model.Is_Abnormal,
                Is_Default = model.Is_Default,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Parameter Option Master",
                "Create",
                $"Created Parameter Option '{model.Option_Text}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Parameter Option '{model.Option_Text}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Parameter Option";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await apiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Parameter Option not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabParameterOptionFormViewModel
            {
                Option_ID = item.Option_ID,
                CompanyId = item.CompanyId,
                Option_Code = item.Option_Code,
                Test_ID = item.Test_ID,
                Option_Text = item.Option_Text,
                Display_Order = item.Display_Order,
                Is_Abnormal = item.Is_Abnormal,
                Is_Default = item.Is_Default,
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Parameter Option";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabParameterOptionFormViewModel model)
    {
        if (id != model.Option_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabParameterOptionUpdateRequestModel
            {
                Option_ID = model.Option_ID,
                Test_ID = model.Test_ID,
                Option_Text = model.Option_Text.Trim(),
                Display_Order = model.Display_Order,
                Is_Abnormal = model.Is_Abnormal,
                Is_Default = model.Is_Default,
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Parameter Option Master",
                "Edit",
                $"Updated Parameter Option #{model.Option_ID} ('{model.Option_Text}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Parameter Option '{model.Option_Text}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Parameter Option";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await apiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Parameter Option not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Parameter Option Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabParameterOptionToggleStatusRequestModel { Option_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Parameter Option Master Status",
                "ToggleStatus",
                $"Toggled status for Parameter Option #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
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
            await apiClient.DeleteAsync(id, User.GetUserId());
            await auditLogService.LogAsync(
                "Delete Parameter Option Master",
                "Delete",
                $"Deleted Parameter Option #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Parameter Option deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabParameterOptionFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var tests = await apiClient.LookupTestsAsync(companyId);
        model.Test_IDOptions = tests.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Test_ID }).ToList();
    }
}
