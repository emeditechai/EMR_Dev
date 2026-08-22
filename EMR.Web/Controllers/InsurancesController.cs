using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class InsurancesController(
    IInsuranceTPAApiClient insuranceApiClient,
    IInsuranceTariffApiClient tariffApiClient,
    IInsuranceTPAService insuranceService,
    IInsuranceTariffService tariffService,
    IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> InsuranceTypes = ["Insurance Company", "TPA"];
    private static readonly List<string> NetworkCategories = ["Cashless", "Reimbursement", "Both"];
    private static readonly List<string> EntitlementTypes = ["Room", "Package", "Procedure", "HospitalService", "NonPayableItem"];
    private static readonly List<string> DeductionRuleTypes = ["Standard Tariff", "Fixed Deduction (₹)", "Percentage Co-Pay (%)", "Proportional Capping (%)", "Non-Payable (100% Deducted)", "Agreed Tariff Cap (₹)"];

    [HttpGet]
    public async Task<IActionResult> Index(
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = (await insuranceApiClient.GetListAsync(branchId, type, networkCategory, status, search, companyId)).ToList();

            // Fetch tariffs to populate count badges
            try
            {
                var allTariffs = (await tariffApiClient.GetListAsync(branchId: branchId, companyId: companyId)).ToList();
                var tariffsByIns = allTariffs.GroupBy(t => t.InsuranceTPA_ID).ToDictionary(g => g.Key, g => g.ToList());
                foreach (var ins in list)
                {
                    if (tariffsByIns.TryGetValue(ins.InsuranceTPA_ID, out var insTariffs))
                    {
                        ins.TariffsCount = insTariffs.Count;
                        ins.Tariffs = insTariffs;
                    }
                }
            }
            catch
            {
                // Non-blocking fallback
            }

            var model = new InsuranceTPAIndexViewModel
            {
                InsuranceList = list,
                SelectedBranchId = branchId,
                SelectedType = type,
                SelectedNetworkCategory = networkCategory,
                SelectedStatus = status,
                SearchTerm = search,
                TypeOptions = InsuranceTypes.Select(t => new SelectListItem
                {
                    Value = t,
                    Text = t,
                    Selected = string.Equals(t, type, StringComparison.OrdinalIgnoreCase)
                }).ToList(),
                NetworkCategoryOptions = NetworkCategories.Select(c => new SelectListItem
                {
                    Value = c,
                    Text = c,
                    Selected = string.Equals(c, networkCategory, StringComparison.OrdinalIgnoreCase)
                }).ToList(),
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
            ViewData["PageName"] = "Insurance / TPA Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var initialPrefix = await insuranceService.GeneratePolicyPrefixAsync("Insurance Company");

        var model = new InsuranceTPAFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Branch_ID = User.GetCurrentBranchId() ?? 1,
            Type = "Insurance Company",
            NetworkCategory = "Both",
            AuthorizationRequired = true,
            PolicyPrefix = initialPrefix,
            Status = true,
            TypeOptions = GetTypeSelectList("Insurance Company"),
            NetworkCategoryOptions = GetNetworkCategorySelectList("Both")
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(InsuranceTPAFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (string.IsNullOrWhiteSpace(model.PolicyPrefix))
        {
            model.PolicyPrefix = await insuranceService.GeneratePolicyPrefixAsync(model.Type, model.Code);
        }

        if (await insuranceService.NameExistsAsync(model.Name, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Name), "An Insurance Company or TPA with this name already exists in this branch.");
        }

        if (await insuranceService.CodeExistsAsync(model.Code, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Code), "An Insurance Company or TPA with this code already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.TypeOptions = GetTypeSelectList(model.Type);
            model.NetworkCategoryOptions = GetNetworkCategorySelectList(model.NetworkCategory);
            return View(model);
        }

        try
        {
            var newId = await insuranceApiClient.CreateAsync(model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "InsuranceTPA.Create",
                $"Created {model.Type}: {model.Name} ({model.Code}) [Prefix: {model.PolicyPrefix}] - Network: {model.NetworkCategory} [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"{model.Type} '{model.Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.TypeOptions = GetTypeSelectList(model.Type);
            model.NetworkCategoryOptions = GetNetworkCategorySelectList(model.NetworkCategory);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var entity = await insuranceApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            var model = new InsuranceTPAFormViewModel
            {
                InsuranceTPA_ID = entity.InsuranceTPA_ID,
                CompanyId = entity.CompanyId,
                Branch_ID = entity.Branch_ID,
                Type = entity.Type,
                Name = entity.Name,
                Code = entity.Code,
                SchemeName = entity.SchemeName,
                PolicyPrefix = entity.PolicyPrefix,
                NetworkCategory = entity.NetworkCategory,
                AuthorizationRequired = entity.AuthorizationRequired,
                ContactPerson = entity.ContactPerson,
                ContactNumber = entity.ContactNumber,
                Email = entity.Email,
                Status = entity.Status,
                TypeOptions = GetTypeSelectList(entity.Type),
                NetworkCategoryOptions = GetNetworkCategorySelectList(entity.NetworkCategory)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Insurance / TPA Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, InsuranceTPAFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.Branch_ID ?? 1;
        model.InsuranceTPA_ID = id;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (await insuranceService.NameExistsAsync(model.Name, excludeId: id, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Name), "An Insurance Company or TPA with this name already exists in this branch.");
        }

        if (await insuranceService.CodeExistsAsync(model.Code, excludeId: id, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Code), "An Insurance Company or TPA with this code already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.TypeOptions = GetTypeSelectList(model.Type);
            model.NetworkCategoryOptions = GetNetworkCategorySelectList(model.NetworkCategory);
            return View(model);
        }

        try
        {
            await insuranceApiClient.UpdateAsync(id, model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "InsuranceTPA.Edit",
                $"Updated {model.Type}: {model.Name} ({model.Code}) [Prefix: {model.PolicyPrefix}] - Network: {model.NetworkCategory} [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = $"{model.Type} '{model.Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.TypeOptions = GetTypeSelectList(model.Type);
            model.NetworkCategoryOptions = GetNetworkCategorySelectList(model.NetworkCategory);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var entity = await insuranceApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            try
            {
                var tariffs = (await tariffApiClient.GetListAsync(insuranceTpaId: id, branchId: branchId, companyId: companyId)).ToList();
                entity.Tariffs = tariffs;
                entity.TariffsCount = tariffs.Count;
            }
            catch
            {
                // Non-blocking fallback
            }

            return View(entity);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Insurance / TPA Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await insuranceApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "InsuranceTPA.ToggleStatus",
                $"Toggled active status for Insurance/TPA [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Insurance/TPA status updated successfully.";
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
            await insuranceApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "InsuranceTPA.Delete",
                $"Deleted Insurance/TPA record [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Insurance/TPA record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete Insurance/TPA record: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetInsuranceJson(int id)
    {
        var item = await insuranceApiClient.GetByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    [HttpGet]
    public async Task<IActionResult> GeneratePrefix(string type, string? code = null)
    {
        var prefix = await insuranceService.GeneratePolicyPrefixAsync(type, code);
        return Json(new { prefix });
    }

    // =========================================================================
    // INSURANCE TARIFF CONFIGURATION - INTEGRATED AJAX ACTIONS
    // =========================================================================

    [HttpGet]
    public async Task<IActionResult> GetInsuranceTariffs(int insuranceTpaId)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var tariffs = await tariffApiClient.GetListAsync(insuranceTpaId: insuranceTpaId, branchId: branchId, companyId: companyId);
        return Json(new { success = true, data = tariffs });
    }

    [HttpGet]
    public async Task<IActionResult> GetTariffMasterItems(string? entitlementType)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var items = await tariffApiClient.GetMasterItemsAsync(entitlementType, branchId, companyId);
        return Json(new { success = true, data = items });
    }

    [HttpGet]
    public async Task<IActionResult> GetInsuranceTariff(int id)
    {
        var tariff = await tariffApiClient.GetByIdAsync(id);
        if (tariff is null) return Json(new { success = false, message = "Insurance tariff rule not found." });
        return Json(new { success = true, data = tariff });
    }

    [HttpPost]
    public async Task<IActionResult> SaveInsuranceTariff([FromBody] InsuranceTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.InsuranceTPA_ID <= 0)
            return Json(new { success = false, message = "Valid Insurance / TPA partner is required." });

        if (string.IsNullOrWhiteSpace(model.EntitlementType))
            return Json(new { success = false, message = "Entitlement Type is required." });

        if (model.Reference_ID <= 0)
            return Json(new { success = false, message = "Please select a master service item." });

        if (model.Effective_To < model.Effective_From)
            return Json(new { success = false, message = "Effective To date cannot be earlier than Effective From date." });

        if (model.Rate < 0)
            return Json(new { success = false, message = "Agreed Tariff Rate cannot be negative." });

        if (model.DeductionValue < 0)
            return Json(new { success = false, message = "Deduction / Co-pay value cannot be negative." });

        try
        {
            if (model.InsTariff_ID > 0)
            {
                await tariffApiClient.UpdateAsync(model.InsTariff_ID, model, userId);
                await auditLogService.LogAsync("MasterData", "InsuranceTariff.Update",
                    $"Updated Insurance Tariff [ID: {model.InsTariff_ID}] for Partner [ID: {model.InsuranceTPA_ID}]: Head={model.EntitlementType}, Rule={model.DeductionRuleType}, Rate={model.Rate}",
                    branchId: branchId);
                return Json(new { success = true, message = "Insurance tariff rule updated successfully!", id = model.InsTariff_ID });
            }
            else
            {
                var newId = await tariffApiClient.CreateAsync(model, userId);
                await auditLogService.LogAsync("MasterData", "InsuranceTariff.Create",
                    $"Created Insurance Tariff [ID: {newId}] for Partner [ID: {model.InsuranceTPA_ID}]: Head={model.EntitlementType}, Rule={model.DeductionRuleType}, Rate={model.Rate}",
                    branchId: branchId);
                return Json(new { success = true, message = "Insurance tariff rule created successfully!", id = newId });
            }
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> ToggleTariffStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await tariffApiClient.ToggleStatusAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "InsuranceTariff.ToggleStatus",
                $"Toggled active status for Insurance Tariff [ID: {id}]",
                branchId: branchId);
            return Json(new { success = true, message = "Status toggled successfully." });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> DeleteInsuranceTariff(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await tariffApiClient.DeleteAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "InsuranceTariff.Delete",
                $"Deleted Insurance Tariff [ID: {id}]",
                branchId: branchId);
            return Json(new { success = true, message = "Insurance tariff rule deleted successfully." });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    private static List<SelectListItem> GetTypeSelectList(string? selected = null) =>
        InsuranceTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();

    private static List<SelectListItem> GetNetworkCategorySelectList(string? selected = null) =>
        NetworkCategories.Select(c => new SelectListItem
        {
            Value = c,
            Text = c,
            Selected = string.Equals(c, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();
}
