using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public class StateService(IDbConnectionFactory db) : IStateService
{
    public async Task<IEnumerable<StateMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<StateMaster, CountryMaster, StateMaster>(@"
            SELECT s.*, c.CountryId, c.CountryName FROM StateMaster s
            INNER JOIN CountryMaster c ON s.CountryId = c.CountryId
            ORDER BY s.StateName",
            (s, c) => { s.Country = c; return s; },
            splitOn: "CountryId");
    }

    public async Task<StateMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var results = await con.QueryAsync<StateMaster, CountryMaster, StateMaster>(@"
            SELECT s.*, c.CountryId, c.CountryName FROM StateMaster s
            INNER JOIN CountryMaster c ON s.CountryId = c.CountryId
            WHERE s.StateId = @id",
            (s, c) => { s.Country = c; return s; },
            new { id }, splitOn: "CountryId");
        return results.FirstOrDefault();
    }

    public async Task<IEnumerable<StateMaster>> GetByCountryAsync(int countryId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<StateMaster>(
            "SELECT StateId, StateName, StateCode FROM StateMaster WHERE CountryId = @countryId AND IsActive = 1 ORDER BY StateName",
            new { countryId });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM StateMaster WHERE StateCode = @code AND (@excludeId IS NULL OR StateId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(StateMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedBy, CreatedDate)
            VALUES (@StateCode, @StateName, @CountryId, @IsActive, @userId, GETUTCDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.StateCode, m.StateName, m.CountryId, m.IsActive, userId });
    }

    public async Task UpdateAsync(StateMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE StateMaster SET
                StateCode = @StateCode, StateName = @StateName,
                CountryId = @CountryId, IsActive = @IsActive,
                ModifiedBy = @userId, ModifiedDate = GETUTCDATE()
            WHERE StateId = @StateId",
            new { m.StateCode, m.StateName, m.CountryId, m.IsActive, userId, m.StateId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var inUse = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM DistrictMaster WHERE StateId = @id", new { id });
        if (inUse > 0) return false;
        await con.ExecuteAsync("DELETE FROM StateMaster WHERE StateId = @id", new { id });
        return true;
    }
}
