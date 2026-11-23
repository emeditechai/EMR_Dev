-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2447  LAB > Marketing Executive Sales Target  +  LAB > Doctor Visit Log
--   * MarketingTarget (per company / branch / LAB executive / financial year) with a frequency: MONTHLY (12 buckets),
--     QUARTERLY (4), HALFYEARLY (2), YEARLY (1). MarketingTargetBucket holds each bucket's sales target (Rs.) and
--     doctor-visit target (count). The financial year follows Acc_Settings.FinancialYearStartMonth (default April).
--   * MarketingDoctorVisit: visits of an executive to a Doctor Master doctor (the "actual" against the visit target,
--     together with the verified-or-not visits logged in the Marketing Executive App, ForecastDoctorVisit).
--     An executive login sees and logs its own visits only.
--   * usp_Api_LabReport_MarketingBusiness (Reports > LAB > Marketing Executive Business): the period target now comes
--     from these buckets only (each bucket pro-rated by the days of the report period inside it), plus visit target,
--     visits done and visit achievement. The old MonthlyTarget x months is no longer used by the report.
--   Pages LAB.MARKETINGTARGETS (VIEW, EDIT) and LAB.MARKETINGVISITS (VIEW, ADD, DELETE). No role grants.
--   Run after 2440-2445. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
IF OBJECT_ID('dbo.MarketingTarget') IS NULL
CREATE TABLE dbo.MarketingTarget (
    TargetId     INT IDENTITY(1,1) CONSTRAINT PK_MarketingTarget PRIMARY KEY,
    CompanyId    INT NOT NULL,
    BranchId     INT NOT NULL,
    ExecutiveId  INT NOT NULL CONSTRAINT FK_MarketingTarget_Executive REFERENCES dbo.MarketingExecutive (ExecutiveId),
    FyStart      DATE NOT NULL,
    FyLabel      VARCHAR(7) NOT NULL,
    Frequency    VARCHAR(10) NOT NULL CONSTRAINT CK_MarketingTarget_Frequency CHECK (Frequency IN ('MONTHLY','QUARTERLY','HALFYEARLY','YEARLY')),
    Remarks      NVARCHAR(500) NULL,
    CreatedBy    INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_MarketingTarget_Created DEFAULT (GETDATE()),
    ModifiedBy   INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UX_MarketingTarget UNIQUE (BranchId, ExecutiveId, FyStart)
);
GO
IF OBJECT_ID('dbo.MarketingTargetBucket') IS NULL
CREATE TABLE dbo.MarketingTargetBucket (
    BucketId     INT IDENTITY(1,1) CONSTRAINT PK_MarketingTargetBucket PRIMARY KEY,
    TargetId     INT NOT NULL CONSTRAINT FK_MarketingTargetBucket_Target REFERENCES dbo.MarketingTarget (TargetId) ON DELETE CASCADE,
    BucketNo     TINYINT NOT NULL,
    PeriodLabel  NVARCHAR(40) NOT NULL,
    FromDate     DATE NOT NULL,
    ToDate       DATE NOT NULL,
    SalesTarget  DECIMAL(18,2) NOT NULL CONSTRAINT CK_MarketingTargetBucket_Sales CHECK (SalesTarget >= 0),
    VisitTarget  INT NOT NULL CONSTRAINT CK_MarketingTargetBucket_Visit CHECK (VisitTarget >= 0),
    CONSTRAINT UX_MarketingTargetBucket UNIQUE (TargetId, BucketNo)
);
GO
IF OBJECT_ID('dbo.MarketingDoctorVisit') IS NULL
CREATE TABLE dbo.MarketingDoctorVisit (
    VisitId      INT IDENTITY(1,1) CONSTRAINT PK_MarketingDoctorVisit PRIMARY KEY,
    CompanyId    INT NOT NULL,
    BranchId     INT NOT NULL,
    ExecutiveId  INT NOT NULL CONSTRAINT FK_MarketingDoctorVisit_Executive REFERENCES dbo.MarketingExecutive (ExecutiveId),
    DoctorId     INT NOT NULL CONSTRAINT FK_MarketingDoctorVisit_Doctor REFERENCES dbo.DoctorMaster (DoctorId),
    VisitDate    DATETIME NOT NULL,
    Purpose      VARCHAR(20) NOT NULL CONSTRAINT CK_MarketingDoctorVisit_Purpose CHECK (Purpose IN ('INTRODUCTION','FOLLOW_UP','RELATIONSHIP','COLLECTION','COMPLAINT','OTHER')),
    Remarks      NVARCHAR(500) NULL,
    IsDeleted    BIT NOT NULL CONSTRAINT DF_MarketingDoctorVisit_Deleted DEFAULT (0),
    CreatedBy    INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_MarketingDoctorVisit_Created DEFAULT (GETDATE()),
    DeletedBy    INT NULL, DeletedDate DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MarketingDoctorVisit_Exec' AND object_id = OBJECT_ID('dbo.MarketingDoctorVisit'))
    CREATE INDEX IX_MarketingDoctorVisit_Exec ON dbo.MarketingDoctorVisit (BranchId, ExecutiveId, VisitDate) WHERE IsDeleted = 0;
GO

-- financial year of a date for a company: start date and label
CREATE OR ALTER FUNCTION dbo.fn_Mkt_FyStart (@CompanyId INT, @Date DATE)
RETURNS DATE
AS
BEGIN
    DECLARE @m TINYINT = ISNULL((SELECT FinancialYearStartMonth FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId), 4);
    IF @m NOT BETWEEN 1 AND 12 SET @m = 4;
    RETURN DATEFROMPARTS(YEAR(@Date) - CASE WHEN MONTH(@Date) < @m THEN 1 ELSE 0 END, @m, 1);
END;
GO

-- the buckets of a frequency for a financial year
CREATE OR ALTER FUNCTION dbo.fn_Mkt_Buckets (@FyStart DATE, @Frequency VARCHAR(10))
RETURNS TABLE
AS
RETURN
    WITH f AS (SELECT CASE @Frequency WHEN 'MONTHLY' THEN 1 WHEN 'QUARTERLY' THEN 3 WHEN 'HALFYEARLY' THEN 6 WHEN 'YEARLY' THEN 12 END AS M),
    n AS (SELECT v AS BucketNo FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) x(v))
    SELECT CAST(n.BucketNo AS TINYINT) AS BucketNo,
           DATEADD(MONTH, (n.BucketNo - 1) * f.M, @FyStart) AS FromDate,
           DATEADD(DAY, -1, DATEADD(MONTH, n.BucketNo * f.M, @FyStart)) AS ToDate,
           CAST(CASE @Frequency
                WHEN 'MONTHLY' THEN FORMAT(DATEADD(MONTH, n.BucketNo - 1, @FyStart), 'MMM yyyy', 'en-US')
                WHEN 'YEARLY'  THEN N'FY ' + dbo.fn_Acc_FinancialYear(@FyStart, MONTH(@FyStart))
                ELSE CASE @Frequency WHEN 'QUARTERLY' THEN N'Q' ELSE N'H' END + CAST(n.BucketNo AS NVARCHAR(2)) + N' (' +
                     FORMAT(DATEADD(MONTH, (n.BucketNo - 1) * f.M, @FyStart), 'MMM', 'en-US') + N'–' +
                     FORMAT(DATEADD(MONTH, n.BucketNo * f.M - 1, @FyStart), 'MMM yyyy', 'en-US') + N')' END AS NVARCHAR(40)) AS PeriodLabel
    FROM f JOIN n ON n.BucketNo <= 12 / f.M
    WHERE f.M IS NOT NULL;
