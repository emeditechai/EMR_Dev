using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorVisitProcessConfigsController(
    IDoctorCommissionApiClient apiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private static readonly string[] StandardVisitTypes = ["All", "New", "Follow-up", "Emergency", "Review", "Consultation"];
    private static readonly string[] StandardPaymentTimings = ["Before Consultation", "After Consultation", "At Discharge"];

    [HttpGet]
    public async Task<IActionResult> Index(int? branchId, int? specialityId, int? doctorId, string? visitType, bool? isActive, string? search)
    {
        var currentBranchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        try
        {
            var list = await apiClient.GetProcessConfigsAsync(branchId ?? currentBranchId, specialityId, doctorId, visitType, isActive, search, companyId);

            var vm = new DoctorVisitProcessConfigIndexViewModel
            {
                Items = list,
                SelectedBranchId = branchId,
                SelectedSpecialityId = specialityId,
                SelectedDoctorId = doctorId,
                SelectedVisitType = visitType,
                SelectedStatus = isActive,
                SearchTerm = search,
                BranchOptions = await GetBranchOptionsAsync(branchId),
                SpecialityOptions = await GetSpecialityOptionsAsync(specialityId),
                DoctorOptions = await GetDoctorOptionsAsync(doctorId)
            };

            return View(vm);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        var model = new DoctorVisitProcessConfigFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            VisitType = "All",
            PaymentTiming = "Before Consultation",
            VitalsRequired = true,
            DiagnosisRequired = true,
            Icd10Required = true,
            ProcedureAllowed = true,
            BillingRequired = true,
            PaymentBeforeClosure = true,
            EffectiveFrom = DateTime.Today,
            IsActive = true,
            BranchOptions = await GetBranchOptionsAsync(branchId),
            SpecialityOptions = await GetSpecialityOptionsAsync(),
            DoctorOptions = await GetDoctorOptionsAsync(),
            VisitTypeOptions = GetVisitTypeOptions("All"),
            PaymentTimingOptions = GetPaymentTimingOptions("Before Consultation")
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorVisitProcessConfigFormViewModel model)
    {
        model.CompanyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var newId = await apiClient.SaveProcessConfigAsync(model, User.GetUserId());

            await auditLogService.LogAsync(
                "MasterData",
                "DoctorVisitProcessConfigs.Create",
                $"Created Doctor Visit Process Config #{newId} (VisitType: {model.VisitType}, PaymentTiming: {model.PaymentTiming})",
                branchId: model.BranchId ?? User.GetCurrentBranchId());

            TempData["SuccessMessage"] = "Doctor Visit Process Configuration created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (HttpRequestException ex)
        {
            ModelState.AddModelError(string.Empty, "Unable to communicate with the EMR API server: " + ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await apiClient.GetProcessConfigByIdAsync(id);
        if (model is null) return NotFound();

        await PopulateFormOptionsAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorVisitProcessConfigFormViewModel model)
    {
        model.CompanyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            await apiClient.SaveProcessConfigAsync(model, User.GetUserId());

            await auditLogService.LogAsync(
                "MasterData",
                "DoctorVisitProcessConfigs.Edit",
                $"Updated Doctor Visit Process Config #{model.ProcessConfigId} (VisitType: {model.VisitType}, Active: {model.IsActive})",
                branchId: model.BranchId ?? User.GetCurrentBranchId());

            TempData["SuccessMessage"] = "Doctor Visit Process Configuration updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (HttpRequestException ex)
        {
            ModelState.AddModelError(string.Empty, "Unable to communicate with the EMR API server: " + ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId();
        var deleted = await apiClient.DeleteProcessConfigAsync(id);
        if (deleted)
        {
            await auditLogService.LogAsync(
                "MasterData",
                "DoctorVisitProcessConfigs.Delete",
                $"Deleted Doctor Visit Process Config #{id}",
                branchId: branchId);

            TempData["SuccessMessage"] = "Doctor Visit Process Configuration deleted successfully.";
        }
        else
        {
            TempData["ErrorMessage"] = "Could not delete Doctor Visit Process Configuration.";
        }

        return RedirectToAction(nameof(Index));
    }

    // ── Dropdown Helpers ──────────────────────────────────────────────────────
    private async Task PopulateFormOptionsAsync(DoctorVisitProcessConfigFormViewModel m)
    {
        m.BranchOptions = await GetBranchOptionsAsync(m.BranchId);
        m.SpecialityOptions = await GetSpecialityOptionsAsync(m.SpecialityId);
        m.DoctorOptions = await GetDoctorOptionsAsync(m.DoctorId);
        m.VisitTypeOptions = GetVisitTypeOptions(m.VisitType);
        m.PaymentTimingOptions = GetPaymentTimingOptions(m.PaymentTiming);
    }

    private async Task<List<SelectListItem>> GetBranchOptionsAsync(int? selected = null)
    {
        var list = await dbContext.BranchMasters.Where(b => b.IsActive)
            .OrderBy(b => b.BranchName)
            .Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName ?? ("Branch #" + b.BranchId), Selected = b.BranchId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Branches --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetSpecialityOptionsAsync(int? selected = null)
    {
        var list = await dbContext.DoctorSpecialityMasters.Where(s => s.IsActive)
            .OrderBy(s => s.SpecialityName)
            .Select(s => new SelectListItem { Value = s.SpecialityId.ToString(), Text = s.SpecialityName, Selected = s.SpecialityId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Specialties --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetDoctorOptionsAsync(int? selected = null)
    {
        var list = await dbContext.DoctorMasters.Where(d => d.IsActive)
            .OrderBy(d => d.FullName)
            .Select(d => new SelectListItem { Value = d.DoctorId.ToString(), Text = d.FullName ?? ("Doctor #" + d.DoctorId), Selected = d.DoctorId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Doctors --" });
        return list;
    }

    private static List<SelectListItem> GetVisitTypeOptions(string selected)
    {
        return StandardVisitTypes.Select(v => new SelectListItem { Value = v, Text = v, Selected = v == selected }).ToList();
    }

    private static List<SelectListItem> GetPaymentTimingOptions(string selected)
    {
        return StandardPaymentTimings.Select(p => new SelectListItem { Value = p, Text = p, Selected = p == selected }).ToList();
    }
}
