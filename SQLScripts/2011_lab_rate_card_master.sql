-- =================================================================================
-- Script Name: 2011_lab_rate_card_master.sql
-- Description: Creates Header & Detail tables, UDT, and Stored Procedures for
--              Lab Rate Card Master (B2C, Corporate, Franchise, Doctor, Camp).
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

-- 1. Create Header Table: dbo.LabRateCardMaster
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabRateCardMaster]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[LabRateCardMaster]
    (
        [RateCard_ID]    INT IDENTITY(1,1) NOT NULL,
        [CompanyId]      INT NOT NULL DEFAULT(1),
        [Branch_ID]      INT NOT NULL,
        [Rate_Type]      VARCHAR(50) NOT NULL, -- 'B2C', 'Corporate', 'Franchise', 'Doctor', 'Camp'
        [Effective_From] DATE NOT NULL,
        [Effective_To]   DATE NOT NULL,
        [Status]         BIT NOT NULL DEFAULT(1),
        [IsDeleted]      BIT NOT NULL DEFAULT(0),
        [CreatedBy]      INT NULL,
        [CreatedDate]    DATETIME2 NOT NULL DEFAULT(GETDATE()),
        [ModifiedBy]     INT NULL,
        [ModifiedDate]   DATETIME2 NULL,
        CONSTRAINT [PK_LabRateCardMaster] PRIMARY KEY CLUSTERED ([RateCard_ID] ASC),
        CONSTRAINT [FK_LabRateCardMaster_Branch] FOREIGN KEY ([Branch_ID]) REFERENCES [dbo].[BranchMaster] ([BranchId])
    );

    CREATE NONCLUSTERED INDEX [IX_LabRateCardMaster_Branch] ON [dbo].[LabRateCardMaster]([Branch_ID]) WHERE [IsDeleted] = 0;
    CREATE NONCLUSTERED INDEX [IX_LabRateCardMaster_Type] ON [dbo].[LabRateCardMaster]([Rate_Type]) WHERE [IsDeleted] = 0;

    PRINT 'Table dbo.LabRateCardMaster created successfully.';
END
GO

-- 2. Create Detail Table: dbo.LabRateCardDetail
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LabRateCardDetail]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[LabRateCardDetail]
    (
        [Detail_ID]    INT IDENTITY(1,1) NOT NULL,
        [RateCard_ID]  INT NOT NULL,
        [Item_Type]    VARCHAR(20) NOT NULL, -- 'Test' or 'Profile'
        [Item_ID]      INT NOT NULL,
        [Rate]         DECIMAL(18,2) NOT NULL DEFAULT(0.00),
        [Status]       BIT NOT NULL DEFAULT(1),
        [IsDeleted]    BIT NOT NULL DEFAULT(0),
        [CreatedBy]    INT NULL,
        [CreatedDate]  DATETIME2 NOT NULL DEFAULT(GETDATE()),
        [ModifiedBy]   INT NULL,
        [ModifiedDate] DATETIME2 NULL,
        CONSTRAINT [PK_LabRateCardDetail] PRIMARY KEY CLUSTERED ([Detail_ID] ASC),
        CONSTRAINT [FK_LabRateCardDetail_Header] FOREIGN KEY ([RateCard_ID]) REFERENCES [dbo].[LabRateCardMaster] ([RateCard_ID])
    );

    CREATE NONCLUSTERED INDEX [IX_LabRateCardDetail_RateCard] ON [dbo].[LabRateCardDetail]([RateCard_ID]) WHERE [IsDeleted] = 0;

    PRINT 'Table dbo.LabRateCardDetail created successfully.';
END
GO

-- 3. Drop existing stored procedures referencing UDT before UDT recreation
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Save];
GO

-- 4. Create User-Defined Table Type (UDT) for saving Details
IF EXISTS (SELECT * FROM sys.types WHERE is_user_defined = 1 AND name = N'udt_LabRateCardDetail')
BEGIN
    DROP TYPE [dbo].[udt_LabRateCardDetail];
END
GO

CREATE TYPE [dbo].[udt_LabRateCardDetail] AS TABLE
(
    [Detail_ID] INT NULL,
    [Item_Type] VARCHAR(20) NOT NULL,
    [Item_ID]   INT NOT NULL,
    [Rate]      DECIMAL(18,2) NOT NULL,
    [Status]    BIT NOT NULL DEFAULT(1)
);
GO
PRINT 'User-Defined Table Type dbo.udt_LabRateCardDetail created successfully.';
GO

