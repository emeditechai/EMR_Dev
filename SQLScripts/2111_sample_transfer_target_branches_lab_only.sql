-- ============================================================================
-- Migration: 2111_sample_transfer_target_branches_lab_only.sql
-- Description:
--   Sample Transfer > Dispatch Samples Worklist:
--     1. The worklist already lists only Collected samples (SampleCollection.CollectionstatusID = 2) -
--        unchanged here, confirmed by test.
--     2. dbo.usp_SampleTransfer_GetTargetBranches now offers only branches marked IsLab = 1
--        (Branch Master > Is Lab), so a sample can only be routed to a branch that is actually a lab.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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
      AND IsLab = 1
      AND (@CurrentBranchId <= 0 OR BranchID <> @CurrentBranchId)
    ORDER BY BranchName;
END;
GO

PRINT 'Updated dbo.usp_SampleTransfer_GetTargetBranches (lab branches only).';
GO
