-- =================================================================================
-- Script Name: 102_lab_investigation_profile_master.sql
-- Description: Creates Header & Detail tables, UDT, and Stored Procedures for
--              Lab Investigation Profile / Package Master (Header-Detail CRUD).
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileDetail]') AND type in (N'U'))
    DROP TABLE [dbo].[LabInvestigationProfileDetail];
GO

IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileHeader]') AND type in (N'U'))
    DROP TABLE [dbo].[LabInvestigationProfileHeader];
GO

-- 1. Create Header Table: dbo.LabInvestigationProfileHeader
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileHeader]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[LabInvestigationProfileHeader]
    (
        [Profile_ID]               INT IDENTITY(1,1) NOT NULL,
        [CompanyId]                INT NOT NULL DEFAULT(1),
        [BranchId]                 INT NOT NULL DEFAULT(1),
        [Profile_Code]             VARCHAR(50) NOT NULL,
        [Profile_Name]             NVARCHAR(200) NOT NULL,
        [Profile_Type]             VARCHAR(50) NOT NULL DEFAULT('Profile'), -- 'Profile' (fixed group) / 'Package' (health checkup bundle)
        [MRP]                      DECIMAL(18,2) NOT NULL DEFAULT(0.00),
        [Discount_Pct]             DECIMAL(5,2) NOT NULL DEFAULT(0.00),
        [Age_Operator]             VARCHAR(20) NULL, -- 'Exact', 'GreaterEqual', 'LessEqual', 'Between'
        [Applicable_Age]           INT NULL,
        [Applicable_Gender]        VARCHAR(20) NOT NULL DEFAULT('All'), -- 'All', 'Male', 'Female', 'Other'
        [Profile_TAT_Hours]        INT NOT NULL DEFAULT(24),
        [Profile_NABL_Accredited]  BIT NOT NULL DEFAULT(0),
        [Report_Print_Sequence]    INT NOT NULL DEFAULT(1),
        [Status]                   BIT NOT NULL DEFAULT(1),
        [IsDeleted]                BIT NOT NULL DEFAULT(0),
        [CreatedBy]                INT NULL,
        [CreatedDate]              DATETIME NOT NULL DEFAULT(GETDATE()),
        [ModifiedBy]               INT NULL,
        [ModifiedDate]             DATETIME NULL,
        CONSTRAINT [PK_LabInvestigationProfileHeader] PRIMARY KEY CLUSTERED ([Profile_ID] ASC)
    );

    CREATE UNIQUE NONCLUSTERED INDEX [UX_LabInvestigationProfileHeader_ProfileCode] 
        ON [dbo].[LabInvestigationProfileHeader]([BranchId], [Profile_Code]) 
        WHERE [IsDeleted] = 0;

    CREATE UNIQUE NONCLUSTERED INDEX [UX_LabInvestigationProfileHeader_ProfileName] 
        ON [dbo].[LabInvestigationProfileHeader]([BranchId], [Profile_Name]) 
        WHERE [IsDeleted] = 0;

    PRINT 'Table dbo.LabInvestigationProfileHeader created successfully.';
END
GO

-- 2. Create Detail Table: dbo.LabInvestigationProfileDetail
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileDetail]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[LabInvestigationProfileDetail]
    (
        [Detail_ID]     INT IDENTITY(1,1) NOT NULL,
        [Profile_ID]    INT NOT NULL,
        [Test_ID]       INT NOT NULL,
        [Sequence]      INT NOT NULL DEFAULT(1),
        [IsDeleted]     BIT NOT NULL DEFAULT(0),
        [CreatedBy]     INT NULL,
        [CreatedDate]   DATETIME NOT NULL DEFAULT(GETDATE()),
        [ModifiedBy]    INT NULL,
        [ModifiedDate]  DATETIME NULL,
        CONSTRAINT [PK_LabInvestigationProfileDetail] PRIMARY KEY CLUSTERED ([Detail_ID] ASC),
        CONSTRAINT [FK_LabInvestigationProfileDetail_Header] FOREIGN KEY ([Profile_ID]) REFERENCES [dbo].[LabInvestigationProfileHeader] ([Profile_ID]),
        CONSTRAINT [FK_LabInvestigationProfileDetail_Test] FOREIGN KEY ([Test_ID]) REFERENCES [dbo].[LabInvestigationMaster] ([Test_ID])
    );

    CREATE NONCLUSTERED INDEX [IX_LabInvestigationProfileDetail_ProfileID] 
        ON [dbo].[LabInvestigationProfileDetail]([Profile_ID]) 
        WHERE [IsDeleted] = 0;

    PRINT 'Table dbo.LabInvestigationProfileDetail created successfully.';
END
GO

-- 3. Drop existing stored procedures referencing UDT before UDT recreation
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Save];
GO

-- 4. Create User-Defined Table Type (UDT) for saving Details in 1 Go
IF EXISTS (SELECT * FROM sys.types WHERE is_user_defined = 1 AND name = N'udt_LabInvestigationProfileDetail')
BEGIN
    DROP TYPE [dbo].[udt_LabInvestigationProfileDetail];
END
GO

