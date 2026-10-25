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
            visits = (await con.QueryAsync<PatientVisitHistoryItem>(@"
                SELECT 
                    s.OPDServiceId, 
                    s.VisitDate, 
                    s.OPDBillNo, 
                    s.TokenNo, 
                    s.TotalAmount, 
                    s.Status, 
                    ISNULL((SELECT TOP 1 ph.PaymentStatus FROM PaymentHeader ph 
                            WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1), 'U') AS PaymentStatus,
                    ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultingDoctorName,
                    ISNULL(
                        STUFF((
                            SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                            FROM PatientOPDServiceItem si
                            WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                            FOR XML PATH(''), TYPE
                        ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
                    ) AS ServiceTypesSummary
                FROM PatientOPDService s
                LEFT JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                ORDER BY s.OPDServiceId DESC",
                new { PatientId = patientId })).ToList();
        }
        catch (Exception)
        {
            // Silently fallback
        }

        List<PatientLabOrderHistoryItem> labOrders = [];
        try
        {
            using var con = db.CreateConnection();
            labOrders = (await con.QueryAsync<PatientLabOrderHistoryItem>(@"
                SELECT 
                    l.LabOrderId,
                    l.OrderDate,
                    l.BillNo,
                    l.TotalAmount,
                    ISNULL(ph.SubTotal - ph.NetAmount, 0) AS DiscountAmount,
                    ISNULL(ph.TotalPaid, 0) AS PaidAmount,
                    ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
                    -- tests already signed off (Report Approve); >0 = the approved report can be printed
                    (SELECT COUNT(1)
                       FROM SampleCollection sc
                       INNER JOIN labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                      WHERE sc.Laborderid = l.LabOrderId AND led.ReportStatusId = 5) AS ApprovedTestCount
                FROM LabOrder l
                LEFT JOIN PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = l.LabOrderId AND ph.IsActive = 1
                WHERE l.PatientId = @PatientId AND l.IsActive = 1
                ORDER BY l.LabOrderId DESC",
                new { PatientId = patientId })).ToList();
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
        using var grid = await con.QueryMultipleAsync(@"
            DECLARE @Phone NVARCHAR(20) = NULLIF(LTRIM(RTRIM(@PhoneNumber)), '');

            SELECT (SELECT RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId) AS RelationName,
                   (SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @BranchId) AS RegisteredBranchName,
                   (SELECT COALESCE(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = @CreatedBy) AS RegisteredByName,
                   (SELECT LTRIM(ISNULL(Salutation + ' ', '') + DoctorName) FROM dbo.ReferralDoctorMaster WHERE ReferralDoctorId = @ReferralDoctorId) AS ReferralDoctorName;

            -- family: everyone registered on the same mobile number, head of family (Self) first
            SELECT f.PatientId, f.PatientCode,
                   LTRIM(CONCAT(f.Salutation + ' ', f.FirstName, ' ' + NULLIF(f.MiddleName, ''), ' ' + f.LastName)) AS FullName,
                   f.Gender, f.DateOfBirth, f.RelationId, rm.RelationName, f.IsActive
              FROM dbo.PatientMaster f
              LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = f.RelationId
             WHERE @Phone IS NOT NULL AND LTRIM(RTRIM(f.PhoneNumber)) = @Phone AND f.PatientId <> @PatientId
               AND ISNULL(f.CompanyId, 0) = ISNULL(@CompanyId, 0)
             ORDER BY CASE WHEN f.RelationId = 1 THEN 0 ELSE 1 END, f.IsActive DESC, ISNULL(rm.SortOrder, 99), f.PatientId;

            -- membership cards this patient holds or is covered by
            SELECT c.CardId, c.CardNo, pl.PlanName, pl.PlanType, c.Status, c.ValidFrom, c.ValidTo, c.PointsBalance, pl.PointValue,
                   pl.MaxMembers, c.FeeAmount, c.ReceiptNo, b.BranchName AS IssueBranchName, c.CreatedDate,
                   m.IsPrimary, m.Relation AS MemberRelation, m.IsActive AS MemberActive, c.PrimaryPatientId,
                   LTRIM(CONCAT(hp.Salutation + ' ', hp.FirstName, ' ' + NULLIF(hp.MiddleName, ''), ' ' + hp.LastName)) AS PrimaryName,
                   hp.PatientCode AS PrimaryCode
              FROM dbo.MembershipCardMember m
              JOIN dbo.MembershipCard c ON c.CardId = m.CardId
              JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
              LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.IssueBranchId
              LEFT JOIN dbo.PatientMaster hp ON hp.PatientId = c.PrimaryPatientId
             WHERE m.PatientId = @PatientId
             ORDER BY CASE WHEN c.Status = 'Active' AND c.ValidTo >= CAST(GETDATE() AS DATE) AND m.IsActive = 1 THEN 0 ELSE 1 END, c.CardId DESC;

            -- members of those cards
            SELECT m.CardId, m.PatientId, mp.PatientCode,
                   LTRIM(CONCAT(mp.Salutation + ' ', mp.FirstName, ' ' + NULLIF(mp.MiddleName, ''), ' ' + mp.LastName)) AS FullName,
                   m.Relation, m.IsPrimary, m.IsActive
              FROM dbo.MembershipCardMember m
              JOIN dbo.PatientMaster mp ON mp.PatientId = m.PatientId
             WHERE m.CardId IN (SELECT CardId FROM dbo.MembershipCardMember WHERE PatientId = @PatientId)
             ORDER BY m.CardId, m.IsPrimary DESC, m.CardMemberId;

            -- points ledger of those cards (newest first)
            SELECT TOP 100 l.CreatedDate, c.CardNo, l.TxnType, l.Points, l.Amount, l.BalanceAfter, l.ReceiptNo, l.Narration,
                   LTRIM(CONCAT(lp.FirstName, ' ' + lp.LastName)) AS PatientName
              FROM dbo.MembershipLedger l
              JOIN dbo.MembershipCard c ON c.CardId = l.CardId
              LEFT JOIN dbo.PatientMaster lp ON lp.PatientId = l.PatientId
             WHERE l.CardId IN (SELECT CardId FROM dbo.MembershipCardMember WHERE PatientId = @PatientId)
             ORDER BY l.LedgerId DESC;

            -- billing totals by module (active bills)
            SELECT ModuleCode, COUNT(*) AS Bills, SUM(ISNULL(NetAmount, 0)) AS NetAmount,
                   SUM(ISNULL(TotalPaid, 0)) AS Paid, SUM(ISNULL(BalanceDue, 0)) AS Due
              FROM dbo.PaymentHeader
             WHERE PatientId = @PatientId AND IsActive = 1
             GROUP BY ModuleCode;",
            new { p.PatientId, p.PhoneNumber, p.RelationId, p.BranchId, p.CreatedBy, p.ReferralDoctorId, p.CompanyId });

        var head = await grid.ReadFirstOrDefaultAsync();
        model.RelationName = (string?)head?.RelationName;
        model.RegisteredBranchName = (string?)head?.RegisteredBranchName;
        model.RegisteredByName = (string?)head?.RegisteredByName;
        model.ReferralDoctorName = (string?)head?.ReferralDoctorName;
        model.Family = (await grid.ReadAsync<PatientFamilyItem>()).ToList();
        model.MembershipCards = (await grid.ReadAsync<PatientMembershipCardItem>()).ToList();
        model.CardMembers = (await grid.ReadAsync<PatientCardMemberItem>()).ToList();
        model.PointsLedger = (await grid.ReadAsync<PatientPointsItem>()).ToList();
        model.BillingSummary = (await grid.ReadAsync<PatientBillingSummaryItem>()).ToList();
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
