-- ============================================================================================================
-- Migration: 2286_hospital_settings_ai_billing.sql
-- Hospital Settings > LAB > "Enable AI Features at Billing" (per branch). Yes: B2C / B2B booking offer the AI
-- prescription assist and the Smart ID Scan of the ID document. No (default): neither is shown nor answered -
-- billing works exactly as it did without AI. Switch it on per branch in Hospital Settings. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'EnableAiBillingFeatures') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD EnableAiBillingFeatures BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_EnableAiBillingFeatures DEFAULT (0);
GO
PRINT 'Script 2286 applied: Hospital Settings - Enable AI Features at Billing.';
GO
