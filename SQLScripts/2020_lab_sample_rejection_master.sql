-- ====================================================================================================
-- Script: 2020_lab_sample_rejection_master.sql
-- Description: Creates dbo.LabSampleRejectionMaster table and Stored Procedures for Sample Rejection Master
--              under Lab -> Sample Rejection Master (Masters > Lab).
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE Dev_EMR;
GO

-- 1. Create dbo.LabSampleRejectionMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabSampleRejectionMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabSampleRejectionMaster
    (
        Rejection_ID       INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId          INT NOT NULL DEFAULT 1,
        Rejection_Code     NVARCHAR(50) NOT NULL,
        Rejection_Reason   NVARCHAR(255) NOT NULL,
        Description        NVARCHAR(500) NULL,
        Display_Order      INT NOT NULL DEFAULT 1,
        Status             BIT NOT NULL DEFAULT 1,
        IsDeleted          BIT NOT NULL DEFAULT 0,
        CreatedBy          INT NULL,
        CreatedDate        DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy         INT NULL,
        ModifiedDate       DATETIME2 NULL
    );
    CREATE INDEX IX_LabSampleRejectionMaster_Status ON dbo.LabSampleRejectionMaster(Status);
    CREATE INDEX IX_LabSampleRejectionMaster_Code ON dbo.LabSampleRejectionMaster(Rejection_Code);
    PRINT 'Created table dbo.LabSampleRejectionMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.LabSampleRejectionMaster already exists';
END
GO

-- Seed sample data if empty
IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE IsDeleted = 0)
BEGIN
    INSERT INTO dbo.LabSampleRejectionMaster (CompanyId, Rejection_Code, Rejection_Reason, Description, Display_Order, Status, CreatedDate)
    VALUES
    (1, 'REJ0001', 'Hemolyzed Sample', 'Sample contains hemolyzed red blood cells affecting test results.', 1, 1, GETDATE()),
    (2, 'REJ0002', 'Insufficient Sample Volume', 'Quantity of blood/fluid collected is less than required minimum volume.', 2, 1, GETDATE()),
    (3, 'REJ0003', 'Clotted Sample', 'Anticoagulated blood sample has formed clots.', 3, 1, GETDATE()),
    (4, 'REJ0004', 'Incorrect Container Used', 'Sample collected in wrong tube or container without appropriate additive.', 4, 1, GETDATE()),
    (5, 'REJ0005', 'Mislabeled or Unlabeled Specimen', 'Specimen label details do not match lab order form or patient details.', 5, 1, GETDATE());
    PRINT 'Seeded initial data into dbo.LabSampleRejectionMaster';
END
GO

-- 2. Stored Procedure: usp_Api_LabSampleRejectionMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_GetList
    @Status     BIT = NULL,
    @Search     NVARCHAR(100) = NULL,
    @CompanyId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        Rejection_ID,
        CompanyId,
        Rejection_Code,
        Rejection_Reason,
        Description,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate,
        ModifiedBy,
        ModifiedDate
    FROM dbo.LabSampleRejectionMaster
    WHERE IsDeleted = 0
      AND (@Status IS NULL OR Status = @Status)
      AND (@CompanyId IS NULL OR CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           Rejection_Reason LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           Rejection_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           Description LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY Display_Order ASC, Rejection_Reason ASC;
END
GO

-- 3. Stored Procedure: usp_Api_LabSampleRejectionMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_GetById
    @Rejection_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        Rejection_ID,
        CompanyId,
        Rejection_Code,
        Rejection_Reason,
        Description,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate,
        ModifiedBy,
        ModifiedDate
    FROM dbo.LabSampleRejectionMaster
    WHERE Rejection_ID = @Rejection_ID AND IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabSampleRejectionMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_Create
    @Rejection_Reason  NVARCHAR(255),
    @Description       NVARCHAR(500) = NULL,
    @Display_Order     INT = 1,
    @CompanyId         INT = 1,
    @UserId            INT = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Rejection_Reason IS NULL OR LTRIM(RTRIM(@Rejection_Reason)) = ''
    BEGIN
        RAISERROR('Rejection Reason is required.', 16, 1);
        RETURN;
    END

    SET @Rejection_Reason = LTRIM(RTRIM(@Rejection_Reason));
    SET @Description = LTRIM(RTRIM(@Description));

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionMaster 
        WHERE LOWER(Rejection_Reason) = LOWER(@Rejection_Reason)
          AND CompanyId = @CompanyId
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Sample Rejection Reason with the same name already exists.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    DECLARE @GeneratedCode NVARCHAR(50);

    SELECT @NextNum = ISNULL(MAX(Rejection_ID), 0) + 1 FROM dbo.LabSampleRejectionMaster;
    SET @GeneratedCode = 'REJ' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);

    WHILE EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE Rejection_Code = @GeneratedCode)
    BEGIN
        SET @NextNum = @NextNum + 1;
        SET @GeneratedCode = 'REJ' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
    END

    INSERT INTO dbo.LabSampleRejectionMaster
    (
        CompanyId,
        Rejection_Code,
        Rejection_Reason,
        Description,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @GeneratedCode,
        @Rejection_Reason,
        @Description,
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleRejectionMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_Update
    @Rejection_ID      INT,
    @Rejection_Reason  NVARCHAR(255),
    @Description       NVARCHAR(500) = NULL,
    @Display_Order     INT = 1,
    @Status            BIT = 1,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE Rejection_ID = @Rejection_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection record not found.', 16, 1);
        RETURN;
    END

    IF @Rejection_Reason IS NULL OR LTRIM(RTRIM(@Rejection_Reason)) = ''
    BEGIN
        RAISERROR('Rejection Reason is required.', 16, 1);
        RETURN;
    END

    SET @Rejection_Reason = LTRIM(RTRIM(@Rejection_Reason));
    SET @Description = LTRIM(RTRIM(@Description));

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionMaster 
        WHERE LOWER(Rejection_Reason) = LOWER(@Rejection_Reason)
          AND Rejection_ID <> @Rejection_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('A Sample Rejection Reason with the same name already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionMaster
    SET Rejection_Reason = @Rejection_Reason,
        Description      = @Description,
        Display_Order    = ISNULL(@Display_Order, 1),
        Status           = @Status,
        ModifiedBy       = @UserId,
        ModifiedDate     = GETDATE()
    WHERE Rejection_ID = @Rejection_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabSampleRejectionMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_ToggleStatus
    @Rejection_ID INT,
    @Status       BIT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE Rejection_ID = @Rejection_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Rejection_ID = @Rejection_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabSampleRejectionMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionMaster_Delete
    @Rejection_ID INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionMaster WHERE Rejection_ID = @Rejection_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Rejection_ID = @Rejection_ID;
END
GO

PRINT 'Created SQL objects for Lab Sample Rejection Master.';
