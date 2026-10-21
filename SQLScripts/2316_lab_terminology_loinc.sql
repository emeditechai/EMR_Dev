-- ============================================================================================================
-- Migration: 2316_lab_terminology_loinc.sql
-- Utility > API data: Standard Laboratory Test Master (LOINC) - "Import -> Validate -> Map -> Approve -> Publish"
-- (Standard_Laboratory_Test_Master_Technical_Implementation_Guide.docx).
--
-- Everything lives in its own schema [Terminology], separate from the operational lab masters:
--   Terminology.Release            one row per imported release (LOINC 2.xx / API lookups), one active per system
--   Terminology.ImportJob          an import of a release file: status, counts, hash, timings
--   Terminology.ImportError        row-level validation failures of a job
--   Terminology.StageLoinc         raw rows of a job (staging - the published data is untouched until Publish)
--   Terminology.LoincConcept       the published, version-aware LOINC repository (never physically deleted)
--   Terminology.ReleaseChange      added / modified / retired concepts of a release against the published data
--   Terminology.InvestigationLoincMapping  local investigation -> LOINC code, Pending / Approved / Rejected
--   Terminology.MappingAudit       every proposal, approval, rejection and review flag
-- The real Investigation Master (dbo.LabInvestigationMaster and its related tables) is ONLY READ - no column, row,
-- constraint or trigger of it is created or changed; the mapping keeps the local Test_ID without a foreign key.
-- No role grant is seeded (Settings > Security > Role Permissions); Super Admin sees the pages. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'Terminology') IS NULL EXEC (N'CREATE SCHEMA Terminology');
GO

