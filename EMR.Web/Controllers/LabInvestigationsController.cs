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
public class LabInvestigationsController(
    ILabInvestigationApiClient investigationApiClient,
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ILabSampleTypeApiClient sampleTypeApiClient,
    ILabTestMethodApiClient methodApiClient,
    ILabUnitApiClient unitApiClient,
    IGeneralMasterApiClient masterApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? departmentId = null, int? categoryId = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var investigations = (await investigationApiClient.GetListAsync(departmentId, categoryId, status, search, companyId)).ToList();
            var deptOptions = await GetDepartmentOptionsAsync();
            var catOptions = await GetCategoryOptionsAsync(departmentId);
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabInvestigations");

            var model = new LabInvestigationIndexViewModel
            {
                Investigations = investigations,
                SelectedDepartmentId = departmentId,
                SelectedCategoryId = categoryId,
                SelectedStatus = status,
                SearchTerm = search,
                DepartmentOptions = deptOptions,
                CategoryOptions = catOptions,
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
            ViewData["PageName"] = "Investigation Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabInvestigationFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            TAT_Hours = 24,
            Status = true,
            DepartmentOptions = await GetDepartmentOptionsAsync(),
            CategoryOptions = await GetCategoryOptionsAsync(),
            SubCategoryOptions = await GetSubCategoryOptionsAsync(),
            SampleTypeOptions = await GetSampleTypeOptionsAsync(),
            MethodOptions = await GetMethodOptionsAsync(),
            UnitOptions = await GetUnitOptionsAsync(),
            ReportingTypeOptions = GetReportingTypeOptions()
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabInvestigationFormViewModel model)
    {
        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var req = new LabInvestigationCreateRequestModel
            {
                Department_ID = model.Department_ID,
                Category_ID = model.Category_ID,
                SubCategory_ID = model.SubCategory_ID,
                Sample_Type_ID = model.Sample_Type_ID,
                Method_ID = model.Method_ID,
                Unit_ID = model.Unit_ID,
                Test_Name = model.Test_Name,
                Reporting_Type = model.Reporting_Type,
                TAT_Hours = model.TAT_Hours,
                NABL_Accredited = model.NABL_Accredited,
                NABL_Scope_No = model.NABL_Accredited ? model.NABL_Scope_No : null,
                Is_Outsourced = model.Is_Outsourced,
                MRP = model.MRP,
                Status = model.Status,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId()
            };

            var newId = await investigationApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Investigation",
                "Create",
                $"Created Lab Investigation '{model.Test_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Investigation Master '{model.Test_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Investigation Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await investigationApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Investigation Master record not found.";
                return RedirectToAction(nameof(Index));
            }

            var model = new LabInvestigationFormViewModel
            {
                Test_ID = item.Test_ID,
                CompanyId = item.CompanyId,
                Test_Code = item.Test_Code,
                Test_Name = item.Test_Name,
                Department_ID = item.Department_ID,
                Category_ID = item.Category_ID,
                SubCategory_ID = item.SubCategory_ID,
                Sample_Type_ID = item.Sample_Type_ID,
                Method_ID = item.Method_ID,
                Unit_ID = item.Unit_ID,
                Reporting_Type = item.Reporting_Type,
                TAT_Hours = item.TAT_Hours ?? 24,
                NABL_Accredited = item.NABL_Accredited,
                NABL_Scope_No = item.NABL_Scope_No,
                Is_Outsourced = item.Is_Outsourced,
                MRP = item.MRP,
                Status = item.Status,
            };

            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Investigation Master";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabInvestigationFormViewModel model)
    {
        if (id != model.Test_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var req = new LabInvestigationUpdateRequestModel
            {
                Test_ID = model.Test_ID,
                Department_ID = model.Department_ID,
                Category_ID = model.Category_ID,
                SubCategory_ID = model.SubCategory_ID,
                Sample_Type_ID = model.Sample_Type_ID,
                Method_ID = model.Method_ID,
                Unit_ID = model.Unit_ID,
                Test_Name = model.Test_Name,
                Reporting_Type = model.Reporting_Type,
                TAT_Hours = model.TAT_Hours,
                NABL_Accredited = model.NABL_Accredited,
                NABL_Scope_No = model.NABL_Accredited ? model.NABL_Scope_No : null,
                Is_Outsourced = model.Is_Outsourced,
                MRP = model.MRP,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await investigationApiClient.UpdateAsync(id, req);

            await auditLogService.LogAsync(
                "Update Lab Investigation",
                "Edit",
                $"Updated Lab Investigation #{id} - '{model.Test_Name}'",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"Investigation Master '{model.Test_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Investigation Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await investigationApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Investigation Master record not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Investigation Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            var req = new LabInvestigationToggleStatusRequestModel
            {
                Test_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await investigationApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Investigation Status",
                "ToggleStatus",
                $"Toggled status for Investigation #{id} to {(status ? "Active" : "Inactive")}",
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
            await investigationApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Investigation",
                "Delete",
                $"Deleted Lab Investigation #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Investigation record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateFormOptionsAsync(LabInvestigationFormViewModel model)
    {
        model.DepartmentOptions = await GetDepartmentOptionsAsync();
        model.CategoryOptions = await GetCategoryOptionsAsync(model.Department_ID);
        model.SubCategoryOptions = await GetSubCategoryOptionsAsync(model.Category_ID);
        model.SampleTypeOptions = await GetSampleTypeOptionsAsync();
        model.MethodOptions = await GetMethodOptionsAsync(model.Department_ID);
        model.UnitOptions = await GetUnitOptionsAsync();
        model.ReportingTypeOptions = GetReportingTypeOptions();
    }

    private async Task<List<SelectListItem>> GetDepartmentOptionsAsync()
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

    private async Task<List<SelectListItem>> GetCategoryOptionsAsync(int? departmentId = null)
    {
        try
        {
            var categories = await categoryApiClient.GetListAsync(departmentId, status: true);
            return categories.Select(c => new SelectListItem { Value = c.Category_ID.ToString(), Text = $"{c.Category_Name} ({c.Category_Code})" }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetSubCategoryOptionsAsync(int? categoryId = null)
    {
        try
        {
            var subCategories = await subCategoryApiClient.GetListAsync(categoryId, status: true);
            return subCategories.Select(s => new SelectListItem { Value = s.SubCategory_ID.ToString(), Text = $"{s.SubCategory_Name} ({s.SubCategory_Code})" }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetSampleTypeOptionsAsync()
    {
        try
        {
            var sampleTypes = await sampleTypeApiClient.GetListAsync(status: true);
            return sampleTypes.Select(s => new SelectListItem { Value = s.Sample_Type_ID.ToString(), Text = $"{s.Sample_Name} ({s.Sample_Code})" }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetMethodOptionsAsync(int? departmentId = null)
    {
        try
        {
            var methods = await methodApiClient.GetListAsync(departmentId, status: true);
            return methods.Select(m => new SelectListItem { Value = m.Method_ID.ToString(), Text = $"{m.Method_Name} ({m.Method_Code})" }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetUnitOptionsAsync()
    {
        try
        {
            var units = await unitApiClient.GetListAsync(status: true);
            return units.Select(u => new SelectListItem { Value = u.Unit_ID.ToString(), Text = $"{u.Unit_Name} ({u.Unit_Symbol})" }).ToList();
        }
        catch { return []; }
    }

    private static List<SelectListItem> GetReportingTypeOptions()
    {
        return
        [
            new SelectListItem { Value = "Numeric", Text = "Numeric" },
            new SelectListItem { Value = "Text", Text = "Text" },
            new SelectListItem { Value = "Descriptive", Text = "Descriptive" },
            new SelectListItem { Value = "Image", Text = "Image" },
            new SelectListItem { Value = "Template", Text = "Template" }
        ];
    }
}
