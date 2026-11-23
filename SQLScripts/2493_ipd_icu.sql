-- 2493: IPD Phase 8 - ICU depth.
--   * ICU flowsheet (IpdIcuObservation): vitals, GCS, RASS, pain, glucose, intake / output and ventilator settings at a time;
--     only for a time the patient held an ICU bed; never edited - a wrong entry is struck out with a reason and entered again.
--   * Infusions (IpdIcuInfusion + IpdIcuInfusionEvent): drug, concentration, rate ml/h and dose, rate changes and stop.
--   * Device use (IpdIcuDevice): ventilator, infusion / syringe pumps and other optional heads of the ICU tariff, start / stop.
--   * ICU tariff: an ICU bed day is priced from Master > ICU Tariff (the ICU whose ward is the bed's ward; patient's tariff
--     category, else the branch's default category): every mandatory head each ICU day, an optional head only on a day the
--     device of that head (same code) was in use; a head billed other than "Per Day" is charged once per admission.
--     ICU days without an ICU tariff stay on the Bed / Room Tariff as before. No GST on ICU days.
--   * ICU stays from the bed movements, with return to ICU within 48 hours (NABH indicator).
-- Replaces fn_Ipd_BedDays and fn_Ipd_BillLines (from 2422 / 2434 / 2485) and patches the bed-rate checks of usp_Api_IpdAdmission_Save /
-- _Update, usp_Api_IpdBed_Transfer / _ForTransfer and usp_Api_Ipd_Beds so an ICU bed with an ICU tariff can be given:
-- re-run this script after any of 2422, 2423, 2431, 2434 or 2485.
-- Needs 2422-2492. Safe to re-run.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── 1. tables ─────────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdIcuObservation') IS NULL
CREATE TABLE dbo.IpdIcuObservation
(
    ObservationId BIGINT IDENTITY(1,1) CONSTRAINT PK_IpdIcuObservation PRIMARY KEY,
    AdmissionId   INT NOT NULL CONSTRAINT FK_IpdIcuObs_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    BedId         INT NULL,
    ObservedAt    DATETIME NOT NULL,
    Hr            SMALLINT NULL,
    Sbp           SMALLINT NULL,
    Dbp           SMALLINT NULL,
    Map           AS (CASE WHEN Sbp IS NOT NULL AND Dbp IS NOT NULL THEN CAST(ROUND((Sbp + 2.0 * Dbp) / 3, 0) AS SMALLINT) END) PERSISTED,
    Rr            SMALLINT NULL,
    SpO2          DECIMAL(4,1) NULL,
    TempC         DECIMAL(4,1) NULL,
    Cvp           SMALLINT NULL,
    EtCo2         SMALLINT NULL,
    GcsE          TINYINT NULL,
    GcsV          TINYINT NULL,
    GcsM          TINYINT NULL,
    Gcs           AS (CASE WHEN GcsE IS NOT NULL AND GcsV IS NOT NULL AND GcsM IS NOT NULL THEN CAST(GcsE + GcsV + GcsM AS TINYINT) END) PERSISTED,
    Rass          SMALLINT NULL,
    PainScore     TINYINT NULL,
    Glucose       DECIMAL(6,1) NULL,
    IntakeMl      INT NULL,
    UrineMl       INT NULL,
    OtherOutputMl INT NULL,
    VentMode      NVARCHAR(30) NULL,
    FiO2          TINYINT NULL,
    Peep          DECIMAL(4,1) NULL,
    TidalVolume   SMALLINT NULL,
    SetRate       SMALLINT NULL,
    Pip           SMALLINT NULL,
    PressureSupport SMALLINT NULL,
    Notes         NVARCHAR(500) NULL,
    Status        VARCHAR(8) NOT NULL CONSTRAINT DF_IpdIcuObs_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdIcuObs_Status CHECK (Status IN ('ACTIVE', 'STRUCK')),
    StruckReason  NVARCHAR(300) NULL,
    StruckBy      INT NULL,
    StruckAt      DATETIME NULL,
    RecordedBy    INT NOT NULL,
    RecordedAt    DATETIME NOT NULL CONSTRAINT DF_IpdIcuObs_At DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdIcuObs_Adm' AND object_id = OBJECT_ID('dbo.IpdIcuObservation'))
    CREATE INDEX IX_IpdIcuObs_Adm ON dbo.IpdIcuObservation (AdmissionId, ObservedAt) WHERE Status = 'ACTIVE';
GO

IF OBJECT_ID('dbo.IpdIcuInfusion') IS NULL
CREATE TABLE dbo.IpdIcuInfusion
(
    InfusionId    INT IDENTITY(1,1) CONSTRAINT PK_IpdIcuInfusion PRIMARY KEY,
    AdmissionId   INT NOT NULL CONSTRAINT FK_IpdIcuInf_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    Drug          NVARCHAR(150) NOT NULL,
    Concentration NVARCHAR(100) NULL,     -- e.g. 4 mg in 50 ml NS
    RateMlHr      DECIMAL(7,2) NOT NULL,
    Dose          NVARCHAR(100) NULL,     -- e.g. 0.1 mcg/kg/min
    Route         NVARCHAR(30) NULL,
    StartAt       DATETIME NOT NULL,
    StopAt        DATETIME NULL,
    Status        VARCHAR(8) NOT NULL CONSTRAINT DF_IpdIcuInf_Status DEFAULT ('RUNNING') CONSTRAINT CK_IpdIcuInf_Status CHECK (Status IN ('RUNNING', 'STOPPED', 'STRUCK')),
    StopReason    NVARCHAR(300) NULL,
    Remarks       NVARCHAR(300) NULL,
    CreatedBy     INT NOT NULL,
    CreatedDate   DATETIME NOT NULL CONSTRAINT DF_IpdIcuInf_Created DEFAULT (GETDATE())
);
GO
IF OBJECT_ID('dbo.IpdIcuInfusionEvent') IS NULL
CREATE TABLE dbo.IpdIcuInfusionEvent
(
    EventId     INT IDENTITY(1,1) CONSTRAINT PK_IpdIcuInfusionEvent PRIMARY KEY,
    InfusionId  INT NOT NULL CONSTRAINT FK_IpdIcuInfEv_Inf REFERENCES dbo.IpdIcuInfusion (InfusionId),
    EventType   VARCHAR(8) NOT NULL CONSTRAINT CK_IpdIcuInfEv_Type CHECK (EventType IN ('START', 'RATE', 'STOP', 'STRUCK')),
    RateMlHr    DECIMAL(7,2) NULL,
    Dose        NVARCHAR(100) NULL,
    EventAt     DATETIME NOT NULL,
    Remarks     NVARCHAR(300) NULL,
    CreatedBy   INT NOT NULL,
    CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdIcuInfEv_Created DEFAULT (GETDATE())
);
GO
IF OBJECT_ID('dbo.IpdIcuDevice') IS NULL
CREATE TABLE dbo.IpdIcuDevice
(
    DeviceId    INT IDENTITY(1,1) CONSTRAINT PK_IpdIcuDevice PRIMARY KEY,
    AdmissionId INT NOT NULL CONSTRAINT FK_IpdIcuDev_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    HeadCode    NVARCHAR(50) NOT NULL,    -- the ICU tariff head (IcuTariffDetail.RateHeadCode), e.g. VENT
    HeadName    NVARCHAR(100) NOT NULL,
    StartAt     DATETIME NOT NULL,
    StopAt      DATETIME NULL,
    Status      VARCHAR(8) NOT NULL CONSTRAINT DF_IpdIcuDev_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdIcuDev_Status CHECK (Status IN ('ACTIVE', 'STRUCK')),
    Remarks     NVARCHAR(300) NULL,
    StruckReason NVARCHAR(300) NULL,
    CreatedBy   INT NOT NULL,
    CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdIcuDev_Created DEFAULT (GETDATE()),
    ModifiedBy  INT NULL,
    ModifiedDate DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdIcuDevice_Adm' AND object_id = OBJECT_ID('dbo.IpdIcuDevice'))
    CREATE INDEX IX_IpdIcuDevice_Adm ON dbo.IpdIcuDevice (AdmissionId, HeadCode) INCLUDE (StartAt, StopAt) WHERE Status = 'ACTIVE';
GO

-- ── 2. ICU tariff of a bed's ward ─────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_IcuTariff (@BranchId INT, @WardId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) t.IcuTariffId, i.IcuId, i.IcuName, i.IcuType,
           CAST(CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END AS BIT) AS UsedFallback
    FROM dbo.IcuMaster i
    JOIN dbo.IcuTariffMaster t ON t.IcuId = i.IcuId AND t.BranchId = @BranchId AND t.IsActive = 1
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    WHERE i.BranchId = @BranchId AND i.WardId = @WardId AND i.IsActive = 1
      AND t.TariffCategoryId IN (@TariffCategoryId, ISNULL(s.IpdDefaultTariffCategoryId, @TariffCategoryId))
      AND CAST(t.EffectiveFrom AS DATE) <= @OnDate AND (t.EffectiveTo IS NULL OR CAST(t.EffectiveTo AS DATE) >= @OnDate)
      AND EXISTS (SELECT 1 FROM dbo.IcuTariffDetail d WHERE d.IcuTariffId = t.IcuTariffId)
    ORDER BY CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END, t.EffectiveFrom DESC, t.IcuTariffId DESC
);
GO

-- daily rate of an ICU bed from its ICU tariff: the mandatory heads billed per day (NULL when the bed is not ICU or has no ICU tariff)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_IcuDailyRate (@BranchId INT, @BedId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT it.IcuTariffId, it.IcuName, it.UsedFallback,
           CAST((SELECT ISNULL(SUM(d.RateAmount), 0) FROM dbo.IcuTariffDetail d
                 WHERE d.IcuTariffId = it.IcuTariffId AND d.IsMandatory = 1 AND ISNULL(d.BillingFrequency, N'Per Day') IN (N'Per Day', N'Daily', N'Day')) AS DECIMAL(18,2)) AS DailyRate
    FROM dbo.BedMaster b
    CROSS APPLY dbo.fn_Ipd_IcuTariff(@BranchId, b.WardId, @TariffCategoryId, @OnDate) it
    WHERE b.BedId = @BedId AND ISNULL(b.IsICU, 0) = 1
);
GO

-- ── 3. bed days (replaces 2485): + WardId and the ICU tariff of an ICU day ─────────────────────────────────────────
-- One row per chargeable bed day of a stay up to @AsOf (or the discharge, if earlier), with the bed held and its rate.
--   CALENDAR (default): every calendar day from the admission date; the discharge day is not charged when the
--                       patient leaves before the grace hour (Hospital Settings > IPD, default 12:00) - a stay
--                       within one day is always one day. The bed of a day = the bed held at the end of that day.
--   HOURLY24          : one day per started 24 hours from the admission time, after the grace hours (default 2).
--   CHECKINOUT        : hotel-style days between the branch's Check-Out times (Hospital Settings > Daily Check-In /
--                       Check-Out Time); admitted within the grace hours before check-out or discharged within them after it
--                       adds no day. Falls back to CALENDAR when the branch has no check-out time.
-- GST: the tariff's GST % on a non-ICU day whose total is above the room-rent threshold (default Rs 5,000/day);
-- 0 = always the tariff's GST %. ICU days carry no GST. An ICU day with an ICU tariff (2493) is priced from it.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BedDays (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    WITH a AS
    (
        SELECT ad.AdmissionId, ad.BranchId, ad.TariffCategoryId, ad.AdmissionAt,
               CASE WHEN ad.DischargeAt IS NOT NULL AND ad.DischargeAt < @AsOf THEN ad.DischargeAt ELSE @AsOf END AS EndAt,
               CASE WHEN s.IpdBedChargeMode = 'CHECKINOUT' AND s.CheckOutTime IS NULL THEN 'CALENDAR' ELSE ISNULL(s.IpdBedChargeMode, 'CALENDAR') END AS Mode,
               DATEDIFF(MINUTE, CAST('00:00' AS TIME), ISNULL(s.CheckOutTime, CAST('12:00' AS TIME))) AS OutMin,
               ISNULL(s.IpdDischargeGraceHour, 12) AS GraceHour,
               ISNULL(s.IpdHourlyGraceHours, 2) AS GraceHours, ISNULL(s.IpdRoomGstThreshold, 5000) AS GstThreshold
        FROM dbo.IpdAdmission ad
        LEFT JOIN dbo.HospitalSettings s ON s.BranchID = ad.BranchId
        WHERE ad.AdmissionId = @AdmissionId AND ad.Status <> 'CANCELLED' AND ad.AdmissionAt <= @AsOf
    ),
    n AS
    (
        SELECT a.*,
               CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE) AS CioStart,
               CAST(CASE WHEN a.Mode = 'CHECKINOUT'
                    THEN CASE WHEN DATEDIFF(DAY, CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE),
                                                 CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, -a.GraceHours * 60, a.EndAt)) AS DATE)) + 1 < 1 THEN 1
                              ELSE DATEDIFF(DAY, CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE),
                                                 CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, -a.GraceHours * 60, a.EndAt)) AS DATE)) + 1 END
                    WHEN a.Mode = 'HOURLY24'
                    THEN CASE WHEN DATEDIFF(MINUTE, a.AdmissionAt, a.EndAt) - a.GraceHours * 60 <= 0 THEN 1
                              ELSE CEILING((DATEDIFF(MINUTE, a.AdmissionAt, a.EndAt) - a.GraceHours * 60) / 1440.0) END
                    ELSE DATEDIFF(DAY, a.AdmissionAt, a.EndAt) + 1
                         - CASE WHEN DATEDIFF(DAY, a.AdmissionAt, a.EndAt) >= 1
                                 AND DATEPART(HOUR, a.EndAt) * 60 + DATEPART(MINUTE, a.EndAt) < a.GraceHour * 60 THEN 1 ELSE 0 END
               END AS INT) AS Days
        FROM a
    ),
    d AS
    (
        SELECT n.AdmissionId, n.BranchId, n.TariffCategoryId, n.GstThreshold, k.k + 1 AS DayNo,
               CASE WHEN n.Mode = 'HOURLY24' THEN CAST(DATEADD(MINUTE, 1440 * k.k, n.AdmissionAt) AS DATE)
                    WHEN n.Mode = 'CHECKINOUT' THEN DATEADD(DAY, k.k, n.CioStart)
                    ELSE DATEADD(DAY, k.k, CAST(n.AdmissionAt AS DATE)) END AS DayDate,
               CASE WHEN n.Mode = 'CHECKINOUT'
                    THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) < n.EndAt
                              THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) < n.AdmissionAt THEN n.AdmissionAt
                                        ELSE DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) END
                              ELSE n.EndAt END
                    WHEN n.Mode = 'HOURLY24'
                    THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, 1440 * (k.k + 1), n.AdmissionAt)) < n.EndAt
                              THEN DATEADD(SECOND, -1, DATEADD(MINUTE, 1440 * (k.k + 1), n.AdmissionAt)) ELSE n.EndAt END
                    ELSE CASE WHEN DATEADD(SECOND, -1, CAST(DATEADD(DAY, k.k + 1, CAST(n.AdmissionAt AS DATE)) AS DATETIME)) < n.EndAt
                              THEN DATEADD(SECOND, -1, CAST(DATEADD(DAY, k.k + 1, CAST(n.AdmissionAt AS DATE)) AS DATETIME)) ELSE n.EndAt END
               END AS PointAt
        FROM n
        CROSS APPLY (SELECT TOP (CASE WHEN n.Days < 1 THEN 1 ELSE n.Days END) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS k
                     FROM sys.all_columns c1 CROSS JOIN sys.all_columns c2) k
    )
    SELECT d.AdmissionId, d.DayNo, d.DayDate, m.BedId, b.BedNumber, w.WardName, r.RoomNumber, bc.CategoryName AS BedCategoryName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu,
           ISNULL(rt.RoomCharge, 0) AS RoomCharge, ISNULL(rt.BedCharge, 0) AS BedCharge, ISNULL(rt.NursingCharge, 0) AS NursingCharge, ISNULL(rt.RmoCharge, 0) AS RmoCharge,
           ISNULL(rt.AttendantCharge, 0) AS AttendantCharge, ISNULL(rt.IsolationCharge, 0) AS IsolationCharge,
           CAST(ISNULL(rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge, 0) AS DECIMAL(18,2)) AS DayTotal,
           CAST(CASE WHEN rt.BedRateId IS NULL OR ISNULL(b.IsICU, 0) = 1 THEN 0
                     WHEN d.GstThreshold > 0 AND rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge <= d.GstThreshold THEN 0
                     ELSE rt.GstPercentage END AS DECIMAL(5,2)) AS GstPercent,
           CAST(CASE WHEN rt.BedRateId IS NULL AND it.IcuTariffId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff,
           CAST(CASE WHEN it.IcuTariffId IS NOT NULL THEN it.UsedFallback ELSE ISNULL(rt.UsedFallback, 0) END AS BIT) AS UsedFallback,
           b.WardId, it.IcuTariffId, it.IcuName
    FROM d
    OUTER APPLY (SELECT TOP (1) mv.BedId FROM dbo.IpdBedMovement mv
                 WHERE mv.AdmissionId = d.AdmissionId AND mv.FromAt <= d.PointAt ORDER BY mv.FromAt DESC, mv.MovementId DESC) m
    LEFT JOIN dbo.BedMaster b ON b.BedId = m.BedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY dbo.fn_Ipd_BedRate(d.BranchId, m.BedId, d.TariffCategoryId, d.DayDate) rt
    OUTER APPLY (SELECT x.IcuTariffId, x.IcuName, x.UsedFallback FROM dbo.fn_Ipd_IcuTariff(d.BranchId, b.WardId, d.TariffCategoryId, d.DayDate) x
                 WHERE ISNULL(b.IsICU, 0) = 1) it
    WHERE m.BedId IS NOT NULL
);
GO

