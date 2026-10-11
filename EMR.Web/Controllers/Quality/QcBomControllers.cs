using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

public sealed class QcBomLine
{
    public int ItemId { get; set; }
    public decimal Qty { get; set; }
    public string? Remarks { get; set; }
}

public sealed class QcBomSaveRequest
{
    public int TestId { get; set; }
    public int? AnalyzerId { get; set; }
    public decimal RerunPct { get; set; }
    public decimal DeadVolumePct { get; set; }
    public string? Remarks { get; set; }
    public List<QcBomLine> Lines { get; set; } = [];
}

public sealed class QcBomRemoveRequest
{
    public int TestId { get; set; }
    public int? AnalyzerId { get; set; }
}

public sealed class QcKitSaveRequest
{
    public int SampleTypeId { get; set; }
    public List<QcBomLine> Lines { get; set; } = [];
}

/// <summary>Test BOM: what one run of a test consumes, versioned (an unchanged save keeps the version).</summary>
public class QcBomController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcBomController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await LookupsAsync();
        return View("~/Views/Quality/TestBom.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? search, int? departmentId, string? bomStatus) =>
        QueryAsync("dbo.usp_Qc_Bom_TestList", new { CompanyId, BranchId, Search = search, DepartmentId = departmentId, BomStatus = bomStatus });

    /// <summary>Active items for the BOM line picker.</summary>
    [HttpGet]
    public Task<IActionResult> Items() =>
        QueryAsync("dbo.usp_Qc_Item_List", new { CompanyId, Search = (string?)null, CategoryId = (int?)null, Status = true });

    [HttpGet]
    public async Task<IActionResult> Get(int testId, int? analyzerId)
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Qc_Bom_Get", new { TestId = testId, AnalyzerId = analyzerId }, commandType: CommandType.StoredProcedure);
            var test = await m.ReadFirstOrDefaultAsync();
            if (test == null) return Json(new { success = false, message = "Test not found." });
            var bom = await m.ReadFirstOrDefaultAsync();
            var lines = (await m.ReadAsync()).ToList();
            var versions = (await m.ReadAsync()).ToList();
            return Json(new { success = true, data = new { test, bom, lines, versions } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] BOM load failed for test {TestId}", testId);
            return Json(new { success = false, message = "The BOM could not be loaded." });
        }
    }

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcBomSaveRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new
        {
            CompanyId, r.TestId, AnalyzerId = r.AnalyzerId is > 0 ? r.AnalyzerId : null, r.RerunPct, r.DeadVolumePct, r.Remarks,
            LinesJson = JsonSerializer.Serialize(r.Lines.Select(l => new { itemId = l.ItemId, qty = l.Qty, remarks = l.Remarks })), UserId
        });
        p.Add("@BomId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        p.Add("@Changed", dbType: DbType.Boolean, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Qc_Bom_Save", p, commandType: CommandType.StoredProcedure);
        return new { bomId = p.Get<int>("@BomId"), changed = p.Get<bool>("@Changed") };
    }, "QC.BomSaved", $"BOM of test #{r.TestId}{(r.AnalyzerId is > 0 ? $" (analyzer #{r.AnalyzerId})" : "")} saved with {r.Lines.Count} line(s)");

    [HttpPost]
    public Task<IActionResult> Remove([FromBody] QcBomRemoveRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Bom_Remove", new { r.TestId, AnalyzerId = r.AnalyzerId is > 0 ? r.AnalyzerId : null, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.BomRemoved", $"BOM of test #{r.TestId} removed");
}

/// <summary>Sample collection kit: what one collected sample of a type uses (tube, needle, swab, label).</summary>
public class QcSampleKitsController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcSampleKitsController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public IActionResult Index() => View("~/Views/Quality/SampleKits.cshtml");

    [HttpGet]
    public async Task<IActionResult> List()
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Qc_SampleKit_List", new { CompanyId }, commandType: CommandType.StoredProcedure);
            var types = (await m.ReadAsync()).ToList();
            var lines = (await m.ReadAsync()).ToList();
            return Json(new { success = true, data = new { types, lines } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] sample kit list failed");
            return Json(new { success = false, message = "The sample kits could not be loaded." });
        }
    }

    [HttpGet]
    public Task<IActionResult> Items() =>
        QueryAsync("dbo.usp_Qc_Item_List", new { CompanyId, Search = (string?)null, CategoryId = (int?)null, Status = true });

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcKitSaveRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_SampleKit_Save", new
        {
            CompanyId, r.SampleTypeId, LinesJson = JsonSerializer.Serialize(r.Lines.Select(l => new { itemId = l.ItemId, qty = l.Qty })), UserId
        }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.SampleKitSaved", $"Sample kit of sample type #{r.SampleTypeId} saved with {r.Lines.Count} line(s)");
}

/// <summary>BOM cost preview: material + collection kit cost of every test, profile test and package against its B2C rate.</summary>
public class QcCostPreviewController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcCostPreviewController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await LookupsAsync();
        return View("~/Views/Quality/CostPreview.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? kind, int? departmentId, string? search) =>
        QueryAsync("dbo.usp_Qc_CostPreview", new { CompanyId, BranchId, Kind = kind, DepartmentId = departmentId, Search = search });
}
