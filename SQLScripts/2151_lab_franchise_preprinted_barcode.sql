-- ============================================================================
-- Migration: 2151_lab_franchise_preprinted_barcode.sql
-- Description:
--   Pre-Printed Barcode mechanism for B2B Franchise billing (Master -> Lab
--   Master -> Franchise Barcode Assignment). A franchise flagged
--   LabFranchiseMaster.PreprintedBarcode = 1 ships pre-printed sticker rolls
--   to its own collection point; the code on that sticker has to be captured
--   on the Sample Collection page instead of the system auto-generating one.
--
--   New tables:
--     dbo.LabFranchiseBarcodeSeries   one row per allocation batch ("give me
--                                     500 codes"), immutable once generated.
--     dbo.LabFranchiseBarcodePool     one row per individual code - the full
--                                     audit ledger (Available/Used/Voided).
--
--   New column:
--     dbo.SampleCollection.RequiresManualBarcode  BIT, set by
--     usp_CreateSampleCollectionFromLabOrder (altered below) on the rows of
--     a Franchise order whose PreprintedBarcode = 1 - the one signal the
--     Sample Collection page needs to show a manual/scan entry instead of
--     the usual read-only system-barcode badge.
--
--   New procedures:
--     usp_Api_LabFranchiseBarcodeSeries_Generate   allocates a new series
--     usp_Api_LabFranchiseBarcodeSeries_GetList    series history for a franchise
--     usp_Api_LabFranchiseBarcodeSeries_Cancel     voids the remaining Available codes
--     usp_Lab_ValidateAndConsumeFranchiseBarcode   the one call Sample Collection
--                                                   saves against - checks the
--                                                   code, then atomically marks it
--                                                   Used and writes it onto every
--                                                   SampleCollection row of the
--                                                   same order + tube (profile-
--                                                   shared tests), so the existing
--                                                   usp_SampleCollection_UpdateStatus
--                                                   needs NO change at all: it
--                                                   already keeps a pre-existing
--                                                   BarcodeNo instead of generating
--                                                   a new one.
--     usp_Lab_GetFranchiseBarcodeStatus            read-only single-code lookup
--
--   Altered procedure:
--     usp_CreateSampleCollectionFromLabOrder - the existing "barcode generated
--     at billing" cursor (HospitalSettings.BarcodeGenerateAtBilling = 1) is
--     skipped for a Franchise order whose PreprintedBarcode = 1, so the field
--     is never pre-filled with a system code before Sample Collection even
--     opens. Every other branch of this procedure - B2C, Corporate, and any
--     Franchise with PreprintedBarcode = 0 (the default) - is untouched.
--
--   usp_SampleCollection_UpdateStatus, usp_SampleCollection_GetHeaderList and
--   usp_SampleCollection_GetDetail are NOT modified by this script - they
--   already treat a pre-existing SampleCollection.BarcodeNo as authoritative,
--   which is exactly what a validated pre-printed code becomes once written.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. New column: SampleCollection.RequiresManualBarcode ──────────────────
IF COL_LENGTH('dbo.SampleCollection', 'RequiresManualBarcode') IS NULL
    ALTER TABLE dbo.SampleCollection ADD RequiresManualBarcode BIT NOT NULL DEFAULT (0);
GO

-- ── 2. New table: dbo.LabFranchiseBarcodeSeries ─────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseBarcodeSeries' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseBarcodeSeries
    (
        SeriesId        INT IDENTITY(1,1) PRIMARY KEY,
        Franchise_ID    INT NOT NULL,
        BranchId        INT NOT NULL,
        SeriesCode      NVARCHAR(20) NOT NULL UNIQUE,
        FinancialYear   NVARCHAR(10) NOT NULL,
        StartNumber     INT NOT NULL,
        EndNumber       INT NOT NULL,
        Quantity        INT NOT NULL,
        Status          NVARCHAR(20) NOT NULL DEFAULT ('Active'), -- Active / Exhausted / Cancelled
        GeneratedDate   DATETIME2 NOT NULL DEFAULT (GETDATE()),
        GeneratedBy     INT NULL,
        CancelledDate   DATETIME2 NULL,
        CancelledBy     INT NULL,
        CancelReason    NVARCHAR(500) NULL,
        CompanyId       INT NOT NULL DEFAULT (1),
        IsDeleted       BIT NOT NULL DEFAULT (0),
        CONSTRAINT FK_LabFranchiseBarcodeSeries_Franchise FOREIGN KEY (Franchise_ID) REFERENCES dbo.LabFranchiseMaster(Franchise_ID),
        CONSTRAINT FK_LabFranchiseBarcodeSeries_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_LabFranchiseBarcodeSeries_Franchise ON dbo.LabFranchiseBarcodeSeries(Franchise_ID);
    PRINT 'Created table dbo.LabFranchiseBarcodeSeries';
END
GO

-- ── 3. New table: dbo.LabFranchiseBarcodePool ───────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabFranchiseBarcodePool' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabFranchiseBarcodePool
    (
        BarcodeId           BIGINT IDENTITY(1,1) PRIMARY KEY,
        SeriesId             INT NOT NULL,
        Franchise_ID         INT NOT NULL,
        BarcodeNo            NVARCHAR(50) NOT NULL UNIQUE,
        SequenceNo           INT NOT NULL,
        Status               TINYINT NOT NULL DEFAULT (1), -- 1 Available / 2 Used / 3 Voided
        LabOrderId           INT NULL,
        SamplecollectionID   BIGINT NULL,
        InvestigationId      INT NULL,
        UsedDate             DATETIME2 NULL,
        UsedBy               INT NULL,
        VoidedDate           DATETIME2 NULL,
        VoidedBy             INT NULL,
        VoidReason           NVARCHAR(500) NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT (GETDATE()),
        CONSTRAINT FK_LabFranchiseBarcodePool_Series FOREIGN KEY (SeriesId) REFERENCES dbo.LabFranchiseBarcodeSeries(SeriesId),
        CONSTRAINT FK_LabFranchiseBarcodePool_Franchise FOREIGN KEY (Franchise_ID) REFERENCES dbo.LabFranchiseMaster(Franchise_ID)
    );
    CREATE INDEX IX_LabFranchiseBarcodePool_Franchise_Status ON dbo.LabFranchiseBarcodePool(Franchise_ID, Status);
    CREATE INDEX IX_LabFranchiseBarcodePool_Series ON dbo.LabFranchiseBarcodePool(SeriesId);
    CREATE INDEX IX_LabFranchiseBarcodePool_LabOrder ON dbo.LabFranchiseBarcodePool(LabOrderId);
    PRINT 'Created table dbo.LabFranchiseBarcodePool';
END
GO

-- ============================================================================
-- usp_Api_LabFranchiseBarcodeSeries_Generate
--   Allocates a new, immutable block of codes to a franchise. The increment
--   continues across every series ever generated for that franchise (not per
--   financial year); the FY2 stamped into the code is simply "when this batch
--   was printed". Atomic: series header + every pool row in one transaction.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseBarcodeSeries_Generate
    @Franchise_ID INT,
    @Quantity     INT,
    @CreatedBy    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Franchise_ID IS NULL OR @Franchise_ID <= 0
    BEGIN
        RAISERROR('A valid Franchise is required.', 16, 1);
        RETURN;
    END

    IF @Quantity IS NULL OR @Quantity <= 0 OR @Quantity > 10000
    BEGIN
        RAISERROR('Quantity must be between 1 and 10000.', 16, 1);
        RETURN;
    END

    DECLARE @FranchiseCode NVARCHAR(50);
    DECLARE @CompanyId     INT;
    DECLARE @BranchId      INT;
    DECLARE @PreprintedBarcode BIT;

    SELECT
        @FranchiseCode = f.Franchise_Code,
        @CompanyId     = f.CompanyId,
        @BranchId      = f.Parent_Branch_ID,
        @PreprintedBarcode = f.PreprintedBarcode
    FROM dbo.LabFranchiseMaster f
    WHERE f.Franchise_ID = @Franchise_ID AND f.IsDeleted = 0;

    IF @FranchiseCode IS NULL
    BEGIN
        RAISERROR('Franchise not found.', 16, 1);
        RETURN;
    END

    IF @PreprintedBarcode <> 1
    BEGIN
        RAISERROR('This franchise is not flagged for Preprinted Barcode.', 16, 1);
        RETURN;
    END

    DECLARE @BranchCode NVARCHAR(20) = 'HO';
    SELECT @BranchCode = ISNULL(NULLIF(RTRIM(LTRIM(BranchCode)), ''), 'HO')
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    -- 2-digit financial year, same rule as dbo.usp_Lab_GetNextBarcodeNo (April-start FY)
    DECLARE @Today   DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear INT  = YEAR(@Today);
    DECLARE @Month   INT  = MONTH(@Today);
    DECLARE @FYStart INT  = CASE WHEN @Month >= 4 THEN @CalYear ELSE @CalYear - 1 END;
    DECLARE @FY2     NVARCHAR(10) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2);

    BEGIN TRANSACTION;

    BEGIN TRY
        -- The increment continues across every series this franchise has ever had.
        DECLARE @StartNumber INT;
        SELECT @StartNumber = ISNULL(MAX(EndNumber), 0) + 1
        FROM dbo.LabFranchiseBarcodeSeries WITH (UPDLOCK, HOLDLOCK)
        WHERE Franchise_ID = @Franchise_ID;

        DECLARE @EndNumber INT = @StartNumber + @Quantity - 1;

        -- Auto series code, same generator pattern as Franchise_Code (FRNxxxx)
        DECLARE @NextNum INT;
        DECLARE @SeriesCode NVARCHAR(20);
        SELECT @NextNum = ISNULL(MAX(SeriesId), 0) + 1 FROM dbo.LabFranchiseBarcodeSeries;
        SET @SeriesCode = 'BSR' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
        WHILE EXISTS (SELECT 1 FROM dbo.LabFranchiseBarcodeSeries WHERE SeriesCode = @SeriesCode)
        BEGIN
            SET @NextNum = @NextNum + 1;
            SET @SeriesCode = 'BSR' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
        END

        INSERT INTO dbo.LabFranchiseBarcodeSeries
            (Franchise_ID, BranchId, SeriesCode, FinancialYear, StartNumber, EndNumber, Quantity, Status, GeneratedBy, CompanyId)
        VALUES
            (@Franchise_ID, @BranchId, @SeriesCode, @FY2, @StartNumber, @EndNumber, @Quantity, 'Active', @CreatedBy, @CompanyId);

        DECLARE @SeriesId INT = SCOPE_IDENTITY();

        ;WITH Seq AS (
            SELECT TOP (@Quantity) @StartNumber - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects a1 CROSS JOIN sys.all_objects a2
        )
        INSERT INTO dbo.LabFranchiseBarcodePool (SeriesId, Franchise_ID, BarcodeNo, SequenceNo, Status)
        SELECT
            @SeriesId,
            @Franchise_ID,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(N AS NVARCHAR(10)), 6),
            N,
            1
        FROM Seq;

        COMMIT TRANSACTION;

        SELECT
            @SeriesId AS SeriesId,
            @SeriesCode AS SeriesCode,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(@StartNumber AS NVARCHAR(10)), 6) AS StartBarcode,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(@EndNumber AS NVARCHAR(10)), 6) AS EndBarcode,
            @Quantity AS Quantity;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ============================================================================