-- ── Tables ────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'Terminology.Release', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.Release (
    ReleaseId       INT IDENTITY(1,1) CONSTRAINT PK_TermRelease PRIMARY KEY,
    SystemCode      VARCHAR(30)    NOT NULL,                 -- LOINC
    VersionCode     VARCHAR(30)    NOT NULL,                 -- e.g. 2.78; API-LOOKUP for concepts fetched by the Search API
    ReleaseDate     DATE           NULL,
    ImportedAt      DATETIME2      NOT NULL CONSTRAINT DF_TermRelease_Imported DEFAULT SYSDATETIME(),
    Status          VARCHAR(20)    NOT NULL CONSTRAINT DF_TermRelease_Status DEFAULT 'Staged',   -- Staged / Validated / Published / Failed / Discarded
    IsActive        BIT            NOT NULL CONSTRAINT DF_TermRelease_Active DEFAULT 0,
    SourceFileName  NVARCHAR(260)  NULL,
    SourceFileHash  VARCHAR(128)   NULL,                     -- SHA-256 of the uploaded file
    LicenseNote     NVARCHAR(500)  NULL,
    Notes           NVARCHAR(1000) NULL,
    CreatedBy       INT            NULL,
    PublishedAt     DATETIME2      NULL,
    PublishedBy     INT            NULL,
    CONSTRAINT UQ_TermRelease_SystemVersion UNIQUE (SystemCode, VersionCode)
);
END
GO
IF OBJECT_ID(N'Terminology.ImportJob', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.ImportJob (
    ImportJobId     INT IDENTITY(1,1) CONSTRAINT PK_TermImportJob PRIMARY KEY,
    ReleaseId       INT            NOT NULL CONSTRAINT FK_TermImportJob_Release REFERENCES Terminology.Release(ReleaseId),
    Status          VARCHAR(20)    NOT NULL CONSTRAINT DF_TermImportJob_Status DEFAULT 'Queued',  -- Queued / Running / Validated / Failed / Published / Discarded
    StoredFile      NVARCHAR(400)  NULL,                     -- where the API keeps the uploaded file
    SourceFileName  NVARCHAR(260)  NULL,
    SourceFileHash  VARCHAR(128)   NULL,
    FileSizeBytes   BIGINT         NULL,
    EntryName       NVARCHAR(260)  NULL,                     -- the CSV read (also inside a ZIP)
    RowsRead        INT            NOT NULL CONSTRAINT DF_TermImportJob_Read DEFAULT 0,
    RowsStaged      INT            NOT NULL CONSTRAINT DF_TermImportJob_Staged DEFAULT 0,
    RowsError       INT            NOT NULL CONSTRAINT DF_TermImportJob_Err DEFAULT 0,
    CountAdded      INT            NULL,
    CountModified   INT            NULL,
    CountRetired    INT            NULL,
    CountUnchanged  INT            NULL,
    Message         NVARCHAR(2000) NULL,
    CreatedBy       INT            NULL,
    CreatedAt       DATETIME2      NOT NULL CONSTRAINT DF_TermImportJob_Created DEFAULT SYSDATETIME(),
    StartedAt       DATETIME2      NULL,
    FinishedAt      DATETIME2      NULL
);
END
GO
IF OBJECT_ID(N'Terminology.ImportError', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.ImportError (
    ImportErrorId   BIGINT IDENTITY(1,1) CONSTRAINT PK_TermImportError PRIMARY KEY,
    ImportJobId     INT            NOT NULL CONSTRAINT FK_TermImportError_Job REFERENCES Terminology.ImportJob(ImportJobId),
    FileName        NVARCHAR(260)  NULL,
    RowNumber       INT            NULL,
    LoincCode       VARCHAR(40)    NULL,
    Severity        VARCHAR(10)    NOT NULL CONSTRAINT DF_TermImportError_Sev DEFAULT 'ERROR',   -- ERROR / WARNING / CRITICAL
    Reason          NVARCHAR(500)  NOT NULL
);
CREATE INDEX IX_TermImportError_Job ON Terminology.ImportError (ImportJobId, ImportErrorId);
END
GO
IF OBJECT_ID(N'Terminology.StageLoinc', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.StageLoinc (
    ImportJobId         INT            NOT NULL,
    RowNumber           INT            NOT NULL,
    LoincCode           VARCHAR(20)    NOT NULL,
    LongCommonName      NVARCHAR(500)  NULL,
    ShortName           NVARCHAR(255)  NULL,
    Component           NVARCHAR(500)  NULL,
    Property            NVARCHAR(100)  NULL,
    TimeAspect          NVARCHAR(100)  NULL,
    SystemName          NVARCHAR(255)  NULL,
    ScaleType           NVARCHAR(100)  NULL,
    MethodName          NVARCHAR(255)  NULL,
    ClassName           NVARCHAR(100)  NULL,
    ClassType           VARCHAR(10)    NULL,
    Status              VARCHAR(30)    NULL,
    OrderObs            VARCHAR(30)    NULL,
    ExampleUnits        NVARCHAR(255)  NULL,
    ExampleUcumUnits    NVARCHAR(255)  NULL,
    VersionLastChanged  VARCHAR(30)    NULL,
    RowHash             VARBINARY(32)  NULL,
    CONSTRAINT PK_TermStageLoinc PRIMARY KEY (ImportJobId, RowNumber)
);
CREATE INDEX IX_TermStageLoinc_Code ON Terminology.StageLoinc (ImportJobId, LoincCode);
END
GO
IF OBJECT_ID(N'Terminology.LoincConcept', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.LoincConcept (
    LoincCode           VARCHAR(20)    NOT NULL CONSTRAINT PK_TermLoincConcept PRIMARY KEY,
    LongCommonName      NVARCHAR(500)  NULL,
    ShortName           NVARCHAR(255)  NULL,
    Component           NVARCHAR(500)  NULL,
    Property            NVARCHAR(100)  NULL,
    TimeAspect          NVARCHAR(100)  NULL,
    SystemName          NVARCHAR(255)  NULL,
    ScaleType           NVARCHAR(100)  NULL,
    MethodName          NVARCHAR(255)  NULL,
    ClassName           NVARCHAR(100)  NULL,
    ClassType           VARCHAR(10)    NULL,                -- 1 lab, 2 clinical, 3 claims, 4 surveys
    Status              VARCHAR(30)    NULL,                -- ACTIVE / TRIAL / DISCOURAGED / DEPRECATED (source status)
    OrderObs            VARCHAR(30)    NULL,                -- Order / Observation / Both
    ExampleUnits        NVARCHAR(255)  NULL,
    ExampleUcumUnits    NVARCHAR(255)  NULL,
    VersionLastChanged  VARCHAR(30)    NULL,
    SourceVersion       VARCHAR(30)    NULL,                -- release it was last taken from
    FirstReleaseId      INT            NULL,
    LastChangedReleaseId INT           NULL,
    IsRetired           BIT            NOT NULL CONSTRAINT DF_TermLoincConcept_Retired DEFAULT 0,   -- missing from a later release
    RowHash             VARBINARY(32)  NULL,
    UpdatedAt           DATETIME2      NOT NULL CONSTRAINT DF_TermLoincConcept_Updated DEFAULT SYSDATETIME()
);
CREATE INDEX IX_TermLoincConcept_Name ON Terminology.LoincConcept (LongCommonName);
CREATE INDEX IX_TermLoincConcept_Component ON Terminology.LoincConcept (Component);
CREATE INDEX IX_TermLoincConcept_Class ON Terminology.LoincConcept (ClassName, ClassType, Status);
END
GO
IF OBJECT_ID(N'Terminology.ReleaseChange', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.ReleaseChange (
    ReleaseChangeId BIGINT IDENTITY(1,1) CONSTRAINT PK_TermReleaseChange PRIMARY KEY,
    ReleaseId       INT            NOT NULL CONSTRAINT FK_TermReleaseChange_Release REFERENCES Terminology.Release(ReleaseId),
    ImportJobId     INT            NULL,
    LoincCode       VARCHAR(20)    NOT NULL,
    ChangeType      VARCHAR(12)    NOT NULL,                -- ADDED / MODIFIED / RETIRED / STATUS
    OldStatus       VARCHAR(30)    NULL,
    NewStatus       VARCHAR(30)    NULL,
    OldName         NVARCHAR(500)  NULL,
    NewName         NVARCHAR(500)  NULL,
    ChangedFields   NVARCHAR(400)  NULL
);
CREATE INDEX IX_TermReleaseChange_Release ON Terminology.ReleaseChange (ReleaseId, ChangeType, LoincCode);
END
GO
IF OBJECT_ID(N'Terminology.InvestigationLoincMapping', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.InvestigationLoincMapping (
    MappingId       BIGINT IDENTITY(1,1) CONSTRAINT PK_TermInvMapping PRIMARY KEY,
    InvestigationId INT            NOT NULL,                -- dbo.LabInvestigationMaster.Test_ID (read only, no foreign key)
    LoincCode       VARCHAR(20)    NOT NULL CONSTRAINT FK_TermInvMapping_Concept REFERENCES Terminology.LoincConcept(LoincCode),
    MappingStatus   VARCHAR(20)    NOT NULL CONSTRAINT DF_TermInvMapping_Status DEFAULT 'Pending',   -- Pending / Approved / Rejected
    MappingMethod   VARCHAR(20)    NOT NULL CONSTRAINT DF_TermInvMapping_Method DEFAULT 'Manual',    -- Manual / Suggested / Imported
    IsPreferred     BIT            NOT NULL CONSTRAINT DF_TermInvMapping_Pref DEFAULT 0,
    NeedsReview     BIT            NOT NULL CONSTRAINT DF_TermInvMapping_Review DEFAULT 0,          -- the concept changed / retired in a later release
    ReviewReason    NVARCHAR(300)  NULL,
    Notes           NVARCHAR(1000) NULL,
    ProposedBy      INT            NULL,
    ProposedAt      DATETIME2      NOT NULL CONSTRAINT DF_TermInvMapping_Proposed DEFAULT SYSDATETIME(),
    ApprovedBy      INT            NULL,
    ApprovedAt      DATETIME2      NULL,
    DecisionNote    NVARCHAR(1000) NULL,
    CompanyId       INT            NULL,
    CONSTRAINT UQ_TermInvMapping UNIQUE (InvestigationId, LoincCode)
);
CREATE INDEX IX_TermInvMapping_Code ON Terminology.InvestigationLoincMapping (LoincCode, MappingStatus);
CREATE INDEX IX_TermInvMapping_Status ON Terminology.InvestigationLoincMapping (MappingStatus, NeedsReview);
END
GO
IF OBJECT_ID(N'Terminology.MappingAudit', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.MappingAudit (
    MappingAuditId  BIGINT IDENTITY(1,1) CONSTRAINT PK_TermMappingAudit PRIMARY KEY,
    MappingId       BIGINT         NOT NULL,
    InvestigationId INT            NOT NULL,
    LoincCode       VARCHAR(20)    NOT NULL,
    Action          VARCHAR(20)    NOT NULL,                -- PROPOSED / APPROVED / REJECTED / PREFERRED / REVIEW / REOPENED
    FromStatus      VARCHAR(20)    NULL,
    ToStatus        VARCHAR(20)    NULL,
    Note            NVARCHAR(1000) NULL,
    UserId          INT            NULL,
    At              DATETIME2      NOT NULL CONSTRAINT DF_TermMappingAudit_At DEFAULT SYSDATETIME()
);
CREATE INDEX IX_TermMappingAudit_Mapping ON Terminology.MappingAudit (MappingId, MappingAuditId);
END
GO

-- local lab shorthand -> words used by LOINC, for mapping suggestions (editable data, not clinical decisions)
IF OBJECT_ID(N'Terminology.SearchSynonym', N'U') IS NULL
BEGIN
CREATE TABLE Terminology.SearchSynonym (
    Term      NVARCHAR(60)  NOT NULL,
    Expansion NVARCHAR(200) NOT NULL,
    CONSTRAINT PK_TermSearchSynonym PRIMARY KEY (Term, Expansion)
);
END
GO
MERGE Terminology.SearchSynonym AS t
USING (VALUES
    (N'sugar', N'glucose'), (N'fbs', N'glucose'), (N'rbs', N'glucose'), (N'ppbs', N'glucose'), (N'gtt', N'glucose'),
    (N'hb', N'hemoglobin'), (N'hgb', N'hemoglobin'), (N'haemoglobin', N'hemoglobin'), (N'hba1c', N'hemoglobin a1c'), (N'glycated', N'hemoglobin a1c'),
    (N'tlc', N'leukocytes'), (N'wbc', N'leukocytes'), (N'rbc', N'erythrocytes'), (N'platelet', N'platelets'), (N'plt', N'platelets'),
    (N'esr', N'erythrocyte sedimentation rate'), (N'pcv', N'hematocrit'), (N'hct', N'hematocrit'), (N'mcv', N'erythrocyte mean corpuscular volume'),
    (N'sgpt', N'alanine aminotransferase'), (N'alt', N'alanine aminotransferase'), (N'sgot', N'aspartate aminotransferase'), (N'ast', N'aspartate aminotransferase'),
    (N'alp', N'alkaline phosphatase'), (N'ggt', N'gamma glutamyl transferase'), (N'bun', N'urea nitrogen'), (N'urea', N'urea nitrogen'),
    (N'tsh', N'thyrotropin'), (N't3', N'triiodothyronine'), (N't4', N'thyroxine'), (N'ft3', N'triiodothyronine free'), (N'ft4', N'thyroxine free'),
    (N'hdl', N'cholesterol in hdl'), (N'ldl', N'cholesterol in ldl'), (N'vldl', N'cholesterol in vldl'), (N'tg', N'triglyceride'),
    (N'crp', N'c reactive protein'), (N'cpk', N'creatine kinase'), (N'ldh', N'lactate dehydrogenase'), (N'psa', N'prostate specific ag'),
    (N'vitamin', N'vitamin'), (N'vit', N'vitamin'), (N'b12', N'cobalamin'), (N'uric', N'urate'), (N'calcium', N'calcium'),
    (N'pt', N'prothrombin time'), (N'inr', N'inr'), (N'aptt', N'activated partial thromboplastin time'), (N'bilirubin', N'bilirubin'),
    (N'hiv', N'hiv'), (N'hbsag', N'hepatitis b virus surface ag'), (N'hcv', N'hepatitis c virus'), (N'widal', N'salmonella'), (N'vdrl', N'reagin')
) AS v (Term, Expansion)
ON t.Term = v.Term AND t.Expansion = v.Expansion
WHEN NOT MATCHED THEN INSERT (Term, Expansion) VALUES (v.Term, v.Expansion);
GO

-- ── Releases and imports ──────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE Terminology.usp_Release_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ReleaseId, r.SystemCode, r.VersionCode, r.ReleaseDate, r.ImportedAt, r.Status, r.IsActive, r.SourceFileName,
           r.SourceFileHash, r.Notes, r.PublishedAt,
           ISNULL(NULLIF(LTRIM(RTRIM(pu.FullName)), N''), pu.Username) AS PublishedByName,
           j.ImportJobId, j.Status AS JobStatus, j.RowsRead, j.RowsStaged, j.RowsError, j.CountAdded, j.CountModified,
           j.CountRetired, j.CountUnchanged, j.Message AS JobMessage, j.StartedAt, j.FinishedAt, j.FileSizeBytes,
           (SELECT COUNT(*) FROM Terminology.LoincConcept c WHERE c.SourceVersion = r.VersionCode) AS ConceptsFromRelease
    FROM Terminology.Release r
    OUTER APPLY (SELECT TOP 1 * FROM Terminology.ImportJob x WHERE x.ReleaseId = r.ReleaseId ORDER BY x.ImportJobId DESC) j
    LEFT JOIN dbo.Users pu ON pu.Id = r.PublishedBy
    ORDER BY r.ReleaseId DESC;

    SELECT COUNT(*) AS Concepts,
           SUM(CASE WHEN IsRetired = 0 THEN 1 ELSE 0 END) AS ActiveConcepts,
           SUM(CASE WHEN IsRetired = 0 AND ClassType = '1' THEN 1 ELSE 0 END) AS LabConcepts,
           (SELECT TOP 1 VersionCode FROM Terminology.Release WHERE SystemCode = 'LOINC' AND IsActive = 1 AND VersionCode <> 'API-LOOKUP') AS ActiveVersion,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping WHERE MappingStatus = 'Approved') AS ApprovedMappings,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping WHERE MappingStatus = 'Pending') AS PendingMappings,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping WHERE NeedsReview = 1 AND MappingStatus <> 'Rejected') AS ReviewMappings
    FROM Terminology.LoincConcept;
END
GO

-- a new import: refuses a version already published / being imported; a failed / discarded one may be imported again
CREATE OR ALTER PROCEDURE Terminology.usp_Import_Create
    @VersionCode    VARCHAR(30),
    @ReleaseDate    DATE = NULL,
    @SourceFileName NVARCHAR(260),
    @SourceFileHash VARCHAR(128),
    @FileSizeBytes  BIGINT,
    @StoredFile     NVARCHAR(400),
    @Notes          NVARCHAR(1000) = NULL,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @VersionCode = LTRIM(RTRIM(@VersionCode));
    IF @VersionCode = '' OR @VersionCode = 'API-LOOKUP' THROW 51001, 'Enter the LOINC release version (for example 2.78).', 1;

    BEGIN TRANSACTION;
    DECLARE @rid INT, @st VARCHAR(20);
    SELECT @rid = ReleaseId, @st = Status FROM Terminology.Release WITH (UPDLOCK, HOLDLOCK) WHERE SystemCode = 'LOINC' AND VersionCode = @VersionCode;
    IF @rid IS NOT NULL AND @st IN ('Published')
        THROW 51002, 'This LOINC version is already published.', 1;
    IF @rid IS NOT NULL AND EXISTS (SELECT 1 FROM Terminology.ImportJob WHERE ReleaseId = @rid AND Status IN ('Queued', 'Running'))
        THROW 51003, 'This LOINC version is being imported right now.', 1;
    IF EXISTS (SELECT 1 FROM Terminology.Release r JOIN Terminology.ImportJob j ON j.ReleaseId = r.ReleaseId
               WHERE r.Status = 'Published' AND j.SourceFileHash = @SourceFileHash)
        THROW 51004, 'This exact file was already imported and published as another version.', 1;

    IF @rid IS NULL
    BEGIN
        INSERT INTO Terminology.Release (SystemCode, VersionCode, ReleaseDate, Status, SourceFileName, SourceFileHash, Notes, CreatedBy)
        VALUES ('LOINC', @VersionCode, @ReleaseDate, 'Staged', @SourceFileName, @SourceFileHash, @Notes, @UserId);
        SET @rid = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- retry of a failed / validated / discarded import: clear the old staging of that release
        DELETE s FROM Terminology.StageLoinc s JOIN Terminology.ImportJob j ON j.ImportJobId = s.ImportJobId WHERE j.ReleaseId = @rid;
        DELETE FROM Terminology.ReleaseChange WHERE ReleaseId = @rid;
        UPDATE Terminology.ImportJob SET Status = 'Discarded' WHERE ReleaseId = @rid AND Status NOT IN ('Discarded');
        UPDATE Terminology.Release SET Status = 'Staged', ReleaseDate = @ReleaseDate, SourceFileName = @SourceFileName,
               SourceFileHash = @SourceFileHash, Notes = ISNULL(@Notes, Notes), ImportedAt = SYSDATETIME()
         WHERE ReleaseId = @rid;
    END

    INSERT INTO Terminology.ImportJob (ReleaseId, Status, StoredFile, SourceFileName, SourceFileHash, FileSizeBytes, CreatedBy)
    VALUES (@rid, 'Queued', @StoredFile, @SourceFileName, @SourceFileHash, @FileSizeBytes, @UserId);
    DECLARE @jid INT = SCOPE_IDENTITY();
    COMMIT TRANSACTION;

    SELECT @jid AS ImportJobId, @rid AS ReleaseId;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Import_Get
    @ImportJobId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.*, r.VersionCode, r.ReleaseDate, r.Status AS ReleaseStatus, r.IsActive,
           (SELECT COUNT(*) FROM Terminology.ImportError e WHERE e.ImportJobId = j.ImportJobId AND e.Severity = 'CRITICAL') AS CriticalErrors,
           (SELECT COUNT(*) FROM Terminology.ImportError e WHERE e.ImportJobId = j.ImportJobId AND e.Severity = 'WARNING') AS Warnings
    FROM Terminology.ImportJob j JOIN Terminology.Release r ON r.ReleaseId = j.ReleaseId
    WHERE j.ImportJobId = @ImportJobId;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Import_SetStatus
    @ImportJobId INT,
    @Status      VARCHAR(20),
    @Message     NVARCHAR(2000) = NULL,
    @RowsRead    INT = NULL,
    @RowsStaged  INT = NULL,
    @RowsError   INT = NULL,
    @EntryName   NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Terminology.ImportJob
       SET Status = @Status, Message = ISNULL(@Message, Message),
           RowsRead = ISNULL(@RowsRead, RowsRead), RowsStaged = ISNULL(@RowsStaged, RowsStaged), RowsError = ISNULL(@RowsError, RowsError),
           EntryName = ISNULL(@EntryName, EntryName),
           StartedAt = CASE WHEN @Status = 'Running' AND StartedAt IS NULL THEN SYSDATETIME() ELSE StartedAt END,
           FinishedAt = CASE WHEN @Status IN ('Validated', 'Failed', 'Discarded', 'Published') THEN SYSDATETIME() ELSE FinishedAt END
     WHERE ImportJobId = @ImportJobId;
    IF @Status = 'Failed'
        UPDATE r SET Status = 'Failed' FROM Terminology.Release r JOIN Terminology.ImportJob j ON j.ReleaseId = r.ReleaseId
         WHERE j.ImportJobId = @ImportJobId AND r.Status <> 'Published';
END
GO

-- after staging: database checks (duplicates), then the difference against the published repository
CREATE OR ALTER PROCEDURE Terminology.usp_Import_Validate
    @ImportJobId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rid INT = (SELECT ReleaseId FROM Terminology.ImportJob WHERE ImportJobId = @ImportJobId);
    DECLARE @file NVARCHAR(260) = (SELECT ISNULL(EntryName, SourceFileName) FROM Terminology.ImportJob WHERE ImportJobId = @ImportJobId);

    BEGIN TRANSACTION;
    -- duplicate codes: the first row is kept, the others are errors
    ;WITH d AS (SELECT RowNumber, LoincCode, ROW_NUMBER() OVER (PARTITION BY LoincCode ORDER BY RowNumber) AS rn
                FROM Terminology.StageLoinc WHERE ImportJobId = @ImportJobId)
    INSERT INTO Terminology.ImportError (ImportJobId, FileName, RowNumber, LoincCode, Severity, Reason)
    SELECT @ImportJobId, @file, RowNumber, LoincCode, 'ERROR', N'Duplicate LOINC code in the file (first occurrence kept).' FROM d WHERE rn > 1;
    ;WITH d AS (SELECT RowNumber, ROW_NUMBER() OVER (PARTITION BY LoincCode ORDER BY RowNumber) AS rn
                FROM Terminology.StageLoinc WHERE ImportJobId = @ImportJobId)
    DELETE s FROM Terminology.StageLoinc s JOIN d ON d.RowNumber = s.RowNumber WHERE s.ImportJobId = @ImportJobId AND d.rn > 1;

    -- unknown source status: kept, reported as a warning
    INSERT INTO Terminology.ImportError (ImportJobId, FileName, RowNumber, LoincCode, Severity, Reason)
    SELECT @ImportJobId, @file, RowNumber, LoincCode, 'WARNING', N'Unknown STATUS value "' + ISNULL(Status, '') + N'".'
    FROM Terminology.StageLoinc
    WHERE ImportJobId = @ImportJobId AND ISNULL(Status, '') NOT IN ('ACTIVE', 'TRIAL', 'DISCOURAGED', 'DEPRECATED');

    -- the difference against the published repository
    DELETE FROM Terminology.ReleaseChange WHERE ReleaseId = @rid;
    INSERT INTO Terminology.ReleaseChange (ReleaseId, ImportJobId, LoincCode, ChangeType, NewStatus, NewName)
    SELECT @rid, @ImportJobId, s.LoincCode, 'ADDED', s.Status, s.LongCommonName
    FROM Terminology.StageLoinc s
    WHERE s.ImportJobId = @ImportJobId AND NOT EXISTS (SELECT 1 FROM Terminology.LoincConcept c WHERE c.LoincCode = s.LoincCode);

    INSERT INTO Terminology.ReleaseChange (ReleaseId, ImportJobId, LoincCode, ChangeType, OldStatus, NewStatus, OldName, NewName, ChangedFields)
    SELECT @rid, @ImportJobId, s.LoincCode,
           CASE WHEN ISNULL(c.Status, '') <> ISNULL(s.Status, '') AND c.IsRetired = 0 THEN 'STATUS' ELSE 'MODIFIED' END,
           c.Status, s.Status, c.LongCommonName, s.LongCommonName,
           NULLIF(STUFF(
               CASE WHEN ISNULL(c.LongCommonName, N'') <> ISNULL(s.LongCommonName, N'') THEN N', Name' ELSE N'' END +
               CASE WHEN ISNULL(c.Component, N'') <> ISNULL(s.Component, N'') THEN N', Component' ELSE N'' END +
               CASE WHEN ISNULL(c.Property, N'') <> ISNULL(s.Property, N'') THEN N', Property' ELSE N'' END +
               CASE WHEN ISNULL(c.TimeAspect, N'') <> ISNULL(s.TimeAspect, N'') THEN N', Time' ELSE N'' END +
               CASE WHEN ISNULL(c.SystemName, N'') <> ISNULL(s.SystemName, N'') THEN N', System' ELSE N'' END +
               CASE WHEN ISNULL(c.ScaleType, N'') <> ISNULL(s.ScaleType, N'') THEN N', Scale' ELSE N'' END +
               CASE WHEN ISNULL(c.MethodName, N'') <> ISNULL(s.MethodName, N'') THEN N', Method' ELSE N'' END +
               CASE WHEN ISNULL(c.ClassName, N'') <> ISNULL(s.ClassName, N'') THEN N', Class' ELSE N'' END +
               CASE WHEN ISNULL(c.Status, '') <> ISNULL(s.Status, '') THEN N', Status' ELSE N'' END +
               CASE WHEN ISNULL(c.ExampleUcumUnits, N'') <> ISNULL(s.ExampleUcumUnits, N'') THEN N', Units' ELSE N'' END +
               CASE WHEN c.IsRetired = 1 THEN N', Back in release' ELSE N'' END, 1, 2, N''), N'')
    FROM Terminology.StageLoinc s
    JOIN Terminology.LoincConcept c ON c.LoincCode = s.LoincCode
    WHERE s.ImportJobId = @ImportJobId AND (ISNULL(c.RowHash, 0x) <> ISNULL(s.RowHash, 0x) OR c.IsRetired = 1);

    -- concepts of the published LOINC releases missing from this file = retirement candidates (not deleted)
    INSERT INTO Terminology.ReleaseChange (ReleaseId, ImportJobId, LoincCode, ChangeType, OldStatus, OldName)
    SELECT @rid, @ImportJobId, c.LoincCode, 'RETIRED', c.Status, c.LongCommonName
    FROM Terminology.LoincConcept c
    WHERE c.IsRetired = 0 AND ISNULL(c.SourceVersion, '') <> 'API-LOOKUP'
      AND NOT EXISTS (SELECT 1 FROM Terminology.StageLoinc s WHERE s.ImportJobId = @ImportJobId AND s.LoincCode = c.LoincCode);

    DECLARE @staged INT = (SELECT COUNT(*) FROM Terminology.StageLoinc WHERE ImportJobId = @ImportJobId);
    DECLARE @errors INT = (SELECT COUNT(*) FROM Terminology.ImportError WHERE ImportJobId = @ImportJobId AND Severity IN ('ERROR', 'CRITICAL'));
    DECLARE @added INT = (SELECT COUNT(*) FROM Terminology.ReleaseChange WHERE ReleaseId = @rid AND ChangeType = 'ADDED');
    DECLARE @mod INT = (SELECT COUNT(*) FROM Terminology.ReleaseChange WHERE ReleaseId = @rid AND ChangeType IN ('MODIFIED', 'STATUS'));
    DECLARE @ret INT = (SELECT COUNT(*) FROM Terminology.ReleaseChange WHERE ReleaseId = @rid AND ChangeType = 'RETIRED');

    UPDATE Terminology.ImportJob
       SET RowsStaged = @staged, RowsError = @errors, CountAdded = @added, CountModified = @mod, CountRetired = @ret,
           CountUnchanged = @staged - @added - @mod
     WHERE ImportJobId = @ImportJobId;

    IF @staged = 0 OR EXISTS (SELECT 1 FROM Terminology.ImportError WHERE ImportJobId = @ImportJobId AND Severity = 'CRITICAL')
    BEGIN
        UPDATE Terminology.ImportJob SET Status = 'Failed', FinishedAt = SYSDATETIME(),
               Message = ISNULL(Message, N'') + CASE WHEN @staged = 0 THEN N' No valid row was found in the file.' ELSE N' Critical errors - see the error list.' END
         WHERE ImportJobId = @ImportJobId;
        UPDATE Terminology.Release SET Status = 'Failed' WHERE ReleaseId = @rid;
    END
    ELSE
    BEGIN
        UPDATE Terminology.ImportJob SET Status = 'Validated', FinishedAt = SYSDATETIME(),
               Message = CONCAT(N'Staged ', @staged, N' concepts: ', @added, N' new, ', @mod, N' changed, ', @ret, N' missing from this release. ', @errors, N' row error(s). Review, then Publish.')
         WHERE ImportJobId = @ImportJobId;
        UPDATE Terminology.Release SET Status = 'Validated' WHERE ReleaseId = @rid;
    END
    COMMIT TRANSACTION;

    EXEC Terminology.usp_Import_Get @ImportJobId = @ImportJobId;
END
GO

-- publish a validated release: one transaction - nothing is published partly
CREATE OR ALTER PROCEDURE Terminology.usp_Release_Publish
    @ReleaseId INT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @jid INT, @ver VARCHAR(30);
    SELECT TOP 1 @jid = j.ImportJobId, @ver = r.VersionCode
    FROM Terminology.Release r JOIN Terminology.ImportJob j ON j.ReleaseId = r.ReleaseId
    WHERE r.ReleaseId = @ReleaseId AND r.Status = 'Validated' AND j.Status = 'Validated'
    ORDER BY j.ImportJobId DESC;
    IF @jid IS NULL THROW 51010, 'Only a validated release can be published.', 1;

    BEGIN TRANSACTION;
    -- new concepts
    INSERT INTO Terminology.LoincConcept (LoincCode, LongCommonName, ShortName, Component, Property, TimeAspect, SystemName, ScaleType,
           MethodName, ClassName, ClassType, Status, OrderObs, ExampleUnits, ExampleUcumUnits, VersionLastChanged, SourceVersion,
           FirstReleaseId, LastChangedReleaseId, IsRetired, RowHash, UpdatedAt)
    SELECT s.LoincCode, s.LongCommonName, s.ShortName, s.Component, s.Property, s.TimeAspect, s.SystemName, s.ScaleType,
           s.MethodName, s.ClassName, s.ClassType, s.Status, s.OrderObs, s.ExampleUnits, s.ExampleUcumUnits, s.VersionLastChanged, @ver,
           @ReleaseId, @ReleaseId, 0, s.RowHash, SYSDATETIME()
    FROM Terminology.StageLoinc s
    WHERE s.ImportJobId = @jid AND NOT EXISTS (SELECT 1 FROM Terminology.LoincConcept c WHERE c.LoincCode = s.LoincCode);
    -- changed concepts
    UPDATE c SET c.LongCommonName = s.LongCommonName, c.ShortName = s.ShortName, c.Component = s.Component, c.Property = s.Property,
           c.TimeAspect = s.TimeAspect, c.SystemName = s.SystemName, c.ScaleType = s.ScaleType, c.MethodName = s.MethodName,
           c.ClassName = s.ClassName, c.ClassType = s.ClassType, c.Status = s.Status, c.OrderObs = s.OrderObs,
           c.ExampleUnits = s.ExampleUnits, c.ExampleUcumUnits = s.ExampleUcumUnits, c.VersionLastChanged = s.VersionLastChanged,
           c.SourceVersion = @ver, c.LastChangedReleaseId = @ReleaseId, c.IsRetired = 0, c.RowHash = s.RowHash, c.UpdatedAt = SYSDATETIME()
    FROM Terminology.LoincConcept c JOIN Terminology.StageLoinc s ON s.LoincCode = c.LoincCode AND s.ImportJobId = @jid
    WHERE ISNULL(c.RowHash, 0x) <> ISNULL(s.RowHash, 0x) OR c.IsRetired = 1;
    -- unchanged concepts now belong to this release too
    UPDATE c SET c.SourceVersion = @ver
    FROM Terminology.LoincConcept c JOIN Terminology.StageLoinc s ON s.LoincCode = c.LoincCode AND s.ImportJobId = @jid
    WHERE c.SourceVersion <> @ver;
    -- missing from this release: retired, never deleted
    UPDATE c SET c.IsRetired = 1, c.LastChangedReleaseId = @ReleaseId, c.UpdatedAt = SYSDATETIME()
    FROM Terminology.LoincConcept c
    JOIN Terminology.ReleaseChange rc ON rc.ReleaseId = @ReleaseId AND rc.ChangeType = 'RETIRED' AND rc.LoincCode = c.LoincCode;

    -- local mappings to concepts that changed meaningfully / were retired / deprecated need review
    UPDATE m SET m.NeedsReview = 1,
           m.ReviewReason = LEFT(CONCAT(N'Release ', @ver, N': ', rc.ChangeType, ISNULL(N' (' + rc.ChangedFields + N')', N''),
                                 CASE WHEN rc.NewStatus IN ('DEPRECATED', 'DISCOURAGED') THEN N' - now ' + rc.NewStatus ELSE N'' END), 300)
    FROM Terminology.InvestigationLoincMapping m
    JOIN Terminology.ReleaseChange rc ON rc.ReleaseId = @ReleaseId AND rc.LoincCode = m.LoincCode AND rc.ChangeType IN ('MODIFIED', 'STATUS', 'RETIRED')
    WHERE m.MappingStatus <> 'Rejected';
    INSERT INTO Terminology.MappingAudit (MappingId, InvestigationId, LoincCode, Action, FromStatus, ToStatus, Note, UserId)
    SELECT m.MappingId, m.InvestigationId, m.LoincCode, 'REVIEW', m.MappingStatus, m.MappingStatus, m.ReviewReason, @UserId
    FROM Terminology.InvestigationLoincMapping m
    JOIN Terminology.ReleaseChange rc ON rc.ReleaseId = @ReleaseId AND rc.LoincCode = m.LoincCode AND rc.ChangeType IN ('MODIFIED', 'STATUS', 'RETIRED')
    WHERE m.MappingStatus <> 'Rejected';

    -- one active LOINC file release
    UPDATE Terminology.Release SET IsActive = 0 WHERE SystemCode = 'LOINC' AND VersionCode <> 'API-LOOKUP' AND ReleaseId <> @ReleaseId;
    UPDATE Terminology.Release SET Status = 'Published', IsActive = 1, PublishedAt = SYSDATETIME(), PublishedBy = @UserId WHERE ReleaseId = @ReleaseId;
    UPDATE Terminology.ImportJob SET Status = 'Published' WHERE ImportJobId = @jid;
    -- the staged rows are no longer needed (the change report stays)
    DELETE FROM Terminology.StageLoinc WHERE ImportJobId = @jid;
    COMMIT TRANSACTION;

    EXEC Terminology.usp_Import_Get @ImportJobId = @jid;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Release_Discard
    @ReleaseId INT,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM Terminology.Release WHERE ReleaseId = @ReleaseId AND Status IN ('Staged', 'Validated', 'Failed'))
        THROW 51011, 'Only an unpublished import can be discarded.', 1;
    IF EXISTS (SELECT 1 FROM Terminology.ImportJob WHERE ReleaseId = @ReleaseId AND Status IN ('Queued', 'Running'))
        THROW 51012, 'Wait until the import has finished.', 1;
    BEGIN TRANSACTION;
    DELETE s FROM Terminology.StageLoinc s JOIN Terminology.ImportJob j ON j.ImportJobId = s.ImportJobId WHERE j.ReleaseId = @ReleaseId;
    DELETE FROM Terminology.ReleaseChange WHERE ReleaseId = @ReleaseId;
    UPDATE Terminology.ImportJob SET Status = 'Discarded', FinishedAt = SYSDATETIME() WHERE ReleaseId = @ReleaseId;
    UPDATE Terminology.Release SET Status = 'Discarded', IsActive = 0 WHERE ReleaseId = @ReleaseId;
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Import_Errors
    @ImportJobId INT,
    @PageNumber  INT = 1,
    @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize NOT BETWEEN 1 AND 200 SET @PageSize = 50;
    SELECT COUNT(*) AS TotalCount FROM Terminology.ImportError WHERE ImportJobId = @ImportJobId;
    SELECT ImportErrorId, FileName, RowNumber, LoincCode, Severity, Reason
    FROM Terminology.ImportError WHERE ImportJobId = @ImportJobId
    ORDER BY CASE Severity WHEN 'CRITICAL' THEN 0 WHEN 'ERROR' THEN 1 ELSE 2 END, ImportErrorId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Release_Changes
    @ReleaseId   INT,
    @ChangeType  VARCHAR(12) = NULL,
    @Search      NVARCHAR(100) = NULL,
    @PageNumber  INT = 1,
    @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ChangeType = NULLIF(LTRIM(RTRIM(@ChangeType)), '');
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize NOT BETWEEN 1 AND 200 SET @PageSize = 50;

    SELECT ChangeType, COUNT(*) AS Cnt FROM Terminology.ReleaseChange WHERE ReleaseId = @ReleaseId GROUP BY ChangeType;
    SELECT COUNT(*) AS TotalCount FROM Terminology.ReleaseChange rc
    WHERE rc.ReleaseId = @ReleaseId AND (@ChangeType IS NULL OR rc.ChangeType = @ChangeType)
      AND (@Search IS NULL OR rc.LoincCode LIKE @Search + '%' OR rc.NewName LIKE N'%' + @Search + N'%' OR rc.OldName LIKE N'%' + @Search + N'%');
    SELECT rc.ReleaseChangeId, rc.LoincCode, rc.ChangeType, rc.OldStatus, rc.NewStatus, rc.OldName, rc.NewName, rc.ChangedFields,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.LoincCode = rc.LoincCode AND m.MappingStatus <> 'Rejected') AS LocalMappings
    FROM Terminology.ReleaseChange rc
    WHERE rc.ReleaseId = @ReleaseId AND (@ChangeType IS NULL OR rc.ChangeType = @ChangeType)
      AND (@Search IS NULL OR rc.LoincCode LIKE @Search + '%' OR rc.NewName LIKE N'%' + @Search + N'%' OR rc.OldName LIKE N'%' + @Search + N'%')
    ORDER BY CASE rc.ChangeType WHEN 'RETIRED' THEN 0 WHEN 'STATUS' THEN 1 WHEN 'MODIFIED' THEN 2 ELSE 3 END, rc.LoincCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ── Search ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE Terminology.usp_Loinc_Search
    @Query        NVARCHAR(200) = NULL,
    @ClassName    NVARCHAR(100) = NULL,
    @LabOnly      BIT = 1,           -- CLASSTYPE 1 = laboratory
    @IncludeRetired BIT = 0,
    @Status       VARCHAR(30) = NULL,
    @OrderObs     VARCHAR(30) = NULL,
    @PageNumber   INT = 1,
    @PageSize     INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @Query = NULLIF(LTRIM(RTRIM(@Query)), N'');
    SET @ClassName = NULLIF(LTRIM(RTRIM(@ClassName)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), '');
    SET @OrderObs = NULLIF(LTRIM(RTRIM(@OrderObs)), '');
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize NOT BETWEEN 1 AND 100 SET @PageSize = 25;

    -- every word of the query must appear (in the name, component, system or short name); an exact code matches too
    DECLARE @w TABLE (w NVARCHAR(100));
    IF @Query IS NOT NULL AND @Query NOT LIKE '%[0-9]-[0-9]'
        INSERT INTO @w SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Query, ' ') WHERE LTRIM(RTRIM(value)) <> '';

    SELECT c.LoincCode, c.LongCommonName, c.ShortName, c.Component, c.Property, c.TimeAspect, c.SystemName, c.ScaleType,
           c.MethodName, c.ClassName, c.ClassType, c.Status, c.OrderObs, c.ExampleUcumUnits, c.ExampleUnits, c.SourceVersion, c.IsRetired,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.LoincCode = c.LoincCode AND m.MappingStatus = 'Approved') AS ApprovedMappings,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.LoincCode = c.LoincCode AND m.MappingStatus = 'Pending') AS PendingMappings,
           CASE WHEN c.LoincCode = @Query THEN 0
                WHEN c.Component = @Query OR c.ShortName = @Query THEN 1
                WHEN c.LongCommonName LIKE @Query + N'%' THEN 2 ELSE 3 END AS Rank_
    INTO #R
    FROM Terminology.LoincConcept c
    WHERE (@IncludeRetired = 1 OR c.IsRetired = 0)
      AND (@LabOnly = 0 OR c.ClassType = '1')
      AND (@ClassName IS NULL OR c.ClassName = @ClassName)
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@OrderObs IS NULL OR c.OrderObs = @OrderObs OR c.OrderObs = 'Both')
      AND (@Query IS NULL OR c.LoincCode = @Query
           -- every word must match: itself, or its LOINC wording (Terminology.SearchSynonym, e.g. "sugar" -> glucose)
           OR (EXISTS (SELECT 1 FROM @w) AND NOT EXISTS (SELECT 1 FROM @w x
                    WHERE c.LongCommonName NOT LIKE N'%' + x.w + N'%' AND ISNULL(c.Component, N'') NOT LIKE N'%' + x.w + N'%'
                      AND ISNULL(c.ShortName, N'') NOT LIKE N'%' + x.w + N'%' AND ISNULL(c.SystemName, N'') NOT LIKE N'%' + x.w + N'%'
                      AND NOT EXISTS (SELECT 1 FROM Terminology.SearchSynonym sy WHERE sy.Term = LOWER(x.w)
                                        AND (c.LongCommonName LIKE N'%' + sy.Expansion + N'%' OR ISNULL(c.Component, N'') LIKE N'%' + sy.Expansion + N'%')))));

    SELECT COUNT(*) AS TotalCount FROM #R;
    SELECT * FROM #R ORDER BY Rank_, CASE Status WHEN 'ACTIVE' THEN 0 WHEN 'TRIAL' THEN 1 ELSE 2 END, LEN(LongCommonName), LoincCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
    DROP TABLE #R;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Loinc_Get
    @LoincCode VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.*, fr.VersionCode AS FirstVersion, lr.VersionCode AS LastChangedVersion
    FROM Terminology.LoincConcept c
    LEFT JOIN Terminology.Release fr ON fr.ReleaseId = c.FirstReleaseId
    LEFT JOIN Terminology.Release lr ON lr.ReleaseId = c.LastChangedReleaseId
    WHERE c.LoincCode = @LoincCode;
    SELECT m.MappingId, m.InvestigationId, lim.Test_Code AS TestCode, lim.Test_Name AS TestName, m.MappingStatus, m.IsPreferred, m.NeedsReview
    FROM Terminology.InvestigationLoincMapping m
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = m.InvestigationId
    WHERE m.LoincCode = @LoincCode
    ORDER BY CASE m.MappingStatus WHEN 'Approved' THEN 0 WHEN 'Pending' THEN 1 ELSE 2 END;
    SELECT TOP 20 r.VersionCode, rc.ChangeType, rc.ChangedFields, rc.OldStatus, rc.NewStatus
    FROM Terminology.ReleaseChange rc JOIN Terminology.Release r ON r.ReleaseId = rc.ReleaseId
    WHERE rc.LoincCode = @LoincCode AND r.Status = 'Published'
    ORDER BY rc.ReleaseChangeId DESC;
    SELECT DISTINCT TOP 200 ClassName FROM Terminology.LoincConcept WHERE ClassType = '1' AND ClassName IS NOT NULL ORDER BY ClassName;
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Loinc_Classes
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ClassName, COUNT(*) AS Concepts FROM Terminology.LoincConcept
    WHERE ClassType = '1' AND IsRetired = 0 AND ClassName IS NOT NULL GROUP BY ClassName ORDER BY ClassName;