-- ── 4. bill lines (replaces 2434): ICU days with an ICU tariff are priced by its heads ─────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BillLines (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    WITH adm AS
    (
        SELECT a.AdmissionId, a.BillId, a.PackageId, a.AdmissionAt,
               (SELECT MAX(pc.Days) FROM dbo.fn_Ipd_PackageCover(a.PackageId) pc WHERE pc.Head = 'BED') AS PkgDays
        FROM dbo.IpdAdmission a WHERE a.AdmissionId = @AdmissionId
    )
    -- bed days (live) priced from the Bed / Room Tariff
    SELECT CAST(CONCAT('B', bd.DayNo, '-', v.Code) AS NVARCHAR(40)) AS LineKey,
           CAST(CASE WHEN bd.IsIcu = 1 THEN 'ICU' ELSE 'BED' END AS VARCHAR(20)) AS Head,
           CAST(bd.DayDate AS DATETIME) AS ChargeAt, CAST(v.Code AS NVARCHAR(50)) AS ItemCode,
           CAST(CASE WHEN bd.NoTariff = 1 AND pk.InPkg = 0 THEN N'No bed tariff for ' + ISNULL(bd.BedCategoryName, N'this bed')
                     WHEN bd.NoTariff = 1 THEN N'Bed (in package)' ELSE v.Name END AS NVARCHAR(250)) AS ItemName,
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.WardName, N' / ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)) AS Detail,
           CAST(NULL AS NVARCHAR(150)) AS DoctorName,
           CAST(1 AS DECIMAL(18,3)) AS Qty, v.Amount AS Rate,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount END AS DECIMAL(18,2)) AS Gross, CAST(0 AS DECIMAL(18,2)) AS Discount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.GstPercent END AS DECIMAL(5,2)) AS GstPercent,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS GstAmount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount + ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS Net,
           CAST('ACCRUED' AS VARCHAR(10)) AS Status, CAST('IPD' AS VARCHAR(10)) AS SourceModule, CAST(NULL AS NVARCHAR(50)) AS SourceNo,
           CAST(pk.InPkg AS BIT) AS IsPackageItem, CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.NoTariff END AS BIT) AS NoTariff, bd.UsedFallback, bd.DayNo, v.Sort
    FROM adm
    CROSS APPLY dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    CROSS APPLY (SELECT CASE WHEN bd.IsIcu = 0 AND bd.DayNo <= ISNULL(adm.PkgDays, 0) THEN 1 ELSE 0 END AS InPkg) pk
    CROSS APPLY (VALUES ('ROOM', N'Room Rent', bd.RoomCharge, 1), ('BED', N'Bed Charge', bd.BedCharge, 2),
                        ('NURSING', N'Nursing Charge', bd.NursingCharge, 3), ('RMO', N'RMO Charge', bd.RmoCharge, 4), ('ATTENDANT', N'Attendant Charge', bd.AttendantCharge, 5),
                        ('ISOLATION', N'Isolation Charge', bd.IsolationCharge, 6), ('NOTARIFF', N'', CAST(0 AS DECIMAL(18,2)), 7)) v (Code, Name, Amount, Sort)
    WHERE adm.BillId IS NULL AND bd.IcuTariffId IS NULL
      AND ((bd.NoTariff = 0 AND v.Code <> 'NOTARIFF' AND v.Amount > 0) OR (bd.NoTariff = 1 AND v.Code = 'NOTARIFF'))

    UNION ALL
    -- ICU days (live) priced from the ICU tariff: mandatory heads every day, optional heads on days the device was in use;
    -- a head not billed "Per Day" only once, on the first ICU day it applies
    SELECT CAST(CONCAT('I', bd.DayNo, '-', dt.IcuTariffDetailId) AS NVARCHAR(40)), CAST('ICU' AS VARCHAR(20)), CAST(bd.DayDate AS DATETIME),
           CAST(dt.RateHeadCode AS NVARCHAR(50)), CAST(dt.RateHeadName AS NVARCHAR(250)),
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.IcuName, N' · ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)),
           CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), CAST(dt.RateAmount AS DECIMAL(18,2)), CAST(dt.RateAmount AS DECIMAL(18,2)),
           CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)), CAST(dt.RateAmount AS DECIMAL(18,2)),
           CAST('ACCRUED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), CAST(NULL AS NVARCHAR(50)), CAST(0 AS BIT), CAST(0 AS BIT), bd.UsedFallback, bd.DayNo,
           10 + ISNULL(dt.DisplayOrder, 0)
    FROM adm
    CROSS APPLY dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    JOIN dbo.IcuTariffDetail dt ON dt.IcuTariffId = bd.IcuTariffId AND dt.RateAmount > 0
    WHERE adm.BillId IS NULL AND bd.IcuTariffId IS NOT NULL
      AND (dt.IsMandatory = 1
           OR EXISTS (SELECT 1 FROM dbo.IpdIcuDevice dv WHERE dv.AdmissionId = @AdmissionId AND dv.Status = 'ACTIVE' AND dv.HeadCode = dt.RateHeadCode
                      AND dv.StartAt < DATEADD(DAY, 1, CAST(bd.DayDate AS DATETIME)) AND (dv.StopAt IS NULL OR dv.StopAt > CAST(bd.DayDate AS DATETIME))
                      AND dv.StartAt <= @AsOf))
      AND (ISNULL(dt.BillingFrequency, N'Per Day') IN (N'Per Day', N'Daily', N'Day')
           OR bd.DayNo = (SELECT MIN(b2.DayNo) FROM dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) b2
                          WHERE b2.IcuTariffId IS NOT NULL
                            AND (dt.IsMandatory = 1
                                 OR EXISTS (SELECT 1 FROM dbo.IpdIcuDevice dv WHERE dv.AdmissionId = @AdmissionId AND dv.Status = 'ACTIVE' AND dv.HeadCode = dt.RateHeadCode
                                            AND dv.StartAt < DATEADD(DAY, 1, CAST(b2.DayDate AS DATETIME)) AND (dv.StopAt IS NULL OR dv.StopAt > CAST(b2.DayDate AS DATETIME))))))

    UNION ALL
    -- the package amount (live, once)
    SELECT CAST('PKG' AS NVARCHAR(40)), CAST('PACKAGE' AS VARCHAR(20)), adm.AdmissionAt, CAST(p.Package_Code AS NVARCHAR(50)), CAST(p.Package_Name AS NVARCHAR(250)),
           CAST(N'Package' AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), CAST(p.TotalPackageAmount AS DECIMAL(18,2)),
           CAST(p.TotalPackageAmount AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(p.TotalPackageAmount AS DECIMAL(18,2)), CAST('ACCRUED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), CAST(NULL AS NVARCHAR(50)),
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.HospitalPackageMaster p ON p.HospitalPackage_ID = adm.PackageId
    WHERE adm.BillId IS NULL AND adm.AdmissionAt <= @AsOf

    UNION ALL
    -- posted charges (live)
    SELECT CAST(CONCAT('C', c.ChargeId) AS NVARCHAR(40)), c.Head, c.ChargeAt, c.ItemCode, c.ItemName,
           CAST(CASE WHEN c.SourceNo IS NOT NULL THEN CONCAT(c.SourceModule, N' ', c.SourceNo) ELSE c.Remarks END AS NVARCHAR(300)),
           CAST(doc.FullName AS NVARCHAR(150)),
           c.Qty, c.Rate, c.Gross, c.Discount, c.GstPercent, c.GstAmount, c.Net,
           CAST('POSTED' AS VARCHAR(10)), c.SourceModule, c.SourceNo, c.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm
    JOIN dbo.IpdCharge c ON c.AdmissionId = adm.AdmissionId AND c.Status = 'POSTED' AND c.ChargeAt <= @AsOf
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = c.DoctorId
    WHERE adm.BillId IS NULL

    UNION ALL
    -- the final bill: its frozen lines
    SELECT l.LineKey, l.Head, l.ChargeAt, l.ItemCode, l.ItemName, l.Detail, l.DoctorName, l.Qty, l.Rate, l.Gross,
           CAST(l.ItemDiscount + l.BillDiscount AS DECIMAL(18,2)), l.GstPercent, l.GstAmount, l.Net,
           CAST('BILLED' AS VARCHAR(10)), l.SourceModule, l.SourceNo, l.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), l.DayNo, l.Sort
    FROM adm JOIN dbo.IpdBillLine l ON l.BillId = adm.BillId

    UNION ALL
    SELECT CAST('ROUNDOFF' AS NVARCHAR(40)), CAST('ADJUST' AS VARCHAR(20)), b.BillUpToAt, CAST(NULL AS NVARCHAR(50)), CAST(N'Round off' AS NVARCHAR(250)),
           CAST(NULL AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), b.RoundOff, CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)), b.RoundOff, CAST('BILLED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), b.BillNo,
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.IpdBill b ON b.BillId = adm.BillId WHERE b.RoundOff <> 0
);
GO

