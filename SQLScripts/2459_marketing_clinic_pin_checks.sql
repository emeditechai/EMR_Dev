-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2459  Marketing Executive App: clinic location from GPS or from the address, and the pin checks (phase 1 of
--       "Clinic Location and Visit Verification" in the marketing module spec).
--   * Adding a doctor (or Save Clinic Location) the executive says whether they are at the clinic:
--       GPS     - the phone's position is the pin (no mock location, accurate to 100 m);
--       ADDRESS - the pin is where the typed address is found on the map (EMR.Api geocodes it on the server); the
--                 phone's own position at that moment is kept for the office. An address pin is UNCONFIRMED: visits
--                 near it count, but never as Verified, until the executive saves the GPS position at the clinic.
--   * EMR.Api also geocodes the address of a GPS pin. usp_Mkt_Pin_Check then flags the pin (PinStatus FLAGGED) when:
--       1. it is more than MarketingSettings.AddressPinMaxDistanceM (500 m) from the address;
--       5. two or more doctors of other clinics of the same executive are pinned within SamePinRadiusM (50 m);
--          it is within BranchPinRadiusM (150 m) of the branch; or the field-day route (MarketingLocationPoint) was
--          more than 1 km away in the 15 minutes before the pin was saved.
--   * A visit within the radius of a flagged pin is UNCONFIRMED (not VERIFIED). A visit that is further from the
--     executive's previous visit of the day than MaxTravelKmph allows for the time between them gets a FlagReason.
--   Pins saved before this script are GPS pins with PinStatus OK (they are checked again when the address is edited).
--   Needs 2446. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
-- ── ForecastDoctor: where the pin came from, the geocoded address, the check result ─────────────────────────────
IF COL_LENGTH('dbo.ForecastDoctor', 'PinSource') IS NULL
    ALTER TABLE dbo.ForecastDoctor ADD PinSource VARCHAR(7) NULL CONSTRAINT CK_ForecastDoctor_PinSource CHECK (PinSource IN ('GPS', 'ADDRESS'));
IF COL_LENGTH('dbo.ForecastDoctor', 'PinAccuracyM') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PinAccuracyM DECIMAL(8, 2) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'PinSetBy') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PinSetBy INT NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'PhoneLatAtPin') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PhoneLatAtPin DECIMAL(10, 8) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'PhoneLngAtPin') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PhoneLngAtPin DECIMAL(11, 8) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'GeoLat') IS NULL ALTER TABLE dbo.ForecastDoctor ADD GeoLat DECIMAL(10, 8) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'GeoLng') IS NULL ALTER TABLE dbo.ForecastDoctor ADD GeoLng DECIMAL(11, 8) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'GeoAddress') IS NULL ALTER TABLE dbo.ForecastDoctor ADD GeoAddress NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'GeoSource') IS NULL ALTER TABLE dbo.ForecastDoctor ADD GeoSource VARCHAR(10) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'AddressDistanceM') IS NULL ALTER TABLE dbo.ForecastDoctor ADD AddressDistanceM INT NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'PinStatus') IS NULL
    ALTER TABLE dbo.ForecastDoctor ADD PinStatus VARCHAR(11) NULL
        CONSTRAINT CK_ForecastDoctor_PinStatus CHECK (PinStatus IN ('OK', 'FLAGGED', 'UNCONFIRMED', 'CONFIRMED', 'REJECTED'));
IF COL_LENGTH('dbo.ForecastDoctor', 'PinFlagReason') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PinFlagReason NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ForecastDoctor', 'PinCheckedDate') IS NULL ALTER TABLE dbo.ForecastDoctor ADD PinCheckedDate DATETIME NULL;
GO
UPDATE dbo.ForecastDoctor SET PinSource = 'GPS', PinStatus = 'OK', PinSetBy = ISNULL(ModifiedBy, CreatedBy)
 WHERE Latitude IS NOT NULL AND PinSource IS NULL;
GO
-- ── MarketingSettings: the limits of the checks ────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.MarketingSettings', 'AddressPinMaxDistanceM') IS NULL
    ALTER TABLE dbo.MarketingSettings ADD AddressPinMaxDistanceM INT NOT NULL CONSTRAINT DF_MarketingSettings_AddrMax DEFAULT (500);
IF COL_LENGTH('dbo.MarketingSettings', 'SamePinRadiusM') IS NULL
    ALTER TABLE dbo.MarketingSettings ADD SamePinRadiusM INT NOT NULL CONSTRAINT DF_MarketingSettings_SamePin DEFAULT (50);
