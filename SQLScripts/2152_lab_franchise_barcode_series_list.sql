-- ============================================================================
-- Migration: 2152_lab_franchise_barcode_series_list.sql
-- Description:
--   dbo.usp_Lab_GetFranchiseBarcodeStatus (script 2151) looks up ONE barcode.
--   The "View Barcodes" list of the Franchise Barcode Assignment page needs
--   every code of a series at once, with its Status and (once Used) the
--   Bill No / Test that consumed it - the audit-history requirement.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetSeriesBarcodes
    @SeriesId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        bp.BarcodeId,
        bp.BarcodeNo,
        bp.Status,
        CASE bp.Status WHEN 1 THEN 'Available' WHEN 2 THEN 'Used' WHEN 3 THEN 'Voided' END AS StatusName,
        bp.Franchise_ID,
        f.Franchise_Code,
        f.Franchise_Name,
        bp.SeriesId,
        s.SeriesCode,
        s.Status AS SeriesStatus,
        bp.LabOrderId,
        lo.BillNo,
        bp.SamplecollectionID,
        bp.InvestigationId,
        lim.Test_Name,
        bp.UsedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UsedByName
    FROM dbo.LabFranchiseBarcodePool bp
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = bp.Franchise_ID
    INNER JOIN dbo.LabFranchiseBarcodeSeries s ON s.SeriesId = bp.SeriesId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = bp.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = bp.InvestigationId
    LEFT JOIN dbo.Users u ON u.Id = bp.UsedBy
    WHERE bp.SeriesId = @SeriesId
    ORDER BY bp.SequenceNo;
END
GO

PRINT 'Script 2152 applied: usp_Lab_GetSeriesBarcodes created.';
GO