GO

-- the executive a login belongs to (NULL when the user is not a marketing executive login)
CREATE OR ALTER FUNCTION dbo.fn_Mkt_OwnExecutive (@CompanyId INT, @UserId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT TOP 1 e.ExecutiveId FROM dbo.MarketingExecutive e JOIN dbo.Users u ON u.Id = e.LoginUserId
            WHERE e.LoginUserId = @UserId AND e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND u.Is_MarketingExecutive = 1);
END;
GO

-- ── targets ─────────────────────────────────────────────────────────────────────────────────────────────────
-- financial years to choose (previous, current, next two) with the current one marked
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktTarget_Years @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cur DATE = dbo.fn_Mkt_FyStart(@CompanyId, CAST(GETDATE() AS DATE));
    SELECT DATEADD(YEAR, v, @cur) AS FyStart, DATEADD(DAY, -1, DATEADD(YEAR, v + 1, @cur)) AS FyEnd,
           dbo.fn_Acc_FinancialYear(DATEADD(YEAR, v, @cur), MONTH(@cur)) AS FyLabel, CAST(CASE WHEN v = 0 THEN 1 ELSE 0 END AS BIT) AS IsCurrent
    FROM (VALUES (-1),(0),(1)) x(v) ORDER BY v;
END;
GO

-- the LAB executives of the branch's company with their target for the year (summary list)
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktTarget_List @CompanyId INT, @BranchId INT, @FyStart DATE, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    SELECT e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.IsActive, t.TargetId, t.Frequency,
           ISNULL(b.SalesTarget, 0) AS SalesTarget, ISNULL(b.VisitTarget, 0) AS VisitTarget, ISNULL(b.Buckets, 0) AS Buckets,
           t.ModifiedDate, ISNULL(um.FullName, uc.FullName) AS ModifiedByName, ISNULL(t.ModifiedDate, t.CreatedDate) AS LastChanged
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.MarketingTarget t ON t.ExecutiveId = e.ExecutiveId AND t.BranchId = @BranchId AND t.FyStart = @FyStart
    LEFT JOIN dbo.Users uc ON uc.Id = t.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = t.ModifiedBy
    OUTER APPLY (SELECT SUM(SalesTarget) AS SalesTarget, SUM(VisitTarget) AS VisitTarget, COUNT(1) AS Buckets FROM dbo.MarketingTargetBucket WHERE TargetId = t.TargetId) b
    WHERE e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
      AND (e.IsActive = 1 OR t.TargetId IS NOT NULL)
      AND (@own IS NULL OR e.ExecutiveId = @own)
    ORDER BY e.IsActive DESC, e.ExecutiveName;
