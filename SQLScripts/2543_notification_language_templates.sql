-- ============================================================================================================
-- Migration: 2543_notification_language_templates.sql   (UTF-8 with BOM: Hindi / Bengali text - run as Unicode)
-- Patient notifications in the patient's language (PatientMaster.LanguageId: English / Hindi / Bengali ...).
--   * NotifyEvent: the notifications that can be translated (first: LAB_BILL - the LAB B2C bill on WhatsApp / e-mail),
--     with their placeholders.
--   * NotifyTemplate: the text of an event for a channel (WHATSAPP / EMAIL) and a language; company default
--     (BranchId NULL) or a branch's own. Settings > Notification Languages (SETTINGS.NOTIFYTEMPLATES).
--   * At send time the patient's language picks the template (branch first, then company). No template for the
--     language -> the message goes exactly as before (WhatsApp Configuration's LAB template / the built-in English
--     e-mail), so English patients see no change. An English template, if one is added, replaces the English text.
--   * Seeded: Hindi and Bengali LAB_BILL for WhatsApp and e-mail - the same message as the current English one,
--     sentence by sentence (edit the wording on the page).
--   * LanguageMaster.LanguageCode (ISO 639-1: en, hi, bn).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LanguageMaster', 'LanguageCode') IS NULL
    ALTER TABLE dbo.LanguageMaster ADD LanguageCode VARCHAR(10) NULL;
GO
UPDATE dbo.LanguageMaster SET LanguageCode = CASE LanguageName WHEN 'English' THEN 'en' WHEN 'Hindi' THEN 'hi' WHEN 'Bengali' THEN 'bn' END
WHERE LanguageCode IS NULL AND LanguageName IN ('English', 'Hindi', 'Bengali');
GO

IF OBJECT_ID('dbo.NotifyEvent', 'U') IS NULL
CREATE TABLE dbo.NotifyEvent (
    EventCode    VARCHAR(40) NOT NULL CONSTRAINT PK_NotifyEvent PRIMARY KEY,
    Module       VARCHAR(20) NOT NULL,
    Name         NVARCHAR(150) NOT NULL,
    Channels     VARCHAR(40) NOT NULL,            -- WHATSAPP,EMAIL
    Placeholders NVARCHAR(400) NOT NULL,          -- {PatientName},{HospitalName} ...
    Description  NVARCHAR(400) NULL,
    SortOrder    INT NOT NULL CONSTRAINT DF_NotifyEvent_Sort DEFAULT (100),
    IsActive     BIT NOT NULL CONSTRAINT DF_NotifyEvent_Active DEFAULT (1)
);
GO
MERGE dbo.NotifyEvent AS t
USING (VALUES ('LAB_BILL', 'LAB', N'LAB bill (B2C)', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{BillNo},{TokenNo},{Amount},{BillDate},{HospitalAddress}',
               N'Sent to the patient when a LAB B2C bill is made: WhatsApp with the bill PDF, e-mail with the bill PDF.', 10))
      s (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, Name = s.Name, Channels = s.Channels, Placeholders = s.Placeholders, Description = s.Description, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder) VALUES (s.EventCode, s.Module, s.Name, s.Channels, s.Placeholders, s.Description, s.SortOrder);
GO

