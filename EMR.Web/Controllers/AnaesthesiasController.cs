using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class AnaesthesiasController(
    IIpdMasterApiClient apiClient,
    IAnaesthesiaService anaesthesiaService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? procedureId, int? anaesthesiaTypeId, string tab = "rates")
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var rates = (await apiClient.GetAnaesthesiaRatesAsync(branchId, procedureId, anaesthesiaTypeId, companyId)).ToList();
            var types = (await apiClient.GetAnaesthesiaTypesAsync(branchId, companyId)).ToList();

            var model = new AnaesthesiaUnifiedViewModel
            {
                Rates = rates,
                Types = types,
                SelectedProcedureId = procedureId,
                SelectedAnaesthesiaTypeId = anaesthesiaTypeId,
                ActiveTab = string.Equals(tab, "types", StringComparison.OrdinalIgnoreCase) ? "types" : "rates",
                ProcedureOptions = await anaesthesiaService.GetProcedureOptionsAsync(procedureId, branchId),
                AnaesthesiaTypeOptions = await anaesthesiaService.GetAnaesthesiaTypeOptionsAsync(anaesthesiaTypeId, branchId)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    // ── Type Actions ──────────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateType(AnaesthesiaTypeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await anaesthesiaService.IsTypeCodeExistsAsync(model.TypeCode, branchId))
        {
            TempData["Error"] = $"Anaesthesia Type code '{model.TypeCode}' already exists.";
            return RedirectToAction(nameof(Index), new { tab = "types" });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please provide all required fields for Anaesthesia Type.";
            return RedirectToAction(nameof(Index), new { tab = "types" });
        }

        var newId = await anaesthesiaService.CreateTypeAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaType.Create",
            $"Created Anaesthesia Type: {model.TypeName} ({model.TypeCode}) [ID: {newId}]",
            branchId: branchId);

        TempData["Success"] = $"Anaesthesia Type '{model.TypeName}' created successfully.";
        return RedirectToAction(nameof(Index), new { tab = "types" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> EditType(AnaesthesiaTypeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await anaesthesiaService.IsTypeCodeExistsAsync(model.TypeCode, branchId, model.AnaesthesiaTypeId))
        {
            TempData["Error"] = $"Anaesthesia Type code '{model.TypeCode}' already exists.";
            return RedirectToAction(nameof(Index), new { tab = "types" });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please verify all fields for Anaesthesia Type.";
            return RedirectToAction(nameof(Index), new { tab = "types" });
        }

        var updated = await anaesthesiaService.UpdateTypeAsync(model, User.GetUserId());
        if (!updated)
        {
            TempData["Error"] = "Anaesthesia Type not found.";
            return RedirectToAction(nameof(Index), new { tab = "types" });
        }

        await auditLogService.LogAsync("MasterData", "AnaesthesiaType.Edit",
            $"Updated Anaesthesia Type: {model.TypeName} ({model.TypeCode}) [ID: {model.AnaesthesiaTypeId}]",
            branchId: branchId);

        TempData["Success"] = $"Anaesthesia Type '{model.TypeName}' updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "types" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleTypeStatus(int id)
    {
        var entity = await anaesthesiaService.GetTypeByIdAsync(id);
        if (entity is null) return NotFound();

        await anaesthesiaService.ToggleTypeActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaType.ToggleStatus",
            $"Toggled active status for Anaesthesia Type: {entity.TypeName} ({entity.TypeCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = $"Status updated for '{entity.TypeName}'.";
        return RedirectToAction(nameof(Index), new { tab = "types" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteType(int id)
    {
        var entity = await anaesthesiaService.GetTypeByIdAsync(id);
        if (entity is null) return NotFound();

        await anaesthesiaService.DeleteTypeAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaType.Delete",
            $"Deleted Anaesthesia Type: {entity.TypeName} ({entity.TypeCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = $"Anaesthesia Type '{entity.TypeName}' removed.";
        return RedirectToAction(nameof(Index), new { tab = "types" });
    }

    [HttpGet]
    public async Task<IActionResult> GetTypeJson(int id)
    {
        var model = await anaesthesiaService.GetTypeFormModelByIdAsync(id);
        if (model is null) return NotFound();
        return Json(model);
    }

    // ── Rate Actions ──────────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateRate(AnaesthesiaRateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
        {
            TempData["Error"] = "Effective To date cannot be earlier than Effective From date.";
            return RedirectToAction(nameof(Index), new { tab = "rates", procedureId = model.ProcedureId, anaesthesiaTypeId = model.AnaesthesiaTypeId });
        }

        if (model.IsActive && await anaesthesiaService.HasActiveRateAsync(branchId, model.ProcedureId, model.AnaesthesiaTypeId))
        {
            TempData["Error"] = "An active anaesthesia rate already exists for this Procedure and Anaesthesia Type. Only one rate can be active at a time.";
            return RedirectToAction(nameof(Index), new { tab = "rates", procedureId = model.ProcedureId, anaesthesiaTypeId = model.AnaesthesiaTypeId });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please fill in all required rate fields.";
            return RedirectToAction(nameof(Index), new { tab = "rates" });
        }

        var newId = await anaesthesiaService.CreateRateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaRate.Create",
            $"Created Anaesthesia Rate: Proc {model.ProcedureId}, Type {model.AnaesthesiaTypeId}, Total {model.TotalRate:C} [ID: {newId}]",
            branchId: branchId);

        TempData["Success"] = "Anaesthesia rate package configured successfully.";
        return RedirectToAction(nameof(Index), new { tab = "rates", procedureId = model.ProcedureId, anaesthesiaTypeId = model.AnaesthesiaTypeId });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> EditRate(AnaesthesiaRateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (model.EffectiveTo.HasValue && model.EffectiveTo.Value < model.EffectiveFrom)
        {
            TempData["Error"] = "Effective To date cannot be earlier than Effective From date.";
            return RedirectToAction(nameof(Index), new { tab = "rates" });
        }

        if (model.IsActive && await anaesthesiaService.HasActiveRateAsync(branchId, model.ProcedureId, model.AnaesthesiaTypeId, model.AnaesthesiaRateId))
        {
            TempData["Error"] = "Another active anaesthesia rate already exists for this Procedure and Anaesthesia Type. Only one rate can be active at a time.";
            return RedirectToAction(nameof(Index), new { tab = "rates" });
        }

        if (!ModelState.IsValid)
        {
            TempData["Error"] = "Please verify all rate fields.";
            return RedirectToAction(nameof(Index), new { tab = "rates" });
        }

        var updated = await anaesthesiaService.UpdateRateAsync(model, User.GetUserId());
        if (!updated)
        {
            TempData["Error"] = "Anaesthesia rate record not found.";
            return RedirectToAction(nameof(Index), new { tab = "rates" });
        }

        await auditLogService.LogAsync("MasterData", "AnaesthesiaRate.Edit",
            $"Updated Anaesthesia Rate: Proc {model.ProcedureId}, Type {model.AnaesthesiaTypeId}, Total {model.TotalRate:C} [ID: {model.AnaesthesiaRateId}]",
            branchId: branchId);

        TempData["Success"] = "Anaesthesia rate updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "rates" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleRateStatus(int id)
    {
        var entity = await anaesthesiaService.GetRateByIdAsync(id);
        if (entity is null) return NotFound();

        if (!entity.IsActive)
        {
            var hasActive = await anaesthesiaService.HasActiveRateAsync(entity.BranchId, entity.ProcedureId, entity.AnaesthesiaTypeId, entity.AnaesthesiaRateId);
            if (hasActive)
            {
                TempData["Error"] = "Cannot activate: An active rate already exists for this Procedure and Anaesthesia Type.";
                return RedirectToAction(nameof(Index), new { tab = "rates" });
            }
        }

        await anaesthesiaService.ToggleRateActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaRate.ToggleStatus",
            $"Toggled active status for Anaesthesia Rate [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = "Status updated successfully.";
        return RedirectToAction(nameof(Index), new { tab = "rates" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteRate(int id)
    {
        var entity = await anaesthesiaService.GetRateByIdAsync(id);
        if (entity is null) return NotFound();

        await anaesthesiaService.DeleteRateAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "AnaesthesiaRate.Delete",
            $"Deleted Anaesthesia Rate [ID: {id}]",
            branchId: entity.BranchId);

        TempData["Success"] = "Anaesthesia rate configuration deleted successfully.";
        return RedirectToAction(nameof(Index), new { tab = "rates" });
    }

    [HttpGet]
    public async Task<IActionResult> GetRateJson(int id)
    {
        var model = await anaesthesiaService.GetRateFormModelByIdAsync(id);
        if (model is null) return NotFound();
        return Json(model);
    }
}
