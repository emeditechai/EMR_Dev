-- ============================================================
-- Script 25: RelationMaster table + PatientMaster.RelationId
-- ============================================================
-- 1. Create RelationMaster table
-- 2. Seed relation types
-- 3. Add RelationId column to PatientMaster
-- 4. Add unique index: PhoneNumber + RelationId
-- 5. Update usp_Patient_Create to include @RelationId
-- 6. Update usp_Patient_Update to include @RelationId
-- ============================================================

-- ─── 1. Create RelationMaster ─────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.RelationMaster') AND type = 'U')
BEGIN
    CREATE TABLE dbo.RelationMaster
    (
        RelationId   INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RelationName NVARCHAR(100)  NOT NULL,
        SortOrder    INT            NOT NULL DEFAULT 0,
        IsActive     BIT            NOT NULL DEFAULT 1,
        CreatedBy    INT            NULL,
        CreatedDate  DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedBy   INT            NULL,
        ModifiedDate DATETIME2      NULL
    );
    PRINT 'Table RelationMaster created.';
END
ELSE
    PRINT 'Table RelationMaster already exists – skipped.';
GO

-- ─── 2. Seed relation types ───────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.RelationMaster WHERE RelationName = 'Self')
BEGIN
    SET IDENTITY_INSERT dbo.RelationMaster ON;

    INSERT INTO dbo.RelationMaster (RelationId, RelationName, SortOrder, IsActive, CreatedDate)
    VALUES
        (1,  'Self',           1,  1, SYSUTCDATETIME()),
        (2,  'Father',         2,  1, SYSUTCDATETIME()),
        (3,  'Mother',         3,  1, SYSUTCDATETIME()),
        (4,  'Brother',        4,  1, SYSUTCDATETIME()),
        (5,  'Sister',         5,  1, SYSUTCDATETIME()),
        (6,  'Spouse',         6,  1, SYSUTCDATETIME()),
        (7,  'Husband',        7,  1, SYSUTCDATETIME()),
        (8,  'Wife',           8,  1, SYSUTCDATETIME()),
        (9,  'Son',            9,  1, SYSUTCDATETIME()),
        (10, 'Daughter',       10, 1, SYSUTCDATETIME()),
        (11, 'Father-In-Law',  11, 1, SYSUTCDATETIME()),
        (12, 'Mother-In-Law',  12, 1, SYSUTCDATETIME()),
        (13, 'Other',          99, 1, SYSUTCDATETIME());

    SET IDENTITY_INSERT dbo.RelationMaster OFF;
    PRINT 'RelationMaster seeded.';
END
ELSE
    PRINT 'RelationMaster already seeded – skipped.';
GO

-- ─── 3. Add RelationId column to PatientMaster ────────────────────────────────
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'RelationId'
)
BEGIN
    ALTER TABLE dbo.PatientMaster
        ADD RelationId INT NULL;

    ALTER TABLE dbo.PatientMaster
        ADD CONSTRAINT FK_PatientMaster_RelationMaster
        FOREIGN KEY (RelationId) REFERENCES dbo.RelationMaster(RelationId);

    PRINT 'Column PatientMaster.RelationId added with FK.';
END
ELSE
    PRINT 'Column PatientMaster.RelationId already exists – skipped.';
GO

-- ─── 4. Unique index: one patient per PhoneNumber + RelationId ────────────────
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.PatientMaster')
      AND name = 'UIX_PatientMaster_Phone_Relation'
)
BEGIN
    CREATE UNIQUE INDEX UIX_PatientMaster_Phone_Relation
        ON dbo.PatientMaster (PhoneNumber, RelationId)
        WHERE RelationId IS NOT NULL AND IsActive = 1;
    PRINT 'Unique index UIX_PatientMaster_Phone_Relation created.';
END
ELSE
    PRINT 'Unique index already exists – skipped.';
GO

-- ─── 5. usp_Patient_Create (with RelationId) ─────────────────────────────────
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
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

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

        -- Uniqueness check: PhoneNumber + RelationId
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber
              AND RelationId  = @RelationId
              AND IsActive    = 1
        )
        BEGIN
            DECLARE @RelName NVARCHAR(100);
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
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
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))),0)
            FROM OPENJSON(@LineItemsJson) j;

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            GETDATE(), 'Registered', 1, @UserId, GETDATE()
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

-- ─── 6. usp_Patient_Update (with RelationId) ─────────────────────────────────
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
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check on update: same phone+relation must not belong to another patient
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber
              AND RelationId  = @RelationId
              AND IsActive    = 1
              AND PatientId  <> @PatientId
        )
        BEGIN
            DECLARE @RelName NVARCHAR(100);
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

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
            OccupationId           = @OccupationId,
            MaritalStatusId        = @MaritalStatusId,
            BloodGroup             = @BloodGroup,
            KnownAllergies         = @KnownAllergies,
            Remarks                = @Remarks,
            ModifiedBy             = @UserId,
            ModifiedDate           = @Now
        WHERE PatientId = @PatientId;

        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))),0)
            FROM OPENJSON(@LineItemsJson) j;

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate
        ) VALUES (
            @PatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            GETDATE(), 'Registered', 1, @UserId, GETDATE()
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

PRINT 'Script 25 complete: RelationMaster created, seeded, PatientMaster.RelationId added, SPs updated.';
