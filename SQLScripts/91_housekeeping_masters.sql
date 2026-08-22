-- ====================================================================================================
-- Script: 91_housekeeping_masters.sql
-- Description: Creates dbo.HKLocationMaster, dbo.HKChecklistTemplateMaster, dbo.HKCleaningMaster,
--              dbo.HKStaffMaster and Stored Procedures for Integrated Housekeeping Master
--              under Master -> IPD Master -> Housekeeping Master.
-- ====================================================================================================

-- 1. Create dbo.HKLocationMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HKLocationMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HKLocationMaster
    (
        Location_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        LocationType         NVARCHAR(50) NOT NULL, -- Ward, Room, Toilet, ICU, OT, OPD, Public Area
        Reference_ID         INT NOT NULL DEFAULT 0, -- FK to relevant physical master (WardId, RoomId, IcuId, OtId) or 0 for Public Area / General
        LocationCode         NVARCHAR(50) NOT NULL,
        LocationName         NVARCHAR(200) NOT NULL,
        Floor_ID             INT NULL,
        Building_ID          INT NULL,
        RiskLevel            NVARCHAR(50) NOT NULL DEFAULT 'Moderate Risk', -- High Risk (ICU/OT/Isolation), Moderate Risk (Wards/OPD), Low Risk (Corridors/Admin)
        Status               BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_HKLocation_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_HKLocation_Branch_Type ON dbo.HKLocationMaster(Branch_ID, LocationType, Status);
    CREATE INDEX IX_HKLocation_Ref ON dbo.HKLocationMaster(LocationType, Reference_ID);
    PRINT 'Created table dbo.HKLocationMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.HKLocationMaster already exists';
END
GO

-- 2. Create dbo.HKChecklistTemplateMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HKChecklistTemplateMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HKChecklistTemplateMaster
    (
        Template_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        TemplateCode         NVARCHAR(50) NOT NULL,
        TemplateName         NVARCHAR(100) NOT NULL,
        ChecklistItemsJSON   NVARCHAR(MAX) NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_HKTemplate_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    PRINT 'Created table dbo.HKChecklistTemplateMaster';
END
GO

-- 3. Create dbo.HKCleaningMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HKCleaningMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HKCleaningMaster
    (
        Cleaning_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        CleaningType         NVARCHAR(100) NOT NULL, -- Routine Mopping, Terminal Cleaning, Biohazard Spill Sanitation, High-Touch Disinfection, OT Fumigation, Deep Sanitation
        Frequency            NVARCHAR(100) NOT NULL, -- Every 2 Hours, Every 4 Hours, Daily, Twice Daily, Thrice Daily, On Patient Discharge, Weekly
        ChecklistTemplate_ID INT NULL,               -- FK to dbo.HKChecklistTemplateMaster
        ChemicalUsed         NVARCHAR(200) NOT NULL, -- Sodium Hypochlorite 1%, Bacillocid Extra, Virex II 256, Lysol Surface Cleaner, Glutaraldehyde 2%
        EquipmentUsed        NVARCHAR(200) NOT NULL, -- Microfiber Mop Trolley, Fogger Machine, Auto Floor Scrubber, HEPA Vacuum, Spill Kit
        SLA_Minutes          INT NOT NULL DEFAULT 30, -- Target turnaround in minutes
        Status               BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_HKCleaning_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_HKCleaning_Template FOREIGN KEY (ChecklistTemplate_ID) REFERENCES dbo.HKChecklistTemplateMaster(Template_ID)
    );
    CREATE INDEX IX_HKCleaning_Branch_Status ON dbo.HKCleaningMaster(Branch_ID, Status);
    PRINT 'Created table dbo.HKCleaningMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.HKCleaningMaster already exists';
END
GO

-- 4. Create dbo.HKStaffMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HKStaffMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HKStaffMaster
    (
        HKStaff_ID           INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        Staff_ID             INT NOT NULL,           -- FK to dbo.Users (Housekeeping Employee)
        ShiftMaster_ID       INT NOT NULL,           -- FK to dbo.ShiftMaster
        Supervisor_ID        INT NULL,               -- FK to dbo.Users (Supervisor/Incharge)
        AreaAllocation_ID    INT NOT NULL,           -- FK to dbo.HKLocationMaster
        Status               BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_HKStaff_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_HKStaff_StaffUser FOREIGN KEY (Staff_ID) REFERENCES dbo.Users(Id),
        CONSTRAINT FK_HKStaff_Shift FOREIGN KEY (ShiftMaster_ID) REFERENCES dbo.ShiftMaster(ShiftMaster_ID),
        CONSTRAINT FK_HKStaff_SupervisorUser FOREIGN KEY (Supervisor_ID) REFERENCES dbo.Users(Id),
        CONSTRAINT FK_HKStaff_Location FOREIGN KEY (AreaAllocation_ID) REFERENCES dbo.HKLocationMaster(Location_ID)
    );
    CREATE INDEX IX_HKStaff_Branch_Status ON dbo.HKStaffMaster(Branch_ID, Status);
    CREATE INDEX IX_HKStaff_Staff ON dbo.HKStaffMaster(Staff_ID);
    CREATE INDEX IX_HKStaff_Shift ON dbo.HKStaffMaster(ShiftMaster_ID);
    CREATE INDEX IX_HKStaff_Location ON dbo.HKStaffMaster(AreaAllocation_ID);
    PRINT 'Created table dbo.HKStaffMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.HKStaffMaster already exists';
END
GO

-- ====================================================================================================
-- STORED PROCEDURES: LOCATION MASTER
-- ====================================================================================================

-- 5. Stored Procedure: usp_Api_HKLocation_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_GetList
    @BranchId     INT = NULL,
    @LocationType NVARCHAR(50) = NULL,
    @Status       BIT = NULL,
    @Search       NVARCHAR(100) = NULL,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        l.Location_ID,
        l.CompanyId,
        l.Branch_ID,
        b.BranchName,
        b.BranchCode,
        l.LocationType,
        l.Reference_ID,
        l.LocationCode,
        l.LocationName,
        l.Floor_ID,
        f.FloorName,
        l.Building_ID,
        bu.BuildingName,
        l.RiskLevel,
        l.Status,
        l.CreatedBy,
        l.CreatedDate,
        l.ModifiedBy,
        l.ModifiedDate,
        -- Resolved Physical Master Reference Name
        CASE l.LocationType
            WHEN 'Ward' THEN (SELECT TOP 1 w.WardName + ' (' + w.WardCode + ')' FROM dbo.WardMaster w WHERE w.WardId = l.Reference_ID)
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = l.Reference_ID)
            WHEN 'ICU'  THEN (SELECT TOP 1 i.IcuName + ' [' + i.IcuCode + ']' FROM dbo.IcuMaster i WHERE i.IcuId = l.Reference_ID)
            WHEN 'OT'   THEN (SELECT TOP 1 o.OtName + ' [' + o.OtCode + ']' FROM dbo.OtMaster o WHERE o.OtId = l.Reference_ID)
            WHEN 'OPD'  THEN (SELECT TOP 1 dr.RoomName FROM dbo.DoctorRoomMaster dr WHERE dr.RoomId = l.Reference_ID)
            ELSE l.LocationName
        END AS ReferenceEntityName,
        (SELECT COUNT(1) FROM dbo.HKStaffMaster s WHERE s.AreaAllocation_ID = l.Location_ID AND s.Status = 1) AS AssignedStaffCount
    FROM dbo.HKLocationMaster l
    INNER JOIN dbo.Branchmaster b ON l.Branch_ID = b.BranchID
    LEFT JOIN dbo.FloorMaster f ON l.Floor_ID = f.FloorId
    LEFT JOIN dbo.BuildingMaster bu ON l.Building_ID = bu.BuildingId
    WHERE (@BranchId IS NULL OR l.Branch_ID = @BranchId)
      AND (@LocationType IS NULL OR @LocationType = '' OR l.LocationType = @LocationType)
      AND (@Status IS NULL OR l.Status = @Status)
      AND (@CompanyId IS NULL OR l.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           l.LocationCode LIKE '%' + @Search + '%' OR
           l.LocationName LIKE '%' + @Search + '%' OR
           l.LocationType LIKE '%' + @Search + '%')
    ORDER BY l.Location_ID DESC;
END
GO

-- 6. Stored Procedure: usp_Api_HKLocation_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_GetById
    @Location_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        l.Location_ID,
        l.CompanyId,
        l.Branch_ID,
        b.BranchName,
        b.BranchCode,
        l.LocationType,
        l.Reference_ID,
        l.LocationCode,
        l.LocationName,
        l.Floor_ID,
        f.FloorName,
        l.Building_ID,
        bu.BuildingName,
        l.RiskLevel,
        l.Status,
        l.CreatedBy,
        l.CreatedDate,
        l.ModifiedBy,
        l.ModifiedDate,
        CASE l.LocationType
            WHEN 'Ward' THEN (SELECT TOP 1 w.WardName + ' (' + w.WardCode + ')' FROM dbo.WardMaster w WHERE w.WardId = l.Reference_ID)
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = l.Reference_ID)
            WHEN 'ICU'  THEN (SELECT TOP 1 i.IcuName + ' [' + i.IcuCode + ']' FROM dbo.IcuMaster i WHERE i.IcuId = l.Reference_ID)
            WHEN 'OT'   THEN (SELECT TOP 1 o.OtName + ' [' + o.OtCode + ']' FROM dbo.OtMaster o WHERE o.OtId = l.Reference_ID)
            WHEN 'OPD'  THEN (SELECT TOP 1 dr.RoomName FROM dbo.DoctorRoomMaster dr WHERE dr.RoomId = l.Reference_ID)
            ELSE l.LocationName
        END AS ReferenceEntityName
    FROM dbo.HKLocationMaster l
    INNER JOIN dbo.Branchmaster b ON l.Branch_ID = b.BranchID
    LEFT JOIN dbo.FloorMaster f ON l.Floor_ID = f.FloorId
    LEFT JOIN dbo.BuildingMaster bu ON l.Building_ID = bu.BuildingId
    WHERE l.Location_ID = @Location_ID;
