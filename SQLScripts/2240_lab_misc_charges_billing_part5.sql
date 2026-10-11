-- ============================================================================
-- Migration: 2240_lab_misc_charges_billing_part5.sql   (run after part 4)
-- Description: Misc charges in the remaining LAB amounts (live definitions, only the 2240-marked changes):
--   * Billing Register / Owner MIS: a bill's gross = tests + misc charges with GST (net / due already came from the bill).
--   * LAB dashboard revenue and the order list's Total Amount card: + misc charges with GST.
--   * B2B invoice detail: + the invoiced bills' misc charges (amount + GST), so the lines add up to the invoice.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BillingRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @BillingType   VARCHAR(3)    = NULL,   -- B2C / B2B
    @PaymentStatus VARCHAR(10)   = NULL,   -- PAID / PARTIAL / UNPAID / CANCELLED
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 SET @CreatedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @PaymentStatus = NULLIF(UPPER(LTRIM(RTRIM(@PaymentStatus))), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctor,
        items.TestCount, items.TestNames,
        CAST(lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount /* 2240: + misc charges with GST */,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN lo.IsActive = 0 THEN 0
                  WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END
                  ELSE CASE WHEN ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END END AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(lo.IsB2B, 0) = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'PAID'
             WHEN ISNULL(lo.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    OUTER APPLY (SELECT COUNT(1) AS TestCount,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT SUM(bc.CancelledAmount) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1) canc
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @PaymentStatus IS NOT NULL DELETE FROM #R WHERE PaymentStatus <> @PaymentStatus;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount,
           SUM(CASE WHEN IsCancelled = 0 THEN 1 ELSE 0 END) AS ActiveBills,
           SUM(CASE WHEN IsCancelled = 1 THEN 1 ELSE 0 END) AS CancelledBills,
           SUM(CASE WHEN BillingType = 'B2C' THEN 1 ELSE 0 END) AS B2CBills,
           SUM(CASE WHEN BillingType = 'B2B' THEN 1 ELSE 0 END) AS B2BBills,
           ISNULL(SUM(TestCount), 0) AS TestCount,
           ISNULL(SUM(GrossAmount), 0) AS GrossAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           COUNT(DISTINCT PatientId) AS PatientCount
    FROM #R;

    -- RS2 groups
    SELECT 'byDate' AS GroupKey, NULL AS GroupId, BillDay AS GroupName, 0 AS SortOrder,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY CreatedById, CreatedBy
    UNION ALL
    SELECT 'byBillingType', NULL, BillingType, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillingType
    UNION ALL
    SELECT 'byPaymentStatus', NULL, PaymentStatus,
           CASE PaymentStatus WHEN 'PAID' THEN 1 WHEN 'PARTIAL' THEN 2 WHEN 'UNPAID' THEN 3 ELSE 4 END,
           COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PaymentStatus
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
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
           CAST(lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount /* 2240: + misc charges with GST */,
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_LAB_Dashboard_GetStats
    @BranchId INT,
    @Date     DATE = NULL,
    @ClientType VARCHAR(10) = 'ALL'    -- ALL | B2C | B2B : drives every result set
AS
BEGIN
    SET @ClientType = UPPER(LTRIM(RTRIM(ISNULL(@ClientType, 'ALL'))));
    IF @ClientType NOT IN ('ALL', 'B2C', 'B2B') SET @ClientType = 'ALL';

    SET NOCOUNT ON;

    IF @Date IS NULL
        SET @Date = CAST(GETDATE() AS DATE);

    -- ─────────────────────────────────────────────────────────────
    -- 1. Summary KPI Statistics
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        COUNT(DISTINCT o.LabOrderId) AS TotalOrdersToday,
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0) AS TotalRevenueToday,
        ISNULL(SUM(CASE WHEN o.IsUrgent = 1 THEN 1 ELSE 0 END), 0) AS UrgentOrdersToday,
        ISNULL(SUM(CASE WHEN o.CollectionType = 'Home' OR o.CollectionType = 'Home Collection' THEN 1 ELSE 0 END), 0) AS HomeCollectionOrders,
        ISNULL(SUM(CASE WHEN o.CollectionType = 'Lab' OR o.CollectionType IS NULL THEN 1 ELSE 0 END), 0) AS InLabOrders,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 1
              AND sc.Is_Active = 1
        ), 0) AS PendingCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 2
              AND sc.Is_Active = 1
        ), 0) AS CompletedCollectionsToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 3
              AND sc.Is_Active = 1
        ), 0) AS RecollectSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND sc.CollectionstatusID = 4
              AND sc.Is_Active = 1
        ), 0) AS RejectedSamplesToday,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.LabOrderItem loi
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
            WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0)) 
              AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
              AND loi.IsActive = 1
        ), 0) AS TotalTestsBookedToday
    FROM dbo.LabOrder o
    WHERE o.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND (CAST(o.OrderDate AS DATE) = @Date OR CAST(o.BookingDate AS DATE) = @Date)
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 2. Collection Status Breakdown
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        scs.StatusID,
        scs.StatusCode,
        scs.StatusName,
        scs.BadgeClass,
        ISNULL(cnt.TotalCount, 0) AS TotalCount
    FROM dbo.SampleCollectionStatus scs
    LEFT JOIN (
        SELECT sc.CollectionstatusID, COUNT(1) AS TotalCount
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
        WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
          AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
          AND sc.Is_Active = 1
        GROUP BY sc.CollectionstatusID
    ) cnt ON cnt.CollectionstatusID = scs.StatusID
    WHERE scs.IsActive = 1
    ORDER BY scs.DisplayOrder;

    -- ─────────────────────────────────────────────────────────────
    -- 3. Top Investigations / Profiles Booked
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        CASE 
            WHEN loi.Type = 'P' THEN ISNULL(p.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
            ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
        END AS ItemName,
        ISNULL(loi.Type, 'I') AS ItemType,
        ISNULL(cat.Category_Name, 'General Investigation') AS CategoryName,
        COUNT(1) AS OrderCount,
        SUM(ISNULL(loi.Price, 0)) AS TotalRevenue
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
    LEFT JOIN dbo.LabInvestigationProfileHeader p ON p.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = lim.Category_ID
    WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
      AND loi.IsActive = 1
    GROUP BY 
        loi.Type,
        CASE 
            WHEN loi.Type = 'P' THEN ISNULL(p.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
            ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
        END,
        cat.Category_Name
    ORDER BY OrderCount DESC, TotalRevenue DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 4. Category Distribution
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        ISNULL(cat.Category_Name, 'Profile / Package') AS CategoryName,
        COUNT(1) AS TestCount
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = sc.TestcategoryID
    WHERE lo.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (CAST(lo.OrderDate AS DATE) = @Date OR CAST(lo.BookingDate AS DATE) = @Date)
      AND sc.Is_Active = 1
    GROUP BY cat.Category_Name
    ORDER BY TestCount DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 5. Today's Patient / Lab Order Queue
    -- ─────────────────────────────────────────────────────────────
    SELECT 
        o.LabOrderId,
        o.BillNo,
        o.TokenNo,
        o.OrderDate,
        ISNULL(o.BookingDate, o.OrderDate) AS BookingDate,
        o.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        p.Gender,
        CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
            ELSE NULL 
        END AS Age,
        o.TotalAmount,
        ISNULL(o.IsUrgent, 0) AS IsUrgent,
        ISNULL(o.CollectionType, 'Lab') AS CollectionType,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.LabOrderItem loi 
            WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
        ), 0) AS TotalItems,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID = 1 AND sc.Is_Active = 1
        ), 0) AS PendingCount,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID = 2 AND sc.Is_Active = 1
        ), 0) AS CollectedCount,
        ISNULL((
            SELECT COUNT(1) 
            FROM dbo.SampleCollection sc 
            WHERE sc.Laborderid = o.LabOrderId AND (sc.CollectionstatusID = 3 OR sc.CollectionstatusID = 4) AND sc.Is_Active = 1
        ), 0) AS AlertCount,
        CASE 
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1) THEN 'Unassigned'
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID != 2 AND sc.Is_Active = 1) THEN 'Collected'
            WHEN NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = o.LabOrderId AND sc.CollectionstatusID != 1 AND sc.Is_Active = 1) THEN 'Pending'
            ELSE 'Partially Collected'
        END AS OverallSampleStatus,
        (
            SELECT STRING_AGG(
                CASE 
                    WHEN loi.Type = 'P' THEN ISNULL(pr.Profile_Name, 'Profile #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                END, ', ')
            FROM dbo.LabOrderItem loi
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
            LEFT JOIN dbo.LabInvestigationProfileHeader pr ON pr.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
        ) AS TestSummary
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
              AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND (CAST(o.OrderDate AS DATE) = @Date OR CAST(o.BookingDate AS DATE) = @Date)
      AND o.IsActive = 1
    ORDER BY 
        o.IsUrgent DESC,
        ISNULL(o.BookingDate, o.OrderDate) DESC,
        o.LabOrderId DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 6. Reporting pipeline (entry -> validation -> approval)
    -- ─────────────────────────────────────────────────────────────
    SELECT
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 1 ELSE 0 END) AS PendingEntry,
        SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' AND led.ReportStatusId IN (1, 2) THEN 1 ELSE 0 END) AS Entered,
        SUM(CASE WHEN led.ReportStatusId = 3 THEN 1 ELSE 0 END)                     AS Validated,
        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END)                     AS Approved,
        SUM(CASE WHEN ISNULL(led.AbnormalFlag, '') IN ('H', 'L') THEN 1 ELSE 0 END) AS AbnormalResults,
        SUM(CASE WHEN ISNULL(led.AbnormalFlag, '') = 'Critical' THEN 1 ELSE 0 END)  AS CriticalResults,
        CAST(AVG(CASE WHEN led.ReportStatusId = 5 AND led.Approved_Date IS NOT NULL
                      THEN DATEDIFF(MINUTE, ISNULL(o.BookingDate, o.OrderDate), led.Approved_Date) * 1.0 END) AS DECIMAL(12,1)) AS AvgTatMinutes
    FROM dbo.LabOrder o
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 7. Billing and money collected
    -- ─────────────────────────────────────────────────────────────
    SELECT
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0)                                                  AS GrossAmount,
        ISNULL(SUM(ISNULL(ph.TotalPaid, 0)), 0)                                        AS CollectedAmount,
        ISNULL(SUM(ISNULL(ph.BalanceDue, o.TotalAmount)), 0)                           AS OutstandingAmount,
        SUM(CASE WHEN ISNULL(ph.BalanceDue, o.TotalAmount) > 0 THEN 1 ELSE 0 END)      AS BillsWithDue,
        SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 1 ELSE 0 END)                        AS B2BOrders,
        SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 0 THEN 1 ELSE 0 END)                        AS B2COrders,
        ISNULL(SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN o.TotalAmount ELSE 0 END), 0) AS B2BAmount,
        ISNULL(SUM(CASE WHEN ISNULL(o.IsB2B, 0) = 0 THEN o.TotalAmount ELSE 0 END), 0) AS B2CAmount,
        CAST(ISNULL(AVG(NULLIF(o.TotalAmount, 0)), 0) AS DECIMAL(12,2))                AS AvgBillValue
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1;

    -- ─────────────────────────────────────────────────────────────
    -- 8. Bookings by hour
    -- ─────────────────────────────────────────────────────────────
    SELECT
        DATEPART(HOUR, ISNULL(o.BookingDate, o.OrderDate)) AS HourOfDay,
        COUNT(1)                                           AS OrderCount,
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0)                      AS Amount
    FROM dbo.LabOrder o
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY DATEPART(HOUR, ISNULL(o.BookingDate, o.OrderDate))
    ORDER BY HourOfDay;

    -- ─────────────────────────────────────────────────────────────
    -- 9. Department workload
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 8
        ISNULL(d.DeptName, 'Unassigned')                           AS DepartmentName,
        COUNT(1)                                                   AS TestCount,
        SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS CollectedCount,
        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END)    AS ApprovedCount
    FROM dbo.LabOrder o
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.DepartmentMaster d ON d.DeptId = COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND ISNULL(o.IsB2B, 0) = 1) OR (@ClientType = 'B2C' AND ISNULL(o.IsB2B, 0) = 0))
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY ISNULL(d.DeptName, 'Unassigned')
    ORDER BY TestCount DESC;

    -- ─────────────────────────────────────────────────────────────
    -- 10. Top B2B clients (franchise / company)
    -- ─────────────────────────────────────────────────────────────
    SELECT TOP 6
        CASE o.AgentType WHEN 'F' THEN 'FRANCHISE' ELSE 'COMPANY' END                  AS ClientType,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END AS ClientName,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END AS ClientCode,
        COUNT(1)                                                                       AS OrderCount,
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0)                                                  AS Amount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.BranchId = @BranchId
      AND ISNULL(o.IsB2B, 0) = 1
      AND @ClientType <> 'B2C'
      AND CAST(ISNULL(o.BookingDate, o.OrderDate) AS DATE) = @Date
      AND o.IsActive = 1
    GROUP BY o.AgentType,
             CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END,
             CASE WHEN o.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END
    ORDER BY OrderCount DESC, Amount DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @IsB2B BIT = NULL,
    -- which date the From / To range applies to: 'B' = booking date (falls back to the order date), 'C' = bill /
    -- created date; NULL = the order date, as before (B2B list and every other caller unchanged)
    @DateType CHAR(1) = NULL,
    -- 2233: payment / cancellation filter of the order list: NULL = all; DUE = nothing received yet; PARTIAL = part
    -- received; PAID = fully covered; PCAN = some tests cancelled; FCAN = the whole bill cancelled
    @PaymentFilter VARCHAR(10) = NULL,
    -- 2234: B2B order list - partner type ('F' franchise / 'C' company) and one partner of that type; NULL = all
    @AgentType VARCHAR(5) = NULL,
    @AgentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 1
            ELSE 0
        END), 0) AS PaidCount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) < ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ISNULL(ph.PaymentStatus, 'U') <> 'P' THEN 1
            ELSE 0
        END), 0) AS UnpaidCount,
        ISNULL(SUM(CASE WHEN o.IsB2B = 1 THEN ISNULL(o.B2BTotal, 0.00) ELSE 0.00 END), 0.00) AS B2BTotalAmount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
      AND CAST(CASE @DateType WHEN 'B' THEN ISNULL(o.BookingDate, o.OrderDate) WHEN 'C' THEN o.CreatedDate ELSE o.OrderDate END AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
      AND (@AgentType IS NULL OR o.AgentType = @AgentType)
      AND (@AgentId IS NULL OR o.B2BAgentID = @AgentId)
      AND (@PaymentFilter IS NULL
           OR (@PaymentFilter = 'FCAN' AND ISNULL(o.IsActive, 0) = 0)
           OR (@PaymentFilter = 'PCAN' AND ISNULL(o.IsActive, 0) = 1
               AND EXISTS (SELECT 1 FROM dbo.LabOrderItem xi WHERE xi.LabOrderId = o.LabOrderId AND ISNULL(xi.IsActive, 0) = 0))
           OR (@PaymentFilter IN ('DUE', 'PARTIAL', 'PAID') AND ISNULL(o.IsActive, 0) = 1
               AND (CASE WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                         WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                         WHEN o.IsB2B = 1 THEN 'U'
                         ELSE ISNULL(ph.PaymentStatus, 'U') END)
                   = CASE @PaymentFilter WHEN 'DUE' THEN 'U' WHEN 'PARTIAL' THEN 'R' ELSE 'P' END))
      AND (
          @Search IS NULL
          OR o.BillNo LIKE '%' + @Search + '%'
          OR o.TokenNo LIKE '%' + @Search + '%'
          OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p
              WHERE p.PatientId = o.PatientId
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      );

    -- Paged Items
    WITH PagedOrders AS (
        SELECT
            o.LabOrderId,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.CollectionType,
            o.PhlebotomistId,
            o.IsUrgent,
            phleb.FullName AS PhlebotomistName,
            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            o.IsB2B,
            o.B2BAgentID,
            o.AgentType,
            o.B2BTotal,
            CASE
                WHEN o.AgentType = 'F' THEN f.Franchise_Name
                WHEN o.AgentType = 'C' THEN corp.Corporate_Name
                ELSE NULL
            END AS AgentName,
            CASE
                WHEN o.AgentType = 'F' THEN f.Franchise_Code
                WHEN o.AgentType = 'C' THEN corp.Corporate_Code
                ELSE NULL
            END AS AgentCode,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL
            END AS Age,
            ph.PaymentHeaderId,
            CASE
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                WHEN o.IsB2B = 1 THEN 'U'
                ELSE ISNULL(ph.PaymentStatus, 'U')
            END AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            CASE
                WHEN o.IsB2B = 1 THEN
                    CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00
                         ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
                ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
            END AS BalanceDue,
            ISNULL(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
            u.Username AS CreatedByUsername,
            (
                SELECT COUNT(1)
                FROM dbo.LabOrderItem loi
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS ItemCount,
            (
                SELECT STRING_AGG(
                    CASE
                        WHEN loi.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Package #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                        ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    END, ', ')
                FROM dbo.LabOrderItem loi
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
                LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS TestNamesSummary,
            -- Tests already signed off (ReportStatusId = 5 "Report Approve"); >0 means the report can be
            -- printed even if not every test on the order is approved yet (partial approval allowed).
            (
                SELECT COUNT(1)
                FROM dbo.SampleCollection sc
                INNER JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                WHERE sc.Laborderid = o.LabOrderId AND led.ReportStatusId = 5
            ) AS ApprovedTestCount,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
        WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
          AND CAST(CASE @DateType WHEN 'B' THEN ISNULL(o.BookingDate, o.OrderDate) WHEN 'C' THEN o.CreatedDate ELSE o.OrderDate END AS DATE) BETWEEN @FromDate AND @ToDate
          AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
      AND (@AgentType IS NULL OR o.AgentType = @AgentType)
      AND (@AgentId IS NULL OR o.B2BAgentID = @AgentId)
      AND (@PaymentFilter IS NULL
           OR (@PaymentFilter = 'FCAN' AND ISNULL(o.IsActive, 0) = 0)
           OR (@PaymentFilter = 'PCAN' AND ISNULL(o.IsActive, 0) = 1
               AND EXISTS (SELECT 1 FROM dbo.LabOrderItem xi WHERE xi.LabOrderId = o.LabOrderId AND ISNULL(xi.IsActive, 0) = 0))
           OR (@PaymentFilter IN ('DUE', 'PARTIAL', 'PAID') AND ISNULL(o.IsActive, 0) = 1
               AND (CASE WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                         WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                         WHEN o.IsB2B = 1 THEN 'U'
                         ELSE ISNULL(ph.PaymentStatus, 'U') END)
                   = CASE @PaymentFilter WHEN 'DUE' THEN 'U' WHEN 'PARTIAL' THEN 'R' ELSE 'P' END))
          AND (
              @Search IS NULL
              OR o.BillNo LIKE '%' + @Search + '%'
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p
              WHERE p.PatientId = o.PatientId
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      )
    )
    SELECT
        LabOrderId,
        PatientId,
        BranchId,
        OrderDate,
        BillNo,
        TokenNo,
        TotalAmount,
        CollectionType,
        PhlebotomistId,
        IsUrgent,
        PhlebotomistName,
        BookingDate,
        IsActive,
        CreatedDate,
        CreatedBy,
        IsB2B,
        B2BAgentID,
        AgentType,
        B2BTotal,
        AgentName,
        AgentCode,
        PatientCode,
        PatientName,
        PhoneNumber,
        Gender,
        Age,
        PaymentHeaderId,
        PaymentStatus,
        TotalPaid,
        BalanceDue,
        CreatedByName,
        CreatedByUsername,
        ItemCount,
        TestNamesSummary,
        ApprovedTestCount,
        TotalCount
    FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY LabOrderId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_B2B_GetInvoiceDetail
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Result Set 1: Invoice Header ──────────────────────────────────────────
    SELECT 
        inv.InvoiceId,
        inv.InvoiceNo,
        inv.PartnerType,
        inv.PartnerId,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Name 
            WHEN 'C' THEN corp.Corporate_Name 
            ELSE 'Unknown' 
        END AS PartnerName,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Franchise_Code 
            WHEN 'C' THEN corp.Corporate_Code 
            ELSE '' 
        END AS PartnerCode,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Mobile_No 
            WHEN 'C' THEN corp.Contact_No 
            ELSE '' 
        END AS PartnerPhone,
        CASE inv.PartnerType 
            WHEN 'F' THEN f.Email 
            WHEN 'C' THEN corp.Email 
            ELSE '' 
        END AS PartnerEmail,
        CASE inv.PartnerType 
            WHEN 'F' THEN '' 
            WHEN 'C' THEN corp.Address 
            ELSE '' 
        END AS PartnerAddress,
        inv.BranchId,
        b.BranchName,
        b.BranchCode,
        inv.BillingCycle,
        inv.InvoiceDate,
        inv.DueDate,
        inv.TotalAmount,
        inv.DiscountAmount,
        inv.TaxAmount,
        inv.NetAmount,
        CASE WHEN inv.PaidAmount > inv.NetAmount THEN inv.NetAmount ELSE inv.PaidAmount END AS PaidAmount,
        CASE WHEN inv.BalanceAmount < 0 THEN 0.00 ELSE inv.BalanceAmount END AS BalanceAmount,
        inv.Status,
        inv.Notes,
        inv.CreatedDate,
        u.FullName AS CreatedByName
    FROM dbo.B2BInvoice inv
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = inv.PartnerId AND inv.PartnerType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = inv.PartnerId AND inv.PartnerType = 'C'
    LEFT JOIN dbo.Branchmaster b ON b.BranchId = inv.BranchId
    LEFT JOIN dbo.UserMaster u ON u.Id = inv.CreatedBy
    WHERE inv.InvoiceId = @InvoiceId;

    -- ── Result Set 2: Order-level Items ───────────────────────────────────────
    SELECT 
        bii.InvoiceItemId,
        bii.InvoiceId,
        bii.LabOrderId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        p.PhoneNumber AS PatientPhone,
        bii.B2BTotal,
        bii.Amount,
        STUFF((
            SELECT ', ' + CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Profile') ELSE ISNULL(sm.Test_Name, 'Test') END
            FROM dbo.LabOrderItem si
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
            WHERE si.LabOrderId = bii.LabOrderId AND si.IsActive = 1
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS TestNames
    FROM dbo.B2BInvoiceItem bii
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE bii.InvoiceId = @InvoiceId
    ORDER BY bii.OrderDate ASC, bii.LabOrderId ASC;

    -- ── Result Set 3: Test-level Line Items with B2B Rates ───────────────────
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        bii.InvoiceId,
        bii.BillNo,
        bii.OrderDate,
        bii.PatientName,
        p.PatientCode,
        loi.InvestigationId,
        ISNULL(loi.Type, 'I') AS ItemType,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END AS TestName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE ISNULL(dm.DeptName, 'Pathology') END AS DepartmentName,
        loi.Price AS MrpRate,
        ISNULL(NULLIF(loi.B2BRate, 0.00), loi.Price) AS B2BRate,
        0 AS LineSort
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = loi.LabOrderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    WHERE bii.InvoiceId = @InvoiceId AND loi.IsActive = 1
    -- 2240: misc charges of the invoiced bills, at what the partner is charged (amount + GST)
    UNION ALL
    SELECT -m.LabOrderMiscChargeId, m.LabOrderId, bii.InvoiceId, bii.BillNo, bii.OrderDate, bii.PatientName, p.PatientCode,
           0, 'M',
           CASE WHEN m.ChargeType = 'Home Collection' THEN 'HOME-COLL' ELSE 'MISC' END,
           m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END
               + CASE WHEN m.IsGstRequired = 1 THEN ' (incl. GST ' + FORMAT(m.GstPercentage, '0.##') + '%)' ELSE '' END,
           'Misc Charge', m.Amount + m.GstAmount, m.Amount + m.GstAmount, 1
    FROM dbo.LabOrderMiscCharge m
    INNER JOIN dbo.B2BInvoiceItem bii ON bii.LabOrderId = m.LabOrderId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bii.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE bii.InvoiceId = @InvoiceId AND m.IsActive = 1
    ORDER BY OrderDate ASC, LabOrderId ASC, LineSort ASC, LabOrderItemId ASC;
END;
GO

PRINT 'Script 2240 part 5 applied: misc charges in gross / dashboard / invoice detail.';
GO
