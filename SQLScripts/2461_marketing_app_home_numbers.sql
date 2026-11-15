-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2461  Marketing Executive App: plain monthly numbers on the home screen, and referral bills counted from the right column.
--   * usp_Mkt_Summary adds VisitsThisMonth, VerifiedThisMonth, DoctorsReferringThisMonth (promoted doctors with a LAB bill
--     this month) and WaitingApproval (doctors moved to Trial that the office has not switched on yet). The app shows these
--     instead of the weighted forecast (ForecastDoctors / ForecastReferrals stay in the answer for older apps).
--   * Fix (from 2446): a Doctor Master doctor on a LAB bill is LabOrder.RefDoctorId (FK to DoctorMaster); ReferralDoctorId
--     is the Referral Doctor Master. usp_Mkt_Summary (ReferralsThisMonth) and usp_Mkt_Lead_Get (ReferralCount ...) used
--     ReferralDoctorId, so a promoted doctor's bills were never counted. Cancelled bills (IsActive = 0) do not count.
--   Needs 2446 and 2459. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
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
    SELECT ISNULL(SUM(CASE WHEN Stage = 'PROSPECT' THEN 1 ELSE 0 END), 0) AS Prospect,
           ISNULL(SUM(CASE WHEN Stage = 'CONTACTED' THEN 1 ELSE 0 END), 0) AS Contacted,
           ISNULL(SUM(CASE WHEN Stage = 'ENGAGED' THEN 1 ELSE 0 END), 0) AS Engaged,
           ISNULL(SUM(CASE WHEN Stage = 'TRIAL' THEN 1 ELSE 0 END), 0) AS Trial,
           ISNULL(SUM(CASE WHEN Stage = 'ACTIVE' THEN 1 ELSE 0 END), 0) AS Active,
           ISNULL(SUM(CASE WHEN Stage = 'LOST' THEN 1 ELSE 0 END), 0) AS Lost,
           ISNULL(SUM(CASE WHEN NextFollowUpDate = @Today AND Stage NOT IN ('ACTIVE', 'LOST') THEN 1 ELSE 0 END), 0) AS FollowUpsToday,
           ISNULL(SUM(CASE WHEN NextFollowUpDate < @Today AND Stage NOT IN ('ACTIVE', 'LOST') THEN 1 ELSE 0 END), 0) AS FollowUpsOverdue,
           CAST(ROUND(ISNULL(SUM(CASE WHEN Stage NOT IN ('ACTIVE', 'LOST') THEN Weight ELSE 0 END), 0), 1) AS DECIMAL(10, 1)) AS ForecastDoctors,
           CAST(ROUND(ISNULL(SUM(ExpectedMonthlyReferrals * Weight), 0), 0) AS INT) AS ForecastReferrals,
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @Today) AS VisitsToday,
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @Today
               AND v.VisitStatus = 'VERIFIED') AS VerifiedToday,
           (SELECT COUNT(*) FROM dbo.ForecastDoctor f WHERE f.ExecutiveId = @Exec AND f.BranchId = @BranchId AND f.IsActive = 1
               AND f.CreatedDate >= @MonthStart) AS LeadsThisMonth,
           -- 2461: RefDoctorId (Doctor Master), not ReferralDoctorId; cancelled bills do not count
           (SELECT COUNT(*) FROM dbo.LabOrder o
              JOIN dbo.ForecastDoctor f ON f.DoctorId = o.RefDoctorId AND f.ExecutiveId = @Exec AND f.IsActive = 1
             WHERE o.BranchId = @BranchId AND o.OrderDate >= @MonthStart AND o.IsActive = 1) AS ReferralsThisMonth,
           -- 2461: plain numbers for the home screen
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @MonthStart) AS VisitsThisMonth,
           (SELECT COUNT(*) FROM dbo.ForecastDoctorVisit v WHERE v.UserId = @UserId AND v.BranchId = @BranchId AND v.VisitDate >= @MonthStart
               AND v.VisitStatus = 'VERIFIED') AS VerifiedThisMonth,
           (SELECT COUNT(DISTINCT f.DoctorId) FROM dbo.LabOrder o
              JOIN dbo.ForecastDoctor f ON f.DoctorId = o.RefDoctorId AND f.ExecutiveId = @Exec AND f.IsActive = 1
             WHERE o.BranchId = @BranchId AND o.OrderDate >= @MonthStart AND o.IsActive = 1) AS DoctorsReferringThisMonth,
           (SELECT COUNT(*) FROM dbo.ForecastDoctor f JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
             WHERE f.ExecutiveId = @Exec AND f.BranchId = @BranchId AND f.IsActive = 1 AND f.Stage = 'TRIAL' AND ISNULL(d.IsActive, 0) = 0) AS WaitingApproval
      FROM l;
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
      -- 2461: a Doctor Master doctor on a LAB bill is LabOrder.RefDoctorId (ReferralDoctorId is Referral Doctor Master); cancelled bills do not count
      OUTER APPLY (SELECT COUNT(*) AS ReferralCount,
                          SUM(CASE WHEN o.OrderDate >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END) AS Referrals30Days,
                          MAX(o.OrderDate) AS LastReferralDate
                     FROM dbo.LabOrder o WHERE l.DoctorId IS NOT NULL AND o.RefDoctorId = l.DoctorId AND o.IsActive = 1) r
     WHERE l.ForecastDoctorId = @ForecastDoctorId;

    SELECT VisitId, VisitDate, VisitStatus, DistanceM, Outcome, Notes, NextFollowUpDate, FlagReason
      FROM dbo.ForecastDoctorVisit WHERE ForecastDoctorId = @ForecastDoctorId ORDER BY VisitDate DESC;

    SELECT g.FromStage, g.ToStage, g.Reason, g.ChangedDate, ISNULL(NULLIF(u.FullName, N''), u.Username) AS ChangedByName
      FROM dbo.ForecastDoctorStageLog g LEFT JOIN dbo.Users u ON u.Id = g.ChangedBy
     WHERE g.ForecastDoctorId = @ForecastDoctorId ORDER BY g.ChangedDate DESC, g.LogId DESC;
END
GO
PRINT 'Script 2461 applied: plain monthly numbers for the app home screen; referral bills counted from LabOrder.RefDoctorId.';
GO
