-- ============================================================================================================
-- 2356  LAB External Document Upload: the record also keeps the lab booking no; the file is named by test code.
--   LabExternalDocument.LabBookingNo  passed to usp_Lab_ExternalDoc_Save; when not given it is taken from LabOrder.BillNo. Backfilled here.
--   File name on the FTP server       <BranchCode>_<Lab booking no>_<Test code>.<ext> (built in the app).
-- Run after 2354. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.LabExternalDocument', 'LabBookingNo') IS NULL
    ALTER TABLE dbo.LabExternalDocument ADD LabBookingNo NVARCHAR(50) NULL;
GO
UPDATE d SET LabBookingNo = lo.BillNo
  FROM dbo.LabExternalDocument d
  JOIN dbo.LabOrder lo ON lo.LabOrderId = d.LabOrderId
 WHERE d.LabBookingNo IS NULL;
GO

-- descriptions (picked up by the data dictionary)
DECLARE @d TABLE (c SYSNAME, v NVARCHAR(400));
INSERT @d VALUES
 (N'LabBookingNo', N'Lab booking no (LabOrder.BillNo) at the time of upload.'),
 (N'FileName', N'Name stored on the FTP server: <BranchCode>_<Lab booking no>_<Test code>.<ext> (characters other than letters, digits, . _ - become _).');
DECLARE @t SYSNAME = N'dbo.LabExternalDocument', @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT c, v FROM @d;
OPEN dc;
FETCH NEXT FROM dc INTO @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(@t) AND minor_id = COLUMNPROPERTY(OBJECT_ID(@t), @c, 'ColumnId') AND name = 'MS_Description')
        EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'LabExternalDocument', 'COLUMN', @c;
    ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'LabExternalDocument', 'COLUMN', @c;
    FETCH NEXT FROM dc INTO @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_ExternalDoc_Save
    @CompanyId        INT,
    @BranchId         INT,
    @LabOrderId       INT,
    @InvestigationId  INT,
    @LabOrderItemId   INT = NULL,
    @OriginalFileName NVARCHAR(260),
    @FileName         NVARCHAR(260),
    @FilePath         NVARCHAR(1000),
    @FileSizeBytes    BIGINT,
    @ContentType      NVARCHAR(100) = NULL,
    @UserId           INT,
    @LabBookingNo     NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_LabExternalDocTest v JOIN dbo.LabOrder lo ON lo.LabOrderId = v.LabOrderId
                    WHERE v.LabOrderId = @LabOrderId AND v.Test_ID = @InvestigationId AND lo.BranchId = @BranchId AND lo.IsActive = 1)
        THROW 54301, 'This test is not an active external-document test of the booking.', 1;

    BEGIN TRAN;
    UPDATE dbo.LabExternalDocument SET IsActive = 0, ReplacedBy = @UserId, ReplacedDate = GETDATE()
     WHERE LabOrderId = @LabOrderId AND InvestigationId = @InvestigationId AND IsActive = 1;
    INSERT dbo.LabExternalDocument (CompanyId, BranchId, LabOrderId, LabBookingNo, InvestigationId, LabOrderItemId, OriginalFileName,
                                    FileName, FilePath, FileSizeBytes, ContentType, UpdatedBy, UpdatedDate)
    VALUES (@CompanyId, @BranchId, @LabOrderId, COALESCE(NULLIF(@LabBookingNo, ''), (SELECT BillNo FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId)), @InvestigationId, @LabOrderItemId, @OriginalFileName,
            @FileName, @FilePath, @FileSizeBytes, @ContentType, @UserId, GETDATE());
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DocumentId;
    COMMIT;
END
GO
