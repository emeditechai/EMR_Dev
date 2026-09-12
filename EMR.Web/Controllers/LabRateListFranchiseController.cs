using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

public class LabRateListFranchiseController(
    ILabRateCardApiClient rateCardApi,
    IGeneralMasterApiClient masterApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ILabFranchiseApiClient franchiseApiClient,
    ApplicationDbContext dbContext) : Controller
{
    private const string FranchiseRateType = "Franchise";

    private async Task<List<SelectListItem>> GetDepartmentListAsync()
    {
        try
        {
            var departments = await masterApiClient.GetDepartmentsAsync("Lab");
            return departments
                .Where(d => d.IsActive && (string.Equals(d.DeptType, "Lab", StringComparison.OrdinalIgnoreCase) || d.DeptType.Contains("Lab", StringComparison.OrdinalIgnoreCase)))
                .Select(d => new SelectListItem { Value = d.DeptId.ToString(), Text = $"{d.DeptName} ({d.DeptCode})" })
                .ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetCategoryListAsync()
    {
        try
        {
            var categories = await categoryApiClient.GetListAsync(status: true);
            return categories.Select(c => new SelectListItem { Value = c.Category_ID.ToString(), Text = $"{c.Category_Name} ({c.Category_Code})" }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetSubCategoryListAsync()
    {
        try
        {
            var subCategories = await subCategoryApiClient.GetListAsync(status: true);
            return subCategories.Select(s => new SelectListItem { Value = s.SubCategory_ID.ToString(), Text = $"{s.SubCategory_Name} ({s.SubCategory_Code})" }).ToList();
        }
        catch { return []; }
    }

    private bool CheckIsHOBranch()
    {
        var sessionVal = HttpContext.Session.GetString("IsHOBranch");
        if (!string.IsNullOrEmpty(sessionVal) && bool.TryParse(sessionVal, out var isHOSession))
        {
            return isHOSession;
        }

        if (User.IsHOBranch())
        {
            return true;
        }

        var currentBranchId = User.GetCurrentBranchId();
        if (currentBranchId.HasValue)
        {
            var branch = dbContext.BranchMasters.Find(currentBranchId.Value);
            return branch?.IsHOBranch == true;
        }

        return false;
    }

    private async Task<List<SelectListItem>> GetBranchListAsync(int? selectedId = null)
    {
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();

        IQueryable<BranchMaster> query = dbContext.BranchMasters.Where(b => b.IsActive);
        if (!isHO && currentBranchId.HasValue)
        {
            query = query.Where(b => b.BranchId == currentBranchId.Value);
        }

        var branches = await query.OrderBy(b => b.BranchName).ToListAsync();
        return branches.Select(b => new SelectListItem
        {
            Value = b.BranchId.ToString(),
            Text = b.BranchName,
            Selected = selectedId.HasValue && b.BranchId == selectedId.Value
        }).ToList();
    }

    private async Task<List<SelectListItem>> GetActiveFranchiseListAsync(int? selectedId = null)
    {
        try
        {
            var list = await franchiseApiClient.GetListAsync();
            // Filter: Status == false (0 means not suspended) AND IsActive == true
            return list
                .Where(f => !f.Status && f.IsActive)
                .OrderBy(f => f.Franchise_Name)
                .Select(f => new SelectListItem
                {
                    Value = f.Franchise_ID.ToString(),
                    Text = $"{f.Franchise_Name} ({f.Franchise_Code})",
                    Selected = selectedId.HasValue && f.Franchise_ID == selectedId.Value
                })
                .ToList();
        }
        catch { return []; }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();
        var branchList = await GetBranchListAsync(isHO ? null : currentBranchId);

        var vm = new LabRateCardIndexViewModel
        {
            IsHOBranch = isHO,
            Branch_ID = isHO ? null : currentBranchId,
            BranchList = new SelectList(branchList, "Value", "Text", isHO ? null : currentBranchId?.ToString())
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> LoadData(int? branchId, bool? status, [FromServices] IQueryStringEncryptionService encryptionService)
    {
        var companyId = User.GetCompanyId();
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();

        int? filterBranchId = isHO ? branchId : currentBranchId;

        var data = await rateCardApi.GetListAsync(FranchiseRateType, filterBranchId, status, companyId);
        var result = data.Select(item => new
        {
            item.RateCard_ID,
            item.CompanyId,
            item.Branch_ID,
            item.Branch_Name,
            item.B2CIdentity_ID,
            item.Entity_Name,
            item.Rate_Type,
            item.Effective_From,
            item.Effective_To,
            item.Status,
            item.ItemCount,
            EncryptedId = encryptionService.EncryptParameters(new Dictionary<string, string?> { { "id", item.RateCard_ID.ToString() } })
        });
        return Json(new { data = result }, new JsonSerializerOptions { PropertyNamingPolicy = null });
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId() ?? 1;

        var branches = await GetBranchListAsync(currentBranchId);
        var sourceBranches = await GetBranchListAsync();
        var franchises = await GetActiveFranchiseListAsync();

        var vm = new LabRateCardFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            IsHOBranch = isHO,
            Branch_ID = currentBranchId,
            BranchList = new SelectList(branches, "Value", "Text", currentBranchId),
            FranchiseList = new SelectList(franchises, "Value", "Text"),
            Rate_Type = FranchiseRateType,
            Effective_From = DateTime.Today,
            Effective_To = new DateTime(2099, 12, 31),
            Status = true,
            SourceBranchList = new SelectList(sourceBranches, "Value", "Text"),
            DepartmentList = new SelectList(await GetDepartmentListAsync(), "Value", "Text"),
            CategoryList = new SelectList(await GetCategoryListAsync(), "Value", "Text"),
            SubCategoryList = new SelectList(await GetSubCategoryListAsync(), "Value", "Text")
        };

        return View("Form", vm);
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var card = await rateCardApi.GetByIdAsync(id);
        if (card == null || card.Header == null)
        {
            return NotFound();
        }

        var isHO = CheckIsHOBranch();
        var branches = await GetBranchListAsync(card.Header.Branch_ID);
        var sourceBranches = await GetBranchListAsync();
        var franchises = await GetActiveFranchiseListAsync(card.Header.B2CIdentity_ID);

        var vm = new LabRateCardFormViewModel
        {
            RateCard_ID = card.Header.RateCard_ID,
            CompanyId = card.Header.CompanyId,
            IsHOBranch = isHO,
            Branch_ID = card.Header.Branch_ID,
            BranchList = new SelectList(branches, "Value", "Text", card.Header.Branch_ID),
            B2CIdentity_ID = card.Header.B2CIdentity_ID,
            FranchiseList = new SelectList(franchises, "Value", "Text", card.Header.B2CIdentity_ID),
            Rate_Type = FranchiseRateType,
            Effective_From = card.Header.Effective_From,
            Effective_To = card.Header.Effective_To,
            Status = card.Header.Status,
            SourceBranchList = new SelectList(sourceBranches, "Value", "Text"),
            DepartmentList = new SelectList(await GetDepartmentListAsync(), "Value", "Text"),
            CategoryList = new SelectList(await GetCategoryListAsync(), "Value", "Text"),
            SubCategoryList = new SelectList(await GetSubCategoryListAsync(), "Value", "Text"),
            DetailsJson = JsonSerializer.Serialize(card.Details)
        };

        return View("Form", vm);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(LabRateCardFormViewModel vm)
    {
        if (!ModelState.IsValid)
        {
            var errors = string.Join(" | ", ModelState.Values.SelectMany(v => v.Errors).Select(e => e.ErrorMessage));
            TempData["ErrorMessage"] = string.IsNullOrWhiteSpace(errors) ? "Please fill all required fields correctly." : errors;
            var isHO = CheckIsHOBranch();
            vm.BranchList = new SelectList(await GetBranchListAsync(vm.Branch_ID), "Value", "Text", vm.Branch_ID);
            vm.FranchiseList = new SelectList(await GetActiveFranchiseListAsync(vm.B2CIdentity_ID), "Value", "Text", vm.B2CIdentity_ID);
            vm.SourceBranchList = new SelectList(await GetBranchListAsync(), "Value", "Text");
            vm.DepartmentList = new SelectList(await GetDepartmentListAsync(), "Value", "Text");
            vm.CategoryList = new SelectList(await GetCategoryListAsync(), "Value", "Text");
            vm.SubCategoryList = new SelectList(await GetSubCategoryListAsync(), "Value", "Text");
            vm.IsHOBranch = isHO;
            return View("Form", vm);
        }

        try
        {
            var details = JsonSerializer.Deserialize<List<LabRateCardDetailModel>>(
                vm.DetailsJson, 
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }
            ) ?? new List<LabRateCardDetailModel>();

            var req = new LabRateCardSaveRequestModel
            {
                RateCard_ID = vm.RateCard_ID,
                CompanyId = vm.CompanyId,
                Branch_ID = vm.Branch_ID,
                B2CIdentity_ID = vm.B2CIdentity_ID,
                Rate_Type = FranchiseRateType,
                Effective_From = vm.Effective_From,
                Effective_To = vm.Effective_To,
                Status = vm.Status,
                UserId = User.GetUserId(),
                Details = details
            };

            var id = await rateCardApi.SaveAsync(req);
            TempData["SuccessMessage"] = "Franchise Rate Card saved successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError("", ex.Message);
            TempData["ErrorMessage"] = ex.Message;
            var isHO = CheckIsHOBranch();
            vm.BranchList = new SelectList(await GetBranchListAsync(vm.Branch_ID), "Value", "Text", vm.Branch_ID);
            vm.FranchiseList = new SelectList(await GetActiveFranchiseListAsync(vm.B2CIdentity_ID), "Value", "Text", vm.B2CIdentity_ID);
            vm.SourceBranchList = new SelectList(await GetBranchListAsync(), "Value", "Text");
            vm.DepartmentList = new SelectList(await GetDepartmentListAsync(), "Value", "Text");
            vm.CategoryList = new SelectList(await GetCategoryListAsync(), "Value", "Text");
            vm.SubCategoryList = new SelectList(await GetSubCategoryListAsync(), "Value", "Text");
            vm.IsHOBranch = isHO;
            return View("Form", vm);
        }
    }

    [HttpPost]
    public async Task<IActionResult> ToggleStatus([FromBody] LabRateCardToggleStatusRequestModel req)
    {
        req.UserId = User.GetUserId();
        var success = await rateCardApi.ToggleStatusAsync(req);
        return Json(new { success });
    }

    [HttpDelete]
    public async Task<IActionResult> Delete(int id)
    {
        var userId = User.GetUserId();
        var success = await rateCardApi.DeleteAsync(id, userId);
        return Json(new { success });
    }

    [HttpGet]
    public async Task<IActionResult> GetCategories(int? departmentId)
    {
        try
        {
            var categories = await categoryApiClient.GetListAsync(departmentId: departmentId, status: true);
            var data = categories.Select(c => new { id = c.Category_ID, name = $"{c.Category_Name} ({c.Category_Code})" });
            return Json(new { success = true, data });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetSubCategories(int? categoryId)
    {
        try
        {
            var subCategories = await subCategoryApiClient.GetListAsync(categoryId: categoryId, status: true);
            var data = subCategories.Select(s => new { id = s.SubCategory_ID, name = $"{s.SubCategory_Name} ({s.SubCategory_Code})" });
            return Json(new { success = true, data });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetAllItems()
    {
        try
        {
            var items = await rateCardApi.GetAllItemsAsync(User.GetCompanyId());
            return Json(new { success = true, data = items });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetDetailsForBranch(int branchId)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var list = await rateCardApi.GetListAsync(FranchiseRateType, branchId, true, companyId);
            var latestHeader = list.OrderByDescending(x => x.Effective_From).FirstOrDefault();
            if (latestHeader == null)
            {
                return Json(new { success = true, data = new List<LabRateCardDetailModel>() });
            }

            var fullCard = await rateCardApi.GetByIdAsync(latestHeader.RateCard_ID);
            return Json(new { success = true, data = fullCard?.Details ?? new List<LabRateCardDetailModel>() });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }
}
