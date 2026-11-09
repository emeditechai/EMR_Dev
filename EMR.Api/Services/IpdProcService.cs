using System.Data;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

/// <summary>
/// Runs the IPD stored procedures for api/ipd (SQLScripts/2422-2424). The controller always names the procedure of an
/// endpoint, never the caller. Rows come back as column / value pairs named as the procedure returns them.
/// </summary>
public interface IIpdProcService
{
    Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args);
    Task<IDictionary<string, object?>?> RowAsync(string proc, object args);
    Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count);
    /// <summary>Runs a procedure for its effect only (result sets, if any, are discarded).</summary>
    Task ExecAsync(string proc, object args);
}

public class IpdProcService(IDbConnectionFactory db) : IIpdProcService
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
        for (var i = 0; i < count; i++)
            sets.Add(m.IsConsumed ? new List<IDictionary<string, object?>>() : AsRows(await m.ReadAsync()));
        return sets;
    }

    public async Task ExecAsync(string proc, object args)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(proc, args, commandType: CommandType.StoredProcedure);
    }
}
