-- ============================================================
-- Script 31: Add CanModify flag to Vital history SPs
-- The DB server computes the 2-minute edit window using its own
-- GETDATE(), eliminating any web-server / API timezone mismatch.
-- Run once — CREATE OR ALTER is safe to re-run.
-- ============================================================

-- ─── usp_PatientVital_GetByPatient (paged history) ───────────────────────────
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetByPatient
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
        u.FullName  AS RecordedByName,
        COUNT(*)    OVER()  AS TotalCount,
        -- Edit/Delete allowed for 2 minutes after recording (DB-server clock)
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ─── usp_PatientVital_GetById ─────────────────────────────────────────────────
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
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
        u.FullName  AS RecordedByName,
        0           AS TotalCount,
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientVitalId = @PatientVitalId AND v.IsActive = 1;
END
GO

-- ─── usp_PatientVital_GetLatest ───────────────────────────────────────────────
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
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
        u.FullName  AS RecordedByName,
        0           AS TotalCount,
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC;
END
GO

-- ─── usp_Api_VitalPrint_GetData (RS3 latest vital with CanModify) ────────────
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_VitalPrint_GetData
    @PatientId  INT,
    @BranchId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Hospital Settings
    SELECT TOP 1
        hs.Id,
        hs.BranchID                 AS BranchId,
        hs.HotelName                AS HospitalName,
        hs.Address,
        hs.ContactNumber1,
        hs.ContactNumber2,
        hs.EmailAddress,
        hs.Website,
        hs.LogoPath
    FROM dbo.HospitalSettings hs
    WHERE hs.IsActive = 1
      AND (@BranchId IS NULL OR hs.BranchID = @BranchId)
    ORDER BY CASE WHEN hs.BranchID = @BranchId THEN 0 ELSE 1 END;

    -- RS2: Patient Info
    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            ISNULL(p.FirstName  + ' ', '') +
            ISNULL(p.MiddleName + ' ', '') +
            ISNULL(p.LastName,  '')
        ))              AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.Address
    FROM dbo.PatientMaster p
    WHERE p.PatientId = @PatientId;

    -- RS3: Latest Vital (with CanModify)
    SELECT TOP 1
        v.PatientVitalId,
        v.PatientId,
        v.Height, v.Weight, v.BMI, v.BMICategory,
        v.BPSystolic, v.BPDiastolic, v.PulseRate, v.SpO2,
        v.Temperature, v.RespiratoryRate,
        v.BloodGlucose, v.GlucoseType, v.PainScore,
        v.Notes,
        v.RecordedOn,
        u.FullName  AS RecordedByName,
        0           AS TotalCount,
        CAST(CASE WHEN DATEDIFF(MINUTE, v.RecordedOn, GETDATE()) <= 2
                  THEN 1 ELSE 0 END AS BIT) AS CanModify
    FROM dbo.PatientVitals v
    LEFT JOIN dbo.Users u ON u.Id = v.RecordedByUserId
    WHERE v.PatientId = @PatientId AND v.IsActive = 1
    ORDER BY v.RecordedOn DESC;

    -- RS4: Last OPD Bill
    SELECT TOP 1
        OPDBillNo
    FROM dbo.PatientOPDService
    WHERE PatientId = @PatientId
    ORDER BY CreatedDate DESC;
END
GO

PRINT 'Script 31 complete — CanModify flag added to all vital SPs.';
