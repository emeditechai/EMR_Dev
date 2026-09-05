-- ==============================================================================
-- Migration Script: 2034_lab_barcode_sequence_and_pattern.sql
-- Description: Configurable Barcode Pattern (<BranchCode><FY2><6-digit Sequence>)
-- Example: HO26000001 for Branch 'HO', FY '26', sequence 1
-- Profile items share the same barcode.
-- Sequence is tracked in dbo.LabBarcodeSequence.
-- Pattern is configurable in dbo.LabBarcodeConfig.
-- ==============================================================================

SET NOCOUNT ON;
PRINT 'Starting 2034_lab_barcode_sequence_and_pattern migration...';

-- ── 1. Ensure Table: dbo.LabBarcodeConfig ──────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabBarcodeConfig')
BEGIN
    CREATE TABLE dbo.LabBarcodeConfig (
        ConfigId                 INT IDENTITY(1,1) PRIMARY KEY,
        BranchId                 INT NULL,                      -- NULL = Global fallback
        CompanyId                INT NULL DEFAULT 1,
        PrefixFormat             NVARCHAR(50) NOT NULL DEFAULT '<BranchCode><FY2>',
        DigitCount               INT NOT NULL DEFAULT 6,
        CurrentFinancialYear     NVARCHAR(10) NULL,             -- Manual override if specified (e.g. '26')
        IncludeSampleTypeSuffix  BIT NOT NULL DEFAULT 0,
        IsActive                 BIT NOT NULL DEFAULT 1,
        CreatedDate              DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedDate             DATETIME NULL
    );
    PRINT 'Created dbo.LabBarcodeConfig table.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabBarcodeConfig' AND COLUMN_NAME = 'CurrentFinancialYear')
    BEGIN
        ALTER TABLE dbo.LabBarcodeConfig ADD CurrentFinancialYear NVARCHAR(10) NULL;
        PRINT 'Added CurrentFinancialYear to dbo.LabBarcodeConfig.';
    END
END
GO

-- Seed default global configuration if none exists
IF NOT EXISTS (SELECT 1 FROM dbo.LabBarcodeConfig WHERE BranchId IS NULL)
BEGIN
    INSERT INTO dbo.LabBarcodeConfig (BranchId, CompanyId, PrefixFormat, DigitCount, CurrentFinancialYear, IncludeSampleTypeSuffix, IsActive)
    VALUES (NULL, 1, '<BranchCode><FY2>', 6, NULL, 0, 1);
    PRINT 'Inserted default global configuration in dbo.LabBarcodeConfig.';
END
ELSE
BEGIN
    UPDATE dbo.LabBarcodeConfig
    SET PrefixFormat = '<BranchCode><FY2>',
        DigitCount   = 6,
        IsActive     = 1
    WHERE BranchId IS NULL;
    PRINT 'Updated default global configuration in dbo.LabBarcodeConfig.';
END
GO

-- ── 2. Ensure Table: dbo.LabBarcodeSequence ────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabBarcodeSequence')
BEGIN
    CREATE TABLE dbo.LabBarcodeSequence (
        BranchId       INT NOT NULL,
        FinancialYear  NVARCHAR(10) NOT NULL, -- e.g. '26'
        LastSeq        BIGINT NOT NULL DEFAULT 0,
        CompanyId      INT NULL DEFAULT 1,
        CONSTRAINT PK_LabBarcodeSequence PRIMARY KEY (BranchId, FinancialYear)
    );
    PRINT 'Created dbo.LabBarcodeSequence table.';
END
GO

-- ── 3. Stored Procedure: usp_Lab_GetNextBarcodeNo ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetNextBarcodeNo
    @BranchId    INT,
    @BarcodeNo   NVARCHAR(50) OUTPUT
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

