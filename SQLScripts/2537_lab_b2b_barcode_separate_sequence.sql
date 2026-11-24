-- ============================================================================================================
-- Migration: 2537_lab_b2b_barcode_separate_sequence.sql
-- Hospital Settings > LAB "B2B Barcode Generate Separate Sequence Required" (B2BBarcodeSeparateSequence, 2536):
--   No  (default): sample barcodes exactly as before - <BranchCode><FY2><digits> from LabBarcodeSequence.
--   Yes: barcodes of B2B bills (franchise / company) are F-<BranchCode><FY2><6 digits>, e.g. F-HO26000001, from their
--        own sequence LabBarcodeSequenceB2B, per branch and financial year (restarts at 000001 every April).
-- Changes (altered from their live definitions; nothing else changed):
--   * LabBarcodeSequenceB2B (new table).
--   * usp_Lab_GetNextBarcodeNo: optional @LabOrderId (default NULL = the usual sequence, so every other caller is
--     unchanged); a B2B bill with the setting on takes the B2B sequence.
--   * usp_Lab_AssignTubeBarcode, usp_SampleCollection_GetDetail: pass their @LabOrderId.
--   Pre-printed franchise barcodes (LabFranchiseBarcodePool) are not affected.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.LabBarcodeSequenceB2B', 'U') IS NULL
    CREATE TABLE dbo.LabBarcodeSequenceB2B
    (
        BranchId      INT           NOT NULL,
        FinancialYear NVARCHAR(20)  NOT NULL,
        LastSeq       BIGINT        NOT NULL CONSTRAINT DF_LabBarcodeSequenceB2B_LastSeq DEFAULT (0),
        CompanyId     INT           NULL,
        CONSTRAINT PK_LabBarcodeSequenceB2B PRIMARY KEY (BranchId, FinancialYear)
    );
GO

-- ── 3. Stored Procedure: usp_Lab_GetNextBarcodeNo ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetNextBarcodeNo
    @BranchId    INT,
    @BarcodeNo   NVARCHAR(50) OUTPUT,
    @LabOrderId  INT = NULL          -- 2537: the bill the barcode is for; NULL = the usual sequence
