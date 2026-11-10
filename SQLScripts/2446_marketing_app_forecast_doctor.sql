-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2446  Marketing executive app (inside the phlebotomist app): forecast doctors (leads), verified visits, field-day
--       location tracking, and promotion of a lead to Doctor Master as a referral doctor at the Trial stage.
--   Who: a login with Users.Is_MarketingExecutive = 1 that is the LoginUserId of an active MarketingExecutive (2440, 2444).
--   Phones: the same approval as the phlebotomist app (dbo.PhleboDevice, usp_Phlebo_Device_Register).
--   ForecastDoctor keeps only basic details. Moving a lead to Trial (usp_Mkt_Lead_Promote) adds the doctor to Doctor Master
--   with IsReferralDoctor = 1, the executive (DoctorMaster.MarketingExecutiveId, 2441), the branch and the company's LAB
--   departments - switched off: the office checks the doctor in Doctors > Edit and switches it on (the approval).
--   A doctor with the same mobile already in Doctor Master is linked, not added again.
--   Needs 2440-2445. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.MarketingSettings', 'U') IS NULL
CREATE TABLE dbo.MarketingSettings (
    CompanyId               INT      NOT NULL CONSTRAINT PK_MarketingSettings PRIMARY KEY
                                     CONSTRAINT FK_MarketingSettings_Company REFERENCES dbo.CompanyMaster (CompanyId),
    VisitRadiusM            INT      NOT NULL CONSTRAINT DF_MarketingSettings_Radius DEFAULT (100),
    LocationIntervalSeconds INT      NOT NULL CONSTRAINT DF_MarketingSettings_Interval DEFAULT (60),
    LocationRetentionDays   INT      NOT NULL CONSTRAINT DF_MarketingSettings_Retention DEFAULT (90),
    ModifiedBy              INT      NULL,
    ModifiedDate            DATETIME NULL
);
GO
INSERT dbo.MarketingSettings (CompanyId)
SELECT c.CompanyId FROM dbo.CompanyMaster c WHERE NOT EXISTS (SELECT 1 FROM dbo.MarketingSettings s WHERE s.CompanyId = c.CompanyId);
GO

