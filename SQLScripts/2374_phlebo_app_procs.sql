-- ============================================================================================================
-- 2374  Phlebotomist app: stored procedures behind api/phlebo. Run after 2373. Re-runnable.
--   The user always comes from the token, so a phlebotomist reaches only visits assigned to them.
--   Each write carries a ClientEventId from the phone; a repeat of the same id changes nothing.
--   Messages raised here are shown to the phlebotomist as they are.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- metres between two points
CREATE OR ALTER FUNCTION dbo.ufn_Phlebo_DistanceM (@Lat1 FLOAT, @Lng1 FLOAT, @Lat2 FLOAT, @Lng2 FLOAT)
RETURNS FLOAT
AS
BEGIN
    IF @Lat1 IS NULL OR @Lng1 IS NULL OR @Lat2 IS NULL OR @Lng2 IS NULL RETURN NULL;
    DECLARE @a FLOAT = SIN(RADIANS(@Lat2 - @Lat1) / 2) * SIN(RADIANS(@Lat2 - @Lat1) / 2)
                     + COS(RADIANS(@Lat1)) * COS(RADIANS(@Lat2)) * SIN(RADIANS(@Lng2 - @Lng1) / 2) * SIN(RADIANS(@Lng2 - @Lng1) / 2);
    IF @a > 1 SET @a = 1;
    RETURN 6371000.0 * 2 * ATN2(SQRT(@a), SQRT(1 - @a));
END
GO

-- The whole bill. LabOrder.TotalAmount holds the tests only; home collection and other charges are in LabOrderMiscCharge.
-- PaymentHeader.NetAmount has both, after discounts; the sum is used only for a bill with no payment record yet.
CREATE OR ALTER FUNCTION dbo.ufn_Phlebo_BillAmount (@LabOrderId INT)
RETURNS DECIMAL(12, 2)
AS
BEGIN
    RETURN (SELECT COALESCE(
                (SELECT TOP 1 ph.NetAmount FROM dbo.PaymentHeader ph WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1),
                o.TotalAmount + ISNULL((SELECT SUM(m.NetAmount) FROM dbo.LabOrderMiscCharge m WHERE m.LabOrderId = o.LabOrderId AND m.IsActive = 1), 0))
              FROM dbo.LabOrder o WHERE o.LabOrderId = @LabOrderId);
END
GO

-- Who may use the app: a phlebotomist on an approved phone. Code is OK, NOT_PHLEBOTOMIST, NO_SHIFT, DEVICE_NEW, DEVICE_PENDING or DEVICE_REVOKED.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Guard
    @UserId   INT,
    @DeviceId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Code VARCHAR(20) = 'OK', @IsPhlebo BIT, @Shift INT, @Zone INT, @Status VARCHAR(10);
    SELECT @IsPhlebo = IsPhlebotomist & IsActive, @Shift = ShiftSlotId, @Zone = AssignedZoneId FROM dbo.Users WHERE Id = @UserId;
    SELECT @Status = Status FROM dbo.PhleboDevice WHERE UserId = @UserId AND DeviceId = @DeviceId;

    IF ISNULL(@IsPhlebo, 0) = 0 SET @Code = 'NOT_PHLEBOTOMIST';
    ELSE IF @Shift IS NULL OR @Zone IS NULL SET @Code = 'NO_SHIFT';
    ELSE IF @Status IS NULL SET @Code = 'DEVICE_NEW';
    ELSE IF @Status = 'PENDING' SET @Code = 'DEVICE_PENDING';
    ELSE IF @Status = 'REVOKED' SET @Code = 'DEVICE_REVOKED';

    IF @Status IS NOT NULL UPDATE dbo.PhleboDevice SET LastSeen = GETDATE() WHERE UserId = @UserId AND DeviceId = @DeviceId;
    SELECT @Code AS Code;
END
GO

-- First phone of a phlebotomist is approved when the company allows it; any later phone waits for a supervisor.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Device_Register
    @UserId     INT,
    @CompanyId  INT,
    @DeviceId   NVARCHAR(100),
    @DeviceName NVARCHAR(150) = NULL,
    @Platform   VARCHAR(10) = NULL,
    @AppVersion VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@DeviceId)), N'') IS NULL BEGIN RAISERROR('Device id is required.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM dbo.PhleboDevice WHERE UserId = @UserId AND DeviceId = @DeviceId)
        UPDATE dbo.PhleboDevice SET DeviceName = ISNULL(@DeviceName, DeviceName), Platform = ISNULL(@Platform, Platform),
               AppVersion = ISNULL(@AppVersion, AppVersion), LastSeen = GETDATE()
         WHERE UserId = @UserId AND DeviceId = @DeviceId;
    ELSE
    BEGIN
        DECLARE @Auto BIT = 0;
        IF NOT EXISTS (SELECT 1 FROM dbo.PhleboDevice WHERE UserId = @UserId AND Status <> 'REVOKED')
            SELECT @Auto = AutoApproveFirstDevice FROM dbo.PhleboSettings WHERE CompanyId = @CompanyId;
        INSERT dbo.PhleboDevice (CompanyId, UserId, DeviceId, DeviceName, Platform, AppVersion, Status, ApprovedDate, LastSeen)
        VALUES (@CompanyId, @UserId, @DeviceId, @DeviceName, @Platform, @AppVersion,
                CASE WHEN @Auto = 1 THEN 'APPROVED' ELSE 'PENDING' END, CASE WHEN @Auto = 1 THEN GETDATE() END, GETDATE());
    END
    SELECT Status FROM dbo.PhleboDevice WHERE UserId = @UserId AND DeviceId = @DeviceId;
END
GO

-- Keeps visits in step with bookings: a visit for every open home collection of this phlebotomist, and a cancelled
-- or moved booking closes the visit on this phone.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Sync
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE v SET Status = 'CANCELLED', OutcomeReason = N'Booking cancelled', ModifiedDate = GETDATE()
      FROM dbo.LabHomeVisit v JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
     WHERE v.PhlebotomistId = @UserId AND o.IsActive = 0
       AND v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS');

    UPDATE v SET PhlebotomistId = o.PhlebotomistId, Status = 'ASSIGNED', ModifiedDate = GETDATE()
      FROM dbo.LabHomeVisit v JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
     WHERE o.PhlebotomistId = @UserId AND v.PhlebotomistId <> @UserId AND v.ParentVisitId IS NULL
       AND v.Status IN ('ASSIGNED', 'ACCEPTED');

    INSERT dbo.LabHomeVisit (CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, SlotAt, AddressSnapshot, Latitude, Longitude)
    SELECT b.CompanyId, o.BranchId, o.LabOrderId, o.PatientId, @UserId, o.BookingDate,
           LEFT(COALESCE(NULLIF(p.HomeCollectionAddress, N''), p.Address), 500), p.Latitude, p.Longitude
      FROM dbo.LabOrder o
      JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
      JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
     WHERE o.PhlebotomistId = @UserId AND o.CollectionType = 'Home Collection' AND o.IsActive = 1
       AND NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit v WHERE v.LabOrderId = o.LabOrderId AND v.ParentVisitId IS NULL)
       AND EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                    WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                      AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Session_Get
    @UserId    INT,
    @CompanyId INT,
    @DeviceId  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhleboSettings WHERE CompanyId = @CompanyId)
        INSERT dbo.PhleboSettings (CompanyId) VALUES (@CompanyId);

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    SELECT u.Id AS UserId, u.FullName, u.Username, u.PhoneNumber, u.CertificationNo, u.VehicleRegNo, u.IsVehicleAvailable,
           u.DailyCollectionTarget, sm.ShiftName, sm.StartTime AS ShiftStart, sm.EndTime AS ShiftEnd,
           d.Status AS DeviceStatus,
           a.AttendanceId, a.PunchInAt, a.PunchOutAt, a.DayStatus, a.ReviewStatus,
           CAST(CASE WHEN a.AttendanceId IS NOT NULL AND a.PunchOutAt IS NULL THEN 1 ELSE 0 END AS BIT) AS OnDuty,
           s.ArrivalRadiusM, s.OutsideRadiusAction, s.RequireSelfie, s.RequireVehiclePhoto, s.RequireBagPhoto, s.RequireTempGunPhoto,
           s.RequireTemperature, s.FieldStartAllowed, s.LocationIntervalSeconds, s.LocationDistanceM,
           s.OtpRequired, s.OtpPoint, s.AcceptStepEnabled, s.CashHoldingLimit
      FROM dbo.Users u
      JOIN dbo.PhleboSettings s ON s.CompanyId = @CompanyId
      LEFT JOIN dbo.ShiftMaster sm ON sm.ShiftMaster_ID = u.ShiftSlotId
      LEFT JOIN dbo.PhleboDevice d ON d.UserId = u.Id AND d.DeviceId = @DeviceId
      LEFT JOIN dbo.PhleboAttendance a ON a.UserId = u.Id AND a.DutyDate = @Today
     WHERE u.Id = @UserId;

    SELECT DocType FROM dbo.PhleboDocument WHERE UserId = @UserId AND DutyDate = @Today AND AttendanceId IS NULL;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Document_Save
    @UserId      INT,
    @CompanyId   INT,
    @BranchId    INT,
    @VisitId     INT = NULL,
    @DocType     VARCHAR(20),
    @FileName    NVARCHAR(200),
    @FilePath    NVARCHAR(400),
    @ContentType NVARCHAR(100) = NULL,
    @FileSize    BIGINT,
    @Remarks     NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @VisitId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId)
        BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
        IF @DocType = 'CONSENT'
            UPDATE dbo.LabHomeVisit SET ConsentTaken = 1, ModifiedDate = GETDATE() WHERE VisitId = @VisitId;
    END
    INSERT dbo.PhleboDocument (CompanyId, BranchId, UserId, VisitId, DutyDate, DocType, FileName, FilePath, ContentType, FileSizeBytes, Remarks)
    OUTPUT INSERTED.DocumentId
    VALUES (@CompanyId, @BranchId, @UserId, @VisitId, CASE WHEN @VisitId IS NULL THEN CAST(GETDATE() AS DATE) END, @DocType, @FileName, @FilePath, @ContentType, @FileSize, @Remarks);
