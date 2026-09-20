-- ============================================================================
-- Migration: 2090_lab_report_dispatch_dashboard.sql
-- Description:
--   Adds dbo.usp_LabReportDispatch_GetDashboard - a READ-ONLY procedure behind the
--   "Lab Report Dispatch" screen (LAB menu). Bill No wise view used to print / hand over reports.
--
--   Parameters
--     @BranchId        billing branch (lo.BranchId) - the branch that hands the report to the patient
--     @FromDate/@ToDate inclusive range; @ToDate at 00:00 is treated as end-of-day
--     @DateBasis       'BillingDate' (LabOrder.OrderDate)  |  'ApprovedDate' (last test approval)
--     @Search          Patient ID / name / phone / Bill No / Token No / B2B client name or code
--     @DispatchStatus  ALL | READY | PARTIAL | AWAITING | INPROGRESS | NOTSTARTED | PRINTED | NOTPRINTED
--     @ClientType      ALL | B2C | B2B
--
--   Result sets
--     RS1  summary cards (computed on the date / search / client-type filtered set, NOT on @DispatchStatus,
--          so the cards stay stable while the user clicks a card to filter the list)
--     RS2  the bill list (filtered by @DispatchStatus)
--
--   Dispatch status of a bill (in-house, active, non-cancelled tests only)
--     READY       every test approved                          -> final report can be printed
--     PARTIAL     some tests approved, some not                -> printable with NOT APPROVED watermark
--     AWAITING    nothing approved yet, >=1 test validated     -> printable with NOT APPROVED watermark
--     INPROGRESS  results entered / drafted, none validated
--     NOTSTARTED  no result entered yet
--   "Printed" = the final (READY) report was printed after the last approval (AuditLogs LAB.ReportPrinted).
--
--   No existing table or procedure is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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

PRINT 'Created procedure dbo.usp_LabReportDispatch_GetDashboard';
GO
