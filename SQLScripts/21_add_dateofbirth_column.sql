-- =============================================================================
-- Script : 21_add_dateofbirth_column.sql
-- Purpose: Add DateOfBirth column to PatientMaster table.
-- Safe to re-run (checks column existence before altering).
-- =============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster')
      AND name = 'DateOfBirth'
)
BEGIN
    ALTER TABLE dbo.PatientMaster
        ADD DateOfBirth DATE NULL;
    PRINT 'Column DateOfBirth added to PatientMaster.';
END
ELSE
BEGIN
    PRINT 'Column DateOfBirth already exists — skipped.';
END
GO

PRINT 'Script 21 complete.';
GO
