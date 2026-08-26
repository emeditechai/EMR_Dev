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
public class LabTestCategoriesController(
    ILabTestCategoryApiClient categoryApiClient,
    IGeneralMasterApiClient masterApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? departmentId = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var categories = (await categoryApiClient.GetListAsync(departmentId, status, search, companyId)).ToList();
            var deptOptions = await GetDepartmentOptionsAsync();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabTestCategories");

            var model = new LabTestCategoryIndexViewModel
            {
                Categories = categories,
                SelectedDepartmentId = departmentId,
                SelectedStatus = status,
                SearchTerm = search,
                DepartmentOptions = deptOptions,
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
            ViewData["PageName"] = "Test Category Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabTestCategoryFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Display_Order = 1,
            Status = true,
            DepartmentOptions = await GetDepartmentOptionsAsync()
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabTestCategoryFormViewModel model)
    {
        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }

        try
        {
            var req = new LabTestCategoryCreateRequestModel
            {
                Department_ID = model.Department_ID,
                Category_Name = model.Category_Name,
                Display_Order = model.Display_Order,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };

            var newId = await categoryApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Test Category",
                "Create",
                $"Created Lab Test Category '{model.Category_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Test Category '{model.Category_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Test Category";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await categoryApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Category not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabTestCategoryFormViewModel
            {
                Category_ID = item.Category_ID,
                CompanyId = item.CompanyId,
                Department_ID = item.Department_ID,
                Category_Name = item.Category_Name,
                Category_Code = item.Category_Code,
                Display_Order = item.Display_Order,
                Status = item.Status,
                DepartmentOptions = await GetDepartmentOptionsAsync()
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Test Category";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabTestCategoryFormViewModel model)
    {
        if (id != model.Category_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }

        try
        {
            var req = new LabTestCategoryUpdateRequestModel
            {
                Category_ID = model.Category_ID,
                Department_ID = model.Department_ID,
                Category_Name = model.Category_Name,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await categoryApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Test Category",
                "Edit",
                $"Updated Lab Test Category #{model.Category_ID} ('{model.Category_Name}')",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Test Category '{model.Category_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Test Category";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await categoryApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Category not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Test Category Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            var req = new LabTestCategoryToggleStatusRequestModel
            {
                Category_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await categoryApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Test Category Status",
                "ToggleStatus",
                $"Toggled status for Lab Test Category #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
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
        try
        {
            await categoryApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Test Category",
                "Delete",
                $"Deleted Lab Test Category #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Test Category deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task<List<SelectListItem>> GetDepartmentOptionsAsync()
    {
        try
        {
            var departments = await masterApiClient.GetDepartmentsAsync("Lab");
            return departments
                .Where(d => d.IsActive && (string.Equals(d.DeptType, "Lab", StringComparison.OrdinalIgnoreCase) || d.DeptType.Contains("Lab", StringComparison.OrdinalIgnoreCase)))
                .Select(d => new SelectListItem
                {
                    Value = d.DeptId.ToString(),
                    Text = $"{d.DeptName} ({d.DeptCode})"
                }).ToList();
        }
        catch
        {
            return [];
        }
    }
}
