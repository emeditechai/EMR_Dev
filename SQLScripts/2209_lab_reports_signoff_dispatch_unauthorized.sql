-- ============================================================================
-- Migration: 2209_lab_reports_signoff_dispatch_unauthorized.sql
-- Description: three more Reports > LAB registers from the LAB Reports Roadmap (approval & dispatch stage), on the
--   shared register pattern (one procedure per report returning Summary / Groups / Rows / Options, run through
--   api/reports/lab/run/{report}, page on _LabReportShell + lab-report.js). Visibility: branch first
--   (usp_LabReport_CheckAccess), Administrator / super admin see every user's data, everyone else only their own.
--     LR-19 Pathologist Sign-off Register     usp_Api_LabReport_SignOff        by sign-off date (+ what waits now)
--     LR-20 Report Dispatch & Print Register  usp_Api_LabReport_DispatchPrint  by ready date (last test approved)
--     LR-22 Un-authorized & Amended Reports   usp_Api_LabReport_Unauthorized   by withdrawal date
--   LR-22 needs to know who had approved a withdrawn result; the sign-offs are cleared when it is withdrawn, so
--   dbo.usp_LabUnapprove_Execute now keeps them with the withdrawal (LabReportUnapproval.PreviousApprovedBy /
--   PreviousApprovers). Nothing else in the withdrawal changes. Pages are added to Reports > LAB with their VIEW
--   endpoints; no role or user grant is seeded. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabReportUnapproval', 'PreviousApprovedBy') IS NULL
    ALTER TABLE dbo.LabReportUnapproval ADD PreviousApprovedBy INT NULL;
IF COL_LENGTH('dbo.LabReportUnapproval', 'PreviousApprovers') IS NULL
    ALTER TABLE dbo.LabReportUnapproval ADD PreviousApprovers NVARCHAR(400) NULL;
GO

-- ============================================================================
-- usp_LabUnapprove_Execute: unchanged except that the withdrawal row now keeps who had approved the result
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabUnapprove_Execute
    @LabOrderId          INT,
    @SamplecollectionIds NVARCHAR(MAX),      -- CSV of SamplecollectionID
    @Reason              NVARCHAR(500),
    @UserId              INT,
    @Action              VARCHAR(20) = 'RETEST'   -- RETEST | RECOLLECT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = LTRIM(RTRIM(ISNULL(@Reason, '')));
    SET @Action = UPPER(LTRIM(RTRIM(ISNULL(@Action, 'RETEST'))));

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN RAISERROR('Valid LabOrderId is required.', 16, 1); RETURN; END
    IF LEN(@Reason) < 5
    BEGIN RAISERROR('A reason (at least 5 characters) is required to un-approve a report.', 16, 1); RETURN; END
    IF @Action NOT IN ('RETEST', 'RECOLLECT')
    BEGIN RAISERROR('Select what the withdrawal is for: Re-Test or Re-Collect.', 16, 1); RETURN; END

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
    DECLARE @NewStatusId INT = CASE WHEN @Action = 'RETEST' THEN 2 ELSE NULL END;   -- Re-collect: no report status at all

    BEGIN TRAN;

    -- 2209: who had approved it is kept with the withdrawal (the sign-offs are cleared below), for LR-22
    INSERT dbo.LabReportUnapproval
        (LabOrderId, SamplecollectionID, InvestigationID, PreviousStatusId, NewStatusId, TestValue, PreviousApprovedDate, Reason, [Action], UnapprovedBy, UnapprovedDate,
         PreviousApprovedBy, PreviousApprovers)
    SELECT @LabOrderId, led.SamplecollectionID, led.InvestigationID, 5, @NewStatusId, led.TestValue, led.Approved_Date, @Reason, @Action, @UserId, @Now,
           (SELECT TOP 1 a.ApprovedBy FROM dbo.LabReportApproval a
             WHERE a.SamplecollectionID = led.SamplecollectionID ORDER BY a.Level_No DESC, a.ApprovedDate DESC),
           (SELECT STRING_AGG('L' + CAST(a.Level_No AS VARCHAR(2)) + ' ' + ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username), ' · ')
                   WITHIN GROUP (ORDER BY a.Level_No)
              FROM dbo.LabReportApproval a LEFT JOIN dbo.Users u ON u.Id = a.ApprovedBy
             WHERE a.SamplecollectionID = led.SamplecollectionID)
    FROM dbo.labentrydetails led
    INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
    WHERE led.ReportStatusId = 5;

    IF @Action = 'RETEST'
    BEGIN
        -- Back to Submitted, value kept: corrected on the Lab Reporting Entry page.
        UPDATE led
        SET led.ReportStatusId = 2,
            led.Approved_Date  = NULL,
            led.Validated_date = NULL,
            led.ModifiedBy     = @UserId,
            led.ModifiedDate   = @Now
        FROM dbo.labentrydetails led
        INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
        WHERE led.ReportStatusId = 5;
    END
    ELSE
    BEGIN
        -- Re-collect: same effect as the "Re-Collect" action of dbo.usp_LabReporting_UpdateSampleStatus -
        -- the sample returns to the Sample Collection page and the entered result is cleared.
        UPDATE sc
        SET sc.CollectionstatusID   = 3,                 -- Re-Collect
            sc.RejectionReason      = @Reason,
            sc.Samplecollectiondate = NULL,
            sc.Samplecollectiontime = NULL,
            sc.ModifiedBy           = @UserId,
            sc.ModifiedDate         = @Now
        FROM dbo.SampleCollection sc
        INNER JOIN @Ids i ON i.Id = sc.samplecollectionID
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0;

        UPDATE led
        SET led.TestValue       = NULL,
            led.ReportStatusId  = NULL,
            led.Drafted_Date    = NULL,
            led.Submitted_Date  = NULL,
            led.Validated_date  = NULL,
            led.Approved_Date   = NULL,
            led.AbnormalFlag    = NULL,
            led.RejectionReason = @Reason,
            led.ModifiedBy      = @UserId,
            led.ModifiedDate    = @Now
        FROM dbo.labentrydetails led
        INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
        WHERE led.ReportStatusId = 5;
    END

    -- The per-level pathologist sign-offs are cleared too, so a withdrawn report starts again at Level 1.
    DELETE a
    FROM dbo.LabReportApproval a
    INNER JOIN @Ids i ON i.Id = a.SamplecollectionID
    WHERE a.LabOrderId = @LabOrderId;

    DECLARE @Count INT = @@ROWCOUNT;

    COMMIT;

    SELECT @Count AS UnapprovedCount;
