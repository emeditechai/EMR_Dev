-- ============================================================================================================
-- 2373  Phlebotomist app: tables, per-company settings and the LAB.PHLEBOAPP permission page.
--   A home visit hangs off LabOrder (the lab booking) and LabOrder.PhlebotomistId (Users); PatientMaster gives the
--   address, which is copied on to the visit so a later address change does not rewrite an old visit.
--   Procedures are in 2374. Web screens (dispatch, approvals) are not part of this script.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.Branchmaster', 'Latitude') IS NULL
    ALTER TABLE dbo.Branchmaster ADD Latitude DECIMAL(10, 8) NULL, Longitude DECIMAL(11, 8) NULL, GeofenceRadiusM INT NULL;
GO

IF OBJECT_ID('dbo.PhleboSettings', 'U') IS NULL
CREATE TABLE dbo.PhleboSettings (
    CompanyId                   INT            NOT NULL CONSTRAINT PK_PhleboSettings PRIMARY KEY
                                               CONSTRAINT FK_PhleboSettings_Company REFERENCES dbo.CompanyMaster (CompanyId),
    BranchRadiusM               INT            NOT NULL CONSTRAINT DF_PhleboSettings_BranchRadius DEFAULT (200),
    ArrivalRadiusM              INT            NOT NULL CONSTRAINT DF_PhleboSettings_ArrivalRadius DEFAULT (200),
    OutsideRadiusAction         VARCHAR(5)     NOT NULL CONSTRAINT DF_PhleboSettings_Outside DEFAULT ('FLAG'),   -- FLAG / BLOCK
    LateGraceMinutes            INT            NOT NULL CONSTRAINT DF_PhleboSettings_Grace DEFAULT (15),
    RequireSelfie               BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Selfie DEFAULT (1),
    RequireVehiclePhoto         BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Vehicle DEFAULT (1),
    RequireBagPhoto             BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Bag DEFAULT (1),
    RequireTempGunPhoto         BIT            NOT NULL CONSTRAINT DF_PhleboSettings_TempGun DEFAULT (1),
    RequireTemperature          BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Temp DEFAULT (1),
    FieldStartAllowed           BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Field DEFAULT (0),
    LocationIntervalSeconds     INT            NOT NULL CONSTRAINT DF_PhleboSettings_LocSec DEFAULT (60),
    LocationDistanceM           INT            NOT NULL CONSTRAINT DF_PhleboSettings_LocM DEFAULT (100),
    PayableKmTolerance          DECIMAL(4, 2)  NOT NULL CONSTRAINT DF_PhleboSettings_Tol DEFAULT (1.15),
    RatePerKm                   DECIMAL(10, 2) NOT NULL CONSTRAINT DF_PhleboSettings_Rate DEFAULT (0),
    VisitIncentive              DECIMAL(10, 2) NOT NULL CONSTRAINT DF_PhleboSettings_Incentive DEFAULT (0),
    OtpRequired                 BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Otp DEFAULT (1),
    OtpPoint                    VARCHAR(10)    NOT NULL CONSTRAINT DF_PhleboSettings_OtpPoint DEFAULT ('ARRIVAL'),   -- ARRIVAL / COMPLETION
    AcceptStepEnabled           BIT            NOT NULL CONSTRAINT DF_PhleboSettings_Accept DEFAULT (0),
    AcceptTimeoutMinutes        INT            NOT NULL CONSTRAINT DF_PhleboSettings_AcceptMin DEFAULT (30),
    BillChangeEscalationMinutes INT            NOT NULL CONSTRAINT DF_PhleboSettings_Escalate DEFAULT (10),
    AddTestAutoApprove          BIT            NOT NULL CONSTRAINT DF_PhleboSettings_AddTest DEFAULT (1),
    CashHoldingLimit            DECIMAL(12, 2) NULL,
    LocationRetentionDays       INT            NOT NULL CONSTRAINT DF_PhleboSettings_Retention DEFAULT (90),
    AutoApproveFirstDevice      BIT            NOT NULL CONSTRAINT DF_PhleboSettings_FirstDevice DEFAULT (1),
    ModifiedBy                  INT            NULL,
    ModifiedDate                DATETIME       NULL
);
GO
INSERT dbo.PhleboSettings (CompanyId)
SELECT c.CompanyId FROM dbo.CompanyMaster c WHERE NOT EXISTS (SELECT 1 FROM dbo.PhleboSettings s WHERE s.CompanyId = c.CompanyId);
GO