END
GO

-- Rebuilds the day's legs from proven stops: Punch In -> each stop -> Punch Out. Payable km uses the road km when a
-- routing provider has filled it, else GPS km. Legs already decided by a supervisor are kept.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Legs_Build
    @AttendanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.PhleboTravelLeg WHERE AttendanceId = @AttendanceId AND ReviewStatus IN ('APPROVED', 'REFUSED')) RETURN;

    DECLARE @UserId INT, @In DATETIME, @Out DATETIME, @Tol DECIMAL(4, 2);
    SELECT @UserId = a.UserId, @In = a.PunchInAt, @Out = a.PunchOutAt, @Tol = s.PayableKmTolerance
      FROM dbo.PhleboAttendance a JOIN dbo.PhleboSettings s ON s.CompanyId = a.CompanyId
     WHERE a.AttendanceId = @AttendanceId;
    IF @In IS NULL RETURN;

    DECLARE @Stops TABLE (N INT IDENTITY(1, 1), At DATETIME, Label NVARCHAR(100), VisitId INT);
    INSERT @Stops (At, Label, VisitId) VALUES (@In, N'Punch In', NULL);
    INSERT @Stops (At, Label, VisitId)
    SELECT e.ServerTime, LEFT(CONCAT(N'Visit ', ISNULL(o.BillNo, CONVERT(NVARCHAR(12), v.VisitId))), 100), e.VisitId
      FROM dbo.LabHomeVisitEvent e
      JOIN dbo.LabHomeVisit v ON v.VisitId = e.VisitId
      JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
     WHERE e.CreatedBy = @UserId AND e.Status IN ('REACHED', 'UNAVAILABLE') AND e.ServerTime >= @In
       AND (@Out IS NULL OR e.ServerTime <= @Out)
     ORDER BY e.ServerTime;
    IF @Out IS NOT NULL INSERT @Stops (At, Label, VisitId) VALUES (@Out, N'Punch Out', NULL);

    -- clean points: accuracy within 50 m, no jump above 120 km/h
    DECLARE @Pts TABLE (T DATETIME, Lat FLOAT, Lng FLOAT, PrevT DATETIME, PrevLat FLOAT, PrevLng FLOAT);
    INSERT @Pts
    SELECT PointTime, Latitude, Longitude,
           LAG(PointTime) OVER (ORDER BY PointTime), LAG(Latitude) OVER (ORDER BY PointTime), LAG(Longitude) OVER (ORDER BY PointTime)
      FROM dbo.PhleboLocationPoint
     WHERE AttendanceId = @AttendanceId AND ISNULL(AccuracyM, 0) <= 50 AND IsMock = 0;

    DELETE dbo.PhleboTravelLeg WHERE AttendanceId = @AttendanceId;

    INSERT dbo.PhleboTravelLeg (AttendanceId, LegNo, FromLabel, ToLabel, FromTime, ToTime, ToVisitId, GpsKm, PayableKm, HasGap, ReviewStatus)
    SELECT @AttendanceId, a.N, a.Label, b.Label, a.At, b.At, b.VisitId, g.Km, g.Km, g.Gap,
           CASE WHEN g.Gap = 1 THEN 'NEEDS_REVIEW' ELSE 'OK' END
      FROM @Stops a
      JOIN @Stops b ON b.N = a.N + 1
     CROSS APPLY (
        SELECT CAST(ISNULL(SUM(CASE WHEN p.D / NULLIF(DATEDIFF(SECOND, p.PrevT, p.T), 0) * 3.6 <= 120 THEN p.D END), 0) / 1000.0 AS DECIMAL(9, 3)) AS Km,
               CAST(CASE WHEN COUNT(*) = 0 OR MAX(DATEDIFF(SECOND, p.PrevT, p.T)) > 300 THEN 1 ELSE 0 END AS BIT) AS Gap
          FROM (SELECT x.*, dbo.ufn_Phlebo_DistanceM(x.PrevLat, x.PrevLng, x.Lat, x.Lng) AS D FROM @Pts x
                 WHERE x.T > a.At AND x.T <= b.At AND x.PrevT IS NOT NULL) p
     ) g;

    UPDATE dbo.PhleboTravelLeg
       SET PayableKm = CASE WHEN RoadKm IS NULL THEN GpsKm WHEN RoadKm < GpsKm * @Tol THEN RoadKm ELSE GpsKm * @Tol END
     WHERE AttendanceId = @AttendanceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Attendance_Punch
    @UserId        INT,
    @CompanyId     INT,
    @BranchId      INT,
    @PunchType     VARCHAR(3),       -- IN / OUT
    @ClientEventId NVARCHAR(64),
    @DeviceId      NVARCHAR(100),
    @DeviceTime    DATETIME = NULL,
    @Latitude      DECIMAL(10, 8) = NULL,
    @Longitude     DECIMAL(11, 8) = NULL,
    @AccuracyM     DECIMAL(8, 2) = NULL,
    @IsMock        BIT = 0,
    @Temperature   DECIMAL(5, 2) = NULL,
    @FieldStart    BIT = 0,
    @Reason        NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @PunchType NOT IN ('IN', 'OUT') BEGIN RAISERROR('Punch type must be IN or OUT.', 16, 1); RETURN; END
    IF @Latitude IS NULL OR @Longitude IS NULL BEGIN RAISERROR('Your location is needed to punch. Turn on GPS and try again.', 16, 1); RETURN; END

    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @Now DATETIME = GETDATE(), @AttId INT;

    -- a repeat of the same punch answers with the saved row
    SELECT @AttId = AttendanceId FROM dbo.PhleboAttendance
     WHERE UserId = @UserId AND (PunchInEventId = @ClientEventId OR PunchOutEventId = @ClientEventId);
    IF @AttId IS NOT NULL
    BEGIN
        SELECT AttendanceId, PunchInAt, PunchOutAt, DayStatus, ReviewStatus, ReviewReason FROM dbo.PhleboAttendance WHERE AttendanceId = @AttId;
        RETURN;
    END

    DECLARE @BranchRadius INT, @LateGrace INT, @FieldOk BIT, @RSelfie BIT, @RVehicle BIT, @RBag BIT, @RGun BIT, @RTemp BIT, @Retention INT;
    SELECT @BranchRadius = BranchRadiusM, @LateGrace = LateGraceMinutes, @FieldOk = FieldStartAllowed, @RSelfie = RequireSelfie,
           @RVehicle = RequireVehiclePhoto, @RBag = RequireBagPhoto, @RGun = RequireTempGunPhoto, @RTemp = RequireTemperature,
           @Retention = LocationRetentionDays
      FROM dbo.PhleboSettings WHERE CompanyId = @CompanyId;

    IF @PunchType = 'IN'
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.PhleboAttendance WHERE UserId = @UserId AND DutyDate = @Today)
        BEGIN RAISERROR('You have already punched in today.', 16, 1); RETURN; END
        IF @FieldStart = 1 AND @FieldOk = 0 BEGIN RAISERROR('Starting from the field is not allowed. Punch in at your branch.', 16, 1); RETURN; END
        IF @FieldStart = 1 AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason for starting from the field.', 16, 1); RETURN; END
        IF @RTemp = 1 AND @Temperature IS NULL BEGIN RAISERROR('Enter the temperature reading.', 16, 1); RETURN; END

        DECLARE @Missing NVARCHAR(100) =
            STUFF(CONCAT(
                CASE WHEN @RSelfie = 1  AND NOT EXISTS (SELECT 1 FROM dbo.PhleboDocument WHERE UserId = @UserId AND DutyDate = @Today AND DocType = 'SELFIE')   THEN N', selfie' END,
                CASE WHEN @RVehicle = 1 AND NOT EXISTS (SELECT 1 FROM dbo.PhleboDocument WHERE UserId = @UserId AND DutyDate = @Today AND DocType = 'VEHICLE')  THEN N', vehicle' END,
                CASE WHEN @RBag = 1     AND NOT EXISTS (SELECT 1 FROM dbo.PhleboDocument WHERE UserId = @UserId AND DutyDate = @Today AND DocType = 'BAG')      THEN N', medical bag' END,
                CASE WHEN @RGun = 1     AND NOT EXISTS (SELECT 1 FROM dbo.PhleboDocument WHERE UserId = @UserId AND DutyDate = @Today AND DocType = 'TEMP_GUN') THEN N', temperature gun' END
            ), 1, 2, N'');
        IF @Missing IS NOT NULL
        BEGIN
            DECLARE @MissingMsg NVARCHAR(200) = N'Take these photos first: ' + @Missing + N'.';
            RAISERROR(@MissingMsg, 16, 1);
            RETURN;
        END

        -- nearest allowed start: the branch or a start point
        DECLARE @Dist FLOAT, @Radius INT;
        SELECT TOP 1 @Dist = d.M, @Radius = d.R FROM (
            SELECT dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, b.Latitude, b.Longitude) AS M, ISNULL(b.GeofenceRadiusM, @BranchRadius) AS R
              FROM dbo.Branchmaster b WHERE b.BranchID = @BranchId AND b.Latitude IS NOT NULL
            UNION ALL
            SELECT dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, p.Latitude, p.Longitude), p.RadiusM
              FROM dbo.PhleboStartPoint p WHERE p.CompanyId = @CompanyId AND p.IsActive = 1
        ) d ORDER BY d.M;

        DECLARE @ShiftId INT, @Start TIME(0);
        SELECT @ShiftId = u.ShiftSlotId, @Start = sm.StartTime
          FROM dbo.Users u LEFT JOIN dbo.ShiftMaster sm ON sm.ShiftMaster_ID = u.ShiftSlotId WHERE u.Id = @UserId;

        DECLARE @Day VARCHAR(15) =
            CASE WHEN @Start IS NOT NULL AND @Now > DATEADD(MINUTE, @LateGrace, CAST(@Today AS DATETIME) + CAST(@Start AS DATETIME)) THEN 'LATE' ELSE 'PRESENT' END;
        DECLARE @Review NVARCHAR(300) =
            CASE WHEN @IsMock = 1 THEN N'Mock location reported by the phone.'
                 WHEN @FieldStart = 1 THEN N'Field start.'
                 WHEN @Dist IS NULL THEN N'No branch or start point coordinates to check against.'
                 WHEN @Dist > @Radius THEN CONCAT(N'Punched in ', CAST(ROUND(@Dist, 0) AS INT), N' m from the start point.') END;

        INSERT dbo.PhleboAttendance (CompanyId, BranchId, UserId, DutyDate, ShiftId, PunchInAt, PunchInLat, PunchInLng, PunchInAccuracyM, PunchInDistanceM,
               PunchInIsMock, DeviceId, IsFieldStart, FieldStartReason, TemperatureReading, PunchInEventId, DayStatus, ReviewStatus, ReviewReason)
        VALUES (@CompanyId, @BranchId, @UserId, @Today, @ShiftId, @Now, @Latitude, @Longitude, @AccuracyM, @Dist,
               @IsMock, @DeviceId, @FieldStart, CASE WHEN @FieldStart = 1 THEN @Reason END, @Temperature, @ClientEventId, @Day,
               CASE WHEN @Review IS NULL THEN 'OK' ELSE 'NEEDS_REVIEW' END, @Review);
        SET @AttId = SCOPE_IDENTITY();

        UPDATE dbo.PhleboDocument SET AttendanceId = @AttId WHERE UserId = @UserId AND DutyDate = @Today AND AttendanceId IS NULL;
    END
    ELSE
    BEGIN
        SELECT @AttId = AttendanceId FROM dbo.PhleboAttendance WHERE UserId = @UserId AND DutyDate = @Today AND PunchOutAt IS NULL;
        IF @AttId IS NULL BEGIN RAISERROR('You are not punched in.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE PhlebotomistId = @UserId AND Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS'))
        BEGIN RAISERROR('Finish your open visit before you punch out.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE PhlebotomistId = @UserId AND Status = 'COLLECTED')
        BEGIN RAISERROR('Hand over your collected samples before you punch out.', 16, 1); RETURN; END

        UPDATE dbo.PhleboAttendance
           SET PunchOutAt = @Now, PunchOutLat = @Latitude, PunchOutLng = @Longitude, PunchOutIsMock = @IsMock, PunchOutEventId = @ClientEventId,
               ReviewStatus = CASE WHEN @IsMock = 1 THEN 'NEEDS_REVIEW' ELSE ReviewStatus END,
               ReviewReason = CASE WHEN @IsMock = 1 THEN N'Mock location reported by the phone.' ELSE ReviewReason END
         WHERE AttendanceId = @AttId;

        EXEC dbo.usp_Phlebo_Legs_Build @AttendanceId = @AttId;
        DELETE TOP (5000) FROM dbo.PhleboLocationPoint WHERE UserId = @UserId AND PointTime < DATEADD(DAY, -@Retention, @Now);
    END

    SELECT AttendanceId, PunchInAt, PunchOutAt, DayStatus, ReviewStatus, ReviewReason FROM dbo.PhleboAttendance WHERE AttendanceId = @AttId;
END
GO

-- [{"time":"2026-11-01T10:00:00","lat":22.5,"lng":88.3,"accuracy":12,"speed":3.1,"mock":false}]; a repeated point is skipped.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Location_Batch
    @UserId INT,
    @Json   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AttId INT;
    SELECT TOP 1 @AttId = AttendanceId FROM dbo.PhleboAttendance WHERE UserId = @UserId AND PunchOutAt IS NULL ORDER BY DutyDate DESC;
    IF @AttId IS NULL BEGIN SELECT 0 AS Saved; RETURN; END

    INSERT dbo.PhleboLocationPoint (UserId, AttendanceId, PointTime, Latitude, Longitude, AccuracyM, SpeedMps, IsMock)
    SELECT DISTINCT @UserId, @AttId, j.[time], j.lat, j.lng, j.accuracy, j.speed, ISNULL(j.mock, 0)
      FROM OPENJSON(@Json) WITH ([time] DATETIME '$.time', lat DECIMAL(10, 8) '$.lat', lng DECIMAL(11, 8) '$.lng',
                                 accuracy DECIMAL(8, 2) '$.accuracy', speed DECIMAL(8, 2) '$.speed', mock BIT '$.mock') j
     WHERE j.[time] IS NOT NULL AND j.lat IS NOT NULL AND j.lng IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.PhleboLocationPoint p WHERE p.UserId = @UserId AND p.PointTime = j.[time]);
    SELECT @@ROWCOUNT AS Saved;