-- 5. Stored Procedure: dbo.usp_Api_LabRateCardMaster_GetList
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_GetList]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_GetList];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabRateCardMaster_GetList]
    @RateType     VARCHAR(50) = NULL,
    @BranchId     INT = NULL,
    @Status       BIT = NULL,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        h.[RateCard_ID],
        h.[CompanyId],
        h.[Branch_ID],
        b.[BranchName] AS [Branch_Name],
        h.[Rate_Type],
        h.[Effective_From],
        h.[Effective_To],
        h.[Status],
        h.[CreatedBy],
        h.[CreatedDate],
        h.[ModifiedBy],
        h.[ModifiedDate],
        (SELECT COUNT(1) FROM [dbo].[LabRateCardDetail] d WHERE d.[RateCard_ID] = h.[RateCard_ID] AND d.[IsDeleted] = 0) AS [ItemCount]
    FROM [dbo].[LabRateCardMaster] h
    LEFT JOIN [dbo].[BranchMaster] b ON h.[Branch_ID] = b.[BranchId]
    WHERE h.[IsDeleted] = 0
      AND (@CompanyId IS NULL OR h.[CompanyId] = @CompanyId)
      AND (@RateType IS NULL OR h.[Rate_Type] = @RateType)
      AND (@BranchId IS NULL OR h.[Branch_ID] = @BranchId)
      AND (@Status IS NULL OR h.[Status] = @Status)
    ORDER BY b.[BranchName] ASC, h.[Effective_From] DESC;
END
GO

-- 6. Stored Procedure: dbo.usp_Api_LabRateCardMaster_GetById
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_GetById]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_GetById];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabRateCardMaster_GetById]
    @RateCard_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resultset 1: Header
    SELECT 
        h.[RateCard_ID],
        h.[CompanyId],
        h.[Branch_ID],
        b.[BranchName] AS [Branch_Name],
        h.[Rate_Type],
        h.[Effective_From],
        h.[Effective_To],
        h.[Status],
        h.[CreatedBy],
        h.[CreatedDate],
        h.[ModifiedBy],
        h.[ModifiedDate]
    FROM [dbo].[LabRateCardMaster] h
    LEFT JOIN [dbo].[BranchMaster] b ON h.[Branch_ID] = b.[BranchId]
    WHERE h.[RateCard_ID] = @RateCard_ID AND h.[IsDeleted] = 0;

    -- Resultset 2: Details with Item Names resolved from LabInvestigationMaster
    SELECT 
        d.[Detail_ID],
        d.[RateCard_ID],
        d.[Item_Type],
        d.[Item_ID],
        t.[Test_Name] AS [Item_Name],
        t.[Test_Code] AS [Item_Code],
        t.[MRP] AS [Default_Rate],
        t.[Category_ID],
        t.[SubCategory_ID],
        t.[Department_ID],
        t.[Is_Profile_Test],
        d.[Rate],
        d.[Status]
    FROM [dbo].[LabRateCardDetail] d
    INNER JOIN [dbo].[LabInvestigationMaster] t ON d.[Item_ID] = t.[Test_ID]
    WHERE d.[RateCard_ID] = @RateCard_ID AND d.[IsDeleted] = 0
    ORDER BY t.[Is_Profile_Test] DESC, t.[Test_Name] ASC;
END
GO

