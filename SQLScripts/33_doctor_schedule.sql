USE [Dev_EMR]
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[DoctorScheduleMaster]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[DoctorScheduleMaster](
        [ScheduleId] [int] IDENTITY(1,1) NOT NULL,
        [DoctorId] [int] NOT NULL,
        [BranchId] [int] NOT NULL,
        [RoomId] [int] NULL,
        [DayOfWeek] [tinyint] NOT NULL,
        [StartTime] [time](7) NOT NULL,
        [EndTime] [time](7) NOT NULL,
        [SlotDurationMinutes] [int] NOT NULL,
        [MaxPatientsPerSlot] [int] NOT NULL CONSTRAINT [DF_DoctorScheduleMaster_MaxPatientsPerSlot]  DEFAULT ((1)),
        [MaxPatientsPerSession] [int] NULL,
        [ScheduleType] [varchar](20) NOT NULL CONSTRAINT [DF_DoctorScheduleMaster_ScheduleType]  DEFAULT ('OPD'),
        [EffectiveFrom] [date] NOT NULL,
        [EffectiveTo] [date] NULL,
        [IsActive] [bit] NOT NULL CONSTRAINT [DF_DoctorScheduleMaster_IsActive]  DEFAULT ((1)),
        [CreatedBy] [int] NOT NULL,
        [CreatedDate] [datetime] NOT NULL CONSTRAINT [DF_DoctorScheduleMaster_CreatedDate]  DEFAULT (getutcdate()),
        [ModifiedBy] [int] NULL,
        [ModifiedDate] [datetime] NULL,
        CONSTRAINT [PK_DoctorScheduleMaster] PRIMARY KEY CLUSTERED ([ScheduleId] ASC)
    ) ON [PRIMARY]
    
    ALTER TABLE [dbo].[DoctorScheduleMaster] WITH CHECK ADD CONSTRAINT [FK_DoctorScheduleMaster_DoctorMaster] FOREIGN KEY([DoctorId])
    REFERENCES [dbo].[DoctorMaster] ([DoctorId])

    ALTER TABLE [dbo].[DoctorScheduleMaster] WITH CHECK ADD CONSTRAINT [FK_DoctorScheduleMaster_BranchMaster] FOREIGN KEY([BranchId])
    REFERENCES [dbo].[BranchMaster] ([BranchId])

    ALTER TABLE [dbo].[DoctorScheduleMaster] WITH CHECK ADD CONSTRAINT [FK_DoctorScheduleMaster_DoctorRoomMaster] FOREIGN KEY([RoomId])
    REFERENCES [dbo].[DoctorRoomMaster] ([RoomId])

    CREATE NONCLUSTERED INDEX [IX_DoctorScheduleMaster_DoctorBranchDay] ON [dbo].[DoctorScheduleMaster]
    (
        [DoctorId] ASC,
        [BranchId] ASC,
        [DayOfWeek] ASC,
        [IsActive] ASC
    ) ON [PRIMARY]
END
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[DoctorScheduleException]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[DoctorScheduleException](
        [ExceptionId] [int] IDENTITY(1,1) NOT NULL,
        [DoctorId] [int] NOT NULL,
        [BranchId] [int] NOT NULL,
        [ExceptionDate] [date] NOT NULL,
        [Reason] [nvarchar](500) NULL,
        [ExceptionType] [varchar](20) NOT NULL CONSTRAINT [DF_DoctorScheduleException_ExceptionType]  DEFAULT ('Leave'),
        [IsActive] [bit] NOT NULL CONSTRAINT [DF_DoctorScheduleException_IsActive]  DEFAULT ((1)),
        [CreatedBy] [int] NOT NULL,
        [CreatedDate] [datetime] NOT NULL CONSTRAINT [DF_DoctorScheduleException_CreatedDate]  DEFAULT (getutcdate()),
        CONSTRAINT [PK_DoctorScheduleException] PRIMARY KEY CLUSTERED ([ExceptionId] ASC)
    ) ON [PRIMARY]

    ALTER TABLE [dbo].[DoctorScheduleException] WITH CHECK ADD CONSTRAINT [FK_DoctorScheduleException_DoctorMaster] FOREIGN KEY([DoctorId])
    REFERENCES [dbo].[DoctorMaster] ([DoctorId])

    ALTER TABLE [dbo].[DoctorScheduleException] WITH CHECK ADD CONSTRAINT [FK_DoctorScheduleException_BranchMaster] FOREIGN KEY([BranchId])
    REFERENCES [dbo].[BranchMaster] ([BranchId])

    ALTER TABLE [dbo].[DoctorScheduleException] ADD CONSTRAINT [UQ_DoctorScheduleException_DoctorBranchDate] UNIQUE NONCLUSTERED 
    (
        [DoctorId] ASC,
        [BranchId] ASC,
        [ExceptionDate] ASC
    )