IF COL_LENGTH('dbo.MarketingSettings', 'BranchPinRadiusM') IS NULL
    ALTER TABLE dbo.MarketingSettings ADD BranchPinRadiusM INT NOT NULL CONSTRAINT DF_MarketingSettings_BranchPin DEFAULT (150);
IF COL_LENGTH('dbo.MarketingSettings', 'MaxTravelKmph') IS NULL
    ALTER TABLE dbo.MarketingSettings ADD MaxTravelKmph INT NOT NULL CONSTRAINT DF_MarketingSettings_Travel DEFAULT (80);
GO
-- ── ForecastDoctorVisit: UNCONFIRMED status and a flag ─────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.ForecastDoctorVisit', 'FlagReason') IS NULL ALTER TABLE dbo.ForecastDoctorVisit ADD FlagReason NVARCHAR(300) NULL;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ForecastDoctorVisit_Status'
                AND definition NOT LIKE '%UNCONFIRMED%')
BEGIN
    ALTER TABLE dbo.ForecastDoctorVisit DROP CONSTRAINT CK_ForecastDoctorVisit_Status;
    ALTER TABLE dbo.ForecastDoctorVisit ALTER COLUMN VisitStatus VARCHAR(12) NOT NULL;
    ALTER TABLE dbo.ForecastDoctorVisit ADD CONSTRAINT CK_ForecastDoctorVisit_Status
        CHECK (VisitStatus IN ('VERIFIED', 'OUTSIDE', 'NO_PIN', 'NO_GPS', 'MOCK', 'UNCONFIRMED'));
END
GO
-- descriptions
DECLARE @t SYSNAME, @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT t, c, v FROM (VALUES
    ('ForecastDoctor', 'PinSource', N'GPS = the phone''s position at the clinic; ADDRESS = where the typed address was found on the map (executive not at the clinic).'),
    ('ForecastDoctor', 'PinAccuracyM', N'Accuracy of the phone''s position when a GPS pin was saved.'),
    ('ForecastDoctor', 'PinSetBy', N'The user who saved the pin.'),
    ('ForecastDoctor', 'PhoneLatAtPin', N'For an ADDRESS pin: where the phone was when it was saved.'),
    ('ForecastDoctor', 'PhoneLngAtPin', N'For an ADDRESS pin: where the phone was when it was saved.'),
    ('ForecastDoctor', 'GeoLat', N'Where the typed address was found on the map (EMR.Api geocoding).'),
    ('ForecastDoctor', 'GeoLng', N'Where the typed address was found on the map (EMR.Api geocoding).'),
    ('ForecastDoctor', 'GeoAddress', N'The address as the map service found it.'),
    ('ForecastDoctor', 'GeoSource', N'GOOGLE (Places API) or OSM (OpenStreetMap Nominatim).'),
    ('ForecastDoctor', 'AddressDistanceM', N'Distance between the pin and the geocoded address, in metres.'),
    ('ForecastDoctor', 'PinStatus', N'OK, FLAGGED (a check failed, see PinFlagReason), UNCONFIRMED (address pin), CONFIRMED / REJECTED (by the office, later).'),
    ('ForecastDoctor', 'PinFlagReason', N'Why the pin is flagged or unconfirmed (usp_Mkt_Pin_Check).'),
    ('ForecastDoctor', 'PinCheckedDate', N'When usp_Mkt_Pin_Check last ran for the pin.'),
    ('MarketingSettings', 'AddressPinMaxDistanceM', N'A GPS pin further than this from the geocoded address is flagged; visits within this of an address pin are UNCONFIRMED.'),
    ('MarketingSettings', 'SamePinRadiusM', N'Doctors of other clinics pinned within this of each other (two or more) flag the pin.'),
    ('MarketingSettings', 'BranchPinRadiusM', N'A GPS pin within this of the branch is flagged.'),
    ('MarketingSettings', 'MaxTravelKmph', N'A visit further from the previous visit of the day than this speed allows is flagged.'),
    ('ForecastDoctorVisit', 'FlagReason', N'Why the visit is flagged (e.g. too far from the previous visit for the time between them).')) x(t, c, v);
OPEN dc; FETCH NEXT FROM dc INTO @t, @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.' + @t), @c, 'ColumnId') AND name = 'MS_Description')
        EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    FETCH NEXT FROM dc INTO @t, @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO

-- metres as words: 850 m / 3.2 km
CREATE OR ALTER FUNCTION dbo.fn_Mkt_DistanceText (@Metres FLOAT)
RETURNS NVARCHAR(20)
AS
BEGIN
    RETURN CASE WHEN @Metres IS NULL THEN NULL
                WHEN @Metres < 1000 THEN CAST(CAST(ROUND(@Metres, 0) AS INT) AS NVARCHAR(10)) + N' m'
                ELSE CAST(CAST(ROUND(@Metres / 1000.0, 1) AS DECIMAL(9, 1)) AS NVARCHAR(12)) + N' km' END;
