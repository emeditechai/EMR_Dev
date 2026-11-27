-- ============================================================================================================
-- 2561  LAB > B2C Order List > Reschedule Booking (application database)
--   A booked B2C order (Is Booking Req = Yes) can be moved to another date and time:
--     - only an active B2C bill with Is Booking Req = Yes,
--     - only up to its booking date (a booking whose day has passed cannot be moved),
--     - only to a future date / time, at most 90 days ahead, different from the current one, with a reason,
--     - not once every test has its result entered (Report Entry: Draft or later).
--   What moves: LabOrder.BookingDate and SampleCollection.Bookingdatetime (the B2C Order List and the Sample Collection
--   worklist both list by the booking date). The bill date / OrderDate does not change.
--   Moved to another day: a new token of that day (tokens are per booking day), unless a sample is already collected.
--   Home collection: the phlebotomist's open visit moves to the new time (as LAB > Home Collection Dispatch > Reschedule);
--   refused while the phlebotomist is at the patient (REACHED / IN_PROGRESS).
--   Every change is kept in dbo.LabOrderReschedule with what the patient was sent (WhatsApp / e-mail).
--   Patient message: notification event LAB_RESCHEDULE (WhatsApp + e-mail; Hindi / Bengali texts added).
--   Permission: new control RESCHEDULE on LAB.LABORDERBOOKING.B2CORDERLIST (no grant seeded: give it in Role Permissions).
--   Errors 56600-56619. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

-- ── history of every reschedule ──
IF OBJECT_ID('dbo.LabOrderReschedule', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabOrderReschedule
    (
        RescheduleId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabOrderReschedule PRIMARY KEY,
        LabOrderId      INT            NOT NULL,
        BranchId        INT            NOT NULL,
        OldBookingDate  DATETIME       NOT NULL,
        NewBookingDate  DATETIME       NOT NULL,
        OldTokenNo      NVARCHAR(50)   NULL,
        NewTokenNo      NVARCHAR(50)   NULL,
        HomeVisitId     INT            NULL,
        Reason          NVARCHAR(300)  NOT NULL,
        WhatsAppStatus  VARCHAR(20)    NULL,   -- SENT / FAILED / SKIPPED (null = not tried yet)
        EmailStatus     VARCHAR(20)    NULL,
        NotifyDetail    NVARCHAR(500)  NULL,
        CreatedBy       INT            NOT NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_LabOrderReschedule_CreatedDate DEFAULT (GETDATE())
    );
    CREATE INDEX IX_LabOrderReschedule_Order ON dbo.LabOrderReschedule (LabOrderId, RescheduleId DESC);
END
GO

-- ── can these orders be rescheduled? (the B2C Order List shows the menu item only when CanReschedule = 1) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrder_RescheduleInfo
    @LabOrderIds NVARCHAR(MAX),
    @BranchId    INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    DECLARE @ids TABLE (LabOrderId INT PRIMARY KEY);
    INSERT @ids (LabOrderId)
    SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(@LabOrderIds, ',') WHERE TRY_CAST(value AS INT) > 0;

    ;WITH t AS (   -- tests of the order and whether their result is entered (Draft or later)
        SELECT sc.Laborderid AS LabOrderId,
               COUNT(1) AS TotalTests,
               SUM(e.Entered) AS EnteredTests
          FROM dbo.SampleCollection sc
          JOIN @ids i ON i.LabOrderId = sc.Laborderid
         CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.labentrydetails led
                                                WHERE led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1 AND led.ReportStatusId >= 1)
                                  THEN 1 ELSE 0 END AS Entered) e
         WHERE ISNULL(sc.Is_Active, 1) = 1 AND ISNULL(sc.Iscancelled, 0) = 0
         GROUP BY sc.Laborderid
    ), v AS (      -- the phlebotomist's visit of a home collection (the first visit, not a re-collection)
        SELECT hv.LabOrderId, hv.VisitId, hv.Status,
               ROW_NUMBER() OVER (PARTITION BY hv.LabOrderId ORDER BY hv.VisitId DESC) AS rn
          FROM dbo.LabHomeVisit hv
          JOIN @ids i ON i.LabOrderId = hv.LabOrderId
         WHERE hv.ParentVisitId IS NULL
    ), r AS (
        SELECT lr.LabOrderId, COUNT(1) AS RescheduleCount, MAX(lr.CreatedDate) AS LastRescheduledAt
          FROM dbo.LabOrderReschedule lr
          JOIN @ids i ON i.LabOrderId = lr.LabOrderId
         GROUP BY lr.LabOrderId
    )
    SELECT o.LabOrderId,
           o.BookingDate,
           ISNULL(t.TotalTests, 0) AS TotalTests,
           ISNULL(t.EnteredTests, 0) AS EnteredTests,
           v.Status AS HomeVisitStatus,
           ISNULL(r.RescheduleCount, 0) AS RescheduleCount,
           r.LastRescheduledAt,
           CAST(CASE WHEN x.WhyNot IS NULL THEN 1 ELSE 0 END AS BIT) AS CanReschedule,
           x.WhyNot
      FROM dbo.LabOrder o
      JOIN @ids i ON i.LabOrderId = o.LabOrderId
      LEFT JOIN t ON t.LabOrderId = o.LabOrderId
      LEFT JOIN v ON v.LabOrderId = o.LabOrderId AND v.rn = 1
      LEFT JOIN r ON r.LabOrderId = o.LabOrderId
     CROSS APPLY (SELECT WhyNot = CASE
            WHEN ISNULL(o.IsB2B, 0) = 1                              THEN N'Only a B2C booking can be rescheduled here.'
            WHEN ISNULL(o.IsActive, 1) = 0                           THEN N'The bill is cancelled.'
            WHEN ISNULL(o.IsBookingRequired, 0) = 0 OR o.BookingDate IS NULL THEN N'The bill is not a booking (Is Booking Req = No).'
            WHEN CAST(o.BookingDate AS DATE) < @today                THEN N'The booking date has passed.'
            WHEN t.TotalTests > 0 AND t.EnteredTests >= t.TotalTests THEN N'The results of every test are entered.'
            WHEN v.Status IN ('REACHED', 'IN_PROGRESS')              THEN N'The phlebotomist is at the patient now.'
            END) x
     WHERE o.BranchId = @BranchId;
