-- ============================================================================================================
-- Migration: 2391_lab_report_external_document_merge.sql
-- Lab Report print / e-mail / WhatsApp / portal: the external document uploaded for a test (LAB > External Document
-- Upload, dbo.LabExternalDocument) is merged into the report at print time, right below that test, once the test is
-- approved - under the report's own header and footer. Nothing is stored: the file is read from the FTP server.
--   usp_Lab_ExternalDoc_ForReport: the active external documents of a lab order (one per test, the latest).
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_ExternalDoc_ForReport
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DocumentId, d.CompanyId, d.BranchId, d.LabOrderId, d.InvestigationId, d.LabOrderItemId,
           d.OriginalFileName, d.FileName, d.FilePath, d.ContentType, d.FileSizeBytes, d.UpdatedDate
      FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.InvestigationId ORDER BY x.UpdatedDate DESC, x.DocumentId DESC) AS rn
              FROM dbo.LabExternalDocument x
             WHERE x.LabOrderId = @LabOrderId AND x.IsActive = 1) d
     WHERE d.rn = 1
     ORDER BY d.InvestigationId;
END
GO

PRINT 'Script 2391 applied: external documents merged into the lab report at print time.';
GO
