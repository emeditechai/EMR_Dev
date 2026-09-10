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
public class LabSampleRejectionsController(
    ILabSampleRejectionApiClient sampleRejectionApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var rejections = (await sampleRejectionApiClient.GetListAsync(status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabSampleRejections");

            var model = new LabSampleRejectionIndexViewModel
            {
                Rejections = rejections,
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
            ViewData["PageName"] = "Sample Rejection Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var companyId = User.GetCompanyId();

        var model = new LabSampleRejectionFormViewModel
        {
            CompanyId = companyId,
            Display_Order = 1,
            Status = true
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabSampleRejectionFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        try
        {
            var req = new LabSampleRejectionCreateRequestModel
            {
                Rejection_Reason = model.Rejection_Reason,
                Description = model.Description,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                UserId = User.GetUserId()
            };

            var newId = await sampleRejectionApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Sample Rejection",
                "Create",
                $"Created Lab Sample Rejection '{model.Rejection_Reason}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Sample Rejection reason '{model.Rejection_Reason}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Sample Rejection";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await sampleRejectionApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Rejection reason not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabSampleRejectionFormViewModel
            {
                Rejection_ID = item.Rejection_ID,
                CompanyId = item.CompanyId,
                Rejection_Code = item.Rejection_Code,
                Rejection_Reason = item.Rejection_Reason,
                Description = item.Description,
                Display_Order = item.Display_Order,
                Status = item.Status
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Rejection";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabSampleRejectionFormViewModel model)
    {
        if (id != model.Rejection_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        try
        {
            var req = new LabSampleRejectionUpdateRequestModel
            {
                Rejection_ID = model.Rejection_ID,
                Rejection_Reason = model.Rejection_Reason,
                Description = model.Description,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await sampleRejectionApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Sample Rejection",
                "Edit",
                $"Updated Lab Sample Rejection #{model.Rejection_ID} ('{model.Rejection_Reason}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Sample Rejection reason '{model.Rejection_Reason}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Rejection";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await sampleRejectionApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Rejection reason not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Sample Rejection Details";
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
            var req = new LabSampleRejectionToggleStatusRequestModel
            {
                Rejection_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await sampleRejectionApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Sample Rejection Status",
                "ToggleStatus",
                $"Toggled status for Lab Sample Rejection #{id} to {(status ? "Active" : "Inactive")}",
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
            await sampleRejectionApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Sample Rejection",
                "Delete",
                $"Deleted Lab Sample Rejection #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Sample Rejection reason deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }
}