END;
GO

-- one executive's target for a year. @Frequency NULL = the saved one (MONTHLY when nothing is saved); another frequency
-- returns its empty buckets (the screen asks before replacing the saved ones). RS1 header, RS2 buckets with actuals so far.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktTarget_Get @CompanyId INT, @BranchId INT, @ExecutiveId INT, @FyStart DATE, @Frequency VARCHAR(10) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL AND @own <> @ExecutiveId THROW 56101, 'You can see your own target only.', 1;
    DECLARE @TargetId INT, @Saved VARCHAR(10);
    SELECT @TargetId = TargetId, @Saved = Frequency FROM dbo.MarketingTarget WHERE BranchId = @BranchId AND ExecutiveId = @ExecutiveId AND FyStart = @FyStart;
    SET @Frequency = ISNULL(NULLIF(UPPER(@Frequency), ''), ISNULL(@Saved, 'MONTHLY'));
    IF @Frequency NOT IN ('MONTHLY','QUARTERLY','HALFYEARLY','YEARLY') THROW 56102, 'Choose the frequency.', 1;

    SELECT e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.IsActive, @FyStart AS FyStart, DATEADD(DAY, -1, DATEADD(YEAR, 1, @FyStart)) AS FyEnd,
           dbo.fn_Acc_FinancialYear(@FyStart, MONTH(@FyStart)) AS FyLabel, @Frequency AS Frequency, @Saved AS SavedFrequency, @TargetId AS TargetId,
           t.Remarks, t.CreatedDate, uc.FullName AS CreatedByName, t.ModifiedDate, um.FullName AS ModifiedByName,
           CAST(CASE WHEN @own IS NULL THEN 0 ELSE 1 END AS BIT) AS IsOwnView
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.MarketingTarget t ON t.TargetId = @TargetId
    LEFT JOIN dbo.Users uc ON uc.Id = t.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = t.ModifiedBy
    WHERE e.ExecutiveId = @ExecutiveId AND e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB';
    IF @@ROWCOUNT = 0 THROW 56103, 'The LAB marketing executive was not found.', 1;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT g.BucketNo, g.PeriodLabel, g.FromDate, g.ToDate,
           CAST(ISNULL(s.SalesTarget, 0) AS DECIMAL(18,2)) AS SalesTarget, ISNULL(s.VisitTarget, 0) AS VisitTarget,
           CAST(CASE WHEN g.ToDate < @today THEN 1 ELSE 0 END AS BIT) AS IsPast,
           CAST(CASE WHEN @today BETWEEN g.FromDate AND g.ToDate THEN 1 ELSE 0 END AS BIT) AS IsCurrent,
           CAST(ISNULL(sale.NetAmount, 0) AS DECIMAL(18,2)) AS SalesActual, ISNULL(v.Visits, 0) AS VisitActual
    FROM dbo.fn_Mkt_Buckets(@FyStart, @Frequency) g
    LEFT JOIN dbo.MarketingTargetBucket s ON s.TargetId = @TargetId AND @Saved = @Frequency AND s.BucketNo = g.BucketNo
    OUTER APPLY (SELECT SUM(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                                 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END) AS NetAmount
                 FROM dbo.LabOrder lo
                 LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
                 WHERE lo.BranchId = @BranchId AND lo.MarketingExecutiveId = @ExecutiveId AND g.FromDate <= @today
                   AND lo.OrderDate >= g.FromDate AND lo.OrderDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) sale
    OUTER APPLY (SELECT (SELECT COUNT(1) FROM dbo.MarketingDoctorVisit mv WHERE mv.BranchId = @BranchId AND mv.ExecutiveId = @ExecutiveId AND mv.IsDeleted = 0
                           AND mv.VisitDate >= g.FromDate AND mv.VisitDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME)))
                      + (SELECT COUNT(1) FROM dbo.ForecastDoctorVisit fv WHERE fv.BranchId = @BranchId AND fv.ExecutiveId = @ExecutiveId
                           AND fv.VisitDate >= g.FromDate AND fv.VisitDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) AS Visits) v
    ORDER BY g.BucketNo;
END;
GO

-- save: @Buckets = JSON [{ "bucketNo": 1, "salesTarget": 100000, "visitTarget": 40 }, ...] - one entry for every bucket
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktTarget_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @ExecutiveId INT, @FyStart DATE, @Frequency VARCHAR(10), @Buckets NVARCHAR(MAX), @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN mt_sp;
        SET @Frequency = UPPER(LTRIM(RTRIM(ISNULL(@Frequency, ''))));
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
        IF dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId) IS NOT NULL THROW 56110, 'A marketing executive cannot set targets.', 1;
        IF @Frequency NOT IN ('MONTHLY','QUARTERLY','HALFYEARLY','YEARLY') THROW 56111, 'Choose the frequency (Monthly, Quarterly, Half-yearly or Yearly).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId) THROW 56112, 'Your branch could not be found - sign in again.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0 AND ExecutiveType = 'LAB')
            THROW 56113, 'The LAB marketing executive was not found.', 1;
        IF @FyStart IS NULL OR @FyStart <> dbo.fn_Mkt_FyStart(@CompanyId, @FyStart) THROW 56114, 'Choose a financial year.', 1;
        IF @FyStart < DATEADD(YEAR, -1, dbo.fn_Mkt_FyStart(@CompanyId, CAST(GETDATE() AS DATE))) THROW 56115, 'Targets of a closed financial year (older than the previous one) cannot be changed.', 1;
        IF ISJSON(@Buckets) <> 1 THROW 56116, 'The targets could not be read.', 1;

        DECLARE @In TABLE (BucketNo INT, Sales DECIMAL(18,2), Visit DECIMAL(18,2));
        INSERT @In SELECT BucketNo, Sales, Visit FROM OPENJSON(@Buckets) WITH (BucketNo INT '$.bucketNo', Sales DECIMAL(18,2) '$.salesTarget', Visit DECIMAL(18,2) '$.visitTarget');
        DECLARE @need INT = (SELECT COUNT(1) FROM dbo.fn_Mkt_Buckets(@FyStart, @Frequency));
        IF (SELECT COUNT(DISTINCT BucketNo) FROM @In) <> @need OR (SELECT COUNT(1) FROM @In) <> @need
           OR EXISTS (SELECT 1 FROM @In i WHERE NOT EXISTS (SELECT 1 FROM dbo.fn_Mkt_Buckets(@FyStart, @Frequency) g WHERE g.BucketNo = i.BucketNo))
            THROW 56117, 'Enter the target of every period of the year.', 1;
        IF EXISTS (SELECT 1 FROM @In WHERE Sales IS NULL OR Sales < 0 OR Visit IS NULL OR Visit < 0) THROW 56118, 'Targets must be 0 or more.', 1;
        IF EXISTS (SELECT 1 FROM @In WHERE Visit <> FLOOR(Visit)) THROW 56119, 'Doctor visits are a whole number.', 1;
        IF EXISTS (SELECT 1 FROM @In WHERE Sales > 9999999999 OR Visit > 100000) THROW 56120, 'A target is too large.', 1;
        IF NOT EXISTS (SELECT 1 FROM @In WHERE Sales > 0 OR Visit > 0) THROW 56121, 'Enter at least one sales or doctor-visit target.', 1;

        DECLARE @TargetId INT = (SELECT TargetId FROM dbo.MarketingTarget WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND ExecutiveId = @ExecutiveId AND FyStart = @FyStart);
        IF @TargetId IS NULL
        BEGIN
            INSERT dbo.MarketingTarget (CompanyId, BranchId, ExecutiveId, FyStart, FyLabel, Frequency, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @ExecutiveId, @FyStart, dbo.fn_Acc_FinancialYear(@FyStart, MONTH(@FyStart)), @Frequency, @Remarks, @UserId);
            SET @TargetId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.MarketingTarget SET Frequency = @Frequency, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE TargetId = @TargetId;
            DELETE FROM dbo.MarketingTargetBucket WHERE TargetId = @TargetId;
        END
        INSERT dbo.MarketingTargetBucket (TargetId, BucketNo, PeriodLabel, FromDate, ToDate, SalesTarget, VisitTarget)
        SELECT @TargetId, g.BucketNo, g.PeriodLabel, g.FromDate, g.ToDate, i.Sales, CAST(i.Visit AS INT)
        FROM dbo.fn_Mkt_Buckets(@FyStart, @Frequency) g JOIN @In i ON i.BucketNo = g.BucketNo;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @TargetId AS TargetId,
               (SELECT SUM(Sales) FROM @In) AS SalesTarget, (SELECT SUM(CAST(Visit AS INT)) FROM @In) AS VisitTarget;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN mt_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── doctor visits ───────────────────────────────────────────────────────────────────────────────────────────
