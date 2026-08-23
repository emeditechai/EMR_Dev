using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class LabTestSubCategoriesController(
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? categoryId = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var subCategories = (await subCategoryApiClient.GetListAsync(branchId, categoryId, status, search, companyId)).ToList();
            var categoryOptions = await GetCategoryOptionsAsync(branchId, companyId);
            var dashboard = await dashboardService.GetDashboardAsync(branchId, companyId, "LabTestSubCategories");

            var model = new LabTestSubCategoryIndexViewModel
            {
                SubCategories = subCategories,
                SelectedBranchId = branchId,
                SelectedCategoryId = categoryId,
                SelectedStatus = status,
                SearchTerm = search,
                CategoryOptions = categoryOptions,
                Dashboard = dashboard,
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
            ViewData["PageName"] = "Test Sub Category Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        var model = new LabTestSubCategoryFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            Display_Order = 1,
            Status = true,
            CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabTestSubCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (!ModelState.IsValid)
        {
            model.CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId);
            return View(model);
        }

        try
        {
            var req = new LabTestSubCategoryCreateRequestModel
            {
                Category_ID = model.Category_ID,
                SubCategory_Name = model.SubCategory_Name,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                BranchId = branchId,
                UserId = User.GetUserId()
            };

            var newId = await subCategoryApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Test Sub Category",
                "Create",
                $"Created Lab Test Sub Category '{model.SubCategory_Name}' with ID #{newId}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Test Sub Category '{model.SubCategory_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Test Sub Category";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var item = await subCategoryApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Sub Category not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabTestSubCategoryFormViewModel
            {
                SubCategory_ID = item.SubCategory_ID,
                CompanyId = item.CompanyId,
                BranchId = item.BranchId,
                Category_ID = item.Category_ID,
                SubCategory_Name = item.SubCategory_Name,
                SubCategory_Code = item.SubCategory_Code,
                Display_Order = item.Display_Order,
                Status = item.Status,
                CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Test Sub Category";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabTestSubCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (id != model.SubCategory_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId);
            return View(model);
        }

        try
        {
            var req = new LabTestSubCategoryUpdateRequestModel
            {
                SubCategory_ID = model.SubCategory_ID,
                Category_ID = model.Category_ID,
                SubCategory_Name = model.SubCategory_Name,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await subCategoryApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Test Sub Category",
                "Edit",
                $"Updated Lab Test Sub Category #{model.SubCategory_ID} ('{model.SubCategory_Name}')",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Test Sub Category '{model.SubCategory_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CategoryOptions = await GetCategoryOptionsAsync(branchId, companyId);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Test Sub Category";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await subCategoryApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Sub Category not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Test Sub Category Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            var req = new LabTestSubCategoryToggleStatusRequestModel
            {
                SubCategory_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await subCategoryApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Test Sub Category Status",
                "ToggleStatus",
                $"Toggled status for Lab Test Sub Category #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Status updated successfully.";
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
            await subCategoryApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Test Sub Category",
                "Delete",
                $"Deleted Lab Test Sub Category #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Test Sub Category deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task<List<SelectListItem>> GetCategoryOptionsAsync(int branchId, int companyId)
    {
        try
        {
            var categories = await categoryApiClient.GetListAsync(branchId: branchId, status: true, companyId: companyId);
            return categories.Select(c => new SelectListItem
            {
                Value = c.Category_ID.ToString(),
                Text = $"{c.Category_Name} ({c.Department_Name})"
            }).ToList();
        }
        catch
        {
            return [];
        }
    }
}
