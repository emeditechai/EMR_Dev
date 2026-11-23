-- ============================================================================================================
-- Migration: 2528_notification_areas_doctor_roster.sql   (application database; needs 2397)
-- Settings > Audit Notification Setup becomes a set of AREAS (dbo.AuditNotifyArea), each with its own events - a new area
-- is rows here, no page change:
--   AUDIT       Audit alerts (the 2397 events: bill cancelled, refund, report un-authorised)
--   OPD_ROSTER  OPD Doctor Roster Notification:
--     OPD_ROSTER_DAILY : every day at the branch's send time, each doctor with a session today (Doctor Schedule, not on
--                        leave) gets the day's roster - sessions, slots, capacity, booked so far, room - by WhatsApp and
--                        e-mail (Doctor Master mobile / e-mail); the same message goes to the users chosen for the event.
--                        When a doctor's room is assigned / changed / removed (OPD > Room Doctor Assignment), the same
--                        roster message of that doctor goes again, with a line saying the room changed. When the doctor's
--                        roster changes (Doctor Schedule: a session added / changed / deactivated, a leave added / removed),
--                        the doctor and the users get what changed with the doctor's weekly roster and coming leave.
-- Each event may now say: its channels (WhatsApp / e-mail), whether the doctor is told too, the daily send time.
--   AuditNotifyArea, AuditNotifyEvent (+ AreaCode, SupportsEmail, SupportsDoctor, IsDaily),
--   AuditNotifyEventSetting (+ SendWhatsApp, SendEmail, NotifyDoctor, SendTime), AuditNotifyLog (+ Channel, RecipientName),
--   AuditNotifyDailyRun (a daily event claimed once per branch and day).
--   Procedures: usp_AuditNotify_GetSetup / SaveEvent / GetRecipients / RecentLog (extended), usp_AuditNotify_EventSetting,
--   usp_AuditNotify_DailyDue (claims the branches due now), usp_AuditNotify_ClaimDaily (Send now), usp_AuditNotify_DoctorRoster,
--   usp_AuditNotify_DoctorRoom, usp_AuditNotify_DoctorWeekly, usp_AuditNotify_RosterItem, usp_AuditNotify_Log (+ channel / name).
-- Endpoint AuditNotificationSetup/SendNow (EDIT). Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.AuditNotifyEvent', 'U') IS NULL
BEGIN
    RAISERROR('Script 2528 needs script 2397 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ── areas ──────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.AuditNotifyArea', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyArea
(
    AreaCode    VARCHAR(30)   NOT NULL CONSTRAINT PK_AuditNotifyArea PRIMARY KEY,
    Title       NVARCHAR(100) NOT NULL,
    Description NVARCHAR(400) NULL,
    Icon        VARCHAR(60)   NULL,
    SortOrder   INT           NOT NULL CONSTRAINT DF_AuditNotifyArea_Sort DEFAULT (0),
    IsActive    BIT           NOT NULL CONSTRAINT DF_AuditNotifyArea_Active DEFAULT (1)
);
GO
MERGE dbo.AuditNotifyArea AS t
USING (VALUES
    ('AUDIT',      N'Audit alerts',                     N'WhatsApp alerts of sensitive actions - bills cancelled, refunds, reports un-authorised.', 'bi-shield-exclamation', 10),
    ('OPD_ROSTER', N'OPD Doctor Roster Notification',   N'Each doctor''s daily roster (sent again when the doctor''s room or roster changes), to the doctor and to the users you choose - by WhatsApp and e-mail.', 'bi-calendar2-week', 20)
) AS s (AreaCode, Title, Description, Icon, SortOrder) ON t.AreaCode = s.AreaCode
WHEN MATCHED THEN UPDATE SET Title = s.Title, Description = s.Description, Icon = s.Icon, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (AreaCode, Title, Description, Icon, SortOrder) VALUES (s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder);
GO

-- ── events: area and what each one can do ──────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.AuditNotifyEvent', 'AreaCode') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD AreaCode VARCHAR(30) NOT NULL CONSTRAINT DF_AuditNotifyEvent_Area DEFAULT ('AUDIT');
IF COL_LENGTH('dbo.AuditNotifyEvent', 'SupportsEmail') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD SupportsEmail BIT NOT NULL CONSTRAINT DF_AuditNotifyEvent_Email DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEvent', 'SupportsDoctor') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD SupportsDoctor BIT NOT NULL CONSTRAINT DF_AuditNotifyEvent_Doctor DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEvent', 'IsDaily') IS NULL
    ALTER TABLE dbo.AuditNotifyEvent ADD IsDaily BIT NOT NULL CONSTRAINT DF_AuditNotifyEvent_Daily DEFAULT (0);
