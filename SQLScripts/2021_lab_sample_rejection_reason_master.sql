-- ====================================================================================================
-- Script: 2021_lab_sample_rejection_reason_master.sql
-- Description: Creates dbo.LabSampleRejectionReasonMaster table and Stored Procedures for Sample Rejection Reason Master
--              under Lab -> Sample Rejection Reason Master (Masters > Lab).
-- Fields:
--   Reason_ID (INT IDENTITY PK)
--   Reason_Text (NVARCHAR(1000) Mandatory)
--   Applicable_Sample_Type_ID (INT NULL, FK to dbo.LabSampleTypeMaster)
--   Status (BIT NOT NULL DEFAULT 1)
--   IsDeleted (BIT NOT NULL DEFAULT 0)
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE Dev_EMR;
GO

-- 1. Create dbo.LabSampleRejectionReasonMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabSampleRejectionReasonMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabSampleRejectionReasonMaster
    (
        Reason_ID                 INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                 INT NOT NULL DEFAULT 1,
        Reason_Text               NVARCHAR(1000) NOT NULL,
        Applicable_Sample_Type_ID INT NULL,
        Display_Order             INT NOT NULL DEFAULT 1,
        Status                    BIT NOT NULL DEFAULT 1,
        IsDeleted                 BIT NOT NULL DEFAULT 0,
        CreatedBy                 INT NULL,
        CreatedDate               DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy                INT NULL,
        ModifiedDate              DATETIME2 NULL,
        CONSTRAINT FK_LabSampleRejectionReasonMaster_SampleType 
            FOREIGN KEY (Applicable_Sample_Type_ID) REFERENCES dbo.LabSampleTypeMaster(Sample_Type_ID)
    );
    CREATE INDEX IX_LabSampleRejectionReasonMaster_Status ON dbo.LabSampleRejectionReasonMaster(Status);
    CREATE INDEX IX_LabSampleRejectionReasonMaster_SampleType ON dbo.LabSampleRejectionReasonMaster(Applicable_Sample_Type_ID);
    PRINT 'Created table dbo.LabSampleRejectionReasonMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.LabSampleRejectionReasonMaster already exists';
END
GO

-- Seed sample data if empty
IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionReasonMaster WHERE IsDeleted = 0)
BEGIN
    DECLARE @SampleTypeId INT;
    SELECT TOP 1 @SampleTypeId = Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE IsDeleted = 0 AND Status = 1;

    INSERT INTO dbo.LabSampleRejectionReasonMaster (CompanyId, Reason_Text, Applicable_Sample_Type_ID, Display_Order, Status, CreatedDate)
    VALUES
    (1, 'Hemolyzed sample - gross hemolysis detected during visual inspection.', @SampleTypeId, 1, 1, GETDATE()),
    (1, 'Insufficient sample volume for complete laboratory investigation testing.', @SampleTypeId, 2, 1, GETDATE()),
    (1, 'Clotted blood sample in EDTA anticoagulant vial.', @SampleTypeId, 3, 1, GETDATE()),
    (1, 'Incorrect sample collection container used without required preservative.', NULL, 4, 1, GETDATE()),
    (1, 'Mislabeled or unlabeled specimen container.', NULL, 5, 1, GETDATE());
    PRINT 'Seeded initial data into dbo.LabSampleRejectionReasonMaster';
END
GO

-- 2. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_GetList
    @Status                 BIT = NULL,
    @Sample_Type_ID         INT = NULL,
    @Search                 NVARCHAR(100) = NULL,
    @CompanyId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        r.Reason_ID,
        r.CompanyId,
        r.Reason_Text,
        r.Applicable_Sample_Type_ID,
        st.Sample_Name AS Applicable_Sample_Type_Name,
        st.Sample_Code AS Applicable_Sample_Type_Code,
        r.Display_Order,
        r.Status,
        r.CreatedBy,
        r.CreatedDate,
        r.ModifiedBy,
        r.ModifiedDate
    FROM dbo.LabSampleRejectionReasonMaster r
    LEFT JOIN dbo.LabSampleTypeMaster st ON r.Applicable_Sample_Type_ID = st.Sample_Type_ID
    WHERE r.IsDeleted = 0
      AND (@Status IS NULL OR r.Status = @Status)
      AND (@CompanyId IS NULL OR r.CompanyId = @CompanyId)
      AND (@Sample_Type_ID IS NULL OR r.Applicable_Sample_Type_ID = @Sample_Type_ID)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           r.Reason_Text LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           st.Sample_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY r.Display_Order ASC, r.Reason_ID DESC;
END
GO

