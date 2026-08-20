using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class OtTariffService(ApplicationDbContext dbContext) : IOtTariffService
{
    public async Task<OtTariffMaster?> GetByIdAsync(int id)
    {
        return await dbContext.OtTariffMasters
            .Include(t => t.Branch)
            .Include(t => t.TariffCategory)
            .Include(t => t.Ot)
                .ThenInclude(o => o!.Floor)
                    .ThenInclude(f => f!.Building)
            .FirstOrDefaultAsync(t => t.OtTariffId == id);
    }

    public async Task<OtTariffFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new OtTariffFormViewModel
        {
            OtTariffId = entity.OtTariffId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            TariffCategoryId = entity.TariffCategoryId,
            OtId = entity.OtId,
            OtUsageRate = entity.OtUsageRate,
            NursingCharges = entity.NursingCharges,
            EquipmentCharges = entity.EquipmentCharges,
            RecoveryCharges = entity.RecoveryCharges,
            ConsumableCharges = entity.ConsumableCharges,
            SpecialEquipmentCharges = entity.SpecialEquipmentCharges,
            TotalRate = entity.TotalRate,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            Description = entity.Description,
            IsActive = entity.IsActive,
            TariffCategoryOptions = await GetTariffCategoryOptionsAsync(entity.TariffCategoryId, entity.CompanyId, entity.BranchId),
            OtOptions = await GetOtOptionsAsync(entity.OtId, entity.BranchId)
        };
    }

    public async Task<int> CreateAsync(OtTariffFormViewModel model, int? userId)
    {
        var total = model.OtUsageRate + model.NursingCharges + model.EquipmentCharges +
                    model.RecoveryCharges + model.ConsumableCharges + model.SpecialEquipmentCharges;

        var entity = new OtTariffMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            TariffCategoryId = model.TariffCategoryId,
            OtId = model.OtId,
            OtUsageRate = model.OtUsageRate,
            NursingCharges = model.NursingCharges,
            EquipmentCharges = model.EquipmentCharges,
            RecoveryCharges = model.RecoveryCharges,
            ConsumableCharges = model.ConsumableCharges,
            SpecialEquipmentCharges = model.SpecialEquipmentCharges,
            TotalRate = total,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.OtTariffMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.OtTariffId;
    }

    public async Task<bool> UpdateAsync(OtTariffFormViewModel model, int? userId)
    {
        var entity = await dbContext.OtTariffMasters.FindAsync(model.OtTariffId);
        if (entity is null) return false;

        var total = model.OtUsageRate + model.NursingCharges + model.EquipmentCharges +
                    model.RecoveryCharges + model.ConsumableCharges + model.SpecialEquipmentCharges;

        entity.TariffCategoryId = model.TariffCategoryId;
        entity.OtId = model.OtId;
        entity.OtUsageRate = model.OtUsageRate;
        entity.NursingCharges = model.NursingCharges;
        entity.EquipmentCharges = model.EquipmentCharges;
        entity.RecoveryCharges = model.RecoveryCharges;
        entity.ConsumableCharges = model.ConsumableCharges;
        entity.SpecialEquipmentCharges = model.SpecialEquipmentCharges;
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

    public async Task<bool> ToggleActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.OtTariffMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.OtTariffMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.OtTariffMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int otId, int? excludeId = null)
    {
        var query = dbContext.OtTariffMasters
            .Where(r => r.BranchId == branchId &&
                        r.TariffCategoryId == tariffCategoryId &&
                        r.OtId == otId &&
                        r.IsActive);

        if (excludeId.HasValue)
            query = query.Where(r => r.OtTariffId != excludeId.Value);

        return await query.AnyAsync();
    }

    public async Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? companyId = null, int? branchId = null)
    {
        var query = dbContext.TariffCategoryMasters.Where(tc => tc.IsActive);
        if (companyId.HasValue && companyId.Value > 0)
            query = query.Where(tc => tc.CompanyId == companyId.Value);
        if (branchId.HasValue)
            query = query.Where(tc => tc.BranchId == branchId.Value || tc.BranchId == null);

        var list = await query.OrderBy(tc => tc.Name).ToListAsync();

        return list.Select(tc => new SelectListItem
        {
            Value = tc.TariffCategoryId.ToString(),
            Text = $"{tc.Name} ({tc.PatientCategory})",
            Selected = selectedId.HasValue && tc.TariffCategoryId == selectedId.Value
        }).ToList();
    }

    public async Task<List<SelectListItem>> GetOtOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.OtMasters.Where(o => o.IsActive);
        if (branchId.HasValue)
            query = query.Where(o => o.BranchId == branchId.Value);

        var list = await query
            .OrderBy(o => o.OtType)
            .ThenBy(o => o.OtName)
            .ToListAsync();

        return list.Select(o => new SelectListItem
        {
            Value = o.OtId.ToString(),
            Text = $"[{o.OtType}] {o.OtName} ({o.OtCode})",
            Selected = selectedId.HasValue && o.OtId == selectedId.Value
        }).ToList();
    }
}
