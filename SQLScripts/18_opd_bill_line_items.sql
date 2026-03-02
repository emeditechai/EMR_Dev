-- ============================================================
-- Script 18: OPD Bill architecture
-- • OPDBillNo  : <BranchCode><FY><6-digit seq>  e.g. HO2526000001
-- • TokenNo    : <BranchCode>-<day-wise seq>    e.g. HO-0042
-- • PatientOPDService  now = Bill header (OPDBillNo, TokenNo, Doctor)
-- • PatientOPDServiceItem = line items per bill
-- • Both sequences are BRANCH-WISE
-- ============================================================

-- ── 1. OPD Bill Number Sequence (branch-wise + yearly) ────────────────────
-- Composite PK: (BranchId, FinancialYear) — sequence resets each FY per branch.
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'OPDBillSequence')
BEGIN
    CREATE TABLE dbo.OPDBillSequence (
        BranchId       INT          NOT NULL,
        FinancialYear  NVARCHAR(4)  NOT NULL,  -- e.g. '2526'
        LastSeq        INT          NOT NULL DEFAULT 0,
        CONSTRAINT PK_OPDBillSequence PRIMARY KEY (BranchId, FinancialYear)
    );
END
ELSE
BEGIN
    -- Migrate old single-column PK to composite if needed
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('OPDBillSequence') AND name = 'FinancialYear')
    AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('OPDBillSequence') AND name = 'BranchId')
    BEGIN
        -- Drop old PK, add BranchId column, recreate composite PK
        DECLARE @OldPK_Bill NVARCHAR(128);
        SELECT @OldPK_Bill = name FROM sys.key_constraints
            WHERE parent_object_id = OBJECT_ID('OPDBillSequence') AND type = 'PK';
        IF @OldPK_Bill IS NOT NULL
            EXEC ('ALTER TABLE dbo.OPDBillSequence DROP CONSTRAINT [' + @OldPK_Bill + ']');
        TRUNCATE TABLE dbo.OPDBillSequence;
        ALTER TABLE dbo.OPDBillSequence ADD BranchId INT NOT NULL DEFAULT 0;
        ALTER TABLE dbo.OPDBillSequence ADD CONSTRAINT PK_OPDBillSequence PRIMARY KEY (BranchId, FinancialYear);
        ALTER TABLE dbo.OPDBillSequence DROP CONSTRAINT IF EXISTS DF__OPDBillSe__Brand;
    END
END
GO

-- ── 2. OPD Token Sequence (branch-wise + day-wise counter) ──────────────────
-- Composite PK: (BranchId, TokenDate) — sequence resets each day per branch.
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'OPDTokenSequence')
BEGIN
    CREATE TABLE dbo.OPDTokenSequence (
        BranchId       INT   NOT NULL,
        TokenDate      DATE  NOT NULL,
        LastSeq        INT   NOT NULL DEFAULT 0,
        CONSTRAINT PK_OPDTokenSequence PRIMARY KEY (BranchId, TokenDate)
    );
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('OPDTokenSequence') AND name = 'TokenDate')
    AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('OPDTokenSequence') AND name = 'BranchId')
    BEGIN
        DECLARE @OldPK_Token NVARCHAR(128);
        SELECT @OldPK_Token = name FROM sys.key_constraints
            WHERE parent_object_id = OBJECT_ID('OPDTokenSequence') AND type = 'PK';
        IF @OldPK_Token IS NOT NULL
            EXEC ('ALTER TABLE dbo.OPDTokenSequence DROP CONSTRAINT [' + @OldPK_Token + ']');
        TRUNCATE TABLE dbo.OPDTokenSequence;
        ALTER TABLE dbo.OPDTokenSequence ADD BranchId INT NOT NULL DEFAULT 0;
        ALTER TABLE dbo.OPDTokenSequence ADD CONSTRAINT PK_OPDTokenSequence PRIMARY KEY (BranchId, TokenDate);
    END
END
GO

-- ── 3. Alter PatientOPDService — add OPDBillNo, TokenNo columns ─────────────
-- Remove old per-row service columns (migrated to PatientOPDServiceItem)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'OPDBillNo')
    ALTER TABLE dbo.PatientOPDService ADD OPDBillNo  NVARCHAR(30) NULL;
ELSE
BEGIN
    -- Widen column if it was created as NVARCHAR(20) previously
    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'OPDBillNo'
          AND max_length < 60   -- 30 nvarchar chars = 60 bytes
    )
        ALTER TABLE dbo.PatientOPDService ALTER COLUMN OPDBillNo NVARCHAR(30) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'TokenNo')
    ALTER TABLE dbo.PatientOPDService ADD TokenNo    NVARCHAR(20) NULL;
