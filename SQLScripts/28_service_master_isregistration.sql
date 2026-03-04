-- ── Add IsRegistration column to ServiceMaster ────────────────────────────────
-- Only services of ServiceType = 'Service' can be marked as registration.
-- Only one service per branch can have IsRegistration = 1.

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ServiceMaster')
      AND name = 'IsRegistration'
)
BEGIN
    ALTER TABLE dbo.ServiceMaster
    ADD IsRegistration BIT NOT NULL DEFAULT 0;
    PRINT 'Column IsRegistration added to ServiceMaster.';
END
ELSE
BEGIN
    PRINT 'Column IsRegistration already exists. Skipped.';
END
GO