IF OBJECT_ID('dbo.PhleboStartPoint', 'U') IS NULL
CREATE TABLE dbo.PhleboStartPoint (
    StartPointId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboStartPoint PRIMARY KEY,
    CompanyId    INT            NOT NULL CONSTRAINT FK_PhleboStartPoint_Company REFERENCES dbo.CompanyMaster (CompanyId),
    Name         NVARCHAR(150)  NOT NULL,
    Latitude     DECIMAL(10, 8) NOT NULL,
    Longitude    DECIMAL(11, 8) NOT NULL,
    RadiusM      INT            NOT NULL CONSTRAINT DF_PhleboStartPoint_Radius DEFAULT (200),
    IsActive     BIT            NOT NULL CONSTRAINT DF_PhleboStartPoint_Active DEFAULT (1)
);
GO

IF OBJECT_ID('dbo.PhleboDevice', 'U') IS NULL
CREATE TABLE dbo.PhleboDevice (
    PhleboDeviceId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboDevice PRIMARY KEY,
    CompanyId      INT           NOT NULL,
    UserId         INT           NOT NULL CONSTRAINT FK_PhleboDevice_User REFERENCES dbo.Users (Id),
    DeviceId       NVARCHAR(100) NOT NULL,
    DeviceName     NVARCHAR(150) NULL,
    Platform       VARCHAR(10)   NULL,
    AppVersion     VARCHAR(20)   NULL,
    Status         VARCHAR(10)   NOT NULL CONSTRAINT DF_PhleboDevice_Status DEFAULT ('PENDING'),   -- PENDING / APPROVED / REVOKED
    ApprovedBy     INT           NULL,
    ApprovedDate   DATETIME      NULL,
    LastSeen       DATETIME      NULL,
    CreatedDate    DATETIME      NOT NULL CONSTRAINT DF_PhleboDevice_Created DEFAULT (GETDATE()),
    CONSTRAINT UQ_PhleboDevice_UserDevice UNIQUE (UserId, DeviceId)
);
GO

IF OBJECT_ID('dbo.PhleboAttendance', 'U') IS NULL
CREATE TABLE dbo.PhleboAttendance (
    AttendanceId      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboAttendance PRIMARY KEY,
    CompanyId         INT            NOT NULL,
    BranchId          INT            NOT NULL,
    UserId            INT            NOT NULL CONSTRAINT FK_PhleboAttendance_User REFERENCES dbo.Users (Id),
    DutyDate          DATE           NOT NULL,
    ShiftId           INT            NULL,
    PunchInAt         DATETIME       NOT NULL,
    PunchInLat        DECIMAL(10, 8) NULL,
    PunchInLng        DECIMAL(11, 8) NULL,
    PunchInAccuracyM  DECIMAL(8, 2)  NULL,
    PunchInDistanceM  DECIMAL(10, 1) NULL,
    PunchInIsMock     BIT            NOT NULL CONSTRAINT DF_PhleboAttendance_InMock DEFAULT (0),
    DeviceId          NVARCHAR(100)  NULL,
    IsFieldStart      BIT            NOT NULL CONSTRAINT DF_PhleboAttendance_Field DEFAULT (0),
    FieldStartReason  NVARCHAR(300)  NULL,
    TemperatureReading DECIMAL(5, 2) NULL,
    PunchInEventId    NVARCHAR(64)   NOT NULL,
    PunchOutAt        DATETIME       NULL,
    PunchOutLat       DECIMAL(10, 8) NULL,
    PunchOutLng       DECIMAL(11, 8) NULL,
    PunchOutIsMock    BIT            NOT NULL CONSTRAINT DF_PhleboAttendance_OutMock DEFAULT (0),
    PunchOutEventId   NVARCHAR(64)   NULL,
    DayStatus         VARCHAR(15)    NOT NULL CONSTRAINT DF_PhleboAttendance_Day DEFAULT ('PRESENT'),      -- PRESENT / LATE / HALF_DAY / ABSENT
    ReviewStatus      VARCHAR(15)    NOT NULL CONSTRAINT DF_PhleboAttendance_Review DEFAULT ('OK'),        -- OK / NEEDS_REVIEW / APPROVED / REFUSED
    ReviewReason      NVARCHAR(300)  NULL,
    CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_PhleboAttendance_Created DEFAULT (GETDATE()),
    CONSTRAINT UQ_PhleboAttendance_UserDay UNIQUE (UserId, DutyDate)
);
GO

