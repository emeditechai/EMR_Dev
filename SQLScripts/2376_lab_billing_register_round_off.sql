-- ============================================================================================================
-- Migration: 2376_lab_billing_register_round_off.sql
-- Reports > LAB > Daily Billing Register: the bill's round off (PaymentHeader.RoundOffAmount; 0 for B2B) as a column,
-- in the totals and in each summary group. usp_Api_LabReport_BillingRegister as in 2240_lab_misc_charges_billing_part5.sql
-- + RoundOffAmount.
-- ============================================================================================================
SET ANSI_NULLS ON;
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
        -- 2376: round off of the bill (B2C; a B2B bill is not rounded here)
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.RoundOffAmount, 0) END AS DECIMAL(18, 2)) AS RoundOffAmount,
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
           ISNULL(SUM(GrossAmount), 0) AS GrossAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount, ISNULL(SUM(RoundOffAmount), 0) AS RoundOffAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           COUNT(DISTINCT PatientId) AS PatientCount
    FROM #R;

    -- RS2 groups
    SELECT 'byDate' AS GroupKey, NULL AS GroupId, BillDay AS GroupName, 0 AS SortOrder,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount, SUM(RoundOffAmount) AS RoundOffAmount,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY CreatedById, CreatedBy
    UNION ALL
    SELECT 'byBillingType', NULL, BillingType, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillingType
    UNION ALL
    SELECT 'byPaymentStatus', NULL, PaymentStatus,
           CASE PaymentStatus WHEN 'PAID' THEN 1 WHEN 'PARTIAL' THEN 2 WHEN 'UNPAID' THEN 3 ELSE 4 END,
           COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PaymentStatus
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO
