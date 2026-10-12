-- ============================================================================
-- Migration: 2252_qc_internal_qc.sql
-- Description: Quality & Compliance - LF-05 Internal QC (ISO 15189 7.3.7.2, CLSI C24, Westgard multirule).
--   QC materials (manufacturer, level, matrix; optionally the Item Master's control item) and their lots (lot no.,
--   expiry, opened on). Targets: mean and SD of a lot on an analyzer for a parameter (manufacturer's or lab-established),
--   optional 4-1s / 10x rules.
--   Daily QC: a run = the control levels of one parameter on one analyzer at one time. Every run is judged:
--     1-2s warning (|z| > 2); rejection: 1-3s (|z| > 3), 2-2s (two levels beyond 2 SD on the same side in the run, or the
--     same level in this and the previous run), R-4s (one level > +2 SD and another < -2 SD in the run), 4-1s and 10x
--     when switched on for the target. An expired or inactive lot cannot be used.
--   A REJECTED run blocks Validate / Approve of that parameter (Lab Reporting Entry, Microbiology entry, Report Approval
--   Dashboard) for the samples run at that branch until the corrective action is recorded (root cause, action, patient
--   results look-back; a CAPA can be raised). The block is checked by the web screens (clear message) and enforced in
--   dbo.usp_LabReporting_SaveEntry and dbo.usp_Api_PathologistDashboard_Approve.
--   Levey-Jennings data: points with z and the rules they broke, and the lab's own mean / SD / CV of accepted runs.
--   Report: Reports > LAB > IQC Run Register ("iqc-runs").
--   QcCapa gets the source IQC. No role is granted (Settings > Security). Rules: THROW 55000-55999. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. CAPA source IQC ---------------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_QcCapa_Source' AND definition NOT LIKE '%IQC%')
BEGIN
    ALTER TABLE dbo.QcCapa DROP CONSTRAINT CK_QcCapa_Source;
    ALTER TABLE dbo.QcCapa ADD CONSTRAINT CK_QcCapa_Source CHECK (SourceType IN ('EQAS', 'CALIBRATION', 'BREAKDOWN', 'IQC', 'OTHER'));
END
GO

-- 2. Tables --------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.IqcMaterial', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IqcMaterial
    (
        MaterialId    INT IDENTITY(1,1) CONSTRAINT PK_IqcMaterial PRIMARY KEY,
        CompanyId     INT NOT NULL,
        MaterialName  NVARCHAR(200) NOT NULL,         -- e.g. Lyphochek Assayed Chemistry Control
        Manufacturer  NVARCHAR(150) NULL,
        ControlLevel  NVARCHAR(30) NOT NULL,          -- Level 1 / Level 2 / Level 3 / Normal / Abnormal / Positive / Negative
        Matrix        NVARCHAR(100) NULL,             -- human serum, whole blood, urine ...
        ItemId        INT NULL,                       -- InvItem (Control / Calibrator) for stock and BOM
        DepartmentId  INT NULL,
        Remarks       NVARCHAR(500) NULL,
        Status        BIT NOT NULL CONSTRAINT DF_IqcMaterial_Status DEFAULT 1,
        IsDeleted     BIT NOT NULL CONSTRAINT DF_IqcMaterial_Deleted DEFAULT 0,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME NOT NULL CONSTRAINT DF_IqcMaterial_Created DEFAULT GETDATE()
    );
    CREATE TABLE dbo.IqcLot
    (
        LotId       INT IDENTITY(1,1) CONSTRAINT PK_IqcLot PRIMARY KEY,
        MaterialId  INT NOT NULL CONSTRAINT FK_IqcLot_Material REFERENCES dbo.IqcMaterial(MaterialId),
        LotNo       NVARCHAR(50) NOT NULL,
        ExpiryDate  DATE NOT NULL,
        ReceivedOn  DATE NULL,
        OpenedOn    DATE NULL,
        Status      BIT NOT NULL CONSTRAINT DF_IqcLot_Status DEFAULT 1,
        Remarks     NVARCHAR(300) NULL,
        CreatedBy   INT NULL,
        CreatedDate DATETIME NOT NULL CONSTRAINT DF_IqcLot_Created DEFAULT GETDATE()
    );
    CREATE UNIQUE INDEX UX_IqcLot ON dbo.IqcLot(MaterialId, LotNo);
    CREATE TABLE dbo.IqcTarget
    (
        TargetId      INT IDENTITY(1,1) CONSTRAINT PK_IqcTarget PRIMARY KEY,
        LotId         INT NOT NULL CONSTRAINT FK_IqcTarget_Lot REFERENCES dbo.IqcLot(LotId),
        AnalyzerId    INT NOT NULL,                   -- tbl_mst_analyzer
        TestId        INT NOT NULL,                   -- LabInvestigationMaster: the parameter
        Unit          NVARCHAR(30) NULL,
        Mean          DECIMAL(18,4) NOT NULL,
        Sd            DECIMAL(18,4) NOT NULL,
        Source        VARCHAR(12) NOT NULL CONSTRAINT DF_IqcTarget_Source DEFAULT 'MANUFACTURER',   -- MANUFACTURER | LAB
        Rule41s       BIT NOT NULL CONSTRAINT DF_IqcTarget_41s DEFAULT 0,
        Rule10x       BIT NOT NULL CONSTRAINT DF_IqcTarget_10x DEFAULT 0,
        IsActive      BIT NOT NULL CONSTRAINT DF_IqcTarget_Active DEFAULT 1,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME NOT NULL CONSTRAINT DF_IqcTarget_Created DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME NULL,
        CONSTRAINT CK_IqcTarget_Sd CHECK (Sd > 0),
        CONSTRAINT CK_IqcTarget_Source CHECK (Source IN ('MANUFACTURER', 'LAB'))
    );
    CREATE UNIQUE INDEX UX_IqcTarget ON dbo.IqcTarget(LotId, AnalyzerId, TestId);
END
GO

IF OBJECT_ID(N'dbo.IqcRun', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IqcRun
    (
        RunId            INT IDENTITY(1,1) CONSTRAINT PK_IqcRun PRIMARY KEY,
        CompanyId        INT NOT NULL,
        BranchId         INT NOT NULL,
        AnalyzerId       INT NOT NULL,
        TestId           INT NOT NULL,
        RunAt            DATETIME NOT NULL,
        Status           VARCHAR(10) NOT NULL,          -- ACCEPTED | WARNING | REJECTED
        Rules            NVARCHAR(100) NULL,            -- rules broken, e.g. 1-3s, 2-2s
        Remarks          NVARCHAR(500) NULL,
        EnteredBy        INT NULL,
        EnteredOn        DATETIME NOT NULL CONSTRAINT DF_IqcRun_Entered DEFAULT GETDATE(),
        RootCause        NVARCHAR(500) NULL,
        CorrectiveAction NVARCHAR(1000) NULL,
        PatientImpact    NVARCHAR(500) NULL,            -- look-back of patient results since the last good QC
        ActionBy         INT NULL,
        ActionOn         DATETIME NULL,
        CapaId           INT NULL CONSTRAINT FK_IqcRun_Capa REFERENCES dbo.QcCapa(CapaId),
        CONSTRAINT CK_IqcRun_Status CHECK (Status IN ('ACCEPTED', 'WARNING', 'REJECTED'))
    );
    CREATE INDEX IX_IqcRun_Block ON dbo.IqcRun(BranchId, TestId, Status) INCLUDE (CorrectiveAction);
    CREATE INDEX IX_IqcRun_Analyzer ON dbo.IqcRun(AnalyzerId, RunAt);
    CREATE TABLE dbo.IqcResult
    (
        ResultId  INT IDENTITY(1,1) CONSTRAINT PK_IqcResult PRIMARY KEY,
        RunId     INT NOT NULL CONSTRAINT FK_IqcResult_Run REFERENCES dbo.IqcRun(RunId),
        TargetId  INT NOT NULL CONSTRAINT FK_IqcResult_Target REFERENCES dbo.IqcTarget(TargetId),
        Value     DECIMAL(18,4) NOT NULL,
        ZScore    DECIMAL(8,2) NOT NULL,
        Flags     NVARCHAR(60) NULL
    );
    CREATE INDEX IX_IqcResult_Target ON dbo.IqcResult(TargetId, RunId);
END
GO

-- 3. Setup: materials, lots, targets ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_SetupList
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.*, d.DeptName AS DepartmentName, i.ItemName,
           (SELECT COUNT(1) FROM dbo.IqcLot l WHERE l.MaterialId = m.MaterialId AND l.Status = 1 AND l.ExpiryDate >= CAST(GETDATE() AS DATE)) AS ActiveLots
    FROM dbo.IqcMaterial m LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.DepartmentId LEFT JOIN dbo.InvItem i ON i.ItemId = m.ItemId
    WHERE m.CompanyId = @CompanyId AND m.IsDeleted = 0 ORDER BY m.Status DESC, m.MaterialName, m.ControlLevel;

    SELECT l.*, CAST(CASE WHEN l.ExpiryDate < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsExpired,
           (SELECT COUNT(1) FROM dbo.IqcTarget t WHERE t.LotId = l.LotId AND t.IsActive = 1) AS Targets
    FROM dbo.IqcLot l INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId AND m.IsDeleted = 0
    ORDER BY l.MaterialId, l.ExpiryDate DESC;

    SELECT t.*, a.Analyzer_Name AS AnalyzerName, x.Test_Name AS TestName, x.Test_Code AS TestCode, l.LotNo, l.ExpiryDate, m.MaterialName, m.ControlLevel,
           (SELECT COUNT(1) FROM dbo.IqcResult r WHERE r.TargetId = t.TargetId) AS Points,
           CAST(t.Sd * 100.0 / NULLIF(ABS(t.Mean), 0) AS DECIMAL(8,2)) AS CvPct
    FROM dbo.IqcTarget t
    INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
    INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId AND m.IsDeleted = 0
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = t.AnalyzerId
    LEFT JOIN dbo.LabInvestigationMaster x ON x.Test_ID = t.TestId
    ORDER BY t.LotId, a.Analyzer_Name, x.Test_Name;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Iqc_MaterialSave
    @MaterialId INT = NULL, @CompanyId INT, @MaterialName NVARCHAR(200), @Manufacturer NVARCHAR(150) = NULL, @ControlLevel NVARCHAR(30),
    @Matrix NVARCHAR(100) = NULL, @ItemId INT = NULL, @DepartmentId INT = NULL, @Remarks NVARCHAR(500) = NULL, @Status BIT = 1,
    @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @MaterialName = NULLIF(LTRIM(RTRIM(@MaterialName)), ''); SET @ControlLevel = NULLIF(LTRIM(RTRIM(@ControlLevel)), '');
    IF @MaterialName IS NULL THROW 55001, 'Control material name is required.', 1;
    IF @ControlLevel IS NULL THROW 55002, 'Control level is required (Level 1, Level 2 ...).', 1;
    IF @ItemId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.InvItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId AND IsDeleted = 0)
        THROW 55003, 'The linked item is not in the Item Master.', 1;
    IF EXISTS (SELECT 1 FROM dbo.IqcMaterial WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND MaterialName = @MaterialName AND ControlLevel = @ControlLevel
                                             AND MaterialId <> ISNULL(@MaterialId, 0))
        THROW 55004, 'This material already has this level.', 1;
    IF ISNULL(@MaterialId, 0) = 0
    BEGIN
        INSERT INTO dbo.IqcMaterial (CompanyId, MaterialName, Manufacturer, ControlLevel, Matrix, ItemId, DepartmentId, Remarks, Status, CreatedBy)
        VALUES (@CompanyId, @MaterialName, NULLIF(LTRIM(RTRIM(@Manufacturer)), ''), @ControlLevel, NULLIF(LTRIM(RTRIM(@Matrix)), ''), @ItemId, @DepartmentId,
                NULLIF(LTRIM(RTRIM(@Remarks)), ''), ISNULL(@Status, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.IqcMaterial WHERE MaterialId = @MaterialId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 55005, 'Material not found.', 1;
        UPDATE dbo.IqcMaterial SET MaterialName = @MaterialName, Manufacturer = NULLIF(LTRIM(RTRIM(@Manufacturer)), ''), ControlLevel = @ControlLevel,
               Matrix = NULLIF(LTRIM(RTRIM(@Matrix)), ''), ItemId = @ItemId, DepartmentId = @DepartmentId, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = ISNULL(@Status, 1)
        WHERE MaterialId = @MaterialId;
        SET @NewId = @MaterialId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Iqc_LotSave
    @LotId INT = NULL, @MaterialId INT, @CompanyId INT, @LotNo NVARCHAR(50), @ExpiryDate DATE, @ReceivedOn DATE = NULL, @OpenedOn DATE = NULL,
    @Status BIT = 1, @Remarks NVARCHAR(300) = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @LotNo = NULLIF(LTRIM(RTRIM(@LotNo)), '');
    IF NOT EXISTS (SELECT 1 FROM dbo.IqcMaterial WHERE MaterialId = @MaterialId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 55005, 'Material not found.', 1;
    IF @LotNo IS NULL THROW 55006, 'Lot number is required.', 1;
    IF @ExpiryDate IS NULL THROW 55007, 'Expiry date is required.', 1;
    IF @OpenedOn IS NOT NULL AND @OpenedOn > CAST(GETDATE() AS DATE) THROW 55008, 'Opened date cannot be in the future.', 1;
    IF @ReceivedOn IS NOT NULL AND @OpenedOn IS NOT NULL AND @OpenedOn < @ReceivedOn THROW 55009, 'A lot cannot be opened before it was received.', 1;
    IF EXISTS (SELECT 1 FROM dbo.IqcLot WHERE MaterialId = @MaterialId AND LotNo = @LotNo AND LotId <> ISNULL(@LotId, 0)) THROW 55010, 'This lot number already exists for the material.', 1;
    IF ISNULL(@LotId, 0) = 0
    BEGIN
        IF @ExpiryDate < CAST(GETDATE() AS DATE) THROW 55011, 'This lot has already expired.', 1;
        INSERT INTO dbo.IqcLot (MaterialId, LotNo, ExpiryDate, ReceivedOn, OpenedOn, Status, Remarks, CreatedBy)
        VALUES (@MaterialId, @LotNo, @ExpiryDate, @ReceivedOn, @OpenedOn, ISNULL(@Status, 1), NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.IqcLot WHERE LotId = @LotId AND MaterialId = @MaterialId) THROW 55012, 'Lot not found.', 1;
        UPDATE dbo.IqcLot SET LotNo = @LotNo, ExpiryDate = @ExpiryDate, ReceivedOn = @ReceivedOn, OpenedOn = @OpenedOn, Status = ISNULL(@Status, 1),
               Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '') WHERE LotId = @LotId;
        SET @NewId = @LotId;
    END
END;
GO

-- targets of a lot: several analyzer / parameter rows at once. A target already used by runs keeps its mean / SD
-- history: changing the mean / SD of a used target is allowed (re-baseline) but it is recorded in ModifiedBy / On.
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_TargetSave
    @LotId INT, @CompanyId INT, @TargetsJson NVARCHAR(MAX), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IqcLot l INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId AND m.IsDeleted = 0 WHERE l.LotId = @LotId)
        THROW 55012, 'Lot not found.', 1;
    DECLARE @T TABLE (TargetId INT, AnalyzerId INT, TestId INT, Unit NVARCHAR(30), Mean DECIMAL(18,4), Sd DECIMAL(18,4), Source VARCHAR(12), Rule41s BIT, Rule10x BIT, IsActive BIT);
    INSERT INTO @T
    SELECT NULLIF(j.targetId, 0), j.analyzerId, j.testId, NULLIF(LTRIM(RTRIM(j.unit)), ''), j.mean, j.sd, UPPER(ISNULL(NULLIF(j.source, ''), 'MANUFACTURER')),
           ISNULL(j.rule41s, 0), ISNULL(j.rule10x, 0), ISNULL(j.isActive, 1)
    FROM OPENJSON(ISNULL(@TargetsJson, '[]')) WITH (targetId INT '$.targetId', analyzerId INT '$.analyzerId', testId INT '$.testId', unit NVARCHAR(30) '$.unit',
         mean DECIMAL(18,4) '$.mean', sd DECIMAL(18,4) '$.sd', source VARCHAR(12) '$.source', rule41s BIT '$.rule41s', rule10x BIT '$.rule10x', isActive BIT '$.isActive') j;
    IF NOT EXISTS (SELECT 1 FROM @T) THROW 55013, 'Add at least one analyzer / parameter target.', 1;
    IF EXISTS (SELECT 1 FROM @T WHERE AnalyzerId IS NULL OR TestId IS NULL OR Mean IS NULL OR Sd IS NULL) THROW 55014, 'Every target needs the analyzer, the parameter, the mean and the SD.', 1;
    IF EXISTS (SELECT 1 FROM @T WHERE Sd <= 0) THROW 55015, 'SD must be more than 0.', 1;
    IF EXISTS (SELECT 1 FROM @T WHERE Source NOT IN ('MANUFACTURER', 'LAB')) THROW 55016, 'Target source must be the manufacturer or the lab.', 1;
    IF EXISTS (SELECT 1 FROM @T GROUP BY AnalyzerId, TestId HAVING COUNT(1) > 1) THROW 55017, 'An analyzer / parameter appears twice for this lot.', 1;
    IF EXISTS (SELECT 1 FROM @T t WHERE NOT EXISTS (SELECT 1 FROM dbo.tbl_mst_analyzer a WHERE a.Analyzer_ID = t.AnalyzerId AND ISNULL(a.IsDeleted, 0) = 0))
        THROW 55018, 'An analyzer is not valid.', 1;
    IF EXISTS (SELECT 1 FROM @T t WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster m WHERE m.Test_ID = t.TestId AND ISNULL(m.IsDeleted, 0) = 0))
        THROW 55019, 'A parameter is not in the test master.', 1;
    BEGIN TRANSACTION;
        UPDATE x SET Unit = t.Unit, Mean = t.Mean, Sd = t.Sd, Source = t.Source, Rule41s = t.Rule41s, Rule10x = t.Rule10x, IsActive = t.IsActive,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
        FROM dbo.IqcTarget x INNER JOIN @T t ON t.AnalyzerId = x.AnalyzerId AND t.TestId = x.TestId WHERE x.LotId = @LotId;
        INSERT INTO dbo.IqcTarget (LotId, AnalyzerId, TestId, Unit, Mean, Sd, Source, Rule41s, Rule10x, IsActive, CreatedBy)
        SELECT @LotId, t.AnalyzerId, t.TestId, t.Unit, t.Mean, t.Sd, t.Source, t.Rule41s, t.Rule10x, t.IsActive, @UserId FROM @T t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.IqcTarget x WHERE x.LotId = @LotId AND x.AnalyzerId = t.AnalyzerId AND x.TestId = t.TestId);
    COMMIT TRANSACTION;
END;
GO

-- 4. Daily QC ------------------------------------------------------------------------------------------------------
-- the QC to run on an analyzer: its parameters with the active targets (one per level, usable lots) and today's runs
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_EntryGrid
    @CompanyId INT, @BranchId INT, @AnalyzerId INT, @Date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Date = ISNULL(@Date, CAST(GETDATE() AS DATE));
    SELECT t.TargetId, t.TestId, x.Test_Name AS TestName, x.Test_Code AS TestCode, t.Unit, t.Mean, t.Sd, t.Source, m.MaterialName, m.ControlLevel,
           l.LotNo, l.ExpiryDate, DATEDIFF(DAY, @Date, l.ExpiryDate) AS DaysToExpiry
    FROM dbo.IqcTarget t
    INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId AND l.Status = 1 AND l.ExpiryDate >= @Date
    INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId AND m.IsDeleted = 0 AND m.Status = 1
    INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = t.TestId
    WHERE t.AnalyzerId = @AnalyzerId AND t.IsActive = 1
    ORDER BY x.Test_Name, m.ControlLevel;

    SELECT r.RunId, r.TestId, x.Test_Name AS TestName, r.RunAt, r.Status, r.Rules, r.CorrectiveAction, r.ActionOn,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS EnteredByName,
           (SELECT STRING_AGG(m.ControlLevel + N' ' + FORMAT(v.Value, '0.###') + N' (z ' + FORMAT(v.ZScore, '0.0') + N')', N' · ')
              FROM dbo.IqcResult v INNER JOIN dbo.IqcTarget t ON t.TargetId = v.TargetId INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
              INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId WHERE v.RunId = r.RunId) AS ValuesText
    FROM dbo.IqcRun r INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = r.TestId LEFT JOIN dbo.Users u ON u.Id = r.EnteredBy
    WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.AnalyzerId = @AnalyzerId AND r.RunAt >= @Date AND r.RunAt < DATEADD(DAY, 1, @Date)
    ORDER BY r.RunAt DESC;
END;
GO

-- save and judge one run (Westgard multirule)
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_RunSave
    @CompanyId INT, @BranchId INT, @AnalyzerId INT, @TestId INT, @RunAt DATETIME, @ValuesJson NVARCHAR(MAX), @Remarks NVARCHAR(500) = NULL,
    @UserId INT = NULL, @RunId INT = NULL OUTPUT, @Status VARCHAR(10) = NULL OUTPUT, @Rules NVARCHAR(100) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 55020, 'Choose the branch.', 1;
    IF @RunAt IS NULL OR @RunAt > DATEADD(MINUTE, 5, GETDATE()) THROW 55021, 'QC run date/time is required and cannot be in the future.', 1;

    CREATE TABLE #V (TargetId INT PRIMARY KEY, Value DECIMAL(18,4), Mean DECIMAL(18,4), Sd DECIMAL(18,4), Z DECIMAL(8,2), R41 BIT, R10 BIT,
                     LotNo NVARCHAR(50), Expiry DATE, LotActive BIT, Flags NVARCHAR(60) NULL);
    INSERT INTO #V (TargetId, Value)
    SELECT j.targetId, j.value FROM OPENJSON(ISNULL(@ValuesJson, '[]')) WITH (targetId INT '$.targetId', value DECIMAL(18,4) '$.value') j
    WHERE j.targetId IS NOT NULL AND j.value IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM #V) THROW 55022, 'Enter the QC value of at least one control level.', 1;
    UPDATE v SET Mean = t.Mean, Sd = t.Sd, Z = CAST(ROUND((v.Value - t.Mean) / t.Sd, 2) AS DECIMAL(8,2)), R41 = t.Rule41s, R10 = t.Rule10x,
           LotNo = l.LotNo, Expiry = l.ExpiryDate, LotActive = CASE WHEN l.Status = 1 AND m.Status = 1 AND t.IsActive = 1 THEN 1 ELSE 0 END
    FROM #V v
    INNER JOIN dbo.IqcTarget t ON t.TargetId = v.TargetId AND t.AnalyzerId = @AnalyzerId AND t.TestId = @TestId
    INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
    INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId AND m.IsDeleted = 0;
    IF EXISTS (SELECT 1 FROM #V WHERE Mean IS NULL) THROW 55023, 'A control level does not belong to this analyzer and parameter.', 1;
    IF EXISTS (SELECT 1 FROM #V WHERE LotActive = 0) THROW 55024, 'A control lot / target in this run is inactive.', 1;
    DECLARE @Exp NVARCHAR(200) = (SELECT TOP 1 N'Control lot ' + LotNo + N' expired on ' + CONVERT(NVARCHAR(11), Expiry, 106) + N'. Use a valid lot.'
                                  FROM #V WHERE Expiry < CAST(@RunAt AS DATE));
    IF @Exp IS NOT NULL THROW 55025, @Exp, 1;

    -- Westgard rules: within the run, and across runs for the same control level (target) on this branch
    DECLARE @Pos2 INT = (SELECT COUNT(1) FROM #V WHERE Z > 2), @Neg2 INT = (SELECT COUNT(1) FROM #V WHERE Z < -2);
    SELECT v.TargetId,
           CASE WHEN ABS(v.Z) > 3 THEN 1 ELSE 0 END AS R13,
           CASE WHEN ABS(v.Z) > 2 THEN 1 ELSE 0 END AS R12,
           CASE WHEN (v.Z > 2 AND (@Pos2 >= 2 OR p1.Z > 2)) OR (v.Z < -2 AND (@Neg2 >= 2 OR p1.Z < -2)) THEN 1 ELSE 0 END AS R22,
           CASE WHEN ABS(v.Z) > 2 AND @Pos2 >= 1 AND @Neg2 >= 1 THEN 1 ELSE 0 END AS R4s,
           CASE WHEN v.R41 = 1 AND p3.N = 3 AND ((v.Z > 1 AND p3.Pos1 = 3) OR (v.Z < -1 AND p3.Neg1 = 3)) THEN 1 ELSE 0 END AS R41,
           CASE WHEN v.R10 = 1 AND p9.N = 9 AND ((v.Z > 0 AND p9.Pos0 = 9) OR (v.Z < 0 AND p9.Neg0 = 9)) THEN 1 ELSE 0 END AS R10
    INTO #F
    FROM #V v
    OUTER APPLY (SELECT TOP 1 r.ZScore AS Z FROM dbo.IqcResult r INNER JOIN dbo.IqcRun u ON u.RunId = r.RunId
                 WHERE r.TargetId = v.TargetId AND u.BranchId = @BranchId AND u.RunAt < @RunAt ORDER BY u.RunAt DESC, u.RunId DESC) p1
    OUTER APPLY (SELECT COUNT(1) AS N, SUM(CASE WHEN q.Z > 1 THEN 1 ELSE 0 END) AS Pos1, SUM(CASE WHEN q.Z < -1 THEN 1 ELSE 0 END) AS Neg1
                 FROM (SELECT TOP 3 r.ZScore AS Z FROM dbo.IqcResult r INNER JOIN dbo.IqcRun u ON u.RunId = r.RunId
                       WHERE r.TargetId = v.TargetId AND u.BranchId = @BranchId AND u.RunAt < @RunAt ORDER BY u.RunAt DESC, u.RunId DESC) q) p3
    OUTER APPLY (SELECT COUNT(1) AS N, SUM(CASE WHEN q.Z > 0 THEN 1 ELSE 0 END) AS Pos0, SUM(CASE WHEN q.Z < 0 THEN 1 ELSE 0 END) AS Neg0
                 FROM (SELECT TOP 9 r.ZScore AS Z FROM dbo.IqcResult r INNER JOIN dbo.IqcRun u ON u.RunId = r.RunId
                       WHERE r.TargetId = v.TargetId AND u.BranchId = @BranchId AND u.RunAt < @RunAt ORDER BY u.RunAt DESC, u.RunId DESC) q) p9;
    UPDATE v SET Flags = NULLIF(CONCAT_WS(N', ', CASE WHEN f.R13 = 1 THEN N'1-3s' END, CASE WHEN f.R22 = 1 THEN N'2-2s' END, CASE WHEN f.R4s = 1 THEN N'R-4s' END,
                                         CASE WHEN f.R41 = 1 THEN N'4-1s' END, CASE WHEN f.R10 = 1 THEN N'10x' END,
                                         CASE WHEN f.R12 = 1 AND f.R13 = 0 AND f.R22 = 0 AND f.R4s = 0 THEN N'1-2s' END), N'')
    FROM #V v INNER JOIN #F f ON f.TargetId = v.TargetId;

    DECLARE @Reject BIT = CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R13 = 1 OR R22 = 1 OR R4s = 1 OR R41 = 1 OR R10 = 1) THEN 1 ELSE 0 END;
    SET @Status = CASE WHEN @Reject = 1 THEN 'REJECTED' WHEN EXISTS (SELECT 1 FROM #F WHERE R12 = 1) THEN 'WARNING' ELSE 'ACCEPTED' END;
    SET @Rules = NULLIF(CONCAT_WS(N', ',
        CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R13 = 1) THEN N'1-3s' END, CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R22 = 1) THEN N'2-2s' END,
        CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R4s = 1) THEN N'R-4s' END, CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R41 = 1) THEN N'4-1s' END,
        CASE WHEN EXISTS (SELECT 1 FROM #F WHERE R10 = 1) THEN N'10x' END,
        CASE WHEN @Reject = 0 AND EXISTS (SELECT 1 FROM #F WHERE R12 = 1) THEN N'1-2s' END), N'');

    BEGIN TRANSACTION;
        INSERT INTO dbo.IqcRun (CompanyId, BranchId, AnalyzerId, TestId, RunAt, Status, Rules, Remarks, EnteredBy)
        VALUES (@CompanyId, @BranchId, @AnalyzerId, @TestId, @RunAt, @Status, @Rules, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
        SET @RunId = SCOPE_IDENTITY();
        INSERT INTO dbo.IqcResult (RunId, TargetId, Value, ZScore, Flags) SELECT @RunId, TargetId, Value, Z, Flags FROM #V;
    COMMIT TRANSACTION;
END;
GO

-- corrective action of a rejected run (unblocks validation of the parameter); can raise a CAPA
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_RunAction
    @RunId INT, @CompanyId INT, @RootCause NVARCHAR(500) = NULL, @CorrectiveAction NVARCHAR(1000), @PatientImpact NVARCHAR(500) = NULL,
    @RaiseCapa BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @CorrectiveAction = NULLIF(LTRIM(RTRIM(@CorrectiveAction)), ''); SET @PatientImpact = NULLIF(LTRIM(RTRIM(@PatientImpact)), '');
    DECLARE @St VARCHAR(10), @Done NVARCHAR(1000), @Br INT, @Title NVARCHAR(200), @Prob NVARCHAR(1000);
    SELECT @St = r.Status, @Done = r.CorrectiveAction, @Br = r.BranchId,
           @Title = LEFT(N'IQC rejected: ' + x.Test_Name + N' on ' + ISNULL(a.Analyzer_Name, N'analyzer'), 200),
           @Prob = LEFT(N'Run of ' + CONVERT(NVARCHAR(20), r.RunAt, 106) + N' ' + CONVERT(NVARCHAR(5), r.RunAt, 108) + N' broke ' + ISNULL(r.Rules, N'Westgard rules'), 1000)
    FROM dbo.IqcRun r INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = r.TestId LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = r.AnalyzerId
    WHERE r.RunId = @RunId AND r.CompanyId = @CompanyId;
    IF @St IS NULL THROW 55030, 'QC run not found.', 1;
    IF @St <> 'REJECTED' THROW 55031, 'Only a rejected QC run needs corrective action.', 1;
    IF @Done IS NOT NULL THROW 55032, 'Corrective action is already recorded for this run.', 1;
    IF @CorrectiveAction IS NULL THROW 55033, 'Describe the corrective action (e.g. recalibrated, new reagent bottle, QC repeated and accepted).', 1;
    IF @PatientImpact IS NULL THROW 55034, 'Record the look-back: were patient results since the last accepted QC reviewed / repeated?', 1;
    BEGIN TRANSACTION;
        DECLARE @Capa INT = NULL;
        IF @RaiseCapa = 1 EXEC dbo.usp_Qc_Capa_Raise @CompanyId, @Br, 'IQC', @RunId, NULL, NULL, @Title, @Prob, @UserId, @Capa OUTPUT;
        UPDATE dbo.IqcRun SET RootCause = NULLIF(LTRIM(RTRIM(@RootCause)), ''), CorrectiveAction = @CorrectiveAction, PatientImpact = @PatientImpact,
               ActionBy = @UserId, ActionOn = GETDATE(), CapaId = @Capa
        WHERE RunId = @RunId;
    COMMIT TRANSACTION;
END;
GO

-- rejected runs still waiting for corrective action (branch)
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_PendingActions
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RunId, r.BranchId, b.BranchName, r.AnalyzerId, a.Analyzer_Name AS AnalyzerName, r.TestId, x.Test_Name AS TestName, r.RunAt, r.Rules,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS EnteredByName,
           CAST(DATEDIFF(MINUTE, r.RunAt, GETDATE()) / 60.0 AS DECIMAL(10,1)) AS HoursOpen,
           (SELECT STRING_AGG(m.ControlLevel + N' ' + FORMAT(v.Value, '0.###') + N' (z ' + FORMAT(v.ZScore, '0.0') + N')', N' · ')
              FROM dbo.IqcResult v INNER JOIN dbo.IqcTarget t ON t.TargetId = v.TargetId INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
              INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId WHERE v.RunId = r.RunId) AS ValuesText
    FROM dbo.IqcRun r
    INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = r.TestId
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = r.AnalyzerId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = r.BranchId
    LEFT JOIN dbo.Users u ON u.Id = r.EnteredBy
    WHERE r.CompanyId = @CompanyId AND r.Status = 'REJECTED' AND r.CorrectiveAction IS NULL AND (@BranchId IS NULL OR r.BranchId = @BranchId)
    ORDER BY r.RunAt;
END;
GO

-- 5. Levey-Jennings data ---------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_Chart
    @CompanyId INT, @BranchId INT, @TargetId INT, @FromDate DATE, @ToDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SELECT t.TargetId, t.Mean, t.Sd, t.Unit, t.Source, t.Rule41s, t.Rule10x, x.Test_Name AS TestName, a.Analyzer_Name AS AnalyzerName,
           m.MaterialName, m.ControlLevel, l.LotNo, l.ExpiryDate
    FROM dbo.IqcTarget t INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
    INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId AND m.CompanyId = @CompanyId
    INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = t.TestId LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = t.AnalyzerId
    WHERE t.TargetId = @TargetId;

    SELECT r.RunId, r.RunAt, v.Value, v.ZScore, v.Flags, r.Status, r.Rules, r.CorrectiveAction,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS EnteredByName
    FROM dbo.IqcResult v INNER JOIN dbo.IqcRun r ON r.RunId = v.RunId LEFT JOIN dbo.Users u ON u.Id = r.EnteredBy
    WHERE v.TargetId = @TargetId AND r.BranchId = @BranchId AND r.RunAt >= @From AND r.RunAt < @To
    ORDER BY r.RunAt, r.RunId;

    -- the lab's own statistics of accepted / warning runs in the period (to establish or verify the target)
    SELECT COUNT(1) AS N, CAST(AVG(v.Value) AS DECIMAL(18,4)) AS ObsMean, CAST(STDEV(v.Value) AS DECIMAL(18,4)) AS ObsSd,
           CAST(STDEV(v.Value) * 100.0 / NULLIF(ABS(AVG(v.Value)), 0) AS DECIMAL(8,2)) AS ObsCvPct,
           SUM(CASE WHEN r.Status = 'REJECTED' THEN 1 ELSE 0 END) AS Rejected, SUM(CASE WHEN r.Status = 'WARNING' THEN 1 ELSE 0 END) AS Warnings
    FROM dbo.IqcResult v INNER JOIN dbo.IqcRun r ON r.RunId = v.RunId
    WHERE v.TargetId = @TargetId AND r.BranchId = @BranchId AND r.RunAt >= @From AND r.RunAt < @To AND r.Status IN ('ACCEPTED', 'WARNING');
END;
GO

-- 6. Validation block ---------------------------------------------------------------------------------------------------
-- a message when a parameter of these samples has a rejected QC run without corrective action at the branch that ran it
CREATE OR ALTER PROCEDURE dbo.usp_Iqc_BlockMessage
    @LabOrderId INT, @SampleIds NVARCHAR(MAX) = NULL, @Message NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Message = NULL;
    IF OBJECT_ID(N'dbo.IqcRun', N'U') IS NULL RETURN;
    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT INTO @Ids SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) FROM STRING_SPLIT(ISNULL(@SampleIds, ''), ',')
    WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL AND TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) > 0;
    ;WITH s AS (
        SELECT DISTINCT sc.InvestigationID AS TestId,
               CASE WHEN sc.IsTransferred = 1 AND sc.IsReceived = 1 AND sc.TargetBranchID IS NOT NULL THEN sc.TargetBranchID ELSE sc.BranchID END AS BranchId
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.IsoutSource, 0) = 0
          AND (NOT EXISTS (SELECT 1 FROM @Ids) OR sc.samplecollectionID IN (SELECT Id FROM @Ids)))
    SELECT @Message = LEFT(N'Internal QC rejected: ' + STRING_AGG(CAST(b.Txt AS NVARCHAR(MAX)), N'; ')
                      + N'. Record the corrective action in Quality & Compliance > Internal QC before validating or approving.', 1000)
    FROM (SELECT TOP 5 x.Test_Name + N' on ' + ISNULL(a.Analyzer_Name, N'analyzer') + N' (' + CONVERT(NVARCHAR(11), r.RunAt, 106) + N' '
                 + CONVERT(NVARCHAR(5), r.RunAt, 108) + N', ' + ISNULL(r.Rules, N'rejected') + N')' AS Txt
          FROM s INNER JOIN dbo.IqcRun r ON r.TestId = s.TestId AND r.BranchId = s.BranchId AND r.Status = 'REJECTED' AND r.CorrectiveAction IS NULL
          INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = r.TestId LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = r.AnalyzerId
          ORDER BY r.RunAt) b
    HAVING COUNT(1) > 0;
END;
GO

-- hooks: Validate / Approve on the entry screens (dbo.usp_LabReporting_SaveEntry) and the Report Approval Dashboard
DECLARE @def NVARCHAR(MAX), @anchor NVARCHAR(400), @hook NVARCHAR(MAX);
SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_LabReporting_SaveEntry'));
IF CHARINDEX(N'usp_Iqc_BlockMessage', @def) = 0
BEGIN
    SET @anchor = N'    DECLARE @Now DATETIME = GETDATE();';
    IF CHARINDEX(@anchor, @def) = 0 THROW 55090, 'usp_LabReporting_SaveEntry: anchor not found; IQC block not added.', 1;
    SET @hook = N'    -- 2254: a parameter whose internal QC is rejected (no corrective action yet) cannot be validated or approved
    IF @ReportStatusId IN (3, 5) OR @StatusCode IN (''REPORT_VALIDATED'', ''REPORT_APPROVE'', ''REPORT_APPROVED'')
    BEGIN
        DECLARE @IqcIds NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(SamplecollectionID AS VARCHAR(20)), '','') FROM #ParsedEntries
                                         WHERE LTRIM(RTRIM(ISNULL(TestValue, ''''))) <> '''' OR LTRIM(RTRIM(ISNULL(Template_Html, ''''))) <> '''');
        DECLARE @IqcMsg NVARCHAR(1000);
        IF @IqcIds IS NOT NULL EXEC dbo.usp_Iqc_BlockMessage @LabOrderId, @IqcIds, @IqcMsg OUTPUT;
        IF @IqcMsg IS NOT NULL THROW 55050, @IqcMsg, 1;
    END

' + @anchor;
    SET @def = STUFF(@def, CHARINDEX(@anchor, @def), LEN(@anchor), @hook);
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

DECLARE @def NVARCHAR(MAX), @anchor NVARCHAR(400), @hook NVARCHAR(MAX);
SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_Api_PathologistDashboard_Approve'));
IF @def IS NOT NULL AND CHARINDEX(N'usp_Iqc_BlockMessage', @def) = 0
BEGIN
    SET @anchor = N'    DECLARE @Now DATETIME = GETDATE();';
    IF CHARINDEX(@anchor, @def) = 0 THROW 55091, 'usp_Api_PathologistDashboard_Approve: anchor not found; IQC block not added.', 1;
    SET @hook = N'    -- 2254: a parameter whose internal QC is rejected (no corrective action yet) cannot be approved
    DECLARE @IqcMsg NVARCHAR(1000);
    EXEC dbo.usp_Iqc_BlockMessage @LabOrderId, @SamplecollectionIds, @IqcMsg OUTPUT;
    IF @IqcMsg IS NOT NULL BEGIN DROP TABLE #Can; RAISERROR(@IqcMsg, 16, 1); RETURN; END

' + @anchor;
    SET @def = STUFF(@def, CHARINDEX(@anchor, @def), LEN(@anchor), @hook);
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

-- 7. Report: IQC Run Register -------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_IqcRuns
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @RunStatus VARCHAR(20) = NULL,        -- ACCEPTED | WARNING | REJECTED | PENDING (rejected without action)
    @AnalyzerId INT = NULL, @TestId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @RunStatus = NULLIF(UPPER(LTRIM(RTRIM(@RunStatus))), '');
    SELECT r.RunId, r.RunAt, CONVERT(VARCHAR(10), CAST(r.RunAt AS DATE), 23) AS RunDay, r.AnalyzerId, a.Analyzer_Name AS AnalyzerName, r.TestId,
           x.Test_Name AS TestName, x.Test_Code AS TestCode, r.Status,
           CASE r.Status WHEN 'ACCEPTED' THEN N'Accepted' WHEN 'WARNING' THEN N'Warning (1-2s)' ELSE N'Rejected' END AS StatusLabel,
           r.Rules, r.Remarks, r.RootCause, r.CorrectiveAction, r.PatientImpact, r.ActionOn, c.CapaNo,
           CAST(CASE WHEN r.Status = 'REJECTED' AND r.CorrectiveAction IS NULL THEN 1 ELSE 0 END AS BIT) AS ActionPending,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS EnteredByName, ISNULL(NULLIF(LTRIM(RTRIM(ua.FullName)), ''), ua.Username) AS ActionByName,
           (SELECT STRING_AGG(m.ControlLevel + N' ' + FORMAT(v.Value, '0.###') + N' (z ' + FORMAT(v.ZScore, '0.0') + ISNULL(N', ' + v.Flags, N'') + N')', N' · ')
              FROM dbo.IqcResult v INNER JOIN dbo.IqcTarget t ON t.TargetId = v.TargetId INNER JOIN dbo.IqcLot l ON l.LotId = t.LotId
              INNER JOIN dbo.IqcMaterial m ON m.MaterialId = l.MaterialId WHERE v.RunId = r.RunId) AS ValuesText
    INTO #R
    FROM dbo.IqcRun r
    INNER JOIN dbo.LabInvestigationMaster x ON x.Test_ID = r.TestId
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = r.AnalyzerId
    LEFT JOIN dbo.QcCapa c ON c.CapaId = r.CapaId
    LEFT JOIN dbo.Users u ON u.Id = r.EnteredBy
    LEFT JOIN dbo.Users ua ON ua.Id = r.ActionBy
    WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.RunAt >= @From AND r.RunAt < @To
      AND (@AnalyzerId IS NULL OR r.AnalyzerId = @AnalyzerId) AND (@TestId IS NULL OR r.TestId = @TestId)
      AND (@Search IS NULL OR x.Test_Name LIKE '%' + @Search + '%' OR a.Analyzer_Name LIKE '%' + @Search + '%');
    DELETE FROM #R WHERE @RunStatus IS NOT NULL AND NOT ((@RunStatus = 'PENDING' AND ActionPending = 1) OR Status = @RunStatus);

    SELECT COUNT(1) AS Runs, SUM(CASE WHEN Status = 'ACCEPTED' THEN 1 ELSE 0 END) AS Accepted, SUM(CASE WHEN Status = 'WARNING' THEN 1 ELSE 0 END) AS Warnings,
           SUM(CASE WHEN Status = 'REJECTED' THEN 1 ELSE 0 END) AS Rejected, SUM(CASE WHEN ActionPending = 1 THEN 1 ELSE 0 END) AS ActionPending,
           CAST(SUM(CASE WHEN Status <> 'REJECTED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(1), 0) AS DECIMAL(5,1)) AS AcceptedPct,
           COUNT(DISTINCT TestId) AS Parameters, COUNT(DISTINCT AnalyzerId) AS Analyzers
    FROM #R;
    SELECT 'byAnalyzer' AS GroupKey, AnalyzerId AS GroupId, AnalyzerName AS GroupName, COUNT(1) AS Runs, SUM(CASE WHEN Status = 'WARNING' THEN 1 ELSE 0 END) AS Warnings,
           SUM(CASE WHEN Status = 'REJECTED' THEN 1 ELSE 0 END) AS Rejected, CAST(SUM(CASE WHEN Status <> 'REJECTED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(1), 0) AS DECIMAL(5,1)) AS AcceptedPct
    FROM #R GROUP BY AnalyzerId, AnalyzerName
    UNION ALL
    SELECT 'byTest', TestId, TestName, COUNT(1), SUM(CASE WHEN Status = 'WARNING' THEN 1 ELSE 0 END), SUM(CASE WHEN Status = 'REJECTED' THEN 1 ELSE 0 END),
           CAST(SUM(CASE WHEN Status <> 'REJECTED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(1), 0) AS DECIMAL(5,1))
    FROM #R GROUP BY TestId, TestName
    UNION ALL
    SELECT 'byStatus', NULL, StatusLabel, COUNT(1), SUM(CASE WHEN Status = 'WARNING' THEN 1 ELSE 0 END), SUM(CASE WHEN Status = 'REJECTED' THEN 1 ELSE 0 END), NULL
    FROM #R GROUP BY StatusLabel
    UNION ALL
    SELECT 'byDate', NULL, RunDay, COUNT(1), SUM(CASE WHEN Status = 'WARNING' THEN 1 ELSE 0 END), SUM(CASE WHEN Status = 'REJECTED' THEN 1 ELSE 0 END),
           CAST(SUM(CASE WHEN Status <> 'REJECTED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(1), 0) AS DECIMAL(5,1))
    FROM #R GROUP BY RunDay
    ORDER BY GroupKey, GroupName;
    SELECT * FROM #R ORDER BY RunAt DESC;
    SELECT 'analyzerId' AS FilterKey, CAST(Analyzer_ID AS VARCHAR(20)) AS Value, Analyzer_Name AS Text FROM dbo.tbl_mst_analyzer
    WHERE ISNULL(IsDeleted, 0) = 0 AND (CompanyId = @CompanyId OR CompanyId IS NULL)
    UNION ALL
    SELECT DISTINCT 'testId', CAST(TestId AS VARCHAR(20)), TestName FROM #R
    ORDER BY FilterKey, Text;
END;
GO

-- 8. Menu, pages, controls, endpoints -----------------------------------------------------------------------------------
DECLARE @co INT, @top INT, @mIqc INT, @mRep INT, @page INT, @ctl INT, @code NVARCHAR(150), @title NVARCHAR(150), @ctrl NVARCHAR(100),
        @sort INT, @icon NVARCHAR(100), @action NVARCHAR(100);
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Ctrl NVARCHAR(100), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
 (N'QC.IQC.ENTRY', N'Daily QC Entry',              N'IqcEntry', N'Index', 10, N'bi bi-clipboard-pulse me-2'),
 (N'QC.IQC.CHART', N'Levey-Jennings Charts',       N'IqcChart', N'Index', 20, N'bi bi-graph-up me-2'),
 (N'QC.IQC.SETUP', N'QC Materials, Lots & Targets', N'IqcSetup', N'Index', 30, N'bi bi-sliders me-2'),
 (N'REPORTS.LABIQCRUNS', N'IQC Run Register', N'Reports', N'LabIqcRuns', 420, N'bi bi-clipboard-pulse me-2');
DECLARE @Controls TABLE (Page NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
 (N'QC.IQC.ENTRY', 'ENTRY', N'Enter QC runs', 20), (N'QC.IQC.ENTRY', 'ACTION', N'Record corrective action', 30),
 (N'QC.IQC.SETUP', 'ADD', N'Add / edit materials, lots and targets', 20);
DECLARE @Ep TABLE (Page NVARCHAR(150), Method VARCHAR(10), Ctrl NVARCHAR(100), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Ep VALUES
 (N'QC.IQC.ENTRY', 'GET', N'IqcEntry', N'Index', 'VIEW'), (N'QC.IQC.ENTRY', 'GET', N'IqcEntry', N'Grid', 'VIEW'),
 (N'QC.IQC.ENTRY', 'GET', N'IqcEntry', N'Pending', 'VIEW'), (N'QC.IQC.ENTRY', 'POST', N'IqcEntry', N'SaveRuns', 'ENTRY'),
 (N'QC.IQC.ENTRY', 'POST', N'IqcEntry', N'Action', 'ACTION'),
 (N'QC.IQC.CHART', 'GET', N'IqcChart', N'Index', 'VIEW'), (N'QC.IQC.CHART', 'GET', N'IqcChart', N'Targets', 'VIEW'), (N'QC.IQC.CHART', 'GET', N'IqcChart', N'Data', 'VIEW'),
 (N'QC.IQC.SETUP', 'GET', N'IqcSetup', N'Index', 'VIEW'), (N'QC.IQC.SETUP', 'GET', N'IqcSetup', N'List', 'VIEW'),
 (N'QC.IQC.SETUP', 'POST', N'IqcSetup', N'SaveMaterial', 'ADD'), (N'QC.IQC.SETUP', 'POST', N'IqcSetup', N'SaveLot', 'ADD'),
 (N'QC.IQC.SETUP', 'POST', N'IqcSetup', N'SaveTargets', 'ADD'),
 (N'REPORTS.LABIQCRUNS', 'GET', N'Reports', N'LabIqcRuns', 'VIEW'), (N'REPORTS.LABIQCRUNS', 'GET', N'Reports', N'GetLabReportData', 'VIEW');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @top = NULL; SET @mRep = NULL;
    SELECT @top = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'QUALITY' AND CompanyId = @co;
    SELECT @mRep = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @top IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @top, @Menu_Type = 'MENU', @Menu_Code = N'QUALITY.IQC',
             @Title = N'Internal QC', @Icon = N'bi bi-clipboard-pulse me-2', @Sort_Order = 25, @Menu_ID = @mIqc OUTPUT;
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Ctrl, Action, Sort, Icon FROM @Pages WHERE Ctrl <> N'Reports' OR @mRep IS NOT NULL;
        OPEN pg; FETCH NEXT FROM pg INTO @code, @title, @ctrl, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            DECLARE @mid INT = CASE WHEN @ctrl = N'Reports' THEN @mRep ELSE @mIqc END;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @mid, @Page_Code = @code, @Title = @title, @Controller = @ctrl, @Action = @action,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT;
            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE Page = @code;
            OPEN c1; FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            END
            CLOSE c1; DEALLOCATE c1;
            DECLARE @em VARCHAR(10), @ec NVARCHAR(100), @ea NVARCHAR(100), @ecode VARCHAR(30);
            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Ctrl, Action, Code FROM @Ep WHERE Page = @code;
            OPEN e1; FETCH NEXT FROM e1 INTO @em, @ec, @ea, @ecode;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @ecode;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @em,
                     @Controller = @ec, @Action = @ea, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @em, @ec, @ea, @ecode;
            END
            CLOSE e1; DEALLOCATE e1;
            FETCH NEXT FROM pg INTO @code, @title, @ctrl, @action, @sort, @icon;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2254 applied: LF-05 Internal QC (materials, lots, targets, Westgard runs, validation block, Levey-Jennings, IQC register).';
GO
