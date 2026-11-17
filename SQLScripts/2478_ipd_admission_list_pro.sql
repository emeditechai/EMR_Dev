-- ============================================================================================================
-- Migration: 2478_ipd_admission_list_pro.sql   (application database)
-- IPD > Admission List, enhanced (replaces usp_Api_IpdAdmission_List of 2423 - the old parameters keep working):
--   new filters  @ConsultantId, @DepartmentId, @Flag (ICU | MLC | LOW_DEPOSIT | DUE | DISCHARGE_DUE | PACKAGE | INDENT)
--   sorting      @Sort ADMITTED_DESC (default) | ADMITTED_ASC | BALANCE_DESC | BILL_DESC | DAYS_DESC | NAME | BED | IPNO
--   new columns  department, ICU, MLC, package, expected discharge, deposit alert (as the Due List: cash payer, bill above
--                the advance or above IPD deposit alert % of it), advance cover %, open medicine indents
--   set 3        summary tiles of the branch (in hospital, admitted / discharged today, discharge advised, ICU, MLC,
--                deposit alerts, total due, discharge due today / overdue)
--   set 4 / 5    filter lookups: wards, consultants of the branch's admissions; set 6 departments
-- Money (bill so far, advance) is worked out only for the page shown, unless the sort / filter needs it for every row.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_List
    @CompanyId INT, @BranchId INT, @Status VARCHAR(20) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @Search NVARCHAR(100) = NULL,
    @WardId INT = NULL, @PayerType VARCHAR(12) = NULL, @Page INT = 1, @PageSize INT = 25,
    @ConsultantId INT = NULL, @DepartmentId INT = NULL, @Flag VARCHAR(20) = NULL, @Sort VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Page = CASE WHEN @Page < 1 THEN 1 ELSE @Page END;
    SET @PageSize = CASE WHEN @PageSize < 1 THEN 25 WHEN @PageSize > 2000 THEN 2000 ELSE @PageSize END;
    SET @Status = NULLIF(UPPER(@Status), ''); SET @PayerType = NULLIF(UPPER(@PayerType), '');
    SET @Flag = NULLIF(UPPER(@Flag), ''); SET @Sort = ISNULL(NULLIF(UPPER(@Sort), ''), 'ADMITTED_DESC');
    SET @ConsultantId = NULLIF(@ConsultantId, 0); SET @DepartmentId = NULLIF(@DepartmentId, 0); SET @WardId = NULLIF(@WardId, 0);
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @now DATETIME = GETDATE(), @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @pct DECIMAL(9,2) = ISNULL((SELECT TOP 1 IpdDepositAlertPercent FROM dbo.HospitalSettings WHERE BranchID = @BranchId ORDER BY IsActive DESC), 80);
    DECLARE @hasIndent BIT = CASE WHEN OBJECT_ID('dbo.IpdPhIndent', 'U') IS NOT NULL THEN 1 ELSE 0 END;

    CREATE TABLE #x (AdmissionId INT PRIMARY KEY, IpNo NVARCHAR(40), Status VARCHAR(20), IsOpen BIT, AdmissionAt DATETIME, AdmissionType VARCHAR(20), PayerType VARCHAR(12),
                     DischargeAt DATETIME, ExpectedDischargeAt DATETIME, PatientId INT, PatientCode NVARCHAR(50), PatientName NVARCHAR(300), Gender NVARCHAR(20), PhoneNumber NVARCHAR(30),
                     AgeText NVARCHAR(30), BedNumber NVARCHAR(50), WardName NVARCHAR(150), IsIcu BIT, ConsultantDoctorId INT, ConsultantDoctorName NVARCHAR(200),
                     DepartmentName NVARCHAR(150), TariffCategoryName NVARCHAR(150), PackageName NVARCHAR(250), IsMlc BIT, DayCount INT,
                     BillNow DECIMAL(18,2) NULL, NetAdvance DECIMAL(18,2) NULL, OpenIndents INT NULL);
    INSERT #x
    SELECT a.AdmissionId, a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.AdmissionType, a.PayerType, a.DischargeAt, a.ExpectedDischargeAt, p.PatientId, p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))), p.Gender, p.PhoneNumber,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)), b.BedNumber, w.WardName, CAST(ISNULL(b.IsICU, 0) AS BIT),
           a.ConsultantDoctorId, d.FullName, dep.DeptName, tc.Name, pk.Package_Name, CAST(ISNULL(a.IsMlc, 0) AS BIT),
           DATEDIFF(DAY, a.AdmissionAt, ISNULL(a.DischargeAt, @now)) + 1, NULL, NULL, NULL
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = a.TariffCategoryId
    LEFT JOIN dbo.HospitalPackageMaster pk ON pk.HospitalPackage_ID = a.PackageId
    WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId
      AND (@Status IS NULL OR (@Status = 'OPEN' AND a.IsOpen = 1) OR a.Status = @Status)
      AND (@FromDate IS NULL OR a.AdmissionAt >= @FromDate) AND (@ToDate IS NULL OR a.AdmissionAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
      AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
      AND (@ConsultantId IS NULL OR a.ConsultantDoctorId = @ConsultantId) AND (@DepartmentId IS NULL OR a.DepartmentId = @DepartmentId)
      AND (@Flag IS NULL OR @Flag IN ('LOW_DEPOSIT', 'DUE', 'INDENT')
           OR (@Flag = 'ICU' AND ISNULL(b.IsICU, 0) = 1) OR (@Flag = 'MLC' AND ISNULL(a.IsMlc, 0) = 1) OR (@Flag = 'PACKAGE' AND a.PackageId IS NOT NULL)
           OR (@Flag = 'DISCHARGE_DUE' AND a.IsOpen = 1 AND a.ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME))))
      AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like OR w.WardName LIKE @like
           OR d.FullName LIKE @like OR CONCAT(p.FirstName, ' ', p.MiddleName, ' ', p.LastName) LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like);

    -- money for every row only when the sort / filter needs it (a branch's in-hospital list is small)
    DECLARE @allMoney BIT = CASE WHEN @Sort IN ('BALANCE_DESC', 'BILL_DESC') OR @Flag IN ('LOW_DEPOSIT', 'DUE') THEN 1 ELSE 0 END;
    IF @allMoney = 1
        UPDATE x SET BillNow = CASE WHEN x.Status = 'CANCELLED' THEN 0 ELSE lt.Net END, NetAdvance = mo.NetAdvance
        FROM #x x OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(x.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(x.AdmissionId) mo;
    IF @Flag = 'DUE' DELETE #x WHERE NOT (IsOpen = 1 AND ISNULL(BillNow, 0) - ISNULL(NetAdvance, 0) > 0);
    IF @Flag = 'LOW_DEPOSIT' DELETE #x WHERE NOT (IsOpen = 1 AND PayerType = 'CASH' AND (BillNow > NetAdvance OR (NetAdvance > 0 AND BillNow >= NetAdvance * @pct / 100.0)));
    IF @Flag = 'INDENT' AND @hasIndent = 1
        EXEC (N'DELETE x FROM #x x WHERE NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndent i WHERE i.AdmissionId = x.AdmissionId AND i.Status IN (''PENDING'', ''PARTIAL''))');

    DECLARE @total INT = (SELECT COUNT(*) FROM #x);
    CREATE TABLE #pg (AdmissionId INT PRIMARY KEY, RowNo INT);
    INSERT #pg (AdmissionId, RowNo)
    SELECT AdmissionId, rn FROM (
        SELECT AdmissionId, ROW_NUMBER() OVER (ORDER BY
            CASE WHEN @Sort = 'BALANCE_DESC' THEN ISNULL(BillNow, 0) - ISNULL(NetAdvance, 0) END DESC,
            CASE WHEN @Sort = 'BILL_DESC' THEN BillNow END DESC,
            CASE WHEN @Sort = 'DAYS_DESC' THEN DayCount END DESC,
            CASE WHEN @Sort = 'NAME' THEN PatientName END ASC,
            CASE WHEN @Sort = 'BED' THEN ISNULL(WardName, N'~') END ASC, CASE WHEN @Sort = 'BED' THEN BedNumber END ASC,
            CASE WHEN @Sort = 'IPNO' THEN IpNo END DESC,
            CASE WHEN @Sort = 'ADMITTED_ASC' THEN AdmissionAt END ASC,
            AdmissionAt DESC, AdmissionId DESC) AS rn
        FROM #x) s
    WHERE rn > (@Page - 1) * @PageSize AND rn <= @Page * @PageSize;

    IF @allMoney = 0
        UPDATE x SET BillNow = CASE WHEN x.Status = 'CANCELLED' THEN NULL ELSE lt.Net END, NetAdvance = mo.NetAdvance
        FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId
        OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(x.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(x.AdmissionId) mo;
    IF @hasIndent = 1
        EXEC (N'UPDATE x SET OpenIndents = (SELECT COUNT(*) FROM dbo.IpdPhIndent i WHERE i.AdmissionId = x.AdmissionId AND i.Status IN (''PENDING'', ''PARTIAL''))
                FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId');

    SELECT x.AdmissionId, x.IpNo, x.Status, x.IsOpen, x.AdmissionAt, x.AdmissionType, x.PayerType, x.DischargeAt, x.ExpectedDischargeAt, x.PatientId, x.PatientCode,
           x.PatientName, x.Gender, x.PhoneNumber, x.AgeText, x.BedNumber, x.WardName, x.IsIcu, x.ConsultantDoctorId, x.ConsultantDoctorName, x.DepartmentName,
           x.TariffCategoryName, x.PackageName, x.IsMlc, x.DayCount, x.BillNow, x.NetAdvance,
           CAST(CASE WHEN x.Status = 'CANCELLED' THEN NULL ELSE ISNULL(x.BillNow, 0) - ISNULL(x.NetAdvance, 0) END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN ISNULL(x.BillNow, 0) > 0 THEN ROUND(ISNULL(x.NetAdvance, 0) * 100.0 / x.BillNow, 0) END AS INT) AS AdvanceCoverPct,
           CAST(CASE WHEN x.IsOpen = 1 AND x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           CAST(CASE WHEN x.IsOpen = 1 AND x.ExpectedDischargeAt < CAST(@today AS DATETIME) THEN 1 ELSE 0 END AS BIT) AS DischargeOverdue,
           CAST(CASE WHEN x.IsOpen = 1 AND x.ExpectedDischargeAt >= CAST(@today AS DATETIME) AND x.ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME)) THEN 1 ELSE 0 END AS BIT) AS DischargeToday,
           CAST(CASE WHEN CAST(x.AdmissionAt AS DATE) = @today THEN 1 ELSE 0 END AS BIT) AS AdmittedToday,
           ISNULL(x.OpenIndents, 0) AS OpenIndents
    FROM #x x JOIN #pg g ON g.AdmissionId = x.AdmissionId
    ORDER BY g.RowNo;

    SELECT @total AS Total;

    -- summary tiles (whole branch, not the filter)
    ;WITH o AS (SELECT a.AdmissionId, a.PayerType, a.Status, a.IsMlc, a.ExpectedDischargeAt, ISNULL(b.IsICU, 0) AS IsIcu, a.AdmissionAt
                FROM dbo.IpdAdmission a LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
                WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1),
          m AS (SELECT o.*, lt.Net AS BillNow, mo.NetAdvance FROM o OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(o.AdmissionId, @now)) lt CROSS APPLY dbo.fn_Ipd_Money(o.AdmissionId) mo)
    SELECT COUNT(*) AS InHospital,
           SUM(CASE WHEN CAST(AdmissionAt AS DATE) = @today THEN 1 ELSE 0 END) AS AdmittedToday,
           SUM(CASE WHEN Status = 'DISCHARGE_ADVISED' THEN 1 ELSE 0 END) AS DischargeAdvised,
           SUM(CASE WHEN IsIcu = 1 THEN 1 ELSE 0 END) AS InIcu,
           SUM(CASE WHEN ISNULL(IsMlc, 0) = 1 THEN 1 ELSE 0 END) AS Mlc,
           SUM(CASE WHEN PayerType = 'CASH' AND (BillNow > NetAdvance OR (NetAdvance > 0 AND BillNow >= NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END) AS DepositAlerts,
           CAST(SUM(CASE WHEN ISNULL(BillNow, 0) - ISNULL(NetAdvance, 0) > 0 THEN ISNULL(BillNow, 0) - ISNULL(NetAdvance, 0) ELSE 0 END) AS DECIMAL(18,2)) AS TotalDue,
           SUM(CASE WHEN ExpectedDischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME)) THEN 1 ELSE 0 END) AS DischargeDue,
           (SELECT COUNT(*) FROM dbo.IpdAdmission d WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId AND d.DischargeAt >= @today AND d.DischargeAt < DATEADD(DAY, 1, CAST(@today AS DATETIME))) AS DischargedToday
    FROM m;

    -- filter lookups
    SELECT w.WardId AS Id, w.WardName AS Name FROM dbo.WardMaster w WHERE w.BranchId = @BranchId AND ISNULL(w.IsActive, 1) = 1 ORDER BY w.WardName;
    SELECT DISTINCT d.DoctorId AS Id, d.FullName AS Name FROM dbo.IpdAdmission a JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
     WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId ORDER BY d.FullName;
    SELECT DISTINCT dep.DeptId AS Id, dep.DeptName AS Name FROM dbo.IpdAdmission a JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
     WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId ORDER BY dep.DeptName;
END;
GO
-- Excel export of the list: the page's View, as the list itself (no role is granted)
DECLARE @page INT, @view INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.ADMISSIONLIST';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @view = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdmission', @Action = N'ListExport', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2478 applied: IPD Admission List (filters, sorting, flags, summary).';
GO
