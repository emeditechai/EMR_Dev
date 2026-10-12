using System.Data;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

// ── LF-06 Equipment and EQAS register (SQLScripts/2253) ──────────────────────────────────────────────────────

public sealed class QcEquipmentSaveRequest
{
    public int? EquipmentId { get; set; }
    public int BranchId { get; set; }
    public string? EquipmentName { get; set; }
    public int TypeId { get; set; }
    public int? AnalyzerId { get; set; }
    public int? DepartmentId { get; set; }
    public string? Make { get; set; }
    public string? Model { get; set; }
    public string? SerialNo { get; set; }
    public string? Location { get; set; }
    public int? SupplierId { get; set; }
    public DateTime? InstallDate { get; set; }
    public DateTime? WarrantyUpto { get; set; }
    public string? ContractType { get; set; }
    public int? ContractVendorId { get; set; }
    public DateTime? ContractFrom { get; set; }
    public DateTime? ContractUpto { get; set; }
    public decimal? ContractCost { get; set; }
    public decimal? PurchaseCost { get; set; }
    public int? CalibrationFreqDays { get; set; }
    public int? PmFreqDays { get; set; }
    public string? Remarks { get; set; }
}

public sealed class QcEquipmentStatusRequest
{
    public int Id { get; set; }
    public string? Status { get; set; }
    public string? Reason { get; set; }
}

public sealed class QcCalibrationForm
{
    public int EquipmentId { get; set; }
    public DateTime? CalibratedOn { get; set; }
    public string? Agency { get; set; }
    public string? AgencyName { get; set; }
    public int? VendorId { get; set; }
    public string? CertificateNo { get; set; }
    public string? Result { get; set; }
    public DateTime? NextDueOn { get; set; }
    public string? Remarks { get; set; }
    public IFormFile? Certificate { get; set; }
}

public sealed class QcMaintenanceForm
{
    public int EquipmentId { get; set; }
    public string? MaintType { get; set; }
    public DateTime? DoneOn { get; set; }
    public string? DoneByName { get; set; }
    public int? VendorId { get; set; }
    public string? Checklist { get; set; }
    public string? Findings { get; set; }
    public DateTime? NextDueOn { get; set; }
    public decimal? Cost { get; set; }
    public IFormFile? Report { get; set; }
}

public sealed class QcBreakdownOpenRequest
{
    public int EquipmentId { get; set; }
    public DateTime? ReportedOn { get; set; }
    public string? Problem { get; set; }
    public string? Impact { get; set; }
    public int? VendorId { get; set; }
    public string? VendorTicketNo { get; set; }
    public DateTime? CallLoggedOn { get; set; }
    public bool RaiseCapa { get; set; }
}

public sealed class QcBreakdownResolveRequest
{
    public int BreakdownId { get; set; }
    public DateTime? ResolvedOn { get; set; }
    public string? Resolution { get; set; }
    public string? PartsReplaced { get; set; }
    public decimal? Cost { get; set; }
    public bool QcVerified { get; set; }
}