END
GO

-- My Day: today's and every still-open visit, urgent first, then by slot. Tab follows the itDose job tabs.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_List
    @UserId INT,
    @Date   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Phlebo_Visit_Sync @UserId = @UserId;
    SET @Date = ISNULL(@Date, CAST(GETDATE() AS DATE));

    SELECT v.VisitId, v.LabOrderId, o.BillNo, o.TokenNo, v.Status, v.SlotAt, v.AddressSnapshot, v.Latitude, v.Longitude, o.IsUrgent, v.ParentVisitId,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName, p.Gender,
           CASE WHEN LEN(p.PhoneNumber) > 4 THEN REPLICATE('x', LEN(p.PhoneNumber) - 4) + RIGHT(p.PhoneNumber, 4) ELSE p.PhoneNumber END AS MaskedPhone,
           t.Tests, t.Fasting,
           CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END AS BalanceDue,
           ISNULL(o.IsB2B, 0) AS IsB2B,
           CASE WHEN v.Status IN ('ASSIGNED', 'ACCEPTED') THEN 'PENDING'
                WHEN v.Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS') THEN 'CHECK_IN'
                WHEN v.Status = 'COLLECTED' THEN 'COMPLETED'
                WHEN v.Status IN ('HANDED_OVER', 'RECEIVED') THEN 'BOOKING_COMPLETE'
                ELSE 'CLOSED' END AS Tab
      FROM dbo.LabHomeVisit v
      JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
      JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
     OUTER APPLY (SELECT COUNT(*) AS Tests, CAST(ISNULL(MAX(CAST(lim.Is_Fasting_Required AS INT)), 0) AS BIT) AS Fasting
                    FROM dbo.SampleCollection sc JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                   WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0) t
     WHERE v.PhlebotomistId = @UserId
       AND (CAST(v.SlotAt AS DATE) = @Date OR CAST(v.ModifiedDate AS DATE) = @Date
            OR (@Date = CAST(GETDATE() AS DATE) AND v.Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS', 'COLLECTED')))
     ORDER BY CASE WHEN v.Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS') THEN 0 ELSE 1 END, o.IsUrgent DESC, v.SlotAt;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Get
    @UserId  INT,
    @VisitId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId)
    BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    SELECT v.VisitId, v.LabOrderId, o.BillNo, o.TokenNo, v.Status, v.SlotAt, v.AddressSnapshot, v.Latitude, v.Longitude, o.IsUrgent,
           p.PatientCode, LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName, p.Gender, p.PhoneNumber,
           p.SecondaryPhoneNumber, p.Pincode,
           DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
           dbo.ufn_Phlebo_BillAmount(o.LabOrderId) AS TotalAmount, ISNULL(ph.TotalPaid, 0) AS TotalPaid,
           CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END AS BalanceDue,
           ISNULL(o.IsB2B, 0) AS IsB2B, v.OtpVerifiedOn, v.VerifyMethod, v.ConsentTaken, v.NeedsReview, v.OutcomeReason
      FROM dbo.LabHomeVisit v
      JOIN dbo.LabOrder o ON o.LabOrderId = v.LabOrderId
      JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
     WHERE v.VisitId = @VisitId;

    -- same selection as the Sample Collection screen: tests that need a sample
    SELECT sc.samplecollectionID AS SampleCollectionId, sc.InvestigationID AS InvestigationId, lim.Test_Code AS TestCode, lim.Test_Name AS TestName,
           ISNULL(stm.Sample_Name, N'Standard Sample') AS SampleTypeName, ISNULL(NULLIF(stm.Container_Type, N''), N'Standard Tube') AS ContainerType,
           ISNULL(lim.Is_Fasting_Required, 0) AS IsFastingRequired, sc.BarcodeNo, ISNULL(sc.CollectionstatusID, 1) AS CollectionStatusId,
           ISNULL(cs.StatusName, N'Pending') AS StatusName, COALESCE(sc.ProfileName, sc.PackageName) AS ProfileName,
           ISNULL(cat.Is_Barcode_Required, 1) AS IsBarcodeRequired, sc.RejectionReason
      FROM dbo.LabHomeVisit v
      JOIN dbo.SampleCollection sc ON sc.Laborderid = v.LabOrderId
      JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
      LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
      LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
      LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
     WHERE v.VisitId = @VisitId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
     ORDER BY COALESCE(sc.ProfileName, sc.PackageName, N'ZZZ'), stm.Sample_Name, lim.Test_Name;

    SELECT e.Status, e.ServerTime, e.DeviceTime, e.DistanceM, e.Reason
      FROM dbo.LabHomeVisitEvent e WHERE e.VisitId = @VisitId ORDER BY e.ServerTime;

    SELECT r.Reason_ID AS ReasonId, r.Reason_Text AS ReasonText
      FROM dbo.LabHomeVisit v JOIN dbo.LabSampleRejectionReasonMaster r ON r.CompanyId = v.CompanyId
     WHERE v.VisitId = @VisitId AND r.Status = 1 AND r.IsDeleted = 0
     ORDER BY r.Display_Order, r.Reason_Text;

    SELECT DocumentId, DocType, FileName, CreatedDate FROM dbo.PhleboDocument WHERE VisitId = @VisitId ORDER BY DocumentId;

    -- home collection and other charges on the bill
    SELECT m.ChargeName, m.ChargeType, m.Quantity, m.Amount, m.DiscountAmount, m.GstAmount, m.NetAmount
      FROM dbo.LabHomeVisit v JOIN dbo.LabOrderMiscCharge m ON m.LabOrderId = v.LabOrderId AND m.IsActive = 1
     WHERE v.VisitId = @VisitId
     ORDER BY CASE WHEN m.ChargeType = 'Home Collection' THEN 0 ELSE 1 END, m.LabOrderMiscChargeId;
END
GO

-- A status change from the phone. Sample Collected and Handed Over have their own procedures.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Event
    @UserId        INT,
    @VisitId       INT,
    @Status        VARCHAR(15),
    @ClientEventId NVARCHAR(64),
    @DeviceTime    DATETIME = NULL,
    @Latitude      DECIMAL(10, 8) = NULL,
    @Longitude     DECIMAL(11, 8) = NULL,
    @AccuracyM     DECIMAL(8, 2) = NULL,
    @IsMock        BIT = 0,
    @Reason        NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ClientEventId)), N'') IS NULL BEGIN RAISERROR('ClientEventId is required.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabHomeVisitEvent WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
        RETURN;
    END

    DECLARE @Cur VARCHAR(15), @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Company INT, @OtpOk DATETIME, @Consent BIT;
    SELECT @Cur = Status, @Lat = Latitude, @Lng = Longitude, @Company = CompanyId, @OtpOk = OtpVerifiedOn, @Consent = ConsentTaken
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Cur IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.PhleboAttendance WHERE UserId = @UserId AND DutyDate = CAST(GETDATE() AS DATE) AND PunchOutAt IS NULL)
    BEGIN RAISERROR('Punch in before you start a visit.', 16, 1); RETURN; END

    DECLARE @AcceptOn BIT, @ArrRadius INT, @Outside VARCHAR(5), @OtpReq BIT, @OtpPoint VARCHAR(10);
    SELECT @AcceptOn = AcceptStepEnabled, @ArrRadius = ArrivalRadiusM, @Outside = OutsideRadiusAction, @OtpReq = OtpRequired, @OtpPoint = OtpPoint
      FROM dbo.PhleboSettings WHERE CompanyId = @Company;

    DECLARE @Ok BIT = CASE
        WHEN @Status = 'ACCEPTED'    AND @Cur = 'ASSIGNED' AND @AcceptOn = 1 THEN 1
        WHEN @Status = 'REJECTED'    AND @Cur = 'ASSIGNED' AND @AcceptOn = 1 THEN 1
        WHEN @Status = 'ON_THE_WAY'  AND (@Cur = 'ACCEPTED' OR (@Cur = 'ASSIGNED' AND @AcceptOn = 0)) THEN 1
        WHEN @Status = 'REACHED'     AND @Cur = 'ON_THE_WAY' THEN 1
        WHEN @Status = 'IN_PROGRESS' AND @Cur = 'REACHED' THEN 1
        WHEN @Status IN ('UNAVAILABLE', 'RESCHEDULED') AND @Cur IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS') THEN 1
        ELSE 0 END;
    IF @Ok = 0
    BEGIN
        DECLARE @Bad NVARCHAR(120) = CONCAT(N'A visit in status ', @Cur, N' cannot move to ', @Status, N'.');
        RAISERROR(@Bad, 16, 1);
        RETURN;
    END

    IF @Status IN ('REJECTED', 'UNAVAILABLE', 'RESCHEDULED') AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL
    BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    IF @Status = 'ON_THE_WAY' AND EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE PhlebotomistId = @UserId AND VisitId <> @VisitId AND Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS'))
    BEGIN RAISERROR('Finish your open visit before you start another.', 16, 1); RETURN; END

    IF @Status = 'IN_PROGRESS'
    BEGIN
        IF @OtpReq = 1 AND @OtpPoint = 'ARRIVAL' AND @OtpOk IS NULL BEGIN RAISERROR('Verify the patient before you begin.', 16, 1); RETURN; END
        IF @Consent = 0 BEGIN RAISERROR('Take the patient''s consent before you begin.', 16, 1); RETURN; END
    END

    DECLARE @Dist FLOAT = dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, @Lat, @Lng), @Flag BIT = 0;
    IF @Status = 'REACHED'
    BEGIN
        IF @Dist > @ArrRadius
        BEGIN
            IF @Outside = 'BLOCK' BEGIN RAISERROR('You are too far from the patient address.', 16, 1); RETURN; END
            IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL
            BEGIN
                DECLARE @Far NVARCHAR(120) = CONCAT(N'You are ', CAST(ROUND(@Dist, 0) AS INT), N' m from the address. Give a reason.');
                RAISERROR(@Far, 16, 1);
                RETURN;
            END
            SET @Flag = 1;
        END
        IF @Lat IS NULL SET @Flag = 1;   -- no pin on the patient: the phone's position is saved on the visit for a supervisor
    END
    IF @IsMock = 1 SET @Flag = 1;

    BEGIN TRANSACTION;
        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM, IsMock, DistanceM, Reason, CreatedBy)
        VALUES (@VisitId, @Status, @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM, @IsMock, @Dist, @Reason, @UserId);

        UPDATE dbo.LabHomeVisit
           SET Status = CASE WHEN @Status = 'REJECTED' THEN 'ASSIGNED' ELSE @Status END,
               Latitude = CASE WHEN @Status = 'REACHED' AND Latitude IS NULL THEN @Latitude ELSE Latitude END,
               Longitude = CASE WHEN @Status = 'REACHED' AND Longitude IS NULL THEN @Longitude ELSE Longitude END,
               OutcomeReason = CASE WHEN @Status IN ('REJECTED', 'UNAVAILABLE', 'RESCHEDULED') THEN @Reason ELSE OutcomeReason END,
               NeedsReview = CASE WHEN @Flag = 1 THEN 1 ELSE NeedsReview END,
               ModifiedDate = GETDATE()
         WHERE VisitId = @VisitId;
    COMMIT;

    SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
