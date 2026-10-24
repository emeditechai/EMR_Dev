-- ============================================================================================================
-- Migration: 2321_ask_ai_data_answers_and_daily_learning.sql
-- Ask AI (Help Assistant) - answers from live data and learning from daily use. Needs 2300 / 2301.
--
-- 1. Data answers: a fixed set of READ-ONLY questions, each a procedure below, always limited to one branch (@BranchId;
--    NULL only for a Super Admin signed in without a branch) and the company. EMR.Web decides which of them the user
--    may get (the same page permissions as the screens: LAB bills, OPD bills, samples / reports, patients). No free SQL.
--      usp_HelpData_BillLookup     a bill by its number (LAB or OPD): patient, amounts, payment, samples, reports
--      usp_HelpData_TokenLookup    a token (latest first)
--      usp_HelpData_PatientLookup  a patient by phone, Patient ID or name: last visit, bills, outstanding due
--      usp_HelpData_Summary        bills / net / paid / due / cancelled of a period, LAB and OPD
--      usp_HelpData_Dues           bills with a balance due in a period (top 10 + totals)
--      usp_HelpData_LabWork        samples pending / collected, reports pending approval / approved in a period
-- 2. Daily learning: every signal (Yes / No / opened answer) is kept with its user (HelpSignalLog). Each night
--    usp_Help_Learn_Nightly promotes an answer to "AUTO" (used as a confirmed answer) when at least 2 different users
--    chose it for the same question and few rejected it; it is demoted again when that stops being true. Admin
--    teaching still wins and anything learned can be forgotten in Help Insights.
--    usp_Help_Gaps lists questions asked often but answered weakly, for an administrator to teach.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── learning ────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID(N'dbo.HelpSignalLog', N'U') IS NULL
CREATE TABLE dbo.HelpSignalLog
(
    SignalId     BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_HelpSignalLog PRIMARY KEY,
    CompanyId    INT            NOT NULL,
    QuestionKey  NVARCHAR(400)  NOT NULL,
    TargetCode   VARCHAR(120)   NOT NULL,
    Signal       VARCHAR(10)    NOT NULL,        -- UP / DOWN / CLICK
    UserId       INT            NULL,
    CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_HelpSignalLog_Created DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HelpSignalLog_Company_Date' AND object_id = OBJECT_ID(N'dbo.HelpSignalLog'))
    CREATE INDEX IX_HelpSignalLog_Company_Date ON dbo.HelpSignalLog (CompanyId, CreatedDate) INCLUDE (QuestionKey, TargetCode, Signal, UserId);
GO
IF COL_LENGTH('dbo.HelpLearned', 'DistinctUsers') IS NULL
    ALTER TABLE dbo.HelpLearned ADD DistinctUsers INT NOT NULL CONSTRAINT DF_HelpLearned_DistinctUsers DEFAULT (0);
GO

IF OBJECT_ID(N'dbo.HelpLearningRun', N'U') IS NULL
CREATE TABLE dbo.HelpLearningRun
(
    RunId        INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_HelpLearningRun PRIMARY KEY,
    RunDate      DATETIME       NOT NULL CONSTRAINT DF_HelpLearningRun_Date DEFAULT (GETDATE()),
    Promoted     INT            NOT NULL,
    Demoted      INT            NOT NULL,
    Signals      INT            NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Help_Signal_Log
    @CompanyId INT, @QuestionKey NVARCHAR(400), @TargetCode VARCHAR(120), @Signal VARCHAR(10), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@QuestionKey), N'') IS NULL OR NULLIF(@TargetCode, '') IS NULL OR @Signal NOT IN ('UP', 'DOWN', 'CLICK') RETURN;
    INSERT dbo.HelpSignalLog (CompanyId, QuestionKey, TargetCode, Signal, UserId)
    VALUES (@CompanyId, LEFT(@QuestionKey, 400), @TargetCode, @Signal, @UserId);
END
GO

