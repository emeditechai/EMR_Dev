-- ============================================================================
-- Migration: 2118_lab_bill_cancellation_validation.sql
-- Description:
--   LAB Bill Cancellation (BillCancellation/Index?moduleCode=LAB) follows the lab's progress on each test:
--
--     Not collected / re-collect pending / rejected      -> may be cancelled
--     Sample collected (no result) / draft result        -> may be cancelled once the user confirms the sample /
--                                                           draft is discarded (@AcknowledgeLabWarnings = 1)
--     Result submitted / validated / report approved     -> BLOCKED; the lab withdraws the result first
--                                                           (reject the sample on Report Entry; Un-Authorize an
--                                                           approved report first)
--   A package / profile line takes the most advanced state among its tests.
--
--   On cancellation the line's samples are marked SampleCollection.Iscancelled = 1 (they leave every lab worklist,
--   the report and the report email) and any draft result is set inactive. OPD cancellation is unchanged.
--
--   Objects:
--     dbo.ufn_LabOrderItemSamples        bill line -> its samples (same expansion as usp_CreateSampleCollectionFromLabOrder)
--     dbo.ufn_LabOrderItemCancelState    per bill line: test counts by lab state + CancelStage (ALLOWED / WARN / BLOCKED)
--     dbo.usp_Bill_GetDetailForCancellation  (live definition + state columns on the LAB line result set)
--     dbo.usp_Bill_Cancel                    (live definition + LAB validation + sample / draft clean-up)
--     dbo.usp_LabReporting_GetDetail         (live definition + excludes cancelled samples)
--   Backfill: samples of LAB lines cancelled before this change (no result beyond draft) are marked cancelled.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Package line (Type P): the samples of that package. Profile line (Type I, profile test): the profile's samples
-- outside any package. Single test line: the standalone sample of that test.
CREATE OR ALTER FUNCTION dbo.ufn_LabOrderItemSamples (@LabOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT loi.LabOrderItemId, sc.samplecollectionID AS SampleCollectionId
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = loi.LabOrderId
    WHERE loi.LabOrderId = @LabOrderId
      AND (
            (loi.Type = 'P' AND sc.PackageId = loi.InvestigationId)
         OR (ISNULL(loi.Type, 'I') <> 'P' AND sc.PackageId IS NULL AND sc.ProfileId IS NOT NULL
             AND sc.ProfileId IN (SELECT h.Profile_ID
                                    FROM dbo.LabInvestigationProfileHeader h
                                    LEFT JOIN dbo.LabInvestigationMaster t ON t.Test_ID = loi.InvestigationId
                                   WHERE h.IsDeleted = 0
                                     AND (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name)))
         OR (ISNULL(loi.Type, 'I') <> 'P' AND sc.PackageId IS NULL AND sc.ProfileId IS NULL
             AND sc.InvestigationID = loi.InvestigationId)
      );
GO

CREATE OR ALTER FUNCTION dbo.ufn_LabOrderItemCancelState (@LabOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT
        loi.LabOrderItemId,
        COUNT(x.SampleCollectionId)                                   AS TestCount,
        SUM(CASE WHEN x.LabState = 'NOTCOLLECTED' THEN 1 ELSE 0 END)  AS NotCollectedCount,
        SUM(CASE WHEN x.LabState = 'REJECTED'     THEN 1 ELSE 0 END)  AS RejectedCount,
        SUM(CASE WHEN x.LabState = 'COLLECTED'    THEN 1 ELSE 0 END)  AS CollectedCount,
        SUM(CASE WHEN x.LabState = 'DRAFT'        THEN 1 ELSE 0 END)  AS DraftCount,
        SUM(CASE WHEN x.LabState = 'SUBMITTED'    THEN 1 ELSE 0 END)  AS SubmittedCount,
        SUM(CASE WHEN x.LabState = 'VALIDATED'    THEN 1 ELSE 0 END)  AS ValidatedCount,
        SUM(CASE WHEN x.LabState = 'APPROVED'     THEN 1 ELSE 0 END)  AS ApprovedCount,
        SUM(CASE WHEN x.IsTransferred = 1 THEN 1 ELSE 0 END)          AS TransferredCount,
        SUM(CASE WHEN x.IsoutSource = 1 THEN 1 ELSE 0 END)            AS OutsourcedCount,
        CASE WHEN SUM(CASE WHEN x.LabState IN ('SUBMITTED', 'VALIDATED', 'APPROVED') THEN 1 ELSE 0 END) > 0 THEN 'BLOCKED'
             WHEN SUM(CASE WHEN x.LabState IN ('COLLECTED', 'DRAFT') THEN 1 ELSE 0 END) > 0 THEN 'WARN'
             ELSE 'ALLOWED' END                                       AS CancelStage
    FROM dbo.LabOrderItem loi
    LEFT JOIN (
        SELECT m.LabOrderItemId, m.SampleCollectionId,
               CAST(ISNULL(sc.IsTransferred, 0) AS INT) AS IsTransferred,
               CAST(ISNULL(sc.IsoutSource, 0) AS INT)   AS IsoutSource,
               CASE WHEN sc.CollectionstatusID = 4 THEN 'REJECTED'
                    WHEN ISNULL(sc.CollectionstatusID, 1) IN (1, 3) THEN 'NOTCOLLECTED'
                    WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'COLLECTED'
                    WHEN led.ReportStatusId = 5 THEN 'APPROVED'
                    WHEN led.ReportStatusId = 3 THEN 'VALIDATED'
                    WHEN led.ReportStatusId = 2 THEN 'SUBMITTED'
                    ELSE 'DRAFT' END AS LabState
        FROM dbo.ufn_LabOrderItemSamples(@LabOrderId) m
        INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = m.SampleCollectionId
        LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
        WHERE sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
    ) x ON x.LabOrderItemId = loi.LabOrderItemId
    WHERE loi.LabOrderId = @LabOrderId
    GROUP BY loi.LabOrderItemId;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            lo.LabOrderId        AS ModuleRefId,
            'LAB'                AS ModuleCode,
            lo.BillNo,
            lo.OrderDate         AS BillDate,
            lo.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            ISNULL(pkg.Profile_Name, lm.Test_Name) AS ItemName,
            ISNULL(pkg.Profile_Code, lm.Test_Code) AS ItemCode,
            loi.Price            AS OriginalAmount,
            ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)    AS DiscountAmount,
            loi.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN loi.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lst.Sample_Name END AS SampleTypeName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
            CASE WHEN loi.Type = 'P' THEN 'Package' ELSE lc.Category_Name END AS CategoryName,
            -- Lab progress of this line's tests: decides whether it may be cancelled (dbo.ufn_LabOrderItemCancelState)
            ISNULL(cs.TestCount, 0)          AS TestCount,
            ISNULL(cs.NotCollectedCount, 0)  AS NotCollectedCount,
            ISNULL(cs.RejectedCount, 0)      AS RejectedCount,
            ISNULL(cs.CollectedCount, 0)     AS CollectedCount,
            ISNULL(cs.DraftCount, 0)         AS DraftCount,
            ISNULL(cs.SubmittedCount, 0)     AS SubmittedCount,
            ISNULL(cs.ValidatedCount, 0)     AS ValidatedCount,
            ISNULL(cs.ApprovedCount, 0)      AS ApprovedCount,
            ISNULL(cs.TransferredCount, 0)   AS TransferredCount,
            ISNULL(cs.OutsourcedCount, 0)    AS OutsourcedCount,
            CASE WHEN loi.IsActive = 0 THEN 'CANCELLED' ELSE ISNULL(cs.CancelStage, 'ALLOWED') END AS CancelStage
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
        LEFT JOIN dbo.LabSampleTypeMaster lst ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc ON lc.Category_ID = lm.Category_ID
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
            AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
            AND pli.IsActive = 1
        LEFT JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
        WHERE loi.LabOrderId = @ModuleRefId
        ORDER BY loi.LabOrderItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            os.OPDServiceId         AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            os.OPDBillNo            AS BillNo,
            os.VisitDate            AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            ISNULL(pli.NetLineAmount, si.ServiceCharges) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)           AS DiscountAmount,
            si.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN si.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            NULL AS SampleTypeName,
            NULL AS DepartmentName,
            NULL AS CategoryName
        FROM dbo.PatientOPDServiceItem si
        LEFT JOIN dbo.ServiceMaster sm    ON sm.ServiceId = si.ServiceId
        LEFT JOIN dbo.PaymentHeader ph     ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli  ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                           AND pli.ModuleLineRefId = si.ItemId 
                                           AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT,
    @AcknowledgeLabWarnings BIT = 0      -- LAB: user confirmed that collected samples / draft results will be discarded
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate cancellation number
        EXEC dbo.usp_Bill_GetNextCancellationNo @ModuleCode, @BranchId, @CancellationNo OUTPUT;

        -- Parse line items from JSON
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2));
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- LAB: a test whose result is already submitted / validated / approved cannot be cancelled from billing;
        -- the lab has to withdraw the result first (reject the sample on Report Entry, or Un-Authorize an approved report).
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @LabMsg NVARCHAR(2048);

            SELECT @LabMsg = STRING_AGG(CAST(
                       ISNULL(pkg.Profile_Name, lm.Test_Name) + ' ('
                       + CASE WHEN cs.ApprovedCount > 0 THEN 'report approved'
                              WHEN cs.ValidatedCount > 0 THEN 'result validated'
                              ELSE 'result submitted' END + ')' AS NVARCHAR(MAX)), '; ')
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId
            INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
            WHERE cs.CancelStage = 'BLOCKED';

            IF @LabMsg IS NOT NULL
            BEGIN
                SET @LabMsg = LEFT(N'Cannot cancel: ' + @LabMsg
                    + N'. The lab must first withdraw the result (reject the sample on Report Entry; an approved report has to be Un-Authorized first).', 2048);
                THROW 50003, @LabMsg, 1;
            END

            IF ISNULL(@AcknowledgeLabWarnings, 0) = 0
               AND EXISTS (SELECT 1 FROM @Items i
                           INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = i.LineRefId
                           WHERE cs.CancelStage = 'WARN')
                THROW 50004, 'Some selected tests already have a collected sample or a draft result. Confirm that they will be discarded to continue.', 1;
        END

        -- Validate: check items are not already cancelled
        IF EXISTS (
            SELECT 1 FROM @Items i
            INNER JOIN dbo.BillCancellationItem bci ON bci.LineRefId = i.LineRefId
            INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
            WHERE bc.ModuleCode = @ModuleCode AND bc.IsActive = 1
        )
            THROW 50002, 'One or more selected items are already cancelled.', 1;

        DECLARE @CancelledAmount DECIMAL(10,2) = (SELECT SUM(Amount) FROM @Items);

        -- Determine full or partial
        DECLARE @TotalBillItems INT;
        DECLARE @CancellationType CHAR(1);

        IF @ModuleCode = 'LAB'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.LabOrderItem 
            WHERE LabOrderId = @ModuleRefId AND IsActive = 1;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.PatientOPDServiceItem 
            WHERE OPDServiceId = @ModuleRefId AND IsActive = 1;
        END

        SET @CancellationType = CASE WHEN @TotalItems >= @TotalBillItems THEN 'F' ELSE 'P' END;

        -- Insert BillCancellation header
        INSERT INTO dbo.BillCancellation 
            (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate,
             CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@ModuleCode, @ModuleRefId, @CancellationNo, @CancellationType, GETDATE(),
             @CancelledAmount, ISNULL(@DiscountAdjusted, 0), @Reason, 'C', @UserId, GETDATE(), 1);

        SET @CancellationId = SCOPE_IDENTITY();

        -- Insert BillCancellationItem rows
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1
        FROM @Items;

        -- Mark items as inactive in source table
        IF @ModuleCode = 'LAB'
        BEGIN
            -- the samples of the cancelled lines leave every lab worklist, and a draft result is discarded
            DECLARE @CancelledSamples TABLE (SampleCollectionId BIGINT PRIMARY KEY);
            INSERT INTO @CancelledSamples (SampleCollectionId)
            SELECT DISTINCT m.SampleCollectionId
            FROM dbo.ufn_LabOrderItemSamples(@ModuleRefId) m
            WHERE m.LabOrderItemId IN (SELECT LineRefId FROM @Items);

            UPDATE led SET led.IsActive = 0, led.ModifiedBy = @UserId, led.ModifiedDate = GETDATE()
            FROM dbo.labentrydetails led
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = led.SamplecollectionID
            WHERE led.IsActive = 1;

            UPDATE sc SET sc.Iscancelled = 1, sc.ModifiedBy = @UserId, sc.ModifiedDate = GETDATE()
            FROM dbo.SampleCollection sc
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = sc.samplecollectionID;

            UPDATE dbo.LabOrderItem 
            SET IsActive = 0
            WHERE LabOrderItemId IN (SELECT LineRefId FROM @Items);
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                RoundOffAmount       = 0,
                LineDiscountTotal    = 0,
                LastModifiedDate     = GETDATE(),
                LastModifiedBy       = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END
        ELSE
        BEGIN
            -- Partial cancellation: reduce NetAmount by (CancelledAmount - DiscountAdjusted)
            UPDATE dbo.PaymentHeader
            SET NetAmount    = CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0 ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END,
                BalanceDue   = CASE 
                                 WHEN (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 
                                 THEN 0 
                                 ELSE (BalanceDue - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0)))
                               END,
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) < 0 THEN 0 ELSE (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- If full cancellation, mark LabOrder/OPDService as inactive
        IF @CancellationType = 'F'
        BEGIN
            IF @ModuleCode = 'LAB'
                UPDATE dbo.LabOrder SET IsActive = 0 WHERE LabOrderId = @ModuleRefId;
            IF @ModuleCode = 'OPD'
                UPDATE dbo.PatientOPDService SET IsActive = 0 WHERE OPDServiceId = @ModuleRefId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT,
    @BranchId   INT = NULL      -- NULL = every sample of the order (print / dispatch); otherwise only this branch's samples
AS
BEGIN
    SET NOCOUNT ON;

    -- Which samples belong to @BranchId (same rule as dbo.usp_LabReporting_GetHeaderList):
    --   * a sample that was never transferred belongs to the branch that booked it (sc.BranchID)
    --   * a transferred sample belongs to the TARGET branch, and only once it has been received
    --   * once the TARGET branch approves it, it also comes back to the SOURCE branch - read-only there
    --     (IsReadOnlyForBranch = 1), so the booking branch can see the result and print the report
    -- so a partially transferred order shows only its own tests on each branch's Report Entry screen.

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;
    DECLARE @IsReceived BIT = 0;
    DECLARE @ReceivedDate DATETIME = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks,
        @IsReceived = ISNULL(sc.IsReceived, 0),
        @ReceivedDate = sc.ReceivedDate
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1
      AND (@BranchId IS NULL
           OR (sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1));

    -- Patient Demographic variables for reference range and delta check matching
    DECLARE @PatientId INT = NULL;
    DECLARE @PatientGender VARCHAR(20) = NULL;
    DECLARE @PatientAge DECIMAL(6,2) = NULL;
    DECLARE @CompanyId INT = 1;

    SELECT 
        @PatientId = lo.PatientId,
        @PatientGender = p.Gender,
        @CompanyId = ISNULL(bm.CompanyId, 1),
        @PatientAge = CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    WHERE lo.LabOrderId = @LabOrderId;

    -- Compute Overall Order Status based on entered test results
    DECLARE @OverallStatusId INT = 0;
    DECLARE @OverallStatusCode VARCHAR(30) = 'PENDING';
    DECLARE @OverallStatusName NVARCHAR(100) = 'Pending Entry';
    DECLARE @OverallBadgeClass NVARCHAR(200) = 'bg-secondary-subtle text-secondary border border-secondary-subtle';
    DECLARE @DraftedDate DATETIME = NULL;
    DECLARE @SubmittedDate DATETIME = NULL;
    DECLARE @ValidatedDate DATETIME = NULL;
    DECLARE @ApprovedDate DATETIME = NULL;

    DECLARE @TotalItems INT = 0;
    DECLARE @FilledItems INT = 0;
    DECLARE @MinStatusId INT = 0;
    DECLARE @MaxStatusId INT = 0;

    SELECT 
        @TotalItems = COUNT(*),
        @FilledItems = COUNT(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0     -- a test cancelled from the bill is no longer reported
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)));

    -- Compute Overall Order Status based on entered test results
    -- Supports partial reporting: overall status reflects the status of entered collected tests
    IF @FilledItems > 0
    BEGIN
        SET @OverallStatusId = @MaxStatusId;
    END
    ELSE
    BEGIN
        SET @OverallStatusId = 0; -- Pending Entry
    END

    IF @OverallStatusId > 0
    BEGIN
        SELECT 
            @OverallStatusCode = StatusCode,
            @OverallStatusName = StatusName,
            @OverallBadgeClass = BadgeClass
        FROM dbo.Reportentrystatus
        WHERE ReportStatusId = @OverallStatusId;
    END

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        @PatientAge AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks,
        ISNULL(@IsReceived, 0) AS IsReceived,
        @ReceivedDate AS ReceivedDate,
        -- Overall Report Status Information
        @OverallStatusId AS ReportStatusId,
        @OverallStatusCode AS StatusCode,
        @OverallStatusName AS ReportStatusName,
        @OverallBadgeClass AS ReportBadgeClass,
        @DraftedDate AS DraftedDate,
        @SubmittedDate AS SubmittedDate,
        @ValidatedDate AS ValidatedDate,
        @ApprovedDate AS ApprovedDate
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Investigation Items for this Order (Collected, Re-Collect, Rejected)
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        -- Test Method Name
        COALESCE(NULLIF(m_ref.Method_Name, ''), NULLIF(m_inv.Method_Name, ''), '') AS MethodName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        -- Unit Name / Symbol from LabReferenceRangeMaster.Unit_ID (with lim.Unit_ID fallback)
        COALESCE(NULLIF(ref.UnitSymbol, ''), NULLIF(u_inv.Unit_Symbol, ''), u_inv.Unit_Name, '') AS UnitName,
        COALESCE(led.Reporting_Type, lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        -- Sample Status metadata
        ISNULL(sc.CollectionstatusID, 2) AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected') AS SampleCollectionStatus,
        ISNULL(scs.StatusCode, 'COLLECTED') AS SampleCollectionStatusCode,
        sc.RejectionReasonId,
        sc.RejectionReason,
        led.LabEntryDetailId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN NULL ELSE led.TestValue END AS TestValue,
        -- Pre-populate Remarks from LabReferenceRangeMaster.Special_Remarks if empty
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,

        -- Header/Group-level Lab Remarks
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        -- Critical / Panic tier: a result beyond Low_Threshold / High_Threshold is flagged 'Critical' / 'Panic'
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Tier END AS RangeTier,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Low_Threshold END AS LowThreshold,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.High_Threshold END AS HighThreshold,
        CASE 
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NOT NULL AND ref.Low_Value > 0 THEN
                CONCAT(
                    CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)), 
                    ' — ', 
                    CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30))
                )
            WHEN ref.Low_Value = 0 AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NULL AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NULL THEN
                CONCAT('> ', CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)))
            ELSE '—'
        END AS ReferenceRange,
        -- Flag: Saved AbnormalFlag, or dynamically evaluated
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN NULL
            ELSE COALESCE(led.AbnormalFlag, 
                CASE 
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Tier IN ('Critical Value', 'Panic Value')
                         AND ((ref.Low_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Threshold)
                           OR (ref.High_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Threshold))
                         THEN CASE ref.Tier WHEN 'Panic Value' THEN 'Panic' ELSE 'Critical' END
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                    ELSE NULL
                END
            )
        END AS AbnormalFlag,
        -- TAT
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        -- Prior Result for Delta Check
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty TestValue or Rejected/Re-collected items
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 0
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        -- 1 = this branch only transferred the sample out; the result was produced and approved elsewhere,
        --     so the Report Entry screen shows it but must not let this branch change anything on it.
        CAST(CASE WHEN @BranchId IS NOT NULL
                   AND sc.IsTransferred = 1
                   AND sc.SourceBranchID = @BranchId
                   AND ISNULL(sc.TargetBranchID, 0) <> @BranchId
                  THEN 1 ELSE 0 END AS BIT) AS IsReadOnlyForBranch,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks,
        ISNULL(sc.IsReceived, 0)    AS IsReceived,
        sc.ReceivedDate,
        sc.ReceiveRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabTestMethodMaster m_inv ON m_inv.Method_ID = lim.Method_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u_inv ON u_inv.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID

    -- Join Group-level remarks if saved
    LEFT JOIN dbo.LabReportTestRemarks rem_prof ON rem_prof.LabOrderId = sc.Laborderid 
                                               AND rem_prof.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20))
                                               AND sc.ProfileId IS NOT NULL
                                               AND rem_prof.IsActive = 1
    LEFT JOIN dbo.LabReportTestRemarks rem_inv ON rem_inv.LabOrderId = sc.Laborderid 
                                              AND rem_inv.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20))
                                              AND rem_inv.IsActive = 1

    -- Match best Reference Range for patient's Gender & Age
    OUTER APPLY (
        SELECT TOP 1 
            r.RefRange_ID,
            r.Method_ID AS RefMethodId,
            r.Unit_ID,
            r.Low_Value,
            r.High_Value,
            r.Special_Remarks,
            r.Tier,
            r.Low_Threshold,
            r.High_Threshold,
            r.Age_From,
            r.Age_To,
            r.Gender AS RangeGender,
            u.Unit_Name,
            COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS UnitSymbol
        FROM dbo.LabReferenceRangeMaster r
        LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = r.Unit_ID
        WHERE r.Test_ID = sc.InvestigationID
          AND r.IsDeleted = 0
          AND r.Status = 1
          AND (r.CompanyId = @CompanyId OR r.CompanyId = 1)
          AND r.Effective_From <= CAST(GETDATE() AS DATE)
          AND (r.Effective_To IS NULL OR r.Effective_To >= CAST(GETDATE() AS DATE))
          AND (
              (@PatientAge IS NULL)
              OR (r.Age_Unit = 'Years' AND @PatientAge >= r.Age_From AND @PatientAge <= r.Age_To)
              OR (r.Age_Unit = 'Months' AND (@PatientAge * 12.0) >= r.Age_From AND (@PatientAge * 12.0) <= r.Age_To)
              OR (r.Age_Unit = 'Days' AND (@PatientAge * 365.25) >= r.Age_From AND (@PatientAge * 365.25) <= r.Age_To)
              OR r.Is_Common_For_All = 1
          )
          AND (
              r.Is_Common_For_All = 1
              OR r.Gender = 'All'
              OR LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, ''))
          )
        ORDER BY 
          CASE WHEN LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, '')) THEN 1 ELSE 2 END ASC,
          CASE WHEN r.Is_Common_For_All = 0 THEN 1 ELSE 2 END ASC,
          r.RefRange_ID DESC
    ) ref
    LEFT JOIN dbo.LabTestMethodMaster m_ref ON m_ref.Method_ID = ref.RefMethodId

    -- Previous Historical Result for Delta Check
    OUTER APPLY (
        SELECT TOP 1 
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = @PatientId
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev

    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0     -- a test cancelled from the bill is no longer reported
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)))
    ORDER BY sc.samplecollectionID ASC;

    -- RS 3: Header-Level Lab Remarks
    SELECT 
        GroupKey,
        HeaderName,
        ProfileId,
        InvestigationId,
        LabRemarks
    FROM dbo.LabReportTestRemarks
    WHERE LabOrderId = @LabOrderId AND IsActive = 1;
END;
GO

-- Backfill: lines cancelled before this change left their samples active in the lab worklists.
-- Only samples without a result beyond draft are touched.
DECLARE @Backfilled INT;
;WITH cancelledLines AS (
    SELECT loi.LabOrderId, loi.LabOrderItemId
    FROM dbo.LabOrderItem loi
    WHERE loi.IsActive = 0
      AND EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                  INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                  WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
)
UPDATE sc SET sc.Iscancelled = 1, sc.ModifiedDate = GETDATE()
FROM cancelledLines cl
CROSS APPLY dbo.ufn_LabOrderItemSamples(cl.LabOrderId) m
INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = m.SampleCollectionId
WHERE m.LabOrderItemId = cl.LabOrderItemId
  AND ISNULL(sc.Iscancelled, 0) = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.labentrydetails led
                  WHERE led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                    AND ISNULL(led.ReportStatusId, 0) >= 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '');
SET @Backfilled = @@ROWCOUNT;
PRINT CONCAT('Backfill: ', @Backfilled, ' sample(s) of previously cancelled lines marked cancelled.');
GO

PRINT 'LAB bill cancellation validation ready.';
GO
