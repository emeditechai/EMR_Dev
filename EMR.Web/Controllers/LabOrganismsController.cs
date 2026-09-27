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
public class LabOrganismsController(
    ILabOrganismApiClient apiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var items = (await apiClient.GetListAsync(status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabOrganisms");
            var model = new LabOrganismIndexViewModel
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
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Organism Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabOrganismFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Organism";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabOrganismFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabOrganismCreateRequestModel
            {
                Organism_Name = model.Organism_Name.Trim(),
                Gram_Type = model.Gram_Type,
                Organism_Type = model.Organism_Type,
                Organism_Category = model.Organism_Category,
                WHONET_Code = model.WHONET_Code?.Trim(),
                Description = model.Description?.Trim(),
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Organism Master",
                "Create",
                $"Created Organism '{model.Organism_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Organism '{model.Organism_Name}' created successfully.";
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
            ViewData["PageName"] = "Create Organism";
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
                TempData["ErrorMessage"] = "Organism not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabOrganismFormViewModel
            {
                Organism_ID = item.Organism_ID,
                CompanyId = item.CompanyId,
                Organism_Code = item.Organism_Code,
                Organism_Name = item.Organism_Name,
                Gram_Type = item.Gram_Type,
                Organism_Type = item.Organism_Type,
                Organism_Category = item.Organism_Category,
                WHONET_Code = item.WHONET_Code,
                Description = item.Description,
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Organism";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabOrganismFormViewModel model)
    {
        if (id != model.Organism_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabOrganismUpdateRequestModel
            {
                Organism_ID = model.Organism_ID,
                Organism_Name = model.Organism_Name.Trim(),
                Gram_Type = model.Gram_Type,
                Organism_Type = model.Organism_Type,
                Organism_Category = model.Organism_Category,
                WHONET_Code = model.WHONET_Code?.Trim(),
                Description = model.Description?.Trim(),
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Organism Master",
                "Edit",
                $"Updated Organism #{model.Organism_ID} ('{model.Organism_Name}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Organism '{model.Organism_Name}' updated successfully.";
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
            ViewData["PageName"] = "Edit Organism";
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
                TempData["ErrorMessage"] = "Organism not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Organism Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabOrganismToggleStatusRequestModel { Organism_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Organism Master Status",
                "ToggleStatus",
                $"Toggled status for Organism #{id} to {(status ? "Active" : "Inactive")}",
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
                "Delete Organism Master",
                "Delete",
                $"Deleted Organism #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Organism deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabOrganismFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        await Task.CompletedTask;
    }
}
