-- Drop the foreign key constraint on InvestigationId to allow negative IDs for packages
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LabOrderItem_Investigation')
BEGIN
    ALTER TABLE dbo.LabOrderItem DROP CONSTRAINT FK_LabOrderItem_Investigation;
END
GO
