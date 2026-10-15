using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class CorporatesController(
    ICorporateApiClient corporateApiClient,
    ICorporateHospitalRateApiClient rateApiClient,
    ICorporateService corporateService,
    ICorporateHospitalRateService rateService,
    IAuditLogService auditLogService,
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasherService,
    IMasterApprovalService approvals,
    ILoginCredentialsMailer credentialsMailer) : Controller
{
    private static readonly List<string> CorporateTypes = ["IPD", "OPD", "LAB", "MED", "GENERAL", "ALL"];
    private static readonly List<string> BillingCycles = ["Monthly", "Daily", "Yearly", "Bi-Monthly", "Half-Yearly"];
    private static readonly List<string> RateServiceTypes = ["Room", "Procedure", "OT", "ICU", "HospitalService", "Package"];
    private static readonly List<string> RateTypes = ["Percentage", "Rate", "Both"];

    [HttpGet]
    public async Task<IActionResult> Index(string? type = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = (await corporateApiClient.GetListAsync(branchId, type, status, search, companyId)).ToList();
            ViewBag.ApprovalStates = await approvals.GetOpenStatesAsync(companyId, ApprovalModules.Corporate);

            // Fetch rate rules in parallel or batch for rich UI rate count pill
            try
            {
                var allRates = (await rateApiClient.GetListAsync(branchId: branchId, companyId: companyId)).ToList();
                var ratesByCorp = allRates.GroupBy(r => r.Corporate_ID).ToDictionary(g => g.Key, g => g.ToList());
                foreach (var c in list)
                {
                    if (ratesByCorp.TryGetValue(c.Corporate_ID, out var corpRates))
                    {
                        c.RatesCount = corpRates.Count;
                        c.Rates = corpRates;
                    }
                }
            }
            catch
            {
                // Fallback gracefully if rate API returns error
            }

            var model = new CorporateIndexViewModel
            {
                Corporates = list,
                SelectedBranchId = branchId,
                SelectedType = type,
                SelectedStatus = status,
                SearchTerm = search,
                TypeOptions = CorporateTypes.Select(t => new SelectListItem
                {
                    Value = t,
                    Text = t,
                    Selected = string.Equals(t, type, StringComparison.OrdinalIgnoreCase)
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
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new CorporateFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Branch_ID = User.GetCurrentBranchId() ?? 1,
            Effective_From = DateTime.Today,
            Effective_To = DateTime.Today.AddYears(1),
            Corporate_Type = "ALL",
            BillingCycle = "Monthly",
            Status = true,
            CorporateTypeOptions = GetTypeSelectList(),
            BillingCycleOptions = GetBillingCycleSelectList()
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CorporateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        if (await corporateService.NameExistsAsync(model.Corporate_Name, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Corporate_Name), "A Corporate with this name already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }

        try
        {
            // under approval the corporate is saved inactive (not offered in billing) until approved
            var matrix = await approvals.FindMatrixAsync(companyId, ApprovalModules.Corporate, branchId);
            var wantedStatus = model.Status;
            if (matrix is not null) model.Status = false;

            var newId = await corporateApiClient.CreateAsync(model, User.GetUserId());

            await CreateLinkedUserAsync(model, newId, companyId, branchId, activeNow: matrix is null);

            if (matrix is not null)
            {
                model.Status = wantedStatus;
                await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Corporate, Matrix = matrix, CompanyId = companyId, BranchId = branchId,
                    EntityId = newId, EntityName = model.Corporate_Name, ActionType = "CREATE", RequestedActive = wantedStatus,
                    NewValues = model, UserId = User.GetUserId()
                });
                await auditLogService.LogAsync("MasterData", "Corporate.Create",
                    $"Created Corporate (awaiting approval): {model.Corporate_Name} [ID: {newId}]", branchId: branchId);
                TempData["Success"] = $"Corporate '{model.Corporate_Name}' saved and sent for approval. It becomes active, and its login is enabled, once approved.";
                return RedirectToAction(nameof(Index));
            }

            await auditLogService.LogAsync("MasterData", "Corporate.Create",
                $"Created Corporate: {model.Corporate_Name} ({model.Corporate_Code}) [{model.Corporate_Type}] - Contact: {model.Contact_No} [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"Corporate '{model.Corporate_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var entity = await corporateApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            var model = new CorporateFormViewModel
            {
                Corporate_ID = entity.Corporate_ID,
                CompanyId = entity.CompanyId,
                Branch_ID = entity.Branch_ID,
                Corporate_Code = entity.Corporate_Code,
                Corporate_Name = entity.Corporate_Name,
                Corporate_Type = entity.Corporate_Type,
                Effective_From = entity.Effective_From,
                Effective_To = entity.Effective_To,
                Credit_Limit = entity.Credit_Limit,
                Credit_Days = entity.Credit_Days,
                BillingCycle = entity.BillingCycle,
                Contact_No = entity.Contact_No,
                Email = entity.Email,
                Address = entity.Address,
                Pincode = entity.Pincode,
                Status = entity.Status,
                CorporateTypeOptions = GetTypeSelectList(entity.Corporate_Type),
                BillingCycleOptions = GetBillingCycleSelectList(entity.BillingCycle)
            };

            var open = await approvals.GetOpenAsync(ApprovalModules.Corporate, id);
            if (open is { IsPendingCreate: true, Requested_Active: bool wanted }) model.Status = wanted;
            ViewBag.ApprovalOpen = open;

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, CorporateFormViewModel model)
    {
        // a record waiting for approval cannot be changed until the approver acts (a sent-back one can)
        if (await approvals.GetOpenAsync(ApprovalModules.Corporate, id) is { Status: "P" })
        {
            TempData["Error"] = "This corporate is awaiting approval and cannot be edited until the approver approves it or sends it back.";
            return RedirectToAction(nameof(Index));
        }

        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.Branch_ID ?? 1;
        model.Corporate_ID = id;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        if (await corporateService.NameExistsAsync(model.Corporate_Name, excludeId: id, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Corporate_Name), "A Corporate with this name already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }

        try
        {
            var open = await approvals.GetOpenAsync(ApprovalModules.Corporate, id);
            var matrix = await approvals.FindMatrixAsync(companyId, ApprovalModules.Corporate, branchId);
            var wantedStatus = model.Status;

            if (matrix is not null && open is { IsPendingCreate: true })
            {
                // not approved yet: stays inactive and goes back for approval with these values
                model.Status = false;
                await corporateApiClient.UpdateAsync(id, model, User.GetUserId());
                model.Status = wantedStatus;
                await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Corporate, Matrix = matrix, CompanyId = companyId, BranchId = branchId,
                    EntityId = id, EntityName = model.Corporate_Name, ActionType = "CREATE", RequestedActive = wantedStatus,
                    NewValues = model, UserId = User.GetUserId()
                });
                TempData["Success"] = $"Corporate '{model.Corporate_Name}' saved and sent for approval again.";
                return RedirectToAction(nameof(Index));
            }

            if (matrix is not null)
            {
                // an approved corporate keeps its current details until the change is approved
                var current = await corporateApiClient.GetByIdAsync(id);
                var old = current is null ? null
                    : System.Text.Json.JsonSerializer.Deserialize<CorporateFormViewModel>(System.Text.Json.JsonSerializer.Serialize(current));
                if (old is not null) { old.CompanyId = companyId; old.Branch_ID = current!.Branch_ID; }
                var requestId = await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Corporate, Matrix = matrix, CompanyId = companyId, BranchId = branchId,
                    EntityId = id, EntityName = model.Corporate_Name, ActionType = "UPDATE",
                    OldValues = old, NewValues = model, UserId = User.GetUserId()
                });
                TempData["Success"] = requestId == 0
                    ? "Nothing was changed, so nothing was sent for approval."
                    : $"The change to '{model.Corporate_Name}' was sent for approval. The corporate keeps its current details until it is approved.";
                return RedirectToAction(nameof(Index));
            }

            await corporateApiClient.UpdateAsync(id, model, User.GetUserId());
            if (open is { IsPendingCreate: true })
            {
                // the approval for this module was switched off while it was waiting: it is live now
                await approvals.CloseAsync(ApprovalModules.Corporate, id, User.GetUserId(), "Approval no longer configured");
                var login = await dbContext.Users.FirstOrDefaultAsync(u => u.UserType == UserTypes.Company && u.ReferenceUserId == id);
                if (login is { IsActive: false }) { login.IsActive = true; await dbContext.SaveChangesAsync(); }
            }

            await auditLogService.LogAsync("MasterData", "Corporate.Edit",
                $"Updated Corporate: {model.Corporate_Name} ({model.Corporate_Code}) [{model.Corporate_Type}] - Contact: {model.Contact_No} [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = $"Corporate '{model.Corporate_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
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
            var entity = await corporateApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            try
            {
                var rates = (await rateApiClient.GetListAsync(corporateId: id, branchId: branchId, companyId: companyId)).ToList();
                entity.Rates = rates;
                entity.RatesCount = rates.Count;
            }
            catch
            {
                // Non-blocking fallback
            }

            return View(entity);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        if (await approvals.GetOpenAsync(ApprovalModules.Corporate, id) is { IsPendingCreate: true })
        {
            TempData["Error"] = "This corporate is awaiting approval. It becomes active once approved.";
            return RedirectToAction(nameof(Index));
        }
        try
        {
            await corporateApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "Corporate.ToggleStatus",
                $"Toggled active status for Corporate [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Corporate status updated successfully.";
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
            await corporateApiClient.DeleteAsync(id, User.GetUserId());
            await approvals.CloseAsync(ApprovalModules.Corporate, id, User.GetUserId(), "Record deleted");

            await auditLogService.LogAsync("MasterData", "Corporate.Delete",
                $"Deleted Corporate record [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Corporate record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete corporate record: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetCorporateJson(int id)
    {
        var item = await corporateApiClient.GetByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    // =========================================================================
    // CORPORATE HOSPITAL RATE MASTER - INTEGRATED AJAX ACTIONS
    // =========================================================================

    [HttpGet]
    public async Task<IActionResult> GetCorporateRates(int corporateId)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var rates = await rateApiClient.GetListAsync(corporateId: corporateId, branchId: branchId, companyId: companyId);
        return Json(new { success = true, data = rates });
    }

    [HttpGet]
    public async Task<IActionResult> GetMasterServiceItems(string? serviceType)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var items = await rateApiClient.GetMasterItemsAsync(serviceType, branchId, companyId);
        return Json(new { success = true, data = items });
    }

    [HttpGet]
    public async Task<IActionResult> GetCorporateRate(int id)
    {
        var rate = await rateApiClient.GetByIdAsync(id);
        if (rate is null) return Json(new { success = false, message = "Corporate rate not found." });
        return Json(new { success = true, data = rate });
    }

    [HttpPost]
    public async Task<IActionResult> SaveCorporateRate([FromBody] CorporateHospitalRateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        var userId = User.GetUserId();

        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.Corporate_ID <= 0)
            return Json(new { success = false, message = "Valid Corporate ID is required." });

        if (string.IsNullOrWhiteSpace(model.RateServiceType))
            return Json(new { success = false, message = "Rate Service Type is required." });

        if (model.ReferenceMaster_ID <= 0)
            return Json(new { success = false, message = "Please select a master service item." });

        if (model.Effective_To < model.Effective_From)
            return Json(new { success = false, message = "Effective To date cannot be earlier than Effective From date." });

        if (model.RateType == "Rate" && (!model.Rate.HasValue || model.Rate.Value < 0))
            return Json(new { success = false, message = "Please enter a valid rate amount." });

        if (model.RateType == "Percentage" && (!model.DiscountPercent.HasValue || model.DiscountPercent.Value < 0 || model.DiscountPercent.Value > 100))
            return Json(new { success = false, message = "Please enter a valid discount percentage between 0 and 100%." });

        if (model.RateType == "Both")
        {
            if (!model.Rate.HasValue || model.Rate.Value < 0)
                return Json(new { success = false, message = "Please enter a valid contracted rate amount." });
            if (!model.DiscountPercent.HasValue || model.DiscountPercent.Value < 0 || model.DiscountPercent.Value > 100)
                return Json(new { success = false, message = "Please enter a valid discount percentage." });
        }

        try
        {
            if (model.CorpRate_ID > 0)
            {
                await rateApiClient.UpdateAsync(model.CorpRate_ID, model, userId);
                await auditLogService.LogAsync("MasterData", "CorporateRate.Update",
                    $"Updated Corporate Rate [ID: {model.CorpRate_ID}] for Corporate [ID: {model.Corporate_ID}]: Head={model.RateServiceType}, RateType={model.RateType}",
                    branchId: branchId);
                return Json(new { success = true, message = "Corporate rate rule updated successfully!", id = model.CorpRate_ID });
            }
            else
            {
                var newId = await rateApiClient.CreateAsync(model, userId);
                await auditLogService.LogAsync("MasterData", "CorporateRate.Create",
                    $"Created Corporate Rate [ID: {newId}] for Corporate [ID: {model.Corporate_ID}]: Head={model.RateServiceType}, RateType={model.RateType}",
                    branchId: branchId);
                return Json(new { success = true, message = "Corporate rate rule created successfully!", id = newId });
            }
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> ToggleRateStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await rateApiClient.ToggleStatusAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "CorporateRate.ToggleStatus",
                $"Toggled active status for Corporate Rate [ID: {id}]",
                branchId: branchId);
            return Json(new { success = true, message = "Status toggled successfully." });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> DeleteCorporateRate(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await rateApiClient.DeleteAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "CorporateRate.Delete",
                $"Deleted Corporate Rate [ID: {id}]",
                branchId: branchId);
            return Json(new { success = true, message = "Corporate rate rule deleted successfully." });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    private static List<SelectListItem> GetTypeSelectList(string? selected = null) =>
        CorporateTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();

    private static List<SelectListItem> GetBillingCycleSelectList(string? selected = null) =>
        BillingCycles.Select(b => new SelectListItem
        {
            Value = b,
            Text = b,
            Selected = string.Equals(b, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();

    /// <summary>The corporate's login. A corporate under approval gets a disabled login: it is enabled, and its
    /// details mailed, on approval.</summary>
    private async Task CreateLinkedUserAsync(CorporateFormViewModel model, int corporateId, int companyId, int branchId, bool activeNow)
    {
        var email = model.Email.Trim();

        if (await dbContext.Users.AnyAsync(u => u.Username == email))
            return;

        var defaultPassword = LoginCredentialsMailer.DefaultPassword;
        var (hash, salt) = passwordHasherService.HashPassword(defaultPassword);

        var newUser = new Models.Entities.User
        {
            CompanyId       = companyId,
            Username        = email,
            Email           = email,
            PasswordHash    = hash,
            Salt            = salt,
            FullName        = model.Corporate_Name,
            FirstName       = model.Corporate_Name,
            PhoneNumber     = model.Contact_No,
            Phone           = model.Contact_No,
            IsActive        = activeNow,
            UserType        = Models.Entities.UserTypes.Company,
            ReferenceUserId = corporateId,
            MustChangePassword  = true,
            PasswordLastChanged = DateTime.Now,
            CreatedDate         = DateTime.Now,
            LastModifiedDate    = DateTime.Now
        };

        dbContext.Users.Add(newUser);
        await dbContext.SaveChangesAsync();

        dbContext.UserBranches.Add(new UserBranch
        {
            UserId      = newUser.Id,
            BranchId    = branchId,
            IsActive    = true,
            CreatedDate = DateTime.Now,
            ModifiedDate = DateTime.Now,
            CreatedBy   = User.GetUserId(),
            ModifiedBy  = User.GetUserId()
        });
        await dbContext.SaveChangesAsync();

        if (activeNow)
            await credentialsMailer.SendAsync(branchId, null, model.Corporate_Name, email, defaultPassword, $"{Request.Scheme}://{Request.Host}");
    }
}
