-- ============================================================================
-- Migration: 2276_lab_profile_effective_dates_read.sql
-- Investigation Profile / Package: the Effective Start / End dates were saved by usp_Api_LabInvestigationProfile_Save
-- but never read back, so Edit showed them empty (and a re-save wiped them) and Details / the list had nothing.
-- GetById and GetList now return both columns.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetById]
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

CREATE OR ALTER PROCEDURE [dbo].[usp_Api_LabInvestigationProfile_GetList]
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