END
GO

-- ── the checks of one pin (address vs pin, same spot, branch, route); sets PinStatus and PinFlagReason ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Pin_Check
    @ForecastDoctorId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Src VARCHAR(7), @GeoLat DECIMAL(10, 8), @GeoLng DECIMAL(11, 8), @Exec INT, @Branch INT,
            @Company INT, @Clinic NVARCHAR(150), @SetBy INT, @SetDate DATETIME, @Status VARCHAR(11);
    SELECT @Lat = Latitude, @Lng = Longitude, @Src = PinSource, @GeoLat = GeoLat, @GeoLng = GeoLng, @Exec = ExecutiveId, @Branch = BranchId,
           @Company = CompanyId, @Clinic = UPPER(LTRIM(RTRIM(ISNULL(ClinicName, N'')))), @SetBy = PinSetBy, @SetDate = PinSetDate, @Status = PinStatus
      FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId;

    IF @Lat IS NULL
    BEGIN
        UPDATE dbo.ForecastDoctor SET PinStatus = NULL, PinFlagReason = NULL, AddressDistanceM = NULL, PinCheckedDate = GETDATE()
         WHERE ForecastDoctorId = @ForecastDoctorId;
        RETURN;
    END

    DECLARE @MaxAddr INT = 500, @SameR INT = 50, @BranchR INT = 150;
    SELECT @MaxAddr = AddressPinMaxDistanceM, @SameR = SamePinRadiusM, @BranchR = BranchPinRadiusM FROM dbo.MarketingSettings WHERE CompanyId = @Company;
    DECLARE @Pin geography = geography::Point(@Lat, @Lng, 4326);
    DECLARE @Reasons TABLE (n INT IDENTITY, r NVARCHAR(200));

    -- 1. address vs pin (a GPS pin only: an address pin is the address)
    DECLARE @AddrDist FLOAT = CASE WHEN @GeoLat IS NOT NULL THEN @Pin.STDistance(geography::Point(@GeoLat, @GeoLng, 4326)) END;
    IF @Src = 'GPS' AND @AddrDist > @MaxAddr
        INSERT @Reasons (r) VALUES (N'The pin is ' + dbo.fn_Mkt_DistanceText(@AddrDist) + N' from the address.');

    -- 5a. several doctors of other clinics pinned at the same spot by the same executive
    DECLARE @Same INT = (SELECT COUNT(1) FROM dbo.ForecastDoctor o
                          WHERE o.ExecutiveId = @Exec AND o.IsActive = 1 AND o.ForecastDoctorId <> @ForecastDoctorId AND o.Latitude IS NOT NULL
                            AND UPPER(LTRIM(RTRIM(ISNULL(o.ClinicName, N'')))) <> @Clinic
                            AND geography::Point(o.Latitude, o.Longitude, 4326).STDistance(@Pin) <= @SameR);
    IF @Same >= 2 INSERT @Reasons (r) VALUES (CAST(@Same AS NVARCHAR(10)) + N' doctors of other clinics are pinned at the same spot.');

    -- 5b. a GPS pin at the branch
    DECLARE @BrLat DECIMAL(18, 10), @BrLng DECIMAL(18, 10);
    SELECT @BrLat = TRY_CAST(Latitude AS DECIMAL(18, 10)), @BrLng = TRY_CAST(Longitude AS DECIMAL(18, 10)) FROM dbo.Branchmaster WHERE BranchID = @Branch;
    IF @Src = 'GPS' AND @BrLat BETWEEN -90 AND 90 AND @BrLng BETWEEN -180 AND 180 AND NOT (@BrLat = 0 AND @BrLng = 0)
    BEGIN
        DECLARE @BrDist FLOAT = @Pin.STDistance(geography::Point(@BrLat, @BrLng, 4326));
        IF @BrDist <= @BranchR INSERT @Reasons (r) VALUES (N'The pin is at the branch (' + dbo.fn_Mkt_DistanceText(@BrDist) + N' away).');
    END

    -- 5c. the field-day route was elsewhere when the GPS pin was saved (the points that had reached the server by then)
    IF @Src = 'GPS' AND @SetBy IS NOT NULL AND @SetDate IS NOT NULL
    BEGIN
        DECLARE @Route FLOAT = (SELECT MIN(geography::Point(p.Latitude, p.Longitude, 4326).STDistance(@Pin)) FROM dbo.MarketingLocationPoint p
                                 WHERE p.UserId = @SetBy AND p.IsMock = 0 AND p.PointTime BETWEEN DATEADD(MINUTE, -15, @SetDate) AND DATEADD(MINUTE, 2, @SetDate));
        IF @Route > 1000 INSERT @Reasons (r) VALUES (N'Your field-day route was ' + dbo.fn_Mkt_DistanceText(@Route) + N' away when the pin was saved.');
    END

    DECLARE @Text NVARCHAR(500) = (SELECT STRING_AGG(r, N' ') WITHIN GROUP (ORDER BY n) FROM @Reasons);
    UPDATE dbo.ForecastDoctor
       SET AddressDistanceM = CAST(ROUND(@AddrDist, 0) AS INT),
           PinStatus = CASE WHEN @Status IN ('CONFIRMED', 'REJECTED') THEN @Status       -- the office's decision stays (until the pin changes)
                            WHEN @Src = 'ADDRESS' THEN 'UNCONFIRMED'
                            WHEN @Text IS NOT NULL THEN 'FLAGGED' ELSE 'OK' END,
           PinFlagReason = CASE WHEN @Src = 'ADDRESS'
                                THEN LEFT(N'Pin from the address - save it again at the clinic.' + ISNULL(N' ' + @Text, N''), 500)
                                ELSE @Text END,
           PinCheckedDate = GETDATE()
     WHERE ForecastDoctorId = @ForecastDoctorId;
