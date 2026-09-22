-- ============================================================================
-- Migration: 2099_lab_report_unapprove.sql
-- Description:
--   "Un-Authorize Report" screen (LAB menu). An approved test is frozen on the Lab Reporting Entry page; to correct a
--   value the approval has to be withdrawn first. This adds:
--
--     1. dbo.LabReportUnapproval                 one row per test un-approved (who, when, why, the value it held)
--     2. dbo.usp_LabUnapprove_GetHeaderList      bills that have >= 1 approved test (fully or partially approved)
--     3. dbo.usp_LabUnapprove_GetDetail          the approved tests of one bill
--     4. dbo.usp_LabUnapprove_Execute            withdraws the approval of the chosen tests
--
--   Un-approving moves a test from Approved (5) back to Submitted (2) and clears its Approved_Date and Validated_date
--   (it has to be validated and approved again). From there the
--   existing Entry flow applies unchanged: unlock the row, change the value, submit, validate, approve again.
--   A test that belongs to a profile is never un-approved alone: the whole profile (all its approved tests) goes back.
--   The result value itself is NOT touched. Nothing existing is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. log table ────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.LabReportUnapproval', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportUnapproval
    (
        UnapprovalId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReportUnapproval PRIMARY KEY,
        LabOrderId         INT           NOT NULL,
        SamplecollectionID BIGINT        NOT NULL,
        InvestigationID    INT           NULL,
        PreviousStatusId   INT           NOT NULL,
        NewStatusId        INT           NOT NULL,
        TestValue          NVARCHAR(MAX) NULL,      -- value at the time of un-approval
        PreviousApprovedDate DATETIME    NULL,
        Reason             NVARCHAR(500) NOT NULL,
        UnapprovedBy       INT           NOT NULL,
        UnapprovedDate     DATETIME      NOT NULL CONSTRAINT DF_LabReportUnapproval_Date DEFAULT (GETDATE())
    );
    CREATE INDEX IX_LabReportUnapproval_Order ON dbo.LabReportUnapproval (LabOrderId, UnapprovedDate DESC);
    PRINT 'Created table dbo.LabReportUnapproval';
END
GO

