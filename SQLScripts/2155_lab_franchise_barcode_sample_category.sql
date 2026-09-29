-- ============================================================================
-- Migration: 2155_lab_franchise_barcode_sample_category.sql
-- Description:
--   Adds an optional Sample Category to a Franchise barcode series - Fasting
--   (suffix -F), PP / Post Prandial (suffix -PP), or Urine (suffix -U) - so a
--   franchise can be issued separate barcode rolls per sample type, matching
--   how pre-printed stickers are actually ordered/printed in practice.
--
--   The suffix is appended to the END of the existing pattern, nothing else
--   about it changes:
--     <BranchCode>-<Franchise_Code>-<FY2>-NNNNNN            (no category, as today)
--     <BranchCode>-<Franchise_Code>-<FY2>-NNNNNN-F          (Fasting)
--     <BranchCode>-<Franchise_Code>-<FY2>-NNNNNN-PP         (PP / Post Prandial)
--     <BranchCode>-<Franchise_Code>-<FY2>-NNNNNN-U          (Urine)
--
--   The sequence itself is UNCHANGED: StartNumber still continues as
--   MAX(EndNumber)+1 across every series of that franchise, category
--   included or not - only the display suffix is new. A franchise can hold
--   several concurrently Active series, one per category (or none).
--
--   Altered: usp_Api_LabFranchiseBarcodeSeries_Generate (new optional
--   @SampleCategoryCode param), usp_Api_LabFranchiseBarcodeSeries_GetList,
--   usp_Lab_GetFranchiseBarcodeStatus, usp_Lab_GetSeriesBarcodes (all three
--   now also return SampleCategoryCode / SampleCategoryName for display).
--   usp_Lab_ValidateAndConsumeFranchiseBarcode needs no change - it already
--   matches on the full BarcodeNo string, suffix included.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Split into separate batches: a CHECK constraint referencing a column added earlier in the
-- SAME batch fails name resolution in SQL Server (the schema change isn't visible to the
-- compiler until the batch that made it has finished), so each ALTER TABLE gets its own GO.
IF COL_LENGTH('dbo.LabFranchiseBarcodeSeries', 'SampleCategoryCode') IS NULL
    ALTER TABLE dbo.LabFranchiseBarcodeSeries ADD SampleCategoryCode NVARCHAR(10) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_LabFranchiseBarcodeSeries_SampleCategoryCode')
    ALTER TABLE dbo.LabFranchiseBarcodeSeries
        ADD CONSTRAINT CK_LabFranchiseBarcodeSeries_SampleCategoryCode
        CHECK (SampleCategoryCode IS NULL OR SampleCategoryCode IN ('F', 'PP', 'U'));
GO

-- ============================================================================
-- usp_Api_LabFranchiseBarcodeSeries_Generate (altered: +@SampleCategoryCode)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseBarcodeSeries_Generate
    @Franchise_ID       INT,
    @Quantity           INT,
    @SampleCategoryCode NVARCHAR(10) = NULL,
    @CreatedBy          INT = NULL
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

    SET @SampleCategoryCode = NULLIF(LTRIM(RTRIM(UPPER(ISNULL(@SampleCategoryCode, '')))), '');
    IF @SampleCategoryCode IS NOT NULL AND @SampleCategoryCode NOT IN ('F', 'PP', 'U')
    BEGIN
        RAISERROR('Sample Category must be Fasting (F), PP (PP), Urine (U), or left blank.', 16, 1);
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

    DECLARE @Suffix NVARCHAR(10) = CASE WHEN @SampleCategoryCode IS NULL THEN '' ELSE '-' + @SampleCategoryCode END;

    BEGIN TRANSACTION;

    BEGIN TRY
        -- The increment continues across every series this franchise has ever had,
        -- category included or not - unchanged from before this script.
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
            (Franchise_ID, BranchId, SeriesCode, FinancialYear, StartNumber, EndNumber, Quantity, Status, SampleCategoryCode, GeneratedBy, CompanyId)
        VALUES
            (@Franchise_ID, @BranchId, @SeriesCode, @FY2, @StartNumber, @EndNumber, @Quantity, 'Active', @SampleCategoryCode, @CreatedBy, @CompanyId);

        DECLARE @SeriesId INT = SCOPE_IDENTITY();

        ;WITH Seq AS (
            SELECT TOP (@Quantity) @StartNumber - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects a1 CROSS JOIN sys.all_objects a2
        )
        INSERT INTO dbo.LabFranchiseBarcodePool (SeriesId, Franchise_ID, BarcodeNo, SequenceNo, Status)
        SELECT
            @SeriesId,
            @Franchise_ID,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(N AS NVARCHAR(10)), 6) + @Suffix,
            N,
            1
        FROM Seq;

        COMMIT TRANSACTION;

        SELECT
            @SeriesId AS SeriesId,
            @SeriesCode AS SeriesCode,
            @SampleCategoryCode AS SampleCategoryCode,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(@StartNumber AS NVARCHAR(10)), 6) + @Suffix AS StartBarcode,
            @BranchCode + '-' + @FranchiseCode + '-' + @FY2 + '-' + RIGHT('000000' + CAST(@EndNumber AS NVARCHAR(10)), 6) + @Suffix AS EndBarcode,
            @Quantity AS Quantity;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ============================================================================
-- usp_Api_LabFranchiseBarcodeSeries_GetList (altered: +SampleCategoryCode/Name)
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
        s.SampleCategoryCode,
        CASE s.SampleCategoryCode WHEN 'F' THEN 'Fasting' WHEN 'PP' THEN 'PP (Post Prandial)' WHEN 'U' THEN 'Urine' ELSE 'General' END AS SampleCategoryName,
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
-- usp_Lab_GetFranchiseBarcodeStatus (altered: +SampleCategoryCode/Name)
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
        s.SampleCategoryCode,
        CASE s.SampleCategoryCode WHEN 'F' THEN 'Fasting' WHEN 'PP' THEN 'PP (Post Prandial)' WHEN 'U' THEN 'Urine' ELSE 'General' END AS SampleCategoryName,
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
-- usp_Lab_GetSeriesBarcodes (altered: +SampleCategoryCode/Name)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetSeriesBarcodes
    @SeriesId INT
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
        s.SampleCategoryCode,
        CASE s.SampleCategoryCode WHEN 'F' THEN 'Fasting' WHEN 'PP' THEN 'PP (Post Prandial)' WHEN 'U' THEN 'Urine' ELSE 'General' END AS SampleCategoryName,
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
    WHERE bp.SeriesId = @SeriesId
    ORDER BY bp.SequenceNo;
END
GO

PRINT 'Script 2155 applied: Franchise barcode series now support an optional Sample Category suffix (-F / -PP / -U).';
GO
