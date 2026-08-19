using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class RoomService(IDbConnectionFactory db) : IRoomService
{
    public async Task<IEnumerable<RoomListItemViewModel>> GetAllAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                r.RoomId,
                r.RoomNumber,
                r.BuildingId,
                b.BuildingName,
                b.BuildingCode,
                r.FloorId,
                f.FloorName,
                f.FloorCode,
                r.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                r.RoomType,
                r.RoomCategory,
                r.IsIsolation,
                r.BedCapacity,
                r.IsActive,
                r.CreatedDate
            FROM RoomMaster r
            INNER JOIN BuildingMaster b ON r.BuildingId = b.BuildingId
            INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
            INNER JOIN WardMaster w ON r.WardId = w.WardId
            WHERE (@buildingId IS NULL OR r.BuildingId = @buildingId)
              AND (@floorId IS NULL OR r.FloorId = @floorId)
              AND (@wardId IS NULL OR r.WardId = @wardId)
              AND (@roomCategory IS NULL OR r.RoomCategory = @roomCategory)
              AND (@roomType IS NULL OR r.RoomType = @roomType)
              AND (@companyId IS NULL OR r.CompanyId = @companyId)
              AND (@branchId IS NULL OR r.BranchId = @branchId OR r.BranchId IS NULL)
            ORDER BY b.BuildingCode, f.FloorCode, w.WardCode, r.RoomNumber";

        return await con.QueryAsync<RoomListItemViewModel>(sql, new { buildingId, floorId, wardId, roomCategory, roomType, companyId, branchId });
    }

    public async Task<RoomMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                r.RoomId,
                r.CompanyId,
                r.BranchId,
                r.BuildingId,
                b.BuildingName,
                b.BuildingCode,
                r.FloorId,
                f.FloorName,
                f.FloorCode,
                r.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                r.RoomNumber,
                r.RoomType,
                r.RoomCategory,
                r.IsIsolation,
                r.BedCapacity,
                r.Description,
                r.IsActive,
                r.CreatedBy,
                r.CreatedDate,
                r.ModifiedBy,
                r.ModifiedDate
            FROM RoomMaster r
            INNER JOIN BuildingMaster b ON r.BuildingId = b.BuildingId
            INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
            INNER JOIN WardMaster w ON r.WardId = w.WardId
            WHERE r.RoomId = @id";

        return await con.QueryFirstOrDefaultAsync<RoomMaster>(sql, new { id });
    }

    public async Task<RoomDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                r.RoomId,
                r.CompanyId,
                r.BranchId,
                r.BuildingId,
                b.BuildingName,
                b.BuildingCode,
                r.FloorId,
                f.FloorName,
                f.FloorCode,
                r.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                r.RoomNumber,
                r.RoomType,
                r.RoomCategory,
                r.IsIsolation,
                r.BedCapacity,
                r.Description,
                r.IsActive,
                r.CreatedDate,
                r.ModifiedDate,
                r.CreatedBy,
                r.ModifiedBy
            FROM RoomMaster r
            INNER JOIN BuildingMaster b ON r.BuildingId = b.BuildingId
            INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
            INNER JOIN WardMaster w ON r.WardId = w.WardId
            WHERE r.RoomId = @id";

        return await con.QueryFirstOrDefaultAsync<RoomDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> RoomNumberExistsAsync(string roomNumber, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM RoomMaster
            WHERE RoomNumber = @roomNumber
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR RoomId <> @excludeId)",
            new { roomNumber, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(RoomMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO RoomMaster (
                CompanyId, BranchId, BuildingId, FloorId, WardId, RoomNumber,
                RoomType, RoomCategory, IsIsolation, BedCapacity, Description,
                IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @BuildingId, @FloorId, @WardId, @RoomNumber,
                @RoomType, @RoomCategory, @IsIsolation, @BedCapacity, @Description,
                @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.BuildingId,
            model.FloorId,
            model.WardId,
            model.RoomNumber,
            model.RoomType,
            model.RoomCategory,
            model.IsIsolation,
            model.BedCapacity,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(RoomMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE RoomMaster SET
                BuildingId   = @BuildingId,
                FloorId      = @FloorId,
                WardId       = @WardId,
                RoomNumber   = @RoomNumber,
                RoomType     = @RoomType,
                RoomCategory = @RoomCategory,
                IsIsolation  = @IsIsolation,
                BedCapacity  = @BedCapacity,
                Description  = @Description,
                IsActive     = @IsActive,
                ModifiedBy   = @userId,
                ModifiedDate = GETDATE()
            WHERE RoomId = @RoomId";

        await con.ExecuteAsync(sql, new
        {
            model.BuildingId,
            model.FloorId,
            model.WardId,
            model.RoomNumber,
            model.RoomType,
            model.RoomCategory,
            model.IsIsolation,
            model.BedCapacity,
            model.Description,
            model.IsActive,
            userId,
            model.RoomId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync("DELETE FROM RoomMaster WHERE RoomId = @id", new { id });
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

    public async Task<IEnumerable<SelectListItem>> GetFloorOptionsAsync(int? buildingId = null, int? selectedFloorId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT f.FloorId, f.FloorCode, f.FloorName, b.BuildingName 
            FROM FloorMaster f
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE f.IsActive = 1
              AND (@buildingId IS NULL OR f.BuildingId = @buildingId)
            ORDER BY b.BuildingCode, f.FloorCode";

        var list = await con.QueryAsync<FloorMaster>(sql, new { buildingId });
        return list.Select(f => new SelectListItem
        {
            Value = f.FloorId.ToString(),
            Text = string.IsNullOrWhiteSpace(f.BuildingName)
                ? $"{f.FloorName} ({f.FloorCode})"
                : $"{f.FloorName} ({f.FloorCode}) - {f.BuildingName}",
            Selected = selectedFloorId.HasValue && f.FloorId == selectedFloorId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? floorId = null, int? selectedWardId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT w.WardId, w.WardCode, w.WardName, w.WardType, f.FloorName
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            WHERE w.IsActive = 1
              AND (@floorId IS NULL OR w.FloorId = @floorId)
            ORDER BY w.WardName";

        var list = await con.QueryAsync<WardMaster>(sql, new { floorId });
        return list.Select(w => new SelectListItem
        {
            Value = w.WardId.ToString(),
            Text = $"{w.WardName} ({w.WardCode}) - {w.WardType}",
            Selected = selectedWardId.HasValue && w.WardId == selectedWardId.Value
        });
    }

    public async Task<IEnumerable<FloorOptionDto>> GetFloorsByBuildingAsync(int buildingId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT FloorId, FloorCode, FloorName, BuildingId 
            FROM FloorMaster 
            WHERE BuildingId = @buildingId AND IsActive = 1 
            ORDER BY FloorCode";

        return await con.QueryAsync<FloorOptionDto>(sql, new { buildingId });
    }

    public async Task<IEnumerable<WardOptionDto>> GetWardsByFloorAsync(int floorId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT WardId, WardCode, WardName, WardType, FloorId 
            FROM WardMaster 
            WHERE FloorId = @floorId AND IsActive = 1 
            ORDER BY WardName";

        return await con.QueryAsync<WardOptionDto>(sql, new { floorId });
    }

    public IEnumerable<SelectListItem> GetRoomTypeOptions(string? selectedType = null)
    {
        var types = new[]
        {
            "Single Room",
            "Double Sharing Room",
            "Triple Sharing Room",
            "Four Bedded Room",
            "Suite Room",
            "ICU Isolation Room",
            "Deluxe Room",
            "Super Deluxe Room",
            "Day Care Room",
            "Post-Operative Room",
            "Emergency Observation Room"
        };

        return types.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selectedType, StringComparison.OrdinalIgnoreCase)
        });
    }

    public IEnumerable<SelectListItem> GetRoomCategoryOptions(string? selectedCategory = null)
    {
        var categories = new[]
        {
            "General",
            "Semi-Private",
            "Private",
            "Deluxe",
            "Super Deluxe",
            "Executive Suite",
            "ICU / Critical Care",
            "Isolation / Negative Pressure",
            "Day Care"
        };

        return categories.Select(c => new SelectListItem
        {
            Value = c,
            Text = c,
            Selected = string.Equals(c, selectedCategory, StringComparison.OrdinalIgnoreCase)
        });
    }
}