END
GO

-- ── reschedule one booking ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrder_Reschedule
    @LabOrderId         INT,
    @BranchId           INT,
    @UserId             INT,
    @NewBookingDate     DATETIME,
    @Reason             NVARCHAR(300),
    @ExpectedBookingDate DATETIME = NULL   -- the booking time the user saw: someone else's change in between is refused
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now DATETIME = GETDATE(), @today DATE = CAST(GETDATE() AS DATE);
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    SET @NewBookingDate = DATEADD(SECOND, -DATEPART(SECOND, @NewBookingDate), DATEADD(MILLISECOND, -DATEPART(MILLISECOND, @NewBookingDate), @NewBookingDate));

    IF @NewBookingDate IS NULL                         THROW 56605, 'Choose the new booking date and time.', 1;
    IF @NewBookingDate <= @now                         THROW 56605, 'The new booking date and time must be in the future.', 1;
    IF @NewBookingDate > DATEADD(DAY, 90, @now)        THROW 56607, 'A booking can be moved at most 90 days ahead.', 1;
    IF @Reason IS NULL                                 THROW 56608, 'Enter the reason for rescheduling.', 1;

    BEGIN TRANSACTION;

    DECLARE @old DATETIME, @isB2B BIT, @active BIT, @isBooking BIT, @token NVARCHAR(50), @collType NVARCHAR(50);
    SELECT @old = o.BookingDate, @isB2B = ISNULL(o.IsB2B, 0), @active = ISNULL(o.IsActive, 1), @isBooking = ISNULL(o.IsBookingRequired, 0),
           @token = o.TokenNo, @collType = o.CollectionType
      FROM dbo.LabOrder o WITH (UPDLOCK, HOLDLOCK)
     WHERE o.LabOrderId = @LabOrderId AND o.BranchId = @BranchId;

    IF @@ROWCOUNT = 0                                  THROW 56600, 'The bill was not found in this branch.', 1;
    IF @isB2B = 1                                      THROW 56601, 'Only a B2C booking can be rescheduled here.', 1;
    IF @active = 0                                     THROW 56602, 'The bill is cancelled: it cannot be rescheduled.', 1;
    IF @isBooking = 0 OR @old IS NULL                  THROW 56603, 'The bill is not a booking (Is Booking Req = No): it cannot be rescheduled.', 1;
    IF @ExpectedBookingDate IS NOT NULL AND ABS(DATEDIFF(SECOND, @ExpectedBookingDate, @old)) > 59
                                                       THROW 56611, 'The booking was changed by someone else just now. Reload the list and try again.', 1;
    IF CAST(@old AS DATE) < @today                     THROW 56604, 'The booking date has passed: a booking can be rescheduled only up to its booking date.', 1;
    IF DATEDIFF(MINUTE, @old, @NewBookingDate) = 0     THROW 56606, 'Choose a date or time different from the current booking.', 1;

    DECLARE @total INT, @entered INT, @collected INT;
    SELECT @total = COUNT(1),
           @entered = SUM(e.Entered),
           @collected = SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END)
      FROM dbo.SampleCollection sc
     CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.labentrydetails led
                                            WHERE led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1 AND led.ReportStatusId >= 1)
                              THEN 1 ELSE 0 END AS Entered) e
     WHERE sc.Laborderid = @LabOrderId AND ISNULL(sc.Is_Active, 1) = 1 AND ISNULL(sc.Iscancelled, 0) = 0;
    IF @total > 0 AND @entered >= @total               THROW 56609, 'The results of every test are entered: the booking cannot be rescheduled.', 1;

    -- home collection: the phlebotomist's open visit moves with the booking
    DECLARE @visit INT, @visitStatus VARCHAR(15);
    SELECT TOP 1 @visit = hv.VisitId, @visitStatus = hv.Status
      FROM dbo.LabHomeVisit hv WITH (UPDLOCK)
     WHERE hv.LabOrderId = @LabOrderId AND hv.ParentVisitId IS NULL
     ORDER BY hv.VisitId DESC;
    IF @visitStatus IN ('REACHED', 'IN_PROGRESS')      THROW 56610, 'The phlebotomist is at the patient now: the booking cannot be rescheduled.', 1;

    -- another day: a new token of that day (tokens are per booking day), unless a sample is already collected
    DECLARE @newToken NVARCHAR(50) = @token;
    IF @token IS NOT NULL AND CAST(@NewBookingDate AS DATE) <> CAST(@old AS DATE) AND ISNULL(@collected, 0) = 0
    BEGIN
        DECLARE @tokenDate DATE = CAST(@NewBookingDate AS DATE);
        EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @tokenDate, @newToken OUTPUT;
        IF @newToken IS NULL SET @newToken = @token;
    END

    UPDATE dbo.LabOrder
       SET BookingDate = @NewBookingDate, TokenNo = @newToken, ModifiedBy = @UserId, ModifiedDate = @now
     WHERE LabOrderId = @LabOrderId;

    UPDATE dbo.SampleCollection
       SET Bookingdatetime = @NewBookingDate,
           TokenNo = CASE WHEN @newToken IS NOT NULL THEN @newToken ELSE TokenNo END,
           ModifiedBy = @UserId, ModifiedDate = @now
     WHERE Laborderid = @LabOrderId;

    DECLARE @movedVisit INT = NULL;
    IF @visit IS NOT NULL AND @visitStatus IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'UNAVAILABLE', 'RESCHEDULED')
    BEGIN
        UPDATE dbo.LabHomeVisit
           SET SlotAt = @NewBookingDate, Status = 'ASSIGNED', OutcomeReason = NULL,
               OtpHash = NULL, OtpExpiresOn = NULL, OtpVerifiedOn = NULL, VerifyMethod = NULL, ConsentTaken = 0, ModifiedDate = @now
         WHERE VisitId = @visit;
        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy)
        VALUES (@visit, 'RESCHEDULED', CONCAT('WEB-', NEWID()), LEFT(N'Booking rescheduled: ' + @Reason, 300), @UserId);
        SET @movedVisit = @visit;
    END

    DECLARE @rid INT;
    INSERT dbo.LabOrderReschedule (LabOrderId, BranchId, OldBookingDate, NewBookingDate, OldTokenNo, NewTokenNo, HomeVisitId, Reason, CreatedBy)
    VALUES (@LabOrderId, @BranchId, @old, @NewBookingDate, @token, @newToken, @movedVisit, @Reason, @UserId);
    SET @rid = SCOPE_IDENTITY();

    COMMIT;

    -- what the screen and the patient message need
    SELECT @rid AS RescheduleId, o.LabOrderId, o.BillNo, o.BookingNo, o.TokenNo, @token AS OldTokenNo,
           @old AS OldBookingDate, o.BookingDate AS NewBookingDate, o.CollectionType, @movedVisit AS HomeVisitId,
           p.PatientId,
           LTRIM(RTRIM(REPLACE(CONCAT(ISNULL(p.Salutation, N''), N' ', ISNULL(p.FirstName, N''), N' ', ISNULL(p.MiddleName, N''), N' ', ISNULL(p.LastName, N'')), N'  ', N' '))) AS PatientName,
           p.PhoneNumber, p.EmailId,
           b.BranchName
      FROM dbo.LabOrder o
      JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
      LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
     WHERE o.LabOrderId = @LabOrderId;
