using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

/// <summary>Misc Charges Master (Master > Lab Master, SQLScripts/2239): Home Collection and other misc charges billed
/// with investigations. Access per action: page MASTER.LABMISCCHARGES (VIEW / ADD / DETAILS / EDIT / STATUS / DELETE).</summary>
[Authorize]
public class LabMiscChargesController(
    ILabMiscChargeApiClient miscChargeApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(string? chargeType = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        if (!string.IsNullOrWhiteSpace(chargeType) && !LabMiscChargeTypes.All.Contains(chargeType)) chargeType = null;

        try
        {
            var model = new LabMiscChargeIndexViewModel
            {
                Charges = (await miscChargeApiClient.GetListAsync(status, chargeType, search, companyId)).ToList(),
                SelectedChargeType = chargeType,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = await dashboardService.GetDashboardAsync(companyId, "LabMiscCharges"),
                ChargeTypeOptions = ChargeTypeOptions(chargeType),
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
            ViewData["PageName"] = "Misc Charges Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create() => View(new LabMiscChargeFormViewModel { ChargeTypeOptions = ChargeTypeOptions(LabMiscChargeTypes.Misc) });

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabMiscChargeFormViewModel model)
    {
        NormaliseGst(model);
        if (!ModelState.IsValid)
        {
            model.ChargeTypeOptions = ChargeTypeOptions(model.Charge_Type);
            return View(model);
        }

        try
        {
            var req = ToRequest(model);
            req.CompanyId = User.GetCompanyId();
            var newId = await miscChargeApiClient.CreateAsync(req);

            await auditLogService.LogAsync("Create Lab Misc Charge", "Create",
                $"Created Misc Charge #{newId} '{model.Charge_Name}' ({model.Charge_Type}) ₹{model.Amount:N2}", User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Misc Charge created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.ChargeTypeOptions = ChargeTypeOptions(model.Charge_Type);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Misc Charge";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await miscChargeApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Misc Charge not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(new LabMiscChargeFormViewModel
            {
                Misc_Charge_ID = item.Misc_Charge_ID,
                Charge_Name = item.Charge_Name,
                Charge_Type = item.Charge_Type,
                Amount = item.Amount,
                Is_Discountable = item.Is_Discountable,
                Is_GST_Required = item.Is_GST_Required,
                GST_Percentage = item.GST_Percentage,
                Description = item.Description,
                Display_Order = item.Display_Order,
                Status = item.Status,
                ChargeTypeOptions = ChargeTypeOptions(item.Charge_Type)
            });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Misc Charge";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabMiscChargeFormViewModel model)
    {
        if (id != model.Misc_Charge_ID) return BadRequest();
        NormaliseGst(model);
        if (!ModelState.IsValid)
        {
            model.ChargeTypeOptions = ChargeTypeOptions(model.Charge_Type);
            return View(model);
        }

        try
        {
            await miscChargeApiClient.UpdateAsync(ToRequest(model));

            await auditLogService.LogAsync("Update Lab Misc Charge", "Edit",
                $"Updated Misc Charge #{model.Misc_Charge_ID} '{model.Charge_Name}' ({model.Charge_Type}) ₹{model.Amount:N2}", User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = "Misc Charge updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.ChargeTypeOptions = ChargeTypeOptions(model.Charge_Type);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Misc Charge";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await miscChargeApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Misc Charge not found.";
                return RedirectToAction(nameof(Index));
            }
            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Misc Charge Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            await miscChargeApiClient.ToggleStatusAsync(new LabMiscChargeToggleStatusRequestModel { Misc_Charge_ID = id, Status = status, UserId = User.GetUserId() });
            await auditLogService.LogAsync("Toggle Lab Misc Charge Status", "ToggleStatus",
                $"Misc Charge #{id} set to {(status ? "Active" : "Inactive")}", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
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
            await miscChargeApiClient.DeleteAsync(id, User.GetUserId());
            await auditLogService.LogAsync("Delete Lab Misc Charge", "Delete", $"Deleted Misc Charge #{id}", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Misc Charge deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    // GST % only counts when GST is required: otherwise it is cleared and its checks do not apply
    private void NormaliseGst(LabMiscChargeFormViewModel model)
    {
        if (model.Is_GST_Required) return;
        model.GST_Percentage = null;
        ModelState.Remove(nameof(LabMiscChargeFormViewModel.GST_Percentage));
    }

    private LabMiscChargeSaveRequestModel ToRequest(LabMiscChargeFormViewModel m) => new()
    {
        Misc_Charge_ID = m.Misc_Charge_ID,
        Charge_Name = m.Charge_Name.Trim(),
        Charge_Type = m.Charge_Type,
        Amount = m.Amount ?? 0,
        Is_Discountable = m.Is_Discountable,
        Is_GST_Required = m.Is_GST_Required,
        GST_Percentage = m.Is_GST_Required ? m.GST_Percentage : null,
        Description = string.IsNullOrWhiteSpace(m.Description) ? null : m.Description.Trim(),
        Display_Order = m.Display_Order,
        Status = m.Status,
        UserId = User.GetUserId()
    };

    private static List<SelectListItem> ChargeTypeOptions(string? selected) =>
        LabMiscChargeTypes.All.Select(t => new SelectListItem { Value = t, Text = t, Selected = t == selected }).ToList();
}
