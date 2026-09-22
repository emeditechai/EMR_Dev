-- ============================================================================
-- Migration: 2124_lab_reports_billing_dues_patient_cancellation.sql
-- Description:
--   Reports > LAB (LAB Reports Roadmap):
--     LR-02  Daily Billing Register            dbo.usp_Api_LabReport_BillingRegister
--     LR-04  Outstanding Dues & Ageing (B2C)   dbo.usp_Api_LabReport_OutstandingDues
--     LR-29  Patient-wise Lab Order Report     dbo.usp_Api_LabReport_PatientOrders
--     LR-06  Cancellation & Refund Register    dbo.usp_Api_LabReport_CancellationRefund
--
--   Every report returns the same four result sets, read by one API endpoint and one page script:
--     RS1  summary   one row of totals
--     RS2  groups    GroupKey, GroupId, GroupName, SortOrder + the report's measures (one block per "Group by")
--     RS3  rows      one row per record (bill / order / cancellation)
--     RS4  options   FilterKey, Value, Text - filter lists built from the data (e.g. users)
--
--   Due amounts are worked out as net - paid (never below 0): the stored PaymentHeader.BalanceDue is not always
--   updated after a cancellation, so it is not used here.
--
--   Data visibility (roadmap rule, enforced here):
--     * Branch: only @BranchId, and the user must be mapped to it (dbo.usp_LabReport_CheckAccess); super admin exempt
--     * Administrator (@IsAdmin) / super admin: every user's data of the branch
--     * anyone else: only their own records (defined per report below)
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Shared branch / user check for the LAB reports.
CREATE OR ALTER PROCEDURE dbo.usp_LabReport_CheckAccess
    @BranchId     INT,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@BranchId, 0) <= 0
        THROW 50010, 'A branch is required for this report.', 1;
    IF ISNULL(@IsSuperAdmin, 0) = 1 RETURN;
    IF ISNULL(@UserId, 0) <= 0
        THROW 50010, 'The signed-in user could not be identified.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub
                    WHERE ub.UserId = @UserId AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
        THROW 50011, 'You do not have access to this branch''s reports.', 1;
END;
GO

-- ============================================================================
-- LR-02 Daily Billing Register - LAB bills raised in the period (bill date).
-- Own data: bills the user created.
-- ============================================================================
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
        NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '') AS ReferralDoctor,
        items.TestCount, items.TestNames,
        CAST(lo.TotalAmount AS DECIMAL(18, 2)) AS GrossAmount,
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