GO
MERGE dbo.AuditNotifyEvent AS t
USING (VALUES
    ('OPD_ROSTER_DAILY', 'OPD', 'OPD_ROSTER', N'Daily doctor roster',
     N'Every day at the send time: each doctor with a session today gets the day''s roster - sessions, slots, booked so far and room. Sent again to a doctor whose room or roster changes (Room Doctor Assignment, Doctor Schedule).', 'bi-calendar-check', 110, 1, 1, 1)
) AS s (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily) ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, AreaCode = s.AreaCode, Title = s.Title, Description = s.Description, Icon = s.Icon,
     SortOrder = s.SortOrder, SupportsEmail = s.SupportsEmail, SupportsDoctor = s.SupportsDoctor, IsDaily = s.IsDaily
WHEN NOT MATCHED THEN INSERT (EventCode, Module, AreaCode, Title, Description, Icon, SortOrder, SupportsEmail, SupportsDoctor, IsDaily)
     VALUES (s.EventCode, s.Module, s.AreaCode, s.Title, s.Description, s.Icon, s.SortOrder, s.SupportsEmail, s.SupportsDoctor, s.IsDaily);
GO
-- a separate "room changed" event (an early draft of this script) is folded into the daily roster: its setup is removed
-- (its sent log stays)
IF EXISTS (SELECT 1 FROM dbo.AuditNotifyEvent WHERE EventCode = 'OPD_ROOM_CHANGE')
BEGIN
    DELETE dbo.AuditNotifyRecipient WHERE EventCode = 'OPD_ROOM_CHANGE';
    DELETE dbo.AuditNotifyEventSetting WHERE EventCode = 'OPD_ROOM_CHANGE';
    DELETE dbo.AuditNotifyEvent WHERE EventCode = 'OPD_ROOM_CHANGE';
END
GO

-- ── per branch: channels, the doctor, the send time ────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'SendWhatsApp') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD SendWhatsApp BIT NOT NULL CONSTRAINT DF_AuditNotifyEventSetting_WA DEFAULT (1);
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'SendEmail') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD SendEmail BIT NOT NULL CONSTRAINT DF_AuditNotifyEventSetting_Mail DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'NotifyDoctor') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD NotifyDoctor BIT NOT NULL CONSTRAINT DF_AuditNotifyEventSetting_Doc DEFAULT (0);
IF COL_LENGTH('dbo.AuditNotifyEventSetting', 'SendTime') IS NULL
    ALTER TABLE dbo.AuditNotifyEventSetting ADD SendTime TIME(0) NULL;
GO
IF COL_LENGTH('dbo.AuditNotifyLog', 'Channel') IS NULL
    ALTER TABLE dbo.AuditNotifyLog ADD Channel VARCHAR(10) NULL;          -- WHATSAPP / EMAIL (NULL = WhatsApp, before 2528)
IF COL_LENGTH('dbo.AuditNotifyLog', 'RecipientName') IS NULL
    ALTER TABLE dbo.AuditNotifyLog ADD RecipientName NVARCHAR(150) NULL;   -- a doctor (not a user)
IF COL_LENGTH('dbo.AuditNotifyLog', 'Phone') < 400
    ALTER TABLE dbo.AuditNotifyLog ALTER COLUMN Phone NVARCHAR(200) NULL;  -- mobile, or the e-mail address
GO
IF OBJECT_ID('dbo.AuditNotifyDailyRun', 'U') IS NULL
CREATE TABLE dbo.AuditNotifyDailyRun
(
    BranchId   INT         NOT NULL,
    EventCode  VARCHAR(40) NOT NULL,
    RunDate    DATE        NOT NULL,
    StartedAt  DATETIME    NOT NULL CONSTRAINT DF_AuditNotifyDailyRun_Started DEFAULT (GETDATE()),
    Trigger_By INT         NULL,          -- NULL = the scheduler, else the user who pressed Send now
    CONSTRAINT PK_AuditNotifyDailyRun PRIMARY KEY (BranchId, EventCode, RunDate)
);
GO

-- ── the page ───────────────────────────────────────────────────────────────────────────────────────────────
-- RS1 events, RS2 recipients, RS3 users of the branch, RS4 areas
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetSetup
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EventCode, e.Module, e.AreaCode, e.Title, e.Description, e.Icon, e.SortOrder,
           e.SupportsEmail, e.SupportsDoctor, e.IsDaily,
           CAST(ISNULL(s.IsEnabled, 0) AS BIT) AS IsEnabled,
           CAST(ISNULL(s.SendWhatsApp, 1) AS BIT) AS SendWhatsApp,
           CAST(CASE WHEN e.SupportsEmail = 1 THEN ISNULL(s.SendEmail, 1) ELSE 0 END AS BIT) AS SendEmail,
           CAST(CASE WHEN e.SupportsDoctor = 1 THEN ISNULL(s.NotifyDoctor, 1) ELSE 0 END AS BIT) AS NotifyDoctor,
           CASE WHEN e.IsDaily = 1 THEN CONVERT(VARCHAR(5), ISNULL(s.SendTime, '07:00'), 108) END AS SendTime,
           (SELECT COUNT(*) FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
             WHERE r.BranchId = @BranchId AND r.EventCode = e.EventCode) AS RecipientCount,
           s.ModifiedDate,
           (SELECT MAX(d.StartedAt) FROM dbo.AuditNotifyDailyRun d WHERE d.BranchId = @BranchId AND d.EventCode = e.EventCode) AS LastRunAt
      FROM dbo.AuditNotifyEvent e
      JOIN dbo.AuditNotifyArea a ON a.AreaCode = e.AreaCode AND a.IsActive = 1
      LEFT JOIN dbo.AuditNotifyEventSetting s ON s.BranchId = @BranchId AND s.EventCode = e.EventCode
     WHERE e.IsActive = 1
     ORDER BY a.SortOrder, e.SortOrder;

    SELECT r.EventCode, r.UserId
      FROM dbo.AuditNotifyRecipient r JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
     WHERE r.BranchId = @BranchId;

    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name, u.Username,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           NULLIF(LTRIM(RTRIM(u.Email)), '') AS Email,
           (SELECT b.BranchName FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId) AS BranchName
      FROM dbo.Users u
     WHERE u.IsActive = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
       AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1)
     ORDER BY Name;

    SELECT a.AreaCode, a.Title, a.Description, a.Icon, a.SortOrder
      FROM dbo.AuditNotifyArea a
     WHERE a.IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.AuditNotifyEvent e WHERE e.AreaCode = a.AreaCode AND e.IsActive = 1)
     ORDER BY a.SortOrder;
END
GO

