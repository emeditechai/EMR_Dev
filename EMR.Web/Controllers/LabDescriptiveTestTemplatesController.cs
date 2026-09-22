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
public class LabDescriptiveTestTemplatesController(
    ILabDescriptiveTestTemplateApiClient templateApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var items = (await templateApiClient.GetListAsync(status, search, null, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabDescriptiveTestTemplates");

            var model = new LabDescriptiveTestTemplateIndexViewModel
            {
                Templates = items,
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
            ViewData["PageName"] = "Descriptive Test Template";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new LabDescriptiveTestTemplateFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            IsActive = true,
            Section_Sequence = 1
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabDescriptiveTestTemplateFormViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabDescriptiveTestTemplateCreateRequestModel
            {
                Test_ID = model.Test_ID,
                Section_Name = model.Section_Name,
                Section_Sequence = model.Section_Sequence,
                Is_Mandatory = model.Is_Mandatory,
                Default_Content_Html = model.Default_Content_Html,
                Placeholder_Tags = model.Placeholder_Tags,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };

            var newId = await templateApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Descriptive Test Template",
                "Create",
                $"Created Descriptive Test Template '{model.Section_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Template section '{model.Section_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Descriptive Test Template";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await templateApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Template not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabDescriptiveTestTemplateFormViewModel
            {
                Template_ID = item.Template_ID,
                CompanyId = item.CompanyId,
                Test_ID = item.Test_ID,
                Test_Name = item.Test_Name,
                Section_Name = item.Section_Name,
                Section_Sequence = item.Section_Sequence,
                Is_Mandatory = item.Is_Mandatory,
                Default_Content_Html = item.Default_Content_Html,
                Placeholder_Tags = item.Placeholder_Tags,
                IsActive = item.IsActive
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Descriptive Test Template";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabDescriptiveTestTemplateFormViewModel model)
    {
        if (id != model.Template_ID)
            return BadRequest();

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabDescriptiveTestTemplateUpdateRequestModel
            {
                Template_ID = model.Template_ID,
                Test_ID = model.Test_ID,
                Section_Name = model.Section_Name,
                Section_Sequence = model.Section_Sequence,
                Is_Mandatory = model.Is_Mandatory,
                Default_Content_Html = model.Default_Content_Html,
                Placeholder_Tags = model.Placeholder_Tags,
                IsActive = model.IsActive,
                UserId = User.GetUserId()
            };

            await templateApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Descriptive Test Template",
                "Edit",
                $"Updated Descriptive Test Template #{model.Template_ID} ('{model.Section_Name}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Template section '{model.Section_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Descriptive Test Template";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await templateApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Template not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Descriptive Test Template Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool isActive)
    {
        try
        {
            var req = new LabDescriptiveTestTemplateToggleStatusRequestModel
            {
                Template_ID = id,
                IsActive = isActive,
                UserId = User.GetUserId()
            };

            await templateApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Descriptive Test Template Status",
                "ToggleStatus",
                $"Toggled status for Template #{id} to {(isActive ? "Active" : "Inactive")}",
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
            await templateApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Descriptive Test Template",
                "Delete",
                $"Deleted Descriptive Test Template #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Template deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> SearchRadiologyTests(string? term)
    {
        var companyId = User.GetCompanyId();
        var tests = await templateApiClient.GetRadiologyTestsAsync(companyId, term);
        return Json(tests.Select(t => new { id = t.Test_ID, text = $"{t.Test_Name} ({t.Test_Code})" }));
    }
}
