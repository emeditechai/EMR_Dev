using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class EmrTemplatesController(
    IEmrTemplateService emrTemplateService,
    IDoctorSpecialityService doctorSpecialityService,
    IAuditLogService auditLogService,
    ApplicationDbContext db) : Controller
{
    // ── INDEX ──
    public async Task<IActionResult> Index()
    {
        var list = await emrTemplateService.GetListAsync();
        return View(list);
    }

    // ── CREATE GET ──
    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new EmrTemplateViewModel();
        await PopulateSpecialities(model);
        return View(model);
    }

    // ── CREATE POST ──
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmrTemplateViewModel model)
    {
        await ValidateSpecialityMappings(model);

        if (!ModelState.IsValid)
        {
            await PopulateSpecialities(model);
            return View(model);
        }

        var userId = User.GetUserId();
        var newId = await emrTemplateService.CreateAsync(model, userId);

        await auditLogService.LogAsync("Utility", "EmrTemplates.Create", 
            $"Created EMR template '{model.TemplateName}'", newId);

        TempData["Success"] = "EMR Template created successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── EDIT GET ──
    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await emrTemplateService.GetByIdAsync(id);
        if (model is null) return NotFound();

        await PopulateSpecialities(model);
        return View(model);
    }

    // ── EDIT POST ──
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(EmrTemplateViewModel model)
    {
        await ValidateSpecialityMappings(model);

        if (!ModelState.IsValid)
        {
            await PopulateSpecialities(model);
            return View(model);
        }

        var userId = User.GetUserId();
        var success = await emrTemplateService.UpdateAsync(model, userId);
        if (!success) return NotFound();

        await auditLogService.LogAsync("Utility", "EmrTemplates.Update", 
            $"Updated EMR template '{model.TemplateName}'", model.TemplateId);

        TempData["Success"] = "EMR Template updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── TOGGLE ACTIVE ──
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleActive(int id)
    {
        var success = await emrTemplateService.ToggleActiveAsync(id);
        if (!success) return NotFound();

        await auditLogService.LogAsync("Utility", "EmrTemplates.ToggleActive", 
            $"Toggled active status of EMR template ID {id}", id);

        TempData["Success"] = "EMR Template status updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateSpecialities(EmrTemplateViewModel model)
    {
        var specialities = await doctorSpecialityService.GetActiveAsync();
        model.SpecialityOptions = specialities
            .Select(s => new SelectListItem(s.SpecialityName, s.SpecialityId.ToString()))
            .ToList();
    }

    private async Task ValidateSpecialityMappings(EmrTemplateViewModel model)
    {
        if (model.SelectedSpecialityIds == null || !model.SelectedSpecialityIds.Any())
        {
            ModelState.AddModelError(nameof(model.SelectedSpecialityIds), "At least one Speciality is required.");
            return;
        }

        if (model.IsActive)
        {
            var conflicts = await db.EmrTemplateSpecialityMaps
                .Include(x => x.Template)
                .Include(x => x.Speciality)
                .Where(x => x.IsActive 
                         && x.Template!.IsActive 
                         && x.TemplateId != model.TemplateId 
                         && model.SelectedSpecialityIds.Contains(x.SpecialityId))
                .ToListAsync();

            if (conflicts.Any())
            {
                foreach (var c in conflicts)
                {
                    ModelState.AddModelError(nameof(model.SelectedSpecialityIds), 
                        $"Speciality '{c.Speciality!.SpecialityName}' is already mapped to active template '{c.Template!.TemplateName}'.");
                }
            }
        }
    }
}
