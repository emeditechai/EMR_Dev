-- ============================================================
-- 11_doctor_room_master.sql
-- Creates DoctorRoomMaster table (branch-wise)
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'DoctorRoomMaster'
)
BEGIN
    CREATE TABLE DoctorRoomMaster (
        RoomId         INT IDENTITY(1,1) PRIMARY KEY,
        RoomName       NVARCHAR(10)  NOT NULL,
        FloorId        INT           NOT NULL,
        BranchId       INT           NOT NULL,
        IsActive       BIT           NOT NULL DEFAULT 1,
        CreatedBy      INT           NULL,
        CreatedDate    DATETIME2     NOT NULL DEFAULT GETDATE(),
        ModifiedBy     INT           NULL,
        ModifiedDate   DATETIME2     NULL,
        CONSTRAINT FK_DoctorRoomMaster_Floor
            FOREIGN KEY (FloorId) REFERENCES FloorMaster(FloorId),
        CONSTRAINT FK_DoctorRoomMaster_Branch
            FOREIGN KEY (BranchId) REFERENCES BranchMaster(BranchId),
        CONSTRAINT UQ_DoctorRoomMaster_Branch_Floor_RoomName
            UNIQUE (BranchId, FloorId, RoomName)
    );

    CREATE INDEX IX_DoctorRoomMaster_BranchId ON DoctorRoomMaster(BranchId);
    CREATE INDEX IX_DoctorRoomMaster_FloorId ON DoctorRoomMaster(FloorId);

    PRINT 'DoctorRoomMaster table created.';
END
ELSE
BEGIN
    PRINT 'DoctorRoomMaster table already exists — skipped.';
END
GO

-- Backward-compatible alter for already-created table
IF OBJECT_ID('DoctorRoomMaster', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('DoctorRoomMaster', 'FloorId') IS NULL
    BEGIN
        DECLARE @defaultFloorId INT;
        SELECT TOP 1 @defaultFloorId = FloorId FROM FloorMaster ORDER BY FloorId;

        IF @defaultFloorId IS NOT NULL
        BEGIN
            ALTER TABLE DoctorRoomMaster ADD FloorId INT NULL;
            UPDATE DoctorRoomMaster SET FloorId = @defaultFloorId WHERE FloorId IS NULL;
            ALTER TABLE DoctorRoomMaster ALTER COLUMN FloorId INT NOT NULL;

            IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_DoctorRoomMaster_Floor')
            BEGIN
                ALTER TABLE DoctorRoomMaster
                ADD CONSTRAINT FK_DoctorRoomMaster_Floor FOREIGN KEY (FloorId) REFERENCES FloorMaster(FloorId);
            END

            IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_DoctorRoomMaster_Branch_RoomName')
            BEGIN
                ALTER TABLE DoctorRoomMaster DROP CONSTRAINT UQ_DoctorRoomMaster_Branch_RoomName;
            END

            IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_DoctorRoomMaster_Branch_Floor_RoomName')
            BEGIN
                ALTER TABLE DoctorRoomMaster
                ADD CONSTRAINT UQ_DoctorRoomMaster_Branch_Floor_RoomName UNIQUE (BranchId, FloorId, RoomName);
            END

            IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DoctorRoomMaster_FloorId' AND object_id = OBJECT_ID('DoctorRoomMaster'))
            BEGIN
                CREATE INDEX IX_DoctorRoomMaster_FloorId ON DoctorRoomMaster(FloorId);
            END

            PRINT 'DoctorRoomMaster.FloorId added and constraints updated.';
        END
        ELSE
        BEGIN
            PRINT 'FloorMaster has no rows. Insert floor records first, then add FloorId manually.';
        END
    END
END
GO