END
GO

-- 1. usp_Api_DoctorSchedule_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dsm.ScheduleId,
        dsm.DoctorId,
        ISNULL(doc.NamePrefix + ' ', '') + doc.FullName AS DoctorName,
        dsm.BranchId,
        dsm.RoomId,
        drm.RoomName,
        dsm.DayOfWeek,
        dsm.StartTime,
        dsm.EndTime,
        dsm.SlotDurationMinutes,
        dsm.MaxPatientsPerSlot,
        dsm.MaxPatientsPerSession,
        dsm.ScheduleType,
        dsm.EffectiveFrom,
        dsm.EffectiveTo,
        dsm.IsActive,
        CASE dsm.DayOfWeek
            WHEN 1 THEN 'Monday'
            WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday'
            WHEN 4 THEN 'Thursday'
            WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday'
            WHEN 7 THEN 'Sunday'
        END AS DayName,
        dsm.CreatedBy,
        dsm.CreatedDate,
        dsm.ModifiedBy,
        dsm.ModifiedDate
    FROM DoctorScheduleMaster dsm
    INNER JOIN DoctorMaster doc ON doc.DoctorId = dsm.DoctorId
    LEFT JOIN DoctorRoomMaster drm ON dsm.RoomId = drm.RoomId
    WHERE (@DoctorId IS NULL OR dsm.DoctorId = @DoctorId)
      AND (@BranchId IS NULL OR dsm.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR EXISTS (
            SELECT 1 FROM DoctorDepartmentMap ddm 
            WHERE ddm.DoctorId = dsm.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
          ))
      AND dsm.IsActive = 1
    ORDER BY dsm.DayOfWeek, dsm.StartTime;
END
GO

-- 2. usp_Api_DoctorSchedule_GetById
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetById]
    @ScheduleId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dsm.ScheduleId,
        dsm.DoctorId,
        dsm.BranchId,
        dsm.RoomId,
        drm.RoomName,
        dsm.DayOfWeek,
        dsm.StartTime,
        dsm.EndTime,
        dsm.SlotDurationMinutes,
        dsm.MaxPatientsPerSlot,
        dsm.MaxPatientsPerSession,
        dsm.ScheduleType,
        dsm.EffectiveFrom,
        dsm.EffectiveTo,
        dsm.IsActive,
        CASE dsm.DayOfWeek
            WHEN 1 THEN 'Monday'
            WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday'
            WHEN 4 THEN 'Thursday'
            WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday'
            WHEN 7 THEN 'Sunday'
        END AS DayName
    FROM DoctorScheduleMaster dsm
    LEFT JOIN DoctorRoomMaster drm ON dsm.RoomId = drm.RoomId
    WHERE dsm.ScheduleId = @ScheduleId;
END
GO

-- 3. usp_Api_DoctorSchedule_Upsert
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_Upsert]
    @ScheduleId INT,
    @DoctorId INT,
    @BranchId INT,
    @RoomId INT = NULL,
    @DayOfWeek TINYINT,
    @StartTime TIME,
    @EndTime TIME,
    @SlotDurationMinutes INT,
    @MaxPatientsPerSlot INT,
    @MaxPatientsPerSession INT = NULL,
    @ScheduleType VARCHAR(20),
    @EffectiveFrom DATE,
    @EffectiveTo DATE = NULL,
    @RequestedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Validation
    IF @StartTime >= @EndTime
    BEGIN
        RAISERROR('StartTime must be less than EndTime.', 16, 1);
        RETURN;
    END

    -- Check overlap
    IF EXISTS (
        SELECT 1 FROM DoctorScheduleMaster
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
          AND ScheduleId <> @ScheduleId
          AND (
                (@StartTime >= StartTime AND @StartTime < EndTime) OR
                (@EndTime > StartTime AND @EndTime <= EndTime) OR
                (@StartTime <= StartTime AND @EndTime >= EndTime)
          )
          AND (EffectiveTo IS NULL OR EffectiveTo >= @EffectiveFrom)
          AND (@EffectiveTo IS NULL OR EffectiveFrom <= @EffectiveTo)
    )
    BEGIN
        RAISERROR('Schedule overlaps with an existing active schedule for this day and time period.', 16, 1);
        RETURN;
    END

    IF @ScheduleId = 0
    BEGIN
        INSERT INTO DoctorScheduleMaster (
            DoctorId, BranchId, RoomId, DayOfWeek, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession, ScheduleType, EffectiveFrom, EffectiveTo, CreatedBy
        )
        VALUES (
            @DoctorId, @BranchId, @RoomId, @DayOfWeek, @StartTime, @EndTime, @SlotDurationMinutes, @MaxPatientsPerSlot, @MaxPatientsPerSession, @ScheduleType, @EffectiveFrom, @EffectiveTo, @RequestedByUserId
        );
        SELECT SCOPE_IDENTITY() AS ScheduleId;
    END
    ELSE
    BEGIN
        UPDATE DoctorScheduleMaster
        SET 
            DoctorId = @DoctorId,
            BranchId = @BranchId,
            RoomId = @RoomId,
            DayOfWeek = @DayOfWeek,
            StartTime = @StartTime,
            EndTime = @EndTime,
            SlotDurationMinutes = @SlotDurationMinutes,
            MaxPatientsPerSlot = @MaxPatientsPerSlot,
            MaxPatientsPerSession = @MaxPatientsPerSession,
            ScheduleType = @ScheduleType,
            EffectiveFrom = @EffectiveFrom,
            EffectiveTo = @EffectiveTo,
            ModifiedBy = @RequestedByUserId,
            ModifiedDate = getutcdate()
        WHERE ScheduleId = @ScheduleId;
        
        SELECT @ScheduleId AS ScheduleId;
    END
END
GO

-- 4. usp_Api_DoctorSchedule_Delete
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_Delete]
    @ScheduleId INT,
    @DeletedBy INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WarningMessage NVARCHAR(500) = NULL;

    -- Soft delete
    UPDATE DoctorScheduleMaster
    SET IsActive = 0, ModifiedBy = @DeletedBy, ModifiedDate = getutcdate()
    WHERE ScheduleId = @ScheduleId;

    -- Check future bookings (if PatientOPDService has ScheduleId)
    -- We use dynamic sql check if table altered yet or we can just safely join if we create the other script too.
    -- Assuming Phase 2 alters the table, we do:
    IF EXISTS (
        SELECT 1 FROM sys.columns 
        WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService')
    )
    BEGIN
        DECLARE @Sql NVARCHAR(MAX) = N'
        IF EXISTS (SELECT 1 FROM PatientOPDService WHERE ScheduleId = @p_ScheduleId AND VisitDate > GETDATE() AND Status <> ''Cancelled'')
        BEGIN
            SET @p_Warning = ''Warning: There are future patient bookings associated with this deleted schedule.''
        END';
        
        EXEC sp_executesql @Sql, N'@p_ScheduleId INT, @p_Warning NVARCHAR(500) OUTPUT', @ScheduleId, @WarningMessage OUTPUT;
    END

    SELECT 1 AS Success, @WarningMessage AS Warning;
END
GO

-- 5. usp_Api_DoctorSchedule_GetAvailableSlots
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetAvailableSlots]
    @DoctorId INT,
    @BranchId INT,
    @Date DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DayOfWeek TINYINT;
    -- Map to 1=Mon, 7=Sun regardless of @@DATEFIRST
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
                     
    -- Check Exception
    DECLARE @ExceptionReason NVARCHAR(500);
    IF EXISTS (SELECT 1 FROM DoctorScheduleException WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @Date AND IsActive = 1)
    BEGIN
        SELECT TOP 1 @ExceptionReason = Reason FROM DoctorScheduleException WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @Date AND IsActive = 1;
        
        -- Return Exception state
        SELECT 1 AS HasException, @ExceptionReason AS ExceptionReason;
        -- Empty slots
        SELECT TOP 0 0 AS ScheduleId, '' AS SlotTime, 0 AS BookedCount, 0 AS MaxPerSlot, 0 AS IsAvailable;
        RETURN;
    END

    -- Ensure PatientOPDService ScheduleId exists
    DECLARE @PatientColExists BIT = 0;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'ScheduleId' AND Object_ID = Object_ID(N'dbo.PatientOPDService'))
        SET @PatientColExists = 1;

    -- Generate Slots
    CREATE TABLE #AvailableSlots (
        ScheduleId INT,
        SlotTime TIME,
        BookedCount INT,
        MaxPerSlot INT,
        IsAvailable BIT,
        MaxPatientsPerSession INT
    );

    DECLARE @CurScheduleId INT, @CurStartTime TIME, @CurEndTime TIME, @CurDuration INT, @CurMaxPerSlot INT, @CurMaxSession INT;
    
    DECLARE curSchedules CURSOR FOR
    SELECT ScheduleId, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession
    FROM DoctorScheduleMaster
    WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND DayOfWeek = @DayOfWeek AND IsActive = 1
      AND EffectiveFrom <= @Date AND (EffectiveTo IS NULL OR EffectiveTo >= @Date);

    OPEN curSchedules;
    FETCH NEXT FROM curSchedules INTO @CurScheduleId, @CurStartTime, @CurEndTime, @CurDuration, @CurMaxPerSlot, @CurMaxSession;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @SlotTime TIME = @CurStartTime;
        
        WHILE DATEADD(MINUTE, @CurDuration, @SlotTime) <= @CurEndTime
        BEGIN
            DECLARE @Booked INT = 0;
            
            IF @PatientColExists = 1
            BEGIN
                DECLARE @CountSql NVARCHAR(MAX) = N'SELECT @cnt = COUNT(*) FROM PatientOPDService WHERE ScheduleId = @sid AND CAST(VisitDate AS DATE) = @d AND AppointmentTime = @st AND Status <> ''Cancelled''';
                EXEC sp_executesql @CountSql, N'@sid INT, @d DATE, @st TIME, @cnt INT OUTPUT', @CurScheduleId, @Date, @SlotTime, @Booked OUTPUT;
            END

            INSERT INTO #AvailableSlots (ScheduleId, SlotTime, BookedCount, MaxPerSlot, IsAvailable, MaxPatientsPerSession)
            VALUES (@CurScheduleId, @SlotTime, @Booked, @CurMaxPerSlot, CASE WHEN @Booked < @CurMaxPerSlot THEN 1 ELSE 0 END, @CurMaxSession);

            SET @SlotTime = DATEADD(MINUTE, @CurDuration, @SlotTime);
        END

        FETCH NEXT FROM curSchedules INTO @CurScheduleId, @CurStartTime, @CurEndTime, @CurDuration, @CurMaxPerSlot, @CurMaxSession;
    END
    CLOSE curSchedules;
    DEALLOCATE curSchedules;

    -- Handle MaxPatientsPerSession
    -- If total booked for a schedule >= MaxPatientsPerSession, mark remaining slots IsAvailable = 0
    IF @PatientColExists = 1
    BEGIN
        UPDATE s
        SET s.IsAvailable = 0
        FROM #AvailableSlots s
        WHERE s.MaxPatientsPerSession IS NOT NULL 
        AND (
            SELECT ISNULL(COUNT(*), 0) FROM PatientOPDService p 
            WHERE p.ScheduleId = s.ScheduleId AND CAST(p.VisitDate AS DATE) = @Date AND p.Status <> 'Cancelled'
        ) >= s.MaxPatientsPerSession;
    END

    SELECT 0 AS HasException, NULL AS ExceptionReason;
    
    SELECT 
        ScheduleId,
        CONVERT(varchar(5), SlotTime, 108) AS SlotTime, 
        BookedCount, 
        MaxPerSlot, 
        IsAvailable 
    FROM #AvailableSlots
    ORDER BY SlotTime;

    DROP TABLE #AvailableSlots;