-- saves one event: its switch, its recipients (the list replaces the old one) and its options
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_SaveEvent
    @CompanyId INT, @BranchId INT, @EventCode VARCHAR(40), @IsEnabled BIT, @UserIds VARCHAR(MAX) = NULL, @UserId INT,
    @SendWhatsApp BIT = NULL, @SendEmail BIT = NULL, @NotifyDoctor BIT = NULL, @SendTime VARCHAR(5) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @email BIT, @doctor BIT, @daily BIT;
    SELECT @email = SupportsEmail, @doctor = SupportsDoctor, @daily = IsDaily FROM dbo.AuditNotifyEvent WHERE EventCode = @EventCode AND IsActive = 1;
    IF @email IS NULL BEGIN RAISERROR('Unknown event.', 16, 1); RETURN; END

    SET @SendWhatsApp = ISNULL(@SendWhatsApp, 1);
    SET @SendEmail = CASE WHEN @email = 1 THEN ISNULL(@SendEmail, 1) ELSE 0 END;
    SET @NotifyDoctor = CASE WHEN @doctor = 1 THEN ISNULL(@NotifyDoctor, 1) ELSE 0 END;
    DECLARE @time TIME(0) = CASE WHEN @daily = 1 THEN TRY_CAST(NULLIF(LTRIM(RTRIM(@SendTime)), '') AS TIME(0)) END;
    IF @daily = 1 AND @time IS NULL SET @time = '07:00';

    DECLARE @Ids TABLE (UserId INT PRIMARY KEY);
    INSERT @Ids (UserId)
    SELECT DISTINCT u.Id FROM STRING_SPLIT(ISNULL(@UserIds, ''), ',') x
      JOIN dbo.Users u ON u.Id = TRY_CAST(LTRIM(RTRIM(x.value)) AS INT) AND u.IsActive = 1
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1;

    IF @IsEnabled = 1 AND @SendWhatsApp = 0 AND @SendEmail = 0
    BEGIN RAISERROR('Choose WhatsApp, e-mail or both to switch this alert on.', 16, 1); RETURN; END
    IF @IsEnabled = 1 AND NOT EXISTS (SELECT 1 FROM @Ids) AND @NotifyDoctor = 0
    BEGIN RAISERROR('Choose at least one user (or send it to the doctor) to switch this alert on.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        MERGE dbo.AuditNotifyEventSetting AS t
        USING (SELECT @BranchId AS BranchId, @EventCode AS EventCode) AS s ON t.BranchId = s.BranchId AND t.EventCode = s.EventCode
        WHEN MATCHED THEN UPDATE SET IsEnabled = @IsEnabled, SendWhatsApp = @SendWhatsApp, SendEmail = @SendEmail, NotifyDoctor = @NotifyDoctor,
             SendTime = @time, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, EventCode, IsEnabled, SendWhatsApp, SendEmail, NotifyDoctor, SendTime, ModifiedBy)
             VALUES (@CompanyId, @BranchId, @EventCode, @IsEnabled, @SendWhatsApp, @SendEmail, @NotifyDoctor, @time, @UserId);

        DELETE r FROM dbo.AuditNotifyRecipient r
         WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId NOT IN (SELECT UserId FROM @Ids);
        INSERT dbo.AuditNotifyRecipient (CompanyId, BranchId, EventCode, UserId, CreatedBy)
        SELECT @CompanyId, @BranchId, @EventCode, i.UserId, @UserId FROM @Ids i
         WHERE NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyRecipient r WHERE r.BranchId = @BranchId AND r.EventCode = @EventCode AND r.UserId = i.UserId);
    COMMIT;
END
GO

-- who gets an alert now: the event is on for the branch and the user is active (no mobile / e-mail = skipped, logged)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_GetRecipients
    @BranchId INT, @EventCode VARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id AS UserId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           NULLIF(LTRIM(RTRIM(u.Email)), '') AS Email
      FROM dbo.AuditNotifyEventSetting s
      JOIN dbo.AuditNotifyRecipient r ON r.BranchId = s.BranchId AND r.EventCode = s.EventCode
      JOIN dbo.Users u ON u.Id = r.UserId AND u.IsActive = 1
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode AND s.IsEnabled = 1;
END
GO