IF OBJECT_ID('dbo.ForecastDoctor', 'U') IS NULL
CREATE TABLE dbo.ForecastDoctor (
    ForecastDoctorId         INT            IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ForecastDoctor PRIMARY KEY,
    CompanyId                INT            NOT NULL CONSTRAINT FK_ForecastDoctor_Company REFERENCES dbo.CompanyMaster (CompanyId),
    BranchId                 INT            NOT NULL CONSTRAINT FK_ForecastDoctor_Branch REFERENCES dbo.Branchmaster (BranchID),
    ExecutiveId              INT            NOT NULL CONSTRAINT FK_ForecastDoctor_Executive REFERENCES dbo.MarketingExecutive (ExecutiveId),
    NamePrefix               NVARCHAR(20)   NOT NULL CONSTRAINT DF_ForecastDoctor_Prefix DEFAULT (N'Dr.'),
    FullName                 NVARCHAR(150)  NOT NULL,
    PhoneNumber              VARCHAR(10)    NOT NULL,
    PrimarySpecialityId      INT            NULL CONSTRAINT FK_ForecastDoctor_Speciality REFERENCES dbo.DoctorSpecialityMaster (SpecialityId),
    ClinicName               NVARCHAR(150)  NULL,
    Address                  NVARCHAR(500)  NULL,
    Latitude                 DECIMAL(10, 8) NULL,
    Longitude                DECIMAL(11, 8) NULL,
    PinSetDate               DATETIME       NULL,
    Stage                    VARCHAR(10)    NOT NULL CONSTRAINT DF_ForecastDoctor_Stage DEFAULT ('PROSPECT')
                                            CONSTRAINT CK_ForecastDoctor_Stage CHECK (Stage IN ('PROSPECT', 'CONTACTED', 'ENGAGED', 'TRIAL', 'ACTIVE', 'LOST')),
    ExpectedMonthlyReferrals INT            NOT NULL CONSTRAINT DF_ForecastDoctor_Expected DEFAULT (0)
                                            CONSTRAINT CK_ForecastDoctor_Expected CHECK (ExpectedMonthlyReferrals BETWEEN 0 AND 10000),
    NextFollowUpDate         DATE           NULL,
    Remarks                  NVARCHAR(500)  NULL,
    DoctorId                 INT            NULL CONSTRAINT FK_ForecastDoctor_Doctor REFERENCES dbo.DoctorMaster (DoctorId),
    PromotedDate             DATETIME       NULL,
    PromotedBy               INT            NULL,
    IsActive                 BIT            NOT NULL CONSTRAINT DF_ForecastDoctor_Active DEFAULT (1),
    CreatedBy                INT            NULL,
    CreatedDate              DATETIME       NOT NULL CONSTRAINT DF_ForecastDoctor_Created DEFAULT (GETDATE()),
    ModifiedBy               INT            NULL,
    ModifiedDate             DATETIME       NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_ForecastDoctor_Phone' AND object_id = OBJECT_ID('dbo.ForecastDoctor'))
    CREATE UNIQUE INDEX UX_ForecastDoctor_Phone ON dbo.ForecastDoctor (CompanyId, PhoneNumber) WHERE IsActive = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ForecastDoctor_Executive' AND object_id = OBJECT_ID('dbo.ForecastDoctor'))
    CREATE INDEX IX_ForecastDoctor_Executive ON dbo.ForecastDoctor (ExecutiveId, BranchId, Stage) INCLUDE (NextFollowUpDate);
GO

IF OBJECT_ID('dbo.ForecastDoctorVisit', 'U') IS NULL
CREATE TABLE dbo.ForecastDoctorVisit (
    VisitId          INT            IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ForecastDoctorVisit PRIMARY KEY,
    ForecastDoctorId INT            NOT NULL CONSTRAINT FK_ForecastDoctorVisit_Lead REFERENCES dbo.ForecastDoctor (ForecastDoctorId),
    ExecutiveId      INT            NOT NULL CONSTRAINT FK_ForecastDoctorVisit_Executive REFERENCES dbo.MarketingExecutive (ExecutiveId),
    UserId           INT            NOT NULL,
    BranchId         INT            NOT NULL,
    ClientEventId    NVARCHAR(50)   NOT NULL,
    VisitDate        DATETIME       NOT NULL CONSTRAINT DF_ForecastDoctorVisit_Date DEFAULT (GETDATE()),
    DeviceTime       DATETIME       NULL,
    Latitude         DECIMAL(10, 8) NULL,
    Longitude        DECIMAL(11, 8) NULL,
    AccuracyM        DECIMAL(8, 2)  NULL,
    IsMock           BIT            NOT NULL CONSTRAINT DF_ForecastDoctorVisit_Mock DEFAULT (0),
    DistanceM        INT            NULL,
    VisitStatus      VARCHAR(10)    NOT NULL
                                    CONSTRAINT CK_ForecastDoctorVisit_Status CHECK (VisitStatus IN ('VERIFIED', 'OUTSIDE', 'NO_PIN', 'NO_GPS', 'MOCK')),
    Outcome          VARCHAR(15)    NOT NULL
                                    CONSTRAINT CK_ForecastDoctorVisit_Outcome CHECK (Outcome IN ('INTERESTED', 'FOLLOW_UP', 'NOT_AVAILABLE', 'NOT_INTERESTED')),
    Notes            NVARCHAR(1000) NULL,
    NextFollowUpDate DATE           NULL,
    CONSTRAINT UQ_ForecastDoctorVisit_Event UNIQUE (UserId, ClientEventId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ForecastDoctorVisit_Lead' AND object_id = OBJECT_ID('dbo.ForecastDoctorVisit'))
    CREATE INDEX IX_ForecastDoctorVisit_Lead ON dbo.ForecastDoctorVisit (ForecastDoctorId, VisitDate);
GO

IF OBJECT_ID('dbo.ForecastDoctorStageLog', 'U') IS NULL
CREATE TABLE dbo.ForecastDoctorStageLog (
    LogId            INT           IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ForecastDoctorStageLog PRIMARY KEY,
    ForecastDoctorId INT           NOT NULL CONSTRAINT FK_ForecastDoctorStageLog_Lead REFERENCES dbo.ForecastDoctor (ForecastDoctorId),
    FromStage        VARCHAR(10)   NULL,
    ToStage          VARCHAR(10)   NOT NULL,
    Reason           NVARCHAR(300) NULL,
    ChangedBy        INT           NULL,
    ChangedDate      DATETIME      NOT NULL CONSTRAINT DF_ForecastDoctorStageLog_Date DEFAULT (GETDATE())
);
GO

IF OBJECT_ID('dbo.MarketingFieldDay', 'U') IS NULL
CREATE TABLE dbo.MarketingFieldDay (
    DayId       INT            IDENTITY(1, 1) NOT NULL CONSTRAINT PK_MarketingFieldDay PRIMARY KEY,
    CompanyId   INT            NOT NULL,
    BranchId    INT            NOT NULL,
    UserId      INT            NOT NULL,
    ExecutiveId INT            NOT NULL CONSTRAINT FK_MarketingFieldDay_Executive REFERENCES dbo.MarketingExecutive (ExecutiveId),
    DutyDate    DATE           NOT NULL,
    StartDate   DATETIME       NOT NULL,
    StartLat    DECIMAL(10, 8) NULL,
    StartLng    DECIMAL(11, 8) NULL,
    EndDate     DATETIME       NULL,
    EndLat      DECIMAL(10, 8) NULL,
    EndLng      DECIMAL(11, 8) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MarketingFieldDay_User' AND object_id = OBJECT_ID('dbo.MarketingFieldDay'))
    CREATE INDEX IX_MarketingFieldDay_User ON dbo.MarketingFieldDay (UserId, DutyDate);
GO

IF OBJECT_ID('dbo.MarketingLocationPoint', 'U') IS NULL
CREATE TABLE dbo.MarketingLocationPoint (
    PointId      BIGINT         IDENTITY(1, 1) NOT NULL CONSTRAINT PK_MarketingLocationPoint PRIMARY KEY,
    UserId       INT            NOT NULL,
    DayId        INT            NOT NULL CONSTRAINT FK_MarketingLocationPoint_Day REFERENCES dbo.MarketingFieldDay (DayId),
    PointTime    DATETIME       NOT NULL,
    Latitude     DECIMAL(10, 8) NOT NULL,
    Longitude    DECIMAL(11, 8) NOT NULL,
    AccuracyM    DECIMAL(8, 2)  NULL,
    SpeedMps     DECIMAL(8, 2)  NULL,
    IsMock       BIT            NOT NULL CONSTRAINT DF_MarketingLocationPoint_Mock DEFAULT (0),
    ReceivedDate DATETIME       NOT NULL CONSTRAINT DF_MarketingLocationPoint_Received DEFAULT (GETDATE()),
    CONSTRAINT UQ_MarketingLocationPoint_UserTime UNIQUE (UserId, PointTime)
);
GO

-- ── who may use the app ──────────────────────────────────────────────────────────────────────────────────────
-- NOT_MARKETING: not an active marketing login; NO_EXECUTIVE: no active executive owns this login;
-- DEVICE_NEW / DEVICE_PENDING / DEVICE_REVOKED: the phone (same approval as the phlebotomist app)
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Guard
    @UserId   INT,
    @DeviceId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Code VARCHAR(20) = 'OK', @IsMkt BIT, @Exec INT, @Status VARCHAR(10);
    SELECT @IsMkt = u.Is_MarketingExecutive & u.IsActive FROM dbo.Users u WHERE u.Id = @UserId;
    SELECT @Exec = e.ExecutiveId FROM dbo.MarketingExecutive e WHERE e.LoginUserId = @UserId AND e.IsActive = 1 AND e.IsDeleted = 0;
    SELECT @Status = Status FROM dbo.PhleboDevice WHERE UserId = @UserId AND DeviceId = @DeviceId;

    IF ISNULL(@IsMkt, 0) = 0 SET @Code = 'NOT_MARKETING';
    ELSE IF @Exec IS NULL SET @Code = 'NO_EXECUTIVE';
    ELSE IF @Status IS NULL SET @Code = 'DEVICE_NEW';
    ELSE IF @Status = 'PENDING' SET @Code = 'DEVICE_PENDING';
    ELSE IF @Status = 'REVOKED' SET @Code = 'DEVICE_REVOKED';

    IF @Status IS NOT NULL UPDATE dbo.PhleboDevice SET LastSeen = GETDATE() WHERE UserId = @UserId AND DeviceId = @DeviceId;
    SELECT @Code AS Code;
END
GO

-- which app the login opens: marketing, phlebotomist, or both (the phone asks)
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_AppMode
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(ISNULL(u.Is_MarketingExecutive, 0) & u.IsActive AS BIT) AS IsMarketingExecutive,
           CAST(ISNULL(u.IsPhlebotomist, 0) & u.IsActive AS BIT) AS IsPhlebotomist,
           ISNULL(NULLIF(u.FullName, N''), u.Username) AS FullName
      FROM dbo.Users u WHERE u.Id = @UserId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Session_Get
    @UserId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @DeviceId  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.MarketingSettings WHERE CompanyId = @CompanyId)
        INSERT dbo.MarketingSettings (CompanyId) VALUES (@CompanyId);

    SELECT u.Id AS UserId, ISNULL(NULLIF(u.FullName, N''), u.Username) AS FullName,
           e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, e.MonthlyTarget,
           b.BranchID AS BranchId, b.BranchName,
           d.Status AS DeviceStatus,
           f.DayId, f.StartDate AS FieldStart, f.EndDate AS FieldEnd,
           CAST(CASE WHEN f.DayId IS NOT NULL AND f.EndDate IS NULL THEN 1 ELSE 0 END AS BIT) AS OnField,
           s.VisitRadiusM, s.LocationIntervalSeconds,
           (SELECT COUNT(*) FROM dbo.UserBranches ub JOIN dbo.Branchmaster bb ON bb.BranchID = ub.BranchID
             WHERE ub.UserId = u.Id AND ub.IsActive = 1 AND bb.IsActive = 1) AS BranchCount
      FROM dbo.Users u
      JOIN dbo.MarketingSettings s ON s.CompanyId = @CompanyId
      LEFT JOIN dbo.MarketingExecutive e ON e.LoginUserId = u.Id AND e.IsActive = 1 AND e.IsDeleted = 0
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = @BranchId
      LEFT JOIN dbo.PhleboDevice d ON d.UserId = u.Id AND d.DeviceId = @DeviceId
      OUTER APPLY (SELECT TOP 1 DayId, StartDate, EndDate FROM dbo.MarketingFieldDay
                    WHERE UserId = u.Id AND DutyDate = CAST(GETDATE() AS DATE) ORDER BY DayId DESC) f
     WHERE u.Id = @UserId;
END
GO

-- the branches of the login (UserBranches), for Change Branch
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Branches
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT b.BranchID AS BranchId, b.BranchName
      FROM dbo.UserBranches ub JOIN dbo.Branchmaster b ON b.BranchID = ub.BranchID
     WHERE ub.UserId = @UserId AND ub.IsActive = 1 AND b.IsActive = 1
     ORDER BY b.BranchName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Specialities
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SpecialityId, SpecialityName FROM dbo.DoctorSpecialityMaster
     WHERE IsActive = 1 AND CompanyId = @CompanyId ORDER BY SpecialityName;
END
GO

-- ── leads ────────────────────────────────────────────────────────────────────────────────────────────────────
-- Heat from the last visit: HOT within 7 days, WARM within 30, COLD within 90, STALE older, NEW never visited.
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
           l.Latitude, l.Longitude, l.Stage, l.ExpectedMonthlyReferrals, l.NextFollowUpDate, l.DoctorId,
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

-- one lead: the lead, its visits (newest first), its stage changes, and the Doctor Master referral bills once promoted
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
           l.Latitude, l.Longitude, l.PinSetDate, l.Stage, l.ExpectedMonthlyReferrals, l.NextFollowUpDate, l.Remarks,
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

    SELECT VisitId, VisitDate, VisitStatus, DistanceM, Outcome, Notes, NextFollowUpDate
      FROM dbo.ForecastDoctorVisit WHERE ForecastDoctorId = @ForecastDoctorId ORDER BY VisitDate DESC;

    SELECT g.FromStage, g.ToStage, g.Reason, g.ChangedDate, ISNULL(NULLIF(u.FullName, N''), u.Username) AS ChangedByName
      FROM dbo.ForecastDoctorStageLog g LEFT JOIN dbo.Users u ON u.Id = g.ChangedBy
     WHERE g.ForecastDoctorId = @ForecastDoctorId ORDER BY g.ChangedDate DESC, g.LogId DESC;
END
GO

-- add (no id) or edit the basic details. The clinic pin is set once, from the clinic (usp_Mkt_Lead_SetPin).
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
    @Longitude                DECIMAL(11, 8) = NULL
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
    IF (@Latitude IS NULL AND @Longitude IS NOT NULL) OR (@Latitude IS NOT NULL AND @Longitude IS NULL)
       OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
        THROW 50000, N'The clinic location is not valid.', 1;
    IF @ForecastDoctorId IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches WHERE UserId = @UserId AND BranchID = @BranchId AND IsActive = 1)
        THROW 50000, N'This branch is not mapped to your login.', 1;

    BEGIN TRAN;
    IF @ForecastDoctorId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1)
        THROW 50000, N'This doctor is not in your list.', 1;

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

    IF @ForecastDoctorId IS NULL
    BEGIN
        INSERT dbo.ForecastDoctor (CompanyId, BranchId, ExecutiveId, NamePrefix, FullName, PhoneNumber, PrimarySpecialityId, ClinicName, Address,
                                   Latitude, Longitude, PinSetDate, ExpectedMonthlyReferrals, NextFollowUpDate, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @Exec, @NamePrefix, @FullName, @PhoneNumber, @PrimarySpecialityId, @ClinicName, @Address,
                @Latitude, @Longitude, CASE WHEN @Latitude IS NOT NULL THEN GETDATE() END, @ExpectedMonthlyReferrals, @NextFollowUpDate, @Remarks, @UserId);
        SET @ForecastDoctorId = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.ForecastDoctorStageLog (ForecastDoctorId, FromStage, ToStage, Reason, ChangedBy) VALUES (@ForecastDoctorId, NULL, 'PROSPECT', N'Added', @UserId);
    END
    ELSE
        -- the name and mobile of a promoted lead are kept in Doctor Master; the rest stays editable here
        UPDATE dbo.ForecastDoctor
           SET NamePrefix = CASE WHEN DoctorId IS NULL THEN @NamePrefix ELSE NamePrefix END,
               FullName = CASE WHEN DoctorId IS NULL THEN @FullName ELSE FullName END,
               PhoneNumber = CASE WHEN DoctorId IS NULL THEN @PhoneNumber ELSE PhoneNumber END,
               PrimarySpecialityId = @PrimarySpecialityId, ClinicName = @ClinicName, Address = @Address,
               ExpectedMonthlyReferrals = @ExpectedMonthlyReferrals, NextFollowUpDate = @NextFollowUpDate, Remarks = @Remarks,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE ForecastDoctorId = @ForecastDoctorId;
    COMMIT;
    SELECT @ForecastDoctorId AS ForecastDoctorId;
END
GO

-- the clinic location, once: taken from the phone while standing at the clinic. Moving a saved pin is an office job.
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_SetPin
    @UserId           INT,
    @CompanyId        INT,
    @ForecastDoctorId INT,
    @Latitude         DECIMAL(10, 8),
    @Longitude        DECIMAL(11, 8),
    @AccuracyM        DECIMAL(8, 2) = NULL,
    @IsMock           BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    IF ISNULL(@IsMock, 0) = 1 THROW 50000, N'A fake (mock) location cannot be saved. Turn off the mock location app.', 1;
    IF @Latitude IS NULL OR @Longitude IS NULL OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
        THROW 50000, N'Your location could not be read. Turn on location and try again.', 1;
    IF @AccuracyM > 100 THROW 50000, N'Your location is not accurate enough yet (more than 100 m). Wait a moment outdoors and try again.', 1;

    UPDATE dbo.ForecastDoctor SET Latitude = @Latitude, Longitude = @Longitude, PinSetDate = GETDATE(), ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1 AND Latitude IS NULL;
    IF @@ROWCOUNT = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.ForecastDoctor WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1)
            THROW 50000, N'The clinic location is already saved. Ask the office to change it.', 1;
        THROW 50000, N'This doctor is not in your list.', 1;
    END
    SELECT @ForecastDoctorId AS ForecastDoctorId;
