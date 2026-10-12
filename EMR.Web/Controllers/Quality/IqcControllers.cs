using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

// ── LF-05 Internal QC (SQLScripts/2254): materials / lots / targets, daily Westgard runs, Levey-Jennings ──────────

/// <summary>
/// The validation gate: a parameter whose internal QC run is rejected (no corrective action yet) at the branch that ran
/// the sample cannot be validated or approved. Lab Reporting Entry, Microbiology entry and the Report Approval Dashboard
/// ask before saving so the user sees the reason; the save / approve procedures enforce it as well.
/// </summary>
public static class IqcGate
{
    public static async Task<string?> BlockAsync(HttpContext http, int labOrderId, IEnumerable<long> sampleIds)
    {
        var ids = string.Join(",", sampleIds.Where(i => i > 0).Distinct());
        if (labOrderId <= 0 || ids.Length == 0) return null;
        try
        {
            var factory = http.RequestServices.GetRequiredService<IDbConnectionFactory>();
            using var con = factory.CreateConnection();
            var p = new DynamicParameters(new { LabOrderId = labOrderId, SampleIds = ids });
            p.Add("@Message", dbType: DbType.String, size: 1000, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Iqc_BlockMessage", p, commandType: CommandType.StoredProcedure);
            return p.Get<string?>("@Message");
        }
        catch (Exception ex)
        {
            // the procedures still enforce the rule; only the friendly message is lost
            http.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("IqcGate").LogWarning(ex, "[IQC] block check failed for order {Id}", labOrderId);
            return null;
        }
    }
}

public sealed class IqcMaterialRequest
{
    public int? MaterialId { get; set; }
    public string? MaterialName { get; set; }
    public string? Manufacturer { get; set; }
    public string? ControlLevel { get; set; }
    public string? Matrix { get; set; }
    public int? ItemId { get; set; }
    public int? DepartmentId { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
}

public sealed class IqcLotRequest
{
    public int? LotId { get; set; }
    public int MaterialId { get; set; }
    public string? LotNo { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public DateTime? ReceivedOn { get; set; }
    public DateTime? OpenedOn { get; set; }
    public bool Status { get; set; } = true;
    public string? Remarks { get; set; }
}

public sealed class IqcTargetRow
{
    public int AnalyzerId { get; set; }
    public int TestId { get; set; }
    public string? Unit { get; set; }
    public decimal Mean { get; set; }
    public decimal Sd { get; set; }
    public string? Source { get; set; }
    public bool Rule41s { get; set; }
    public bool Rule10x { get; set; }
    public bool IsActive { get; set; } = true;
}

public sealed class IqcTargetsRequest
{
    public int LotId { get; set; }
    public List<IqcTargetRow> Targets { get; set; } = [];
}

/// <summary>QC materials, their lots and the mean / SD targets per analyzer and parameter.</summary>
public class IqcSetupController(IDbConnectionFactory db, IAuditLogService audit, ILogger<IqcSetupController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await QcEquipmentController.EqLookupsAsync(Db, CompanyId);
        using var con = Db.CreateConnection();
        // control items of the Item Master (category Control / Calibrator) for the link to stock and BOM
        ViewBag.ControlItems = (await con.QueryAsync(@"SELECT i.ItemId AS Id, i.ItemName AS Name FROM dbo.InvItem i
            INNER JOIN dbo.InvItemCategory c ON c.CategoryId = i.CategoryId WHERE i.CompanyId = @CompanyId AND i.IsDeleted = 0 AND i.Status = 1
            AND c.IsQcMaterial = 1 ORDER BY i.ItemName", new { CompanyId })).ToList();
        return View("~/Views/Quality/IqcSetup.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> List()
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Iqc_SetupList", new { CompanyId }, commandType: CommandType.StoredProcedure);
            return Json(new { success = true, data = new { materials = (await m.ReadAsync()).ToList(), lots = (await m.ReadAsync()).ToList(), targets = (await m.ReadAsync()).ToList() } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[IQC] setup list failed");
            return Json(new { success = false, message = "The QC setup could not be loaded." });
        }
    }

    [HttpPost]
    public Task<IActionResult> SaveMaterial([FromBody] IqcMaterialRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new { r.MaterialId, CompanyId, r.MaterialName, r.Manufacturer, r.ControlLevel, r.Matrix, r.ItemId, r.DepartmentId, r.Remarks, r.Status, UserId });
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Iqc_MaterialSave", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }, "IQC.MaterialSaved", $"QC material '{r.MaterialName}' ({r.ControlLevel}) saved");

    [HttpPost]
    public Task<IActionResult> SaveLot([FromBody] IqcLotRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new { r.LotId, r.MaterialId, CompanyId, r.LotNo, r.ExpiryDate, r.ReceivedOn, r.OpenedOn, r.Status, r.Remarks, UserId });
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Iqc_LotSave", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }, "IQC.LotSaved", $"QC lot '{r.LotNo}' of material #{r.MaterialId} saved");

    [HttpPost]
    public Task<IActionResult> SaveTargets([FromBody] IqcTargetsRequest r) => RunAsync(async con =>
    {
        var json = JsonSerializer.Serialize(r.Targets.Select(t => new
        {
            analyzerId = t.AnalyzerId, testId = t.TestId, unit = t.Unit, mean = t.Mean, sd = t.Sd, source = t.Source, rule41s = t.Rule41s, rule10x = t.Rule10x, isActive = t.IsActive
        }));
        await con.ExecuteAsync("dbo.usp_Iqc_TargetSave", new { r.LotId, CompanyId, TargetsJson = json, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "IQC.TargetsSaved", $"QC targets of lot #{r.LotId} saved ({r.Targets.Count})");
}

public sealed class IqcRunValue
{
    public int TargetId { get; set; }
    public decimal? Value { get; set; }
}

public sealed class IqcRunRow
{
    public int TestId { get; set; }
    public List<IqcRunValue> Values { get; set; } = [];
    public string? Remarks { get; set; }
}

public sealed class IqcRunsRequest
{
    public int AnalyzerId { get; set; }
    public DateTime? RunAt { get; set; }
    public List<IqcRunRow> Runs { get; set; } = [];
}

public sealed class IqcActionRequest
{
    public int RunId { get; set; }
    public string? RootCause { get; set; }
    public string? CorrectiveAction { get; set; }
    public string? PatientImpact { get; set; }
    public bool RaiseCapa { get; set; }
}

/// <summary>Daily QC entry per analyzer: one run per parameter, judged by the Westgard rules; corrective action of rejected runs.</summary>
public class IqcEntryController(IDbConnectionFactory db, IAuditLogService audit, ILogger<IqcEntryController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await QcEquipmentController.EqLookupsAsync(Db, CompanyId);
        ViewBag.BranchId = BranchId;
        return View("~/Views/Quality/IqcEntry.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Grid(int analyzerId, DateTime? date)
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Iqc_EntryGrid", new { CompanyId, BranchId, AnalyzerId = analyzerId, Date = date },
                commandType: CommandType.StoredProcedure);
            return Json(new { success = true, data = new { targets = (await m.ReadAsync()).ToList(), runs = (await m.ReadAsync()).ToList() } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[IQC] grid failed for analyzer {Id}", analyzerId);
            return Json(new { success = false, message = "The QC entry could not be loaded." });
        }
    }

    [HttpGet]
    public Task<IActionResult> Pending() => QueryAsync("dbo.usp_Iqc_PendingActions", new { CompanyId, BranchId });

    /// <summary>Saves each parameter's run separately; one refused run does not stop the others.</summary>
    [HttpPost]
    public async Task<IActionResult> SaveRuns([FromBody] IqcRunsRequest r)
    {
        if (r == null || r.AnalyzerId <= 0) return Json(new { success = false, message = "Choose the analyzer." });
        var runs = r.Runs.Where(x => x.Values.Any(v => v.Value.HasValue)).ToList();
        if (runs.Count == 0) return Json(new { success = false, message = "Enter at least one QC value." });
        var outcome = new List<object>();
        using var con = Db.CreateConnection();
        foreach (var run in runs)
        {
            try
            {
                var p = new DynamicParameters(new
                {
                    CompanyId, BranchId, r.AnalyzerId, run.TestId, RunAt = r.RunAt ?? DateTime.Now,
                    ValuesJson = JsonSerializer.Serialize(run.Values.Where(v => v.Value.HasValue).Select(v => new { targetId = v.TargetId, value = v.Value })),
                    run.Remarks, UserId
                });
                p.Add("@RunId", dbType: DbType.Int32, direction: ParameterDirection.Output);
                p.Add("@Status", dbType: DbType.String, size: 10, direction: ParameterDirection.Output);
                p.Add("@Rules", dbType: DbType.String, size: 100, direction: ParameterDirection.Output);
                await con.ExecuteAsync("dbo.usp_Iqc_RunSave", p, commandType: CommandType.StoredProcedure);
                var status = p.Get<string>("@Status");
                outcome.Add(new { run.TestId, ok = true, runId = p.Get<int>("@RunId"), status, rules = p.Get<string?>("@Rules") });
                try { await audit.LogAsync("Quality & Compliance", "IQC.RunSaved", $"IQC run analyzer #{r.AnalyzerId} test #{run.TestId}: {status} {p.Get<string?>("@Rules")}", UserId, BranchId); } catch { }
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
            {
                outcome.Add(new { run.TestId, ok = false, message = ex.Message });
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[IQC] run save failed for test {Id}", run.TestId);
                outcome.Add(new { run.TestId, ok = false, message = "The run could not be saved." });
            }
        }
        return Json(new { success = true, data = outcome });
    }

    [HttpPost]
    public Task<IActionResult> Action([FromBody] IqcActionRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Iqc_RunAction", new { r.RunId, CompanyId, r.RootCause, r.CorrectiveAction, r.PatientImpact, r.RaiseCapa, UserId },
            commandType: CommandType.StoredProcedure);
        return null;
    }, "IQC.CorrectiveAction", $"Corrective action recorded for IQC run #{r.RunId}");
}

/// <summary>Levey-Jennings charts of a control level (target) with the lab's own statistics.</summary>
public class IqcChartController(IDbConnectionFactory db, IAuditLogService audit, ILogger<IqcChartController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index(int? targetId)
    {
        ViewBag.Lookups = await QcEquipmentController.EqLookupsAsync(Db, CompanyId);
        ViewBag.TargetId = targetId;
        return View("~/Views/Quality/IqcChart.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Targets()
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Iqc_SetupList", new { CompanyId }, commandType: CommandType.StoredProcedure);
            await m.ReadAsync(); await m.ReadAsync();
            return Json(new { success = true, data = (await m.ReadAsync()).ToList() });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[IQC] targets failed");
            return Json(new { success = false, message = "The QC targets could not be loaded." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> Data(int targetId, DateTime from, DateTime to)
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Iqc_Chart", new { CompanyId, BranchId, TargetId = targetId, FromDate = from.Date, ToDate = to.Date },
                commandType: CommandType.StoredProcedure);
            var target = await m.ReadFirstOrDefaultAsync();
            if (target == null) return Json(new { success = false, message = "Control target not found." });
            return Json(new { success = true, data = new { target, points = (await m.ReadAsync()).ToList(), stats = await m.ReadFirstOrDefaultAsync() } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[IQC] chart failed for target {Id}", targetId);
            return Json(new { success = false, message = "The chart could not be loaded." });
        }
    }
}