END
GO

-- The code itself is made and hashed in the API; a new one replaces the old.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Otp_Save
    @UserId  INT,
    @VisitId INT,
    @OtpHash VARCHAR(64),
    @Expires DATETIME
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId AND Status IN ('REACHED', 'IN_PROGRESS'))
    BEGIN RAISERROR('Mark the visit as Reached first.', 16, 1); RETURN; END

    UPDATE dbo.LabHomeVisit SET OtpHash = @OtpHash, OtpExpiresOn = @Expires, OtpAttempts = 0, ModifiedDate = GETDATE() WHERE VisitId = @VisitId;

    SELECT v.BranchId, p.PhoneNumber, p.FirstName
      FROM dbo.LabHomeVisit v JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId WHERE v.VisitId = @VisitId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Otp_Verify
    @UserId   INT,
    @VisitId  INT,
    @OtpHash  VARCHAR(64) = NULL,
    @Reason   NVARCHAR(300) = NULL     -- no code: the patient's ID photo stands in, with a reason
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hash VARCHAR(64), @Exp DATETIME, @Tries INT;
    SELECT @Hash = OtpHash, @Exp = OtpExpiresOn, @Tries = OtpAttempts
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    IF @OtpHash IS NULL
    BEGIN
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END
        IF NOT EXISTS (SELECT 1 FROM dbo.PhleboDocument WHERE VisitId = @VisitId AND DocType = 'ID_PROOF')
        BEGIN RAISERROR('Take a photo of the patient''s ID first.', 16, 1); RETURN; END
        UPDATE dbo.LabHomeVisit SET OtpVerifiedOn = GETDATE(), VerifyMethod = 'ID_PROOF', VerifyReason = @Reason, NeedsReview = 1, ModifiedDate = GETDATE()
         WHERE VisitId = @VisitId;
        SELECT 1 AS Verified;
        RETURN;
    END

    IF @Hash IS NULL OR @Exp < GETDATE() BEGIN RAISERROR('The code has expired. Send a new one.', 16, 1); RETURN; END
    IF @Tries >= 5 BEGIN RAISERROR('Too many wrong codes. Send a new one.', 16, 1); RETURN; END
    IF @Hash <> @OtpHash
    BEGIN
        UPDATE dbo.LabHomeVisit SET OtpAttempts = OtpAttempts + 1 WHERE VisitId = @VisitId;
        RAISERROR('The code is not correct.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabHomeVisit SET OtpVerifiedOn = GETDATE(), VerifyMethod = 'OTP', OtpHash = NULL, ModifiedDate = GETDATE() WHERE VisitId = @VisitId;
    SELECT 1 AS Verified;
END
GO

-- Sample Collected: the one step that writes to the lab tables, through the same procedure as the Sample Collection screen.
-- @TubesJson: [{"sampleCollectionId":1,"collected":true,"barcode":"123"},{"sampleCollectionId":2,"collected":false,"reasonId":4,"remarks":"..."}]
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Samples
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @TubesJson     NVARCHAR(MAX),
    @DeviceTime    DATETIME = NULL,
    @Latitude      DECIMAL(10, 8) = NULL,
    @Longitude     DECIMAL(11, 8) = NULL,
    @AccuracyM     DECIMAL(8, 2) = NULL,
    @IsMock        BIT = 0,
    @DueReason     NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ClientEventId)), N'') IS NULL BEGIN RAISERROR('ClientEventId is required.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabHomeVisitEvent WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
        RETURN;
    END

    DECLARE @Cur VARCHAR(15), @OrderId INT, @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Company INT, @OtpOk DATETIME;
    SELECT @Cur = Status, @OrderId = LabOrderId, @Lat = Latitude, @Lng = Longitude, @Company = CompanyId, @OtpOk = OtpVerifiedOn
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Cur IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
    IF @Cur <> 'IN_PROGRESS' BEGIN RAISERROR('Begin the visit first.', 16, 1); RETURN; END

    DECLARE @OtpReq BIT, @ArrRadius INT, @Outside VARCHAR(5);
    SELECT @OtpReq = OtpRequired, @ArrRadius = ArrivalRadiusM, @Outside = OutsideRadiusAction FROM dbo.PhleboSettings WHERE CompanyId = @Company;
    IF @OtpReq = 1 AND @OtpOk IS NULL BEGIN RAISERROR('Verify the patient first.', 16, 1); RETURN; END

    DECLARE @Dist FLOAT = dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, @Lat, @Lng);
    IF @Outside = 'BLOCK' AND @Dist > @ArrRadius BEGIN RAISERROR('You are too far from the patient address.', 16, 1); RETURN; END

    DECLARE @Tubes TABLE (Id BIGINT PRIMARY KEY, Collected BIT, Barcode NVARCHAR(50), ReasonId INT, Remarks NVARCHAR(300));
    INSERT @Tubes
    SELECT j.id, ISNULL(j.collected, 0), NULLIF(LTRIM(RTRIM(j.barcode)), N''), j.reasonId, j.remarks
      FROM OPENJSON(@TubesJson) WITH (id BIGINT '$.sampleCollectionId', collected BIT '$.collected', barcode NVARCHAR(50) '$.barcode',
                                      reasonId INT '$.reasonId', remarks NVARCHAR(300) '$.remarks') j;

    -- every open tube of this booking must be answered, and only its own tubes
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.samplecollectionID = t.Id AND sc.Laborderid = @OrderId))
    BEGIN RAISERROR('A tube does not belong to this booking.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                 LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                 LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @OrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3)
                  AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
                  AND NOT EXISTS (SELECT 1 FROM @Tubes t WHERE t.Id = sc.samplecollectionID))
    BEGIN RAISERROR('Scan every tube, or mark it as not collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE t.Collected = 0 AND t.ReasonId IS NULL)
    BEGIN RAISERROR('Choose a reason for every tube not collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t JOIN dbo.SampleCollection sc ON sc.BarcodeNo = t.Barcode AND sc.Laborderid <> @OrderId AND ISNULL(sc.Iscancelled, 0) = 0)
    BEGIN RAISERROR('A barcode is already used on another booking.', 16, 1); RETURN; END

    DECLARE @Due DECIMAL(12, 2) = (SELECT CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END
                                     FROM dbo.LabOrder o
                                     LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
                                    WHERE o.LabOrderId = @OrderId);
    IF @Due > 0 AND NULLIF(LTRIM(RTRIM(@DueReason)), N'') IS NULL
    BEGIN RAISERROR('Record the payment, or give a reason for leaving the amount due.', 16, 1); RETURN; END

    DECLARE @At DATETIME = CASE WHEN @DeviceTime IS NOT NULL AND @DeviceTime <= GETDATE() AND @DeviceTime >= DATEADD(DAY, -1, GETDATE()) THEN @DeviceTime ELSE GETDATE() END;
    DECLARE @ColDate DATE = CAST(@At AS DATE), @ColTime TIME(0) = CAST(@At AS TIME(0));
    DECLARE @Failed INT = (SELECT COUNT(*) FROM @Tubes WHERE Collected = 0);
    DECLARE @Sink TABLE (R INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE sc SET BarcodeNo = t.Barcode FROM dbo.SampleCollection sc JOIN @Tubes t ON t.Id = sc.samplecollectionID WHERE t.Collected = 1 AND t.Barcode IS NOT NULL;

        DECLARE @Id BIGINT, @Col BIT, @RId INT, @Rem NVARCHAR(300), @RText NVARCHAR(300);
        DECLARE tc CURSOR LOCAL FAST_FORWARD FOR SELECT Id, Collected, ReasonId, Remarks FROM @Tubes;
        OPEN tc; FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @Col = 1
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 2,
                     @SampleCollectionDate = @ColDate, @SampleCollectionTime = @ColTime, @UserId = @UserId;
            ELSE
            BEGIN
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 3, @UserId = @UserId;
                SELECT @RText = Reason_Text FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @RId;
                UPDATE dbo.SampleCollection SET RejectionReasonId = @RId, RejectionReason = LEFT(CONCAT(@RText, N' ', @Rem), 500) WHERE samplecollectionID = @Id;
            END
            FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        END
        CLOSE tc; DEALLOCATE tc;

        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM, IsMock, DistanceM, Reason, CreatedBy)
        VALUES (@VisitId, 'COLLECTED', @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM, @IsMock, @Dist, @DueReason, @UserId);

        UPDATE dbo.LabHomeVisit
           SET Status = 'COLLECTED', ModifiedDate = GETDATE(),
               NeedsReview = CASE WHEN @IsMock = 1 OR @Dist > @ArrRadius THEN 1 ELSE NeedsReview END
         WHERE VisitId = @VisitId;

        -- failed tubes go back out as a child visit, for the dispatcher to re-time
        IF @Failed > 0
            INSERT dbo.LabHomeVisit (CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, SlotAt, AddressSnapshot, Latitude, Longitude, ParentVisitId)
            SELECT CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, DATEADD(DAY, 1, GETDATE()), AddressSnapshot, Latitude, Longitude, VisitId
              FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
END
GO

-- A payment at the door: the same rows and ledger posting as the web payment screen. Cash also joins the phlebotomist's balance.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Payment
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @MethodCode    VARCHAR(10),
    @Amount        DECIMAL(12, 2),
    @Reference     NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ClientEventId)), N'') IS NULL BEGIN RAISERROR('ClientEventId is required.', 16, 1); RETURN; END

    DECLARE @OrderId INT, @Branch INT, @Company INT, @Cur VARCHAR(15);
    SELECT @OrderId = LabOrderId, @Branch = BranchId, @Company = CompanyId, @Cur = Status
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @OrderId IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    DECLARE @HeaderId INT, @Net DECIMAL(12, 2), @Balance DECIMAL(12, 2);
    IF EXISTS (SELECT 1 FROM dbo.LabHomeVisitEvent WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT ph.TotalPaid, ph.BalanceDue, ph.PaymentStatus, CAST(NULL AS NVARCHAR(50)) AS ReceiptNo
          FROM dbo.PaymentHeader ph WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @OrderId AND ph.IsActive = 1;
        RETURN;
    END

    IF @Cur NOT IN ('REACHED', 'IN_PROGRESS', 'COLLECTED') BEGIN RAISERROR('A payment can be taken only at the patient''s address.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @OrderId AND ISNULL(IsB2B, 0) = 1)
    BEGIN RAISERROR('This bill belongs to a partner account. Do not take payment.', 16, 1); RETURN; END
    IF @MethodCode NOT IN ('CASH', 'UPI', 'CARD') BEGIN RAISERROR('Payment mode must be cash, UPI or card.', 16, 1); RETURN; END
    IF @Amount IS NULL OR @Amount <= 0 BEGIN RAISERROR('Enter the amount.', 16, 1); RETURN; END
    IF @MethodCode <> 'CASH' AND NULLIF(LTRIM(RTRIM(@Reference)), N'') IS NULL BEGIN RAISERROR('Enter the reference number.', 16, 1); RETURN; END

    DECLARE @MethodId INT = (SELECT TOP 1 PaymentMethodId FROM dbo.PaymentMethodMaster WHERE MethodCode = @MethodCode AND IsActive = 1 ORDER BY CASE WHEN CompanyId = @Company THEN 0 ELSE 1 END);
    IF @MethodId IS NULL BEGIN RAISERROR('This payment mode is not active.', 16, 1); RETURN; END

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @HeaderId = PaymentHeaderId, @Net = NetAmount, @Balance = BalanceDue
          FROM dbo.PaymentHeader WITH (UPDLOCK, HOLDLOCK)
         WHERE ModuleCode = 'LAB' AND ModuleRefId = @OrderId AND IsActive = 1;
        IF @HeaderId IS NULL RAISERROR('This bill has no payment record yet. Ask the branch to open it.', 16, 1);
        IF @Amount > @Balance
        BEGIN
            DECLARE @Over NVARCHAR(120) = CONCAT(N'Amount cannot exceed the balance of ', FORMAT(@Balance, 'N2'), N'.');
            RAISERROR(@Over, 16, 1);
        END

        DECLARE @Receipt NVARCHAR(50), @DetailId INT;
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @Branch, @ReceiptNo = @Receipt OUTPUT;

        INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
        VALUES (@HeaderId, @MethodId, @Amount, CASE WHEN @MethodCode = 'CARD' THEN @Reference END, CASE WHEN @MethodCode = 'UPI' THEN @Reference END,
                GETDATE(), N'Phlebotomist app', GETDATE(), @UserId, 1, @Receipt, @Company);
        SET @DetailId = SCOPE_IDENTITY();

        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'RECEIPT', @RefId = @DetailId, @UserId = @UserId;

        DECLARE @Paid DECIMAL(12, 2) =
            ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = @HeaderId AND d.IsActive = 1), 0)
          - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.ModuleCode = 'LAB' AND r.ModuleRefId = @OrderId AND r.IsActive = 1), 0);
        UPDATE dbo.PaymentHeader
           SET TotalPaid = @Paid,
               BalanceDue = CASE WHEN @Net - @Paid > 0 THEN @Net - @Paid ELSE 0 END,
               PaymentStatus = CASE WHEN @Paid >= @Net THEN 'P' WHEN @Paid > 0 THEN 'R' ELSE 'U' END,
               LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
         WHERE PaymentHeaderId = @HeaderId;

        EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @HeaderId, @UserId = @UserId;
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @HeaderId, @UserId = @UserId;

        IF @MethodCode = 'CASH'
            INSERT dbo.PhleboCashLedger (CompanyId, BranchId, UserId, LabOrderId, PaymentDetailId, Amount, EntryType, CreatedBy)
            VALUES (@Company, @Branch, @UserId, @OrderId, @DetailId, @Amount, 'COLLECT', @UserId);

        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, CreatedBy, Reason) VALUES (@VisitId, 'PAYMENT', @ClientEventId, @UserId, CONCAT(@MethodCode, N' ', @Amount));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    DECLARE @Token NVARCHAR(20);
    EXEC dbo.usp_LAB_AssignTokenOnPayment @LabOrderId = @OrderId, @TokenNo = @Token OUTPUT;

    SELECT TotalPaid, BalanceDue, PaymentStatus, @Receipt AS ReceiptNo
      FROM dbo.PaymentHeader WHERE PaymentHeaderId = @HeaderId;
END
GO

-- Tests the phlebotomist can add, at this branch's B2C rate list.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Test_Search
    @UserId  INT,
    @VisitId INT,
    @Search  NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Branch INT, @Company INT;
    SELECT @Branch = BranchId, @Company = CompanyId FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Branch IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    SELECT TOP 30 lim.Test_ID AS InvestigationId, lim.Test_Code AS TestCode, lim.Test_Name AS TestName, r.Rate
      FROM dbo.LabInvestigationMaster lim
     CROSS APPLY (SELECT TOP 1 d.Rate FROM dbo.LabRateCardDetail d JOIN dbo.LabRateCardMaster m ON m.RateCard_ID = d.RateCard_ID
                   WHERE m.Branch_ID = @Branch AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0 AND d.Status = 1 AND d.IsDeleted = 0
                     AND d.Item_Type = 'Test' AND d.Item_ID = lim.Test_ID
                   ORDER BY m.Effective_From DESC) r
     WHERE lim.CompanyId = @Company AND lim.Status = 1 AND lim.IsDeleted = 0 AND lim.Is_Billable = 1
       AND (lim.Test_Name LIKE N'%' + @Search + N'%' OR lim.Test_Code LIKE N'%' + @Search + N'%')
     ORDER BY lim.Test_Name;
