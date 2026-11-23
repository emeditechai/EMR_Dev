-- ============================================================================================================
-- Migration: 2513_hospital_settings_is_lab_serial_no_req.sql
-- Hospital Settings > LAB: "Is Lab Serial No Req" (HospitalSettings.IsLabSerialNoReq, per branch, default 0 = No).
-- Shown and edited on the LAB tab (view and edit). Safe to re-run.
-- ============================================================================================================
IF COL_LENGTH('dbo.HospitalSettings', 'IsLabSerialNoReq') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD IsLabSerialNoReq BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_IsLabSerialNoReq DEFAULT (0);
GO
PRINT 'Script 2513 applied: Hospital Settings > Is Lab Serial No Req.';
GO