-- ============================================================================
-- LR-04 Outstanding Dues & Ageing - B2C LAB bills that still have a balance (bill date in the period).
-- Age = days since the bill; buckets 0-2 / 3-7 / 8-30 / 30+ days. Own data: bills the user created.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_OutstandingDues
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @AgeBucket     VARCHAR(10)   = NULL,   -- 0-2 / 3-7 / 8-30 / 30+
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
    SET @AgeBucket = NULLIF(LTRIM(RTRIM(@AgeBucket)), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        DATEDIFF(DAY, lo.OrderDate, GETDATE()) AS AgeDays,
        CASE WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 2 THEN '0-2'
             WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 7 THEN '3-7'
             WHEN DATEDIFF(DAY, lo.OrderDate, GETDATE()) <= 30 THEN '8-30'
             ELSE '30+' END AS AgeBucket,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        CAST(ISNULL(ph.NetAmount, lo.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        -- due = net - paid (the stored BalanceDue is not always updated after a cancellation)
        CAST(ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS DueAmount,
        pay.LastPaymentDate,
        rep.TotalTests, rep.ApprovedTests,
        CAST(CASE WHEN rep.ApprovedTests > 0 THEN 1 ELSE 0 END AS BIT) AS ReportHeld,   -- approved result waiting on the due
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    OUTER APPLY (SELECT MAX(pd.PaymentDate) AS LastPaymentDate FROM dbo.PaymentDetail pd
                  WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1) pay
    OUTER APPLY (SELECT COUNT(1) AS TotalTests,
                        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END) AS ApprovedTests
                   FROM dbo.SampleCollection sc
                   LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                  WHERE sc.Laborderid = lo.LabOrderId AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0) rep
    WHERE lo.BranchId = @BranchId
      AND lo.IsActive = 1
      AND ISNULL(lo.IsB2B, 0) = 0
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) > 0
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @AgeBucket IS NOT NULL DELETE FROM #R WHERE AgeBucket <> @AgeBucket;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PatientId) AS PatientCount,
           ISNULL(SUM(DueAmount), 0) AS DueAmount, ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount,
           ISNULL(SUM(CASE WHEN AgeBucket = '0-2'  THEN DueAmount END), 0) AS Due0to2,
           ISNULL(SUM(CASE WHEN AgeBucket = '3-7'  THEN DueAmount END), 0) AS Due3to7,
           ISNULL(SUM(CASE WHEN AgeBucket = '8-30' THEN DueAmount END), 0) AS Due8to30,
           ISNULL(SUM(CASE WHEN AgeBucket = '30+'  THEN DueAmount END), 0) AS Due30Plus,
           SUM(CASE WHEN ReportHeld = 1 THEN 1 ELSE 0 END) AS ReportsHeld,
           ISNULL(MAX(AgeDays), 0) AS OldestDays
    FROM #R;

    -- RS2 groups
    SELECT 'byAgeBucket' AS GroupKey, NULL AS GroupId, AgeBucket AS GroupName,
           CASE AgeBucket WHEN '0-2' THEN 1 WHEN '3-7' THEN 2 WHEN '8-30' THEN 3 ELSE 4 END AS SortOrder,
           COUNT(1) AS BillCount, SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount, MAX(AgeDays) AS OldestDays
    FROM #R GROUP BY AgeBucket
    UNION ALL
    SELECT 'byPatient', PatientId, PatientName + ' (' + ISNULL(PatientCode, '') + ')', 0,
           COUNT(1), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(AgeDays)
    FROM #R GROUP BY PatientId, PatientName, PatientCode
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(AgeDays)
    FROM #R GROUP BY CreatedById, CreatedBy
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(AgeDays)
    FROM #R GROUP BY BillDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows (oldest first: that is what gets followed up)
    SELECT * FROM #R ORDER BY AgeDays DESC, DueAmount DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- LR-29 Patient-wise Lab Order Report - every LAB order in the period (bill date) with its tests,
-- report progress and payment. Summary per patient; detail per order. Own data: orders the user created.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PatientOrders
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @ReportStatus  VARCHAR(10)   = NULL,   -- APPROVED / PARTIAL / INPROGRESS / PENDING / CANCELLED
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
    SET @ReportStatus = NULLIF(UPPER(LTRIM(RTRIM(@ReportStatus))), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber, p.Gender,
        NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '') AS ReferralDoctor,
        items.TestNames,
        ISNULL(rep.TotalTests, 0) AS TestCount,
        ISNULL(rep.ApprovedTests, 0) AS ApprovedTests,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(rep.TotalTests, 0) > 0 AND rep.ApprovedTests = rep.TotalTests THEN 'APPROVED'
             WHEN ISNULL(rep.ApprovedTests, 0) > 0 THEN 'PARTIAL'
             WHEN ISNULL(rep.EnteredTests, 0) > 0 THEN 'INPROGRESS'
             ELSE 'PENDING' END AS ReportStatus,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN lo.IsActive = 0 THEN 0
                  WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END
                  ELSE CASE WHEN ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END END AS DECIMAL(18, 2)) AS DueAmount,
        ISNULL(prn.PrintCount, 0) AS PrintCount,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportEmailLog el WHERE el.LabOrderId = lo.LabOrderId AND el.Status = 'Sent') THEN 1 ELSE 0 END AS BIT) AS Emailed,
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    OUTER APPLY (SELECT STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT COUNT(1) AS TotalTests,
                        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END) AS ApprovedTests,
                        SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END) AS EnteredTests
                   FROM dbo.SampleCollection sc
                   LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                  WHERE sc.Laborderid = lo.LabOrderId AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
                    AND ISNULL(sc.IsoutSource, 0) = 0 AND sc.CollectionstatusID <> 4) rep
    OUTER APPLY (SELECT COUNT(1) AS PrintCount FROM dbo.AuditLogs a
                  WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportPrinted' AND a.ReferenceId = lo.LabOrderId) prn
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @ReportStatus IS NOT NULL DELETE FROM #R WHERE ReportStatus <> @ReportStatus;

    -- RS1 summary
    SELECT COUNT(DISTINCT PatientId) AS PatientCount, COUNT(1) AS OrderCount,
           ISNULL(SUM(TestCount), 0) AS TestCount, ISNULL(SUM(ApprovedTests), 0) AS ApprovedTests,
           SUM(CASE WHEN ReportStatus = 'APPROVED' THEN 1 ELSE 0 END) AS OrdersApproved,
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END) AS OrdersOpen,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount
    FROM #R;

    -- RS2 groups
    SELECT 'byPatient' AS GroupKey, PatientId AS GroupId, PatientName + ' (' + ISNULL(PatientCode, '') + ')' AS GroupName, 0 AS SortOrder,
           COUNT(1) AS OrderCount, SUM(TestCount) AS TestCount, SUM(ApprovedTests) AS ApprovedTests,
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END) AS OpenOrders,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount, MAX(BillDate) AS LastVisit
    FROM #R GROUP BY PatientId, PatientName, PatientCode
    UNION ALL
    SELECT 'byReportStatus', NULL, ReportStatus,
           CASE ReportStatus WHEN 'PENDING' THEN 1 WHEN 'INPROGRESS' THEN 2 WHEN 'PARTIAL' THEN 3 WHEN 'APPROVED' THEN 4 ELSE 5 END,
           COUNT(1), SUM(TestCount), SUM(ApprovedTests),
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END),
           SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(BillDate)
    FROM #R GROUP BY ReportStatus
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), SUM(TestCount), SUM(ApprovedTests),
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END),
           SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(BillDate)
    FROM #R GROUP BY BillDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY PatientName, BillDate DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- LR-06 Cancellation & Refund Register - LAB cancellations in the period (cancellation date) with the refund
