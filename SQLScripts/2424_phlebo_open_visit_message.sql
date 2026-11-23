-- ============================================================================================================
-- 2424  Phlebotomist app: "Finish your open visit" now names that visit.
--   usp_Phlebo_Visit_Event (live definition + this change): Start Journey on one visit while another is on the way,
--   reached or in progress was refused with a message that did not say which visit was open. It now gives the bill
--   number, the patient and the status, e.g. "Finish your open visit first: <bill no>, <patient> (reached).".
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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

    DECLARE @Cur VARCHAR(15), @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Company INT, @OtpOk DATETIME, @Consent BIT, @Slot DATETIME;
    SELECT @Cur = Status, @Lat = Latitude, @Lng = Longitude, @Company = CompanyId, @OtpOk = OtpVerifiedOn, @Consent = ConsentTaken, @Slot = SlotAt
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Cur IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.PhleboAttendance WHERE UserId = @UserId AND DutyDate = CAST(GETDATE() AS DATE) AND PunchOutAt IS NULL)
    BEGIN RAISERROR('Punch in before you start a visit.', 16, 1); RETURN; END

    -- 2414: a visit is started on its booked day, never before it; a visit of an earlier day (overdue) can still be started
    IF @Status = 'ON_THE_WAY' AND CAST(@Slot AS DATE) > CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @Early NVARCHAR(200) = CONCAT(N'This visit is booked for ', FORMAT(@Slot, 'd MMM', 'en-IN'), N'. You can start it on that day.');
        RAISERROR(@Early, 16, 1); RETURN;
    END

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

    IF @Status = 'ON_THE_WAY'
    BEGIN
        -- name the visit that is still open, so the phlebotomist can find it in My Jobs (2424)
        DECLARE @Open NVARCHAR(400);
        SELECT TOP 1 @Open = CONCAT(N'Finish your open visit first: ', o.BillNo,
                   ISNULL(N', ' + NULLIF(LTRIM(RTRIM(CONCAT(p.FirstName, N' ', p.LastName))), N''), N''),
                   N' (', CASE ov.Status WHEN 'ON_THE_WAY' THEN N'on the way' WHEN 'REACHED' THEN N'reached' ELSE N'in progress' END,
                   N'). Open it from My Jobs and collect the samples, or mark the patient not available.')
          FROM dbo.LabHomeVisit ov
          JOIN dbo.LabOrder o ON o.LabOrderId = ov.LabOrderId
          LEFT JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
         WHERE ov.PhlebotomistId = @UserId AND ov.VisitId <> @VisitId AND ov.Status IN ('ON_THE_WAY', 'REACHED', 'IN_PROGRESS')
         ORDER BY ov.VisitId;
        IF @Open IS NOT NULL BEGIN RAISERROR(@Open, 16, 1); RETURN; END
    END

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
