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
public class LabAntibioticPanelsController(
    ILabAntibioticPanelApiClient apiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null, int? sample_Type_ID = null)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var items = (await apiClient.GetListAsync(status, search, companyId, sample_Type_ID)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabAntibioticPanels");
            var model = new LabAntibioticPanelIndexViewModel
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
            var sampleTypesFilter = await apiClient.LookupSampleTypesAsync(companyId);
            model.SelectedSample_Type_ID = sample_Type_ID;
            model.Sample_Type_IDFilterOptions = sampleTypesFilter.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == sample_Type_ID }).ToList();
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Antibiotic Panel Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabAntibioticPanelFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Antibiotic Panel";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabAntibioticPanelFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabAntibioticPanelCreateRequestModel
            {
                Panel_Name = model.Panel_Name.Trim(),
                Gram_Type = model.Gram_Type,
                Organism_Category = model.Organism_Category,
                Sample_Type_ID = model.Sample_Type_ID,
                Description = model.Description?.Trim(),
                Antibiotic_IDs = model.Antibiotic_IDs,
                Antibiotic_Tiers = model.Antibiotic_Tiers,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Antibiotic Panel Master",
                "Create",
                $"Created Antibiotic Panel '{model.Panel_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Antibiotic Panel '{model.Panel_Name}' created successfully.";
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
            ViewData["PageName"] = "Create Antibiotic Panel";
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
                TempData["ErrorMessage"] = "Antibiotic Panel not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabAntibioticPanelFormViewModel
            {
                Panel_ID = item.Panel_ID,
                CompanyId = item.CompanyId,
                Panel_Code = item.Panel_Code,
                Panel_Name = item.Panel_Name,
                Gram_Type = item.Gram_Type,
                Organism_Category = item.Organism_Category,
                Sample_Type_ID = item.Sample_Type_ID,
                Description = item.Description,
                Antibiotic_IDs = ParseIds(item.Antibiotic_IDs),
                Antibiotic_Tiers = ParseIds(item.Antibiotic_Tiers),
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Antibiotic Panel";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabAntibioticPanelFormViewModel model)
    {
        if (id != model.Panel_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabAntibioticPanelUpdateRequestModel
            {
                Panel_ID = model.Panel_ID,
                Panel_Name = model.Panel_Name.Trim(),
                Gram_Type = model.Gram_Type,
                Organism_Category = model.Organism_Category,
                Sample_Type_ID = model.Sample_Type_ID,
                Description = model.Description?.Trim(),
                Antibiotic_IDs = model.Antibiotic_IDs,
                Antibiotic_Tiers = model.Antibiotic_Tiers,
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Antibiotic Panel Master",
                "Edit",
                $"Updated Antibiotic Panel #{model.Panel_ID} ('{model.Panel_Name}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Antibiotic Panel '{model.Panel_Name}' updated successfully.";
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
            ViewData["PageName"] = "Edit Antibiotic Panel";
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
                TempData["ErrorMessage"] = "Antibiotic Panel not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Antibiotic Panel Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabAntibioticPanelToggleStatusRequestModel { Panel_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Antibiotic Panel Master Status",
                "ToggleStatus",
                $"Toggled status for Antibiotic Panel #{id} to {(status ? "Active" : "Inactive")}",
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
                "Delete Antibiotic Panel Master",
                "Delete",
                $"Deleted Antibiotic Panel #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Antibiotic Panel deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabAntibioticPanelFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var sampleTypes = await apiClient.LookupSampleTypesAsync(companyId);
        model.Sample_Type_IDOptions = sampleTypes.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Sample_Type_ID }).ToList();
        var antibiotics = await apiClient.LookupAntibioticsAsync(companyId);
        var antibioticsOrder = model.Antibiotic_IDs.Select((id, i) => (id, i)).ToDictionary(t => t.id, t => t.i);
        model.Antibiotic_IDsOptions = antibiotics
            .OrderBy(x => antibioticsOrder.TryGetValue(x.Id, out var i) ? i : int.MaxValue)
            .Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = antibioticsOrder.ContainsKey(x.Id) })
            .ToList();
    }

    private static List<int> ParseIds(string? csv) =>
        string.IsNullOrWhiteSpace(csv)
            ? []
            : csv.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => int.TryParse(x, out var n) ? n : 0).Where(n => n > 0).ToList();
}