CREATE TYPE [dbo].[udt_LabInvestigationProfileDetail] AS TABLE
(
    [Detail_ID] INT NULL,
    [Test_ID]   INT NOT NULL,
    [Sequence]  INT NOT NULL DEFAULT(1)
);
GO
PRINT 'User-Defined Table Type dbo.udt_LabInvestigationProfileDetail created successfully.';
GO

-- 4. Stored Procedure: dbo.usp_Api_LabInvestigationProfile_GetList
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_GetList]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetList];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetList]
    @BranchId     INT = NULL,
    @ProfileType  VARCHAR(50) = NULL,
    @Status       BIT = NULL,
    @SearchTerm   NVARCHAR(200) = NULL,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        h.[Profile_ID],
        h.[CompanyId],
        h.[BranchId],
        h.[Profile_Code],
        h.[Profile_Name],
        h.[Profile_Type],
        h.[MRP],
        h.[Discount_Pct],
        h.[Age_Operator],
        h.[Applicable_Age],
        h.[Applicable_Gender],
        h.[Profile_TAT_Hours],
        h.[Profile_NABL_Accredited],
        h.[Report_Print_Sequence],
        h.[Status],
        h.[CreatedBy],
        h.[CreatedDate],
        h.[ModifiedBy],
        h.[ModifiedDate],
        (SELECT COUNT(1) FROM [dbo].[LabInvestigationProfileDetail] d WHERE d.[Profile_ID] = h.[Profile_ID] AND d.[IsDeleted] = 0) AS [TestCount]
    FROM [dbo].[LabInvestigationProfileHeader] h
    WHERE h.[IsDeleted] = 0
      AND (@BranchId IS NULL OR h.[BranchId] = @BranchId)
      AND (@CompanyId IS NULL OR h.[CompanyId] = @CompanyId)
      AND (@ProfileType IS NULL OR h.[Profile_Type] = @ProfileType)
      AND (@Status IS NULL OR h.[Status] = @Status)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.[Profile_Name] LIKE '%' + @SearchTerm + '%' OR h.[Profile_Code] LIKE '%' + @SearchTerm + '%')
    ORDER BY h.[Report_Print_Sequence] ASC, h.[Profile_Name] ASC;
END
GO

-- 5. Stored Procedure: dbo.usp_Api_LabInvestigationProfile_GetById
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_GetById]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetById];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetById]
    @Profile_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resultset 1: Header
    SELECT 
        h.[Profile_ID],
        h.[CompanyId],
        h.[BranchId],
        h.[Profile_Code],
        h.[Profile_Name],
        h.[Profile_Type],
        h.[MRP],
        h.[Discount_Pct],
        h.[Age_Operator],
        h.[Applicable_Age],
        h.[Applicable_Gender],
        h.[Profile_TAT_Hours],
        h.[Profile_NABL_Accredited],
        h.[Report_Print_Sequence],
        h.[Status],
        h.[CreatedBy],
        h.[CreatedDate],
        h.[ModifiedBy],
        h.[ModifiedDate]
    FROM [dbo].[LabInvestigationProfileHeader] h
    WHERE h.[Profile_ID] = @Profile_ID AND h.[IsDeleted] = 0;

    -- Resultset 2: Details
    SELECT 
        d.[Detail_ID],
        d.[Profile_ID],
        d.[Test_ID],
        t.[Test_Code],
        t.[Test_Name],
        d.[Sequence],
        t.[MRP] AS [TestMRP],
        t.[Reporting_Type],
        dept.[DeptName] AS [DepartmentName],
        cat.[Category_Name] AS [CategoryName]
    FROM [dbo].[LabInvestigationProfileDetail] d
    INNER JOIN [dbo].[LabInvestigationMaster] t ON d.[Test_ID] = t.[Test_ID]
    LEFT JOIN [dbo].[DepartmentMaster] dept ON t.[Department_ID] = dept.[DeptId]
    LEFT JOIN [dbo].[LabTestCategoryMaster] cat ON t.[Category_ID] = cat.[Category_ID]
    WHERE d.[Profile_ID] = @Profile_ID AND d.[IsDeleted] = 0
    ORDER BY d.[Sequence] ASC, t.[Test_Name] ASC;
END
GO

