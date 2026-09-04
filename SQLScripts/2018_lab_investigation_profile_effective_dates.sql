-- =================================================================================
-- Script Name: 2018_lab_investigation_profile_effective_dates.sql
-- Description: Adds Effective_Start_Date and Effective_End_Date to LabInvestigationProfileHeader
--              and updates stored procedures usp_Api_LabInvestigationProfile_GetList, 
--              usp_Api_LabInvestigationProfile_GetById, and usp_Api_LabInvestigationProfile_Save.
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

-- 1. Add Columns Effective_Start_Date and Effective_End_Date to dbo.LabInvestigationProfileHeader if not exists
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileHeader]') AND name = 'Effective_Start_Date')
BEGIN
    ALTER TABLE [dbo].[LabInvestigationProfileHeader]
    ADD [Effective_Start_Date] DATE NULL;

    PRINT 'Added Effective_Start_Date column to dbo.LabInvestigationProfileHeader.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'[dbo].[LabInvestigationProfileHeader]') AND name = 'Effective_End_Date')
BEGIN
    ALTER TABLE [dbo].[LabInvestigationProfileHeader]
    ADD [Effective_End_Date] DATE NULL;

    PRINT 'Added Effective_End_Date column to dbo.LabInvestigationProfileHeader.';
END
GO

-- 2. Update Stored Procedure: dbo.usp_Api_LabInvestigationProfile_GetList
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_GetList]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetList];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetList]
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
        h.[Profile_Code],
        h.[Profile_Name],
        h.[Profile_Type],
        h.[Test_ID],
        pt.[Test_Code] AS [ProfileTestCode],
        pt.[Test_Name] AS [ProfileTestName],
        h.[MRP],
        h.[Discount_Pct],
        h.[Effective_Start_Date],
        h.[Effective_End_Date],
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
    LEFT JOIN [dbo].[LabInvestigationMaster] pt ON h.[Test_ID] = pt.[Test_ID]
    WHERE h.[IsDeleted] = 0
      AND (@CompanyId IS NULL OR h.[CompanyId] = @CompanyId)
      AND (@ProfileType IS NULL OR h.[Profile_Type] = @ProfileType)
      AND (@Status IS NULL OR h.[Status] = @Status)
      AND (@SearchTerm IS NULL OR @SearchTerm = '' OR h.[Profile_Name] LIKE '%' + @SearchTerm + '%' OR h.[Profile_Code] LIKE '%' + @SearchTerm + '%' OR pt.[Test_Name] LIKE '%' + @SearchTerm + '%')
    ORDER BY h.[Report_Print_Sequence] ASC, h.[Profile_Name] ASC;
END
GO

-- 3. Update Stored Procedure: dbo.usp_Api_LabInvestigationProfile_GetById
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
        h.[Profile_Code],
        h.[Profile_Name],
        h.[Profile_Type],
        h.[Test_ID],
        pt.[Test_Code] AS [ProfileTestCode],
        pt.[Test_Name] AS [ProfileTestName],
        h.[MRP],
        h.[Discount_Pct],
        h.[Effective_Start_Date],
        h.[Effective_End_Date],
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
    LEFT JOIN [dbo].[LabInvestigationMaster] pt ON h.[Test_ID] = pt.[Test_ID]
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

-- 4. Update Stored Procedure: dbo.usp_Api_LabInvestigationProfile_Save
IF OBJECT_ID(N'[dbo].[usp_Api_LabInvestigationProfile_Save]', N'P') IS NOT NULL
    DROP PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Save];
GO

CREATE PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_Save]
    @Profile_ID              INT = NULL OUTPUT,
    @CompanyId               INT = 1,
    @Profile_Name            NVARCHAR(200),
    @Profile_Type            VARCHAR(50) = 'Profile',
    @Test_ID                 INT = NULL,
    @MRP                     DECIMAL(18,2) = 0.00,
    @Discount_Pct            DECIMAL(5,2) = 0.00,
    @Effective_Start_Date    DATE = NULL,
    @Effective_End_Date      DATE = NULL,
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
        -- Sync Profile_Name from LabInvestigationMaster if Profile_Type = 'Profile' and Test_ID is provided
        IF @Profile_Type = 'Profile' AND @Test_ID IS NOT NULL AND (ISNULL(@Profile_Name, '') = '')
        BEGIN
            SELECT @Profile_Name = [Test_Name] 
            FROM [dbo].[LabInvestigationMaster] 
            WHERE [Test_ID] = @Test_ID;
        END

        -- Check Duplicate Profile Name or Test_ID for Profile
        IF @Profile_Type = 'Profile' AND @Test_ID IS NOT NULL
        BEGIN
            IF EXISTS (
                SELECT 1 FROM [dbo].[LabInvestigationProfileHeader]
                WHERE [Test_ID] = @Test_ID 
                  AND (@Profile_ID IS NULL OR [Profile_ID] <> @Profile_ID)
                  AND [IsDeleted] = 0
            )
            BEGIN
                RAISERROR('A profile with this selected Investigation Test already exists.', 16, 1);
                ROLLBACK TRANSACTION;
                RETURN;
            END
        END
        ELSE
        BEGIN
            IF EXISTS (
                SELECT 1 FROM [dbo].[LabInvestigationProfileHeader]
                WHERE [Profile_Name] = @Profile_Name 
                  AND (@Profile_ID IS NULL OR [Profile_ID] <> @Profile_ID)
                  AND [IsDeleted] = 0
            )
            BEGIN
                RAISERROR('Investigation Profile/Package Name already exists. Duplicate names are not allowed.', 16, 1);
                ROLLBACK TRANSACTION;
                RETURN;
            END
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
                [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
                [MRP], [Discount_Pct], [Effective_Start_Date], [Effective_End_Date],
                [Age_Operator], [Applicable_Age], [Applicable_Gender],
                [Profile_TAT_Hours], [Profile_NABL_Accredited], [Report_Print_Sequence],
                [Status], [IsDeleted], [CreatedBy], [CreatedDate]
            )
            VALUES
            (
                @CompanyId, @Profile_Code, @Profile_Name, @Profile_Type, @Test_ID,
                @MRP, @Discount_Pct, @Effective_Start_Date, @Effective_End_Date,
                @Age_Operator, @Applicable_Age, @Applicable_Gender,
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
                [Test_ID]                = @Test_ID,
                [MRP]                    = @MRP,
                [Discount_Pct]           = @Discount_Pct,
                [Effective_Start_Date]   = @Effective_Start_Date,
                [Effective_End_Date]     = @Effective_End_Date,
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

        -- Synchronize Details using UDT
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

PRINT 'Migration 2018_lab_investigation_profile_effective_dates.sql executed successfully.';
