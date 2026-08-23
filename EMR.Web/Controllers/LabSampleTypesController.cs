using System.ComponentModel.DataAnnotations;
using System.Reflection;
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
public class LabSampleTypesController(
    ILabSampleTypeApiClient sampleTypeApiClient,
    ILabUnitApiClient unitApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(string? containerType = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var sampleTypes = (await sampleTypeApiClient.GetListAsync(branchId, containerType, status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(branchId, companyId, "LabSampleTypes");

            var model = new LabSampleTypeIndexViewModel
            {
                SampleTypes = sampleTypes,
                SelectedBranchId = branchId,
                SelectedContainerType = containerType,
                SelectedStatus = status,
                SearchTerm = search,
                ContainerTypeOptions = GetContainerTypeSelectList(containerType),
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
            ViewData["PageName"] = "Sample Type Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        var model = new LabSampleTypeFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            Display_Order = 1,
            Status = true,
            Volume_Value = 2.00m,
            ContainerTypeOptions = GetContainerTypeSelectList(null),
            UnitOptions = await GetUnitOptionsAsync(branchId, companyId)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabSampleTypeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (!ModelState.IsValid)
        {
            model.ContainerTypeOptions = GetContainerTypeSelectList(model.Container_Type.ToString());
            model.UnitOptions = await GetUnitOptionsAsync(branchId, companyId);
            return View(model);
        }

        try
        {
            var req = new LabSampleTypeCreateRequestModel
            {
                Sample_Name = model.Sample_Name,
                Container_Type = model.Container_Type,
                Volume_Value = model.Volume_Value,
                Unit_ID = model.Unit_ID,
                Volume_Unit = model.Volume_Unit,
                Storage_Temperature = model.Storage_Temperature,
                Rejection_Criteria = model.Rejection_Criteria,
                Display_Order = model.Display_Order,
                CompanyId = companyId,
                BranchId = branchId,
                UserId = User.GetUserId()
            };

            var newId = await sampleTypeApiClient.CreateAsync(req);

            await auditLogService.LogAsync(
                "Create Lab Sample Type",
                "Create",
                $"Created Lab Sample Type '{model.Sample_Name}' with ID #{newId}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Sample Type '{model.Sample_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.ContainerTypeOptions = GetContainerTypeSelectList(model.Container_Type.ToString());
            model.UnitOptions = await GetUnitOptionsAsync(branchId, companyId);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Sample Type";
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
            var item = await sampleTypeApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Type not found.";
                return RedirectToAction(nameof(Index));
            }

            var containerEnum = ParseContainerType(item.Container_Type);

            var model = new LabSampleTypeFormViewModel
            {
                Sample_Type_ID = item.Sample_Type_ID,
                CompanyId = item.CompanyId,
                BranchId = item.BranchId,
                Sample_Name = item.Sample_Name,
                Sample_Code = item.Sample_Code,
                Container_Type = containerEnum,
                Volume_Value = item.Volume_Value,
                Unit_ID = item.Unit_ID,
                Volume_Unit = item.Volume_Unit,
                Storage_Temperature = item.Storage_Temperature,
                Rejection_Criteria = item.Rejection_Criteria,
                Display_Order = item.Display_Order,
                Status = item.Status,
                ContainerTypeOptions = GetContainerTypeSelectList(containerEnum.ToString()),
                UnitOptions = await GetUnitOptionsAsync(branchId, companyId)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Type";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabSampleTypeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (id != model.Sample_Type_ID)
            return BadRequest();

        if (!ModelState.IsValid)
        {
            model.ContainerTypeOptions = GetContainerTypeSelectList(model.Container_Type.ToString());
            model.UnitOptions = await GetUnitOptionsAsync(branchId, companyId);
            return View(model);
        }

        try
        {
            var req = new LabSampleTypeUpdateRequestModel
            {
                Sample_Type_ID = model.Sample_Type_ID,
                Sample_Name = model.Sample_Name,
                Container_Type = model.Container_Type,
                Volume_Value = model.Volume_Value,
                Unit_ID = model.Unit_ID,
                Volume_Unit = model.Volume_Unit,
                Storage_Temperature = model.Storage_Temperature,
                Rejection_Criteria = model.Rejection_Criteria,
                Display_Order = model.Display_Order,
                Status = model.Status,
                UserId = User.GetUserId()
            };

            await sampleTypeApiClient.UpdateAsync(req);

            await auditLogService.LogAsync(
                "Update Lab Sample Type",
                "Edit",
                $"Updated Lab Sample Type #{model.Sample_Type_ID} ('{model.Sample_Name}')",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = $"Sample Type '{model.Sample_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.ContainerTypeOptions = GetContainerTypeSelectList(model.Container_Type.ToString());
            model.UnitOptions = await GetUnitOptionsAsync(branchId, companyId);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Sample Type";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await sampleTypeApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Sample Type not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Sample Type Details";
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
            var req = new LabSampleTypeToggleStatusRequestModel
            {
                Sample_Type_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await sampleTypeApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Sample Type Status",
                "ToggleStatus",
                $"Toggled status for Lab Sample Type #{id} to {(status ? "Active" : "Inactive")}",
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
            await sampleTypeApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Sample Type",
                "Delete",
                $"Deleted Lab Sample Type #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Sample Type deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private static List<SelectListItem> GetContainerTypeSelectList(string? selectedValue)
    {
        return Enum.GetValues<ContainerTypeEnum>()
            .Select(e =>
            {
                var name = e.GetType().GetMember(e.ToString()).FirstOrDefault()?.GetCustomAttribute<DisplayAttribute>()?.GetName() ?? e.ToString();
                return new SelectListItem
                {
                    Value = e.ToString(),
                    Text = name,
                    Selected = selectedValue == e.ToString() || selectedValue == name
                };
            }).ToList();
    }

    private async Task<List<SelectListItem>> GetUnitOptionsAsync(int branchId, int companyId)
    {
        try
        {
            var units = await unitApiClient.GetListAsync(branchId: branchId, status: true, companyId: companyId);
            return units.Select(u => new SelectListItem
            {
                Value = u.Unit_ID.ToString(),
                Text = string.IsNullOrWhiteSpace(u.Unit_Symbol) ? u.Unit_Name : $"{u.Unit_Name} ({u.Unit_Symbol})"
            }).ToList();
        }
        catch
        {
            return [];
        }
    }

    private static ContainerTypeEnum ParseContainerType(string containerTypeStr)
    {
        foreach (var val in Enum.GetValues<ContainerTypeEnum>())
        {
            var name = val.GetType().GetMember(val.ToString()).FirstOrDefault()?.GetCustomAttribute<DisplayAttribute>()?.GetName();
            if (string.Equals(val.ToString(), containerTypeStr, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, containerTypeStr, StringComparison.OrdinalIgnoreCase))
            {
                return val;
            }
        }
        return ContainerTypeEnum.RedTopVial;
    }
}
