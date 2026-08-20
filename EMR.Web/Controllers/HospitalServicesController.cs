using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class HospitalServicesController(
    IHospitalServiceService serviceService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(int? departmentId = null, string? serviceType = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetHospitalServicesAsync(branchId, departmentId, serviceType, companyId);

            ViewBag.DepartmentId = departmentId;
            ViewBag.ServiceType = serviceType;
            ViewBag.DepartmentOptions = await serviceService.GetDepartmentOptionsAsync(departmentId);
            ViewBag.ServiceTypeOptions = serviceService.GetServiceTypeOptions(serviceType);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Hospital Service Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? departmentId = null, string? serviceType = null)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var model = new HospitalServiceFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = branchId,
            DepartmentId = departmentId ?? 0,
            ServiceType = serviceType ?? string.Empty,
            DepartmentOptions = await serviceService.GetDepartmentOptionsAsync(departmentId),
            ServiceTypeOptions = serviceService.GetServiceTypeOptions(serviceType),
            UomOptions = serviceService.GetUomOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(HospitalServiceFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await serviceService.CodeExistsAsync(model.ServiceCode, branchId))
            ModelState.AddModelError(nameof(model.ServiceCode), "This Service Code already exists for the current branch.");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await serviceService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.ServiceTypeOptions = serviceService.GetServiceTypeOptions(model.ServiceType);
            model.UomOptions = serviceService.GetUomOptions(model.UOM);
            return View(model);
        }

        var newId = await serviceService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServices.Create",
            $"Created hospital service: {model.ServiceName} ({model.ServiceCode}) [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Hospital Service '{model.ServiceName}' created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await serviceService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(HospitalServiceFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await serviceService.CodeExistsAsync(model.ServiceCode, branchId, model.HospitalServiceId))
            ModelState.AddModelError(nameof(model.ServiceCode), "This Service Code already exists for the current branch.");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await serviceService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.ServiceTypeOptions = serviceService.GetServiceTypeOptions(model.ServiceType);
            model.UomOptions = serviceService.GetUomOptions(model.UOM);
            return View(model);
        }

        var updated = await serviceService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "HospitalServices.Edit",
            $"Updated hospital service: {model.ServiceName} ({model.ServiceCode}) [ID: {model.HospitalServiceId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Hospital Service '{model.ServiceName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await serviceService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var rates = await serviceService.GetRatesByServiceIdAsync(id);

        var model = new HospitalServiceDetailsViewModel
        {
            Service = entity,
            Rates = rates
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await serviceService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await serviceService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServices.ToggleStatus",
            $"Toggled active status for hospital service: {entity.ServiceName} ({entity.ServiceCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Status updated for '{entity.ServiceName}'.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await serviceService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await serviceService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "HospitalServices.Delete",
            $"Deleted/deactivated hospital service: {entity.ServiceName} ({entity.ServiceCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Hospital Service '{entity.ServiceName}' deleted successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> CheckCode(string code, int? excludeId)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var exists = await serviceService.CodeExistsAsync(code, branchId, excludeId);
        return Json(new { exists });
    }
}
