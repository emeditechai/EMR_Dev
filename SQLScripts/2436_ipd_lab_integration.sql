-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2436  IPD Phase 4 · LAB integration: LAB / radiology orders from the IPD Patient screen
--   An IPD order is an ordinary LAB order (LabOrder / LabOrderItem, LAB bill no., token, SampleCollection rows), so
--   sample collection, result entry, validation, reports and dispatch work unchanged. Differences:
--     * LabOrder.AdmissionId marks it; items are priced from the branch's IPD LAB Rate List (fn_Ipd_LabRate, 2435)
--     * no money at the LAB counter: a LAB payment header settled as "credit to the IP bill" (no payment lines, so no
--       cash, receipt or day-closing effect); the charge goes to the IP bill (IpdCharge head LAB / RADIOLOGY)
--     * LAB revenue is not posted for it (IPD revenue is posted at the final IPD bill): the accounts posting audit,
--       reconciliation and repair leave IPD orders out
--     * cancellation only from the IPD Patient screen, while no sample is collected and no result entered
--       (usp_Bill_Cancel refuses an IPD order)
--   usp_Api_IpdLab_Items, _Order, _List, _CancelItem. Needs 2422-2435. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. LabOrder: the admission and the ordering doctor ───────────────────────────────────────────────────────
IF COL_LENGTH('dbo.LabOrder', 'AdmissionId') IS NULL
    ALTER TABLE dbo.LabOrder ADD AdmissionId INT NULL, OrderedByDoctorId INT NULL, IpdRemarks NVARCHAR(300) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabOrder_Admission')
    CREATE INDEX IX_LabOrder_Admission ON dbo.LabOrder (AdmissionId) WHERE AdmissionId IS NOT NULL;
GO

-- ── 2. existing procedures: leave IPD orders out of LAB accounts, refuse LAB-side cancellation ─────────────────
DECLARE @p SYSNAME, @def NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM (VALUES ('usp_Acc_Recon_Bills'), ('usp_Acc_Recon_Repair'), ('usp_AccRpt_PostingAudit')) v (name);
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.' + @p));
    IF @def IS NOT NULL AND @def NOT LIKE '%lo.AdmissionId IS NULL%'
    BEGIN
        IF @def NOT LIKE '%ISNULL(lo.TotalAmount, 0) > 0%' BEGIN DECLARE @m NVARCHAR(300) = @p + N' has changed: leave IPD LAB orders out by hand.'; THROW 51310, @m, 1; END;
        -- IPD LAB orders (2436) are billed on the IPD final bill: not a LAB bill for the ledger
        SET @def = REPLACE(@def, 'ISNULL(lo.TotalAmount, 0) > 0', 'ISNULL(lo.TotalAmount, 0) > 0 AND lo.AdmissionId IS NULL');
        SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        EXEC (@def);
    END
    FETCH NEXT FROM c INTO @p;
END
CLOSE c; DEALLOCATE c;
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Bill_Cancel'));
IF @def NOT LIKE '%IPD admission (2436)%'
BEGIN
    DECLARE @anchor NVARCHAR(100) = N'BEGIN TRY';
    IF CHARINDEX(@anchor, @def) = 0 THROW 51311, 'usp_Bill_Cancel has changed: add the IPD guard by hand.', 1;
    SET @def = STUFF(@def, CHARINDEX(@anchor, @def), 0, N'-- an order of an IPD admission (2436) is cancelled from the IPD Patient screen, never refunded at the LAB counter
    IF @ModuleCode = ''LAB'' AND EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId AND AdmissionId IS NOT NULL)
        THROW 50090, ''This LAB order belongs to an IPD admission: cancel its tests from the IPD Patient screen (LAB tab).'', 1;

    ');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- ── 3. what an IPD patient can be ordered: the branch's IPD LAB Rate List ────────────────────────────────────
