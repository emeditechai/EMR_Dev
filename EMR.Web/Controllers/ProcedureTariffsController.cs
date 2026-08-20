using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class ProcedureTariffsController(
    IIpdMasterApiClient apiClient,
    IProcedureTariffService tariffService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? tariffCategoryId, int? procedureId)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetProcedureTariffsAsync(branchId, tariffCategoryId, procedureId, companyId);
            ViewBag.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId);
            ViewBag.ProcedureOptions = await tariffService.GetProcedureOptionsAsync(procedureId, branchId);
            ViewBag.SelectedTariffCategoryId = tariffCategoryId;
            ViewBag.SelectedProcedureId = procedureId;
            return View(list);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? tariffCategoryId = null, int? procedureId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var isLocked = procedureId.HasValue && procedureId.Value > 0;

        var model = new ProcedureTariffFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            TariffCategoryId = tariffCategoryId ?? 0,
            ProcedureId = procedureId ?? 0,
            IsProcedureLocked = isLocked,
            EffectiveFrom = DateTime.Today,
            TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId),
            ProcedureOptions = await tariffService.GetProcedureOptionsAsync(procedureId, branchId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ProcedureTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await tariffService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.ProcedureId))
            ModelState.AddModelError(string.Empty, "An active tariff rate already exists for this Tariff Category and Procedure. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.ProcedureOptions = await tariffService.GetProcedureOptionsAsync(model.ProcedureId, branchId);
            return View(model);
        }

        var newId = await tariffService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "ProcedureTariffs.Create",
            $"Created procedure tariff: Procedure ID {model.ProcedureId}, Tariff {model.TariffCategoryId}, Total: {model.TotalRate:C} [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "Procedure Tariff created successfully.";
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
    public async Task<IActionResult> Edit(ProcedureTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await tariffService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.ProcedureId, model.ProcedureTariffId))
            ModelState.AddModelError(string.Empty, "Another active tariff rate already exists for this Tariff Category and Procedure. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.ProcedureOptions = await tariffService.GetProcedureOptionsAsync(model.ProcedureId, branchId);
            return View(model);
        }

        var updated = await tariffService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "ProcedureTariffs.Edit",
            $"Updated procedure tariff: Procedure ID {model.ProcedureId}, Total: {model.TotalRate:C} [ID: {model.ProcedureTariffId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "Procedure Tariff updated successfully.";
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

        // If currently inactive, check if another is active
        if (!entity.IsActive)
        {
            var hasActive = await tariffService.HasActiveTariffAsync(entity.BranchId, entity.TariffCategoryId, entity.ProcedureId, entity.ProcedureTariffId);
            if (hasActive)
            {
                TempData["ErrorMessage"] = "Cannot activate: An active tariff rate already exists for this Tariff Category and Procedure. Only one rate can be active at a time.";
                return RedirectToAction(nameof(Index));
            }
        }

        await tariffService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "ProcedureTariffs.ToggleStatus",
            $"Toggled active status for procedure tariff [ID: {id}]",
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

        await auditLogService.LogAsync("MasterData", "ProcedureTariffs.Delete",
            $"Deleted procedure tariff [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = "Procedure Tariff deleted successfully.";
        return RedirectToAction(nameof(Index));
    }
}
