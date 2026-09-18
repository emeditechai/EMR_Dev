SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ========================================================================
-- Description: Returns active branches available as targets for sample transfer
-- Excludes the current branch if specified.
-- ========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_GetTargetBranches
    @CurrentBranchId INT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        BranchID,
        BranchCode,
        BranchName,
        IsActive
    FROM dbo.Branchmaster
    WHERE IsActive = 1
      AND (@CurrentBranchId <= 0 OR BranchID <> @CurrentBranchId)
    ORDER BY BranchName;
END;
GO