-- 7. Stored Procedure: dbo.usp_Api_LabRateCardMaster_Save (Header + Detail UDT Save in One Go)
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Save];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Save]
    @RateCard_ID     INT = NULL OUTPUT,
    @CompanyId       INT = 1,
    @Branch_ID       INT,
    @Rate_Type       VARCHAR(50),
    @Effective_From  DATE,
    @Effective_To    DATE,
    @Status          BIT = 1,
    @UserId          INT = NULL,
    @Details         [dbo].[udt_LabRateCardDetail] READONLY
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        IF @RateCard_ID IS NULL OR @RateCard_ID = 0
        BEGIN
            INSERT INTO [dbo].[LabRateCardMaster]
            (
                [CompanyId], [Branch_ID], [Rate_Type], [Effective_From], [Effective_To],
                [Status], [IsDeleted], [CreatedBy], [CreatedDate]
            )
            VALUES
            (
                @CompanyId, @Branch_ID, @Rate_Type, @Effective_From, @Effective_To,
                @Status, 0, @UserId, GETDATE()
            );

            SET @RateCard_ID = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            -- Update Header
            UPDATE [dbo].[LabRateCardMaster]
            SET [Branch_ID]      = @Branch_ID,
                [Rate_Type]      = @Rate_Type,
                [Effective_From] = @Effective_From,
                [Effective_To]   = @Effective_To,
                [Status]         = @Status,
                [ModifiedBy]     = @UserId,
                [ModifiedDate]   = GETDATE()
            WHERE [RateCard_ID] = @RateCard_ID AND [IsDeleted] = 0;
        END

        -- Synchronize Details using UDT (Delete non-matching, Update existing, Insert new)
        UPDATE [dbo].[LabRateCardDetail]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [RateCard_ID] = @RateCard_ID
          AND [IsDeleted] = 0
          AND NOT EXISTS (
              SELECT 1 FROM @Details s WHERE s.[Item_Type] = [dbo].[LabRateCardDetail].[Item_Type] AND s.[Item_ID] = [dbo].[LabRateCardDetail].[Item_ID]
          );

        -- Merge / Insert Details
        MERGE INTO [dbo].[LabRateCardDetail] AS Target
        USING @Details AS Source
        ON (Target.[RateCard_ID] = @RateCard_ID AND Target.[Item_Type] = Source.[Item_Type] AND Target.[Item_ID] = Source.[Item_ID] AND Target.[IsDeleted] = 0)
        WHEN MATCHED THEN
            UPDATE SET 
                Target.[Rate] = Source.[Rate],
                Target.[Status] = Source.[Status],
                Target.[ModifiedBy] = @UserId,
                Target.[ModifiedDate] = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT ([RateCard_ID], [Item_Type], [Item_ID], [Rate], [Status], [IsDeleted], [CreatedBy], [CreatedDate])
            VALUES (@RateCard_ID, Source.[Item_Type], Source.[Item_ID], Source.[Rate], Source.[Status], 0, @UserId, GETDATE());

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

-- 8. Stored Procedure: dbo.usp_Api_LabRateCardMaster_ToggleStatus
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_ToggleStatus]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_ToggleStatus];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabRateCardMaster_ToggleStatus]
    @RateCard_ID INT,
    @Status      BIT,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE [dbo].[LabRateCardMaster]
    SET [Status] = @Status,
        [ModifiedBy] = @UserId,
        [ModifiedDate] = GETDATE()
    WHERE [RateCard_ID] = @RateCard_ID AND [IsDeleted] = 0;
END
GO

-- 9. Stored Procedure: dbo.usp_Api_LabRateCardMaster_Delete
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_Delete]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Delete];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Delete]
    @RateCard_ID INT,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        UPDATE [dbo].[LabRateCardMaster]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [RateCard_ID] = @RateCard_ID;

        UPDATE [dbo].[LabRateCardDetail]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [RateCard_ID] = @RateCard_ID;

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

-- 10. Stored Procedure: dbo.usp_Api_LabItems_GetAll (For Rate Card Dropdowns & Copy Logic)
IF OBJECT_ID(N'[dbo].[usp_Api_LabItems_GetAll]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabItems_GetAll];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabItems_GetAll]
    @CompanyId INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        CASE WHEN m.[Is_Profile_Test] = 1 THEN 'Profile' ELSE 'Test' END AS [Item_Type],
        m.[Test_ID] AS [Item_ID],
        m.[Test_Code] AS [Item_Code],
        m.[Test_Name] AS [Item_Name],
        ISNULL(m.[Department_ID], c.[Department_ID]) AS [Department_ID],
        m.[Category_ID],
        m.[SubCategory_ID],
        m.[MRP] AS [Default_Rate],
        m.[Is_Profile_Test]
    FROM [dbo].[LabInvestigationMaster] m
    LEFT JOIN [dbo].[LabTestCategoryMaster] c ON m.[Category_ID] = c.[Category_ID]
    WHERE m.[IsDeleted] = 0 AND m.[Status] = 1
    ORDER BY m.[Is_Profile_Test] DESC, m.[Test_Name] ASC;
END
GO

PRINT 'Rate Card SQL objects created successfully.';
