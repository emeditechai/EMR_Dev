-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2462  Reports > LAB > Marketing Field Report (EMR.Web): what the Marketing Executive App recorded, for the office to check.
--   * Visits      - every app visit with the doctor's address, the visit status, the distance from the clinic pin, how
--                   the pin was set (GPS / address) and its flags, and both points for the map.
--   * Field days  - per executive per day: start / end, hours, km covered (from the route points), visits made.
--   * Route       - one field day: its points and its visits, for the map.
--   * Doctors     - the forecast doctors (leads) with address, stage, clinic location source / status / flags, visits.
--   An executive login sees its own records only (fn_Mkt_OwnExecutive, 2447). Branch = the signed-in branch.
--   km covered: consecutive route points (and the start / end positions) of the day; a step counts when both readings are
--   accurate to 50 m, it is at least 25 m (GPS jitter while standing is left out) and not faster than 150 km/h (jumps).
--   Page REPORTS.LABMARKETINGFIELD (VIEW), in Reports > LAB beside Marketing Executive Business. No role grants. Needs 2446, 2447, 2459. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ── visits ───────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktField_Visits
    @CompanyId INT, @BranchId INT, @UserId INT, @FromDate DATE, @ToDate DATE,
    @ExecutiveId INT = NULL, @Status VARCHAR(12) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL SET @ExecutiveId = @own;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Status = NULLIF(UPPER(LTRIM(RTRIM(@Status))), ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @like NVARCHAR(110) = N'%' + @Search + N'%';

    SELECT v.VisitId, v.VisitDate, v.ExecutiveId, e.ExecutiveName, e.ExecutiveCode,
           l.ForecastDoctorId, LTRIM(RTRIM(ISNULL(l.NamePrefix + N' ', N'') + l.FullName)) AS DoctorName, l.PhoneNumber AS DoctorMobile,
           l.ClinicName, l.Address, l.Stage,
           v.VisitStatus, v.DistanceM, v.AccuracyM, v.IsMock, v.Latitude AS VisitLat, v.Longitude AS VisitLng, v.FlagReason,
           v.Outcome, v.Notes, v.NextFollowUpDate,
           l.Latitude AS PinLat, l.Longitude AS PinLng, l.PinSource, l.PinStatus, l.PinFlagReason, l.AddressDistanceM,
           l.GeoLat, l.GeoLng, l.PinSetDate
      FROM dbo.ForecastDoctorVisit v
      JOIN dbo.ForecastDoctor l ON l.ForecastDoctorId = v.ForecastDoctorId
      JOIN dbo.MarketingExecutive e ON e.ExecutiveId = v.ExecutiveId
     WHERE e.CompanyId = @CompanyId AND v.BranchId = @BranchId AND v.VisitDate >= @FromDate AND v.VisitDate < @To
       AND (@ExecutiveId IS NULL OR v.ExecutiveId = @ExecutiveId)
       AND (@Status IS NULL OR v.VisitStatus = @Status OR (@Status = 'FLAGGED' AND v.FlagReason IS NOT NULL))
       AND (@Search IS NULL OR l.FullName LIKE @like OR l.ClinicName LIKE @like OR l.Address LIKE @like OR e.ExecutiveName LIKE @like OR l.PhoneNumber LIKE @like)
     ORDER BY v.VisitDate DESC, v.VisitId DESC;

    -- the executives to choose (own only for an executive login)
    SELECT e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, e.IsActive
      FROM dbo.MarketingExecutive e
     WHERE e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND e.LoginUserId IS NOT NULL AND (@own IS NULL OR e.ExecutiveId = @own)
     ORDER BY e.IsActive DESC, e.ExecutiveName;
END
GO

-- ── field days with km covered ───────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktField_Days
    @CompanyId INT, @BranchId INT, @UserId INT, @FromDate DATE, @ToDate DATE, @ExecutiveId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL SET @ExecutiveId = @own;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END

    SELECT d.DayId, d.UserId, d.ExecutiveId, d.DutyDate, d.StartDate, d.EndDate, d.StartLat, d.StartLng, d.EndLat, d.EndLng
      INTO #D
      FROM dbo.MarketingFieldDay d
     WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DutyDate BETWEEN @FromDate AND @ToDate
       AND (@ExecutiveId IS NULL OR d.ExecutiveId = @ExecutiveId);

    -- the day's positions in time order: start, route points, end
    ;WITH pts AS (
        SELECT d.DayId, d.StartDate AS T, d.StartLat AS Lat, d.StartLng AS Lng, CAST(NULL AS DECIMAL(8, 2)) AS Acc, CAST(0 AS BIT) AS Mock
          FROM #D d WHERE d.StartLat IS NOT NULL
        UNION ALL
        SELECT p.DayId, p.PointTime, p.Latitude, p.Longitude, p.AccuracyM, p.IsMock FROM dbo.MarketingLocationPoint p JOIN #D d ON d.DayId = p.DayId
        UNION ALL
        SELECT d.DayId, d.EndDate, d.EndLat, d.EndLng, NULL, 0 FROM #D d WHERE d.EndLat IS NOT NULL AND d.EndDate IS NOT NULL),
    ordered AS (
        SELECT DayId, T, Lat, Lng, Acc, Mock,
               LAG(T) OVER (PARTITION BY DayId ORDER BY T) AS PT, LAG(Lat) OVER (PARTITION BY DayId ORDER BY T) AS PLat,
               LAG(Lng) OVER (PARTITION BY DayId ORDER BY T) AS PLng, LAG(Acc) OVER (PARTITION BY DayId ORDER BY T) AS PAcc,
               LAG(Mock) OVER (PARTITION BY DayId ORDER BY T) AS PMock
          FROM pts WHERE Mock = 0),
    steps AS (
        SELECT DayId, geography::Point(Lat, Lng, 4326).STDistance(geography::Point(PLat, PLng, 4326)) AS M,
               NULLIF(DATEDIFF(SECOND, PT, T), 0) AS Sec
          FROM ordered WHERE PLat IS NOT NULL AND ISNULL(Acc, 0) <= 50 AND ISNULL(PAcc, 0) <= 50)
    SELECT DayId, CAST(ISNULL(SUM(CASE WHEN M >= 25 AND (Sec IS NULL OR M / Sec * 3.6 <= 150) THEN M END), 0) / 1000.0 AS DECIMAL(9, 2)) AS Km
      INTO #K FROM steps GROUP BY DayId;

    SELECT d.DayId, d.DutyDate, d.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, d.StartDate, d.EndDate,
           CAST(DATEDIFF(MINUTE, d.StartDate, ISNULL(d.EndDate, GETDATE())) / 60.0 AS DECIMAL(6, 1)) AS Hours,
           CAST(CASE WHEN d.EndDate IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
           d.StartLat, d.StartLng, d.EndLat, d.EndLng,
           ISNULL(k.Km, 0) AS Km,
           (SELECT COUNT(1) FROM dbo.MarketingLocationPoint p WHERE p.DayId = d.DayId) AS Points,
           (SELECT COUNT(1) FROM dbo.MarketingLocationPoint p WHERE p.DayId = d.DayId AND p.IsMock = 1) AS MockPoints,
           ISNULL(v.Visits, 0) AS Visits, ISNULL(v.Verified, 0) AS Verified, ISNULL(v.Unconfirmed, 0) AS Unconfirmed,
           ISNULL(v.Outside, 0) AS Outside, ISNULL(v.Flagged, 0) AS Flagged
      FROM #D d
      JOIN dbo.MarketingExecutive e ON e.ExecutiveId = d.ExecutiveId
      LEFT JOIN #K k ON k.DayId = d.DayId
      OUTER APPLY (SELECT COUNT(1) AS Visits, SUM(CASE WHEN fv.VisitStatus = 'VERIFIED' THEN 1 ELSE 0 END) AS Verified,
                          SUM(CASE WHEN fv.VisitStatus = 'UNCONFIRMED' THEN 1 ELSE 0 END) AS Unconfirmed,
                          SUM(CASE WHEN fv.VisitStatus = 'OUTSIDE' THEN 1 ELSE 0 END) AS Outside,
                          SUM(CASE WHEN fv.FlagReason IS NOT NULL OR fv.VisitStatus IN ('MOCK', 'NO_GPS') THEN 1 ELSE 0 END) AS Flagged
                     FROM dbo.ForecastDoctorVisit fv
                    WHERE fv.UserId = d.UserId AND fv.BranchId = @BranchId
                      AND fv.VisitDate >= d.StartDate AND fv.VisitDate <= ISNULL(d.EndDate, GETDATE())) v
     ORDER BY d.DutyDate DESC, d.StartDate DESC;
END
GO

-- ── one field day for the map: header, route points, visits made during it ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktField_Route
    @CompanyId INT, @BranchId INT, @UserId INT, @DayId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF NOT EXISTS (SELECT 1 FROM dbo.MarketingFieldDay WHERE DayId = @DayId AND CompanyId = @CompanyId AND BranchId = @BranchId
                     AND (@own IS NULL OR ExecutiveId = @own))
        THROW 50000, N'The field day was not found.', 1;

    SELECT d.DayId, d.DutyDate, e.ExecutiveName, e.ExecutiveCode, d.StartDate, d.EndDate, d.StartLat, d.StartLng, d.EndLat, d.EndLng
      FROM dbo.MarketingFieldDay d JOIN dbo.MarketingExecutive e ON e.ExecutiveId = d.ExecutiveId WHERE d.DayId = @DayId;

    SELECT p.PointTime, p.Latitude, p.Longitude, p.AccuracyM, p.IsMock
      FROM dbo.MarketingLocationPoint p WHERE p.DayId = @DayId ORDER BY p.PointTime;

    SELECT v.VisitId, v.VisitDate, v.VisitStatus, v.DistanceM, v.FlagReason, v.Latitude AS VisitLat, v.Longitude AS VisitLng,
           LTRIM(RTRIM(ISNULL(l.NamePrefix + N' ', N'') + l.FullName)) AS DoctorName, l.ClinicName, l.Address,
           l.Latitude AS PinLat, l.Longitude AS PinLng, l.PinSource, l.PinStatus
      FROM dbo.MarketingFieldDay d
      JOIN dbo.ForecastDoctorVisit v ON v.UserId = d.UserId AND v.BranchId = d.BranchId
                                    AND v.VisitDate >= d.StartDate AND v.VisitDate <= ISNULL(d.EndDate, GETDATE())
      JOIN dbo.ForecastDoctor l ON l.ForecastDoctorId = v.ForecastDoctorId
     WHERE d.DayId = @DayId
     ORDER BY v.VisitDate;
END
GO

-- ── forecast doctors (leads) with address and clinic location ─────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktField_Doctors
    @CompanyId INT, @BranchId INT, @UserId INT, @ExecutiveId INT = NULL, @Stage VARCHAR(10) = NULL,
    @Pin VARCHAR(11) = NULL,      -- FLAGGED / UNCONFIRMED / NONE (no location) / OK
    @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL SET @ExecutiveId = @own;
    SET @Stage = NULLIF(UPPER(LTRIM(RTRIM(@Stage))), ''); SET @Pin = NULLIF(UPPER(LTRIM(RTRIM(@Pin))), '');
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';

    SELECT l.ForecastDoctorId, LTRIM(RTRIM(ISNULL(l.NamePrefix + N' ', N'') + l.FullName)) AS DoctorName, l.PhoneNumber AS DoctorMobile,
           sp.SpecialityName, l.ClinicName, l.Address, l.Stage, l.ExpectedMonthlyReferrals, l.NextFollowUpDate, l.CreatedDate,
           l.ExecutiveId, e.ExecutiveName, e.ExecutiveCode,
           l.Latitude AS PinLat, l.Longitude AS PinLng, l.PinSource, l.PinStatus, l.PinFlagReason, l.AddressDistanceM, l.PinSetDate,
           l.GeoLat, l.GeoLng, l.GeoAddress, l.PhoneLatAtPin, l.PhoneLngAtPin,
           l.DoctorId, dm.IsActive AS DoctorActive,
           ISNULL(v.Visits, 0) AS Visits, ISNULL(v.Verified, 0) AS Verified, v.LastVisitDate,
           (SELECT TOP 1 x.VisitStatus FROM dbo.ForecastDoctorVisit x WHERE x.ForecastDoctorId = l.ForecastDoctorId ORDER BY x.VisitDate DESC) AS LastVisitStatus
      FROM dbo.ForecastDoctor l
      JOIN dbo.MarketingExecutive e ON e.ExecutiveId = l.ExecutiveId
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = l.PrimarySpecialityId
      LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = l.DoctorId
      OUTER APPLY (SELECT COUNT(1) AS Visits, SUM(CASE WHEN x.VisitStatus = 'VERIFIED' THEN 1 ELSE 0 END) AS Verified, MAX(x.VisitDate) AS LastVisitDate
                     FROM dbo.ForecastDoctorVisit x WHERE x.ForecastDoctorId = l.ForecastDoctorId) v
     WHERE l.CompanyId = @CompanyId AND l.BranchId = @BranchId AND l.IsActive = 1
       AND (@ExecutiveId IS NULL OR l.ExecutiveId = @ExecutiveId)
       AND (@Stage IS NULL OR l.Stage = @Stage)
       AND (@Pin IS NULL OR (@Pin = 'NONE' AND l.Latitude IS NULL) OR (@Pin <> 'NONE' AND l.PinStatus = @Pin))
       AND (@Search IS NULL OR l.FullName LIKE @like OR l.ClinicName LIKE @like OR l.Address LIKE @like OR l.PhoneNumber LIKE @like OR e.ExecutiveName LIKE @like)
     ORDER BY CASE l.PinStatus WHEN 'FLAGGED' THEN 0 WHEN 'UNCONFIRMED' THEN 1 ELSE 2 END, l.CreatedDate DESC;
END
GO

-- ── page (Reports > LAB menu) ───────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB'), @page INT, @view INT;
IF @menu IS NULL THROW 51460, 'Menu REPORTS.LAB is missing.', 1;
-- an earlier run placed the page in the LAB menu as LAB.MARKETINGFIELD: move that row (its role permissions stay with it)
IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.LABMARKETINGFIELD')
    UPDATE dbo.PageMaster SET Page_Code = N'REPORTS.LABMARKETINGFIELD', Menu_ID = @menu WHERE Page_Code = N'LAB.MARKETINGFIELD';
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABMARKETINGFIELD', @Title = N'Marketing Field Report',
     @Controller = N'MarketingField', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 17, @Icon = N'bi bi-map me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingField', @Action = N'Index', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingField', @Action = N'VisitData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingField', @Action = N'DayData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingField', @Action = N'RouteData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'MarketingField', @Action = N'DoctorData', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2462 applied: Reports > LAB > Marketing Field Report (visits, field days with km, routes, forecast doctors).';
GO
