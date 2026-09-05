-- ==============================================================================
-- Migration Script: 2035_hospitalsettings_issamplecollectionmandatory.sql
-- Description: Add IsSampleCollectionMandatory column to dbo.HospitalSettings
-- ==============================================================================

SET NOCOUNT ON;

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE Name = N'IsSampleCollectionMandatory'
      AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]')
)
BEGIN
    ALTER TABLE [dbo].[HospitalSettings] ADD [IsSampleCollectionMandatory] BIT NOT NULL CONSTRAINT DF_HospitalSettings_IsSampleCollectionMandatory DEFAULT 1;
    PRINT 'Added IsSampleCollectionMandatory column to dbo.HospitalSettings table with default value 1 (Yes).';
END
ELSE
BEGIN
    PRINT 'IsSampleCollectionMandatory column already exists in dbo.HospitalSettings table.';
END
GO
