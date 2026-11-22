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
    // SQLScripts/2517: 'Service' - OPD services (Service Type Service, not registration), all or the selected ones
    private static readonly string[] StandardRevenueTypes = ["Consultant", "Consultation", "Service", "Procedure", "Investigation", "Package", "Emergency", "Telemedicine", "All Services"];
    private static readonly string[] StandardCalculationTypes = ["Percentage", "Fixed Amount", "Tiered"];
    private static readonly string[] StandardCommissionBases = ["Net Collected", "Gross Bill", "Net Bill (After Discount)", "Base Tariff"];

    // ── SQLScripts/2518: the page works on commission PROFILES - one scope (doctor / speciality / branch, dates, overrides,
    //    approval, status) with a table of share lines (Consultation, Service - all or picked services -, ...). Each line
    //    is one DoctorCommissionConfig row; the share calculation, accrual and settlement are unchanged.

    [HttpGet]
    public async Task<IActionResult> Index(int? branchId, int? doctorId, int? specialityId, string? revenueType, bool? isActive, string? search)
    {
        var currentBranchId = User.GetCurrentBranchId();
        try
        {
            var vm = new DoctorCommissionConfigIndexViewModel
            {
                Profiles = await apiClient.GetCommissionProfilesAsync(branchId ?? currentBranchId, doctorId, specialityId, isActive, search),
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
            // a revenue type filter keeps the profiles that have a line of it
            if (!string.IsNullOrWhiteSpace(revenueType))
                vm.Profiles = vm.Profiles.Where(x => (x.LinesText ?? "").Contains(revenueType, StringComparison.OrdinalIgnoreCase)).ToList();
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
        var model = new DoctorCommissionConfigFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            ApprovalRequired = true,
            EffectiveFrom = DateTime.Today,
            IsActive = true,
            // a new profile starts with the consultation share; Service lines are added in the table
            Lines = [new DoctorCommissionShareLineViewModel { RevenueType = "Consultation", CalculationType = "Percentage", CommissionBasis = "Net Collected", DoctorShare = 70m }]
        };
        await PopulateFormOptionsAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Create(DoctorCommissionConfigFormViewModel model) => SaveProfileAsync(model, isNew: true);

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var model = await apiClient.GetCommissionProfileAsync(id);
            if (model is null) return NotFound();
            model.CompanyId = User.GetCompanyId();
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Edit(DoctorCommissionConfigFormViewModel model) => SaveProfileAsync(model, isNew: false);

    private async Task<IActionResult> SaveProfileAsync(DoctorCommissionConfigFormViewModel model, bool isNew)
    {
        model.CompanyId = User.GetCompanyId();
        if (isNew) model.ProfileId = 0;
        try
        {
            model.Lines = string.IsNullOrWhiteSpace(model.LinesJson) ? []
                : System.Text.Json.JsonSerializer.Deserialize<List<DoctorCommissionShareLineViewModel>>(model.LinesJson,
                      new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web)) ?? [];
        }
        catch (System.Text.Json.JsonException) { model.Lines = []; }
        // the old single-rule fields are not part of the profile form
        foreach (var k in new[] { nameof(model.RevenueType), nameof(model.CalculationType), nameof(model.CommissionBasis), nameof(model.DoctorShare) })
            ModelState.Remove(k);
        if (model.Lines.Count == 0) ModelState.AddModelError(string.Empty, "Add at least one share line.");
        var view = isNew ? nameof(Create) : nameof(Edit);
        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(view, model);
        }
        try
        {
            var (id, error) = await apiClient.SaveCommissionProfileAsync(model);
            if (error is not null)
            {
                ModelState.AddModelError(string.Empty, error);
                await PopulateFormOptionsAsync(model);
                return View(view, model);
            }
            await auditLogService.LogAsync("MasterData", isNew ? "DoctorCommissionConfigs.Create" : "DoctorCommissionConfigs.Edit",
                $"{(isNew ? "Created" : "Updated")} doctor commission profile #{id}: "
                + string.Join(" · ", model.Lines.Select(l => $"{l.RevenueType}{(l.RevenueType == "Service" ? $" ({(l.ServiceIds.Count == 0 ? "all services" : l.ServiceIds.Count + " service(s)")})" : "")} "
                    + (l.CalculationType == "Fixed Amount" ? $"₹{l.DoctorShare:0.##} flat" : $"{l.DoctorShare:0.##}% of {l.CommissionBasis}")))
                + $" (active: {model.IsActive})",
                branchId: model.BranchId ?? User.GetCurrentBranchId());
            TempData["SuccessMessage"] = isNew ? "Doctor commission profile created." : "Doctor commission profile updated.";
            return RedirectToAction(nameof(Index));
        }
        catch (HttpRequestException ex)
        {
            ModelState.AddModelError(string.Empty, "Unable to communicate with the EMR API server: " + ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(view, model);
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await apiClient.DeleteCommissionProfileAsync(id);
        if (deleted)
        {
            await auditLogService.LogAsync("MasterData", "DoctorCommissionConfigs.Delete", $"Deleted doctor commission profile #{id} (all its share lines)",
                branchId: User.GetCurrentBranchId());
            TempData["SuccessMessage"] = "Doctor commission profile deleted.";
        }
        else TempData["ErrorMessage"] = "Could not delete the doctor commission profile.";
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
        // SQLScripts/2517 / 2518: the services a Service share line can be limited to - Service Type 'Service', not a
        // registration service, of this company and the profile's branch (all branches for a global profile); read like the
        // page's other lists. A service already chosen stays listed (marked) even if it is inactive now.
        var picked = (m.ServiceIds ?? []).Concat(m.Lines.SelectMany(l => l.ServiceIds)).ToHashSet();
        var companyId = User.GetCompanyId();
        var branchId = m.BranchId;
        m.ServiceRuleOptions = await dbContext.ServiceMasters.AsNoTracking()
            .Where(s => s.ServiceType == "Service" && !s.IsRegistration && s.CompanyId == companyId
                        && (branchId == null || s.BranchId == branchId)
                        && (s.IsActive || picked.Contains(s.ServiceId)))
            .OrderBy(s => s.ItemName)
            .Select(s => new SelectListItem
            {
                Value = s.ServiceId.ToString(),
                Text = s.ItemName + (string.IsNullOrEmpty(s.ItemCode) ? "" : " (" + s.ItemCode + ")") + (s.IsActive ? "" : " (inactive)"),
                Selected = picked.Contains(s.ServiceId)
            })
            .ToListAsync();
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