-- ── 4. Stored Procedure: usp_SampleCollection_UpdateStatus ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId   BIGINT,
    @CollectionstatusID   INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId               INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LabOrderId   INT;
    DECLARE @ProfileId    INT;
    DECLARE @ProfileName  NVARCHAR(200);
    DECLARE @BranchId     INT = 1;
    DECLARE @GeneratedBarcode NVARCHAR(50);

    SELECT 
        @LabOrderId   = sc.Laborderid,
        @ProfileId    = sc.ProfileId,
        @ProfileName  = sc.ProfileName,
        @BranchId     = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('SampleCollection record with ID %I64d does not exist.', 16, 1, @SampleCollectionId);
        RETURN;
    END

    -- If Collected (StatusID = 2)
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        -- Profile-wise: Check if any sibling test in the same profile already has a barcode
        IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        BEGIN
            SELECT TOP 1 @GeneratedBarcode = BarcodeNo 
            FROM dbo.SampleCollection 
            WHERE Laborderid = @LabOrderId 
              AND (
                  (@ProfileId IS NOT NULL AND ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND ProfileName = @ProfileName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @GeneratedBarcode),
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
        ELSE
        BEGIN
            -- Standalone investigation
            SELECT @GeneratedBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = @GeneratedBarcode,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── 5. Stored Procedure: usp_SampleCollection_UpdateProfileStatus ──────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateProfileStatus
    @LabOrderId          INT,
    @ProfileId           INT = NULL,
    @ProfileName         NVARCHAR(200) = NULL,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    DECLARE @BranchId INT = 1;
    SELECT TOP 1 @BranchId = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- If Collected (2)
    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        -- 1. Check if any test in this profile already has a barcode generated
        DECLARE @ExistingBarcode NVARCHAR(50);
        SELECT TOP 1 @ExistingBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        -- 2. If none, generate a single barcode for the entire profile
        IF @ExistingBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ExistingBarcode OUTPUT;
        END

        -- 3. Update all tests in this profile
        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ExistingBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE IF @CollectionstatusID = 1 -- Revert to Pending: clear collection date, time, and BarcodeNo
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE -- Other statuses (Re Collect = 3, Rejected = 4)
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END

    SELECT @@ROWCOUNT AS RowsUpdated;
END
GO

-- ── 6. Stored Procedure: usp_SampleCollection_CollectAll ──────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_CollectAll
    @LabOrderId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    DECLARE @CurrentDate DATE    = CAST(GETDATE() AS DATE);
    DECLARE @CurrentTime TIME(0) = CAST(GETDATE() AS TIME(0));

    DECLARE @BranchId INT = 1;
    SELECT TOP 1 @BranchId = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    -- 1. Process Profiles: Each profile shares a single barcode
    DECLARE @CurProfileId INT, @CurProfileName NVARCHAR(200);
    DECLARE prof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT sc.ProfileId, sc.ProfileName
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL)
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

    OPEN prof_cur;
    FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ProfBarcode NVARCHAR(50) = NULL;
        SELECT TOP 1 @ProfBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ProfBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ProfBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ProfBarcode),
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND (
              (@CurProfileId IS NOT NULL AND sc.ProfileId = @CurProfileId)
              OR (@CurProfileId IS NULL AND @CurProfileName IS NOT NULL AND sc.ProfileName = @CurProfileName)
          )
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

        FETCH NEXT FROM prof_cur INTO @CurProfileId, @CurProfileName;
    END
    CLOSE prof_cur;
    DEALLOCATE prof_cur;

    -- 2. Process Standalone Investigations: Each gets its own unique sequential barcode
    DECLARE @CurSampleCollectionId BIGINT;
    DECLARE item_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT sc.samplecollectionID
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0
          AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL
          AND (sc.CollectionstatusID IS NULL OR sc.CollectionstatusID IN (1, 3));

    OPEN item_cur;
    FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @ItemBarcode NVARCHAR(50) = NULL;
        SELECT @ItemBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @CurSampleCollectionId;

        IF @ItemBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ItemBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = ISNULL(sc.Samplecollectiondate, @CurrentDate),
            Samplecollectiontime = ISNULL(sc.Samplecollectiontime, @CurrentTime),
            BarcodeNo            = @ItemBarcode,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @CurSampleCollectionId;

        FETCH NEXT FROM item_cur INTO @CurSampleCollectionId;
    END
    CLOSE item_cur;
    DEALLOCATE item_cur;

    -- Return count of collected items for this order
    SELECT COUNT(*) AS RowsUpdated
    FROM dbo.SampleCollection
    WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2;
