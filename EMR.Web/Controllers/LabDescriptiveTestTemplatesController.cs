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
                Modality = model.Modality,
                Body_Part = model.Body_Part,
                Laterality = model.Laterality,
                Contrast_Required = model.Contrast_Required,
                Contrast_Agent = model.Contrast_Agent,
                Views_Projections = model.Views_Projections,
                Preparation_Instructions = model.Preparation_Instructions,
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
    public IActionResult BatchCreate()
    {
        var model = new LabDescriptiveTestTemplateBatchFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Sections =
            [
                new() { Section_Name = "Clinical History", Section_Sequence = 1, Is_Mandatory = true },
                new() { Section_Name = "Technique", Section_Sequence = 2, Is_Mandatory = true },
                new() { Section_Name = "Comparison", Section_Sequence = 3 },
                new() { Section_Name = "Findings", Section_Sequence = 4, Is_Mandatory = true },
                new() { Section_Name = "Impression", Section_Sequence = 5, Is_Mandatory = true },
                new() { Section_Name = "Recommendation", Section_Sequence = 6 }
            ]
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> BatchCreate(LabDescriptiveTestTemplateBatchFormViewModel model)
    {
        if (model.Sections == null || model.Sections.Count == 0)
        {
            ModelState.AddModelError(string.Empty, "At least one section is required.");
            return View(model);
        }

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var req = new LabDescriptiveTestTemplateBatchCreateRequestModel
            {
                Test_ID = model.Test_ID,
                Modality = model.Modality,
                Body_Part = model.Body_Part,
                Laterality = model.Laterality,
                Contrast_Required = model.Contrast_Required,
                Contrast_Agent = model.Contrast_Agent,
                Views_Projections = model.Views_Projections,
                Preparation_Instructions = model.Preparation_Instructions,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId(),
                Sections = model.Sections.Select(s => new LabDescriptiveTestTemplateSectionRequestModel
                {
                    Section_Name = s.Section_Name,
                    Section_Sequence = s.Section_Sequence,
                    Is_Mandatory = s.Is_Mandatory,
                    Default_Content_Html = s.Default_Content_Html,
                    Placeholder_Tags = s.Placeholder_Tags
                }).ToList()
            };

            var ids = await templateApiClient.BatchCreateAsync(req);

            await auditLogService.LogAsync(
                "Batch Create Descriptive Test Template",
                "Create",
                $"Created {ids.Count} template sections for Test ID #{model.Test_ID}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"{ids.Count} template section(s) created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Template (Multi-Section)";
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
                Modality = item.Modality,
                Body_Part = item.Body_Part,
                Laterality = item.Laterality,
                Contrast_Required = item.Contrast_Required,
                Contrast_Agent = item.Contrast_Agent,
                Views_Projections = item.Views_Projections,
                Preparation_Instructions = item.Preparation_Instructions,
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
                Modality = model.Modality,
                Body_Part = model.Body_Part,
                Laterality = model.Laterality,
                Contrast_Required = model.Contrast_Required,
                Contrast_Agent = model.Contrast_Agent,
                Views_Projections = model.Views_Projections,
                Preparation_Instructions = model.Preparation_Instructions,
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
