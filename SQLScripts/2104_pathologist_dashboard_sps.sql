-- ============================================================================
-- Migration: 2104_pathologist_dashboard_sps.sql
-- Description:
--   The read / write procedures behind the Pathologist Dashboard (see 2103 for the scope rules).
--     dbo.usp_Api_PathologistDashboard_GetAccess     who am I + the departments / categories I may filter by
--     dbo.usp_Api_PathologistDashboard_GetHeaderList summary cards + the bill list awaiting my signature
--     dbo.usp_Api_PathologistDashboard_GetDetail     one bill: header, its in-scope tests, level state, history
--     dbo.usp_Api_PathologistDashboard_Approve       sign off the selected tests at the next level
--   Also: dbo.usp_LabUnapprove_Execute now clears the per-level sign-off records, so a withdrawn report
--   starts again at level 1.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. profile + filter lists ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PathologistDashboard_GetAccess
    @UserId   INT,
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: the pathologist profile (IsPathologist / branch assignment decide access)
    SELECT
        u.Id                                                          AS UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)      AS FullName,
        u.RegistrationNo,
        u.SignaturePath,
        CAST(ISNULL(u.IsPathologist, 0) AS BIT)                       AS IsPathologist,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.UserBranches ub
                               WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
                  THEN 1 ELSE 0 END AS BIT)                           AS HasBranchAccess,
        ISNULL(u.DepartmentIds, '')                                   AS DepartmentIds,
        ISNULL(u.PathologistCategoryIds, '')                          AS CategoryIds,
        b.BranchName
    FROM dbo.Users u
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = @BranchId
    WHERE u.Id = @UserId AND ISNULL(u.IsActive, 0) = 1;

    -- RS2: the departments this pathologist may filter by
    SELECT d.DeptId AS DepartmentId, d.DeptName AS DepartmentName
    FROM dbo.DepartmentMaster d
    WHERE EXISTS (SELECT 1 FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) s WHERE s.DepartmentId = d.DeptId)
       OR d.DeptId IN (
            SELECT TRY_CAST(LTRIM(RTRIM(v.value)) AS INT)
            FROM dbo.Users u CROSS APPLY STRING_SPLIT(ISNULL(NULLIF(LTRIM(RTRIM(u.DepartmentIds)), ''), '0'), ',') v
            WHERE u.Id = @UserId)
    ORDER BY d.DeptName;

    -- RS3: the test categories this pathologist signs off
    SELECT c.Category_ID AS CategoryId, c.Category_Name AS CategoryName, c.Department_ID AS DepartmentId
    FROM dbo.LabTestCategoryMaster c
    WHERE ISNULL(c.IsDeleted, 0) = 0
      AND c.Category_ID IN (
            SELECT TRY_CAST(LTRIM(RTRIM(v.value)) AS INT)
            FROM dbo.Users u CROSS APPLY STRING_SPLIT(ISNULL(NULLIF(LTRIM(RTRIM(u.PathologistCategoryIds)), ''), '0'), ',') v
            WHERE u.Id = @UserId)
    ORDER BY c.Category_Name;
END;
GO
PRINT 'Created dbo.usp_Api_PathologistDashboard_GetAccess';
GO

