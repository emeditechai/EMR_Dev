-- ── Add OpdRegistrationValidityDays column to HospitalSettings ──────────────
-- Tracks how many days a patient's registration charge remains valid (OPD).

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.HospitalSettings')
      AND name = 'OpdRegistrationValidityDays'
)
BEGIN
    ALTER TABLE dbo.HospitalSettings
    ADD OpdRegistrationValidityDays INT NULL;
    PRINT 'Column OpdRegistrationValidityDays added to HospitalSettings.';
END
ELSE
BEGIN
    PRINT 'Column OpdRegistrationValidityDays already exists. Skipped.';
END
GO