-- The nightly learning pass (EMR.Api runs it once a day; safe to run any time).
CREATE OR ALTER PROCEDURE dbo.usp_Help_Learn_Nightly
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = DATEADD(DAY, -90, GETDATE());

    SELECT CompanyId, QuestionKey, TargetCode,
           COUNT(DISTINCT CASE WHEN Signal IN ('UP', 'CLICK') THEN ISNULL(UserId, -1) END) AS PosUsers,
           COUNT(DISTINCT CASE WHEN Signal = 'DOWN' THEN ISNULL(UserId, -1) END) AS NegUsers
    INTO #s
    FROM dbo.HelpSignalLog
    WHERE CreatedDate >= @from
    GROUP BY CompanyId, QuestionKey, TargetCode;

    UPDATE l SET DistinctUsers = s.PosUsers
    FROM dbo.HelpLearned l
    INNER JOIN #s s ON s.CompanyId = l.CompanyId AND s.QuestionKey = l.QuestionKey AND s.TargetCode = l.TargetCode
    WHERE l.DistinctUsers <> s.PosUsers;

    -- promote: chosen by 2+ different users, rejected by fewer than half as many
    UPDATE l SET Source = 'AUTO', ModifiedDate = GETDATE()
    FROM dbo.HelpLearned l
    INNER JOIN #s s ON s.CompanyId = l.CompanyId AND s.QuestionKey = l.QuestionKey AND s.TargetCode = l.TargetCode
    WHERE l.Source = 'USER' AND l.IsActive = 1 AND s.PosUsers >= 2 AND s.NegUsers * 2 < s.PosUsers;
    DECLARE @promoted INT = @@ROWCOUNT;

    -- demote: no longer supported
    UPDATE l SET Source = 'USER', ModifiedDate = GETDATE()
    FROM dbo.HelpLearned l
    LEFT JOIN #s s ON s.CompanyId = l.CompanyId AND s.QuestionKey = l.QuestionKey AND s.TargetCode = l.TargetCode
    WHERE l.Source = 'AUTO' AND (s.QuestionKey IS NULL OR s.PosUsers < 2 OR s.NegUsers * 2 >= s.PosUsers);
    DECLARE @demoted INT = @@ROWCOUNT;

    INSERT dbo.HelpLearningRun (Promoted, Demoted, Signals)
    SELECT @promoted, @demoted, (SELECT COUNT(*) FROM dbo.HelpSignalLog WHERE CreatedDate >= DATEADD(DAY, -1, GETDATE()));

    SELECT @promoted AS Promoted, @demoted AS Demoted;
    DROP TABLE #s;
END
GO

-- Help Insights: questions of the last 14 days that found no answer or a weak one, most asked first.
CREATE OR ALTER PROCEDURE dbo.usp_Help_Gaps @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 30
           MAX(Question) AS Question,
           COUNT(*) AS Asked,
           COUNT(DISTINCT UserId) AS Users,
           SUM(CASE WHEN Found = 0 THEN 1 ELSE 0 END) AS NotFound,
           CAST(AVG(ISNULL(Confidence, 0)) AS DECIMAL(4, 2)) AS AvgConfidence,
           MAX(CreatedDate) AS LastAsked
    FROM dbo.HelpAskLog
    WHERE CompanyId = @CompanyId AND CreatedDate >= DATEADD(DAY, -14, GETDATE())
      AND ISNULL(AnswerCode, '') NOT LIKE 'DATA:%'
      AND (Found = 0 OR ISNULL(Confidence, 0) < 0.35)
    GROUP BY LOWER(LTRIM(RTRIM(Question)))
    ORDER BY COUNT(*) DESC, MAX(CreatedDate) DESC;

    SELECT TOP 1 RunDate, Promoted, Demoted, Signals FROM dbo.HelpLearningRun ORDER BY RunId DESC;
END
GO