-- doctors for the visit form: the executive's tagged doctors first, then the other active doctors
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktVisit_Doctors @CompanyId INT, @ExecutiveId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName, d.PhoneNumber,
           CAST(CASE WHEN d.MarketingExecutiveId = @ExecutiveId THEN 1 ELSE 0 END AS BIT) AS IsTagged
    FROM dbo.DoctorMaster d
    WHERE d.IsActive = 1 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY CASE WHEN d.MarketingExecutiveId = @ExecutiveId THEN 0 ELSE 1 END, d.FullName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MktVisit_List
    @CompanyId INT, @BranchId INT, @UserId INT, @FromDate DATE, @ToDate DATE, @ExecutiveId INT = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL SET @ExecutiveId = @own;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    -- RS1 visits: logged here (LOG) and from the Marketing Executive App (APP)
    SELECT x.* FROM (
        SELECT 'LOG' AS Source, v.VisitId, v.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, v.DoctorId,
               LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName, v.VisitDate, v.Purpose, v.Remarks,
               CAST(NULL AS VARCHAR(10)) AS VisitStatus, u.FullName AS CreatedByName, v.CreatedDate,
               CAST(CASE WHEN v.CreatedBy = @UserId OR @own IS NULL THEN 1 ELSE 0 END AS BIT) AS CanDelete
        FROM dbo.MarketingDoctorVisit v
        JOIN dbo.MarketingExecutive e ON e.ExecutiveId = v.ExecutiveId
        JOIN dbo.DoctorMaster d ON d.DoctorId = v.DoctorId
        LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
        WHERE v.CompanyId = @CompanyId AND v.BranchId = @BranchId AND v.IsDeleted = 0 AND v.VisitDate >= @FromDate AND v.VisitDate < @To
          AND (@ExecutiveId IS NULL OR v.ExecutiveId = @ExecutiveId)
        UNION ALL
        SELECT 'APP', fv.VisitId, fv.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, NULL,
               LTRIM(RTRIM(ISNULL(fd.NamePrefix + ' ', '') + fd.FullName)), fv.VisitDate, fv.Outcome, fv.Notes, fv.VisitStatus, u.FullName, fv.VisitDate, CAST(0 AS BIT)
        FROM dbo.ForecastDoctorVisit fv
        JOIN dbo.MarketingExecutive e ON e.ExecutiveId = fv.ExecutiveId
        JOIN dbo.ForecastDoctor fd ON fd.ForecastDoctorId = fv.ForecastDoctorId
        LEFT JOIN dbo.Users u ON u.Id = fv.UserId
        WHERE e.CompanyId = @CompanyId AND fv.BranchId = @BranchId AND fv.VisitDate >= @FromDate AND fv.VisitDate < @To
          AND (@ExecutiveId IS NULL OR fv.ExecutiveId = @ExecutiveId)
    ) x
    WHERE @Search IS NULL OR x.DoctorName LIKE N'%' + @Search + N'%' OR x.ExecutiveName LIKE N'%' + @Search + N'%' OR x.Remarks LIKE N'%' + @Search + N'%'
    ORDER BY x.VisitDate DESC, x.VisitId DESC;
    -- RS2 executives to choose (own only for an executive login)
    SELECT e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.IsActive
    FROM dbo.MarketingExecutive e
    WHERE e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB' AND (@own IS NULL OR e.ExecutiveId = @own)
    ORDER BY e.IsActive DESC, e.ExecutiveName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MktVisit_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @ExecutiveId INT = NULL, @DoctorId INT, @VisitDate DATETIME, @Purpose VARCHAR(20), @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
        IF @own IS NOT NULL SET @ExecutiveId = @own;
        SET @Purpose = UPPER(LTRIM(RTRIM(ISNULL(@Purpose, ''))));
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId) THROW 56130, 'Your branch could not be found - sign in again.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0 AND IsActive = 1 AND ExecutiveType = 'LAB')
            THROW 56131, 'Choose an active LAB marketing executive.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND IsActive = 1) THROW 56132, 'Choose the doctor visited.', 1;
        IF @VisitDate IS NULL THROW 56133, 'Enter the date and time of the visit.', 1;
        IF @VisitDate > DATEADD(MINUTE, 10, GETDATE()) THROW 56134, 'The visit cannot be in the future.', 1;
        IF @VisitDate < DATEADD(DAY, CASE WHEN @own IS NULL THEN -90 ELSE -7 END, CAST(GETDATE() AS DATE))
            THROW 56135, 'The visit is too old to log (up to 7 days back for an executive, 90 days for the office).', 1;
        IF @Purpose NOT IN ('INTRODUCTION','FOLLOW_UP','RELATIONSHIP','COLLECTION','COMPLAINT','OTHER') THROW 56136, 'Choose the purpose of the visit.', 1;
        IF @Purpose = 'OTHER' AND @Remarks IS NULL THROW 56137, 'Enter remarks for a visit of purpose Other.', 1;
        IF EXISTS (SELECT 1 FROM dbo.MarketingDoctorVisit WHERE ExecutiveId = @ExecutiveId AND DoctorId = @DoctorId AND IsDeleted = 0
                   AND CAST(VisitDate AS DATE) = CAST(@VisitDate AS DATE))
            THROW 56138, 'A visit of this executive to this doctor is already logged for that day.', 1;
        INSERT dbo.MarketingDoctorVisit (CompanyId, BranchId, ExecutiveId, DoctorId, VisitDate, Purpose, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @ExecutiveId, @DoctorId, @VisitDate, @Purpose, @Remarks, @UserId);
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, CAST(SCOPE_IDENTITY() AS INT) AS VisitId;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_MktVisit_Delete @CompanyId INT, @BranchId INT, @UserId INT, @VisitId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    UPDATE dbo.MarketingDoctorVisit SET IsDeleted = 1, DeletedBy = @UserId, DeletedDate = GETDATE()
    WHERE VisitId = @VisitId AND CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0
      AND (@own IS NULL OR (CreatedBy = @UserId AND ExecutiveId = @own));
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, N'The visit was not found, or you cannot delete it.' AS Error, @VisitId AS VisitId;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @VisitId AS VisitId;
END;
GO

