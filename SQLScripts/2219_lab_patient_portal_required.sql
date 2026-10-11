-- =====================================================================================================================
-- 2219  Hospital Settings > LAB: "Required Patient Portal" (per branch, B2C patients only)
--
--   LabPatientPortalRequired  No (default) = LAB booking never creates Patient Portal logins (as before).
--                             Yes = a B2C LAB booking creates the patient's Patient Portal login and e-mails the
--                             credentials, the same way OPD registration does (only once per patient, and only when the
--                             patient has a mobile number and an e-mail address). B2B bookings are never affected.
--
-- Default No = nothing changes until an administrator switches it on. Safe to re-run.
-- =====================================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'LabPatientPortalRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LabPatientPortalRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_LabPatientPortalRequired DEFAULT (0);
GO

PRINT 'Script 2219: HospitalSettings.LabPatientPortalRequired added (default No).';
GO
