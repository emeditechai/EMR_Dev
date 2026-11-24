-- ============================================================================================================
-- Migration: 2536_hospital_settings_b2b_barcode_sequence.sql
-- Hospital Settings > LAB > Billing & Sample Collection: "B2B Barcode Generate Separate Sequence Required"
-- (B2BBarcodeSeparateSequence, per branch, default 0 = No). Yes / No setting only for now: the sample barcode
-- numbering is not changed by this script.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'B2BBarcodeSeparateSequence') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD B2BBarcodeSeparateSequence BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_B2BBarcodeSeparateSequence DEFAULT (0);
GO
