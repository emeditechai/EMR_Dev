-- ============================================================
-- 10_floor_master.sql
-- Creates FloorMaster table
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'FloorMaster'
)
BEGIN
    CREATE TABLE FloorMaster (
        FloorId       INT IDENTITY(1,1) PRIMARY KEY,
        FloorCode     NVARCHAR(20)  NOT NULL,
        FloorName     NVARCHAR(100) NOT NULL,
        IsActive      BIT           NOT NULL DEFAULT 1,
        CreatedBy     INT           NULL,
        CreatedDate   DATETIME2     NOT NULL DEFAULT GETDATE(),
        ModifiedBy    INT           NULL,
        ModifiedDate  DATETIME2     NULL,
        CONSTRAINT UQ_FloorMaster_FloorCode UNIQUE (FloorCode)
    );

    PRINT 'FloorMaster table created.';
END
ELSE
BEGIN
    PRINT 'FloorMaster table already exists — skipped.';
END
GO

-- Optional seed data
IF NOT EXISTS (SELECT 1 FROM FloorMaster)
BEGIN
    INSERT INTO FloorMaster (FloorCode, FloorName, IsActive) VALUES
    ('GF', 'Ground Floor', 1),
    ('F1', 'First Floor', 1),
    ('F2', 'Second Floor', 1),
    ('F3', 'Third Floor', 1);

    PRINT 'FloorMaster seeded with default floors.';
END
GO
