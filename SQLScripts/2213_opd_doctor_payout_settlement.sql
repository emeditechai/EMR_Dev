-- ============================================================================
-- Migration: 2213_opd_doctor_payout_settlement.sql
-- Description: OPD doctor commission & disbursal, simplified to the usual hospital consultant-payout flow:
--
--   1. SHARE EARNED ON COLLECTION (automatic, no "Calculate" button)
--      Each OPD visit's doctor share is worked out from the Doctor Commission Config rules every time the workbench
--      opens or a settlement is prepared (dbo.usp_DoctorPayout_Accrue). The share follows the money: it is earned in
--      proportion to what has been collected on the bill, and dated the day the money came in. A due collected later
--      adds a TOP-UP line; a cancellation / refund after the share was settled adds a RECOVERY line that is deducted
--      from the doctor's next payout. Lines stay in dbo.DoctorDisbursal (one line per visit, plus top-up / recovery).
--   2. DAY-END SETTLEMENT, DOCTOR-WISE (payout voucher DPV/<branch><FY><no>)
--      For a day, each doctor's unsettled share up to that day goes on one settlement: gross share, recoveries, an
--      optional deduction / incentive, TDS (section 194J, from the doctor's payout profile; 20% without PAN, 206AA)
--      and net payable. Days not settled roll into the next settlement.
--   3. MAKER-CHECKER
--      PREPARED (accounts) -> APPROVED (a different user) -> PAID (mode, reference, date). A prepared settlement can be
--      cancelled, a prepared / approved one rejected; both put its lines back to be settled again. A Super Admin may also
--      approve a settlement they prepared ("Self-approved by Super Admin" is kept on it); the page names who can approve.
--   4. DOCTOR PAYOUT PROFILE: PAN, TDS, bank / IFSC / UPI, preferred mode (needed before a doctor can be settled).
--
--   Rules: the visit's consulting line(s) (active, after their share of the bill discount) for 'Consultation' rules,
--   the whole bill for 'All Services'; the rule must be in force on the bill date (EffectiveFrom / EffectiveTo); a doctor
--   rule beats a speciality rule beats the general rule, a branch rule beats an all-branch rule. A visit with no rule,
--   or no consulting line for a consultation rule, earns no share (listed on the board so the rule can be added).
--   Old line columns (ApprovalStatus / PaymentStatus / PaidDate ...) are kept in step, so RPT-01..08 keep working.
--   Read-only for bills, payments and consultations. No grant is seeded.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. tables ────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.DoctorPayoutProfile', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DoctorPayoutProfile (
        PayoutProfileId  INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DoctorPayoutProfile PRIMARY KEY,
        CompanyId        INT            NOT NULL,
        DoctorId         INT            NOT NULL,
        PayeeName        NVARCHAR(200)  NULL,            -- name on the bank account / cheque
        PAN              VARCHAR(10)    NULL,
        TdsApplicable    BIT            NOT NULL CONSTRAINT DF_DoctorPayoutProfile_TdsApplicable DEFAULT 1,
        TdsPercent       DECIMAL(5, 2)  NOT NULL CONSTRAINT DF_DoctorPayoutProfile_TdsPercent DEFAULT 10,
        PreferredMode    NVARCHAR(30)   NULL,            -- Cash / UPI / NEFT / RTGS / IMPS / Cheque
        BankName         NVARCHAR(150)  NULL,
        AccountNo        NVARCHAR(30)   NULL,
        IFSC             VARCHAR(11)    NULL,
        UpiId            NVARCHAR(100)  NULL,
        Remarks          NVARCHAR(300)  NULL,
        IsActive         BIT            NOT NULL CONSTRAINT DF_DoctorPayoutProfile_IsActive DEFAULT 1,
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_DoctorPayoutProfile_CreatedDate DEFAULT GETDATE(),
        ModifiedBy       INT            NULL,
        ModifiedDate     DATETIME       NULL,
        CONSTRAINT UQ_DoctorPayoutProfile_Doctor UNIQUE (CompanyId, DoctorId),
        CONSTRAINT CK_DoctorPayoutProfile_Tds CHECK (TdsPercent >= 0 AND TdsPercent <= 30)
    );
END
GO