END
GO

-- ── 7. Stored Procedure: usp_SampleCollection_GetDetail ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    -- Auto-backfill ProfileId / PackageId if missing
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND ProfileId IS NULL AND PackageId IS NULL AND ProfilePackageName IS NOT NULL AND ProfilePackageName <> '—')
    BEGIN
        -- Profiles
        UPDATE sc
        SET 
            sc.ProfileId   = h.Profile_ID,
            sc.ProfileName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'I'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
        INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.Test_ID = sc.InvestigationID
        WHERE sc.Laborderid = @LabOrderId AND sc.ProfileId IS NULL;

        -- Packages
        UPDATE sc
        SET 
            sc.PackageId   = h.Profile_ID,
            sc.PackageName = h.Profile_Name
        FROM dbo.SampleCollection sc
        INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = sc.Laborderid AND loi.Type = 'P'
        INNER JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = loi.InvestigationId
        WHERE sc.Laborderid = @LabOrderId AND sc.PackageId IS NULL;
    END

    -- If any COLLECTED sample is missing BarcodeNo, generate it using new pattern
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND CollectionstatusID = 2 AND BarcodeNo IS NULL)
    BEGIN
        DECLARE @BranchId INT = 1;
        SELECT TOP 1 @BranchId = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1))
        FROM dbo.SampleCollection sc
        LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
        WHERE sc.Laborderid = @LabOrderId;

        -- For missing profile barcodes
        DECLARE @MissingProfId INT, @MissingProfName NVARCHAR(200);
        DECLARE missing_prof CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT sc.ProfileId, sc.ProfileName
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
              AND (sc.ProfileId IS NOT NULL OR sc.ProfileName IS NOT NULL);

        OPEN missing_prof;
        FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MBarcode NVARCHAR(50) = NULL;
            SELECT TOP 1 @MBarcode = BarcodeNo
            FROM dbo.SampleCollection
            WHERE Laborderid = @LabOrderId
              AND (
                  (@MissingProfId IS NOT NULL AND ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND ProfileName = @MissingProfName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @MBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MBarcode OUTPUT;
            END

            UPDATE sc
            SET BarcodeNo = @MBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
              AND (
                  (@MissingProfId IS NOT NULL AND sc.ProfileId = @MissingProfId)
                  OR (@MissingProfId IS NULL AND @MissingProfName IS NOT NULL AND sc.ProfileName = @MissingProfName)
              );

            FETCH NEXT FROM missing_prof INTO @MissingProfId, @MissingProfName;
        END
        CLOSE missing_prof;
        DEALLOCATE missing_prof;

        -- For missing standalone barcodes
        DECLARE @MissingItemId BIGINT;
        DECLARE missing_item CURSOR LOCAL FAST_FORWARD FOR
            SELECT sc.samplecollectionID
            FROM dbo.SampleCollection sc
            WHERE sc.Laborderid = @LabOrderId AND sc.CollectionstatusID = 2 AND sc.BarcodeNo IS NULL
              AND sc.ProfileId IS NULL AND sc.ProfileName IS NULL;

        OPEN missing_item;
        FETCH NEXT FROM missing_item INTO @MissingItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @MItemBarcode NVARCHAR(50) = NULL;
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @MItemBarcode OUTPUT;

            UPDATE sc
            SET BarcodeNo = @MItemBarcode
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @MissingItemId;

            FETCH NEXT FROM missing_item INTO @MissingItemId;
        END
        CLOSE missing_item;
        DEALLOCATE missing_item;
    END

    -- RS1: Order Header Summary
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
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS2: Investigation Line Items with Barcode, Container, and Collection Status
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
        sc.BarcodeNo,
        ISNULL(sc.CollectionstatusID, 1) AS CollectionstatusID,
        ISNULL(cs.StatusName, 'Pending') AS StatusName,
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
        u.FullName AS CollectedByName
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.SampleCollectionStatus cs ON cs.StatusID = sc.CollectionstatusID
    LEFT JOIN dbo.Users u ON u.Id = sc.ModifiedBy
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0
    ORDER BY 
        COALESCE(sc.ProfileName, sc.PackageName, 'ZZZ'),
        ISNULL(stm.Sample_Name, ''),
        lim.Test_Name;
END
GO

-- ── 8. Backfill Existing Barcodes to New Pattern (<BranchCode><FY2><6-Digit Sequence>)
PRINT 'Backfilling existing collected sample barcodes...';

BEGIN TRANSACTION;
BEGIN TRY
    -- Reset LabBarcodeSequence for Branch 1 and FY '26'
    DELETE FROM dbo.LabBarcodeSequence WHERE BranchId = 1 AND FinancialYear = '26';

    -- Build temporary mapping table for existing collected tubes
    IF OBJECT_ID('tempdb..#TubeMapping') IS NOT NULL DROP TABLE #TubeMapping;

    CREATE TABLE #TubeMapping (
        SeqNumber INT IDENTITY(1,1),
        TubeKey   NVARCHAR(100) PRIMARY KEY,
        BarcodeNo NVARCHAR(50)
    );

    -- Insert distinct tubes in deterministic order
    INSERT INTO #TubeMapping (TubeKey)
    SELECT DISTINCT 
        CASE 
            WHEN sc.ProfileId IS NOT NULL THEN 'ORD' + CAST(sc.Laborderid AS VARCHAR(10)) + '-P' + CAST(sc.ProfileId AS VARCHAR(10))
            ELSE 'ORD' + CAST(sc.Laborderid AS VARCHAR(10)) + '-I' + CAST(sc.samplecollectionID AS VARCHAR(10))
        END AS TubeKey
    FROM dbo.SampleCollection sc
    WHERE sc.CollectionstatusID = 2
    ORDER BY TubeKey;

    -- Compute barcode for each distinct tube (Branch 'HO', FY '26')
    UPDATE #TubeMapping
    SET BarcodeNo = 'HO26' + RIGHT('000000' + CAST(SeqNumber AS NVARCHAR(10)), 6);

    -- Apply updated barcodes to SampleCollection
    UPDATE sc
    SET sc.BarcodeNo = m.BarcodeNo
    FROM dbo.SampleCollection sc
    INNER JOIN #TubeMapping m ON m.TubeKey = CASE 
        WHEN sc.ProfileId IS NOT NULL THEN 'ORD' + CAST(sc.Laborderid AS VARCHAR(10)) + '-P' + CAST(sc.ProfileId AS VARCHAR(10))
        ELSE 'ORD' + CAST(sc.Laborderid AS VARCHAR(10)) + '-I' + CAST(sc.samplecollectionID AS VARCHAR(10))
    END
    WHERE sc.CollectionstatusID = 2;

    -- Update sequence counter to match highest assigned sequence
    DECLARE @MaxSeq INT;
    SELECT @MaxSeq = ISNULL(MAX(SeqNumber), 0) FROM #TubeMapping;

    INSERT INTO dbo.LabBarcodeSequence (BranchId, FinancialYear, LastSeq, CompanyId)
    VALUES (1, '26', @MaxSeq, 1);

    COMMIT TRANSACTION;
    PRINT 'Successfully backfilled ' + CAST(@MaxSeq AS NVARCHAR(10)) + ' barcodes in dbo.SampleCollection and updated sequence table.';
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Backfill failed: %s', 16, 1, @ErrMsg);
END CATCH
GO

PRINT 'Migration 2034 completed successfully.';
