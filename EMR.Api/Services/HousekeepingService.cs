using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class HousekeepingService(IDbConnectionFactory db) : IHousekeepingService
{
    // ── Location Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKLocationListItemDto>> GetLocationsAsync(
        int? branchId = null,
        string? locationType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@LocationType", string.IsNullOrWhiteSpace(locationType) ? null : locationType.Trim());
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<HKLocationListItemDto>(
            "dbo.usp_Api_HKLocation_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<HKLocationDetailDto?> GetLocationByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<HKLocationDetailDto>(
            "dbo.usp_Api_HKLocation_GetById",
            new { Location_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateLocationAsync(HKLocationSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@LocationType", request.LocationType.Trim());
        parameters.Add("@Reference_ID", request.Reference_ID);
        parameters.Add("@LocationCode", request.LocationCode.Trim());
        parameters.Add("@LocationName", request.LocationName.Trim());
        parameters.Add("@Floor_ID", request.Floor_ID);
        parameters.Add("@Building_ID", request.Building_ID);
        parameters.Add("@RiskLevel", string.IsNullOrWhiteSpace(request.RiskLevel) ? "Moderate Risk" : request.RiskLevel.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewLocation_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Api_HKLocation_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewLocation_ID");
    }

    public async Task<bool> UpdateLocationAsync(int id, HKLocationSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Location_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@LocationType", request.LocationType.Trim());
        parameters.Add("@Reference_ID", request.Reference_ID);
        parameters.Add("@LocationCode", request.LocationCode.Trim());
        parameters.Add("@LocationName", request.LocationName.Trim());
        parameters.Add("@Floor_ID", request.Floor_ID);
        parameters.Add("@Building_ID", request.Building_ID);
        parameters.Add("@RiskLevel", string.IsNullOrWhiteSpace(request.RiskLevel) ? "Moderate Risk" : request.RiskLevel.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Api_HKLocation_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleLocationStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Api_HKLocation_ToggleStatus",
            new { Location_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteLocationAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Api_HKLocation_Delete",
            new { Location_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<IEnumerable<HKPhysicalMasterItemDto>> GetPhysicalMasterItemsAsync(string locationType, int? branchId = null)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryAsync<HKPhysicalMasterItemDto>(
            "dbo.usp_Api_HKLocation_GetPhysicalMasterItems",
            new { LocationType = locationType, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── Cleaning Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKCleaningListItemDto>> GetCleaningsAsync(
        int? branchId = null,
        string? cleaningType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CleaningType", string.IsNullOrWhiteSpace(cleaningType) ? null : cleaningType.Trim());
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<HKCleaningListItemDto>(
            "dbo.usp_Api_HKCleaning_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<HKCleaningDetailDto?> GetCleaningByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<HKCleaningDetailDto>(
            "dbo.usp_Api_HKCleaning_GetById",
            new { Cleaning_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateCleaningAsync(HKCleaningSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@CleaningType", request.CleaningType.Trim());
        parameters.Add("@Frequency", request.Frequency.Trim());
        parameters.Add("@ChecklistTemplate_ID", request.ChecklistTemplate_ID);
        parameters.Add("@ChemicalUsed", request.ChemicalUsed.Trim());
        parameters.Add("@EquipmentUsed", request.EquipmentUsed.Trim());
        parameters.Add("@SLA_Minutes", request.SLA_Minutes);
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewCleaning_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Api_HKCleaning_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewCleaning_ID");
    }

    public async Task<bool> UpdateCleaningAsync(int id, HKCleaningSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Cleaning_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@CleaningType", request.CleaningType.Trim());
        parameters.Add("@Frequency", request.Frequency.Trim());
        parameters.Add("@ChecklistTemplate_ID", request.ChecklistTemplate_ID);
        parameters.Add("@ChemicalUsed", request.ChemicalUsed.Trim());
        parameters.Add("@EquipmentUsed", request.EquipmentUsed.Trim());
        parameters.Add("@SLA_Minutes", request.SLA_Minutes);
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Api_HKCleaning_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleCleaningStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Api_HKCleaning_ToggleStatus",
            new { Cleaning_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteCleaningAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Api_HKCleaning_Delete",
            new { Cleaning_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    // ── HK Staff Master ──────────────────────────────────────────────────────
    public async Task<IEnumerable<HKStaffListItemDto>> GetStaffListAsync(
        int? branchId = null,
        int? shiftId = null,
        int? locationId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@ShiftMaster_ID", shiftId);
        parameters.Add("@AreaAllocation_ID", locationId);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<HKStaffListItemDto>(
            "dbo.usp_Api_HKStaff_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<HKStaffDetailDto?> GetStaffByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<HKStaffDetailDto>(
            "dbo.usp_Api_HKStaff_GetById",
            new { HKStaff_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateStaffAsync(HKStaffSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Staff_ID", request.Staff_ID);
        parameters.Add("@ShiftMaster_ID", request.ShiftMaster_ID);
        parameters.Add("@Supervisor_ID", request.Supervisor_ID);
        parameters.Add("@AreaAllocation_ID", request.AreaAllocation_ID);
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewHKStaff_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Api_HKStaff_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewHKStaff_ID");
    }

    public async Task<bool> UpdateStaffAsync(int id, HKStaffSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@HKStaff_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Staff_ID", request.Staff_ID);
        parameters.Add("@ShiftMaster_ID", request.ShiftMaster_ID);
        parameters.Add("@Supervisor_ID", request.Supervisor_ID);
        parameters.Add("@AreaAllocation_ID", request.AreaAllocation_ID);
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Api_HKStaff_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStaffStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Api_HKStaff_ToggleStatus",
            new { HKStaff_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteStaffAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Api_HKStaff_Delete",
            new { HKStaff_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    // ── Checklist Templates ─────────────────────────────────────────────────
    public async Task<IEnumerable<HKChecklistTemplateDto>> GetChecklistTemplatesAsync(int? branchId = null)
    {
        using var conn = db.CreateConnection();
        var sql = "SELECT Template_ID, CompanyId, Branch_ID, TemplateCode, TemplateName, ChecklistItemsJSON, IsActive FROM dbo.HKChecklistTemplateMaster WHERE (@BranchId IS NULL OR Branch_ID = @BranchId) AND IsActive = 1 ORDER BY TemplateName";
        return await conn.QueryAsync<HKChecklistTemplateDto>(sql, new { BranchId = branchId });
    }
}