END
GO

-- A stage the executive sets: CONTACTED, ENGAGED and ACTIVE forward only; LOST from any stage; PROSPECT reopens a lost lead.
-- TRIAL only through usp_Mkt_Lead_Promote; ACTIVE once the doctor is switched on in Doctor Master.
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_Stage
    @UserId           INT,
    @CompanyId        INT,
    @ForecastDoctorId INT,
    @Stage            VARCHAR(10),
    @Reason           NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    DECLARE @From VARCHAR(10), @DoctorId INT, @DoctorActive BIT;
    SET @Stage = UPPER(LTRIM(RTRIM(ISNULL(@Stage, ''))));
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');

    BEGIN TRAN;
    SELECT @From = l.Stage, @DoctorId = l.DoctorId, @DoctorActive = dm.IsActive
      FROM dbo.ForecastDoctor l WITH (UPDLOCK) LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = l.DoctorId
     WHERE l.ForecastDoctorId = @ForecastDoctorId AND l.ExecutiveId = @Exec AND l.IsActive = 1;
    IF @From IS NULL THROW 50000, N'This doctor is not in your list.', 1;
    IF @Stage = @From THROW 50000, N'The doctor is already at this stage.', 1;
    IF @Stage = 'TRIAL' THROW 50000, N'Use Move to Trial: it adds the doctor to Doctor Master.', 1;
    IF @Stage NOT IN ('PROSPECT', 'CONTACTED', 'ENGAGED', 'ACTIVE', 'LOST') THROW 50000, N'Choose a valid stage.', 1;
    IF @Stage = 'LOST' AND @Reason IS NULL THROW 50000, N'Give the reason the doctor is lost.', 1;
    IF @Stage = 'PROSPECT' AND @From <> 'LOST' THROW 50000, N'Only a lost doctor can be opened again.', 1;
    IF @From = 'LOST' AND @Stage <> 'PROSPECT' THROW 50000, N'Open the lost doctor again first.', 1;
    IF @Stage = 'ACTIVE' AND (@DoctorId IS NULL OR ISNULL(@DoctorActive, 0) = 0)
        THROW 50000, N'The doctor becomes Active once the office switches the doctor on in Doctor Master.', 1;
    IF @Stage IN ('CONTACTED', 'ENGAGED', 'ACTIVE')
       AND CHARINDEX(',' + @Stage + ',', ',PROSPECT,CONTACTED,ENGAGED,TRIAL,ACTIVE,') <= CHARINDEX(',' + @From + ',', ',PROSPECT,CONTACTED,ENGAGED,TRIAL,ACTIVE,')
        THROW 50000, N'A doctor moves forward through the stages, not back.', 1;
    IF @Stage = 'PROSPECT' AND @DoctorId IS NOT NULL SET @Stage = 'TRIAL';   -- a promoted doctor reopens at Trial

    UPDATE dbo.ForecastDoctor SET Stage = @Stage, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE ForecastDoctorId = @ForecastDoctorId;
    INSERT dbo.ForecastDoctorStageLog (ForecastDoctorId, FromStage, ToStage, Reason, ChangedBy) VALUES (@ForecastDoctorId, @From, @Stage, @Reason, @UserId);
    COMMIT;
    SELECT @Stage AS Stage;