/// <summary>Equipment register and equipment card: calibration, maintenance, breakdowns (ISO 15189 6.4).</summary>
public class QcEquipmentController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcEquipmentController> logger)
    : QcControllerBase(db, audit, logger)
{
    /// <summary>Equipment types, suppliers, analyzers, LAB departments, branches, users and tests for the dropdowns.</summary>
    internal static async Task<object> EqLookupsAsync(IDbConnectionFactory factory, int companyId)
    {
        using var con = factory.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Qc_EqLookups", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        return new
        {
            types = (await m.ReadAsync()).ToList(),
            suppliers = (await m.ReadAsync()).ToList(),
            analyzers = (await m.ReadAsync()).ToList(),
            departments = (await m.ReadAsync()).ToList(),
            branches = (await m.ReadAsync()).ToList(),
            users = (await m.ReadAsync()).ToList(),
            tests = (await m.ReadAsync()).ToList()
        };
    }

    [HttpGet]
    public async Task<IActionResult> Index(int? analyzerId)
    {
        ViewBag.Lookups = await EqLookupsAsync(Db, CompanyId);
        ViewBag.BranchId = BranchId;
        ViewBag.PrefillAnalyzerId = analyzerId;
        return View("~/Views/Quality/Equipment.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(int? typeId, int? departmentId, string? status, string? due, string? search) =>
        QueryAsync("dbo.usp_Qc_Equipment_List", new { CompanyId, BranchId, TypeId = typeId, DepartmentId = departmentId, Status = status, Due = due, Search = search });

    [HttpGet]
    public Task<IActionResult> Summary() =>
        QueryAsync("dbo.usp_Qc_Compliance_Summary", new { CompanyId, BranchId });

    /// <summary>Each analyzer's equipment status, for the Analyzers master page.</summary>
    [HttpGet]
    public Task<IActionResult> AnalyzerStatus() => QueryAsync("dbo.usp_Qc_AnalyzerEquipmentStatus", new { CompanyId, BranchId });

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] QcEquipmentSaveRequest r)
    {
        if (r.EquipmentId is > 0 && await OtherBranchAsync(EquipmentBranchSql, r.EquipmentId.Value) is { } refused) return refused;
        r.BranchId = BranchId;   // equipment is registered for the branch signed in to
        return await RunAsync(async con =>
        {
            var p = new DynamicParameters(new
            {
                r.EquipmentId, CompanyId, r.BranchId, r.EquipmentName, r.TypeId, r.AnalyzerId, r.DepartmentId, r.Make, r.Model, r.SerialNo, r.Location,
                r.SupplierId, r.InstallDate, r.WarrantyUpto, r.ContractType, r.ContractVendorId, r.ContractFrom, r.ContractUpto, r.ContractCost,
                r.PurchaseCost, r.CalibrationFreqDays, r.PmFreqDays, r.Remarks, UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Equipment_Save", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, r.EquipmentId is > 0 ? "QC.EquipmentUpdated" : "QC.EquipmentCreated", $"Equipment '{r.EquipmentName}' saved");
    }

    [HttpPost]
    public async Task<IActionResult> SetStatus([FromBody] QcEquipmentStatusRequest r)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, r.Id) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            await con.ExecuteAsync("dbo.usp_Qc_Equipment_SetStatus", new { EquipmentId = r.Id, CompanyId, r.Status, r.Reason, Delete = false, UserId },
                commandType: CommandType.StoredProcedure);
            return null;
        }, "QC.EquipmentStatus", $"Equipment #{r.Id} set {r.Status}");
    }

    [HttpPost]
    public async Task<IActionResult> Delete([FromBody] QcEquipmentStatusRequest r)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, r.Id) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            await con.ExecuteAsync("dbo.usp_Qc_Equipment_SetStatus", new { EquipmentId = r.Id, CompanyId, Status = "RETIRED", Reason = (string?)null, Delete = true, UserId },
                commandType: CommandType.StoredProcedure);
            return null;
        }, "QC.EquipmentDeleted", $"Equipment #{r.Id} deleted");
    }

    [HttpGet]
    public async Task<IActionResult> Card(int id)
    {
        ViewBag.Lookups = await EqLookupsAsync(Db, CompanyId);
        ViewBag.EquipmentId = id;
        return View("~/Views/Quality/EquipmentCard.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> CardData(int id)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, id) is { } refused) return refused;
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Qc_Equipment_Get", new { EquipmentId = id, CompanyId }, commandType: CommandType.StoredProcedure);
            var equipment = await m.ReadFirstOrDefaultAsync();
            if (equipment == null) return Json(new { success = false, message = "Equipment not found." });
            return Json(new
            {
                success = true,
                data = new
                {
                    equipment,
                    calibrations = (await m.ReadAsync()).ToList(),
                    maintenance = (await m.ReadAsync()).ToList(),
                    breakdowns = (await m.ReadAsync()).ToList(),
                    capas = (await m.ReadAsync()).ToList()
                }
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] equipment card {Id} failed", id);
            return Json(new { success = false, message = "The equipment could not be loaded." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> AddCalibration([FromForm] QcCalibrationForm f)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, f.EquipmentId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            var path = await SaveUploadAsync(f.Certificate, "equipment");
            var p = new DynamicParameters(new
            {
                f.EquipmentId, CompanyId, f.CalibratedOn, f.Agency, f.AgencyName, f.VendorId, f.CertificateNo, f.Result, f.NextDueOn, f.Remarks,
                CertificatePath = path, UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            p.Add("@CapaId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Calibration_Add", p, commandType: CommandType.StoredProcedure);
            return new { id = p.Get<int>("@NewId"), capaId = p.Get<int?>("@CapaId") };
        }, "QC.CalibrationRecorded", $"Calibration of equipment #{f.EquipmentId}: {f.Result}");
    }

    [HttpPost]
    public async Task<IActionResult> AddMaintenance([FromForm] QcMaintenanceForm f)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, f.EquipmentId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            var path = await SaveUploadAsync(f.Report, "equipment");
            var p = new DynamicParameters(new
            {
                f.EquipmentId, CompanyId, f.MaintType, f.DoneOn, f.DoneByName, f.VendorId, f.Checklist, f.Findings, f.NextDueOn, f.Cost, ReportPath = path, UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Maintenance_Add", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, "QC.MaintenanceRecorded", $"Maintenance ({f.MaintType}) of equipment #{f.EquipmentId}");
    }

    [HttpPost]
    public async Task<IActionResult> OpenBreakdown([FromBody] QcBreakdownOpenRequest r)
    {
        if (await OtherBranchAsync(EquipmentBranchSql, r.EquipmentId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            var p = new DynamicParameters(new
            {
                r.EquipmentId, CompanyId, r.ReportedOn, r.Problem, r.Impact, r.VendorId, r.VendorTicketNo, r.CallLoggedOn, r.RaiseCapa, UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Breakdown_Open", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, "QC.BreakdownReported", $"Breakdown of equipment #{r.EquipmentId}: {r.Problem}");
    }

    [HttpPost]
    public async Task<IActionResult> ResolveBreakdown([FromBody] QcBreakdownResolveRequest r)
    {
        if (await OtherBranchAsync(BreakdownBranchSql, r.BreakdownId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            await con.ExecuteAsync("dbo.usp_Qc_Breakdown_Resolve", new
            {
                r.BreakdownId, CompanyId, r.ResolvedOn, r.Resolution, r.PartsReplaced, r.Cost, r.QcVerified, UserId
            }, commandType: CommandType.StoredProcedure);
            return null;
        }, "QC.BreakdownResolved", $"Breakdown #{r.BreakdownId} resolved");
    }
}

public sealed class QcEqasTestRow
{
    public int TestId { get; set; }
    public string? ResultType { get; set; }
    public string? Unit { get; set; }
}

public sealed class QcEqasProgramRequest
{
    public int? ProgramId { get; set; }
    public int BranchId { get; set; }
    public string? ProgramName { get; set; }
    public string? Provider { get; set; }
    public string? EnrolmentNo { get; set; }
    public int? DepartmentId { get; set; }
    public int? CyclesPerYear { get; set; }
    public DateTime? EnrolledFrom { get; set; }
    public DateTime? EnrolledUpto { get; set; }
    public decimal? Fee { get; set; }
    public decimal? AcceptZ { get; set; }
    public decimal? ActionZ { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
    public List<QcEqasTestRow> Tests { get; set; } = [];
}

public sealed class QcEqasCycleRequest
{
    public int? CycleId { get; set; }
    public int ProgramId { get; set; }
    public string? CycleName { get; set; }
    public string? SampleCode { get; set; }
    public DateTime? ReceivedOn { get; set; }
    public DateTime? ReportDueOn { get; set; }
    public string? Remarks { get; set; }
}

public sealed class QcEqasResultForm
{
    public int CycleId { get; set; }
    public string? Stage { get; set; }
    public DateTime? SubmittedOn { get; set; }
    public DateTime? EvaluatedOn { get; set; }
    public string? ResultsJson { get; set; }
    public IFormFile? Report { get; set; }
}

/// <summary>EQAS / proficiency testing: programmes, cycles, our results against the provider's evaluation (ISO 15189 7.3.7.3).</summary>
public class QcEqasController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcEqasController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await QcEquipmentController.EqLookupsAsync(Db, CompanyId);
        ViewBag.BranchId = BranchId;
        return View("~/Views/Quality/Eqas.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> List(bool? status, string? search)
    {
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Qc_Eqas_ProgramList", new { CompanyId, BranchId, Status = status, Search = search },
                commandType: CommandType.StoredProcedure);
            return Json(new { success = true, data = new { programs = (await m.ReadAsync()).ToList(), tests = (await m.ReadAsync()).ToList() } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] EQAS programme list failed");
            return Json(new { success = false, message = "The programmes could not be loaded." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] QcEqasProgramRequest r)
    {
        if (r.ProgramId is > 0 && await OtherBranchAsync(ProgramBranchSql, r.ProgramId.Value) is { } refused) return refused;
        r.BranchId = BranchId;   // EQAS enrolment is per branch
        return await RunAsync(async con =>
        {
            var p = new DynamicParameters(new
            {
                r.ProgramId, CompanyId, r.BranchId, r.ProgramName, r.Provider, r.EnrolmentNo, r.DepartmentId, r.CyclesPerYear, r.EnrolledFrom, r.EnrolledUpto,
                r.Fee, r.AcceptZ, r.ActionZ, r.Remarks, r.Status,
                TestsJson = System.Text.Json.JsonSerializer.Serialize(r.Tests.Select(t => new { testId = t.TestId, resultType = t.ResultType, unit = t.Unit })),
                UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Eqas_ProgramSave", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, r.ProgramId is > 0 ? "QC.EqasProgramUpdated" : "QC.EqasProgramCreated", $"EQAS programme '{r.ProgramName}' saved");
    }

    [HttpGet]
    public async Task<IActionResult> Cycles(int programId)
    {
        if (await OtherBranchAsync(ProgramBranchSql, programId) is { } refused) return refused;
        return await QueryAsync("dbo.usp_Qc_Eqas_CycleList", new { ProgramId = programId, CompanyId });
    }

    [HttpPost]
    public async Task<IActionResult> SaveCycle([FromBody] QcEqasCycleRequest r)
    {
        if (await OtherBranchAsync(ProgramBranchSql, r.ProgramId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            var p = new DynamicParameters(new { r.CycleId, r.ProgramId, CompanyId, r.CycleName, r.SampleCode, r.ReceivedOn, r.ReportDueOn, r.Remarks, UserId });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Eqas_CycleSave", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, "QC.EqasCycleSaved", $"EQAS cycle '{r.CycleName}' of programme #{r.ProgramId} saved");
    }

    [HttpGet]
    public async Task<IActionResult> Results(int cycleId)
    {
        if (await OtherBranchAsync(CycleBranchSql, cycleId) is { } refused) return refused;
        try
        {
            using var con = Db.CreateConnection();
            using var m = await con.QueryMultipleAsync("dbo.usp_Qc_Eqas_ResultGet", new { CycleId = cycleId, CompanyId }, commandType: CommandType.StoredProcedure);
            var cycle = await m.ReadFirstOrDefaultAsync();
            if (cycle == null) return Json(new { success = false, message = "Cycle not found." });
            return Json(new { success = true, data = new { cycle, results = (await m.ReadAsync()).ToList() } });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC] EQAS results {Id} failed", cycleId);
            return Json(new { success = false, message = "The results could not be loaded." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> SaveResults([FromForm] QcEqasResultForm f)
    {
        if (await OtherBranchAsync(CycleBranchSql, f.CycleId) is { } refused) return refused;
        return await RunAsync(async con =>
        {
            var path = await SaveUploadAsync(f.Report, "eqas");
            await con.ExecuteAsync("dbo.usp_Qc_Eqas_ResultSave", new
            {
                f.CycleId, CompanyId, f.Stage, f.SubmittedOn, f.EvaluatedOn, ReportPath = path, ResultsJson = f.ResultsJson ?? "[]", UserId
            }, commandType: CommandType.StoredProcedure);
            return null;
        }, "QC.EqasResultsSaved", $"EQAS cycle #{f.CycleId}: {f.Stage}");
    }
}

public sealed class QcCapaRequest
{
    public int? CapaId { get; set; }
    public int BranchId { get; set; }
    public string? Title { get; set; }
    public string? Problem { get; set; }
    public string? RootCause { get; set; }
    public string? CorrectiveAction { get; set; }
    public string? PreventiveAction { get; set; }
    public int? ResponsibleUserId { get; set; }
    public DateTime? TargetDate { get; set; }
    public string? Status { get; set; }
    public string? Effectiveness { get; set; }
    public int? EquipmentId { get; set; }
}

/// <summary>Corrective and preventive action register (from EQAS, calibration, breakdowns or raised by hand).</summary>
public class QcCapaController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcCapaController> logger, IActionPermissionGuard guard)
    : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await QcEquipmentController.EqLookupsAsync(Db, CompanyId);
        ViewBag.BranchId = BranchId;
        return View("~/Views/Quality/Capa.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? status, string? sourceType, string? search) =>
        QueryAsync("dbo.usp_Qc_Capa_List", new { CompanyId, BranchId, Status = status, SourceType = sourceType, Search = search });

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] QcCapaRequest r)
    {
        // closing is its own control of the page
        if (r.CapaId is > 0 && await OtherBranchAsync(CapaBranchSql, r.CapaId.Value) is { } refused) return refused;
        r.BranchId = BranchId;   // CAPAs are raised and handled per branch
        if (string.Equals(r.Status, "CLOSED", StringComparison.OrdinalIgnoreCase) && !await guard.AllowsAsync(HttpContext, "QC.CAPA", "CLOSE"))
            return Json(new { success = false, message = "You do not have permission to close a CAPA." });
        return await RunAsync(async con =>
        {
            var p = new DynamicParameters(new
            {
                r.CapaId, CompanyId, r.BranchId, r.Title, r.Problem, r.RootCause, r.CorrectiveAction, r.PreventiveAction, r.ResponsibleUserId,
                r.TargetDate, r.Status, r.Effectiveness, r.EquipmentId, UserId
            });
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_Qc_Capa_Save", p, commandType: CommandType.StoredProcedure);
            return p.Get<int>("@NewId");
        }, r.CapaId is > 0 ? "QC.CapaUpdated" : "QC.CapaCreated", $"CAPA '{r.Title}' saved ({r.Status})");
    }
}
