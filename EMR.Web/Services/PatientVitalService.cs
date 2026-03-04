using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class PatientVitalService(IDbConnectionFactory db) : IPatientVitalService
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
        null          => null,
        < 18.5m       => "Underweight",
        < 25m         => "Normal",
        < 30m         => "Overweight",
        _             => "Obese"
    };

    // ─── Add ──────────────────────────────────────────────────────────────────

    public async Task<int> AddVitalAsync(VitalEntryViewModel m, int recordedByUserId)
    {
        m.BMI         = CalcBMI(m.Height, m.Weight);
        m.BMICategory = GetBMICategory(m.BMI);

        using var con = db.CreateConnection();
        var result = await con.QuerySingleAsync<int>(
            "usp_PatientVital_Create",
            BuildParams(m, recordedByUserId),
            commandType: CommandType.StoredProcedure);
        return result;
    }

    // ─── Update ───────────────────────────────────────────────────────────────

    public async Task UpdateVitalAsync(VitalEntryViewModel m, int updatedByUserId)
    {
        m.BMI         = CalcBMI(m.Height, m.Weight);
        m.BMICategory = GetBMICategory(m.BMI);

        var p = new DynamicParameters();
        p.Add("@PatientVitalId",  m.PatientVitalId);
        p.Add("@Height",          m.Height);
        p.Add("@Weight",          m.Weight);
        p.Add("@BMI",             m.BMI);
        p.Add("@BMICategory",     m.BMICategory);
        p.Add("@BPSystolic",      m.BPSystolic);
        p.Add("@BPDiastolic",     m.BPDiastolic);
        p.Add("@PulseRate",       m.PulseRate);
        p.Add("@SpO2",            m.SpO2);
        p.Add("@Temperature",     m.Temperature);
        p.Add("@RespiratoryRate", m.RespiratoryRate);
        p.Add("@BloodGlucose",    m.BloodGlucose);
        p.Add("@GlucoseType",     m.GlucoseType);
        p.Add("@PainScore",       m.PainScore);
        p.Add("@Notes",           m.Notes);
        p.Add("@UpdatedByUserId", updatedByUserId);

        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_PatientVital_Update", p,
            commandType: CommandType.StoredProcedure);
    }

    // ─── History (paged) ──────────────────────────────────────────────────────

    public async Task<(List<VitalHistoryRow> Rows, int TotalCount)> GetHistoryAsync(
        int patientId, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<VitalHistoryRow>(
            "usp_PatientVital_GetByPatient",
            new { PatientId = patientId, PageNumber = page, PageSize = pageSize },
            commandType: CommandType.StoredProcedure)).ToList();

        return (rows, rows.FirstOrDefault()?.TotalCount ?? 0);
    }

    // ─── Latest ───────────────────────────────────────────────────────────────

    public async Task<PatientVital?> GetLatestAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientVital>(
            "usp_PatientVital_GetLatest",
            new { PatientId = patientId },
            commandType: CommandType.StoredProcedure);
    }

    // ─── Get by ID ────────────────────────────────────────────────────────────

    public async Task<PatientVital?> GetByIdAsync(int vitalId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientVital>(
            "usp_PatientVital_GetById",
            new { PatientVitalId = vitalId },
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

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static DynamicParameters BuildParams(VitalEntryViewModel m, int userId)
    {
        var p = new DynamicParameters();
        p.Add("@PatientId",       m.PatientId);
        p.Add("@Height",          m.Height);
        p.Add("@Weight",          m.Weight);
        p.Add("@BMI",             m.BMI);
        p.Add("@BMICategory",     m.BMICategory);
        p.Add("@BPSystolic",      m.BPSystolic);
        p.Add("@BPDiastolic",     m.BPDiastolic);
        p.Add("@PulseRate",       m.PulseRate);
        p.Add("@SpO2",            m.SpO2);
        p.Add("@Temperature",     m.Temperature);
        p.Add("@RespiratoryRate", m.RespiratoryRate);
        p.Add("@BloodGlucose",    m.BloodGlucose);
        p.Add("@GlucoseType",     m.GlucoseType);
        p.Add("@PainScore",       m.PainScore);
        p.Add("@Notes",           m.Notes);
        p.Add("@RecordedByUserId", userId);
        return p;
    }
}