-- ── 2. the bill list awaiting signature ─────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PathologistDashboard_GetHeaderList
    @UserId       INT,
    @BranchId     INT,
    @FromDate     DATETIME      = NULL,
    @ToDate       DATETIME      = NULL,
    @DateBasis    VARCHAR(20)   = 'BookingDate',   -- BookingDate | ValidatedDate
    @Search       NVARCHAR(100) = NULL,
    @DepartmentId INT           = NULL,
    @CategoryId   INT           = NULL,
    @StatusFilter VARCHAR(20)   = 'PENDING'        -- PENDING | MINE | APPROVED | ALL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(CAST(GETDATE() AS DATE) AS DATETIME);
    IF @ToDate   IS NULL SET @ToDate   = DATEADD(SECOND, 86399, CAST(CAST(GETDATE() AS DATE) AS DATETIME));
    ELSE IF CAST(@ToDate AS TIME) = '00:00:00'
        SET @ToDate = DATEADD(SECOND, 86399, CAST(CAST(@ToDate AS DATE) AS DATETIME));

    SET @DateBasis    = UPPER(LTRIM(RTRIM(ISNULL(@DateBasis, 'BOOKINGDATE'))));
    SET @StatusFilter = UPPER(LTRIM(RTRIM(ISNULL(@StatusFilter, 'PENDING'))));
    SET @Search       = NULLIF(LTRIM(RTRIM(@Search)), '');
    IF @DepartmentId <= 0 SET @DepartmentId = NULL;
    IF @CategoryId   <= 0 SET @CategoryId   = NULL;

    SELECT s.*, led.Validated_date
    INTO #Scope
    FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) s
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = s.SamplecollectionID AND led.IsActive = 1
    WHERE (@DepartmentId IS NULL OR s.DepartmentId = @DepartmentId)
      AND (@CategoryId   IS NULL OR s.CategoryId   = @CategoryId);

    SELECT
        sp.LabOrderId,
        COUNT(1)                                                                   AS ScopeTests,
        SUM(CASE WHEN sp.CanApproveNow = 1 THEN 1 ELSE 0 END)                      AS AwaitingMeTests,
        SUM(CASE WHEN sp.IsApproved = 1 THEN 1 ELSE 0 END)                         AS ApprovedTests,
        SUM(CASE WHEN sp.IsApproved = 0 AND sp.CanApproveNow = 0 THEN 1 ELSE 0 END) AS AwaitingOthersTests,
        MAX(sp.TotalLevels)                                                        AS TotalLevels,
        MIN(CASE WHEN sp.IsApproved = 0 THEN sp.LevelsDone END)                    AS LevelsDone,
        MAX(sp.Validated_date)                                                     AS ValidatedDate,
        MAX(sp.Flow_Name)                                                          AS FlowName
    INTO #Agg
    FROM #Scope sp
    GROUP BY sp.LabOrderId;

    SELECT
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        lo.OrderDate                                              AS BillingDate,
        ISNULL(lo.BookingDate, lo.OrderDate)                      AS BookingDateTime,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END                                                  AS Age,
        p.Gender,
        p.PhoneNumber,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END          AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName,
        ag.ScopeTests, ag.AwaitingMeTests, ag.ApprovedTests, ag.AwaitingOthersTests,
        ag.TotalLevels, ISNULL(ag.LevelsDone, ag.TotalLevels) AS LevelsDone,
        ag.ValidatedDate, ag.FlowName,
        CASE WHEN ag.AwaitingMeTests > 0 THEN 'AWAITING_ME'
             WHEN ag.ApprovedTests = ag.ScopeTests THEN 'APPROVED'
             ELSE 'AWAITING_OTHER' END                            AS DashboardStatus,
        STUFF((SELECT DISTINCT ', ' + d2.DeptName
               FROM #Scope s2 LEFT JOIN dbo.DepartmentMaster d2 ON d2.DeptId = s2.DepartmentId
               WHERE s2.LabOrderId = lo.LabOrderId FOR XML PATH('')), 1, 2, '') AS Departments,
        STUFF((SELECT DISTINCT ', ' + c2.Category_Name
               FROM #Scope s3 LEFT JOIN dbo.LabTestCategoryMaster c2 ON c2.Category_ID = s3.CategoryId
               WHERE s3.LabOrderId = lo.LabOrderId FOR XML PATH('')), 1, 2, '') AS Categories
    INTO #Bills
    FROM #Agg ag
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = ag.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId   = lo.PatientId
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE (
            (@DateBasis = 'VALIDATEDDATE' AND ag.ValidatedDate BETWEEN @FromDate AND @ToDate)
         OR (@DateBasis <> 'VALIDATEDDATE' AND ISNULL(lo.BookingDate, lo.OrderDate) BETWEEN @FromDate AND @ToDate)
          )
      AND (
            @Search IS NULL
         OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
         OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
         OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
         OR (ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, '')) LIKE '%' + @Search + '%'
          );

    -- RS1: summary cards (computed before the status filter, so the cards stay stable)
    SELECT
        COUNT(1)                                                                       AS TotalBills,
        ISNULL(SUM(CASE WHEN DashboardStatus = 'AWAITING_ME'    THEN 1 ELSE 0 END), 0) AS AwaitingMeBills,
        ISNULL(SUM(CASE WHEN DashboardStatus = 'AWAITING_OTHER' THEN 1 ELSE 0 END), 0) AS AwaitingOtherBills,
        ISNULL(SUM(CASE WHEN DashboardStatus = 'APPROVED'       THEN 1 ELSE 0 END), 0) AS ApprovedBills,
        ISNULL(SUM(AwaitingMeTests), 0)                                                AS AwaitingMeTests,
        ISNULL(SUM(ApprovedTests), 0)                                                  AS ApprovedTests,
        ISNULL(SUM(ScopeTests), 0)                                                     AS TotalTests,
        ISNULL(SUM(CASE WHEN IsUrgent = 1 AND DashboardStatus = 'AWAITING_ME' THEN 1 ELSE 0 END), 0) AS UrgentAwaitingBills
    FROM #Bills;

    -- RS2: the list
    SELECT * FROM #Bills
    WHERE @StatusFilter = 'ALL'
       OR (@StatusFilter IN ('PENDING', 'MINE') AND DashboardStatus = 'AWAITING_ME')
       OR (@StatusFilter = 'APPROVED' AND DashboardStatus = 'APPROVED')
    ORDER BY IsUrgent DESC,
             CASE WHEN DashboardStatus = 'AWAITING_ME' THEN 0 ELSE 1 END,
             ISNULL(ValidatedDate, BookingDateTime) DESC,
             LabOrderId DESC;

    DROP TABLE #Bills; DROP TABLE #Agg; DROP TABLE #Scope;