IF OBJECT_ID('dbo.NotifyTemplate', 'U') IS NULL
CREATE TABLE dbo.NotifyTemplate (
    TemplateId   INT IDENTITY(1,1) CONSTRAINT PK_NotifyTemplate PRIMARY KEY,
    CompanyId    INT NOT NULL,
    BranchId     INT NULL,                        -- NULL = every branch of the company
    EventCode    VARCHAR(40) NOT NULL CONSTRAINT FK_NotifyTemplate_Event REFERENCES dbo.NotifyEvent (EventCode),
    Channel      VARCHAR(10) NOT NULL,            -- WHATSAPP | EMAIL
    LanguageId   INT NOT NULL CONSTRAINT FK_NotifyTemplate_Lang REFERENCES dbo.LanguageMaster (LanguageId),
    Subject      NVARCHAR(300) NULL,              -- e-mail subject
    Heading      NVARCHAR(200) NULL,              -- e-mail heading (top of the mail)
    Body         NVARCHAR(MAX) NOT NULL,          -- WhatsApp text / e-mail text (paragraphs separated by a blank line)
    IsActive     BIT NOT NULL CONSTRAINT DF_NotifyTemplate_Active DEFAULT (1),
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_NotifyTemplate_Created DEFAULT (GETDATE()),
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT CK_NotifyTemplate_Channel CHECK (Channel IN ('WHATSAPP', 'EMAIL'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_NotifyTemplate_Company' AND object_id = OBJECT_ID('dbo.NotifyTemplate'))
    CREATE UNIQUE INDEX UX_NotifyTemplate_Company ON dbo.NotifyTemplate (CompanyId, EventCode, Channel, LanguageId) WHERE BranchId IS NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_NotifyTemplate_Branch' AND object_id = OBJECT_ID('dbo.NotifyTemplate'))
    CREATE UNIQUE INDEX UX_NotifyTemplate_Branch ON dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId) WHERE BranchId IS NOT NULL;
GO

-- ── seed: LAB_BILL in Hindi and Bengali (same message as the current English one), for every active company ──────
DECLARE @hi INT = (SELECT TOP 1 LanguageId FROM dbo.LanguageMaster WHERE LanguageCode = 'hi'),
        @bn INT = (SELECT TOP 1 LanguageId FROM dbo.LanguageMaster WHERE LanguageCode = 'bn');
DECLARE @seed TABLE (LanguageId INT, Channel VARCHAR(10), Subject NVARCHAR(300), Heading NVARCHAR(200), Body NVARCHAR(MAX));
-- English (for reference, not seeded - it stays as today):
--   WhatsApp: Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered.
--             Token: {TokenNo}. Please find your bill attached. Thank you!
--   E-mail:   "Your Lab Order Bill [{BillNo}] - {HospitalName}" / Your lab bill / Dear .., Thank you for choosing .. for your healthcare needs.
--             Bill No / Date. Please find your detailed lab order bill attached .. as a PDF document. If you have any questions ..
--             Wishing you the best of health, The .. Team
IF @hi IS NOT NULL
INSERT @seed VALUES
 (@hi, 'WHATSAPP', NULL, NULL,
  N'प्रिय {PatientName}, {HospitalName} चुनने के लिए धन्यवाद। आपका लैब ऑर्डर {BillNo}, राशि रु. {Amount}, दर्ज कर लिया गया है। टोकन: {TokenNo}। कृपया संलग्न बिल देखें। धन्यवाद!'),
 (@hi, 'EMAIL', N'आपका लैब ऑर्डर बिल [{BillNo}] - {HospitalName}', N'आपका लैब बिल',
  N'प्रिय {PatientName},

अपनी स्वास्थ्य देखभाल के लिए {HospitalName} को चुनने के लिए धन्यवाद।

बिल नंबर: {BillNo}
दिनांक: {BillDate}

आपके लैब ऑर्डर का विस्तृत बिल इस ईमेल के साथ PDF दस्तावेज़ के रूप में संलग्न है।

यदि आपका कोई प्रश्न हो या आपको किसी सहायता की आवश्यकता हो, तो कृपया बेझिझक हमसे संपर्क करें।

आपके उत्तम स्वास्थ्य की शुभकामनाओं सहित,
{HospitalName} टीम');
IF @bn IS NOT NULL
INSERT @seed VALUES
 (@bn, 'WHATSAPP', NULL, NULL,
  N'প্রিয় {PatientName}, {HospitalName} বেছে নেওয়ার জন্য ধন্যবাদ। আপনার ল্যাব অর্ডার {BillNo}, মোট টাকা {Amount}, নথিভুক্ত করা হয়েছে। টোকেন: {TokenNo}। অনুগ্রহ করে সংযুক্ত বিলটি দেখুন। ধন্যবাদ!'),
 (@bn, 'EMAIL', N'আপনার ল্যাব অর্ডারের বিল [{BillNo}] - {HospitalName}', N'আপনার ল্যাব বিল',
  N'প্রিয় {PatientName},

আপনার স্বাস্থ্যসেবার প্রয়োজনে {HospitalName} বেছে নেওয়ার জন্য ধন্যবাদ।

বিল নম্বর: {BillNo}
তারিখ: {BillDate}

আপনার ল্যাব অর্ডারের বিস্তারিত বিল এই ইমেলের সাথে PDF নথি হিসেবে সংযুক্ত করা হয়েছে।

আপনার কোনো প্রশ্ন থাকলে বা কোনো সহায়তার প্রয়োজন হলে, অনুগ্রহ করে নির্দ্বিধায় আমাদের সাথে যোগাযোগ করুন।

আপনার সুস্বাস্থ্য কামনা করি,
{HospitalName} টিম');
INSERT dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId, Subject, Heading, Body)
SELECT c.CompanyId, NULL, 'LAB_BILL', s.Channel, s.LanguageId, s.Subject, s.Heading, s.Body
FROM dbo.CompanyMaster c CROSS JOIN @seed s
WHERE c.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.NotifyTemplate t WHERE t.CompanyId = c.CompanyId AND t.BranchId IS NULL AND t.EventCode = 'LAB_BILL' AND t.Channel = s.Channel AND t.LanguageId = s.LanguageId);
GO

-- ── the template for a patient's language (the branch's own first, then the company's); no row = send as before ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_NotifyTemplate_Resolve
    @CompanyId INT, @BranchId INT, @EventCode VARCHAR(40), @Channel VARCHAR(10), @LanguageId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 t.TemplateId, t.Subject, t.Heading, t.Body, l.LanguageName, l.LanguageCode, t.BranchId
    FROM dbo.NotifyTemplate t
    JOIN dbo.NotifyEvent e ON e.EventCode = t.EventCode AND e.IsActive = 1
    JOIN dbo.LanguageMaster l ON l.LanguageId = t.LanguageId AND l.IsActive = 1
    WHERE t.CompanyId = @CompanyId AND t.EventCode = @EventCode AND t.Channel = @Channel AND t.LanguageId = @LanguageId AND t.IsActive = 1
      AND (t.BranchId = @BranchId OR t.BranchId IS NULL)
    ORDER BY CASE WHEN t.BranchId = @BranchId THEN 0 ELSE 1 END;
END
GO

-- ── Settings > Notification Languages ──────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_NotifyTemplate_Lookups @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT EventCode, Module, Name, Channels, Placeholders, Description FROM dbo.NotifyEvent WHERE IsActive = 1 ORDER BY SortOrder, Name;
    SELECT LanguageId, LanguageName, LanguageCode FROM dbo.LanguageMaster WHERE IsActive = 1 ORDER BY CASE WHEN LanguageCode = 'en' THEN 0 ELSE 1 END, LanguageName;
    SELECT BranchID AS BranchId, BranchName FROM dbo.BranchMaster WHERE CompanyId = @CompanyId AND ISNULL(IsActive, 1) = 1 ORDER BY BranchName;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_NotifyTemplate_List @CompanyId INT, @EventCode VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.TemplateId, t.BranchId, b.BranchName, t.EventCode, e.Name AS EventName, t.Channel, t.LanguageId, l.LanguageName, l.LanguageCode,
           t.Subject, t.Heading, t.Body, t.IsActive, t.ModifiedDate, t.CreatedDate, ISNULL(um.FullName, uc.FullName) AS ChangedByName
    FROM dbo.NotifyTemplate t
    JOIN dbo.NotifyEvent e ON e.EventCode = t.EventCode
    JOIN dbo.LanguageMaster l ON l.LanguageId = t.LanguageId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = t.BranchId
    LEFT JOIN dbo.Users uc ON uc.Id = t.CreatedBy LEFT JOIN dbo.Users um ON um.Id = t.ModifiedBy
    WHERE t.CompanyId = @CompanyId AND (@EventCode IS NULL OR t.EventCode = @EventCode)
    ORDER BY e.SortOrder, t.EventCode, CASE WHEN t.BranchId IS NULL THEN 0 ELSE 1 END, b.BranchName, l.LanguageName, t.Channel DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_NotifyTemplate_Save
    @CompanyId INT, @UserId INT, @TemplateId INT = NULL, @BranchId INT = NULL, @EventCode VARCHAR(40), @Channel VARCHAR(10), @LanguageId INT,
    @Subject NVARCHAR(300) = NULL, @Heading NVARCHAR(200) = NULL, @Body NVARCHAR(MAX), @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Channel = UPPER(LTRIM(RTRIM(@Channel))); SET @Subject = NULLIF(LTRIM(RTRIM(@Subject)), N''); SET @Heading = NULLIF(LTRIM(RTRIM(@Heading)), N'');
    SET @Body = NULLIF(LTRIM(RTRIM(@Body)), N''); IF @BranchId = 0 SET @BranchId = NULL;
    DECLARE @channels VARCHAR(40) = (SELECT Channels FROM dbo.NotifyEvent WHERE EventCode = @EventCode AND IsActive = 1);
    IF @channels IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose the notification.' AS Error; RETURN; END;
    IF CHARINDEX(@Channel, @channels) = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'This notification is not sent on that channel.' AS Error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.LanguageMaster WHERE LanguageId = @LanguageId AND IsActive = 1) BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose the language.' AS Error; RETURN; END;
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.BranchMaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The branch is not of this company.' AS Error; RETURN; END;
    IF @Body IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the message.' AS Error; RETURN; END;
    IF @Channel = 'EMAIL' AND @Subject IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the e-mail subject.' AS Error; RETURN; END;
    IF @Channel = 'WHATSAPP' AND LEN(@Body) > 1000 BEGIN SELECT CAST(0 AS BIT) AS Success, N'A WhatsApp message can have at most 1000 characters.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM dbo.NotifyTemplate WHERE CompanyId = @CompanyId AND ISNULL(BranchId, 0) = ISNULL(@BranchId, 0) AND EventCode = @EventCode
               AND Channel = @Channel AND LanguageId = @LanguageId AND TemplateId <> ISNULL(@TemplateId, 0))
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'There is already a template for this notification, channel, language and branch: edit that one.' AS Error; RETURN; END;
    IF ISNULL(@TemplateId, 0) = 0
    BEGIN
        INSERT dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId, Subject, Heading, Body, IsActive, CreatedBy)
        VALUES (@CompanyId, @BranchId, @EventCode, @Channel, @LanguageId, CASE WHEN @Channel = 'EMAIL' THEN @Subject END, CASE WHEN @Channel = 'EMAIL' THEN @Heading END,
                @Body, ISNULL(@IsActive, 1), @UserId);
        SET @TemplateId = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.NotifyTemplate WHERE TemplateId = @TemplateId AND CompanyId = @CompanyId)
        BEGIN SELECT CAST(0 AS BIT) AS Success, N'The template was not found.' AS Error; RETURN; END;
        UPDATE dbo.NotifyTemplate SET BranchId = @BranchId, EventCode = @EventCode, Channel = @Channel, LanguageId = @LanguageId,
               Subject = CASE WHEN @Channel = 'EMAIL' THEN @Subject END, Heading = CASE WHEN @Channel = 'EMAIL' THEN @Heading END, Body = @Body,
               IsActive = ISNULL(@IsActive, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE TemplateId = @TemplateId;
    END
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @TemplateId AS TemplateId;
END
GO

-- ── page Settings > Notification Languages (no grants) ────────────────────────────────────────────────────────────
DECLARE @nav INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'SETTINGS' AND CompanyId = 1), @page INT, @view INT, @ctl INT, @a NVARCHAR(60);
IF @nav IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = 1, @Menu_ID = @nav, @Page_Code = N'SETTINGS.NOTIFYTEMPLATES', @Title = N'Notification Languages', @Controller = N'NotifyTemplates',
         @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 85, @Icon = N'bi bi-translate me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Index,Data', ',');
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'NotifyTemplates', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
    CLOSE v; DEALLOCATE v;
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Add / edit notification texts', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'NotifyTemplates', @Action = N'Save', @Source = 'SEED';
END
GO

PRINT 'Script 2543 applied: notification texts per language (LAB B2C bill: Hindi, Bengali).';
GO
