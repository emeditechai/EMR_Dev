-- ============================================================================
-- Migration: 2094_lab_reporting_b2b_flags.sql
-- Description:
--   Adds dbo.usp_LabReporting_GetB2BFlags - a READ-ONLY lookup used by the Lab Reporting list to mark
--   B2B-billed orders with a "B2B" badge. It returns one row per B2B order among the ids passed in
--   (B2C orders return nothing), with the billing partner (Franchise 'F' / Company 'C') for the tooltip.
--
--   Deliberately separate from usp_LabReporting_GetHeaderList so the list procedure is left untouched.
--   No existing table or procedure is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetB2BFlags
    @LabOrderIds NVARCHAR(MAX)          -- comma-separated LabOrderId list
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        lo.LabOrderId,
        CASE lo.AgentType WHEN 'F' THEN 'FRANCHISE' ELSE 'COMPANY' END                  AS ClientType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END AS ClientCode,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END AS ClientName
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.LabFranchiseMaster f    ON f.Franchise_ID    = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster    corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.IsB2B = 1
      AND lo.LabOrderId IN (SELECT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
                            FROM STRING_SPLIT(ISNULL(@LabOrderIds, ''), ',') s
                            WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) IS NOT NULL);
END;
GO

PRINT 'Created procedure dbo.usp_LabReporting_GetB2BFlags';
GO
