using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class ProcedureTariffService(ApplicationDbContext dbContext) : IProcedureTariffService
{
    public async Task<ProcedureTariffMaster?> GetByIdAsync(int id)
    {
        return await dbContext.ProcedureTariffMasters
            .Include(x => x.Branch)
            .Include(x => x.TariffCategory)
            .Include(x => x.Procedure)
                .ThenInclude(p => p!.Department)
            .Include(x => x.Procedure)
                .ThenInclude(p => p!.Speciality)
            .FirstOrDefaultAsync(x => x.ProcedureTariffId == id);
    }

    public async Task<ProcedureTariffFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new ProcedureTariffFormViewModel
        {
            ProcedureTariffId = entity.ProcedureTariffId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            TariffCategoryId = entity.TariffCategoryId,
            ProcedureId = entity.ProcedureId,
            SurgeonFee = entity.SurgeonFee,
            AssistantFee = entity.AssistantFee,
            AnaesthetistFee = entity.AnaesthetistFee,
            OtCharges = entity.OtCharges,
            EquipmentCharges = entity.EquipmentCharges,
            ConsumableCharges = entity.ConsumableCharges,
            NursingCharges = entity.NursingCharges,
            TotalRate = entity.TotalRate,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            Description = entity.Description,
            IsActive = entity.IsActive,
            TariffCategoryOptions = await GetTariffCategoryOptionsAsync(entity.TariffCategoryId, entity.CompanyId, entity.BranchId),
            ProcedureOptions = await GetProcedureOptionsAsync(entity.ProcedureId, entity.BranchId)
        };
    }

    public async Task<int> CreateAsync(ProcedureTariffFormViewModel model, int? userId)
    {
        var total = model.SurgeonFee + model.AssistantFee + model.AnaesthetistFee +
                    model.OtCharges + model.EquipmentCharges + model.ConsumableCharges + model.NursingCharges;

        var entity = new ProcedureTariffMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            TariffCategoryId = model.TariffCategoryId,
            ProcedureId = model.ProcedureId,
            SurgeonFee = model.SurgeonFee,
            AssistantFee = model.AssistantFee,
            AnaesthetistFee = model.AnaesthetistFee,
            OtCharges = model.OtCharges,
            EquipmentCharges = model.EquipmentCharges,
            ConsumableCharges = model.ConsumableCharges,
            NursingCharges = model.NursingCharges,
            TotalRate = total,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.ProcedureTariffMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.ProcedureTariffId;
    }

    public async Task<bool> UpdateAsync(ProcedureTariffFormViewModel model, int? userId)
    {
        var entity = await dbContext.ProcedureTariffMasters.FindAsync(model.ProcedureTariffId);
        if (entity is null) return false;

        var total = model.SurgeonFee + model.AssistantFee + model.AnaesthetistFee +
                    model.OtCharges + model.EquipmentCharges + model.ConsumableCharges + model.NursingCharges;

        entity.TariffCategoryId = model.TariffCategoryId;
        entity.ProcedureId = model.ProcedureId;
        entity.SurgeonFee = model.SurgeonFee;
        entity.AssistantFee = model.AssistantFee;
        entity.AnaesthetistFee = model.AnaesthetistFee;
        entity.OtCharges = model.OtCharges;
        entity.EquipmentCharges = model.EquipmentCharges;
        entity.ConsumableCharges = model.ConsumableCharges;
        entity.NursingCharges = model.NursingCharges;
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
        var entity = await dbContext.ProcedureTariffMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.ProcedureTariffMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.ProcedureTariffMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int procedureId, int? excludeId = null)
    {
        var query = dbContext.ProcedureTariffMasters
            .Where(r => r.BranchId == branchId &&
                        r.TariffCategoryId == tariffCategoryId &&
                        r.ProcedureId == procedureId &&
                        r.IsActive);

        if (excludeId.HasValue)
            query = query.Where(r => r.ProcedureTariffId != excludeId.Value);

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
}
