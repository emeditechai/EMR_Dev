-- Update usp_GetAvailableInvestigations to return Is_Outsourced
CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL,
    @Gender VARCHAR(20) = NULL,
    @AgeInYears INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        i.Test_ID as InvestigationId,
        i.Test_Code as TestCode,
        i.Test_Name as TestName,
        i.TAT_Hours as TATHours,
        COALESCE(d.Rate, i.MRP, 0) as MRP,
        CAST(ISNULL(i.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        st.Sample_Name as SampleType,
        tm.Method_Name as Method,
        CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) as IsDiscountAllowed,
        CAST(0 AS BIT) as IsPackage,
        CAST(ISNULL(i.Is_Outsourced, 0) AS BIT) as IsOutsourced
    FROM LabInvestigationMaster i
    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = @BranchId 
        AND m.Rate_Type = 'B2C' 
        AND m.Status = 1 
        AND m.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
        AND d.Item_ID = i.Test_ID 
        AND d.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND d.IsDeleted = 0
    LEFT JOIN LabInvestigationProfileHeader h ON (h.Test_ID = i.Test_ID OR h.Profile_Name = i.Test_Name) AND h.IsDeleted = 0
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

    -- Packages (Profile_Type = 2)
    SELECT 
        h.Profile_ID as InvestigationId,
        h.Profile_Code as TestCode,
        h.Profile_Name as TestName,
        h.Profile_TAT_Hours as TATHours,
        COALESCE(d.Rate, h.MRP, 0) as MRP,
        CAST(0 AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        NULL as SampleType,
        NULL as Method,
        CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) as IsDiscountAllowed,
        CAST(1 AS BIT) as IsPackage,
        CAST(0 AS BIT) as IsOutsourced
    FROM LabInvestigationProfileHeader h
    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = @BranchId 
        AND m.Rate_Type = 'B2C' 
        AND m.Status = 1 
        AND m.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
        AND d.Item_ID = h.Profile_ID 
        AND d.Item_Type = 'Package' 
        AND d.IsDeleted = 0
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
END
GO
