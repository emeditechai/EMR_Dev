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
    public async Task<IActionResult> Create(int? copyFromId)
    {
        if (copyFromId is > 0)
        {
            // Copy From: the source template opens in the editor as a new, unsaved template (same speciality, no doctors)
            var source = await emrTemplateService.GetByIdAsync(copyFromId.Value);
            if (source is null) { TempData["Error"] = "The template to copy was not found."; return RedirectToAction(nameof(Create)); }
            var copiedFrom = source.TemplateName;
            source.TemplateId = 0;
            source.TemplateName = (source.TemplateName.Length > 140 ? source.TemplateName[..140] : source.TemplateName) + " (copy)";
            source.IsActive = true;
            source.SelectedDoctorIds = [];
            foreach (var sec in source.Sections)
            {
                sec.SectionId = 0;
                foreach (var f in sec.Fields) f.FieldId = 0;
            }
            await PopulateSpecialities(source);
            ViewData["CreateMode"] = true;
            ViewData["CopiedFrom"] = copiedFrom;
            return View("Edit", source);
        }
        var model = new EmrTemplateViewModel();
        await PopulateSpecialities(model);
        return View(model);
    }

    /// <summary>Copy From: the templates of a speciality, and the one a doctor of it uses (SQLScripts/2483).</summary>
    [HttpGet]
    public async Task<IActionResult> CopySources(int specialityId, int? doctorId) =>
        Json(specialityId > 0 ? await emrTemplateService.CopySourcesAsync(specialityId, doctorId) : new { templates = Array.Empty<object>() });

    // ── CREATE POST ──
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmrTemplateViewModel model)
    {
        await ValidateSpecialityMappings(model);

        if (!ModelState.IsValid)
        {
            await PopulateSpecialities(model);
            if (model.Sections.Count == 0) return View(model);
            // keep the canvas as it was: the editor renders the posted sections and fields
            ViewData["CreateMode"] = true;
            return View("Edit", model);
        }

        var userId = User.GetUserId();
        int newId;
        try { newId = await emrTemplateService.CreateAsync(model, userId); }
        catch (EmrTemplateRuleException ex)
        {
            // refused inside the transaction (e.g. another user saved a default for the speciality a moment ago)
            ModelState.AddModelError(nameof(model.SelectedSpecialityIds), ex.Message);
            await PopulateSpecialities(model);
            ViewData["CreateMode"] = true;
            return model.Sections.Count == 0 ? View(model) : View("Edit", model);
        }

        // the template id is the reference (not the user: the signed-in user is taken by the service)
        await auditLogService.LogActivityAsync("Utility", "EmrTemplates.Create", $"Created EMR template '{model.TemplateName}'", referenceId: newId);

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
        bool success;
        try { success = await emrTemplateService.UpdateAsync(model, userId); }
        catch (EmrTemplateRuleException ex)
        {
            ModelState.AddModelError(nameof(model.SelectedSpecialityIds), ex.Message);
            await PopulateSpecialities(model);
            return View(model);
        }
        if (!success) return NotFound();

        await auditLogService.LogActivityAsync("Utility", "EmrTemplates.Update", $"Updated EMR template '{model.TemplateName}'", referenceId: model.TemplateId);

        TempData["Success"] = "EMR Template updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── TOGGLE ACTIVE ──
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleActive(int id)
    {
        // activating: the same rules as saving (one default per speciality, one doctor-specific template per doctor)
        var current = await emrTemplateService.GetByIdAsync(id);
        if (current is null) return NotFound();
        var activate = !current.IsActive;
        if (activate)
        {
            current.IsActive = true;
            await ValidateSpecialityMappings(current);
            if (!ModelState.IsValid)
            {
                TempData["Error"] = "The template cannot be activated: " + string.Join(" ", ModelState.Values.SelectMany(v => v.Errors).Select(e => e.ErrorMessage));
                return RedirectToAction(nameof(Index));
            }
        }
        bool success;
        try { success = await emrTemplateService.SetActiveCheckedAsync(id, activate); }
        catch (EmrTemplateRuleException ex) { TempData["Error"] = "The template cannot be activated: " + ex.Message; return RedirectToAction(nameof(Index)); }
        if (!success) return NotFound();

        await auditLogService.LogActivityAsync("Utility", "EmrTemplates.ToggleActive", $"Toggled active status of EMR template ID {id}", referenceId: id);

        TempData["Success"] = "EMR Template status updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateSpecialities(EmrTemplateViewModel model)
    {
        var specialities = await doctorSpecialityService.GetActiveAsync();
        model.SpecialityOptions = specialities
            .Select(s => new SelectListItem(s.SpecialityName, s.SpecialityId.ToString()))
            .ToList();
        // the doctors of the chosen specialities (the page reloads the list when the specialities change)
        model.DoctorOptions = await emrTemplateService.DoctorOptionsAsync(model.SelectedSpecialityIds ?? [], model.TemplateId, model.SelectedDoctorIds);
    }

    /// <summary>Doctors of the chosen specialities for the "Map to doctors" list (SQLScripts/2483).</summary>
    [HttpGet]
    public async Task<IActionResult> Doctors([FromQuery] List<int> specialityIds, int templateId = 0, [FromQuery] List<int>? doctorIds = null)
    {
        var ids = (specialityIds ?? []).Where(x => x > 0).ToList();
        return Json(new
        {
            // + the doctors already chosen (an inactive one stays visible instead of silently dropping off the template)
            doctors = await emrTemplateService.DoctorOptionsAsync(ids, templateId, doctorIds),
            // the speciality's current default template (another one): this template must then be for doctors
            defaultTemplate = ids.Count == 1 ? await emrTemplateService.SpecialityDefaultAsync(ids[0], templateId) : null
        });
    }

    /// <summary>
    /// Specialities are required. Without doctors the template is the specialities' default: one active default per speciality.
    /// With doctors (SQLScripts/2483) it is doctor-specific: every doctor must be of a chosen speciality, and a doctor has at
    /// most one active doctor-specific template. A doctor-specific template does not take the speciality's default place.
    /// </summary>
    private async Task ValidateSpecialityMappings(EmrTemplateViewModel model)
    {
        model.SelectedSpecialityIds = (model.SelectedSpecialityIds ?? []).Where(x => x > 0).Distinct().ToList();
        if (model.SelectedSpecialityIds.Count == 0)
        {
            ModelState.AddModelError(nameof(model.SelectedSpecialityIds), "Choose the speciality of the template.");
            return;
        }
        if (model.SelectedSpecialityIds.Count > 1)
        {
            ModelState.AddModelError(nameof(model.SelectedSpecialityIds), "A template belongs to one speciality: choose only one.");
            return;
        }
        model.SelectedDoctorIds = (model.SelectedDoctorIds ?? []).Distinct().ToList();
        var co = int.TryParse(User.FindFirst("CompanyId")?.Value, out var c) && c > 0 ? c : 1;

        if (model.SelectedDoctorIds.Count > 0)
        {
            var doctors = await db.DoctorMasters.AsNoTracking()
                .Where(d => model.SelectedDoctorIds.Contains(d.DoctorId))
                .Select(d => new { d.DoctorId, d.FullName, d.PrimarySpecialityId, d.CompanyId, d.IsActive }).ToListAsync();
            foreach (var id in model.SelectedDoctorIds.Where(id => doctors.All(d => d.DoctorId != id)))
                ModelState.AddModelError(nameof(model.SelectedDoctorIds), $"Doctor #{id} was not found.");
            foreach (var d in doctors.Where(d => d.CompanyId != co))
                ModelState.AddModelError(nameof(model.SelectedDoctorIds), $"Dr {d.FullName} is not a doctor of this company.");
            foreach (var d in doctors.Where(d => d.CompanyId == co && !model.SelectedSpecialityIds.Contains(d.PrimarySpecialityId)))
                ModelState.AddModelError(nameof(model.SelectedDoctorIds), $"Dr {d.FullName} is not of a chosen speciality: add the doctor's speciality or remove the doctor.");
        }

        if (!model.IsActive) return;

        if (model.SelectedDoctorIds.Count == 0)
        {
            // the specialities' default template: only one active default per speciality (doctor-specific ones do not count)
            var conflicts = await db.EmrTemplateSpecialityMaps
                .Include(x => x.Template)
                .Include(x => x.Speciality)
                .Where(x => x.IsActive
                         && x.Template!.IsActive
                         && x.Template.CompanyId == co
                         && x.TemplateId != model.TemplateId
                         && model.SelectedSpecialityIds.Contains(x.SpecialityId)
                         && !db.EmrTemplateDoctorMaps.Any(d => d.TemplateId == x.TemplateId && d.IsActive))
                .ToListAsync();
            foreach (var cf in conflicts)
                ModelState.AddModelError(nameof(model.SelectedSpecialityIds),
                    $"Speciality '{cf.Speciality!.SpecialityName}' already has the default template '{cf.Template!.TemplateName}'. Choose doctors to make this a doctor-specific template, or deactivate the other one.");
        }
        else
        {
            // a doctor has at most one active doctor-specific template
            var taken = await (from m in db.EmrTemplateDoctorMaps
                               join t in db.EmrTemplates on m.TemplateId equals t.TemplateId
                               join d in db.DoctorMasters on m.DoctorId equals d.DoctorId
                               where m.IsActive && t.IsActive && t.CompanyId == co && t.TemplateId != model.TemplateId && model.SelectedDoctorIds.Contains(m.DoctorId)
                               select new { d.FullName, t.TemplateName }).ToListAsync();
            foreach (var x in taken)
                ModelState.AddModelError(nameof(model.SelectedDoctorIds), $"Dr {x.FullName} already has the template '{x.TemplateName}'. Remove the doctor here or from that template.");
        }
    }
}
