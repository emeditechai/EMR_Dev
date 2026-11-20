-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2497  Marketing Executive App: a field day left open on an earlier date no longer blocks Start Field Day.
--   Before: the home screen looked at today's field day only ("Not in the field"), but START refused while ANY day was
--   open ("Your field day has already started"), so a day not ended yesterday blocked the executive for good.
--   Now usp_Mkt_FieldDay, on START, first closes an open day of an earlier date: EndDate = its last route point
--   (MarketingLocationPoint), else its start time. A day still open from TODAY is kept and START is refused as before.
--   END with only an earlier open day closes that day the same way.
--   Needs 2446. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Mkt_FieldDay
    @UserId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @Action    VARCHAR(5),
    @Latitude  DECIMAL(10, 8) = NULL,
    @Longitude DECIMAL(11, 8) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    IF @Exec IS NULL THROW 50000, N'This login is not an active marketing executive.', 1;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    -- 2497: days left open on an earlier date are closed at their last route point (else at their start)
    IF @Action = 'START'
        UPDATE f
           SET EndDate = ISNULL((SELECT MAX(p.PointTime) FROM dbo.MarketingLocationPoint p WHERE p.DayId = f.DayId AND p.PointTime >= f.StartDate), f.StartDate)
          FROM dbo.MarketingFieldDay f
         WHERE f.UserId = @UserId AND f.EndDate IS NULL AND f.DutyDate < @Today;

    DECLARE @Open INT = (SELECT TOP 1 DayId FROM dbo.MarketingFieldDay WHERE UserId = @UserId AND EndDate IS NULL ORDER BY DayId DESC);

    IF @Action = 'START'
    BEGIN
        IF @Open IS NOT NULL THROW 50000, N'Your field day has already started.', 1;
        INSERT dbo.MarketingFieldDay (CompanyId, BranchId, UserId, ExecutiveId, DutyDate, StartDate, StartLat, StartLng)
        VALUES (@CompanyId, @BranchId, @UserId, @Exec, @Today, GETDATE(), @Latitude, @Longitude);
        SET @Open = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE IF @Action = 'END'
    BEGIN
        IF @Open IS NULL THROW 50000, N'Your field day has not started.', 1;
        IF (SELECT DutyDate FROM dbo.MarketingFieldDay WHERE DayId = @Open) < @Today
            -- a day from an earlier date: closed at its last route point, not now
            UPDATE f
               SET EndDate = ISNULL((SELECT MAX(p.PointTime) FROM dbo.MarketingLocationPoint p WHERE p.DayId = f.DayId AND p.PointTime >= f.StartDate), f.StartDate)
              FROM dbo.MarketingFieldDay f WHERE f.DayId = @Open;
        ELSE
            UPDATE dbo.MarketingFieldDay SET EndDate = GETDATE(), EndLat = @Latitude, EndLng = @Longitude WHERE DayId = @Open;
    END
    ELSE THROW 50000, N'Action must be START or END.', 1;

    SELECT DayId, StartDate AS FieldStart, EndDate AS FieldEnd, CAST(CASE WHEN EndDate IS NULL THEN 1 ELSE 0 END AS BIT) AS OnField
      FROM dbo.MarketingFieldDay WHERE DayId = @Open;
END
GO
PRINT 'Script 2497 applied: a field day left open on an earlier date is closed when a new one starts.';
GO
