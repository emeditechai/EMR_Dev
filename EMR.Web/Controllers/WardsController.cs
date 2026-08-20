using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class WardsController(
    IWardService wardService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(int? floorId = null, int? departmentId = null, string? wardType = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetWardsAsync(floorId, departmentId, wardType, companyId, branchId);

            ViewBag.FloorId = floorId;
            ViewBag.DepartmentId = departmentId;
            ViewBag.WardType = wardType;
            ViewBag.FloorOptions = await wardService.GetFloorOptionsAsync(floorId);
            ViewBag.DepartmentOptions = await wardService.GetIpdDepartmentOptionsAsync(departmentId);
            ViewBag.WardTypeOptions = wardService.GetWardTypeOptions(wardType);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Ward Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? floorId = null, int? departmentId = null)
    {
        var model = new WardFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            FloorId = floorId,
            DepartmentId = departmentId,
            FloorOptions = await wardService.GetFloorOptionsAsync(floorId),
            DepartmentOptions = await wardService.GetIpdDepartmentOptionsAsync(departmentId),
            WardTypeOptions = wardService.GetWardTypeOptions(),
            GenderOptions = wardService.GetGenderOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(WardFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.WardCode = model.WardCode.Trim().ToUpper();
        model.WardName = model.WardName.Trim();

        if (model.WardCode.Length > 5)
            ModelState.AddModelError(nameof(model.WardCode), "Ward Code cannot exceed 5 characters.");

        if (await wardService.CodeExistsAsync(model.WardCode, companyId: companyId))
            ModelState.AddModelError(nameof(model.WardCode), "This Ward Code already exists.");

        if (!ModelState.IsValid)
        {
            model.FloorOptions = await wardService.GetFloorOptionsAsync(model.FloorId);
            model.DepartmentOptions = await wardService.GetIpdDepartmentOptionsAsync(model.DepartmentId);
            model.WardTypeOptions = wardService.GetWardTypeOptions(model.WardType);
            model.GenderOptions = wardService.GetGenderOptions(model.Gender);
            return View(model);
        }

        var newId = await wardService.CreateAsync(new WardMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            FloorId = model.FloorId!.Value,
            DepartmentId = model.DepartmentId!.Value,
            WardCode = model.WardCode,
            WardName = model.WardName,
            WardType = model.WardType,
            Gender = model.Gender,
            Capacity = model.Capacity,
            IsIsolationWard = model.IsIsolationWard,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Wards.Create",
            $"Created ward: {model.WardName} ({model.WardCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Ward created successfully.";
        return RedirectToAction(nameof(Details), new { id = newId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await wardService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new WardFormViewModel
        {
            WardId = entity.WardId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            FloorId = entity.FloorId,
            DepartmentId = entity.DepartmentId,
            WardCode = entity.WardCode,
            WardName = entity.WardName,
            WardType = entity.WardType,
            Gender = entity.Gender,
            Capacity = entity.Capacity,
            IsIsolationWard = entity.IsIsolationWard,
            Description = entity.Description,
            IsActive = entity.IsActive,
            FloorOptions = await wardService.GetFloorOptionsAsync(entity.FloorId),
            DepartmentOptions = await wardService.GetIpdDepartmentOptionsAsync(entity.DepartmentId),
            WardTypeOptions = wardService.GetWardTypeOptions(entity.WardType),
            GenderOptions = wardService.GetGenderOptions(entity.Gender)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(WardFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.WardCode = model.WardCode.Trim().ToUpper();
        model.WardName = model.WardName.Trim();

        if (model.WardCode.Length > 5)
            ModelState.AddModelError(nameof(model.WardCode), "Ward Code cannot exceed 5 characters.");

        if (await wardService.CodeExistsAsync(model.WardCode, excludeId: model.WardId, companyId: companyId))
            ModelState.AddModelError(nameof(model.WardCode), "This Ward Code already exists.");

        if (!ModelState.IsValid)
        {
            model.FloorOptions = await wardService.GetFloorOptionsAsync(model.FloorId);
            model.DepartmentOptions = await wardService.GetIpdDepartmentOptionsAsync(model.DepartmentId);
            model.WardTypeOptions = wardService.GetWardTypeOptions(model.WardType);
            model.GenderOptions = wardService.GetGenderOptions(model.Gender);
            return View(model);
        }

        await wardService.UpdateAsync(new WardMaster
        {
            WardId = model.WardId,
            FloorId = model.FloorId!.Value,
            DepartmentId = model.DepartmentId!.Value,
            WardCode = model.WardCode,
            WardName = model.WardName,
            WardType = model.WardType,
            Gender = model.Gender,
            Capacity = model.Capacity,
            IsIsolationWard = model.IsIsolationWard,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Wards.Edit",
            $"Updated ward: {model.WardName} ({model.WardCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Ward updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await wardService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await wardService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Ward deleted successfully."
            : "Cannot delete this Ward.";
        return RedirectToAction(nameof(Index));
    }
}
