-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2460  Marketing Executive App: field-day route points that arrive after the field day has ended are kept.
--   Before (2446) usp_Mkt_Location_Batch only accepted points while a field day was open; End Field Day closed the day
--   first and the app sent its last points afterwards, so they were dropped (and removed from the phone). Now each point
--   goes to the executive's field day whose time covers it (start .. end, or still open); points outside every field
--   day are still not saved. The app also sends its points before ending the day.
--   Needs 2446. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Location_Batch
    @UserId INT,
    @Json   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.MarketingLocationPoint (UserId, DayId, PointTime, Latitude, Longitude, AccuracyM, SpeedMps, IsMock)
    SELECT DISTINCT @UserId, d.DayId, j.[time], j.lat, j.lng, j.accuracy, j.speed, ISNULL(j.mock, 0)
      FROM OPENJSON(@Json) WITH ([time] DATETIME '$.time', lat DECIMAL(10, 8) '$.lat', lng DECIMAL(11, 8) '$.lng',
                                 accuracy DECIMAL(8, 2) '$.accuracy', speed DECIMAL(8, 2) '$.speed', mock BIT '$.mock') j
     CROSS APPLY (SELECT TOP 1 f.DayId FROM dbo.MarketingFieldDay f
                   WHERE f.UserId = @UserId AND f.StartDate <= DATEADD(MINUTE, 1, j.[time])          -- a minute of clock difference
                     AND (f.EndDate IS NULL OR f.EndDate >= DATEADD(MINUTE, -1, j.[time]))
                   ORDER BY f.DayId DESC) d
     WHERE j.[time] IS NOT NULL AND j.lat IS NOT NULL AND j.lng IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.MarketingLocationPoint p WHERE p.UserId = @UserId AND p.PointTime = j.[time]);
    SELECT @@ROWCOUNT AS Saved;
END
GO
PRINT 'Script 2460 applied: field-day route points are kept when they arrive after the day ends.';
GO