END
GO

-- 7. Stored Procedure: usp_Api_HKLocation_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_Create
    @CompanyId      INT = 1,
    @Branch_ID      INT,
    @LocationType   NVARCHAR(50),
    @Reference_ID   INT = 0,
    @LocationCode   NVARCHAR(50),
    @LocationName   NVARCHAR(200),
    @Floor_ID       INT = NULL,
    @Building_ID    INT = NULL,
    @RiskLevel      NVARCHAR(50) = 'Moderate Risk',
    @Status         BIT = 1,
    @CreatedBy      INT = NULL,
    @NewLocation_ID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.HKLocationMaster WHERE Branch_ID = @Branch_ID AND LocationCode = @LocationCode)
    BEGIN
        RAISERROR('A housekeeping location with this Location Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    INSERT INTO dbo.HKLocationMaster
    (
        CompanyId,
        Branch_ID,
        LocationType,
        Reference_ID,
        LocationCode,
        LocationName,
        Floor_ID,
        Building_ID,
        RiskLevel,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @LocationType,
        @Reference_ID,
        @LocationCode,
        @LocationName,
        @Floor_ID,
        @Building_ID,
        @RiskLevel,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewLocation_ID = SCOPE_IDENTITY();
END
GO

-- 8. Stored Procedure: usp_Api_HKLocation_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_Update
    @Location_ID    INT,
    @Branch_ID      INT,
    @LocationType   NVARCHAR(50),
    @Reference_ID   INT = 0,
    @LocationCode   NVARCHAR(50),
    @LocationName   NVARCHAR(200),
    @Floor_ID       INT = NULL,
    @Building_ID    INT = NULL,
    @RiskLevel      NVARCHAR(50) = 'Moderate Risk',
    @Status         BIT = 1,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.HKLocationMaster WHERE Branch_ID = @Branch_ID AND LocationCode = @LocationCode AND Location_ID <> @Location_ID)
    BEGIN
        RAISERROR('Another housekeeping location with this Location Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    UPDATE dbo.HKLocationMaster
    SET
        Branch_ID    = @Branch_ID,
        LocationType = @LocationType,
        Reference_ID = @Reference_ID,
        LocationCode = @LocationCode,
        LocationName = @LocationName,
        Floor_ID     = @Floor_ID,
        Building_ID  = @Building_ID,
        RiskLevel    = @RiskLevel,
        Status       = @Status,
        ModifiedBy   = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE Location_ID = @Location_ID;
END
GO

-- 9. Stored Procedure: usp_Api_HKLocation_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_ToggleStatus
    @Location_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HKLocationMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE Location_ID = @Location_ID;

    SELECT Status FROM dbo.HKLocationMaster WHERE Location_ID = @Location_ID;
END
GO

-- 10. Stored Procedure: usp_Api_HKLocation_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_Delete
    @Location_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.HKLocationMaster
    WHERE Location_ID = @Location_ID;
END
GO

-- 11. Stored Procedure: usp_Api_HKLocation_GetPhysicalMasterItems
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKLocation_GetPhysicalMasterItems
    @LocationType NVARCHAR(50),
    @BranchId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationType = 'Ward'
    BEGIN
        SELECT 
            w.WardId AS Reference_ID,
            w.WardCode AS ItemCode,
            w.WardName + ' (' + w.WardCode + ')' AS ItemName,
            w.FloorId AS Floor_ID,
            f.BuildingId AS Building_ID
        FROM dbo.WardMaster w
        LEFT JOIN dbo.FloorMaster f ON w.FloorId = f.FloorId
        WHERE (@BranchId IS NULL OR w.BranchId = @BranchId) AND w.IsActive = 1
        ORDER BY w.WardName;
    END
    ELSE IF @LocationType = 'Room' OR @LocationType = 'Toilet'
    BEGIN
        SELECT 
            r.RoomId AS Reference_ID,
            r.RoomNumber AS ItemCode,
            'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ' - ' + ISNULL(r.RoomType, '') + ')' AS ItemName,
            r.FloorId AS Floor_ID,
            r.BuildingId AS Building_ID
        FROM dbo.RoomMaster r
        WHERE (@BranchId IS NULL OR r.BranchId = @BranchId) AND r.IsActive = 1
        ORDER BY r.RoomNumber;
    END
    ELSE IF @LocationType = 'ICU'
    BEGIN
        SELECT 
            i.IcuId AS Reference_ID,
            i.IcuCode AS ItemCode,
            i.IcuName + ' [' + i.IcuCode + ']' AS ItemName,
            w.FloorId AS Floor_ID,
            f.BuildingId AS Building_ID
        FROM dbo.IcuMaster i
        LEFT JOIN dbo.WardMaster w ON i.WardId = w.WardId
        LEFT JOIN dbo.FloorMaster f ON w.FloorId = f.FloorId
        WHERE (@BranchId IS NULL OR i.BranchId = @BranchId) AND i.IsActive = 1
        ORDER BY i.IcuName;
    END
    ELSE IF @LocationType = 'OT'
    BEGIN
        SELECT 
            o.OtId AS Reference_ID,
            o.OtCode AS ItemCode,
            o.OtName + ' [' + o.OtCode + ']' AS ItemName,
            o.FloorId AS Floor_ID,
            f.BuildingId AS Building_ID
        FROM dbo.OtMaster o
        LEFT JOIN dbo.FloorMaster f ON o.FloorId = f.FloorId
        WHERE (@BranchId IS NULL OR o.BranchId = @BranchId) AND o.IsActive = 1
        ORDER BY o.OtName;
    END
    ELSE IF @LocationType = 'OPD'
    BEGIN
        SELECT 
            dr.RoomId AS Reference_ID,
            CAST(dr.RoomId AS NVARCHAR(50)) AS ItemCode,
            dr.RoomName AS ItemName,
            dr.FloorId AS Floor_ID,
            f.BuildingId AS Building_ID
        FROM dbo.DoctorRoomMaster dr
        LEFT JOIN dbo.FloorMaster f ON dr.FloorId = f.FloorId
        WHERE (@BranchId IS NULL OR dr.BranchId = @BranchId) AND dr.IsActive = 1
        ORDER BY dr.RoomName;
    END
    ELSE -- Public Area or Generic
    BEGIN
        SELECT 
            0 AS Reference_ID,
            'PUBLIC' AS ItemCode,
            'General Public Area / Common Zone' AS ItemName,
            NULL AS Floor_ID,
            NULL AS Building_ID;
    END
END
GO

-- ====================================================================================================
-- STORED PROCEDURES: CLEANING MASTER
-- ====================================================================================================

-- 12. Stored Procedure: usp_Api_HKCleaning_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_GetList
    @BranchId     INT = NULL,
    @CleaningType NVARCHAR(100) = NULL,
    @Status       BIT = NULL,
    @Search       NVARCHAR(100) = NULL,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Cleaning_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.CleaningType,
        c.Frequency,
        c.ChecklistTemplate_ID,
        t.TemplateName AS ChecklistTemplateName,
        t.TemplateCode AS ChecklistTemplateCode,
        c.ChemicalUsed,
        c.EquipmentUsed,
        c.SLA_Minutes,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.HKCleaningMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    LEFT JOIN dbo.HKChecklistTemplateMaster t ON c.ChecklistTemplate_ID = t.Template_ID
    WHERE (@BranchId IS NULL OR c.Branch_ID = @BranchId)
      AND (@CleaningType IS NULL OR @CleaningType = '' OR c.CleaningType = @CleaningType)
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           c.CleaningType LIKE '%' + @Search + '%' OR
           c.Frequency LIKE '%' + @Search + '%' OR
           c.ChemicalUsed LIKE '%' + @Search + '%' OR
           c.EquipmentUsed LIKE '%' + @Search + '%')
    ORDER BY c.Cleaning_ID DESC;