-- ── pages (LAB menu) ────────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB'), @page INT, @view INT, @ctl INT;
IF @menu IS NULL THROW 51460, 'Menu LAB is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'LAB.MARKETINGTARGETS', @Title = N'Marketing Executive Sales Target',
     @Controller = N'MarketingTargets', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 78, @Icon = N'bi bi-bullseye me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'Index', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'ListData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'Get', @Source = 'SEED';
SET @ctl = NULL;
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT';
IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Set / change targets', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MarketingTargets', @Action = N'Save', @Source = 'SEED';

SET @page = NULL; SET @view = NULL;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'LAB.MARKETINGVISITS', @Title = N'Doctor Visit Log',
     @Controller = N'MarketingTargets', @Action = N'Visits', @Show_In_Menu = 1, @Sort_Order = 79, @Icon = N'bi bi-geo-alt me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'Visits', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'VisitData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingTargets', @Action = N'VisitDoctors', @Source = 'SEED';
SET @ctl = NULL;
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'ADD';
IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ADD', @Title = N'Log a visit', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MarketingTargets', @Action = N'VisitSave', @Source = 'SEED';
SET @ctl = NULL;
SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'DELETE';
IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'DELETE', @Title = N'Delete a visit', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MarketingTargets', @Action = N'VisitDelete', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

