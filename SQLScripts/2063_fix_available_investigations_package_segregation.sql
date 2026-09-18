-- ============================================================================
-- Migration: 2063_fix_available_investigations_package_segregation.sql
-- Description: 
--   1. Fix dbo.usp_GetAvailableInvestigations to segregate Packages and Profiles
--      in LabRateCardDetail joins (change OR condition to strict 'Package' match).
--   2. Ensure ProfileHeader join in Part 1 strictly checks Profile_Type = 1.
--   3. Avoid duplicate rows when a test/profile and package share the same numeric Item_ID.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL,
    @Gender VARCHAR(20) = NULL,
    @AgeInYears INT = NULL,
    @RateType VARCHAR(50) = 'B2C',
    @AgentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Investigations & Profiles from LabInvestigationMaster
    SELECT 
        i.Test_ID as InvestigationId,
        i.Test_Code as TestCode,
        i.Test_Name as TestName,
        i.TAT_Hours as TATHours,
        COALESCE(db2c.Rate, i.MRP, 0) as MRP,
        CAST(ISNULL(i.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        st.Sample_Name as SampleType,
        tm.Method_Name as Method,
        CAST(ISNULL(COALESCE(db2b.Is_Discount_Allowed, db2c.Is_Discount_Allowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(0 AS BIT) as IsPackage,
        CAST(ISNULL(i.Is_Outsourced, 0) AS BIT) as IsOutsourced,
        COALESCE(db2b.Rate, db2c.Rate, i.MRP, 0) as B2BRate
    FROM LabInvestigationMaster i
    LEFT JOIN LabRateCardMaster mb2c ON mb2c.Branch_ID = @BranchId 
        AND mb2c.Rate_Type = 'B2C' 
        AND mb2c.Status = 1 
        AND mb2c.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2c.Effective_From AND mb2c.Effective_To
    LEFT JOIN LabRateCardDetail db2c ON db2c.RateCard_ID = mb2c.RateCard_ID 
        AND db2c.Item_ID = i.Test_ID 
        AND db2c.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND db2c.IsDeleted = 0
    LEFT JOIN LabRateCardMaster mb2b ON (mb2b.Branch_ID = @BranchId OR (mb2b.Rate_Type = 'Corporate' AND mb2b.Branch_ID IS NULL))
        AND mb2b.Rate_Type = @RateType 
        AND mb2b.B2CIdentity_ID = @AgentId
        AND mb2b.Status = 1 
        AND mb2b.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2b.Effective_From AND mb2b.Effective_To
    LEFT JOIN LabRateCardDetail db2b ON db2b.RateCard_ID = mb2b.RateCard_ID 
        AND db2b.Item_ID = i.Test_ID 
        AND db2b.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND db2b.IsDeleted = 0
    LEFT JOIN LabInvestigationProfileHeader h ON (h.Test_ID = i.Test_ID OR (h.Profile_Name = i.Test_Name AND h.Profile_Type = 1)) 
        AND h.IsDeleted = 0 
        AND h.Profile_Type = 1
    LEFT JOIN dbo.LabSampleTypeMaster st ON i.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON i.Method_ID = tm.Method_ID
    WHERE i.Status = 1 AND i.IsDeleted = 0
      AND i.Is_Billable = 1
      AND (@DepartmentId IS NULL OR i.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR i.Category_ID = @CategoryId)
      AND (@SubCategoryId IS NULL OR i.SubCategory_ID = @SubCategoryId)
      AND (
          i.Applicable_Gender = 'All' 
          OR @Gender IS NULL 
          OR i.Applicable_Gender = @Gender
      )
      AND (
          i.Age_Operator IS NULL 
          OR i.Age_Operator = '-- No Age Limit --' 
          OR @AgeInYears IS NULL 
          OR (i.Age_Operator = '=' AND @AgeInYears = i.Applicable_Age)
          OR (i.Age_Operator = '>=' AND @AgeInYears >= i.Applicable_Age)
          OR (i.Age_Operator = '<=' AND @AgeInYears <= i.Applicable_Age)
      )

    UNION ALL

    -- 2. Packages from LabInvestigationProfileHeader (Profile_Type = 2)
    SELECT 
        h.Profile_ID as InvestigationId,
        h.Profile_Code as TestCode,
        h.Profile_Name as TestName,
        h.Profile_TAT_Hours as TATHours,
        COALESCE(db2c.Rate, h.MRP, 0) as MRP,
        CAST(0 AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        NULL as SampleType,
        NULL as Method,
        CAST(ISNULL(COALESCE(db2b.Is_Discount_Allowed, db2c.Is_Discount_Allowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(1 AS BIT) as IsPackage,
        CAST(0 AS BIT) as IsOutsourced,
        COALESCE(db2b.Rate, db2c.Rate, h.MRP, 0) as B2BRate
    FROM LabInvestigationProfileHeader h
    LEFT JOIN LabRateCardMaster mb2c ON mb2c.Branch_ID = @BranchId 
        AND mb2c.Rate_Type = 'B2C' 
        AND mb2c.Status = 1 
        AND mb2c.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2c.Effective_From AND mb2c.Effective_To
    LEFT JOIN LabRateCardDetail db2c ON db2c.RateCard_ID = mb2c.RateCard_ID 
        AND db2c.Item_ID = h.Profile_ID 
        AND db2c.Item_Type = 'Package'
        AND db2c.IsDeleted = 0
    LEFT JOIN LabRateCardMaster mb2b ON (mb2b.Branch_ID = @BranchId OR (mb2b.Rate_Type = 'Corporate' AND mb2b.Branch_ID IS NULL))
        AND mb2b.Rate_Type = @RateType 
        AND mb2b.B2CIdentity_ID = @AgentId
        AND mb2b.Status = 1 
        AND mb2b.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2b.Effective_From AND mb2b.Effective_To
    LEFT JOIN LabRateCardDetail db2b ON db2b.RateCard_ID = mb2b.RateCard_ID 
        AND db2b.Item_ID = h.Profile_ID 
        AND db2b.Item_Type = 'Package'
        AND db2b.IsDeleted = 0
    WHERE h.Status = 1 AND h.IsDeleted = 0
      AND h.Profile_Type = 2 -- 2 = Package
      AND (@DepartmentId IS NULL) 
      AND (@CategoryId IS NULL) 
      AND (@SubCategoryId IS NULL)
      AND (
          h.Applicable_Gender = 'All' 
          OR @Gender IS NULL 
          OR h.Applicable_Gender = @Gender
      )
      AND (
          h.Age_Operator IS NULL 
          OR h.Age_Operator = '-- No Age Limit --' 
          OR @AgeInYears IS NULL 
          OR (h.Age_Operator = '=' AND @AgeInYears = h.Applicable_Age)
          OR (h.Age_Operator = '>=' AND @AgeInYears >= h.Applicable_Age)
          OR (h.Age_Operator = '<=' AND @AgeInYears <= h.Applicable_Age)
      )
    ORDER BY TestName;
END;
GO
