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
public class LabSampleRejectionReasonsController(
    ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
    ILabSampleTypeApiClient sampleTypeApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? sampleTypeId = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var reasons = (await rejectionReasonApiClient.GetListAsync(status, sampleTypeId, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabSampleRejections");

            var model = new LabSampleRejectionReasonIndexViewModel
            {
                Reasons = reasons,
                SelectedSampleTypeId = sampleTypeId,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = dashboard,
                SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, sampleTypeId),
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
            ViewData["PageName"] = "Sample Rejection Reason Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();

        var model = new LabSampleRejectionReasonFormViewModel
        {
            CompanyId = companyId,
            Display_Order = 1,
            Status = true,
            SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, null)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabSampleRejectionReasonFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            model.SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, model.Applicable_Sample_Type_ID);
            return View(model);
        }

        try
        {
            var req = new LabSampleRejectionReasonCreateRequestModel
            {
                Reason_Text = model.Reason_Text,
                Applicable_Sample_Type_ID = model.Applicable_Sample_Type_ID > 0 ? model.Applicable_Sample_Type_ID : null,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                UserId = User.GetUserId()
            };

            var newId = await rejectionReasonApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Sample Rejection Reason",
                "Create",
                $"Created Lab Sample Rejection Reason #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Sample Rejection Reason created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, model.Applicable_Sample_Type_ID);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Sample Rejection Reason";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var item = await rejectionReasonApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Rejection Reason not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabSampleRejectionReasonFormViewModel
            {
                Reason_ID = item.Reason_ID,
                CompanyId = item.CompanyId,
                Reason_Text = item.Reason_Text,
                Applicable_Sample_Type_ID = item.Applicable_Sample_Type_ID,
                Display_Order = item.Display_Order,
                Status = item.Status,
                SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, item.Applicable_Sample_Type_ID)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Rejection Reason";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabSampleRejectionReasonFormViewModel model)
    {
        var companyId = User.GetCompanyId();

        if (id != model.Reason_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, model.Applicable_Sample_Type_ID);
            return View(model);
        }

        try
        {
            var req = new LabSampleRejectionReasonUpdateRequestModel
            {
                Reason_ID = model.Reason_ID,
                Reason_Text = model.Reason_Text,
                Applicable_Sample_Type_ID = model.Applicable_Sample_Type_ID > 0 ? model.Applicable_Sample_Type_ID : null,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await rejectionReasonApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Sample Rejection Reason",
                "Edit",
                $"Updated Lab Sample Rejection Reason #{model.Reason_ID}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Sample Rejection Reason updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.SampleTypeOptions = await GetActiveSampleTypeOptionsAsync(companyId, model.Applicable_Sample_Type_ID);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Rejection Reason";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await rejectionReasonApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Rejection Reason not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Sample Rejection Reason Details";
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
            var req = new LabSampleRejectionReasonToggleStatusRequestModel
            {
                Reason_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await rejectionReasonApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Sample Rejection Reason Status",
                "ToggleStatus",
                $"Toggled status for Lab Sample Rejection Reason #{id} to {(status ? "Active" : "Inactive")}",
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
            await rejectionReasonApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Sample Rejection Reason",
                "Delete",
                $"Deleted Lab Sample Rejection Reason #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Sample Rejection Reason deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task<List<SelectListItem>> GetActiveSampleTypeOptionsAsync(int companyId, int? selectedId)
    {
        try
        {
            // Only fetch sample types with status=true (isactive=1)
            var sampleTypes = await sampleTypeApiClient.GetListAsync(status: true, companyId: companyId);
            return sampleTypes.Select(st => new SelectListItem
            {
                Value = st.Sample_Type_ID.ToString(),
                Text = $"{st.Sample_Name} ({st.Sample_Code})",
                Selected = selectedId.HasValue && selectedId.Value == st.Sample_Type_ID
            }).ToList();
        }
        catch
        {
            return [];
        }
    }
}
