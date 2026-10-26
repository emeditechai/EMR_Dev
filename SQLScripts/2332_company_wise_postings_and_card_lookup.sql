-- 2332 Company-wise postings and lookups (no more company 1 by default)
--   usp_Ledger_PostEntry: the voucher's company is the branch's company (callers passed 1).
--   usp_Membership_CardForPatient: a bill's patient finds only a card of its own company (was: any company, by phone).
--   usp_CreateSampleCollectionFromLabOrder, usp_Api_Patient_Create:
--     a missing company is the branch's company, not 1.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── voucher numbering for automatic postings ────────────────────────────────────────────────────────────────
-- Same parameters as before; the number now comes from Acc_VoucherSequence (shared with manual vouchers) and the
-- financial year is stamped. Period locks are not checked here: an automatic posting is never refused (billing goes on).
CREATE OR ALTER PROCEDURE dbo.usp_Ledger_PostEntry
    @VoucherTypeId INT,
    @TransactionDate DATETIME,
    @ReferenceType NVARCHAR(50),
    @ReferenceId INT,
    @BranchId INT,
    @CompanyId INT,
    @TotalAmount DECIMAL(18,2),
    @Narration NVARCHAR(MAX),
    @DebitLedgerId INT,
    @CreditLedgerId INT,
    @CreatedBy INT,
    @NewTransactionId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @co INT = ISNULL(@CompanyId, 1), @br INT = ISNULL(@BranchId, 0), @no INT;
    SELECT @co = CompanyId FROM dbo.BranchMaster WHERE BranchId = @br AND CompanyId IS NOT NULL;   -- 2332: the branch's company
    DECLARE @fyStart TINYINT = ISNULL((SELECT TOP 1 FinancialYearStartMonth FROM dbo.Acc_Settings WHERE CompanyId = @co), 4);
    DECLARE @fy VARCHAR(7) = dbo.fn_Acc_FinancialYear(ISNULL(@TransactionDate, GETDATE()), @fyStart);
    DECLARE @prefix NVARCHAR(10) = ISNULL((SELECT ISNULL(NULLIF(Prefix, ''), VoucherTypeCode) FROM dbo.Acc_VoucherType WHERE VoucherTypeId = @VoucherTypeId), N'VCH');
    DECLARE @branchCode NVARCHAR(20) = ISNULL((SELECT NULLIF(BranchCode, '') FROM dbo.Branchmaster WHERE BranchID = @br), CAST(@br AS NVARCHAR(10)));
    DECLARE @VoucherNo NVARCHAR(50);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Acc_VoucherSequence WITH (UPDLOCK, HOLDLOCK) SET @no = LastNo = LastNo + 1
        WHERE CompanyId = @co AND BranchId = @br AND VoucherTypeId = @VoucherTypeId AND FinancialYear = @fy;
        IF @@ROWCOUNT = 0
        BEGIN
            SET @no = 1;
            INSERT INTO dbo.Acc_VoucherSequence (CompanyId, BranchId, VoucherTypeId, FinancialYear, LastNo) VALUES (@co, @br, @VoucherTypeId, @fy, 1);
        END
        SET @VoucherNo = CONCAT(@prefix, '/', @branchCode, '/', @fy, '/', RIGHT('00000' + CAST(@no AS VARCHAR(10)), 5));

        INSERT INTO dbo.Acc_LedgerTransaction
            (VoucherTypeId, VoucherNo, TransactionDate, ReferenceType, ReferenceId, BranchId, CompanyId, TotalAmount, Narration, CreatedBy, CreatedDate,
             Status, IsManual, FinancialYear)
        VALUES
            (@VoucherTypeId, @VoucherNo, @TransactionDate, @ReferenceType, @ReferenceId, @BranchId, @co, @TotalAmount, @Narration, @CreatedBy, GETDATE(),
             'P', 0, @fy);

        SET @NewTransactionId = SCOPE_IDENTITY();

        INSERT INTO dbo.Acc_LedgerTransactionDetail (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @DebitLedgerId, @TotalAmount, 0, @Narration);

        INSERT INTO dbo.Acc_LedgerTransactionDetail (TransactionId, LedgerId, DebitAmount, CreditAmount, Narration)
        VALUES (@NewTransactionId, @CreditLedgerId, 0, @TotalAmount, @Narration);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── the card of a bill's patient: by patient, or by the bill patient's phone ─
