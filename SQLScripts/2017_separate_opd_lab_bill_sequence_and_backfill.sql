-- ============================================================
-- 2017_separate_opd_lab_bill_sequence_and_backfill.sql
-- 1. Separates OPD and LAB Bill No sequence generation
-- 2. Patterns:
--    OPD: OPD/<BranchCode><FY><6-digit seq>  (e.g., OPD/HO2627000001)
--    LAB: LAB/<BranchCode><FY><6-digit seq>  (e.g., LAB/HO2627000001)
-- 3. Updates usp_OPD_GetNextBillNo, usp_LAB_GetNextBillNo, usp_CreateLabOrder, usp_Patient_Create, usp_Patient_Update
-- 4. Backfills all existing OPD and LAB bill records, ledger references, consultations, and sequences
-- ============================================================

USE [Dev_EMR];
GO

-- ── 1. Table Schema: OPDBillSequence & Columns ─────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'OPDBillSequence' AND COLUMN_NAME = 'ModuleCode')
BEGIN
    ALTER TABLE dbo.OPDBillSequence ADD ModuleCode NVARCHAR(10) NOT NULL DEFAULT 'OPD';
END
GO

-- Ensure Primary Key is (BranchId, FinancialYear, ModuleCode)
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID('dbo.OPDBillSequence') AND type = 'PK')
BEGIN
    DECLARE @PKName NVARCHAR(200);
    SELECT @PKName = name FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID('dbo.OPDBillSequence') AND type = 'PK';
    EXEC('ALTER TABLE dbo.OPDBillSequence DROP CONSTRAINT [' + @PKName + ']');
END
GO

ALTER TABLE dbo.OPDBillSequence ADD CONSTRAINT PK_OPDBillSequence PRIMARY KEY (BranchId, FinancialYear, ModuleCode);
GO

-- Ensure column sizes
ALTER TABLE dbo.PatientOPDService ALTER COLUMN OPDBillNo NVARCHAR(50) NULL;
ALTER TABLE dbo.LabOrder ALTER COLUMN BillNo NVARCHAR(50) NULL;
GO

-- ── 2. Stored Procedure: usp_OPD_GetNextBillNo ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextBillNo
    @BranchId  INT,
    @BillNo    NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Look up the branch code (UPPER, trimmed)
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL OR @BranchCode = ''
        SET @BranchCode = 'BR';

    -- Financial year: Apr–Mar e.g. Apr 2026 → Mar 2027 = '2627'
    DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear   INT  = YEAR(@Today);
    DECLARE @Month     INT  = MONTH(@Today);

    DECLARE @FYStart   INT  = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd     INT  = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY        NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;

    -- Atomically update sequence for OPD
    UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'OPD';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @FY, 'OPD', 1, 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'OPD';
            END
            ELSE THROW;
        END CATCH
    END

    -- Format: OPD/<BranchCode><FY><6-digit seq> e.g. OPD/HO2627000001
    SET @BillNo = 'OPD/' + @BranchCode + @FY + RIGHT('000000' + CAST(@NewSeq AS NVARCHAR(10)), 6);
END
GO

-- ── 3. Stored Procedure: usp_LAB_GetNextBillNo ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LAB_GetNextBillNo
    @BranchId  INT,
    @BillNo    NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Look up the branch code (UPPER, trimmed)
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL OR @BranchCode = ''
        SET @BranchCode = 'BR';

    -- Financial year: Apr–Mar e.g. Apr 2026 → Mar 2027 = '2627'
    DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear   INT  = YEAR(@Today);
    DECLARE @Month     INT  = MONTH(@Today);

    DECLARE @FYStart   INT  = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd     INT  = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY        NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;

    -- Atomically update sequence for LAB
    UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @FY, 'LAB', 1, 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';
            END
            ELSE THROW;
        END CATCH
    END

    -- Format: LAB/<BranchCode><FY><6-digit seq> e.g. LAB/HO2627000001
    SET @BillNo = 'LAB/' + @BranchCode + @FY + RIGHT('000000' + CAST(@NewSeq AS NVARCHAR(10)), 6);
END
GO