-- ── 5. ICU stays and return within 48 h ─────────────────────────────────────────────────────────────────────────────
-- One row per continuous stretch of the admission in ICU beds (consecutive ICU bed movements form one stay).
CREATE OR ALTER FUNCTION dbo.fn_Ipd_IcuStays (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    WITH m AS
    (
        SELECT mv.MovementId, mv.FromAt, mv.ToAt, CAST(ISNULL(b.IsICU, 0) AS INT) AS IsIcu,
               ROW_NUMBER() OVER (ORDER BY mv.FromAt, mv.MovementId) AS rn
        FROM dbo.IpdBedMovement mv JOIN dbo.BedMaster b ON b.BedId = mv.BedId
        WHERE mv.AdmissionId = @AdmissionId
    ),
    g AS
    (
        SELECT m.*, m.rn - ROW_NUMBER() OVER (PARTITION BY m.IsIcu ORDER BY m.FromAt, m.MovementId) AS grp FROM m
    ),
    s AS
    (
        SELECT MIN(g.FromAt) AS InAt,
               CASE WHEN COUNT(*) = COUNT(g.ToAt) THEN MAX(g.ToAt) END AS OutAt,
               MIN(g.rn) AS FirstRn
        FROM g WHERE g.IsIcu = 1 GROUP BY g.grp
    )
    SELECT ROW_NUMBER() OVER (ORDER BY s.InAt) AS StayNo, s.InAt, s.OutAt,
           LAG(s.OutAt) OVER (ORDER BY s.InAt) AS PrevOutAt,
           DATEDIFF(MINUTE, LAG(s.OutAt) OVER (ORDER BY s.InAt), s.InAt) / 60.0 AS HoursSincePrev,
           CAST(CASE WHEN LAG(s.OutAt) OVER (ORDER BY s.InAt) IS NOT NULL AND DATEDIFF(MINUTE, LAG(s.OutAt) OVER (ORDER BY s.InAt), s.InAt) <= 48 * 60 THEN 1 ELSE 0 END AS BIT) AS IsReturn48h,
           DATEDIFF(MINUTE, s.InAt, ISNULL(s.OutAt, GETDATE())) / 60.0 AS Hours
    FROM s
);
GO

