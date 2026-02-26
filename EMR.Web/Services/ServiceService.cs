using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class ServiceService(IDbConnectionFactory db) : IServiceService
{
    public async Task<IEnumerable<ServiceMaster>> GetAllByBranchAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ServiceMaster>(
            @"SELECT * FROM ServiceMaster
              WHERE BranchId = @branchId
              ORDER BY ServiceType, ItemCode",
            new { branchId });
    }

    public async Task<ServiceMaster?> GetByIdAsync(int id, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<ServiceMaster>(
            "SELECT * FROM ServiceMaster WHERE ServiceId = @id AND BranchId = @branchId",
            new { id, branchId });
    }

    public async Task<bool> ItemCodeExistsAsync(string itemCode, int branchId, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM ServiceMaster
              WHERE BranchId = @branchId
                AND ItemCode = @itemCode
                AND (@excludeId IS NULL OR ServiceId <> @excludeId)",
            new { itemCode, branchId, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(ServiceMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO ServiceMaster
                (ItemCode, ItemName, ServiceType, ItemCharges, BranchId, IsActive, CreatedBy, CreatedDate)
            VALUES
                (@ItemCode, @ItemName, @ServiceType, @ItemCharges, @BranchId, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.ItemCode, m.ItemName, m.ServiceType, m.ItemCharges, m.BranchId, m.IsActive, userId });
    }

    public async Task UpdateAsync(ServiceMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE ServiceMaster SET
                ItemCode     = @ItemCode,
                ItemName     = @ItemName,
                ServiceType  = @ServiceType,
                ItemCharges  = @ItemCharges,
                IsActive     = @IsActive,
                ModifiedBy   = @userId,
                ModifiedDate = GETDATE()
            WHERE ServiceId = @ServiceId AND BranchId = @BranchId",
            new { m.ItemCode, m.ItemName, m.ServiceType, m.ItemCharges, m.IsActive, userId, m.ServiceId, m.BranchId });
    }
}
