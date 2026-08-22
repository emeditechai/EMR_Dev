-- ====================================================================================================
-- Script: 90_shift_master.sql
-- Description: Creates dbo.ShiftMaster table and Stored Procedures for Shift Master
--              under Master -> General -> Shift Master.
-- ====================================================================================================

-- 1. Create dbo.ShiftMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ShiftMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.ShiftMaster
    (
        ShiftMaster_ID       INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        ShiftCode            NVARCHAR(50) NOT NULL,
        ShiftName            NVARCHAR(100) NOT NULL,
        StartTime            TIME(0) NOT NULL,
        EndTime              TIME(0) NOT NULL,
        GraceTimeMinutes     INT NOT NULL DEFAULT 15,
        BreakDurationMinutes INT NOT NULL DEFAULT 30,
        IsNightShift         BIT NOT NULL DEFAULT 0,
        Status               BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_ShiftMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_ShiftMaster_Branch_Status ON dbo.ShiftMaster(Branch_ID, Status);
    CREATE INDEX IX_ShiftMaster_Code ON dbo.ShiftMaster(ShiftCode);
    PRINT 'Created table dbo.ShiftMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.ShiftMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_ShiftMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_GetList
    @BranchId    INT = NULL,
    @Status      BIT = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        sm.ShiftMaster_ID,
        sm.CompanyId,
        sm.Branch_ID,
        b.BranchName,
        b.BranchCode,
        sm.ShiftCode,
        sm.ShiftName,
        sm.StartTime,
        sm.EndTime,
        sm.GraceTimeMinutes,
        sm.BreakDurationMinutes,
        sm.IsNightShift,
        sm.Status,
        sm.CreatedBy,
        sm.CreatedDate,
        sm.ModifiedBy,
        sm.ModifiedDate,
        (SELECT COUNT(1) FROM dbo.HKStaffMaster hks WHERE hks.ShiftMaster_ID = sm.ShiftMaster_ID AND hks.Status = 1) AS AssignedStaffCount
    FROM dbo.ShiftMaster sm
    INNER JOIN dbo.Branchmaster b ON sm.Branch_ID = b.BranchID
    WHERE (@BranchId IS NULL OR sm.Branch_ID = @BranchId)
      AND (@Status IS NULL OR sm.Status = @Status)
      AND (@CompanyId IS NULL OR sm.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           sm.ShiftCode LIKE '%' + @Search + '%' OR
           sm.ShiftName LIKE '%' + @Search + '%')
    ORDER BY sm.StartTime ASC;
END
GO

-- 3. Stored Procedure: usp_Api_ShiftMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_GetById
    @ShiftMaster_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        sm.ShiftMaster_ID,
        sm.CompanyId,
        sm.Branch_ID,
        b.BranchName,
        b.BranchCode,
        sm.ShiftCode,
        sm.ShiftName,
        sm.StartTime,
        sm.EndTime,
        sm.GraceTimeMinutes,
        sm.BreakDurationMinutes,
        sm.IsNightShift,
        sm.Status,
        sm.CreatedBy,
        sm.CreatedDate,
        sm.ModifiedBy,
        sm.ModifiedDate,
        (SELECT COUNT(1) FROM dbo.HKStaffMaster hks WHERE hks.ShiftMaster_ID = sm.ShiftMaster_ID AND hks.Status = 1) AS AssignedStaffCount
    FROM dbo.ShiftMaster sm
    INNER JOIN dbo.Branchmaster b ON sm.Branch_ID = b.BranchID
    WHERE sm.ShiftMaster_ID = @ShiftMaster_ID;
END
GO

-- 4. Stored Procedure: usp_Api_ShiftMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_Create
    @CompanyId            INT = 1,
    @Branch_ID            INT,
    @ShiftCode            NVARCHAR(50),
    @ShiftName            NVARCHAR(100),
    @StartTime            TIME(0),
    @EndTime              TIME(0),
    @GraceTimeMinutes     INT = 15,
    @BreakDurationMinutes INT = 30,
    @IsNightShift         BIT = 0,
    @Status               BIT = 1,
    @CreatedBy            INT = NULL,
    @NewShiftMaster_ID    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.ShiftMaster WHERE Branch_ID = @Branch_ID AND ShiftCode = @ShiftCode)
    BEGIN
        RAISERROR('A shift with this Shift Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    INSERT INTO dbo.ShiftMaster
    (
        CompanyId,
        Branch_ID,
        ShiftCode,
        ShiftName,
        StartTime,
        EndTime,
        GraceTimeMinutes,
        BreakDurationMinutes,
        IsNightShift,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @ShiftCode,
        @ShiftName,
        @StartTime,
        @EndTime,
        @GraceTimeMinutes,
        @BreakDurationMinutes,
        @IsNightShift,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewShiftMaster_ID = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_ShiftMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_Update
    @ShiftMaster_ID       INT,
    @Branch_ID            INT,
    @ShiftCode            NVARCHAR(50),
    @ShiftName            NVARCHAR(100),
    @StartTime            TIME(0),
    @EndTime              TIME(0),
    @GraceTimeMinutes     INT = 15,
    @BreakDurationMinutes INT = 30,
    @IsNightShift         BIT = 0,
    @Status               BIT = 1,
    @ModifiedBy           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.ShiftMaster WHERE Branch_ID = @Branch_ID AND ShiftCode = @ShiftCode AND ShiftMaster_ID <> @ShiftMaster_ID)
    BEGIN
        RAISERROR('Another shift with this Shift Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    UPDATE dbo.ShiftMaster
    SET
        Branch_ID            = @Branch_ID,
        ShiftCode            = @ShiftCode,
        ShiftName            = @ShiftName,
        StartTime            = @StartTime,
        EndTime              = @EndTime,
        GraceTimeMinutes     = @GraceTimeMinutes,
        BreakDurationMinutes = @BreakDurationMinutes,
        IsNightShift         = @IsNightShift,
        Status               = @Status,
        ModifiedBy           = @ModifiedBy,
        ModifiedDate         = GETDATE()
    WHERE ShiftMaster_ID     = @ShiftMaster_ID;
END
GO

-- 6. Stored Procedure: usp_Api_ShiftMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_ToggleStatus
    @ShiftMaster_ID INT,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ShiftMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE ShiftMaster_ID = @ShiftMaster_ID;

    SELECT Status FROM dbo.ShiftMaster WHERE ShiftMaster_ID = @ShiftMaster_ID;
END
GO

-- 7. Stored Procedure: usp_Api_ShiftMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_ShiftMaster_Delete
    @ShiftMaster_ID INT,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.ShiftMaster
    WHERE ShiftMaster_ID = @ShiftMaster_ID;
END
GO

-- 8. Seed Initial Operational Shifts
IF NOT EXISTS (SELECT 1 FROM dbo.ShiftMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        INSERT INTO dbo.ShiftMaster
        (CompanyId, Branch_ID, ShiftCode, ShiftName, StartTime, EndTime, GraceTimeMinutes, BreakDurationMinutes, IsNightShift, Status, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'MORN-01', 'Morning Shift (07:00 AM - 03:00 PM)', '07:00:00', '15:00:00', 15, 45, 0, 1, GETDATE()),
        (1, @DefaultBranch, 'EVE-01',  'Evening Shift (03:00 PM - 11:00 PM)', '15:00:00', '23:00:00', 15, 45, 0, 1, GETDATE()),
        (1, @DefaultBranch, 'NIGHT-01','Night Shift (11:00 PM - 07:00 AM)',   '23:00:00', '07:00:00', 15, 45, 1, 1, GETDATE()),
        (1, @DefaultBranch, 'GEN-01',  'General Day Shift (09:00 AM - 06:00 PM)', '09:00:00', '18:00:00', 15, 60, 0, 1, GETDATE()),
        (1, @DefaultBranch, 'EMERG-01','Emergency Rotational Shift', '08:00:00', '20:00:00', 15, 60, 0, 1, GETDATE());

        PRINT 'Sample Operational Shifts seeded successfully.';
    END
END
GO
