-- ============================================================================
-- Migration: 2200_lab_owner_mis.sql
-- Description: Reports > LAB > Owner MIS & Test Revenue (LF-18) - one management view of the lab for a period:
--   revenue by test, department, referring doctor and B2B partner; discount and partner margin given; TAT compliance;
--   rejection, re-collection and retest rates; collection against billing; outstanding ageing; branch comparison.
--   * usp_Api_LabReport_OwnerMis returns ten result sets (see the RS comments). Definitions match the LAB registers:
--     net / paid / due as the Daily Billing Register, rejection statuses as LR-11, age buckets as the Outstanding Dues
--     (B2C) and B2B Outstanding registers. Test-wise revenue is exact per bill line (PaymentLineItem), scaled so the lines
--     of a bill add up to the bill's net. No cost / profit yet: that needs LF-07 (reagent cost per test).
--   * Scope: the current branch, or all branches the user works in (@AllBranches; a super admin: all of the company).
--   * Page REPORTS.LABOWNERMIS in the database navigation (Reports > LAB, first), VIEW on GET Reports/LabOwnerMis and
--     GET Reports/GetLabOwnerMisData. No role or user grant is seeded: who may open it is set in Role Permissions.
--   Run after 2199.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── shared TAT definition (LF-18 Owner MIS and LR-15 Turnaround Time) ─────────────────────────────────────────────
-- One row per test approved in [@From, @To): a profile is one test (its parameters together), a single test is one test.
-- The test counts once all its parameters are approved; its approval time is the last parameter's approval.
-- Timestamps: billed (bill date), collected (last collection before approval, from the status log, else the collection
-- date & time), received at lab (receipt at the target branch for a transferred sample, else = collected), entered (last
-- parameter submitted / drafted), validated, approved. Lab TAT = received at lab -> approval, against the profile's TAT
-- hours, else the test's TAT hours (the roadmap's "received at lab" rule: transport delay is kept out of bench delay).
-- HolderBranchId = the branch that tested it (the target branch of a transferred sample). Outsourced tests are left out.
CREATE OR ALTER FUNCTION dbo.ufn_LabReport_TatUnits (@From DATETIME, @To DATETIME)
RETURNS TABLE
AS
RETURN
(
    WITH R AS (
        SELECT sc.Laborderid AS LabOrderId, sc.samplecollectionID AS SampleId, sc.ProfileId,
               CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END AS UnitKey,
               CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 THEN sc.TargetBranchID ELSE sc.BranchID END AS HolderBranchId,
               CAST(ISNULL(sc.IsTransferred, 0) AS INT) AS IsTransferred, sc.ReceivedDate,
               COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
               COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName, lim.Test_Code, lim.TAT_Hours,
               led.ReportStatusId, led.Approved_Date, led.Validated_date,
               COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate) AS EnteredOn,
               led.CreatedBy AS EnteredById, led.ModifiedBy AS UpdatedById,
               COALESCE(col.ChangedOn, CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME)) AS CollectedOn
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        OUTER APPLY (SELECT TOP 1 l.ChangedOn FROM dbo.LabSampleStatusLog l
                      WHERE l.SampleCollectionId = sc.samplecollectionID AND l.ToStatusId = 2
                        AND (led.Approved_Date IS NULL OR l.ChangedOn <= led.Approved_Date)
                      ORDER BY l.ChangedOn DESC, l.LogId DESC) col
        WHERE sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0 AND ISNULL(sc.IsoutSource, 0) = 0
          AND sc.Laborderid IN (SELECT a.LabOrderId FROM dbo.labentrydetails a
                                WHERE a.IsActive = 1 AND a.Approved_Date >= @From AND a.Approved_Date < @To)
    ),
    U AS (
        SELECT LabOrderId, UnitKey, MIN(SampleId) AS FirstSampleId, MAX(ProfileId) AS ProfileId, MAX(HolderBranchId) AS HolderBranchId,
               MAX(IsTransferred) AS IsTransferred, MAX(DepartmentId) AS DepartmentId, MAX(TestName) AS TestName, MAX(Test_Code) AS TestCode,
               MAX(TAT_Hours) AS ParamTatHours, COUNT(1) AS Parameters,
               MAX(CollectedOn) AS CollectedOn, MAX(ReceivedDate) AS ReceivedDate, MAX(EnteredOn) AS EnteredOn,
               MAX(Validated_date) AS ValidatedOn, MAX(Approved_Date) AS ApprovedOn,
               MAX(EnteredById) AS EnteredById, MAX(UpdatedById) AS UpdatedById
        FROM R
        GROUP BY LabOrderId, UnitKey
        HAVING MIN(CASE WHEN ReportStatusId = 5 AND Approved_Date IS NOT NULL THEN 1 ELSE 0 END) = 1
           AND MAX(Approved_Date) >= @From AND MAX(Approved_Date) < @To
    ),
    T AS (
        SELECT u.*, lo.BranchId AS BillBranchId, lo.OrderDate AS BilledOn, lo.PatientId, lo.BillNo, lo.TokenNo,
               CASE WHEN u.IsTransferred = 1 AND u.ReceivedDate IS NOT NULL THEN u.ReceivedDate ELSE u.CollectedOn END AS ReceivedOn,
               COALESCE(h.Profile_Code, u.TestCode) AS UnitCode,
               COALESCE(NULLIF(h.Profile_TAT_Hours, 0), NULLIF(hp.TAT_Hours, 0), NULLIF(u.ParamTatHours, 0)) AS TargetHours
        FROM U u
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = u.LabOrderId
        LEFT  JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = u.ProfileId
        LEFT  JOIN dbo.LabInvestigationMaster hp ON hp.Test_ID = h.Test_ID
    )
    SELECT t.LabOrderId, t.UnitKey, t.FirstSampleId, t.ProfileId, t.HolderBranchId, t.BillBranchId, CAST(t.IsTransferred AS BIT) AS IsTransferred,
           t.DepartmentId, t.UnitCode AS TestCode, t.TestName, t.Parameters, t.PatientId, t.BillNo, t.TokenNo,
           t.BilledOn, t.CollectedOn, t.ReceivedOn, t.EnteredOn, t.ValidatedOn, t.ApprovedOn, t.TargetHours,
           t.EnteredById, t.UpdatedById,
           h.PreHours, h.TransportHours, h.BenchHours, h.ValidationHours, h.SignoffHours, h.LabHours, h.TotalHours,
           CASE WHEN t.TargetHours IS NULL THEN 'NOTARGET'
                WHEN h.LabHours IS NULL THEN 'NOTIMED'          -- received / approval times missing or out of order
                WHEN h.LabHours <= t.TargetHours THEN 'ONTIME' ELSE 'BREACH' END AS TatStatus
    FROM T t
    CROSS APPLY (SELECT
        CAST(CASE WHEN t.CollectedOn >= t.BilledOn THEN DATEDIFF(MINUTE, t.BilledOn, t.CollectedOn) / 60.0 END AS DECIMAL(10, 1)) AS PreHours,
        CAST(CASE WHEN t.ReceivedOn >= t.CollectedOn THEN DATEDIFF(MINUTE, t.CollectedOn, t.ReceivedOn) / 60.0 END AS DECIMAL(10, 1)) AS TransportHours,
        CAST(CASE WHEN t.EnteredOn >= t.ReceivedOn THEN DATEDIFF(MINUTE, t.ReceivedOn, t.EnteredOn) / 60.0 END AS DECIMAL(10, 1)) AS BenchHours,
        CAST(CASE WHEN t.ValidatedOn >= t.EnteredOn THEN DATEDIFF(MINUTE, t.EnteredOn, t.ValidatedOn) / 60.0 END AS DECIMAL(10, 1)) AS ValidationHours,
        CAST(CASE WHEN t.ApprovedOn >= COALESCE(t.ValidatedOn, t.EnteredOn) THEN DATEDIFF(MINUTE, COALESCE(t.ValidatedOn, t.EnteredOn), t.ApprovedOn) / 60.0 END AS DECIMAL(10, 1)) AS SignoffHours,
        CAST(CASE WHEN t.ApprovedOn >= t.ReceivedOn THEN DATEDIFF(MINUTE, t.ReceivedOn, t.ApprovedOn) / 60.0 END AS DECIMAL(10, 1)) AS LabHours,
        CAST(CASE WHEN t.ApprovedOn >= t.BilledOn THEN DATEDIFF(MINUTE, t.BilledOn, t.ApprovedOn) / 60.0 END AS DECIMAL(10, 1)) AS TotalHours) h
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_OwnerMis
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @AllBranches  BIT = 0,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @sw DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @sw; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From), @PrevTo DATETIME = @From;
    DECLARE @ByMonth BIT = CASE WHEN @Days > 62 THEN 1 ELSE 0 END;

    -- ── branches in scope ────────────────────────────────────────────────────
    DECLARE @Br TABLE (BranchId INT PRIMARY KEY, BranchName NVARCHAR(200));
    IF ISNULL(@AllBranches, 0) = 1
        INSERT INTO @Br
        SELECT b.BranchID, b.BranchName
        FROM dbo.Branchmaster b
        WHERE b.IsActive = 1
          AND b.CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId)
          AND (ISNULL(@IsSuperAdmin, 0) = 1
               OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.BranchID = b.BranchID AND ISNULL(ub.IsActive, 1) = 1));
    ELSE
        INSERT INTO @Br SELECT BranchID, BranchName FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    -- ── bills of the period (and of the previous period, for growth) ─────────
    SELECT lo.LabOrderId, lo.BranchId, lo.OrderDate, lo.PatientId,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, lo.AgentType, lo.B2BAgentID, lo.RefDoctorId, lo.ReferralDoctorId,
           CAST(lo.IsActive AS BIT) AS IsActive,
           CAST(CASE WHEN lo.OrderDate >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(lo.TotalAmount AS DECIMAL(18, 2)) AS GrossAmount,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           ph.PaymentHeaderId
    INTO #O
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.OrderDate >= @PrevFrom AND lo.OrderDate < @To;

    ALTER TABLE #O ADD DueAmount DECIMAL(18, 2);
    UPDATE #O SET DueAmount = CASE WHEN IsActive = 0 OR NetAmount - PaidAmount < 0 THEN 0 ELSE NetAmount - PaidAmount END;

    -- ── bill lines of the period: revenue per test (lines of a bill add up to the bill's net) ──
    SELECT o.LabOrderId, o.BranchId, o.IsB2B, li.LabOrderItemId,
           CASE WHEN li.[Type] = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS Kind,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Code END, lim.Test_Code, '') AS TestCode,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, lim.Test_Name, 'Item ' + CAST(li.InvestigationId AS VARCHAR(20))) AS TestName,
           CASE WHEN li.[Type] = 'P' THEN 'Packages' ELSE ISNULL(dm.DeptName, 'Not set') END AS Department,
           CAST(li.Price AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN o.IsB2B = 1 THEN ISNULL(li.B2BRate, li.Price) ELSE COALESCE(pli.NetLineAmount, li.Price) END AS DECIMAL(18, 4)) AS Basis,
           o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.LabOrderItem li ON li.LabOrderId = o.LabOrderId AND li.IsActive = 1
    LEFT  JOIN dbo.LabInvestigationMaster lim ON li.[Type] <> 'P' AND lim.Test_ID = li.InvestigationId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT  JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = o.PaymentHeaderId AND pli.ModuleLineRefId = li.LabOrderItemId AND pli.IsActive = 1
    WHERE o.InPeriod = 1 AND o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2), Discount DECIMAL(18, 2), PartnerMargin DECIMAL(18, 2);
    ;WITH s AS (SELECT LabOrderId, SUM(Basis) AS SumBasis FROM #L GROUP BY LabOrderId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.LabOrderId = l.LabOrderId;
    UPDATE #L SET Discount = CASE WHEN IsB2B = 0 THEN Mrp - NetLine ELSE 0 END,
                  PartnerMargin = CASE WHEN IsB2B = 1 THEN Mrp - NetLine ELSE 0 END;

    -- per bill: tests, MRP and partner margin of its lines (for the doctor and partner tables)
    ALTER TABLE #O ADD Tests INT NOT NULL DEFAULT 0, LineMrp DECIMAL(18, 2) NOT NULL DEFAULT 0, LineMargin DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET Tests = x.Tests, LineMrp = x.Mrp, LineMargin = x.Margin
    FROM #O o INNER JOIN (SELECT LabOrderId, COUNT(1) AS Tests, SUM(Mrp) AS Mrp, SUM(PartnerMargin) AS Margin FROM #L GROUP BY LabOrderId) x
         ON x.LabOrderId = o.LabOrderId;

    -- ── tests approved in the period: lab TAT (received at lab -> approval) against the TAT hours (dbo.ufn_LabReport_TatUnits) ──
    SELECT ISNULL(dm.DeptName, 'Not set') AS Department, t.LabHours AS Hours,
           CAST(CASE WHEN t.TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END AS BIT) AS HasTarget,
           CAST(CASE WHEN t.TatStatus = 'ONTIME' THEN 1 ELSE 0 END AS BIT) AS Within
    INTO #T
    FROM dbo.ufn_LabReport_TatUnits(@From, @To) t
    INNER JOIN @Br br ON br.BranchId = t.HolderBranchId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.DepartmentId;

    -- ── quality: specimens collected / rejected / sent for re-collection (as LR-11), retests ──
    SELECT l.ToStatusId, l.RejectionReasonId, l.RejectionReason,
           COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END) AS SpecimenKey
    INTO #Q
    FROM dbo.LabSampleStatusLog l
    INNER JOIN @Br br ON br.BranchId = l.BranchId
    WHERE l.ToStatusId IN (2, 3, 4) AND l.ChangedOn >= @From AND l.ChangedOn < @To;

    DECLARE @Specimens INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 2);
    DECLARE @Rejected INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 4);
    DECLARE @Recollect INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 3);
    DECLARE @Retests INT = (SELECT COUNT(1) FROM dbo.LabReportUnapproval u
                            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = u.LabOrderId
                            INNER JOIN @Br br ON br.BranchId = lo.BranchId
                            WHERE u.Action = 'RETEST' AND u.UnapprovedDate >= @From AND u.UnapprovedDate < @To);

    -- ── money received in the period (receipt date); wallet deductions are shown apart (paid earlier as top-ups) ──
    SELECT pd.PaidAmount, ISNULL(pm.MethodName, 'Unknown') AS Mode,
           CAST(CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 1 ELSE 0 END AS BIT) AS FromWallet,
           CAST(CASE WHEN COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           ph.BranchId, COALESCE(pd.PaymentDate, pd.CreatedDate) AS PaidOn
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN @Br br ON br.BranchId = ph.BranchId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @PrevFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    DECLARE @Refunds DECIMAL(18, 2) = (SELECT ISNULL(SUM(r.RefundAmount), 0) FROM dbo.BillRefund r
                                       INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
                                       INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                       WHERE r.ModuleCode = 'LAB' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P'
                                         AND r.RefundDate >= @From AND r.RefundDate < @To);

    DECLARE @CancelledAmount DECIMAL(18, 2) = (SELECT ISNULL(SUM(bc.CancelledAmount), 0) FROM dbo.BillCancellation bc
                                               INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
                                               INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                               WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1 AND bc.CancellationDate >= @From AND bc.CancellationDate < @To);

    -- ── outstanding today (all open bills of the branches), for ageing ───────
    SELECT CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, DATEDIFF(DAY, lo.OrderDate, GETDATE()) AS AgeDays,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END
                - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS Due
    INTO #D
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.IsActive = 1;
    DELETE FROM #D WHERE Due <= 0;

    -- RS1 summary
    SELECT
        (SELECT COUNT(1) FROM @Br) AS BranchCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN 1 ELSE 0 END) AS BillCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
        @CancelledAmount AS CancelledAmount,
        COUNT(DISTINCT CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PatientId END) AS PatientCount,
        (SELECT COUNT(1) FROM #L) AS TestCount,
        (SELECT ISNULL(SUM(Mrp), 0) FROM #L) AS GrossAmount,
        (SELECT ISNULL(SUM(Discount), 0) FROM #L) AS DiscountAmount,
        (SELECT ISNULL(SUM(PartnerMargin), 0) FROM #L) AS PartnerMargin,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN NetAmount END), 0) AS NetRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN NetAmount END), 0) AS B2CRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN NetAmount END), 0) AS B2BRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PaidAmount END), 0) AS CollectedOnPeriodBills,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN DueAmount END), 0) AS PeriodBillsDue,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 0) AS Collected,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 1) AS PaidFromWallet,
        @Refunds AS Refunds,
        (SELECT ISNULL(SUM(Due), 0) FROM #D) AS OutstandingNow,
        -- previous period of the same length, for growth
        SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN 1 ELSE 0 END) AS PrevBillCount,
        ISNULL(SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN NetAmount END), 0) AS PrevNetRevenue,
        COUNT(DISTINCT CASE WHEN InPeriod = 0 AND IsActive = 1 THEN PatientId END) AS PrevPatientCount,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 0 AND FromWallet = 0) AS PrevCollected,
        (SELECT COUNT(1) FROM #T) AS ReportsApproved,
        (SELECT COUNT(1) FROM #T WHERE HasTarget = 1) AS TatTests,
        (SELECT COUNT(1) FROM #T WHERE Within = 1) AS TatWithin,
        (SELECT CAST(AVG(Hours) AS DECIMAL(10, 1)) FROM #T WHERE Hours IS NOT NULL) AS TatAvgHours,
        @Specimens AS SpecimensCollected, @Rejected AS SpecimensRejected, @Recollect AS SpecimensRecollect, @Retests AS Retests,
        @Days AS PeriodDays,
        CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom,
        CONVERT(VARCHAR(10), DATEADD(DAY, -1, CAST(@PrevTo AS DATE)), 23) AS PrevTo
    FROM #O;

    -- RS2 trend: billed / collected per day (per month for long periods)
    ;WITH b AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END AS Bucket,
               COUNT(1) AS Bills, SUM(NetAmount) AS Billed
        FROM #O WHERE InPeriod = 1 AND IsActive = 1
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END),
    c AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END AS Bucket,
               SUM(PaidAmount) AS Collected
        FROM #P WHERE InPeriod = 1 AND FromWallet = 0
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END)
    SELECT COALESCE(b.Bucket, c.Bucket) AS Bucket, ISNULL(b.Bills, 0) AS Bills, ISNULL(b.Billed, 0) AS Billed, ISNULL(c.Collected, 0) AS Collected,
           CAST(@ByMonth AS BIT) AS ByMonth
    FROM b FULL OUTER JOIN c ON c.Bucket = b.Bucket
    ORDER BY Bucket;

    -- RS3 revenue by test
    SELECT Kind, TestCode, TestName, Department,
           COUNT(1) AS Tests, SUM(CASE WHEN IsB2B = 0 THEN 1 ELSE 0 END) AS B2CTests, SUM(CASE WHEN IsB2B = 1 THEN 1 ELSE 0 END) AS B2BTests,
           SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net,
           CAST(SUM(NetLine) / NULLIF(COUNT(1), 0) AS DECIMAL(18, 2)) AS AvgRealised
    FROM #L GROUP BY Kind, TestCode, TestName, Department
    ORDER BY Net DESC;

    -- RS4 by department: revenue and TAT compliance
    ;WITH r AS (SELECT Department, COUNT(1) AS Tests, SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net
                FROM #L GROUP BY Department),
    t AS (SELECT Department, COUNT(1) AS Reported, SUM(CASE WHEN HasTarget = 1 THEN 1 ELSE 0 END) AS TatTests,
                 SUM(CASE WHEN Within = 1 THEN 1 ELSE 0 END) AS TatWithin, CAST(AVG(Hours) AS DECIMAL(10, 1)) AS AvgHours
          FROM #T GROUP BY Department)
    SELECT COALESCE(r.Department, t.Department) AS Department, ISNULL(r.Tests, 0) AS Tests, ISNULL(r.Gross, 0) AS Gross,
           ISNULL(r.Discount, 0) AS Discount, ISNULL(r.PartnerMargin, 0) AS PartnerMargin, ISNULL(r.Net, 0) AS Net,
           ISNULL(t.Reported, 0) AS Reported, ISNULL(t.TatTests, 0) AS TatTests, ISNULL(t.TatWithin, 0) AS TatWithin, t.AvgHours
    FROM r FULL OUTER JOIN t ON t.Department = r.Department
    ORDER BY ISNULL(r.Net, 0) DESC;

    -- RS5 by referring doctor
    SELECT COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)), ''),
                    NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), ''), 'Self / walk-in') AS Doctor,
           COUNT(1) AS Bills, COUNT(DISTINCT o.PatientId) AS Patients, SUM(o.Tests) AS Tests,
           SUM(CASE WHEN o.IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills, SUM(CASE WHEN o.IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
           SUM(o.NetAmount) AS Net, SUM(o.DueAmount) AS Due
    FROM #O o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    WHERE o.InPeriod = 1 AND o.IsActive = 1
    GROUP BY o.RefDoctorId, o.ReferralDoctorId, d.NamePrefix, d.FullName, rd.Salutation, rd.DoctorName
    ORDER BY Net DESC;

    -- RS6 by B2B partner
    SELECT CASE o.AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE 'Other' END AS PartnerType,
           CASE o.AgentType WHEN 'F' THEN f.Franchise_Code ELSE c.Corporate_Code END AS PartnerCode,
           ISNULL(CASE o.AgentType WHEN 'F' THEN f.Franchise_Name ELSE c.Corporate_Name END, 'Unknown partner') AS Partner,
           COUNT(1) AS Bills, SUM(o.Tests) AS Tests, SUM(o.LineMrp) AS Mrp, SUM(o.NetAmount) AS Billed, SUM(o.LineMargin) AS MarginGiven,
           SUM(o.PaidAmount) AS Collected, SUM(o.DueAmount) AS Due
    FROM #O o
    LEFT JOIN dbo.LabFranchiseMaster f ON o.AgentType = 'F' AND f.Franchise_ID = o.B2BAgentID
    LEFT JOIN dbo.CorporateMaster c ON o.AgentType = 'C' AND c.Corporate_ID = o.B2BAgentID
    WHERE o.InPeriod = 1 AND o.IsActive = 1 AND o.IsB2B = 1
    GROUP BY o.AgentType, o.B2BAgentID, f.Franchise_Code, f.Franchise_Name, c.Corporate_Code, c.Corporate_Name
    ORDER BY Billed DESC;

    -- RS7 quality: rejection / re-collection reasons
    SELECT ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded') AS Reason,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 4 THEN q.SpecimenKey END) AS Rejected,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 3 THEN q.SpecimenKey END) AS Recollect
    FROM #Q q
    LEFT JOIN dbo.LabSampleRejectionReasonMaster rr ON rr.Reason_ID = q.RejectionReasonId
    WHERE q.ToStatusId IN (3, 4)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded')
    ORDER BY COUNT(DISTINCT q.SpecimenKey) DESC;

    -- RS8 outstanding ageing today (B2C buckets as Outstanding Dues, B2B as B2B Outstanding)
    SELECT Segment, Bucket, SortOrder, COUNT(1) AS Bills, SUM(Due) AS Due
    FROM (SELECT CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS Segment,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN '0-2' WHEN AgeDays <= 7 THEN '3-7' WHEN AgeDays <= 30 THEN '8-30' ELSE '30+' END
                      ELSE CASE WHEN AgeDays <= 30 THEN '0-30' WHEN AgeDays <= 60 THEN '31-60' WHEN AgeDays <= 90 THEN '61-90' ELSE '90+' END END AS Bucket,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN 1 WHEN AgeDays <= 7 THEN 2 WHEN AgeDays <= 30 THEN 3 ELSE 4 END
                      ELSE CASE WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2 WHEN AgeDays <= 90 THEN 3 ELSE 4 END END AS SortOrder,
                 Due
          FROM #D) x
    GROUP BY Segment, Bucket, SortOrder
    ORDER BY Segment, SortOrder;

    -- RS9 collection by payment mode (receipts of the period)
    SELECT CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END AS Mode, COUNT(1) AS Receipts, SUM(PaidAmount) AS Amount
    FROM #P WHERE InPeriod = 1
    GROUP BY CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END
    ORDER BY Amount DESC;

    -- RS10 by branch
    SELECT br.BranchName AS Branch,
           (SELECT COUNT(1) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Bills,
           (SELECT ISNULL(SUM(o.NetAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Net,
           (SELECT ISNULL(SUM(p.PaidAmount), 0) FROM #P p WHERE p.BranchId = br.BranchId AND p.InPeriod = 1 AND p.FromWallet = 0) AS Collected,
           (SELECT ISNULL(SUM(o.DueAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Due
    FROM @Br br
    ORDER BY Net DESC;

    DROP TABLE #O; DROP TABLE #L; DROP TABLE #T; DROP TABLE #Q; DROP TABLE #P; DROP TABLE #D;
END;
GO

-- ── menu page and endpoints (database navigation) ────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABOWNERMIS',
             @Title = N'Owner MIS & Test Revenue', @Controller = N'Reports', @Action = N'LabOwnerMis', @Show_In_Menu = 1, @Sort_Order = 5,
             @Icon = N'bi bi-graph-up-arrow me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabOwnerMis', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabOwnerMisData', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2200 applied: Reports > LAB > Owner MIS & Test Revenue.';
GO