END
GO

-- ── visits ───────────────────────────────────────────────────────────────────────────────────────────────────
-- Verified when the phone is within MarketingSettings.VisitRadiusM of the clinic pin. The first visit moves a Prospect to
-- Contacted; a second visit with Interested moves Contacted to Engaged. A repeated ClientEventId returns the saved visit.
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
    IF @VisitId IS NULL
    BEGIN
        SET @Outcome = UPPER(LTRIM(RTRIM(ISNULL(@Outcome, ''))));
        SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
        IF @Outcome NOT IN ('INTERESTED', 'FOLLOW_UP', 'NOT_AVAILABLE', 'NOT_INTERESTED') THROW 50000, N'Choose the outcome of the visit.', 1;
        IF @NextFollowUpDate < CAST(GETDATE() AS DATE) THROW 50000, N'The follow-up date cannot be in the past.', 1;
        IF @Outcome IN ('FOLLOW_UP', 'INTERESTED') AND @NextFollowUpDate IS NULL THROW 50000, N'Set the next follow-up date.', 1;

        DECLARE @Stage VARCHAR(10), @PinLat DECIMAL(10, 8), @PinLng DECIMAL(11, 8), @Radius INT, @Distance INT, @Status VARCHAR(10), @Visits INT;
        BEGIN TRAN;
        SELECT @Stage = Stage, @PinLat = Latitude, @PinLng = Longitude
          FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1;
        IF @Stage IS NULL THROW 50000, N'This doctor is not in your list.', 1;
        IF @Stage = 'LOST' THROW 50000, N'This doctor is marked lost. Open the doctor again to log a visit.', 1;
        SELECT @Radius = VisitRadiusM FROM dbo.MarketingSettings WHERE CompanyId = @CompanyId;

        IF ISNULL(@IsMock, 0) = 1 SET @Status = 'MOCK';
        ELSE IF @Latitude IS NULL OR @Longitude IS NULL SET @Status = 'NO_GPS';
        ELSE IF @PinLat IS NULL SET @Status = 'NO_PIN';
        ELSE
        BEGIN
            SET @Distance = CAST(ROUND(geography::Point(@Latitude, @Longitude, 4326).STDistance(geography::Point(@PinLat, @PinLng, 4326)), 0) AS INT);
            SET @Status = CASE WHEN @Distance <= ISNULL(@Radius, 100) THEN 'VERIFIED' ELSE 'OUTSIDE' END;
        END

        INSERT dbo.ForecastDoctorVisit (ForecastDoctorId, ExecutiveId, UserId, BranchId, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM,
                                        IsMock, DistanceM, VisitStatus, Outcome, Notes, NextFollowUpDate)
        VALUES (@ForecastDoctorId, @Exec, @UserId, @BranchId, @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM,
                ISNULL(@IsMock, 0), @Distance, @Status, @Outcome, @Notes, @NextFollowUpDate);
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

    SELECT v.VisitId, v.VisitStatus, v.DistanceM, v.Outcome, l.Stage, s.VisitRadiusM
      FROM dbo.ForecastDoctorVisit v
      JOIN dbo.ForecastDoctor l ON l.ForecastDoctorId = v.ForecastDoctorId
      LEFT JOIN dbo.MarketingSettings s ON s.CompanyId = @CompanyId
     WHERE v.VisitId = @VisitId;
