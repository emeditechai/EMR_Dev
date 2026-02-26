using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class DoctorRoomService(IDbConnectionFactory db) : IDoctorRoomService
{
    public async Task<IEnumerable<DoctorRoomMaster>> GetAllByBranchAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorRoomMaster>(
            @"SELECT r.RoomId, r.RoomName, r.FloorId, f.FloorName, r.BranchId, r.IsActive,
                      r.CreatedBy, r.CreatedDate, r.ModifiedBy, r.ModifiedDate
               FROM DoctorRoomMaster r
               INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
               WHERE r.BranchId = @branchId
               ORDER BY f.FloorName, r.RoomName",
            new { branchId });
    }

    public async Task<DoctorRoomMaster?> GetByIdAsync(int id, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorRoomMaster>(
            @"SELECT r.RoomId, r.RoomName, r.FloorId, f.FloorName, r.BranchId, r.IsActive,
                      r.CreatedBy, r.CreatedDate, r.ModifiedBy, r.ModifiedDate
               FROM DoctorRoomMaster r
               INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
               WHERE r.RoomId = @id AND r.BranchId = @branchId",
            new { id, branchId });
    }

    public async Task<bool> NameExistsAsync(string roomName, int branchId, int floorId, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM DoctorRoomMaster
              WHERE BranchId = @branchId
                AND FloorId = @floorId
                AND RoomName = @roomName
                AND (@excludeId IS NULL OR RoomId <> @excludeId)",
            new { roomName, branchId, floorId, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(DoctorRoomMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO DoctorRoomMaster (RoomName, FloorId, BranchId, IsActive, CreatedBy, CreatedDate)
            VALUES (@RoomName, @FloorId, @BranchId, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.RoomName, m.FloorId, m.BranchId, m.IsActive, userId });
    }

    public async Task UpdateAsync(DoctorRoomMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE DoctorRoomMaster SET
                RoomName      = @RoomName,
                FloorId       = @FloorId,
                IsActive      = @IsActive,
                ModifiedBy    = @userId,
                ModifiedDate  = GETDATE()
            WHERE RoomId = @RoomId AND BranchId = @BranchId",
            new { m.RoomName, m.FloorId, m.IsActive, userId, m.RoomId, m.BranchId });
    }
}
