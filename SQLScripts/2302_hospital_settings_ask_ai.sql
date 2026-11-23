-- ============================================================================================================
-- Migration: 2302_hospital_settings_ask_ai.sql
-- Hospital Settings > LAB > "Enable Ask AI Features" (per branch). Yes: the AI Help Assistant is offered - the Ask AI
-- box and button on the Home dashboard, its panel, and the assistant on the Help Center pages. No (default): none of
-- it is shown and questions are refused; the Help Center guides, workflows and FAQs stay. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'EnableAskAiFeatures') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD EnableAskAiFeatures BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_EnableAskAiFeatures DEFAULT (0);
GO
PRINT 'Script 2302 applied: Hospital Settings - Enable Ask AI Features.';
GO
