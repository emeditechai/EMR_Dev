-- ============================================================================================================
-- Migration: 2303_doctor_roster_past_slots.sql
-- Doctor Roster / OPD booking: a slot can be booked only at or after the current date and time (GETDATE()).
-- usp_Api_DoctorSchedule_GetAvailableSlots (latest body from 2062) now returns IsPast for every slot and makes a
-- passed slot unavailable - the slot is still listed (shown disabled as "Passed"), it is not hidden. The OPD save
-- (Patient Registration / New Service Booking) refuses a passed slot as well. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetAvailableSlots]
    @DoctorId INT,
    @BranchId INT,
    @Date DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Map weekday: 1=Mon .. 6=Sat, 0=Sun
    DECLARE @DayOfWeek TINYINT;
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
    IF @DayOfWeek = 7 SET @DayOfWeek = 0;

    -- Check Exception
    DECLARE @ExceptionReason NVARCHAR(500) = NULL;
    IF EXISTS (SELECT 1 FROM DoctorScheduleException WHERE DoctorId=@DoctorId AND BranchId=@BranchId AND ExceptionDate=@Date AND IsActive=1)
    BEGIN
        SELECT TOP 1 @ExceptionReason = Reason FROM DoctorScheduleException WHERE DoctorId=@DoctorId AND BranchId=@BranchId AND ExceptionDate=@Date AND IsActive=1;
        SELECT 1 AS HasException, @ExceptionReason AS ExceptionReason;
        SELECT TOP 0 0 AS ScheduleId, '' AS SlotTime, 0 AS BookedCount, 0 AS MaxPerSlot, CAST(0 AS BIT) AS IsAvailable, CAST(0 AS BIT) AS IsPast;
        RETURN;
    END

    -- ── Build all slots using INTEGER minute arithmetic (avoids TIME overflow at midnight) ──
    CREATE TABLE #Slots (
        ScheduleId          INT,
        SlotMinutes         INT,   -- minutes from 00:00
        MaxPerSlot          INT,
        MaxPatientsPerSession INT
    );

    DECLARE @CurId INT, @CurStart TIME, @CurEnd TIME, @CurDur INT, @CurMaxSlot INT, @CurMaxSess INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ScheduleId, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession
        FROM DoctorScheduleMaster
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
          AND EffectiveFrom <= @Date AND (EffectiveTo IS NULL OR EffectiveTo >= @Date);

    OPEN cur;
    FETCH NEXT FROM cur INTO @CurId, @CurStart, @CurEnd, @CurDur, @CurMaxSlot, @CurMaxSess;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @StartMin INT = DATEDIFF(MINUTE, '00:00:00', @CurStart);
        DECLARE @EndMin   INT = DATEDIFF(MINUTE, '00:00:00', @CurEnd);
        DECLARE @CurMin   INT = @StartMin;

        -- Use integer loop: no TIME type overflow possible
        WHILE (@CurMin + @CurDur) <= @EndMin
        BEGIN
            INSERT INTO #Slots (ScheduleId, SlotMinutes, MaxPerSlot, MaxPatientsPerSession)
            VALUES (@CurId, @CurMin, @CurMaxSlot, @CurMaxSess);
            SET @CurMin = @CurMin + @CurDur;
        END

        FETCH NEXT FROM cur INTO @CurId, @CurStart, @CurEnd, @CurDur, @CurMaxSlot, @CurMaxSess;
    END
    CLOSE cur; DEALLOCATE cur;

    -- ── Count bookings per slot in ONE set-based query (no sp_executesql per slot) ──
    CREATE TABLE #Bookings (ScheduleId INT, SlotMinutes INT, BookedCount INT);

    IF EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService'))
    BEGIN
        INSERT INTO #Bookings (ScheduleId, SlotMinutes, BookedCount)
        SELECT
            pos.ScheduleId,
            DATEDIFF(MINUTE, '00:00:00', pos.AppointmentTime) AS SlotMinutes,
            COUNT(*) AS BookedCount
        FROM PatientOPDService pos
        WHERE CAST(pos.VisitDate AS DATE) = @Date
          AND pos.Status <> 'Cancelled'
          AND pos.ScheduleId IN (SELECT DISTINCT ScheduleId FROM #Slots)
        GROUP BY pos.ScheduleId, pos.AppointmentTime;

        -- Mark full session: if total booked >= MaxPatientsPerSession, set MaxPerSlot = 0 (all slots unavailable)
        UPDATE s SET s.MaxPerSlot = 0
        FROM #Slots s
        INNER JOIN (
            SELECT ScheduleId, COUNT(*) AS TotalBooked
            FROM PatientOPDService
            WHERE CAST(VisitDate AS DATE) = @Date AND Status <> 'Cancelled'
            GROUP BY ScheduleId
        ) b ON s.ScheduleId = b.ScheduleId
        WHERE s.MaxPatientsPerSession IS NOT NULL AND b.TotalBooked >= s.MaxPatientsPerSession;
    END

    -- ── Return header row ──
    SELECT 0 AS HasException, CAST(NULL AS NVARCHAR(500)) AS ExceptionReason;

    -- ── Return slots ── (2303: a slot whose time has already passed is returned, but not available - IsPast)
    DECLARE @Now DATETIME = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, GETDATE()), 0);   -- now, to the minute
    SELECT
        s.ScheduleId,
        CONVERT(VARCHAR(5), DATEADD(MINUTE, s.SlotMinutes, '00:00:00'), 108) AS SlotTime,
        ISNULL(b.BookedCount, 0) AS BookedCount,
        s.MaxPerSlot,
        CAST(CASE WHEN ISNULL(b.BookedCount, 0) < s.MaxPerSlot
                   AND DATEADD(MINUTE, s.SlotMinutes, CAST(@Date AS DATETIME)) >= @Now THEN 1 ELSE 0 END AS BIT) AS IsAvailable,
        CAST(CASE WHEN DATEADD(MINUTE, s.SlotMinutes, CAST(@Date AS DATETIME)) < @Now THEN 1 ELSE 0 END AS BIT) AS IsPast
    FROM #Slots s
    LEFT JOIN #Bookings b ON b.ScheduleId = s.ScheduleId AND b.SlotMinutes = s.SlotMinutes
    ORDER BY s.ScheduleId, s.SlotMinutes;

    DROP TABLE #Slots;
    DROP TABLE #Bookings;
END
GO

PRINT 'Script 2303 applied: Doctor Roster - slots in the past are not bookable.';
GO