-- ── 6. ICU chart data ─────────────────────────────────────────────────────────────────────────────────────────────
-- @FromAt / @ToAt: the window of the chart (default the last 24 hours).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_Data @CompanyId INT, @BranchId INT, @AdmissionId INT, @FromAt DATETIME = NULL, @ToAt DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT, @bed INT, @tc INT, @now DATETIME = GETDATE();
    SELECT @adm = AdmissionId, @bed = CurrentBedId, @tc = TariffCategoryId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    SET @ToAt = ISNULL(@ToAt, @now); SET @FromAt = ISNULL(@FromAt, DATEADD(HOUR, -24, @ToAt));
    -- 1 state: in an ICU bed now, the ICU tariff and the current stay
    SELECT CAST(ISNULL(b.IsICU, 0) AS BIT) AS InIcuNow, b.BedNumber, w.WardName, it.IcuTariffId, it.IcuName, it.UsedFallback AS TariffFallback,
           (SELECT TOP (1) InAt FROM dbo.fn_Ipd_IcuStays(@adm) WHERE OutAt IS NULL ORDER BY InAt DESC) AS CurrentStayInAt,
           (SELECT MAX(ObservedAt) FROM dbo.IpdIcuObservation WHERE AdmissionId = @adm AND Status = 'ACTIVE') AS LastObservedAt,
           @FromAt AS FromAt, @ToAt AS ToAt
    FROM (SELECT 1 AS x) one
    LEFT JOIN dbo.BedMaster b ON b.BedId = @bed
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    OUTER APPLY (SELECT x.IcuTariffId, x.IcuName, x.UsedFallback FROM dbo.fn_Ipd_IcuTariff(@BranchId, b.WardId, @tc, CAST(@now AS DATE)) x WHERE ISNULL(b.IsICU, 0) = 1) it
    WHERE @adm IS NOT NULL;
    -- 2 ICU stays
    SELECT StayNo, InAt, OutAt, PrevOutAt, HoursSincePrev, IsReturn48h, Hours FROM dbo.fn_Ipd_IcuStays(@adm) ORDER BY StayNo;
    -- 3 observations of the window (struck ones too, marked)
    SELECT o.*, u.FullName AS RecordedByName, us.FullName AS StruckByName
    FROM dbo.IpdIcuObservation o LEFT JOIN dbo.Users u ON u.Id = o.RecordedBy LEFT JOIN dbo.Users us ON us.Id = o.StruckBy
    WHERE o.AdmissionId = @adm AND o.ObservedAt >= @FromAt AND o.ObservedAt <= @ToAt
    ORDER BY o.ObservedAt, o.ObservationId;
    -- 4 infusions running in the window or started in it
    SELECT i.InfusionId, i.Drug, i.Concentration, i.RateMlHr, i.Dose, i.Route, i.StartAt, i.StopAt, i.Status, i.StopReason, i.Remarks, u.FullName AS CreatedByName
    FROM dbo.IpdIcuInfusion i LEFT JOIN dbo.Users u ON u.Id = i.CreatedBy
    WHERE i.AdmissionId = @adm AND i.Status <> 'STRUCK' AND i.StartAt <= @ToAt AND (i.StopAt IS NULL OR i.StopAt >= @FromAt)
    ORDER BY CASE i.Status WHEN 'RUNNING' THEN 0 ELSE 1 END, i.StartAt DESC;
    -- 5 infusion events
    SELECT e.EventId, e.InfusionId, e.EventType, e.RateMlHr, e.Dose, e.EventAt, e.Remarks, u.FullName AS CreatedByName
    FROM dbo.IpdIcuInfusionEvent e JOIN dbo.IpdIcuInfusion i ON i.InfusionId = e.InfusionId LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    WHERE i.AdmissionId = @adm ORDER BY e.EventAt, e.EventId;
    -- 6 device use (all of the admission)
    SELECT d.DeviceId, d.HeadCode, d.HeadName, d.StartAt, d.StopAt, d.Status, d.Remarks, d.StruckReason,
           DATEDIFF(MINUTE, d.StartAt, ISNULL(d.StopAt, @now)) / 60.0 AS Hours, u.FullName AS CreatedByName
    FROM dbo.IpdIcuDevice d LEFT JOIN dbo.Users u ON u.Id = d.CreatedBy
    WHERE d.AdmissionId = @adm ORDER BY CASE WHEN d.StopAt IS NULL AND d.Status = 'ACTIVE' THEN 0 ELSE 1 END, d.StartAt DESC;
    -- 7 device heads that can be recorded: the optional heads of the patient's ICU tariff, else the common ICU devices
    SELECT DISTINCT dt.RateHeadCode AS Code, dt.RateHeadName AS Name, dt.RateAmount AS Rate, dt.BillingFrequency
    FROM dbo.BedMaster b
    CROSS APPLY dbo.fn_Ipd_IcuTariff(@BranchId, b.WardId, @tc, CAST(@now AS DATE)) it
    JOIN dbo.IcuTariffDetail dt ON dt.IcuTariffId = it.IcuTariffId AND dt.IsMandatory = 0
    WHERE b.BedId = @bed AND ISNULL(b.IsICU, 0) = 1
    UNION
    SELECT v.Code, v.Name, CAST(NULL AS DECIMAL(18,2)), CAST(NULL AS NVARCHAR(50))
    FROM (VALUES (N'VENT', N'Mechanical ventilator'), (N'NIV', N'Non-invasive ventilation (BiPAP / CPAP)'), (N'INF', N'Infusion pump'),
                 (N'SYR', N'Syringe pump'), (N'HFNO', N'High-flow nasal oxygen')) v (Code, Name)
    WHERE NOT EXISTS (SELECT 1 FROM dbo.BedMaster b CROSS APPLY dbo.fn_Ipd_IcuTariff(@BranchId, b.WardId, @tc, CAST(@now AS DATE)) it
                      JOIN dbo.IcuTariffDetail dt ON dt.IcuTariffId = it.IcuTariffId AND dt.IsMandatory = 0 WHERE b.BedId = @bed AND ISNULL(b.IsICU, 0) = 1);
    -- 8 intake / output by 24 h period (08:00 to 08:00) over the last 7 days
    SELECT CAST(DATEADD(HOUR, -8, o.ObservedAt) AS DATE) AS Day, SUM(ISNULL(o.IntakeMl, 0)) AS IntakeMl, SUM(ISNULL(o.UrineMl, 0)) AS UrineMl,
           SUM(ISNULL(o.OtherOutputMl, 0)) AS OtherOutputMl, SUM(ISNULL(o.IntakeMl, 0)) - SUM(ISNULL(o.UrineMl, 0)) - SUM(ISNULL(o.OtherOutputMl, 0)) AS BalanceMl
    FROM dbo.IpdIcuObservation o
    WHERE o.AdmissionId = @adm AND o.Status = 'ACTIVE' AND o.ObservedAt >= DATEADD(DAY, -7, @now)
    GROUP BY CAST(DATEADD(HOUR, -8, o.ObservedAt) AS DATE) ORDER BY 1 DESC;
