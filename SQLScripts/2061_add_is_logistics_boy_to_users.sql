-- ============================================================================
-- Migration: 2061_add_is_logistics_boy_to_users.sql
-- Description: Add IsLogisticsBoy, IsVehicleAvailable, and VehicleRegNo columns to Users table
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsLogisticsBoy'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsLogisticsBoy BIT NOT NULL CONSTRAINT DF_Users_IsLogisticsBoy DEFAULT (0);
    PRINT 'Added column IsLogisticsBoy to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsLogisticsBoy already exists in Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'IsVehicleAvailable'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD IsVehicleAvailable BIT NOT NULL CONSTRAINT DF_Users_IsVehicleAvailable DEFAULT (0);
    PRINT 'Added column IsVehicleAvailable to Users table.';
END
ELSE
BEGIN
    PRINT 'Column IsVehicleAvailable already exists in Users table.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'VehicleRegNo'
)
BEGIN
    ALTER TABLE dbo.Users 
    ADD VehicleRegNo NVARCHAR(50) NULL;
    PRINT 'Added column VehicleRegNo to Users table.';
END
ELSE
BEGIN
    PRINT 'Column VehicleRegNo already exists in Users table.';
END
GO
