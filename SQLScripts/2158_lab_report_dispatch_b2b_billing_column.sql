-- ============================================================================
-- Migration: 2158_lab_report_dispatch_b2b_billing_column.sql
-- Description:
--   Lab Report Dispatch page (LAB menu) - two B2B-only changes to the BILLING column and
--   the print gate, requested for B2B bills specifically; B2C is unaffected:
--
--   1. BILLING column: a B2B row shows the partner's Credit Facility Type (Prepaid (Wallet) /
--      Postpaid (Credit) / Hybrid for a Franchise, always Postpaid (Credit) for a Corporate
--      company) instead of a Paid/Due badge - the same source/mapping already used by
--      usp_LabReporting_GetPrintMeta (script 2142) and usp_B2B_GetPartnerCreditStatus.
--      Adds CreditFacilityType/CreditFacilityTypeName to dbo.usp_LabReportDispatch_GetDashboard
--      (script 2090).
--
--   2. Print gate: dbo.usp_LabReporting_GetDetail (last altered in script 2135) now also
--      returns IsB2B on RS1, so the Lab Report Dispatch print action (LabReportDispatchController.
--      PrintReportPdf) can skip the "outstanding due blocks printing" rule for B2B bills - a B2B
--      bill is settled with the franchise/company, not per-patient, so it must always be printable
--      once ready. B2C keeps the existing due-must-be-cleared rule unchanged.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. usp_LabReportDispatch_GetDashboard: add CreditFacilityType / CreditFacilityTypeName ────────

