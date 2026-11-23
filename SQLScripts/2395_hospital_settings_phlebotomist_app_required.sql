-- ============================================================================================================
-- Migration: 2395_hospital_settings_phlebotomist_app_required.sql
-- Hospital Settings > LAB: "Is Phlebotomist App Required" (HospitalSettings.IsPhlebotomistAppRequired, per branch,
-- default 0 = No). Shown and edited on the LAB tab (view and edit). Safe to re-run.
-- ============================================================================================================
IF COL_LENGTH('dbo.HospitalSettings', 'IsPhlebotomistAppRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD IsPhlebotomistAppRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_IsPhlebotomistAppRequired DEFAULT (0);
GO
PRINT 'Script 2395 applied: Hospital Settings > Is Phlebotomist App Required.';
GO