END
GO

-- ── Trial: into Doctor Master as a referral doctor ──────────────────────────────────────────────────────────
-- Adds the doctor switched off (the office approves it in Doctors > Edit), with IsReferralDoctor = 1, the executive, the
-- branch and every active LAB department of the company (the referral doctor list on a LAB bill needs one). A doctor with
-- the same mobile already in Doctor Master is linked instead and left as it is (its executive is filled only when empty).
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Lead_Promote
    @UserId              INT,
    @CompanyId           INT,
    @BranchId            INT,
    @ForecastDoctorId    INT,
    @Gender              NVARCHAR(20),
    @EmailId             NVARCHAR(150),
    @PrimarySpecialityId INT,
    @MedicalLicenseNo    NVARCHAR(80) = NULL,
    @DateOfBirth         DATE         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    DECLARE @Stage VARCHAR(10), @DoctorId INT, @Prefix NVARCHAR(20), @Name NVARCHAR(150), @Phone VARCHAR(10), @LeadBranch INT, @Linked BIT = 0;
    SET @Gender = LTRIM(RTRIM(ISNULL(@Gender, N'')));
    SET @EmailId = NULLIF(LOWER(LTRIM(RTRIM(@EmailId))), N'');
    SET @MedicalLicenseNo = NULLIF(LTRIM(RTRIM(@MedicalLicenseNo)), N'');

    IF @Gender NOT IN (N'Male', N'Female', N'Other') THROW 50000, N'Choose the gender.', 1;
    IF @EmailId IS NULL OR @EmailId NOT LIKE N'_%@_%._%' OR @EmailId LIKE N'% %' OR @EmailId LIKE N'%@%@%' OR @EmailId LIKE N'%..%'
        THROW 50000, N'Enter a valid e-mail ID (e.g. name@example.com).', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorSpecialityMaster WHERE SpecialityId = @PrimarySpecialityId AND CompanyId = @CompanyId AND IsActive = 1)
        THROW 50000, N'Choose an active speciality.', 1;
    IF @DateOfBirth > DATEADD(YEAR, -20, GETDATE()) THROW 50000, N'Check the date of birth.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE CompanyId = @CompanyId AND IsActive = 1 AND DeptType = 'LAB')
        THROW 50000, N'No active LAB department is set up. Ask the office to add one.', 1;

    BEGIN TRAN;
    SELECT @Stage = Stage, @DoctorId = DoctorId, @Prefix = NamePrefix, @Name = FullName, @Phone = PhoneNumber, @LeadBranch = BranchId
      FROM dbo.ForecastDoctor WITH (UPDLOCK) WHERE ForecastDoctorId = @ForecastDoctorId AND ExecutiveId = @Exec AND IsActive = 1;
    IF @Stage IS NULL THROW 50000, N'This doctor is not in your list.', 1;
    IF @DoctorId IS NOT NULL THROW 50000, N'This doctor is already in Doctor Master.', 1;
    IF @Stage NOT IN ('CONTACTED', 'ENGAGED') THROW 50000, N'Visit the doctor first: a doctor moves to Trial from Contacted or Engaged.', 1;

    SELECT TOP 1 @DoctorId = DoctorId FROM dbo.DoctorMaster WITH (UPDLOCK, HOLDLOCK)
     WHERE CompanyId = @CompanyId AND RIGHT(PhoneNumber, 10) = @Phone ORDER BY IsActive DESC, DoctorId;
    IF @DoctorId IS NOT NULL
    BEGIN
        SET @Linked = 1;
        UPDATE dbo.DoctorMaster SET MarketingExecutiveId = @Exec, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE DoctorId = @DoctorId AND MarketingExecutiveId IS NULL;
    END
    ELSE
    BEGIN
        INSERT dbo.DoctorMaster (CompanyId, NamePrefix, FullName, Gender, DateOfBirth, EmailId, PhoneNumber, MedicalLicenseNo, PrimarySpecialityId,
                                 IsActive, IsReferralDoctor, CreatedBranchId, CreatedBy, CreatedDate, MarketingExecutiveId)
        VALUES (@CompanyId, @Prefix, @Name, @Gender, @DateOfBirth, @EmailId, @Phone, @MedicalLicenseNo, @PrimarySpecialityId,
                0, 1, @LeadBranch, @UserId, GETDATE(), @Exec);
        SET @DoctorId = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.DoctorBranchMap (DoctorId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate)
        VALUES (@DoctorId, @LeadBranch, @CompanyId, 1, @UserId, GETDATE());
        INSERT dbo.DoctorDepartmentMap (DoctorId, DeptId, CompanyId, IsActive, CreatedBy, CreatedDate)
        SELECT @DoctorId, DeptId, @CompanyId, 1, @UserId, GETDATE() FROM dbo.DepartmentMaster
         WHERE CompanyId = @CompanyId AND IsActive = 1 AND DeptType = 'LAB';
    END

    UPDATE dbo.ForecastDoctor
       SET DoctorId = @DoctorId, Stage = 'TRIAL', PrimarySpecialityId = ISNULL(PrimarySpecialityId, @PrimarySpecialityId),
           PromotedDate = GETDATE(), PromotedBy = @UserId, ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE ForecastDoctorId = @ForecastDoctorId;
    INSERT dbo.ForecastDoctorStageLog (ForecastDoctorId, FromStage, ToStage, Reason, ChangedBy)
    VALUES (@ForecastDoctorId, @Stage, 'TRIAL', CASE WHEN @Linked = 1 THEN N'Linked to Doctor Master' ELSE N'Added to Doctor Master' END, @UserId);
    COMMIT;

    SELECT @DoctorId AS DoctorId, @Linked AS Linked, d.IsActive AS DoctorActive
      FROM dbo.DoctorMaster d WHERE d.DoctorId = @DoctorId;
