using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
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
public class LabFranchisesController(
    ILabFranchiseApiClient franchiseApiClient,
    ApplicationDbContext dbContext,
    IWebHostEnvironment environment,
    IAuditLogService auditLogService) : Controller
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

            var newId = await franchiseApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Franchise",
                "Create",
                $"Created Lab Franchise '{model.Franchise_Name}' #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Lab Franchise created successfully.";
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

            await franchiseApiClient.UpdateAsync(req);

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
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await franchiseApiClient.DeleteAsync(id);

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
            new() { Value = "2", Text = "Postpaid (Credit)", Selected = selectedId == 2 },
            new() { Value = "3", Text = "Hybrid", Selected = selectedId == 3 }
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
}
