-- ============================================================
-- Script 26: Patient Vitals Module
-- Run this script once on the target database
-- ============================================================

-- ─── 1. PatientVitals Table ──────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PatientVitals')
BEGIN
    CREATE TABLE dbo.PatientVitals (
        PatientVitalId      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        PatientId           INT NOT NULL REFERENCES dbo.PatientMaster(PatientId),
        -- Anthropometric
        Height              DECIMAL(6,2)    NULL,   -- cm
        Weight              DECIMAL(6,2)    NULL,   -- kg
        BMI                 DECIMAL(5,2)    NULL,   -- kg/m² (auto-calculated)
        BMICategory         NVARCHAR(30)    NULL,   -- Underweight/Normal/Overweight/Obese
        -- Cardiovascular
        BPSystolic          INT             NULL,   -- mmHg
        BPDiastolic         INT             NULL,   -- mmHg
        PulseRate           INT             NULL,   -- bpm
        SpO2                DECIMAL(5,2)    NULL,   -- %
        -- General
        Temperature         DECIMAL(5,2)    NULL,   -- °F
        RespiratoryRate     INT             NULL,   -- breaths/min
        -- Optional
        BloodGlucose        DECIMAL(7,2)    NULL,   -- mg/dL
        GlucoseType         NVARCHAR(20)    NULL,   -- Fasting / Random / PP
        PainScore           INT             NULL,   -- 0-10
        Notes               NVARCHAR(500)   NULL,
        -- Audit
        RecordedOn          DATETIME        NOT NULL DEFAULT GETDATE(),
        RecordedByUserId    INT             NULL,
        IsActive            BIT             NOT NULL DEFAULT 1,
        CreatedOn           DATETIME        NOT NULL DEFAULT GETDATE(),
        CreatedBy           INT             NULL,
        UpdatedOn           DATETIME        NULL,
        UpdatedBy           INT             NULL
    );

    PRINT 'PatientVitals table created.';
END
ELSE
    PRINT 'PatientVitals table already exists — skipped.';
GO

-- ─── 2. Index for fast patient history lookup ────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PatientVitals_PatientId_RecordedOn')
BEGIN
    CREATE INDEX IX_PatientVitals_PatientId_RecordedOn
        ON dbo.PatientVitals (PatientId, RecordedOn DESC)
        INCLUDE (IsActive);
    PRINT 'Index IX_PatientVitals_PatientId_RecordedOn created.';
END
GO

-- ─── 3. usp_PatientVital_Create ──────────────────────────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_Create', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_Create;
GO

CREATE PROCEDURE dbo.usp_PatientVital_Create
    @PatientId          INT,
    @Height             DECIMAL(6,2)    = NULL,
    @Weight             DECIMAL(6,2)    = NULL,
    @BMI                DECIMAL(5,2)    = NULL,
    @BMICategory        NVARCHAR(30)    = NULL,
    @BPSystolic         INT             = NULL,
    @BPDiastolic        INT             = NULL,
    @PulseRate          INT             = NULL,
    @SpO2               DECIMAL(5,2)    = NULL,
    @Temperature        DECIMAL(5,2)    = NULL,
    @RespiratoryRate    INT             = NULL,
    @BloodGlucose       DECIMAL(7,2)    = NULL,
    @GlucoseType        NVARCHAR(20)    = NULL,
    @PainScore          INT             = NULL,
    @Notes              NVARCHAR(500)   = NULL,
    @RecordedByUserId   INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.PatientVitals (
        PatientId,
        Height, Weight, BMI, BMICategory,
        BPSystolic, BPDiastolic, PulseRate, SpO2,
        Temperature, RespiratoryRate,
        BloodGlucose, GlucoseType, PainScore,
        Notes, RecordedOn, RecordedByUserId,
        IsActive, CreatedOn, CreatedBy
    ) VALUES (
        @PatientId,
        @Height, @Weight, @BMI, @BMICategory,
        @BPSystolic, @BPDiastolic, @PulseRate, @SpO2,
        @Temperature, @RespiratoryRate,
        @BloodGlucose, @GlucoseType, @PainScore,
        @Notes, GETDATE(), @RecordedByUserId,
        1, GETDATE(), @RecordedByUserId
    );
    SELECT SCOPE_IDENTITY() AS NewId;
END
GO

-- ─── 4. usp_PatientVital_Update ──────────────────────────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_Update', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_Update;
GO

