using System.Data;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

/// <summary>
/// Runs the Quality &amp; Compliance stock procedures for api/qc/stock (SQLScripts/2498-2500). The controller always names
/// the procedure of an endpoint, never the caller. Rows come back as column / value pairs named as the procedure returns them.
/// A business-rule refusal raised by a procedure (THROW 50000+) surfaces as <see cref="QcStockRuleException"/>.
/// </summary>
public interface IQcStockProcService
{
    Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args);
    Task<IDictionary<string, object?>?> RowAsync(string proc, object args);
    Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count);
}

public sealed class QcStockRuleException(string message) : Exception(message);

public class QcStockProcService(IDbConnectionFactory db) : IQcStockProcService
{
    private static List<IDictionary<string, object?>> AsRows(IEnumerable<dynamic> rows) =>
        rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();

    private static async Task<T> Guard<T>(Func<Task<T>> work)
    {
        try { return await work(); }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000) { throw new QcStockRuleException(ex.Message); }
    }

    public Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args) => Guard(async () =>
    {
        using var con = db.CreateConnection();
        return AsRows(await con.QueryAsync(proc, args, commandType: CommandType.StoredProcedure, commandTimeout: 120));
    });

    public async Task<IDictionary<string, object?>?> RowAsync(string proc, object args) => (await RowsAsync(proc, args)).FirstOrDefault();

    public Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count) => Guard(async () =>
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync(proc, args, commandType: CommandType.StoredProcedure, commandTimeout: 120);
        var sets = new List<List<IDictionary<string, object?>>>();
        for (var i = 0; i < count; i++)
            sets.Add(m.IsConsumed ? new List<IDictionary<string, object?>>() : AsRows(await m.ReadAsync()));
        return sets;
    });
}