IF OBJECT_ID('dbo.DoctorSettlement', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DoctorSettlement (
        SettlementId          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DoctorSettlement PRIMARY KEY,
        SettlementNo          NVARCHAR(30)   NOT NULL,
        CompanyId             INT            NOT NULL,
        BranchId              INT            NOT NULL,
        DoctorId              INT            NOT NULL,
        SettlementDate        DATE           NOT NULL,       -- the day being settled (shares up to this day)
        PeriodFrom            DATE           NOT NULL,       -- earliest share date on it
        PeriodTo              DATE           NOT NULL,       -- latest share date on it
        LineCount             INT            NOT NULL,
        Visits                INT            NOT NULL,
        GrossShare            DECIMAL(18, 2) NOT NULL,       -- share and top-up lines
        Recoveries            DECIMAL(18, 2) NOT NULL,       -- recovery lines (negative)
        OtherAdjustment       DECIMAL(18, 2) NOT NULL CONSTRAINT DF_DoctorSettlement_OtherAdjustment DEFAULT 0,  -- + incentive / - deduction
        OtherAdjustmentReason NVARCHAR(300)  NULL,
        TaxableAmount         DECIMAL(18, 2) NOT NULL,
        TdsPercent            DECIMAL(5, 2)  NOT NULL,
        TdsAmount             DECIMAL(18, 2) NOT NULL,
        NetPayable            DECIMAL(18, 2) NOT NULL,
        PAN                   VARCHAR(10)    NULL,           -- payee details as they were when prepared
        PayeeName             NVARCHAR(200)  NULL,
        BankName              NVARCHAR(150)  NULL,
        AccountNo             NVARCHAR(30)   NULL,
        IFSC                  VARCHAR(11)    NULL,
        UpiId                 NVARCHAR(100)  NULL,
        Status                VARCHAR(12)    NOT NULL,       -- PREPARED / APPROVED / PAID / REJECTED / CANCELLED
        PreparedBy            INT            NULL,
        PreparedOn            DATETIME       NOT NULL,
        PrepareRemarks        NVARCHAR(500)  NULL,
        ApprovedBy            INT            NULL,
        ApprovedOn            DATETIME       NULL,
        ApprovalRemarks       NVARCHAR(500)  NULL,
        PaymentDate           DATE           NULL,
        PaymentMode           NVARCHAR(30)   NULL,
        PaymentReference      NVARCHAR(100)  NULL,
        PaymentRemarks        NVARCHAR(500)  NULL,
        PaidBy                INT            NULL,
        PaidOn                DATETIME       NULL,
        ClosedBy              INT            NULL,           -- rejected / cancelled by
        ClosedOn              DATETIME       NULL,
        CloseReason           NVARCHAR(500)  NULL,
        CONSTRAINT UQ_DoctorSettlement_No UNIQUE (SettlementNo),
        CONSTRAINT CK_DoctorSettlement_Status CHECK (Status IN ('PREPARED', 'APPROVED', 'PAID', 'REJECTED', 'CANCELLED'))
    );
    CREATE INDEX IX_DoctorSettlement_Branch ON dbo.DoctorSettlement (BranchId, Status, SettlementDate) INCLUDE (DoctorId, NetPayable);
    CREATE INDEX IX_DoctorSettlement_Doctor ON dbo.DoctorSettlement (DoctorId, SettlementDate);
END
GO

IF COL_LENGTH('dbo.DoctorDisbursal', 'ShareDate') IS NULL
    ALTER TABLE dbo.DoctorDisbursal ADD ShareDate DATE NULL;               -- the day the share was earned (money collected)
IF COL_LENGTH('dbo.DoctorDisbursal', 'LineType') IS NULL
    ALTER TABLE dbo.DoctorDisbursal ADD LineType VARCHAR(10) NOT NULL CONSTRAINT DF_DoctorDisbursal_LineType DEFAULT 'SHARE';  -- SHARE / TOPUP / RECOVERY
IF COL_LENGTH('dbo.DoctorDisbursal', 'SettlementId') IS NULL
    ALTER TABLE dbo.DoctorDisbursal ADD SettlementId INT NULL;
GO

-- lines made by the old Calculate button: date them, and put the ones not paid back to "to be settled"
UPDATE dd SET ShareDate = CAST(ISNULL(s.CreatedDate, dd.CreatedDate) AS DATE)
FROM dbo.DoctorDisbursal dd LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
WHERE dd.ShareDate IS NULL;
UPDATE dbo.DoctorDisbursal
SET ApprovalStatus = CASE WHEN CalculatedAmount + AdjustmentAmount = 0 THEN 'NOT_ELIGIBLE' ELSE 'CALCULATED' END
WHERE SettlementId IS NULL AND PaymentStatus <> 'Paid' AND IsActive = 1 AND ApprovalStatus IN ('APPROVED', 'SUBMITTED', 'ELIGIBLE', 'ON_HOLD');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DoctorDisbursal_Settle' AND object_id = OBJECT_ID('dbo.DoctorDisbursal'))
    CREATE INDEX IX_DoctorDisbursal_Settle ON dbo.DoctorDisbursal (BranchId, DoctorId, SettlementId, ShareDate) INCLUDE (NetPayable, CalculatedAmount, PaymentStatus, IsActive, VisitId);
GO

-- ── 2. the share of each visit, as of now ──────────────────────────────────
-- Visits of the branch billed, paid, refunded or cancelled in the range. EarnedShare = the share earned so far
-- (in proportion to what is collected); FullShare = the share once the bill is fully paid.
CREATE OR ALTER FUNCTION dbo.ufn_DoctorPayout_VisitShare (@BranchId INT, @FromDate DATE, @ToDate DATE, @DoctorId INT)
RETURNS TABLE
AS RETURN
WITH v AS (
    SELECT s.OPDServiceId AS VisitId, s.BranchId, s.CompanyId, s.ConsultingDoctorId AS DoctorId, d.PrimarySpecialityId AS SpecialityId,
           s.PatientId, s.CreatedDate AS BillDate, CAST(s.IsActive AS BIT) AS VisitActive, ph.PaymentHeaderId AS BillId,
           CAST(ISNULL(ph.SubTotal, s.TotalAmount) AS DECIMAL(18, 2)) AS BillGross,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS BillNet,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS BillPaid,
           CAST(ISNULL(ph.HeaderDiscountAmount, 0) AS DECIMAL(18, 2)) AS HeaderDisc,
           CAST(COALESCE(NULLIF(pl.g, 0), ps.g, 0) AS DECIMAL(18, 2)) AS ConsultGross,
           CAST(CASE WHEN ISNULL(pl.g, 0) > 0 THEN ISNULL(pl.ld, 0) ELSE 0 END AS DECIMAL(18, 2)) AS ConsultLineDisc,
           act.ActivityOn
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    -- consulting lines of the bill whose service is still active (a cancelled line keeps its bill line)
    OUTER APPLY (SELECT SUM(pli.OriginalAmount) AS g, SUM(ISNULL(pli.LineDiscountAmount, 0)) AS ld
                   FROM dbo.PaymentLineItem pli
                   LEFT JOIN dbo.PatientOPDServiceItem si ON si.ItemId = pli.ModuleLineRefId AND si.OPDServiceId = s.OPDServiceId
                  WHERE pli.PaymentHeaderId = ph.PaymentHeaderId AND pli.IsActive = 1 AND pli.ServiceType = 'Consulting'
                    AND ISNULL(si.IsActive, 1) = 1) pl
    OUTER APPLY (SELECT SUM(si.ServiceCharges) AS g FROM dbo.PatientOPDServiceItem si
                  WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1 AND si.ServiceType = 'Consulting') ps
    OUTER APPLY (SELECT MAX(x.d) AS ActivityOn
                   FROM (VALUES (CAST(s.CreatedDate AS DATETIME)),
                                ((SELECT MAX(COALESCE(pd.PaymentDate, pd.CreatedDate)) FROM dbo.PaymentDetail pd WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1)),
                                ((SELECT MAX(r.RefundDate) FROM dbo.BillRefund r WHERE r.ModuleCode = 'OPD' AND r.ModuleRefId = s.OPDServiceId AND r.IsActive = 1)),
                                ((SELECT MAX(bc.CancellationDate) FROM dbo.BillCancellation bc WHERE bc.ModuleCode = 'OPD' AND bc.ModuleRefId = s.OPDServiceId AND bc.IsActive = 1))) x(d)) act
    WHERE s.BranchId = @BranchId AND s.ConsultingDoctorId IS NOT NULL
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND ((s.CreatedDate >= @FromDate AND s.CreatedDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
           OR (act.ActivityOn >= @FromDate AND act.ActivityOn < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))))
)
SELECT v.VisitId, v.BranchId, v.CompanyId, v.DoctorId, v.SpecialityId, v.PatientId, v.BillDate, v.VisitActive, v.BillId,
       v.BillGross, v.BillNet, v.BillPaid, v.ConsultGross, a.ConsultDisc, v.ActivityOn,
       r.CommissionConfigId, r.RevenueType, r.CalculationType, r.CommissionBasis, r.DoctorShare,
       b.BaseGross, b.BaseNet, k.Ratio,
       CAST(ROUND(b.BaseNet * k.Ratio, 2) AS DECIMAL(18, 2)) AS CollectedBase,
       f.FullShare,
       CAST(ROUND(f.FullShare * k.Ratio, 2) AS DECIMAL(18, 2)) AS EarnedShare,
       CAST(CASE WHEN r.CommissionConfigId IS NULL THEN 'No commission rule'
                 WHEN r.CalculationType = 'Fixed Amount' THEN N'Flat ₹' + FORMAT(r.DoctorShare, '0.##') + ' per visit (' + r.RevenueType + ')'
                 ELSE FORMAT(r.DoctorShare, '0.##') + '% of ' + r.CommissionBasis + ' (' + r.RevenueType + ')' END AS NVARCHAR(200)) AS RuleText
FROM v
-- the consulting lines' share of the bill (header) discount
CROSS APPLY (SELECT CAST(CASE WHEN v.ConsultGross <= 0 THEN 0
                              WHEN v.ConsultLineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(v.HeaderDisc * v.ConsultGross / v.BillGross, 2) ELSE 0 END > v.ConsultGross THEN v.ConsultGross
                              ELSE v.ConsultLineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(v.HeaderDisc * v.ConsultGross / v.BillGross, 2) ELSE 0 END END AS DECIMAL(18, 2)) AS ConsultDisc) a
-- the rule in force on the bill date: doctor > speciality > general, branch > all branches, latest first
OUTER APPLY (SELECT TOP 1 c.CommissionConfigId, ISNULL(c.RevenueType, 'Consultation') AS RevenueType, c.CalculationType, c.CommissionBasis, c.DoctorShare
               FROM dbo.DoctorCommissionConfig c
              WHERE c.IsActive = 1 AND (v.CompanyId IS NULL OR c.CompanyId = v.CompanyId)
                AND (ISNULL(c.BranchId, 0) = 0 OR c.BranchId = v.BranchId)
                AND (c.DoctorId = v.DoctorId
                     OR (ISNULL(c.DoctorId, 0) = 0 AND c.SpecialityId = v.SpecialityId)
                     OR (ISNULL(c.DoctorId, 0) = 0 AND ISNULL(c.SpecialityId, 0) = 0))
                AND (c.RevenueType IS NULL OR c.RevenueType IN ('Consultation', 'Consultant', 'All Services'))
                AND c.EffectiveFrom <= CAST(v.BillDate AS DATE) AND (c.EffectiveTo IS NULL OR c.EffectiveTo >= CAST(v.BillDate AS DATE))
              ORDER BY CASE WHEN c.DoctorId = v.DoctorId THEN 1 WHEN ISNULL(c.SpecialityId, 0) <> 0 THEN 2 ELSE 3 END,
                       CASE WHEN ISNULL(c.BranchId, 0) = 0 THEN 1 ELSE 0 END, c.EffectiveFrom DESC, c.CommissionConfigId DESC) r
