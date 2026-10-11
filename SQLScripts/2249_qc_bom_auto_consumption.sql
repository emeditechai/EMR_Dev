-- ============================================================================
-- Migration: 2249_qc_bom_auto_consumption.sql
-- Description: Quality & Compliance - automatic BOM consumption when a LAB result is submitted (branch-wise).
--
--   When:  dbo.usp_LabReporting_SaveEntry (Lab Reporting Entry > Submit / Validate / Approve) ends by calling
--          dbo.usp_Qc_Consume_Sync for the bill. A test is "run" once it has a result at Submitted (2), Validated (3)
--          or Approved (5); a Draft (1) consumes nothing.
--   What:  one consumption run per test run - a single test (its own BOM), or a profile test once for all its
--          parameters (the profile test's BOM); package members are consumed as the tests / profiles they are.
--          The BOM version current at that moment is used (default BOM; a test with only one analyzer BOM uses it),
--          quantity = BOM qty x (1 + reruns % + dead volume %), at the item's unit cost of that moment (frozen).
--          Outsourced samples / tests consume nothing here; a run of a test with no BOM is recorded as NO_BOM.
--   Where: the branch that ran the test - the receiving branch of a transferred and received sample, else the
--          sample's own branch.
--   Once:  saving again, correcting a value, validating, approving or un-approving for Re-Test never consumes again.
--          A sample collected again (Re-Collect / Reject + collect) after the last consumption and then submitted
--          is a new run (Run 2, 3 ...): the reagent of the first run was really used.
--   Safe:  consumption can never stop a result from being saved - any error is caught and written to
--          dbo.QcConsumptionLog; nothing is returned to the caller.
--   Stock: dbo.QcConsumption.StoreId stays NULL until stores / stock (Phase 2) deduct the lines from a bench store.
--   No back-fill: consumption starts with this script (results submitted earlier are not consumed).
--
--   Report: Reports > LAB > BOM Consumption Register (usp_Api_LabReport_BomConsumption, "bom-consumption").
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.QcConsumption', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcConsumption
    (
        ConsumptionId       INT IDENTITY(1,1) CONSTRAINT PK_QcConsumption PRIMARY KEY,
        CompanyId           INT NOT NULL,
        BranchId            INT NOT NULL,               -- the branch that ran the test
        SampleBranchId      INT NULL,                   -- the branch the sample belongs to (differs when transferred)
        LabOrderId          INT NOT NULL,
        ConsumeKey          VARCHAR(20) NOT NULL,       -- T<test id> | P<profile id>
        TestId              INT NOT NULL,               -- the test / profile test whose BOM is consumed
        ProfileId           INT NULL,
        PackageId           INT NULL,
        RunNo               INT NOT NULL,               -- 1 = first run; 2+ = after a re-collection
        CollectedOn         DATETIME NULL,              -- the sample collection this run used
        SubmittedOn         DATETIME NULL,
        Status              VARCHAR(10) NOT NULL,       -- CONSUMED | NO_BOM
        BomId               INT NULL,
        BomVersionNo        INT NULL,
        AnalyzerId          INT NULL,
        RerunPct            DECIMAL(5,2) NULL,
        DeadVolumePct       DECIMAL(5,2) NULL,
        MaterialCost        DECIMAL(14,2) NOT NULL CONSTRAINT DF_QcConsumption_Cost DEFAULT 0,
        SampleCollectionIds NVARCHAR(1000) NULL,
        StoreId             INT NULL,                   -- Phase 2: the store the lines were taken from
        ConsumedBy          INT NULL,
        ConsumedOn          DATETIME NOT NULL CONSTRAINT DF_QcConsumption_On DEFAULT GETDATE()
    );
    CREATE UNIQUE INDEX UX_QcConsumption_Run ON dbo.QcConsumption(LabOrderId, ConsumeKey, RunNo);
    CREATE INDEX IX_QcConsumption_Branch ON dbo.QcConsumption(BranchId, ConsumedOn);
END
GO

IF OBJECT_ID(N'dbo.QcConsumptionLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcConsumptionLine
    (
        ConsumptionLineId INT IDENTITY(1,1) CONSTRAINT PK_QcConsumptionLine PRIMARY KEY,
        ConsumptionId     INT NOT NULL CONSTRAINT FK_QcConsumptionLine_Run REFERENCES dbo.QcConsumption(ConsumptionId),
        ItemId            INT NOT NULL CONSTRAINT FK_QcConsumptionLine_Item REFERENCES dbo.InvItem(ItemId),
        BomQty            DECIMAL(14,4) NOT NULL,       -- the BOM quantity for one run
        Qty               DECIMAL(14,4) NOT NULL,       -- with reruns and dead volume (consumption units)
        UnitCost          DECIMAL(14,4) NOT NULL,
        LineCost          DECIMAL(14,4) NOT NULL
    );
    CREATE INDEX IX_QcConsumptionLine_Run ON dbo.QcConsumptionLine(ConsumptionId);
    CREATE INDEX IX_QcConsumptionLine_Item ON dbo.QcConsumptionLine(ItemId);
END
GO

IF OBJECT_ID(N'dbo.QcConsumptionLog', N'U') IS NULL
    CREATE TABLE dbo.QcConsumptionLog
    (
        LogId        INT IDENTITY(1,1) CONSTRAINT PK_QcConsumptionLog PRIMARY KEY,
        LabOrderId   INT NULL,
        ErrorNumber  INT NULL,
        ErrorMessage NVARCHAR(2000) NULL,
        LoggedOn     DATETIME NOT NULL CONSTRAINT DF_QcConsumptionLog_On DEFAULT GETDATE()
    );
GO

-- consume the BOM of every test of the bill that is now submitted and not consumed yet (no result set: it runs
-- inside usp_LabReporting_SaveEntry, whose caller reads that procedure's own result)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Consume_Sync
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @LabOrderId IS NULL OR @LabOrderId <= 0 RETURN;

    -- the submitted results of the bill, one row per sample-test
    SELECT sc.samplecollectionID AS SampleId,
           CASE WHEN h.Profile_Type = 1 AND h.Test_ID IS NOT NULL THEN 'P' + CAST(sc.ProfileId AS VARCHAR(12)) ELSE 'T' + CAST(sc.InvestigationID AS VARCHAR(12)) END AS ConsumeKey,
           CASE WHEN h.Profile_Type = 1 AND h.Test_ID IS NOT NULL THEN h.Test_ID ELSE sc.InvestigationID END AS TestId,
           CASE WHEN h.Profile_Type = 1 AND h.Test_ID IS NOT NULL THEN sc.ProfileId END AS ProfileId,
           sc.PackageId,
           CASE WHEN sc.IsTransferred = 1 AND sc.IsReceived = 1 AND sc.TargetBranchID IS NOT NULL THEN sc.TargetBranchID ELSE sc.BranchID END AS RunBranchId,
           sc.BranchID AS SampleBranchId,
           CASE WHEN sc.Samplecollectiondate IS NULL THEN NULL
                ELSE CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END AS CollectedOn,
           led.Submitted_Date
    INTO #S
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = sc.ProfileId
    WHERE sc.Laborderid = @LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.IsoutSource, 0) = 0
      AND led.ReportStatusId IN (2, 3, 5) AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '';
    IF NOT EXISTS (SELECT 1 FROM #S) RETURN;

    -- one unit per test / profile test
    SELECT s.ConsumeKey, MAX(s.TestId) AS TestId, MAX(s.ProfileId) AS ProfileId, MAX(s.PackageId) AS PackageId,
           MAX(s.RunBranchId) AS RunBranchId, MAX(s.SampleBranchId) AS SampleBranchId, MAX(s.CollectedOn) AS CollectedOn,
           MIN(s.Submitted_Date) AS SubmittedOn,
           LEFT(STRING_AGG(CAST(s.SampleId AS VARCHAR(20)), ','), 1000) AS SampleIds
    INTO #U
    FROM #S s
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = s.TestId AND ISNULL(m.Is_Outsourced, 0) = 0
    GROUP BY s.ConsumeKey;

    BEGIN TRANSACTION;
        -- a new run: never consumed, or the sample was collected again after the last consumption
        SELECT u.*, ISNULL(last.RunNo, 0) + 1 AS RunNo, dbo.ufn_Qc_BranchCompany(u.RunBranchId) AS CompanyId
        INTO #N
        FROM #U u
        OUTER APPLY (SELECT TOP 1 c.RunNo, c.CollectedOn, c.ConsumedOn FROM dbo.QcConsumption c WITH (UPDLOCK, HOLDLOCK)
                     WHERE c.LabOrderId = @LabOrderId AND c.ConsumeKey = u.ConsumeKey ORDER BY c.RunNo DESC) last
        WHERE last.RunNo IS NULL
           OR (u.CollectedOn IS NOT NULL AND ISNULL(last.CollectedOn, '19000101') <> u.CollectedOn AND u.CollectedOn > last.ConsumedOn);

        IF EXISTS (SELECT 1 FROM #N)
        BEGIN
            -- the BOM to use: the default one, else the test's only analyzer BOM
            SELECT n.*, b.BomId, b.VersionNo, b.AnalyzerId, b.RerunPct, b.DeadVolumePct
            INTO #B
            FROM #N n
            OUTER APPLY (SELECT TOP 1 x.BomId, x.VersionNo, x.AnalyzerId, x.RerunPct, x.DeadVolumePct FROM dbo.BomTest x
                         WHERE x.TestId = n.TestId AND x.IsActive = 1 AND x.CompanyId = n.CompanyId
                           AND (x.AnalyzerId IS NULL OR (SELECT COUNT(1) FROM dbo.BomTest y WHERE y.TestId = n.TestId AND y.IsActive = 1 AND y.CompanyId = n.CompanyId) = 1)
                         ORDER BY CASE WHEN x.AnalyzerId IS NULL THEN 0 ELSE 1 END) b;

            DECLARE @Now DATETIME = GETDATE();
            INSERT INTO dbo.QcConsumption (CompanyId, BranchId, SampleBranchId, LabOrderId, ConsumeKey, TestId, ProfileId, PackageId, RunNo, CollectedOn,
                                           SubmittedOn, Status, BomId, BomVersionNo, AnalyzerId, RerunPct, DeadVolumePct, MaterialCost, SampleCollectionIds, ConsumedBy, ConsumedOn)
            SELECT b.CompanyId, b.RunBranchId, b.SampleBranchId, @LabOrderId, b.ConsumeKey, b.TestId, b.ProfileId, b.PackageId, b.RunNo, b.CollectedOn,
                   b.SubmittedOn, CASE WHEN b.BomId IS NULL THEN 'NO_BOM' ELSE 'CONSUMED' END, b.BomId, b.VersionNo, b.AnalyzerId, b.RerunPct, b.DeadVolumePct,
                   ISNULL(dbo.ufn_Qc_BomCost(b.BomId), 0), b.SampleIds, @UserId, @Now
            FROM #B b;

            INSERT INTO dbo.QcConsumptionLine (ConsumptionId, ItemId, BomQty, Qty, UnitCost, LineCost)
            SELECT c.ConsumptionId, l.ItemId, l.Qty,
                   CAST(l.Qty * (1 + (b.RerunPct + b.DeadVolumePct) / 100.0) AS DECIMAL(14,4)),
                   ISNULL(dbo.ufn_Qc_ItemUnitCost(l.ItemId), 0),
                   CAST(l.Qty * (1 + (b.RerunPct + b.DeadVolumePct) / 100.0) * ISNULL(dbo.ufn_Qc_ItemUnitCost(l.ItemId), 0) AS DECIMAL(14,4))
            FROM #B b
            INNER JOIN dbo.QcConsumption c ON c.LabOrderId = @LabOrderId AND c.ConsumeKey = b.ConsumeKey AND c.RunNo = b.RunNo
            INNER JOIN dbo.BomTestLine l ON l.BomId = b.BomId
            WHERE b.BomId IS NOT NULL;
        END
    COMMIT TRANSACTION;
END;
GO

-- ── the hook: usp_LabReporting_SaveEntry calls the sync before returning (patched in place, rest unchanged) ──
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_LabReporting_SaveEntry'));
DECLARE @anchor NVARCHAR(200) = N'    -- Return 1 on success' + CHAR(13) + CHAR(10) + N'    SELECT 1 AS Result;';
IF CHARINDEX(@anchor, @def) = 0 SET @anchor = N'    -- Return 1 on success' + CHAR(10) + N'    SELECT 1 AS Result;';
IF CHARINDEX(N'usp_Qc_Consume_Sync', @def) = 0
BEGIN
    IF CHARINDEX(@anchor, @def) = 0 THROW 59100, 'usp_LabReporting_SaveEntry: the end of the procedure was not found; consumption hook not added.', 1;
    DECLARE @hook NVARCHAR(MAX) =
N'    -- 2249: BOM consumption of the tests submitted now (Quality & Compliance); it never stops the result from being saved
    BEGIN TRY
        EXEC dbo.usp_Qc_Consume_Sync @LabOrderId = @LabOrderId, @UserId = @UserId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        BEGIN TRY
            INSERT INTO dbo.QcConsumptionLog (LabOrderId, ErrorNumber, ErrorMessage) VALUES (@LabOrderId, ERROR_NUMBER(), LEFT(ERROR_MESSAGE(), 2000));
        END TRY
        BEGIN CATCH
        END CATCH
    END CATCH

' + @anchor;
    SET @def = REPLACE(@def, @anchor, @hook);
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 8 - PATINDEX(N'%CREATE%PROCEDURE%', @def) + 1, N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

-- ═════ Reports > LAB > BOM Consumption Register ═════════════════════════════════════════════
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BomConsumption
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @RunType VARCHAR(20) = NULL,          -- FIRST | RERUN | NOBOM
    @DepartmentId INT = NULL, @ItemId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @RunType = NULLIF(UPPER(LTRIM(RTRIM(@RunType))), '');

    SELECT c.ConsumptionId, c.ConsumedOn, CONVERT(VARCHAR(10), CAST(c.ConsumedOn AS DATE), 23) AS ConsumedDay,
           c.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName, pm.PatientCode,
           c.TestId, m.Test_Code AS TestCode, m.Test_Name AS TestName,
           CASE WHEN c.ProfileId IS NOT NULL THEN 'Profile' ELSE 'Test' END AS Kind,
           ISNULL(m.Department_ID, 0) AS DepartmentId, ISNULL(d.DeptName, N'No department') AS DepartmentName,
           ph.Profile_Name AS PackageName, c.RunNo,
           CASE WHEN c.Status = 'NO_BOM' THEN 'No BOM' WHEN c.RunNo > 1 THEN 'Re-run (sample re-collected)' ELSE 'First run' END AS RunLabel,
           CASE WHEN c.Status = 'NO_BOM' THEN 'NOBOM' WHEN c.RunNo > 1 THEN 'RERUN' ELSE 'FIRST' END AS RunType,
           c.Status, c.BomVersionNo, ISNULL(a.Analyzer_Name, CASE WHEN c.BomId IS NULL THEN NULL ELSE N'Default' END) AS AppliesTo,
           c.MaterialCost, (SELECT COUNT(1) FROM dbo.QcConsumptionLine l WHERE l.ConsumptionId = c.ConsumptionId) AS LineCount,
           c.CollectedOn, c.SubmittedOn,
           CASE WHEN c.SampleBranchId IS NOT NULL AND c.SampleBranchId <> c.BranchId THEN sb.BranchName END AS TransferredFrom,
           ISNULL(c.ConsumedBy, 0) AS ConsumedById, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS ConsumedByName
    INTO #R
    FROM dbo.QcConsumption c
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = c.TestId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = lo.PatientId
    LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = c.PackageId
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = c.AnalyzerId
    LEFT JOIN dbo.Branchmaster sb ON sb.BranchID = c.SampleBranchId
    LEFT JOIN dbo.Users u ON u.Id = c.ConsumedBy
    WHERE c.BranchId = @BranchId AND c.ConsumedOn >= @From AND c.ConsumedOn < @To
      AND (@DepartmentId IS NULL OR m.Department_ID = @DepartmentId)
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM dbo.QcConsumptionLine l WHERE l.ConsumptionId = c.ConsumptionId AND l.ItemId = @ItemId))
      AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR m.Test_Code LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%'
           OR pm.PatientCode LIKE '%' + @Search + '%' OR pm.FirstName LIKE '%' + @Search + '%');
    DELETE FROM #R WHERE @RunType IS NOT NULL AND RunType <> @RunType;

    -- item totals of the runs listed (Summary "Item" and the KPIs)
    SELECT l.ItemId, i.ItemCode, i.ItemName, cu.UnitName AS Unit, COUNT(1) AS Uses, SUM(l.Qty) AS Qty, CAST(SUM(l.LineCost) AS DECIMAL(14,2)) AS Cost
    INTO #I
    FROM dbo.QcConsumptionLine l
    INNER JOIN #R r ON r.ConsumptionId = l.ConsumptionId
    INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    GROUP BY l.ItemId, i.ItemCode, i.ItemName, cu.UnitName;

    SELECT COUNT(1) AS Runs, COUNT(DISTINCT LabOrderId) AS Bills, CAST(ISNULL(SUM(MaterialCost), 0) AS DECIMAL(14,2)) AS MaterialCost,
           SUM(CASE WHEN RunType = 'RERUN' THEN 1 ELSE 0 END) AS Reruns, SUM(CASE WHEN RunType = 'NOBOM' THEN 1 ELSE 0 END) AS NoBomRuns,
           (SELECT COUNT(1) FROM #I) AS ItemsUsed,
           (SELECT TOP 1 ItemName FROM #I ORDER BY Cost DESC) AS TopItem, (SELECT TOP 1 Cost FROM #I ORDER BY Cost DESC) AS TopItemCost,
           SUM(CASE WHEN TransferredFrom IS NOT NULL THEN 1 ELSE 0 END) AS TransferredRuns
    FROM #R;

    SELECT 'byTest' AS GroupKey, TestId AS GroupId, TestName AS GroupName, COUNT(1) AS Runs, CAST(SUM(MaterialCost) AS DECIMAL(14,2)) AS Cost, CAST(NULL AS NVARCHAR(60)) AS QtyText
    FROM #R GROUP BY TestId, TestName
    UNION ALL
    SELECT 'byDept', DepartmentId, DepartmentName, COUNT(1), CAST(SUM(MaterialCost) AS DECIMAL(14,2)), NULL FROM #R GROUP BY DepartmentId, DepartmentName
    UNION ALL
    SELECT 'byDate', NULL, ConsumedDay, COUNT(1), CAST(SUM(MaterialCost) AS DECIMAL(14,2)), NULL FROM #R GROUP BY ConsumedDay
    UNION ALL
    SELECT 'byRunType', NULL, RunLabel, COUNT(1), CAST(SUM(MaterialCost) AS DECIMAL(14,2)), NULL FROM #R GROUP BY RunLabel
    UNION ALL
    SELECT 'byItem', ItemId, ItemName, Uses, Cost,
           CAST(CONCAT(FORMAT(Qty, '#,##0.####'), ' ', Unit) AS NVARCHAR(60)) FROM #I
    ORDER BY GroupKey, GroupName;

    SELECT * FROM #R ORDER BY ConsumedOn DESC, ConsumptionId DESC;

    SELECT 'departmentId' AS FilterKey, CAST(DeptId AS VARCHAR(20)) AS Value, DeptName AS Text FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
    UNION ALL
    SELECT 'itemId', CAST(ItemId AS VARCHAR(20)), ItemName FROM #I
    ORDER BY FilterKey, Text;

    SELECT l.ConsumptionId, i.ItemCode, i.ItemName, cu.UnitName AS Unit, l.BomQty, l.Qty, l.UnitCost, l.LineCost
    FROM dbo.QcConsumptionLine l
    INNER JOIN #R r ON r.ConsumptionId = l.ConsumptionId
    INNER JOIN dbo.InvItem i ON i.ItemId = l.ItemId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    ORDER BY l.ConsumptionId, l.ConsumptionLineId;
END;
GO

-- Page under Reports > LAB -----------------------------------------------------------------------
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABBOMCONSUMPTION',
             @Title = N'BOM Consumption Register', @Controller = N'Reports', @Action = N'LabBomConsumption',
             @Show_In_Menu = 1, @Sort_Order = 298, @Icon = N'bi bi-box-arrow-right me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabBomConsumption', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'PrintBill', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2249 applied: BOM consumption on LAB result submit (branch-wise) + BOM Consumption Register.';
GO
