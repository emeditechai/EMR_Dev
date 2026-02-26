-- ============================================================
-- 12_service_master.sql
-- Creates ServiceMaster table (branch-wise)
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'ServiceMaster'
)
BEGIN
    CREATE TABLE ServiceMaster (
        ServiceId      INT IDENTITY(1,1) PRIMARY KEY,
        ItemCode       NVARCHAR(20)  NOT NULL,
        ItemName       NVARCHAR(150) NOT NULL,
        ServiceType    NVARCHAR(20)  NOT NULL,
        ItemCharges    DECIMAL(18,2) NOT NULL DEFAULT 0,
        BranchId       INT           NOT NULL,
        IsActive       BIT           NOT NULL DEFAULT 1,
        CreatedBy      INT           NULL,
        CreatedDate    DATETIME2     NOT NULL DEFAULT GETDATE(),
        ModifiedBy     INT           NULL,
        ModifiedDate   DATETIME2     NULL,
        CONSTRAINT FK_ServiceMaster_Branch
            FOREIGN KEY (BranchId) REFERENCES BranchMaster(BranchId),
        CONSTRAINT UQ_ServiceMaster_Branch_ItemCode
            UNIQUE (BranchId, ItemCode)
    );

    CREATE INDEX IX_ServiceMaster_BranchId ON ServiceMaster(BranchId);

    PRINT 'ServiceMaster table created.';
END
ELSE
BEGIN
    PRINT 'ServiceMaster table already exists — skipped.';
END
GO