END
GO

-- a concept fetched with the LOINC Search API (not in the local repository yet), kept under release API-LOOKUP
CREATE OR ALTER PROCEDURE Terminology.usp_Loinc_SaveLookup
    @LoincCode VARCHAR(20), @LongCommonName NVARCHAR(500) = NULL, @ShortName NVARCHAR(255) = NULL, @Component NVARCHAR(500) = NULL,
    @Property NVARCHAR(100) = NULL, @TimeAspect NVARCHAR(100) = NULL, @SystemName NVARCHAR(255) = NULL, @ScaleType NVARCHAR(100) = NULL,
    @MethodName NVARCHAR(255) = NULL, @ClassName NVARCHAR(100) = NULL, @ClassType VARCHAR(10) = NULL, @Status VARCHAR(30) = NULL,
    @OrderObs VARCHAR(30) = NULL, @ExampleUcumUnits NVARCHAR(255) = NULL, @VersionLastChanged VARCHAR(30) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @LoincCode IS NULL OR @LoincCode NOT LIKE '%[0-9]-[0-9]' THROW 51020, 'Not a valid LOINC code.', 1;
    IF EXISTS (SELECT 1 FROM Terminology.LoincConcept WHERE LoincCode = @LoincCode)
    BEGIN
        SELECT CAST(0 AS BIT) AS Added, N'Already in the local repository.' AS Message; RETURN;
    END
    BEGIN TRANSACTION;
    DECLARE @rid INT = (SELECT ReleaseId FROM Terminology.Release WHERE SystemCode = 'LOINC' AND VersionCode = 'API-LOOKUP');
    IF @rid IS NULL
    BEGIN
        INSERT INTO Terminology.Release (SystemCode, VersionCode, Status, IsActive, Notes, CreatedBy, PublishedAt, PublishedBy)
        VALUES ('LOINC', 'API-LOOKUP', 'Published', 1, N'Concepts taken one by one from the LOINC Search API (until the full release file is imported).', @UserId, SYSDATETIME(), @UserId);
        SET @rid = SCOPE_IDENTITY();
    END
    INSERT INTO Terminology.LoincConcept (LoincCode, LongCommonName, ShortName, Component, Property, TimeAspect, SystemName, ScaleType, MethodName,
           ClassName, ClassType, Status, OrderObs, ExampleUcumUnits, VersionLastChanged, SourceVersion, FirstReleaseId, LastChangedReleaseId, IsRetired)
    VALUES (@LoincCode, @LongCommonName, @ShortName, @Component, @Property, @TimeAspect, @SystemName, @ScaleType, @MethodName,
           @ClassName, @ClassType, @Status, @OrderObs, @ExampleUcumUnits, @VersionLastChanged, 'API-LOOKUP', @rid, @rid, 0);
    INSERT INTO Terminology.ReleaseChange (ReleaseId, LoincCode, ChangeType, NewStatus, NewName) VALUES (@rid, @LoincCode, 'ADDED', @Status, @LongCommonName);
    COMMIT TRANSACTION;
    SELECT CAST(1 AS BIT) AS Added, N'Added to the local repository.' AS Message;