END;
GO
PRINT 'Created dbo.usp_Api_PathologistDashboard_GetHeaderList';
GO

-- ── 3. one bill: header, in-scope tests, level state, sign-off history ──────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PathologistDashboard_GetDetail
    @LabOrderId INT,
    @UserId     INT,
    @BranchId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT * INTO #S FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) WHERE LabOrderId = @LabOrderId;

    -- RS1: bill / patient header
    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.IsUrgent,
        lo.OrderDate AS BillingDate, ISNULL(lo.BookingDate, lo.OrderDate) AS BookingDateTime,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE WHEN p.DateOfBirth IS NOT NULL
             THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                  - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
             END AS Age,
        p.Gender, p.PhoneNumber, p.EmailId,
        CASE WHEN lo.IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.IsB2B = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END END AS ClientName,
        (SELECT COUNT(1) FROM #S)                                     AS ScopeTests,
        (SELECT COUNT(1) FROM #S WHERE CanApproveNow = 1)             AS AwaitingMeTests,
        (SELECT COUNT(1) FROM #S WHERE IsApproved = 1)                AS ApprovedTests
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: the tests this pathologist may see, with the result and the level state
    SELECT
        s.SamplecollectionID, s.InvestigationID,
        lim.Test_Code AS TestCode, lim.Test_Name AS TestName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName) AS GroupName,
        sc.ProfileId,
        ISNULL(d.DeptName, '')        AS DepartmentName,
        ISNULL(c.Category_Name, '')   AS CategoryName,
        sc.BarcodeNo,
        led.TestValue, led.AbnormalFlag, led.Remarks, led.Reporting_Type AS ReportingType,
        ISNULL(u_unit.Unit_Symbol, u_unit.Unit_Name) AS UnitName,
        led.Validated_date AS ValidatedDate, led.Approved_Date AS ApprovedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(uv.FullName)), ''), uv.Username) AS ValidatedByName,
        s.ReportStatusId, s.Flow_ID, s.Flow_Name, s.TotalLevels, s.LevelsDone, s.NextLevelNo,
        s.CanApproveNow, s.IsApproved,
        -- who is expected to sign the next level
        STUFF((SELECT DISTINCT ', ' + ISNULL(NULLIF(LTRIM(RTRIM(un.FullName)), ''), un.Username)
               FROM dbo.LabApprovalFlowLevel l
               JOIN dbo.LabApprovalFlowApprover ap ON ap.Level_ID = l.Level_ID
               JOIN dbo.Users un ON un.Id = ap.UserId
               WHERE l.Flow_ID = s.Flow_ID AND l.Level_No = s.NextLevelNo
               FOR XML PATH('')), 1, 2, '') AS NextLevelApprovers,
        (SELECT l.Level_Title FROM dbo.LabApprovalFlowLevel l
          WHERE l.Flow_ID = s.Flow_ID AND l.Level_No = s.NextLevelNo)  AS NextLevelTitle
    FROM #S s
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = s.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = s.SamplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.DepartmentMaster d ON d.DeptId = s.DepartmentId
    LEFT  JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = s.CategoryId
    LEFT  JOIN dbo.LabUnitMaster u_unit ON u_unit.Unit_ID = lim.Unit_ID
    LEFT  JOIN dbo.Users uv ON uv.Id = led.ModifiedBy
    ORDER BY ISNULL(d.DeptName, ''), COALESCE(sc.ProfileName, ''), lim.Test_Name;

    -- RS3: the sign-off history of this bill (every level already signed)
    SELECT a.SamplecollectionID, a.Level_No, a.TotalLevels, a.IsFinalLevel,
           a.ApprovedDate, a.Remarks,
           ISNULL(NULLIF(LTRIM(RTRIM(ua.FullName)), ''), ua.Username) AS ApprovedByName,
           lim.Test_Name AS TestName,
           (SELECT l.Level_Title FROM dbo.LabApprovalFlowLevel l
             WHERE l.Flow_ID = a.Flow_ID AND l.Level_No = a.Level_No) AS LevelTitle
    FROM dbo.LabReportApproval a
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = a.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.Users ua ON ua.Id = a.ApprovedBy
    WHERE a.LabOrderId = @LabOrderId
    ORDER BY a.ApprovedDate DESC, a.Level_No DESC;

    DROP TABLE #S;