-- 3. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_GetById
    @Reason_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        r.Reason_ID,
        r.CompanyId,
        r.Reason_Text,
        r.Applicable_Sample_Type_ID,
        st.Sample_Name AS Applicable_Sample_Type_Name,
        st.Sample_Code AS Applicable_Sample_Type_Code,
        r.Display_Order,
        r.Status,
        r.CreatedBy,
        r.CreatedDate,
        r.ModifiedBy,
        r.ModifiedDate
    FROM dbo.LabSampleRejectionReasonMaster r
    LEFT JOIN dbo.LabSampleTypeMaster st ON r.Applicable_Sample_Type_ID = st.Sample_Type_ID
    WHERE r.Reason_ID = @Reason_ID AND r.IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_Create
    @Reason_Text               NVARCHAR(1000),
    @Applicable_Sample_Type_ID INT = NULL,
    @Display_Order             INT = 1,
    @CompanyId                 INT = 1,
    @UserId                    INT = NULL,
    @NewId                     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Reason_Text IS NULL OR LTRIM(RTRIM(@Reason_Text)) = ''
    BEGIN
        RAISERROR('Reason Text is required.', 16, 1);
        RETURN;
    END

    SET @Reason_Text = LTRIM(RTRIM(@Reason_Text));

    IF LEN(@Reason_Text) > 1000
    BEGIN
        RAISERROR('Reason Text cannot exceed 1000 characters.', 16, 1);
        RETURN;
    END

    IF @Applicable_Sample_Type_ID IS NOT NULL AND @Applicable_Sample_Type_ID > 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Applicable_Sample_Type_ID AND IsDeleted = 0 AND Status = 1)
        BEGIN
            RAISERROR('Selected Sample Type is inactive or invalid.', 16, 1);
            RETURN;
        END
    END
    ELSE
    BEGIN
        SET @Applicable_Sample_Type_ID = NULL;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionReasonMaster 
        WHERE LOWER(Reason_Text) = LOWER(@Reason_Text)
          AND ISNULL(Applicable_Sample_Type_ID, 0) = ISNULL(@Applicable_Sample_Type_ID, 0)
          AND CompanyId = @CompanyId
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('An identical Sample Rejection Reason already exists.', 16, 1);
        RETURN;
    END

    INSERT INTO dbo.LabSampleRejectionReasonMaster
    (
        CompanyId,
        Reason_Text,
        Applicable_Sample_Type_ID,
        Display_Order,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Reason_Text,
        @Applicable_Sample_Type_ID,
        ISNULL(@Display_Order, 1),
        1,
        @UserId,
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_Update
    @Reason_ID                 INT,
    @Reason_Text               NVARCHAR(1000),
    @Applicable_Sample_Type_ID INT = NULL,
    @Display_Order             INT = 1,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @Reason_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection Reason record not found.', 16, 1);
        RETURN;
    END

    IF @Reason_Text IS NULL OR LTRIM(RTRIM(@Reason_Text)) = ''
    BEGIN
        RAISERROR('Reason Text is required.', 16, 1);
        RETURN;
    END

    SET @Reason_Text = LTRIM(RTRIM(@Reason_Text));

    IF LEN(@Reason_Text) > 1000
    BEGIN
        RAISERROR('Reason Text cannot exceed 1000 characters.', 16, 1);
        RETURN;
    END

    IF @Applicable_Sample_Type_ID IS NOT NULL AND @Applicable_Sample_Type_ID > 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Applicable_Sample_Type_ID AND IsDeleted = 0 AND Status = 1)
        BEGIN
            RAISERROR('Selected Sample Type is inactive or invalid.', 16, 1);
            RETURN;
        END
    END
    ELSE
    BEGIN
        SET @Applicable_Sample_Type_ID = NULL;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.LabSampleRejectionReasonMaster 
        WHERE LOWER(Reason_Text) = LOWER(@Reason_Text)
          AND ISNULL(Applicable_Sample_Type_ID, 0) = ISNULL(@Applicable_Sample_Type_ID, 0)
          AND Reason_ID <> @Reason_ID
          AND IsDeleted = 0
    )
    BEGIN
        RAISERROR('An identical Sample Rejection Reason already exists.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionReasonMaster
    SET Reason_Text               = @Reason_Text,
        Applicable_Sample_Type_ID = @Applicable_Sample_Type_ID,
        Display_Order             = ISNULL(@Display_Order, 1),
        Status                    = @Status,
        ModifiedBy                = @UserId,
        ModifiedDate              = GETDATE()
    WHERE Reason_ID = @Reason_ID;
END
GO

-- 6. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_ToggleStatus
    @Reason_ID INT,
    @Status     BIT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @Reason_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection Reason record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionReasonMaster
    SET Status       = @Status,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Reason_ID = @Reason_ID;
END
GO

-- 7. Stored Procedure: usp_Api_LabSampleRejectionReasonMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSampleRejectionReasonMaster_Delete
    @Reason_ID INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @Reason_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Sample Rejection Reason record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabSampleRejectionReasonMaster
    SET IsDeleted = 1,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE Reason_ID = @Reason_ID;
END
GO

PRINT 'Created SQL objects for Lab Sample Rejection Reason Master.';
