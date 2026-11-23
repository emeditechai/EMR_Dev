-- ============================================================================================================
-- 2381  LAB > Bill Change Approval: the office decides the phlebotomist's bill change requests. Run after 2373, 2374. Re-runnable.
--   Page LAB.BILLCHANGEAPPROVAL (LAB menu). No role is granted here: give it from Settings > Security.
--   Added tests are billed at the rate saved on the request, with their samples and barcodes; removed tests go through
--   usp_Bill_Cancel, so the receipt, refund and ledger follow an ordinary partial cancellation.
--   A discount is the amount the approver enters, up to the balance due. Payment mode and patient details are recorded as
--   approved only: the office makes that change on its usual screen.
--   Samples cannot be saved in the app while a request on the visit is waiting.
-- ============================================================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_BillChange_List
    @BranchId INT,
    @Status   VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 200 r.BillChangeId, r.RequestType, r.Reason, r.Details, r.OldTotal, r.NewTotal, r.Status, r.RequestedDate, r.ActionedDate, r.ActionRemarks,
           o.BillNo, v.Status AS VisitStatus, ph.NetAmount, ph.TotalPaid, ph.BalanceDue,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName, p.PhoneNumber,
           COALESCE(u.FullName, u.Username) AS RequestedByName, COALESCE(a.FullName, a.Username) AS ActionedByName,
           (SELECT STRING_AGG(CONCAT(CASE l.LineAction WHEN 'ADD' THEN N'Add ' ELSE N'Remove ' END, t.Test_Name, N' (Rs ', FORMAT(l.Price, 'N2'), N')'), N'; ')
              FROM dbo.LabBillChangeLine l JOIN dbo.LabInvestigationMaster t ON t.Test_ID = l.InvestigationId
             WHERE l.BillChangeId = r.BillChangeId) AS Lines
      FROM dbo.LabBillChangeRequest r
      JOIN dbo.LabOrder o ON o.LabOrderId = r.LabOrderId
      JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
      JOIN dbo.Users u ON u.Id = r.RequestedBy
      LEFT JOIN dbo.Users a ON a.Id = r.ActionedBy
      LEFT JOIN dbo.LabHomeVisit v ON v.VisitId = r.VisitId
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = r.LabOrderId AND ph.IsActive = 1
     WHERE r.BranchId = @BranchId AND (@Status IS NULL OR r.Status = @Status)
     ORDER BY CASE WHEN r.Status = 'PENDING' THEN 0 ELSE 1 END, r.BillChangeId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_BillChange_Decide
    @BillChangeId   INT,
    @BranchId       INT,
    @UserId         INT,
    @Action         VARCHAR(10),   -- APPROVE / REFUSE
    @Remarks        NVARCHAR(300) = NULL,
    @DiscountAmount DECIMAL(12, 2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(10), @Type VARCHAR(20), @Order INT, @Visit INT, @Company INT;
    SELECT @Status = Status, @Type = RequestType, @Order = LabOrderId, @Visit = VisitId, @Company = CompanyId
      FROM dbo.LabBillChangeRequest WITH (UPDLOCK) WHERE BillChangeId = @BillChangeId AND BranchId = @BranchId;

    IF @Status IS NULL BEGIN RAISERROR('This request is not of your branch.', 16, 1); RETURN; END
    IF @Status <> 'PENDING' BEGIN RAISERROR('This request has already been decided.', 16, 1); RETURN; END
    IF @Action NOT IN ('APPROVE', 'REFUSE') BEGIN RAISERROR('Choose approve or refuse.', 16, 1); RETURN; END
    IF @Action = 'REFUSE' AND NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    DECLARE @EventId NVARCHAR(64) = CONCAT('WEB-', NEWID()), @NewStatus VARCHAR(10), @Header INT;

    IF @Action = 'REFUSE'
    BEGIN
        BEGIN TRANSACTION;
            UPDATE dbo.LabBillChangeRequest
               SET Status = 'REFUSED', NewTotal = OldTotal, ActionedBy = @UserId, ActionedDate = GETDATE(), ActionRemarks = @Remarks
             WHERE BillChangeId = @BillChangeId;
            IF @Visit IS NOT NULL
                INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy) VALUES (@Visit, 'BILL_REFUSED', @EventId, @Remarks, @UserId);
        COMMIT;
    END
    ELSE
    BEGIN
        DECLARE @IsTests BIT = CASE WHEN @Type IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST') THEN 1 ELSE 0 END;
        DECLARE @VisitStatus VARCHAR(15) = (SELECT Status FROM dbo.LabHomeVisit WHERE VisitId = @Visit);
        IF @IsTests = 1 AND ISNULL(@VisitStatus, '') NOT IN ('REACHED', 'IN_PROGRESS')
        BEGIN RAISERROR('The phlebotomist has left this stage of the visit. Refuse this request.', 16, 1); RETURN; END

        SELECT @Header = PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @Order AND ISNULL(IsActive, 0) = 1;
        IF @Header IS NULL AND @Type IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST', 'DISCOUNT')
        BEGIN RAISERROR('This bill has no payment record yet. Open it on the bill page first.', 16, 1); RETURN; END

        IF @Type = 'DISCOUNT' AND (@DiscountAmount IS NULL OR @DiscountAmount <= 0)
        BEGIN RAISERROR('Enter the discount amount.', 16, 1); RETURN; END
        IF @Type = 'DISCOUNT' AND @DiscountAmount > (SELECT BalanceDue FROM dbo.PaymentHeader WHERE PaymentHeaderId = @Header)
        BEGIN RAISERROR('The discount cannot be more than the balance due.', 16, 1); RETURN; END

        DECLARE @Remove TABLE (ItemId INT PRIMARY KEY, Price DECIMAL(12, 2));
        INSERT @Remove
        SELECT DISTINCT i.LabOrderItemId, i.Price
          FROM dbo.LabBillChangeLine l
          JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
         WHERE l.BillChangeId = @BillChangeId AND l.LineAction = 'REMOVE';
        IF EXISTS (SELECT 1 FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'REMOVE')
           AND NOT EXISTS (SELECT 1 FROM @Remove)
        BEGIN RAISERROR('The test is no longer on this bill. Refuse this request.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM @Remove)
           AND NOT EXISTS (SELECT 1 FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'ADD')
           AND NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem i WHERE i.LabOrderId = @Order AND i.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM @Remove x WHERE x.ItemId = i.LabOrderItemId))
        BEGIN RAISERROR('This removes every test. Use Bill Cancellation for the whole bill.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.LabBillChangeLine l JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
                    WHERE l.BillChangeId = @BillChangeId AND l.LineAction = 'ADD')
        BEGIN RAISERROR('A test in this request is already on the bill. Refuse this request.', 16, 1); RETURN; END

        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @Rev INT = ISNULL((SELECT MAX(RevisionNo) FROM dbo.LabBillRevision WHERE LabOrderId = @Order), 0) + 1;
            IF @IsTests = 1 OR @Type = 'DISCOUNT'
                INSERT dbo.LabBillRevision (LabOrderId, RevisionNo, BillChangeId, Snapshot, AppliedBy)
                SELECT @Order, @Rev, @BillChangeId,
                       (SELECT ph.SubTotal, ph.HeaderDiscountAmount, ph.NetAmount, ph.TotalPaid, ph.BalanceDue, o.TotalAmount,
                               (SELECT i.LabOrderItemId, i.InvestigationId, i.Type, i.Price FROM dbo.LabOrderItem i
                                 WHERE i.LabOrderId = @Order AND i.IsActive = 1 FOR JSON PATH) AS Items
                          FROM dbo.PaymentHeader ph JOIN dbo.LabOrder o ON o.LabOrderId = ph.ModuleRefId
                         WHERE ph.PaymentHeaderId = @Header FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                       @UserId;

            -- removed tests: an ordinary partial cancellation, with the same discount share as the Bill Cancellation page
            IF EXISTS (SELECT 1 FROM @Remove)
            BEGIN
                DECLARE @Sub DECIMAL(18, 2) = (SELECT SUM(Price) FROM @Remove), @Disc DECIMAL(18, 2), @BillDisc DECIMAL(18, 2), @BillSub DECIMAL(18, 2);
                SELECT @BillDisc = ISNULL(LineDiscountTotal, 0) + ISNULL(HeaderDiscountAmount, 0), @BillSub = ISNULL(SubTotal, 0)
                  FROM dbo.PaymentHeader WHERE PaymentHeaderId = @Header;
                SET @Disc = ISNULL((SELECT SUM(pli.LineDiscountAmount) FROM dbo.PaymentLineItem pli JOIN @Remove x ON x.ItemId = pli.ModuleLineRefId
                                     WHERE pli.PaymentHeaderId = @Header AND pli.IsActive = 1), 0);
                IF @Disc = 0 AND @BillSub > 0 SET @Disc = ROUND(@Sub / @BillSub * @BillDisc, 2);
                IF @Disc > @BillDisc SET @Disc = @BillDisc;

                DECLARE @Json NVARCHAR(MAX) = (SELECT ItemId AS lineRefId, Price AS amount FROM @Remove FOR JSON PATH),
                        @Why NVARCHAR(500) = CONCAT(N'Home collection bill change #', @BillChangeId), @CancelId INT, @CancelNo NVARCHAR(50);
                EXEC dbo.usp_Bill_Cancel @ModuleCode = 'LAB', @ModuleRefId = @Order, @BranchId = @BranchId, @LineItemsJson = @Json, @Reason = @Why,
                     @DiscountAdjusted = @Disc, @UserId = @UserId, @CancellationId = @CancelId OUTPUT, @CancellationNo = @CancelNo OUTPUT;
            END

            -- added tests
            DECLARE @Added DECIMAL(12, 2) = 0, @Test INT, @Price DECIMAL(12, 2), @Item INT;
            DECLARE @Patient INT, @Token NVARCHAR(50), @OrderDate DATE, @Booking DATETIME, @Urgent BIT;
            SELECT @Patient = PatientId, @Token = TokenNo, @OrderDate = CAST(OrderDate AS DATE), @Booking = ISNULL(BookingDate, OrderDate), @Urgent = ISNULL(IsUrgent, 0)
              FROM dbo.LabOrder WHERE LabOrderId = @Order;
            DECLARE @New TABLE (Id BIGINT PRIMARY KEY);

            DECLARE ac CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT InvestigationId, Price FROM dbo.LabBillChangeLine WHERE BillChangeId = @BillChangeId AND LineAction = 'ADD';
            OPEN ac; FETCH NEXT FROM ac INTO @Test, @Price;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT dbo.LabOrderItem (LabOrderId, InvestigationId, Price, IsActive, CreatedBy, CreatedDate, Type, IsUrgent)
                VALUES (@Order, @Test, @Price, 1, @UserId, GETDATE(), 'I', @Urgent);
                SET @Item = SCOPE_IDENTITY();

                INSERT dbo.PaymentLineItem (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType, OriginalAmount, LineDiscountType, LineDiscountValue,
                       LineDiscountAmount, NetLineAmount, CreatedDate, CreatedBy, IsActive, IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount, CompanyId, MembershipDiscountAmount)
                SELECT @Header, @Item, t.Test_Name, 'Test', @Price, 'P', 0, 0, @Price, GETDATE(), @UserId, 1, 0, 0, 0, 0, 0, @Company, 0
                  FROM dbo.LabInvestigationMaster t WHERE t.Test_ID = @Test;

                -- a profile test brings its member tests; a single test brings itself (as usp_CreateSampleCollectionFromLabOrder)
                INSERT dbo.SampleCollection (Laborderid, BranchID, CompanyID, PatientID, TokenNo, InvestigationID, DepartmentID, DepartmentD, TestcategoryID,
                       TestsubcategoryID, TestsubcategotyID, Orderdate, Bookingdatetime, Is_Active, Samplecollectiondate, Samplecollectiontime, Iscancelled, CreatedBy,
                       CreatedDate, ProfilePackageName, ProfileId, ProfileName, CollectionstatusID, BarcodeNo, IsoutSource)
                OUTPUT inserted.samplecollectionID INTO @New (Id)
                SELECT @Order, @BranchId, @Company, @Patient, @Token, x.TestId, x.Dept, x.Dept, x.Cat, x.SubCat, x.SubCat, @OrderDate, @Booking, 1,
                       CASE WHEN x.NeedsSample = 0 THEN @OrderDate END, CASE WHEN x.NeedsSample = 0 THEN CAST(@Booking AS TIME(0)) END, 0, @UserId,
                       GETDATE(), x.Label, x.ProfileId, x.ProfileName, CASE WHEN x.NeedsSample = 0 THEN 2 ELSE 1 END, NULL, x.Outsourced
                  FROM (
                        SELECT t.Test_ID AS TestId, COALESCE(pm.Department_ID, t.Department_ID) AS Dept, COALESCE(pm.Category_ID, t.Category_ID) AS Cat,
                               COALESCE(pm.SubCategory_ID, t.SubCategory_ID) AS SubCat, h.Profile_ID AS ProfileId, h.Profile_Name AS ProfileName, h.Profile_Name AS Label,
                               CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT) AS NeedsSample, CAST(ISNULL(t.Is_Outsourced, 0) AS BIT) AS Outsourced
                          FROM dbo.LabInvestigationMaster pm
                          JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = pm.Test_ID OR h.Profile_Name = pm.Test_Name) AND h.IsDeleted = 0
                          JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0
                          JOIN dbo.LabInvestigationMaster t ON t.Test_ID = d.Test_ID AND t.Status = 1 AND t.IsDeleted = 0
                          LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                         WHERE pm.Test_ID = @Test
                        UNION ALL
                        SELECT t.Test_ID, t.Department_ID, t.Category_ID, t.SubCategory_ID, NULL, NULL, N'—',
                               CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT), CAST(ISNULL(t.Is_Outsourced, 0) AS BIT)
                          FROM dbo.LabInvestigationMaster t
                          LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                         WHERE t.Test_ID = @Test
                           AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileHeader h WHERE (h.Test_ID = t.Test_ID OR h.Profile_Name = t.Test_Name) AND h.IsDeleted = 0)
                       ) x;

                SET @Added += @Price;
                FETCH NEXT FROM ac INTO @Test, @Price;
            END
            CLOSE ac; DEALLOCATE ac;

            IF EXISTS (SELECT 1 FROM dbo.HospitalSettings WHERE BranchId = @BranchId AND IsActive = 1 AND ISNULL(BarcodeGenerateAtBilling, 0) = 1)
            BEGIN
                DECLARE @Sc BIGINT, @Barcode NVARCHAR(50);
                DECLARE bc CURSOR LOCAL FAST_FORWARD FOR
                    SELECT sc.samplecollectionID FROM dbo.SampleCollection sc JOIN @New n ON n.Id = sc.samplecollectionID
                      LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = sc.TestcategoryID
                     WHERE ISNULL(cat.Is_Barcode_Required, 1) = 1 ORDER BY sc.samplecollectionID;
                OPEN bc; FETCH NEXT FROM bc INTO @Sc;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @Barcode = NULL;
                    EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @Sc, @BranchId = @BranchId, @Barcode = @Barcode OUTPUT;
                    UPDATE dbo.SampleCollection SET BarcodeNo = @Barcode WHERE samplecollectionID = @Sc AND BarcodeNo IS NULL;
                    FETCH NEXT FROM bc INTO @Sc;
                END
                CLOSE bc; DEALLOCATE bc;
            END

            IF @Added > 0
            BEGIN
                UPDATE dbo.LabOrder SET TotalAmount = TotalAmount + @Added, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE LabOrderId = @Order;
                UPDATE dbo.PaymentHeader
                   SET SubTotal = SubTotal + @Added, NetAmount = NetAmount + @Added,
                       BalanceDue = CASE WHEN NetAmount + @Added - TotalPaid > 0 THEN NetAmount + @Added - TotalPaid ELSE 0 END,
                       PaymentStatus = CASE WHEN TotalPaid >= NetAmount + @Added THEN 'P' WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                       LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
                 WHERE PaymentHeaderId = @Header;

                -- the added revenue, as another LAB_BILL entry: usp_Ledger_PostBillMoney adds them up
                DECLARE @Sales INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Sales'),
                        @Dr INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
                        @Cr INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'LAB Revenue'),
                        @BillNo NVARCHAR(60) = (SELECT BillNo FROM dbo.LabOrder WHERE LabOrderId = @Order), @Now DATETIME = GETDATE(), @Tx BIGINT;
                DECLARE @Narr NVARCHAR(300) = CONCAT(N'Tests added in the field, LAB Bill ', @BillNo);
                IF @Sales IS NOT NULL AND @Dr IS NOT NULL AND @Cr IS NOT NULL
                    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Sales, @TransactionDate = @Now, @ReferenceType = 'LAB_BILL', @ReferenceId = @Order,
                         @BranchId = @BranchId, @CompanyId = @Company, @TotalAmount = @Added, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
                         @CreatedBy = @UserId, @NewTransactionId = @Tx OUTPUT;
            END

            IF @Type = 'DISCOUNT'
                UPDATE dbo.PaymentHeader
                   SET HeaderDiscountType = 'D', HeaderDiscountValue = ISNULL(HeaderDiscountAmount, 0) + @DiscountAmount,
                       HeaderDiscountAmount = ISNULL(HeaderDiscountAmount, 0) + @DiscountAmount, NetAmount = NetAmount - @DiscountAmount,
                       BalanceDue = BalanceDue - @DiscountAmount, PaymentStatus = CASE WHEN TotalPaid >= NetAmount - @DiscountAmount THEN 'P' WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                       DiscountReason = LEFT((SELECT Reason FROM dbo.LabBillChangeRequest WHERE BillChangeId = @BillChangeId), 200), DiscountApprovedBy = @UserId, DiscountApprovedDate = GETDATE(),
                       LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
                 WHERE PaymentHeaderId = @Header;

            IF @Added > 0 OR @Type = 'DISCOUNT'
            BEGIN
                EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @Header, @UserId = @UserId;
                EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @Header, @UserId = @UserId;
            END

            SET @NewStatus = CASE WHEN @IsTests = 1 OR @Type = 'DISCOUNT' THEN 'APPLIED' ELSE 'APPROVED' END;
            UPDATE dbo.LabBillChangeRequest
               SET Status = @NewStatus, NewTotal = dbo.ufn_Phlebo_BillAmount(@Order), ActionedBy = @UserId, ActionedDate = GETDATE(), ActionRemarks = @Remarks
             WHERE BillChangeId = @BillChangeId;
            IF @Visit IS NOT NULL
                INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, Reason, CreatedBy) VALUES (@Visit, 'BILL_APPROVED', @EventId, @Remarks, @UserId);

            COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            THROW;
        END CATCH
    END

    SELECT r.Status, r.NewTotal, ph.BalanceDue,
           CASE WHEN ph.TotalPaid > ph.NetAmount THEN ph.TotalPaid - ph.NetAmount ELSE 0 END AS Refundable
      FROM dbo.LabBillChangeRequest r
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = r.LabOrderId AND ph.IsActive = 1
     WHERE r.BillChangeId = @BillChangeId;
