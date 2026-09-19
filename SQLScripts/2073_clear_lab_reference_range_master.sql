-- ============================================================
-- Script: 2073_clear_lab_reference_range_master.sql
-- Description: Truncates/Deletes all records from dbo.LabReferenceRangeMaster
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

PRINT 'Clearing all entries from dbo.LabReferenceRangeMaster...';

DELETE FROM dbo.LabReferenceRangeMaster;

-- Reset identity seed back to 0 so next insert starts at 1
DBCC CHECKIDENT ('dbo.LabReferenceRangeMaster', RESEED, 0);

PRINT 'Successfully cleared all reference range entries.';
GO