END
GO

-- ── leads ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_List
    @UserId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @Stage     VARCHAR(10)   = NULL,
    @Search    NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    SET @Stage = NULLIF(UPPER(LTRIM(RTRIM(@Stage))), '');
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @Today DATE = CAST(GETDATE() AS DATE);

    SELECT l.ForecastDoctorId, l.NamePrefix, l.FullName, l.PhoneNumber, sp.SpecialityName, l.ClinicName, l.Address,
           l.Latitude, l.Longitude, l.PinSource, l.PinStatus, l.Stage, l.ExpectedMonthlyReferrals, l.NextFollowUpDate, l.DoctorId,
           dm.IsActive AS DoctorActive, v.LastVisitDate, ISNULL(v.VisitCount, 0) AS VisitCount,
           CASE WHEN v.LastVisitDate IS NULL THEN 'NEW'
                WHEN DATEDIFF(DAY, v.LastVisitDate, GETDATE()) <= 7 THEN 'HOT'
                WHEN DATEDIFF(DAY, v.LastVisitDate, GETDATE()) <= 30 THEN 'WARM'
                WHEN DATEDIFF(DAY, v.LastVisitDate, GETDATE()) <= 90 THEN 'COLD'
                ELSE 'STALE' END AS Heat,
           CAST(CASE WHEN l.NextFollowUpDate <= @Today AND l.Stage NOT IN ('ACTIVE', 'LOST') THEN 1 ELSE 0 END AS BIT) AS FollowUpDue
      FROM dbo.ForecastDoctor l
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = l.PrimarySpecialityId
      LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = l.DoctorId
      OUTER APPLY (SELECT MAX(VisitDate) AS LastVisitDate, COUNT(*) AS VisitCount
                     FROM dbo.ForecastDoctorVisit WHERE ForecastDoctorId = l.ForecastDoctorId) v
     WHERE l.ExecutiveId = @Exec AND l.BranchId = @BranchId AND l.IsActive = 1
       AND (@Stage IS NULL OR l.Stage = @Stage)
       AND (@Search IS NULL OR l.FullName LIKE @like OR l.PhoneNumber LIKE @like OR l.ClinicName LIKE @like OR l.Address LIKE @like)
     ORDER BY CASE WHEN l.NextFollowUpDate <= @Today AND l.Stage NOT IN ('ACTIVE', 'LOST') THEN 0 ELSE 1 END,
              l.NextFollowUpDate, l.FullName;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_Get
    @UserId           INT,
    @CompanyId        INT,
    @ForecastDoctorId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    IF NOT EXISTS (SELECT 1 FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1)
        THROW 50000, N'This doctor is not in your list.', 1;

    SELECT l.ForecastDoctorId, l.NamePrefix, l.FullName, l.PhoneNumber, l.PrimarySpecialityId, sp.SpecialityName, l.ClinicName, l.Address,
           l.Latitude, l.Longitude, l.PinSetDate, l.PinSource, l.PinStatus, l.PinFlagReason, l.AddressDistanceM, l.GeoAddress,
           l.Stage, l.ExpectedMonthlyReferrals, l.NextFollowUpDate, l.Remarks,
           l.DoctorId, dm.IsActive AS DoctorActive, dm.EmailId AS DoctorEmail, dm.Gender AS DoctorGender,
           r.ReferralCount, r.Referrals30Days, r.LastReferralDate, l.CreatedDate
      FROM dbo.ForecastDoctor l
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = l.PrimarySpecialityId
      LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = l.DoctorId
      OUTER APPLY (SELECT COUNT(*) AS ReferralCount,
                          SUM(CASE WHEN o.OrderDate >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END) AS Referrals30Days,
                          MAX(o.OrderDate) AS LastReferralDate
                     FROM dbo.LabOrder o WHERE l.DoctorId IS NOT NULL AND o.ReferralDoctorId = l.DoctorId) r
     WHERE l.ForecastDoctorId = @ForecastDoctorId;

    SELECT VisitId, VisitDate, VisitStatus, DistanceM, Outcome, Notes, NextFollowUpDate, FlagReason
      FROM dbo.ForecastDoctorVisit WHERE ForecastDoctorId = @ForecastDoctorId ORDER BY VisitDate DESC;

    SELECT g.FromStage, g.ToStage, g.Reason, g.ChangedDate, ISNULL(NULLIF(u.FullName, N''), u.Username) AS ChangedByName
      FROM dbo.ForecastDoctorStageLog g LEFT JOIN dbo.Users u ON u.Id = g.ChangedBy
     WHERE g.ForecastDoctorId = @ForecastDoctorId ORDER BY g.ChangedDate DESC, g.LogId DESC;
