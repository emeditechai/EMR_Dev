using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class ShiftsController(
    IShiftMasterApiClient shiftApiClient,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = (await shiftApiClient.GetListAsync(branchId, status, search, companyId)).ToList();

            var model = new ShiftMasterIndexViewModel
            {
                ShiftList = list,
                SelectedBranchId = branchId,
                SelectedStatus = status,
                SearchTerm = search,
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
            ViewData["PageName"] = "Shift Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new ShiftMasterFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Branch_ID = User.GetCurrentBranchId() ?? 1,
            StartTime = new TimeSpan(7, 0, 0),
            EndTime = new TimeSpan(15, 0, 0),
            GraceTimeMinutes = 15,
            BreakDurationMinutes = 30,
            IsNightShift = false,
            Status = true
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ShiftMasterFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            var newId = await shiftApiClient.CreateAsync(model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "ShiftMaster.Create",
                $"Created Shift: {model.ShiftName} ({model.ShiftCode}) [{model.StartTime} - {model.EndTime}] [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"Shift '{model.ShiftName}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var entity = await shiftApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            var model = new ShiftMasterFormViewModel
            {
                ShiftMaster_ID = entity.ShiftMaster_ID,
                CompanyId = entity.CompanyId,
                Branch_ID = entity.Branch_ID,
                ShiftCode = entity.ShiftCode,
                ShiftName = entity.ShiftName,
                StartTime = entity.StartTime,
                EndTime = entity.EndTime,
                GraceTimeMinutes = entity.GraceTimeMinutes,
                BreakDurationMinutes = entity.BreakDurationMinutes,
                IsNightShift = entity.IsNightShift,
                Status = entity.Status
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Shift Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, ShiftMasterFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;
        model.ShiftMaster_ID = id;

        if (!ModelState.IsValid)
            return View(model);

        try
        {
            await shiftApiClient.UpdateAsync(id, model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "ShiftMaster.Edit",
                $"Updated Shift: {model.ShiftName} ({model.ShiftCode}) [{model.StartTime} - {model.EndTime}] [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = $"Shift '{model.ShiftName}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var entity = await shiftApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            return View(entity);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Shift Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await shiftApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "ShiftMaster.ToggleStatus",
                $"Toggled status for Shift [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Shift status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to update status: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await shiftApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "ShiftMaster.Delete",
                $"Deleted Shift record [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Shift record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete shift: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }
}
