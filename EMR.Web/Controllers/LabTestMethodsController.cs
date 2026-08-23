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
public class LabTestMethodsController(
    ILabTestMethodApiClient methodApiClient,
    IGeneralMasterApiClient masterApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? departmentId = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var methods = (await methodApiClient.GetListAsync(branchId, departmentId, status, search, companyId)).ToList();
            var deptOptions = await GetDepartmentOptionsAsync();
            var dashboard = await dashboardService.GetDashboardAsync(branchId, companyId, "LabTestMethods");

            var model = new LabTestMethodIndexViewModel
            {
                Methods = methods,
                SelectedBranchId = branchId,
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
            ViewData["PageName"] = "Test Method Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabTestMethodFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId() ?? 1,
            Display_Order = 1,
            Status = true,
            DepartmentOptions = await GetDepartmentOptionsAsync()
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabTestMethodFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }

        try
        {
            var req = new LabTestMethodCreateRequestModel
            {
                Department_ID = model.Department_ID,
                Method_Name = model.Method_Name,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                BranchId = branchId,
                UserId = User.GetUserId()
            };

            var newId = await methodApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Test Method",
                "Create",
                $"Created Lab Test Method '{model.Method_Name}' with ID #{newId}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Test Method '{model.Method_Name}' created successfully.";
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
            ViewData["PageName"] = "Create Test Method";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await methodApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Method not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabTestMethodFormViewModel
            {
                Method_ID = item.Method_ID,
                CompanyId = item.CompanyId,
                BranchId = item.BranchId,
                Department_ID = item.Department_ID,
                Method_Name = item.Method_Name,
                Method_Code = item.Method_Code,
                Display_Order = item.Display_Order,
                Status = item.Status,
                DepartmentOptions = await GetDepartmentOptionsAsync()
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Test Method";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabTestMethodFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (id != model.Method_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetDepartmentOptionsAsync();
            return View(model);
        }

        try
        {
            var req = new LabTestMethodUpdateRequestModel
            {
                Method_ID = model.Method_ID,
                Department_ID = model.Department_ID,
                Method_Name = model.Method_Name,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await methodApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Test Method",
                "Edit",
                $"Updated Lab Test Method #{model.Method_ID} ('{model.Method_Name}')",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Test Method '{model.Method_Name}' updated successfully.";
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
            ViewData["PageName"] = "Edit Test Method";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await methodApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Test Method not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Test Method Details";
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
            var req = new LabTestMethodToggleStatusRequestModel
            {
                Method_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await methodApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Test Method Status",
                "ToggleStatus",
                $"Toggled status for Lab Test Method #{id} to {(status ? "Active" : "Inactive")}",
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
            await methodApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Test Method",
                "Delete",
                $"Deleted Lab Test Method #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Test Method deleted successfully.";
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
            var departments = await masterApiClient.GetDepartmentsAsync();
            return departments.Select(d => new SelectListItem
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
