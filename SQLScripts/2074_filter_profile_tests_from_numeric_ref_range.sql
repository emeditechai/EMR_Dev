-- ============================================================
-- Script: 2074_filter_profile_tests_from_numeric_ref_range.sql
-- Description: Updates usp_Api_LabReferenceRange_GetNumericTests to filter out
--              Profile/Package parent tests (Is_Profile_Test = 1 or linked in LabInvestigationProfileHeader),
--              so only individual numeric investigation child tests are selectable.
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReferenceRange_GetNumericTests
    @CompanyId INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        t.Test_ID,
        t.Test_Code,
        t.Test_Name,
        t.Reporting_Type,
        t.Method_ID,
        m.Method_Name,
        t.Unit_ID,
        u.Unit_Name,
        u.Unit_Symbol,
        t.Applicable_Gender
    FROM dbo.LabInvestigationMaster t
    LEFT JOIN dbo.LabTestMethodMaster m ON t.Method_ID = m.Method_ID AND m.IsDeleted = 0
    LEFT JOIN dbo.LabUnitMaster u ON t.Unit_ID = u.Unit_ID AND u.IsDeleted = 0
    WHERE t.CompanyId = @CompanyId
      AND t.IsDeleted = 0
      AND t.Status = 1
      AND LOWER(LTRIM(RTRIM(ISNULL(t.Reporting_Type, '')))) = 'numeric'
      -- Exclude parent profiles / packages (such as CBC, LFT, Lipid Profile)
      AND ISNULL(t.Is_Profile_Test, 0) = 0
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE h.Test_ID = t.Test_ID 
            AND h.IsDeleted = 0
      )
    ORDER BY t.Test_Name ASC;
END
GO

PRINT 'Successfully updated usp_Api_LabReferenceRange_GetNumericTests to exclude profiles/packages.';
GO