ELSE
BEGIN
    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'TokenNo'
          AND max_length < 40   -- 20 nvarchar chars = 40 bytes
    )
        ALTER TABLE dbo.PatientOPDService ALTER COLUMN TokenNo NVARCHAR(20) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'TotalAmount')
    ALTER TABLE dbo.PatientOPDService ADD TotalAmount DECIMAL(10,2) NULL DEFAULT 0;
GO

-- Drop old single-service columns (now moved to line-item table)
-- Only drop if PatientOPDServiceItem already exists (safe re-run)
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PatientOPDServiceItem')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'ServiceType')
        ALTER TABLE dbo.PatientOPDService DROP COLUMN ServiceType;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'ServiceId')
        ALTER TABLE dbo.PatientOPDService DROP COLUMN ServiceId;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('PatientOPDService') AND name = 'ServiceCharges')
        ALTER TABLE dbo.PatientOPDService DROP COLUMN ServiceCharges;
END
GO

-- ── 4. Create PatientOPDServiceItem (line items) ────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PatientOPDServiceItem')
BEGIN
    CREATE TABLE dbo.PatientOPDServiceItem (
        ItemId          INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        OPDServiceId    INT            NOT NULL,   -- FK → PatientOPDService
        ServiceType     NVARCHAR(20)   NULL,       -- 'Consulting' | 'Service'
        ServiceId       INT            NULL,       -- FK → ServiceMaster
        ServiceCharges  DECIMAL(10,2)  NULL,
        IsActive        BIT            NOT NULL DEFAULT 1,
        CreatedBy       INT            NULL,
        CreatedDate     DATETIME2      NOT NULL DEFAULT GETUTCDATE(),

        CONSTRAINT FK_OPDServiceItem_OPDService
            FOREIGN KEY (OPDServiceId) REFERENCES dbo.PatientOPDService(OPDServiceId)
    );
END
GO

-- ── 5. Recreate stored procedure: usp_OPD_GetNextBillNo ─────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextBillNo
    @BranchId  INT,
    @BillNo    NVARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- Look up the branch code (UPPER, trimmed)
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';   -- fallback if branch not found

    -- Financial year: Apr–Mar  e.g. Apr 2025 → Mar 2026 = '2526'
    DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear   INT  = YEAR(@Today);
    DECLARE @Month     INT  = MONTH(@Today);

    DECLARE @FYStart   INT  = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd     INT  = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY        NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    -- Upsert counter row (branch + FY composite key)
    IF NOT EXISTS (SELECT 1 FROM dbo.OPDBillSequence WHERE BranchId = @BranchId AND FinancialYear = @FY)
        INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FY, 0);

    UPDATE dbo.OPDBillSequence
        SET LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY;

    DECLARE @Seq INT;
    SELECT @Seq = LastSeq FROM dbo.OPDBillSequence WHERE BranchId = @BranchId AND FinancialYear = @FY;

    -- Format: <BranchCode><FY><6-digit seq>  e.g. HO2526000001
    SET @BillNo = @BranchCode + @FY + RIGHT('000000' + CAST(@Seq AS NVARCHAR(10)), 6);
END
GO

-- ── 6. Recreate stored procedure: usp_OPD_GetNextTokenNo ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextTokenNo
    @BranchId  INT,
    @TokenNo   NVARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- Look up branch code for prefix
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';   -- fallback

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    -- Upsert counter row (branch + date composite key)
    IF NOT EXISTS (SELECT 1 FROM dbo.OPDTokenSequence WHERE BranchId = @BranchId AND TokenDate = @Today)
        INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, LastSeq) VALUES (@BranchId, @Today, 0);

    UPDATE dbo.OPDTokenSequence
        SET LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @Today;

    DECLARE @Seq INT;
    SELECT @Seq = LastSeq FROM dbo.OPDTokenSequence WHERE BranchId = @BranchId AND TokenDate = @Today;

    -- Format: <BranchCode>-<4-digit seq>  e.g. HO-0042
    SET @TokenNo = @BranchCode + '-' + RIGHT('0000' + CAST(@Seq AS NVARCHAR(10)), 4);
END
GO

