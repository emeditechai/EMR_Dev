using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class IcuService(ApplicationDbContext dbContext) : IIcuService
{
    private static readonly string[] StandardIcuTypes =
    [
        "ICU",
        "HDU",
        "NICU",
        "PICU",
        "CCU",
        "SICU",
        "MICU",
        "CTICU",
        "Neuro ICU",
        "Burns ICU",
        "Isolation ICU"
    ];

    // ── 1. ICU Configurations ─────────────────────────────────────────────────
    public async Task<IcuMaster?> GetIcuByIdAsync(int id)
    {
        return await dbContext.IcuMasters
            .Include(i => i.Branch)
            .Include(i => i.Ward)
                .ThenInclude(w => w!.Floor)
            .Include(i => i.Tariffs)
                .ThenInclude(t => t.TariffCategory)
            .Include(i => i.Tariffs)
                .ThenInclude(t => t.Details)
            .FirstOrDefaultAsync(i => i.IcuId == id);
    }

    public async Task<IcuConfigurationFormViewModel?> GetIcuFormModelByIdAsync(int id)
    {
        var entity = await GetIcuByIdAsync(id);
        if (entity is null) return null;

        return new IcuConfigurationFormViewModel
        {
            IcuId = entity.IcuId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            WardId = entity.WardId,
            IcuCode = entity.IcuCode,
            IcuName = entity.IcuName,
            IcuType = entity.IcuType,
            BedCapacity = entity.BedCapacity,
            VentilatorCapacity = entity.VentilatorCapacity,
            IsolationCapacity = entity.IsolationCapacity,
            Description = entity.Description,
            IsActive = entity.IsActive,
            WardOptions = await GetWardOptionsAsync(entity.WardId, entity.BranchId),
            IcuTypeOptions = GetIcuTypeOptions(entity.IcuType)
        };
    }

    public async Task<int> CreateIcuAsync(IcuConfigurationFormViewModel model, int? userId)
    {
        var entity = new IcuMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            WardId = model.WardId,
            IcuCode = model.IcuCode.Trim().ToUpperInvariant(),
            IcuName = model.IcuName.Trim(),
            IcuType = model.IcuType.Trim(),
            BedCapacity = model.BedCapacity,
            VentilatorCapacity = model.VentilatorCapacity,
            IsolationCapacity = model.IsolationCapacity,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.IcuMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.IcuId;
    }

    public async Task<bool> UpdateIcuAsync(IcuConfigurationFormViewModel model, int? userId)
    {
        var entity = await dbContext.IcuMasters.FindAsync(model.IcuId);
        if (entity is null) return false;

        entity.WardId = model.WardId;
        entity.IcuCode = model.IcuCode.Trim().ToUpperInvariant();
        entity.IcuName = model.IcuName.Trim();
        entity.IcuType = model.IcuType.Trim();
        entity.BedCapacity = model.BedCapacity;
        entity.VentilatorCapacity = model.VentilatorCapacity;
        entity.IsolationCapacity = model.IsolationCapacity;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleIcuActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.IcuMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteIcuAsync(int id, int? userId)
    {
        var entity = await dbContext.IcuMasters
            .Include(i => i.Tariffs)
            .FirstOrDefaultAsync(i => i.IcuId == id);

        if (entity is null) return false;

        if (entity.Tariffs.Any())
        {
            // Soft delete if tariffs configured
            entity.IsActive = false;
            entity.ModifiedBy = userId;
            entity.ModifiedDate = DateTime.Now;
        }
        else
        {
            dbContext.IcuMasters.Remove(entity);
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> IsIcuCodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var normalized = code.Trim().ToUpperInvariant();
        var query = dbContext.IcuMasters.Where(i => i.BranchId == branchId && i.IcuCode == normalized);
        if (excludeId.HasValue)
            query = query.Where(i => i.IcuId != excludeId.Value);

        return await query.AnyAsync();
    }

    // ── 2. Dynamic ICU Tariffs ────────────────────────────────────────────────
    public async Task<IcuTariffMaster?> GetTariffByIdAsync(int id)
    {
        return await dbContext.IcuTariffMasters
            .Include(t => t.Branch)
            .Include(t => t.Icu)
                .ThenInclude(i => i!.Ward)
            .Include(t => t.TariffCategory)
            .Include(t => t.Details.OrderBy(d => d.DisplayOrder))
            .FirstOrDefaultAsync(t => t.IcuTariffId == id);
    }

    public async Task<IcuTariffFormViewModel?> GetTariffFormModelByIdAsync(int id)
    {
        var entity = await GetTariffByIdAsync(id);
        if (entity is null) return null;

        return new IcuTariffFormViewModel
        {
            IcuTariffId = entity.IcuTariffId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            IcuId = entity.IcuId,
            TariffCategoryId = entity.TariffCategoryId,
            TotalRate = entity.TotalRate,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            Description = entity.Description,
            IsActive = entity.IsActive,
            Details = entity.Details.Select(d => new IcuTariffDetailFormViewModel
            {
                IcuTariffDetailId = d.IcuTariffDetailId,
                IcuTariffId = d.IcuTariffId,
                RateHeadName = d.RateHeadName,
                RateHeadCode = d.RateHeadCode,
                RateAmount = d.RateAmount,
                BillingFrequency = d.BillingFrequency,
                IsMandatory = d.IsMandatory,
                Remarks = d.Remarks,
                DisplayOrder = d.DisplayOrder
            }).ToList(),
            IcuOptions = await GetIcuOptionsAsync(entity.IcuId, entity.BranchId),
            TariffCategoryOptions = await GetTariffCategoryOptionsAsync(entity.TariffCategoryId, entity.BranchId)
        };
    }

    public async Task<int> CreateTariffAsync(IcuTariffFormViewModel model, int? userId)
    {
        var total = model.Details.Sum(d => d.RateAmount);

        var entity = new IcuTariffMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            IcuId = model.IcuId,
            TariffCategoryId = model.TariffCategoryId,
            TotalRate = total,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        // Add dynamic line items
        int order = 1;
        foreach (var d in model.Details.Where(x => !string.IsNullOrWhiteSpace(x.RateHeadName)))
        {
            entity.Details.Add(new IcuTariffDetail
            {
                RateHeadName = d.RateHeadName.Trim(),
                RateHeadCode = d.RateHeadCode?.Trim().ToUpperInvariant(),
                RateAmount = d.RateAmount,
                BillingFrequency = string.IsNullOrWhiteSpace(d.BillingFrequency) ? "Per Day" : d.BillingFrequency.Trim(),
                IsMandatory = d.IsMandatory,
                Remarks = d.Remarks?.Trim(),
                DisplayOrder = order++
            });
        }

        dbContext.IcuTariffMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.IcuTariffId;
    }

    public async Task<bool> UpdateTariffAsync(IcuTariffFormViewModel model, int? userId)
    {
        var entity = await dbContext.IcuTariffMasters
            .Include(t => t.Details)
            .FirstOrDefaultAsync(t => t.IcuTariffId == model.IcuTariffId);

        if (entity is null) return false;

        var total = model.Details.Sum(d => d.RateAmount);

        entity.IcuId = model.IcuId;
        entity.TariffCategoryId = model.TariffCategoryId;
        entity.TotalRate = total;
        entity.EffectiveFrom = model.EffectiveFrom;
        entity.EffectiveTo = model.EffectiveTo;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        // Replace details
        dbContext.IcuTariffDetails.RemoveRange(entity.Details);
        entity.Details.Clear();

        int order = 1;
        foreach (var d in model.Details.Where(x => !string.IsNullOrWhiteSpace(x.RateHeadName)))
        {
            entity.Details.Add(new IcuTariffDetail
            {
                IcuTariffId = entity.IcuTariffId,
                RateHeadName = d.RateHeadName.Trim(),
                RateHeadCode = d.RateHeadCode?.Trim().ToUpperInvariant(),
                RateAmount = d.RateAmount,
                BillingFrequency = string.IsNullOrWhiteSpace(d.BillingFrequency) ? "Per Day" : d.BillingFrequency.Trim(),
                IsMandatory = d.IsMandatory,
                Remarks = d.Remarks?.Trim(),
                DisplayOrder = order++
            });
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleTariffActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.IcuTariffMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteTariffAsync(int id, int? userId)
    {
        var entity = await dbContext.IcuTariffMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.IcuTariffMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int icuId, int? excludeId = null)
    {
        var query = dbContext.IcuTariffMasters
            .Where(t => t.BranchId == branchId &&
                        t.TariffCategoryId == tariffCategoryId &&
                        t.IcuId == icuId &&
                        t.IsActive);

        if (excludeId.HasValue)
            query = query.Where(t => t.IcuTariffId != excludeId.Value);

        return await query.AnyAsync();
    }

    // ── 3. Dropdown Helpers ───────────────────────────────────────────────────
    public async Task<List<SelectListItem>> GetWardOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.WardMasters
            .Include(w => w.Floor)
            .Where(w => w.IsActive);

        if (branchId.HasValue)
            query = query.Where(w => w.BranchId == branchId.Value || w.BranchId == null);

        var list = await query
            .OrderBy(w => w.WardName)
            .ToListAsync();

        return list.Select(w => new SelectListItem
        {
            Value = w.WardId.ToString(),
            Text = $"{w.WardName} ({w.WardCode}) - {w.WardType}",
            Selected = selectedId.HasValue && w.WardId == selectedId.Value
        }).ToList();
    }

    public List<SelectListItem> GetIcuTypeOptions(string? selectedType = null)
    {
        return StandardIcuTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = !string.IsNullOrWhiteSpace(selectedType) && string.Equals(t, selectedType, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }

    public async Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.TariffCategoryMasters.Where(t => t.IsActive);
        if (branchId.HasValue)
            query = query.Where(t => t.BranchId == branchId.Value || t.BranchId == null);

        var list = await query
            .OrderBy(t => t.Name)
            .ToListAsync();

        return list.Select(t => new SelectListItem
        {
            Value = t.TariffCategoryId.ToString(),
            Text = string.IsNullOrWhiteSpace(t.PatientCategory) ? t.Name : $"{t.Name} ({t.PatientCategory})",
            Selected = selectedId.HasValue && t.TariffCategoryId == selectedId.Value
        }).ToList();
    }

    public async Task<List<SelectListItem>> GetIcuOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var query = dbContext.IcuMasters.Where(i => i.IsActive);
        if (branchId.HasValue)
            query = query.Where(i => i.BranchId == branchId.Value);

        var list = await query
            .OrderBy(i => i.IcuType)
            .ThenBy(i => i.IcuName)
            .ToListAsync();

        return list.Select(i => new SelectListItem
        {
            Value = i.IcuId.ToString(),
            Text = $"[{i.IcuType}] {i.IcuName} ({i.IcuCode}) - {i.BedCapacity} Beds",
            Selected = selectedId.HasValue && i.IcuId == selectedId.Value
        }).ToList();
    }
}