AS
BEGIN
    SET NOCOUNT ON;

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = 1;

    DECLARE @CompanyId  INT = 1;
    DECLARE @BranchCode NVARCHAR(20) = 'HO';

    SELECT TOP 1 
        @BranchCode = ISNULL(NULLIF(RTRIM(LTRIM(BranchCode)), ''), 'HO'),
        @CompanyId  = ISNULL(CompanyId, 1)
    FROM dbo.Branchmaster 
    WHERE BranchId = @BranchId;

    -- Fetch config (branch override first, else global fallback where BranchId IS NULL)
    DECLARE @PrefixFormat NVARCHAR(50) = '<BranchCode><FY2>';
    DECLARE @DigitCount   INT = 6;
    DECLARE @ConfigFY     NVARCHAR(10) = NULL;

    SELECT TOP 1
        @PrefixFormat = ISNULL(PrefixFormat, '<BranchCode><FY2>'),
        @DigitCount   = ISNULL(DigitCount, 6),
        @ConfigFY     = NULLIF(RTRIM(LTRIM(CurrentFinancialYear)), '')
    FROM dbo.LabBarcodeConfig
    WHERE (BranchId = @BranchId OR BranchId IS NULL)
      AND IsActive = 1
    ORDER BY CASE WHEN BranchId = @BranchId THEN 0 ELSE 1 END;

    -- Determine 2-digit Financial Year (e.g. '26')
    DECLARE @FY2 NVARCHAR(10);
    IF @ConfigFY IS NOT NULL
    BEGIN
        SET @FY2 = @ConfigFY;
    END
    ELSE
    BEGIN
        DECLARE @Today   DATE = CAST(GETDATE() AS DATE);
        DECLARE @CalYear INT  = YEAR(@Today);
        DECLARE @Month   INT  = MONTH(@Today);
        -- Indian FY starts in April (Month >= 4):
        -- e.g. Sep 2026: FY 2026-2027 => start year is 2026 => '26'
        -- e.g. Feb 2026: FY 2025-2026 (2526) => user requirement: 'If 2526 then only show 26' => '26'
        DECLARE @FYStart INT = CASE WHEN @Month >= 4 THEN @CalYear ELSE @CalYear - 1 END;
        SET @FY2 = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2);
    END

    -- 2537: B2B bill + Hospital Settings "B2B Barcode Generate Separate Sequence Required" = Yes:
    --       F-<BranchCode><FY2><6 digits> from its own sequence per branch and financial year
    IF @LabOrderId IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND ISNULL(IsB2B, 0) = 1)
       AND (SELECT TOP 1 ISNULL(hs.B2BBarcodeSeparateSequence, 0) FROM dbo.HospitalSettings hs
            WHERE hs.BranchId = @BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) = 1
    BEGIN
        DECLARE @B2BSeq BIGINT = 0;
        UPDATE dbo.LabBarcodeSequenceB2B WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
        SET @B2BSeq = LastSeq = LastSeq + 1
        WHERE BranchId = @BranchId AND FinancialYear = @FY2;
        IF @@ROWCOUNT = 0
        BEGIN
            BEGIN TRY
                INSERT INTO dbo.LabBarcodeSequenceB2B (BranchId, FinancialYear, LastSeq, CompanyId)
                VALUES (@BranchId, @FY2, 1, @CompanyId);
                SET @B2BSeq = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() IN (2627, 2601)
                    UPDATE dbo.LabBarcodeSequenceB2B WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                    SET @B2BSeq = LastSeq = LastSeq + 1
                    WHERE BranchId = @BranchId AND FinancialYear = @FY2;
                ELSE THROW;
            END CATCH
        END
        SET @BarcodeNo = N'F-' + @BranchCode + @FY2 + RIGHT(REPLICATE('0', 6) + CAST(@B2BSeq AS NVARCHAR(20)), 6);
        RETURN;
    END

    -- Atomically increment sequence for (BranchId, FinancialYear)
    DECLARE @NewSeq BIGINT = 0;

    UPDATE dbo.LabBarcodeSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY2;

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.LabBarcodeSequence (BranchId, FinancialYear, LastSeq, CompanyId)
            VALUES (@BranchId, @FY2, 1, @CompanyId);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.LabBarcodeSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY2;
            END
            ELSE THROW;
        END CATCH
    END

    -- Format sequence number with padded digits
    DECLARE @SeqStr NVARCHAR(20) = RIGHT(REPLICATE('0', @DigitCount) + CAST(@NewSeq AS NVARCHAR(20)), @DigitCount);

    -- Format Prefix: replace <BranchCode> and <FY2> tokens
    DECLARE @Prefix NVARCHAR(50) = @PrefixFormat;
    SET @Prefix = REPLACE(@Prefix, '<BranchCode>', @BranchCode);
    SET @Prefix = REPLACE(@Prefix, '<FY2>', @FY2);
    SET @Prefix = REPLACE(@Prefix, '<FY>', @FY2);

    SET @BarcodeNo = @Prefix + @SeqStr;
END
GO

