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
    ORDER BY m.[Is_Profile_Test] DESC, m.[Test_Name] ASC;
END
GO