-- usp_Api_LabFranchiseBarcodeSeries_GetList
--   Series history for a franchise, with live Used/Available/Voided counts.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseBarcodeSeries_GetList
    @Franchise_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        s.SeriesId,
        s.SeriesCode,
        s.Franchise_ID,
        s.BranchId,
        b.BranchCode,
        s.FinancialYear,
        s.StartNumber,
        s.EndNumber,
        s.Quantity,
        s.Status,
        s.GeneratedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(gu.FullName)), ''), gu.Username) AS GeneratedByName,
        s.CancelledDate,
        ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CancelledByName,
        s.CancelReason,
        f.Franchise_Code,
        ISNULL(p.AvailableCount, 0) AS AvailableCount,
        ISNULL(p.UsedCount, 0)      AS UsedCount,
        ISNULL(p.VoidedCount, 0)    AS VoidedCount
    FROM dbo.LabFranchiseBarcodeSeries s
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = s.Franchise_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
    LEFT JOIN dbo.Users gu ON gu.Id = s.GeneratedBy
    LEFT JOIN dbo.Users cu ON cu.Id = s.CancelledBy
    OUTER APPLY (
        SELECT
            SUM(CASE WHEN bp.Status = 1 THEN 1 ELSE 0 END) AS AvailableCount,
            SUM(CASE WHEN bp.Status = 2 THEN 1 ELSE 0 END) AS UsedCount,
            SUM(CASE WHEN bp.Status = 3 THEN 1 ELSE 0 END) AS VoidedCount
        FROM dbo.LabFranchiseBarcodePool bp
        WHERE bp.SeriesId = s.SeriesId
    ) p
    WHERE s.Franchise_ID = @Franchise_ID AND s.IsDeleted = 0
    ORDER BY s.SeriesId DESC;