END
GO

-- ── field day and tracking ───────────────────────────────────────────────────────────────────────────────────
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
    DECLARE @Open INT = (SELECT TOP 1 DayId FROM dbo.MarketingFieldDay WHERE UserId = @UserId AND EndDate IS NULL ORDER BY DayId DESC);
    IF @Exec IS NULL THROW 50000, N'This login is not an active marketing executive.', 1;

    IF @Action = 'START'
    BEGIN
        IF @Open IS NOT NULL THROW 50000, N'Your field day has already started.', 1;
        INSERT dbo.MarketingFieldDay (CompanyId, BranchId, UserId, ExecutiveId, DutyDate, StartDate, StartLat, StartLng)
        VALUES (@CompanyId, @BranchId, @UserId, @Exec, CAST(GETDATE() AS DATE), GETDATE(), @Latitude, @Longitude);
        SET @Open = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE IF @Action = 'END'
    BEGIN
        IF @Open IS NULL THROW 50000, N'Your field day has not started.', 1;
        UPDATE dbo.MarketingFieldDay SET EndDate = GETDATE(), EndLat = @Latitude, EndLng = @Longitude WHERE DayId = @Open;
    END
    ELSE THROW 50000, N'Action must be START or END.', 1;

    SELECT DayId, StartDate AS FieldStart, EndDate AS FieldEnd, CAST(CASE WHEN EndDate IS NULL THEN 1 ELSE 0 END AS BIT) AS OnField
      FROM dbo.MarketingFieldDay WHERE DayId = @Open;