END;
GO

-- ============================================================================
-- LR-19 Pathologist Sign-off Register - who signed what, at which level, and how long it waited for them.
-- Signed: every sign-off in the period (dbo.LabReportApproval, by sign-off date), one line per test (a profile once)
-- and level. Waited = from the moment the test reached that level (validated for level 1, the previous level's
-- sign-off after that) to the sign-off. Waiting now: validated tests still waiting for a level, one line per
-- pathologist who may sign it (dbo.ufn_LabPathologistScope, the Pathologist Dashboard's own rule); not limited by date.
-- Own data: tests they signed and tests waiting for their signature.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_SignOff
    @BranchId       INT,
    @FromDate       DATE,
    @ToDate         DATE,
    @Show           VARCHAR(10)   = NULL,   -- SIGNED / WAITING
    @Level          VARCHAR(5)    = NULL,   -- 1 / 2 / 3
    @Source         VARCHAR(10)   = NULL,   -- FLOW (Pathologist Dashboard) / ENTRY (Report Entry approval)
    @PathologistId  INT           = NULL,
    @DepartmentId   INT           = NULL,
    @Search         NVARCHAR(100) = NULL,
    @UserId         INT           = NULL,
    @IsAdmin        BIT           = 0,
    @IsSuperAdmin   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Show = NULLIF(UPPER(LTRIM(RTRIM(@Show))), '');
    SET @Source = NULLIF(UPPER(LTRIM(RTRIM(@Source))), '');
    DECLARE @Lvl INT = TRY_CAST(NULLIF(LTRIM(RTRIM(@Level)), '') AS INT);
    IF @OwnOnly = 1 SET @PathologistId = @UserId;      -- own data: always the signed-in user

    -- signatures in the period, one per parameter and level
    SELECT a.LabOrderId, a.SamplecollectionID AS SampleId, a.Level_No, ISNULL(a.TotalLevels, 1) AS TotalLevels,
           CAST(ISNULL(a.IsFinalLevel, 0) AS INT) AS IsFinal, a.ApprovedBy, a.ApprovedDate, ISNULL(NULLIF(a.Source, ''), 'FLOW') AS Source,
           sc.ProfileId, CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END AS UnitKey,
           COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
           COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName, lim.Test_Code,
           COALESCE(led.Validated_date, led.Submitted_Date) AS ValidatedOn,
           (SELECT MAX(p.ApprovedDate) FROM dbo.LabReportApproval p
             WHERE p.SamplecollectionID = a.SamplecollectionID AND p.Level_No < a.Level_No) AS PrevSignedOn
    INTO #S
    FROM dbo.LabReportApproval a
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = a.SamplecollectionID
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = a.LabOrderId AND lo.IsActive = 1
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = a.SamplecollectionID AND led.IsActive = 1
    WHERE a.BranchId = @BranchId AND a.ApprovedDate >= @From AND a.ApprovedDate < @To
      AND (@PathologistId IS NULL OR a.ApprovedBy = @PathologistId);

    -- tests waiting now, one line per pathologist who may sign the next level
    SELECT u.Id AS PathologistId, s.SamplecollectionID AS SampleId, s.LabOrderId, s.NextLevelNo, s.TotalLevels,
           sc.ProfileId, CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END AS UnitKey,
           COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
           COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName, lim.Test_Code,
           COALESCE(led.Validated_date, led.Submitted_Date) AS ValidatedOn,
           (SELECT MAX(p.ApprovedDate) FROM dbo.LabReportApproval p WHERE p.SamplecollectionID = s.SamplecollectionID) AS LastSignedOn
    INTO #W
    FROM dbo.Users u
    CROSS APPLY dbo.ufn_LabPathologistScope(u.Id, @BranchId) s
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = s.SamplecollectionID
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = s.LabOrderId AND lo.IsActive = 1
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = s.SamplecollectionID AND led.IsActive = 1
    WHERE ISNULL(u.IsPathologist, 0) = 1 AND ISNULL(u.IsActive, 0) = 1 AND s.CanApproveNow = 1
      AND (@PathologistId IS NULL OR u.Id = @PathologistId)
      AND ISNULL(@Show, 'WAITING') = 'WAITING' AND @Source IS NULL;

    -- one line per test (a profile once)
    ;WITH su AS (
        SELECT 'SIGNED' AS Kind, LabOrderId, UnitKey, MIN(SampleId) AS FirstSampleId, MAX(ProfileId) AS ProfileId,
               Level_No AS LevelNo, MAX(TotalLevels) AS TotalLevels, MAX(IsFinal) AS IsFinal, ApprovedBy AS PathologistId,
               MAX(ApprovedDate) AS SignedOn, MAX(Source) AS Source, MAX(DepartmentId) AS DepartmentId, MAX(TestName) AS TestName,
               MAX(Test_Code) AS TestCode, COUNT(1) AS Parameters, MAX(ValidatedOn) AS ValidatedOn,
               CASE WHEN Level_No = 1 THEN MAX(ValidatedOn) ELSE MAX(PrevSignedOn) END AS AvailableSince
        FROM #S WHERE ISNULL(@Show, 'SIGNED') = 'SIGNED'
        GROUP BY LabOrderId, UnitKey, Level_No, ApprovedBy),
    wu AS (
        SELECT 'WAITING' AS Kind, LabOrderId, UnitKey, MIN(SampleId) AS FirstSampleId, MAX(ProfileId) AS ProfileId,
               MIN(NextLevelNo) AS LevelNo, MAX(TotalLevels) AS TotalLevels,
               CASE WHEN MIN(NextLevelNo) >= MAX(TotalLevels) THEN 1 ELSE 0 END AS IsFinal, PathologistId,
               CAST(NULL AS DATETIME) AS SignedOn, CAST(NULL AS VARCHAR(10)) AS Source, MAX(DepartmentId) AS DepartmentId,
               MAX(TestName) AS TestName, MAX(Test_Code) AS TestCode, COUNT(1) AS Parameters, MAX(ValidatedOn) AS ValidatedOn,
               MAX(COALESCE(LastSignedOn, ValidatedOn)) AS AvailableSince
        FROM #W GROUP BY LabOrderId, UnitKey, PathologistId),
    x AS (SELECT * FROM su UNION ALL SELECT * FROM wu)
    SELECT x.Kind, x.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BilledOn, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           x.FirstSampleId, COALESCE(h.Profile_Code, x.TestCode) AS TestCode, x.TestName, x.Parameters,
           x.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department,
           x.LevelNo, x.TotalLevels, CAST(x.IsFinal AS BIT) AS IsFinal,
           CASE WHEN x.TotalLevels <= 1 THEN 'Single sign-off' ELSE 'Level ' + CAST(x.LevelNo AS VARCHAR(2)) + ' of ' + CAST(x.TotalLevels AS VARCHAR(2)) END AS LevelName,
           x.Source, CASE x.Source WHEN 'FLOW' THEN 'Pathologist Dashboard' WHEN 'ENTRY' THEN 'Report Entry' END AS SourceName,
           x.PathologistId, ISNULL(NULLIF(LTRIM(RTRIM(pu.FullName)), ''), pu.Username) AS Pathologist,
           x.AvailableSince, x.ValidatedOn, x.SignedOn,
           CONVERT(VARCHAR(10), CAST(x.SignedOn AS DATE), 23) AS SignedDay,
           CAST(CASE WHEN x.AvailableSince IS NULL THEN NULL
                     WHEN x.Kind = 'SIGNED' AND x.SignedOn >= x.AvailableSince THEN DATEDIFF(MINUTE, x.AvailableSince, x.SignedOn) / 60.0
                     WHEN x.Kind = 'WAITING' AND @Now >= x.AvailableSince THEN DATEDIFF(MINUTE, x.AvailableSince, @Now) / 60.0 END AS DECIMAL(10, 1)) AS WaitHours,
           CAST(CASE WHEN x.Kind = 'SIGNED' AND x.ValidatedOn IS NOT NULL AND x.SignedOn >= x.ValidatedOn
                     THEN DATEDIFF(MINUTE, x.ValidatedOn, x.SignedOn) / 60.0 END AS DECIMAL(10, 1)) AS SinceValidationHours
    INTO #R
    FROM x
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = x.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = x.ProfileId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = x.DepartmentId
    LEFT  JOIN dbo.Users pu ON pu.Id = x.PathologistId
    WHERE (@Lvl IS NULL OR x.LevelNo = @Lvl)
      AND (@Source IS NULL OR x.Source = @Source)
      AND (@DepartmentId IS NULL OR x.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR x.TestName LIKE '%' + @Search + '%' OR pu.FullName LIKE '%' + @Search + '%');

    -- RS1 summary
    SELECT SUM(CASE WHEN Kind = 'SIGNED' THEN 1 ELSE 0 END) AS SignedTests,
           SUM(CASE WHEN Kind = 'SIGNED' AND IsFinal = 1 THEN 1 ELSE 0 END) AS FinalSignoffs,
           COUNT(DISTINCT CASE WHEN Kind = 'SIGNED' THEN PathologistId END) AS Pathologists,
           CAST(AVG(CASE WHEN Kind = 'SIGNED' THEN WaitHours END) AS DECIMAL(10, 1)) AS AvgWaitHours,
           MAX(CASE WHEN Kind = 'SIGNED' THEN WaitHours END) AS MaxWaitHours,
           SUM(CASE WHEN Kind = 'SIGNED' AND WaitHours > 24 THEN 1 ELSE 0 END) AS SignedAfterDay,
           SUM(CASE WHEN Kind = 'SIGNED' AND Source = 'FLOW' THEN 1 ELSE 0 END) AS ViaDashboard,
           SUM(CASE WHEN Kind = 'SIGNED' AND Source = 'ENTRY' THEN 1 ELSE 0 END) AS ViaEntry,
           COUNT(DISTINCT CASE WHEN Kind = 'WAITING' THEN CONCAT(LabOrderId, ':', FirstSampleId, ':', LevelNo) END) AS WaitingTests,
           MAX(CASE WHEN Kind = 'WAITING' THEN WaitHours END) AS OldestWaitingHours
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byPathologist' AS GroupKey, PathologistId AS GroupId, Pathologist AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byLevel', LevelNo, 'Level ' + CAST(LevelNo AS VARCHAR(2)), LevelNo, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, SignedDay, 0, * FROM #R WHERE SignedDay IS NOT NULL)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           SUM(CASE WHEN Kind = 'SIGNED' THEN 1 ELSE 0 END) AS Signed,
           SUM(CASE WHEN Kind = 'SIGNED' AND IsFinal = 1 THEN 1 ELSE 0 END) AS FinalSignoffs,
           CAST(AVG(CASE WHEN Kind = 'SIGNED' THEN WaitHours END) AS DECIMAL(10, 1)) AS AvgWaitHours,
           MAX(CASE WHEN Kind = 'SIGNED' THEN WaitHours END) AS MaxWaitHours,
           SUM(CASE WHEN Kind = 'WAITING' THEN 1 ELSE 0 END) AS Waiting,
           MAX(CASE WHEN Kind = 'WAITING' THEN WaitHours END) AS OldestWaitingHours
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, COUNT(1) DESC, GroupName;

    -- RS3 rows: what is waiting first (longest wait), then the sign-offs, latest first
    SELECT * FROM #R ORDER BY CASE Kind WHEN 'WAITING' THEN 0 ELSE 1 END,
                              CASE WHEN Kind = 'WAITING' THEN WaitHours END DESC, SignedOn DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL
    UNION ALL
    SELECT DISTINCT 'pathologistId', CAST(u.Id AS VARCHAR(20)), ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
    FROM dbo.Users u INNER JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1
    WHERE ISNULL(u.IsPathologist, 0) = 1 AND ISNULL(u.IsActive, 0) = 1;

    DROP TABLE #R; DROP TABLE #S; DROP TABLE #W;
END;
GO

-- ============================================================================
-- LR-20 Report Dispatch & Print Register - which reports are ready, handed over, or still waiting at the counter.
-- One line per bill whose last approved test was approved in the period (ready date). Same tests as the Report
-- Dispatch dashboard: collected samples of the bill, not cancelled, not outsourced. A bill is Ready when every test is
-- approved, Partly ready otherwise. Handed over = the report printed (LAB.ReportPrinted, not the "not approved" copy),
-- emailed (sent) or sent on WhatsApp at or after it became ready. Held for dues = ready, not handed over, and the
-- B2C bill still has a balance (net - paid; the dispatch desk releases a report only when the bill is paid).
-- Days waiting = from ready to hand-over, or to now. Own data: bills they created and reports they printed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DispatchPrint
    @BranchId        INT,
    @FromDate        DATE,
    @ToDate          DATE,
    @DispatchStatus  VARCHAR(20)   = NULL,   -- DELIVERED / NOT_COLLECTED / HELD_DUES / PARTIAL
    @BillingType     VARCHAR(10)   = NULL,   -- B2C / B2B
    @PrintedBy       INT           = NULL,
    @Search          NVARCHAR(100) = NULL,
    @UserId          INT           = NULL,
    @IsAdmin         BIT           = 0,
    @IsSuperAdmin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @DispatchStatus = NULLIF(UPPER(LTRIM(RTRIM(@DispatchStatus))), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');

    SELECT lo.LabOrderId,
           COUNT(sc.samplecollectionID) AS TotalTests,
           SUM(CASE WHEN led.ReportStatusId = 5 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END) AS ApprovedTests,
           MAX(CASE WHEN led.ReportStatusId = 5 THEN led.Approved_Date END) AS LastApprovedOn
    INTO #A
    FROM dbo.LabOrder lo
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = lo.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.IsoutSource, 0) = 0
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1
    GROUP BY lo.LabOrderId
    HAVING MAX(CASE WHEN led.ReportStatusId = 5 THEN led.Approved_Date END) >= @From
       AND MAX(CASE WHEN led.ReportStatusId = 5 THEN led.Approved_Date END) < @To;

    SELECT ag.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BilledOn, lo.CreatedBy AS CreatedById,
           p.PatientCode, p.PhoneNumber AS PatientPhone,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
           CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS PartnerName,
           ag.TotalTests, ag.ApprovedTests,
           CAST(CASE WHEN ag.ApprovedTests >= ag.TotalTests THEN 1 ELSE 0 END AS BIT) AS IsReady,
           ag.LastApprovedOn AS ReadyOn, CONVERT(VARCHAR(10), CAST(ag.LastApprovedOn AS DATE), 23) AS ReadyDay,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0
                     WHEN ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0
                     ELSE ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END AS DECIMAL(18, 2)) AS DueAmount,
           pr.FinalPrints, pr.PendingCopies, pr.FirstPrintOn, pr.LastPrintOn, pr.FirstPrintedById, pr.PrintedByNames,
           pr.PrintedAfterReady,
           em.EmailedOn, em.LastEmailStatus,
           wa.WhatsAppOn,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.AuditLogs a2 WHERE a2.ModuleCode = 'LAB' AND a2.ActionName = 'LAB.ReportPrinted'
                                   AND a2.ReferenceNo = lo.BillNo AND a2.UserId = @UserId) THEN 1 ELSE 0 END AS BIT) AS PrintedByMe,
           CAST(CASE WHEN @PrintedBy IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.AuditLogs a3 WHERE a3.ModuleCode = 'LAB' AND a3.ActionName = 'LAB.ReportPrinted'
                                   AND a3.ReferenceNo = lo.BillNo AND a3.UserId = @PrintedBy) THEN 1 ELSE 0 END AS BIT) AS PrintedBySelected
    INTO #B
    FROM #A ag
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ag.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    OUTER APPLY (
        SELECT SUM(CASE WHEN a.Description IS NULL OR a.Description NOT LIKE '%[[]scope:pending]%' THEN 1 ELSE 0 END) AS FinalPrints,
               SUM(CASE WHEN a.Description LIKE '%[[]scope:pending]%' THEN 1 ELSE 0 END) AS PendingCopies,
               MIN(CASE WHEN a.Description IS NULL OR a.Description NOT LIKE '%[[]scope:pending]%' THEN a.CreatedDate END) AS FirstPrintOn,
               MAX(CASE WHEN a.Description IS NULL OR a.Description NOT LIKE '%[[]scope:pending]%' THEN a.CreatedDate END) AS LastPrintOn,
               (SELECT MIN(a0.CreatedDate) FROM dbo.AuditLogs a0 WHERE a0.ModuleCode = 'LAB' AND a0.ActionName = 'LAB.ReportPrinted' AND a0.ReferenceNo = lo.BillNo
                  AND (a0.Description IS NULL OR a0.Description NOT LIKE '%[[]scope:pending]%') AND a0.CreatedDate >= ag.LastApprovedOn) AS PrintedAfterReady,
               (SELECT TOP 1 a1.UserId FROM dbo.AuditLogs a1 WHERE a1.ModuleCode = 'LAB' AND a1.ActionName = 'LAB.ReportPrinted' AND a1.ReferenceNo = lo.BillNo
                  AND (a1.Description IS NULL OR a1.Description NOT LIKE '%[[]scope:pending]%') ORDER BY a1.CreatedDate, a1.Id) AS FirstPrintedById,
               (SELECT STRING_AGG(x.Name, ', ') FROM (
                    SELECT DISTINCT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name
                    FROM dbo.AuditLogs a4 INNER JOIN dbo.Users u ON u.Id = a4.UserId
                    WHERE a4.ModuleCode = 'LAB' AND a4.ActionName = 'LAB.ReportPrinted' AND a4.ReferenceNo = lo.BillNo) x) AS PrintedByNames
        FROM dbo.AuditLogs a
        WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportPrinted' AND a.ReferenceNo = lo.BillNo) pr
    OUTER APPLY (
        SELECT (SELECT MIN(e.SentDate) FROM dbo.LabReportEmailLog e
                 WHERE e.LabOrderId = lo.LabOrderId AND e.Status = 'Sent' AND e.SentDate >= DATEADD(MINUTE, -1, ag.LastApprovedOn)) AS EmailedOn,
               (SELECT TOP 1 e2.Status FROM dbo.LabReportEmailLog e2 WHERE e2.LabOrderId = lo.LabOrderId ORDER BY e2.LabReportEmailLogId DESC) AS LastEmailStatus) em
    OUTER APPLY (
        SELECT MIN(w.CreatedDate) AS WhatsAppOn FROM dbo.AuditLogs w
        WHERE w.ModuleCode = 'LAB' AND w.ActionName = 'LAB.ReportWhatsAppSent' AND w.ReferenceId = lo.LabOrderId
          AND w.CreatedDate >= DATEADD(MINUTE, -1, ag.LastApprovedOn)) wa
    WHERE (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%'
           OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    ALTER TABLE #B ADD DeliveredOn DATETIME, DeliveredVia VARCHAR(20), DispatchStatus VARCHAR(20), DaysWaiting INT, HoursToDeliver DECIMAL(10, 1), DuplicatePrints INT;
    UPDATE #B SET DeliveredOn = CASE WHEN IsReady = 1 THEN (SELECT MIN(v) FROM (VALUES (PrintedAfterReady), (EmailedOn), (WhatsAppOn)) t(v)) END,
                  DuplicatePrints = CASE WHEN ISNULL(FinalPrints, 0) > 1 THEN FinalPrints - 1 ELSE 0 END;
    UPDATE #B SET DeliveredVia = CASE WHEN DeliveredOn IS NULL THEN NULL WHEN DeliveredOn = PrintedAfterReady THEN 'PRINT'
                                      WHEN DeliveredOn = EmailedOn THEN 'EMAIL' ELSE 'WHATSAPP' END,
                  DispatchStatus = CASE WHEN IsReady = 0 THEN 'PARTIAL' WHEN DeliveredOn IS NOT NULL THEN 'DELIVERED'
                                        WHEN DueAmount > 0 THEN 'HELD_DUES' ELSE 'NOT_COLLECTED' END,
                  DaysWaiting = CASE WHEN IsReady = 1 THEN DATEDIFF(DAY, ReadyOn, ISNULL(DeliveredOn, @Now)) END,
                  HoursToDeliver = CASE WHEN DeliveredOn IS NOT NULL AND DeliveredOn >= ReadyOn THEN CAST(DATEDIFF(MINUTE, ReadyOn, DeliveredOn) / 60.0 AS DECIMAL(10, 1)) END;

    IF @OwnOnly = 1 DELETE FROM #B WHERE NOT (CreatedById = @UserId OR PrintedByMe = 1);
    IF @PrintedBy IS NOT NULL DELETE FROM #B WHERE PrintedBySelected = 0;
    IF @DispatchStatus IS NOT NULL DELETE FROM #B WHERE DispatchStatus <> @DispatchStatus;

    -- RS1 summary
    SELECT COUNT(1) AS Bills,
           SUM(CASE WHEN IsReady = 1 THEN 1 ELSE 0 END) AS ReadyBills,
           SUM(CASE WHEN IsReady = 0 THEN 1 ELSE 0 END) AS PartialBills,
           SUM(CASE WHEN DispatchStatus = 'DELIVERED' THEN 1 ELSE 0 END) AS Delivered,
           SUM(CASE WHEN PrintedAfterReady IS NOT NULL THEN 1 ELSE 0 END) AS Printed,
           SUM(CASE WHEN EmailedOn IS NOT NULL THEN 1 ELSE 0 END) AS Emailed,
           SUM(CASE WHEN WhatsAppOn IS NOT NULL THEN 1 ELSE 0 END) AS WhatsApp,
           ISNULL(SUM(DuplicatePrints), 0) AS DuplicatePrints,
           SUM(CASE WHEN DispatchStatus = 'NOT_COLLECTED' THEN 1 ELSE 0 END) AS NotCollected,
           SUM(CASE WHEN DispatchStatus = 'HELD_DUES' THEN 1 ELSE 0 END) AS HeldForDues,
           ISNULL(SUM(CASE WHEN DispatchStatus = 'HELD_DUES' THEN DueAmount END), 0) AS HeldDueAmount,
           CAST(AVG(HoursToDeliver) AS DECIMAL(10, 1)) AS AvgHoursToDeliver,
           MAX(CASE WHEN DispatchStatus IN ('NOT_COLLECTED', 'HELD_DUES') THEN DaysWaiting END) AS OldestWaitingDays
    FROM #B;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byDay' AS GroupKey, NULL AS GroupId, ReadyDay AS GroupName, 0 AS SortOrder, * FROM #B
        UNION ALL SELECT 'byStatus', NULL, DispatchStatus,
               CASE DispatchStatus WHEN 'HELD_DUES' THEN 0 WHEN 'NOT_COLLECTED' THEN 1 WHEN 'PARTIAL' THEN 2 ELSE 3 END, * FROM #B
        UNION ALL SELECT 'byPrintedBy', FirstPrintedById, ISNULL(ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username), 'Not printed'),
               CASE WHEN FirstPrintedById IS NULL THEN 1 ELSE 0 END, b.* FROM #B b LEFT JOIN dbo.Users u ON u.Id = b.FirstPrintedById
        UNION ALL SELECT 'byBillingType', NULL, BillingType, 0, * FROM #B)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Bills,
           SUM(CASE WHEN IsReady = 1 THEN 1 ELSE 0 END) AS ReadyBills,
           SUM(CASE WHEN DispatchStatus = 'DELIVERED' THEN 1 ELSE 0 END) AS Delivered,
           SUM(CASE WHEN PrintedAfterReady IS NOT NULL THEN 1 ELSE 0 END) AS Printed,
           ISNULL(SUM(DuplicatePrints), 0) AS DuplicatePrints,
           SUM(CASE WHEN DispatchStatus = 'NOT_COLLECTED' THEN 1 ELSE 0 END) AS NotCollected,
           SUM(CASE WHEN DispatchStatus = 'HELD_DUES' THEN 1 ELSE 0 END) AS HeldForDues,
           ISNULL(SUM(CASE WHEN DispatchStatus = 'HELD_DUES' THEN DueAmount END), 0) AS HeldDueAmount,
           CAST(AVG(HoursToDeliver) AS DECIMAL(10, 1)) AS AvgHoursToDeliver
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDay' THEN GroupName END DESC, COUNT(1) DESC, GroupName;

    -- RS3 rows: still at the counter first (longest wait), then the rest, latest ready first
    SELECT * FROM #B ORDER BY CASE DispatchStatus WHEN 'HELD_DUES' THEN 0 WHEN 'NOT_COLLECTED' THEN 0 WHEN 'PARTIAL' THEN 1 ELSE 2 END,
                              CASE WHEN DispatchStatus IN ('HELD_DUES', 'NOT_COLLECTED') THEN DaysWaiting END DESC, ReadyOn DESC;

    -- RS4 filter options: who printed reports of the branch
    SELECT DISTINCT 'printedBy' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.AuditLogs a INNER JOIN dbo.Users u ON u.Id = a.UserId
    WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportPrinted' AND a.BranchId = @BranchId;

    DROP TABLE #B; DROP TABLE #A;
END;
GO

-- ============================================================================
-- LR-22 Un-authorized & Amended Reports - NABL / NABH quality indicator. Every approved result withdrawn in the
-- period (dbo.LabReportUnapproval, by withdrawal date): why, by whom, who had approved it, whether and when it was
-- approved again, whether the value changed (amended) and whether the revised report was emailed. Approved by: kept
-- with the withdrawal from script 2209; for earlier withdrawals it is read from the approval entry in the audit trail.
-- Own data: withdrawals they made and results they had approved.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_Unauthorized
    @BranchId       INT,
    @FromDate       DATE,
    @ToDate         DATE,
    @WithdrawAction VARCHAR(10)   = NULL,   -- RETEST / RECOLLECT
    @Outcome        VARCHAR(20)   = NULL,   -- REAPPROVED / OPEN
    @Amended        VARCHAR(5)    = NULL,   -- YES / NO
    @UnapprovedBy   INT           = NULL,
    @DepartmentId   INT           = NULL,
    @Search         NVARCHAR(100) = NULL,
    @UserId         INT           = NULL,
    @IsAdmin        BIT           = 0,
    @IsSuperAdmin   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @WithdrawAction = NULLIF(UPPER(LTRIM(RTRIM(@WithdrawAction))), '');
    SET @Outcome = NULLIF(UPPER(LTRIM(RTRIM(@Outcome))), '');
    SET @Amended = NULLIF(UPPER(LTRIM(RTRIM(@Amended))), '');

    SELECT un.UnapprovalId, un.LabOrderId, un.SamplecollectionID AS SampleId, un.UnapprovedDate AS UnapprovedOn,
           CONVERT(VARCHAR(10), CAST(un.UnapprovedDate AS DATE), 23) AS UnapprovedDay,
           un.UnapprovedBy AS UnapprovedById, ISNULL(NULLIF(LTRIM(RTRIM(uu.FullName)), ''), uu.Username) AS UnapprovedByName,
           LTRIM(RTRIM(ISNULL(un.Reason, ''))) AS Reason, ISNULL(un.[Action], 'RETEST') AS WithdrawAction,
           un.PreviousApprovedDate AS PreviousApprovedOn, LTRIM(RTRIM(ISNULL(un.TestValue, ''))) AS ValueWithdrawn,
           COALESCE(un.PreviousApprovedBy, aud.UserId) AS ApprovedById,
           COALESCE(un.PreviousApprovers, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), ''), au.Username)) AS ApprovedByName,
           CAST(CASE WHEN un.PreviousApprovedBy IS NULL AND aud.UserId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS ApprovedByFromAudit,
           lo.BillNo, lo.TokenNo, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           lim.Test_Name AS TestName, NULLIF(sc.ProfileName, '') AS ProfileName,
           COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
           -- the next withdrawal of the same result, if it was withdrawn again
           nx.NextApprovedOn, nx.NextValue, nx.NextApprovedBy,
           led.ReportStatusId AS CurrentStatusId, led.Approved_Date AS CurrentApprovedOn, LTRIM(RTRIM(ISNULL(led.TestValue, ''))) AS CurrentValue
    INTO #U
    FROM dbo.LabReportUnapproval un
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = un.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = un.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = un.SamplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.Users uu ON uu.Id = un.UnapprovedBy
    OUTER APPLY (SELECT TOP 1 a.UserId FROM dbo.AuditLogs a
                  WHERE un.PreviousApprovedBy IS NULL AND un.PreviousApprovedDate IS NOT NULL
                    AND a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportApproved' AND a.ReferenceId = un.LabOrderId
                    AND a.CreatedDate BETWEEN DATEADD(SECOND, -30, un.PreviousApprovedDate) AND DATEADD(MINUTE, 2, un.PreviousApprovedDate)
                  ORDER BY ABS(DATEDIFF(SECOND, un.PreviousApprovedDate, a.CreatedDate))) aud
    LEFT  JOIN dbo.Users au ON au.Id = aud.UserId
    OUTER APPLY (SELECT TOP 1 n.PreviousApprovedDate AS NextApprovedOn, LTRIM(RTRIM(ISNULL(n.TestValue, ''))) AS NextValue, n.PreviousApprovedBy AS NextApprovedBy
                  FROM dbo.LabReportUnapproval n
                  WHERE n.SamplecollectionID = un.SamplecollectionID AND n.UnapprovedDate > un.UnapprovedDate
                  ORDER BY n.UnapprovedDate, n.UnapprovalId) nx
    WHERE un.UnapprovedDate >= @From AND un.UnapprovedDate < @To
      AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId) OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId)
           OR (sc.BranchID IS NULL AND lo.BranchId = @BranchId));

    ALTER TABLE #U ADD ReApprovedOn DATETIME, ValueApproved NVARCHAR(MAX), ReApprovedById INT, Outcome VARCHAR(20),
                       IsAmended BIT, HoursToReApprove DECIMAL(10, 1), RevisedEmailedOn DATETIME;
    -- approved again: before a later withdrawal of the same result, or now
    UPDATE #U SET ReApprovedOn = CASE WHEN NextApprovedOn > UnapprovedOn THEN NextApprovedOn
                                      WHEN NextApprovedOn IS NULL AND CurrentStatusId = 5 AND CurrentApprovedOn > UnapprovedOn THEN CurrentApprovedOn END,
                  ValueApproved = CASE WHEN NextApprovedOn > UnapprovedOn THEN NextValue
                                       WHEN NextApprovedOn IS NULL AND CurrentStatusId = 5 AND CurrentApprovedOn > UnapprovedOn THEN CurrentValue END;
    UPDATE u SET ReApprovedById = CASE WHEN u.NextApprovedOn IS NOT NULL THEN u.NextApprovedBy
                                       ELSE (SELECT TOP 1 a.ApprovedBy FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = u.SampleId
                                              ORDER BY a.Level_No DESC, a.ApprovedDate DESC) END
    FROM #U u WHERE u.ReApprovedOn IS NOT NULL;
    UPDATE #U SET Outcome = CASE WHEN ReApprovedOn IS NOT NULL THEN 'REAPPROVED' ELSE 'OPEN' END,
                  IsAmended = CASE WHEN ReApprovedOn IS NULL THEN NULL WHEN ISNULL(ValueApproved, '') <> ISNULL(ValueWithdrawn, '') THEN 1 ELSE 0 END,
                  HoursToReApprove = CASE WHEN ReApprovedOn IS NOT NULL THEN CAST(DATEDIFF(MINUTE, UnapprovedOn, ReApprovedOn) / 60.0 AS DECIMAL(10, 1)) END;
    UPDATE u SET RevisedEmailedOn = (SELECT MIN(e.SentDate) FROM dbo.LabReportEmailLog e
                                      WHERE e.LabOrderId = u.LabOrderId AND e.IsRevised = 1 AND e.Status = 'Sent'
                                        AND e.SentDate >= DATEADD(MINUTE, -1, u.ReApprovedOn))
    FROM #U u WHERE u.ReApprovedOn IS NOT NULL;

    IF @OwnOnly = 1 DELETE FROM #U WHERE NOT (UnapprovedById = @UserId OR ApprovedById = @UserId);
    IF @WithdrawAction IS NOT NULL DELETE FROM #U WHERE WithdrawAction <> @WithdrawAction;
    IF @Outcome IS NOT NULL DELETE FROM #U WHERE Outcome <> @Outcome;
    IF @Amended = 'YES' DELETE FROM #U WHERE ISNULL(IsAmended, 0) = 0;
    IF @Amended = 'NO' DELETE FROM #U WHERE IsAmended IS NULL OR IsAmended = 1;
    IF @UnapprovedBy IS NOT NULL DELETE FROM #U WHERE UnapprovedById <> @UnapprovedBy;
    IF @DepartmentId IS NOT NULL DELETE FROM #U WHERE ISNULL(DepartmentId, 0) <> @DepartmentId;
    IF @Search IS NOT NULL DELETE FROM #U WHERE NOT (BillNo LIKE '%' + @Search + '%' OR TokenNo LIKE '%' + @Search + '%' OR PatientCode LIKE '%' + @Search + '%'
                                                      OR PatientName LIKE '%' + @Search + '%' OR TestName LIKE '%' + @Search + '%' OR Reason LIKE '%' + @Search + '%');

    SELECT u.*, ISNULL(dm.DeptName, 'Not set') AS Department,
           ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS ReApprovedByName
    INTO #R
    FROM #U u
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = u.DepartmentId
    LEFT JOIN dbo.Users ru ON ru.Id = u.ReApprovedById;

    -- results approved at the branch in the period (still approved, or withdrawn since): the base of the withdrawal rate.
    -- A branch-wide figure, so it is shown to Administrators only (an own-data view would compare against the whole branch).
    DECLARE @ApprovedInPeriod INT = CASE WHEN @OwnOnly = 1 THEN NULL ELSE
        (SELECT COUNT(1) FROM dbo.labentrydetails led
           INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
          WHERE led.IsActive = 1 AND led.ReportStatusId = 5 AND led.Approved_Date >= @From AND led.Approved_Date < @To
            AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId) OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId)))
      + (SELECT COUNT(1) FROM dbo.LabReportUnapproval un
           INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = un.SamplecollectionID
          WHERE un.PreviousApprovedDate >= @From AND un.PreviousApprovedDate < @To
            AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId) OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId))) END;

    -- RS1 summary
    SELECT COUNT(1) AS Withdrawals, COUNT(DISTINCT LabOrderId) AS Bills,
           SUM(CASE WHEN WithdrawAction = 'RETEST' THEN 1 ELSE 0 END) AS Retest,
           SUM(CASE WHEN WithdrawAction = 'RECOLLECT' THEN 1 ELSE 0 END) AS Recollect,
           SUM(CASE WHEN Outcome = 'REAPPROVED' THEN 1 ELSE 0 END) AS ReApproved,
           SUM(CASE WHEN Outcome = 'OPEN' THEN 1 ELSE 0 END) AS StillOpen,
           SUM(CASE WHEN IsAmended = 1 THEN 1 ELSE 0 END) AS Amended,
           SUM(CASE WHEN RevisedEmailedOn IS NOT NULL THEN 1 ELSE 0 END) AS RevisedEmailed,
           CAST(AVG(HoursToReApprove) AS DECIMAL(10, 1)) AS AvgHoursToReApprove,
           @ApprovedInPeriod AS ApprovedInPeriod,
           CAST(CASE WHEN @ApprovedInPeriod > 0 THEN COUNT(1) * 100.0 / @ApprovedInPeriod END AS DECIMAL(10, 2)) AS WithdrawalRatePct,
           (SELECT TOP 1 Reason FROM #R GROUP BY Reason ORDER BY COUNT(1) DESC, Reason) AS TopReason
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byReason' AS GroupKey, NULL AS GroupId, Reason AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byUnapprovedBy', UnapprovedById, UnapprovedByName, 0, * FROM #R
        UNION ALL SELECT 'byApprovedBy', ApprovedById, ISNULL(ApprovedByName, 'Not recorded'), 0, * FROM #R
        UNION ALL SELECT 'byTest', NULL, TestName, 0, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, UnapprovedDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Withdrawals,
           SUM(CASE WHEN WithdrawAction = 'RECOLLECT' THEN 1 ELSE 0 END) AS Recollect,
           SUM(CASE WHEN Outcome = 'REAPPROVED' THEN 1 ELSE 0 END) AS ReApproved,
           SUM(CASE WHEN Outcome = 'OPEN' THEN 1 ELSE 0 END) AS StillOpen,
           SUM(CASE WHEN IsAmended = 1 THEN 1 ELSE 0 END) AS Amended,
           SUM(CASE WHEN RevisedEmailedOn IS NOT NULL THEN 1 ELSE 0 END) AS RevisedEmailed,
           CAST(AVG(HoursToReApprove) AS DECIMAL(10, 1)) AS AvgHoursToReApprove
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, COUNT(1) DESC, GroupName;

    -- RS3 rows: still open first, then latest withdrawal first
    SELECT * FROM #R ORDER BY CASE Outcome WHEN 'OPEN' THEN 0 ELSE 1 END, UnapprovedOn DESC, UnapprovalId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL
    UNION ALL
    SELECT DISTINCT 'unapprovedBy', CAST(UnapprovedById AS VARCHAR(20)), UnapprovedByName FROM #R WHERE UnapprovedById IS NOT NULL;

    DROP TABLE #R; DROP TABLE #U;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > LAB) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.LABSIGNOFF',      N'Pathologist Sign-off Register',     N'LabSignOff',        190, N'bi bi-pen me-2'),
    (N'REPORTS.LABDISPATCHPRINT', N'Report Dispatch & Print Register', N'LabDispatchPrint',  195, N'bi bi-printer me-2'),
    (N'REPORTS.LABUNAUTHORIZED', N'Un-authorized & Amended Reports',   N'LabUnauthorized',   200, N'bi bi-arrow-counterclockwise me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pc; FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'Reports', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon,
                 @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2209 applied: Reports > LAB > LR-19, LR-20, LR-22.';
GO