CROSS APPLY (SELECT CAST(CASE WHEN r.RevenueType = 'All Services' THEN v.BillGross ELSE v.ConsultGross END AS DECIMAL(18, 2)) AS BaseGross,
                    CAST(CASE WHEN r.RevenueType = 'All Services' THEN v.BillNet ELSE v.ConsultGross - a.ConsultDisc END AS DECIMAL(18, 2)) AS BaseNet) b
-- how much of the bill is collected (refunds already reduce TotalPaid); a cancelled visit earns nothing
CROSS APPLY (SELECT CAST(CASE WHEN v.VisitActive = 0 THEN 0 WHEN v.BillNet <= 0 THEN 1
                              WHEN v.BillPaid >= v.BillNet THEN 1 WHEN v.BillPaid <= 0 THEN 0
                              ELSE v.BillPaid / v.BillNet END AS DECIMAL(9, 6)) AS Ratio) k
CROSS APPLY (SELECT CAST(CASE WHEN r.CommissionConfigId IS NULL OR b.BaseGross <= 0 THEN 0
                              WHEN r.CalculationType = 'Fixed Amount' THEN r.DoctorShare
                              ELSE ROUND(CASE WHEN r.CommissionBasis = 'Gross Bill' THEN b.BaseGross ELSE b.BaseNet END * r.DoctorShare / 100.0, 2) END
                         AS DECIMAL(18, 2)) AS FullShare) f;
GO

-- ── 3. accrual: bring the share lines of visits in a range up to date ──────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Accrue
    @BranchId  INT,
    @FromDate  DATE,
    @ToDate    DATE,
    @DoctorId  INT = NULL,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @ToDate > CAST(GETDATE() AS DATE) SET @ToDate = CAST(GETDATE() AS DATE);
    IF @FromDate > @ToDate SET @FromDate = @ToDate;

    SELECT * INTO #S FROM dbo.ufn_DoctorPayout_VisitShare(@BranchId, @FromDate, @ToDate, @DoctorId);

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lock NVARCHAR(100) = N'DoctorPayout_' + CAST(@BranchId AS NVARCHAR(10));
        EXEC sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;

        -- what is already on the lines of each visit: all lines, settled / paid lines, and the one open (unsettled) line
        SELECT x.VisitId, x.EarnedShare, x.DoctorId, x.BillId, x.CompanyId, x.RuleText, x.CommissionConfigId, x.RevenueType, x.CommissionBasis,
               x.CalculationType, x.DoctorShare, x.BaseGross, x.BaseNet, x.CollectedBase, x.ConsultDisc, x.ActivityOn,
               ISNULL(bk.Booked, 0) AS Booked, ISNULL(bk.Settled, 0) AS Settled, ISNULL(bk.SettledLines, 0) AS SettledLines, op.DisbursalId AS OpenLineId,
               CAST(CASE WHEN x.ActivityOn > GETDATE() THEN GETDATE() ELSE x.ActivityOn END AS DATE) AS ShareDate
        INTO #W
        FROM #S x
        OUTER APPLY (SELECT SUM(dd.CalculatedAmount) AS Booked,
                            SUM(CASE WHEN dd.SettlementId IS NOT NULL OR dd.PaymentStatus = 'Paid' THEN dd.CalculatedAmount ELSE 0 END) AS Settled,
                            SUM(CASE WHEN dd.SettlementId IS NOT NULL OR dd.PaymentStatus = 'Paid' THEN 1 ELSE 0 END) AS SettledLines
                       FROM dbo.DoctorDisbursal dd WHERE dd.VisitId = x.VisitId AND dd.IsActive = 1) bk
        OUTER APPLY (SELECT TOP 1 dd.DisbursalId FROM dbo.DoctorDisbursal dd
                      WHERE dd.VisitId = x.VisitId AND dd.IsActive = 1 AND dd.SettlementId IS NULL AND dd.PaymentStatus <> 'Paid'
                      ORDER BY dd.DisbursalId DESC) op;

        -- open line: it carries whatever is not settled yet (earned - settled)
        UPDATE dd SET
            CalculatedAmount = w.EarnedShare - w.Settled,
            NetPayable = w.EarnedShare - w.Settled + dd.AdjustmentAmount,
            LineType = CASE WHEN w.SettledLines = 0 THEN 'SHARE' WHEN w.EarnedShare - w.Settled >= 0 THEN 'TOPUP' ELSE 'RECOVERY' END,
            ShareDate = w.ShareDate, SettlementPeriod = CONVERT(VARCHAR(7), w.ShareDate, 23),
            DoctorId = w.DoctorId, BillId = w.BillId, RevenueType = ISNULL(w.RevenueType, dd.RevenueType),
            GrossBillAmount = w.BaseGross, DiscountAmount = w.ConsultDisc, NetBillAmount = w.BaseNet, CollectedAmount = w.CollectedBase,
            CommissionBasis = ISNULL(w.CommissionBasis, dd.CommissionBasis), EligibleAmount = w.CollectedBase,
            CommissionConfigId = w.CommissionConfigId, CommissionRule = w.RuleText,
            CommissionPercentage = CASE WHEN w.CalculationType = 'Fixed Amount' THEN NULL ELSE w.DoctorShare END,
            ApprovalStatus = CASE WHEN w.EarnedShare - w.Settled + dd.AdjustmentAmount = 0 THEN 'NOT_ELIGIBLE' ELSE 'CALCULATED' END,
            IsActive = CASE WHEN w.SettledLines > 0 AND w.EarnedShare - w.Settled = 0 AND dd.AdjustmentAmount = 0 THEN 0 ELSE 1 END,
            ModifiedDate = GETDATE(), ModifiedBy = @UserId
        FROM dbo.DoctorDisbursal dd
        INNER JOIN #W w ON w.OpenLineId = dd.DisbursalId
        WHERE dd.CalculatedAmount <> w.EarnedShare - w.Settled
           OR ISNULL(dd.ShareDate, '19000101') <> w.ShareDate
           OR ISNULL(dd.CommissionConfigId, -1) <> ISNULL(w.CommissionConfigId, -1)
           OR dd.CollectedAmount <> w.CollectedBase;

        -- no open line and the share moved: a new line (first share, top-up or recovery)
        INSERT INTO dbo.DoctorDisbursal (
            CompanyId, BranchId, DoctorId, VisitId, BillId, ConsultationId, RevenueType, GrossBillAmount, DiscountAmount, ApprovedAdjustment,
            NetBillAmount, CollectedAmount, CommissionBasis, EligibleAmount, CommissionConfigId, CommissionRule, CommissionPercentage,
            CalculatedAmount, AdjustmentAmount, NetPayable, SettlementPeriod, ApprovalStatus, PaymentStatus, IsActive, CreatedDate, CreatedBy,
            ShareDate, LineType)
        SELECT w.CompanyId, @BranchId, w.DoctorId, w.VisitId, w.BillId,
               (SELECT TOP 1 ec.ConsultationId FROM dbo.EmrPatientConsultation ec WHERE ec.OPDServiceId = w.VisitId ORDER BY ec.ConsultationId DESC),
               ISNULL(w.RevenueType, 'Consultation'), w.BaseGross, w.ConsultDisc, 0, w.BaseNet, w.CollectedBase, ISNULL(w.CommissionBasis, 'Net Collected'),
               w.CollectedBase, w.CommissionConfigId, w.RuleText, CASE WHEN w.CalculationType = 'Fixed Amount' THEN NULL ELSE w.DoctorShare END,
               w.EarnedShare - w.Booked, 0, w.EarnedShare - w.Booked, CONVERT(VARCHAR(7), w.ShareDate, 23), 'CALCULATED', 'Pending', 1, GETDATE(), @UserId,
               w.ShareDate, CASE WHEN w.Booked = 0 AND w.SettledLines = 0 THEN 'SHARE' WHEN w.EarnedShare - w.Booked > 0 THEN 'TOPUP' ELSE 'RECOVERY' END
        FROM #W w
        WHERE w.OpenLineId IS NULL AND w.EarnedShare - w.Booked <> 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    DROP TABLE #W; DROP TABLE #S;