-- ── 2. bills with approved tests ────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabUnapprove_GetHeaderList
    @BranchId     INT,
    @FromDate     DATETIME      = NULL,
    @ToDate       DATETIME      = NULL,
    @DateBasis    VARCHAR(20)   = 'ApprovedDate',   -- ApprovedDate | BookingDate
    @Search       NVARCHAR(100) = NULL,
    @ApprovalType VARCHAR(10)   = 'ALL'             -- ALL | FULL | PARTIAL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    IF @ToDate   IS NULL SET @ToDate   = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    SET @DateBasis    = UPPER(LTRIM(RTRIM(ISNULL(@DateBasis, 'APPROVEDDATE'))));
    SET @ApprovalType = UPPER(LTRIM(RTRIM(ISNULL(@ApprovalType, 'ALL'))));
    SET @Search       = NULLIF(LTRIM(RTRIM(@Search)), '');

    SELECT
        lo.LabOrderId,
        COUNT(sc.samplecollectionID)                                                              AS TotalTests,
        SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' AND led.ReportStatusId = 5
                 THEN 1 ELSE 0 END)                                                               AS ApprovedTests,
        MAX(CASE WHEN led.ReportStatusId = 5 THEN led.Approved_Date END)                          AS LastApprovedDate
    INTO #Agg
    FROM dbo.LabOrder lo
    INNER JOIN dbo.SampleCollection sc
            ON sc.Laborderid = lo.LabOrderId
           AND sc.Is_Active = 1 AND sc.Iscancelled = 0
           AND sc.CollectionstatusID = 2
           AND ISNULL(sc.IsoutSource, 0) = 0
    LEFT JOIN dbo.labentrydetails led
           ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE lo.BranchId = @BranchId
      AND lo.IsActive = 1
    GROUP BY lo.LabOrderId
    HAVING SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' AND led.ReportStatusId = 5 THEN 1 ELSE 0 END) > 0;

    SELECT
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        lo.OrderDate                                             AS BillingDate,
        ISNULL(lo.BookingDate, lo.OrderDate)                     AS BookingDateTime,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END                                                 AS Age,
        p.Gender,
        p.PhoneNumber,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END         AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName,
        ag.TotalTests,
        ag.ApprovedTests,
        ag.LastApprovedDate                                      AS ApprovedDate,
        CASE WHEN ag.ApprovedTests = ag.TotalTests THEN 'FULL' ELSE 'PARTIAL' END AS ApprovalType,
        ISNULL(ph.PaymentStatus, 'U')                            AS PaymentStatus,
        (SELECT COUNT(1) FROM dbo.LabReportUnapproval x WHERE x.LabOrderId = lo.LabOrderId) AS UnapprovalCount
    INTO #Bills
    FROM #Agg ag
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = ag.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId   = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE (
            (@DateBasis  = 'APPROVEDDATE' AND ag.LastApprovedDate BETWEEN @FromDate AND @ToDate)
         OR (@DateBasis <> 'APPROVEDDATE' AND ISNULL(lo.BookingDate, lo.OrderDate) BETWEEN @FromDate AND @ToDate)
          )
      AND (
            @Search IS NULL
         OR lo.BillNo      LIKE '%' + @Search + '%'
         OR lo.TokenNo     LIKE '%' + @Search + '%'
         OR p.PatientCode  LIKE '%' + @Search + '%'
         OR p.PhoneNumber  LIKE '%' + @Search + '%'
         OR p.FirstName    LIKE '%' + @Search + '%'
         OR p.LastName     LIKE '%' + @Search + '%'
         OR (ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, '')) LIKE '%' + @Search + '%'
          );

    -- RS1: cards
    SELECT
        COUNT(1)                                                       AS TotalBills,
        ISNULL(SUM(CASE WHEN ApprovalType = 'FULL'    THEN 1 ELSE 0 END), 0) AS FullyApprovedBills,
        ISNULL(SUM(CASE WHEN ApprovalType = 'PARTIAL' THEN 1 ELSE 0 END), 0) AS PartiallyApprovedBills,
        ISNULL(SUM(ApprovedTests), 0)                                  AS ApprovedTests
    FROM #Bills;

    -- RS2: list
    SELECT * FROM #Bills
    WHERE @ApprovalType NOT IN ('FULL', 'PARTIAL') OR ApprovalType = @ApprovalType
    ORDER BY ApprovedDate DESC, LabOrderId DESC;

    DROP TABLE #Bills;
    DROP TABLE #Agg;
END;
GO

-- ── 3. approved tests of one bill ───────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabUnapprove_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: bill header
    SELECT
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        lo.OrderDate                                             AS BillingDate,
        ISNULL(lo.BookingDate, lo.OrderDate)                     AS BookingDateTime,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END                                                 AS Age,
        p.Gender,
        p.PhoneNumber,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END         AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: every reportable test of the bill; IsApproved tells which can be un-approved
    SELECT
        sc.samplecollectionID                                   AS SamplecollectionID,
        sc.InvestigationID,
        lim.Test_Code                                           AS TestCode,
        lim.Test_Name                                           AS TestName,
        sc.ProfileId,
        NULLIF(LTRIM(RTRIM(sc.ProfileName)), '')                AS ProfileName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName) AS GroupName,
        ISNULL(d.DeptName, '')                                  AS DepartmentName,
        led.TestValue,
        led.AbnormalFlag,
        led.Reporting_Type                                      AS ReportingType,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0 ELSE ISNULL(led.ReportStatusId, 0) END AS ReportStatusId,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
             ELSE ISNULL(res.StatusName, 'Pending Entry') END   AS ReportStatusName,
        led.Approved_Date                                       AS ApprovedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS ApprovedByName,
        CAST(CASE WHEN led.ReportStatusId = 5 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END AS BIT) AS IsApproved
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.DepartmentMaster d         ON d.DeptId = COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)
    LEFT  JOIN dbo.labentrydetails led        ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.Reportentrystatus res      ON res.ReportStatusId = led.ReportStatusId
    LEFT  JOIN dbo.Users u                    ON u.Id = led.ModifiedBy AND led.ReportStatusId = 5
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND sc.Iscancelled = 0
      AND sc.CollectionstatusID = 2
      AND ISNULL(sc.IsoutSource, 0) = 0
    ORDER BY CASE WHEN sc.ProfileId IS NULL THEN 0 ELSE 1 END, ISNULL(d.DeptName, ''), ISNULL(sc.ProfileName, ''), lim.Test_Name;
