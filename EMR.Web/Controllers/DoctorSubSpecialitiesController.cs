using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorSubSpecialitiesController(
    IDoctorSubSpecialityService subSpecialityService,
    IAuditLogService auditLogService,
    IGeneralMasterApiClient masterApiClient) : Controller

{
    public async Task<IActionResult> Index(int? specialityId = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await masterApiClient.GetDoctorSubSpecialitiesAsync(specialityId, companyId, branchId);
            
            ViewBag.SpecialityId = specialityId;
            ViewBag.SpecialityOptions = await subSpecialityService.GetSpecialityOptionsAsync(specialityId);
            
            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor Sub-Speciality Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? specialityId = null)
    {
        var model = new DoctorSubSpecialityFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            SpecialityId = specialityId,
            SpecialityOptions = await subSpecialityService.GetSpecialityOptionsAsync(specialityId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorSubSpecialityFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        model.SubSpecialityCode = model.SubSpecialityCode.Trim().ToUpper();
        model.SubSpecialityName = model.SubSpecialityName.Trim();

        if (await subSpecialityService.CodeExistsAsync(model.SubSpecialityCode, companyId: companyId))
            ModelState.AddModelError(nameof(model.SubSpecialityCode), "This Sub-Speciality Code already exists.");

        if (model.SpecialityId.HasValue && await subSpecialityService.NameExistsAsync(model.SubSpecialityName, model.SpecialityId.Value, companyId: companyId))
            ModelState.AddModelError(nameof(model.SubSpecialityName), "This Sub-Speciality Name already exists under the selected Speciality.");

        if (!ModelState.IsValid)
        {
            model.SpecialityOptions = await subSpecialityService.GetSpecialityOptionsAsync(model.SpecialityId);
            return View(model);
        }

        var newId = await subSpecialityService.CreateAsync(new DoctorSubSpecialityMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? User.GetCurrentBranchId(),
            SpecialityId = model.SpecialityId!.Value,
            SubSpecialityCode = model.SubSpecialityCode,
            SubSpecialityName = model.SubSpecialityName,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorSubSpecialities.Create",
            $"Created sub-speciality: {model.SubSpecialityName} ({model.SubSpecialityCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Doctor Sub-Speciality created successfully.";
        return RedirectToAction(nameof(Index), new { specialityId = model.SpecialityId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await subSpecialityService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new DoctorSubSpecialityFormViewModel
        {
            SubSpecialityId = entity.SubSpecialityId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            SpecialityId = entity.SpecialityId,
            SpecialityName = entity.SpecialityName,
            SubSpecialityCode = entity.SubSpecialityCode,
            SubSpecialityName = entity.SubSpecialityName,
            Description = entity.Description,
            IsActive = entity.IsActive,
            SpecialityOptions = await subSpecialityService.GetSpecialityOptionsAsync(entity.SpecialityId)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorSubSpecialityFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        model.SubSpecialityCode = model.SubSpecialityCode.Trim().ToUpper();
        model.SubSpecialityName = model.SubSpecialityName.Trim();

        if (await subSpecialityService.CodeExistsAsync(model.SubSpecialityCode, excludeId: model.SubSpecialityId, companyId: companyId))
            ModelState.AddModelError(nameof(model.SubSpecialityCode), "This Sub-Speciality Code already exists.");

        if (model.SpecialityId.HasValue && await subSpecialityService.NameExistsAsync(model.SubSpecialityName, model.SpecialityId.Value, excludeId: model.SubSpecialityId, companyId: companyId))
            ModelState.AddModelError(nameof(model.SubSpecialityName), "This Sub-Speciality Name already exists under the selected Speciality.");

        if (!ModelState.IsValid)
        {
            model.SpecialityOptions = await subSpecialityService.GetSpecialityOptionsAsync(model.SpecialityId);
            return View(model);
        }

        await subSpecialityService.UpdateAsync(new DoctorSubSpecialityMaster
        {
            SubSpecialityId = model.SubSpecialityId,
            SpecialityId = model.SpecialityId!.Value,
            SubSpecialityCode = model.SubSpecialityCode,
            SubSpecialityName = model.SubSpecialityName,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorSubSpecialities.Edit",
            $"Updated sub-speciality: {model.SubSpecialityName} ({model.SubSpecialityCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Doctor Sub-Speciality updated successfully.";
        return RedirectToAction(nameof(Index), new { specialityId = model.SpecialityId });
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await subSpecialityService.GetDetailsByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await subSpecialityService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Doctor Sub-Speciality deleted successfully."
            : "Cannot delete this Sub-Speciality.";
        return RedirectToAction(nameof(Index));
    }
}
