using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.Extensions;
using EMR.Web.Services;

using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

public class LabRateListB2CController(
    ILabRateCardApiClient rateCardApi,
    IGeneralMasterApiClient masterApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ApplicationDbContext dbContext) : Controller
{
    private const string B2CRateType = "B2C";

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
        // 1. Check Session
        var sessionVal = HttpContext.Session.GetString("IsHOBranch");
        if (!string.IsNullOrEmpty(sessionVal) && bool.TryParse(sessionVal, out var isHOSession))
        {
            return isHOSession;
        }

        // 2. Check User Claims
        if (User.IsHOBranch())
        {
            return true;
        }

        // 3. Fallback check DB for the branch
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
        var isHO = CheckIsHOBranch();
        if (!isHO)
        {
            branchId = User.GetCurrentBranchId();
        }
        var list = await rateCardApi.GetListAsync(B2CRateType, branchId, status);
        var result = list.Select(item => new
        {
            item.RateCard_ID,
            item.CompanyId,
            item.Branch_ID,
            item.Branch_Name,
            item.Rate_Type,
            item.Effective_From,
            item.Effective_To,
            item.Status,
            item.ItemCount,
            EncryptedId = encryptionService.EncryptParameters(new Dictionary<string, string?> { { "id", item.RateCard_ID.ToString() } })
        });
        return Json(new { data = result }, new JsonSerializerOptions { PropertyNamingPolicy = null });
    }

    public async Task<IActionResult> Create()
    {
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();
        var branches = await GetBranchListAsync(currentBranchId);
        var allBranches = isHO ? branches : await dbContext.BranchMasters.Where(b => b.IsActive).OrderBy(b => b.BranchName).Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName }).ToListAsync();
        var depts = await GetDepartmentListAsync();
        var cats = await GetCategoryListAsync();
        var subCats = await GetSubCategoryListAsync();

        var vm = new LabRateCardFormViewModel
        {
            IsHOBranch = isHO,
            Branch_ID = currentBranchId ?? 0,
            BranchList = new SelectList(branches, "Value", "Text", currentBranchId),
            SourceBranchList = new SelectList(allBranches, "Value", "Text"),
            DepartmentList = new SelectList(depts, "Value", "Text"),
            CategoryList = new SelectList(cats, "Value", "Text"),
            SubCategoryList = new SelectList(subCats, "Value", "Text")
        };
        return View("Form", vm);
    }

    public async Task<IActionResult> Edit(int id)
    {
        var item = await rateCardApi.GetByIdAsync(id);
        if (item == null) return NotFound();

        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();

        // Non-HO users can only view/edit their own branch rate card
        if (!isHO && currentBranchId.HasValue && item.Header.Branch_ID != currentBranchId.Value)
        {
            TempData["ErrorMessage"] = "You do not have access to manage rate cards for other branches.";
            return RedirectToAction(nameof(Index));
        }

        var branches = await GetBranchListAsync(item.Header.Branch_ID);
        var allBranches = isHO ? branches : await dbContext.BranchMasters.Where(b => b.IsActive).OrderBy(b => b.BranchName).Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName }).ToListAsync();
        var depts = await GetDepartmentListAsync();
        var cats = await GetCategoryListAsync();
        var subCats = await GetSubCategoryListAsync();

        var vm = new LabRateCardFormViewModel
        {
            IsHOBranch = isHO,
            RateCard_ID = item.Header.RateCard_ID,
            CompanyId = item.Header.CompanyId,
            Branch_ID = item.Header.Branch_ID,
            Rate_Type = item.Header.Rate_Type,
            Effective_From = item.Header.Effective_From,
            Effective_To = item.Header.Effective_To,
            Status = item.Header.Status,
            BranchList = new SelectList(branches, "Value", "Text", item.Header.Branch_ID),
            SourceBranchList = new SelectList(allBranches, "Value", "Text"),
            DepartmentList = new SelectList(depts, "Value", "Text"),
            CategoryList = new SelectList(cats, "Value", "Text"),
            SubCategoryList = new SelectList(subCats, "Value", "Text"),
            DetailsJson = JsonSerializer.Serialize(item.Details, new JsonSerializerOptions { PropertyNamingPolicy = null })
        };
        return View("Form", vm);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(LabRateCardFormViewModel vm)
    {
        var isHO = CheckIsHOBranch();
        var currentBranchId = User.GetCurrentBranchId();
        if (!isHO && currentBranchId.HasValue)
        {
            vm.Branch_ID = currentBranchId.Value;
        }

        vm.IsHOBranch = isHO;

        if (!ModelState.IsValid)
        {
            var branches = await GetBranchListAsync(vm.Branch_ID);
            var allBranches = isHO ? branches : await dbContext.BranchMasters.Where(b => b.IsActive).OrderBy(b => b.BranchName).Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName }).ToListAsync();
            var depts = await GetDepartmentListAsync();
            var cats = await GetCategoryListAsync();
            var subCats = await GetSubCategoryListAsync();

            vm.BranchList = new SelectList(branches, "Value", "Text", vm.Branch_ID);
            vm.SourceBranchList = new SelectList(allBranches, "Value", "Text");
            vm.DepartmentList = new SelectList(depts, "Value", "Text");
            vm.CategoryList = new SelectList(cats, "Value", "Text");
            vm.SubCategoryList = new SelectList(subCats, "Value", "Text");
            return View("Form", vm);
        }

        try
        {
            var details = JsonSerializer.Deserialize<List<LabRateCardDetailModel>>(
                vm.DetailsJson, 
                new JsonSerializerOptions { PropertyNamingPolicy = null }
            ) ?? new List<LabRateCardDetailModel>();

            var req = new LabRateCardSaveRequestModel
            {
                RateCard_ID = vm.RateCard_ID,
                CompanyId = vm.CompanyId,
                Branch_ID = vm.Branch_ID,
                Rate_Type = vm.Rate_Type,
                Effective_From = vm.Effective_From,
                Effective_To = vm.Effective_To,
                Status = vm.Status,
                UserId = User.GetUserId() > 0 ? User.GetUserId() : 1,
                Details = details
            };

            await rateCardApi.SaveAsync(req);
            TempData["SuccessMessage"] = "Rate List saved successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError("", ex.Message);
            var branches = await GetBranchListAsync(vm.Branch_ID);
            var allBranches = isHO ? branches : await dbContext.BranchMasters.Where(b => b.IsActive).OrderBy(b => b.BranchName).Select(b => new SelectListItem { Value = b.BranchId.ToString(), Text = b.BranchName }).ToListAsync();
            var depts = await GetDepartmentListAsync();
            var cats = await GetCategoryListAsync();
            var subCats = await GetSubCategoryListAsync();

            vm.BranchList = new SelectList(branches, "Value", "Text", vm.Branch_ID);
            vm.SourceBranchList = new SelectList(allBranches, "Value", "Text");
            vm.DepartmentList = new SelectList(depts, "Value", "Text");
            vm.CategoryList = new SelectList(cats, "Value", "Text");
            vm.SubCategoryList = new SelectList(subCats, "Value", "Text");
            return View("Form", vm);
        }
    }

    [HttpPost]
    public async Task<IActionResult> ToggleStatus([FromBody] LabRateCardToggleStatusRequestModel req)
    {
        try
        {
            req.UserId = 1; // Default
            await rateCardApi.ToggleStatusAsync(req);
            return Json(new { success = true });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpDelete]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await rateCardApi.DeleteAsync(id, 1);
            return Json(new { success = true });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    // Helper for Copy from Branch
    [HttpGet]
    public async Task<IActionResult> GetDetailsForBranch(int branchId)
    {
        // First get the rate card for that branch & rate type
        var cards = await rateCardApi.GetListAsync(B2CRateType, branchId, true);
        var activeCard = cards.FirstOrDefault();
        if (activeCard == null)
        {
            return Json(new { success = false, message = "No active B2C rate card found for selected branch." });
        }

        var fullCard = await rateCardApi.GetByIdAsync(activeCard.RateCard_ID);
        return Json(new { success = true, data = fullCard?.Details ?? new List<LabRateCardDetailModel>() }, new JsonSerializerOptions { PropertyNamingPolicy = null });
    }

    // Helper for Dropdown All Items
    [HttpGet]
    public async Task<IActionResult> GetAllItems()
    {
        var items = await rateCardApi.GetAllItemsAsync();
        return Json(new { success = true, data = items }, new JsonSerializerOptions { PropertyNamingPolicy = null });
    }

    [HttpGet]
    public async Task<IActionResult> GetCategories(int? departmentId = null)
    {
        try
        {
            var categories = await categoryApiClient.GetListAsync(departmentId, status: true);
            var list = categories.Select(c => new { id = c.Category_ID, name = $"{c.Category_Name} ({c.Category_Code})" });
            return Json(new { success = true, data = list });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetSubCategories(int? categoryId = null)
    {
        try
        {
            var subCategories = await subCategoryApiClient.GetListAsync(categoryId, status: true);
            var list = subCategories.Select(s => new { id = s.SubCategory_ID, name = $"{s.SubCategory_Name} ({s.SubCategory_Code})" });
            return Json(new { success = true, data = list });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
    }
}