END;
GO

-- ── 7. observations ───────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_AddObservation
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ObservedAt DATETIME,
    @Hr SMALLINT = NULL, @Sbp SMALLINT = NULL, @Dbp SMALLINT = NULL, @Rr SMALLINT = NULL, @SpO2 DECIMAL(4,1) = NULL, @TempC DECIMAL(4,1) = NULL,
    @Cvp SMALLINT = NULL, @EtCo2 SMALLINT = NULL, @GcsE TINYINT = NULL, @GcsV TINYINT = NULL, @GcsM TINYINT = NULL, @Rass SMALLINT = NULL,
    @PainScore TINYINT = NULL, @Glucose DECIMAL(6,1) = NULL, @IntakeMl INT = NULL, @UrineMl INT = NULL, @OtherOutputMl INT = NULL,
    @VentMode NVARCHAR(30) = NULL, @FiO2 TINYINT = NULL, @Peep DECIMAL(4,1) = NULL, @TidalVolume SMALLINT = NULL, @SetRate SMALLINT = NULL,
    @Pip SMALLINT = NULL, @PressureSupport SMALLINT = NULL, @Notes NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @admAt DATETIME, @dis DATETIME;
        SELECT @st = Status, @admAt = AdmissionAt, @dis = DischargeAt FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @st IS NULL THROW 57301, 'The admission was not found in this branch.', 1;
        IF @st = 'CANCELLED' THROW 57302, 'The admission is cancelled.', 1;
        IF @ObservedAt IS NULL THROW 57303, 'Enter the time of the observation.', 1;
        SET @ObservedAt = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ObservedAt), 0);
        IF @ObservedAt > DATEADD(MINUTE, 5, @now) THROW 57304, 'The observation time cannot be in the future.', 1;
        IF @ObservedAt < @admAt OR (@dis IS NOT NULL AND @ObservedAt > @dis) THROW 57305, 'The observation time is outside the admission.', 1;
        DECLARE @bed INT, @icu BIT;
        SELECT TOP (1) @bed = mv.BedId, @icu = ISNULL(b.IsICU, 0) FROM dbo.IpdBedMovement mv JOIN dbo.BedMaster b ON b.BedId = mv.BedId
        WHERE mv.AdmissionId = @AdmissionId AND mv.FromAt <= @ObservedAt ORDER BY mv.FromAt DESC, mv.MovementId DESC;
        IF ISNULL(@icu, 0) = 0 THROW 57306, 'The patient was not in an ICU bed at that time (shift the patient to an ICU bed first).', 1;
        IF COALESCE(@Hr, @Sbp, @Dbp, @Rr, @Cvp, @EtCo2, @Rass, @PainScore, @IntakeMl, @UrineMl, @OtherOutputMl, @FiO2, @TidalVolume, @SetRate, @Pip, @PressureSupport) IS NULL
           AND @SpO2 IS NULL AND @TempC IS NULL AND @Glucose IS NULL AND @Peep IS NULL AND COALESCE(@GcsE, @GcsV, @GcsM) IS NULL
           AND NULLIF(LTRIM(RTRIM(@VentMode)), N'') IS NULL AND NULLIF(LTRIM(RTRIM(@Notes)), N'') IS NULL
            THROW 57307, 'Enter at least one reading.', 1;
        SELECT @msg = CASE
            WHEN @Hr NOT BETWEEN 0 AND 300 THEN N'Heart rate must be 0-300 /min.'
            WHEN @Sbp NOT BETWEEN 0 AND 300 THEN N'Systolic BP must be 0-300 mmHg.'
            WHEN @Dbp NOT BETWEEN 0 AND 200 THEN N'Diastolic BP must be 0-200 mmHg.'
            WHEN @Sbp IS NOT NULL AND @Dbp IS NOT NULL AND @Dbp > @Sbp THEN N'Diastolic BP cannot be above systolic.'
            WHEN (@Sbp IS NULL AND @Dbp IS NOT NULL) OR (@Sbp IS NOT NULL AND @Dbp IS NULL) THEN N'Enter both systolic and diastolic BP.'
            WHEN @Rr NOT BETWEEN 0 AND 80 THEN N'Respiratory rate must be 0-80 /min.'
            WHEN @SpO2 NOT BETWEEN 0 AND 100 THEN N'SpO2 must be 0-100 %.'
            WHEN @TempC NOT BETWEEN 25 AND 45 THEN N'Temperature must be 25-45 °C.'
            WHEN @Cvp NOT BETWEEN -10 AND 40 THEN N'CVP must be -10 to 40 cmH2O.'
            WHEN @EtCo2 NOT BETWEEN 0 AND 150 THEN N'EtCO2 must be 0-150 mmHg.'
            WHEN @GcsE NOT BETWEEN 1 AND 4 OR @GcsV NOT BETWEEN 1 AND 5 OR @GcsM NOT BETWEEN 1 AND 6 THEN N'GCS: eyes 1-4, verbal 1-5, motor 1-6.'
            WHEN (@GcsE IS NULL OR @GcsV IS NULL OR @GcsM IS NULL) AND COALESCE(@GcsE, @GcsV, @GcsM) IS NOT NULL THEN N'Enter all three GCS parts (eyes, verbal, motor).'
            WHEN @Rass NOT BETWEEN -5 AND 4 THEN N'RASS must be -5 to +4.'
            WHEN @PainScore > 10 THEN N'Pain score must be 0-10.'
            WHEN @Glucose NOT BETWEEN 0 AND 1500 THEN N'Glucose must be 0-1500 mg/dl.'
            WHEN @IntakeMl NOT BETWEEN 0 AND 10000 OR @UrineMl NOT BETWEEN 0 AND 10000 OR @OtherOutputMl NOT BETWEEN 0 AND 10000 THEN N'Intake / output must be 0-10,000 ml.'
            WHEN @FiO2 NOT BETWEEN 21 AND 100 THEN N'FiO2 must be 21-100 %.'
            WHEN @Peep NOT BETWEEN 0 AND 30 THEN N'PEEP must be 0-30 cmH2O.'
            WHEN @TidalVolume NOT BETWEEN 0 AND 2000 THEN N'Tidal volume must be 0-2000 ml.'
            WHEN @SetRate NOT BETWEEN 0 AND 80 THEN N'Set rate must be 0-80 /min.'
            WHEN @Pip NOT BETWEEN 0 AND 80 OR @PressureSupport NOT BETWEEN 0 AND 60 THEN N'Airway pressures out of range (PIP 0-80, PS 0-60).'
            END;
        IF @msg IS NOT NULL THROW 57308, @msg, 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdIcuObservation WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND ObservedAt = @ObservedAt AND Status = 'ACTIVE')
            THROW 57309, 'There is already an observation at this time: strike it out first to correct it.', 1;
        INSERT dbo.IpdIcuObservation (AdmissionId, BedId, ObservedAt, Hr, Sbp, Dbp, Rr, SpO2, TempC, Cvp, EtCo2, GcsE, GcsV, GcsM, Rass, PainScore, Glucose,
               IntakeMl, UrineMl, OtherOutputMl, VentMode, FiO2, Peep, TidalVolume, SetRate, Pip, PressureSupport, Notes, RecordedBy)
        VALUES (@AdmissionId, @bed, @ObservedAt, @Hr, @Sbp, @Dbp, @Rr, @SpO2, @TempC, @Cvp, @EtCo2, @GcsE, @GcsV, @GcsM, @Rass, @PainScore, @Glucose,
               @IntakeMl, @UrineMl, @OtherOutputMl, NULLIF(LTRIM(RTRIM(@VentMode)), N''), @FiO2, @Peep, @TidalVolume, @SetRate, @Pip, @PressureSupport,
               NULLIF(LTRIM(RTRIM(@Notes)), N''), @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS ObservationId, @AdmissionId AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- Strikes out a flowsheet entry (kept, shown struck through) or a device / infusion entered by mistake.
-- @Kind OBS / DEVICE / INFUSION.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_Strike @CompanyId INT, @BranchId INT, @UserId INT, @Kind VARCHAR(10), @Id BIGINT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 57321, 'Enter the reason for striking out the entry.', 1;
        DECLARE @adm INT, @bill INT;
        IF @Kind = 'OBS'
        BEGIN
            SELECT @adm = o.AdmissionId FROM dbo.IpdIcuObservation o WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = o.AdmissionId
            WHERE o.ObservationId = @Id AND o.Status = 'ACTIVE' AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
            IF @adm IS NULL THROW 57322, 'The entry was not found (or is already struck out).', 1;
            UPDATE dbo.IpdIcuObservation SET Status = 'STRUCK', StruckReason = LTRIM(RTRIM(@Reason)), StruckBy = @UserId, StruckAt = @now WHERE ObservationId = @Id;
        END
        ELSE IF @Kind = 'DEVICE'
        BEGIN
            SELECT @adm = d.AdmissionId, @bill = a.BillId FROM dbo.IpdIcuDevice d WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = d.AdmissionId
            WHERE d.DeviceId = @Id AND d.Status = 'ACTIVE' AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
            IF @adm IS NULL THROW 57322, 'The entry was not found (or is already struck out).', 1;
            IF @bill IS NOT NULL THROW 57323, 'The final bill is made (device days are billed): cancel the bill first.', 1;
            UPDATE dbo.IpdIcuDevice SET Status = 'STRUCK', StruckReason = LTRIM(RTRIM(@Reason)), ModifiedBy = @UserId, ModifiedDate = @now WHERE DeviceId = @Id;
        END
        ELSE IF @Kind = 'INFUSION'
        BEGIN
            SELECT @adm = i.AdmissionId FROM dbo.IpdIcuInfusion i WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = i.AdmissionId
            WHERE i.InfusionId = @Id AND i.Status <> 'STRUCK' AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
            IF @adm IS NULL THROW 57322, 'The entry was not found (or is already struck out).', 1;
            UPDATE dbo.IpdIcuInfusion SET Status = 'STRUCK', StopReason = LTRIM(RTRIM(@Reason)), StopAt = ISNULL(StopAt, @now) WHERE InfusionId = @Id;
            INSERT dbo.IpdIcuInfusionEvent (InfusionId, EventType, EventAt, Remarks, CreatedBy) VALUES (@Id, 'STRUCK', @now, LTRIM(RTRIM(@Reason)), @UserId);
        END
        ELSE THROW 57324, 'Unknown entry.', 1;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'ICU_STRIKE', LEFT(CONCAT(CASE @Kind WHEN 'OBS' THEN N'ICU observation' WHEN 'DEVICE' THEN N'ICU device entry' ELSE N'Infusion' END,
                N' struck out: ', LTRIM(RTRIM(@Reason))), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 8. infusions ──────────────────────────────────────────────────────────────────────────────────────────────────
-- @InfusionId NULL = start a new infusion; else @EventType RATE (new rate / dose) or STOP.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_Infusion
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @InfusionId INT = NULL, @EventType VARCHAR(8) = 'START', @Drug NVARCHAR(150) = NULL,
    @Concentration NVARCHAR(100) = NULL, @RateMlHr DECIMAL(7,2) = NULL, @Dose NVARCHAR(100) = NULL, @Route NVARCHAR(30) = NULL, @EventAt DATETIME = NULL,
    @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @open BIT, @admAt DATETIME;
        SELECT @st = Status, @open = IsOpen, @admAt = AdmissionAt FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @st IS NULL THROW 57331, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @st = 'CANCELLED' THROW 57332, 'The admission is closed.', 1;
        SET @EventAt = ISNULL(@EventAt, @now);
        IF @EventAt > DATEADD(MINUTE, 5, @now) OR @EventAt < @admAt THROW 57333, 'The time must be within the admission and not in the future.', 1;
        IF @RateMlHr IS NOT NULL AND (@RateMlHr < 0 OR @RateMlHr > 1000) THROW 57334, 'The rate must be 0-1000 ml/h.', 1;
        IF @InfusionId IS NULL
        BEGIN
            IF NULLIF(LTRIM(RTRIM(@Drug)), N'') IS NULL THROW 57335, 'Enter the drug / fluid.', 1;
            IF @RateMlHr IS NULL THROW 57336, 'Enter the rate in ml/h.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdBedMovement mv JOIN dbo.BedMaster b ON b.BedId = mv.BedId
                           WHERE mv.AdmissionId = @AdmissionId AND mv.FromAt <= @EventAt AND (mv.ToAt IS NULL OR mv.ToAt > @EventAt) AND b.IsICU = 1)
                THROW 57337, 'The patient was not in an ICU bed at that time.', 1;
            INSERT dbo.IpdIcuInfusion (AdmissionId, Drug, Concentration, RateMlHr, Dose, Route, StartAt, Remarks, CreatedBy)
            VALUES (@AdmissionId, LTRIM(RTRIM(@Drug)), NULLIF(LTRIM(RTRIM(@Concentration)), N''), @RateMlHr, NULLIF(LTRIM(RTRIM(@Dose)), N''),
                    NULLIF(LTRIM(RTRIM(@Route)), N''), @EventAt, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
            SET @InfusionId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.IpdIcuInfusionEvent (InfusionId, EventType, RateMlHr, Dose, EventAt, Remarks, CreatedBy)
            VALUES (@InfusionId, 'START', @RateMlHr, NULLIF(LTRIM(RTRIM(@Dose)), N''), @EventAt, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        END
        ELSE
        BEGIN
            DECLARE @ist VARCHAR(8), @start DATETIME;
            SELECT @ist = Status, @start = StartAt FROM dbo.IpdIcuInfusion WITH (UPDLOCK) WHERE InfusionId = @InfusionId AND AdmissionId = @AdmissionId;
            IF @ist IS NULL THROW 57338, 'The infusion was not found.', 1;
            IF @ist <> 'RUNNING' THROW 57339, 'The infusion is not running.', 1;
            IF @EventAt < @start THROW 57340, 'The time cannot be before the infusion started.', 1;
            IF @EventType = 'RATE'
            BEGIN
                IF @RateMlHr IS NULL THROW 57341, 'Enter the new rate in ml/h.', 1;
                UPDATE dbo.IpdIcuInfusion SET RateMlHr = @RateMlHr, Dose = ISNULL(NULLIF(LTRIM(RTRIM(@Dose)), N''), Dose) WHERE InfusionId = @InfusionId;
            END
            ELSE IF @EventType = 'STOP'
                UPDATE dbo.IpdIcuInfusion SET Status = 'STOPPED', StopAt = @EventAt, StopReason = NULLIF(LTRIM(RTRIM(@Remarks)), N'') WHERE InfusionId = @InfusionId;
            ELSE THROW 57342, 'Choose rate change or stop.', 1;
            INSERT dbo.IpdIcuInfusionEvent (InfusionId, EventType, RateMlHr, Dose, EventAt, Remarks, CreatedBy)
            VALUES (@InfusionId, @EventType, @RateMlHr, NULLIF(LTRIM(RTRIM(@Dose)), N''), @EventAt, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @InfusionId AS InfusionId, @AdmissionId AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 9. device use (ventilator, pumps, ...) ──────────────────────────────────────────────────────────────────────
-- @DeviceId NULL = start; else stop it at @At. A device of the same head cannot overlap itself. Before the final bill only.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_Device
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @DeviceId INT = NULL, @HeadCode NVARCHAR(50) = NULL, @HeadName NVARCHAR(100) = NULL,
    @At DATETIME = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @open BIT, @admAt DATETIME, @bill INT;
        SELECT @st = Status, @open = IsOpen, @admAt = AdmissionAt, @bill = BillId FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @st IS NULL THROW 57351, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @st NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') OR @bill IS NOT NULL THROW 57352, 'Device use can be recorded only before the final bill.', 1;
        SET @At = ISNULL(@At, @now);
        IF @At > DATEADD(MINUTE, 5, @now) OR @At < @admAt THROW 57353, 'The time must be within the admission and not in the future.', 1;
        IF @DeviceId IS NULL
        BEGIN
            SET @HeadCode = NULLIF(LTRIM(RTRIM(@HeadCode)), N'');
            IF @HeadCode IS NULL THROW 57354, 'Choose the device.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdBedMovement mv JOIN dbo.BedMaster b ON b.BedId = mv.BedId
                           WHERE mv.AdmissionId = @AdmissionId AND mv.FromAt <= @At AND (mv.ToAt IS NULL OR mv.ToAt > @At) AND b.IsICU = 1)
                THROW 57355, 'The patient was not in an ICU bed at that time.', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdIcuDevice WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND HeadCode = @HeadCode AND Status = 'ACTIVE'
                       AND (StopAt IS NULL OR StopAt > @At))
                THROW 57356, 'This device is already in use for the patient: stop it first.', 1;
            INSERT dbo.IpdIcuDevice (AdmissionId, HeadCode, HeadName, StartAt, Remarks, CreatedBy)
            VALUES (@AdmissionId, @HeadCode, ISNULL(NULLIF(LTRIM(RTRIM(@HeadName)), N''), @HeadCode), @At, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
            SET @DeviceId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'ICU_DEVICE', LEFT(CONCAT(ISNULL(NULLIF(LTRIM(RTRIM(@HeadName)), N''), @HeadCode), N' started ', FORMAT(@At, 'dd-MMM HH:mm')), 1000), @UserId);
        END
        ELSE
        BEGIN
            DECLARE @start DATETIME, @stop DATETIME, @name NVARCHAR(100);
            SELECT @start = StartAt, @stop = StopAt, @name = HeadName FROM dbo.IpdIcuDevice WITH (UPDLOCK) WHERE DeviceId = @DeviceId AND AdmissionId = @AdmissionId AND Status = 'ACTIVE';
            IF @start IS NULL THROW 57357, 'The device entry was not found.', 1;
            IF @stop IS NOT NULL THROW 57358, 'The device is already stopped.', 1;
            IF @At < @start THROW 57359, 'The stop time cannot be before the start.', 1;
            UPDATE dbo.IpdIcuDevice SET StopAt = @At, Remarks = ISNULL(NULLIF(LTRIM(RTRIM(@Remarks)), N''), Remarks), ModifiedBy = @UserId, ModifiedDate = @now WHERE DeviceId = @DeviceId;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'ICU_DEVICE', LEFT(CONCAT(@name, N' stopped ', FORMAT(@At, 'dd-MMM HH:mm')), 1000), @UserId);
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @DeviceId AS DeviceId, @AdmissionId AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 10. ICU board: every patient in an ICU bed now, and returns within 48 h in the last 30 days ─────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIcu_Board @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SELECT a.AdmissionId, a.IpNo, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, @now) AS AgeText, p.Gender, a.ProvisionalDiagnosis,
           LTRIM(RTRIM(ISNULL(cd.NamePrefix + ' ', '') + cd.FullName)) AS ConsultantName,
           w.WardName, r.RoomNumber, b.BedNumber, it.IcuName,
           st.InAt AS IcuInAt, st.IsReturn48h, DATEDIFF(MINUTE, st.InAt, @now) / 60.0 AS IcuHours,
           o.ObservedAt AS LastObservedAt, DATEDIFF(MINUTE, o.ObservedAt, @now) AS MinutesSinceObs,
           o.Hr, o.Sbp, o.Dbp, o.Map, o.Rr, o.SpO2, o.TempC, o.Gcs, o.FiO2, o.VentMode,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdIcuDevice d WHERE d.AdmissionId = a.AdmissionId AND d.Status = 'ACTIVE' AND d.StopAt IS NULL AND d.HeadCode IN (N'VENT', N'NIV'))
                     THEN 1 ELSE 0 END AS BIT) AS OnVentilator,
           (SELECT COUNT(*) FROM dbo.IpdIcuInfusion i WHERE i.AdmissionId = a.AdmissionId AND i.Status = 'RUNNING') AS RunningInfusions,
           (SELECT STRING_AGG(i.Drug, N', ') FROM dbo.IpdIcuInfusion i WHERE i.AdmissionId = a.AdmissionId AND i.Status = 'RUNNING') AS InfusionDrugs
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId AND b.IsICU = 1
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    OUTER APPLY (SELECT TOP (1) s.InAt, s.IsReturn48h FROM dbo.fn_Ipd_IcuStays(a.AdmissionId) s WHERE s.OutAt IS NULL ORDER BY s.InAt DESC) st
    OUTER APPLY (SELECT TOP (1) x.IcuName FROM dbo.fn_Ipd_IcuTariff(a.BranchId, b.WardId, a.TariffCategoryId, CAST(@now AS DATE)) x) it
    OUTER APPLY (SELECT TOP (1) * FROM dbo.IpdIcuObservation x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'ACTIVE' ORDER BY x.ObservedAt DESC) o
    WHERE a.BranchId = @BranchId AND a.CompanyId = @CompanyId AND a.IsOpen = 1 AND a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL')
    ORDER BY w.WardName, b.BedNumber;
    -- ICU beds of the branch: total / occupied
    SELECT COUNT(*) AS IcuBeds, SUM(CASE WHEN occ.x IS NOT NULL THEN 1 ELSE 0 END) AS Occupied
    FROM dbo.BedMaster b OUTER APPLY (SELECT TOP (1) 1 AS x FROM dbo.IpdBedMovement m WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    WHERE b.BranchId = @BranchId AND b.IsActive = 1 AND b.IsICU = 1;
    -- returns to ICU within 48 h in the last 30 days (NABH)
    SELECT a.AdmissionId, a.IpNo, LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           s.StayNo, s.PrevOutAt, s.InAt, s.HoursSincePrev
    FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    CROSS APPLY dbo.fn_Ipd_IcuStays(a.AdmissionId) s
    WHERE a.BranchId = @BranchId AND a.CompanyId = @CompanyId AND a.Status <> 'CANCELLED' AND s.IsReturn48h = 1 AND s.InAt >= DATEADD(DAY, -30, @now)
      AND EXISTS (SELECT 1 FROM dbo.IpdBedMovement mv JOIN dbo.BedMaster bb ON bb.BedId = mv.BedId WHERE mv.AdmissionId = a.AdmissionId AND bb.IsICU = 1)
    ORDER BY s.InAt DESC;
END;
GO


-- ── 11. an ICU bed with an ICU tariff can be given (admission, transfer, tariff change) and shows its ICU daily rate ──
-- patches 2423 / 2431 / 2485 procedures in place (guarded: each patch is applied once; a missing piece stops the script)
CREATE OR ALTER PROCEDURE #Patch @Proc SYSNAME, @Marker NVARCHAR(200), @Old1 NVARCHAR(MAX), @New1 NVARCHAR(MAX),
    @Old2 NVARCHAR(MAX) = NULL, @New2 NVARCHAR(MAX) = NULL, @Old3 NVARCHAR(MAX) = NULL, @New3 NVARCHAR(MAX) = NULL
AS
BEGIN
    DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@Proc)), @m NVARCHAR(400);
    IF @d IS NULL BEGIN SET @m = @Proc + N' is missing.'; THROW 51460, @m, 1; END;
    IF CHARINDEX(@Marker, @d) > 0 BEGIN PRINT @Proc + N': already patched'; RETURN; END;
    IF CHARINDEX(@Old1, @d) = 0 OR (@Old2 IS NOT NULL AND CHARINDEX(@Old2, @d) = 0) OR (@Old3 IS NOT NULL AND CHARINDEX(@Old3, @d) = 0)
    BEGIN SET @m = @Proc + N': the expected code was not found - not patched.'; THROW 51461, @m, 1; END;
    SET @d = REPLACE(@d, @Old1, @New1);
    IF @Old2 IS NOT NULL SET @d = REPLACE(@d, @Old2, @New2);
    IF @Old3 IS NOT NULL SET @d = REPLACE(@d, @Old3, @New3);
    DECLARE @p INT = PATINDEX(N'%CREATE[ ' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%PROC%', @d);   -- the statement, not a word in a comment
    SET @d = STUFF(@d, @p, CHARINDEX(N'PROC', @d, @p) - @p, N'CREATE OR ALTER ');
    BEGIN TRY EXEC sp_executesql @d; END TRY BEGIN CATCH THROW; END CATCH;
    PRINT @Proc + N': patched';
END;
GO
EXEC #Patch N'dbo.usp_Api_IpdBed_Transfer', N'/* 2493 icu */',
    N'IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, @ToBedId, a.TariffCategoryId, CAST(@TransferAt AS DATE)) r WHERE a.AdmissionId = @AdmissionId)',
    N'IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, @ToBedId, a.TariffCategoryId, CAST(@TransferAt AS DATE)) r WHERE a.AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, @ToBedId, a.TariffCategoryId, CAST(@TransferAt AS DATE)) r WHERE a.AdmissionId = @AdmissionId) /* 2493 icu */';
EXEC #Patch N'dbo.usp_Api_IpdAdmission_Save', N'/* 2493 icu */',
    N'IF NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_BedRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE)))',
    N'IF NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_BedRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE)))
           AND NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_IcuDailyRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE))) /* 2493 icu */',
    N'DECLARE @need DECIMAL(18,2) = ROUND(ISNULL(@daily, 0) * @minDays, 0);',
    N'DECLARE @need DECIMAL(18,2) = ROUND(COALESCE(@daily, (SELECT DailyRate FROM dbo.fn_Ipd_IcuDailyRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE))), 0) * @minDays, 0);';
