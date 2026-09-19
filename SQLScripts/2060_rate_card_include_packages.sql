-- ====================================================================================================
-- Script: 2060_rate_card_include_packages.sql
-- Description: Updates usp_Api_LabItems_GetAll and usp_Api_LabRateCardMaster_GetById to support Packages
--              defined in LabInvestigationProfileHeader (Profile_Type = 2 / 'Package' and Test_ID IS NULL).
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;
GO

-- 1. Update dbo.usp_Api_LabItems_GetAll
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_LabItems_GetAll]
    @CompanyId INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    -- Tests and Profiles from LabInvestigationMaster
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
    WHERE m.[IsDeleted] = 0 
      AND m.[Status] = 1 
      AND m.[Is_Billable] = 1
      AND (@CompanyId IS NULL OR m.[CompanyId] = @CompanyId)

    UNION ALL

    -- Pure Packages from LabInvestigationProfileHeader (Profile_Type = 2 or 'Package')
    SELECT 
        'Package' AS [Item_Type],
        h.[Profile_ID] AS [Item_ID],
        h.[Profile_Code] AS [Item_Code],
        h.[Profile_Name] AS [Item_Name],
        NULL AS [Department_ID],
        NULL AS [Category_ID],
        NULL AS [SubCategory_ID],
        h.[MRP] AS [Default_Rate],
        CAST(0 AS BIT) AS [Is_Profile_Test]
    FROM [dbo].[LabInvestigationProfileHeader] h
    WHERE h.[IsDeleted] = 0 
      AND h.[Status] = 1 
      AND (h.[Profile_Type] = 2 OR CAST(h.[Profile_Type] AS VARCHAR(50)) = 'Package')
      AND h.[Test_ID] IS NULL
      AND (@CompanyId IS NULL OR h.[CompanyId] = @CompanyId)

    ORDER BY [Item_Type] DESC, [Item_Name] ASC;
END
GO

-- 2. Update dbo.usp_Api_LabRateCardMaster_GetById
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
        h.[B2CIdentity_ID],
        CASE 
            WHEN h.[Rate_Type] = 'Franchise' THEN f.[Franchise_Name]
            WHEN h.[Rate_Type] = 'Corporate' THEN c.[Corporate_Name]
            ELSE NULL 
        END AS [Entity_Name],
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
    LEFT JOIN [dbo].[LabFranchiseMaster] f ON h.[B2CIdentity_ID] = f.[Franchise_ID]
    LEFT JOIN [dbo].[CorporateMaster] c ON h.[B2CIdentity_ID] = c.[Corporate_ID]
    WHERE h.[RateCard_ID] = @RateCard_ID AND h.[IsDeleted] = 0;

    -- Resultset 2: Details with Item Names & Rates resolved for Tests, Profiles, and Packages
    DECLARE @Branch_ID INT;
    SELECT @Branch_ID = [Branch_ID] FROM [dbo].[LabRateCardMaster] WHERE [RateCard_ID] = @RateCard_ID;

    SELECT 
        d.[Detail_ID],
        d.[RateCard_ID],
        d.[Item_Type],
        d.[Item_ID],
        COALESCE(t.[Test_Name], pkg.[Profile_Name], 'Unknown Item') AS [Item_Name],
        COALESCE(t.[Test_Code], pkg.[Profile_Code], '') AS [Item_Code],
        COALESCE(t.[MRP], pkg.[MRP], 0) AS [Default_Rate],
        COALESCE(b2cd.[Rate], t.[MRP], pkg.[MRP], 0) AS [Branch_Rate],
        t.[Category_ID],
        t.[SubCategory_ID],
        t.[Department_ID],
        ISNULL(t.[Is_Profile_Test], 0) AS [Is_Profile_Test],
        d.[Rate],
        ISNULL(d.[Is_Discount_Allowed], 0) AS [Is_Discount_Allowed],
        d.[Status]
    FROM [dbo].[LabRateCardDetail] d
    LEFT JOIN [dbo].[LabInvestigationMaster] t 
        ON d.[Item_ID] = t.[Test_ID] AND d.[Item_Type] IN ('Test', 'Profile')
    LEFT JOIN [dbo].[LabInvestigationProfileHeader] pkg 
        ON d.[Item_ID] = pkg.[Profile_ID] AND d.[Item_Type] = 'Package' AND pkg.[IsDeleted] = 0
    OUTER APPLY (
        SELECT TOP 1 cd.[Rate]
        FROM [dbo].[LabRateCardMaster] ch
        INNER JOIN [dbo].[LabRateCardDetail] cd ON ch.[RateCard_ID] = cd.[RateCard_ID] AND cd.[IsDeleted] = 0
        WHERE ch.[Rate_Type] = 'B2C'
          AND ch.[Branch_ID] = @Branch_ID
          AND ch.[Status] = 1
          AND ch.[IsDeleted] = 0
          AND cd.[Item_Type] = d.[Item_Type]
          AND cd.[Item_ID] = d.[Item_ID]
        ORDER BY ch.[Effective_From] DESC, ch.[RateCard_ID] DESC
    ) b2cd
    WHERE d.[RateCard_ID] = @RateCard_ID AND d.[IsDeleted] = 0
    ORDER BY 
        CASE d.[Item_Type] 
            WHEN 'Package' THEN 1 
            WHEN 'Profile' THEN 2 
            ELSE 3 
        END ASC,
        COALESCE(t.[Test_Name], pkg.[Profile_Name]) ASC;
END
GO

PRINT 'Updated usp_Api_LabItems_GetAll and usp_Api_LabRateCardMaster_GetById for package support.';
GO