END
GO

-- ── Investigation mapping (the local Investigation Master is only read) ─────────────────────────────────────
CREATE OR ALTER PROCEDURE Terminology.usp_Mapping_Investigations
    @CompanyId   INT = NULL,
    @Search      NVARCHAR(100) = NULL,
    @State       VARCHAR(20) = NULL,    -- UNMAPPED / PENDING / APPROVED / REVIEW
    @DepartmentId INT = NULL,
    @PageNumber  INT = 1,
    @PageSize    INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @State = NULLIF(UPPER(LTRIM(RTRIM(@State))), '');
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize NOT BETWEEN 1 AND 100 SET @PageSize = 25;

    SELECT lim.Test_ID AS InvestigationId, lim.Test_Code AS TestCode, lim.Test_Name AS TestName,
           ISNULL(d.DeptName, '') AS DepartmentName, ISNULL(c.Category_Name, '') AS CategoryName,
           ISNULL(st.Sample_Name, '') AS SampleName, ISNULL(st.Container_Type, '') AS ContainerType,
           ISNULL(u.Unit_Symbol, u.Unit_Name) AS UnitName, CAST(ISNULL(lim.Is_Profile_Test, 0) AS BIT) AS IsProfile,
           CAST(CASE WHEN lim.Status = 1 AND lim.IsDeleted = 0 THEN 1 ELSE 0 END AS BIT) AS IsActive,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.InvestigationId = lim.Test_ID AND m.MappingStatus = 'Approved') AS Approved,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.InvestigationId = lim.Test_ID AND m.MappingStatus = 'Pending') AS Pending,
           (SELECT COUNT(*) FROM Terminology.InvestigationLoincMapping m WHERE m.InvestigationId = lim.Test_ID AND m.NeedsReview = 1 AND m.MappingStatus <> 'Rejected') AS Review,
           (SELECT TOP 1 m.LoincCode + N' - ' + ISNULL(lc.LongCommonName, N'') FROM Terminology.InvestigationLoincMapping m
              JOIN Terminology.LoincConcept lc ON lc.LoincCode = m.LoincCode
             WHERE m.InvestigationId = lim.Test_ID AND m.MappingStatus = 'Approved' ORDER BY m.IsPreferred DESC, m.MappingId) AS PreferredLoinc
    INTO #I
    FROM dbo.LabInvestigationMaster lim
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    WHERE ISNULL(lim.IsDeleted, 0) = 0
      AND (@CompanyId IS NULL OR lim.CompanyId = @CompanyId OR lim.CompanyId IS NULL)
      AND (@DepartmentId IS NULL OR lim.Department_ID = @DepartmentId)
      AND (@Search IS NULL OR lim.Test_Name LIKE N'%' + @Search + N'%' OR lim.Test_Code LIKE N'%' + @Search + N'%');

    SELECT COUNT(*) AS Total, SUM(CASE WHEN Approved > 0 THEN 1 ELSE 0 END) AS Mapped,
           SUM(CASE WHEN Approved = 0 AND Pending > 0 THEN 1 ELSE 0 END) AS PendingOnly,
           SUM(CASE WHEN Approved = 0 AND Pending = 0 THEN 1 ELSE 0 END) AS Unmapped,
           SUM(CASE WHEN Review > 0 THEN 1 ELSE 0 END) AS NeedReview
    FROM #I;

    SELECT * INTO #F FROM #I x
    WHERE @State IS NULL
       OR (@State = 'UNMAPPED' AND x.Approved = 0 AND x.Pending = 0)
       OR (@State = 'PENDING' AND x.Pending > 0)
       OR (@State = 'APPROVED' AND x.Approved > 0)
       OR (@State = 'REVIEW' AND x.Review > 0);
    SELECT COUNT(*) AS FilteredCount FROM #F;
    SELECT * FROM #F ORDER BY TestName, InvestigationId OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
    SELECT DISTINCT d.DeptId, d.DeptName FROM dbo.DepartmentMaster d JOIN #I i ON i.DepartmentName = d.DeptName ORDER BY d.DeptName;
    DROP TABLE #F; DROP TABLE #I;
