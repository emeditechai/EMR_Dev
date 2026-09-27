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
public class LabAntibioticsController(
    ILabAntibioticApiClient apiClient,
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
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabAntibiotics");
            var model = new LabAntibioticIndexViewModel
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
            ViewData["PageName"] = "Antibiotic Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabAntibioticFormViewModel { CompanyId = User.GetCompanyId(), Status = true };
        try
        {
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Antibiotic";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabAntibioticFormViewModel model)
    {
        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabAntibioticCreateRequestModel
            {
                Antibiotic_Name = model.Antibiotic_Name.Trim(),
                Abbreviation = model.Abbreviation?.Trim(),
                Antibiotic_Class = model.Antibiotic_Class,
                Route = model.Route,
                WHONET_Code = model.WHONET_Code?.Trim(),
                Description = model.Description?.Trim(),
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };
            var newId = await apiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Antibiotic Master",
                "Create",
                $"Created Antibiotic '{model.Antibiotic_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Antibiotic '{model.Antibiotic_Name}' created successfully.";
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
            ViewData["PageName"] = "Create Antibiotic";
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
                TempData["ErrorMessage"] = "Antibiotic not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabAntibioticFormViewModel
            {
                Antibiotic_ID = item.Antibiotic_ID,
                CompanyId = item.CompanyId,
                Antibiotic_Code = item.Antibiotic_Code,
                Antibiotic_Name = item.Antibiotic_Name,
                Abbreviation = item.Abbreviation,
                Antibiotic_Class = item.Antibiotic_Class,
                Route = item.Route,
                WHONET_Code = item.WHONET_Code,
                Description = item.Description,
                Status = item.Status
            };
            await PopulateLookupsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Antibiotic";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabAntibioticFormViewModel model)
    {
        if (id != model.Antibiotic_ID)
            return BadRequest();

        try
        {
            if (!ModelState.IsValid)
            {
                await PopulateLookupsAsync(model);
                return View(model);
            }

            var req = new LabAntibioticUpdateRequestModel
            {
                Antibiotic_ID = model.Antibiotic_ID,
                Antibiotic_Name = model.Antibiotic_Name.Trim(),
                Abbreviation = model.Abbreviation?.Trim(),
                Antibiotic_Class = model.Antibiotic_Class,
                Route = model.Route,
                WHONET_Code = model.WHONET_Code?.Trim(),
                Description = model.Description?.Trim(),
                Status = model.Status,
                UserId = User.GetUserId()
            };
            await apiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Antibiotic Master",
                "Edit",
                $"Updated Antibiotic #{model.Antibiotic_ID} ('{model.Antibiotic_Name}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Antibiotic '{model.Antibiotic_Name}' updated successfully.";
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
            ViewData["PageName"] = "Edit Antibiotic";
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
                TempData["ErrorMessage"] = "Antibiotic not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Antibiotic Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await apiClient.ToggleStatusAsync(new LabAntibioticToggleStatusRequestModel { Antibiotic_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync(
                "Toggle Antibiotic Master Status",
                "ToggleStatus",
                $"Toggled status for Antibiotic #{id} to {(status ? "Active" : "Inactive")}",
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
                "Delete Antibiotic Master",
                "Delete",
                $"Deleted Antibiotic #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Antibiotic deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateLookupsAsync(LabAntibioticFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        await Task.CompletedTask;
    }
}