-- ── 4. Stored Procedure: usp_CreateLabOrder ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId INT,
    @BranchId INT,
    @CreatedBy INT,
    @TotalAmount DECIMAL(10,2),
    @Items dbo.udt_LabOrderItem READONLY,
    @LabOrderId INT OUTPUT,
    @BillNo NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        INSERT INTO dbo.LabOrder (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CreatedBy, CreatedDate, IsActive)
        VALUES (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount, @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Price, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, Price, @CreatedBy, GETDATE(), 1
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 5. Update usp_Patient_Create ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
(
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
    @Address                NVARCHAR(500)   = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @PatientCode            NVARCHAR(50)    OUTPUT,
    @OPDBillNo              NVARCHAR(50)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName     NVARCHAR(100);
    DECLARE @Now         DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate   DATE;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check: PhoneNumber + RelationId
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE  PhoneNumber = @PhoneNumber
              AND  RelationId  = @RelationId
              AND  IsActive    = 1
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        SET @Now = SYSUTCDATETIME();

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;

        SET @TokenNo = NULL;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        -- Calculate total amount
        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Exception: zero-amount bills get token immediately (no payment required)
        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate,
            ScheduleId, AppointmentTime
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            ISNULL(@AppointmentDate, GETDATE()), 'Registered', 1, @UserId, GETDATE(),
            @ScheduleId, @AppointmentTime
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT @NewOPDServiceId,
                JSON_VALUE(j.value,'$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ── 6. Update usp_Patient_Update ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Update
(
    @PatientId              INT,
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
    @Address                NVARCHAR(500)   = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(50)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName2    NVARCHAR(100);
    DECLARE @Now2        DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate   DATE;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check on update
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE  PhoneNumber = @PhoneNumber
              AND  RelationId  = @RelationId
              AND  IsActive    = 1
              AND  PatientId  <> @PatientId
        )
        BEGIN
            SELECT @RelName2 = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName2, @PhoneNumber);
        END

        SET @Now2 = SYSUTCDATETIME();

        UPDATE dbo.PatientMaster SET
            PhoneNumber            = @PhoneNumber,
            SecondaryPhoneNumber   = @SecondaryPhoneNumber,
            Salutation             = @Salutation,
            FirstName              = @FirstName,
            MiddleName             = @MiddleName,
            LastName               = @LastName,
            Gender                 = @Gender,
            DateOfBirth            = @DateOfBirth,
            ReligionId             = @ReligionId,
            EmailId                = @EmailId,
            GuardianName           = @GuardianName,
            CountryId              = @CountryId,
            StateId                = @StateId,
            DistrictId             = @DistrictId,
            CityId                 = @CityId,
            AreaId                 = @AreaId,
            Address                = @Address,
            RelationId             = @RelationId,
            IdentificationTypeId   = @IdentificationTypeId,
            IdentificationNumber   = @IdentificationNumber,
            IdentificationFilePath = @IdentificationFilePath,
            PhotoPath              = @PhotoPath,
            OccupationId           = @OccupationId,
            MaritalStatusId        = @MaritalStatusId,
            BloodGroup             = @BloodGroup,
            KnownAllergies         = @KnownAllergies,
            Remarks                = @Remarks,
            ModifiedBy             = @UserId,
            ModifiedDate           = @Now2
        WHERE PatientId = @PatientId;

        -- Calculate total
        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Bill No generated, Token remains NULL until payment
        EXEC dbo.usp_OPD_GetNextBillNo @BranchId, @OPDBillNo OUTPUT;
        SET @TokenNo = NULL;

        -- Exception: zero-amount bills get token immediately
        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate,
            ScheduleId, AppointmentTime
        ) VALUES (
            @PatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            ISNULL(@AppointmentDate, GETDATE()), 'Registered', 1, @UserId, GETDATE(),
            @ScheduleId, @AppointmentTime
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT @NewOPDServiceId,
                JSON_VALUE(j.value,'$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ── 7. Data Backfill: OPD Bills ───────────────────────────────
PRINT 'Starting OPD Bill No backfill...';

DECLARE @OPDUpdates TABLE (
    OPDServiceId INT,
    BranchId     INT,
    FY           NVARCHAR(4),
    OldBillNo    NVARCHAR(50),
    NewBillNo    NVARCHAR(50),
    Seq          INT
);

INSERT INTO @OPDUpdates (OPDServiceId, BranchId, FY, OldBillNo, NewBillNo, Seq)
SELECT 
    s.OPDServiceId,
    s.BranchId,
    FYCalc.FY,
    s.OPDBillNo,
    'OPD/' + ISNULL(UPPER(LTRIM(RTRIM(b.BranchCode))), 'BR') + FYCalc.FY + RIGHT('000000' + CAST(ROW_NUMBER() OVER (PARTITION BY s.BranchId, FYCalc.FY ORDER BY s.OPDServiceId) AS NVARCHAR(10)), 6),
    ROW_NUMBER() OVER (PARTITION BY s.BranchId, FYCalc.FY ORDER BY s.OPDServiceId)
FROM dbo.PatientOPDService s
LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
CROSS APPLY (
    SELECT CASE WHEN MONTH(s.CreatedDate) >= 4 
                THEN RIGHT(CAST(YEAR(s.CreatedDate) AS NVARCHAR(4)), 2) + RIGHT(CAST(YEAR(s.CreatedDate) + 1 AS NVARCHAR(4)), 2)
                ELSE RIGHT(CAST(YEAR(s.CreatedDate) - 1 AS NVARCHAR(4)), 2) + RIGHT(CAST(YEAR(s.CreatedDate) AS NVARCHAR(4)), 2)
           END AS FY
) FYCalc;

-- Update PatientOPDService
UPDATE s
SET s.OPDBillNo = u.NewBillNo
FROM dbo.PatientOPDService s
INNER JOIN @OPDUpdates u ON u.OPDServiceId = s.OPDServiceId;

-- Update EmrPatientConsultation
UPDATE c
SET c.OPDBillNo = u.NewBillNo
FROM dbo.EmrPatientConsultation c
INNER JOIN @OPDUpdates u ON u.OldBillNo = c.OPDBillNo;

-- Update Acc_LedgerTransaction for OPD_BILL
UPDATE lt
SET lt.Narration = 'Revenue recognized for OPD Bill ' + u.NewBillNo
FROM dbo.Acc_LedgerTransaction lt
INNER JOIN @OPDUpdates u ON u.OPDServiceId = lt.ReferenceId AND lt.ReferenceType = 'OPD_BILL';

-- Update Acc_LedgerTransactionDetail for OPD_BILL
UPDATE ltd
SET ltd.Narration = 'Revenue recognized for OPD Bill ' + u.NewBillNo
FROM dbo.Acc_LedgerTransactionDetail ltd
INNER JOIN dbo.Acc_LedgerTransaction lt ON lt.TransactionId = ltd.TransactionId
INNER JOIN @OPDUpdates u ON u.OPDServiceId = lt.ReferenceId AND lt.ReferenceType = 'OPD_BILL';

-- Update OPDBillSequence counters for OPD
MERGE dbo.OPDBillSequence AS target
USING (
    SELECT BranchId, FY, MAX(Seq) AS MaxSeq
    FROM @OPDUpdates
    GROUP BY BranchId, FY
) AS src
ON (target.BranchId = src.BranchId AND target.FinancialYear = src.FY AND target.ModuleCode = 'OPD')
WHEN MATCHED THEN
    UPDATE SET LastSeq = src.MaxSeq
WHEN NOT MATCHED THEN
    INSERT (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
    VALUES (src.BranchId, src.FY, 'OPD', src.MaxSeq, 1);

PRINT 'OPD Bill No backfill completed.';
GO

-- ── 8. Data Backfill: LAB Bills ───────────────────────────────
PRINT 'Starting LAB Bill No backfill...';

DECLARE @LABUpdates TABLE (
    LabOrderId   INT,
    BranchId     INT,
    FY           NVARCHAR(4),
    OldBillNo    NVARCHAR(50),
    NewBillNo    NVARCHAR(50),
    Seq          INT
);

INSERT INTO @LABUpdates (LabOrderId, BranchId, FY, OldBillNo, NewBillNo, Seq)
SELECT 
    o.LabOrderId,
    o.BranchId,
    FYCalc.FY,
    o.BillNo,
    'LAB/' + ISNULL(UPPER(LTRIM(RTRIM(b.BranchCode))), 'BR') + FYCalc.FY + RIGHT('000000' + CAST(ROW_NUMBER() OVER (PARTITION BY o.BranchId, FYCalc.FY ORDER BY o.LabOrderId) AS NVARCHAR(10)), 6),
    ROW_NUMBER() OVER (PARTITION BY o.BranchId, FYCalc.FY ORDER BY o.LabOrderId)
FROM dbo.LabOrder o
LEFT JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
CROSS APPLY (
    SELECT CASE WHEN MONTH(o.OrderDate) >= 4 
                THEN RIGHT(CAST(YEAR(o.OrderDate) AS NVARCHAR(4)), 2) + RIGHT(CAST(YEAR(o.OrderDate) + 1 AS NVARCHAR(4)), 2)
                ELSE RIGHT(CAST(YEAR(o.OrderDate) - 1 AS NVARCHAR(4)), 2) + RIGHT(CAST(YEAR(o.OrderDate) AS NVARCHAR(4)), 2)
           END AS FY
) FYCalc;

-- Update LabOrder
UPDATE o
SET o.BillNo = u.NewBillNo
FROM dbo.LabOrder o
INNER JOIN @LABUpdates u ON u.LabOrderId = o.LabOrderId;

-- Update Acc_LedgerTransaction for LAB_BILL
UPDATE lt
SET lt.Narration = 'Revenue recognized for LAB Bill ' + u.NewBillNo
FROM dbo.Acc_LedgerTransaction lt
INNER JOIN @LABUpdates u ON u.LabOrderId = lt.ReferenceId AND lt.ReferenceType = 'LAB_BILL';

-- Update Acc_LedgerTransactionDetail for LAB_BILL
UPDATE ltd
SET ltd.Narration = 'Revenue recognized for LAB Bill ' + u.NewBillNo
FROM dbo.Acc_LedgerTransactionDetail ltd
INNER JOIN dbo.Acc_LedgerTransaction lt ON lt.TransactionId = ltd.TransactionId
INNER JOIN @LABUpdates u ON u.LabOrderId = lt.ReferenceId AND lt.ReferenceType = 'LAB_BILL';

-- Update OPDBillSequence counters for LAB
MERGE dbo.OPDBillSequence AS target
USING (
    SELECT BranchId, FY, MAX(Seq) AS MaxSeq
    FROM @LABUpdates
    GROUP BY BranchId, FY
) AS src
ON (target.BranchId = src.BranchId AND target.FinancialYear = src.FY AND target.ModuleCode = 'LAB')
WHEN MATCHED THEN
    UPDATE SET LastSeq = src.MaxSeq
WHEN NOT MATCHED THEN
    INSERT (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
    VALUES (src.BranchId, src.FY, 'LAB', src.MaxSeq, 1);

PRINT 'LAB Bill No backfill completed.';
GO
