using System.Text.Json;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class EmrTemplateService(ApplicationDbContext db) : IEmrTemplateService
{
    public async Task<IEnumerable<EmrTemplateListViewModel>> GetListAsync()
    {
        var templates = await db.EmrTemplates
            .AsNoTracking()
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

            list.Add(new EmrTemplateListViewModel
            {
                TemplateId = t.TemplateId,
                TemplateName = t.TemplateName,
                Description = t.Description,
                IsActive = t.IsActive,
                MappedSpecialityNames = specialityNames
            });
        }

        return list;
    }

    public async Task<EmrTemplateViewModel?> GetByIdAsync(int id)
    {
        var template = await db.EmrTemplates
            .AsNoTracking()
            .FirstOrDefaultAsync(x => x.TemplateId == id);

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
                    try
                    {
                        var options = JsonSerializer.Deserialize<List<string>>(f.OptionsJson);
                        if (options != null)
                        {
                            optionsString = string.Join(", ", options);
                        }
                    }
                    catch { /* fallback to raw */ }
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
                    TemplateId = template.TemplateId,
                    SpecialityId = specId,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                });
            }

            // Save sections and fields
            int secOrder = 1;
            foreach (var secVm in model.Sections)
            {
                var section = new EmrTemplateSection
                {
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
                        var list = fieldVm.OptionsString.Split(',', StringSplitOptions.RemoveEmptyEntries)
                            .Select(x => x.Trim())
                            .ToList();
                        optionsJson = JsonSerializer.Serialize(list);
                    }

                    db.EmrTemplateFields.Add(new EmrTemplateField
                    {
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
        if (template is null) return false;

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
                    TemplateId = template.TemplateId,
                    SpecialityId = specId,
                    IsActive = true,
                    CreatedBy = userId,
                    CreatedDate = DateTime.Now
                });
            }

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
                        var list = fieldVm.OptionsString.Split(',', StringSplitOptions.RemoveEmptyEntries)
                            .Select(x => x.Trim())
                            .ToList();
                        optionsJson = JsonSerializer.Serialize(list);
                    }

                    db.EmrTemplateFields.Add(new EmrTemplateField
                    {
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
        if (template is null) return false;

        template.IsActive = !template.IsActive;
        template.ModifiedDate = DateTime.Now;
        await db.SaveChangesAsync();
        return true;
    }
}