-- 6. Stored Procedure: dbo.usp_Api_LabInvestigationProfile_Save (Header + Detail UDT Save in One Go)
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Save];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Save]
    @Profile_ID              INT = NULL OUTPUT,
    @CompanyId               INT = 1,
    @BranchId                INT = 1,
    @Profile_Name            NVARCHAR(200),
    @Profile_Type            VARCHAR(50) = 'Profile',
    @MRP                     DECIMAL(18,2) = 0.00,
    @Discount_Pct            DECIMAL(5,2) = 0.00,
    @Age_Operator            VARCHAR(10) = NULL,
    @Applicable_Age          INT = NULL,
    @Applicable_Gender       VARCHAR(20) = 'All',
    @Profile_TAT_Hours       INT = 24,
    @Profile_NABL_Accredited BIT = 0,
    @Report_Print_Sequence   INT = 1,
    @Status                  BIT = 1,
    @UserId                  INT = NULL,
    @Details                 [dbo].[udt_LabInvestigationProfileDetail] READONLY
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        -- Check Duplicate Profile Name
        IF EXISTS (
            SELECT 1 FROM [dbo].[LabInvestigationProfileHeader] 
            WHERE [BranchId] = @BranchId 
              AND [Profile_Name] = @Profile_Name 
              AND (@Profile_ID IS NULL OR [Profile_ID] <> @Profile_ID)
              AND [IsDeleted] = 0
        )
        BEGIN
            RAISERROR('Investigation Profile Name already exists. Duplicate profile names are not allowed.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @Profile_ID IS NULL OR @Profile_ID = 0
        BEGIN
            -- Generate Auto Profile Code (e.g. PRF0001)
            DECLARE @NextNo INT;
            DECLARE @Profile_Code VARCHAR(50);

            SELECT @NextNo = ISNULL(MAX(CAST(RIGHT([Profile_Code], 4) AS INT)), 0) + 1 
            FROM [dbo].[LabInvestigationProfileHeader] WITH (UPDLOCK, HOLDLOCK)
            WHERE [Profile_Code] LIKE 'PRF%';

            SET @Profile_Code = 'PRF' + RIGHT('0000' + CAST(@NextNo AS VARCHAR(4)), 4);

            INSERT INTO [dbo].[LabInvestigationProfileHeader]
            (
                [CompanyId], [BranchId], [Profile_Code], [Profile_Name], [Profile_Type],
                [MRP], [Discount_Pct], [Age_Operator], [Applicable_Age], [Applicable_Gender],
                [Profile_TAT_Hours], [Profile_NABL_Accredited], [Report_Print_Sequence],
                [Status], [IsDeleted], [CreatedBy], [CreatedDate]
            )
            VALUES
            (
                @CompanyId, @BranchId, @Profile_Code, @Profile_Name, @Profile_Type,
                @MRP, @Discount_Pct, @Age_Operator, @Applicable_Age, @Applicable_Gender,
                @Profile_TAT_Hours, @Profile_NABL_Accredited, @Report_Print_Sequence,
                @Status, 0, @UserId, GETDATE()
            );

            SET @Profile_ID = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            -- Update Header
            UPDATE [dbo].[LabInvestigationProfileHeader]
            SET [Profile_Name]           = @Profile_Name,
                [Profile_Type]           = @Profile_Type,
                [MRP]                    = @MRP,
                [Discount_Pct]           = @Discount_Pct,
                [Age_Operator]           = @Age_Operator,
                [Applicable_Age]         = @Applicable_Age,
                [Applicable_Gender]      = @Applicable_Gender,
                [Profile_TAT_Hours]      = @Profile_TAT_Hours,
                [Profile_NABL_Accredited]= @Profile_NABL_Accredited,
                [Report_Print_Sequence]  = @Report_Print_Sequence,
                [Status]                 = @Status,
                [ModifiedBy]             = @UserId,
                [ModifiedDate]           = GETDATE()
            WHERE [Profile_ID] = @Profile_ID AND [IsDeleted] = 0;
        END

        -- Synchronize Details using UDT (Delete non-matching, Update existing, Insert new)
        -- Mark details deleted that are not present in UDT
        UPDATE [dbo].[LabInvestigationProfileDetail]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [Profile_ID] = @Profile_ID
          AND [IsDeleted] = 0
          AND [Test_ID] NOT IN (SELECT [Test_ID] FROM @Details);

        -- Merge / Insert Details
        MERGE INTO [dbo].[LabInvestigationProfileDetail] AS Target
        USING @Details AS Source
        ON (Target.[Profile_ID] = @Profile_ID AND Target.[Test_ID] = Source.[Test_ID] AND Target.[IsDeleted] = 0)
        WHEN MATCHED THEN
            UPDATE SET 
                Target.[Sequence] = Source.[Sequence],
                Target.[ModifiedBy] = @UserId,
                Target.[ModifiedDate] = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedBy], [CreatedDate])
            VALUES (@Profile_ID, Source.[Test_ID], Source.[Sequence], 0, @UserId, GETDATE());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH
END
GO

-- 7. Stored Procedure: dbo.usp_Api_LabInvestigationProfile_ToggleStatus
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_ToggleStatus]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_ToggleStatus];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_ToggleStatus]
    @Profile_ID INT,
    @Status     BIT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE [dbo].[LabInvestigationProfileHeader]
    SET [Status] = @Status,
        [ModifiedBy] = @UserId,
        [ModifiedDate] = GETDATE()
    WHERE [Profile_ID] = @Profile_ID AND [IsDeleted] = 0;
END
GO

-- 8. Stored Procedure: dbo.usp_Api_LabInvestigationProfile_Delete
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_Delete]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Delete];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Delete]
    @Profile_ID INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        UPDATE [dbo].[LabInvestigationProfileHeader]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [Profile_ID] = @Profile_ID;

        UPDATE [dbo].[LabInvestigationProfileDetail]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [Profile_ID] = @Profile_ID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH
END
GO

PRINT 'Investigation Profile SQL objects created successfully.';