END
GO

-- points recorded while the field day is open; points outside one are dropped
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Location_Batch
    @UserId INT,
    @Json   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DayId INT = (SELECT TOP 1 DayId FROM dbo.MarketingFieldDay WHERE UserId = @UserId AND EndDate IS NULL ORDER BY DayId DESC);
    IF @DayId IS NULL BEGIN SELECT 0 AS Saved; RETURN; END

    INSERT dbo.MarketingLocationPoint (UserId, DayId, PointTime, Latitude, Longitude, AccuracyM, SpeedMps, IsMock)
    SELECT DISTINCT @UserId, @DayId, j.[time], j.lat, j.lng, j.accuracy, j.speed, ISNULL(j.mock, 0)
      FROM OPENJSON(@Json) WITH ([time] DATETIME '$.time', lat DECIMAL(10, 8) '$.lat', lng DECIMAL(11, 8) '$.lng',
                                 accuracy DECIMAL(8, 2) '$.accuracy', speed DECIMAL(8, 2) '$.speed', mock BIT '$.mock') j
     WHERE j.[time] IS NOT NULL AND j.lat IS NOT NULL AND j.lng IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.MarketingLocationPoint p WHERE p.UserId = @UserId AND p.PointTime = j.[time]);
    SELECT @@ROWCOUNT AS Saved;
END
GO

-- ── home screen: pipeline, today, forecast ──────────────────────────────────────────────────────────────────
-- Forecast weights by stage (chance the lead becomes an active referrer): Prospect 10%, Contacted 20%, Engaged 40%,
-- Trial 70%, Active 100%. ForecastDoctors = expected new active referral doctors from the open pipeline;
-- ForecastReferrals = expected referrals a month (ExpectedMonthlyReferrals x weight, Active leads included).
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Summary
    @UserId    INT,
    @CompanyId INT,
    @BranchId  INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = (SELECT ExecutiveId FROM dbo.MarketingExecutive WHERE LoginUserId = @UserId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0);
    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @MonthStart DATE = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);

    ;WITH l AS (
        SELECT Stage, ExpectedMonthlyReferrals, NextFollowUpDate,
               CASE Stage WHEN 'PROSPECT' THEN 0.10 WHEN 'CONTACTED' THEN 0.20 WHEN 'ENGAGED' THEN 0.40
                          WHEN 'TRIAL' THEN 0.70 WHEN 'ACTIVE' THEN 1.00 ELSE 0 END AS Weight
          FROM dbo.ForecastDoctor WHERE ExecutiveId = @Exec AND BranchId = @BranchId AND IsActive = 1)
    SELECT SUM(CASE WHEN Stage = 'PROSPECT' THEN 1 ELSE 0 END) AS Prospect,
           SUM(CASE WHEN Stage = 'CONTACTED' THEN 1 ELSE 0 END) AS Contacted,
           SUM(CASE WHEN Stage = 'ENGAGED' THEN 1 ELSE 0 END) AS Engaged,
           SUM(CASE WHEN Stage = 'TRIAL' THEN 1 ELSE 0 END) AS Trial,
           SUM(CASE WHEN Stage = 'ACTIVE' THEN 1 ELSE 0 END) AS Active,
           SUM(CASE WHEN Stage = 'LOST' THEN 1 ELSE 0 END) AS Lost,
           SUM(CASE WHEN NextFollowUpDate = @Today AND Stage NOT IN ('ACTIVE', 'LOST') THEN 1 ELSE 0 END) AS FollowUpsToday,
           SUM(CASE WHEN NextFollowUpDate < @Today AND Stage NOT IN ('ACTIVE', 'LOST') THEN 1 ELSE 0 END) AS FollowUpsOverdue,
           CAST(ROUND(SUM(CASE WHEN Stage NOT IN ('ACTIVE', 'LOST') THEN Weight ELSE 0 END), 1) AS DECIMAL(10, 1)) AS ForecastDoctors,
           CAST(ROUND(SUM(ExpectedMonthlyReferrals * Weight), 0) AS INT) AS ForecastReferrals,
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @Today) AS VisitsToday,
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @Today
               AND v.VisitStatus = 'VERIFIED') AS VerifiedToday,
           (SELECT COUNT(*) FROM dbo.ForecastDoctor f WHERE f.ExecutiveId = @Exec AND f.BranchId = @BranchId AND f.IsActive = 1
               AND f.CreatedDate >= @MonthStart) AS LeadsThisMonth,
           (SELECT COUNT(*) FROM dbo.LabOrder o
              JOIN dbo.ForecastDoctor f ON f.DoctorId = o.ReferralDoctorId AND f.ExecutiveId = @Exec AND f.IsActive = 1
             WHERE o.BranchId = @BranchId AND o.OrderDate >= @MonthStart) AS ReferralsThisMonth
      FROM l;