IF OBJECT_ID('dbo.PhleboLocationPoint', 'U') IS NULL
CREATE TABLE dbo.PhleboLocationPoint (
    PointId       BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboLocationPoint PRIMARY KEY,
    UserId        INT            NOT NULL,
    AttendanceId  INT            NOT NULL CONSTRAINT FK_PhleboLocationPoint_Attendance REFERENCES dbo.PhleboAttendance (AttendanceId),
    PointTime     DATETIME       NOT NULL,
    Latitude      DECIMAL(10, 8) NOT NULL,
    Longitude     DECIMAL(11, 8) NOT NULL,
    AccuracyM     DECIMAL(8, 2)  NULL,
    SpeedMps      DECIMAL(8, 2)  NULL,
    IsMock        BIT            NOT NULL CONSTRAINT DF_PhleboLocationPoint_Mock DEFAULT (0),
    ReceivedDate  DATETIME       NOT NULL CONSTRAINT DF_PhleboLocationPoint_Received DEFAULT (GETDATE()),
    CONSTRAINT UQ_PhleboLocationPoint_UserTime UNIQUE (UserId, PointTime)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhleboLocationPoint_Attendance' AND object_id = OBJECT_ID('dbo.PhleboLocationPoint'))
    CREATE INDEX IX_PhleboLocationPoint_Attendance ON dbo.PhleboLocationPoint (AttendanceId, PointTime);
GO

IF OBJECT_ID('dbo.LabHomeVisit', 'U') IS NULL
CREATE TABLE dbo.LabHomeVisit (
    VisitId         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabHomeVisit PRIMARY KEY,
    CompanyId       INT            NOT NULL,
    BranchId        INT            NOT NULL,
    LabOrderId      INT            NOT NULL CONSTRAINT FK_LabHomeVisit_LabOrder REFERENCES dbo.LabOrder (LabOrderId),
    PatientId       INT            NOT NULL CONSTRAINT FK_LabHomeVisit_Patient REFERENCES dbo.PatientMaster (PatientId),
    PhlebotomistId  INT            NOT NULL CONSTRAINT FK_LabHomeVisit_User REFERENCES dbo.Users (Id),
    SlotAt          DATETIME       NULL,
    Status          VARCHAR(15)    NOT NULL CONSTRAINT DF_LabHomeVisit_Status DEFAULT ('ASSIGNED'),
    AddressSnapshot NVARCHAR(500)  NULL,
    Latitude        DECIMAL(10, 8) NULL,
    Longitude       DECIMAL(11, 8) NULL,
    ParentVisitId   INT            NULL CONSTRAINT FK_LabHomeVisit_Parent REFERENCES dbo.LabHomeVisit (VisitId),
    OtpHash         VARCHAR(64)    NULL,
    OtpExpiresOn    DATETIME       NULL,
    OtpAttempts     INT            NOT NULL CONSTRAINT DF_LabHomeVisit_OtpAttempts DEFAULT (0),
    OtpVerifiedOn   DATETIME       NULL,
    VerifyMethod    VARCHAR(10)    NULL,   -- OTP / ID_PROOF
    VerifyReason    NVARCHAR(300)  NULL,
    ConsentTaken    BIT            NOT NULL CONSTRAINT DF_LabHomeVisit_Consent DEFAULT (0),
    OutcomeReason   NVARCHAR(300)  NULL,
    NeedsReview     BIT            NOT NULL CONSTRAINT DF_LabHomeVisit_Review DEFAULT (0),
    HandoverId      INT            NULL,
    CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_LabHomeVisit_Created DEFAULT (GETDATE()),
    ModifiedDate    DATETIME       NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_LabHomeVisit_Order' AND object_id = OBJECT_ID('dbo.LabHomeVisit'))
    CREATE UNIQUE INDEX UQ_LabHomeVisit_Order ON dbo.LabHomeVisit (LabOrderId) WHERE ParentVisitId IS NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabHomeVisit_Phlebo' AND object_id = OBJECT_ID('dbo.LabHomeVisit'))
    CREATE INDEX IX_LabHomeVisit_Phlebo ON dbo.LabHomeVisit (PhlebotomistId, Status, SlotAt);
GO

IF OBJECT_ID('dbo.LabHomeVisitEvent', 'U') IS NULL
CREATE TABLE dbo.LabHomeVisitEvent (
    VisitEventId  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabHomeVisitEvent PRIMARY KEY,
    VisitId       INT            NOT NULL CONSTRAINT FK_LabHomeVisitEvent_Visit REFERENCES dbo.LabHomeVisit (VisitId),
    Status        VARCHAR(15)    NOT NULL,
    ClientEventId NVARCHAR(64)   NOT NULL CONSTRAINT UQ_LabHomeVisitEvent_Client UNIQUE,
    DeviceTime    DATETIME       NULL,
    ServerTime    DATETIME       NOT NULL CONSTRAINT DF_LabHomeVisitEvent_Server DEFAULT (GETDATE()),
    Latitude      DECIMAL(10, 8) NULL,
    Longitude     DECIMAL(11, 8) NULL,
    AccuracyM     DECIMAL(8, 2)  NULL,
    IsMock        BIT            NOT NULL CONSTRAINT DF_LabHomeVisitEvent_Mock DEFAULT (0),
    DistanceM     DECIMAL(10, 1) NULL,
    Reason        NVARCHAR(300)  NULL,
    CreatedBy     INT            NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabHomeVisitEvent_Visit' AND object_id = OBJECT_ID('dbo.LabHomeVisitEvent'))
    CREATE INDEX IX_LabHomeVisitEvent_Visit ON dbo.LabHomeVisitEvent (VisitId, ServerTime);
GO

IF OBJECT_ID('dbo.PhleboTravelLeg', 'U') IS NULL
CREATE TABLE dbo.PhleboTravelLeg (
    LegId         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboTravelLeg PRIMARY KEY,
    AttendanceId  INT            NOT NULL CONSTRAINT FK_PhleboTravelLeg_Attendance REFERENCES dbo.PhleboAttendance (AttendanceId),
    LegNo         INT            NOT NULL,
    FromLabel     NVARCHAR(100)  NOT NULL,
    ToLabel       NVARCHAR(100)  NOT NULL,
    FromTime      DATETIME       NOT NULL,
    ToTime        DATETIME       NOT NULL,
    ToVisitId     INT            NULL,
    GpsKm         DECIMAL(9, 3)  NOT NULL CONSTRAINT DF_PhleboTravelLeg_Gps DEFAULT (0),
    RoadKm        DECIMAL(9, 3)  NULL,
    PayableKm     DECIMAL(9, 3)  NOT NULL CONSTRAINT DF_PhleboTravelLeg_Pay DEFAULT (0),
    HasGap        BIT            NOT NULL CONSTRAINT DF_PhleboTravelLeg_Gap DEFAULT (0),
    ReviewStatus  VARCHAR(15)    NOT NULL CONSTRAINT DF_PhleboTravelLeg_Review DEFAULT ('OK'),   -- OK / NEEDS_REVIEW / APPROVED / REFUSED
    CONSTRAINT UQ_PhleboTravelLeg UNIQUE (AttendanceId, LegNo)
);
GO

IF OBJECT_ID('dbo.PhleboDocument', 'U') IS NULL
CREATE TABLE dbo.PhleboDocument (
    DocumentId    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboDocument PRIMARY KEY,
    CompanyId     INT           NOT NULL,
    BranchId      INT           NOT NULL,
    UserId        INT           NOT NULL,
    AttendanceId  INT           NULL,
    VisitId       INT           NULL CONSTRAINT FK_PhleboDocument_Visit REFERENCES dbo.LabHomeVisit (VisitId),
    DutyDate      DATE          NULL,
    DocType       VARCHAR(20)   NOT NULL,   -- SELFIE, VEHICLE, BAG, TEMP_GUN, ODOMETER, PRESCRIPTION, CONSENT, ID_PROOF, SIGNATURE
    FileName      NVARCHAR(200) NOT NULL,
    FilePath      NVARCHAR(400) NOT NULL,
    ContentType   NVARCHAR(100) NULL,
    FileSizeBytes BIGINT        NOT NULL,
    Remarks       NVARCHAR(300) NULL,
    CreatedDate   DATETIME      NOT NULL CONSTRAINT DF_PhleboDocument_Created DEFAULT (GETDATE())
);
GO

IF OBJECT_ID('dbo.PhleboCashLedger', 'U') IS NULL
CREATE TABLE dbo.PhleboCashLedger (
    CashLedgerId     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboCashLedger PRIMARY KEY,
    CompanyId        INT            NOT NULL,
    BranchId         INT            NOT NULL,
    UserId           INT            NOT NULL CONSTRAINT FK_PhleboCashLedger_User REFERENCES dbo.Users (Id),
    LabOrderId       INT            NULL,
    PaymentDetailId  INT            NULL,
    Amount           DECIMAL(12, 2) NOT NULL,   -- + collected from a patient, - deposited with the cashier
    EntryType        VARCHAR(10)    NOT NULL,   -- COLLECT / DEPOSIT
    DepositReference NVARCHAR(100)  NULL,
    CreatedBy        INT            NOT NULL,
    CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_PhleboCashLedger_Created DEFAULT (GETDATE())
);
GO

IF OBJECT_ID('dbo.LabBillChangeRequest', 'U') IS NULL
CREATE TABLE dbo.LabBillChangeRequest (
    BillChangeId      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabBillChangeRequest PRIMARY KEY,
    CompanyId         INT            NOT NULL,
    BranchId          INT            NOT NULL,
    LabOrderId        INT            NOT NULL CONSTRAINT FK_LabBillChangeRequest_Order REFERENCES dbo.LabOrder (LabOrderId),
    VisitId           INT            NULL CONSTRAINT FK_LabBillChangeRequest_Visit REFERENCES dbo.LabHomeVisit (VisitId),
    RequestType       VARCHAR(20)    NOT NULL,   -- ADD_TEST, REMOVE_TEST, REPLACE_TEST, DISCOUNT, PAYMENT_MODE, PATIENT_DETAILS
    Reason            NVARCHAR(300)  NOT NULL,
    Details           NVARCHAR(500)  NULL,
    OldTotal          DECIMAL(12, 2) NOT NULL,
    NewTotal          DECIMAL(12, 2) NOT NULL,
    Status            VARCHAR(10)    NOT NULL CONSTRAINT DF_LabBillChangeRequest_Status DEFAULT ('PENDING'),   -- PENDING / APPROVED / REFUSED / APPLIED
    ApprovalRequestId INT            NULL,
    ClientEventId     NVARCHAR(64)   NOT NULL CONSTRAINT UQ_LabBillChangeRequest_Client UNIQUE,
    RequestedBy       INT            NOT NULL,
    RequestedDate     DATETIME       NOT NULL CONSTRAINT DF_LabBillChangeRequest_Requested DEFAULT (GETDATE()),
    ActionedBy        INT            NULL,
    ActionedDate      DATETIME       NULL,
    ActionRemarks     NVARCHAR(300)  NULL
);
GO
IF OBJECT_ID('dbo.LabBillChangeLine', 'U') IS NULL
CREATE TABLE dbo.LabBillChangeLine (
    BillChangeLineId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabBillChangeLine PRIMARY KEY,
    BillChangeId     INT            NOT NULL CONSTRAINT FK_LabBillChangeLine_Request REFERENCES dbo.LabBillChangeRequest (BillChangeId),
    LineAction       VARCHAR(10)    NOT NULL,   -- ADD / REMOVE
    InvestigationId  INT            NOT NULL,
    Price            DECIMAL(12, 2) NOT NULL,
    TaxAmount        DECIMAL(12, 2) NOT NULL CONSTRAINT DF_LabBillChangeLine_Tax DEFAULT (0)
);
GO
IF OBJECT_ID('dbo.LabBillRevision', 'U') IS NULL
CREATE TABLE dbo.LabBillRevision (
    BillRevisionId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabBillRevision PRIMARY KEY,
    LabOrderId     INT           NOT NULL CONSTRAINT FK_LabBillRevision_Order REFERENCES dbo.LabOrder (LabOrderId),
    RevisionNo     INT           NOT NULL,
    BillChangeId   INT           NULL CONSTRAINT FK_LabBillRevision_Request REFERENCES dbo.LabBillChangeRequest (BillChangeId),
    Snapshot       NVARCHAR(MAX) NOT NULL,
    AppliedBy      INT           NOT NULL,
    AppliedDate    DATETIME      NOT NULL CONSTRAINT DF_LabBillRevision_Applied DEFAULT (GETDATE()),
    CONSTRAINT UQ_LabBillRevision UNIQUE (LabOrderId, RevisionNo)
);
GO

IF OBJECT_ID('dbo.PhleboHandover', 'U') IS NULL
CREATE TABLE dbo.PhleboHandover (
    HandoverId     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboHandover PRIMARY KEY,
    CompanyId      INT           NOT NULL,
    BranchId       INT           NOT NULL,
    PhlebotomistId INT           NOT NULL CONSTRAINT FK_PhleboHandover_User REFERENCES dbo.Users (Id),
    ReceiverName   NVARCHAR(150) NOT NULL,
    TemperatureC   DECIMAL(5, 2) NULL,
    Status         VARCHAR(10)   NOT NULL CONSTRAINT DF_PhleboHandover_Status DEFAULT ('SUBMITTED'),   -- SUBMITTED / RECEIVED
    ClientEventId  NVARCHAR(64)  NOT NULL CONSTRAINT UQ_PhleboHandover_Client UNIQUE,
    HandedOverAt   DATETIME      NOT NULL CONSTRAINT DF_PhleboHandover_At DEFAULT (GETDATE()),
    ReceivedBy     INT           NULL,
    ReceivedAt     DATETIME      NULL
);
GO
IF OBJECT_ID('dbo.PhleboHandoverLine', 'U') IS NULL
CREATE TABLE dbo.PhleboHandoverLine (
    HandoverLineId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PhleboHandoverLine PRIMARY KEY,
    HandoverId     INT           NOT NULL CONSTRAINT FK_PhleboHandoverLine_Handover REFERENCES dbo.PhleboHandover (HandoverId),
    VisitId        INT           NOT NULL CONSTRAINT FK_PhleboHandoverLine_Visit REFERENCES dbo.LabHomeVisit (VisitId),
    BarcodeNo      NVARCHAR(50)  NOT NULL,
    IsReceived     BIT           NOT NULL CONSTRAINT DF_PhleboHandoverLine_Received DEFAULT (0),
    CONSTRAINT UQ_PhleboHandoverLine UNIQUE (HandoverId, VisitId, BarcodeNo)
);
GO

-- ── page and endpoints: api/auth tokens are refused on any endpoint not mapped to a page ───────────────────
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
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.PHLEBOAPP', @Title = N'Phlebotomist App',
             @Controller = N'Phlebo', @Action = N'Session', @Show_In_Menu = 0, @Sort_Order = 76, @Icon = N'bi bi-phone me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

        DECLARE @m TABLE (Verb VARCHAR(6), Act NVARCHAR(50));
        DELETE @m;
        INSERT @m VALUES ('GET', N'Session'), ('POST', N'RegisterDevice'), ('POST', N'AttendancePhoto'), ('POST', N'Punch'), ('POST', N'LocationBatch'),
                         ('GET', N'Visits'), ('GET', N'Visit'), ('POST', N'VisitEvent'), ('POST', N'Verify'), ('POST', N'Samples'), ('POST', N'Payment'),
                         ('POST', N'Documents'), ('POST', N'CreateBillChange'), ('GET', N'BillChanges'), ('POST', N'Handover'), ('GET', N'Summary'), ('GET', N'SearchTests');
        DECLARE @verb VARCHAR(6), @act NVARCHAR(50);
        DECLARE mm CURSOR LOCAL FAST_FORWARD FOR SELECT Verb, Act FROM @m;
        OPEN mm; FETCH NEXT FROM mm INTO @verb, @act;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = @verb, @Controller = N'Phlebo', @Action = @act, @Source = 'SEED';
            FETCH NEXT FROM mm INTO @verb, @act;
        END
        CLOSE mm; DEALLOCATE mm;

        -- starter grant: the roles today's phlebotomists hold. A client changes this in Settings > Security.
        INSERT dbo.RolePermission (Role_ID, Page_ID, Permission, CompanyId, Reason, CreatedBy)
        SELECT DISTINCT ur.RoleId, @page, 'A', @co, N'Phlebotomist app (2373)', 1
          FROM dbo.Users u
          JOIN dbo.Userroles ur ON ur.UserId = u.Id AND ur.IsActive = 1
         WHERE u.IsPhlebotomist = 1 AND u.IsActive = 1 AND u.CompanyId = @co
           AND NOT EXISTS (SELECT 1 FROM dbo.RolePermission rp WHERE rp.Role_ID = ur.RoleId AND rp.Page_ID = @page AND rp.Control_ID IS NULL AND rp.Branch_ID IS NULL);

        UPDATE dbo.Users SET Permission_Version = Permission_Version + 1 WHERE IsPhlebotomist = 1 AND CompanyId = @co;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- table descriptions (picked up by the data dictionary)
DECLARE @d TABLE (t SYSNAME, v NVARCHAR(400));
INSERT @d VALUES
 (N'PhleboSettings', N'Phlebotomist app rules, one row per company; seeded values are starter defaults.'),
 (N'PhleboStartPoint', N'Named duty start points (hubs, collection centres) with a radius, besides the branch.'),
 (N'PhleboDevice', N'Phones registered by a phlebotomist; only an approved phone can use the app.'),
 (N'PhleboAttendance', N'One duty day per phlebotomist: punch in and out with location, day status and review status.'),
 (N'PhleboLocationPoint', N'GPS points recorded on duty; purged after LocationRetentionDays.'),
 (N'LabHomeVisit', N'One home collection visit of a lab booking (LabOrder), from assignment to lab receipt.'),
 (N'LabHomeVisitEvent', N'Every visit status change with device and server time and GPS; ClientEventId makes a retry harmless.'),
 (N'PhleboTravelLeg', N'Server-built travel legs of a duty day: GPS km, road km and payable km.'),
 (N'PhleboDocument', N'Photos taken in the app: duty checklist, prescription, consent, ID proof.'),
 (N'PhleboCashLedger', N'Cash held by a phlebotomist: + collected from patients, - deposited with the cashier.'),
 (N'LabBillChangeRequest', N'A bill change raised from the field; the server prices it and an approver decides.'),
 (N'LabBillChangeLine', N'Tests added or removed by a bill change request.'),
 (N'LabBillRevision', N'Snapshot of a lab bill for each applied change; the bill number stays the same.'),
 (N'PhleboHandover', N'Manifest of samples handed from a phlebotomist to the lab or a runner.'),
 (N'PhleboHandoverLine', N'One barcode on a handover manifest.');
DECLARE @t SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT t, v FROM @d;
OPEN dc; FETCH NEXT FROM dc INTO @t, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.' + @t) AND minor_id = 0 AND name = 'MS_Description')
        EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
    ELSE
        EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', @t;
    FETCH NEXT FROM dc INTO @t, @v;
END
CLOSE dc; DEALLOCATE dc;
GO
