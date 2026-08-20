using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class HospitalServiceService(ApplicationDbContext dbContext, IDbConnectionFactory db) : IHospitalServiceService
{
    private static readonly List<string> StandardServiceTypes =
    [
        "IPD Service",
        "Nursing Service",
        "ICU Service",
        "OT Service",
        "Equipment Service",
        "Room Service",
        "Ambulance",
        "Diet",
        "Medical Gas",
        "Housekeeping Service",
        "CSSD Service",
        "Physiotherapy Service",
        "Other Service"
    ];

    private static readonly List<string> StandardUoms =
    [
        "Per Day",
        "Per Hour",
        "Per Session",
        "Per Visit",
        "Per Procedure",
        "Per Unit",
        "Per Km",
        "Per Meal",
        "Per Test",
        "Fixed / Flat"
    ];

    public async Task<HospitalServiceMaster?> GetByIdAsync(int id)
    {
        return await dbContext.HospitalServiceMasters
            .Include(x => x.Branch)
            .Include(x => x.Department)
            .FirstOrDefaultAsync(x => x.HospitalServiceId == id);
    }

    public async Task<List<HospitalServiceRateMaster>> GetRatesByServiceIdAsync(int serviceId)
    {
        return await dbContext.HospitalServiceRateMasters
            .Include(r => r.TariffCategory)
            .Include(r => r.Branch)
            .Where(r => r.HospitalServiceId == serviceId)
            .OrderByDescending(r => r.EffectiveFrom)
            .ToListAsync();
    }

    public async Task<HospitalServiceFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new HospitalServiceFormViewModel
        {
            HospitalServiceId = entity.HospitalServiceId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            DepartmentId = entity.DepartmentId,
            ServiceCode = entity.ServiceCode,
            ServiceName = entity.ServiceName,
            ServiceType = entity.ServiceType,
            UOM = entity.UOM,
            TaxPercentage = entity.TaxPercentage,
            Description = entity.Description,
            IsActive = entity.IsActive,
            DepartmentOptions = await GetDepartmentOptionsAsync(entity.DepartmentId),
            ServiceTypeOptions = GetServiceTypeOptions(entity.ServiceType),
            UomOptions = GetUomOptions(entity.UOM)
        };
    }

    public async Task<int> CreateAsync(HospitalServiceFormViewModel model, int? userId)
    {
        var entity = new HospitalServiceMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            DepartmentId = model.DepartmentId,
            ServiceCode = model.ServiceCode.Trim(),
            ServiceName = model.ServiceName.Trim(),
            ServiceType = model.ServiceType.Trim(),
            UOM = model.UOM.Trim(),
            TaxPercentage = model.TaxPercentage,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.HospitalServiceMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.HospitalServiceId;
    }

    public async Task<bool> UpdateAsync(HospitalServiceFormViewModel model, int? userId)
    {
        var entity = await dbContext.HospitalServiceMasters.FindAsync(model.HospitalServiceId);
        if (entity is null) return false;

        entity.DepartmentId = model.DepartmentId;
        entity.ServiceCode = model.ServiceCode.Trim();
        entity.ServiceName = model.ServiceName.Trim();
        entity.ServiceType = model.ServiceType.Trim();
        entity.UOM = model.UOM.Trim();
        entity.TaxPercentage = model.TaxPercentage;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.HospitalServiceMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.HospitalServiceMasters.FindAsync(id);
        if (entity is null) return false;

        // Check if referenced by HospitalServiceRateMaster
        var hasRates = await dbContext.HospitalServiceRateMasters.AnyAsync(r => r.HospitalServiceId == id);
        if (hasRates)
        {
            // Soft-delete if referenced
            entity.IsActive = false;
            entity.ModifiedBy = userId;
            entity.ModifiedDate = DateTime.Now;
        }
        else
        {
            dbContext.HospitalServiceMasters.Remove(entity);
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> CodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var query = dbContext.HospitalServiceMasters
            .Where(x => x.BranchId == branchId && x.ServiceCode.ToLower() == code.ToLower().Trim());

        if (excludeId.HasValue)
            query = query.Where(x => x.HospitalServiceId != excludeId.Value);

        return await query.AnyAsync();
    }

    public async Task<List<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null)
    {
        var depts = await dbContext.DepartmentMasters
            .Where(d => d.DeptType == "IPD" && d.IsActive)
            .OrderBy(d => d.DeptName)
            .ToListAsync();

        return depts.Select(d => new SelectListItem
        {
            Value = d.DeptId.ToString(),
            Text = $"{d.DeptName} ({d.DeptCode})",
            Selected = selectedId.HasValue && d.DeptId == selectedId.Value
        }).ToList();
    }

    public List<SelectListItem> GetServiceTypeOptions(string? selectedValue = null)
    {
        return StandardServiceTypes.Select(st => new SelectListItem
        {
            Value = st,
            Text = st,
            Selected = !string.IsNullOrWhiteSpace(selectedValue) && st.Equals(selectedValue, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }

    public List<SelectListItem> GetUomOptions(string? selectedValue = null)
    {
        return StandardUoms.Select(u => new SelectListItem
        {
            Value = u,
            Text = u,
            Selected = !string.IsNullOrWhiteSpace(selectedValue) && u.Equals(selectedValue, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }
}
