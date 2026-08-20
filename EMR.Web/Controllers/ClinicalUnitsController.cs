using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class ClinicalUnitsController(
    IClinicalUnitService clinicalUnitService,
    IAuditLogService auditLogService,
    IGeneralMasterApiClient masterApiClient) : Controller
{
    public async Task<IActionResult> Index(int? departmentId = null, int? specialityId = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await masterApiClient.GetClinicalUnitsAsync(departmentId, specialityId, companyId, branchId);

            ViewBag.DepartmentId = departmentId;
            ViewBag.SpecialityId = specialityId;
            ViewBag.DepartmentOptions = await clinicalUnitService.GetDepartmentOptionsAsync(departmentId);
            ViewBag.SpecialityOptions = await clinicalUnitService.GetSpecialityOptionsAsync(specialityId);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Clinical Unit Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? departmentId = null, int? specialityId = null)
    {
        var branchId = User.GetCurrentBranchId();
        var model = new ClinicalUnitFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = branchId,
            DepartmentId = departmentId,
            SpecialityId = specialityId,
            DepartmentOptions = await clinicalUnitService.GetDepartmentOptionsAsync(departmentId),
            SpecialityOptions = await clinicalUnitService.GetSpecialityOptionsAsync(specialityId),
            DoctorOptions = await clinicalUnitService.GetDoctorOptionsAsync(specialityId, null, branchId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ClinicalUnitFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.UnitCode = model.UnitCode.Trim().ToUpper();
        model.UnitName = model.UnitName.Trim();

        if (await clinicalUnitService.CodeExistsAsync(model.UnitCode, companyId: companyId))
            ModelState.AddModelError(nameof(model.UnitCode), "This Clinical Unit Code already exists.");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await clinicalUnitService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.SpecialityOptions = await clinicalUnitService.GetSpecialityOptionsAsync(model.SpecialityId);
            model.DoctorOptions = await clinicalUnitService.GetDoctorOptionsAsync(model.SpecialityId, model.ConsultantInChargeDoctorId, branchId);
            return View(model);
        }

        var newId = await clinicalUnitService.CreateAsync(new ClinicalUnitMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            DepartmentId = model.DepartmentId!.Value,
            SpecialityId = model.SpecialityId!.Value,
            UnitCode = model.UnitCode,
            UnitName = model.UnitName,
            ConsultantInChargeDoctorId = model.ConsultantInChargeDoctorId,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "ClinicalUnits.Create",
            $"Created clinical unit: {model.UnitName} ({model.UnitCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Clinical Unit created successfully.";
        return RedirectToAction(nameof(Index), new { departmentId = model.DepartmentId, specialityId = model.SpecialityId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await clinicalUnitService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var branchId = entity.BranchId ?? User.GetCurrentBranchId();
        var model = new ClinicalUnitFormViewModel
        {
            UnitId = entity.UnitId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            DepartmentId = entity.DepartmentId,
            SpecialityId = entity.SpecialityId,
            UnitCode = entity.UnitCode,
            UnitName = entity.UnitName,
            ConsultantInChargeDoctorId = entity.ConsultantInChargeDoctorId,
            Description = entity.Description,
            IsActive = entity.IsActive,
            DepartmentOptions = await clinicalUnitService.GetDepartmentOptionsAsync(entity.DepartmentId),
            SpecialityOptions = await clinicalUnitService.GetSpecialityOptionsAsync(entity.SpecialityId),
            DoctorOptions = await clinicalUnitService.GetDoctorOptionsAsync(entity.SpecialityId, entity.ConsultantInChargeDoctorId, branchId)
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(ClinicalUnitFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.UnitCode = model.UnitCode.Trim().ToUpper();
        model.UnitName = model.UnitName.Trim();

        if (await clinicalUnitService.CodeExistsAsync(model.UnitCode, excludeId: model.UnitId, companyId: companyId))
            ModelState.AddModelError(nameof(model.UnitCode), "This Clinical Unit Code already exists.");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await clinicalUnitService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.SpecialityOptions = await clinicalUnitService.GetSpecialityOptionsAsync(model.SpecialityId);
            model.DoctorOptions = await clinicalUnitService.GetDoctorOptionsAsync(model.SpecialityId, model.ConsultantInChargeDoctorId, branchId);
            return View(model);
        }

        await clinicalUnitService.UpdateAsync(new ClinicalUnitMaster
        {
            UnitId = model.UnitId,
            DepartmentId = model.DepartmentId!.Value,
            SpecialityId = model.SpecialityId!.Value,
            UnitCode = model.UnitCode,
            UnitName = model.UnitName,
            ConsultantInChargeDoctorId = model.ConsultantInChargeDoctorId,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "ClinicalUnits.Edit",
            $"Updated clinical unit: {model.UnitName} ({model.UnitCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Clinical Unit updated successfully.";
        return RedirectToAction(nameof(Index), new { departmentId = model.DepartmentId, specialityId = model.SpecialityId });
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await clinicalUnitService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await clinicalUnitService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Clinical Unit deleted successfully."
            : "Cannot delete this Clinical Unit.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetDoctorsBySpeciality(int? specialityId)
    {
        var branchId = User.GetCurrentBranchId();
        var doctors = await clinicalUnitService.GetDoctorsBySpecialityAsync(specialityId, branchId);
        return Json(doctors);
    }
}
