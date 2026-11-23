-- ============================================================================================================
-- Migration: 2477_lab_worksheet.sql   (application database)
-- LAB > Work Sheet (LAB.WORKSHEET): the numeric tests of one day's bills, bill-wise, printed (A4, print template
-- header / footer) or exported to PDF so the technician writes the values by hand on the bench (hard copy).
--   Date filter : ORDER (bill date) | BOOKING (booking date) | COLLECTION (sample collected that day) - one day
--   Channel     : ALL | B2C | B2B
--   Values      : ALL | WITH (value entered) | WITHOUT (blank)
--   Tests       : sample collected (status Collected) and Reporting Type = Numeric only; a profile test (e.g. LFT) or a profile / package ordered is shown with its name as the header and its
--                 numeric tests under it (profile sequence); a value already entered is printed, else the box is blank.
--   usp_Api_LabWorksheet_List. Page LAB.WORKSHEET: VIEW (Index, Data), PRINT (Print, Pdf). No role is granted.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabWorksheet_List
    @CompanyId INT, @BranchId INT, @DateType VARCHAR(12) = 'ORDER', @Date DATE, @Channel VARCHAR(5) = 'ALL', @Values VARCHAR(8) = 'ALL'
AS
BEGIN
    SET NOCOUNT ON;
    SET @DateType = ISNULL(NULLIF(UPPER(@DateType), ''), 'ORDER');
    SET @Channel = ISNULL(NULLIF(UPPER(@Channel), ''), 'ALL');
    IF @DateType NOT IN ('ORDER', 'BOOKING', 'COLLECTION') SET @DateType = 'ORDER';
    IF @Channel NOT IN ('ALL', 'B2C', 'B2B') SET @Channel = 'ALL';
    SET @Values = ISNULL(NULLIF(UPPER(@Values), ''), 'ALL');
    IF @Values NOT IN ('ALL', 'WITH', 'WITHOUT') SET @Values = 'ALL';
    IF @Date IS NULL SET @Date = CAST(GETDATE() AS DATE);

    -- the bills of the day (branch, active, channel)
    DECLARE @O TABLE (LabOrderId INT PRIMARY KEY);
    INSERT @O (LabOrderId)
    SELECT lo.LabOrderId
    FROM dbo.LabOrder lo
    WHERE lo.BranchId = @BranchId AND ISNULL(lo.IsActive, 1) = 1
      AND (@Channel = 'ALL' OR (@Channel = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@Channel = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (   (@DateType = 'ORDER'   AND lo.OrderDate >= @Date AND lo.OrderDate < DATEADD(DAY, 1, @Date))
           OR (@DateType = 'BOOKING' AND lo.BookingDate >= @Date AND lo.BookingDate < DATEADD(DAY, 1, @Date))
           OR (@DateType = 'COLLECTION' AND EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.Laborderid = lo.LabOrderId AND ISNULL(sc.Iscancelled, 0) = 0
                                                    AND ISNULL(sc.CollectionstatusID, 1) = 2 AND sc.Samplecollectiondate = @Date)));

    -- the tests of each bill: a single test as it is, a profile / package as its tests (profile sequence)
    -- a profile test (Is_Profile_Test, e.g. Liver Function Test) is a test linked to a profile header: shown as its tests
    ;WITH PT AS
    (
        SELECT h.Test_ID, MIN(h.Profile_ID) AS Profile_ID
        FROM dbo.LabInvestigationProfileHeader h
        WHERE h.Test_ID IS NOT NULL AND ISNULL(h.IsDeleted, 0) = 0 AND (h.CompanyId = @CompanyId OR h.CompanyId IS NULL)
          AND EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileDetail d WHERE d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0)
        GROUP BY h.Test_ID
    ),
    T AS
    (
        SELECT oi.LabOrderId, oi.LabOrderItemId, CAST(NULL AS INT) AS ProfileId, CAST(NULL AS NVARCHAR(200)) AS ProfileName, oi.InvestigationId AS TestId, 0 AS Seq
        FROM dbo.LabOrderItem oi JOIN @O o ON o.LabOrderId = oi.LabOrderId
        WHERE ISNULL(oi.IsActive, 1) = 1 AND ISNULL(oi.Type, 'I') = 'I' AND NOT EXISTS (SELECT 1 FROM PT WHERE PT.Test_ID = oi.InvestigationId)
        UNION ALL
        SELECT oi.LabOrderId, oi.LabOrderItemId, h.Profile_ID, ISNULL(NULLIF(LTRIM(RTRIM(pinv.Reporting_Name)), N''), h.Profile_Name), d.Test_ID, ISNULL(d.Sequence, 0)
        FROM dbo.LabOrderItem oi JOIN @O o ON o.LabOrderId = oi.LabOrderId
        JOIN PT ON PT.Test_ID = oi.InvestigationId
        JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = PT.Profile_ID
        JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
        JOIN dbo.LabInvestigationMaster pinv ON pinv.Test_ID = oi.InvestigationId AND pinv.Reporting_Type = 'Numeric'   -- as Lab Reporting Entry: a Template profile (e.g. Urine R/M) is reported elsewhere
        WHERE ISNULL(oi.IsActive, 1) = 1 AND ISNULL(oi.Type, 'I') = 'I'
        UNION ALL
        SELECT oi.LabOrderId, oi.LabOrderItemId, h.Profile_ID, h.Profile_Name, d.Test_ID, ISNULL(d.Sequence, 0) * 1000
        FROM dbo.LabOrderItem oi JOIN @O o ON o.LabOrderId = oi.LabOrderId
        JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = oi.InvestigationId
        JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
        WHERE ISNULL(oi.IsActive, 1) = 1 AND oi.Type = 'P' AND NOT EXISTS (SELECT 1 FROM PT WHERE PT.Test_ID = d.Test_ID)
        UNION ALL
        -- a profile test inside a package (e.g. Lipid Profile in a health package): its tests under "package · profile"
        SELECT oi.LabOrderId, oi.LabOrderItemId, h2.Profile_ID, h.Profile_Name + N' · ' + ISNULL(NULLIF(LTRIM(RTRIM(pinv.Reporting_Name)), N''), h2.Profile_Name),
               d2.Test_ID, ISNULL(d.Sequence, 0) * 1000 + ISNULL(d2.Sequence, 0)
        FROM dbo.LabOrderItem oi JOIN @O o ON o.LabOrderId = oi.LabOrderId
        JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = oi.InvestigationId
        JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
        JOIN PT ON PT.Test_ID = d.Test_ID
        JOIN dbo.LabInvestigationMaster pinv ON pinv.Test_ID = d.Test_ID AND pinv.Reporting_Type = 'Numeric'
        JOIN dbo.LabInvestigationProfileHeader h2 ON h2.Profile_ID = PT.Profile_ID
        JOIN dbo.LabInvestigationProfileDetail d2 ON d2.Profile_ID = h2.Profile_ID AND ISNULL(d2.IsDeleted, 0) = 0
        WHERE ISNULL(oi.IsActive, 1) = 1 AND oi.Type = 'P'
    )
    SELECT lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate, lo.BookingDate, CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
           CAST(CASE WHEN lo.AdmissionId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsIpd,
           p.PatientCode, LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation + N' ', N' '), p.FirstName, N' ', NULLIF(p.MiddleName + N' ', N' '), p.LastName))) AS PatientName,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(lo.OrderDate AS DATE)) AS AgeText, p.Gender,
           t.LabOrderItemId, t.ProfileId, t.ProfileName, t.Seq, inv.Test_ID AS TestId, inv.Test_Code AS TestCode,
           ISNULL(NULLIF(LTRIM(RTRIM(inv.Reporting_Name)), N''), inv.Test_Name) AS TestName,
           ISNULL(NULLIF(u.Unit_Symbol, N''), u.Unit_Name) AS Unit,
           CASE WHEN sc.Samplecollectiondate IS NOT NULL THEN CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END AS CollectedAt,
           sc.BarcodeNo, NULLIF(LTRIM(RTRIM(le.TestValue)), N'') AS TestValue, le.AbnormalFlag, rs.StatusName AS ReportStatus
    FROM T t
    JOIN dbo.LabOrder lo ON lo.LabOrderId = t.LabOrderId
    JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    JOIN dbo.LabInvestigationMaster inv ON inv.Test_ID = t.TestId AND inv.Reporting_Type = 'Numeric'
    LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = inv.Unit_ID
    OUTER APPLY (SELECT TOP (1) s.Samplecollectiondate, s.Samplecollectiontime, s.BarcodeNo
                 FROM dbo.SampleCollection s
                 WHERE s.Laborderid = t.LabOrderId AND s.InvestigationID = t.TestId AND ISNULL(s.Iscancelled, 0) = 0 AND ISNULL(s.CollectionstatusID, 1) = 2
                 ORDER BY CASE WHEN ISNULL(s.ProfileId, 0) = ISNULL(t.ProfileId, 0) THEN 0 ELSE 1 END, s.samplecollectionID DESC) sc
    OUTER APPLY (SELECT TOP (1) e.TestValue, e.AbnormalFlag, e.ReportStatusId
                 FROM dbo.labentrydetails e
                 WHERE e.LabOrderId = t.LabOrderId AND e.InvestigationID = t.TestId AND ISNULL(e.IsActive, 1) = 1
                 ORDER BY e.LabEntryDetailId DESC) le
    LEFT JOIN dbo.Reportentrystatus rs ON rs.ReportStatusId = le.ReportStatusId
    -- only tests whose sample is collected (Sample Collection status Collected); a bill with none is not listed.
    -- Sample collection day: only the tests collected that day
    WHERE sc.Samplecollectiondate IS NOT NULL
      AND (@DateType <> 'COLLECTION' OR sc.Samplecollectiondate = @Date)
      -- value filter: tests with a value entered / still blank (a profile header stays only while one of its tests does)
      AND (@Values = 'ALL' OR (@Values = 'WITH' AND NULLIF(LTRIM(RTRIM(le.TestValue)), N'') IS NOT NULL)
                          OR (@Values = 'WITHOUT' AND NULLIF(LTRIM(RTRIM(le.TestValue)), N'') IS NULL))
    ORDER BY lo.OrderDate, lo.LabOrderId, t.LabOrderItemId, t.Seq, inv.Test_ID;
END
GO

-- ── page LAB > Work Sheet ───────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @lab INT, @page INT, @view INT, @ctl INT, @a NVARCHAR(40);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'LAB';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.WORKSHEET', @Title = N'Work Sheet',
         @Controller = N'LabWorksheet', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 45, @Icon = N'bi bi-grid-3x3 me-2 text-primary',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Index,Data', ',');
    OPEN v; FETCH NEXT FROM v INTO @a;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabWorksheet', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
    CLOSE v; DEALLOCATE v;
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PRINT', @Title = N'Print / export the work sheet (PDF)', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabWorksheet', @Action = N'Print', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabWorksheet', @Action = N'Pdf', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2477 applied: LAB > Work Sheet.';
GO
