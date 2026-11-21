-- ============================================================================================================
-- Migration: 2501_opd_registration_charges_not_required.sql
-- Description: Hospital Settings > OPD Configuration > "Registration Charges Not Required" (per branch, default No).
--   No  (default): unchanged - when Registration Charges Validity is set and the patient's registration has lapsed
--                  (or a new patient), an OPD consultation must be billed together with the Registration service.
--   Yes          : an OPD consultation can be billed without the Registration service; it stays available as an
--                  optional line.
--   Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'OpdRegistrationChargesNotRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD OpdRegistrationChargesNotRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_OpdRegistrationChargesNotRequired DEFAULT (0);
GO

PRINT 'Script 2501 applied: HospitalSettings.OpdRegistrationChargesNotRequired (OPD, default No).';
GO