EXEC #Patch N'dbo.usp_Api_IpdAdmission_Update', N'/* 2493 icu */',
    N'IF @TariffCategoryId <> @oldTc AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r',
    N'IF @TariffCategoryId <> @oldTc AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r2
                                                         WHERE a.AdmissionId = @AdmissionId) /* 2493 icu */
           AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r';
EXEC #Patch N'dbo.usp_Api_IpdBed_ForTransfer', N'/* 2493 icu */',
    N'rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge AS DailyRate, CAST(CASE WHEN rt.BedRateId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff',
    N'COALESCE(icu.DailyRate, rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge) AS DailyRate,
           CAST(CASE WHEN rt.BedRateId IS NULL AND icu.IcuTariffId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff /* 2493 icu */',
    N'OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@tc, 0), @today) rt',
    N'OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@tc, 0), @today) rt
    OUTER APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, b.BedId, ISNULL(@tc, 0), @today) icu';
EXEC #Patch N'dbo.usp_Api_Ipd_Beds', N'/* 2493 icu */',
    N'rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge AS DailyRate, rt.GstPercentage, rt.UsedFallback,',
    N'COALESCE(icu.DailyRate, rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge + rt.IsolationCharge) AS DailyRate,
           CASE WHEN icu.IcuTariffId IS NOT NULL THEN CAST(0 AS DECIMAL(5,2)) ELSE rt.GstPercentage END AS GstPercentage, COALESCE(icu.UsedFallback, rt.UsedFallback) AS UsedFallback, /* 2493 icu */',
    N'CAST(CASE WHEN rt.BedRateId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff,',
    N'CAST(CASE WHEN rt.BedRateId IS NULL AND icu.IcuTariffId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff,',
    N'OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@TariffCategoryId, 0), @today) rt',
    N'OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@TariffCategoryId, 0), @today) rt
    OUTER APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, b.BedId, ISNULL(@TariffCategoryId, 0), @today) icu';
GO
DROP PROCEDURE IF EXISTS #Patch;
GO

PRINT '2493 IPD ICU - done.';
GO
