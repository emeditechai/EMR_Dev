-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2471  Marketing Executive App: one visit per doctor per day.
--   usp_Mkt_Visit_Create refuses a second visit to the same doctor on the same day ("Already visited today") once a
--   visit that day was VERIFIED. If the earlier visit was OUTSIDE / UNCONFIRMED (or no GPS), one more try is allowed,
--   so at most 2 visits a day. A resend of the same visit (same ClientEventId) still returns the saved visit.
--   Needs 2459. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Visit_Create
    @UserId           INT,
    @CompanyId        INT,
    @BranchId         INT,
    @ForecastDoctorId INT,
    @ClientEventId    NVARCHAR(50),
    @DeviceTime       DATETIME       = NULL,
    @Latitude         DECIMAL(10, 8) = NULL,
    @Longitude        DECIMAL(11, 8) = NULL,
    @AccuracyM        DECIMAL(8, 2)  = NULL,
    @IsMock           BIT            = 0,
    @Outcome          VARCHAR(15),
    @Notes            NVARCHAR(1000) = NULL,
    @NextFollowUpDate DATE           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    DECLARE @VisitId INT = (SELECT VisitId FROM dbo.ForecastDoctorVisit WHERE UserId = @UserId AND ClientEventId = @ClientEventId);
    DECLARE @Radius INT = 100, @MaxAddr INT = 500, @MaxKmph INT = 80;
    SELECT @Radius = VisitRadiusM, @MaxAddr = AddressPinMaxDistanceM, @MaxKmph = MaxTravelKmph FROM dbo.MarketingSettings WHERE CompanyId = @CompanyId;
    IF @VisitId IS NULL
    BEGIN
        SET @Outcome = UPPER(LTRIM(RTRIM(ISNULL(@Outcome, ''))));
        SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
        IF @Outcome NOT IN ('INTERESTED', 'FOLLOW_UP', 'NOT_AVAILABLE', 'NOT_INTERESTED') THROW 50000, N'Choose the outcome of the visit.', 1;
        IF @NextFollowUpDate < CAST(GETDATE() AS DATE) THROW 50000, N'The follow-up date cannot be in the past.', 1;
        IF @Outcome IN ('FOLLOW_UP', 'INTERESTED') AND @NextFollowUpDate IS NULL THROW 50000, N'Set the next follow-up date.', 1;

        DECLARE @Stage VARCHAR(10), @PinLat DECIMAL(10, 8), @PinLng DECIMAL(11, 8), @PinSrc VARCHAR(7), @PinStatus VARCHAR(11),
                @Distance INT, @Status VARCHAR(12), @Visits INT, @Flag NVARCHAR(300);
        BEGIN TRAN;
        SELECT @Stage = Stage, @PinLat = Latitude, @PinLng = Longitude, @PinSrc = ISNULL(PinSource, 'GPS'), @PinStatus = PinStatus
          FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1;
        IF @Stage IS NULL THROW 50000, N'This doctor is not in your list.', 1;
        IF @Stage = 'LOST' THROW 50000, N'This doctor is marked lost. Open the doctor again to log a visit.', 1;
        -- 2471: one visit per doctor per day. A Verified visit today closes the day; after an Outside / Unconfirmed /
        -- No-GPS visit one more try is allowed (the executive may not have been close enough the first time).
        DECLARE @TodayVisits INT, @TodayVerified INT;
        SELECT @TodayVisits = COUNT(*), @TodayVerified = ISNULL(SUM(CASE WHEN VisitStatus = 'VERIFIED' THEN 1 ELSE 0 END), 0)
          FROM dbo.ForecastDoctorVisit
         WHERE ForecastDoctorId = @ForecastDoctorId AND VisitDate >= CAST(CAST(GETDATE() AS DATE) AS DATETIME);
        IF @TodayVerified > 0 THROW 50000, N'Already visited today.', 1;
        IF @TodayVisits >= 2 THROW 50000, N'Already visited today. Only one more try is allowed after a visit that was not verified.', 1;

        IF ISNULL(@IsMock, 0) = 1 SET @Status = 'MOCK';
        ELSE IF @Latitude IS NULL OR @Longitude IS NULL SET @Status = 'NO_GPS';
        ELSE IF @PinLat IS NULL SET @Status = 'NO_PIN';
        ELSE
        BEGIN
            SET @Distance = CAST(ROUND(geography::Point(@Latitude, @Longitude, 4326).STDistance(geography::Point(@PinLat, @PinLng, 4326)), 0) AS INT);
            SET @Status = CASE WHEN @PinSrc = 'ADDRESS' THEN CASE WHEN @Distance <= ISNULL(@MaxAddr, 500) THEN 'UNCONFIRMED' ELSE 'OUTSIDE' END
                               WHEN @Distance > ISNULL(@Radius, 100) THEN 'OUTSIDE'
                               WHEN @PinStatus IN ('FLAGGED', 'REJECTED') THEN 'UNCONFIRMED'
                               ELSE 'VERIFIED' END;
        END

        -- check 5: further from the previous visit of the day than the time between them allows
        IF @Latitude IS NOT NULL AND ISNULL(@IsMock, 0) = 0
        BEGIN
            DECLARE @PrevLat DECIMAL(10, 8), @PrevLng DECIMAL(11, 8), @PrevDate DATETIME;
            SELECT TOP 1 @PrevLat = Latitude, @PrevLng = Longitude, @PrevDate = VisitDate FROM dbo.ForecastDoctorVisit
             WHERE UserId = @UserId AND Latitude IS NOT NULL AND IsMock = 0 AND VisitDate >= CAST(CAST(GETDATE() AS DATE) AS DATETIME)
             ORDER BY VisitDate DESC;
            IF @PrevDate IS NOT NULL
            BEGIN
                DECLARE @Km FLOAT = geography::Point(@Latitude, @Longitude, 4326).STDistance(geography::Point(@PrevLat, @PrevLng, 4326)) / 1000.0;
                DECLARE @Min FLOAT = DATEDIFF(SECOND, @PrevDate, GETDATE()) / 60.0;
                IF @Km >= 1 AND @Km / (CASE WHEN @Min < 1 THEN 1 ELSE @Min END / 60.0) > ISNULL(@MaxKmph, 80)
                    SET @Flag = N'Too far from the previous visit for the time between them (' + dbo.fn_Mkt_DistanceText(@Km * 1000)
                              + N' in ' + CAST(CAST(ROUND(@Min, 0) AS INT) AS NVARCHAR(10)) + N' min).';
            END
        END

        INSERT dbo.ForecastDoctorVisit (ForecastDoctorId, ExecutiveId, UserId, BranchId, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM,
                                        IsMock, DistanceM, VisitStatus, Outcome, Notes, NextFollowUpDate, FlagReason)
        VALUES (@ForecastDoctorId, @Exec, @UserId, @BranchId, @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM,
                ISNULL(@IsMock, 0), @Distance, @Status, @Outcome, @Notes, @NextFollowUpDate, @Flag);
        SET @VisitId = CAST(SCOPE_IDENTITY() AS INT);

        SELECT @Visits = COUNT(*) FROM dbo.ForecastDoctorVisit WHERE ForecastDoctorId = @ForecastDoctorId;
        DECLARE @Next VARCHAR(10) = CASE WHEN @Stage = 'PROSPECT' THEN 'CONTACTED'
                                         WHEN @Stage = 'CONTACTED' AND @Visits >= 2 AND @Outcome = 'INTERESTED' THEN 'ENGAGED' END;
        UPDATE dbo.ForecastDoctor
           SET Stage = ISNULL(@Next, Stage), NextFollowUpDate = ISNULL(@NextFollowUpDate, NextFollowUpDate), ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE ForecastDoctorId = @ForecastDoctorId;
        IF @Next IS NOT NULL
            INSERT dbo.ForecastDoctorStageLog (ForecastDoctorId, FromStage, ToStage, Reason, ChangedBy)
            VALUES (@ForecastDoctorId, @Stage, @Next, N'Visit', @UserId);
        COMMIT;
    END

    SELECT v.VisitId, v.VisitStatus, v.DistanceM, v.Outcome, v.FlagReason, l.Stage, @Radius AS VisitRadiusM, @MaxAddr AS AddressPinMaxDistanceM,
           l.PinSource, l.PinStatus, l.PinFlagReason,
           -- an address pin and a good GPS reading near it: the app offers to save this position as the clinic location
           CAST(CASE WHEN l.PinSource = 'ADDRESS' AND v.VisitStatus = 'UNCONFIRMED' AND ISNULL(v.AccuracyM, 0) <= 100 THEN 1 ELSE 0 END AS BIT) AS CanUpgradePin
      FROM dbo.ForecastDoctorVisit v
      JOIN dbo.ForecastDoctor l ON l.ForecastDoctorId = v.ForecastDoctorId
     WHERE v.VisitId = @VisitId;
END
GO
PRINT 'Script 2471 applied: one marketing visit per doctor per day (one retry after a visit that was not verified).';
GO