-- an event's setting for a branch (no row = off)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_EventSetting
    @BranchId INT, @EventCode VARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.CompanyId, s.BranchId, s.EventCode, s.IsEnabled, s.SendWhatsApp,
           CAST(s.SendEmail & e.SupportsEmail AS BIT) AS SendEmail, CAST(s.NotifyDoctor & e.SupportsDoctor AS BIT) AS NotifyDoctor,
           CONVERT(VARCHAR(5), s.SendTime, 108) AS SendTime, b.BranchName
      FROM dbo.AuditNotifyEventSetting s
      JOIN dbo.AuditNotifyEvent e ON e.EventCode = s.EventCode
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
     WHERE s.BranchId = @BranchId AND s.EventCode = @EventCode;
END
GO

-- the scheduler: branches whose daily event is on and due (send time passed today, not run today) - claimed here, so a
-- branch's day goes out once even with two servers
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DailyDue
    @EventCode VARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @now TIME(0) = CAST(GETDATE() AS TIME(0));
    DECLARE @claimed TABLE (BranchId INT);
    INSERT dbo.AuditNotifyDailyRun (BranchId, EventCode, RunDate)
    OUTPUT inserted.BranchId INTO @claimed
    SELECT s.BranchId, s.EventCode, @today
      FROM dbo.AuditNotifyEventSetting s
     WHERE s.EventCode = @EventCode AND s.IsEnabled = 1 AND ISNULL(s.SendTime, '07:00') <= @now
       AND NOT EXISTS (SELECT 1 FROM dbo.AuditNotifyDailyRun d WITH (UPDLOCK, HOLDLOCK)
                        WHERE d.BranchId = s.BranchId AND d.EventCode = s.EventCode AND d.RunDate = @today);
    SELECT BranchId FROM @claimed;
END
GO

-- Send now (the page): claims today for the branch; 0 = already sent today (the caller may still force it)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_ClaimDaily
    @BranchId INT, @EventCode VARCHAR(40), @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    IF EXISTS (SELECT 1 FROM dbo.AuditNotifyDailyRun WHERE BranchId = @BranchId AND EventCode = @EventCode AND RunDate = @today)
        SELECT CAST(0 AS BIT) AS Claimed;
    ELSE
    BEGIN
        INSERT dbo.AuditNotifyDailyRun (BranchId, EventCode, RunDate, Trigger_By) VALUES (@BranchId, @EventCode, @today, @UserId);
        SELECT CAST(1 AS BIT) AS Claimed;
    END
END
GO

