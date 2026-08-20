using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class AnaesthesiaService(ApplicationDbContext dbContext) : IAnaesthesiaService
{
    // ── 1. Anaesthesia Types ──────────────────────────────────────────────────
    public async Task<AnaesthesiaTypeMaster?> GetTypeByIdAsync(int id)
    {
        return await dbContext.AnaesthesiaTypeMasters
            .Include(t => t.Branch)
            .Include(t => t.Rates)
            .FirstOrDefaultAsync(t => t.AnaesthesiaTypeId == id);
    }

    public async Task<AnaesthesiaTypeFormViewModel?> GetTypeFormModelByIdAsync(int id)
    {
        var entity = await GetTypeByIdAsync(id);
        if (entity is null) return null;

        return new AnaesthesiaTypeFormViewModel
        {
            AnaesthesiaTypeId = entity.AnaesthesiaTypeId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            TypeCode = entity.TypeCode,
            TypeName = entity.TypeName,
            Description = entity.Description,
            IsActive = entity.IsActive
        };
    }

    public async Task<int> CreateTypeAsync(AnaesthesiaTypeFormViewModel model, int? userId)
    {
        var entity = new AnaesthesiaTypeMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            TypeCode = model.TypeCode.Trim().ToUpperInvariant(),
            TypeName = model.TypeName.Trim(),
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.AnaesthesiaTypeMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.AnaesthesiaTypeId;
    }

    public async Task<bool> UpdateTypeAsync(AnaesthesiaTypeFormViewModel model, int? userId)
    {
        var entity = await dbContext.AnaesthesiaTypeMasters.FindAsync(model.AnaesthesiaTypeId);
        if (entity is null) return false;

        entity.TypeCode = model.TypeCode.Trim().ToUpperInvariant();
        entity.TypeName = model.TypeName.Trim();
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleTypeActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.AnaesthesiaTypeMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteTypeAsync(int id, int? userId)
    {
        var entity = await dbContext.AnaesthesiaTypeMasters
            .Include(t => t.Rates)
            .FirstOrDefaultAsync(t => t.AnaesthesiaTypeId == id);

        if (entity is null) return false;

        if (entity.Rates.Any())
        {
            // Soft delete if rates exist
            entity.IsActive = false;
            entity.ModifiedBy = userId;
            entity.ModifiedDate = DateTime.Now;
        }
        else
        {
            dbContext.AnaesthesiaTypeMasters.Remove(entity);
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> IsTypeCodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var normalized = code.Trim().ToUpperInvariant();
        var query = dbContext.AnaesthesiaTypeMasters.Where(t => t.BranchId == branchId && t.TypeCode == normalized);
        if (excludeId.HasValue)
            query = query.Where(t => t.AnaesthesiaTypeId != excludeId.Value);

        return await query.AnyAsync();
    }

    // ── 2. Anaesthesia Rates ──────────────────────────────────────────────────
    public async Task<AnaesthesiaRateMaster?> GetRateByIdAsync(int id)
    {
        return await dbContext.AnaesthesiaRateMasters
            .Include(r => r.Branch)
            .Include(r => r.Procedure)
                .ThenInclude(p => p!.Department)
            .Include(r => r.AnaesthesiaType)
            .FirstOrDefaultAsync(r => r.AnaesthesiaRateId == id);
    }

    public async Task<AnaesthesiaRateFormViewModel?> GetRateFormModelByIdAsync(int id)
    {
        var entity = await GetRateByIdAsync(id);
        if (entity is null) return null;

        return new AnaesthesiaRateFormViewModel
        {
            AnaesthesiaRateId = entity.AnaesthesiaRateId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            ProcedureId = entity.ProcedureId,
            AnaesthesiaTypeId = entity.AnaesthesiaTypeId,
            AnaesthetistFee = entity.AnaesthetistFee,
            ConsumableCharge = entity.ConsumableCharge,
            TotalRate = entity.TotalRate,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            Description = entity.Description,
            IsActive = entity.IsActive,
            ProcedureOptions = await GetProcedureOptionsAsync(entity.ProcedureId, entity.BranchId),
            AnaesthesiaTypeOptions = await GetAnaesthesiaTypeOptionsAsync(entity.AnaesthesiaTypeId, entity.BranchId)
        };
    }

    public async Task<int> CreateRateAsync(AnaesthesiaRateFormViewModel model, int? userId)
    {
        var total = model.AnaesthetistFee + model.ConsumableCharge;

        var entity = new AnaesthesiaRateMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            ProcedureId = model.ProcedureId,
            AnaesthesiaTypeId = model.AnaesthesiaTypeId,
            AnaesthetistFee = model.AnaesthetistFee,
            ConsumableCharge = model.ConsumableCharge,
            TotalRate = total,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.AnaesthesiaRateMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.AnaesthesiaRateId;
    }

    public async Task<bool> UpdateRateAsync(AnaesthesiaRateFormViewModel model, int? userId)
    {
        var entity = await dbContext.AnaesthesiaRateMasters.FindAsync(model.AnaesthesiaRateId);
        if (entity is null) return false;

        var total = model.AnaesthetistFee + model.ConsumableCharge;

        entity.ProcedureId = model.ProcedureId;
        entity.AnaesthesiaTypeId = model.AnaesthesiaTypeId;
        entity.AnaesthetistFee = model.AnaesthetistFee;
        entity.ConsumableCharge = model.ConsumableCharge;
        entity.TotalRate = total;
        entity.EffectiveFrom = model.EffectiveFrom;
        entity.EffectiveTo = model.EffectiveTo;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleRateActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.AnaesthesiaRateMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteRateAsync(int id, int? userId)
    {
        var entity = await dbContext.AnaesthesiaRateMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.AnaesthesiaRateMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> HasActiveRateAsync(int branchId, int procedureId, int anaesthesiaTypeId, int? excludeId = null)
    {
        var query = dbContext.AnaesthesiaRateMasters
            .Where(r => r.BranchId == branchId &&
                        r.ProcedureId == procedureId &&
                        r.AnaesthesiaTypeId == anaesthesiaTypeId &&
                        r.IsActive);

        if (excludeId.HasValue)
            query = query.Where(r => r.AnaesthesiaRateId != excludeId.Value);

        return await query.AnyAsync();
    }

    // ── 3. Dropdown Helpers ───────────────────────────────────────────────────
    public async Task<List<SelectListItem>> GetProcedureOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.ProcedureMasters.Where(p => p.IsActive);
        if (branchId.HasValue)
            query = query.Where(p => p.BranchId == branchId.Value);

        var list = await query
            .OrderBy(p => p.ProcedureCategory)
            .ThenBy(p => p.ProcedureName)
            .ToListAsync();

        return list.Select(p => new SelectListItem
        {
            Value = p.ProcedureId.ToString(),
            Text = $"[{p.ProcedureCategory}] {p.ProcedureName} ({p.ProcedureCode})",
            Selected = selectedId.HasValue && p.ProcedureId == selectedId.Value
        }).ToList();
    }

    public async Task<List<SelectListItem>> GetAnaesthesiaTypeOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.AnaesthesiaTypeMasters.Where(t => t.IsActive);
        if (branchId.HasValue)
            query = query.Where(t => t.BranchId == branchId.Value);

        var list = await query
            .OrderBy(t => t.TypeName)
            .ToListAsync();

        return list.Select(t => new SelectListItem
        {
            Value = t.AnaesthesiaTypeId.ToString(),
            Text = $"{t.TypeName} ({t.TypeCode})",
            Selected = selectedId.HasValue && t.AnaesthesiaTypeId == selectedId.Value
        }).ToList();
    }
}