END;
GO

-- ── 4. withdraw the approval ────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabUnapprove_Execute
    @LabOrderId          INT,
    @SamplecollectionIds NVARCHAR(MAX),      -- CSV of SamplecollectionID
    @Reason              NVARCHAR(500),
    @UserId              INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = LTRIM(RTRIM(ISNULL(@Reason, '')));
    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN RAISERROR('Valid LabOrderId is required.', 16, 1); RETURN; END
    IF LEN(@Reason) < 5
    BEGIN RAISERROR('A reason (at least 5 characters) is required to un-approve a report.', 16, 1); RETURN; END

    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT @Ids (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@SamplecollectionIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @Ids)
    BEGIN RAISERROR('Select at least one approved test to un-approve.', 16, 1); RETURN; END

    -- A profile is un-approved as a whole: every approved test of a selected test's profile comes with it.
    INSERT @Ids (Id)
    SELECT DISTINCT sc2.samplecollectionID
    FROM dbo.SampleCollection sc1
    INNER JOIN @Ids i ON i.Id = sc1.samplecollectionID
    INNER JOIN dbo.SampleCollection sc2
            ON sc2.Laborderid = sc1.Laborderid
           AND sc2.ProfileId = sc1.ProfileId
           AND sc2.Is_Active = 1 AND sc2.Iscancelled = 0
    INNER JOIN dbo.labentrydetails led2
            ON led2.SamplecollectionID = sc2.samplecollectionID
           AND led2.IsActive = 1 AND led2.ReportStatusId = 5
           AND LTRIM(RTRIM(ISNULL(led2.TestValue, ''))) <> ''
    WHERE sc1.Laborderid = @LabOrderId
      AND sc1.ProfileId IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM @Ids x WHERE x.Id = sc2.samplecollectionID);

    -- every selected test must belong to this bill and currently be approved
    IF EXISTS (
        SELECT 1 FROM @Ids i
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.labentrydetails led
            INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
            WHERE led.SamplecollectionID = i.Id
              AND led.LabOrderId = @LabOrderId
              AND sc.Laborderid = @LabOrderId
              AND led.IsActive = 1
              AND led.ReportStatusId = 5
              AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''))
    BEGIN
        RAISERROR('One or more selected tests are not approved (they may already have been un-approved). Refresh and try again.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME = GETDATE();

    BEGIN TRAN;

    INSERT dbo.LabReportUnapproval
        (LabOrderId, SamplecollectionID, InvestigationID, PreviousStatusId, NewStatusId, TestValue, PreviousApprovedDate, Reason, UnapprovedBy, UnapprovedDate)
    SELECT @LabOrderId, led.SamplecollectionID, led.InvestigationID, 5, 2, led.TestValue, led.Approved_Date, @Reason, @UserId, @Now
    FROM dbo.labentrydetails led
    INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
    WHERE led.ReportStatusId = 5;

    UPDATE led
    SET led.ReportStatusId = 2,
        led.Approved_Date  = NULL,
        led.Validated_date = NULL,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = @Now
    FROM dbo.labentrydetails led
    INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
    WHERE led.ReportStatusId = 5;

    DECLARE @Count INT = @@ROWCOUNT;

    COMMIT;

    SELECT @Count AS UnapprovedCount;
END;
GO

PRINT 'Created Un-Authorize Report objects (2099).';
GO