END
GO

-- ── permission page, as the phlebotomist app (2373): the routes are [PublicEndpoint] and guarded by usp_Mkt_Guard ──
DECLARE @co INT, @lab INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @lab = NULL;
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @lab IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.MARKETINGAPP', @Title = N'Marketing Executive App',
             @Controller = N'Marketing', @Action = N'Session', @Show_In_Menu = 0, @Sort_Order = 77, @Icon = N'bi bi-bullseye me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

        DECLARE @m TABLE (Verb VARCHAR(6), Act NVARCHAR(50));
        DELETE @m;
        INSERT @m VALUES ('GET', N'AppMode'), ('GET', N'Session'), ('POST', N'RegisterDevice'), ('GET', N'Branches'), ('GET', N'Specialities'),
                         ('GET', N'Summary'), ('GET', N'Leads'), ('GET', N'Lead'), ('POST', N'SaveLead'), ('PUT', N'UpdateLead'),
                         ('POST', N'SetPin'), ('POST', N'SetStage'), ('POST', N'Promote'), ('POST', N'CreateVisit'),
                         ('POST', N'FieldDay'), ('POST', N'LocationBatch');
        DECLARE @verb VARCHAR(6), @act NVARCHAR(50);
        DECLARE mm CURSOR LOCAL FAST_FORWARD FOR SELECT Verb, Act FROM @m;
        OPEN mm; FETCH NEXT FROM mm INTO @verb, @act;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = @verb,
                 @Controller = N'Marketing', @Action = @act, @Source = 'SEED';
            FETCH NEXT FROM mm INTO @verb, @act;
        END
        CLOSE mm; DEALLOCATE mm;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- table and code descriptions (picked up by the data dictionary)
DECLARE @d TABLE (t SYSNAME, c SYSNAME NULL, v NVARCHAR(400));
INSERT @d VALUES
 (N'MarketingSettings', NULL, N'Marketing executive app rules, one row per company: visit radius, tracking interval, point retention.'),
 (N'ForecastDoctor', NULL, N'A referral doctor lead of a marketing executive (basic details only) until it joins Doctor Master at Trial.'),
 (N'ForecastDoctor', N'Stage', N'PROSPECT = not visited, CONTACTED = visited, ENGAGED = interested after 2+ visits, TRIAL = in Doctor Master, ACTIVE = referring, LOST'),
 (N'ForecastDoctor', N'DoctorId', N'The Doctor Master doctor the lead became (or was linked to) at Trial.'),
 (N'ForecastDoctorVisit', NULL, N'A visit to a lead, with the phone location and its distance from the clinic pin.'),
 (N'ForecastDoctorVisit', N'VisitStatus', N'VERIFIED = within the visit radius, OUTSIDE = farther, NO_PIN = clinic not pinned, NO_GPS = no location, MOCK = fake location'),
 (N'ForecastDoctorVisit', N'Outcome', N'INTERESTED, FOLLOW_UP, NOT_AVAILABLE, NOT_INTERESTED'),
 (N'ForecastDoctorStageLog', NULL, N'Every stage change of a lead, by the executive or by a visit.'),
 (N'MarketingFieldDay', NULL, N'A field day of a marketing executive: start and end with location; tracking runs while it is open.'),
 (N'MarketingLocationPoint', NULL, N'GPS points recorded during a marketing field day.');
DECLARE @t SYSNAME, @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT t, c, v FROM @d;
OPEN dc; FETCH NEXT FROM dc INTO @t, @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @c IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = 0 AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
        ELSE
            EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
    END
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.' + @t), @c, 'ColumnId') AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
        ELSE
            EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t, 'COLUMN', @c;
    END
    FETCH NEXT FROM dc INTO @t, @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO
