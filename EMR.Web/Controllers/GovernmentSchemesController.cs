using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class GovernmentSchemesController(
    IGovernmentSchemeApiClient schemeApiClient,
    IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> SchemeTypes =
    [
        "Central Government",
        "State Government",
        "Defence / Ex-Servicemen",
        "PSU / Autonomous Body",
        "Social Security / Labour"
    ];

    [HttpGet]
    public async Task<IActionResult> Index(
        string? schemeType = null,
        bool? status = null,
        string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = (await schemeApiClient.GetListAsync(branchId, schemeType, status, search, companyId)).ToList();

            var model = new GovernmentSchemeIndexViewModel
            {
                SchemeList = list,
                SelectedBranchId = branchId,
                SelectedSchemeType = schemeType,
                SelectedStatus = status,
                SearchTerm = search,
                SchemeTypeOptions = SchemeTypes.Select(t => new SelectListItem
                {
                    Value = t,
                    Text = t,
                    Selected = string.Equals(t, schemeType, StringComparison.OrdinalIgnoreCase)
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
            ViewData["PageName"] = "Government Scheme Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new GovernmentSchemeFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Branch_ID = User.GetCurrentBranchId() ?? 1,
            SchemeType = "Central Government",
            Effective_From = DateTime.Today,
            Effective_To = DateTime.Today.AddYears(5),
            IsActive = true,
            AnnualCoverageLimit = 500000,
            PreAuthMandatory = true,
            BiometricAuthRequired = true,
            AbhaCreationMandatory = true,
            CoPayPercentage = 0,
            MaxClaimSubmissionDays = 7,
            PackageRateDiscountPercent = 0,
            DefaultBedCategory = "General Ward",
            TMSPortalUrl = "https://tms.pmjay.gov.in",
            NHA_SchemeCode = "PMJAY_V2",
            BeneficiaryIdType = "PM-JAY Golden Card / Aadhaar / Ration Card",
            SchemeTypeOptions = GetSchemeTypeSelectList("Central Government")
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(GovernmentSchemeFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        // Build RuleConfigJSON from visual builder inputs if not manually overridden
        BuildRuleConfigJsonIfEmpty(model);

        if (!ModelState.IsValid)
        {
            model.SchemeTypeOptions = GetSchemeTypeSelectList(model.SchemeType);
            return View(model);
        }

        try
        {
            var newId = await schemeApiClient.CreateAsync(model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "GovernmentScheme.Create",
                $"Created Government Scheme: {model.SchemeName} ({model.SchemeCode}) - Type: {model.SchemeType} [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"Government Scheme '{model.SchemeName}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.SchemeTypeOptions = GetSchemeTypeSelectList(model.SchemeType);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var entity = await schemeApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            var model = new GovernmentSchemeFormViewModel
            {
                Scheme_ID = entity.Scheme_ID,
                CompanyId = entity.CompanyId,
                Branch_ID = entity.Branch_ID,
                SchemeCode = entity.SchemeCode,
                SchemeName = entity.SchemeName,
                SchemeType = entity.SchemeType,
                AuthorityName = entity.AuthorityName,
                RuleConfigJSON = entity.RuleConfigJSON,
                Effective_From = entity.Effective_From,
                Effective_To = entity.Effective_To,
                IsActive = entity.IsActive,
                SchemeTypeOptions = GetSchemeTypeSelectList(entity.SchemeType)
            };

            // Parse existing RuleConfigJSON into form helper fields
            if (!string.IsNullOrWhiteSpace(entity.RuleConfigJSON))
            {
                try
                {
                    var rule = JsonSerializer.Deserialize<SchemeRuleConfigModel>(entity.RuleConfigJSON, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (rule is not null)
                    {
                        model.AnnualCoverageLimit = rule.AnnualCoverageLimit;
                        model.PreAuthMandatory = rule.PreAuthMandatory;
                        model.BiometricAuthRequired = rule.BiometricAuthRequired;
                        model.AbhaCreationMandatory = rule.AbhaCreationMandatory;
                        model.CoPayPercentage = rule.CoPayPercentage;
                        model.MaxClaimSubmissionDays = rule.MaxClaimSubmissionDays > 0 ? rule.MaxClaimSubmissionDays : 7;
                        model.PackageRateDiscountPercent = rule.PackageRateDiscountPercent;
                        model.DefaultBedCategory = rule.DefaultBedCategory ?? "General Ward";
                        model.TMSPortalUrl = rule.TMSPortalUrl;
                        model.NHA_SchemeCode = rule.NHA_SchemeCode;
                        model.BeneficiaryIdType = rule.BeneficiaryIdType ?? "Aadhaar / Scheme Card";
                        model.SpecialRemarks = rule.SpecialRemarks;
                    }
                }
                catch
                {
                    // Fallback to defaults
                }
            }

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Government Scheme Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, GovernmentSchemeFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;
        model.Scheme_ID = id;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        BuildRuleConfigJsonIfEmpty(model);

        if (!ModelState.IsValid)
        {
            model.SchemeTypeOptions = GetSchemeTypeSelectList(model.SchemeType);
            return View(model);
        }

        try
        {
            await schemeApiClient.UpdateAsync(id, model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "GovernmentScheme.Edit",
                $"Updated Government Scheme: {model.SchemeName} ({model.SchemeCode}) - Type: {model.SchemeType} [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = $"Government Scheme '{model.SchemeName}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.SchemeTypeOptions = GetSchemeTypeSelectList(model.SchemeType);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var entity = await schemeApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            return View(entity);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Government Scheme Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await schemeApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "GovernmentScheme.ToggleStatus",
                $"Toggled active status for Government Scheme [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Government Scheme status updated successfully.";
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
            await schemeApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "GovernmentScheme.Delete",
                $"Deleted Government Scheme record [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Government Scheme record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete Government Scheme record: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetSchemeJson(int id)
    {
        var item = await schemeApiClient.GetByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    private static void BuildRuleConfigJsonIfEmpty(GovernmentSchemeFormViewModel model)
    {
        var ruleObj = new SchemeRuleConfigModel
        {
            AnnualCoverageLimit = model.AnnualCoverageLimit,
            PreAuthMandatory = model.PreAuthMandatory,
            BiometricAuthRequired = model.BiometricAuthRequired,
            AbhaCreationMandatory = model.AbhaCreationMandatory,
            CoPayPercentage = model.CoPayPercentage,
            MaxClaimSubmissionDays = model.MaxClaimSubmissionDays,
            PackageRateDiscountPercent = model.PackageRateDiscountPercent,
            DefaultBedCategory = model.DefaultBedCategory,
            TMSPortalUrl = model.TMSPortalUrl,
            NHA_SchemeCode = model.NHA_SchemeCode,
            BeneficiaryIdType = model.BeneficiaryIdType,
            MandatoryDocuments = GetDefaultDocumentsForScheme(model.SchemeType, model.SchemeName),
            SpecialRemarks = model.SpecialRemarks
        };

        model.RuleConfigJSON = JsonSerializer.Serialize(ruleObj, new JsonSerializerOptions { WriteIndented = true });
    }

    private static List<string> GetDefaultDocumentsForScheme(string schemeType, string schemeName)
    {
        var nameLower = (schemeName ?? "").ToLowerInvariant();
        if (nameLower.Contains("pmjay") || nameLower.Contains("ayushman"))
        {
            return ["PM-JAY Golden Card / e-Card", "Aadhaar Card", "Ration Card", "Pre-Authorization Approval Letter", "Discharge Summary"];
        }
        if (nameLower.Contains("cghs"))
        {
            return ["CGHS Beneficiary Card", "Referral Letter from Wellness Centre", "Permission Letter", "Discharge Summary"];
        }
        if (nameLower.Contains("echs"))
        {
            return ["ECHS 64Kb Smart Card", "Polyclinic Referral Slip", "Discharge Summary", "Investigation Reports"];
        }
        if (nameLower.Contains("swasthya"))
        {
            return ["Swasthya Sathi Smart Card", "Patient Aadhaar Card", "Pre-Authorization Approval Slip", "Discharge Summary"];
        }
        if (nameLower.Contains("esi") || nameLower.Contains("esic"))
        {
            return ["ESIC Pehchan Card", "Form 16 Referral Letter", "IP Contribution Slip", "Discharge Summary"];
        }

        return ["Beneficiary Scheme Card / Letter", "Govt Photo ID (Aadhaar / Voter ID)", "Pre-Authorization Letter", "Discharge Summary"];
    }

    private static List<SelectListItem> GetSchemeTypeSelectList(string? selected = null) =>
        SchemeTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();
}
