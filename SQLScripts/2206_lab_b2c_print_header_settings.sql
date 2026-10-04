-- =====================================================================================================================
-- 2206  Hospital Settings > LAB: print header switches for B2C prints (per branch)
--
--   LabB2CBillPrintHeaderRequired    Yes (default) = the B2C LAB bill prints the hospital letterhead.
--                                    No = the letterhead is left blank, for pre-printed letterhead paper.
--   LabB2CReportPrintHeaderRequired  Same for the printed B2C LAB report (Lab / Microbiology report PDF).
--
-- B2B bills and reports, and the copies emailed / sent on WhatsApp to the patient, always keep the letterhead.
-- Default Yes on both = prints exactly as before. Safe to re-run.
-- =====================================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'LabB2CBillPrintHeaderRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LabB2CBillPrintHeaderRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_LabB2CBillPrintHeaderRequired DEFAULT (1);
GO

IF COL_LENGTH('dbo.HospitalSettings', 'LabB2CReportPrintHeaderRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LabB2CReportPrintHeaderRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_LabB2CReportPrintHeaderRequired DEFAULT (1);
GO
