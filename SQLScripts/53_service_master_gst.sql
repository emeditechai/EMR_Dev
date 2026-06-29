-- Migration script for adding GST fields to Service Master
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'[ServiceMaster]') AND name = 'IsGstRequired')
BEGIN
    ALTER TABLE ServiceMaster ADD IsGstRequired BIT NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'[ServiceMaster]') AND name = 'GstPercentage')
BEGIN
    ALTER TABLE ServiceMaster ADD GstPercentage DECIMAL(5,2) NULL;
END
GO
