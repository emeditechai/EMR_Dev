using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface IPharmacyPurchaseService
{
    Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args);
    Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count);
    Task<PhDocResult> DocAsync(string proc, object args, bool withHeader);
    Task<PhResult> ResultAsync(string proc, object args);
    Task ExecAsync(string proc, object args);
    Task<PhResult> PostAsync(string kind, PhDocRefRequest req);
}

/// <summary>
/// Pharmacy > Purchase (SQLScripts/2344 tables, 2357 procedures). Stored procedures only; the controller names
/// the procedure of each endpoint, never the caller. Rows come back as column / value pairs named like the
/// models of EMR.Web.
/// </summary>
public class PharmacyPurchaseService(IDbConnectionFactory db) : IPharmacyPurchaseService
{
    private static List<IDictionary<string, object?>> AsRows(IEnumerable<dynamic> rows) =>
        rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();

    public async Task<List<IDictionary<string, object?>>> RowsAsync(string proc, object args)
    {
        using var con = db.CreateConnection();
        return AsRows(await con.QueryAsync(proc, args, commandType: CommandType.StoredProcedure));
    }

    public async Task<List<List<IDictionary<string, object?>>>> SetsAsync(string proc, object args, int count)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync(proc, args, commandType: CommandType.StoredProcedure);
        var sets = new List<List<IDictionary<string, object?>>>();
        for (var i = 0; i < count; i++) sets.Add(AsRows(await m.ReadAsync()));
        return sets;
    }

    public async Task<PhDocResult> DocAsync(string proc, object args, bool withHeader)
    {
        var sets = await SetsAsync(proc, args, withHeader ? 3 : 2);
        return withHeader
            ? new PhDocResult { Header = sets[0].FirstOrDefault(), Lines = sets[1], Items = sets[2] }
            : new PhDocResult { Lines = sets[0], Items = sets[1] };
    }

    public async Task<PhResult> ResultAsync(string proc, object args)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<PhResult>(proc, args, commandType: CommandType.StoredProcedure);
    }

    public async Task ExecAsync(string proc, object args)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(proc, args, commandType: CommandType.StoredProcedure);
    }

    /// <summary>Posts a GRN or a purchase return (stock and ledger in usp_PhGrn_Post / usp_PhPurchaseReturn_Post).</summary>
    public async Task<PhResult> PostAsync(string kind, PhDocRefRequest req)
    {
        using var con = db.CreateConnection();
        var belongs = await con.ExecuteScalarAsync<bool>("dbo.usp_Api_PhPur_Belongs", new { Kind = kind, req.CompanyId, req.BranchId, req.Id }, commandType: CommandType.StoredProcedure);
        if (!belongs) return new PhResult { Error = kind == "grn" ? "GRN not found." : "Return not found." };
        try
        {
            var docNo = kind == "grn"
                ? await con.ExecuteScalarAsync<string>("dbo.usp_PhGrn_Post", new { GrnId = req.Id, req.UserId }, commandType: CommandType.StoredProcedure)
                : await con.ExecuteScalarAsync<string>("dbo.usp_PhPurchaseReturn_Post", new { ReturnId = req.Id, req.UserId }, commandType: CommandType.StoredProcedure);
            return new PhResult { Id = req.Id, DocNo = docNo };
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 54000) { return new PhResult { Error = ex.Message }; }   // 53xxx: accounts (books locked, ledger missing)
    }
}
