-- =================================================================================
-- Script Name: 2015_lab_rate_card_detail_discount_allowed.sql
-- Description: Adds Is_Discount_Allowed to dbo.LabRateCardDetail, updates UDT and
--              stored procedures for Rate Card Master.
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;

PRINT 'Adding Is_Discount_Allowed to dbo.LabRateCardDetail...';

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'[dbo].[LabRateCardDetail]') AND name = N'Is_Discount_Allowed')
BEGIN
    ALTER TABLE [dbo].[LabRateCardDetail] ADD [Is_Discount_Allowed] BIT NOT NULL DEFAULT(0);
    PRINT 'Added Is_Discount_Allowed column to dbo.LabRateCardDetail';
END
GO

-- Drop SP before type drop
IF OBJECT_ID(N'[dbo].[usp_Api_LabRateCardMaster_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Save];
GO

-- Recreate UDT
IF EXISTS (SELECT * FROM sys.types WHERE is_user_defined = 1 AND name = N'udt_LabRateCardDetail')
BEGIN
    DROP TYPE [dbo].[udt_LabRateCardDetail];
END
GO

CREATE TYPE [dbo].[udt_LabRateCardDetail] AS TABLE
(
    [Detail_ID]           INT NULL,
    [Item_Type]           VARCHAR(20) NOT NULL,
    [Item_ID]             INT NOT NULL,
    [Rate]                DECIMAL(18,2) NOT NULL,
    [Is_Discount_Allowed] BIT NOT NULL DEFAULT(0),
    [Status]              BIT NOT NULL DEFAULT(1)
);
GO
PRINT 'Recreated UDT dbo.udt_LabRateCardDetail with Is_Discount_Allowed.';
GO

-- 1. Update GetById SP
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_LabRateCardMaster_GetById]
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

    -- Resultset 2: Details
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
        ISNULL(d.[Is_Discount_Allowed], 0) AS [Is_Discount_Allowed],
        d.[Status]
    FROM [dbo].[LabRateCardDetail] d
    INNER JOIN [dbo].[LabInvestigationMaster] t ON d.[Item_ID] = t.[Test_ID]
    WHERE d.[RateCard_ID] = @RateCard_ID AND d.[IsDeleted] = 0
    ORDER BY t.[Is_Profile_Test] DESC, t.[Test_Name] ASC;
END
GO

-- 2. Update Save SP
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_LabRateCardMaster_Save]
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

        -- Synchronize Details
        UPDATE [dbo].[LabRateCardDetail]
        SET [IsDeleted] = 1,
            [ModifiedBy] = @UserId,
            [ModifiedDate] = GETDATE()
        WHERE [RateCard_ID] = @RateCard_ID
          AND [IsDeleted] = 0
          AND NOT EXISTS (
              SELECT 1 FROM @Details s WHERE s.[Item_Type] = [dbo].[LabRateCardDetail].[Item_Type] AND s.[Item_ID] = [dbo].[LabRateCardDetail].[Item_ID]
          );

        -- Merge Details
        MERGE INTO [dbo].[LabRateCardDetail] AS Target
        USING @Details AS Source
        ON (Target.[RateCard_ID] = @RateCard_ID AND Target.[Item_Type] = Source.[Item_Type] AND Target.[Item_ID] = Source.[Item_ID] AND Target.[IsDeleted] = 0)
        WHEN MATCHED THEN
            UPDATE SET 
                Target.[Rate] = Source.[Rate],
                Target.[Is_Discount_Allowed] = ISNULL(Source.[Is_Discount_Allowed], 0),
                Target.[Status] = Source.[Status],
                Target.[ModifiedBy] = @UserId,
                Target.[ModifiedDate] = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT ([RateCard_ID], [Item_Type], [Item_ID], [Rate], [Is_Discount_Allowed], [Status], [IsDeleted], [CreatedBy], [CreatedDate])
            VALUES (@RateCard_ID, Source.[Item_Type], Source.[Item_ID], Source.[Rate], ISNULL(Source.[Is_Discount_Allowed], 0), Source.[Status], 0, @UserId, GETDATE());

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

PRINT 'Rate Card Detail Is_Discount_Allowed migration completed successfully.';
GO