END
GO
-- Add / edit. On add the pin is GPS (@Latitude/@Longitude from the phone at the clinic) or ADDRESS (@GeoLat/@GeoLng, found by
-- EMR.Api from the address). EMR.Api geocodes the address on every save (@Geo* NULL when it is not found or there is none).
-- On edit, an address pin follows a changed address; the pin is checked again.
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_Save
    @UserId                   INT,
    @CompanyId                INT,
    @BranchId                 INT,
    @ForecastDoctorId         INT           = NULL,
    @NamePrefix               NVARCHAR(20)  = N'Dr.',
    @FullName                 NVARCHAR(150),
    @PhoneNumber              VARCHAR(20),
    @PrimarySpecialityId      INT           = NULL,
    @ClinicName               NVARCHAR(150) = NULL,
    @Address                  NVARCHAR(500) = NULL,
    @ExpectedMonthlyReferrals INT           = 0,
    @NextFollowUpDate         DATE          = NULL,
    @Remarks                  NVARCHAR(500) = NULL,
    @Latitude                 DECIMAL(10, 8) = NULL,
    @Longitude                DECIMAL(11, 8) = NULL,
    -- 2459
    @PinSource                VARCHAR(7)     = NULL,   -- GPS / ADDRESS / NULL = no pin (GPS when @Latitude is sent by an older app)
    @AccuracyM                DECIMAL(8, 2)  = NULL,
    @IsMock                   BIT            = 0,
    @PhoneLatitude            DECIMAL(10, 8) = NULL,
    @PhoneLongitude           DECIMAL(11, 8) = NULL,
    @GeoLat                   DECIMAL(10, 8) = NULL,
    @GeoLng                   DECIMAL(11, 8) = NULL,
    @GeoAddress               NVARCHAR(500)  = NULL,
    @GeoSource                VARCHAR(10)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @msg NVARCHAR(400);
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    IF @Exec IS NULL THROW 50000, N'This login is not an active marketing executive.', 1;

    SET @NamePrefix = ISNULL(NULLIF(LTRIM(RTRIM(@NamePrefix)), N''), N'Dr.');
    SET @FullName = LTRIM(RTRIM(ISNULL(@FullName, N'')));
    SET @PhoneNumber = RIGHT(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(@PhoneNumber, ''))), ' ', ''), '-', ''), '+', ''), 10);
    SET @ClinicName = NULLIF(LTRIM(RTRIM(@ClinicName)), N'');
    SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
    SET @PrimarySpecialityId = NULLIF(@PrimarySpecialityId, 0);
    SET @ExpectedMonthlyReferrals = ISNULL(@ExpectedMonthlyReferrals, 0);
    SET @PinSource = NULLIF(UPPER(LTRIM(RTRIM(@PinSource))), '');
    IF @ForecastDoctorId IS NULL AND @PinSource IS NULL AND @Latitude IS NOT NULL SET @PinSource = 'GPS';
    IF @GeoLat IS NULL OR @GeoLng IS NULL OR @Address IS NULL SELECT @GeoLat = NULL, @GeoLng = NULL, @GeoAddress = NULL, @GeoSource = NULL;

    IF LEN(@FullName) < 2 THROW 50000, N'Enter the doctor''s name.', 1;
    IF @FullName LIKE N'%[0-9]%' THROW 50000, N'The name cannot contain digits.', 1;
    IF LEN(@PhoneNumber) <> 10 OR @PhoneNumber LIKE '%[^0-9]%' OR LEFT(@PhoneNumber, 1) NOT IN ('6', '7', '8', '9')
        THROW 50000, N'Enter a valid 10-digit mobile number (starting with 6, 7, 8 or 9).', 1;
    IF @PrimarySpecialityId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.DoctorSpecialityMaster WHERE SpecialityId = @PrimarySpecialityId AND CompanyId = @CompanyId AND IsActive = 1)
        THROW 50000, N'Choose an active speciality.', 1;
    IF @ExpectedMonthlyReferrals NOT BETWEEN 0 AND 10000 THROW 50000, N'Expected referrals a month must be between 0 and 10000.', 1;
    -- an overdue date already saved may stay while other details are edited
    IF @NextFollowUpDate < CAST(GETDATE() AS DATE)
       AND @NextFollowUpDate <> ISNULL((SELECT NextFollowUpDate FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId), '19000101')
        THROW 50000, N'The follow-up date cannot be in the past.', 1;
    IF @ForecastDoctorId IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches WHERE UserId = @UserId AND BranchID = @BranchId AND IsActive = 1)
        THROW 50000, N'This branch is not mapped to your login.', 1;

    -- the pin of a new doctor (2459)
    IF @ForecastDoctorId IS NULL
    BEGIN
        IF @PinSource IS NULL OR @PinSource NOT IN ('GPS', 'ADDRESS') THROW 50000, N'Say whether you are at the clinic.', 1;
        IF @PinSource = 'GPS'
        BEGIN
            IF ISNULL(@IsMock, 0) = 1 THROW 50000, N'A fake (mock) location cannot be saved. Turn off the mock location app.', 1;
            IF @Latitude IS NULL OR @Longitude IS NULL OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
                THROW 50000, N'Your location could not be read. Turn on location and try again.', 1;
            IF @AccuracyM > 100 THROW 50000, N'Your location is not accurate enough yet (more than 100 m). Wait a moment outdoors and try again.', 1;
            SELECT @PhoneLatitude = NULL, @PhoneLongitude = NULL;
        END
        IF @PinSource = 'ADDRESS'
        BEGIN
            IF @Address IS NULL THROW 50000, N'Enter the clinic address, or save the location when you are at the clinic.', 1;
            IF @GeoLat IS NULL THROW 50000, N'The address could not be found on the map. Add the area, city and pin code, or save the location when you are at the clinic.', 1;
            SELECT @Latitude = @GeoLat, @Longitude = @GeoLng, @AccuracyM = NULL;
            IF ISNULL(@IsMock, 0) = 1 SELECT @PhoneLatitude = NULL, @PhoneLongitude = NULL;
        END
    END

    BEGIN TRAN;
    DECLARE @OldAddress NVARCHAR(500), @OldSource VARCHAR(7), @OldGeoLat DECIMAL(10, 8), @OldGeoLng DECIMAL(11, 8);
    IF @ForecastDoctorId IS NOT NULL
    BEGIN
        SELECT @OldAddress = Address, @OldSource = PinSource, @OldGeoLat = GeoLat, @OldGeoLng = GeoLng
          FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1;
        IF @@ROWCOUNT = 0 THROW 50000, N'This doctor is not in your list.', 1;
    END

    DECLARE @dupLead NVARCHAR(300) = (SELECT TOP 1 l.NamePrefix + N' ' + l.FullName + N' (' + e.ExecutiveName + N')'
                                        FROM dbo.ForecastDoctor l WITH (UPDLOCK, HOLDLOCK)
                                        JOIN dbo.MarketingExecutive e ON e.ExecutiveId = l.ExecutiveId
                                       WHERE l.CompanyId = @CompanyId AND l.IsActive = 1 AND l.PhoneNumber = @PhoneNumber
                                         AND l.ForecastDoctorId <> ISNULL(@ForecastDoctorId, 0));
    IF @dupLead IS NOT NULL
    BEGIN SET @msg = N'This mobile number is already a lead: ' + @dupLead + N'.'; THROW 50000, @msg, 1; END;

    -- a doctor already in Doctor Master is not a new lead (a promoted lead keeps its own doctor)
    DECLARE @dupDoctor NVARCHAR(200) = (SELECT TOP 1 ISNULL(d.NamePrefix + N' ', N'') + d.FullName FROM dbo.DoctorMaster d
                                         WHERE d.CompanyId = @CompanyId AND RIGHT(d.PhoneNumber, 10) = @PhoneNumber
                                           AND d.DoctorId <> ISNULL((SELECT DoctorId FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId), 0));
    IF @dupDoctor IS NOT NULL
    BEGIN SET @msg = @dupDoctor + N' with this mobile number is already in Doctor Master.'; THROW 50000, @msg, 1; END;

    DECLARE @Check BIT = 0;
    IF @ForecastDoctorId IS NULL
    BEGIN
        INSERT dbo.ForecastDoctor (CompanyId, BranchId, ExecutiveId, NamePrefix, FullName, PhoneNumber, PrimarySpecialityId, ClinicName, Address,
                                   Latitude, Longitude, PinSetDate, ExpectedMonthlyReferrals, NextFollowUpDate, Remarks, CreatedBy,
                                   PinSource, PinAccuracyM, PinSetBy, PhoneLatAtPin, PhoneLngAtPin, GeoLat, GeoLng, GeoAddress, GeoSource)
        VALUES (@CompanyId, @BranchId, @Exec, @NamePrefix, @FullName, @PhoneNumber, @PrimarySpecialityId, @ClinicName, @Address,
                @Latitude, @Longitude, GETDATE(), @ExpectedMonthlyReferrals, @NextFollowUpDate, @Remarks, @UserId,
                @PinSource, @AccuracyM, @UserId, @PhoneLatitude, @PhoneLongitude, @GeoLat, @GeoLng, LEFT(@GeoAddress, 500), @GeoSource);
        SET @ForecastDoctorId = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.ForecastDoctorStageLog (ForecastDoctorId, FromStage, ToStage, Reason, ChangedBy) VALUES (@ForecastDoctorId, NULL, 'PROSPECT', N'Added', @UserId);
        SET @Check = 1;
    END
    ELSE
    BEGIN
        DECLARE @AddressChanged BIT = CASE WHEN ISNULL(@OldAddress, N'') <> ISNULL(@Address, N'') THEN 1 ELSE 0 END;
        -- the name and mobile of a promoted lead are kept in Doctor Master; the rest stays editable here
        UPDATE dbo.ForecastDoctor
           SET NamePrefix = CASE WHEN DoctorId IS NULL THEN @NamePrefix ELSE NamePrefix END,
               FullName = CASE WHEN DoctorId IS NULL THEN @FullName ELSE FullName END,
               PhoneNumber = CASE WHEN DoctorId IS NULL THEN @PhoneNumber ELSE PhoneNumber END,
               PrimarySpecialityId = @PrimarySpecialityId, ClinicName = @ClinicName, Address = @Address,
               ExpectedMonthlyReferrals = @ExpectedMonthlyReferrals, NextFollowUpDate = @NextFollowUpDate, Remarks = @Remarks,
               GeoLat = @GeoLat, GeoLng = @GeoLng, GeoAddress = LEFT(@GeoAddress, 500), GeoSource = @GeoSource,
               -- an address pin follows the address it came from
               Latitude = CASE WHEN PinSource = 'ADDRESS' AND @AddressChanged = 1 AND @GeoLat IS NOT NULL THEN @GeoLat ELSE Latitude END,
               Longitude = CASE WHEN PinSource = 'ADDRESS' AND @AddressChanged = 1 AND @GeoLat IS NOT NULL THEN @GeoLng ELSE Longitude END,
               PinSetDate = CASE WHEN PinSource = 'ADDRESS' AND @AddressChanged = 1 AND @GeoLat IS NOT NULL THEN GETDATE() ELSE PinSetDate END,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE ForecastDoctorId = @ForecastDoctorId;
        IF @AddressChanged = 1 OR ISNULL(@OldGeoLat, 0) <> ISNULL(@GeoLat, 0) OR ISNULL(@OldGeoLng, 0) <> ISNULL(@GeoLng, 0) SET @Check = 1;
    END
    IF @Check = 1 EXEC dbo.usp_Mkt_Pin_Check @ForecastDoctorId;
    COMMIT;
    SELECT @ForecastDoctorId AS ForecastDoctorId;
