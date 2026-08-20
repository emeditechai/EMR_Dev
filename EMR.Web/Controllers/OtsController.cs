using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class OtsController(
    IIpdMasterApiClient apiClient,
    IOtService otService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? floorId, string? otType)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetOtsAsync(branchId, floorId, otType, companyId);
            ViewBag.FloorOptions = await otService.GetFloorOptionsAsync(floorId, branchId);
            ViewBag.OtTypeOptions = otService.GetOtTypeOptions(otType);
            ViewBag.SelectedFloorId = floorId;
            ViewBag.SelectedOtType = otType;
            return View(list);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        var model = new OtFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            FloorOptions = await otService.GetFloorOptionsAsync(null, branchId),
            OtTypeOptions = otService.GetOtTypeOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(OtFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await otService.IsCodeExistsAsync(model.OtCode, branchId))
            ModelState.AddModelError(nameof(model.OtCode), "An Operation Theatre with this code already exists in your branch.");

        if (!ModelState.IsValid)
        {
            model.FloorOptions = await otService.GetFloorOptionsAsync(model.FloorId, branchId);
            model.OtTypeOptions = otService.GetOtTypeOptions(model.OtType);
            return View(model);
        }

        var newId = await otService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Ots.Create",
            $"Created OT: {model.OtName} ({model.OtCode}) [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Operation Theatre '{model.OtName}' created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await otService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(OtFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await otService.IsCodeExistsAsync(model.OtCode, branchId, model.OtId))
            ModelState.AddModelError(nameof(model.OtCode), "An Operation Theatre with this code already exists in your branch.");

        if (!ModelState.IsValid)
        {
            model.FloorOptions = await otService.GetFloorOptionsAsync(model.FloorId, branchId);
            model.OtTypeOptions = otService.GetOtTypeOptions(model.OtType);
            return View(model);
        }

        var updated = await otService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "Ots.Edit",
            $"Updated OT: {model.OtName} ({model.OtCode}) [ID: {model.OtId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Operation Theatre '{model.OtName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await otService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var equipments = await otService.GetEquipmentsByOtIdAsync(id);
        var tariffs = await otService.GetTariffsByOtIdAsync(id);

        var model = new OtDetailsViewModel
        {
            Ot = entity,
            Equipments = equipments,
            Tariffs = tariffs
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await otService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await otService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Ots.ToggleStatus",
            $"Toggled active status for OT: {entity.OtName} ({entity.OtCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Status updated for '{entity.OtName}'.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await otService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await otService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Ots.Delete",
            $"Deleted OT: {entity.OtName} ({entity.OtCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Operation Theatre '{entity.OtName}' removed.";
        return RedirectToAction(nameof(Index));
    }
}