-- ── 7. Recreate usp_Patient_Create (now with bill/token + line items) ───────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
    -- PatientMaster
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(150)   = NULL,
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
    @Remarks                NVARCHAR(1000)  = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,
    -- OPD Bill (header)
    @ConsultingDoctorId     INT             = NULL,
    -- Line items (JSON array: [{ServiceType, ServiceId, ServiceCharges}])
    @LineItemsJson          NVARCHAR(MAX)   = NULL,
    -- OUTPUT
    @PatientCode            NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(20)    OUTPUT,
    @TokenNo                NVARCHAR(15)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate PatientCode
        DECLARE @NextSeq BIGINT = NEXT VALUE FOR dbo.PatientCodeSeq;
        SET @PatientCode = 'P' + RIGHT('000000' + CAST(@NextSeq AS NVARCHAR), 6);

        -- Insert PatientMaster
        INSERT INTO dbo.PatientMaster (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, ReligionId,
            EmailId, GuardianName, CountryId, StateId, DistrictId,
            CityId, AreaId, IdentificationTypeId, IdentificationNumber,
            IdentificationFilePath, OccupationId, MaritalStatusId,
            BloodGroup, KnownAllergies, Remarks, BranchId,
            CreatedBy, CreatedDate, IsActive
        ) VALUES (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @ReligionId,
            @EmailId, @GuardianName, @CountryId, @StateId, @DistrictId,
            @CityId, @AreaId, @IdentificationTypeId, @IdentificationNumber,
            @IdentificationFilePath, @OccupationId, @MaritalStatusId,
            @BloodGroup, @KnownAllergies, @Remarks, @BranchId,
            @UserId, GETUTCDATE(), 1
        );
        SET @NewPatientId = SCOPE_IDENTITY();

        -- Generate Bill No and Token No (branch-wise)
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        -- Compute total from line items JSON
        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Insert OPD Bill header
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

        -- Insert line items
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2)),
                1,
                @UserId,
                GETUTCDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- ── 8. Recreate usp_Patient_Update (new visit with bill/token + line items) ─
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Update
    -- PatientMaster
    @PatientId              INT,
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(150)   = NULL,
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
    @Remarks                NVARCHAR(1000)  = NULL,
    @UserId                 INT             = NULL,
    -- OPD visit
    @OPDServiceId           INT             = 0,   -- 0 = new visit
    @BranchId               INT             = NULL,
    @ConsultingDoctorId     INT             = NULL,
    -- Line items JSON
    @LineItemsJson          NVARCHAR(MAX)   = NULL,
    -- OUTPUT
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(20)    OUTPUT,
    @TokenNo                NVARCHAR(15)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Update PatientMaster
        UPDATE dbo.PatientMaster SET
            PhoneNumber            = @PhoneNumber,
            SecondaryPhoneNumber   = @SecondaryPhoneNumber,
            Salutation             = @Salutation,
            FirstName              = @FirstName,
            MiddleName             = @MiddleName,
            LastName               = @LastName,
            Gender                 = @Gender,
            ReligionId             = @ReligionId,
            EmailId                = @EmailId,
            GuardianName           = @GuardianName,
            CountryId              = @CountryId,
            StateId                = @StateId,
            DistrictId             = @DistrictId,
            CityId                 = @CityId,
            AreaId                 = @AreaId,
            IdentificationTypeId   = @IdentificationTypeId,
            IdentificationNumber   = @IdentificationNumber,
            IdentificationFilePath = @IdentificationFilePath,
            OccupationId           = @OccupationId,
            MaritalStatusId        = @MaritalStatusId,
            BloodGroup             = @BloodGroup,
            KnownAllergies         = @KnownAllergies,
            Remarks                = @Remarks,
            ModifiedBy             = @UserId,
            ModifiedDate           = GETUTCDATE()
        WHERE PatientId = @PatientId;

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        IF @OPDServiceId > 0
        BEGIN
            -- Update existing bill header (same visit re-save)
            UPDATE dbo.PatientOPDService SET
                ConsultingDoctorId = @ConsultingDoctorId,
                TotalAmount        = @TotalAmount,
                ModifiedBy         = @UserId,
                ModifiedDate       = GETUTCDATE()
            WHERE OPDServiceId = @OPDServiceId;

            SET @NewOPDServiceId = @OPDServiceId;

            -- Delete & re-insert line items
            DELETE FROM dbo.PatientOPDServiceItem WHERE OPDServiceId = @OPDServiceId;

            SELECT @OPDBillNo = OPDBillNo, @TokenNo = TokenNo
            FROM dbo.PatientOPDService WHERE OPDServiceId = @OPDServiceId;
        END
        ELSE
        BEGIN
            -- New visit for returning patient (branch-wise)
            EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

            INSERT INTO dbo.PatientOPDService (
                PatientId, BranchId, ConsultingDoctorId,
                OPDBillNo, TokenNo, TotalAmount,
                VisitDate, Status, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @PatientId, @BranchId, @ConsultingDoctorId,
                @OPDBillNo, @TokenNo, @TotalAmount,
                GETUTCDATE(), 'Registered', 1, @UserId, GETUTCDATE()
            );
            SET @NewOPDServiceId = SCOPE_IDENTITY();
        END

        -- Insert line items
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2)),
                1,
                @UserId,
                GETUTCDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

PRINT 'Script 18 completed: OPD Bill architecture with line items, sequences, and stored procedures.';
