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
public class LabFormulaParametersController(
    ILabFormulaParameterApiClient formulaApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var items = (await formulaApiClient.GetListAsync(status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabFormulaParameters");

            var model = new LabFormulaParameterIndexViewModel
            {
                FormulaParameters = items,
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
            ViewData["PageName"] = "Lab Formula Component";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new LabFormulaParameterFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            IsActive = true,
            Rounding_Precision = 2
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabFormulaParameterFormViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabFormulaParameterCreateRequestModel
            {
                Test_ID = model.Test_ID,
                Formula_Expression = model.Formula_Expression,
                Rounding_Precision = model.Rounding_Precision,
                Validity_Condition = model.Validity_Condition,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };

            var newId = await formulaApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Formula Parameter",
                "Create",
                $"Created Lab Formula Parameter with ID #{newId} for Test #{model.Test_ID}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Formula Parameter created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Formula Parameter";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await formulaApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Formula Parameter not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabFormulaParameterFormViewModel
            {
                Parameter_ID = item.Parameter_ID,
                CompanyId = item.CompanyId,
                Test_ID = item.Test_ID,
                Test_Name = item.Test_Name,
                Formula_Expression = item.Formula_Expression,
                Rounding_Precision = item.Rounding_Precision,
                Validity_Condition = item.Validity_Condition,
                IsActive = item.IsActive
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Formula Parameter";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabFormulaParameterFormViewModel model)
    {
        if (id != model.Parameter_ID)
            return BadRequest();

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabFormulaParameterUpdateRequestModel
            {
                Parameter_ID = model.Parameter_ID,
                Test_ID = model.Test_ID,
                Formula_Expression = model.Formula_Expression,
                Rounding_Precision = model.Rounding_Precision,
                Validity_Condition = model.Validity_Condition,
                IsActive = model.IsActive,
                UserId = User.GetUserId()
            };

            await formulaApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Formula Parameter",
                "Edit",
                $"Updated Lab Formula Parameter #{model.Parameter_ID}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Formula Parameter updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Formula Parameter";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await formulaApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Formula Parameter not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Formula Parameter Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool isActive)
    {
        try
        {
            var req = new LabFormulaParameterToggleStatusRequestModel
            {
                Parameter_ID = id,
                IsActive = isActive,
                UserId = User.GetUserId()
            };

            await formulaApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Formula Parameter Status",
                "ToggleStatus",
                $"Toggled status for Lab Formula Parameter #{id} to {(isActive ? "Active" : "Inactive")}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
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
        try
        {
            await formulaApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Formula Parameter",
                "Delete",
                $"Deleted Lab Formula Parameter #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Formula Parameter deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> SearchNumericTests(string? term)
    {
        var companyId = User.GetCompanyId();
        var tests = await formulaApiClient.GetNumericTestsAsync(companyId, term);
        return Json(tests.Select(t => new { id = t.Test_ID, text = $"{t.Test_Name} ({t.Test_Code})", code = t.Test_Code, name = t.Test_Name }));
    }
}
