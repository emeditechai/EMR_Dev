using System.Data;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

/// <summary>
/// Runs the pharmacy's stored procedures for the pharmacy controllers (SQLScripts/2358+). The controller always names
/// the procedure of an endpoint, never the caller. Rows come back as column / value pairs named like EMR.Web's models.
/// </summary>
public interface IPharmacyProcService
{
    Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args);
    Task<IDictionary<string, object?>?> RowAsync(string proc, object args);
    Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count);
}

public class PharmacyProcService(IDbConnectionFactory db) : IPharmacyProcService
{
    private static List<IDictionary<string, object?>> AsRows(IEnumerable<dynamic> rows) =>
        rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();

    public async Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args)
    {
        using var con = db.CreateConnection();
        return AsRows(await con.QueryAsync(proc, args, commandType: CommandType.StoredProcedure));
    }

    public async Task<IDictionary<string, object?>?> RowAsync(string proc, object args) => (await RowsAsync(proc, args)).FirstOrDefault();

    public async Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync(proc, args, commandType: CommandType.StoredProcedure);
        var sets = new List<List<IDictionary<string, object?>>>();
        for (var i = 0; i < count; i++) sets.Add(AsRows(await m.ReadAsync()));
        return sets;
    }
}