END
GO

-- 2. usp_Api_DoctorScheduleException_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        e.ExceptionId,
        e.DoctorId,
        ISNULL(doc.NamePrefix + ' ', '') + doc.FullName AS DoctorName,
        e.BranchId,
        e.ExceptionDate,
        e.Reason,
        e.ExceptionType,
        e.IsActive,
        e.CreatedBy,
        e.CreatedDate
    FROM DoctorScheduleException e
    INNER JOIN DoctorMaster doc ON doc.DoctorId = e.DoctorId
    WHERE (@DoctorId IS NULL OR e.DoctorId = @DoctorId)
      AND (@BranchId IS NULL OR e.BranchId = @BranchId)
      AND (@FromDate IS NULL OR e.ExceptionDate >= @FromDate)
      AND (@ToDate IS NULL OR e.ExceptionDate <= @ToDate)
      AND (@DepartmentId IS NULL OR EXISTS (
            SELECT 1 FROM DoctorDepartmentMap ddm 
            WHERE ddm.DoctorId = e.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
          ))
      AND e.IsActive = 1
    ORDER BY e.ExceptionDate DESC;
END
GO

-- 7. usp_Api_DoctorScheduleException_Upsert
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_Upsert]
    @ExceptionId INT = 0,
    @DoctorId INT,
    @BranchId INT,
    @ExceptionDate DATE,
    @Reason NVARCHAR(500),
    @ExceptionType VARCHAR(20),
    @RequestedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1 FROM DoctorScheduleException 
        WHERE DoctorId = @DoctorId AND BranchId = @BranchId AND ExceptionDate = @ExceptionDate AND IsActive = 1 AND ExceptionId <> @ExceptionId
    )
    BEGIN
        RAISERROR('Exception already exists for this date.', 16, 1);
        RETURN;
    END

    IF @ExceptionId = 0
    BEGIN
        INSERT INTO DoctorScheduleException (DoctorId, BranchId, ExceptionDate, Reason, ExceptionType, CreatedBy)
        VALUES (@DoctorId, @BranchId, @ExceptionDate, @Reason, @ExceptionType, @RequestedByUserId);
        
        SELECT SCOPE_IDENTITY() AS ExceptionId;
    END
    ELSE
    BEGIN
        UPDATE DoctorScheduleException
        SET ExceptionDate = @ExceptionDate,
            Reason = @Reason,
            ExceptionType = @ExceptionType
        WHERE ExceptionId = @ExceptionId;
        
        SELECT @ExceptionId AS ExceptionId;
    END
END
GO

-- 8. usp_Api_DoctorScheduleException_Delete
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_Delete]
    @ExceptionId INT,
    @DeletedBy INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE DoctorScheduleException
    SET IsActive = 0
    WHERE ExceptionId = @ExceptionId;

    SELECT 1 AS Success;
END
GO
