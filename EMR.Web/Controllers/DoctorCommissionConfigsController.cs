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
public class DoctorCommissionConfigsController(
    IDoctorCommissionApiClient apiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private static readonly string[] StandardRevenueTypes = ["Consultant", "Consultation", "Procedure", "Investigation", "Package", "Emergency", "Telemedicine", "All Services"];
    private static readonly string[] StandardCalculationTypes = ["Percentage", "Fixed Amount", "Tiered"];
    private static readonly string[] StandardCommissionBases = ["Net Collected", "Gross Bill", "Net Bill (After Discount)", "Base Tariff"];

    [HttpGet]
    public async Task<IActionResult> Index(int? branchId, int? doctorId, int? specialityId, string? revenueType, bool? isActive, string? search)
    {
        var currentBranchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();

        try
        {
            var list = await apiClient.GetCommissionConfigsAsync(branchId ?? currentBranchId, doctorId, specialityId, revenueType, isActive, search, companyId);

            var vm = new DoctorCommissionConfigIndexViewModel
            {
                Items = list,
                SelectedBranchId = branchId,
                SelectedDoctorId = doctorId,
                SelectedSpecialityId = specialityId,
                SelectedRevenueType = revenueType,
                SelectedStatus = isActive,
                SearchTerm = search,
                BranchOptions = await GetBranchOptionsAsync(branchId),
                DoctorOptions = await GetDoctorOptionsAsync(doctorId),
                SpecialityOptions = await GetSpecialityOptionsAsync(specialityId),
                RevenueTypeOptions = GetRevenueTypeOptions(revenueType)
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

        var model = new DoctorCommissionConfigFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            RevenueType = "Consultation",
            CalculationType = "Percentage",
            CommissionBasis = "Net Collected",
            DoctorShare = 70.00m,
            ApprovalRequired = true,
            EffectiveFrom = DateTime.Today,
            IsActive = true
        };

        await PopulateFormOptionsAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorCommissionConfigFormViewModel model)
    {
        model.CompanyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var newId = await apiClient.SaveCommissionConfigAsync(model, User.GetUserId());

            await auditLogService.LogAsync(
                "MasterData",
                "DoctorCommissionConfigs.Create",
                $"Created Doctor Commission Config #{newId} (Revenue: {model.RevenueType}, Share: {model.DoctorShare}{(model.CalculationType == "Percentage" ? "%" : " flat")})",
                branchId: model.BranchId ?? User.GetCurrentBranchId());

            TempData["SuccessMessage"] = "Doctor Commission Configuration created successfully.";
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
        var model = await apiClient.GetCommissionConfigByIdAsync(id);
        if (model is null) return NotFound();

        await PopulateFormOptionsAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorCommissionConfigFormViewModel model)
    {
        model.CompanyId = User.GetCompanyId();

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            await apiClient.SaveCommissionConfigAsync(model, User.GetUserId());

            await auditLogService.LogAsync(
                "MasterData",
                "DoctorCommissionConfigs.Edit",
                $"Updated Doctor Commission Config #{model.CommissionConfigId} (Revenue: {model.RevenueType}, Share: {model.DoctorShare}, Active: {model.IsActive})",
                branchId: model.BranchId ?? User.GetCurrentBranchId());

            TempData["SuccessMessage"] = "Doctor Commission Configuration updated successfully.";
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
        var deleted = await apiClient.DeleteCommissionConfigAsync(id);
        if (deleted)
        {
            await auditLogService.LogAsync(
                "MasterData",
                "DoctorCommissionConfigs.Delete",
                $"Deleted Doctor Commission Config #{id}",
                branchId: branchId);

            TempData["SuccessMessage"] = "Doctor Commission Configuration deleted successfully.";
        }
        else
        {
            TempData["ErrorMessage"] = "Could not delete Doctor Commission Configuration.";
        }

        return RedirectToAction(nameof(Index));
    }

    // ── Dropdown Helpers ──────────────────────────────────────────────────────
    private async Task PopulateFormOptionsAsync(DoctorCommissionConfigFormViewModel m)
    {
        m.BranchOptions = await GetBranchOptionsAsync(m.BranchId);
        m.DoctorOptions = await GetDoctorOptionsAsync(m.DoctorId);
        m.SpecialityOptions = await GetSpecialityOptionsAsync(m.SpecialityId);
        m.RevenueTypeOptions = GetRevenueTypeOptions(m.RevenueType);
        m.CalculationTypeOptions = GetCalculationTypeOptions(m.CalculationType);
        m.CommissionBasisOptions = GetCommissionBasisOptions(m.CommissionBasis);
        m.ProcedureOptions = await GetProcedureOptionsAsync(m.ProcedureId);
        m.ServiceOptions = await GetServiceOptionsAsync(m.ServiceId);
        m.CorporateOptions = await GetCorporateOptionsAsync(m.CorporateId);
        m.InsuranceOptions = await GetInsuranceOptionsAsync(m.InsuranceTPAId);
    }

    private async Task<List<SelectListItem>> GetBranchOptionsAsync(int? selected = null)
    {
        var list = await dbContext.BranchMasters.Where(b => b.IsActive)
            .OrderBy(b => b.BranchName)
            .Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName ?? ("Branch #" + b.BranchId), Selected = b.BranchId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Branches (Global) --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetDoctorOptionsAsync(int? selected = null)
    {
        var list = await dbContext.DoctorMasters.Where(d => d.IsActive)
            .OrderBy(d => d.FullName)
            .Select(d => new SelectListItem { Value = d.DoctorId.ToString(), Text = d.FullName ?? ("Doctor #" + d.DoctorId), Selected = d.DoctorId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- All Doctors in Speciality / General --" });
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

    private async Task<List<SelectListItem>> GetProcedureOptionsAsync(int? selected = null)
    {
        var list = await dbContext.ProcedureMasters.Where(p => p.IsActive)
            .OrderBy(p => p.ProcedureName)
            .Select(p => new SelectListItem { Value = p.ProcedureId.ToString(), Text = p.ProcedureName, Selected = p.ProcedureId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- None / Any Procedure --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetServiceOptionsAsync(int? selected = null)
    {
        var list = await dbContext.ServiceMasters.Where(s => s.IsActive)
            .OrderBy(s => s.ItemName)
            .Select(s => new SelectListItem { Value = s.ServiceId.ToString(), Text = s.ItemName, Selected = s.ServiceId == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- None / Any Service --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetCorporateOptionsAsync(int? selected = null)
    {
        var list = await dbContext.CorporateMasters.Where(c => c.Status)
            .OrderBy(c => c.Corporate_Name)
            .Select(c => new SelectListItem { Value = c.Corporate_ID.ToString(), Text = c.Corporate_Name, Selected = c.Corporate_ID == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- None / Direct Patient --" });
        return list;
    }

    private async Task<List<SelectListItem>> GetInsuranceOptionsAsync(int? selected = null)
    {
        var list = await dbContext.InsuranceTPAMasters.Where(i => i.Status)
            .OrderBy(i => i.Name)
            .Select(i => new SelectListItem { Value = i.InsuranceTPA_ID.ToString(), Text = $"{i.Name} ({i.Type})", Selected = i.InsuranceTPA_ID == selected })
            .ToListAsync();
        list.Insert(0, new SelectListItem { Value = "", Text = "-- None / Non-Insurance --" });
        return list;
    }

    private static List<SelectListItem> GetRevenueTypeOptions(string? selected = null)
    {
        return StandardRevenueTypes.Select(r => new SelectListItem { Value = r, Text = r, Selected = r == selected }).ToList();
    }

    private static List<SelectListItem> GetCalculationTypeOptions(string? selected = null)
    {
        return StandardCalculationTypes.Select(c => new SelectListItem { Value = c, Text = c, Selected = c == selected }).ToList();
    }

    private static List<SelectListItem> GetCommissionBasisOptions(string? selected = null)
    {
        return StandardCommissionBases.Select(b => new SelectListItem { Value = b, Text = b, Selected = b == selected }).ToList();
    }
}
