using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class OtTariffsController(
    IIpdMasterApiClient apiClient,
    IOtTariffService tariffService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? tariffCategoryId, int? otId)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetOtTariffsAsync(branchId, tariffCategoryId, otId, companyId);
            ViewBag.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId);
            ViewBag.OtOptions = await tariffService.GetOtOptionsAsync(otId, branchId);
            ViewBag.SelectedTariffCategoryId = tariffCategoryId;
            ViewBag.SelectedOtId = otId;
            return View(list);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? tariffCategoryId = null, int? otId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var isLocked = otId.HasValue && otId.Value > 0;

        var model = new OtTariffFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            TariffCategoryId = tariffCategoryId ?? 0,
            OtId = otId ?? 0,
            IsOtLocked = isLocked,
            EffectiveFrom = DateTime.Today,
            TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId),
            OtOptions = await tariffService.GetOtOptionsAsync(otId, branchId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(OtTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await tariffService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.OtId))
            ModelState.AddModelError(string.Empty, "An active tariff rate already exists for this Tariff Category and Operation Theatre. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.OtOptions = await tariffService.GetOtOptionsAsync(model.OtId, branchId);
            return View(model);
        }

        var newId = await tariffService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtTariffs.Create",
            $"Created OT tariff: OT ID {model.OtId}, Tariff {model.TariffCategoryId}, Total: {model.TotalRate:C} [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "OT Tariff rate created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await tariffService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(OtTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await tariffService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.OtId, model.OtTariffId))
            ModelState.AddModelError(string.Empty, "Another active tariff rate already exists for this Tariff Category and Operation Theatre. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.OtOptions = await tariffService.GetOtOptionsAsync(model.OtId, branchId);
            return View(model);
        }

        var updated = await tariffService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "OtTariffs.Edit",
            $"Updated OT tariff: OT ID {model.OtId}, Total: {model.TotalRate:C} [ID: {model.OtTariffId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "OT Tariff updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await tariffService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await tariffService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        if (!entity.IsActive)
        {
            var hasActive = await tariffService.HasActiveTariffAsync(entity.BranchId, entity.TariffCategoryId, entity.OtId, entity.OtTariffId);
            if (hasActive)
            {
                TempData["ErrorMessage"] = "Cannot activate: An active tariff rate already exists for this Tariff Category and Operation Theatre. Only one rate can be active at a time.";
                return RedirectToAction(nameof(Index));
            }
        }

        await tariffService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtTariffs.ToggleStatus",
            $"Toggled active status for OT tariff [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = "Status updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await tariffService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await tariffService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "OtTariffs.Delete",
            $"Deleted OT tariff [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = "OT Tariff deleted successfully.";
        return RedirectToAction(nameof(Index));
    }
}
