-- ============================================================================================================
-- 2382  Bill change approval as an optional parameter (Hospital Settings > LAB), per company, default Yes.
--   BillChangeApprovalRequired  Yes = every request from the phlebotomist app waits on LAB > Bill Change Approval.
--                               No  = a test change is applied to the bill as soon as it is raised, and a payment
--                                     mode or patient details request is recorded as approved. A discount still
--                                     waits for the office: the app sends no amount, and it gives money away.
-- usp_Phlebo_BillChange_Create now also refuses a test that is already on the bill, and returns the balance due
-- and any amount to refund. Requests already waiting when the switch is turned off stay on the approval page.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'BillChangeApprovalRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD BillChangeApprovalRequired BIT NOT NULL CONSTRAINT DF_HS_BillChangeApprovalRequired DEFAULT (1);
GO

-- description (picked up by the data dictionary)
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.HospitalSettings') AND name = 'MS_Description'
                  AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.HospitalSettings'), 'BillChangeApprovalRequired', 'ColumnId'))
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
         @value = N'1 = bill changes from the phlebotomist app wait for office approval. 0 = test changes apply at once; discounts still wait. Saved for all branches of the company.',
         @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'HospitalSettings',
         @level2type = N'COLUMN', @level2name = N'BillChangeApprovalRequired';
GO

CREATE OR ALTER PROCEDURE dbo.usp_Phlebo_BillChange_Create
    @UserId        INT,
    @VisitId       INT,
    @ClientEventId NVARCHAR(64),
    @RequestType   VARCHAR(20),
    @Reason        NVARCHAR(300),
    @Details       NVARCHAR(500) = NULL,
    @LinesJson     NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id INT = (SELECT BillChangeId FROM dbo.LabBillChangeRequest WHERE ClientEventId = @ClientEventId);
    IF @Id IS NOT NULL GOTO Result;

    IF @RequestType NOT IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST', 'DISCOUNT', 'PAYMENT_MODE', 'PATIENT_DETAILS')
    BEGIN RAISERROR('Unknown request type.', 16, 1); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN RAISERROR('Give a reason.', 16, 1); RETURN; END

    DECLARE @Order INT, @Branch INT, @Company INT, @Cur VARCHAR(15);
    SELECT @Order = LabOrderId, @Branch = BranchId, @Company = CompanyId, @Cur = Status
      FROM dbo.LabHomeVisit WHERE VisitId = @VisitId AND PhlebotomistId = @UserId;
    IF @Order IS NULL BEGIN RAISERROR('This visit is not assigned to you.', 16, 1); RETURN; END
    IF @Cur NOT IN ('REACHED', 'IN_PROGRESS') BEGIN RAISERROR('A bill change can be raised only at the patient''s address, before samples are collected.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @Order AND ISNULL(IsB2B, 0) = 1)
    BEGIN RAISERROR('This bill belongs to a partner account and cannot be changed in the field.', 16, 1); RETURN; END

    DECLARE @Lines TABLE (LineAction VARCHAR(10), InvestigationId INT, Price DECIMAL(12, 2));
    INSERT @Lines (LineAction, InvestigationId)
    SELECT UPPER(j.action), j.investigationId
      FROM OPENJSON(ISNULL(@LinesJson, N'[]')) WITH (action VARCHAR(10) '$.action', investigationId INT '$.investigationId') j;

    IF @RequestType IN ('ADD_TEST', 'REMOVE_TEST', 'REPLACE_TEST') AND NOT EXISTS (SELECT 1 FROM @Lines)
    BEGIN RAISERROR('Choose the tests.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Lines WHERE LineAction NOT IN ('ADD', 'REMOVE') OR InvestigationId IS NULL)
    BEGIN RAISERROR('A test line is not valid.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Lines l JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
                WHERE l.LineAction = 'ADD')
    BEGIN RAISERROR('This test is already on the bill.', 16, 1); RETURN; END

    UPDATE l SET Price = r.Rate
      FROM @Lines l
     CROSS APPLY (SELECT TOP 1 d.Rate FROM dbo.LabRateCardDetail d JOIN dbo.LabRateCardMaster m ON m.RateCard_ID = d.RateCard_ID
                   WHERE m.Branch_ID = @Branch AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0 AND d.Status = 1 AND d.IsDeleted = 0
                     AND d.Item_Type = 'Test' AND d.Item_ID = l.InvestigationId
                   ORDER BY m.Effective_From DESC) r
     WHERE l.LineAction = 'ADD';
    UPDATE l SET Price = i.Price
      FROM @Lines l JOIN dbo.LabOrderItem i ON i.LabOrderId = @Order AND i.InvestigationId = l.InvestigationId AND i.IsActive = 1
     WHERE l.LineAction = 'REMOVE';

    IF EXISTS (SELECT 1 FROM @Lines WHERE Price IS NULL)
    BEGIN RAISERROR('A test has no rate at this branch, or is not on this bill.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @Lines l JOIN dbo.SampleCollection sc ON sc.Laborderid = @Order AND sc.InvestigationID = l.InvestigationId AND sc.CollectionstatusID = 2
                WHERE l.LineAction = 'REMOVE')
    BEGIN RAISERROR('A collected test cannot be removed in the field.', 16, 1); RETURN; END

    DECLARE @Old DECIMAL(12, 2) = dbo.ufn_Phlebo_BillAmount(@Order);
    DECLARE @New DECIMAL(12, 2) = @Old + ISNULL((SELECT SUM(CASE WHEN LineAction = 'ADD' THEN Price ELSE -Price END) FROM @Lines), 0);
    DECLARE @ApprovalRequired BIT = ISNULL((SELECT TOP 1 BillChangeApprovalRequired FROM dbo.HospitalSettings WHERE BranchId = @Branch AND IsActive = 1), 1);

    BEGIN TRY
        BEGIN TRANSACTION;
            INSERT dbo.LabBillChangeRequest (CompanyId, BranchId, LabOrderId, VisitId, RequestType, Reason, Details, OldTotal, NewTotal, ClientEventId, RequestedBy)
            VALUES (@Company, @Branch, @Order, @VisitId, @RequestType, @Reason, @Details, @Old, @New, @ClientEventId, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT dbo.LabBillChangeLine (BillChangeId, LineAction, InvestigationId, Price)
            SELECT @Id, LineAction, InvestigationId, Price FROM @Lines;

            -- approval off: decided here, so a failure leaves no request behind and the phlebotomist sees why
            IF @ApprovalRequired = 0 AND @RequestType <> 'DISCOUNT'
                EXEC dbo.usp_Lab_BillChange_Decide @BillChangeId = @Id, @BranchId = @Branch, @UserId = @UserId, @Action = 'APPROVE',
                     @Remarks = N'Automatic: approval is off in Hospital Settings.';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

Result:
    -- the last result set is the one to read: an automatic decision returns others before it
    SELECT r.BillChangeId, r.Status, r.OldTotal, r.NewTotal, ph.BalanceDue,
           CASE WHEN ph.TotalPaid > ph.NetAmount THEN ph.TotalPaid - ph.NetAmount ELSE 0 END AS Refundable
      FROM dbo.LabBillChangeRequest r
      LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = r.LabOrderId AND ph.IsActive = 1
     WHERE r.BillChangeId = @Id;
END
GO
