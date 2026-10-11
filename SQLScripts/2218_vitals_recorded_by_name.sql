-- ============================================================================
-- Migration: 2218_vitals_recorded_by_name.sql
-- Description: Vital History "Recorded by" was always blank. usp_PatientVital_GetByPatient returned the recorder as
--   RecordedByUsername while the API reads RecordedByName, so the name was dropped (the recorder itself was always
--   saved in PatientVitals.RecordedByUserId). The procedure now returns RecordedByName, and all three read procedures
--   fall back to First + Last name, then the login name, when a user has no full name. Nothing else in their output
--   changes. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetByPatient
    @PatientId INT,
    @CompanyId INT = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        v.PatientVitalId,
        v.CompanyId,
        v.PatientId,
        v.Height,
        v.Weight,
        v.BMI,
        v.BMICategory,
        v.BPSystolic,
        v.BPDiastolic,
        v.PulseRate,
        v.SpO2,
        v.Temperature,
        v.RespiratoryRate,
        v.BloodGlucose,
        v.GlucoseType,
        v.PainScore,
        v.Notes,
        v.RecordedOn,
        v.RecordedByUserId,
        COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))), ''),
                 u.Username) AS RecordedByName,
        v.IsActive,
        v.CreatedOn,
        COUNT(*) OVER() AS TotalCount,
        -- Edit/Delete allowed for 2 minutes after recording (DB-server clock)
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM PatientVitals v
    LEFT JOIN Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId
      AND (@CompanyId IS NULL OR v.CompanyId = @CompanyId)
      AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetById
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
        COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))), ''),
                 u.Username) AS RecordedByName,
        0           AS TotalCount,
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientVitalId = @PatientVitalId AND v.IsActive = 1;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetLatest
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
        COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))), ''),
                 u.Username) AS RecordedByName,
        0           AS TotalCount,
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC;
END
GO

PRINT 'Script 2218: vitals Recorded by name returned by all three read procedures.';
GO
