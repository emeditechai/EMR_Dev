using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

/// <summary>
/// Doctor IP (referral doctor commission). Confidential: besides the normal page permission, every action
/// except unlocking needs the company access code to have been entered in this session.
/// </summary>
[Authorize]
public class DoctorIpController(
    IDoctorIpApiClient apiClient,
    IGeneralMasterApiClient masterApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    IQueryStringEncryptionService encryptionService) : Controller
{
    private static readonly string[] OpenActions = [nameof(Unlock), nameof(SetAccessCode)];
    private static readonly JsonSerializerOptions RawJson = new() { PropertyNamingPolicy = null };

    private string UnlockKey => $"DoctorIp.UnlockedUntil.{User.GetCompanyId()}.{User.GetUserId()}";

    private DateTime? UnlockedUntil()
    {
        var raw = HttpContext.Session.GetString(UnlockKey);
        return long.TryParse(raw, out var ticks) ? new DateTime(ticks, DateTimeKind.Utc) : null;
    }

    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var action = context.RouteData.Values["action"]?.ToString();
        if (!OpenActions.Contains(action, StringComparer.OrdinalIgnoreCase))
        {
            var until = UnlockedUntil();
            if (until == null || until.Value < DateTime.UtcNow)
            {
                HttpContext.Session.Remove(UnlockKey);
                var wantsJson = Request.Headers.XRequestedWith == "XMLHttpRequest"
                                || Request.Headers.Accept.ToString().Contains("application/json");
                context.Result = wantsJson
                    ? new JsonResult(new { success = false, locked = true, message = "Doctor IP is locked. Enter the access code again." }) { StatusCode = 401 }
                    : RedirectToAction(nameof(Unlock), new { returnUrl = Request.Method == "GET" ? Request.Path + Request.QueryString : null });
                return;
            }

            // Sliding expiry: keep the page open while it is being used.
            var minutes = HttpContext.Session.GetInt32(UnlockKey + ".Minutes") ?? 15;
            HttpContext.Session.SetString(UnlockKey, DateTime.UtcNow.AddMinutes(minutes).Ticks.ToString());
        }
        await next();
    }

    // ── Access code ────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Unlock(string? returnUrl = null)
    {
        var status = await apiClient.GetAccessStatusAsync(User.GetCompanyId(), User.GetUserId());
        return View(new DoctorIpUnlockViewModel
        {
            ReturnUrl = returnUrl,
            IsConfigured = status.IsConfigured,
            IsLockedOut = status.IsLockedOut,
            LockedMinutesLeft = status.LockedMinutesLeft,
            AttemptsLeft = status.AttemptsLeft,
            IsSuperAdmin = User.IsSuperAdmin()
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Unlock(DoctorIpUnlockViewModel model)
    {
        model.IsSuperAdmin = User.IsSuperAdmin();
        if (!ModelState.IsValid)
        {
            var s = await apiClient.GetAccessStatusAsync(User.GetCompanyId(), User.GetUserId());
            model.IsConfigured = s.IsConfigured; model.AttemptsLeft = s.AttemptsLeft;
            return View(model);
        }

        var result = await apiClient.VerifyAccessCodeAsync(new DoctorIpVerifyCodeRequestModel
        {
            CompanyId = User.GetCompanyId(),
            UserId = User.GetUserId(),
            Code = model.Code,
            IpAddress = HttpContext.Connection.RemoteIpAddress?.ToString()
        });
        model.Code = string.Empty;
        model.IsConfigured = result.Result != "NOT_CONFIGURED";

        switch (result.Result)
        {
            case "OK":
                var unlockMinutes = result.UnlockMinutes > 0 ? result.UnlockMinutes : 15;
                HttpContext.Session.SetInt32(UnlockKey + ".Minutes", unlockMinutes);
                HttpContext.Session.SetString(UnlockKey, DateTime.UtcNow.AddMinutes(unlockMinutes).Ticks.ToString());
                await auditLogService.LogAsync("Unlock Doctor IP", "Access", "Doctor IP unlocked with access code", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
                return !string.IsNullOrWhiteSpace(model.ReturnUrl) && Url.IsLocalUrl(model.ReturnUrl)
                    ? LocalRedirect(model.ReturnUrl)
                    : RedirectToAction(nameof(Index));
            case "LOCKED":
                model.IsLockedOut = true;
                model.LockedMinutesLeft = result.LockedMinutesLeft;
                await auditLogService.LogAsync("Doctor IP Locked Out", "Access", "Too many wrong Doctor IP access codes", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
                break;
            case "NOT_CONFIGURED":
                break;
            default:
                model.AttemptsLeft = result.AttemptsLeft;
                ModelState.AddModelError(nameof(model.Code), $"Incorrect access code. {result.AttemptsLeft} attempt(s) left before the page is locked.");
                break;
        }
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Lock()
    {
        HttpContext.Session.Remove(UnlockKey);
        return RedirectToAction(nameof(Unlock));
    }

    [HttpGet]
    public async Task<IActionResult> SetAccessCode()
    {
        if (!User.IsSuperAdmin()) return Forbid();
        var status = await apiClient.GetAccessStatusAsync(User.GetCompanyId(), User.GetUserId());
        return View(new DoctorIpSetCodeViewModel { IsConfigured = status.IsConfigured });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SetAccessCode(DoctorIpSetCodeViewModel model)
    {
        if (!User.IsSuperAdmin()) return Forbid();
        var status = await apiClient.GetAccessStatusAsync(User.GetCompanyId(), User.GetUserId());
        model.IsConfigured = status.IsConfigured;
        if (model.IsConfigured && string.IsNullOrWhiteSpace(model.CurrentCode))
            ModelState.AddModelError(nameof(model.CurrentCode), "Enter the current access code.");
        if (!ModelState.IsValid) return View(model);

        try
        {
            await apiClient.SetAccessCodeAsync(new DoctorIpSetCodeRequestModel
            {
                CompanyId = User.GetCompanyId(),
                NewCode = model.NewCode,
                CurrentCode = model.CurrentCode,
                UserId = User.GetUserId()
            });
            HttpContext.Session.Remove(UnlockKey);
            await auditLogService.LogAsync("Set Doctor IP Access Code", "Access", "Doctor IP access code changed", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Access code saved. Enter it to open Doctor IP.";
            return RedirectToAction(nameof(Unlock));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CurrentCode = model.NewCode = model.ConfirmCode = string.Empty;
            return View(model);
        }
    }

    // ── List / Details ────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var branchId = User.GetCurrentBranchId();
        try
        {
            var items = (await apiClient.GetListAsync(User.GetCompanyId(), branchId, status, search)).ToList();
            var until = UnlockedUntil();
            return View(new DoctorIpIndexViewModel
            {
                Items = items,
                SelectedStatus = status,
                SearchTerm = search,
                BranchName = await BranchNameAsync(branchId),
                IsSuperAdmin = User.IsSuperAdmin(),
                UnlockMinutesLeft = until == null ? 0 : Math.Max(0, (int)Math.Ceiling((until.Value - DateTime.UtcNow).TotalMinutes)),
                StatusOptions =
                [
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                ]
            });
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor IP";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var item = await LoadOwnBranchAsync(id);
        if (item == null) return RedirectToAction(nameof(Index));
        return View(item);
    }

    // ── Create / Copy / Edit ─────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new DoctorIpFormViewModel { Branch_ID = User.GetCurrentBranchId() ?? 0 };
        await PopulateAsync(model);
        return View("Form", model);
    }

    /// <summary>New Doctor IP pre-filled with another Doctor IP's tests and rates; the doctor is chosen fresh.</summary>
    [HttpGet]
    public async Task<IActionResult> Copy(int id)
    {
        var source = await LoadOwnBranchAsync(id);
        if (source == null) return RedirectToAction(nameof(Index));

        var model = new DoctorIpFormViewModel
        {
            Branch_ID = User.GetCurrentBranchId() ?? 0,
            Speciality_ID = source.Header.Speciality_ID ?? 0,
            Effective_From = source.Header.Effective_From,
            Effective_To = source.Header.Effective_To,
            DetailsJson = JsonSerializer.Serialize(source.Details.Select(d => { d.Doctor_IP_Dtl_ID = 0; return d; }), RawJson),
            CopiedFrom = $"{source.Header.Doctor_Name} ({source.Header.Effective_From:dd-MMM-yyyy} to {source.Header.Effective_To:dd-MMM-yyyy})"
        };
        await PopulateAsync(model);
        return View("Form", model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Create(DoctorIpFormViewModel model) => SaveAsync(model, isNew: true);

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var item = await LoadOwnBranchAsync(id);
        if (item == null) return RedirectToAction(nameof(Index));

        var model = new DoctorIpFormViewModel
        {
            Doctor_IP_Hdr_ID = item.Header.Doctor_IP_Hdr_ID,
            Speciality_ID = item.Header.Speciality_ID ?? 0,
            Doctor_ID = item.Header.Doctor_ID,
            Branch_ID = item.Header.Branch_ID,
            Effective_From = item.Header.Effective_From,
            Effective_To = item.Header.Effective_To,
            Frequency_Of_Disbursal = item.Header.Frequency_Of_Disbursal ?? "Monthly",
            IsActive = item.Header.IsActive,
            DetailsJson = JsonSerializer.Serialize(item.Details, RawJson)
        };
        await PopulateAsync(model, item.Header.Doctor_Name);
        return View("Form", model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, DoctorIpFormViewModel model)
    {
        if (id != model.Doctor_IP_Hdr_ID) return BadRequest();
        if (await LoadOwnBranchAsync(id) == null) return RedirectToAction(nameof(Index));
        return await SaveAsync(model, isNew: false);
    }

    private async Task<IActionResult> SaveAsync(DoctorIpFormViewModel model, bool isNew)
    {
        model.Branch_ID = isNew ? User.GetCurrentBranchId() ?? 0 : model.Branch_ID;
        List<DoctorIpDetailInputModel> details;
        try
        {
            details = JsonSerializer.Deserialize<List<DoctorIpDetailInputModel>>(model.DetailsJson ?? "[]", RawJson) ?? [];
        }
        catch (JsonException)
        {
            details = [];
        }

        if (model.Effective_To < model.Effective_From)
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To must be on or after Effective From.");
        if (details.Count == 0)
            ModelState.AddModelError(string.Empty, "Add at least one test with a commission %.");
        if (details.Any(d => d.Commission_Rate < 0 || d.Commission_Rate > 100))
            ModelState.AddModelError(string.Empty, "Commission % must be between 0 and 100 for every test.");

        if (!ModelState.IsValid)
        {
            await PopulateAsync(model);
            return View("Form", model);
        }

        try
        {
            var newId = await apiClient.SaveAsync(new DoctorIpSaveRequestModel
            {
                Doctor_IP_Hdr_ID = isNew ? 0 : model.Doctor_IP_Hdr_ID,
                CompanyId = User.GetCompanyId(),
                Doctor_ID = model.Doctor_ID,
                Speciality_ID = model.Speciality_ID,
                Branch_ID = model.Branch_ID,
                Effective_From = model.Effective_From,
                Effective_To = model.Effective_To,
                Frequency_Of_Disbursal = model.Frequency_Of_Disbursal,
                IsActive = isNew || model.IsActive,
                UserId = User.GetUserId(),
                Details = details
            });

            await auditLogService.LogAsync(isNew ? "Create Doctor IP" : "Update Doctor IP", isNew ? "Create" : "Edit",
                $"{(isNew ? "Created" : "Updated")} Doctor IP #{newId} for doctor #{model.Doctor_ID} with {details.Count} test(s)",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);

            TempData["SuccessMessage"] = $"Doctor IP {(isNew ? "created" : "updated")} with {details.Count} test(s).";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateAsync(model);
            return View("Form", model);
        }
    }

    // ── Status / Delete ───────────────────────────────────────────────────────

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool isActive)
    {
        if (await LoadOwnBranchAsync(id) == null) return RedirectToAction(nameof(Index));
        try
        {
            await apiClient.ToggleStatusAsync(new DoctorIpToggleStatusRequestModel { Doctor_IP_Hdr_ID = id, IsActive = isActive, UserId = User.GetUserId() });
            await auditLogService.LogAsync("Toggle Doctor IP Status", "ToggleStatus", $"Doctor IP #{id} set {(isActive ? "Active" : "Inactive")}",
                User.GetUserId(), User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Status updated.";
        }
        catch (InvalidOperationException ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        if (await LoadOwnBranchAsync(id) == null) return RedirectToAction(nameof(Index));
        try
        {
            await apiClient.DeleteAsync(id, User.GetUserId());
            await auditLogService.LogAsync("Delete Doctor IP", "Delete", $"Deleted Doctor IP #{id}", User.GetUserId(), User.GetCurrentBranchId() ?? 1);
            TempData["SuccessMessage"] = "Doctor IP deleted.";
        }
        catch (InvalidOperationException ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    // ── AJAX lookups (all behind the access code) ─────────────────────────────

    [HttpGet]
    public async Task<IActionResult> GetDoctors(int specialityId)
    {
        var doctors = await apiClient.GetDoctorsAsync(specialityId, User.GetCompanyId());
        return Json(new { success = true, data = doctors.Select(d => new { id = d.Id, name = d.Name }) });
    }

    [HttpGet]
    public async Task<IActionResult> GetItems()
        => Json(new { success = true, data = await apiClient.GetItemsAsync(User.GetCompanyId()) }, RawJson);

    [HttpGet]
    public async Task<IActionResult> GetCategories(int? departmentId = null)
    {
        var list = await categoryApiClient.GetListAsync(departmentId, status: true);
        return Json(new { success = true, data = list.Select(c => new { id = c.Category_ID, name = c.Category_Name }) });
    }

    [HttpGet]
    public async Task<IActionResult> GetSubCategories(int? categoryId = null)
    {
        var list = await subCategoryApiClient.GetListAsync(categoryId, status: true);
        return Json(new { success = true, data = list.Select(s => new { id = s.SubCategory_ID, name = s.SubCategory_Name }) });
    }

    /// <summary>Tests and rates of another Doctor IP, for the Copy section of the form.</summary>
    [HttpGet]
    public async Task<IActionResult> GetCopySource(int id)
    {
        var source = await LoadOwnBranchAsync(id);
        if (source == null) return Json(new { success = false, message = "Source Doctor IP not found." });
        return Json(new { success = true, data = source.Details }, RawJson);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private async Task<DoctorIpDetailModel?> LoadOwnBranchAsync(int id)
    {
        var item = await apiClient.GetByIdAsync(id);
        if (item == null)
        {
            TempData["ErrorMessage"] = "Doctor IP not found.";
            return null;
        }
        var branchId = User.GetCurrentBranchId();
        if (branchId.HasValue && item.Header.Branch_ID != branchId.Value)
        {
            TempData["ErrorMessage"] = "This Doctor IP belongs to another branch.";
            return null;
        }
        return item;
    }

    private async Task<string?> BranchNameAsync(int? branchId)
        => branchId.HasValue ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName : null;

    private async Task PopulateAsync(DoctorIpFormViewModel model, string? currentDoctorName = null)
    {
        var companyId = User.GetCompanyId();
        model.Branch_Name = await BranchNameAsync(model.Branch_ID);

        var specialities = await apiClient.GetSpecialitiesAsync(companyId);
        model.SpecialityOptions = specialities
            .Select(s => new SelectListItem { Value = s.Id.ToString(), Text = $"{s.Name} ({s.ReferralDoctorCount})", Selected = s.Id == model.Speciality_ID })
            .ToList();

        model.DoctorOptions = model.Speciality_ID > 0
            ? (await apiClient.GetDoctorsAsync(model.Speciality_ID, companyId))
                .Select(d => new SelectListItem { Value = d.Id.ToString(), Text = d.Name, Selected = d.Id == model.Doctor_ID }).ToList()
            : [];
        // Keep the saved doctor selectable even if they are no longer an active referral doctor.
        if (model.Doctor_ID > 0 && model.DoctorOptions.All(o => o.Value != model.Doctor_ID.ToString()) && currentDoctorName != null)
            model.DoctorOptions.Insert(0, new SelectListItem { Value = model.Doctor_ID.ToString(), Text = currentDoctorName + " (inactive / not referral)", Selected = true });

        try
        {
            var departments = await masterApiClient.GetDepartmentsAsync("Lab");
            model.DepartmentOptions = departments.Where(d => d.IsActive)
                .Select(d => new SelectListItem { Value = d.DeptId.ToString(), Text = d.DeptName }).ToList();
        }
        catch (HttpRequestException) { model.DepartmentOptions = []; }

        var sources = await apiClient.GetListAsync(companyId, model.Branch_ID > 0 ? model.Branch_ID : null);
        model.CopySourceOptions = sources
            .Where(s => s.Doctor_IP_Hdr_ID != model.Doctor_IP_Hdr_ID && s.Item_Count > 0)
            .Select(s => new SelectListItem
            {
                Value = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = s.Doctor_IP_Hdr_ID.ToString() }),
                Text = $"{s.Doctor_Name} - {s.Speciality_Name} ({s.Effective_From:dd-MMM-yy} to {s.Effective_To:dd-MMM-yy}, {s.Item_Count} tests){(s.IsActive ? "" : " [Inactive]")}"
            }).ToList();
    }
}
