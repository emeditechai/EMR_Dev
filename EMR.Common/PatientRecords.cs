using System.Data;
using Dapper;

namespace EMR.Common;

// What hangs off one patient - OPD visits, LAB bills, family, membership cards and points, billing totals - read the same
// way by EMR.Web (Patient Master > View, Patient Portal) and EMR.Api (the patient app).


// ─── Patient Visit History Item ──────────────────────────────────────────────
public class PatientVisitHistoryItem
{
    public int OPDServiceId { get; set; }
    public DateTime VisitDate { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public decimal TotalAmount { get; set; }
    public string Status { get; set; } = string.Empty;
    public string PaymentStatus { get; set; } = string.Empty;
    public string? ConsultingDoctorName { get; set; }
    public string ServiceTypesSummary { get; set; } = string.Empty;
}

/// <summary>A patient registered on the same mobile number (family / dependents, by relation).</summary>
public class PatientFamilyItem
{
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string FullName { get; set; } = "";
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public int? RelationId { get; set; }
    public string? RelationName { get; set; }
    public bool IsActive { get; set; }
    public bool IsSelf => RelationId == 1;
}

public class PatientMembershipCardItem
{
    public int CardId { get; set; }
    public string CardNo { get; set; } = "";
    public string? PlanName { get; set; }
    public string? PlanType { get; set; }
    public string Status { get; set; } = "";
    public DateTime ValidFrom { get; set; }
    public DateTime ValidTo { get; set; }
    public decimal PointsBalance { get; set; }
    public decimal PointValue { get; set; }
    public int MaxMembers { get; set; }
    public decimal FeeAmount { get; set; }
    public string? ReceiptNo { get; set; }
    public string? IssueBranchName { get; set; }
    public DateTime CreatedDate { get; set; }
    public bool IsPrimary { get; set; }
    public string? MemberRelation { get; set; }
    public int PrimaryPatientId { get; set; }
    public string? PrimaryName { get; set; }
    public string? PrimaryCode { get; set; }
    public bool MemberActive { get; set; }

    /// <summary>Active / Expired / Blocked / Cancelled / Renewed - expiry comes from ValidTo.</summary>
    public string EffectiveStatus => Status == "Active" && ValidTo.Date < DateTime.Today ? "Expired" : Status;
}

public class PatientCardMemberItem
{
    public int CardId { get; set; }
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string FullName { get; set; } = "";
    public string? Relation { get; set; }
    public bool IsPrimary { get; set; }
    public bool IsActive { get; set; }
}

public class PatientPointsItem
{
    public DateTime CreatedDate { get; set; }
    public string? CardNo { get; set; }
    public string TxnType { get; set; } = "";
    public decimal Points { get; set; }
    public decimal? Amount { get; set; }
    public decimal BalanceAfter { get; set; }
    public string? ReceiptNo { get; set; }
    public string? Narration { get; set; }
    public string? PatientName { get; set; }
}

public class PatientBillingSummaryItem
{
    public string ModuleCode { get; set; } = "";
    public int Bills { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Paid { get; set; }
    public decimal Due { get; set; }
}

public class PatientLabOrderHistoryItem
{
    public int LabOrderId { get; set; }
    public DateTime OrderDate { get; set; }
    public string BillNo { get; set; } = null!;
    public decimal TotalAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal PaidAmount { get; set; }
    public string PaymentStatus { get; set; } = null!;
    /// <summary>Tests already approved; &gt;0 means the approved lab report can be printed.</summary>
    public int ApprovedTestCount { get; set; }
}

/// <summary>Who a patient is linked to: relation, branch, registrar, referral doctor, family, cards, points, billing.</summary>
public sealed class PatientLinks
{
    public string? RelationName { get; set; }
    public string? RegisteredBranchName { get; set; }
    public string? RegisteredByName { get; set; }
    public string? ReferralDoctorName { get; set; }
    public List<PatientFamilyItem> Family { get; set; } = [];
    public List<PatientMembershipCardItem> MembershipCards { get; set; } = [];
    public List<PatientCardMemberItem> CardMembers { get; set; } = [];
    public List<PatientPointsItem> PointsLedger { get; set; } = [];
    public List<PatientBillingSummaryItem> BillingSummary { get; set; } = [];
}

public static class PatientRecordQueries
{
    /// <summary>The patient's OPD visits, newest first.</summary>
    public static async Task<List<PatientVisitHistoryItem>> VisitsAsync(IDbConnection con, int patientId) =>
        (await con.QueryAsync<PatientVisitHistoryItem>(@"
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

    /// <summary>The patient's LAB bills, newest first, with what is paid and how many tests are approved.</summary>
    public static async Task<List<PatientLabOrderHistoryItem>> LabOrdersAsync(IDbConnection con, int patientId) =>
        (await con.QueryAsync<PatientLabOrderHistoryItem>(@"
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

    /// <summary>The rest of what hangs off a patient: relation, where / by whom registered, referral doctor, the family on the
    /// same mobile number, membership cards (held or covered by), the card members, points ledger and billing totals.</summary>
    public static async Task<PatientLinks> LinksAsync(IDbConnection con, int patientId, string? phoneNumber, int? relationId, int? branchId,
        int? createdBy, int? referralDoctorId, int? companyId)
    {
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
            new { PatientId = patientId, PhoneNumber = phoneNumber, RelationId = relationId, BranchId = branchId, CreatedBy = createdBy,
                  ReferralDoctorId = referralDoctorId, CompanyId = companyId });
        var head = await grid.ReadFirstOrDefaultAsync();
        return new PatientLinks
        {
            RelationName = (string?)head?.RelationName,
            RegisteredBranchName = (string?)head?.RegisteredBranchName,
            RegisteredByName = (string?)head?.RegisteredByName,
            ReferralDoctorName = (string?)head?.ReferralDoctorName,
            Family = (await grid.ReadAsync<PatientFamilyItem>()).ToList(),
            MembershipCards = (await grid.ReadAsync<PatientMembershipCardItem>()).ToList(),
            CardMembers = (await grid.ReadAsync<PatientCardMemberItem>()).ToList(),
            PointsLedger = (await grid.ReadAsync<PatientPointsItem>()).ToList(),
            BillingSummary = (await grid.ReadAsync<PatientBillingSummaryItem>()).ToList()
        };
    }
}