CREATE OR ALTER PROCEDURE dbo.usp_Membership_CardForPatient
    @PatientId INT = NULL,
    @Phone     NVARCHAR(30) = NULL,
    @CompanyId INT = NULL,
    @CardId    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), '');
    IF @CompanyId IS NULL AND @PatientId IS NOT NULL   -- 2332: the patient's own company only
        SELECT @CompanyId = CompanyId FROM dbo.PatientMaster WHERE PatientId = @PatientId;
    IF @Phone IS NULL AND @PatientId IS NOT NULL
        SELECT @Phone = NULLIF(LTRIM(RTRIM(PhoneNumber)), '') FROM dbo.PatientMaster WHERE PatientId = @PatientId;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT TOP 1 @CardId = c.CardId
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId AND pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0
    INNER JOIN dbo.MembershipCardMember m ON m.CardId = c.CardId AND m.IsActive = 1
    INNER JOIN dbo.PatientMaster mp ON mp.PatientId = m.PatientId
    WHERE c.Status = 'Active' AND @Today BETWEEN c.ValidFrom AND c.ValidTo
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND ((@PatientId IS NOT NULL AND m.PatientId = @PatientId)
           OR (@Phone IS NOT NULL AND LTRIM(RTRIM(mp.PhoneNumber)) = @Phone))
    ORDER BY CASE WHEN m.PatientId = @PatientId THEN 0 ELSE 1 END, CASE WHEN m.IsPrimary = 1 THEN 0 ELSE 1 END, c.ValidTo DESC, c.CardId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateSampleCollectionFromLabOrder
    @LabOrderId INT,
    @BranchId   INT = NULL,
    @CompanyId  INT = NULL,
    @CreatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
        RETURN;

    -- Avoid duplicate sample collection creation for this order
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId)
    BEGIN
        SELECT COUNT(1) AS RowsCount FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId;
        RETURN;
    END

    DECLARE @PatientId       INT;
    DECLARE @TokenNo         NVARCHAR(50);
    DECLARE @OrderDate       DATE;
    DECLARE @BookingDateTime DATETIME;
    DECLARE @OrderBranch     INT;
    DECLARE @OrderCreatedBy  INT;
    DECLARE @OrderIsB2B      BIT;
    DECLARE @OrderAgentType  VARCHAR(10);
    DECLARE @OrderB2BAgentID INT;

    SELECT 
        @OrderBranch     = BranchId,
        @PatientId       = PatientId,
        @TokenNo         = TokenNo,
        @OrderDate       = CAST(OrderDate AS DATE),
        @BookingDateTime = ISNULL(BookingDate, OrderDate),
        @OrderCreatedBy  = CreatedBy,
        @OrderIsB2B      = IsB2B,
        @OrderAgentType  = AgentType,
        @OrderB2BAgentID = B2BAgentID
    FROM dbo.LabOrder
    WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
        RETURN;

    -- Pre-Printed Barcode (Franchise): when this B2B order's Franchise has PreprintedBarcode = 1,
    -- no system barcode is ever auto-generated for it - the franchise's own sticker, entered on the
    -- Sample Collection page, is validated against its pool and becomes the row's BarcodeNo instead
    -- (see dbo.usp_Lab_ValidateAndConsumeFranchiseBarcode). @SkipAutoBarcode only gates the
    -- barcode-AT-BILLING cursor below; it changes nothing for a B2C order or a Corporate order,
    -- and nothing for a Franchise whose own PreprintedBarcode flag is 0 (the default).
    DECLARE @SkipAutoBarcode BIT = 0;
    IF @OrderIsB2B = 1 AND @OrderAgentType = 'F' AND EXISTS (
        SELECT 1 FROM dbo.LabFranchiseMaster f
        WHERE f.Franchise_ID = @OrderB2BAgentID AND f.PreprintedBarcode = 1
    )
        SET @SkipAutoBarcode = 1;

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = @OrderBranch;

    IF @CompanyId IS NULL OR @CompanyId <= 0
        SET @CompanyId = ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1);   -- 2332

    IF @CreatedBy IS NULL OR @CreatedBy <= 0
        SET @CreatedBy = @OrderCreatedBy;

    -- Temporary table to hold expanded tests
    CREATE TABLE #TestsToInsert (
        InvestigationId    INT,
        DepartmentId       INT,
        CategoryId         INT,
        SubCategoryId      INT,
        SampleTypeId       INT,
        ProfileId          INT,
        ProfileName        NVARCHAR(200),
        PackageId          INT,
        PackageName        NVARCHAR(200),
        ProfilePackageName NVARCHAR(200),
        IsoutSource        BIT,
        IsSampleRequired   BIT,
        IsBarcodeRequired  BIT
    );

    -- 1A. Packages (Type = 'P'): Standalone tests directly under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        NULL,
        NULL,
        h.Profile_ID,
        h.Profile_Name,
        h.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
       AND t.Is_Profile_Test = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 1B. Packages (Type = 'P'): Tests under profiles that are under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        COALESCE(pt.Department_ID, t.Department_ID),   -- a profile's tests belong to the profile's department / category
        COALESCE(pt.Category_ID, t.Category_ID),
        COALESCE(pt.SubCategory_ID, t.SubCategory_ID),
        t.Sample_Type_ID,
        pheader.Profile_ID,
        pheader.Profile_Name,
        h.Profile_ID,
        h.Profile_Name,
        pheader.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail pd 
        ON pd.Profile_ID = h.Profile_ID 
       AND pd.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster pt 
        ON pt.Test_ID = pd.Test_ID AND pt.Is_Profile_Test = 1
    INNER JOIN dbo.LabInvestigationProfileHeader pheader 
        ON (pheader.Test_ID = pt.Test_ID OR pheader.Profile_Name = pt.Test_Name) AND pheader.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail child_d 
        ON child_d.Profile_ID = pheader.Profile_ID AND child_d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = child_d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 2. Profiles (Type = 'I' AND Is_Profile_Test = 1): Tests under regular profiles
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        COALESCE(pm.Department_ID, t.Department_ID),   -- a profile's tests belong to the profile's department / category
        COALESCE(pm.Category_ID, t.Category_ID),
        COALESCE(pm.SubCategory_ID, t.SubCategory_ID),
        t.Sample_Type_ID,
        h.Profile_ID,
        h.Profile_Name,
        NULL,
        NULL,
        h.Profile_Name,
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabInvestigationMaster pm 
        ON pm.Test_ID = h.Test_ID
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1;

    -- 3. Non-profile regular individual tests (Type = 'I' AND Is_Profile_Test = 0)
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId, SampleTypeId, ProfileId, ProfileName, PackageId, PackageName, ProfilePackageName, IsoutSource, IsSampleRequired, IsBarcodeRequired)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
        t.Sample_Type_ID,
        NULL,
        NULL,
        NULL,
        NULL,
        '—',
        CAST(ISNULL(t.Is_Outsourced, 0) AS BIT),
        CAST(ISNULL(cat.Is_Sample_Collection_Required, 1) AS BIT),
        CAST(ISNULL(cat.Is_Barcode_Required, 1) AS BIT)
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = loi.InvestigationId 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    LEFT JOIN dbo.LabTestCategoryMaster cat 
        ON cat.Category_ID = t.Category_ID
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

    -- Insert into SampleCollection table:
    -- If IsSampleRequired = 0: auto-mark CollectionstatusID = 2 (ready for report entry immediately)
    -- If IsSampleRequired = 1: CollectionstatusID = 1 (Pending sample collection)
    INSERT INTO dbo.SampleCollection (
        Laborderid,
        BranchID,
        CompanyID,
        PatientID,
        TokenNo,
        InvestigationID,
        DepartmentID,
        DepartmentD,
        TestcategoryID,
        TestsubcategoryID,
        TestsubcategotyID,
        Orderdate,
        Bookingdatetime,
        Is_Active,
        Samplecollectiondate,
        Samplecollectiontime,
        Iscancelled,
        CreatedBy,
        CreatedDate,
        ProfilePackageName,
        ProfileId,
        ProfileName,
        PackageId,
        PackageName,
        CollectionstatusID,
        BarcodeNo,
        IsoutSource
    )
    SELECT 
        @LabOrderId,
        @BranchId,
        @CompanyId,
        @PatientId,
        @TokenNo,
        ti.InvestigationId,
        ti.DepartmentId,
        ti.DepartmentId,
        ti.CategoryId,
        ti.SubCategoryId,
        ti.SubCategoryId,
        @OrderDate,
        @BookingDateTime,
        1,
        CASE WHEN ti.IsSampleRequired = 0 THEN @OrderDate ELSE NULL END,
        CASE WHEN ti.IsSampleRequired = 0 THEN CAST(@BookingDateTime AS TIME(0)) ELSE NULL END,
        0,
        @CreatedBy,
        GETDATE(),
        ti.ProfilePackageName,
        ti.ProfileId,
        ti.ProfileName,
        ti.PackageId,
        ti.PackageName,
        CASE WHEN ti.IsSampleRequired = 0 THEN 2 ELSE 1 END,
        NULL,
        ti.IsoutSource
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    -- Flags these rows for the Sample Collection page: show a manual/scan barcode entry
    -- instead of the usual read-only system-generated badge.
    IF @SkipAutoBarcode = 1
    BEGIN
        UPDATE dbo.SampleCollection
        SET RequiresManualBarcode = 1
        WHERE Laborderid = @LabOrderId;
    END

    -- ── CHECK FOR BARCODE GEN AT BILLING ────────────────────────────
    -- ONLY generate barcodes if HospitalSettings.BarcodeGenerateAtBilling = 1
    -- AND the test's category has Is_Barcode_Required = 1!
    DECLARE @BarcodeGenAtBilling BIT = 0;
    SELECT @BarcodeGenAtBilling = ISNULL(BarcodeGenerateAtBilling, 0)
    FROM dbo.HospitalSettings
    WHERE BranchId = @BranchId AND IsActive = 1;

    IF @BarcodeGenAtBilling = 1 AND @SkipAutoBarcode = 0
    BEGIN
        -- One barcode per tube (SQLScripts/2312): tests of this bill with the same Sample Name + Container Type share a
        -- barcode; a test without a sample type keeps the old rule (shared within its profile, else its own).
        -- SKIPS any tests where category has Is_Barcode_Required = 0!
        DECLARE @v_SampleCollectionId BIGINT, @GenBarcode NVARCHAR(50);
        DECLARE barcode_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
        ORDER BY sc.samplecollectionID;

        OPEN barcode_cursor;
        FETCH NEXT FROM barcode_cursor INTO @v_SampleCollectionId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @GenBarcode = NULL;
            EXEC dbo.usp_Lab_AssignTubeBarcode @SampleCollectionId = @v_SampleCollectionId, @BranchId = @BranchId, @Barcode = @GenBarcode OUTPUT;
            UPDATE dbo.SampleCollection SET BarcodeNo = @GenBarcode
             WHERE samplecollectionID = @v_SampleCollectionId AND BarcodeNo IS NULL;
            FETCH NEXT FROM barcode_cursor INTO @v_SampleCollectionId;
        END

        CLOSE barcode_cursor;
        DEALLOCATE barcode_cursor;
    END
    -- ─────────────────────────────────────────────────────────────

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO

-- 7. usp_Api_Patient_Create
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_Patient_Create]
    @CompanyId INT = 1,
    @PhoneNumber NVARCHAR(15),
    @SecondaryPhoneNumber NVARCHAR(15) = NULL,
    @Salutation NVARCHAR(10) = NULL,
    @FirstName NVARCHAR(100),
    @MiddleName NVARCHAR(100) = NULL,
    @LastName NVARCHAR(100),
    @Gender NVARCHAR(10),
    @DateOfBirth DATE = NULL,
    @EmailId NVARCHAR(150) = NULL,
    @GuardianName NVARCHAR(200) = NULL,
    @Address NVARCHAR(500) = NULL,
    @RelationId INT = NULL,
    @BloodGroup NVARCHAR(10) = NULL,
    @KnownAllergies NVARCHAR(500) = NULL,
    @Remarks NVARCHAR(1000) = NULL,
    @BranchId INT = NULL,
    @PhotoPath NVARCHAR(500) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (@CompanyId IS NULL OR @CompanyId = 0)
    BEGIN
        IF @BranchId IS NOT NULL
            SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId;
        IF (@CompanyId IS NULL) SET @CompanyId = ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1);   -- 2332
    END

    -- Generate Patient Code
    DECLARE @FY NVARCHAR(4) = CAST(YEAR(GETDATE()) AS NVARCHAR(4));
    DECLARE @NextSeq INT = 1;

    UPDATE PatientCodeCounter
    SET @NextSeq = LastSeq = LastSeq + 1
    WHERE BranchId = ISNULL(@BranchId, 1) AND FinancialYear = @FY;

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO PatientCodeCounter (CompanyId, BranchId, FinancialYear, LastSeq)
        VALUES (@CompanyId, ISNULL(@BranchId, 1), @FY, 1);
        SET @NextSeq = 1;
    END

    DECLARE @BranchCode NVARCHAR(10) = 'HO';
    IF @BranchId IS NOT NULL
        SELECT @BranchCode = BranchCode FROM Branchmaster WHERE BranchID = @BranchId;

    DECLARE @PatientCode NVARCHAR(30) = @BranchCode + '/' + @FY + '/' + RIGHT('00000' + CAST(@NextSeq AS NVARCHAR(10)), 5);

    INSERT INTO PatientMaster (
        CompanyId, PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
        FirstName, MiddleName, LastName, Gender, DateOfBirth,
        EmailId, GuardianName, Address, RelationId, BloodGroup,
        KnownAllergies, Remarks, BranchId, PhotoPath,
        IsActive, CreatedBy, CreatedDate
    ) VALUES (
        @CompanyId, @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
        @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth,
        @EmailId, @GuardianName, @Address, @RelationId, @BloodGroup,
        @KnownAllergies, @Remarks, @BranchId, @PhotoPath,
        1, @UserId, SYSUTCDATETIME()
    );

    SELECT SCOPE_IDENTITY() AS PatientId;
END
GO

PRINT 'Script 2332 applied: company-wise ledger postings and membership card lookup.';
GO
