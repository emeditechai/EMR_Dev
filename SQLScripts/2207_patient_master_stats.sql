-- =====================================================================================================================
-- 2207  Patient Master list: summary cards
--
-- usp_Api_Patient_GetStats @CompanyId, @BranchId - the same patients the list shows (usp_Api_Patient_GetByBranch
-- scope, no search): total, active, inactive, registered today and registered this month. Read only. Safe to re-run.
-- =====================================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetStats
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);

    SELECT
        COUNT(1)                                                                       AS TotalPatients,
        SUM(CASE WHEN p.IsActive = 1 THEN 1 ELSE 0 END)                                AS ActivePatients,
        SUM(CASE WHEN ISNULL(p.IsActive, 0) = 0 THEN 1 ELSE 0 END)                     AS InactivePatients,
        SUM(CASE WHEN p.CreatedDate >= @Today THEN 1 ELSE 0 END)                       AS RegisteredToday,
        SUM(CASE WHEN p.CreatedDate >= @MonthStart THEN 1 ELSE 0 END)                  AS RegisteredThisMonth
    FROM dbo.PatientMaster p
    WHERE (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR p.BranchId = @BranchId);
END;
GO