END
GO

-- Samples stay open while a bill change on the visit is waiting. Otherwise as in 2374.
CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_Visit_Samples
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @TubesJson     NVARCHAR(MAX),
    @DeviceTime    DATETIME = NULL,
    @Latitude      DECIMAL(10, 8) = NULL,
    @Longitude     DECIMAL(11, 8) = NULL,
    @AccuracyM     DECIMAL(8, 2) = NULL,
    @IsMock        BIT = 0,
    @DueReason     NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ClientEventId)), N'') IS NULL BEGIN RAISERROR('ClientEventId is required.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabHomeVisitEvent WHERE ClientEventId = @ClientEventId)
    BEGIN
        SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
        RETURN;
    END

    DECLARE @Cur VARCHAR(15), @OrderId INT, @Lat DECIMAL(10, 8), @Lng DECIMAL(11, 8), @Company INT, @OtpOk DATETIME;
    SELECT @Cur = Status, @OrderId = LabOrderId, @Lat = Latitude, @Lng = Longitude, @Company = CompanyId, @OtpOk = OtpVerifiedOn
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Cur IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
    IF @Cur <> 'IN_PROGRESS' BEGIN RAISERROR('Begin the visit first.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabBillChangeRequest WHERE VisitId = @VisitId AND Status = 'PENDING')
    BEGIN RAISERROR('A bill change is waiting for approval. Ask the office to decide it first.', 16, 1); RETURN; END

    DECLARE @OtpReq BIT, @ArrRadius INT, @Outside VARCHAR(5);
    SELECT @OtpReq = OtpRequired, @ArrRadius = ArrivalRadiusM, @Outside = OutsideRadiusAction FROM dbo.PhleboSettings WHERE CompanyId = @Company;
    IF @OtpReq = 1 AND @OtpOk IS NULL BEGIN RAISERROR('Verify the patient first.', 16, 1); RETURN; END

    DECLARE @Dist FLOAT = dbo.ufn_Phlebo_DistanceM(@Latitude, @Longitude, @Lat, @Lng);
    IF @Outside = 'BLOCK' AND @Dist > @ArrRadius BEGIN RAISERROR('You are too far from the patient address.', 16, 1); RETURN; END

    DECLARE @Tubes TABLE (Id BIGINT PRIMARY KEY, Collected BIT, Barcode NVARCHAR(50), ReasonId INT, Remarks NVARCHAR(300));
    INSERT @Tubes
    SELECT j.id, ISNULL(j.collected, 0), NULLIF(LTRIM(RTRIM(j.barcode)), N''), j.reasonId, j.remarks
      FROM OPENJSON(@TubesJson) WITH (id BIGINT '$.sampleCollectionId', collected BIT '$.collected', barcode NVARCHAR(50) '$.barcode',
                                      reasonId INT '$.reasonId', remarks NVARCHAR(300) '$.remarks') j;

    -- every open tube of this booking must be answered, and only its own tubes
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE NOT EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.samplecollectionID = t.Id AND sc.Laborderid = @OrderId))
    BEGIN RAISERROR('A tube does not belong to this booking.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                 LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                 LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @OrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0 AND ISNULL(sc.CollectionstatusID, 1) IN (1, 3)
                  AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
                  AND NOT EXISTS (SELECT 1 FROM @Tubes t WHERE t.Id = sc.samplecollectionID))
    BEGIN RAISERROR('Scan every tube, or mark it as not collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t WHERE t.Collected = 0 AND t.ReasonId IS NULL)
    BEGIN RAISERROR('Choose a reason for every tube not collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Tubes t JOIN dbo.SampleCollection sc ON sc.BarcodeNo = t.Barcode AND sc.Laborderid <> @OrderId AND ISNULL(sc.Iscancelled, 0) = 0)
    BEGIN RAISERROR('A barcode is already used on another booking.', 16, 1); RETURN; END

    DECLARE @Due DECIMAL(12, 2) = (SELECT CASE WHEN ISNULL(o.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.BalanceDue, dbo.ufn_Phlebo_BillAmount(o.LabOrderId)) END
                                     FROM dbo.LabOrder o
                                     LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
                                    WHERE o.LabOrderId = @OrderId);
    IF @Due > 0 AND NULLIF(LTRIM(RTRIM(@DueReason)), N'') IS NULL
    BEGIN RAISERROR('Record the payment, or give a reason for leaving the amount due.', 16, 1); RETURN; END

    DECLARE @At DATETIME = CASE WHEN @DeviceTime IS NOT NULL AND @DeviceTime <= GETDATE() AND @DeviceTime >= DATEADD(DAY, -1, GETDATE()) THEN @DeviceTime ELSE GETDATE() END;
    DECLARE @ColDate DATE = CAST(@At AS DATE), @ColTime TIME(0) = CAST(@At AS TIME(0));
    DECLARE @Failed INT = (SELECT COUNT(*) FROM @Tubes WHERE Collected = 0);
    DECLARE @Sink TABLE (R INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE sc SET BarcodeNo = t.Barcode FROM dbo.SampleCollection sc JOIN @Tubes t ON t.Id = sc.samplecollectionID WHERE t.Collected = 1 AND t.Barcode IS NOT NULL;

        DECLARE @Id BIGINT, @Col BIT, @RId INT, @Rem NVARCHAR(300), @RText NVARCHAR(300);
        DECLARE tc CURSOR LOCAL FAST_FORWARD FOR SELECT Id, Collected, ReasonId, Remarks FROM @Tubes;
        OPEN tc; FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @Col = 1
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 2,
                     @SampleCollectionDate = @ColDate, @SampleCollectionTime = @ColTime, @UserId = @UserId;
            ELSE
            BEGIN
                INSERT @Sink EXEC dbo.usp_SampleCollection_UpdateStatus @SampleCollectionId = @Id, @CollectionstatusID = 3, @UserId = @UserId;
                SELECT @RText = Reason_Text FROM dbo.LabSampleRejectionReasonMaster WHERE Reason_ID = @RId;
                UPDATE dbo.SampleCollection SET RejectionReasonId = @RId, RejectionReason = LEFT(CONCAT(@RText, N' ', @Rem), 500) WHERE samplecollectionID = @Id;
            END
            FETCH NEXT FROM tc INTO @Id, @Col, @RId, @Rem;
        END
        CLOSE tc; DEALLOCATE tc;

        INSERT dbo.LabHomeVisitEvent (VisitId, Status, ClientEventId, DeviceTime, Latitude, Longitude, AccuracyM, IsMock, DistanceM, Reason, CreatedBy)
        VALUES (@VisitId, 'COLLECTED', @ClientEventId, @DeviceTime, @Latitude, @Longitude, @AccuracyM, @IsMock, @Dist, @DueReason, @UserId);

        UPDATE dbo.LabHomeVisit
           SET Status = 'COLLECTED', ModifiedDate = GETDATE(),
               NeedsReview = CASE WHEN @IsMock = 1 OR @Dist > @ArrRadius THEN 1 ELSE NeedsReview END
         WHERE VisitId = @VisitId;

        -- failed tubes go back out as a child visit, for the dispatcher to re-time
        IF @Failed > 0
            INSERT dbo.LabHomeVisit (CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, SlotAt, AddressSnapshot, Latitude, Longitude, ParentVisitId)
            SELECT CompanyId, BranchId, LabOrderId, PatientId, PhlebotomistId, DATEADD(DAY, 1, GETDATE()), AddressSnapshot, Latitude, Longitude, VisitId
              FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT VisitId, Status, NeedsReview FROM dbo.LabHomeVisit WHERE VisitId = @VisitId;
END
GO

-- ── page and endpoints ──────────────────────────────────────────────────────────────────────────────
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
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.BILLCHANGEAPPROVAL', @Title = N'Bill Change Approval',
             @Controller = N'LabBillChangeApproval', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 36, @Icon = N'bi bi-check2-square me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabBillChangeApproval', @Action = N'Index',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabBillChangeApproval', @Action = N'Requests', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabBillChangeApproval', @Action = N'Approve',  @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabBillChangeApproval', @Action = N'Refuse',   @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