-- the doctors' sessions on a date in a branch (Doctor Schedule, effective, active), one row per session; room from the
-- session, else the doctor's room (Room Doctor Assignment); doctors on leave that day are flagged; booked = visits so far
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DoctorRoster
    @BranchId INT, @Date DATE, @DoctorId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dow TINYINT = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;   -- 1 = Monday .. 7 = Sunday
    IF @dow = 7 SET @dow = 0;                                                      -- schedules keep Sunday as 0
    SELECT d.DoctorId,
           LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(d.NamePrefix)), '') + ' ', d.FullName))) AS DoctorName,
           sp.SpecialityName,
           NULLIF(LTRIM(RTRIM(d.PhoneNumber)), '') AS Mobile, NULLIF(LTRIM(RTRIM(d.EmailId)), '') AS Email,
           s.ScheduleId, s.StartTime, s.EndTime, s.SlotDurationMinutes, s.MaxPatientsPerSlot, s.MaxPatientsPerSession, s.ScheduleType,
           COALESCE(sr.RoomName, mr.RoomName) AS RoomName, COALESCE(sf.FloorName, mf.FloorName) AS FloorName,
           (SELECT COUNT(*) FROM dbo.PatientOPDService v
             WHERE v.ConsultingDoctorId = d.DoctorId AND v.BranchId = @BranchId AND CAST(v.VisitDate AS DATE) = @Date AND v.IsActive = 1
               AND ISNULL(v.Status, '') <> 'Cancelled' AND (v.ScheduleId = s.ScheduleId OR v.ScheduleId IS NULL AND v.AppointmentTime >= s.StartTime AND v.AppointmentTime < s.EndTime)) AS Booked,
           ex.Reason AS LeaveReason, CAST(CASE WHEN ex.ExceptionId IS NULL THEN 0 ELSE 1 END AS BIT) AS OnLeave,
           b.BranchName, b.CompanyId
      FROM dbo.DoctorScheduleMaster s
      JOIN dbo.DoctorMaster d ON d.DoctorId = s.DoctorId AND d.IsActive = 1 AND ISNULL(d.IsSuspended, 0) = 0
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
      LEFT JOIN dbo.DoctorRoomMaster sr ON sr.RoomId = s.RoomId
      LEFT JOIN dbo.FloorMaster sf ON sf.FloorId = sr.FloorId
      OUTER APPLY (SELECT TOP 1 r.RoomName, r.FloorId FROM dbo.DoctorRoomMapping m JOIN dbo.DoctorRoomMaster r ON r.RoomId = m.RoomId AND r.BranchId = @BranchId
                    WHERE m.DoctorId = d.DoctorId ORDER BY m.CreatedDate DESC) mr
      LEFT JOIN dbo.FloorMaster mf ON mf.FloorId = mr.FloorId
      OUTER APPLY (SELECT TOP 1 x.ExceptionId, x.Reason FROM dbo.DoctorScheduleException x
                    WHERE x.DoctorId = d.DoctorId AND x.BranchId = @BranchId AND x.ExceptionDate = @Date AND x.IsActive = 1) ex
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = @BranchId
     WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.DayOfWeek = @dow
       AND s.EffectiveFrom <= @Date AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @Date)
       AND (@DoctorId IS NULL OR s.DoctorId = @DoctorId)
     ORDER BY DoctorName, s.StartTime;
END
GO

-- a doctor and the room (Room Doctor Assignment) in a branch: before a change (the old room) and after it (the new one)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DoctorRoom
    @DoctorId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId,
           LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(d.NamePrefix)), '') + ' ', d.FullName))) AS DoctorName,
           sp.SpecialityName,
           NULLIF(LTRIM(RTRIM(d.PhoneNumber)), '') AS Mobile, NULLIF(LTRIM(RTRIM(d.EmailId)), '') AS Email,
           r.RoomId, r.RoomName, f.FloorName, b.BranchName, b.CompanyId
      FROM dbo.DoctorMaster d
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
      OUTER APPLY (SELECT TOP 1 m.RoomId FROM dbo.DoctorRoomMapping m WHERE m.DoctorId = d.DoctorId ORDER BY m.CreatedDate DESC) m
      LEFT JOIN dbo.DoctorRoomMaster r ON r.RoomId = m.RoomId
      LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = @BranchId
     WHERE d.DoctorId = @DoctorId;
END
GO

-- a doctor's roster after a change (Doctor Schedule): RS1 the weekly sessions (active, not ended), RS2 leave from today
-- (next 60 days); the room of a session, else the doctor's room
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_DoctorWeekly
    @DoctorId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT s.ScheduleId, s.DayOfWeek, s.StartTime, s.EndTime, s.SlotDurationMinutes, s.MaxPatientsPerSlot, s.MaxPatientsPerSession,
           s.EffectiveFrom, s.EffectiveTo, r.RoomName, f.FloorName
      FROM dbo.DoctorScheduleMaster s
      LEFT JOIN dbo.DoctorRoomMaster r ON r.RoomId = s.RoomId
      LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
     WHERE s.DoctorId = @DoctorId AND s.BranchId = @BranchId AND s.IsActive = 1 AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @today)
     ORDER BY CASE WHEN s.DayOfWeek = 0 THEN 7 ELSE s.DayOfWeek END, s.StartTime;
    SELECT x.ExceptionDate, x.ExceptionType, NULLIF(LTRIM(RTRIM(x.Reason)), '') AS Reason
      FROM dbo.DoctorScheduleException x
     WHERE x.DoctorId = @DoctorId AND x.BranchId = @BranchId AND x.IsActive = 1 AND x.ExceptionDate BETWEEN @today AND DATEADD(DAY, 60, @today)
     ORDER BY x.ExceptionDate;