-- made against each. Pending refund = what was paid on the cancelled part and not yet refunded.
-- Own data: cancellations the user made, or refunds the user processed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CancellationRefund
    @BranchId         INT,
    @FromDate         DATE,
    @ToDate           DATE,
    @CancellationType CHAR(1)       = NULL,   -- F / P
    @RefundStatus     VARCHAR(10)   = NULL,   -- REFUNDED / PENDING / NOTDUE
    @CancelledBy      INT           = NULL,
    @Search           NVARCHAR(100) = NULL,
    @UserId           INT           = NULL,
    @IsAdmin          BIT           = 0,
    @IsSuperAdmin     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @RefundStatus = NULLIF(UPPER(LTRIM(RTRIM(@RefundStatus))), '');
    SET @CancellationType = NULLIF(UPPER(LTRIM(RTRIM(@CancellationType))), '');

    SELECT
        bc.CancellationId, bc.CancellationNo, bc.CancellationDate,
        CONVERT(VARCHAR(10), CAST(bc.CancellationDate AS DATE), 23) AS CancellationDay,
        CASE bc.CancellationType WHEN 'F' THEN 'Full' ELSE 'Partial' END AS CancellationType,
        lo.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        itm.ItemCount, itm.ItemNames,
        CAST(bc.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS DiscountAdjusted,
        CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidOnBill,
        CAST(ISNULL(rf.RefundedAmount, 0) AS DECIMAL(18, 2)) AS RefundedAmount,
        rf.RefundModes, rf.LastRefundDate, rf.RefundedBy,
        CAST(CASE WHEN (CASE WHEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) < ISNULL(ph.TotalPaid, 0)
                             THEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) ELSE ISNULL(ph.TotalPaid, 0) END) - ISNULL(rf.RefundedAmount, 0) > 0
                  THEN (CASE WHEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) < ISNULL(ph.TotalPaid, 0)
                             THEN bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) ELSE ISNULL(ph.TotalPaid, 0) END) - ISNULL(rf.RefundedAmount, 0)
                  ELSE 0 END AS DECIMAL(18, 2)) AS PendingRefund,
        NULLIF(LTRIM(RTRIM(bc.Reason)), '') AS Reason,
        bc.CreatedBy AS CancelledById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CancelledBy,
        rf.RefundUserIds
    INTO #R
    FROM dbo.BillCancellation bc
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = bc.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = bc.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS ItemCount,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS ItemNames
                   FROM dbo.BillCancellationItem bci
                   INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = bci.LineRefId
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE bci.CancellationId = bc.CancellationId AND bci.IsActive = 1) itm
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS RefundedAmount,
                        STRING_AGG(CAST(r.RefundMode AS NVARCHAR(MAX)), ', ') AS RefundModes,
                        MAX(r.RefundDate) AS LastRefundDate,
                        STRING_AGG(CAST(ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS NVARCHAR(MAX)), ', ') AS RefundedBy,
                        ',' + STRING_AGG(CAST(r.CreatedBy AS VARCHAR(MAX)), ',') + ',' AS RefundUserIds
                   FROM dbo.BillRefund r
                   LEFT JOIN dbo.Users ru ON ru.Id = r.CreatedBy
                  WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1) rf
    WHERE bc.ModuleCode = 'LAB'
      AND bc.IsActive = 1
      AND lo.BranchId = @BranchId
      AND bc.CancellationDate >= @From AND bc.CancellationDate < @To
      AND (@CancellationType IS NULL OR bc.CancellationType = @CancellationType)
      AND (@CancelledBy IS NULL OR bc.CreatedBy = @CancelledBy)
      AND (@Search IS NULL OR bc.CancellationNo LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR bc.Reason LIKE '%' + @Search + '%');

    -- own data: cancellations they made, or refunds they processed
    IF @OwnOnly = 1
        DELETE FROM #R WHERE ISNULL(CancelledById, 0) <> @UserId
                         AND ISNULL(RefundUserIds, '') NOT LIKE '%,' + CAST(@UserId AS VARCHAR(20)) + ',%';
    IF @RefundStatus = 'REFUNDED' DELETE FROM #R WHERE NOT (RefundedAmount > 0 AND PendingRefund = 0);
    IF @RefundStatus = 'PENDING'  DELETE FROM #R WHERE PendingRefund <= 0;
    IF @RefundStatus = 'NOTDUE'   DELETE FROM #R WHERE NOT (RefundedAmount = 0 AND PendingRefund = 0);

    -- RS1 summary
    SELECT COUNT(1) AS CancellationCount,
           SUM(CASE WHEN CancellationType = 'Full' THEN 1 ELSE 0 END) AS FullCount,
           SUM(CASE WHEN CancellationType = 'Partial' THEN 1 ELSE 0 END) AS PartialCount,
           COUNT(DISTINCT LabOrderId) AS BillCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetCancelled), 0) AS NetCancelled,
           ISNULL(SUM(RefundedAmount), 0) AS RefundedAmount, ISNULL(SUM(PendingRefund), 0) AS PendingRefund,
           SUM(CASE WHEN PendingRefund > 0 THEN 1 ELSE 0 END) AS PendingRefundCount
    FROM #R;

    -- RS2 groups
    SELECT 'byReason' AS GroupKey, NULL AS GroupId, ISNULL(Reason, 'Not recorded') AS GroupName, 0 AS SortOrder,
           COUNT(1) AS CancellationCount, SUM(ItemCount) AS ItemCount, SUM(NetCancelled) AS NetCancelled,
           SUM(RefundedAmount) AS RefundedAmount, SUM(PendingRefund) AS PendingRefund
    FROM #R GROUP BY Reason
    UNION ALL
    SELECT 'byCancelledBy', CancelledById, CancelledBy, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancelledById, CancelledBy
    UNION ALL
    SELECT 'byType', NULL, CancellationType, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationType
    UNION ALL
    SELECT 'byDate', NULL, CancellationDay, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT CancellationId, CancellationNo, CancellationDate, CancellationDay, CancellationType, LabOrderId, BillNo, BillDate,
           PatientCode, PatientName, PhoneNumber, ItemCount, ItemNames, CancelledAmount, DiscountAdjusted, NetCancelled,
           PaidOnBill, RefundedAmount, RefundModes, LastRefundDate, RefundedBy, PendingRefund,
           ISNULL(Reason, 'Not recorded') AS Reason, CancelledById, CancelledBy
    FROM #R ORDER BY CancellationDate DESC, CancellationId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'cancelledBy' AS FilterKey, CAST(CancelledById AS VARCHAR(20)) AS Value, CancelledBy AS Text FROM #R WHERE CancelledById IS NOT NULL;

    DROP TABLE #R;
END;
GO

PRINT 'LAB reports LR-02, LR-04, LR-29, LR-06 ready.';
GO