END
GO

-- one local investigation: its attributes, its mappings and audit, and suggested LOINC candidates
CREATE OR ALTER PROCEDURE Terminology.usp_Mapping_ForInvestigation
    @InvestigationId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lim.Test_ID AS InvestigationId, lim.Test_Code AS TestCode, lim.Test_Name AS TestName,
           ISNULL(d.DeptName, '') AS DepartmentName, ISNULL(c.Category_Name, '') AS CategoryName,
           ISNULL(st.Sample_Name, '') AS SampleName, ISNULL(st.Container_Type, '') AS ContainerType,
           ISNULL(u.Unit_Symbol, u.Unit_Name) AS UnitName, CAST(ISNULL(lim.Is_Profile_Test, 0) AS BIT) AS IsProfile
    FROM dbo.LabInvestigationMaster lim
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    WHERE lim.Test_ID = @InvestigationId;

    SELECT m.MappingId, m.LoincCode, lc.LongCommonName, lc.Component, lc.SystemName, lc.ScaleType, lc.MethodName, lc.ExampleUcumUnits,
           lc.Status AS ConceptStatus, lc.IsRetired, m.MappingStatus, m.MappingMethod, m.IsPreferred, m.NeedsReview, m.ReviewReason, m.Notes,
           m.ProposedAt, ISNULL(NULLIF(LTRIM(RTRIM(pu.FullName)), N''), pu.Username) AS ProposedByName, m.ProposedBy,
           m.ApprovedAt, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), N''), au.Username) AS ApprovedByName, m.DecisionNote
    FROM Terminology.InvestigationLoincMapping m
    JOIN Terminology.LoincConcept lc ON lc.LoincCode = m.LoincCode
    LEFT JOIN dbo.Users pu ON pu.Id = m.ProposedBy
    LEFT JOIN dbo.Users au ON au.Id = m.ApprovedBy
    WHERE m.InvestigationId = @InvestigationId
    ORDER BY CASE m.MappingStatus WHEN 'Approved' THEN 0 WHEN 'Pending' THEN 1 ELSE 2 END, m.IsPreferred DESC, m.MappingId;

    SELECT TOP 50 a.At, a.Action, a.LoincCode, a.FromStatus, a.ToStatus, a.Note, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS UserName
    FROM Terminology.MappingAudit a LEFT JOIN dbo.Users u ON u.Id = a.UserId
    WHERE a.InvestigationId = @InvestigationId ORDER BY a.MappingAuditId DESC;

    -- suggestions (never approved automatically): words of the local test name in the LOINC component / name,
    -- ranked by how many words match and by the sample system (serum, blood, urine ...)
    DECLARE @name NVARCHAR(300) = (SELECT Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = @InvestigationId);
    DECLARE @sample NVARCHAR(200) = (SELECT st.Sample_Name FROM dbo.LabInvestigationMaster lim
                                     LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = lim.Sample_Type_ID WHERE lim.Test_ID = @InvestigationId);
    -- words of the local name (and of its abbreviation in brackets), their LOINC wording (Terminology.SearchSynonym)
    -- and singular forms ("Triglycerides" -> "Triglyceride"); filler words are ignored
    DECLARE @raw TABLE (w NVARCHAR(100));
    INSERT INTO @raw SELECT DISTINCT LOWER(LTRIM(RTRIM(value)))
    FROM STRING_SPLIT(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@name, N''), N'(', N' '), N')', N' '), N'/', N' '), N',', N' '), N'-', N' '), ' ')
    WHERE LEN(LTRIM(RTRIM(value))) >= 2;
    DECLARE @w TABLE (w NVARCHAR(200));
    INSERT INTO @w SELECT DISTINCT x.w FROM (
        SELECT r.w FROM @raw r WHERE LEN(r.w) >= 3
        UNION SELECT LEFT(r.w, LEN(r.w) - 1) FROM @raw r WHERE LEN(r.w) > 4 AND r.w LIKE N'%s'
        UNION SELECT sy.Expansion FROM @raw r JOIN Terminology.SearchSynonym sy ON sy.Term = r.w
    ) x
    WHERE x.w NOT IN (N'test', N'total', N'level', N'levels', N'serum', N'blood', N'urine', N'plasma', N'and', N'the', N'for', N'fasting',
                      N'random', N'post', N'prandial', N'count', N'profile', N'ratio', N'study', N'examination', N'routine', N'microscopy');
    SELECT TOP 10 c.LoincCode, c.LongCommonName, c.Component, c.SystemName, c.ScaleType, c.MethodName, c.ExampleUcumUnits, c.Status,
           x.Hits,
           CASE WHEN @sample IS NOT NULL AND (c.SystemName LIKE N'%' + LEFT(@sample, 3) + N'%') THEN 1 ELSE 0 END AS SystemMatch
    FROM Terminology.LoincConcept c
    CROSS APPLY (SELECT COUNT(*) AS Hits FROM @w w WHERE c.Component LIKE N'%' + w.w + N'%' OR c.LongCommonName LIKE N'%' + w.w + N'%') x
    WHERE c.IsRetired = 0 AND c.ClassType = '1' AND x.Hits > 0 AND EXISTS (SELECT 1 FROM @w)
      AND NOT EXISTS (SELECT 1 FROM Terminology.InvestigationLoincMapping m WHERE m.InvestigationId = @InvestigationId AND m.LoincCode = c.LoincCode)
    ORDER BY x.Hits DESC, SystemMatch DESC, CASE c.Status WHEN 'ACTIVE' THEN 0 ELSE 1 END, LEN(c.LongCommonName);
END
GO

CREATE OR ALTER PROCEDURE Terminology.usp_Mapping_Propose
    @InvestigationId INT,
    @LoincCode       VARCHAR(20),
    @Method          VARCHAR(20) = 'Manual',
    @Notes           NVARCHAR(1000) = NULL,
    @UserId          INT = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE Test_ID = @InvestigationId) THROW 51030, 'Investigation not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM Terminology.LoincConcept WHERE LoincCode = @LoincCode) THROW 51031, 'LOINC code not in the local repository.', 1;
    IF EXISTS (SELECT 1 FROM Terminology.LoincConcept WHERE LoincCode = @LoincCode AND IsRetired = 1) THROW 51032, 'This LOINC code is retired - choose an active one.', 1;
    IF @Method NOT IN ('Manual', 'Suggested', 'Imported') SET @Method = 'Manual';

    BEGIN TRANSACTION;
    DECLARE @id BIGINT, @old VARCHAR(20);
    SELECT @id = MappingId, @old = MappingStatus FROM Terminology.InvestigationLoincMapping WITH (UPDLOCK, HOLDLOCK)
    WHERE InvestigationId = @InvestigationId AND LoincCode = @LoincCode;
    IF @id IS NOT NULL AND @old IN ('Pending', 'Approved')
        THROW 51033, 'This LOINC code is already proposed / approved for this investigation.', 1;
    IF @id IS NULL
    BEGIN
        INSERT INTO Terminology.InvestigationLoincMapping (InvestigationId, LoincCode, MappingStatus, MappingMethod, Notes, ProposedBy, CompanyId)
        VALUES (@InvestigationId, @LoincCode, 'Pending', @Method, @Notes, @UserId, @CompanyId);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE Terminology.InvestigationLoincMapping
           SET MappingStatus = 'Pending', MappingMethod = @Method, Notes = @Notes, ProposedBy = @UserId, ProposedAt = SYSDATETIME(),
               ApprovedBy = NULL, ApprovedAt = NULL, DecisionNote = NULL, NeedsReview = 0, ReviewReason = NULL, IsPreferred = 0
         WHERE MappingId = @id;
    INSERT INTO Terminology.MappingAudit (MappingId, InvestigationId, LoincCode, Action, FromStatus, ToStatus, Note, UserId)
    VALUES (@id, @InvestigationId, @LoincCode, CASE WHEN @old IS NULL THEN 'PROPOSED' ELSE 'REOPENED' END, @old, 'Pending', @Notes, @UserId);
    COMMIT TRANSACTION;
    SELECT @id AS MappingId;
