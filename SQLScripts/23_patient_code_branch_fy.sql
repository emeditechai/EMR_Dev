-- =============================================================================
-- Script : 23_patient_code_branch_fy.sql
-- Purpose: Changes PatientCode generation from global sequence to
--          P<BranchCode><FinancialYear><6-digit-seq>
--          e.g.  PKOL2526000001
--
-- Changes:
--   1. Create  dbo.PatientCodeCounter  (branch + FY counter table)
--   2. Create  dbo.usp_Patient_GetNextCode  (helper SP)
--   3. Widen   PatientMaster.PatientCode  from NVARCHAR(20) → NVARCHAR(30)
--   4. Recreate dbo.usp_Patient_Create   (uses new code format)
--   5. Drop old global sequence dbo.PatientCodeSeq (if present)
--
-- Safe to re-run.
-- =============================================================================

-- ─── 1.  PatientCodeCounter  ──────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PatientCodeCounter')
BEGIN
    CREATE TABLE dbo.PatientCodeCounter
    (
        CounterId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        BranchId        INT             NOT NULL,
        FinancialYear   NVARCHAR(4)     NOT NULL,   -- e.g. '2526'
        LastSeq         INT             NOT NULL DEFAULT 0,

        CONSTRAINT UQ_PatientCodeCounter_Branch_FY
            UNIQUE (BranchId, FinancialYear),

        CONSTRAINT FK_PatientCodeCounter_Branch
            FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster (BranchID)
    );
    PRINT 'Created table: dbo.PatientCodeCounter';
END
ELSE
    PRINT 'Table dbo.PatientCodeCounter already exists – skipped.';
GO

-- ─── 2.  usp_Patient_GetNextCode  ────────────────────────────────────────────
-- Returns the next patient code for a given branch in the current financial year.
-- Format :  P<BranchCode><FY><6-digit-seq>    e.g.  PKOL2526000001
CREATE OR ALTER PROCEDURE dbo.usp_Patient_GetNextCode
    @BranchId       INT,
    @PatientCode    NVARCHAR(30)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve branch code
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster
    WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';   -- fallback

    -- Financial year: Apr–Mar  →  e.g. Apr 2025 – Mar 2026 = '2526'
    DECLARE @Today   DATE = CAST(GETDATE() AS DATE);
    DECLARE @Month   INT  = MONTH(@Today);
    DECLARE @CalYear INT  = YEAR(@Today);

    DECLARE @FYStart INT       = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd   INT       = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY      NVARCHAR(4) =
        RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) +
        RIGHT(CAST(@FYEnd   AS NVARCHAR(4)), 2);

    -- Upsert counter row (branch + FY)
    IF NOT EXISTS (
        SELECT 1 FROM dbo.PatientCodeCounter
        WHERE BranchId = @BranchId AND FinancialYear = @FY
    )
        INSERT INTO dbo.PatientCodeCounter (BranchId, FinancialYear, LastSeq)
        VALUES (@BranchId, @FY, 0);

    -- Atomic increment (UPDLOCK prevents race conditions)
    UPDATE dbo.PatientCodeCounter WITH (UPDLOCK)
        SET LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY;

    DECLARE @Seq INT;
    SELECT @Seq = LastSeq
    FROM dbo.PatientCodeCounter
    WHERE BranchId = @BranchId AND FinancialYear = @FY;

    -- Build code:  P + BranchCode + FY + 000001
    SET @PatientCode =
        'P' + @BranchCode + @FY +
        RIGHT('000000' + CAST(@Seq AS NVARCHAR(10)), 6);
END
GO

-- ─── 3.  Widen PatientMaster.PatientCode  ────────────────────────────────────
-- Max length: P(1) + BranchCode(~5) + FY(4) + seq(6) = ~16 chars
-- Widening from 20 → 30 to be future-safe.
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster')
      AND name = 'PatientCode'
      AND max_length < 60    -- max_length is bytes; NVARCHAR(30) = 60 bytes
)
BEGIN
    ALTER TABLE dbo.PatientMaster
        ALTER COLUMN PatientCode NVARCHAR(30) NOT NULL;
    PRINT 'Widened PatientMaster.PatientCode to NVARCHAR(30)';
END
ELSE
    PRINT 'PatientMaster.PatientCode already NVARCHAR(30) or wider – skipped.';
GO

-- ─── 4.  Recreate usp_Patient_Create  ────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
(
    -- PatientMaster fields
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE            = NULL,
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    -- PatientOPDService fields
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    -- Output
    @PatientCode            NVARCHAR(30)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ── Generate PatientCode  P<BranchCode><FY><6-digit-seq> ─────────────
        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

        -- ── INSERT PatientMaster ──────────────────────────────────────────────
        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        -- ── Bill No + Token No ────────────────────────────────────────────────
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        -- ── Compute total from line items JSON ────────────────────────────────
        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(
                SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- ── INSERT OPD Bill header ────────────────────────────────────────────
        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            GETUTCDATE(), 'Registered', 1, @UserId, GETUTCDATE()
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        -- ── INSERT line items ─────────────────────────────────────────────────
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId')      AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETUTCDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- ─── 5.  Drop old global sequence (no longer used) ───────────────────────────
IF EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'PatientCodeSeq' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    DROP SEQUENCE dbo.PatientCodeSeq;
    PRINT 'Dropped obsolete sequence: dbo.PatientCodeSeq';
END
ELSE
    PRINT 'Sequence dbo.PatientCodeSeq not found – skipped.';
GO

PRINT '==========================================================';
PRINT 'Script 23 complete.';
PRINT 'PatientCode format: P<BranchCode><FY><6-digit-seq>';
PRINT 'Example:            PKOL2526000001';
PRINT '==========================================================';
