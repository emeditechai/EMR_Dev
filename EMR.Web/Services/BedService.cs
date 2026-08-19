using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class BedService(IDbConnectionFactory db) : IBedService
{
    public async Task<IEnumerable<BedListItemViewModel>> GetAllAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                b.BedId,
                b.BedNumber,
                b.BuildingId,
                bld.BuildingName,
                bld.BuildingCode,
                b.WardId,
                w.WardName,
                w.WardCode,
                b.RoomId,
                r.RoomNumber,
                r.RoomType,
                b.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                bc.CategoryCode AS BedCategoryCode,
                b.BedStatus,
                b.IsIsolation,
                b.IsICU,
                b.IsVentilatorCapable,
                b.IsActive,
                b.CreatedDate
            FROM BedMaster b
            INNER JOIN BuildingMaster bld ON b.BuildingId = bld.BuildingId
            INNER JOIN WardMaster w ON b.WardId = w.WardId
            INNER JOIN RoomMaster r ON b.RoomId = r.RoomId
            INNER JOIN BedCategoryMaster bc ON b.BedCategoryId = bc.BedCategoryId
            WHERE (@buildingId IS NULL OR b.BuildingId = @buildingId)
              AND (@wardId IS NULL OR b.WardId = @wardId)
              AND (@roomId IS NULL OR b.RoomId = @roomId)
              AND (@bedCategoryId IS NULL OR b.BedCategoryId = @bedCategoryId)
              AND (@bedStatus IS NULL OR b.BedStatus = @bedStatus)
              AND (@companyId IS NULL OR b.CompanyId = @companyId)
              AND (@branchId IS NULL OR b.BranchId = @branchId OR b.BranchId IS NULL)
            ORDER BY bld.BuildingCode, w.WardCode, r.RoomNumber, b.BedNumber";

        return await con.QueryAsync<BedListItemViewModel>(sql, new { buildingId, wardId, roomId, bedCategoryId, bedStatus, companyId, branchId });
    }

    public async Task<BedMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                b.BedId,
                b.CompanyId,
                b.BranchId,
                b.BuildingId,
                bld.BuildingName,
                bld.BuildingCode,
                b.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                b.RoomId,
                r.RoomNumber,
                r.RoomType,
                f.FloorName,
                b.BedNumber,
                b.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                bc.CategoryCode AS BedCategoryCode,
                b.BedStatus,
                b.IsIsolation,
                b.IsICU,
                b.IsVentilatorCapable,
                b.Description,
                b.IsActive,
                b.CreatedBy,
                b.CreatedDate,
                b.ModifiedBy,
                b.ModifiedDate
            FROM BedMaster b
            INNER JOIN BuildingMaster bld ON b.BuildingId = bld.BuildingId
            INNER JOIN WardMaster w ON b.WardId = w.WardId
            INNER JOIN RoomMaster r ON b.RoomId = r.RoomId
            INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
            INNER JOIN BedCategoryMaster bc ON b.BedCategoryId = bc.BedCategoryId
            WHERE b.BedId = @id";

        return await con.QueryFirstOrDefaultAsync<BedMaster>(sql, new { id });
    }

    public async Task<BedDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                b.BedId,
                b.CompanyId,
                b.BranchId,
                b.BuildingId,
                bld.BuildingName,
                bld.BuildingCode,
                b.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                b.RoomId,
                r.RoomNumber,
                r.RoomType,
                f.FloorName,
                b.BedNumber,
                b.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                bc.CategoryCode AS BedCategoryCode,
                b.BedStatus,
                b.IsIsolation,
                b.IsICU,
                b.IsVentilatorCapable,
                b.Description,
                b.IsActive,
                b.CreatedDate,
                b.ModifiedDate,
                b.CreatedBy,
                b.ModifiedBy
            FROM BedMaster b
            INNER JOIN BuildingMaster bld ON b.BuildingId = bld.BuildingId
            INNER JOIN WardMaster w ON b.WardId = w.WardId
            INNER JOIN RoomMaster r ON b.RoomId = r.RoomId
            INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
            INNER JOIN BedCategoryMaster bc ON b.BedCategoryId = bc.BedCategoryId
            WHERE b.BedId = @id";

        return await con.QueryFirstOrDefaultAsync<BedDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> BedNumberExistsAsync(string bedNumber, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM BedMaster
            WHERE BedNumber = @bedNumber
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR BedId <> @excludeId)",
            new { bedNumber, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(BedMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO BedMaster (
                CompanyId, BranchId, BuildingId, WardId, RoomId,
                BedNumber, BedCategoryId, BedStatus, IsIsolation,
                IsICU, IsVentilatorCapable, Description, IsActive,
                CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @BuildingId, @WardId, @RoomId,
                @BedNumber, @BedCategoryId, @BedStatus, @IsIsolation,
                @IsICU, @IsVentilatorCapable, @Description, @IsActive,
                @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.BuildingId,
            model.WardId,
            model.RoomId,
            model.BedNumber,
            model.BedCategoryId,
            model.BedStatus,
            model.IsIsolation,
            model.IsICU,
            model.IsVentilatorCapable,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(BedMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE BedMaster SET
                BuildingId          = @BuildingId,
                WardId              = @WardId,
                RoomId              = @RoomId,
                BedNumber           = @BedNumber,
                BedCategoryId       = @BedCategoryId,
                BedStatus           = @BedStatus,
                IsIsolation         = @IsIsolation,
                IsICU               = @IsICU,
                IsVentilatorCapable = @IsVentilatorCapable,
                Description         = @Description,
                IsActive            = @IsActive,
                ModifiedBy          = @userId,
                ModifiedDate        = GETDATE()
            WHERE BedId = @BedId";

        await con.ExecuteAsync(sql, new
        {
            model.BuildingId,
            model.WardId,
            model.RoomId,
            model.BedNumber,
            model.BedCategoryId,
            model.BedStatus,
            model.IsIsolation,
            model.IsICU,
            model.IsVentilatorCapable,
            model.Description,
            model.IsActive,
            userId,
            model.BedId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync("DELETE FROM BedMaster WHERE BedId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<SelectListItem>> GetBuildingOptionsAsync(int? selectedBuildingId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<BuildingMaster>(@"
            SELECT BuildingId, BuildingCode, BuildingName 
            FROM BuildingMaster 
            WHERE IsActive = 1 
            ORDER BY BuildingName");

        return list.Select(b => new SelectListItem
        {
            Value = b.BuildingId.ToString(),
            Text = $"{b.BuildingName} ({b.BuildingCode})",
            Selected = selectedBuildingId.HasValue && b.BuildingId == selectedBuildingId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? buildingId = null, int? selectedWardId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT w.WardId, w.WardCode, w.WardName, w.WardType, f.FloorName, b.BuildingName
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            INNER JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE w.IsActive = 1
              AND (@buildingId IS NULL OR f.BuildingId = @buildingId)
            ORDER BY w.WardName";

        var list = await con.QueryAsync<dynamic>(sql, new { buildingId });
        return list.Select(w => new SelectListItem
        {
            Value = ((int)w.WardId).ToString(),
            Text = $"{w.WardName} ({w.WardCode}) - {w.WardType}",
            Selected = selectedWardId.HasValue && (int)w.WardId == selectedWardId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetRoomOptionsAsync(int? wardId = null, int? selectedRoomId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT r.RoomId, r.RoomNumber, r.RoomType, r.RoomCategory, w.WardName
            FROM RoomMaster r
            INNER JOIN WardMaster w ON r.WardId = w.WardId
            WHERE r.IsActive = 1
              AND (@wardId IS NULL OR r.WardId = @wardId)
            ORDER BY r.RoomNumber";

        var list = await con.QueryAsync<dynamic>(sql, new { wardId });
        return list.Select(r => new SelectListItem
        {
            Value = ((int)r.RoomId).ToString(),
            Text = $"Room {r.RoomNumber} ({r.RoomType} - {r.RoomCategory})",
            Selected = selectedRoomId.HasValue && (int)r.RoomId == selectedRoomId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetBedCategoryOptionsAsync(int? selectedCategoryId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<BedCategoryMaster>(@"
            SELECT BedCategoryId, CategoryCode, CategoryName 
            FROM BedCategoryMaster 
            WHERE IsActive = 1 
            ORDER BY CategoryName");

        return list.Select(c => new SelectListItem
        {
            Value = c.BedCategoryId.ToString(),
            Text = string.IsNullOrWhiteSpace(c.CategoryCode)
                ? c.CategoryName
                : $"{c.CategoryName} ({c.CategoryCode})",
            Selected = selectedCategoryId.HasValue && c.BedCategoryId == selectedCategoryId.Value
        });
    }

    public async Task<IEnumerable<WardOptionByBuildingDto>> GetWardsByBuildingAsync(int buildingId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT w.WardId, w.WardCode, w.WardName, w.WardType, f.BuildingId
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            WHERE f.BuildingId = @buildingId AND w.IsActive = 1
            ORDER BY w.WardName";

        return await con.QueryAsync<WardOptionByBuildingDto>(sql, new { buildingId });
    }

    public async Task<IEnumerable<RoomOptionByWardDto>> GetRoomsByWardAsync(int wardId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT r.RoomId, r.RoomNumber, r.RoomType, r.RoomCategory, r.WardId
            FROM RoomMaster r
            WHERE r.WardId = @wardId AND r.IsActive = 1
            ORDER BY r.RoomNumber";

        return await con.QueryAsync<RoomOptionByWardDto>(sql, new { wardId });
    }

    public IEnumerable<SelectListItem> GetBedStatusOptions(string? selectedStatus = null)
    {
        var statuses = new[]
        {
            "Available",
            "Occupied",
            "Reserved",
            "Blocked",
            "Cleaning",
            "Maintenance"
        };

        return statuses.Select(s => new SelectListItem
        {
            Value = s,
            Text = s,
            Selected = string.Equals(s, selectedStatus, StringComparison.OrdinalIgnoreCase)
        });
    }
}
