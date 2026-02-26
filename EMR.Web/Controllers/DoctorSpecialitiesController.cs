using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorSpecialitiesController(IDoctorSpecialityService specialityService, IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await specialityService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public IActionResult Create() => View(new DoctorSpecialityFormViewModel());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorSpecialityFormViewModel model)
    {
        if (await specialityService.NameExistsAsync(model.SpecialityName.Trim()))
            ModelState.AddModelError(nameof(model.SpecialityName), "This Speciality Name already exists.");

        if (!ModelState.IsValid) return View(model);

        await specialityService.CreateAsync(new DoctorSpecialityMaster
        {
            SpecialityName = model.SpecialityName.Trim(),
            IsActive       = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorSpecialities.Create", $"Created speciality: {model.SpecialityName.Trim()}");
        TempData["Success"] = "Doctor Speciality created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await specialityService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new DoctorSpecialityFormViewModel
        {
            SpecialityId   = entity.SpecialityId,
            SpecialityName = entity.SpecialityName,
            IsActive       = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorSpecialityFormViewModel model)
    {
        if (await specialityService.NameExistsAsync(model.SpecialityName.Trim(), model.SpecialityId))
            ModelState.AddModelError(nameof(model.SpecialityName), "This Speciality Name already exists.");

        if (!ModelState.IsValid) return View(model);

        await specialityService.UpdateAsync(new DoctorSpecialityMaster
        {
            SpecialityId   = model.SpecialityId,
            SpecialityName = model.SpecialityName.Trim(),
            IsActive       = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorSpecialities.Edit", $"Updated speciality: {model.SpecialityName.Trim()}");
        TempData["Success"] = "Doctor Speciality updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await specialityService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await specialityService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Doctor Speciality deleted successfully."
            : "Cannot delete: Doctors are linked to this Speciality.";
        return RedirectToAction(nameof(Index));
    }
}
