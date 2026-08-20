using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class HospitalServiceRatesController(
    IHospitalServiceRateService rateService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(int? tariffCategoryId = null, int? hospitalServiceId = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetHospitalServiceRatesAsync(branchId, tariffCategoryId, hospitalServiceId, companyId);

            ViewBag.TariffCategoryId = tariffCategoryId;
            ViewBag.HospitalServiceId = hospitalServiceId;
            ViewBag.TariffCategoryOptions = await rateService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId);
            ViewBag.HospitalServiceOptions = await rateService.GetHospitalServiceOptionsAsync(hospitalServiceId, branchId);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Hospital Service Rate Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? tariffCategoryId = null, int? hospitalServiceId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var isLocked = hospitalServiceId.HasValue && hospitalServiceId.Value > 0;

        var model = new HospitalServiceRateFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            TariffCategoryId = tariffCategoryId ?? 0,
            HospitalServiceId = hospitalServiceId ?? 0,
            IsServiceLocked = isLocked,
            EffectiveFrom = DateTime.Today,
            TariffCategoryOptions = await rateService.GetTariffCategoryOptionsAsync(tariffCategoryId, companyId, branchId),
            HospitalServiceOptions = await rateService.GetHospitalServiceOptionsAsync(hospitalServiceId, branchId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(HospitalServiceRateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await rateService.HasActiveRateAsync(branchId, model.TariffCategoryId, model.HospitalServiceId))
            ModelState.AddModelError(string.Empty, "An active rate already exists for this Tariff Category and Hospital Service. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await rateService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.HospitalServiceOptions = await rateService.GetHospitalServiceOptionsAsync(model.HospitalServiceId, branchId);
            return View(model);
        }

        var newId = await rateService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServiceRates.Create",
            $"Created service rate: Service ID {model.HospitalServiceId}, Tariff {model.TariffCategoryId}, Rate: {model.Rate:C} [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "Hospital Service Rate created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await rateService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(HospitalServiceRateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
            ModelState.AddModelError(nameof(model.EffectiveTo), "Effective To date cannot be earlier than Effective From date.");

        if (model.IsActive && await rateService.HasActiveRateAsync(branchId, model.TariffCategoryId, model.HospitalServiceId, model.ServiceRateId))
            ModelState.AddModelError(string.Empty, "Another active rate already exists for this Tariff Category and Hospital Service. Only one rate can be active at a time.");

        if (!ModelState.IsValid)
        {
            model.TariffCategoryOptions = await rateService.GetTariffCategoryOptionsAsync(model.TariffCategoryId, companyId, branchId);
            model.HospitalServiceOptions = await rateService.GetHospitalServiceOptionsAsync(model.HospitalServiceId, branchId);
            return View(model);
        }

        var updated = await rateService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "HospitalServiceRates.Edit",
            $"Updated service rate: Service ID {model.HospitalServiceId}, Rate: {model.Rate:C} [ID: {model.ServiceRateId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = "Hospital Service Rate updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await rateService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await rateService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        // If currently inactive, we are trying to activate it
        if (!entity.IsActive)
        {
            var hasActive = await rateService.HasActiveRateAsync(entity.BranchId, entity.TariffCategoryId, entity.HospitalServiceId, entity.ServiceRateId);
            if (hasActive)
            {
                TempData["ErrorMessage"] = "Cannot activate: An active rate already exists for this Tariff Category and Hospital Service. Only one rate can be active at a time.";
                return RedirectToAction(nameof(Index));
            }
        }

        await rateService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServiceRates.ToggleStatus",
            $"Toggled active status for service rate [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = "Status updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await rateService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await rateService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServiceRates.Delete",
            $"Deleted service rate [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = "Hospital Service Rate deleted successfully.";
        return RedirectToAction(nameof(Index));
    }
}
