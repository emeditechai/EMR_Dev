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
public class LabBreakpointsController(
    ILabBreakpointApiClient apiClient,
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
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabBreakpoints");
            var model = new LabBreakpointIndexViewModel
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
            ViewData["PageName"] = "Breakpoint Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabBreakpointFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Breakpoint";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabBreakpointFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabBreakpointCreateRequestModel
            {
                Organism_Category = model.Organism_Category,
                Organism_ID = model.Organism_ID,
                Antibiotic_ID = model.Antibiotic_ID,
                Standard = model.Standard,
                Standard_Version = model.Standard_Version.Trim(),
                Method = model.Method,
                Specimen_Scope = model.Specimen_Scope,
                S_Breakpoint = model.S_Breakpoint,
                R_Breakpoint = model.R_Breakpoint,
                Remarks = model.Remarks?.Trim(),
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Breakpoint Master",
                "Create",
                $"Created Breakpoint '{model.Standard_Version}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Breakpoint '{model.Standard_Version}' created successfully.";
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
            ViewData["PageName"] = "Create Breakpoint";
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
                TempData["ErrorMessage"] = "Breakpoint not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabBreakpointFormViewModel
            {
                Breakpoint_ID = item.Breakpoint_ID,
                CompanyId = item.CompanyId,
                Breakpoint_Code = item.Breakpoint_Code,
                Organism_Category = item.Organism_Category,
                Organism_ID = item.Organism_ID,
                Antibiotic_ID = item.Antibiotic_ID,
                Standard = item.Standard,
                Standard_Version = item.Standard_Version,
                Method = item.Method,
                Specimen_Scope = item.Specimen_Scope,
                S_Breakpoint = item.S_Breakpoint,
                R_Breakpoint = item.R_Breakpoint,
                Remarks = item.Remarks,
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Breakpoint";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabBreakpointFormViewModel model)
    {
        if (id != model.Breakpoint_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabBreakpointUpdateRequestModel
            {
                Breakpoint_ID = model.Breakpoint_ID,
                Organism_Category = model.Organism_Category,
                Organism_ID = model.Organism_ID,
                Antibiotic_ID = model.Antibiotic_ID,
                Standard = model.Standard,
                Standard_Version = model.Standard_Version.Trim(),
                Method = model.Method,
                Specimen_Scope = model.Specimen_Scope,
                S_Breakpoint = model.S_Breakpoint,
                R_Breakpoint = model.R_Breakpoint,
                Remarks = model.Remarks?.Trim(),
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Breakpoint Master",
                "Edit",
                $"Updated Breakpoint #{model.Breakpoint_ID} ('{model.Standard_Version}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Breakpoint '{model.Standard_Version}' updated successfully.";
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
            ViewData["PageName"] = "Edit Breakpoint";
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
                TempData["ErrorMessage"] = "Breakpoint not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Breakpoint Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabBreakpointToggleStatusRequestModel { Breakpoint_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Breakpoint Master Status",
                "ToggleStatus",
                $"Toggled status for Breakpoint #{id} to {(status ? "Active" : "Inactive")}",
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
                "Delete Breakpoint Master",
                "Delete",
                $"Deleted Breakpoint #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Breakpoint deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabBreakpointFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var organisms = await apiClient.LookupOrganismsAsync(companyId);
        model.Organism_IDOptions = organisms.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Organism_ID }).ToList();
        var antibiotics = await apiClient.LookupAntibioticsAsync(companyId);
        model.Antibiotic_IDOptions = antibiotics.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Text, Selected = x.Id == model.Antibiotic_ID }).ToList();
    }
}
