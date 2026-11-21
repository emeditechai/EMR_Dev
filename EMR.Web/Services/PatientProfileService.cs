using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

/// <summary>
/// One patient's full profile: demographics, OPD visits, LAB bills, vitals, family, membership, points and billing totals.
/// Shown to staff on Master > Patient Master > View (OPD/Details) and to the patient on the Patient Portal dashboard,
/// so both read exactly the same data.
/// </summary>
public interface IPatientProfileService
{
    /// <summary>The profile, or null when there is no such patient.</summary>
    Task<PatientDetailsViewModel?> BuildAsync(int patientId);

    /// <summary>Vitals over time for the Vital Graph (oldest first).</summary>
    Task<object> VitalsChartAsync(int patientId);

    /// <summary>Bill amount per visit day and visits per doctor, for the Visit Graph.</summary>
    Task<object> VisitsChartAsync(int patientId);
}

public sealed class PatientProfileService(
    IPatientService patientService,
    IVitalApiClient vitalApiClient,
    IDbConnectionFactory db) : IPatientProfileService
{
    public async Task<PatientDetailsViewModel?> BuildAsync(int patientId)
    {
        var patient = await patientService.GetByIdAsync(patientId);
        if (patient is null) return null;

        var names = await patientService.GetDemographicNamesAsync(patientId);
        string? idTypeName = patient.IdentificationTypeId.HasValue
            ? await patientService.GetIdentificationTypeNameAsync(patient.IdentificationTypeId.Value)
            : null;

        List<EMR.Web.ApiClients.Models.VitalRow> vitals = [];
        try
        {
            var vitalsResult = await vitalApiClient.GetHistoryAsync(patientId, 1, 50);
            vitals = vitalsResult?.Rows ?? [];
        }
        catch (Exception)
        {
            // Silently fallback if Api is down
        }

        List<PatientVisitHistoryItem> visits = [];
        try
        {
            using var con = db.CreateConnection();
            visits = await PatientRecordQueries.VisitsAsync(con, patientId);
        }
        catch (Exception)
        {
            // Silently fallback
        }

        List<PatientLabOrderHistoryItem> labOrders = [];
        try
        {
            using var con = db.CreateConnection();
            labOrders = await PatientRecordQueries.LabOrdersAsync(con, patientId);
        }
        catch (Exception)
        {
            // Silently fallback
        }

        var model = new PatientDetailsViewModel
        {
            Patient = patient,
            ReligionName = names.ReligionName,
            MaritalStatusName = names.MaritalStatusName,
            OccupationName = names.OccupationName,
            LanguageName = names.LanguageName,
            AreaName = names.AreaName,
            CityName = names.CityName,
            DistrictName = names.DistrictName,
            StateName = names.StateName,
            CountryName = names.CountryName,
            IdentificationTypeName = idTypeName,
            VisitHistory = visits,
            VitalHistory = vitals,
            LabOrderHistory = labOrders
        };

        try
        {
            await LoadPatientLinksAsync(model);
        }
        catch (Exception)
        {
            // Silently fallback: the profile still opens, only the linked sections stay empty
        }

        return model;
    }

    /// <summary>
    /// The rest of what hangs off a patient: relation, where / by whom registered, referral doctor, the family on the
    /// same mobile number, membership cards (held or covered by), the card members, points ledger and billing totals.
    /// </summary>
    private async Task LoadPatientLinksAsync(PatientDetailsViewModel model)
    {
        var p = model.Patient;
        using var con = db.CreateConnection();
        var links = await PatientRecordQueries.LinksAsync(con, p.PatientId, p.PhoneNumber, p.RelationId, p.BranchId, p.CreatedBy, p.ReferralDoctorId, p.CompanyId);
        model.RelationName = links.RelationName;
        model.RegisteredBranchName = links.RegisteredBranchName;
        model.RegisteredByName = links.RegisteredByName;
        model.ReferralDoctorName = links.ReferralDoctorName;
        model.Family = links.Family;
        model.MembershipCards = links.MembershipCards;
        model.CardMembers = links.CardMembers;
        model.PointsLedger = links.PointsLedger;
        model.BillingSummary = links.BillingSummary;
    }

    public async Task<object> VitalsChartAsync(int patientId)
    {
        try
        {
            var vitalsResult = await vitalApiClient.GetHistoryAsync(patientId, 1, 100);
            var rows = vitalsResult?.Rows ?? new List<EMR.Web.ApiClients.Models.VitalRow>();
            var chartData = rows
                .OrderBy(v => v.RecordedOn)
                .Select(v => new
                {
                    RecordedOn = v.RecordedOn.ToString("dd MMM yyyy, HH:mm"),
                    v.Height,
                    v.Weight,
                    v.BPSystolic,
                    v.BPDiastolic,
                    v.PulseRate,
                    v.SpO2,
                    v.Temperature,
                    v.BloodGlucose
                }).ToList();

            return chartData;
        }
        catch (Exception)
        {
            return Array.Empty<object>();
        }
    }

    public async Task<object> VisitsChartAsync(int patientId)
    {
        try
        {
            using var con = db.CreateConnection();
            var visitsByDate = await con.QueryAsync(@"
                SELECT 
                    CAST(s.VisitDate AS DATE) AS VisitDate, 
                    SUM(ISNULL(s.TotalAmount, 0)) AS TotalAmount
                FROM PatientOPDService s
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                GROUP BY CAST(s.VisitDate AS DATE)
                ORDER BY CAST(s.VisitDate AS DATE) ASC",
                new { PatientId = patientId });

            var consultingByDoctor = await con.QueryAsync(@"
                SELECT 
                    ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
                    COUNT(s.OPDServiceId) AS ConsultingCount
                FROM PatientOPDService s
                INNER JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                GROUP BY d.NamePrefix, d.FullName
                ORDER BY ConsultingCount DESC",
                new { PatientId = patientId });

            var chartData = new
            {
                billData = visitsByDate.Select(v => new
                {
                    visitDate = ((DateTime)v.VisitDate).ToString("dd MMM yyyy"),
                    totalAmount = (decimal)v.TotalAmount
                }).ToList(),
                consultingData = consultingByDoctor.Select(c => new
                {
                    doctorName = (string)c.DoctorName,
                    consultingCount = (int)c.ConsultingCount
                }).ToList()
            };

            return chartData;
        }
        catch (Exception)
        {
            return Array.Empty<object>();
        }
    }
}
