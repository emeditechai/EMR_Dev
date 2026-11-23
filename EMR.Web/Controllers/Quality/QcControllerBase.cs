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
/// <summary>A rule checked in the web layer (e.g. an attachment), shown to the user as is.</summary>
public sealed class QcRuleException(string message) : Exception(message);

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
        catch (QcRuleException ex)
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

    // ── branch-wise records (equipment, EQAS, CAPA): a user works only on the records of the branch signed in to ──
    protected const string EquipmentBranchSql = "SELECT BranchId FROM dbo.QcEquipment WHERE EquipmentId = @Id AND CompanyId = @CompanyId AND IsDeleted = 0";
    protected const string BreakdownBranchSql = @"SELECT e.BranchId FROM dbo.QcEquipmentBreakdown b INNER JOIN dbo.QcEquipment e ON e.EquipmentId = b.EquipmentId
                                                 WHERE b.BreakdownId = @Id AND e.CompanyId = @CompanyId";
    protected const string ProgramBranchSql = "SELECT BranchId FROM dbo.QcEqasProgram WHERE ProgramId = @Id AND CompanyId = @CompanyId AND IsDeleted = 0";
    protected const string CycleBranchSql = @"SELECT p.BranchId FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId
                                             WHERE c.CycleId = @Id AND p.CompanyId = @CompanyId AND c.IsDeleted = 0";
    protected const string CapaBranchSql = "SELECT BranchId FROM dbo.QcCapa WHERE CapaId = @Id AND CompanyId = @CompanyId";

    /// <summary>null when the record belongs to the signed-in branch; otherwise the refusal to return.</summary>
    protected async Task<IActionResult?> OtherBranchAsync(string sql, int id)
    {
        using var con = db.CreateConnection();
        var branch = await con.ExecuteScalarAsync<int?>(sql, new { Id = id, CompanyId });
        if (branch == BranchId) return null;
        return Json(new { success = false, message = branch == null ? "The record was not found." : "This record belongs to another branch. Switch to that branch to work on it." });
    }

    private static readonly HashSet<string> UploadExtensions = new(StringComparer.OrdinalIgnoreCase) { ".pdf", ".jpg", ".jpeg", ".png", ".webp" };

    /// <summary>A certificate / report file under wwwroot/uploads/lab-compliance/{folder}; null when no file was sent.</summary>
    protected async Task<string?> SaveUploadAsync(IFormFile? file, string folder)
    {
        if (file == null || file.Length == 0) return null;
        var ext = Path.GetExtension(file.FileName);
        if (!UploadExtensions.Contains(ext)) throw new QcRuleException("Attach a PDF or an image (JPG, PNG, WEBP).");
        if (file.Length > 10 * 1024 * 1024) throw new QcRuleException("The file is larger than 10 MB.");
        var env = HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>();
        var dir = Path.Combine(env.WebRootPath, "uploads", "lab-compliance", folder);
        Directory.CreateDirectory(dir);
        var name = $"{Guid.NewGuid():N}{ext.ToLowerInvariant()}";
        await using (var stream = new FileStream(Path.Combine(dir, name), FileMode.Create)) await file.CopyToAsync(stream);
        return $"/uploads/lab-compliance/{folder}/{name}";
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
