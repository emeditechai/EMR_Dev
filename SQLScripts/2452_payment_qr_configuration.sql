-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2452  Settings > Payment QR Configuration  +  Hospital Settings (OPD tab) "Show QR on B2B Invoice"
--   PaymentQrConfig: one UPI QR setup per branch - UPI ID (VPA), payee name, optional merchant category code, whether the
--   QR carries the amount due (DUE) or the payer types it (OPEN), whether the invoice no goes in the UPI note, a caption.
--   The QR is a standard UPI payment QR (upi://pay?...) that any UPI app scans; it is drawn by the web (QRCoder).
--   HospitalSettings.ShowQrOnB2BInvoice (per branch, default 0): Yes = the B2B tax invoice (LAB > B2B Invoices > View)
--   shows the QR in its payment block while a balance is due and the branch has an active QR setup; No = as before.
--   Page SETTINGS.PAYMENTQR (VIEW, EDIT, STATUS). No role grants. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'ShowQrOnB2BInvoice') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD ShowQrOnB2BInvoice BIT NOT NULL CONSTRAINT DF_HospitalSettings_ShowQrOnB2BInvoice DEFAULT (0);
GO
IF OBJECT_ID('dbo.PaymentQrConfig') IS NULL
CREATE TABLE dbo.PaymentQrConfig (
    ConfigId       INT IDENTITY(1,1) CONSTRAINT PK_PaymentQrConfig PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    UpiId          VARCHAR(100) NOT NULL,
    PayeeName      NVARCHAR(60) NOT NULL,
    MerchantCode   VARCHAR(4) NULL,
    AmountMode     VARCHAR(4) NOT NULL CONSTRAINT DF_PaymentQrConfig_Mode DEFAULT ('DUE') CONSTRAINT CK_PaymentQrConfig_Mode CHECK (AmountMode IN ('DUE','OPEN')),
    IncludeReference BIT NOT NULL CONSTRAINT DF_PaymentQrConfig_Ref DEFAULT (1),
    Caption        NVARCHAR(120) NULL,
    IsActive       BIT NOT NULL CONSTRAINT DF_PaymentQrConfig_Active DEFAULT (1),
    CreatedBy      INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_PaymentQrConfig_Created DEFAULT (GETDATE()),
    ModifiedBy     INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UX_PaymentQrConfig_Branch UNIQUE (BranchId)
);
GO

-- the branches of the company with their QR setup (list page)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PaymentQr_List @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchID AS BranchId, b.BranchName, b.BranchCode, c.ConfigId, c.UpiId, c.PayeeName, c.MerchantCode, c.AmountMode, c.IncludeReference, c.Caption,
           ISNULL(c.IsActive, 0) AS IsActive, ISNULL(h.ShowQrOnB2BInvoice, 0) AS ShowQrOnB2BInvoice,
           ISNULL(c.ModifiedDate, c.CreatedDate) AS LastChanged, ISNULL(um.FullName, uc.FullName) AS LastChangedBy
    FROM dbo.Branchmaster b
    LEFT JOIN dbo.PaymentQrConfig c ON c.BranchId = b.BranchID
    LEFT JOIN dbo.Users uc ON uc.Id = c.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = c.ModifiedBy
    OUTER APPLY (SELECT TOP 1 hs.ShowQrOnB2BInvoice FROM dbo.HospitalSettings hs WHERE hs.BranchId = b.BranchID AND hs.IsActive = 1) h
    WHERE b.CompanyId = @CompanyId AND b.IsActive = 1
    ORDER BY b.BranchName;
END;
GO