CREATE PROCEDURE dbo.usp_PatientVital_Update
    @PatientVitalId     INT,
    @Height             DECIMAL(6,2)    = NULL,
    @Weight             DECIMAL(6,2)    = NULL,
    @BMI                DECIMAL(5,2)    = NULL,
    @BMICategory        NVARCHAR(30)    = NULL,
    @BPSystolic         INT             = NULL,
    @BPDiastolic        INT             = NULL,
    @PulseRate          INT             = NULL,
    @SpO2               DECIMAL(5,2)    = NULL,
    @Temperature        DECIMAL(5,2)    = NULL,
    @RespiratoryRate    INT             = NULL,
    @BloodGlucose       DECIMAL(7,2)    = NULL,
    @GlucoseType        NVARCHAR(20)    = NULL,
    @PainScore          INT             = NULL,
    @Notes              NVARCHAR(500)   = NULL,
    @UpdatedByUserId    INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PatientVitals SET
        Height           = @Height,
        Weight           = @Weight,
        BMI              = @BMI,
        BMICategory      = @BMICategory,
        BPSystolic       = @BPSystolic,
        BPDiastolic      = @BPDiastolic,
        PulseRate        = @PulseRate,
        SpO2             = @SpO2,
        Temperature      = @Temperature,
        RespiratoryRate  = @RespiratoryRate,
        BloodGlucose     = @BloodGlucose,
        GlucoseType      = @GlucoseType,
        PainScore        = @PainScore,
        Notes            = @Notes,
        UpdatedOn        = GETDATE(),
        UpdatedBy        = @UpdatedByUserId
    WHERE PatientVitalId = @PatientVitalId AND IsActive = 1;
END
GO

-- ─── 5. usp_PatientVital_GetByPatient (paged history) ────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_GetByPatient', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_GetByPatient;
GO

CREATE PROCEDURE dbo.usp_PatientVital_GetByPatient
    @PatientId  INT,
    @PageNumber INT = 1,
    @PageSize   INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        v.PatientVitalId,
        v.PatientId,
        v.Height, v.Weight, v.BMI, v.BMICategory,
        v.BPSystolic, v.BPDiastolic, v.PulseRate, v.SpO2,
        v.Temperature, v.RespiratoryRate,
        v.BloodGlucose, v.GlucoseType, v.PainScore,
        v.Notes,
        v.RecordedOn, v.RecordedByUserId,
        u.FullName AS RecordedByName,
        COUNT(*) OVER() AS TotalCount
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ─── 6. usp_PatientVital_GetLatest ───────────────────────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_GetLatest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_GetLatest;
GO

CREATE PROCEDURE dbo.usp_PatientVital_GetLatest
    @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1
        v.PatientVitalId,
        v.PatientId,
        v.Height, v.Weight, v.BMI, v.BMICategory,
        v.BPSystolic, v.BPDiastolic, v.PulseRate, v.SpO2,
        v.Temperature, v.RespiratoryRate,
        v.BloodGlucose, v.GlucoseType, v.PainScore,
        v.Notes,
        v.RecordedOn, v.RecordedByUserId,
        u.FullName AS RecordedByName,
        0 AS TotalCount
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC;
END
GO

-- ─── 7. usp_PatientVital_GetById ─────────────────────────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_GetById', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_GetById;
GO

CREATE PROCEDURE dbo.usp_PatientVital_GetById
    @PatientVitalId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        v.PatientVitalId,
        v.PatientId,
        v.Height, v.Weight, v.BMI, v.BMICategory,
        v.BPSystolic, v.BPDiastolic, v.PulseRate, v.SpO2,
        v.Temperature, v.RespiratoryRate,
        v.BloodGlucose, v.GlucoseType, v.PainScore,
        v.Notes,
        v.RecordedOn, v.RecordedByUserId,
        u.FullName AS RecordedByName,
        0 AS TotalCount
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientVitalId = @PatientVitalId AND v.IsActive = 1;
END
GO

-- ─── 8. usp_PatientVital_Delete (soft) ───────────────────────────────────────
IF OBJECT_ID('dbo.usp_PatientVital_Delete', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_PatientVital_Delete;
GO

CREATE PROCEDURE dbo.usp_PatientVital_Delete
    @PatientVitalId  INT,
    @DeletedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PatientVitals SET
        IsActive  = 0,
        UpdatedOn = GETDATE(),
        UpdatedBy = @DeletedByUserId
    WHERE PatientVitalId = @PatientVitalId;
END
GO

PRINT 'Script 26 complete — PatientVitals module ready.';
