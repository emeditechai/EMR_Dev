using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class OtEquipmentsController(
    IIpdMasterApiClient apiClient,
    IOtEquipmentService equipmentService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? otId)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetOtEquipmentsAsync(branchId, otId, companyId);
            ViewBag.OtOptions = await equipmentService.GetOtOptionsAsync(otId, branchId);
            ViewBag.SelectedOtId = otId;
            return View(list);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? otId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var isLocked = otId.HasValue && otId.Value > 0;

        var model = new OtEquipmentFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            OtId = otId ?? 0,
            IsOtLocked = isLocked,
            OtOptions = await equipmentService.GetOtOptionsAsync(otId, branchId),
            EquipmentTypeOptions = equipmentService.GetEquipmentTypeOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(OtEquipmentFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await equipmentService.IsCodeExistsAsync(model.EquipmentCode, branchId))
            ModelState.AddModelError(nameof(model.EquipmentCode), "An equipment with this code already exists in your branch.");

        if (model.CalibrationRequired && model.CalibrationDueDate.HasValue && model.LastCalibrationDate.HasValue && model.CalibrationDueDate.Value < model.LastCalibrationDate.Value)
            ModelState.AddModelError(nameof(model.CalibrationDueDate), "Calibration Due Date cannot be earlier than Last Calibration Date.");

        if (!ModelState.IsValid)
        {
            model.OtOptions = await equipmentService.GetOtOptionsAsync(model.OtId, branchId);
            model.EquipmentTypeOptions = equipmentService.GetEquipmentTypeOptions(model.EquipmentType);
            return View(model);
        }

        var newId = await equipmentService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtEquipments.Create",
            $"Created OT Equipment: {model.EquipmentName} ({model.EquipmentCode}) for OT {model.OtId} [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Equipment '{model.EquipmentName}' added successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await equipmentService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(OtEquipmentFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await equipmentService.IsCodeExistsAsync(model.EquipmentCode, branchId, model.EquipmentId))
            ModelState.AddModelError(nameof(model.EquipmentCode), "An equipment with this code already exists in your branch.");

        if (model.CalibrationRequired && model.CalibrationDueDate.HasValue && model.LastCalibrationDate.HasValue && model.CalibrationDueDate.Value < model.LastCalibrationDate.Value)
            ModelState.AddModelError(nameof(model.CalibrationDueDate), "Calibration Due Date cannot be earlier than Last Calibration Date.");

        if (!ModelState.IsValid)
        {
            model.OtOptions = await equipmentService.GetOtOptionsAsync(model.OtId, branchId);
            model.EquipmentTypeOptions = equipmentService.GetEquipmentTypeOptions(model.EquipmentType);
            return View(model);
        }

        var updated = await equipmentService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "OtEquipments.Edit",
            $"Updated OT Equipment: {model.EquipmentName} ({model.EquipmentCode}) [ID: {model.EquipmentId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Equipment '{model.EquipmentName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await equipmentService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await equipmentService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await equipmentService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtEquipments.ToggleStatus",
            $"Toggled active status for equipment: {entity.EquipmentName} ({entity.EquipmentCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Status updated for '{entity.EquipmentName}'.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await equipmentService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await equipmentService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtEquipments.Delete",
            $"Deleted OT Equipment: {entity.EquipmentName} ({entity.EquipmentCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Equipment '{entity.EquipmentName}' removed.";
        return RedirectToAction(nameof(Index));
    }
}