-- one branch's setup (also used by the B2B invoice): RS1 config (no row = none), with the branch's invoice switch
CREATE OR ALTER PROCEDURE dbo.usp_Api_PaymentQr_Get @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.ConfigId, c.BranchId, b.BranchName, c.UpiId, c.PayeeName, c.MerchantCode, c.AmountMode, c.IncludeReference, c.Caption, c.IsActive,
           ISNULL(h.ShowQrOnB2BInvoice, 0) AS ShowQrOnB2BInvoice
    FROM dbo.PaymentQrConfig c
    JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    OUTER APPLY (SELECT TOP 1 hs.ShowQrOnB2BInvoice FROM dbo.HospitalSettings hs WHERE hs.BranchId = c.BranchId AND hs.IsActive = 1) h
    WHERE c.BranchId = @BranchId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PaymentQr_Save
    @CompanyId INT, @UserId INT, @BranchId INT, @UpiId VARCHAR(300), @PayeeName NVARCHAR(200), @MerchantCode VARCHAR(20) = NULL,
    @AmountMode VARCHAR(10) = 'DUE', @IncludeReference BIT = 1, @Caption NVARCHAR(400) = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SET @UpiId = LOWER(LTRIM(RTRIM(ISNULL(@UpiId, ''))));
        SET @PayeeName = LTRIM(RTRIM(ISNULL(@PayeeName, N'')));
        SET @MerchantCode = NULLIF(LTRIM(RTRIM(@MerchantCode)), '');
        SET @AmountMode = UPPER(LTRIM(RTRIM(ISNULL(@AmountMode, 'DUE'))));
        SET @Caption = NULLIF(LTRIM(RTRIM(@Caption)), N'');
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId) THROW 56301, 'Choose a branch of your company.', 1;
        -- UPI ID: handle@psp - handle 2-256 of letters, digits, . - _ ; psp 2-64 letters (NPCI VPA format)
        IF LEN(@UpiId) < 5 OR @UpiId NOT LIKE '%_@_%' OR @UpiId LIKE '%@%@%' OR @UpiId LIKE '% %'
           OR LEFT(@UpiId, CHARINDEX('@', @UpiId) - 1) LIKE '%[^a-z0-9._-]%' OR SUBSTRING(@UpiId, CHARINDEX('@', @UpiId) + 1, 100) LIKE '%[^a-z]%'
           OR LEN(SUBSTRING(@UpiId, CHARINDEX('@', @UpiId) + 1, 100)) < 2
            THROW 56302, 'Enter a valid UPI ID, e.g. clinicname@okhdfcbank or 9876543210@ybl.', 1;
        IF LEN(@UpiId) > 100 THROW 56308, 'The UPI ID can have up to 100 characters.', 1;
        IF LEN(@PayeeName) > 60 THROW 56309, 'The payee name can have up to 60 characters.', 1;
        IF LEN(@PayeeName) < 2 THROW 56303, 'Enter the payee name (the account holder name the UPI ID belongs to).', 1;
        IF @PayeeName LIKE N'%[&=?#%]%' THROW 56304, 'The payee name cannot contain & = ? # or %.', 1;
        IF @MerchantCode IS NOT NULL AND (LEN(@MerchantCode) <> 4 OR @MerchantCode LIKE '%[^0-9]%') THROW 56305, 'The merchant category code is 4 digits (e.g. 8071 for medical laboratories), or leave it empty.', 1;
        IF @AmountMode NOT IN ('DUE','OPEN') THROW 56306, 'Choose whether the QR carries the amount due.', 1;
        IF @Caption IS NOT NULL AND LEN(@Caption) > 120 THROW 56307, 'The caption can have up to 120 characters.', 1;
        IF EXISTS (SELECT 1 FROM dbo.PaymentQrConfig WHERE BranchId = @BranchId)
            UPDATE dbo.PaymentQrConfig SET UpiId = @UpiId, PayeeName = @PayeeName, MerchantCode = @MerchantCode, AmountMode = @AmountMode,
                   IncludeReference = ISNULL(@IncludeReference, 1), Caption = @Caption, IsActive = ISNULL(@IsActive, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE BranchId = @BranchId;
        ELSE
            INSERT dbo.PaymentQrConfig (CompanyId, BranchId, UpiId, PayeeName, MerchantCode, AmountMode, IncludeReference, Caption, IsActive, CreatedBy)
            VALUES (@CompanyId, @BranchId, @UpiId, @PayeeName, @MerchantCode, @AmountMode, ISNULL(@IncludeReference, 1), @Caption, ISNULL(@IsActive, 1), @UserId);
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, (SELECT ConfigId FROM dbo.PaymentQrConfig WHERE BranchId = @BranchId) AS ConfigId;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, N'This branch already has a QR setup. Reload the page.' AS Error, NULL AS ConfigId;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error, NULL AS ConfigId; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PaymentQr_SetStatus @CompanyId INT, @UserId INT, @BranchId INT, @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    FROM dbo.PaymentQrConfig c JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId AND b.CompanyId = @CompanyId
    WHERE c.BranchId = @BranchId;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, N'This branch has no QR setup yet.' AS Error, NULL AS ConfigId;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, (SELECT ConfigId FROM dbo.PaymentQrConfig WHERE BranchId = @BranchId) AS ConfigId;
END;
GO

-- ── page Settings > Payment QR Configuration ───────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'SETTINGS'), @page INT, @view INT, @ctl INT;
IF @menu IS NULL THROW 51520, 'Menu SETTINGS is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'SETTINGS.PAYMENTQR', @Title = N'Payment QR Configuration',
     @Controller = N'PaymentQrConfig', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 85, @Icon = N'bi bi-qr-code me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page and preview QR', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PaymentQrConfig', @Action = N'Index', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PaymentQrConfig', @Action = N'ListData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PaymentQrConfig', @Action = N'Preview', @Source = 'SEED';
DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Act NVARCHAR(60));
INSERT @c VALUES ('EDIT', N'Set up / change a branch QR', 20, N'Save'), ('STATUS', N'Turn a branch QR on / off', 30, N'SetStatus');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Act FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @cc;
    IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PaymentQrConfig', @Action = @ca, @Source = 'SEED';
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2452 Payment QR configuration - done.';
GO
