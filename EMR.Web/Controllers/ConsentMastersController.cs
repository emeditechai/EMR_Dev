using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class ConsentMastersController(
    IConsentMasterApiClient apiClient,
    IAuditLogService auditLogService) : Controller
{
    private static readonly string[] StandardDepartmentTypes = ["IPD", "OPD", "LAB", "MED"];

    private static readonly string[] StandardConsentTypes =
    [
        "General Admission Consent",
        "Surgical / Operative Consent",
        "Anaesthesia Consent",
        "High Risk / Informed Consent",
        "Blood & Component Transfusion Consent",
        "Chemotherapy & Oncology Consent",
        "Diagnostic Procedure Consent",
        "Endoscopy / Colonoscopy Consent",
        "ICU / Critical Care Procedure Consent",
        "Discharge Against Medical Advice (DAMA)",
        "Left Against Medical Advice (LAMA)",
        "Clinical Trial / Research Protocol Consent",
        "Patient Restraint Consent",
        "Photography / Media Consent",
        "Organ / Tissue Donation Consent",
        "Telemedicine Consultation Consent",
        "HIV / Sensitive Testing Consent",
        "Pediatric Treatment Consent"
    ];

    private static readonly string[] StandardLanguages =
    [
        "English",
        "Hindi",
        "Bengali",
        "Tamil",
        "Telugu",
        "Marathi",
        "Gujarati",
        "Kannada",
        "Malayalam",
        "Punjabi",
        "Odia",
        "Assamese",
        "Urdu",
        "Arabic",
        "French",
        "Spanish"
    ];

    private static readonly string[] StandardValidityPeriods =
    [
        "Per Admission",
        "Single Episode / Procedure",
        "24 Hours",
        "48 Hours",
        "7 Days",
        "30 Days",
        "90 Days",
        "180 Days",
        "365 Days / 1 Year",
        "Permanent / Indefinite"
    ];

    [HttpGet]
    public async Task<IActionResult> Index(string? type, string? consentType, string? language, bool? status, string? search)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();

        try
        {
            var items = await apiClient.GetConsentMastersAsync(branchId, type, consentType, language, null, status, search, companyId);

            var viewModel = new ConsentMasterIndexViewModel
            {
                Items = items,
                SelectedType = type,
                SelectedConsentType = consentType,
                SelectedLanguage = language,
                SelectedStatus = status,
                SearchTerm = search,
                DepartmentTypeOptions = GetDepartmentTypeSelectList(type),
                ConsentTypeOptions = GetConsentTypeSelectList(consentType),
                LanguageOptions = GetLanguageSelectList(language)
            };

            return View(viewModel);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();

        var model = new ConsentMasterFormViewModel
        {
            CompanyId = companyId,
            Branch_ID = branchId,
            Type = "IPD",
            Language = "English",
            Version = "1.0",
            ValidityPeriod = "Per Admission",
            WitnessRequired = true,
            Status = true,
            DepartmentTypeOptions = GetDepartmentTypeSelectList("IPD"),
            ConsentTypeOptions = GetConsentTypeSelectList(),
            LanguageOptions = GetLanguageSelectList("English"),
            ValidityPeriodOptions = GetValidityPeriodSelectList("Per Admission"),
            ProcedureOptions = await GetProcedureSelectListAsync(branchId)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ConsentMasterFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();
        model.Branch_ID = branchId;
        model.CompanyId = companyId;

        // If not IPD, clear Procedure_ID
        if (model.Type != "IPD")
        {
            model.Procedure_ID = null;
        }

        if (string.IsNullOrWhiteSpace(model.ConsentTemplateContent))
        {
            ModelState.AddModelError(nameof(model.ConsentTemplateContent), "Consent Template Content is required.");
        }

        if (!ModelState.IsValid)
        {
            model.DepartmentTypeOptions = GetDepartmentTypeSelectList(model.Type);
            model.ConsentTypeOptions = GetConsentTypeSelectList(model.ConsentType);
            model.LanguageOptions = GetLanguageSelectList(model.Language);
            model.ValidityPeriodOptions = GetValidityPeriodSelectList(model.ValidityPeriod);
            model.ProcedureOptions = await GetProcedureSelectListAsync(branchId, model.Procedure_ID);
            return View(model);
        }

        try
        {
            var newId = await apiClient.CreateConsentMasterAsync(model, User.GetUserId());

            await auditLogService.LogAsync(
                "MasterData",
                "ConsentMasters.Create",
                $"Created Consent Master template: {model.ConsentType} ({model.Type}, {model.Language}, v{model.Version}) [ID: {newId}]",
                branchId: branchId);

            TempData["SuccessMessage"] = $"Consent Master '{model.ConsentType}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (HttpRequestException ex)
        {
            ModelState.AddModelError(string.Empty, "Unable to communicate with the EMR API server: " + ex.Message);
            model.DepartmentTypeOptions = GetDepartmentTypeSelectList(model.Type);
            model.ConsentTypeOptions = GetConsentTypeSelectList(model.ConsentType);
            model.LanguageOptions = GetLanguageSelectList(model.Language);
            model.ValidityPeriodOptions = GetValidityPeriodSelectList(model.ValidityPeriod);
            model.ProcedureOptions = await GetProcedureSelectListAsync(branchId, model.Procedure_ID);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var detail = await apiClient.GetConsentMasterByIdAsync(id);
        if (detail is null) return NotFound();

        var model = new ConsentMasterFormViewModel
        {
            Consent_ID = detail.Consent_ID,
            CompanyId = detail.CompanyId,
            Branch_ID = detail.Branch_ID,
            ConsentType = detail.ConsentType,
            Type = detail.Type,
            Procedure_ID = detail.Procedure_ID,
            Language = detail.Language,
            ConsentTemplateContent = detail.ConsentTemplateContent,
            Version = detail.Version,
            ValidityPeriod = detail.ValidityPeriod,
            WitnessRequired = detail.WitnessRequired,
            Status = detail.Status,
            DepartmentTypeOptions = GetDepartmentTypeSelectList(detail.Type),
            ConsentTypeOptions = GetConsentTypeSelectList(detail.ConsentType),
            LanguageOptions = GetLanguageSelectList(detail.Language),
            ValidityPeriodOptions = GetValidityPeriodSelectList(detail.ValidityPeriod),
            ProcedureOptions = await GetProcedureSelectListAsync(branchId, detail.Procedure_ID)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(ConsentMasterFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? model.Branch_ID;
        var companyId = User.GetCompanyId();
        model.Branch_ID = branchId;
        model.CompanyId = companyId;

        // If not IPD, clear Procedure_ID
        if (model.Type != "IPD")
        {
            model.Procedure_ID = null;
        }

        if (string.IsNullOrWhiteSpace(model.ConsentTemplateContent))
        {
            ModelState.AddModelError(nameof(model.ConsentTemplateContent), "Consent Template Content is required.");
        }

        if (!ModelState.IsValid)
        {
            model.DepartmentTypeOptions = GetDepartmentTypeSelectList(model.Type);
            model.ConsentTypeOptions = GetConsentTypeSelectList(model.ConsentType);
            model.LanguageOptions = GetLanguageSelectList(model.Language);
            model.ValidityPeriodOptions = GetValidityPeriodSelectList(model.ValidityPeriod);
            model.ProcedureOptions = await GetProcedureSelectListAsync(branchId, model.Procedure_ID);
            return View(model);
        }

        try
        {
            var updated = await apiClient.UpdateConsentMasterAsync(model, User.GetUserId());
            if (!updated) return NotFound();

            await auditLogService.LogAsync(
                "MasterData",
                "ConsentMasters.Edit",
                $"Updated Consent Master template: {model.ConsentType} ({model.Type}, {model.Language}, v{model.Version}, Status: {(model.Status ? "Active" : "Inactive")}) [ID: {model.Consent_ID}]",
                branchId: branchId);

            TempData["SuccessMessage"] = $"Consent Master '{model.ConsentType}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (HttpRequestException ex)
        {
            ModelState.AddModelError(string.Empty, "Unable to communicate with the EMR API server: " + ex.Message);
            model.DepartmentTypeOptions = GetDepartmentTypeSelectList(model.Type);
            model.ConsentTypeOptions = GetConsentTypeSelectList(model.ConsentType);
            model.LanguageOptions = GetLanguageSelectList(model.Language);
            model.ValidityPeriodOptions = GetValidityPeriodSelectList(model.ValidityPeriod);
            model.ProcedureOptions = await GetProcedureSelectListAsync(branchId, model.Procedure_ID);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var item = await apiClient.GetConsentMasterByIdAsync(id);
        if (item is null) return NotFound();

        return View(item);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var existing = await apiClient.GetConsentMasterByIdAsync(id);
        var consentName = existing?.ConsentType ?? $"ID #{id}";

        var deleted = await apiClient.DeleteConsentMasterAsync(id);
        if (deleted)
        {
            await auditLogService.LogAsync(
                "MasterData",
                "ConsentMasters.Delete",
                $"Deleted Consent Master template '{consentName}' [ID: {id}]",
                branchId: branchId);

            TempData["SuccessMessage"] = $"Consent Master '{consentName}' deleted successfully.";
        }
        else
        {
            TempData["ErrorMessage"] = "Could not delete Consent Master template. It may not exist.";
        }

        return RedirectToAction(nameof(Index));
    }

    // ── Helper SelectList Generators ──────────────────────────────────────────
    private static List<SelectListItem> GetDepartmentTypeSelectList(string? selected = null)
    {
        return StandardDepartmentTypes
            .Select(t => new SelectListItem { Value = t, Text = t, Selected = string.Equals(t, selected, StringComparison.OrdinalIgnoreCase) })
            .ToList();
    }

    private static List<SelectListItem> GetConsentTypeSelectList(string? selected = null)
    {
        return StandardConsentTypes
            .Select(c => new SelectListItem { Value = c, Text = c, Selected = string.Equals(c, selected, StringComparison.OrdinalIgnoreCase) })
            .ToList();
    }

    private static List<SelectListItem> GetLanguageSelectList(string? selected = null)
    {
        return StandardLanguages
            .Select(l => new SelectListItem { Value = l, Text = l, Selected = string.Equals(l, selected, StringComparison.OrdinalIgnoreCase) })
            .ToList();
    }

    private static List<SelectListItem> GetValidityPeriodSelectList(string? selected = null)
    {
        return StandardValidityPeriods
            .Select(v => new SelectListItem { Value = v, Text = v, Selected = string.Equals(v, selected, StringComparison.OrdinalIgnoreCase) })
            .ToList();
    }

    private async Task<List<SelectListItem>> GetProcedureSelectListAsync(int? branchId, int? selectedId = null)
    {
        try
        {
            var procedures = await apiClient.GetProcedureOptionsAsync(branchId);
            return procedures
                .Select(p => new SelectListItem
                {
                    Value = p.ProcedureId.ToString(),
                    Text = $"{p.ProcedureName} ({p.ProcedureCode})" + (!string.IsNullOrEmpty(p.ProcedureCategory) ? $" — {p.ProcedureCategory}" : ""),
                    Selected = p.ProcedureId == selectedId
                })
                .ToList();
        }
        catch
        {
            return [];
        }
    }
}