END
GO

-- ============================================================================
-- usp_Api_LabFranchiseBarcodeSeries_Cancel
--   Voids only the still-Available codes of a series. Used codes are never
--   touched, so the audit history stays intact.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseBarcodeSeries_Cancel
    @SeriesId INT,
    @Reason   NVARCHAR(500),
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @SeriesId IS NULL OR @SeriesId <= 0
    BEGIN
        RAISERROR('A valid Series is required.', 16, 1);
        RETURN;
    END

    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL
    BEGIN
        RAISERROR('A cancellation reason is required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseBarcodeSeries WHERE SeriesId = @SeriesId AND IsDeleted = 0)
    BEGIN
        RAISERROR('Series not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabFranchiseBarcodePool
    SET Status = 3, VoidedDate = GETDATE(), VoidedBy = @UserId, VoidReason = @Reason
    WHERE SeriesId = @SeriesId AND Status = 1;

    UPDATE dbo.LabFranchiseBarcodeSeries
    SET Status = 'Cancelled', CancelledDate = GETDATE(), CancelledBy = @UserId, CancelReason = @Reason
    WHERE SeriesId = @SeriesId;
END
GO

-- ============================================================================
-- usp_Lab_ValidateAndConsumeFranchiseBarcode
--   The one call the Sample Collection page saves against. Checks the code
--   (exists / right franchise / series not cancelled / Available), and only
--   if every check passes, in the SAME call: flips it to Used, stamps the
--   order/sample/test, AND writes the code onto SampleCollection.BarcodeNo -
--   for every SampleCollection row of this order sharing the same
--   Profile/Package as @SamplecollectionID (the existing shared-tube rule),
--   or just the one row for a standalone test. Because BarcodeNo is now set,
--   usp_SampleCollection_UpdateStatus (unmodified) already keeps it instead
--   of generating a system code - see its ISNULL(sc.BarcodeNo, @Generated...)
--   logic. Locked (UPDLOCK, ROWLOCK, HOLDLOCK), the same pattern already used
--   by usp_Lab_GetNextBarcodeNo, so two operators scanning the same sticker
--   at once can never both succeed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Lab_ValidateAndConsumeFranchiseBarcode
    @BarcodeNo          NVARCHAR(50),
    @Franchise_ID        INT,
    @LabOrderId          INT,
    @SamplecollectionID  BIGINT,
    @InvestigationId     INT = NULL,
    @UserId              INT = NULL,
    @Success             BIT OUTPUT,
    @ErrorMessage        NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Success = 0;
    SET @ErrorMessage = NULL;
    SET @BarcodeNo = LTRIM(RTRIM(ISNULL(@BarcodeNo, '')));

    IF @BarcodeNo = ''
    BEGIN
        SET @ErrorMessage = 'Please enter or scan a barcode.';
        RETURN;
    END

    IF @SamplecollectionID IS NULL OR @SamplecollectionID <= 0
    BEGIN
        SET @ErrorMessage = 'A valid sample is required.';
        RETURN;
    END

    BEGIN TRANSACTION;

    BEGIN TRY
        DECLARE @PoolFranchiseId INT, @PoolStatus TINYINT, @SeriesStatus NVARCHAR(20);
        DECLARE @UsedBillNo NVARCHAR(100), @UsedDate DATETIME2;

        SELECT
            @PoolFranchiseId = bp.Franchise_ID,
            @PoolStatus      = bp.Status,
            @SeriesStatus    = s.Status,
            @UsedDate        = bp.UsedDate
        FROM dbo.LabFranchiseBarcodePool bp WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
        INNER JOIN dbo.LabFranchiseBarcodeSeries s ON s.SeriesId = bp.SeriesId
        WHERE bp.BarcodeNo = @BarcodeNo;

        IF @PoolFranchiseId IS NULL
        BEGIN
            SET @ErrorMessage = 'Barcode not found.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @PoolFranchiseId <> @Franchise_ID
        BEGIN
            SET @ErrorMessage = 'This barcode belongs to a different franchise.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @SeriesStatus = 'Cancelled' OR @PoolStatus = 3
        BEGIN
            SET @ErrorMessage = 'This barcode''s series was cancelled.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF @PoolStatus = 2
        BEGIN
            SELECT @UsedBillNo = lo.BillNo FROM dbo.LabOrder lo
            INNER JOIN dbo.LabFranchiseBarcodePool bp ON bp.LabOrderId = lo.LabOrderId
            WHERE bp.BarcodeNo = @BarcodeNo;

            SET @ErrorMessage = 'Already used on Bill ' + ISNULL(@UsedBillNo, '(unknown)')
                + ', ' + CONVERT(NVARCHAR(20), @UsedDate, 106) + '.';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        -- All checks passed: mark Used and stamp what consumed it.
        UPDATE dbo.LabFranchiseBarcodePool
        SET Status = 2,
            LabOrderId = @LabOrderId,
            SamplecollectionID = @SamplecollectionID,
            InvestigationId = @InvestigationId,
            UsedDate = GETDATE(),
            UsedBy = @UserId
        WHERE BarcodeNo = @BarcodeNo;

        -- Write it onto SampleCollection.BarcodeNo - the row scanned, plus every sibling row of the
        -- same order sharing the same tube (Profile/Package), exactly like the system's own
        -- shared-tube barcodes already work. usp_SampleCollection_UpdateStatus needs no change: it
        -- already keeps a pre-existing BarcodeNo instead of generating a new one.
        DECLARE @ProfileId INT, @ProfileName NVARCHAR(200);
        SELECT @ProfileId = ProfileId, @ProfileName = ProfileName
        FROM dbo.SampleCollection WHERE samplecollectionID = @SamplecollectionID;

        UPDATE sc
        SET BarcodeNo = @BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.BarcodeNo IS NULL
          AND (
                sc.samplecollectionID = @SamplecollectionID
             OR (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
             OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );

        COMMIT TRANSACTION;
        SET @Success = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Success = 0;
        SET @ErrorMessage = 'Server error while validating the barcode. Please try again.';
    END CATCH
END
GO

-- ============================================================================
-- usp_Lab_GetFranchiseBarcodeStatus
--   Read-only single-code lookup (the list/history view, and a pre-flight
--   check before saving).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetFranchiseBarcodeStatus
    @BarcodeNo NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        bp.BarcodeId,
        bp.BarcodeNo,
        bp.Status,
        CASE bp.Status WHEN 1 THEN 'Available' WHEN 2 THEN 'Used' WHEN 3 THEN 'Voided' END AS StatusName,
        bp.Franchise_ID,
        f.Franchise_Code,
        f.Franchise_Name,
        bp.SeriesId,
        s.SeriesCode,
        s.Status AS SeriesStatus,
        bp.LabOrderId,
        lo.BillNo,
        bp.SamplecollectionID,
        bp.InvestigationId,
        lim.Test_Name,
        bp.UsedDate,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UsedByName
    FROM dbo.LabFranchiseBarcodePool bp
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = bp.Franchise_ID
    INNER JOIN dbo.LabFranchiseBarcodeSeries s ON s.SeriesId = bp.SeriesId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = bp.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = bp.InvestigationId
    LEFT JOIN dbo.Users u ON u.Id = bp.UsedBy
    WHERE bp.BarcodeNo = LTRIM(RTRIM(ISNULL(@BarcodeNo, '')));
END
GO

-- ============================================================================
-- usp_CreateSampleCollectionFromLabOrder (altered)
--   Adds the @SkipAutoBarcode gate for a Franchise order with
--   PreprintedBarcode = 1 (see the comment inline below). Every other line is
--   identical to the version in script 2133 - nothing else about how this
--   order's SampleCollection rows are built changes.
-- ============================================================================
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
        SET @CompanyId = 1;

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
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
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
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID,
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
        DECLARE @v_ProfileId INT, @v_ProfileName NVARCHAR(200), @v_SampleCollectionId BIGINT;
        DECLARE @GenBarcode NVARCHAR(50);

        -- Cursor to group by ProfileId/ProfileName or SampleCollectionId for standalones
        -- SKIPS any tests where category has Is_Barcode_Required = 0!
        DECLARE barcode_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.ProfileId, sc.ProfileName, MAX(sc.samplecollectionID)
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId 
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
        GROUP BY sc.ProfileId, sc.ProfileName, 
                 CASE WHEN sc.ProfileId IS NULL AND sc.ProfileName IS NULL THEN sc.samplecollectionID ELSE 0 END;

        OPEN barcode_cursor;
        FETCH NEXT FROM barcode_cursor INTO @v_ProfileId, @v_ProfileName, @v_SampleCollectionId;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GenBarcode OUTPUT;

            IF @v_ProfileId IS NOT NULL OR @v_ProfileName IS NOT NULL
            BEGIN
                UPDATE sc
                SET sc.BarcodeNo = @GenBarcode
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.Laborderid = @LabOrderId
                  AND (
                      (@v_ProfileId IS NOT NULL AND sc.ProfileId = @v_ProfileId)
                      OR (@v_ProfileId IS NULL AND @v_ProfileName IS NOT NULL AND sc.ProfileName = @v_ProfileName)
                  )
                  AND sc.BarcodeNo IS NULL
                  AND ISNULL(cat.Is_Barcode_Required, 1) = 1;
            END
            ELSE
            BEGIN
                UPDATE sc
                SET sc.BarcodeNo = @GenBarcode
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
                WHERE sc.samplecollectionID = @v_SampleCollectionId
                  AND sc.BarcodeNo IS NULL
                  AND ISNULL(cat.Is_Barcode_Required, 1) = 1;
            END

            FETCH NEXT FROM barcode_cursor INTO @v_ProfileId, @v_ProfileName, @v_SampleCollectionId;
        END

        CLOSE barcode_cursor;
        DEALLOCATE barcode_cursor;
    END
    -- ─────────────────────────────────────────────────────────────

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO

-- ─────────────────────────────────────────────────────────────────────────────

PRINT 'Script 2151 applied: Pre-Printed Barcode tables, procedures and usp_CreateSampleCollectionFromLabOrder guard created.';
GO