END
GO

-- The phone sends test ids and a reason; the price comes from the rate list. The request stays PENDING until an approver decides.
-- @LinesJson: [{"action":"ADD","investigationId":12}]
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_BillChange_Create
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @RequestType   VARCHAR(20),
    @Reason        NVARCHAR(300),
    @Details       NVARCHAR(500) = NULL,
    @LinesJson     NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM dbo.LabBillChangeRequest WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT BillChangeId, Status, OldTotal, NewTotal FROM dbo.LabBillChangeRequest WHERE ClientEventId = @ClientEventId;
        RETURN;
    END

    IF @RequestType NOT IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST', 'DISCOUNT', 'PAYMENT_MODE', 'PATIENT_DETAILS')
    BEGIN RAISERROR('Unknown request type.', 16, 1); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    DECLARE @Order INT, @Branch INT, @Company INT, @Cur VARCHAR(15);
    SELECT @Order = LabOrderId, @Branch = BranchId, @Company = CompanyId, @Cur = Status
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Order IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
    IF @Cur NOT IN ('REACHED', 'IN_PROGRESS') BEGIN RAISERROR('A bill change can be raised only at the patient''s address, before samples are collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @Order AND ISNULL(IsB2B, 0) = 1)
    BEGIN RAISERROR('This bill belongs to a partner account and cannot be changed in the field.', 16, 1); RETURN; END

    DECLARE @Lines TABLE (LineAction VARCHAR(10), InvestigationId INT, Price DECIMAL(12, 2));
    INSERT @Lines (LineAction, InvestigationId)
    SELECT UPPER(j.action), j.investigationId
      FROM OPENJSON(ISNULL(@LinesJson, N'[]')) WITH (action VARCHAR(10) '$.action', investigationId INT '$.investigationId') j;

    IF @RequestType IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST') AND NOT EXISTS (SELECT 1 FROM @Lines)
    BEGIN RAISERROR('Choose the tests.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Lines WHERE LineAction NOT IN ('ADD', 'REMOVE') OR InvestigationId IS NULL)
    BEGIN RAISERROR('A test line is not valid.', 16, 1); RETURN; END

    UPDATE l SET Price = r.Rate
      FROM @Lines l
     CROSS APPLY (SELECT TOP 1 d.Rate FROM dbo.LabRateCardDetail d JOIN dbo.LabRateCardMaster m ON m.RateCard_ID = d.RateCard_ID
                   WHERE m.Branch_ID = @Branch AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0 AND d.Status = 1 AND d.IsDeleted = 0
                     AND d.Item_Type = 'Test' AND d.Item_ID = l.InvestigationId
                   ORDER BY m.Effective_From DESC) r
     WHERE l.LineAction = 'ADD';
    UPDATE l SET Price = i.Price
      FROM @Lines l JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
     WHERE l.LineAction = 'REMOVE';

    IF EXISTS (SELECT 1 FROM @Lines WHERE Price IS NULL)
    BEGIN RAISERROR('A test has no rate at this branch, or is not on this bill.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Lines l JOIN dbo.SampleCollection sc ON sc.Laborderid = @Order AND sc.InvestigationID = l.InvestigationId AND sc.CollectionstatusID = 2
                WHERE l.LineAction = 'REMOVE')
    BEGIN RAISERROR('A collected test cannot be removed in the field.', 16, 1); RETURN; END

    DECLARE @Old DECIMAL(12, 2) = dbo.ufn_Phlebo_BillAmount(@Order);
    DECLARE @New DECIMAL(12, 2) = @Old + ISNULL((SELECT SUM(CASE WHEN LineAction = 'ADD' THEN Price ELSE -Price END) FROM @Lines), 0);
    DECLARE @Id INT;

    BEGIN TRANSACTION;
        INSERT dbo.LabBillChangeRequest (CompanyId, BranchId, LabOrderId, VisitId, RequestType, Reason, Details, OldTotal, NewTotal, ClientEventId, RequestedBy)
        VALUES (@Company, @Branch, @Order, @VisitId, @RequestType, @Reason, @Details, @Old, @New, @ClientEventId, @UserId);
        SET @Id = SCOPE_IDENTITY();
        INSERT dbo.LabBillChangeLine (BillChangeId, LineAction, InvestigationId, Price)
        SELECT @Id, LineAction, InvestigationId, Price FROM @Lines;
    COMMIT;

    SELECT BillChangeId, Status, OldTotal, NewTotal FROM dbo.LabBillChangeRequest WHERE BillChangeId = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_BillChange_List
    @UserId  INT,
    @VisitId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 100 r.BillChangeId, r.VisitId, r.LabOrderId, o.BillNo, r.RequestType, r.Reason, r.OldTotal, r.NewTotal, r.Status, r.RequestedDate,
           r.ActionedDate, r.ActionRemarks
      FROM dbo.LabBillChangeRequest r JOIN dbo.LabOrder o ON o.LabOrderId = r.LabOrderId
     WHERE r.RequestedBy = @UserId AND (@VisitId IS NULL OR r.VisitId = @VisitId)
     ORDER BY r.BillChangeId DESC;
END
GO

-- A manifest of the barcodes on collected visits. @VisitIdsJson: [1,2,3]
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Handover_Create
    @UserId        INT,
    @CompanyId     INT,
    @BranchId      INT,
    @ClientEventId NVARCHAR(64),
    @ReceiverName  NVARCHAR(150),
    @TemperatureC  DECIMAL(5, 2) = NULL,
    @VisitIdsJson  NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id INT = (SELECT HandoverId FROM dbo.PhleboHandover WHERE ClientEventId = @ClientEventId);
    IF @Id IS NULL
    BEGIN
        IF NULLIF(LTRIM(RTRIM(@ReceiverName)), N'') IS NULL BEGIN RAISERROR('Enter who received the samples.', 16, 1); RETURN; END

        DECLARE @V TABLE (VisitId INT PRIMARY KEY);
        INSERT @V SELECT DISTINCT TRY_CAST([value] AS INT) FROM OPENJSON(@VisitIdsJson) WHERE TRY_CAST([value] AS INT) IS NOT NULL;
        IF NOT EXISTS (SELECT 1 FROM @V) BEGIN RAISERROR('Choose the visits to hand over.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM @V x LEFT JOIN dbo.LabHomeVisit v ON v.VisitId = x.VisitId AND v.PhlebotomistId = @UserId AND v.Status = 'COLLECTED' WHERE v.VisitId IS NULL)
        BEGIN RAISERROR('Only your collected visits can be handed over.', 16, 1); RETURN; END

        BEGIN TRANSACTION;
            INSERT dbo.PhleboHandover (CompanyId, BranchId, PhlebotomistId, ReceiverName, TemperatureC, ClientEventId)
            VALUES (@CompanyId, @BranchId, @UserId, @ReceiverName, @TemperatureC, @ClientEventId);
            SET @Id = SCOPE_IDENTITY();

            INSERT dbo.PhleboHandoverLine (HandoverId, VisitId, BarcodeNo)
            SELECT DISTINCT @Id, x.VisitId, sc.BarcodeNo
              FROM @V x
              JOIN dbo.LabHomeVisit v ON v.VisitId = x.VisitId
              JOIN dbo.SampleCollection sc ON sc.Laborderid = v.LabOrderId
             WHERE sc.CollectionstatusID = 2 AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND NULLIF(sc.BarcodeNo, N'') IS NOT NULL;

            INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, CreatedBy, Reason)
            SELECT x.VisitId, 'HANDED_OVER', CONCAT(@ClientEventId, N'-', x.VisitId), @UserId, @ReceiverName FROM @V x;

            UPDATE v SET Status = 'HANDED_OVER', HandoverId = @Id, ModifiedDate = GETDATE()
              FROM dbo.LabHomeVisit v JOIN @V x ON x.VisitId = v.VisitId;
        COMMIT;
    END

    SELECT h.HandoverId, h.HandedOverAt, h.ReceiverName, (SELECT COUNT(*) FROM dbo.PhleboHandoverLine l WHERE l.HandoverId = h.HandoverId) AS Barcodes
      FROM dbo.PhleboHandover h WHERE h.HandoverId = @Id;
END
GO

-- The dashboard figures: visits against the target, distance, cash held, travel claim so far.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Summary
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @AttId INT;
    SELECT @AttId = AttendanceId FROM dbo.PhleboAttendance WHERE UserId = @UserId AND DutyDate = @Today;
    IF @AttId IS NOT NULL EXEC dbo.usp_Phlebo_Legs_Build @AttendanceId = @AttId;

    DECLARE @Done INT = (SELECT COUNT(*) FROM dbo.LabHomeVisitEvent e WHERE e.CreatedBy = @UserId AND e.Status = 'COLLECTED' AND CAST(e.ServerTime AS DATE) = @Today);
    DECLARE @Km DECIMAL(9, 3) = ISNULL((SELECT SUM(PayableKm) FROM dbo.PhleboTravelLeg WHERE AttendanceId = @AttId AND ReviewStatus <> 'REFUSED'), 0);

    SELECT @Done AS VisitsCompleted,
           (SELECT COUNT(*) FROM dbo.LabHomeVisit WHERE PhlebotomistId = @UserId AND Status IN ('ASSIGNED', 'ACCEPTED', 'ON_THE_WAY', 'REACHED', 'IN_PROGRESS')) AS VisitsOpen,
           (SELECT COUNT(*) FROM dbo.LabHomeVisit WHERE PhlebotomistId = @UserId AND Status = 'COLLECTED') AS AwaitingHandover,
           (SELECT ISNULL(DailyCollectionTarget, 0) FROM dbo.Users WHERE Id = @UserId) AS DailyTarget,
           @Km AS PayableKm,
           (SELECT COUNT(*) FROM dbo.PhleboTravelLeg WHERE AttendanceId = @AttId AND ReviewStatus = 'NEEDS_REVIEW') AS LegsNeedingReview,
           ISNULL((SELECT SUM(Amount) FROM dbo.PhleboCashLedger WHERE UserId = @UserId), 0) AS CashHeld,
           s.CashHoldingLimit,
           CAST(@Km * s.RatePerKm + @Done * s.VisitIncentive AS DECIMAL(12, 2)) AS TravelClaim
      FROM dbo.Users u JOIN dbo.PhleboSettings s ON s.CompanyId = u.CompanyId
     WHERE u.Id = @UserId;
END
GO
