using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class LabFranchisesController(
    ILabFranchiseApiClient franchiseApiClient,
    ApplicationDbContext dbContext,
    IWebHostEnvironment environment,
    IAuditLogService auditLogService,
    IPasswordHasherService passwordHasherService,
    IMasterApprovalService approvals,
    ILoginCredentialsMailer credentialsMailer) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(
        int? franchiseType = null,
        int? parentBranchId = null,
        bool? status = null,
        bool? isActive = null,
        string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var franchises = (await franchiseApiClient.GetListAsync(
                status: status,
                isActive: isActive,
                search: search,
                companyId: companyId,
                franchiseType: franchiseType,
                parentBranchId: parentBranchId
            )).ToList();

            var branches = await GetBranchOptionsAsync(companyId, parentBranchId);
            ViewBag.ApprovalStates = await approvals.GetOpenStatesAsync(companyId, ApprovalModules.Franchise);

            var model = new LabFranchiseIndexViewModel
            {
                Franchises = franchises,
                SelectedFranchiseType = franchiseType,
                SelectedParentBranchId = parentBranchId,
                SelectedStatus = status,
                SelectedIsActive = isActive,
                SearchTerm = search,
                FranchiseTypeOptions = GetFranchiseTypeOptions(franchiseType),
                BranchOptions = branches,
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Suspended Only", Selected = status == true },
                    new() { Value = "false", Text = "Active (Non-Suspended) Only", Selected = status == false }
                },
                IsActiveOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = isActive == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = isActive == false }
                }
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Franchise Setup Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var currentBranchId = User.GetCurrentBranchId() ?? 1;

        var model = new LabFranchiseWizardViewModel
        {
            CompanyId = companyId,
            Parent_Branch_ID = currentBranchId,
            Onboarding_Date = DateTime.Today,
            Go_Live_Date = DateTime.Today.AddDays(7),
            Agreement_Valid_From = DateTime.Today,
            Agreement_Valid_To = DateTime.Today.AddYears(1),
            Status = false,
            IsActive = true,
            Credit_Facility_Type = 1,
            Credit_Limit = 50000,
            Credit_Days = 30,
            Grace_Days = 7,
            Security_Deposit_Amount = 10000,
            FranchiseTypeOptions = GetFranchiseTypeOptions(null),
            ParentBranchOptions = await GetBranchOptionsAsync(companyId, currentBranchId),
            CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(null)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabFranchiseWizardViewModel model)
    {
        var companyId = User.GetCompanyId();
        ApplyPrepaidRules(model);

        if (!ModelState.IsValid)
        {
            model.FranchiseTypeOptions = GetFranchiseTypeOptions(model.Franchise_Type);
            model.ParentBranchOptions = await GetBranchOptionsAsync(companyId, model.Parent_Branch_ID);
            model.CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(model.Credit_Facility_Type);
            return View(model);
        }

        try
        {
            // Handle agreement file upload if provided
            string? docPath = model.Agreement_Doc_Path;
            if (model.Agreement_Doc_File != null && model.Agreement_Doc_File.Length > 0)
            {
                docPath = await UploadAgreementFileAsync(model.Agreement_Doc_File);
            }

            var req = new LabFranchiseCreateRequestModel
            {
                CompanyId = companyId,
                Franchise_Name = model.Franchise_Name.Trim(),
                Mobile_No = model.Mobile_No.Trim(),
                Email = model.Email?.Trim(),
                Franchise_Type = model.Franchise_Type,
                Parent_Branch_ID = model.Parent_Branch_ID,
                Onboarding_Date = model.Onboarding_Date,
                Go_Live_Date = model.Go_Live_Date,
                Agreement_Doc_Path = docPath,
                Agreement_Valid_From = model.Agreement_Valid_From,
                Agreement_Valid_To = model.Agreement_Valid_To,
                Status = model.Status,
                IsActive = model.IsActive,
                IsNotificationRequired = model.IsNotificationRequired,
                PreprintedBarcode = model.PreprintedBarcode,
                IsReportHeaderRequired = model.IsReportHeaderRequired,
                Credit_Facility_Type = model.Credit_Facility_Type,
                Credit_Limit = model.Credit_Limit,
                Credit_Days = model.Credit_Days,
                Grace_Days = model.Grace_Days,
                Security_Deposit_Amount = model.Security_Deposit_Amount,
                Security_Deposit_Received_On = model.Security_Deposit_Received_On,
                Interest_On_Overdue_Percent = model.Interest_On_Overdue_Percent,
                Temporary_Limit_Increase = model.Temporary_Limit_Increase,
                Temp_Limit_Valid_Till = model.Temp_Limit_Valid_Till,
                UserId = User.GetUserId()
            };

            // under approval the franchise is saved inactive (not offered in B2B rates or billing) until approved
            var matrix = await approvals.FindMatrixAsync(companyId, ApprovalModules.Franchise, model.Parent_Branch_ID);
            if (matrix is not null) req.IsActive = false;

            var newId = await franchiseApiClient.CreateAsync(req);

            var loginNote = await CreateLinkedUserAsync(model, newId, companyId, activeNow: matrix is null);

            if (matrix is not null)
            {
                req.IsActive = model.IsActive;
                await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Franchise, Matrix = matrix, CompanyId = companyId, BranchId = model.Parent_Branch_ID,
                    EntityId = newId, EntityName = model.Franchise_Name.Trim(), ActionType = "CREATE", RequestedActive = model.IsActive,
                    NewValues = req, UserId = User.GetUserId()
                });
            }

            await auditLogService.LogAsync(
                "Create Lab Franchise",
                "Create",
                $"Created Lab Franchise '{model.Franchise_Name}' #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = matrix is null
                ? "Lab Franchise created successfully."
                : "Lab Franchise saved and sent for approval. It becomes active for B2B rates and billing, and its login is enabled, once approved.";
            if (loginNote != null) TempData["Warning"] = loginNote;   // the login / credentials email did not go through
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.FranchiseTypeOptions = GetFranchiseTypeOptions(model.Franchise_Type);
            model.ParentBranchOptions = await GetBranchOptionsAsync(companyId, model.Parent_Branch_ID);
            model.CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(model.Credit_Facility_Type);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Lab Franchise";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var item = await franchiseApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Lab Franchise not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabFranchiseWizardViewModel
            {
                Franchise_ID = item.Franchise_ID,
                CompanyId = item.CompanyId,
                Franchise_Code = item.Franchise_Code,
                Franchise_Name = item.Franchise_Name,
                Mobile_No = item.Mobile_No,
                Email = item.Email,
                Franchise_Type = item.Franchise_Type,
                Parent_Branch_ID = item.Parent_Branch_ID,
                Onboarding_Date = item.Onboarding_Date,
                Go_Live_Date = item.Go_Live_Date,
                Agreement_Doc_Path = item.Agreement_Doc_Path,
                Agreement_Valid_From = item.Agreement_Valid_From,
                Agreement_Valid_To = item.Agreement_Valid_To,
                Status = item.Status,
                IsActive = item.IsActive,
                IsNotificationRequired = item.IsNotificationRequired,
                PreprintedBarcode = item.PreprintedBarcode,
                IsReportHeaderRequired = item.IsReportHeaderRequired,
                Bypass_Credit_Limit = item.Bypass_Credit_Limit,
                Bypass_Effective_From = item.Bypass_Effective_From,
                Bypass_Effective_To = item.Bypass_Effective_To,
                Bypass_Updated_Date = item.Bypass_Updated_Date,
                Bypass_Updated_By_Name = item.Bypass_Updated_By_Name,

                Credit_ID = item.Credit_ID,
                Credit_Facility_Type = item.Credit_Facility_Type,
                Credit_Limit = item.Credit_Limit,
                Credit_Days = item.Credit_Days,
                Grace_Days = item.Grace_Days,
                Security_Deposit_Amount = item.Security_Deposit_Amount,
                Security_Deposit_Received_On = item.Security_Deposit_Received_On,
                Interest_On_Overdue_Percent = item.Interest_On_Overdue_Percent,
                Temporary_Limit_Increase = item.Temporary_Limit_Increase,
                Temp_Limit_Valid_Till = item.Temp_Limit_Valid_Till,

                FranchiseTypeOptions = GetFranchiseTypeOptions(item.Franchise_Type),
                ParentBranchOptions = await GetBranchOptionsAsync(companyId, item.Parent_Branch_ID),
                CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(item.Credit_Facility_Type)
            };

            var open = await approvals.GetOpenAsync(ApprovalModules.Franchise, id);
            if (open is { IsPendingCreate: true, Requested_Active: bool wanted }) model.IsActive = wanted;
            ViewBag.ApprovalOpen = open;

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Lab Franchise";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabFranchiseWizardViewModel model)
    {
        // a record waiting for approval cannot be changed until the approver acts (a sent-back one can)
        if (await approvals.GetOpenAsync(ApprovalModules.Franchise, id) is { Status: "P" })
        {
            TempData["ErrorMessage"] = "This franchise is awaiting approval and cannot be edited until the approver approves it or sends it back.";
            return RedirectToAction(nameof(Index));
        }

        ApplyPrepaidRules(model);
        var companyId = User.GetCompanyId();

        if (id != model.Franchise_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.FranchiseTypeOptions = GetFranchiseTypeOptions(model.Franchise_Type);
            model.ParentBranchOptions = await GetBranchOptionsAsync(companyId, model.Parent_Branch_ID);
            model.CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(model.Credit_Facility_Type);
            return View(model);
        }

        try
        {
            string? docPath = model.Agreement_Doc_Path;
            if (model.Agreement_Doc_File != null && model.Agreement_Doc_File.Length > 0)
            {
                docPath = await UploadAgreementFileAsync(model.Agreement_Doc_File);
            }

            var req = new LabFranchiseUpdateRequestModel
            {
                Franchise_ID = model.Franchise_ID,
                Franchise_Name = model.Franchise_Name.Trim(),
                Mobile_No = model.Mobile_No.Trim(),
                Email = model.Email?.Trim(),
                Franchise_Type = model.Franchise_Type,
                Parent_Branch_ID = model.Parent_Branch_ID,
                Onboarding_Date = model.Onboarding_Date,
                Go_Live_Date = model.Go_Live_Date,
                Agreement_Doc_Path = docPath,
                Agreement_Valid_From = model.Agreement_Valid_From,
                Agreement_Valid_To = model.Agreement_Valid_To,
                Status = model.Status,
                IsActive = model.IsActive,
                IsNotificationRequired = model.IsNotificationRequired,
                PreprintedBarcode = model.PreprintedBarcode,
                IsReportHeaderRequired = model.IsReportHeaderRequired,
                Credit_Facility_Type = model.Credit_Facility_Type,
                Credit_Limit = model.Credit_Limit,
                Credit_Days = model.Credit_Days,
                Grace_Days = model.Grace_Days,
                Security_Deposit_Amount = model.Security_Deposit_Amount,
                Security_Deposit_Received_On = model.Security_Deposit_Received_On,
                Interest_On_Overdue_Percent = model.Interest_On_Overdue_Percent,
                Temporary_Limit_Increase = model.Temporary_Limit_Increase,
                Temp_Limit_Valid_Till = model.Temp_Limit_Valid_Till,
                UserId = User.GetUserId()
            };

            var open = await approvals.GetOpenAsync(ApprovalModules.Franchise, model.Franchise_ID);
            var matrix = await approvals.FindMatrixAsync(companyId, ApprovalModules.Franchise, model.Parent_Branch_ID);

            if (matrix is not null && open is { IsPendingCreate: true })
            {
                // not approved yet: the record stays inactive and goes back for approval with these values
                req.IsActive = false;
                await franchiseApiClient.UpdateAsync(req);
                req.IsActive = model.IsActive;
                await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Franchise, Matrix = matrix, CompanyId = companyId, BranchId = model.Parent_Branch_ID,
                    EntityId = model.Franchise_ID, EntityName = req.Franchise_Name, ActionType = "CREATE", RequestedActive = model.IsActive,
                    NewValues = req, UserId = User.GetUserId()
                });
                TempData["SuccessMessage"] = "Lab Franchise saved and sent for approval again.";
                return RedirectToAction(nameof(Index));
            }

            if (matrix is not null)
            {
                // an approved franchise keeps working on its current values until the change is approved
                var current = await franchiseApiClient.GetByIdAsync(model.Franchise_ID);
                var old = current is null ? null : CopyAs<LabFranchiseUpdateRequestModel>(current);
                if (old is not null) old.UserId = req.UserId;
                var requestId = await approvals.SubmitAsync(new ApprovalSubmission
                {
                    ModuleCode = ApprovalModules.Franchise, Matrix = matrix, CompanyId = companyId, BranchId = model.Parent_Branch_ID,
                    EntityId = model.Franchise_ID, EntityName = req.Franchise_Name, ActionType = "UPDATE",
                    OldValues = old, NewValues = req, UserId = User.GetUserId()
                });
                TempData["SuccessMessage"] = requestId == 0
                    ? "Nothing was changed, so nothing was sent for approval."
                    : "The change was sent for approval. The franchise keeps its current details until it is approved.";
                return RedirectToAction(nameof(Index));
            }

            await franchiseApiClient.UpdateAsync(req);
            if (open is { IsPendingCreate: true })
            {
                // the approval for this module was switched off while the franchise was waiting: it is live now
                await approvals.CloseAsync(ApprovalModules.Franchise, model.Franchise_ID, User.GetUserId(), "Approval no longer configured");
                await ActivateLinkedLoginAsync(model.Franchise_ID);
            }

            await auditLogService.LogAsync(
                "Update Lab Franchise",
                "Edit",
                $"Updated Lab Franchise '{model.Franchise_Name}' #{model.Franchise_ID}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Lab Franchise updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.FranchiseTypeOptions = GetFranchiseTypeOptions(model.Franchise_Type);
            model.ParentBranchOptions = await GetBranchOptionsAsync(companyId, model.Parent_Branch_ID);
            model.CreditFacilityTypeOptions = GetCreditFacilityTypeOptions(model.Credit_Facility_Type);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Lab Franchise";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await franchiseApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Lab Franchise not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Lab Franchise Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool isActive)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        if (await approvals.GetOpenAsync(ApprovalModules.Franchise, id) is { IsPendingCreate: true })
        {
            TempData["ErrorMessage"] = "This franchise is awaiting approval. It becomes active once approved.";
            return RedirectToAction(nameof(Index));
        }
        try
        {
            var req = new LabFranchiseToggleStatusRequestModel
            {
                Franchise_ID = id,
                IsActive = isActive,
                UserId = User.GetUserId()
            };

            await franchiseApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Franchise Active Status",
                "ToggleStatus",
                $"Toggled active status for Lab Franchise #{id} to {(isActive ? "Active" : "Inactive")}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Active status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleSuspension(int id, bool status, string? suspensionReason)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            var req = new LabFranchiseToggleSuspensionRequestModel
            {
                Franchise_ID = id,
                Status = status,
                Suspension_Reason = suspensionReason,
                UserId = User.GetUserId()
            };

            await franchiseApiClient.ToggleSuspensionAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Franchise Suspension Status",
                "ToggleSuspension",
                $"Toggled suspension status for Lab Franchise #{id} to {(status ? "Suspended" : "Active")}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = status ? "Franchise suspended successfully." : "Franchise unsuspended successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission("MASTER.LABFRANCHISES", PermissionControls.Edit)]
    public async Task<IActionResult> UpdateCreditBypass(int id, bool bypassCreditLimit, DateTime? effectiveFrom, DateTime? effectiveTo)
    {
        if (bypassCreditLimit)
        {
            if (effectiveFrom is null || effectiveTo is null)
                return Json(new { success = false, message = "Effective From and Effective To are required to bypass the credit limit." });
            if (effectiveTo < effectiveFrom)
                return Json(new { success = false, message = "Effective To cannot be earlier than Effective From." });
        }

        try
        {
            await franchiseApiClient.UpdateCreditBypassAsync(new LabFranchiseCreditBypassRequestModel
            {
                Franchise_ID = id,
                Bypass_Credit_Limit = bypassCreditLimit,
                Bypass_Effective_From = bypassCreditLimit ? effectiveFrom : null,
                Bypass_Effective_To = bypassCreditLimit ? effectiveTo : null,
                UserId = User.GetUserId()
            });

            await auditLogService.LogAsync(
                "Lab Franchise Credit Limit Bypass",
                "UpdateCreditBypass",
                bypassCreditLimit
                    ? $"Credit limit bypass ON for Lab Franchise #{id} from {effectiveFrom:dd-MMM-yyyy} to {effectiveTo:dd-MMM-yyyy}"
                    : $"Credit limit bypass OFF for Lab Franchise #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1);

            return Json(new { success = true, message = bypassCreditLimit ? "Credit limit bypass saved." : "Credit limit bypass turned off." });
        }
        catch (InvalidOperationException ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is not reachable. Please try again." });
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await franchiseApiClient.DeleteAsync(id);
            await approvals.CloseAsync(ApprovalModules.Franchise, id, User.GetUserId(), "Record deleted");

            await auditLogService.LogAsync(
                "Delete Lab Franchise",
                "Delete",
                $"Deleted Lab Franchise #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Lab Franchise deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    // Helper Methods
    private static List<SelectListItem> GetFranchiseTypeOptions(int? selectedId)
    {
        return new List<SelectListItem>
        {
            new() { Value = "1", Text = "Collection Center", Selected = selectedId == 1 },
            new() { Value = "2", Text = "Franchise Lab", Selected = selectedId == 2 },
            new() { Value = "3", Text = "Pickup Point", Selected = selectedId == 3 },
            new() { Value = "4", Text = "Marketing", Selected = selectedId == 4 }
        };
    }

    private static List<SelectListItem> GetCreditFacilityTypeOptions(int? selectedId)
    {
        return new List<SelectListItem>
        {
            new() { Value = "1", Text = "Prepaid (Wallet)", Selected = selectedId == 1 },
            new() { Value = "2", Text = "Postpaid (Credit)", Selected = selectedId == 2 }
        };
    }

    private async Task<List<SelectListItem>> GetBranchOptionsAsync(int companyId, int? selectedId)
    {
        return await dbContext.BranchMasters
            .Where(b => b.CompanyId == companyId && b.IsActive)
            .OrderBy(b => b.BranchName)
            .Select(b => new SelectListItem
            {
                Value = b.BranchId.ToString(),
                Text = $"{b.BranchName} ({b.BranchCode})",
                Selected = selectedId.HasValue && selectedId.Value == b.BranchId
            })
            .ToListAsync();
    }

    private async Task<string> UploadAgreementFileAsync(IFormFile file)
    {
        var uploadsFolder = Path.Combine(environment.WebRootPath, "uploads", "franchise_docs");
        if (!Directory.Exists(uploadsFolder))
        {
            Directory.CreateDirectory(uploadsFolder);
        }

        var uniqueFileName = $"{Guid.NewGuid()}_{Path.GetFileName(file.FileName)}";
        var filePath = Path.Combine(uploadsFolder, uniqueFileName);

        using var fileStream = new FileStream(filePath, FileMode.Create);
        await file.CopyToAsync(fileStream);

        return $"/uploads/franchise_docs/{uniqueFileName}";
    }

    /// <summary>A Prepaid (Wallet) franchise has no credit terms: whatever was posted for them is dropped.</summary>
    private void ApplyPrepaidRules(LabFranchiseWizardViewModel model)
    {
        if (model.Credit_Facility_Type is not (1 or 2))
            ModelState.AddModelError(nameof(model.Credit_Facility_Type), "Choose Prepaid (Wallet) or Postpaid (Credit).");
        if (model.Credit_Facility_Type != 1) return;
        model.Credit_Limit = 0;
        model.Credit_Days = null;
        model.Grace_Days = 0;
        model.Security_Deposit_Amount = null;
        model.Security_Deposit_Received_On = null;
        model.Interest_On_Overdue_Percent = null;
        model.Temporary_Limit_Increase = 0;
        model.Temp_Limit_Valid_Till = null;
        foreach (var key in new[] { nameof(model.Credit_Limit), nameof(model.Credit_Days), nameof(model.Grace_Days), nameof(model.Security_Deposit_Amount),
                                    nameof(model.Security_Deposit_Received_On), nameof(model.Interest_On_Overdue_Percent),
                                    nameof(model.Temporary_Limit_Increase), nameof(model.Temp_Limit_Valid_Till) })
            ModelState.Remove(key);
    }

    /// <summary>Creates the franchise's login and emails its details. Returns null when all went through, otherwise
    /// what the user creating the franchise must know (no login made / the email could not be sent).
    /// A franchise under approval gets a disabled login: it is enabled, and its details mailed, on approval.</summary>
    private async Task<string?> CreateLinkedUserAsync(LabFranchiseWizardViewModel model, int franchiseId, int companyId, bool activeNow)
    {
        var email = model.Email.Trim();

        // sign-in is by e-mail (SQLScripts/2307): unique among all sign-ins
        var lowerEmail = email.ToLower();
        if (await dbContext.Users.AnyAsync(u => u.Username == email || (u.Email != null && u.Email.Trim().ToLower() == lowerEmail)))
            return $"No login was created for this franchise: the e-mail {email} is already used by another sign-in.";

        var defaultPassword = LoginCredentialsMailer.DefaultPassword;
        var (hash, salt) = passwordHasherService.HashPassword(defaultPassword);

        var newUser = new Models.Entities.User
        {
            CompanyId       = companyId,
            Username        = email,
            Email           = email,
            PasswordHash    = hash,
            Salt            = salt,
            FullName        = model.Franchise_Name,
            FirstName       = model.Franchise_Name,
            PhoneNumber     = model.Mobile_No,
            Phone           = model.Mobile_No,
            IsActive        = activeNow,
            UserType        = Models.Entities.UserTypes.Franchise,
            ReferenceUserId = franchiseId,
            MustChangePassword  = true,
            PasswordLastChanged = DateTime.Now,
            CreatedDate         = DateTime.Now,
            LastModifiedDate    = DateTime.Now
        };

        dbContext.Users.Add(newUser);
        await dbContext.SaveChangesAsync();

        var branchId = model.Parent_Branch_ID > 0 ? model.Parent_Branch_ID : (User.GetCurrentBranchId() ?? 1);
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

        // a login cannot sign in without a role: every franchise login carries the "Franchise" role
        var franchiseRole = await dbContext.Roles.OrderBy(r => r.Id).FirstOrDefaultAsync(r => r.Name == "Franchise");   // roles are global (script 2334)
        if (franchiseRole is null)
        {
            franchiseRole = new Role { Name = "Franchise", Description = "Franchise-level access", IconClass = "fas fa-building", CompanyId = 1 };
            dbContext.Roles.Add(franchiseRole);
            await dbContext.SaveChangesAsync();
        }
        dbContext.UserRoles.Add(new UserRole
        {
            UserId       = newUser.Id,
            RoleId       = franchiseRole.Id,
            Branch_ID    = branchId,
            IsActive     = true,
            AssignedDate = DateTime.Now,
            AssignedBy   = User.GetUserId(),
            CreatedBy    = User.GetUserId(),
            CreatedDate  = DateTime.Now
        });
        await dbContext.SaveChangesAsync();
        if (!activeNow) return null;

        var (sent, reason) = await credentialsMailer.SendAsync(branchId, User.GetCurrentBranchId(), model.Franchise_Name, email, defaultPassword,
            $"{Request.Scheme}://{Request.Host}");
        return sent ? null
            : $"The franchise login {email} was created, but its login details could not be emailed ({reason}). Please share them with the franchise.";
    }

    /// <summary>A franchise that went live without an approval: its login (made disabled) is enabled.</summary>
    private async Task ActivateLinkedLoginAsync(int franchiseId)
    {
        var login = await dbContext.Users.FirstOrDefaultAsync(u => u.UserType == Models.Entities.UserTypes.Franchise && u.ReferenceUserId == franchiseId);
        if (login is null || login.IsActive) return;
        login.IsActive = true;
        login.LastModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();
    }

    private static T? CopyAs<T>(object source) =>
        System.Text.Json.JsonSerializer.Deserialize<T>(System.Text.Json.JsonSerializer.Serialize(source, source.GetType()));
}