-- ── data answers (read only) ────────────────────────────────────────────────────────────────────────────────
-- the bills of one branch / company, LAB and OPD, with their payment
CREATE OR ALTER FUNCTION dbo.ufn_HelpData_Bills (@CompanyId INT, @BranchId INT)
RETURNS TABLE
AS
RETURN
    SELECT 'LAB' AS Module, lo.LabOrderId AS RefId, lo.BillNo, lo.TokenNo, ISNULL(lo.BookingDate, lo.OrderDate) AS BillDate,
           lo.PatientId, lo.BranchId, CAST(lo.IsActive AS BIT) AS IsActive, ISNULL(lo.IsB2B, 0) AS IsB2B,
           ISNULL(ph.NetAmount, lo.TotalAmount) AS NetAmount, ISNULL(ph.TotalPaid, 0) AS Paid,
           ISNULL(ph.BalanceDue, 0) AS Due, ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus
    FROM dbo.LabOrder lo
    INNER JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
    OUTER APPLY (SELECT TOP 1 * FROM dbo.PaymentHeader p WHERE p.ModuleCode = 'LAB' AND p.ModuleRefId = lo.LabOrderId ORDER BY p.IsActive DESC, p.PaymentHeaderId DESC) ph
    WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR lo.BranchId = @BranchId)
    UNION ALL
    SELECT 'OPD', o.OPDServiceId, o.OPDBillNo, o.TokenNo, o.VisitDate,
           o.PatientId, o.BranchId, CAST(o.IsActive AS BIT), 0,
           ISNULL(ph.NetAmount, o.TotalAmount), ISNULL(ph.TotalPaid, 0), ISNULL(ph.BalanceDue, 0), ISNULL(ph.PaymentStatus, 'U')
    FROM dbo.PatientOPDService o
    INNER JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
    OUTER APPLY (SELECT TOP 1 * FROM dbo.PaymentHeader p WHERE p.ModuleCode = 'OPD' AND p.OPDServiceId = o.OPDServiceId ORDER BY p.IsActive DESC, p.PaymentHeaderId DESC) ph
    WHERE b.CompanyId = @CompanyId AND (@BranchId IS NULL OR o.BranchId = @BranchId) AND o.OPDBillNo IS NOT NULL;
GO

CREATE OR ALTER FUNCTION dbo.ufn_HelpData_PatientName (@PatientId INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    RETURN (SELECT LTRIM(RTRIM(CONCAT(NULLIF(Salutation, N'') + N' ', FirstName, N' ', NULLIF(MiddleName, N'') + N' ', LastName)))
            FROM dbo.PatientMaster WHERE PatientId = @PatientId);
END
GO

-- a bill by its number. @Text may omit the prefix ("HO2627000295") or carry spaces; exact match first.
CREATE OR ALTER PROCEDURE dbo.usp_HelpData_BillLookup
    @CompanyId INT, @BranchId INT = NULL, @Text NVARCHAR(60), @Modules VARCHAR(20) = 'LAB,OPD'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t NVARCHAR(60) = UPPER(REPLACE(LTRIM(RTRIM(@Text)), N' ', N''));
    IF LEN(@t) < 5 RETURN;

    SELECT TOP 5 b.Module, b.RefId, b.BillNo, b.TokenNo, b.BillDate, b.IsActive, b.IsB2B, b.NetAmount, b.Paid, b.Due, b.PaymentStatus,
           pm.PatientCode, dbo.ufn_HelpData_PatientName(b.PatientId) AS PatientName, pm.PhoneNumber, pm.Gender,
           CASE WHEN pm.DateOfBirth IS NULL THEN NULL ELSE DATEDIFF(YEAR, pm.DateOfBirth, GETDATE()) END AS AgeYears,
           br.BranchName,
           (SELECT COUNT(*) FROM dbo.SampleCollection s WHERE b.Module = 'LAB' AND s.Laborderid = b.RefId AND ISNULL(s.Iscancelled, 0) = 0 AND s.Is_Active = 1) AS Samples,
           (SELECT COUNT(*) FROM dbo.SampleCollection s WHERE b.Module = 'LAB' AND s.Laborderid = b.RefId AND ISNULL(s.Iscancelled, 0) = 0 AND s.Is_Active = 1 AND s.CollectionstatusID = 2) AS SamplesCollected,
           (SELECT COUNT(DISTINCT e.InvestigationID) FROM dbo.labentrydetails e WHERE b.Module = 'LAB' AND e.LabOrderId = b.RefId AND e.IsActive = 1 AND e.ReportStatusId = 5) AS ReportsApproved,
           (SELECT COUNT(*) FROM dbo.LabOrderItem i WHERE b.Module = 'LAB' AND i.LabOrderId = b.RefId AND i.IsActive = 1) AS Tests,
           -- which reporting screen the bill's tests belong to (Image / Template = Microbiology / the rest = Lab Report Entry)
           (SELECT COUNT(*) FROM dbo.LabOrderItem i INNER JOIN dbo.LabInvestigationMaster im ON im.Test_ID = i.InvestigationId
             WHERE b.Module = 'LAB' AND i.LabOrderId = b.RefId AND i.IsActive = 1 AND im.Reporting_Type = 'Image') AS ImageTests,
           (SELECT COUNT(*) FROM dbo.LabOrderItem i INNER JOIN dbo.LabInvestigationMaster im ON im.Test_ID = i.InvestigationId
             WHERE b.Module = 'LAB' AND i.LabOrderId = b.RefId AND i.IsActive = 1 AND im.Reporting_Type IN ('Template', 'Culture')) AS MicroTests,
           (SELECT STRING_AGG(CAST(x.Test_Name AS NVARCHAR(MAX)), N', ') FROM (
                SELECT TOP 6 im.Test_Name FROM dbo.LabOrderItem i
                INNER JOIN dbo.LabInvestigationMaster im ON im.Test_ID = i.InvestigationId
                WHERE b.Module = 'LAB' AND i.LabOrderId = b.RefId AND i.IsActive = 1) x) AS TestNames
    FROM dbo.ufn_HelpData_Bills(@CompanyId, @BranchId) b
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = b.PatientId
    LEFT JOIN dbo.Branchmaster br ON br.BranchID = b.BranchId
    WHERE CHARINDEX(b.Module, @Modules) > 0
      AND (REPLACE(UPPER(b.BillNo), N' ', N'') = @t
           OR REPLACE(UPPER(b.BillNo), N' ', N'') LIKE N'%/' + @t
           OR (LEN(@t) >= 8 AND REPLACE(UPPER(b.BillNo), N' ', N'') LIKE N'%' + @t))
    ORDER BY CASE WHEN REPLACE(UPPER(b.BillNo), N' ', N'') = @t THEN 0 ELSE 1 END, b.BillDate DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_TokenLookup
    @CompanyId INT, @BranchId INT = NULL, @Text NVARCHAR(40), @From DATE = NULL, @To DATE = NULL, @Modules VARCHAR(20) = 'LAB,OPD'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t NVARCHAR(40) = UPPER(REPLACE(LTRIM(RTRIM(@Text)), N' ', N''));
    SELECT TOP 5 b.Module, b.RefId, b.BillNo, b.TokenNo, b.BillDate, b.IsActive, b.NetAmount, b.Paid, b.Due, b.PaymentStatus,
           pm.PatientCode, dbo.ufn_HelpData_PatientName(b.PatientId) AS PatientName, pm.PhoneNumber
    FROM dbo.ufn_HelpData_Bills(@CompanyId, @BranchId) b
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = b.PatientId
    WHERE CHARINDEX(b.Module, @Modules) > 0 AND UPPER(b.TokenNo) = @t
      AND (@From IS NULL OR CAST(b.BillDate AS DATE) BETWEEN @From AND ISNULL(@To, @From))
    ORDER BY b.BillDate DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_PatientLookup
    @CompanyId INT, @BranchId INT = NULL, @Text NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t NVARCHAR(100) = LTRIM(RTRIM(@Text));
    IF LEN(@t) < 3 RETURN;
    DECLARE @digits NVARCHAR(100) = REPLACE(REPLACE(@t, N' ', N''), N'-', N'');

    SELECT TOP 5 pm.PatientId, pm.PatientCode, dbo.ufn_HelpData_PatientName(pm.PatientId) AS PatientName, pm.PhoneNumber, pm.Gender,
           CASE WHEN pm.DateOfBirth IS NULL THEN NULL ELSE DATEDIFF(YEAR, pm.DateOfBirth, GETDATE()) END AS AgeYears,
           x.Bills, x.LastVisit, x.Due
    FROM dbo.PatientMaster pm
    INNER JOIN dbo.Branchmaster br ON br.BranchID = pm.BranchId AND br.CompanyId = @CompanyId
    OUTER APPLY (SELECT COUNT(*) AS Bills, MAX(b.BillDate) AS LastVisit, SUM(CASE WHEN b.IsActive = 1 THEN b.Due ELSE 0 END) AS Due
                 FROM dbo.ufn_HelpData_Bills(@CompanyId, @BranchId) b WHERE b.PatientId = pm.PatientId) x
    WHERE pm.IsActive = 1
      AND (@BranchId IS NULL OR pm.BranchId = @BranchId OR x.Bills > 0)
      AND (pm.PhoneNumber = @digits OR pm.SecondaryPhoneNumber = @digits OR pm.PatientCode = @t
           OR (LEN(@t) >= 3 AND @digits NOT LIKE N'%[0-9]%' AND CONCAT(pm.FirstName, N' ', pm.LastName) LIKE N'%' + @t + N'%'))
    ORDER BY CASE WHEN pm.PatientCode = @t OR pm.PhoneNumber = @digits THEN 0 ELSE 1 END, x.LastVisit DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Summary
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Modules VARCHAR(20) = 'LAB,OPD'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Module,
           SUM(CASE WHEN b.IsActive = 1 THEN 1 ELSE 0 END) AS Bills,
           SUM(CASE WHEN b.IsActive = 0 THEN 1 ELSE 0 END) AS Cancelled,
           ISNULL(SUM(CASE WHEN b.IsActive = 1 THEN b.NetAmount END), 0) AS NetAmount,
           ISNULL(SUM(CASE WHEN b.IsActive = 1 THEN b.Paid END), 0) AS Paid,
           ISNULL(SUM(CASE WHEN b.IsActive = 1 THEN b.Due END), 0) AS Due,
           SUM(CASE WHEN b.IsActive = 1 AND b.Due > 0 THEN 1 ELSE 0 END) AS DueBills,
           COUNT(DISTINCT CASE WHEN b.IsActive = 1 THEN b.PatientId END) AS Patients
    FROM dbo.ufn_HelpData_Bills(@CompanyId, @BranchId) b
    WHERE CHARINDEX(b.Module, @Modules) > 0 AND CAST(b.BillDate AS DATE) BETWEEN @From AND @To
    GROUP BY b.Module
    ORDER BY b.Module;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Dues
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Modules VARCHAR(20) = 'LAB,OPD'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Module, b.RefId, b.BillNo, b.BillDate, b.NetAmount, b.Paid, b.Due, pm.PatientCode,
           dbo.ufn_HelpData_PatientName(b.PatientId) AS PatientName, pm.PhoneNumber
    INTO #d
    FROM dbo.ufn_HelpData_Bills(@CompanyId, @BranchId) b
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = b.PatientId
    WHERE CHARINDEX(b.Module, @Modules) > 0 AND b.IsActive = 1 AND b.Due > 0 AND b.IsB2B = 0
      AND CAST(b.BillDate AS DATE) BETWEEN @From AND @To;

    SELECT COUNT(*) AS Bills, ISNULL(SUM(Due), 0) AS Due FROM #d;
    SELECT TOP 10 * FROM #d ORDER BY Due DESC, BillDate DESC;
    DROP TABLE #d;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_LabWork
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.samplecollectionID, s.Laborderid, s.InvestigationID, s.CollectionstatusID, s.Orderdate,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.SamplecollectionID = s.samplecollectionID AND e.IsActive = 1 AND e.ReportStatusId = 5) THEN 1 ELSE 0 END AS Approved,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.SamplecollectionID = s.samplecollectionID AND e.IsActive = 1 AND e.ReportStatusId IN (2, 3)) THEN 1 ELSE 0 END AS Entered
    INTO #s
    FROM dbo.SampleCollection s
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = s.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.Branchmaster br ON br.BranchID = lo.BranchId AND br.CompanyId = @CompanyId
    WHERE (@BranchId IS NULL OR lo.BranchId = @BranchId) AND s.Is_Active = 1 AND ISNULL(s.Iscancelled, 0) = 0
      AND CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE) BETWEEN @From AND @To;

    SELECT COUNT(*) AS Tests,
           SUM(CASE WHEN CollectionstatusID IN (1, 3) OR CollectionstatusID IS NULL THEN 1 ELSE 0 END) AS SamplesPending,
           SUM(CASE WHEN CollectionstatusID = 2 THEN 1 ELSE 0 END) AS SamplesCollected,
           SUM(CASE WHEN CollectionstatusID = 4 THEN 1 ELSE 0 END) AS SamplesRejected,
           SUM(CASE WHEN CollectionstatusID = 2 AND Approved = 0 AND Entered = 0 THEN 1 ELSE 0 END) AS AwaitingResult,
           SUM(CASE WHEN Approved = 0 AND Entered = 1 THEN 1 ELSE 0 END) AS AwaitingApproval,
           SUM(Approved) AS ReportsApproved
    FROM #s;
    DROP TABLE #s;
END
GO

-- ── EMR.Api api/help/learning/gaps: under the Help Center page, like the other learning endpoints (2301) ──
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.HELP';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET', @Controller = N'HelpLearning', @Action = N'Gaps', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2321 applied: Ask AI data answers + daily learning.';
GO
