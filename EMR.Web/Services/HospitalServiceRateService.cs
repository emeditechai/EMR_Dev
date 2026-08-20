using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class HospitalServiceRateService(ApplicationDbContext dbContext) : IHospitalServiceRateService
{
    public async Task<HospitalServiceRateMaster?> GetByIdAsync(int id)
    {
        return await dbContext.HospitalServiceRateMasters
            .Include(x => x.Branch)
            .Include(x => x.TariffCategory)
            .Include(x => x.HospitalService)
                .ThenInclude(s => s!.Department)
            .FirstOrDefaultAsync(x => x.ServiceRateId == id);
    }

    public async Task<HospitalServiceRateFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new HospitalServiceRateFormViewModel
        {
            ServiceRateId = entity.ServiceRateId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            TariffCategoryId = entity.TariffCategoryId,
            HospitalServiceId = entity.HospitalServiceId,
            Rate = entity.Rate,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            Description = entity.Description,
            IsActive = entity.IsActive,
            TariffCategoryOptions = await GetTariffCategoryOptionsAsync(entity.TariffCategoryId, entity.CompanyId, entity.BranchId),
            HospitalServiceOptions = await GetHospitalServiceOptionsAsync(entity.HospitalServiceId, entity.BranchId)
        };
    }

    public async Task<int> CreateAsync(HospitalServiceRateFormViewModel model, int? userId)
    {
        var entity = new HospitalServiceRateMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            TariffCategoryId = model.TariffCategoryId,
            HospitalServiceId = model.HospitalServiceId,
            Rate = model.Rate,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.HospitalServiceRateMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.ServiceRateId;
    }

    public async Task<bool> UpdateAsync(HospitalServiceRateFormViewModel model, int? userId)
    {
        var entity = await dbContext.HospitalServiceRateMasters.FindAsync(model.ServiceRateId);
        if (entity is null) return false;

        entity.TariffCategoryId = model.TariffCategoryId;
        entity.HospitalServiceId = model.HospitalServiceId;
        entity.Rate = model.Rate;
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
        var entity = await dbContext.HospitalServiceRateMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.HospitalServiceRateMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.HospitalServiceRateMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> HasActiveRateAsync(int branchId, int tariffCategoryId, int hospitalServiceId, int? excludeId = null)
    {
        var query = dbContext.HospitalServiceRateMasters
            .Where(r => r.BranchId == branchId &&
                        r.TariffCategoryId == tariffCategoryId &&
                        r.HospitalServiceId == hospitalServiceId &&
                        r.IsActive);

        if (excludeId.HasValue)
            query = query.Where(r => r.ServiceRateId != excludeId.Value);

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

    public async Task<List<SelectListItem>> GetHospitalServiceOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.HospitalServiceMasters.Where(s => s.IsActive);
        if (branchId.HasValue)
            query = query.Where(s => s.BranchId == branchId.Value);

        var list = await query
            .Include(s => s.Department)
            .OrderBy(s => s.ServiceType)
            .ThenBy(s => s.ServiceName)
            .ToListAsync();

        return list.Select(s => new SelectListItem
        {
            Value = s.HospitalServiceId.ToString(),
            Text = $"[{s.ServiceType}] {s.ServiceName} ({s.ServiceCode}) - {s.UOM}",
            Selected = selectedId.HasValue && s.HospitalServiceId == selectedId.Value
        }).ToList();
    }
}
