using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

/// <summary>
/// Quality &amp; Compliance module (SQLScripts/2247+): every screen reads and writes through stored procedures, which hold
/// all business rules (THROW 53000-53999 = a message for the user). Access per action comes from the page's endpoint map
/// (Settings &gt; Security), as for every other screen.
/// </summary>
[Authorize]
public abstract class QcControllerBase(IDbConnectionFactory db, IAuditLogService audit, ILogger logger) : Controller
{
    protected IDbConnectionFactory Db => db;
    protected int CompanyId => User.GetCompanyId();
    protected int UserId => User.GetUserId();
    protected int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

    /// <summary>A business-rule refusal from a procedure becomes { success:false, message }; anything else is logged.</summary>
    protected async Task<IActionResult> RunAsync(Func<IDbConnection, Task<object?>> work, string auditAction, string? auditText = null)
    {
        try
        {
            using var con = db.CreateConnection();
            var data = await work(con);
            if (auditText != null)
            {
                try { await audit.LogAsync("Quality & Compliance", auditAction, auditText, UserId, BranchId); }
                catch { /* audit only */ }
            }
            return Json(new { success = true, data });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return Json(new { success = false, message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] {Action} failed", auditAction);
            return Json(new { success = false, message = "The request could not be completed. Please try again." });
        }
    }

    protected async Task<IActionResult> QueryAsync(string procedure, object args)
    {
        try
        {
            using var con = db.CreateConnection();
            var rows = await con.QueryAsync(procedure, args, commandType: CommandType.StoredProcedure);
            return Json(new { success = true, data = rows });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return Json(new { success = false, message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] {Procedure} failed", procedure);
            return Json(new { success = false, message = "The list could not be loaded. Please try again." });
        }
    }

    /// <summary>Units, categories, LAB departments, analyzers, branches and sample types for the screens' dropdowns.</summary>
    protected async Task<object> LookupsAsync()
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Qc_Lookups", new { CompanyId }, commandType: CommandType.StoredProcedure);
        return new
        {
            units = (await m.ReadAsync()).ToList(),
            categories = (await m.ReadAsync()).ToList(),
            departments = (await m.ReadAsync()).ToList(),
            analyzers = (await m.ReadAsync()).ToList(),
            branches = (await m.ReadAsync()).ToList(),
            sampleTypes = (await m.ReadAsync()).ToList()
        };
    }
}
