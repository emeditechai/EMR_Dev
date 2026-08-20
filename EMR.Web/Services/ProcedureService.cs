using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class ProcedureService(ApplicationDbContext dbContext) : IProcedureService
{
    private static readonly string[] StandardProcedureCategories =
    [
        "Major Surgery",
        "Minor Surgery",
        "Diagnostic Procedure",
        "Therapeutic Procedure",
        "Endoscopic Procedure",
        "Interventional Procedure",
        "Dialysis",
        "Bedside / Nursing Procedure",
        "ICU Procedure",
        "Daycare Procedure",
        "Biopsy / Histopathology",
        "Catheterization / Line Placement",
        "Other"
    ];

    public async Task<ProcedureMaster?> GetByIdAsync(int id)
    {
        return await dbContext.ProcedureMasters
            .Include(x => x.Branch)
            .Include(x => x.Department)
            .Include(x => x.Speciality)
            .FirstOrDefaultAsync(x => x.ProcedureId == id);
    }

    public async Task<List<ProcedureTariffMaster>> GetTariffsByProcedureIdAsync(int procedureId)
    {
        return await dbContext.ProcedureTariffMasters
            .Include(t => t.TariffCategory)
            .Include(t => t.Branch)
            .Where(t => t.ProcedureId == procedureId)
            .OrderByDescending(t => t.EffectiveFrom)
            .ToListAsync();
    }

    public async Task<ProcedureFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new ProcedureFormViewModel
        {
            ProcedureId = entity.ProcedureId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            DepartmentId = entity.DepartmentId,
            SpecialityId = entity.SpecialityId,
            ProcedureCode = entity.ProcedureCode,
            ProcedureName = entity.ProcedureName,
            ProcedureCategory = entity.ProcedureCategory,
            DurationHours = entity.DurationHours,
            DurationMinutes = entity.DurationMinutes,
            DurationSeconds = entity.DurationSeconds,
            AnaesthesiaRequired = entity.AnaesthesiaRequired,
            ConsentRequired = entity.ConsentRequired,
            Description = entity.Description,
            IsActive = entity.IsActive,
            DepartmentOptions = await GetDepartmentOptionsAsync(entity.DepartmentId),
            SpecialityOptions = await GetSpecialityOptionsAsync(entity.SpecialityId),
            ProcedureCategoryOptions = GetProcedureCategoryOptions(entity.ProcedureCategory)
        };
    }

    public async Task<int> CreateAsync(ProcedureFormViewModel model, int? userId)
    {
        var entity = new ProcedureMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            DepartmentId = model.DepartmentId,
            SpecialityId = model.SpecialityId,
            ProcedureCode = model.ProcedureCode.Trim().ToUpperInvariant(),
            ProcedureName = model.ProcedureName.Trim(),
            ProcedureCategory = model.ProcedureCategory.Trim(),
            DurationHours = model.DurationHours,
            DurationMinutes = model.DurationMinutes,
            DurationSeconds = model.DurationSeconds,
            AnaesthesiaRequired = model.AnaesthesiaRequired,
            ConsentRequired = model.ConsentRequired,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.ProcedureMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.ProcedureId;
    }

    public async Task<bool> UpdateAsync(ProcedureFormViewModel model, int? userId)
    {
        var entity = await dbContext.ProcedureMasters.FindAsync(model.ProcedureId);
        if (entity is null) return false;

        entity.DepartmentId = model.DepartmentId;
        entity.SpecialityId = model.SpecialityId;
        entity.ProcedureCode = model.ProcedureCode.Trim().ToUpperInvariant();
        entity.ProcedureName = model.ProcedureName.Trim();
        entity.ProcedureCategory = model.ProcedureCategory.Trim();
        entity.DurationHours = model.DurationHours;
        entity.DurationMinutes = model.DurationMinutes;
        entity.DurationSeconds = model.DurationSeconds;
        entity.AnaesthesiaRequired = model.AnaesthesiaRequired;
        entity.ConsentRequired = model.ConsentRequired;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.ProcedureMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.ProcedureMasters.FindAsync(id);
        if (entity is null) return false;

        var hasTariffs = await dbContext.ProcedureTariffMasters.AnyAsync(r => r.ProcedureId == id);
        if (hasTariffs)
        {
            entity.IsActive = false;
            entity.ModifiedBy = userId;
            entity.ModifiedDate = DateTime.Now;
        }
        else
        {
            dbContext.ProcedureMasters.Remove(entity);
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var normalized = code.Trim().ToLower();
        var query = dbContext.ProcedureMasters
            .Where(x => x.BranchId == branchId && x.ProcedureCode.ToLower() == normalized);

        if (excludeId.HasValue)
            query = query.Where(x => x.ProcedureId != excludeId.Value);

        return await query.AnyAsync();
    }

    public async Task<List<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null)
    {
        var depts = await dbContext.DepartmentMasters
            .Where(d => d.DeptType == "IPD" && d.IsActive)
            .OrderBy(d => d.DeptName)
            .ToListAsync();

        if (depts.Count == 0)
        {
            depts = await dbContext.DepartmentMasters
                .Where(d => d.IsActive)
                .OrderBy(d => d.DeptName)
                .ToListAsync();
        }

        return depts.Select(d => new SelectListItem
        {
            Value = d.DeptId.ToString(),
            Text = $"{d.DeptName} ({d.DeptCode})",
            Selected = selectedId.HasValue && d.DeptId == selectedId.Value
        }).ToList();
    }

    public async Task<List<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null)
    {
        var specs = await dbContext.DoctorSpecialityMasters
            .Where(s => s.IsActive)
            .OrderBy(s => s.SpecialityName)
            .ToListAsync();

        return specs.Select(s => new SelectListItem
        {
            Value = s.SpecialityId.ToString(),
            Text = $"{s.SpecialityName} ({s.SpecialityCode})",
            Selected = selectedId.HasValue && s.SpecialityId == selectedId.Value
        }).ToList();
    }

    public List<SelectListItem> GetProcedureCategoryOptions(string? selected = null)
    {
        return StandardProcedureCategories.Select(c => new SelectListItem
        {
            Value = c,
            Text = c,
            Selected = string.Equals(c, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }
}
