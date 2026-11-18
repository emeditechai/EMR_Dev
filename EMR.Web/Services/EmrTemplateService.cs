using System.Text.Json;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class EmrTemplateService(ApplicationDbContext db, IHttpContextAccessor http) : IEmrTemplateService
{
    // EMR templates are company-wise: the signed-in user's company (script 2336 copies them between companies)
    private int Co => int.TryParse(http.HttpContext?.User?.FindFirst("CompanyId")?.Value, out var c) && c > 0 ? c : 1;

    public async Task<IEnumerable<EmrTemplateListViewModel>> GetListAsync()
    {
        var templates = await db.EmrTemplates
            .AsNoTracking()
            .Where(x => x.CompanyId == Co)
            .OrderBy(x => x.TemplateName)
            .ToListAsync();

        var list = new List<EmrTemplateListViewModel>();

        foreach (var t in templates)
        {
            var specialityNames = await db.EmrTemplateSpecialityMaps
                .AsNoTracking()
                .Where(x => x.TemplateId == t.TemplateId && x.IsActive)
                .Select(x => x.Speciality!.SpecialityName)
                .ToListAsync();

            var doctorIds = await db.EmrTemplateDoctorMaps.AsNoTracking()
                .Where(x => x.TemplateId == t.TemplateId && x.IsActive).Select(x => x.DoctorId).ToListAsync();
            var doctorNames = doctorIds.Count == 0 ? [] : await db.DoctorMasters.AsNoTracking()
                .Where(d => doctorIds.Contains(d.DoctorId)).OrderBy(d => d.FullName).Select(d => d.FullName).ToListAsync();

            list.Add(new EmrTemplateListViewModel
            {
                TemplateId = t.TemplateId,
                TemplateName = t.TemplateName,
                Description = t.Description,
                IsActive = t.IsActive,
                MappedSpecialityNames = specialityNames,
                MappedDoctorNames = doctorNames
            });
        }

        return list;
    }

    public async Task<EmrTemplateViewModel?> GetByIdAsync(int id)
    {
        var template = await db.EmrTemplates
            .AsNoTracking()
            .FirstOrDefaultAsync(x => x.TemplateId == id && x.CompanyId == Co);

        if (template is null) return null;

        var selectedSpecialities = await db.EmrTemplateSpecialityMaps
            .AsNoTracking()
            .Where(x => x.TemplateId == id && x.IsActive)
            .Select(x => x.SpecialityId)
            .ToListAsync();

        var sections = await db.EmrTemplateSections
            .AsNoTracking()
            .Where(x => x.TemplateId == id && x.IsActive)
            .OrderBy(x => x.DisplayOrder)
            .ToListAsync();

        var sectionViewModels = new List<EmrSectionViewModel>();
        foreach (var sec in sections)
        {
            var fields = await db.EmrTemplateFields
                .AsNoTracking()
                .Where(x => x.SectionId == sec.SectionId && x.IsActive)
                .OrderBy(x => x.DisplayOrder)
                .ToListAsync();

            var fieldViewModels = fields.Select(f =>
            {
                string? optionsString = null;
                if (!string.IsNullOrWhiteSpace(f.OptionsJson))
                {
                    if (f.FieldType is "Select" or "MultiSelect")
                    {
                        // Stored as a JSON string array — deserialise and rejoin for the UI
                        try
                        {
                            var opts = JsonSerializer.Deserialize<List<string>>(f.OptionsJson);
                            optionsString = opts != null ? string.Join(", ", opts) : f.OptionsJson;
                        }
                        catch { optionsString = f.OptionsJson; }
                    }
                    else
                    {
                        // Investigation/Medication   → stored as raw "id|name,id|name" (may be JSON array from old saves)
                        // ImageUpload / Paint        → raw base64 data URL
                        // FileUpload                 → raw comma-separated file names
                        // RichText                   → raw Quill delta JSON string
                        try
                        {
                            var opts = JsonSerializer.Deserialize<List<string>>(f.OptionsJson);
                            // Rejoin without space to preserve the id|name pair format
                            optionsString = opts != null ? string.Join(",", opts) : f.OptionsJson;
                        }
                        catch { optionsString = f.OptionsJson; }
                    }
                }

                return new EmrFieldViewModel
                {
                    FieldId = f.FieldId,
                    FieldName = f.FieldName,
                    FieldType = f.FieldType,
                    OptionsString = optionsString,
                    IsRequired = f.IsRequired,
                    DisplayOrder = f.DisplayOrder
                };
            }).ToList();

            sectionViewModels.Add(new EmrSectionViewModel
            {
                SectionId = sec.SectionId,
                SectionName = sec.SectionName,
                DisplayOrder = sec.DisplayOrder,
                Fields = fieldViewModels
            });
        }

        return new EmrTemplateViewModel
        {
            TemplateId = template.TemplateId,
            TemplateName = template.TemplateName,
            Description = template.Description,
            IsActive = template.IsActive,
            SelectedSpecialityIds = selectedSpecialities,
            SelectedDoctorIds = await db.EmrTemplateDoctorMaps.AsNoTracking().Where(x => x.TemplateId == id && x.IsActive).Select(x => x.DoctorId).ToListAsync(),
            Sections = sectionViewModels
        };
    }

    public async Task<int> CreateAsync(EmrTemplateViewModel model, int userId)
    {
        using var tx = await db.Database.BeginTransactionAsync();
        try
        {
            var template = new EmrTemplate
            {
                CompanyId = Co,
                TemplateName = model.TemplateName.Trim(),
                Description = model.Description?.Trim(),
                IsActive = model.IsActive,
                CreatedBy = userId,
                CreatedDate = DateTime.Now
            };
            db.EmrTemplates.Add(template);
            await db.SaveChangesAsync();

            // Map specialities
            foreach (var specId in model.SelectedSpecialityIds.Distinct())
            {
                db.EmrTemplateSpecialityMaps.Add(new EmrTemplateSpecialityMap
                {
                    CompanyId = Co,
                    TemplateId = template.TemplateId,
                    SpecialityId = specId,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                });
            }

            SaveDoctorMaps(template.TemplateId, model, userId);

            // Save sections and fields
            int secOrder = 1;
            foreach (var secVm in model.Sections)
            {
                var section = new EmrTemplateSection
                {
                    CompanyId = Co,
                    TemplateId = template.TemplateId,
                    SectionName = secVm.SectionName.Trim(),
                    DisplayOrder = secOrder++,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                };
                db.EmrTemplateSections.Add(section);
                await db.SaveChangesAsync(); // generate SectionId

                int fieldOrder = 1;
                foreach (var fieldVm in secVm.Fields)
                {
                    string? optionsJson = null;
                    if (!string.IsNullOrWhiteSpace(fieldVm.OptionsString))
                    {
                        if (fieldVm.FieldType is "Select" or "MultiSelect")
                        {
                            // Serialize comma-separated options as a JSON string array
                            var list = fieldVm.OptionsString
                                .Split(',', StringSplitOptions.RemoveEmptyEntries)
                                .Select(x => x.Trim())
                                .ToList();
                            optionsJson = JsonSerializer.Serialize(list);
                        }
                        else
                        {
                            // Store raw for all other types:
                            // Investigation/Medication → "id|name,id|name"
                            // ImageUpload / Paint      → base64 data URL
                            // FileUpload               → comma-separated file names
                            // RichText                 → Quill delta JSON
                            optionsJson = fieldVm.OptionsString;
                        }
                    }

                    db.EmrTemplateFields.Add(new EmrTemplateField
                    {
                        CompanyId = Co,
                        SectionId = section.SectionId,
                        FieldName = fieldVm.FieldName.Trim(),
                        FieldType = fieldVm.FieldType,
                        OptionsJson = optionsJson,
                        IsRequired = fieldVm.IsRequired,
                        DisplayOrder = fieldOrder++,
                        IsActive = true,
                        CreatedBy = userId,
                        CreatedDate = DateTime.Now
                    });
                }
            }

            await db.SaveChangesAsync();
            await EnsureUniqueAsync();   // final check inside the transaction (two users saving at once)
            await tx.CommitAsync();
            return template.TemplateId;
        }
        catch
        {
            await tx.RollbackAsync();
            throw;
        }
    }

    public async Task<bool> UpdateAsync(EmrTemplateViewModel model, int userId)
    {
        var template = await db.EmrTemplates.FindAsync(model.TemplateId);
        if (template is null || template.CompanyId != Co) return false;

        using var tx = await db.Database.BeginTransactionAsync();
        try
        {
            template.TemplateName = model.TemplateName.Trim();
            template.Description = model.Description?.Trim();
            template.IsActive = model.IsActive;
            template.ModifiedBy = userId;
            template.ModifiedDate = DateTime.Now;

            // Clear and re-insert speciality maps
            var oldMaps = await db.EmrTemplateSpecialityMaps
                .Where(x => x.TemplateId == template.TemplateId)
                .ToListAsync();
            db.EmrTemplateSpecialityMaps.RemoveRange(oldMaps);

            foreach (var specId in model.SelectedSpecialityIds.Distinct())
            {
                db.EmrTemplateSpecialityMaps.Add(new EmrTemplateSpecialityMap
                {
                    CompanyId = Co,
                    TemplateId = template.TemplateId,
                    SpecialityId = specId,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                });
            }

            db.EmrTemplateDoctorMaps.RemoveRange(await db.EmrTemplateDoctorMaps.Where(x => x.TemplateId == template.TemplateId).ToListAsync());
            SaveDoctorMaps(template.TemplateId, model, userId);

            // Remove all old sections (cascade deletes old fields in DB constraint)
            var oldSections = await db.EmrTemplateSections
                .Where(x => x.TemplateId == template.TemplateId)
                .ToListAsync();
            db.EmrTemplateSections.RemoveRange(oldSections);
            await db.SaveChangesAsync();

            // Re-insert new sections & fields
            int secOrder = 1;
            foreach (var secVm in model.Sections)
            {
                var section = new EmrTemplateSection
                {
                    CompanyId = Co,
                    TemplateId = template.TemplateId,
                    SectionName = secVm.SectionName.Trim(),
                    DisplayOrder = secOrder++,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                };
                db.EmrTemplateSections.Add(section);
                await db.SaveChangesAsync();

                int fieldOrder = 1;
                foreach (var fieldVm in secVm.Fields)
                {
                    string? optionsJson = null;
                    if (!string.IsNullOrWhiteSpace(fieldVm.OptionsString))
                    {
                        if (fieldVm.FieldType is "Select" or "MultiSelect")
                        {
                            var list = fieldVm.OptionsString
                                .Split(',', StringSplitOptions.RemoveEmptyEntries)
                                .Select(x => x.Trim())
                                .ToList();
                            optionsJson = JsonSerializer.Serialize(list);
                        }
                        else
                        {
                            optionsJson = fieldVm.OptionsString;
                        }
                    }

                    db.EmrTemplateFields.Add(new EmrTemplateField
                    {
                        CompanyId = Co,
                        SectionId = section.SectionId,
                        FieldName = fieldVm.FieldName.Trim(),
                        FieldType = fieldVm.FieldType,
                        OptionsJson = optionsJson,
                        IsRequired = fieldVm.IsRequired,
                        DisplayOrder = fieldOrder++,
                        IsActive = true,
                        CreatedBy = userId,
                        CreatedDate = DateTime.Now
                    });
                }
            }

            await db.SaveChangesAsync();
            await EnsureUniqueAsync();   // final check inside the transaction (two users saving at once)
            await tx.CommitAsync();
            return true;
        }
        catch
        {
            await tx.RollbackAsync();
            throw;
        }
    }

    public async Task<bool> ToggleActiveAsync(int id)
    {
        var template = await db.EmrTemplates.FindAsync(id);
        if (template is null || template.CompanyId != Co) return false;

        template.IsActive = !template.IsActive;
        template.ModifiedDate = DateTime.Now;
        await db.SaveChangesAsync();
        return true;
    }

    // ── doctors (SQLScripts/2483) ──
    private void SaveDoctorMaps(int templateId, EmrTemplateViewModel model, int userId)
    {
        foreach (var doctorId in (model.SelectedDoctorIds ?? []).Distinct())
            db.EmrTemplateDoctorMaps.Add(new EmrTemplateDoctorMap
            {
                CompanyId = Co, TemplateId = templateId, DoctorId = doctorId, IsActive = true, CreatedBy = userId, CreatedDate = DateTime.Now
            });
    }

    public async Task<List<EmrTemplateDoctorOption>> DoctorOptionsAsync(IEnumerable<int> specialityIds, int excludeTemplateId, IEnumerable<int>? alsoDoctorIds = null)
    {
        var specs = specialityIds.Distinct().ToList();
        var also = (alsoDoctorIds ?? []).Distinct().ToList();
        if (specs.Count == 0 && also.Count == 0) return [];
        var doctors = await (from d in db.DoctorMasters.AsNoTracking()
                             join sp in db.DoctorSpecialityMasters.AsNoTracking() on d.PrimarySpecialityId equals sp.SpecialityId into g
                             from sp in g.DefaultIfEmpty()
                             where d.CompanyId == Co && ((d.IsActive && specs.Contains(d.PrimarySpecialityId)) || also.Contains(d.DoctorId))
                             orderby d.FullName
                             select new EmrTemplateDoctorOption
                             {
                                 DoctorId = d.DoctorId,
                                 Name = (d.NamePrefix == null || d.NamePrefix == "" ? "" : d.NamePrefix + " ") + d.FullName,
                                 SpecialityId = d.PrimarySpecialityId,
                                 SpecialityName = sp != null ? sp.SpecialityName : null
                             }).ToListAsync();
        // a doctor who already has another active doctor-specific template: shown, so the conflict is clear before saving
        var ids = doctors.Select(d => d.DoctorId).ToList();
        var others = await (from m in db.EmrTemplateDoctorMaps.AsNoTracking()
                            join t in db.EmrTemplates.AsNoTracking() on m.TemplateId equals t.TemplateId
                            where ids.Contains(m.DoctorId) && m.IsActive && t.IsActive && t.CompanyId == Co && t.TemplateId != excludeTemplateId
                            select new { m.DoctorId, t.TemplateName }).ToListAsync();
        foreach (var d in doctors) d.OtherTemplate = others.FirstOrDefault(o => o.DoctorId == d.DoctorId)?.TemplateName;
        return doctors;
    }

    // ── Copy From (Create): the templates of a speciality, and which one a doctor of it uses (SQLScripts/2483) ──
    public async Task<object> CopySourcesAsync(int specialityId, int? doctorId)
    {
        var templates = await (from m in db.EmrTemplateSpecialityMaps.AsNoTracking()
                               join t in db.EmrTemplates.AsNoTracking() on m.TemplateId equals t.TemplateId
                               where m.SpecialityId == specialityId && m.IsActive && t.CompanyId == Co
                               orderby t.IsActive descending, t.TemplateName
                               select new { t.TemplateId, t.TemplateName, t.Description, t.IsActive }).ToListAsync();
        var ids = templates.Select(t => t.TemplateId).ToList();
        var docMaps = await (from m in db.EmrTemplateDoctorMaps.AsNoTracking()
                             join d in db.DoctorMasters.AsNoTracking() on m.DoctorId equals d.DoctorId
                             where ids.Contains(m.TemplateId) && m.IsActive
                             select new { m.TemplateId, m.DoctorId, d.FullName }).ToListAsync();
        var sectionCounts = await db.EmrTemplateSections.AsNoTracking().Where(x => ids.Contains(x.TemplateId) && x.IsActive)
            .GroupBy(x => x.TemplateId).Select(g => new { TemplateId = g.Key, Sections = g.Count() }).ToListAsync();
        var fieldCounts = await (from f in db.EmrTemplateFields.AsNoTracking()
                                 join sc in db.EmrTemplateSections.AsNoTracking() on f.SectionId equals sc.SectionId
                                 where ids.Contains(sc.TemplateId) && f.IsActive && sc.IsActive
                                 group f by sc.TemplateId into g select new { TemplateId = g.Key, Fields = g.Count() }).ToListAsync();

        // only doctors who have their own (doctor-specific) template in this speciality; picking one selects it
        // (the active one first, if the doctor also has inactive ones)
        var doctorIds = docMaps.Select(d => d.DoctorId).Distinct().ToList();
        var doctors = await db.DoctorMasters.AsNoTracking()
            .Where(d => doctorIds.Contains(d.DoctorId))
            .OrderBy(d => d.FullName)
            .Select(d => new { d.DoctorId, Name = (d.NamePrefix == null || d.NamePrefix == "" ? "" : d.NamePrefix + " ") + d.FullName, d.IsActive }).ToListAsync();
        int? OwnTemplate(int docId) => templates.Where(t => docMaps.Any(m => m.TemplateId == t.TemplateId && m.DoctorId == docId))
            .OrderByDescending(t => t.IsActive).Select(t => (int?)t.TemplateId).FirstOrDefault();

        int? used = doctorId is > 0 && doctorIds.Contains(doctorId.Value) ? OwnTemplate(doctorId.Value) : null;

        return new
        {
            usedTemplateId = used,
            doctors = doctors.Select(d => new
            {
                d.DoctorId, d.Name, DoctorActive = d.IsActive,
                TemplateId = OwnTemplate(d.DoctorId),
                TemplateName = templates.Where(t => t.TemplateId == OwnTemplate(d.DoctorId)).Select(t => t.TemplateName).FirstOrDefault()
            }),
            templates = templates.Select(t => new
            {
                t.TemplateId, t.TemplateName, t.Description, t.IsActive,
                Kind = docMaps.Any(d => d.TemplateId == t.TemplateId) ? "DOCTOR" : "SPECIALITY",
                Doctors = docMaps.Where(d => d.TemplateId == t.TemplateId).Select(d => d.FullName).OrderBy(n => n).ToList(),
                Sections = sectionCounts.FirstOrDefault(x => x.TemplateId == t.TemplateId)?.Sections ?? 0,
                Fields = fieldCounts.FirstOrDefault(x => x.TemplateId == t.TemplateId)?.Fields ?? 0
            })
        };
    }

    /// <summary>
    /// The rule the Doctor Dashboard depends on (SQLScripts/2483), checked inside the save transaction just before commit:
    /// a speciality has at most ONE active default template (a template without doctors); a doctor has at most ONE active
    /// doctor-specific template. Different doctors of the same speciality may each have their own. Throws (the save is undone).
    /// </summary>
    private async Task EnsureUniqueAsync()
    {
        var defaults = await (from m in db.EmrTemplateSpecialityMaps
                              join t in db.EmrTemplates on m.TemplateId equals t.TemplateId
                              where m.IsActive && t.IsActive && t.CompanyId == Co
                                    && !db.EmrTemplateDoctorMaps.Any(d => d.TemplateId == t.TemplateId && d.IsActive)
                              group t by m.SpecialityId into g
                              where g.Count() > 1
                              select new { SpecialityId = g.Key, Names = g.Select(x => x.TemplateName).ToList() }).ToListAsync();
        if (defaults.Count > 0)
        {
            var d = defaults[0];
            var spec = await db.DoctorSpecialityMasters.Where(x => x.SpecialityId == d.SpecialityId).Select(x => x.SpecialityName).FirstOrDefaultAsync();
            throw new EmrTemplateRuleException($"Speciality '{spec}' would have more than one default template ({string.Join(", ", d.Names)}). " +
                "Choose doctors to make this a doctor-specific template, or deactivate the other one.");
        }
        var doctors = await (from m in db.EmrTemplateDoctorMaps
                             join t in db.EmrTemplates on m.TemplateId equals t.TemplateId
                             where m.IsActive && t.IsActive && t.CompanyId == Co
                             group t by m.DoctorId into g
                             where g.Count() > 1
                             select new { DoctorId = g.Key, Names = g.Select(x => x.TemplateName).ToList() }).ToListAsync();
        if (doctors.Count > 0)
        {
            var d = doctors[0];
            var name = await db.DoctorMasters.Where(x => x.DoctorId == d.DoctorId).Select(x => x.FullName).FirstOrDefaultAsync();
            throw new EmrTemplateRuleException($"Dr {name} would have more than one template ({string.Join(", ", d.Names)}). A doctor can have only one active template.");
        }
    }

    /// <summary>Default template of a speciality (no doctors), other than the one being edited - for the form's warning.</summary>
    public async Task<string?> SpecialityDefaultAsync(int specialityId, int excludeTemplateId) =>
        await (from m in db.EmrTemplateSpecialityMaps.AsNoTracking()
               join t in db.EmrTemplates.AsNoTracking() on m.TemplateId equals t.TemplateId
               where m.SpecialityId == specialityId && m.IsActive && t.IsActive && t.CompanyId == Co && t.TemplateId != excludeTemplateId
                     && !db.EmrTemplateDoctorMaps.Any(d => d.TemplateId == t.TemplateId && d.IsActive)
               select t.TemplateName).FirstOrDefaultAsync();

    public async Task<bool> SetActiveCheckedAsync(int id, bool active)
    {
        var template = await db.EmrTemplates.FindAsync(id);
        if (template is null || template.CompanyId != Co) return false;
        using var tx = await db.Database.BeginTransactionAsync();
        template.IsActive = active;
        template.ModifiedDate = DateTime.Now;
        await db.SaveChangesAsync();
        if (active)
        {
            try { await EnsureUniqueAsync(); }
            catch { await tx.RollbackAsync(); template.IsActive = !active; throw; }
        }
        await tx.CommitAsync();
        return true;
    }
}

/// <summary>A save refused by the one-default-per-speciality / one-template-per-doctor rule (SQLScripts/2483).</summary>
public sealed class EmrTemplateRuleException(string message) : Exception(message);
