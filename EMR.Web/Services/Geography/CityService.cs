using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public class CityService(IDbConnectionFactory db) : ICityService
{
    public async Task<IEnumerable<CityMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CityMaster, DistrictMaster, CityMaster>(@"
            SELECT c.*, d.DistrictId, d.DistrictName FROM CityMaster c
            INNER JOIN DistrictMaster d ON c.DistrictId = d.DistrictId
            ORDER BY c.CityName",
            (c, d) => { c.District = d; return c; },
            splitOn: "DistrictId");
    }

    public async Task<CityMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var results = await con.QueryAsync<CityMaster, DistrictMaster, CityMaster>(@"
            SELECT c.*, d.DistrictId, d.DistrictName FROM CityMaster c
            INNER JOIN DistrictMaster d ON c.DistrictId = d.DistrictId
            WHERE c.CityId = @id",
            (c, d) => { c.District = d; return c; },
            new { id }, splitOn: "DistrictId");
        return results.FirstOrDefault();
    }

    public async Task<IEnumerable<CityMaster>> GetByDistrictAsync(int districtId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CityMaster>(
            "SELECT CityId, CityName, CityCode FROM CityMaster WHERE DistrictId = @districtId AND IsActive = 1 ORDER BY CityName",
            new { districtId });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM CityMaster WHERE CityCode = @code AND (@excludeId IS NULL OR CityId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(CityMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedBy, CreatedDate)
            VALUES (@CityCode, @CityName, @DistrictId, @IsActive, @userId, GETUTCDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.CityCode, m.CityName, m.DistrictId, m.IsActive, userId });
    }

    public async Task UpdateAsync(CityMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE CityMaster SET
                CityCode = @CityCode, CityName = @CityName,
                DistrictId = @DistrictId, IsActive = @IsActive,
                ModifiedBy = @userId, ModifiedDate = GETUTCDATE()
            WHERE CityId = @CityId",
            new { m.CityCode, m.CityName, m.DistrictId, m.IsActive, userId, m.CityId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var inUse = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM AreaMaster WHERE CityId = @id", new { id });
        if (inUse > 0) return false;
        await con.ExecuteAsync("DELETE FROM CityMaster WHERE CityId = @id", new { id });
        return true;
    }
}