END
GO

-- a session / leave about to be removed: whose it is and what it was (the message says what changed)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_RosterItem
    @ScheduleId INT = NULL, @ExceptionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ScheduleId IS NOT NULL
        SELECT s.DoctorId, s.BranchId, s.DayOfWeek, s.StartTime, s.EndTime, CAST(NULL AS DATE) AS ExceptionDate, CAST(NULL AS NVARCHAR(500)) AS Reason
          FROM dbo.DoctorScheduleMaster s WHERE s.ScheduleId = @ScheduleId;
    ELSE
        SELECT x.DoctorId, x.BranchId, CAST(NULL AS TINYINT) AS DayOfWeek, CAST(NULL AS TIME) AS StartTime, CAST(NULL AS TIME) AS EndTime,
               x.ExceptionDate, NULLIF(LTRIM(RTRIM(x.Reason)), '') AS Reason
          FROM dbo.DoctorScheduleException x WHERE x.ExceptionId = @ExceptionId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_Log
    @CompanyId INT, @BranchId INT = NULL, @EventCode VARCHAR(40), @RefNo NVARCHAR(60) = NULL, @UserId INT = NULL,
    @Phone NVARCHAR(200) = NULL, @Status VARCHAR(20), @Detail NVARCHAR(500) = NULL, @Message NVARCHAR(MAX) = NULL, @TriggeredBy INT = NULL,
    @Channel VARCHAR(10) = NULL, @RecipientName NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.AuditNotifyLog (CompanyId, BranchId, EventCode, RefNo, UserId, Phone, Status, Detail, Message, TriggeredBy, Channel, RecipientName)
    VALUES (@CompanyId, @BranchId, @EventCode, LEFT(@RefNo, 60), @UserId, LEFT(@Phone, 200), @Status, LEFT(@Detail, 500), @Message, @TriggeredBy,
            ISNULL(@Channel, 'WHATSAPP'), LEFT(@RecipientName, 150));
END
GO

-- the last alerts, for the page (with the area and channel)
CREATE OR ALTER PROCEDURE dbo.usp_AuditNotify_RecentLog
    @CompanyId INT, @BranchId INT, @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top) l.LogId, l.EventCode, e.Title AS EventTitle, e.AreaCode, l.RefNo, l.Status, l.Detail, l.Phone, l.CreatedDate,
           ISNULL(l.Channel, 'WHATSAPP') AS Channel,
           COALESCE(NULLIF(l.RecipientName, N''), ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)) AS RecipientName, br.BranchName
      FROM dbo.AuditNotifyLog l
      LEFT JOIN dbo.AuditNotifyEvent e ON e.EventCode = l.EventCode
      LEFT JOIN dbo.Users u ON u.Id = l.UserId
      LEFT JOIN dbo.Branchmaster br ON br.BranchID = l.BranchId
     WHERE l.CompanyId = @CompanyId AND l.BranchId = @BranchId
     ORDER BY l.CreatedDate DESC, l.LogId DESC;
END
GO

-- Send now: on the page's EDIT control, like Save / Send test
DECLARE @page INT, @edit INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.Page_ID, c.Control_ID FROM dbo.PageMaster p JOIN dbo.PageControlMaster c ON c.Page_ID = p.Page_ID AND c.Control_Code = 'EDIT'
     WHERE p.Page_Code = N'SETTINGS.AUDITNOTIFICATION';
OPEN pc; FETCH NEXT FROM pc INTO @page, @edit;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @edit, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'AuditNotificationSetup', @Action = N'SendNow', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page, @edit;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2528 applied: notification areas + OPD Doctor Roster Notification (daily roster, room changes).';
GO
SET NOEXEC OFF;
GO