END
GO
-- Save Clinic Location: a doctor without a pin gets a GPS or an address pin; an ADDRESS pin can be replaced once by a GPS pin
-- (the executive is at the clinic). Any other change is the office's.
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_SetPin
    @UserId           INT,
    @CompanyId        INT,
    @ForecastDoctorId INT,
    @Latitude         DECIMAL(10, 8) = NULL,
    @Longitude        DECIMAL(11, 8) = NULL,
    @AccuracyM        DECIMAL(8, 2)  = NULL,
    @IsMock           BIT            = 0,
    -- 2459
    @PinSource        VARCHAR(7)     = 'GPS',
    @PhoneLatitude    DECIMAL(10, 8) = NULL,
    @PhoneLongitude   DECIMAL(11, 8) = NULL,
    @GeoLat           DECIMAL(10, 8) = NULL,
    @GeoLng           DECIMAL(11, 8) = NULL,
    @GeoAddress       NVARCHAR(500)  = NULL,
    @GeoSource        VARCHAR(10)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    SET @PinSource = ISNULL(NULLIF(UPPER(LTRIM(RTRIM(@PinSource))), ''), 'GPS');
    IF @PinSource NOT IN ('GPS', 'ADDRESS') THROW 50000, N'Say whether you are at the clinic.', 1;

    DECLARE @CurLat DECIMAL(10, 8), @CurSource VARCHAR(7), @Address NVARCHAR(500), @Found BIT = 0;
    BEGIN TRAN;
    SELECT @Found = 1, @CurLat = Latitude, @CurSource = PinSource, @Address = Address
      FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1;
    IF @Found = 0 THROW 50000, N'This doctor is not in your list.', 1;
    IF @CurLat IS NOT NULL AND NOT (ISNULL(@CurSource, 'GPS') = 'ADDRESS' AND @PinSource = 'GPS')
        THROW 50000, N'The clinic location is already saved. Ask the office to change it.', 1;

    IF @PinSource = 'GPS'
    BEGIN
        IF ISNULL(@IsMock, 0) = 1 THROW 50000, N'A fake (mock) location cannot be saved. Turn off the mock location app.', 1;
        IF @Latitude IS NULL OR @Longitude IS NULL OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
            THROW 50000, N'Your location could not be read. Turn on location and try again.', 1;
        IF @AccuracyM > 100 THROW 50000, N'Your location is not accurate enough yet (more than 100 m). Wait a moment outdoors and try again.', 1;
        SELECT @PhoneLatitude = NULL, @PhoneLongitude = NULL;
    END
    ELSE
    BEGIN
        IF @Address IS NULL THROW 50000, N'Add the clinic address first (Edit), or save the location when you are at the clinic.', 1;
        IF @GeoLat IS NULL OR @GeoLng IS NULL
            THROW 50000, N'The address could not be found on the map. Add the area, city and pin code (Edit), or save the location when you are at the clinic.', 1;
        SELECT @Latitude = @GeoLat, @Longitude = @GeoLng, @AccuracyM = NULL;
        IF ISNULL(@IsMock, 0) = 1 SELECT @PhoneLatitude = NULL, @PhoneLongitude = NULL;
    END

    UPDATE dbo.ForecastDoctor
       SET Latitude = @Latitude, Longitude = @Longitude, PinSetDate = GETDATE(), PinSource = @PinSource, PinAccuracyM = @AccuracyM, PinSetBy = @UserId,
           PhoneLatAtPin = @PhoneLatitude, PhoneLngAtPin = @PhoneLongitude, PinStatus = NULL,
           GeoLat = CASE WHEN @GeoLat IS NOT NULL THEN @GeoLat ELSE GeoLat END, GeoLng = CASE WHEN @GeoLat IS NOT NULL THEN @GeoLng ELSE GeoLng END,
           GeoAddress = CASE WHEN @GeoLat IS NOT NULL THEN LEFT(@GeoAddress, 500) ELSE GeoAddress END,
           GeoSource = CASE WHEN @GeoLat IS NOT NULL THEN @GeoSource ELSE GeoSource END,
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE ForecastDoctorId = @ForecastDoctorId;
    EXEC dbo.usp_Mkt_Pin_Check @ForecastDoctorId;
    COMMIT;
    SELECT ForecastDoctorId, PinSource, PinStatus, PinFlagReason, AddressDistanceM FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId;
END
GO

-- ── visits ───────────────────────────────────────────────────────────────────────────────────────────────────
-- VERIFIED within MarketingSettings.VisitRadiusM of a good pin (OK or CONFIRMED). UNCONFIRMED within the radius of a flagged
-- pin, or within AddressPinMaxDistanceM of an address pin (CanUpgradePin: the app offers to save the GPS position as the
-- clinic location). The first visit moves a Prospect to Contacted; a second visit with Interested moves Contacted to Engaged.
-- A repeated ClientEventId returns the saved visit.
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
PRINT 'Script 2459 applied: clinic pin from GPS or the address, pin checks, UNCONFIRMED visits.';
GO