-- ── Reports > LAB > Marketing Executive Business: targets from the Sales Target setup (2447) ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_MarketingBusiness
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @ExecutiveIds  VARCHAR(1000) = NULL,   -- E<ExecutiveId> / NONE, comma separated; NULL = all
    @ExecType      VARCHAR(5)    = NULL,   -- OPD / LAB / IPD / MED
    @BillingType   VARCHAR(3)    = NULL,   -- B2C / B2B
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CreatedBy INT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN @UserId END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @Months DECIMAL(9, 4) = (DATEDIFF(DAY, @FromDate, @ToDate) + 1) / 30.44;
    DECLARE @Company INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @ExecType = NULL;   -- this LAB report covers LAB marketing executives only (param kept for the caller)

    DECLARE @Ex TABLE (ExecKey VARCHAR(20) PRIMARY KEY);
    INSERT @Ex SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(ISNULL(@ExecutiveIds, ''), ',') WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @AnyEx BIT = CASE WHEN EXISTS (SELECT 1 FROM @Ex) THEN 0 ELSE 1 END;

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        CASE WHEN me.ExecutiveId IS NULL THEN 'NONE' ELSE 'E' + CAST(me.ExecutiveId AS VARCHAR(10)) END AS ExecKey,
        ISNULL(me.ExecutiveName, 'Not tagged') AS ExecutiveName, me.ExecutiveCode, me.ExecutiveType,
        dk.DoctorKey, ISNULL(dk.DoctorName, 'Self / Direct') AS RefDoctorName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber, NULLIF(LTRIM(RTRIM(p.Gender)), '') AS Gender,
        ISNULL(items.TestCount, 0) AS TestCount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0))
                  ELSE lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) END AS DECIMAL(18, 2)) AS BillAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0
                  WHEN ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) THEN ph.HeaderDiscountAmount
                  ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                  ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(0 AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(lo.IsB2B, 0) = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'PAID'
             WHEN ISNULL(lo.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT  JOIN dbo.MarketingExecutive me ON me.ExecutiveId = lo.MarketingExecutiveId /* 2445 */ AND me.IsDeleted = 0 AND me.ExecutiveType = 'LAB'
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    CROSS APPLY (SELECT
        CASE WHEN rdoc.DoctorId IS NOT NULL THEN 'D' + CAST(rdoc.DoctorId AS VARCHAR(10))
             WHEN rd.ReferralDoctorId IS NOT NULL THEN 'R' + CAST(rd.ReferralDoctorId AS VARCHAR(10)) ELSE 'SELF' END AS DoctorKey,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS DoctorName) dk
    OUTER APPLY (SELECT COUNT(1) AS TestCount FROM dbo.LabOrderItem loi WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT SUM(ISNULL(bc.CancelledAmount, 0) - ISNULL(bc.DiscountAdjusted, 0)) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1) canc
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR me.ExecutiveName LIKE '%' + @Search + '%' OR rdoc.FullName LIKE '%' + @Search + '%');
    DELETE FROM #R WHERE NOT (@AnyEx = 1 OR ExecKey IN (SELECT ExecKey FROM @Ex));
    IF @ExecType IS NOT NULL DELETE FROM #R WHERE ISNULL(ExecutiveType, '') <> @ExecType;
    UPDATE #R SET DueAmount = CASE WHEN IsCancelled = 0 AND NetAmount - PaidAmount > 0 THEN NetAmount - PaidAmount ELSE 0 END;

    -- the executives of the scope (with or without business in the period)
    SELECT 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) AS ExecKey, e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, e.MonthlyTarget, e.IsActive,
           CAST(0 AS DECIMAL(18, 2)) AS PeriodTarget, CAST(0 AS DECIMAL(18, 1)) AS VisitTarget, 0 AS VisitCount, CAST(NULL AS VARCHAR(10)) AS Frequency
    INTO #E
    FROM dbo.MarketingExecutive e
    WHERE e.CompanyId = @Company AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
      AND (@ExecType IS NULL OR e.ExecutiveType = @ExecType)
      AND (@AnyEx = 1 OR 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) IN (SELECT ExecKey FROM @Ex))
      AND (e.IsActive = 1 OR EXISTS (SELECT 1 FROM #R r WHERE r.ExecKey = 'E' + CAST(e.ExecutiveId AS VARCHAR(10))));

    -- 2447: targets from LAB > Marketing Executive Sales Target (this branch): each bucket pro-rated by the days of the period inside it
    UPDATE x SET PeriodTarget = ISNULL(t.Sales, 0), VisitTarget = ISNULL(t.Visit, 0), Frequency = t.Frequency,
                 VisitCount = (SELECT COUNT(1) FROM dbo.MarketingDoctorVisit mv WHERE mv.BranchId = @BranchId AND mv.IsDeleted = 0
                                  AND 'E' + CAST(mv.ExecutiveId AS VARCHAR(10)) = x.ExecKey AND mv.VisitDate >= @From AND mv.VisitDate < @To)
                            + (SELECT COUNT(1) FROM dbo.ForecastDoctorVisit fv WHERE fv.BranchId = @BranchId
                                  AND 'E' + CAST(fv.ExecutiveId AS VARCHAR(10)) = x.ExecKey AND fv.VisitDate >= @From AND fv.VisitDate < @To)
    FROM #E x
    OUTER APPLY (SELECT SUM(b.SalesTarget * o.Days / (DATEDIFF(DAY, b.FromDate, b.ToDate) + 1.0)) AS Sales,
                        SUM(b.VisitTarget * o.Days / (DATEDIFF(DAY, b.FromDate, b.ToDate) + 1.0)) AS Visit,
                        MAX(mt.Frequency) AS Frequency
                 FROM dbo.MarketingTarget mt
                 JOIN dbo.MarketingTargetBucket b ON b.TargetId = mt.TargetId
                 CROSS APPLY (SELECT DATEDIFF(DAY, CASE WHEN b.FromDate > @FromDate THEN b.FromDate ELSE @FromDate END,
                                                   CASE WHEN b.ToDate < @ToDate THEN b.ToDate ELSE @ToDate END) + 1 AS Days) o
                 WHERE mt.BranchId = @BranchId AND 'E' + CAST(mt.ExecutiveId AS VARCHAR(10)) = x.ExecKey
                   AND b.FromDate <= @ToDate AND b.ToDate >= @FromDate) t;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PatientCode) AS PatientCount, COUNT(DISTINCT CASE WHEN DoctorKey <> 'SELF' THEN DoctorKey END) AS DoctorCount,
           (SELECT COUNT(1) FROM #E) AS ExecutiveCount, COUNT(DISTINCT CASE WHEN ExecKey <> 'NONE' THEN ExecKey END) AS ExecutivesWithBusiness,
           SUM(CASE WHEN ExecKey = 'NONE' THEN 1 ELSE 0 END) AS UntaggedBills,
           ISNULL(SUM(TestCount), 0) AS TestCount, ISNULL(SUM(BillAmount), 0) AS BillAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount,
           ISNULL(SUM(DueAmount), 0) AS DueAmount,
           ISNULL(SUM(CASE WHEN ExecKey <> 'NONE' THEN NetAmount END), 0) AS TaggedNetAmount,
           CAST(ISNULL((SELECT SUM(PeriodTarget) FROM #E), 0) AS DECIMAL(18, 2)) AS PeriodTarget,
           CAST(ISNULL((SELECT SUM(VisitTarget) FROM #E), 0) AS DECIMAL(18, 1)) AS VisitTarget, ISNULL((SELECT SUM(VisitCount) FROM #E), 0) AS VisitCount,
           CAST(@Months AS DECIMAL(9, 2)) AS PeriodMonths
    FROM #R;

    -- RS2 groups: byExecutive (every executive of the scope + Not tagged) and byDoctor (executive -> doctor)
    SELECT 'byExecutive' AS GroupKey, x.ExecKey, x.ExecutiveName, x.ExecutiveCode, x.ExecutiveType, x.MonthlyTarget, x.IsActive,
           x.PeriodTarget,
           CAST(NULL AS VARCHAR(20)) AS DoctorKey, CAST(NULL AS NVARCHAR(200)) AS DoctorName,
           ISNULL(b.DoctorCount, 0) AS DoctorCount, ISNULL(b.BillCount, 0) AS BillCount, ISNULL(b.PatientCount, 0) AS PatientCount, ISNULL(b.TestCount, 0) AS TestCount,
           ISNULL(b.BillAmount, 0) AS BillAmount, ISNULL(b.DiscountAmount, 0) AS DiscountAmount, ISNULL(b.CancelledAmount, 0) AS CancelledAmount,
           ISNULL(b.NetAmount, 0) AS NetAmount, ISNULL(b.PaidAmount, 0) AS PaidAmount, ISNULL(b.DueAmount, 0) AS DueAmount,
           CAST(CASE WHEN x.PeriodTarget > 0 THEN ISNULL(b.NetAmount, 0) * 100 / x.PeriodTarget END AS DECIMAL(9, 1)) AS AchievementPct,
           CASE WHEN x.ExecKey = 'NONE' THEN 1 ELSE 0 END AS SortOrder,
           x.VisitTarget, x.VisitCount, CAST(CASE WHEN x.VisitTarget > 0 THEN x.VisitCount * 100.0 / x.VisitTarget END AS DECIMAL(9, 1)) AS VisitAchievementPct, x.Frequency
    FROM (SELECT ExecKey, ExecutiveName, ExecutiveCode, ExecutiveType, MonthlyTarget, IsActive, PeriodTarget, VisitTarget, VisitCount, Frequency FROM #E
          UNION ALL
          SELECT 'NONE', 'Not tagged', NULL, NULL, 0, CAST(1 AS BIT), 0, 0, 0, NULL WHERE @ExecType IS NULL AND (@AnyEx = 1 OR EXISTS (SELECT 1 FROM @Ex WHERE ExecKey = 'NONE'))) x
    OUTER APPLY (SELECT COUNT(DISTINCT CASE WHEN r.DoctorKey <> 'SELF' THEN r.DoctorKey END) AS DoctorCount, COUNT(1) AS BillCount, COUNT(DISTINCT r.PatientCode) AS PatientCount,
                        SUM(r.TestCount) AS TestCount, SUM(r.BillAmount) AS BillAmount, SUM(r.DiscountAmount) AS DiscountAmount, SUM(r.CancelledAmount) AS CancelledAmount,
                        SUM(r.NetAmount) AS NetAmount, SUM(r.PaidAmount) AS PaidAmount, SUM(r.DueAmount) AS DueAmount
                 FROM #R r WHERE r.ExecKey = x.ExecKey) b
    UNION ALL
    SELECT 'byDoctor', r.ExecKey, MAX(r.ExecutiveName), MAX(r.ExecutiveCode), MAX(r.ExecutiveType), NULL, NULL, NULL,
           r.DoctorKey, MAX(r.RefDoctorName), 1, COUNT(1), COUNT(DISTINCT r.PatientCode), SUM(r.TestCount),
           SUM(r.BillAmount), SUM(r.DiscountAmount), SUM(r.CancelledAmount), SUM(r.NetAmount), SUM(r.PaidAmount), SUM(r.DueAmount), NULL,
           CASE WHEN r.ExecKey = 'NONE' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL
    FROM #R r GROUP BY r.ExecKey, r.DoctorKey
    ORDER BY GroupKey DESC, SortOrder, NetAmount DESC, ExecutiveName;

    -- RS3 bills (executive, doctor, date)
    SELECT * FROM #R ORDER BY CASE WHEN ExecKey = 'NONE' THEN 1 ELSE 0 END, ExecutiveName, RefDoctorName, BillDate, LabOrderId;

    -- RS4 options: the company's executives, and Not tagged
    SELECT 'executive' AS FilterKey, 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) AS Value,
           e.ExecutiveName + N' — ' + CASE e.ExecutiveType WHEN 'MED' THEN N'MED (Pharmacy)' ELSE e.ExecutiveType END + N' (' + e.ExecutiveCode + N')'
               + CASE WHEN e.IsActive = 0 THEN N' · inactive' ELSE N'' END AS Text
    FROM dbo.MarketingExecutive e WHERE e.CompanyId = @Company AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
    UNION ALL SELECT 'executive', 'NONE', N'Not tagged'
    ORDER BY 3;

    -- RS5 lines of the bills (tests / profiles / packages, cancelled ones marked, misc charges)
    SELECT x.LabOrderId, ROW_NUMBER() OVER (PARTITION BY x.LabOrderId ORDER BY x.Kind, x.ItemId) AS LineSeq, x.TestCode, x.TestName, x.ItemType, x.Rate, x.IsCancelled
      FROM (
    SELECT loi.LabOrderId, 0 AS Kind, loi.LabOrderItemId AS ItemId,
           CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
           ISNULL(CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END, 'Unknown test') AS TestName,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           CAST(CASE WHEN r.BillingType = 'B2B' THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END AS DECIMAL(18, 2)) AS Rate,
           CAST(CASE WHEN loi.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled
      FROM #R r JOIN dbo.LabOrderItem loi ON loi.LabOrderId = r.LabOrderId
      LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
      LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    UNION ALL
    SELECT mc.LabOrderId, 1, mc.LabOrderMiscChargeId, 'MISC', mc.ChargeName, 'Misc', CAST(ISNULL(mc.NetAmount, mc.Amount) AS DECIMAL(18, 2)),
           CAST(CASE WHEN mc.IsActive = 0 THEN 1 ELSE 0 END AS BIT)
      FROM #R r JOIN dbo.LabOrderMiscCharge mc ON mc.LabOrderId = r.LabOrderId
      ) x
     ORDER BY x.LabOrderId, LineSeq;

    DROP TABLE #R; DROP TABLE #E;
END;
GO
PRINT '2447 Marketing sales target, doctor visit log, report targets - done.';
GO
