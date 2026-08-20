using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class OtEquipmentService(ApplicationDbContext dbContext) : IOtEquipmentService
{
    private static readonly string[] StandardEquipmentTypes =
    [
        "Imaging / Radiology",
        "Surgical Microscope",
        "Laser System",
        "Electrosurgical / Cautery",
        "Anaesthesia & Ventilation Workstation",
        "Endoscopy / Laparoscopy Tower",
        "Patient Monitoring & Defibrillator",
        "Surgical Table & Lighting",
        "Suction & Waste Management",
        "General OT Equipment"
    ];

    public async Task<OtEquipmentMaster?> GetByIdAsync(int id)
    {
        return await dbContext.OtEquipmentMasters
            .Include(e => e.Branch)
            .Include(e => e.Ot)
                .ThenInclude(o => o!.Floor)
            .FirstOrDefaultAsync(e => e.EquipmentId == id);
    }

    public async Task<OtEquipmentFormViewModel?> GetFormModelByIdAsync(int id)
    {
        var entity = await GetByIdAsync(id);
        if (entity is null) return null;

        return new OtEquipmentFormViewModel
        {
            EquipmentId = entity.EquipmentId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            OtId = entity.OtId,
            EquipmentCode = entity.EquipmentCode,
            EquipmentName = entity.EquipmentName,
            EquipmentType = entity.EquipmentType,
            SerialNo = entity.SerialNo,
            CalibrationRequired = entity.CalibrationRequired,
            LastCalibrationDate = entity.LastCalibrationDate,
            CalibrationDueDate = entity.CalibrationDueDate,
            Description = entity.Description,
            IsActive = entity.IsActive,
            OtOptions = await GetOtOptionsAsync(entity.OtId, entity.BranchId),
            EquipmentTypeOptions = GetEquipmentTypeOptions(entity.EquipmentType)
        };
    }

    public async Task<int> CreateAsync(OtEquipmentFormViewModel model, int? userId)
    {
        var entity = new OtEquipmentMaster
        {
            CompanyId = model.CompanyId,
            BranchId = model.BranchId,
            OtId = model.OtId,
            EquipmentCode = model.EquipmentCode.Trim().ToUpperInvariant(),
            EquipmentName = model.EquipmentName.Trim(),
            EquipmentType = model.EquipmentType?.Trim(),
            SerialNo = model.SerialNo?.Trim(),
            CalibrationRequired = model.CalibrationRequired,
            LastCalibrationDate = model.LastCalibrationDate,
            CalibrationDueDate = model.CalibrationDueDate,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.OtEquipmentMasters.Add(entity);
        await dbContext.SaveChangesAsync();
        return entity.EquipmentId;
    }

    public async Task<bool> UpdateAsync(OtEquipmentFormViewModel model, int? userId)
    {
        var entity = await dbContext.OtEquipmentMasters.FindAsync(model.EquipmentId);
        if (entity is null) return false;

        entity.OtId = model.OtId;
        entity.EquipmentCode = model.EquipmentCode.Trim().ToUpperInvariant();
        entity.EquipmentName = model.EquipmentName.Trim();
        entity.EquipmentType = model.EquipmentType?.Trim();
        entity.SerialNo = model.SerialNo?.Trim();
        entity.CalibrationRequired = model.CalibrationRequired;
        entity.LastCalibrationDate = model.LastCalibrationDate;
        entity.CalibrationDueDate = model.CalibrationDueDate;
        entity.Description = model.Description?.Trim();
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> ToggleActiveAsync(int id, int? userId)
    {
        var entity = await dbContext.OtEquipmentMasters.FindAsync(id);
        if (entity is null) return false;

        entity.IsActive = !entity.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var entity = await dbContext.OtEquipmentMasters.FindAsync(id);
        if (entity is null) return false;

        dbContext.OtEquipmentMasters.Remove(entity);
        await dbContext.SaveChangesAsync();
        return true;
    }

    public async Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null)
    {
        var normalized = code.Trim().ToUpperInvariant();
        var query = dbContext.OtEquipmentMasters.Where(e => e.BranchId == branchId && e.EquipmentCode == normalized);
        if (excludeId.HasValue)
            query = query.Where(e => e.EquipmentId != excludeId.Value);

        return await query.AnyAsync();
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

    public List<SelectListItem> GetEquipmentTypeOptions(string? selectedType = null)
    {
        return StandardEquipmentTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selectedType, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }
}
