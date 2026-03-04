-- ============================================================
-- Script 30: Vital API Stored Procedures
-- Run once against the target database (CREATE OR ALTER — safe to re-run)
-- ============================================================

-- ──────────────────────────────────────────────────────────────────────────────
-- usp_Api_VitalPrint_GetData
-- Used by GET /api/vitals/print/{patientId}?branchId=X
-- Returns 4 result sets:
--   RS1 : HospitalSettings  (1 row)
--   RS2 : PatientInfo        (1 row, same shape as usp_Api_Patient_GetById)
--   RS3 : Latest Vital       (1 row)
--   RS4 : Last OPD Bill      (1 row → OPDBillNo)
-- ──────────────────────────────────────────────────────────────────────────────
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_VitalPrint_GetData
    @PatientId  INT,
    @BranchId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Hospital Settings
    -- Note: DB column names differ from EF model names (HotelName=HospitalName, BranchID=BranchId)
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
            ISNULL(p.FirstName + ' ', '') +
            ISNULL(p.MiddleName + ' ', '') +
            ISNULL(p.LastName, '')
        ))                      AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.Address
    FROM dbo.PatientMaster p
    WHERE p.PatientId = @PatientId;

    -- RS3: Latest Vital
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
        0           AS TotalCount
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

PRINT 'Script 30 complete — Vital API stored procedures ready.';
