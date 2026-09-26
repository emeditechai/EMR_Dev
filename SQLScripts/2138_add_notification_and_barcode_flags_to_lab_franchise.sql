-- =============================================
-- Script : 2138_add_notification_and_barcode_flags_to_lab_franchise.sql
-- Purpose: Add IsNotificationRequired (default 0) and PreprintedBarcode (default 1)
--          to LabFranchiseMaster, exposed as toggles on the Basic Details tab
--          of the Lab Franchise Create/Edit wizard.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_NAME = 'LabFranchiseMaster' AND COLUMN_NAME = 'IsNotificationRequired')
BEGIN
    ALTER TABLE dbo.LabFranchiseMaster
        ADD IsNotificationRequired BIT NOT NULL DEFAULT (0);
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_NAME = 'LabFranchiseMaster' AND COLUMN_NAME = 'PreprintedBarcode')
BEGIN
    ALTER TABLE dbo.LabFranchiseMaster
        ADD PreprintedBarcode BIT NOT NULL DEFAULT (1);
END
GO

-- Backfill existing rows with the intended defaults.
UPDATE dbo.LabFranchiseMaster SET IsNotificationRequired = 0 WHERE IsNotificationRequired IS NULL;
UPDATE dbo.LabFranchiseMaster SET PreprintedBarcode      = 1 WHERE PreprintedBarcode      IS NULL;
GO

-- The following stored procedures were altered to carry the two new columns:
--   dbo.usp_Api_LabFranchiseMaster_Create  -- new @IsNotificationRequired / @PreprintedBarcode params + INSERT columns
--   dbo.usp_Api_LabFranchiseMaster_Update  -- new params + SET clauses
--   dbo.usp_Api_LabFranchiseMaster_GetById -- new columns in SELECT list
--   dbo.usp_Api_LabFranchiseMaster_GetList -- new columns in SELECT list
-- These were applied directly against Dev_EMR; re-script them from the database
-- if this file is replayed against a fresh environment.
