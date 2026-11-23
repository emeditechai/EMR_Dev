-- ============================================================================================================
-- Migration: 2514_lab_report_serial_no.sql   (application database; needs 2513)
-- Lab Serial No on the report entry pages, when Hospital Settings > LAB > "Is Lab Serial No Req" is Yes for the branch:
-- one serial per lab order (patient bill) per reporting page - LAB = Lab Report Entry, IMAGE = Lab Image Reporting,
-- MICRO = Microbiology Report Entry. Required on every save of that page while the setting is Yes.
--   dbo.LabReportSerialNo        : LabOrderId + ReportType unique
--   usp_Api_LabSerialNo_Get      : Required (branch setting) and the stored serial
--   usp_Api_LabSerialNo_Save     : create / change it (Success, Message)
-- Endpoints: LabReporting/SaveEntryJson, LabImageReporting/SaveReportJson, MicrobiologyReporting/SaveEntryJson (existing).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.LabReportSerialNo', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportSerialNo
    (
        LabReportSerialNoId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabReportSerialNo PRIMARY KEY,
        LabOrderId          INT           NOT NULL CONSTRAINT FK_LabReportSerialNo_LabOrder REFERENCES dbo.LabOrder (LabOrderId),
        ReportType          VARCHAR(10)   NOT NULL CONSTRAINT CK_LabReportSerialNo_Type CHECK (ReportType IN ('LAB', 'IMAGE', 'MICRO')),
        BranchId            INT           NOT NULL,
        LabSerialNo         NVARCHAR(50)  NOT NULL,
        CreatedBy           INT           NULL,
        CreatedDate         DATETIME      NOT NULL CONSTRAINT DF_LabReportSerialNo_Created DEFAULT (GETDATE()),
        ModifiedBy          INT           NULL,
        ModifiedDate        DATETIME      NULL
    );
    CREATE UNIQUE INDEX UX_LabReportSerialNo_Order_Type ON dbo.LabReportSerialNo (LabOrderId, ReportType);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSerialNo_Get
    @LabOrderId INT,
    @ReportType VARCHAR(10),
    @BranchId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(ISNULL((SELECT TOP 1 hs.IsLabSerialNoReq FROM dbo.HospitalSettings hs WHERE hs.BranchId = @BranchId), 0) AS BIT) AS Required,
           (SELECT s.LabSerialNo FROM dbo.LabReportSerialNo s WHERE s.LabOrderId = @LabOrderId AND s.ReportType = UPPER(@ReportType)) AS LabSerialNo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSerialNo_Save
    @LabOrderId  INT,
    @ReportType  VARCHAR(10),
    @BranchId    INT,
    @LabSerialNo NVARCHAR(100),
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @ReportType = UPPER(LTRIM(RTRIM(ISNULL(@ReportType, ''))));
    SET @LabSerialNo = NULLIF(LTRIM(RTRIM(@LabSerialNo)), N'');
    DECLARE @Req BIT = ISNULL((SELECT TOP 1 hs.IsLabSerialNoReq FROM dbo.HospitalSettings hs WHERE hs.BranchId = @BranchId), 0);

    IF @ReportType NOT IN ('LAB', 'IMAGE', 'MICRO')
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Unknown report type.' AS Message; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND BranchId = @BranchId)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Lab order not found in this branch.' AS Message; RETURN; END
    IF @Req = 1 AND @LabSerialNo IS NULL
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the Lab Serial No.' AS Message; RETURN; END
    IF LEN(@LabSerialNo) > 50
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The Lab Serial No can be up to 50 characters.' AS Message; RETURN; END
    IF @LabSerialNo IS NULL
    BEGIN SELECT CAST(1 AS BIT) AS Success, N'' AS Message; RETURN; END   -- not required and not given: nothing to keep

    -- approved: the serial stays as it is (LAB = numeric / text entries, IMAGE = image entries; all of them approved)
    DECLARE @Stored NVARCHAR(50) = (SELECT LabSerialNo FROM dbo.LabReportSerialNo WHERE LabOrderId = @LabOrderId AND ReportType = @ReportType);
    IF @Stored IS NOT NULL AND @Stored <> @LabSerialNo AND @ReportType IN ('LAB', 'IMAGE')
       AND EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.LabOrderId = @LabOrderId AND ISNULL(e.IsActive, 1) = 1
                      AND ((@ReportType = 'IMAGE' AND e.Reporting_Type = 'Image') OR (@ReportType = 'LAB' AND ISNULL(e.Reporting_Type, '') <> 'Image')))
       AND NOT EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.LabOrderId = @LabOrderId AND ISNULL(e.IsActive, 1) = 1 AND ISNULL(e.ReportStatusId, 0) <> 5
                      AND ((@ReportType = 'IMAGE' AND e.Reporting_Type = 'Image') OR (@ReportType = 'LAB' AND ISNULL(e.Reporting_Type, '') <> 'Image')))
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The report is approved - its Lab Serial No cannot be changed.' AS Message; RETURN; END

    MERGE dbo.LabReportSerialNo WITH (HOLDLOCK) AS t
    USING (SELECT @LabOrderId AS LabOrderId, @ReportType AS ReportType) AS s
       ON t.LabOrderId = s.LabOrderId AND t.ReportType = s.ReportType
    WHEN MATCHED AND t.LabSerialNo <> @LabSerialNo THEN
        UPDATE SET LabSerialNo = @LabSerialNo, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (LabOrderId, ReportType, BranchId, LabSerialNo, CreatedBy) VALUES (@LabOrderId, @ReportType, @BranchId, @LabSerialNo, @UserId);
    SELECT CAST(1 AS BIT) AS Success, N'' AS Message;
END
GO
-- the serial printed on a report (Specimen Information, before Report Status): LAB / IMAGE / MICRO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabSerialNo_ForPrint
    @LabOrderId INT,
    @ReportType VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.LabSerialNo FROM dbo.LabReportSerialNo s WHERE s.LabOrderId = @LabOrderId AND s.ReportType = UPPER(@ReportType);
END
GO
PRINT 'Script 2514 applied: Lab Serial No on the report entry pages.';
GO