-- The barcode for one sample row: its own; else the barcode of a test of the same bill in the same tube (Sample Name +
-- Container Type); else - only when the test has no sample type - the old rule (its profile's barcode); else a new one.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_AssignTubeBarcode
    @SampleCollectionId BIGINT,
    @BranchId           INT,
    @Barcode            NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Barcode = NULL;

    DECLARE @LabOrderId INT, @ProfileId INT, @ProfileName NVARCHAR(200), @Own NVARCHAR(50), @Key NVARCHAR(400);
    SELECT @LabOrderId = sc.Laborderid, @ProfileId = sc.ProfileId, @ProfileName = sc.ProfileName, @Own = sc.BarcodeNo,
           @Key = dbo.ufn_Lab_SampleTubeKey(sc.InvestigationID)
      FROM dbo.SampleCollection sc
     WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL RETURN;
    IF NULLIF(LTRIM(RTRIM(@Own)), N'') IS NOT NULL BEGIN SET @Barcode = @Own; RETURN; END

    IF @Key IS NOT NULL
        SELECT TOP 1 @Barcode = o.BarcodeNo
          FROM dbo.SampleCollection o
         WHERE o.Laborderid = @LabOrderId
           AND o.samplecollectionID <> @SampleCollectionId
           AND NULLIF(LTRIM(RTRIM(o.BarcodeNo)), N'') IS NOT NULL
           AND ISNULL(o.Iscancelled, 0) = 0 AND ISNULL(o.Is_Active, 1) = 1
           AND dbo.ufn_Lab_SampleTubeKey(o.InvestigationID) = @Key
         ORDER BY o.samplecollectionID;
    ELSE IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        SELECT TOP 1 @Barcode = o.BarcodeNo
          FROM dbo.SampleCollection o
         WHERE o.Laborderid = @LabOrderId
           AND o.samplecollectionID <> @SampleCollectionId
           AND o.BarcodeNo IS NOT NULL
           AND ((@ProfileId IS NOT NULL AND o.ProfileId = @ProfileId)
             OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND o.ProfileName = @ProfileName))
         ORDER BY o.samplecollectionID;

    IF @Barcode IS NULL
        EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @Barcode OUTPUT, @LabOrderId = @LabOrderId;   -- 2537
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
        RETURN;

    -- Heal missing ProfileId / PackageId for legacy rows
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND (ProfileId IS NULL OR PackageId IS NULL))
    BEGIN
        UPDATE sc
        SET 
            sc.ProfileId   = h.Profile_ID,
            sc.ProfileName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
        INNER JOIN dbo.LabOrder lo2 ON lo2.LabOrderId = sc.Laborderid
        INNER JOIN dbo.Branchmaster bm2 ON bm2.BranchID = lo2.BranchId
        INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR (h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId) AND h.CompanyId = bm2.CompanyId))   -- 2455
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfileId IS NULL;

        UPDATE sc
        SET 
            sc.PackageId   = h.Profile_ID,
            sc.PackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
        WHERE sc.Laborderid = @LabOrderId AND sc.PackageId IS NULL;
    END

    -- Backfill BarcodeNo if missing (ONLY for tests requiring barcodes!)
    IF EXISTS (
        SELECT 1 FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
        LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
        WHERE sc.Laborderid = @LabOrderId 
          AND sc.CollectionstatusID = 2 
          AND sc.BarcodeNo IS NULL
          AND ISNULL(cat.Is_Barcode_Required, 1) = 1
    )
    BEGIN
        DECLARE @BranchId INT = 1;
        SELECT TOP 1 @BranchId = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
        WHERE sc.Laborderid = @LabOrderId;

        DECLARE @MissingProfId INT, @MissingProfName NVARCHAR(200);
        DECLARE missing_prof CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT sc.ProfileId, sc.ProfileName
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
              AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL);

        OPEN missing_prof;
        FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MBarcode NVARCHAR(50) = NULL;
            SELECT TOP 1 @MBarcode = sc.BarcodeNo
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              )
              AND sc.BarcodeNo IS NOT NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

            IF @MBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MBarcode OUTPUT, @LabOrderId = @LabOrderId;   -- 2537
            END

            UPDATE sc
            SET sc.BarcodeNo = @MBarcode
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              );

            FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        END
        CLOSE missing_prof;
        DEALLOCATE missing_prof;

        DECLARE @MissingItemId BIGINT;
        DECLARE missing_item CURSOR LOCAL FAST_FORWARD FOR
            SELECT sc.samplecollectionID
            FROM dbo.SampleCollection sc
            LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
            LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
            WHERE sc.Laborderid = @LabOrderId 
              AND sc.CollectionstatusID = 2 
              AND sc.BarcodeNo IS NULL
              AND ISNULL(cat.Is_Barcode_Required, 1) = 1;

        OPEN missing_item;
        FETCH NEXT FROM missing_item INTO @MissingItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MItemBarcode NVARCHAR(50) = NULL;
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MItemBarcode OUTPUT, @LabOrderId = @LabOrderId;   -- 2537

            UPDATE sc
            SET sc.BarcodeNo = @MItemBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @MissingItemId;

            FETCH NEXT FROM missing_item INTO @MissingItemId;
        END
        CLOSE missing_item;
        DEALLOCATE missing_item;
    END

    -- RS1: Order-level header
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        bm.BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        CASE WHEN lo.CreatedDate < ISNULL(lo.BookingDate, lo.OrderDate) THEN lo.CreatedDate ELSE ISNULL(lo.BookingDate, lo.OrderDate) END AS EarliestCollectionOn,   -- 2203: the earliest collection time allowed
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        (SELECT TOP 1 v.Status FROM dbo.LabHomeVisit v WHERE v.LabOrderId = lo.LabOrderId ORDER BY v.VisitId DESC) AS HomeVisitStatus,   -- 2390
        dbo.fn_LabHomeCollectionHold(lo.LabOrderId) AS CollectionHoldReason,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        CASE 
            WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        ISNULL(lo.IsB2B, 0) AS IsB2B,
        lo.AgentType,
        lo.B2BAgentID AS B2BAgentId,
        CASE 
            WHEN lo.AgentType = 'F' THEN f.Franchise_Name
            WHEN lo.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS PartnerName
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    WHERE lo.LabOrderId = @LabOrderId;

    -- 2418: Home Collection with the Phlebotomist App, not handed over yet - a tube the app collected shows as with the
    -- phlebotomist (not collected) on this screen; the data itself is not changed
    DECLARE @HeldByPhlebo BIT = CASE WHEN dbo.fn_LabHomeCollectionHold(@LabOrderId) IS NULL THEN 0 ELSE 1 END;

    -- RS2: Individual test/sample items
    -- EXCLUDES tests where Is_Sample_Collection_Required = 0 (e.g. Radiology)!
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        ISNULL(lim.Is_Fasting_Required, 0) AS IsFastingRequired,
        CAST(ISNULL(sc.IsoutSource, ISNULL(lim.Is_Outsourced, 0)) AS BIT) AS IsOutsourced,
        CAST(ISNULL(sc.IsoutSource, ISNULL(lim.Is_Outsourced, 0)) AS BIT) AS IsoutSource,
        sc.BarcodeNo,
        ISNULL(sc.RequiresManualBarcode, 0) AS RequiresManualBarcode,
        CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN 1 ELSE ISNULL(sc.CollectionstatusID, 1) END AS CollectionstatusID,
        CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN N'With phlebotomist' ELSE ISNULL(cs.StatusName, 'Pending') END AS StatusName,
        CAST(CASE WHEN @HeldByPhlebo = 1 AND sc.CollectionstatusID = 2 THEN 1 ELSE 0 END AS BIT) AS AwaitingHandover,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.Orderdate,
        sc.Bookingdatetime,
        sc.TokenNo,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        u.FullName AS CollectedByName,
        sc.RejectionReasonId,
        sc.RejectionReason
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = COALESCE(sc.TestcategoryID, lim.Category_ID)
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Users u ON u.Id = sc.ModifiedBy
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
      AND ISNULL(cat.Is_Sample_Collection_Required, 1) = 1
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO

PRINT 'Script 2537 applied: separate B2B sample barcode sequence (F-<BranchCode><FY2><6 digits>).';
GO