CREATE OR ALTER PROCEDURE dbo.usp_LabReportDispatch_GetDashboard
    @BranchId       INT,
    @FromDate       DATETIME      = NULL,
    @ToDate         DATETIME      = NULL,
    @DateBasis      VARCHAR(20)   = 'BillingDate',
    @Search         NVARCHAR(100) = NULL,
    @DispatchStatus VARCHAR(20)   = 'ALL',
    @ClientType     VARCHAR(10)   = 'ALL'
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    IF @ToDate   IS NULL SET @ToDate   = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    SET @DateBasis      = UPPER(LTRIM(RTRIM(ISNULL(@DateBasis, 'BILLINGDATE'))));
    SET @DispatchStatus = UPPER(LTRIM(RTRIM(ISNULL(@DispatchStatus, 'ALL'))));
    SET @ClientType     = UPPER(LTRIM(RTRIM(ISNULL(@ClientType, 'ALL'))));
    SET @Search         = NULLIF(LTRIM(RTRIM(@Search)), '');

    -- ── per-order test aggregates ───────────────────────────────────────────
    SELECT
        lo.LabOrderId,
        COUNT(sc.samplecollectionID)                                                                     AS TotalTests,
        SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END)                                       AS CollectedTests,
        SUM(CASE WHEN sc.CollectionstatusID IN (3, 4) THEN 1 ELSE 0 END)                                 AS RecollectTests,
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
                  AND led.ReportStatusId IN (1, 2, 3, 5) THEN 1 ELSE 0 END)                              AS EnteredTests,
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
                  AND led.ReportStatusId = 3 THEN 1 ELSE 0 END)                                          AS ValidatedTests,
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
                  AND led.ReportStatusId = 5 THEN 1 ELSE 0 END)                                          AS ApprovedTests,
        SUM(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
                  AND ISNULL(led.AbnormalFlag, '') = 'Critical' THEN 1 ELSE 0 END)                       AS CriticalTests,
        MAX(CASE WHEN led.ReportStatusId = 5 THEN led.Approved_Date END)                                 AS LastApprovedDate
    INTO #Agg
    FROM dbo.LabOrder lo
    INNER JOIN dbo.SampleCollection sc
            ON sc.Laborderid = lo.LabOrderId
           AND sc.Is_Active = 1
           AND sc.Iscancelled = 0
           AND ISNULL(sc.IsoutSource, 0) = 0
    LEFT JOIN dbo.labentrydetails led
           ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE lo.BranchId = @BranchId
      AND lo.IsActive = 1
    GROUP BY lo.LabOrderId;

    -- ── print log (final report printed after the last approval) ────────────
    SELECT
        lo.LabOrderId,
        COUNT(a.Id)          AS PrintCount,
        MAX(a.CreatedDate)   AS LastPrintedDate
    INTO #Prints
    FROM #Agg ag
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ag.LabOrderId
    INNER JOIN dbo.AuditLogs a ON a.ModuleCode = 'LAB'
                              AND a.ActionName = 'LAB.ReportPrinted'
                              AND a.ReferenceNo = lo.BillNo
    GROUP BY lo.LabOrderId;

    -- ── one row per bill ────────────────────────────────────────────────────
    SELECT
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        lo.OrderDate                                             AS BillingDate,
        ISNULL(lo.BookingDate, lo.OrderDate)                     AS BookingDateTime,
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END                                                 AS Age,
        p.Gender,
        p.PhoneNumber,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END         AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE lo.AgentType WHEN 'F' THEN 'FRANCHISE' ELSE 'COMPANY' END END AS ClientType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END END AS ClientCode,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName,
        ISNULL(ph.PaymentStatus, 'U')                            AS PaymentStatus,
        ISNULL(ph.BalanceDue, lo.TotalAmount)                    AS BalanceDue,
        lo.TotalAmount,
        CASE WHEN lo.IsB2B = 1 AND lo.AgentType = 'F' THEN ISNULL(fc.Credit_Facility_Type, 1)
             WHEN lo.IsB2B = 1 AND lo.AgentType = 'C' THEN 2 END AS CreditFacilityType,
        CASE WHEN lo.IsB2B = 1 AND lo.AgentType = 'F' THEN
                 CASE ISNULL(fc.Credit_Facility_Type, 1)
                     WHEN 1 THEN 'Prepaid (Wallet)'
                     WHEN 2 THEN 'Postpaid (Credit)'
                     WHEN 3 THEN 'Hybrid'
                     ELSE 'Prepaid (Wallet)'
                 END
             WHEN lo.IsB2B = 1 AND lo.AgentType = 'C' THEN 'Postpaid (Credit)'
        END AS CreditFacilityTypeName,
        ag.TotalTests, ag.CollectedTests, ag.RecollectTests,
        ag.EnteredTests, ag.ValidatedTests, ag.ApprovedTests, ag.CriticalTests,
        ag.LastApprovedDate                                      AS ApprovedDate,
        CASE
            WHEN ag.TotalTests > 0 AND ag.ApprovedTests = ag.TotalTests THEN 'READY'
            WHEN ag.ApprovedTests > 0                                    THEN 'PARTIAL'
            WHEN ag.ValidatedTests > 0                                   THEN 'AWAITING'
            WHEN ag.EnteredTests > 0                                     THEN 'INPROGRESS'
            ELSE 'NOTSTARTED'
        END                                                      AS DispatchStatus,
        CAST(CASE WHEN ag.ValidatedTests + ag.ApprovedTests > 0 THEN 1 ELSE 0 END AS BIT) AS CanPrint,
        ISNULL(pr.PrintCount, 0)                                 AS PrintCount,
        pr.LastPrintedDate,
        CAST(CASE WHEN ag.TotalTests > 0 AND ag.ApprovedTests = ag.TotalTests
                   AND pr.LastPrintedDate IS NOT NULL AND pr.LastPrintedDate >= ag.LastApprovedDate
                  THEN 1 ELSE 0 END AS BIT)                      AS PrintedAfterApproval,
        CASE WHEN ag.TotalTests > 0 AND ag.ApprovedTests = ag.TotalTests AND ag.LastApprovedDate IS NOT NULL
             THEN DATEDIFF(MINUTE, ISNULL(lo.BookingDate, lo.OrderDate), ag.LastApprovedDate) END AS TatMinutes
    INTO #Bills
    FROM #Agg ag
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = ag.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId   = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    LEFT  JOIN dbo.LabFranchiseCreditLimitMaster fc ON fc.Franchise_ID = f.Franchise_ID AND lo.AgentType = 'F'
    LEFT  JOIN #Prints pr ON pr.LabOrderId = lo.LabOrderId
    WHERE (
            (@DateBasis <> 'APPROVEDDATE' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)
         OR (@DateBasis  = 'APPROVEDDATE' AND ag.LastApprovedDate BETWEEN @FromDate AND @ToDate)
          )
      AND (@ClientType = 'ALL' OR (@ClientType = 'B2B' AND lo.IsB2B = 1) OR (@ClientType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (
            @Search IS NULL
         OR lo.BillNo      LIKE '%' + @Search + '%'
         OR lo.TokenNo     LIKE '%' + @Search + '%'
         OR p.PatientCode  LIKE '%' + @Search + '%'
         OR p.PhoneNumber  LIKE '%' + @Search + '%'
         OR p.FirstName    LIKE '%' + @Search + '%'
         OR p.LastName     LIKE '%' + @Search + '%'
         OR (ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, '')) LIKE '%' + @Search + '%'
         OR f.Franchise_Name  LIKE '%' + @Search + '%' OR f.Franchise_Code  LIKE '%' + @Search + '%'
         OR corp.Corporate_Name LIKE '%' + @Search + '%' OR corp.Corporate_Code LIKE '%' + @Search + '%'
          );

    -- ── RS1: summary cards ──────────────────────────────────────────────────
    SELECT
        COUNT(1)                                                                                   AS TotalBills,
        ISNULL(SUM(CASE WHEN DispatchStatus = 'READY'      THEN 1 ELSE 0 END), 0)                             AS ReadyBills,
        ISNULL(SUM(CASE WHEN DispatchStatus = 'PARTIAL'    THEN 1 ELSE 0 END), 0)                             AS PartialBills,
        ISNULL(SUM(CASE WHEN DispatchStatus = 'AWAITING'   THEN 1 ELSE 0 END), 0)                             AS AwaitingBills,
        ISNULL(SUM(CASE WHEN DispatchStatus IN ('INPROGRESS', 'NOTSTARTED') THEN 1 ELSE 0 END), 0)            AS InProgressBills,
        ISNULL(SUM(CASE WHEN PrintedAfterApproval = 1      THEN 1 ELSE 0 END), 0)                             AS PrintedBills,
        ISNULL(SUM(CASE WHEN DispatchStatus = 'READY' AND PrintedAfterApproval = 0 THEN 1 ELSE 0 END), 0)     AS NotPrintedBills,
        ISNULL(SUM(CASE WHEN DispatchStatus = 'READY' AND PrintedAfterApproval = 0 AND BalanceDue > 0 THEN 1 ELSE 0 END), 0) AS ReadyPaymentDueBills,
        ISNULL(SUM(CASE WHEN IsUrgent = 1 AND DispatchStatus <> 'READY' THEN 1 ELSE 0 END), 0)                AS UrgentPendingBills,
        ISNULL(SUM(CASE WHEN CriticalTests > 0 THEN 1 ELSE 0 END), 0)                                         AS CriticalBills,
        ISNULL(SUM(CASE WHEN BillingType = 'B2B' THEN 1 ELSE 0 END), 0)                                       AS B2BBills,
        ISNULL(SUM(CASE WHEN BillingType = 'B2C' THEN 1 ELSE 0 END), 0)                                       AS B2CBills,
        ISNULL(SUM(ISNULL(TotalTests, 0)), 0)                                                                 AS TotalTests,
        ISNULL(SUM(ISNULL(ApprovedTests, 0)), 0)                                                              AS ApprovedTests,
        ISNULL(SUM(ISNULL(ValidatedTests, 0)), 0)                                                             AS ValidatedTests,
        CAST(AVG(CASE WHEN TatMinutes IS NOT NULL AND TatMinutes >= 0 THEN TatMinutes * 1.0 END) AS DECIMAL(12,1)) AS AvgTatMinutes
    FROM #Bills;

    -- ── RS2: the bill list ──────────────────────────────────────────────────
    SELECT *
    FROM #Bills
    WHERE @DispatchStatus = 'ALL'
       OR (@DispatchStatus IN ('READY', 'PARTIAL', 'AWAITING') AND DispatchStatus = @DispatchStatus)
       OR (@DispatchStatus = 'INPROGRESS' AND DispatchStatus IN ('INPROGRESS', 'NOTSTARTED'))
       OR (@DispatchStatus = 'NOTSTARTED' AND DispatchStatus = 'NOTSTARTED')
       OR (@DispatchStatus = 'PRINTED'    AND PrintedAfterApproval = 1)
       OR (@DispatchStatus = 'NOTPRINTED' AND DispatchStatus = 'READY' AND PrintedAfterApproval = 0)
    ORDER BY
        IsUrgent DESC,
        CASE WHEN @DateBasis = 'APPROVEDDATE' THEN ApprovedDate ELSE BillingDate END DESC,
        LabOrderId DESC;

    DROP TABLE #Bills;
    DROP TABLE #Prints;
    DROP TABLE #Agg;
END;
GO

GO

PRINT 'Updated dbo.usp_LabReportDispatch_GetDashboard to also return CreditFacilityType/CreditFacilityTypeName.';
GO

-- 2. usp_LabReporting_GetDetail: add IsB2B to RS1 (Order/Patient Header) ─────────────────────

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId    INT,
    @BranchId      INT = NULL,     -- NULL = every sample of the order; otherwise only this branch's samples
    @ReportingType NVARCHAR(50) = 'Numeric' -- NULL = all; 'Numeric' = only Numeric; 'Image' = only Image
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;
    DECLARE @IsReceived BIT = 0;
    DECLARE @ReceivedDate DATETIME = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks,
        @IsReceived = ISNULL(sc.IsReceived, 0),
        @ReceivedDate = sc.ReceivedDate
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1
      AND (@BranchId IS NULL
           OR (sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1));

    -- Patient Demographic variables for reference range and delta check matching
    DECLARE @PatientId INT = NULL;
    DECLARE @PatientGender VARCHAR(20) = NULL;
    DECLARE @PatientAge DECIMAL(6,2) = NULL;
    DECLARE @CompanyId INT = 1;

    SELECT 
        @PatientId = lo.PatientId,
        @PatientGender = p.Gender,
        @CompanyId = ISNULL(bm.CompanyId, 1),
        @PatientAge = CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    WHERE lo.LabOrderId = @LabOrderId;

    -- Compute Overall Order Status based on entered test results / template html
    DECLARE @OverallStatusId INT = 0;
    DECLARE @OverallStatusCode VARCHAR(30) = 'PENDING';
    DECLARE @OverallStatusName NVARCHAR(100) = 'Pending Entry';
    DECLARE @OverallBadgeClass NVARCHAR(200) = 'bg-secondary-subtle text-secondary border border-secondary-subtle';
    DECLARE @DraftedDate DATETIME = NULL;
    DECLARE @SubmittedDate DATETIME = NULL;
    DECLARE @ValidatedDate DATETIME = NULL;
    DECLARE @ApprovedDate DATETIME = NULL;

    DECLARE @TotalItems INT = 0;
    DECLARE @FilledItems INT = 0;
    DECLARE @MinStatusId INT = 0;
    DECLARE @MaxStatusId INT = 0;

    SELECT 
        @TotalItems = COUNT(*),
        @FilledItems = COUNT(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)));

    IF @FilledItems > 0
    BEGIN
        SET @OverallStatusId = @MaxStatusId;
    END
    ELSE
    BEGIN
        SET @OverallStatusId = 0; -- Pending Entry
    END

    IF @OverallStatusId > 0
    BEGIN
        SELECT 
            @OverallStatusCode = StatusCode,
            @OverallStatusName = StatusName,
            @OverallBadgeClass = BadgeClass
        FROM dbo.Reportentrystatus
        WHERE ReportStatusId = @OverallStatusId;
    END

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        @PatientAge AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(lo.RefDoctorId, lo.ReferralDoctorId) AS ReferralDoctorId,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctorName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks,
        ISNULL(@IsReceived, 0) AS IsReceived,
        @ReceivedDate AS ReceivedDate,
        -- Overall Report Status Information
        @OverallStatusId AS ReportStatusId,
        @OverallStatusCode AS StatusCode,
        @OverallStatusName AS ReportStatusName,
        @OverallBadgeClass AS ReportBadgeClass,
        @DraftedDate AS DraftedDate,
        @SubmittedDate AS SubmittedDate,
        @ValidatedDate AS ValidatedDate,
        @ApprovedDate AS ApprovedDate
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Investigation Items for this Order
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        COALESCE(NULLIF(m_ref.Method_Name, ''), NULLIF(m_inv.Method_Name, ''), '') AS MethodName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        COALESCE(NULLIF(ref.UnitSymbol, ''), NULLIF(u_inv.Unit_Symbol, ''), u_inv.Unit_Name, '') AS UnitName,
        ISNULL(lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        ISNULL(sc.CollectionstatusID, 2) AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected') AS SampleCollectionStatus,
        ISNULL(scs.StatusCode, 'COLLECTED') AS SampleCollectionStatusCode,
        sc.RejectionReasonId,
        sc.RejectionReason,
        led.LabEntryDetailId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN NULL ELSE led.TestValue END AS TestValue,
        led.Template_Html AS TemplateHtml,
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Tier END AS RangeTier,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Low_Threshold END AS LowThreshold,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.High_Threshold END AS HighThreshold,
        CASE 
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NOT NULL AND ref.Low_Value > 0 THEN
                CONCAT(
                    CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)), 
                    ' — ', 
                    CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30))
                )
            WHEN ref.Low_Value = 0 AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NULL AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NULL THEN
                CONCAT('> ', CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)))
            ELSE '—'
        END AS ReferenceRange,
        -- AbnormalFlag
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN NULL
            ELSE COALESCE(led.AbnormalFlag, 
                CASE 
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Tier IN ('Critical Value', 'Panic Value')
                         AND ((ref.Low_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Threshold)
                           OR (ref.High_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Threshold))
                         THEN CASE ref.Tier WHEN 'Panic Value' THEN 'Panic' ELSE 'Critical' END
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                    ELSE NULL
                END
            )
        END AS AbnormalFlag,
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty results
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 0
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' AND LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND (LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '') THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        CAST(CASE WHEN @BranchId IS NOT NULL
                   AND sc.IsTransferred = 1
                   AND sc.SourceBranchID = @BranchId
                   AND ISNULL(sc.TargetBranchID, 0) <> @BranchId
                  THEN 1 ELSE 0 END AS BIT) AS IsReadOnlyForBranch,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks,
        ISNULL(sc.IsReceived, 0)    AS IsReceived,
        sc.ReceivedDate,
        sc.ReceiveRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabTestMethodMaster m_inv ON m_inv.Method_ID = lim.Method_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u_inv ON u_inv.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID

    -- Join Group-level remarks if saved
    LEFT JOIN dbo.LabReportTestRemarks rem_prof ON rem_prof.LabOrderId = sc.Laborderid 
                                                AND rem_prof.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20))
                                                AND sc.ProfileId IS NOT NULL
                                                AND rem_prof.IsActive = 1
    LEFT JOIN dbo.LabReportTestRemarks rem_inv ON rem_inv.LabOrderId = sc.Laborderid 
                                              AND rem_inv.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20))
                                              AND rem_inv.IsActive = 1

    -- Match best Reference Range for patient's Gender & Age
    OUTER APPLY (
        SELECT TOP 1 
            r.RefRange_ID,
            r.Method_ID AS RefMethodId,
            r.Unit_ID,
            r.Low_Value,
            r.High_Value,
            r.Special_Remarks,
            r.Tier,
            r.Low_Threshold,
            r.High_Threshold,
            r.Age_From,
            r.Age_To,
            r.Gender AS RangeGender,
            u.Unit_Name,
            COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS UnitSymbol
        FROM dbo.LabReferenceRangeMaster r
        LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = r.Unit_ID
        WHERE r.Test_ID = sc.InvestigationID
          AND r.IsDeleted = 0
          AND r.Status = 1
          AND (r.CompanyId = @CompanyId OR r.CompanyId = 1)
          AND r.Effective_From <= CAST(GETDATE() AS DATE)
          AND (r.Effective_To IS NULL OR r.Effective_To >= CAST(GETDATE() AS DATE))
          AND (
              (@PatientAge IS NULL)
              OR (r.Age_Unit = 'Years' AND @PatientAge >= r.Age_From AND @PatientAge <= r.Age_To)
              OR (r.Age_Unit = 'Months' AND (@PatientAge * 12.0) >= r.Age_From AND (@PatientAge * 12.0) <= r.Age_To)
              OR (r.Age_Unit = 'Days' AND (@PatientAge * 365.25) >= r.Age_From AND (@PatientAge * 365.25) <= r.Age_To)
              OR r.Is_Common_For_All = 1
          )
          AND (
              r.Is_Common_For_All = 1
              OR r.Gender = 'All'
              OR LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, ''))
          )
        ORDER BY 
          CASE WHEN LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, '')) THEN 1 ELSE 2 END ASC,
          CASE WHEN r.Is_Common_For_All = 0 THEN 1 ELSE 2 END ASC,
          r.RefRange_ID DESC
    ) ref

    LEFT JOIN dbo.LabTestMethodMaster m_ref ON m_ref.Method_ID = ref.RefMethodId

    -- Previous Historical Result for Delta Check
    OUTER APPLY (
        SELECT TOP 1 
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = @PatientId
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev

    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@ReportingType IS NULL OR LOWER(LTRIM(RTRIM(ISNULL(lim.Reporting_Type, 'Numeric')))) = LOWER(LTRIM(RTRIM(@ReportingType))))
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)))
    ORDER BY sc.samplecollectionID ASC;

    -- RS 3: Header-Level Lab Remarks
    SELECT 
        GroupKey,
        HeaderName,
        ProfileId,
        InvestigationId,
        LabRemarks
    FROM dbo.LabReportTestRemarks
    WHERE LabOrderId = @LabOrderId AND IsActive = 1;
END;
GO

PRINT 'Updated dbo.usp_LabReporting_GetDetail to also return IsB2B.';
GO

PRINT 'Script 2158 applied: Lab Report Dispatch B2B billing column + due-free print for B2B ready.';
GO