END
GO

-- 13. Stored Procedure: usp_Api_HKCleaning_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_GetById
    @Cleaning_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Cleaning_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.CleaningType,
        c.Frequency,
        c.ChecklistTemplate_ID,
        t.TemplateName AS ChecklistTemplateName,
        t.TemplateCode AS ChecklistTemplateCode,
        c.ChemicalUsed,
        c.EquipmentUsed,
        c.SLA_Minutes,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.HKCleaningMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    LEFT JOIN dbo.HKChecklistTemplateMaster t ON c.ChecklistTemplate_ID = t.Template_ID
    WHERE c.Cleaning_ID = @Cleaning_ID;
END
GO

-- 14. Stored Procedure: usp_Api_HKCleaning_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_Create
    @CompanyId            INT = 1,
    @Branch_ID            INT,
    @CleaningType         NVARCHAR(100),
    @Frequency            NVARCHAR(100),
    @ChecklistTemplate_ID INT = NULL,
    @ChemicalUsed         NVARCHAR(200),
    @EquipmentUsed        NVARCHAR(200),
    @SLA_Minutes          INT = 30,
    @Status               BIT = 1,
    @CreatedBy            INT = NULL,
    @NewCleaning_ID       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.HKCleaningMaster
    (
        CompanyId,
        Branch_ID,
        CleaningType,
        Frequency,
        ChecklistTemplate_ID,
        ChemicalUsed,
        EquipmentUsed,
        SLA_Minutes,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @CleaningType,
        @Frequency,
        @ChecklistTemplate_ID,
        @ChemicalUsed,
        @EquipmentUsed,
        @SLA_Minutes,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewCleaning_ID = SCOPE_IDENTITY();
END
GO

-- 15. Stored Procedure: usp_Api_HKCleaning_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_Update
    @Cleaning_ID          INT,
    @Branch_ID            INT,
    @CleaningType         NVARCHAR(100),
    @Frequency            NVARCHAR(100),
    @ChecklistTemplate_ID INT = NULL,
    @ChemicalUsed         NVARCHAR(200),
    @EquipmentUsed        NVARCHAR(200),
    @SLA_Minutes          INT = 30,
    @Status               BIT = 1,
    @ModifiedBy           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HKCleaningMaster
    SET
        Branch_ID            = @Branch_ID,
        CleaningType         = @CleaningType,
        Frequency            = @Frequency,
        ChecklistTemplate_ID = @ChecklistTemplate_ID,
        ChemicalUsed         = @ChemicalUsed,
        EquipmentUsed        = @EquipmentUsed,
        SLA_Minutes          = @SLA_Minutes,
        Status               = @Status,
        ModifiedBy           = @ModifiedBy,
        ModifiedDate         = GETDATE()
    WHERE Cleaning_ID        = @Cleaning_ID;
END
GO

-- 16. Stored Procedure: usp_Api_HKCleaning_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_ToggleStatus
    @Cleaning_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HKCleaningMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE Cleaning_ID = @Cleaning_ID;

    SELECT Status FROM dbo.HKCleaningMaster WHERE Cleaning_ID = @Cleaning_ID;
END
GO

-- 17. Stored Procedure: usp_Api_HKCleaning_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKCleaning_Delete
    @Cleaning_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.HKCleaningMaster
    WHERE Cleaning_ID = @Cleaning_ID;
END
GO

-- ====================================================================================================
-- STORED PROCEDURES: HOUSEKEEPING STAFF MASTER
-- ====================================================================================================

-- 18. Stored Procedure: usp_Api_HKStaff_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_GetList
    @BranchId          INT = NULL,
    @ShiftMaster_ID    INT = NULL,
    @AreaAllocation_ID INT = NULL,
    @Status            BIT = NULL,
    @Search            NVARCHAR(100) = NULL,
    @CompanyId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        s.HKStaff_ID,
        s.CompanyId,
        s.Branch_ID,
        b.BranchName,
        b.BranchCode,
        s.Staff_ID,
        u.Username AS StaffUsername,
        ISNULL(u.FullName, u.Username) AS StaffName,
        u.PhoneNumber AS StaffPhone,
        s.ShiftMaster_ID,
        sh.ShiftCode,
        sh.ShiftName,
        sh.StartTime AS ShiftStartTime,
        sh.EndTime AS ShiftEndTime,
        s.Supervisor_ID,
        sup.Username AS SupervisorUsername,
        ISNULL(sup.FullName, sup.Username) AS SupervisorName,
        s.AreaAllocation_ID,
        loc.LocationCode,
        loc.LocationName,
        loc.LocationType,
        loc.RiskLevel,
        s.Status,
        s.CreatedBy,
        s.CreatedDate,
        s.ModifiedBy,
        s.ModifiedDate
    FROM dbo.HKStaffMaster s
    INNER JOIN dbo.Branchmaster b ON s.Branch_ID = b.BranchID
    INNER JOIN dbo.Users u ON s.Staff_ID = u.Id
    INNER JOIN dbo.ShiftMaster sh ON s.ShiftMaster_ID = sh.ShiftMaster_ID
    INNER JOIN dbo.HKLocationMaster loc ON s.AreaAllocation_ID = loc.Location_ID
    LEFT JOIN dbo.Users sup ON s.Supervisor_ID = sup.Id
    WHERE (@BranchId IS NULL OR s.Branch_ID = @BranchId)
      AND (@ShiftMaster_ID IS NULL OR s.ShiftMaster_ID = @ShiftMaster_ID)
      AND (@AreaAllocation_ID IS NULL OR s.AreaAllocation_ID = @AreaAllocation_ID)
      AND (@Status IS NULL OR s.Status = @Status)
      AND (@CompanyId IS NULL OR s.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           u.FullName LIKE '%' + @Search + '%' OR
           u.Username LIKE '%' + @Search + '%' OR
           loc.LocationName LIKE '%' + @Search + '%' OR
           sh.ShiftName LIKE '%' + @Search + '%')
    ORDER BY s.HKStaff_ID DESC;
END
GO

-- 19. Stored Procedure: usp_Api_HKStaff_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_GetById
    @HKStaff_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        s.HKStaff_ID,
        s.CompanyId,
        s.Branch_ID,
        b.BranchName,
        b.BranchCode,
        s.Staff_ID,
        u.Username AS StaffUsername,
        ISNULL(u.FullName, u.Username) AS StaffName,
        u.PhoneNumber AS StaffPhone,
        s.ShiftMaster_ID,
        sh.ShiftCode,
        sh.ShiftName,
        sh.StartTime AS ShiftStartTime,
        sh.EndTime AS ShiftEndTime,
        s.Supervisor_ID,
        sup.Username AS SupervisorUsername,
        ISNULL(sup.FullName, sup.Username) AS SupervisorName,
        s.AreaAllocation_ID,
        loc.LocationCode,
        loc.LocationName,
        loc.LocationType,
        loc.RiskLevel,
        s.Status,
        s.CreatedBy,
        s.CreatedDate,
        s.ModifiedBy,
        s.ModifiedDate
    FROM dbo.HKStaffMaster s
    INNER JOIN dbo.Branchmaster b ON s.Branch_ID = b.BranchID
    INNER JOIN dbo.Users u ON s.Staff_ID = u.Id
    INNER JOIN dbo.ShiftMaster sh ON s.ShiftMaster_ID = sh.ShiftMaster_ID
    INNER JOIN dbo.HKLocationMaster loc ON s.AreaAllocation_ID = loc.Location_ID
    LEFT JOIN dbo.Users sup ON s.Supervisor_ID = sup.Id
    WHERE s.HKStaff_ID = @HKStaff_ID;
END
GO

-- 20. Stored Procedure: usp_Api_HKStaff_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_Create
    @CompanyId          INT = 1,
    @Branch_ID          INT,
    @Staff_ID           INT,
    @ShiftMaster_ID     INT,
    @Supervisor_ID      INT = NULL,
    @AreaAllocation_ID  INT,
    @Status             BIT = 1,
    @CreatedBy          INT = NULL,
    @NewHKStaff_ID      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.HKStaffMaster
    (
        CompanyId,
        Branch_ID,
        Staff_ID,
        ShiftMaster_ID,
        Supervisor_ID,
        AreaAllocation_ID,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @Staff_ID,
        @ShiftMaster_ID,
        @Supervisor_ID,
        @AreaAllocation_ID,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewHKStaff_ID = SCOPE_IDENTITY();
END
GO

-- 21. Stored Procedure: usp_Api_HKStaff_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_Update
    @HKStaff_ID         INT,
    @Branch_ID          INT,
    @Staff_ID           INT,
    @ShiftMaster_ID     INT,
    @Supervisor_ID      INT = NULL,
    @AreaAllocation_ID  INT,
    @Status             BIT = 1,
    @ModifiedBy         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HKStaffMaster
    SET
        Branch_ID         = @Branch_ID,
        Staff_ID          = @Staff_ID,
        ShiftMaster_ID    = @ShiftMaster_ID,
        Supervisor_ID     = @Supervisor_ID,
        AreaAllocation_ID = @AreaAllocation_ID,
        Status            = @Status,
        ModifiedBy        = @ModifiedBy,
        ModifiedDate      = GETDATE()
    WHERE HKStaff_ID      = @HKStaff_ID;
END
GO

-- 22. Stored Procedure: usp_Api_HKStaff_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_ToggleStatus
    @HKStaff_ID INT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HKStaffMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE HKStaff_ID = @HKStaff_ID;

    SELECT Status FROM dbo.HKStaffMaster WHERE HKStaff_ID = @HKStaff_ID;
END
GO

-- 23. Stored Procedure: usp_Api_HKStaff_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_HKStaff_Delete
    @HKStaff_ID INT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.HKStaffMaster
    WHERE HKStaff_ID = @HKStaff_ID;
END
GO

-- ====================================================================================================
-- SEED SAMPLE HOUSEKEEPING DATA
-- ====================================================================================================

-- 24. Seed Checklist Templates
IF NOT EXISTS (SELECT 1 FROM dbo.HKChecklistTemplateMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.HKChecklistTemplateMaster
        (CompanyId, Branch_ID, TemplateCode, TemplateName, ChecklistItemsJSON, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'CHK-ROUTINE', 'Standard Ward & Room Routine Checklist',
         '["Empty dustbins & replace color-coded biohazard bags","Mop floors with Sodium Hypochlorite 1%","Wipe high-touch bed rails & call bells","Clean & sanitize attached patient toilet","Replenish liquid soap & tissue rolls"]', 1, GETDATE()),
        (1, @DefaultBranch, 'CHK-ICU-DEEP', 'ICU Critical Care Deep Sanitation Checklist',
         '["Disinfect ventilator panels & monitor casings with Bacillocid","Scrub non-slip flooring with Virex II","Terminal mop under bed & trolley wheels","Sanitize handwash scrub sink & splashbacks","Replace sharps disposal container"]', 1, GETDATE()),
        (1, @DefaultBranch, 'CHK-OT-TERM', 'Operation Theatre Terminal Fumigation Checklist',
         '["Complete carbolization of OT tables and surgical lights","Fumigate OT with dry fogger machine","Clean air suction grills & laminar flow plenum","Sterilize scrub station & kick buckets","Maintain positive pressure sealing verification"]', 1, GETDATE());

        PRINT 'Sample Checklist Templates seeded.';
    END
END
GO

-- 25. Seed Housekeeping Locations
IF NOT EXISTS (SELECT 1 FROM dbo.HKLocationMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    DECLARE @SampleWard INT, @SampleRoom INT, @SampleIcu INT, @SampleOt INT;
    SELECT TOP 1 @SampleWard = WardId FROM dbo.WardMaster ORDER BY WardId;
    SELECT TOP 1 @SampleRoom = RoomId FROM dbo.RoomMaster ORDER BY RoomId;
    SELECT TOP 1 @SampleIcu  = IcuId FROM dbo.IcuMaster ORDER BY IcuId;
    SELECT TOP 1 @SampleOt   = OtId FROM dbo.OtMaster ORDER BY OtId;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.HKLocationMaster
        (CompanyId, Branch_ID, LocationType, Reference_ID, LocationCode, LocationName, RiskLevel, Status, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'Ward', ISNULL(@SampleWard, 1), 'LOC-WARD-01', 'General Medical Ward - East Wing', 'Moderate Risk', 1, GETDATE()),
        (1, @DefaultBranch, 'Room', ISNULL(@SampleRoom, 1), 'LOC-ROOM-101', 'Deluxe Patient Suite 101', 'Moderate Risk', 1, GETDATE()),
        (1, @DefaultBranch, 'ICU',  ISNULL(@SampleIcu, 1),  'LOC-ICU-MAIN', 'Main Critical Care Unit (ICU)', 'High Risk', 1, GETDATE()),
        (1, @DefaultBranch, 'OT',   ISNULL(@SampleOt, 1),   'LOC-OT-01',    'Major Operation Theatre Complex #1', 'High Risk', 1, GETDATE()),
        (1, @DefaultBranch, 'Toilet', ISNULL(@SampleRoom, 1),'LOC-WC-101',  'Patient Ensuite Restroom 101', 'Moderate Risk', 1, GETDATE()),
        (1, @DefaultBranch, 'Public Area', 0,                'LOC-PUB-REC',  'Main Hospital Reception & OPD Waiting Lounge', 'Low Risk', 1, GETDATE());

        PRINT 'Sample HK Locations seeded.';
    END
END
GO

-- 26. Seed Cleaning Master Protocols
IF NOT EXISTS (SELECT 1 FROM dbo.HKCleaningMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    DECLARE @TmplRoutine INT, @TmplIcu INT, @TmplOt INT;
    SELECT TOP 1 @TmplRoutine = Template_ID FROM dbo.HKChecklistTemplateMaster WHERE TemplateCode = 'CHK-ROUTINE';
    SELECT TOP 1 @TmplIcu     = Template_ID FROM dbo.HKChecklistTemplateMaster WHERE TemplateCode = 'CHK-ICU-DEEP';
    SELECT TOP 1 @TmplOt      = Template_ID FROM dbo.HKChecklistTemplateMaster WHERE TemplateCode = 'CHK-OT-TERM';

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.HKCleaningMaster
        (CompanyId, Branch_ID, CleaningType, Frequency, ChecklistTemplate_ID, ChemicalUsed, EquipmentUsed, SLA_Minutes, Status, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'Routine Floor & Surface Mopping', 'Every 4 Hours', @TmplRoutine, 'Sodium Hypochlorite 1% / Virex II 256', 'Microfiber Double-Bucket Mop Trolley', 20, 1, GETDATE()),
        (1, @DefaultBranch, 'Terminal Cleaning on Patient Discharge', 'On Patient Discharge', @TmplRoutine, 'Bacillocid Extra 1% / Hydrogen Peroxide Wipes', 'Color-Coded Microfiber Dusters & Steam Mop', 45, 1, GETDATE()),
        (1, @DefaultBranch, 'ICU Intensive Surface Sanitation', 'Every 2 Hours', @TmplIcu, 'Bacillocid Extra 0.5% / Isopropyl Alcohol 70%', 'Disposable Antimicrobial Wipes & HEPA Vacuum', 30, 1, GETDATE()),
        (1, @DefaultBranch, 'Operation Theatre Terminal Fumigation', 'Daily', @TmplOt, 'Glutaraldehyde 2% / BioShield Disinfectant', 'Ultra-Low Volume Dry Fogger Machine', 60, 1, GETDATE()),
        (1, @DefaultBranch, 'Biohazard Spill Response Protocol', 'On Incident Spill', @TmplRoutine, 'Sodium Hypochlorite 10% / Spill Solidifier', 'OSHA Standard Biohazard Spill Kit & PPE', 15, 1, GETDATE());

        PRINT 'Sample Cleaning Protocols seeded.';
    END
END
GO

-- 27. Seed Housekeeping Staff Allocations
IF NOT EXISTS (SELECT 1 FROM dbo.HKStaffMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    DECLARE @SampleUser INT;
    SELECT TOP 1 @SampleUser = Id FROM dbo.Users ORDER BY Id;

    DECLARE @SampleShift INT;
    SELECT TOP 1 @SampleShift = ShiftMaster_ID FROM dbo.ShiftMaster ORDER BY ShiftMaster_ID;

    DECLARE @SampleLocation INT;
    SELECT TOP 1 @SampleLocation = Location_ID FROM dbo.HKLocationMaster ORDER BY Location_ID;

    IF @DefaultBranch IS NOT NULL AND @SampleUser IS NOT NULL AND @SampleShift IS NOT NULL AND @SampleLocation IS NOT NULL
    BEGIN
        INSERT INTO dbo.HKStaffMaster
        (CompanyId, Branch_ID, Staff_ID, ShiftMaster_ID, Supervisor_ID, AreaAllocation_ID, Status, CreatedDate)
        VALUES
        (1, @DefaultBranch, @SampleUser, @SampleShift, @SampleUser, @SampleLocation, 1, GETDATE());

        PRINT 'Sample HK Staff Allocation seeded.';
    END
END
GO
