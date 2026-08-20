using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class IcusController(
    IIpdMasterApiClient apiClient,
    IIcuService icuService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? wardId, string? icuType, int? tariffCategoryId, int? icuId, string tab = "icus")
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var icus = (await apiClient.GetIcusAsync(branchId, wardId, icuType, companyId)).ToList();
            var tariffs = (await apiClient.GetIcuTariffsAsync(branchId, icuId, tariffCategoryId, companyId)).ToList();

            var model = new IcuUnifiedViewModel
            {
                Icus = icus,
                Tariffs = tariffs,
                SelectedWardId = wardId,
                SelectedIcuType = icuType,
                SelectedTariffCategoryId = tariffCategoryId,
                SelectedIcuId = icuId,
                ActiveTab = string.Equals(tab, "tariffs", StringComparison.OrdinalIgnoreCase) ? "tariffs" : "icus",
                WardOptions = await icuService.GetWardOptionsAsync(wardId, branchId),
                IcuTypeOptions = icuService.GetIcuTypeOptions(icuType),
                TariffCategoryOptions = await icuService.GetTariffCategoryOptionsAsync(tariffCategoryId, branchId),
                IcuOptions = await icuService.GetIcuOptionsAsync(icuId, branchId)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    // ── ICU Configuration Actions ─────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateIcu(IcuConfigurationFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await icuService.IsIcuCodeExistsAsync(model.IcuCode, branchId))
        {
            TempData["Error"] = $"ICU Code '{model.IcuCode}' already exists.";
            return RedirectToAction(nameof(Index), new { tab = "icus" });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please fill in all required ICU fields.";
            return RedirectToAction(nameof(Index), new { tab = "icus" });
        }

        var newId = await icuService.CreateIcuAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Icu.Create",
            $"Created ICU Configuration: {model.IcuName} ({model.IcuCode}) [{model.IcuType}] - {model.BedCapacity} Beds [ID: {newId}]",
            branchId: branchId);

        TempData["Success"] = $"ICU '{model.IcuName}' configured successfully.";
        return RedirectToAction(nameof(Index), new { tab = "icus" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> EditIcu(IcuConfigurationFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await icuService.IsIcuCodeExistsAsync(model.IcuCode, branchId, model.IcuId))
        {
            TempData["Error"] = $"ICU Code '{model.IcuCode}' already exists.";
            return RedirectToAction(nameof(Index), new { tab = "icus" });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please verify all ICU fields.";
            return RedirectToAction(nameof(Index), new { tab = "icus" });
        }

        var updated = await icuService.UpdateIcuAsync(model, User.GetUserId());
        if (!updated)
        {
            TempData["Error"] = "ICU Configuration not found.";
            return RedirectToAction(nameof(Index), new { tab = "icus" });
        }

        await auditLogService.LogAsync("MasterData", "Icu.Edit",
            $"Updated ICU Configuration: {model.IcuName} ({model.IcuCode}) [ID: {model.IcuId}]",
            branchId: branchId);

        TempData["Success"] = $"ICU '{model.IcuName}' updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "icus" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleIcuStatus(int id)
    {
        var entity = await icuService.GetIcuByIdAsync(id);
        if (entity is null) return NotFound();

        await icuService.ToggleIcuActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Icu.ToggleStatus",
            $"Toggled active status for ICU: {entity.IcuName} ({entity.IcuCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = $"Status updated for '{entity.IcuName}'.";
        return RedirectToAction(nameof(Index), new { tab = "icus" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteIcu(int id)
    {
        var entity = await icuService.GetIcuByIdAsync(id);
        if (entity is null) return NotFound();

        await icuService.DeleteIcuAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Icu.Delete",
            $"Deleted ICU: {entity.IcuName} ({entity.IcuCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = $"ICU '{entity.IcuName}' removed.";
        return RedirectToAction(nameof(Index), new { tab = "icus" });
    }

    [HttpGet]
    public async Task<IActionResult> GetIcuJson(int id)
    {
        var model = await icuService.GetIcuFormModelByIdAsync(id);
        if (model is null) return NotFound();
        return Json(model);
    }

    // ── Dynamic ICU Tariff Actions ────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateTariff(IcuTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
        {
            TempData["Error"] = "Effective To date cannot be earlier than Effective From date.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs", icuId = model.IcuId });
        }

        if (model.IsActive && await icuService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.IcuId))
        {
            TempData["Error"] = "An active tariff package already exists for this ICU and Tariff Category. Only one package can be active at a time.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs", icuId = model.IcuId });
        }

        var validDetails = model.Details.Where(d => !string.IsNullOrWhiteSpace(d.RateHeadName)).ToList();
        if (validDetails.Count == 0)
        {
            TempData["Error"] = "Please add at least one dynamic rate head component to the tariff package.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs", icuId = model.IcuId });
        }
        model.Details = validDetails;

        var newId = await icuService.CreateTariffAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "IcuTariff.Create",
            $"Created Dynamic ICU Tariff: ICU {model.IcuId}, Category {model.TariffCategoryId}, Total {model.TotalRate:C}, {model.Details.Count} heads [ID: {newId}]",
            branchId: branchId);

        TempData["Success"] = "Dynamic ICU Tariff package configured successfully.";
        return RedirectToAction(nameof(Index), new { tab = "tariffs", icuId = model.IcuId });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> EditTariff(IcuTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
        {
            TempData["Error"] = "Effective To date cannot be earlier than Effective From date.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs" });
        }

        if (model.IsActive && await icuService.HasActiveTariffAsync(branchId, model.TariffCategoryId, model.IcuId, model.IcuTariffId))
        {
            TempData["Error"] = "Another active tariff package already exists for this ICU and Tariff Category. Only one package can be active at a time.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs" });
        }

        var validDetails = model.Details.Where(d => !string.IsNullOrWhiteSpace(d.RateHeadName)).ToList();
        if (validDetails.Count == 0)
        {
            TempData["Error"] = "Please add at least one dynamic rate head component.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs" });
        }
        model.Details = validDetails;

        var updated = await icuService.UpdateTariffAsync(model, User.GetUserId());
        if (!updated)
        {
            TempData["Error"] = "ICU Tariff record not found.";
            return RedirectToAction(nameof(Index), new { tab = "tariffs" });
        }

        await auditLogService.LogAsync("MasterData", "IcuTariff.Edit",
            $"Updated Dynamic ICU Tariff: ICU {model.IcuId}, Category {model.TariffCategoryId}, Total {model.TotalRate:C} [ID: {model.IcuTariffId}]",
            branchId: branchId);

        TempData["Success"] = "Dynamic ICU Tariff package updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "tariffs" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleTariffStatus(int id)
    {
        var entity = await icuService.GetTariffByIdAsync(id);
        if (entity is null) return NotFound();

        if (!entity.IsActive)
        {
            var hasActive = await icuService.HasActiveTariffAsync(entity.BranchId, entity.TariffCategoryId, entity.IcuId, entity.IcuTariffId);
            if (hasActive)
            {
                TempData["Error"] = "Cannot activate: An active tariff already exists for this ICU and Tariff Category.";
                return RedirectToAction(nameof(Index), new { tab = "tariffs" });
            }
        }

        await icuService.ToggleTariffActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "IcuTariff.ToggleStatus",
            $"Toggled active status for ICU Tariff [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = "Status updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "tariffs" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteTariff(int id)
    {
        var entity = await icuService.GetTariffByIdAsync(id);
        if (entity is null) return NotFound();

        await icuService.DeleteTariffAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "IcuTariff.Delete",
            $"Deleted ICU Tariff [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = "ICU Tariff package deleted successfully.";
        return RedirectToAction(nameof(Index), new { tab = "tariffs" });
    }

    [HttpGet]
    public async Task<IActionResult> GetTariffJson(int id)
    {
        var model = await icuService.GetTariffFormModelByIdAsync(id);
        if (model is null) return NotFound();
        return Json(model);
    }

    [HttpGet]
    public async Task<IActionResult> GetTariffViewJson(int id)
    {
        var entity = await icuService.GetTariffByIdAsync(id);
        if (entity is null) return NotFound();

        return Json(new
        {
            icuTariffId = entity.IcuTariffId,
            icuId = entity.IcuId,
            icuName = entity.Icu?.IcuName,
            icuCode = entity.Icu?.IcuCode,
            icuType = entity.Icu?.IcuType,
            wardName = entity.Icu?.Ward?.WardName,
            wardCode = entity.Icu?.Ward?.WardCode,
            wardType = entity.Icu?.Ward?.WardType,
            tariffCategoryId = entity.TariffCategoryId,
            tariffCategoryName = entity.TariffCategory?.Name,
            patientCategory = entity.TariffCategory?.PatientCategory,
            totalRate = entity.TotalRate,
            effectiveFrom = entity.EffectiveFrom.ToString("dd MMM yyyy"),
            effectiveTo = entity.EffectiveTo.HasValue ? entity.EffectiveTo.Value.ToString("dd MMM yyyy") : "Ongoing",
            description = entity.Description,
            isActive = entity.IsActive,
            createdDate = entity.CreatedDate.ToString("dd MMM yyyy hh:mm tt"),
            details = entity.Details.OrderBy(d => d.DisplayOrder).Select(d => new
            {
                rateHeadName = d.RateHeadName,
                rateHeadCode = d.RateHeadCode,
                rateAmount = d.RateAmount,
                billingFrequency = d.BillingFrequency,
                isMandatory = d.IsMandatory,
                remarks = d.Remarks,
                displayOrder = d.DisplayOrder
            }).ToList()
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetIcuViewJson(int id)
    {
        var entity = await icuService.GetIcuByIdAsync(id);
        if (entity is null) return NotFound();

        return Json(new
        {
            icuId = entity.IcuId,
            icuName = entity.IcuName,
            icuCode = entity.IcuCode,
            icuType = entity.IcuType,
            wardName = entity.Ward?.WardName,
            wardCode = entity.Ward?.WardCode,
            wardType = entity.Ward?.WardType,
            bedCapacity = entity.BedCapacity,
            ventilatorCapacity = entity.VentilatorCapacity,
            isolationCapacity = entity.IsolationCapacity,
            description = entity.Description,
            isActive = entity.IsActive,
            createdDate = entity.CreatedDate.ToString("dd MMM yyyy hh:mm tt"),
            tariffs = entity.Tariffs.Select(t => new
            {
                icuTariffId = t.IcuTariffId,
                tariffCategoryName = t.TariffCategory?.Name,
                patientCategory = t.TariffCategory?.PatientCategory,
                totalRate = t.TotalRate,
                effectiveFrom = t.EffectiveFrom.ToString("dd MMM yyyy"),
                effectiveTo = t.EffectiveTo.HasValue ? t.EffectiveTo.Value.ToString("dd MMM yyyy") : "Ongoing",
                isActive = t.IsActive,
                rateHeadsCount = t.Details.Count
            }).ToList()
        });
    }
}