END;
GO
PRINT 'Created dbo.usp_Api_PathologistDashboard_GetDetail';
GO

-- ── 4. sign off the selected tests at the next level ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PathologistDashboard_Approve
    @LabOrderId          INT,
    @SamplecollectionIds NVARCHAR(MAX),
    @UserId              INT,
    @BranchId            INT,
    @Remarks             NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN RAISERROR('Valid LabOrderId is required.', 16, 1); RETURN; END

    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT @Ids (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@SamplecollectionIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @Ids)
    BEGIN RAISERROR('Select at least one test to approve.', 16, 1); RETURN; END

    -- the caller's own scope decides what may be signed; nothing else is trusted
    SELECT s.* INTO #Can
    FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) s
    INNER JOIN @Ids i ON i.Id = s.SamplecollectionID
    WHERE s.LabOrderId = @LabOrderId AND s.CanApproveNow = 1;

    IF (SELECT COUNT(1) FROM #Can) <> (SELECT COUNT(1) FROM @Ids)
    BEGIN
        DROP TABLE #Can;
        RAISERROR('One or more selected tests are not awaiting your signature (wrong level, out of your department / category access, or already approved). Refresh and try again.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME = GETDATE();

    BEGIN TRAN;

    INSERT dbo.LabReportApproval
        (LabOrderId, SamplecollectionID, InvestigationID, Flow_ID, Level_No, TotalLevels, IsFinalLevel, ApprovedBy, ApprovedDate, Remarks, BranchId)
    SELECT @LabOrderId, c.SamplecollectionID, c.InvestigationID, c.Flow_ID, c.NextLevelNo, c.TotalLevels,
           CASE WHEN c.NextLevelNo >= c.TotalLevels THEN 1 ELSE 0 END,
           @UserId, @Now, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @BranchId
    FROM #Can c;

    -- the test becomes Approved only when the LAST level has signed
    UPDATE led
    SET led.ReportStatusId = 5,
        led.Approved_Date  = @Now,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = @Now
    FROM dbo.labentrydetails led
    INNER JOIN #Can c ON c.SamplecollectionID = led.SamplecollectionID
    WHERE c.NextLevelNo >= c.TotalLevels
      AND led.IsActive = 1;

    DECLARE @Signed INT = (SELECT COUNT(1) FROM #Can);
    DECLARE @Final  INT = (SELECT COUNT(1) FROM #Can WHERE NextLevelNo >= TotalLevels);

    COMMIT;

    DROP TABLE #Can;

    SELECT @Signed AS SignedCount, @Final AS FinalApprovedCount;
END;
GO
PRINT 'Created dbo.usp_Api_PathologistDashboard_Approve';
GO

-- ── 5. a withdrawn report restarts at Level 1 ──────────────────────────────
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

    INSERT dbo.LabReportUnapproval
        (LabOrderId, SamplecollectionID, InvestigationID, PreviousStatusId, NewStatusId, TestValue, PreviousApprovedDate, Reason, [Action], UnapprovedBy, UnapprovedDate)
    SELECT @LabOrderId, led.SamplecollectionID, led.InvestigationID, 5, @NewStatusId, led.TestValue, led.Approved_Date, @Reason, @Action, @UserId, @Now
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

PRINT 'usp_LabUnapprove_Execute now clears the per-level sign-offs.';
GO
