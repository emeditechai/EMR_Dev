-- ============================================================================================================
-- Migration: 2313_hospital_settings_day_closing_reminder.sql
-- Hospital Settings > OPD Configuration: "Remind Day Closing Notification" (per branch).
-- Yes (default - today's behaviour): after login the user sees a pop-up when earlier days' OPD / LAB cash is not closed.
-- No: no pop-up after login. The bell notification and "Block Billing Until Day Closed" are not affected. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'DayClosingLoginReminder') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DayClosingLoginReminder BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_DayClosingLoginReminder DEFAULT (1);
GO

PRINT 'Script 2313 applied: Hospital Settings - Remind Day Closing Notification.';
GO
