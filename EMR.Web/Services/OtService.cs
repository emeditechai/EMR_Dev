using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class OtService(ApplicationDbContext dbContext) : IOtService
{
    private static readonly string[] StandardOtTypes =
    [
        "Major OT",
        "Minor OT",
        "Laparoscopic / Endoscopic OT",
        "Cardiac OT / Cath Lab",
        "Orthopedic & Joint Replacement OT",
        "Neuro Surgery OT",
        "Ophthalmic (Eye) OT",
        "Obstetrics & Gynaecology / Labour OT",
        "Emergency & Trauma OT",
        "Daycare / Ambulatory OT",
        "Robotic Surgery OT",
        "Septic / Isolation OT",
        "General Surgical OT"
    ];

    public async Task<OtMaster?> GetByIdAsync(int id)
    {
        return await dbContext.OtMasters
            .Include(o => o.Branch)
            .Include(o => o.Floor)
            .FirstOrDefaultAsync(o => o.OtId == id);
    }

    public async Task<OtFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new OtFormViewModel
        {
            OtId = entity.OtId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            FloorId = entity.FloorId,
            OtCode = entity.OtCode,
            OtName = entity.OtName,
            OtType = entity.OtType,
            Capacity = entity.Capacity,
            EmergencyAvailable = entity.EmergencyAvailable,
            Description = entity.Description,
            IsActive = entity.IsActive,
            FloorOptions = await GetFloorOptionsAsync(entity.FloorId, entity.BranchId),
            OtTypeOptions = GetOtTypeOptions(entity.OtType)
        };
    }

    public async Task<int> CreateAsync(OtFormViewModel model, int? userId)
    {
        var entity = new OtMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            FloorId = model.FloorId,
            OtCode = model.OtCode.Trim().ToUpperInvariant(),
            OtName = model.OtName.Trim(),
            OtType = model.OtType.Trim(),
            Capacity = model.Capacity.Trim(),
            EmergencyAvailable = model.EmergencyAvailable,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.OtMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.OtId;
    }

    public async Task<bool> UpdateAsync(OtFormViewModel model, int? userId)
    {
        var entity = await dbContext.OtMasters.FindAsync(model.OtId);
        if (entity is null) return false;

        entity.FloorId = model.FloorId;
        entity.OtCode = model.OtCode.Trim().ToUpperInvariant();
        entity.OtName = model.OtName.Trim();
        entity.OtType = model.OtType.Trim();
        entity.Capacity = model.Capacity.Trim();
        entity.EmergencyAvailable = model.EmergencyAvailable;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.OtMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.OtMasters
            .Include(o => o.Equipments)
            .Include(o => o.Tariffs)
            .FirstOrDefaultAsync(o => o.OtId == id);

        if (entity is null) return false;

        if (entity.Equipments.Any() || entity.Tariffs.Any())
        {
            // Soft delete if dependencies exist
            entity.IsActive = false;
            entity.ModifiedBy = userId;
            entity.ModifiedDate = DateTime.Now;
        }
        else
        {
            dbContext.OtMasters.Remove(entity);
        }

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var normalized = code.Trim().ToUpperInvariant();
        var query = dbContext.OtMasters.Where(o => o.BranchId == branchId && o.OtCode == normalized);
        if (excludeId.HasValue)
            query = query.Where(o => o.OtId != excludeId.Value);

        return await query.AnyAsync();
    }

    public async Task<List<SelectListItem>> GetFloorOptionsAsync(int? selectedId = null, int? branchId = null)
    {
        var floors = await dbContext.FloorMasters
            .Where(f => f.IsActive)
            .Include(f => f.Building)
            .OrderBy(f => f.Building != null ? f.Building.BuildingName : string.Empty)
            .ThenBy(f => f.FloorName)
            .ToListAsync();

        var groups = new Dictionary<string, SelectListGroup>();

        var options = new List<SelectListItem>();
        foreach (var f in floors)
        {
            var buildingName = f.Building?.BuildingName ?? "General Building";
            if (!groups.TryGetValue(buildingName, out var grp))
            {
                grp = new SelectListGroup { Name = buildingName };
                groups[buildingName] = grp;
            }

            options.Add(new SelectListItem
            {
                Value = f.FloorId.ToString(),
                Text = $"{buildingName} — {f.FloorName} ({f.FloorCode})",
                Group = grp,
                Selected = selectedId.HasValue && f.FloorId == selectedId.Value
            });
        }

        return options;
    }

    public List<SelectListItem> GetOtTypeOptions(string? selectedType = null)
    {
        return StandardOtTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selectedType, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }

    public async Task<List<OtEquipmentMaster>> GetEquipmentsByOtIdAsync(int otId)
    {
        return await dbContext.OtEquipmentMasters
            .Where(e => e.OtId == otId)
            .OrderBy(e => e.EquipmentName)
            .ToListAsync();
    }

    public async Task<List<OtTariffMaster>> GetTariffsByOtIdAsync(int otId)
    {
        return await dbContext.OtTariffMasters
            .Include(t => t.TariffCategory)
            .Where(t => t.OtId == otId)
            .OrderByDescending(t => t.IsActive)
            .ThenBy(t => t.TariffCategory != null ? t.TariffCategory.Name : string.Empty)
            .ToListAsync();
    }
}