-- @Kind LAB = everything except radiology / imaging departments, RAD = radiology / imaging only, NULL = all
CREATE OR ALTER FUNCTION dbo.fn_Ipd_LabItems (@BranchId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    WITH card AS
    (
        SELECT TOP (1) m.RateCard_ID FROM dbo.LabRateCardMaster m
        WHERE m.Rate_Type = 'IPD' AND m.Branch_ID = @BranchId AND m.Status = 1 AND m.IsDeleted = 0 AND @OnDate BETWEEN m.Effective_From AND m.Effective_To
        ORDER BY m.Effective_From DESC, m.RateCard_ID DESC
    ),
    d AS
    (
        SELECT d.Item_Type, d.Item_ID, d.Rate, ROW_NUMBER() OVER (PARTITION BY d.Item_Type, d.Item_ID ORDER BY d.Detail_ID DESC) AS rn
        FROM dbo.LabRateCardDetail d JOIN card ON card.RateCard_ID = d.RateCard_ID
        WHERE d.IsDeleted = 0 AND d.Status = 1 AND d.Rate > 0
    )
    SELECT d.Item_Type AS ItemType, d.Item_ID AS ItemId, CAST(d.Rate AS DECIMAL(18,2)) AS Rate,
           COALESCE(i.Test_Code, h.Profile_Code) AS Code, COALESCE(i.Test_Name, h.Profile_Name) AS Name,
           COALESCE(i.Applicable_Gender, h.Applicable_Gender) AS Gender, dep.DeptName AS DepartmentName,
           CAST(CASE WHEN dep.DeptName LIKE N'%Radiolog%' OR dep.DeptName LIKE N'%Imaging%' OR dep.DeptName LIKE N'%X-Ray%' OR dep.DeptName LIKE N'%Sonograph%' THEN 1 ELSE 0 END AS BIT) AS IsRadiology
    FROM d
    LEFT JOIN dbo.LabInvestigationMaster i ON d.Item_Type IN ('Test', 'Profile') AND i.Test_ID = d.Item_ID AND i.IsDeleted = 0 AND i.Status = 1
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON d.Item_Type = 'Package' AND h.Profile_ID = d.Item_ID AND h.IsDeleted = 0 AND h.Status = 1
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = i.Department_ID
    WHERE d.rn = 1 AND (i.Test_ID IS NOT NULL OR h.Profile_ID IS NOT NULL)
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdLab_Items @CompanyId INT, @BranchId INT, @AdmissionId INT, @Kind VARCHAR(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gender NVARCHAR(20);
    SELECT @gender = p.Gender FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
    SELECT x.ItemType, x.ItemId, x.Code, x.Name, x.Rate, x.DepartmentName, x.IsRadiology
    FROM dbo.fn_Ipd_LabItems(@BranchId, CAST(GETDATE() AS DATE)) x
    WHERE (@Kind IS NULL OR (@Kind = 'RAD' AND x.IsRadiology = 1) OR (@Kind = 'LAB' AND x.IsRadiology = 0))
      AND (x.Gender IS NULL OR x.Gender IN (N'', N'Both', N'All', N'Any') OR @gender IS NULL OR x.Gender = @gender)
    ORDER BY CASE x.ItemType WHEN 'Package' THEN 0 WHEN 'Profile' THEN 1 ELSE 2 END, x.Name;
    -- has the branch an IPD LAB rate list in force today?
    SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.LabRateCardMaster WHERE Rate_Type = 'IPD' AND Branch_ID = @BranchId AND Status = 1 AND IsDeleted = 0
                                  AND CAST(GETDATE() AS DATE) BETWEEN Effective_From AND Effective_To) THEN 1 ELSE 0 END AS BIT) AS HasRateList;
END;
GO

