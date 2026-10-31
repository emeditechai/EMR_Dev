/* =====================================================================================================
   2354 - LAB > External Document Upload (FTP)

   Tests marked "Has External Document" (LabInvestigationMaster.Has_External_Document, script 2352) get their
   external document (outside report, scan) uploaded against the lab booking. The file goes to the FTP server
   configured per branch in Hospital Settings > Lab tab:
       <RootFolder>/<Company name>/<Branch name>/<yyyy-MM-dd>/<BranchCode>_<Lab booking no>_<Test code>.<ext>
   (the record keeps BranchId, LabOrderId and InvestigationId)
   Folders are created when missing. Every upload is logged in LabExternalDocument; re-uploading a test's
   document replaces the previous one (kept inactive for history).

   - LabFtpSettings              : FTP host / port / user / password (encrypted by the application) per branch
   - LabExternalDocument         : the uploaded documents
   - usp_Lab_ExternalDoc_SearchBookings : bookings of a day (mobile / name / bill no filters) having such tests
   - usp_Lab_ExternalDoc_GetTests       : the booking's external-document tests and their latest upload
   - usp_Lab_ExternalDoc_Save           : records an upload
   - Page LAB.EXTERNALDOCUPLOAD (LAB menu); FTP settings endpoints on SETTINGS.HOSPITALSETTINGS
   Cancelled bookings (LabOrder.IsActive = 0) and cancelled tests (LabOrderItem.IsActive = 0, or every sample
   of the test cancelled) are never offered.
   ===================================================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.LabFtpSettings', 'U') IS NULL
CREATE TABLE dbo.LabFtpSettings
(
    FtpSettingId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabFtpSettings PRIMARY KEY,
    CompanyId     INT            NOT NULL,
    BranchId      INT            NOT NULL,
    Host          NVARCHAR(200)  NOT NULL,
    Port          INT            NOT NULL CONSTRAINT DF_LabFtpSettings_Port DEFAULT (21),
    UserName      NVARCHAR(150)  NOT NULL,
    PasswordEnc   NVARCHAR(2000) NULL,
    RootFolder    NVARCHAR(300)  NOT NULL CONSTRAINT DF_LabFtpSettings_Root DEFAULT (N'emedidoc/reports'),
    UsePassive    BIT            NOT NULL CONSTRAINT DF_LabFtpSettings_Passive DEFAULT (1),
    UseFtps       BIT            NOT NULL CONSTRAINT DF_LabFtpSettings_Ftps DEFAULT (0),
    IsActive      BIT            NOT NULL CONSTRAINT DF_LabFtpSettings_IsActive DEFAULT (1),
    ModifiedBy    INT            NULL,
    ModifiedDate  DATETIME       NOT NULL CONSTRAINT DF_LabFtpSettings_Modified DEFAULT (GETDATE()),
    CONSTRAINT UX_LabFtpSettings_Branch UNIQUE (BranchId)
);
GO

IF OBJECT_ID('dbo.LabExternalDocument', 'U') IS NULL
CREATE TABLE dbo.LabExternalDocument
(
    DocumentId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabExternalDocument PRIMARY KEY,
    CompanyId        INT            NOT NULL,
    BranchId         INT            NOT NULL,
    LabOrderId       INT            NOT NULL,
    InvestigationId  INT            NOT NULL,
    LabOrderItemId   INT            NULL,
    OriginalFileName NVARCHAR(260)  NOT NULL,
    FileName         NVARCHAR(260)  NOT NULL,
    FilePath         NVARCHAR(1000) NOT NULL,
    FileSizeBytes    BIGINT         NOT NULL,
    ContentType      NVARCHAR(100)  NULL,
    IsActive         BIT            NOT NULL CONSTRAINT DF_LabExternalDocument_IsActive DEFAULT (1),
    UpdatedBy        INT            NOT NULL,
    UpdatedDate      DATETIME       NOT NULL CONSTRAINT DF_LabExternalDocument_Updated DEFAULT (GETDATE()),
    ReplacedBy       INT            NULL,
    ReplacedDate     DATETIME       NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabExternalDocument_Order')
    CREATE INDEX IX_LabExternalDocument_Order ON dbo.LabExternalDocument (LabOrderId, InvestigationId, IsActive);
GO

-- descriptions (picked up by the data dictionary)
DECLARE @d TABLE (t SYSNAME, c SYSNAME NULL, v NVARCHAR(400));
INSERT @d VALUES
 (N'LabFtpSettings', NULL, N'FTP server for uploading external lab documents, per branch (Hospital Settings > Lab tab). The password is encrypted by the application.'),
 (N'LabFtpSettings', N'PasswordEnc', N'FTP password, encrypted with ASP.NET Core Data Protection; never shown back.'),
 (N'LabFtpSettings', N'RootFolder', N'Base folder on the FTP server; documents go to <RootFolder>/<Company>/<Branch>/<yyyy-MM-dd>/.'),
 (N'LabFtpSettings', N'UsePassive', N'1 = passive mode transfers (works through most firewalls).'),
 (N'LabFtpSettings', N'UseFtps', N'1 = explicit FTPS (TLS).'),
 (N'LabExternalDocument', NULL, N'External documents uploaded to FTP against a lab booking and test (tests with Has External Document). A re-upload replaces the previous file (kept inactive).'),
 (N'LabExternalDocument', N'FileName', N'Name stored on the FTP server: <BranchCode>_<Lab booking no>_<Test code>.<ext> (characters other than letters, digits, . _ - become _).'),
 (N'LabExternalDocument', N'FilePath', N'Full path of the file on the FTP server.'),
 (N'LabExternalDocument', N'OriginalFileName', N'Name of the file as chosen by the user.'),
 (N'LabExternalDocument', N'UpdatedBy', N'User who uploaded the file (Users.Id).'),
 (N'LabExternalDocument', N'IsActive', N'1 = current document of the test, 0 = replaced by a later upload.');
DECLARE @t SYSNAME, @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT t, c, v FROM @d;
OPEN dc; FETCH NEXT FROM dc INTO @t, @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @c IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(@t) AND minor_id = 0 AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
        ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
    END
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(@t) AND minor_id = COLUMNPROPERTY(OBJECT_ID(@t), @c, 'ColumnId') AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
        ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    END
    FETCH NEXT FROM dc INTO @t, @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO

-- The booking's tests that have an external document: tests billed directly and tests inside a billed profile /
-- package; cancelled lines, and tests whose every sample is cancelled, are left out.
CREATE OR ALTER VIEW dbo.vw_LabExternalDocTest
AS
SELECT x.LabOrderId, x.LabOrderItemId, x.Test_ID, x.Test_Code, x.Test_Name, x.ViaName
  FROM (
        SELECT oi.LabOrderId, oi.LabOrderItemId, im.Test_ID, im.Test_Code, im.Test_Name, CAST(NULL AS NVARCHAR(200)) AS ViaName
          FROM dbo.LabOrderItem oi
          JOIN dbo.LabInvestigationMaster im ON im.Test_ID = oi.InvestigationId
         WHERE oi.IsActive = 1 AND ISNULL(oi.Type, 'I') = 'I' AND im.Has_External_Document = 1
        UNION ALL
        SELECT oi.LabOrderId, oi.LabOrderItemId, im.Test_ID, im.Test_Code, im.Test_Name, h.Profile_Name
          FROM dbo.LabOrderItem oi
          JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = oi.InvestigationId
          JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0
          JOIN dbo.LabInvestigationMaster im ON im.Test_ID = d.Test_ID
         WHERE oi.IsActive = 1 AND oi.Type = 'P' AND im.Has_External_Document = 1
       ) x
 WHERE NOT (EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = x.LabOrderId AND sc.InvestigationID = x.Test_ID)
            AND NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = x.LabOrderId AND sc.InvestigationID = x.Test_ID
                                                                   AND ISNULL(sc.Iscancelled, 0) = 0));
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_ExternalDoc_SearchBookings
    @BranchId INT,
    @Date     DATE,
    @Mobile   NVARCHAR(20)  = NULL,
    @Name     NVARCHAR(100) = NULL,
    @BillNo   NVARCHAR(50)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Name   = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @BillNo = NULLIF(LTRIM(RTRIM(@BillNo)), N'');

    SELECT lo.LabOrderId, lo.BillNo, COALESCE(lo.OrderDate, lo.BookingDate) AS OrderDate,
           p.PatientCode,
           LTRIM(RTRIM(CONCAT(p.Salutation + N' ', p.FirstName, N' ', p.MiddleName + N' ', p.LastName))) AS PatientName,
           p.PhoneNumber AS Mobile,
           t.TestCount,
           (SELECT COUNT(DISTINCT ed.InvestigationId) FROM dbo.LabExternalDocument ed
             WHERE ed.LabOrderId = lo.LabOrderId AND ed.IsActive = 1) AS UploadedCount
      FROM dbo.LabOrder lo
      JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
      CROSS APPLY (SELECT COUNT(DISTINCT v.Test_ID) AS TestCount FROM dbo.vw_LabExternalDocTest v WHERE v.LabOrderId = lo.LabOrderId) t
     WHERE lo.IsActive = 1
       AND lo.BranchId = @BranchId
       AND CAST(COALESCE(lo.OrderDate, lo.BookingDate) AS DATE) = @Date
       AND t.TestCount > 0
       AND (@Mobile IS NULL OR p.PhoneNumber LIKE N'%' + @Mobile + N'%' OR p.SecondaryPhoneNumber LIKE N'%' + @Mobile + N'%')
       AND (@Name IS NULL OR CONCAT(p.FirstName, N' ', p.MiddleName + N' ', p.LastName) LIKE N'%' + @Name + N'%')
       AND (@BillNo IS NULL OR lo.BillNo LIKE N'%' + @BillNo + N'%')
     ORDER BY lo.LabOrderId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_ExternalDoc_GetTests
    @BranchId   INT,
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1. the booking (only an active booking of this branch)
    SELECT lo.LabOrderId, lo.BillNo, lo.BranchId, COALESCE(lo.OrderDate, lo.BookingDate) AS OrderDate, p.PatientCode,
           LTRIM(RTRIM(CONCAT(p.Salutation + N' ', p.FirstName, N' ', p.MiddleName + N' ', p.LastName))) AS PatientName,
           p.PhoneNumber AS Mobile
      FROM dbo.LabOrder lo JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
     WHERE lo.LabOrderId = @LabOrderId AND lo.BranchId = @BranchId AND lo.IsActive = 1;

    -- 2. its external-document tests with the current upload
    SELECT v.Test_ID, v.Test_Code, v.Test_Name, MIN(v.LabOrderItemId) AS LabOrderItemId,
           STRING_AGG(v.ViaName, N', ') AS ViaName,
           ed.DocumentId, ed.FileName, ed.FilePath, ed.OriginalFileName, ed.FileSizeBytes, ed.UpdatedDate,
           COALESCE(NULLIF(u.FullName, N''), u.Username) AS UpdatedByName,
           (SELECT COUNT(*) FROM dbo.LabExternalDocument h WHERE h.LabOrderId = @LabOrderId AND h.InvestigationId = v.Test_ID) AS UploadCount
      FROM dbo.vw_LabExternalDocTest v
      JOIN dbo.LabOrder lo ON lo.LabOrderId = v.LabOrderId AND lo.BranchId = @BranchId AND lo.IsActive = 1
      OUTER APPLY (SELECT TOP 1 * FROM dbo.LabExternalDocument d
                    WHERE d.LabOrderId = v.LabOrderId AND d.InvestigationId = v.Test_ID AND d.IsActive = 1
                    ORDER BY d.DocumentId DESC) ed
      LEFT JOIN dbo.Users u ON u.Id = ed.UpdatedBy
     WHERE v.LabOrderId = @LabOrderId
     GROUP BY v.Test_ID, v.Test_Code, v.Test_Name, ed.DocumentId, ed.FileName, ed.FilePath, ed.OriginalFileName,
              ed.FileSizeBytes, ed.UpdatedDate, u.FullName, u.Username
     ORDER BY v.Test_Name;
END
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
    @UserId           INT
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
    INSERT dbo.LabExternalDocument (CompanyId, BranchId, LabOrderId, InvestigationId, LabOrderItemId, OriginalFileName,
                                    FileName, FilePath, FileSizeBytes, ContentType, UpdatedBy, UpdatedDate)
    VALUES (@CompanyId, @BranchId, @LabOrderId, @InvestigationId, @LabOrderItemId, @OriginalFileName,
            @FileName, @FilePath, @FileSizeBytes, @ContentType, @UserId, GETDATE());
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS DocumentId;
    COMMIT;
END
GO

-- ── page and endpoints ──────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @lab INT, @page INT, @settings INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @lab = NULL; SET @settings = NULL;
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @lab IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.EXTERNALDOCUPLOAD', @Title = N'External Document Upload',
             @Controller = N'LabExternalDocuments', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 75, @Icon = N'bi bi-cloud-arrow-up-fill me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabExternalDocuments', @Action = N'Index',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabExternalDocuments', @Action = N'Bookings', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabExternalDocuments', @Action = N'Tests',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabExternalDocuments', @Action = N'Upload',   @Source = 'SEED';
    END

    SELECT @settings = Page_ID FROM dbo.PageMaster WHERE CompanyId = @co AND Page_Code = N'SETTINGS.HOSPITALSETTINGS';
    IF @settings IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'HospitalSettings', @Action = N'FtpSettings',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'SaveFtpSettings', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @settings, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'TestFtpSettings', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
