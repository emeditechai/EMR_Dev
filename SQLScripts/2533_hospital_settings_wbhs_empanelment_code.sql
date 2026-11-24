-- ============================================================================================================
-- Migration: 2533_hospital_settings_wbhs_empanelment_code.sql
-- Hospital Settings > OPD Configuration: "WBHS Empanelment Code" - the branch's empanelment code under the West Bengal
-- Health Scheme (free text, up to 50 characters, optional; per branch, like the other OPD settings).
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'WbhsEmpanelmentCode') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD WbhsEmpanelmentCode NVARCHAR(50) NULL;
GO
