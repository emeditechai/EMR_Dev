-- ====================================================================================================
-- Script: 2017_rate_card_items_billable_only.sql
-- Description: Updates usp_Api_LabItems_GetAll to filter tests/profiles by Is_Billable = 1.
-- Database:    Dev_EMR (SQL Server)
-- ====================================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;
GO

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