END
GO

-- approve / reject / set preferred / mark reviewed
CREATE OR ALTER PROCEDURE Terminology.usp_Mapping_Decide
    @MappingId BIGINT,
    @Decision  VARCHAR(20),          -- APPROVE / REJECT / PREFERRED / REVIEWED
    @Note      NVARCHAR(1000) = NULL,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inv INT, @code VARCHAR(20), @st VARCHAR(20), @retired BIT;
    SELECT @inv = m.InvestigationId, @code = m.LoincCode, @st = m.MappingStatus, @retired = c.IsRetired
    FROM Terminology.InvestigationLoincMapping m JOIN Terminology.LoincConcept c ON c.LoincCode = m.LoincCode
    WHERE m.MappingId = @MappingId;
    IF @inv IS NULL THROW 51040, 'Mapping not found.', 1;
    SET @Decision = UPPER(@Decision);

    BEGIN TRANSACTION;
    IF @Decision = 'APPROVE'
    BEGIN
        IF @st <> 'Pending' THROW 51041, 'Only a pending mapping can be approved.', 1;
        IF @retired = 1 THROW 51042, 'The LOINC code is retired - it cannot be approved.', 1;
        UPDATE Terminology.InvestigationLoincMapping SET MappingStatus = 'Approved', ApprovedBy = @UserId, ApprovedAt = SYSDATETIME(),
               DecisionNote = @Note, NeedsReview = 0, ReviewReason = NULL,
               -- the first approved mapping of an investigation is its preferred one
               IsPreferred = CASE WHEN EXISTS (SELECT 1 FROM Terminology.InvestigationLoincMapping x WHERE x.InvestigationId = @inv AND x.MappingStatus = 'Approved' AND x.IsPreferred = 1) THEN 0 ELSE 1 END
         WHERE MappingId = @MappingId;
    END
    ELSE IF @Decision = 'REJECT'
    BEGIN
        IF @st NOT IN ('Pending', 'Approved') THROW 51043, 'This mapping is already rejected.', 1;
        IF NULLIF(LTRIM(RTRIM(@Note)), N'') IS NULL THROW 51044, 'Give the reason for rejecting.', 1;
        UPDATE Terminology.InvestigationLoincMapping SET MappingStatus = 'Rejected', ApprovedBy = @UserId, ApprovedAt = SYSDATETIME(),
               DecisionNote = @Note, IsPreferred = 0, NeedsReview = 0
         WHERE MappingId = @MappingId;
        -- another approved mapping takes over as preferred
        IF NOT EXISTS (SELECT 1 FROM Terminology.InvestigationLoincMapping WHERE InvestigationId = @inv AND MappingStatus = 'Approved' AND IsPreferred = 1)
            UPDATE TOP (1) Terminology.InvestigationLoincMapping SET IsPreferred = 1 WHERE InvestigationId = @inv AND MappingStatus = 'Approved';
    END
    ELSE IF @Decision = 'PREFERRED'
    BEGIN
        IF @st <> 'Approved' THROW 51045, 'Only an approved mapping can be preferred.', 1;
        UPDATE Terminology.InvestigationLoincMapping SET IsPreferred = CASE WHEN MappingId = @MappingId THEN 1 ELSE 0 END WHERE InvestigationId = @inv AND MappingStatus = 'Approved';
    END
    ELSE IF @Decision = 'REVIEWED'
        UPDATE Terminology.InvestigationLoincMapping SET NeedsReview = 0, ReviewReason = NULL WHERE MappingId = @MappingId;
    ELSE
        THROW 51046, 'Unknown decision.', 1;

    INSERT INTO Terminology.MappingAudit (MappingId, InvestigationId, LoincCode, Action, FromStatus, ToStatus, Note, UserId)
    SELECT @MappingId, @inv, @code,
           CASE @Decision WHEN 'APPROVE' THEN 'APPROVED' WHEN 'REJECT' THEN 'REJECTED' WHEN 'PREFERRED' THEN 'PREFERRED' ELSE 'REVIEWED' END,
           @st, MappingStatus, @Note, @UserId
    FROM Terminology.InvestigationLoincMapping WHERE MappingId = @MappingId;
    COMMIT TRANSACTION;