END
GO

-- ── what the patient was sent ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrder_RescheduleNotified
    @RescheduleId   INT,
    @BranchId       INT,
    @WhatsAppStatus VARCHAR(20) = NULL,
    @EmailStatus    VARCHAR(20) = NULL,
    @Detail         NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LabOrderReschedule
       SET WhatsAppStatus = @WhatsAppStatus, EmailStatus = @EmailStatus, NotifyDetail = LEFT(@Detail, 500)
     WHERE RescheduleId = @RescheduleId AND BranchId = @BranchId;
END
GO

-- ── reschedule history of one order (the Reschedule dialog) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrder_RescheduleHistory
    @LabOrderId INT,
    @BranchId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lr.RescheduleId, lr.OldBookingDate, lr.NewBookingDate, lr.OldTokenNo, lr.NewTokenNo, lr.Reason,
           lr.WhatsAppStatus, lr.EmailStatus, lr.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS CreatedByName
      FROM dbo.LabOrderReschedule lr
      LEFT JOIN dbo.Users u ON u.Id = lr.CreatedBy
     WHERE lr.LabOrderId = @LabOrderId AND lr.BranchId = @BranchId
     ORDER BY lr.RescheduleId DESC;
END
GO

-- ── patient message: LAB_RESCHEDULE (English reference + Hindi / Bengali) ──
MERGE dbo.NotifyEvent AS t
USING (VALUES
 ('LAB_RESCHEDULE', 'LAB', N'LAB booking rescheduled', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{BillNo},{BookingNo},{OldDateTime},{NewDateTime},{TokenNo},{CollectionType},{Reason}',
  N'Sent to the patient when a B2C LAB booking is moved to another date / time (B2C Order List > Reschedule Booking): WhatsApp and e-mail.', 26,
  N'Dear {PatientName}, your lab booking{#BookingNo} {BookingNo}{/BookingNo} (bill {BillNo}) at {HospitalName} has been rescheduled from {OldDateTime} to *{NewDateTime}* ({CollectionType}).{#TokenNo} Your token is {TokenNo}.{/TokenNo} Please contact us if this time does not suit you.',
  N'Your lab booking is rescheduled to {NewDateTime} - {HospitalName}', N'Lab booking rescheduled',
  N'Dear {PatientName},

Your lab booking{#BookingNo} {BookingNo}{/BookingNo} (bill {BillNo}) has been rescheduled.

Earlier: {OldDateTime}
New date and time: {NewDateTime}
Collection: {CollectionType}{#TokenNo}
Token: {TokenNo}{/TokenNo}

Please contact us if this time does not suit you.')
) s (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, Name = s.Name, Channels = s.Channels, Placeholders = s.Placeholders, Description = s.Description, SortOrder = s.SortOrder,
    RefWhatsApp = s.RefWhatsApp, RefEmailSubject = s.RefEmailSubject, RefEmailHeading = s.RefEmailHeading, RefEmailBody = s.RefEmailBody, IsActive = 1
WHEN NOT MATCHED THEN INSERT (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
    VALUES (s.EventCode, s.Module, s.Name, s.Channels, s.Placeholders, s.Description, s.SortOrder, s.RefWhatsApp, s.RefEmailSubject, s.RefEmailHeading, s.RefEmailBody);
GO

DECLARE @t TABLE (EventCode VARCHAR(40), Channel VARCHAR(10), Lang VARCHAR(10), Subject NVARCHAR(300), Heading NVARCHAR(200), Body NVARCHAR(MAX));
INSERT @t VALUES
 ('LAB_RESCHEDULE', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, {HospitalName} में आपकी लैब बुकिंग{#BookingNo} {BookingNo}{/BookingNo} (बिल {BillNo}) {OldDateTime} से बदलकर *{NewDateTime}* ({CollectionType}) कर दी गई है।{#TokenNo} आपका टोकन {TokenNo} है।{/TokenNo} यदि यह समय आपके लिए उपयुक्त नहीं है तो कृपया हमसे संपर्क करें।'),
 ('LAB_RESCHEDULE', 'EMAIL', 'hi', N'आपकी लैब बुकिंग {NewDateTime} पर बदल दी गई है - {HospitalName}', N'लैब बुकिंग का समय बदला गया', N'प्रिय {PatientName},

आपकी लैब बुकिंग{#BookingNo} {BookingNo}{/BookingNo} (बिल {BillNo}) का समय बदल दिया गया है।

पहले: {OldDateTime}
नई तारीख और समय: {NewDateTime}
कलेक्शन: {CollectionType}{#TokenNo}
टोकन: {TokenNo}{/TokenNo}

यदि यह समय आपके लिए उपयुक्त नहीं है तो कृपया हमसे संपर्क करें।'),
 ('LAB_RESCHEDULE', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, {HospitalName}-এ আপনার ল্যাব বুকিং{#BookingNo} {BookingNo}{/BookingNo} (বিল {BillNo}) {OldDateTime} থেকে পরিবর্তন করে *{NewDateTime}* ({CollectionType}) করা হয়েছে।{#TokenNo} আপনার টোকেন {TokenNo}।{/TokenNo} এই সময় আপনার সুবিধাজনক না হলে অনুগ্রহ করে আমাদের সাথে যোগাযোগ করুন।'),
 ('LAB_RESCHEDULE', 'EMAIL', 'bn', N'আপনার ল্যাব বুকিং {NewDateTime}-এ পরিবর্তন করা হয়েছে - {HospitalName}', N'ল্যাব বুকিংয়ের সময় পরিবর্তন', N'প্রিয় {PatientName},

আপনার ল্যাব বুকিং{#BookingNo} {BookingNo}{/BookingNo} (বিল {BillNo})-এর সময় পরিবর্তন করা হয়েছে।

আগে: {OldDateTime}
নতুন তারিখ ও সময়: {NewDateTime}
কালেকশন: {CollectionType}{#TokenNo}
টোকেন: {TokenNo}{/TokenNo}

এই সময় আপনার সুবিধাজনক না হলে অনুগ্রহ করে আমাদের সাথে যোগাযোগ করুন।');
INSERT dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId, Subject, Heading, Body)
SELECT c.CompanyId, NULL, x.EventCode, x.Channel, l.LanguageId, x.Subject, x.Heading, x.Body
FROM @t x JOIN dbo.LanguageMaster l ON l.LanguageCode = x.Lang CROSS JOIN dbo.CompanyMaster c
WHERE c.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM dbo.NotifyTemplate n WHERE n.CompanyId = c.CompanyId AND n.BranchId IS NULL AND n.EventCode = x.EventCode
                                     AND n.Channel = x.Channel AND n.LanguageId = l.LanguageId);
GO

-- ── permission: RESCHEDULE on the B2C Order List; the dialog's history read is part of it ──
DECLARE @page INT = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = 'LAB.LABORDERBOOKING.B2CORDERLIST'), @ctl INT;
IF @page IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'RESCHEDULE', @Title = N'Reschedule a booking', @Sort_Order = 70, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'RescheduleBookingInfo', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'RescheduleBooking', @Source = 'SEED';
END
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2561 applied: LAB B2C Order List - Reschedule Booking.';
GO
