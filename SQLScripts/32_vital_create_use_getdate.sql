-- ============================================================
-- Script 32: Fix usp_PatientVital_Create and _Update to use
-- GETDATE() (server local time) instead of GETUTCDATE().
-- This makes RecordedOn consistent with the DATEDIFF comparison
-- in GetByPatient so CanModify works correctly within 2 minutes.
-- ============================================================

GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_Create
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
        @Notes, GETDATE(), @RecordedByUserId,   -- GETDATE() not GETUTCDATE()
        1, GETDATE(), @RecordedByUserId
    );
    SELECT SCOPE_IDENTITY() AS NewId;
END
GO

GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_Update
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
        UpdatedOn        = GETDATE(),            -- GETDATE() not GETUTCDATE()
        UpdatedBy        = @UpdatedByUserId
    WHERE PatientVitalId = @PatientVitalId AND IsActive = 1;
END
GO

-- Verify
SELECT
    o.name AS SP,
    CASE WHEN m.definition LIKE '%GETUTCDATE%' THEN 'USES GETUTCDATE (BAD)'
         ELSE 'USES GETDATE (OK)' END AS DateFunc
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.name IN ('usp_PatientVital_Create', 'usp_PatientVital_Update')
ORDER BY o.name;
GO

PRINT 'Script 32 complete.';