END
GO

-- downstream consumers read only approved mappings
CREATE OR ALTER VIEW Terminology.vw_ApprovedInvestigationLoinc
AS
SELECT m.InvestigationId, m.LoincCode, m.IsPreferred, c.LongCommonName, c.ExampleUcumUnits, c.Status AS ConceptStatus, m.ApprovedAt
FROM Terminology.InvestigationLoincMapping m
JOIN Terminology.LoincConcept c ON c.LoincCode = m.LoincCode
WHERE m.MappingStatus = 'Approved';
GO

-- ── Utility > API data: menu, pages, controls, endpoints (no grants) ───────────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Controller NVARCHAR(100), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'UTILITY.APIDATA.RELEASES', N'Terminology Import',      N'LabTerminology', N'Releases', 10, N'bi bi-cloud-arrow-down me-2'),
    (N'UTILITY.APIDATA.SEARCH',   N'Standard Test Search',    N'LabTerminology', N'Search',   20, N'bi bi-search me-2'),
    (N'UTILITY.APIDATA.MAPPING',  N'Investigation Mapping',   N'LabTerminology', N'Mapping',  30, N'bi bi-diagram-3 me-2'),
    (N'UTILITY.APIDATA.CHANGES',  N'Release Changes',         N'LabTerminology', N'Changes',  40, N'bi bi-arrow-left-right me-2');

DECLARE @Controls TABLE (PageCode NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    (N'UTILITY.APIDATA.RELEASES', 'IMPORT',  N'Upload and import a release', 20),
    (N'UTILITY.APIDATA.RELEASES', 'PUBLISH', N'Publish / discard a release', 30),
    (N'UTILITY.APIDATA.SEARCH',   'ONLINE',  N'Search the LOINC Search API and add a concept', 20),
    (N'UTILITY.APIDATA.MAPPING',  'PROPOSE', N'Propose a mapping', 20),
    (N'UTILITY.APIDATA.MAPPING',  'APPROVE', N'Approve / reject mappings', 30);

DECLARE @Endpoints TABLE (PageCode NVARCHAR(150), App VARCHAR(5), Method VARCHAR(10), Controller NVARCHAR(100), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Endpoints VALUES
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'GET',  N'LabTerminology', N'Releases',      'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'GET',  N'LabTerminology', N'ImportStatus',  'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'GET',  N'LabTerminology', N'ImportErrors',  'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'POST', N'LabTerminology', N'UploadChunk',   'IMPORT'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'POST', N'LabTerminology', N'StartImport',   'IMPORT'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'POST', N'LabTerminology', N'Publish',       'PUBLISH'),
    (N'UTILITY.APIDATA.RELEASES', 'WEB', 'POST', N'LabTerminology', N'Discard',       'PUBLISH'),
    (N'UTILITY.APIDATA.SEARCH',   'WEB', 'GET',  N'LabTerminology', N'Search',        'VIEW'),
    (N'UTILITY.APIDATA.SEARCH',   'WEB', 'GET',  N'LabTerminology', N'Concept',       'VIEW'),
    (N'UTILITY.APIDATA.SEARCH',   'WEB', 'GET',  N'LabTerminology', N'OnlineSearch',  'ONLINE'),
    (N'UTILITY.APIDATA.SEARCH',   'WEB', 'POST', N'LabTerminology', N'SaveLookup',    'ONLINE'),
    (N'UTILITY.APIDATA.MAPPING',  'WEB', 'GET',  N'LabTerminology', N'Mapping',       'VIEW'),
    (N'UTILITY.APIDATA.MAPPING',  'WEB', 'GET',  N'LabTerminology', N'MappingDetail', 'VIEW'),
    (N'UTILITY.APIDATA.MAPPING',  'WEB', 'GET',  N'LabTerminology', N'SearchJson',    'VIEW'),
    (N'UTILITY.APIDATA.MAPPING',  'WEB', 'POST', N'LabTerminology', N'Propose',       'PROPOSE'),
    (N'UTILITY.APIDATA.MAPPING',  'WEB', 'POST', N'LabTerminology', N'Decide',        'APPROVE'),
    (N'UTILITY.APIDATA.CHANGES',  'WEB', 'GET',  N'LabTerminology', N'Changes',       'VIEW'),
    -- EMR.Api api/v1/terminology/*
    (N'UTILITY.APIDATA.RELEASES', 'API', 'GET',  N'Terminology', N'Releases',        'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'GET',  N'Terminology', N'Import',          'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'GET',  N'Terminology', N'ImportErrors',    'VIEW'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'POST', N'Terminology', N'UploadChunk',     'IMPORT'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'POST', N'Terminology', N'StartImport',     'IMPORT'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'POST', N'Terminology', N'Publish',         'PUBLISH'),
    (N'UTILITY.APIDATA.RELEASES', 'API', 'POST', N'Terminology', N'Discard',         'PUBLISH'),
    (N'UTILITY.APIDATA.SEARCH',   'API', 'GET',  N'Terminology', N'Search',          'VIEW'),
    (N'UTILITY.APIDATA.SEARCH',   'API', 'GET',  N'Terminology', N'Concept',         'VIEW'),
    (N'UTILITY.APIDATA.SEARCH',   'API', 'GET',  N'Terminology', N'Classes',         'VIEW'),
    (N'UTILITY.APIDATA.SEARCH',   'API', 'GET',  N'Terminology', N'OnlineSearch',    'ONLINE'),
    (N'UTILITY.APIDATA.SEARCH',   'API', 'POST', N'Terminology', N'SaveLookup',      'ONLINE'),
    (N'UTILITY.APIDATA.MAPPING',  'API', 'GET',  N'Terminology', N'Investigations',  'VIEW'),
    (N'UTILITY.APIDATA.MAPPING',  'API', 'GET',  N'Terminology', N'Mappings',        'VIEW'),
    (N'UTILITY.APIDATA.MAPPING',  'API', 'POST', N'Terminology', N'Propose',         'PROPOSE'),
    (N'UTILITY.APIDATA.MAPPING',  'API', 'POST', N'Terminology', N'Decide',          'APPROVE'),
    (N'UTILITY.APIDATA.CHANGES',  'API', 'GET',  N'Terminology', N'Changes',         'VIEW');

DECLARE @co INT, @utility INT, @menu INT, @page INT, @ctl INT;
DECLARE @pc NVARCHAR(150), @title NVARCHAR(150), @controller NVARCHAR(100), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100), @code VARCHAR(30), @method VARCHAR(10), @app VARCHAR(5);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @utility = NULL;
    SELECT @utility = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY' AND CompanyId = @co;
    IF @utility IS NOT NULL
    BEGIN
        SET @menu = NULL;
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @utility, @Menu_Type = 'MENU', @Menu_Code = N'UTILITY.APIDATA', @Title = N'API data',
             @Icon = N'bi bi-database-gear me-2', @Sort_Order = 90, @UserId = NULL, @Menu_ID = @menu OUTPUT;

        DECLARE p1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Controller, Action, Sort, Icon FROM @Pages;
        OPEN p1; FETCH NEXT FROM p1 INTO @pc, @title, @controller, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = @title, @Controller = @controller, @Action = @action,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE PageCode = @pc;
            OPEN c1; FETCH NEXT FROM c1 INTO @code, @title, @sort;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @title, @Sort_Order = @sort, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @code, @title, @sort;
            END
            CLOSE c1; DEALLOCATE c1;

            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT App, Method, Controller, Action, Code FROM @Endpoints WHERE PageCode = @pc;
            OPEN e1; FETCH NEXT FROM e1 INTO @app, @method, @controller, @action, @code;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = @app, @Http_Method = @method,
                     @Controller = @controller, @Action = @action, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @app, @method, @controller, @action, @code;
            END
            CLOSE e1; DEALLOCATE e1;
            FETCH NEXT FROM p1 INTO @pc, @title, @controller, @action, @sort, @icon;
        END
        CLOSE p1; DEALLOCATE p1;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2316 applied: Utility > API data - Standard Laboratory Test Master (LOINC) in schema Terminology.';
GO
