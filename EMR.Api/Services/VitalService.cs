using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class VitalService(IDbConnectionFactory db) : IVitalService
{
    // ─── BMI helpers ──────────────────────────────────────────────────────────

    private static decimal? CalcBMI(decimal? height, decimal? weight)
    {
        if (height is null or <= 0 || weight is null or <= 0) return null;
        var bmi = weight.Value / ((height.Value / 100) * (height.Value / 100));
        return Math.Round(bmi, 2);
    }

    private static string? GetBMICategory(decimal? bmi) => bmi switch
    {
        null      => null,
        < 18.5m   => "Underweight",
        < 25m     => "Normal",
        < 30m     => "Overweight",
        _         => "Obese"
    };

    // ─── Create ───────────────────────────────────────────────────────────────

    public async Task<int> CreateAsync(VitalCreateRequest r)
    {
        var bmi         = CalcBMI(r.Height, r.Weight);
        var bmiCategory = GetBMICategory(bmi);

        var p = new DynamicParameters();
        p.Add("@PatientId",        r.PatientId);
        p.Add("@Height",           r.Height);
        p.Add("@Weight",           r.Weight);
        p.Add("@BMI",              bmi);
        p.Add("@BMICategory",      bmiCategory);
        p.Add("@BPSystolic",       r.BPSystolic);
        p.Add("@BPDiastolic",      r.BPDiastolic);
        p.Add("@PulseRate",        r.PulseRate);
        p.Add("@SpO2",             r.SpO2);
        p.Add("@Temperature",      r.Temperature);
        p.Add("@RespiratoryRate",  r.RespiratoryRate);
        p.Add("@BloodGlucose",     r.BloodGlucose);
        p.Add("@GlucoseType",      r.GlucoseType);
        p.Add("@PainScore",        r.PainScore);
        p.Add("@Notes",            r.Notes);
        p.Add("@RecordedByUserId", r.RecordedByUserId);

        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<int>(
            "usp_PatientVital_Create", p,
            commandType: CommandType.StoredProcedure);
    }

    // ─── Update ───────────────────────────────────────────────────────────────

    public async Task UpdateAsync(VitalUpdateRequest r)
    {
        var bmi         = CalcBMI(r.Height, r.Weight);
        var bmiCategory = GetBMICategory(bmi);

        var p = new DynamicParameters();
        p.Add("@PatientVitalId",   r.PatientVitalId);
        p.Add("@Height",           r.Height);
        p.Add("@Weight",           r.Weight);
        p.Add("@BMI",              bmi);
        p.Add("@BMICategory",      bmiCategory);
        p.Add("@BPSystolic",       r.BPSystolic);
        p.Add("@BPDiastolic",      r.BPDiastolic);
        p.Add("@PulseRate",        r.PulseRate);
        p.Add("@SpO2",             r.SpO2);
        p.Add("@Temperature",      r.Temperature);
        p.Add("@RespiratoryRate",  r.RespiratoryRate);
        p.Add("@BloodGlucose",     r.BloodGlucose);
        p.Add("@GlucoseType",      r.GlucoseType);
        p.Add("@PainScore",        r.PainScore);
        p.Add("@Notes",            r.Notes);
        p.Add("@UpdatedByUserId",  r.UpdatedByUserId);

        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_PatientVital_Update", p,
            commandType: CommandType.StoredProcedure);
    }

    // ─── History (paged) ──────────────────────────────────────────────────────

    public async Task<VitalHistoryResult> GetHistoryAsync(int patientId, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<VitalRow>(
            "usp_PatientVital_GetByPatient",
            new { PatientId = patientId, PageNumber = page, PageSize = pageSize },
            commandType: CommandType.StoredProcedure)).ToList();

        return new VitalHistoryResult
        {
            Rows       = rows,
            TotalCount = rows.FirstOrDefault()?.TotalCount ?? 0,
            Page       = page,
            PageSize   = pageSize
        };
    }

    // ─── Get by ID ────────────────────────────────────────────────────────────

    public async Task<VitalRow?> GetByIdAsync(int vitalId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<VitalRow>(
            "usp_PatientVital_GetById",
            new { PatientVitalId = vitalId },
            commandType: CommandType.StoredProcedure);
    }

    // ─── Latest ───────────────────────────────────────────────────────────────

    public async Task<VitalRow?> GetLatestAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<VitalRow>(
            "usp_PatientVital_GetLatest",
            new { PatientId = patientId },
            commandType: CommandType.StoredProcedure);
    }

    // ─── Delete (soft) ────────────────────────────────────────────────────────

    public async Task DeleteAsync(int vitalId, int deletedByUserId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_PatientVital_Delete",
            new { PatientVitalId = vitalId, DeletedByUserId = deletedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    // ─── Print data ───────────────────────────────────────────────────────────

    public async Task<VitalPrintData?> GetPrintDataAsync(int patientId, int? branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "usp_Api_VitalPrint_GetData",
            new { PatientId = patientId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        var hospital    = await multi.ReadSingleOrDefaultAsync<HospitalPrintInfo>();
        var patient     = await multi.ReadSingleOrDefaultAsync<PatientPrintInfo>();
        var latestVital = await multi.ReadSingleOrDefaultAsync<VitalRow>();
        var lastBill    = await multi.ReadSingleOrDefaultAsync<LastBillRow>();

        if (patient is null) return null;

        return new VitalPrintData
        {
            Hospital      = hospital,
            Patient       = patient,
            LatestVital   = latestVital,
            LastOpdBillNo = lastBill?.OPDBillNo
        };
    }

    // Helper for last bill row
    private class LastBillRow { public string? OPDBillNo { get; set; } }
}
