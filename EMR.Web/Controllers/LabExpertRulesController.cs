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
public class LabExpertRulesController(
    ILabExpertRuleApiClient apiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null, int? organism_ID = null, int? antibiotic_ID = null)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var items = (await apiClient.GetListAsync(status, search, companyId, organism_ID, antibiotic_ID)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabExpertRules");
            var model = new LabExpertRuleIndexViewModel
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
            var organismsFilter = await apiClient.LookupOrganismsAsync(companyId);
            model.SelectedOrganism_ID = organism_ID;
            model.Organism_IDFilterOptions = organismsFilter.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == organism_ID }).ToList();
            var antibioticsFilter = await apiClient.LookupAntibioticsAsync(companyId);
            model.SelectedAntibiotic_ID = antibiotic_ID;
            model.Antibiotic_IDFilterOptions = antibioticsFilter.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == antibiotic_ID }).ToList();
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Expert Rule Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabExpertRuleFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Expert Rule";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabExpertRuleFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabExpertRuleCreateRequestModel
            {
                Rule_Type = model.Rule_Type,
                Organism_Category = model.Organism_Category,
                Organism_ID = model.Organism_ID,
                Antibiotic_ID = model.Antibiotic_ID,
                Trigger_Result = model.Trigger_Result,
                Rule_Action = model.Rule_Action,
                Alert_Message = model.Alert_Message.Trim(),
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Expert Rule Master",
                "Create",
                $"Created Expert Rule '{model.Alert_Message}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Expert Rule '{model.Alert_Message}' created successfully.";
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
            ViewData["PageName"] = "Create Expert Rule";
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
                TempData["ErrorMessage"] = "Expert Rule not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabExpertRuleFormViewModel
            {
                Rule_ID = item.Rule_ID,
                CompanyId = item.CompanyId,
                Rule_Code = item.Rule_Code,
                Rule_Type = item.Rule_Type,
                Organism_Category = item.Organism_Category,
                Organism_ID = item.Organism_ID,
                Antibiotic_ID = item.Antibiotic_ID,
                Trigger_Result = item.Trigger_Result,
                Rule_Action = item.Rule_Action,
                Alert_Message = item.Alert_Message,
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Expert Rule";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabExpertRuleFormViewModel model)
    {
        if (id != model.Rule_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabExpertRuleUpdateRequestModel
            {
                Rule_ID = model.Rule_ID,
                Rule_Type = model.Rule_Type,
                Organism_Category = model.Organism_Category,
                Organism_ID = model.Organism_ID,
                Antibiotic_ID = model.Antibiotic_ID,
                Trigger_Result = model.Trigger_Result,
                Rule_Action = model.Rule_Action,
                Alert_Message = model.Alert_Message.Trim(),
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Expert Rule Master",
                "Edit",
                $"Updated Expert Rule #{model.Rule_ID} ('{model.Alert_Message}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Expert Rule '{model.Alert_Message}' updated successfully.";
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
            ViewData["PageName"] = "Edit Expert Rule";
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
                TempData["ErrorMessage"] = "Expert Rule not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Expert Rule Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabExpertRuleToggleStatusRequestModel { Rule_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Expert Rule Master Status",
                "ToggleStatus",
                $"Toggled status for Expert Rule #{id} to {(status ? "Active" : "Inactive")}",
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
                "Delete Expert Rule Master",
                "Delete",
                $"Deleted Expert Rule #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Expert Rule deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabExpertRuleFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var organisms = await apiClient.LookupOrganismsAsync(companyId);
        model.Organism_IDOptions = organisms.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Organism_ID }).ToList();
        var antibiotics = await apiClient.LookupAntibioticsAsync(companyId);
        model.Antibiotic_IDOptions = antibiotics.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Antibiotic_ID }).ToList();
    }
}
