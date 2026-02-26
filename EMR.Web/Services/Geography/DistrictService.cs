using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public class DistrictService(IDbConnectionFactory db) : IDistrictService
{
    public async Task<IEnumerable<DistrictMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DistrictMaster, StateMaster, DistrictMaster>(@"
            SELECT d.*, s.StateId, s.StateName FROM DistrictMaster d
            INNER JOIN StateMaster s ON d.StateId = s.StateId
            ORDER BY d.DistrictName",
            (d, s) => { d.State = s; return d; },
            splitOn: "StateId");
    }

    public async Task<DistrictMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var results = await con.QueryAsync<DistrictMaster, StateMaster, DistrictMaster>(@"
            SELECT d.*, s.StateId, s.StateName FROM DistrictMaster d
            INNER JOIN StateMaster s ON d.StateId = s.StateId
            WHERE d.DistrictId = @id",
            (d, s) => { d.State = s; return d; },
            new { id }, splitOn: "StateId");
        return results.FirstOrDefault();
    }

    public async Task<IEnumerable<DistrictMaster>> GetByStateAsync(int stateId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DistrictMaster>(
            "SELECT DistrictId, DistrictName, DistrictCode FROM DistrictMaster WHERE StateId = @stateId AND IsActive = 1 ORDER BY DistrictName",
            new { stateId });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM DistrictMaster WHERE DistrictCode = @code AND (@excludeId IS NULL OR DistrictId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(DistrictMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedBy, CreatedDate)
            VALUES (@DistrictCode, @DistrictName, @StateId, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.DistrictCode, m.DistrictName, m.StateId, m.IsActive, userId });
    }

    public async Task UpdateAsync(DistrictMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE DistrictMaster SET
                DistrictCode = @DistrictCode, DistrictName = @DistrictName,
                StateId = @StateId, IsActive = @IsActive,
                ModifiedBy = @userId, ModifiedDate = GETDATE()
            WHERE DistrictId = @DistrictId",
            new { m.DistrictCode, m.DistrictName, m.StateId, m.IsActive, userId, m.DistrictId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var inUse = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM CityMaster WHERE DistrictId = @id", new { id });
        if (inUse > 0) return false;
        await con.ExecuteAsync("DELETE FROM DistrictMaster WHERE DistrictId = @id", new { id });
        return true;
    }
}