-- ── 4. order: LAB order + LAB settlement header (credit to IP) + IP bill charges, in one transaction ─────────────
-- @Items JSON [{ItemType: Test|Profile|Package, ItemId, IsUrgent}]. The caller then creates the sample rows and the
-- token exactly as the LAB booking screen does (usp_CreateSampleCollectionFromLabOrder, usp_LAB_AssignTokenOnPayment).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdLab_Order
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Items NVARCHAR(MAX), @DoctorId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(1000), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT, @patient INT, @ip NVARCHAR(40), @gender NVARCHAR(20);
        SELECT @open = a.IsOpen, @status = a.Status, @bill = a.BillId, @patient = a.PatientId, @ip = a.IpNo, @gender = p.Gender
        FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @open IS NULL THROW 55001, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED')
            THROW 55002, 'Tests can be ordered only for an admitted patient before the final bill.', 1;
        IF @DoctorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
            THROW 55003, 'Choose the ordering doctor.', 1;

        DECLARE @L TABLE (Seq INT IDENTITY(1,1), ItemType VARCHAR(10), ItemId INT, IsUrgent BIT, Rate DECIMAL(18,2), Code NVARCHAR(100), Name NVARCHAR(300),
                          IsRadiology BIT, Gender NVARCHAR(20), ItemRowId INT NULL);
        IF ISJSON(@Items) = 1
            INSERT @L (ItemType, ItemId, IsUrgent)
            SELECT j.ItemType, j.ItemId, ISNULL(j.IsUrgent, 0) FROM OPENJSON(@Items) WITH (ItemType VARCHAR(10), ItemId INT, IsUrgent BIT) j WHERE j.ItemId > 0;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 55004, 'Add at least one test.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ItemType NOT IN ('Test', 'Profile', 'Package')) THROW 55005, 'Unknown kind of LAB item.', 1;
        IF EXISTS (SELECT ItemType, ItemId FROM @L GROUP BY ItemType, ItemId HAVING COUNT(*) > 1) THROW 55006, 'A test is added twice.', 1;
        UPDATE l SET Rate = x.Rate, Code = x.Code, Name = x.Name, IsRadiology = x.IsRadiology, Gender = x.Gender
        FROM @L l JOIN dbo.fn_Ipd_LabItems(@BranchId, CAST(@now AS DATE)) x ON x.ItemType = l.ItemType AND x.ItemId = l.ItemId;
        SET @msg = (SELECT TOP 1 CONCAT(N'Item ', l.ItemType, N' #', l.ItemId) FROM @L l WHERE l.Rate IS NULL);
        IF @msg IS NOT NULL
        BEGIN
            SET @msg = @msg + N' is not on this branch''s IPD LAB Rate List (Master > IPD Master > IPD LAB Rate List): it cannot be ordered.';
            THROW 55007, @msg, 1;
        END
        SET @msg = (SELECT TOP 1 Name FROM @L WHERE Gender IN (N'Male', N'Female') AND @gender IN (N'Male', N'Female') AND Gender <> @gender);
        IF @msg IS NOT NULL BEGIN SET @msg = N'"' + @msg + N'" is only for ' + (SELECT TOP 1 LOWER(Gender) FROM @L WHERE Name = @msg) + N' patients.'; THROW 55008, @msg, 1; END
        -- the same test still pending (not reported) on this admission
        SET @msg = (SELECT TOP 1 l.Name FROM @L l
                    JOIN dbo.LabOrderItem li ON li.InvestigationId = l.ItemId AND li.IsActive = 1 AND li.[Type] = CASE WHEN l.ItemType = 'Package' THEN 'P' ELSE 'I' END
                    JOIN dbo.LabOrder lo ON lo.LabOrderId = li.LabOrderId AND lo.AdmissionId = @AdmissionId AND lo.IsActive = 1
                    WHERE CAST(lo.OrderDate AS DATE) = CAST(@now AS DATE)
                      AND NOT EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.LabOrderId = lo.LabOrderId AND e.ReportStatusId = 5 AND e.IsActive = 1));
        IF @msg IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @L WHERE IsUrgent = 1)
        BEGIN SET @msg = N'"' + @msg + N'" is already ordered today and not yet reported. Mark it urgent to order it again.'; THROW 55009, @msg, 1; END

        DECLARE @total DECIMAL(18,2) = (SELECT SUM(Rate) FROM @L), @billNo NVARCHAR(50), @order INT;
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @billNo OUTPUT;
        INSERT dbo.LabOrder (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive,
                             IsB2B, AdmissionId, OrderedByDoctorId, IpdRemarks)
        VALUES (@patient, @BranchId, @now, @billNo, NULL, @total, 'Lab', NULL, @now, CASE WHEN EXISTS (SELECT 1 FROM @L WHERE IsUrgent = 1) THEN 1 ELSE 0 END,
                @UserId, @now, 1, 0, @AdmissionId, @DoctorId, NULLIF(LTRIM(RTRIM(@Remarks)), N''));
        SET @order = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive)
        SELECT @order, ItemId, CASE WHEN ItemType = 'Package' THEN 'P' ELSE 'I' END, Rate, IsUrgent, @UserId, @now, 1 FROM @L ORDER BY Seq;
        UPDATE l SET ItemRowId = li.LabOrderItemId
        FROM @L l JOIN dbo.LabOrderItem li ON li.LabOrderId = @order AND li.InvestigationId = l.ItemId AND li.[Type] = CASE WHEN l.ItemType = 'Package' THEN 'P' ELSE 'I' END;
        -- settled at the LAB counter as credit to the IP bill (no payment lines: no cash, receipt or day-closing effect)
        INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
               NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
        VALUES ('LAB', @order, @BranchId, @patient, @total, 0, NULL, 0, 0, @total, 0, 0, 'P', LEFT(N'IPD credit: charged to IP bill ' + @ip, 500), @now, @UserId, 1, 0, 0, 0, @CompanyId, 0);
        -- the IP bill
        DECLARE @s INT = 1, @n INT = (SELECT COUNT(*) FROM @L), @cid BIGINT, @h VARCHAR(20), @code NVARCHAR(50), @name NVARCHAR(250), @rate DECIMAL(18,2), @row INT;
        WHILE @s <= @n
        BEGIN
            SELECT @h = CASE WHEN IsRadiology = 1 THEN 'RADIOLOGY' ELSE 'LAB' END, @code = LEFT(Code, 50), @name = LEFT(Name + CASE WHEN IsUrgent = 1 THEN N' (urgent)' ELSE N'' END, 250),
                   @rate = Rate, @row = ItemRowId FROM @L WHERE Seq = @s;
            EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @AdmissionId, @UserId = @UserId, @Head = @h, @ItemCode = @code, @ItemName = @name, @SourceModule = 'LAB',
                 @SourceId = @row, @SourceNo = @billNo, @DoctorId = @DoctorId, @ChargeAt = @now, @Qty = 1, @Rate = @rate, @Discount = 0, @GstPercent = 0,
                 @MasterRate = @rate, @RefKind = 'LAB', @RefId = @order, @ChargeId = @cid OUTPUT;
            SET @s += 1;
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'LAB_ORDER', LEFT(CONCAT(N'LAB order ', @billNo, N' (', @n, N' item(s), ₹', FORMAT(@total, 'N2', 'en-IN'), N'): ', STRING_AGG(CAST(Name AS NVARCHAR(MAX)), N', ')), 1000), @UserId FROM @L;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @order AS LabOrderId, @billNo AS BillNo, @total AS Total, @n AS Items;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 5. orders of an admission, item by item, with the sample and report status ─────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_LabItemStatus (@LabOrderItemId INT)
RETURNS TABLE
AS RETURN
(
    SELECT COUNT(sc.samplecollectionID) AS Samples,
           SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS Collected,
           SUM(CASE WHEN sc.CollectionstatusID = 4 THEN 1 ELSE 0 END) AS Rejected,
           SUM(CASE WHEN sc.CollectionstatusID = 3 THEN 1 ELSE 0 END) AS Recollect,
           MIN(sc.BarcodeNo) AS BarcodeNo,
           (SELECT COUNT(*) FROM dbo.labentrydetails e WHERE e.LabOrderId = li.LabOrderId AND e.IsActive = 1
                AND e.SamplecollectionID IN (SELECT x.samplecollectionID FROM dbo.SampleCollection x WHERE x.Laborderid = li.LabOrderId AND ISNULL(x.Iscancelled, 0) = 0
                    AND ((li.[Type] = 'P' AND x.PackageId = li.InvestigationId)
                      OR (li.[Type] <> 'P' AND x.PackageId IS NULL AND (x.ProfileId IN (SELECT Profile_ID FROM dbo.LabInvestigationProfileHeader WHERE Test_ID = li.InvestigationId)
                                                                    OR (x.ProfileId IS NULL AND x.InvestigationID = li.InvestigationId)))))) AS Entered,
           (SELECT MAX(CASE WHEN e.ReportStatusId = 5 THEN 3 WHEN e.ReportStatusId = 3 THEN 2 WHEN e.ReportStatusId IN (1, 2) THEN 1 ELSE 0 END) FROM dbo.labentrydetails e
             WHERE e.LabOrderId = li.LabOrderId AND e.IsActive = 1
               AND e.SamplecollectionID IN (SELECT x.samplecollectionID FROM dbo.SampleCollection x WHERE x.Laborderid = li.LabOrderId AND ISNULL(x.Iscancelled, 0) = 0
                    AND ((li.[Type] = 'P' AND x.PackageId = li.InvestigationId)
                      OR (li.[Type] <> 'P' AND x.PackageId IS NULL AND (x.ProfileId IN (SELECT Profile_ID FROM dbo.LabInvestigationProfileHeader WHERE Test_ID = li.InvestigationId)
                                                                    OR (x.ProfileId IS NULL AND x.InvestigationID = li.InvestigationId)))))) AS ReportLevel
    FROM dbo.LabOrderItem li
    LEFT JOIN dbo.SampleCollection sc ON sc.Laborderid = li.LabOrderId AND ISNULL(sc.Iscancelled, 0) = 0
         AND ((li.[Type] = 'P' AND sc.PackageId = li.InvestigationId)
           OR (li.[Type] <> 'P' AND sc.PackageId IS NULL AND (sc.ProfileId IN (SELECT Profile_ID FROM dbo.LabInvestigationProfileHeader WHERE Test_ID = li.InvestigationId)
                                                          OR (sc.ProfileId IS NULL AND sc.InvestigationID = li.InvestigationId))))
    WHERE li.LabOrderItemId = @LabOrderItemId
    GROUP BY li.LabOrderId, li.[Type], li.InvestigationId
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdLab_List @CompanyId INT, @AdmissionId INT, @Kind VARCHAR(3) = NULL, @IncludeCancelled BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId) RETURN;
    SELECT lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate, li.LabOrderItemId, li.[Type] AS ItemKind, li.InvestigationId, li.Price, li.IsUrgent,
           CAST(li.IsActive AS BIT) AS IsActive,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name) AS ItemName,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Code END, i.Test_Code) AS ItemCode,
           CASE WHEN li.[Type] = 'P' THEN 'Package' WHEN ISNULL(i.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           dep.DeptName AS DepartmentName,
           CAST(CASE WHEN dep.DeptName LIKE N'%Radiolog%' OR dep.DeptName LIKE N'%Imaging%' OR dep.DeptName LIKE N'%X-Ray%' OR dep.DeptName LIKE N'%Sonograph%' THEN 1 ELSE 0 END AS BIT) AS IsRadiology,
           d.FullName AS OrderedByDoctor, u.FullName AS OrderedByUser, lo.IpdRemarks,
           st.Samples, st.Collected, st.Rejected, st.Recollect, st.BarcodeNo, st.Entered, st.ReportLevel,
           CASE WHEN li.IsActive = 0 THEN 'CANCELLED' WHEN st.ReportLevel = 3 THEN 'REPORTED' WHEN st.ReportLevel = 2 THEN 'VALIDATED'
                WHEN st.ReportLevel = 1 OR st.Entered > 0 THEN 'IN_PROCESS' WHEN st.Rejected > 0 OR st.Recollect > 0 THEN 'RECOLLECT'
                WHEN st.Collected > 0 THEN 'COLLECTED' ELSE 'ORDERED' END AS ItemStatus,
           CAST(CASE WHEN li.IsActive = 1 AND ISNULL(st.Collected, 0) = 0 AND ISNULL(st.Entered, 0) = 0 AND a.BillId IS NULL AND a.IsOpen = 1 THEN 1 ELSE 0 END AS BIT) AS CanCancel,
           c.ChargeId, c.Status AS ChargeStatus, c.CancelReason
    FROM dbo.LabOrder lo
    JOIN dbo.IpdAdmission a ON a.AdmissionId = lo.AdmissionId
    JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster i ON li.[Type] <> 'P' AND i.Test_ID = li.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = i.Department_ID
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = lo.OrderedByDoctorId
    LEFT JOIN dbo.Users u ON u.Id = lo.CreatedBy
    OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
    OUTER APPLY (SELECT TOP 1 x.ChargeId, x.Status, x.CancelReason FROM dbo.IpdCharge x WHERE x.AdmissionId = lo.AdmissionId AND x.SourceModule = 'LAB' AND x.SourceId = li.LabOrderItemId ORDER BY x.ChargeId DESC) c
    WHERE lo.AdmissionId = @AdmissionId AND (ISNULL(@IncludeCancelled, 0) = 1 OR li.IsActive = 1)
      AND (@Kind IS NULL
           OR (@Kind = 'RAD' AND (dep.DeptName LIKE N'%Radiolog%' OR dep.DeptName LIKE N'%Imaging%' OR dep.DeptName LIKE N'%X-Ray%' OR dep.DeptName LIKE N'%Sonograph%'))
           OR (@Kind = 'LAB' AND NOT (ISNULL(dep.DeptName, N'') LIKE N'%Radiolog%' OR ISNULL(dep.DeptName, N'') LIKE N'%Imaging%' OR ISNULL(dep.DeptName, N'') LIKE N'%X-Ray%' OR ISNULL(dep.DeptName, N'') LIKE N'%Sonograph%')))
    ORDER BY lo.OrderDate DESC, lo.LabOrderId DESC, li.LabOrderItemId;
END;
GO

-- ── 6. cancel one item (no sample collected, no result): LAB item and samples off, IP bill charge cancelled ──────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdLab_CancelItem @CompanyId INT, @BranchId INT, @UserId INT, @LabOrderItemId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 55021, 'Enter the reason for cancelling the test.', 1;
        DECLARE @order INT, @adm INT, @active BIT, @bill INT, @open BIT, @price DECIMAL(18,2), @no NVARCHAR(50);
        SELECT @order = lo.LabOrderId, @adm = lo.AdmissionId, @active = li.IsActive, @bill = a.BillId, @open = a.IsOpen, @price = li.Price, @no = lo.BillNo
        FROM dbo.LabOrderItem li WITH (UPDLOCK) JOIN dbo.LabOrder lo WITH (UPDLOCK) ON lo.LabOrderId = li.LabOrderId
        JOIN dbo.IpdAdmission a ON a.AdmissionId = lo.AdmissionId
        WHERE li.LabOrderItemId = @LabOrderItemId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @order IS NULL THROW 55022, 'The test was not found on an admission of this branch.', 1;
        IF @active = 0 THROW 55023, 'The test is already cancelled.', 1;
        IF @bill IS NOT NULL OR @open = 0 THROW 55024, 'The final bill is made: cancel the bill first.', 1;
        DECLARE @st TABLE (Collected INT, Entered INT);
        INSERT @st SELECT ISNULL(Collected, 0), ISNULL(Entered, 0) FROM dbo.fn_Ipd_LabItemStatus(@LabOrderItemId);
        IF EXISTS (SELECT 1 FROM @st WHERE Collected > 0 OR Entered > 0)
            THROW 55025, 'The sample is already collected or the result entered: the test cannot be cancelled (ask the LAB to reject it).', 1;
        -- the item, its sample rows, the order totals and the LAB settlement header
        UPDATE dbo.LabOrderItem SET IsActive = 0 WHERE LabOrderItemId = @LabOrderItemId;
        UPDATE sc SET Iscancelled = 1, Is_Active = 0, ModifiedBy = @UserId, ModifiedDate = @now
        FROM dbo.SampleCollection sc JOIN dbo.LabOrderItem li ON li.LabOrderItemId = @LabOrderItemId
        WHERE sc.Laborderid = @order AND ISNULL(sc.Iscancelled, 0) = 0
          AND ((li.[Type] = 'P' AND sc.PackageId = li.InvestigationId)
            OR (li.[Type] <> 'P' AND sc.PackageId IS NULL AND (sc.ProfileId IN (SELECT Profile_ID FROM dbo.LabInvestigationProfileHeader WHERE Test_ID = li.InvestigationId)
                                                           OR (sc.ProfileId IS NULL AND sc.InvestigationID = li.InvestigationId))));
        DECLARE @left DECIMAL(18,2) = (SELECT ISNULL(SUM(Price), 0) FROM dbo.LabOrderItem WHERE LabOrderId = @order AND IsActive = 1);
        UPDATE dbo.LabOrder SET TotalAmount = @left, IsActive = CASE WHEN @left > 0 OR EXISTS (SELECT 1 FROM dbo.LabOrderItem WHERE LabOrderId = @order AND IsActive = 1) THEN 1 ELSE 0 END,
               ModifiedBy = @UserId, ModifiedDate = @now WHERE LabOrderId = @order;
        UPDATE dbo.PaymentHeader SET SubTotal = @left, NetAmount = @left, IsActive = CASE WHEN @left > 0 THEN 1 ELSE 0 END, LastModifiedBy = @UserId, LastModifiedDate = @now
        WHERE ModuleCode = 'LAB' AND ModuleRefId = @order;
        -- the IP bill charge
        UPDATE dbo.IpdCharge SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now
        WHERE AdmissionId = @adm AND SourceModule = 'LAB' AND SourceId = @LabOrderItemId AND Status = 'POSTED';
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'LAB_CANCEL', LEFT(CONCAT(N'LAB test cancelled on ', @no, N' (₹', FORMAT(@price, 'N2', 'en-IN'), N'): ', LTRIM(RTRIM(@Reason))), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 7. IPD Patient screen controls ──────────────────────────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'LabItems,LabOrders', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdLab', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'LAB_ORDER', @Title = N'Order LAB / radiology tests (charged to the IP bill)', @Sort_Order = 86, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdLab', @Action = N'Order', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = 'LAB_CANCEL', @Title = N'Cancel a LAB / radiology test not yet collected', @Sort_Order = 87, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdLab', @Action = N'CancelItem', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2436 IPD LAB integration - done.';
GO