END;
GO

-- ── 4. doctor payout profile ────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Profiles
    @CompanyId INT,
    @BranchId  INT,
    @UserId    INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SELECT d.DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor ' + CAST(d.DoctorId AS VARCHAR(10))) AS DoctorName,
           sp.SpecialityName AS Speciality, d.PhoneNumber, d.MedicalLicenseNo,
           p.PayoutProfileId, p.PayeeName, p.PAN, ISNULL(p.TdsApplicable, 1) AS TdsApplicable, ISNULL(p.TdsPercent, 10) AS TdsPercent,
           p.PreferredMode, p.BankName, p.AccountNo, p.IFSC, p.UpiId, p.Remarks,
           CAST(CASE WHEN p.PayoutProfileId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfile,
           CAST(CASE WHEN p.PayoutProfileId IS NULL THEN NULL WHEN ISNULL(p.TdsApplicable, 1) = 0 THEN 0
                     WHEN NULLIF(p.PAN, '') IS NULL THEN 20 ELSE p.TdsPercent END AS DECIMAL(5, 2)) AS EffectiveTdsPercent,
           (SELECT COUNT(1) FROM dbo.DoctorCommissionConfig c WHERE c.IsActive = 1 AND c.CompanyId = @CompanyId
                AND (c.DoctorId = d.DoctorId OR (ISNULL(c.DoctorId, 0) = 0 AND (ISNULL(c.SpecialityId, 0) = 0 OR c.SpecialityId = d.PrimarySpecialityId)))
                AND (ISNULL(c.BranchId, 0) = 0 OR c.BranchId = @BranchId)) AS RulesInForce
    FROM dbo.DoctorMaster d
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN dbo.DoctorPayoutProfile p ON p.DoctorId = d.DoctorId AND p.CompanyId = @CompanyId
    WHERE d.CompanyId = @CompanyId AND d.IsActive = 1 AND ISNULL(d.IsReferralDoctor, 0) = 0
      AND (EXISTS (SELECT 1 FROM dbo.DoctorBranchMap m WHERE m.DoctorId = d.DoctorId AND m.BranchId = @BranchId AND ISNULL(m.IsActive, 1) = 1)
           OR EXISTS (SELECT 1 FROM dbo.PatientOPDService s WHERE s.ConsultingDoctorId = d.DoctorId AND s.BranchId = @BranchId))
    ORDER BY DoctorName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_ProfileSave
    @CompanyId     INT,
    @DoctorId      INT,
    @PayeeName     NVARCHAR(200) = NULL,
    @PAN           VARCHAR(10)   = NULL,
    @TdsApplicable BIT           = 1,
    @TdsPercent    DECIMAL(5, 2) = 10,
    @PreferredMode NVARCHAR(30)  = NULL,
    @BankName      NVARCHAR(150) = NULL,
    @AccountNo     NVARCHAR(30)  = NULL,
    @IFSC          VARCHAR(11)   = NULL,
    @UpiId         NVARCHAR(100) = NULL,
    @Remarks       NVARCHAR(300) = NULL,
    @UserId        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @PAN = NULLIF(UPPER(LTRIM(RTRIM(@PAN))), '');
    SET @IFSC = NULLIF(UPPER(LTRIM(RTRIM(@IFSC))), '');
    SET @AccountNo = NULLIF(REPLACE(LTRIM(RTRIM(@AccountNo)), ' ', ''), '');
    SET @UpiId = NULLIF(LTRIM(RTRIM(@UpiId)), '');
    SET @PreferredMode = NULLIF(LTRIM(RTRIM(@PreferredMode)), '');
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId)
        THROW 50020, 'Doctor not found.', 1;
    IF @PAN IS NOT NULL AND @PAN NOT LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]'
        THROW 50020, 'PAN must be 10 characters: 5 letters, 4 digits, 1 letter (e.g. ABCDE1234F).', 1;
    IF @IFSC IS NOT NULL AND @IFSC NOT LIKE '[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]'
        THROW 50020, 'IFSC must be 11 characters: 4 letters, 0, then 6 letters or digits (e.g. SBIN0001234).', 1;
    IF @AccountNo IS NOT NULL AND (@AccountNo LIKE '%[^0-9]%' OR LEN(@AccountNo) NOT BETWEEN 6 AND 20)
        THROW 50020, 'Bank account number must be 6 to 20 digits.', 1;
    IF (@AccountNo IS NULL AND @IFSC IS NOT NULL) OR (@AccountNo IS NOT NULL AND @IFSC IS NULL)
        THROW 50020, 'Enter both the bank account number and its IFSC, or neither.', 1;
    IF ISNULL(@TdsPercent, 0) < 0 OR ISNULL(@TdsPercent, 0) > 30
        THROW 50020, 'TDS % must be between 0 and 30.', 1;
    IF @PreferredMode IS NOT NULL AND @PreferredMode NOT IN ('Cash', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'Cheque')
        THROW 50020, 'Preferred mode must be Cash, UPI, NEFT, RTGS, IMPS or Cheque.', 1;
    IF @PreferredMode IN ('NEFT', 'RTGS', 'IMPS') AND @AccountNo IS NULL
        THROW 50020, 'A bank transfer needs the bank account number and IFSC.', 1;
    IF @PreferredMode = 'UPI' AND @UpiId IS NULL
        THROW 50020, 'UPI needs the doctor''s UPI ID.', 1;

    IF EXISTS (SELECT 1 FROM dbo.DoctorPayoutProfile WHERE CompanyId = @CompanyId AND DoctorId = @DoctorId)
        UPDATE dbo.DoctorPayoutProfile
        SET PayeeName = NULLIF(LTRIM(RTRIM(@PayeeName)), ''), PAN = @PAN, TdsApplicable = ISNULL(@TdsApplicable, 1), TdsPercent = ISNULL(@TdsPercent, 10),
            PreferredMode = @PreferredMode, BankName = NULLIF(LTRIM(RTRIM(@BankName)), ''), AccountNo = @AccountNo, IFSC = @IFSC, UpiId = @UpiId,
            Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), IsActive = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE CompanyId = @CompanyId AND DoctorId = @DoctorId;
    ELSE
        INSERT INTO dbo.DoctorPayoutProfile (CompanyId, DoctorId, PayeeName, PAN, TdsApplicable, TdsPercent, PreferredMode, BankName, AccountNo, IFSC, UpiId, Remarks, CreatedBy)
        VALUES (@CompanyId, @DoctorId, NULLIF(LTRIM(RTRIM(@PayeeName)), ''), @PAN, ISNULL(@TdsApplicable, 1), ISNULL(@TdsPercent, 10), @PreferredMode,
                NULLIF(LTRIM(RTRIM(@BankName)), ''), @AccountNo, @IFSC, @UpiId, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
    SELECT 1;
END;
GO

-- ── 5. day-end board ────────────────────────────────────────────────────────
-- Brings the shares up to date (90 days back to the day), then per doctor: what was earned that day, what is still
-- unsettled from earlier days, recoveries, what is on settlements awaiting approval / payment, and what was paid.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Board
    @CompanyId    INT,
    @BranchId     INT,
    @Date         DATE,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @Date IS NULL OR @Date > CAST(GETDATE() AS DATE) SET @Date = CAST(GETDATE() AS DATE);
    DECLARE @From DATE = DATEADD(DAY, -90, @Date);
    -- older unsettled lines are refreshed too
    SELECT @From = CASE WHEN MIN(ShareDate) < @From THEN MIN(ShareDate) ELSE @From END
    FROM dbo.DoctorDisbursal WHERE BranchId = @BranchId AND IsActive = 1 AND SettlementId IS NULL AND PaymentStatus <> 'Paid';
    EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @BranchId, @FromDate = @From, @ToDate = @Date, @UserId = @UserId;

    -- visits of the day (bill date) and how their share stands
    SELECT * INTO #Day FROM dbo.ufn_DoctorPayout_VisitShare(@BranchId, @Date, @Date, NULL) WHERE CAST(BillDate AS DATE) = @Date AND VisitActive = 1;

    SELECT dd.DisbursalId, dd.DoctorId, dd.VisitId, dd.ShareDate, dd.LineType, dd.NetPayable, dd.CalculatedAmount, dd.SettlementId
    INTO #L
    FROM dbo.DoctorDisbursal dd
    WHERE dd.BranchId = @BranchId AND dd.IsActive = 1 AND dd.ShareDate <= @Date
      AND ((dd.SettlementId IS NULL AND dd.PaymentStatus <> 'Paid' AND dd.NetPayable <> 0) OR dd.ShareDate = @Date);

    SELECT ds.* INTO #St FROM dbo.DoctorSettlement ds
    WHERE ds.BranchId = @BranchId AND (ds.Status IN ('PREPARED', 'APPROVED') OR ds.SettlementDate = @Date OR ds.PaymentDate = @Date);

    -- RS1 summary
    SELECT @Date AS BoardDate,
           (SELECT COUNT(1) FROM #Day) AS VisitsToday,
           (SELECT COUNT(1) FROM #Day WHERE CommissionConfigId IS NULL) AS VisitsWithoutRule,
           (SELECT COUNT(1) FROM #Day WHERE CommissionConfigId IS NOT NULL AND EarnedShare = 0 AND FullShare > 0) AS VisitsAwaitingCollection,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #L WHERE ShareDate = @Date) AS EarnedToday,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #L WHERE SettlementId IS NULL AND ShareDate < @Date) AS CarriedForward,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #L WHERE SettlementId IS NULL AND NetPayable < 0) AS Recoveries,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #L WHERE SettlementId IS NULL) AS ToSettle,
           (SELECT COUNT(DISTINCT DoctorId) FROM #L WHERE SettlementId IS NULL) AS DoctorsToSettle,
           (SELECT COUNT(1) FROM #St WHERE Status = 'PREPARED') AS AwaitingApproval,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #St WHERE Status = 'PREPARED') AS AwaitingApprovalAmount,
           (SELECT COUNT(1) FROM #St WHERE Status = 'APPROVED') AS AwaitingPayment,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #St WHERE Status = 'APPROVED') AS AwaitingPaymentAmount,
           (SELECT ISNULL(SUM(NetPayable), 0) FROM #St WHERE Status = 'PAID' AND PaymentDate = @Date) AS PaidToday,
           (SELECT ISNULL(SUM(TdsAmount), 0) FROM #St WHERE Status = 'PAID' AND PaymentDate = @Date) AS TdsToday;

    -- RS2 doctors with anything for the day
    ;WITH docs AS (
        SELECT DoctorId FROM #Day UNION SELECT DoctorId FROM #L UNION SELECT DoctorId FROM #St WHERE Status IN ('PREPARED', 'APPROVED') OR SettlementDate = @Date)
    SELECT d.DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(dm.NamePrefix + ' ', '') + ISNULL(dm.FullName, ''))), ''), 'Doctor ' + CAST(d.DoctorId AS VARCHAR(10))) AS DoctorName,
           sp.SpecialityName AS Speciality,
           CAST(CASE WHEN p.PayoutProfileId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfile, p.PAN, p.PreferredMode,
           CAST(CASE WHEN p.PayoutProfileId IS NULL THEN NULL WHEN p.TdsApplicable = 0 THEN 0 WHEN NULLIF(p.PAN, '') IS NULL THEN 20 ELSE p.TdsPercent END AS DECIMAL(5, 2)) AS TdsPercent,
           (SELECT COUNT(1) FROM #Day x WHERE x.DoctorId = d.DoctorId) AS VisitsToday,
           (SELECT COUNT(1) FROM #Day x WHERE x.DoctorId = d.DoctorId AND x.CommissionConfigId IS NULL) AS VisitsWithoutRule,
           (SELECT ISNULL(SUM(x.CollectedBase), 0) FROM #Day x WHERE x.DoctorId = d.DoctorId) AS CollectedToday,
           (SELECT ISNULL(SUM(l.NetPayable), 0) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.ShareDate = @Date) AS EarnedToday,
           (SELECT ISNULL(SUM(l.NetPayable), 0) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.SettlementId IS NULL AND l.ShareDate < @Date) AS CarriedForward,
           (SELECT ISNULL(SUM(l.NetPayable), 0) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.SettlementId IS NULL AND l.NetPayable < 0) AS Recoveries,
           (SELECT ISNULL(SUM(l.NetPayable), 0) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.SettlementId IS NULL) AS ToSettle,
           (SELECT COUNT(1) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.SettlementId IS NULL) AS LinesToSettle,
           (SELECT MIN(l.ShareDate) FROM #L l WHERE l.DoctorId = d.DoctorId AND l.SettlementId IS NULL) AS OldestUnsettled,
           (SELECT COUNT(1) FROM #St s WHERE s.DoctorId = d.DoctorId AND s.Status = 'PREPARED') AS AwaitingApproval,
           (SELECT COUNT(1) FROM #St s WHERE s.DoctorId = d.DoctorId AND s.Status = 'APPROVED') AS AwaitingPayment,
           (SELECT ISNULL(SUM(s.NetPayable), 0) FROM #St s WHERE s.DoctorId = d.DoctorId AND s.Status IN ('PREPARED', 'APPROVED')) AS PendingAmount,
           (SELECT ISNULL(SUM(s.NetPayable), 0) FROM #St s WHERE s.DoctorId = d.DoctorId AND s.Status = 'PAID' AND s.PaymentDate = @Date) AS PaidToday
    FROM docs d
    INNER JOIN dbo.DoctorMaster dm ON dm.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = dm.PrimarySpecialityId
    LEFT JOIN dbo.DoctorPayoutProfile p ON p.DoctorId = d.DoctorId AND p.CompanyId = @CompanyId
    ORDER BY ToSettle DESC, DoctorName;

    -- RS3 lines: unsettled up to the day, and everything earned on the day
    SELECT dd.DisbursalId, dd.DoctorId, dd.VisitId, dd.ShareDate, dd.LineType, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName, pm.PatientCode,
           dd.NetBillAmount, dd.CollectedAmount, dd.CommissionRule, dd.NetPayable, dd.ApprovalStatus, dd.PaymentStatus, ds.SettlementNo, ds.Status AS SettlementStatus,
           CAST(CASE WHEN dd.SettlementId IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen
    FROM #L l
    INNER JOIN dbo.DoctorDisbursal dd ON dd.DisbursalId = l.DisbursalId
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
    LEFT JOIN dbo.DoctorSettlement ds ON ds.SettlementId = dd.SettlementId
    ORDER BY dd.DoctorId, dd.ShareDate DESC, dd.DisbursalId DESC;

    -- RS4 visits of the day with no share (no rule, or nothing collected yet)
    SELECT x.VisitId, x.DoctorId, s.OPDBillNo AS BillNo, s.TokenNo, x.BillDate, x.BillNet, x.BillPaid, x.RuleText,
           CASE WHEN x.CommissionConfigId IS NULL THEN 'NO_RULE' WHEN x.BaseGross <= 0 THEN 'NO_CONSULTING_LINE' ELSE 'NOT_COLLECTED' END AS Reason,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName
    FROM #Day x
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = x.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = x.PatientId
    WHERE x.EarnedShare = 0;

    DROP TABLE #Day; DROP TABLE #L; DROP TABLE #St;
END;
GO

-- ── 6. prepare a settlement (one doctor, shares up to a day) ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Prepare
    @CompanyId             INT,
    @BranchId              INT,
    @DoctorId              INT,
    @UpTo                  DATE,
    @OtherAdjustment       DECIMAL(18, 2) = 0,
    @OtherAdjustmentReason NVARCHAR(300)  = NULL,
    @Remarks               NVARCHAR(500)  = NULL,
    @UserId                INT            = NULL,
    @IsSuperAdmin          BIT            = 0,
    @Quiet                 BIT            = 0,      -- 1 = no result set (called from usp_DoctorPayout_PrepareDay)
    @NewId                 INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @UpTo IS NULL OR @UpTo > CAST(GETDATE() AS DATE) SET @UpTo = CAST(GETDATE() AS DATE);
    SET @OtherAdjustment = ISNULL(@OtherAdjustment, 0);
    SET @OtherAdjustmentReason = NULLIF(LTRIM(RTRIM(@OtherAdjustmentReason)), '');
    IF @OtherAdjustment <> 0 AND @OtherAdjustmentReason IS NULL
        THROW 50020, 'Give the reason for the deduction / incentive.', 1;

    DECLARE @p TABLE (PAN VARCHAR(10), PayeeName NVARCHAR(200), BankName NVARCHAR(150), AccountNo NVARCHAR(30), IFSC VARCHAR(11), UpiId NVARCHAR(100), TdsPct DECIMAL(5, 2));
    INSERT INTO @p
    SELECT p.PAN, p.PayeeName, p.BankName, p.AccountNo, p.IFSC, p.UpiId,
           CASE WHEN p.TdsApplicable = 0 THEN 0 WHEN NULLIF(p.PAN, '') IS NULL THEN 20 ELSE p.TdsPercent END
    FROM dbo.DoctorPayoutProfile p WHERE p.CompanyId = @CompanyId AND p.DoctorId = @DoctorId AND p.IsActive = 1;
    IF NOT EXISTS (SELECT 1 FROM @p)
        THROW 50020, 'Set up this doctor''s payout profile (PAN, TDS, bank / UPI) first: Payout profiles tab.', 1;

    -- shares up to date first (from the doctor's oldest open line)
    DECLARE @From DATE = DATEADD(DAY, -90, @UpTo);
    SELECT @From = CASE WHEN MIN(ShareDate) < @From THEN MIN(ShareDate) ELSE @From END
    FROM dbo.DoctorDisbursal WHERE BranchId = @BranchId AND DoctorId = @DoctorId AND IsActive = 1 AND SettlementId IS NULL AND PaymentStatus <> 'Paid';
    EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @BranchId, @FromDate = @From, @ToDate = @UpTo, @DoctorId = @DoctorId, @UserId = @UserId;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lock NVARCHAR(100) = N'DoctorPayout_' + CAST(@BranchId AS NVARCHAR(10));
        EXEC sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;

        SELECT DisbursalId, VisitId, ShareDate, NetPayable INTO #T
        FROM dbo.DoctorDisbursal
        WHERE BranchId = @BranchId AND DoctorId = @DoctorId AND IsActive = 1 AND SettlementId IS NULL AND PaymentStatus <> 'Paid'
          AND NetPayable <> 0 AND ShareDate <= @UpTo;

        IF NOT EXISTS (SELECT 1 FROM #T)
            THROW 50020, 'Nothing to settle for this doctor up to that day.', 1;

        DECLARE @Gross DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetPayable), 0) FROM #T WHERE NetPayable > 0);
        DECLARE @Rec DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetPayable), 0) FROM #T WHERE NetPayable < 0);
        DECLARE @Taxable DECIMAL(18, 2) = @Gross + @Rec + @OtherAdjustment;
        IF @Taxable <= 0
            THROW 50020, 'Recoveries and deductions are more than the share: nothing to pay. Leave it to be carried into the next settlement.', 1;
        DECLARE @TdsPct DECIMAL(5, 2) = (SELECT TdsPct FROM @p);
        DECLARE @Tds DECIMAL(18, 2) = ROUND(@Taxable * @TdsPct / 100.0, 0);

        -- DPV/<branch code><financial year><6 digits>, e.g. DPV/HO2627000001
        DECLARE @fy INT = YEAR(@UpTo) - CASE WHEN MONTH(@UpTo) < 4 THEN 1 ELSE 0 END;
        DECLARE @prefix NVARCHAR(20) = N'DPV/' + ISNULL((SELECT NULLIF(LTRIM(RTRIM(BranchCode)), '') FROM dbo.BranchMaster WHERE BranchID = @BranchId), N'BR' + CAST(@BranchId AS NVARCHAR(5)))
                                     + RIGHT(CAST(@fy AS VARCHAR(4)), 2) + RIGHT(CAST(@fy + 1 AS VARCHAR(4)), 2);
        DECLARE @seq INT = ISNULL((SELECT MAX(TRY_CAST(RIGHT(SettlementNo, 6) AS INT)) FROM dbo.DoctorSettlement WITH (UPDLOCK, HOLDLOCK)
                                   WHERE SettlementNo LIKE @prefix + '[0-9][0-9][0-9][0-9][0-9][0-9]'), 0) + 1;

        INSERT INTO dbo.DoctorSettlement (SettlementNo, CompanyId, BranchId, DoctorId, SettlementDate, PeriodFrom, PeriodTo, LineCount, Visits,
            GrossShare, Recoveries, OtherAdjustment, OtherAdjustmentReason, TaxableAmount, TdsPercent, TdsAmount, NetPayable,
            PAN, PayeeName, BankName, AccountNo, IFSC, UpiId, Status, PreparedBy, PreparedOn, PrepareRemarks)
        SELECT @prefix + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6), @CompanyId, @BranchId, @DoctorId, @UpTo,
               (SELECT MIN(ShareDate) FROM #T), (SELECT MAX(ShareDate) FROM #T), (SELECT COUNT(1) FROM #T), (SELECT COUNT(DISTINCT VisitId) FROM #T),
               @Gross, @Rec, @OtherAdjustment, @OtherAdjustmentReason, @Taxable, @TdsPct, @Tds, @Taxable - @Tds,
               p.PAN, p.PayeeName, p.BankName, p.AccountNo, p.IFSC, p.UpiId, 'PREPARED', @UserId, GETDATE(), NULLIF(LTRIM(RTRIM(@Remarks)), '')
        FROM @p p;
        DECLARE @Id INT = SCOPE_IDENTITY();

        UPDATE dd SET SettlementId = @Id, ApprovalStatus = 'SUBMITTED', ModifiedDate = GETDATE(), ModifiedBy = @UserId
        FROM dbo.DoctorDisbursal dd INNER JOIN #T t ON t.DisbursalId = dd.DisbursalId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SET @NewId = @Id;
    IF @Quiet = 0 SELECT @Id AS SettlementId, SettlementNo, NetPayable FROM dbo.DoctorSettlement WHERE SettlementId = @Id;
END;
GO

-- every doctor of the day with something to settle and a payout profile (no deduction / incentive)
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_PrepareDay
    @CompanyId    INT,
    @BranchId     INT,
    @UpTo         DATE,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @UpTo IS NULL OR @UpTo > CAST(GETDATE() AS DATE) SET @UpTo = CAST(GETDATE() AS DATE);
    DECLARE @Out TABLE (DoctorId INT, Outcome VARCHAR(10), SettlementNo NVARCHAR(30), NetPayable DECIMAL(18, 2), Message NVARCHAR(400));
    DECLARE @doc INT, @sid INT;

    DECLARE dc CURSOR LOCAL FAST_FORWARD FOR
        SELECT DoctorId FROM dbo.DoctorDisbursal
        WHERE BranchId = @BranchId AND IsActive = 1 AND SettlementId IS NULL AND PaymentStatus <> 'Paid' AND NetPayable <> 0 AND ShareDate <= @UpTo
        GROUP BY DoctorId;
    OPEN dc; FETCH NEXT FROM dc INTO @doc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sid = NULL;
            EXEC dbo.usp_DoctorPayout_Prepare @CompanyId = @CompanyId, @BranchId = @BranchId, @DoctorId = @doc, @UpTo = @UpTo,
                                              @UserId = @UserId, @IsSuperAdmin = @IsSuperAdmin, @Quiet = 1, @NewId = @sid OUTPUT;
            INSERT INTO @Out SELECT @doc, 'PREPARED', SettlementNo, NetPayable, NULL FROM dbo.DoctorSettlement WHERE SettlementId = @sid;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            INSERT INTO @Out VALUES (@doc, 'SKIPPED', NULL, NULL, ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM dc INTO @doc;
    END
    CLOSE dc; DEALLOCATE dc;

    SELECT o.*, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName
    FROM @Out o LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId ORDER BY o.Outcome, DoctorName;
END;
GO

-- ── 7. approve / reject / cancel / pay ─────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Action
    @BranchId         INT,
    @SettlementId     INT,
    @Action           VARCHAR(10),          -- APPROVE / REJECT / CANCEL / PAY
    @Remarks          NVARCHAR(500) = NULL, -- approval remarks / reject or cancel reason / payment remarks
    @PaymentDate      DATE          = NULL,
    @PaymentMode      NVARCHAR(30)  = NULL,
    @PaymentReference NVARCHAR(100) = NULL,
    @UserId           INT           = NULL,
    @IsSuperAdmin     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @Action = UPPER(LTRIM(RTRIM(@Action)));
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
    SET @PaymentMode = NULLIF(LTRIM(RTRIM(@PaymentMode)), '');
    SET @PaymentReference = NULLIF(LTRIM(RTRIM(@PaymentReference)), '');

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lock NVARCHAR(100) = N'DoctorPayout_' + CAST(@BranchId AS NVARCHAR(10));
        EXEC sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;

        DECLARE @Status VARCHAR(12), @PreparedBy INT, @PreparedOn DATETIME;
        SELECT @Status = Status, @PreparedBy = PreparedBy, @PreparedOn = PreparedOn
        FROM dbo.DoctorSettlement WHERE SettlementId = @SettlementId AND BranchId = @BranchId;
        IF @Status IS NULL THROW 50020, 'Settlement not found in this branch.', 1;

        IF @Action = 'APPROVE'
        BEGIN
            IF @Status <> 'PREPARED' THROW 50020, 'Only a prepared settlement can be approved.', 1;
            IF @PreparedBy = @UserId AND ISNULL(@IsSuperAdmin, 0) = 0
                THROW 50020, 'Maker-checker: the person who prepared a settlement cannot approve it. Ask another authorised user.', 1;
            UPDATE dbo.DoctorSettlement SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedOn = GETDATE(),
                   ApprovalRemarks = CASE WHEN @PreparedBy = @UserId THEN 'Self-approved by Super Admin' + ISNULL(' · ' + @Remarks, '') ELSE @Remarks END
            WHERE SettlementId = @SettlementId;
            UPDATE dbo.DoctorDisbursal SET ApprovalStatus = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE(), ModifiedDate = GETDATE(), ModifiedBy = @UserId
            WHERE SettlementId = @SettlementId;
        END
        ELSE IF @Action IN ('REJECT', 'CANCEL')
        BEGIN
            IF @Action = 'REJECT' AND @Status NOT IN ('PREPARED', 'APPROVED') THROW 50020, 'Only a settlement not yet paid can be rejected.', 1;
            IF @Action = 'CANCEL' AND @Status <> 'PREPARED' THROW 50020, 'Only a prepared settlement (not yet approved) can be cancelled.', 1;
            IF @Remarks IS NULL THROW 50020, 'Give the reason.', 1;
            UPDATE dbo.DoctorSettlement SET Status = CASE WHEN @Action = 'REJECT' THEN 'REJECTED' ELSE 'CANCELLED' END,
                   ClosedBy = @UserId, ClosedOn = GETDATE(), CloseReason = @Remarks
            WHERE SettlementId = @SettlementId;
            -- its lines go back to be settled again
            UPDATE dbo.DoctorDisbursal SET SettlementId = NULL, ApprovalStatus = CASE WHEN NetPayable = 0 THEN 'NOT_ELIGIBLE' ELSE 'CALCULATED' END,
                   ApprovedBy = NULL, ApprovedDate = NULL, ModifiedDate = GETDATE(), ModifiedBy = @UserId
            WHERE SettlementId = @SettlementId;
        END
        ELSE IF @Action = 'PAY'
        BEGIN
            IF @Status <> 'APPROVED' THROW 50020, 'Only an approved settlement can be paid.', 1;
            IF @PaymentMode IS NULL OR @PaymentMode NOT IN ('Cash', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'Cheque')
                THROW 50020, 'Choose the payment mode: Cash, UPI, NEFT, RTGS, IMPS or Cheque.', 1;
            IF @PaymentMode <> 'Cash' AND @PaymentReference IS NULL
                THROW 50020, 'Enter the payment reference (UTR / transaction ID / cheque number).', 1;
            SET @PaymentDate = ISNULL(@PaymentDate, CAST(GETDATE() AS DATE));
            IF @PaymentDate > CAST(GETDATE() AS DATE) THROW 50020, 'The payment date cannot be in the future.', 1;
            IF @PaymentDate < CAST(@PreparedOn AS DATE) THROW 50020, 'The payment date cannot be before the settlement was prepared.', 1;
            UPDATE dbo.DoctorSettlement SET Status = 'PAID', PaymentDate = @PaymentDate, PaymentMode = @PaymentMode, PaymentReference = @PaymentReference,
                   PaymentRemarks = @Remarks, PaidBy = @UserId, PaidOn = GETDATE()
            WHERE SettlementId = @SettlementId;
            UPDATE dbo.DoctorDisbursal SET PaymentStatus = 'Paid', PaymentMethod = @PaymentMode, PaymentReference = @PaymentReference,
                   PaidDate = @PaymentDate, PaidBy = @UserId, ModifiedDate = GETDATE(), ModifiedBy = @UserId
            WHERE SettlementId = @SettlementId;
        END
        ELSE THROW 50020, 'Unknown action.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT SettlementId, SettlementNo, Status, NetPayable, DoctorId FROM dbo.DoctorSettlement WHERE SettlementId = @SettlementId;
END;
GO

-- ── 8. settlement list and one settlement (voucher) ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Settlements
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @Status       VARCHAR(12) = NULL,
    @DoctorId     INT         = NULL,
    @UserId       INT         = NULL,
    @IsSuperAdmin BIT         = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @Status = NULLIF(UPPER(LTRIM(RTRIM(@Status))), '');
    SELECT ds.SettlementId, ds.SettlementNo, ds.DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName, sp.SpecialityName AS Speciality,
           ds.SettlementDate, ds.PeriodFrom, ds.PeriodTo, ds.LineCount, ds.Visits, ds.GrossShare, ds.Recoveries, ds.OtherAdjustment, ds.OtherAdjustmentReason,
           ds.TaxableAmount, ds.TdsPercent, ds.TdsAmount, ds.NetPayable, ds.PAN, ds.Status,
           ds.PreparedBy, ISNULL(NULLIF(up.FullName, ''), up.Username) AS PreparedByName, ds.PreparedOn,
           ISNULL(NULLIF(ua.FullName, ''), ua.Username) AS ApprovedByName, ds.ApprovedOn,
           ds.PaymentDate, ds.PaymentMode, ds.PaymentReference, ISNULL(NULLIF(uy.FullName, ''), uy.Username) AS PaidByName,
           ISNULL(NULLIF(uc.FullName, ''), uc.Username) AS ClosedByName, ds.ClosedOn, ds.CloseReason,
           CAST(CASE WHEN ds.PreparedBy = @UserId THEN 1 ELSE 0 END AS BIT) AS PreparedByMe
    FROM dbo.DoctorSettlement ds
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN dbo.Users up ON up.Id = ds.PreparedBy
    LEFT JOIN dbo.Users ua ON ua.Id = ds.ApprovedBy
    LEFT JOIN dbo.Users uy ON uy.Id = ds.PaidBy
    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy
    WHERE ds.BranchId = @BranchId
      AND (@DoctorId IS NULL OR ds.DoctorId = @DoctorId)
      AND (@Status IS NULL OR ds.Status = @Status)
      -- open ones (awaiting approval / payment) always show; others by settlement or payment date
      AND (ds.Status IN ('PREPARED', 'APPROVED')
           OR ds.SettlementDate BETWEEN @FromDate AND @ToDate OR ds.PaymentDate BETWEEN @FromDate AND @ToDate)
    ORDER BY CASE ds.Status WHEN 'PREPARED' THEN 1 WHEN 'APPROVED' THEN 2 ELSE 3 END, ds.SettlementId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_SettlementGet
    @BranchId     INT,
    @SettlementId INT,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    -- RS1 header
    SELECT ds.*, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           sp.SpecialityName AS Speciality, d.MedicalLicenseNo, d.PhoneNumber AS DoctorPhone,
           b.BranchName, b.BranchCode, b.Address AS BranchAddress, b.City AS BranchCity,
           ISNULL(NULLIF(up.FullName, ''), up.Username) AS PreparedByName,
           ISNULL(NULLIF(ua.FullName, ''), ua.Username) AS ApprovedByName,
           ISNULL(NULLIF(uy.FullName, ''), uy.Username) AS PaidByName,
           ISNULL(NULLIF(uc.FullName, ''), uc.Username) AS ClosedByName,
           CAST(CASE WHEN ds.PreparedBy = @UserId THEN 1 ELSE 0 END AS BIT) AS PreparedByMe
    FROM dbo.DoctorSettlement ds
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = ds.BranchId
    LEFT JOIN dbo.Users up ON up.Id = ds.PreparedBy
    LEFT JOIN dbo.Users ua ON ua.Id = ds.ApprovedBy
    LEFT JOIN dbo.Users uy ON uy.Id = ds.PaidBy
    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy
    WHERE ds.SettlementId = @SettlementId AND ds.BranchId = @BranchId;

    -- RS2 lines: on the settlement, or (for a rejected / cancelled one) none
    SELECT dd.DisbursalId, dd.ShareDate, dd.LineType, dd.VisitId, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName, pm.PatientCode,
           dd.GrossBillAmount, dd.DiscountAmount, dd.NetBillAmount, dd.CollectedAmount, dd.CommissionRule, dd.CalculatedAmount, dd.AdjustmentAmount, dd.NetPayable
    FROM dbo.DoctorDisbursal dd
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
    WHERE dd.SettlementId = @SettlementId AND dd.IsActive = 1
    ORDER BY dd.ShareDate, dd.DisbursalId;
END;
GO

-- ── 8b. who can approve a settlement at the branch ──────────────────────
-- Active users of the branch (and the company's Super Admins) whose effective permission on
-- OPD.DOCTORDISBURSAL > APPROVE is Allow, worked out by usp_Auth_GetEffectivePermissions as the app does.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_Approvers
    @CompanyId    INT,
    @BranchId     INT,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @Perm TABLE (Page_Code NVARCHAR(150), Page_ID INT, Control_Code VARCHAR(30), Control_ID INT, Permission CHAR(1), Decided_At_Scope INT, Decided_By VARCHAR(10));
    DECLARE @Out TABLE (UserId INT, IsSuperAdmin BIT);
    DECLARE @u INT, @sa BIT;
    DECLARE uc CURSOR LOCAL FAST_FORWARD FOR
        SELECT u.Id, CAST(ISNULL(u.IsSuperAdmin, 0) AS BIT) FROM dbo.Users u
        WHERE u.IsActive = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
          AND (u.IsSuperAdmin = 1
               OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1));
    OPEN uc; FETCH NEXT FROM uc INTO @u, @sa;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @sa = 1 INSERT INTO @Out VALUES (@u, 1);
        ELSE
        BEGIN
            DELETE FROM @Perm;
            INSERT INTO @Perm EXEC dbo.usp_Auth_GetEffectivePermissions @UserId = @u, @BranchId = @BranchId, @CompanyId = @CompanyId;
            IF EXISTS (SELECT 1 FROM @Perm WHERE Page_Code = N'OPD.DOCTORDISBURSAL' AND Control_Code = 'APPROVE' AND Permission = 'A')
                INSERT INTO @Out VALUES (@u, 0);
        END
        FETCH NEXT FROM uc INTO @u, @sa;
    END
    CLOSE uc; DEALLOCATE uc;

    SELECT o.UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName, o.IsSuperAdmin,
           CASE WHEN o.IsSuperAdmin = 1 THEN 'Super Admin'
                ELSE (SELECT STRING_AGG(r.Name, ', ') FROM dbo.Userroles ur INNER JOIN dbo.roles r ON r.Id = ur.RoleId
                       WHERE ur.UserId = o.UserId AND ur.IsActive = 1 AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @BranchId)) END AS Roles
    FROM @Out o INNER JOIN dbo.Users u ON u.Id = o.UserId
    ORDER BY o.IsSuperAdmin, UserName;
END;
GO

-- ── 9. page controls and endpoints (OPD > Doctor Commission & Disbursals) ───
DECLARE @page INT = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORDISBURSAL'), @ctl INT;
IF @page IS NOT NULL
BEGIN
    DECLARE @C TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
    INSERT INTO @C VALUES ('DETAILS', N'View / print payout voucher', 30), ('PREPARE', N'Prepare settlement', 50),
                          ('ADJUSTMENT', N'Add deduction / incentive', 55), ('CANCEL', N'Cancel settlement', 60),
                          ('APPROVE', N'Approve / reject settlement', 90), ('PAYOUT', N'Record payment', 95),
                          ('PROFILE', N'Edit doctor payout profile', 100);
    DECLARE @code VARCHAR(30), @title NVARCHAR(150), @sort INT;
    DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @C;
    OPEN cc; FETCH NEXT FROM cc INTO @code, @title, @sort;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @title, @Sort_Order = @sort, @Control_ID = @ctl OUTPUT;
        FETCH NEXT FROM cc INTO @code, @title, @sort;
    END
    CLOSE cc; DEALLOCATE cc;

    DECLARE @E TABLE (Method VARCHAR(10), Action NVARCHAR(150), Code VARCHAR(30));
    INSERT INTO @E VALUES ('GET', N'BoardData', 'VIEW'), ('GET', N'SettlementsData', 'VIEW'), ('GET', N'ProfilesData', 'VIEW'),
                          ('GET', N'SettlementData', 'DETAILS'), ('GET', N'Voucher', 'DETAILS'),
                          ('POST', N'PrepareSettlement', 'PREPARE'), ('POST', N'PrepareDay', 'PREPARE'),
                          ('POST', N'ApproveSettlement', 'APPROVE'), ('POST', N'RejectSettlement', 'APPROVE'),
                          ('POST', N'CancelSettlement', 'CANCEL'), ('POST', N'PaySettlement', 'PAYOUT'),
                          ('POST', N'SaveProfile', 'PROFILE'), ('GET', N'ApproversData', 'VIEW');
    DECLARE @m VARCHAR(10), @a NVARCHAR(150);
    DECLARE ec CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Code FROM @E;
    OPEN ec; FETCH NEXT FROM ec INTO @m, @a, @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code);
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @m,
             @Controller = N'DoctorDisbursal', @Action = @a, @Source = 'SEED';
        FETCH NEXT FROM ec INTO @m, @a, @code;
    END
    CLOSE ec; DEALLOCATE ec;
END

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2213 applied: OPD doctor payout - share on collection, day-end doctor-wise settlement, maker-checker, TDS, payout profile.';
GO
