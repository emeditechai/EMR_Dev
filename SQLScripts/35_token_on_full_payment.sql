-- ============================================================
-- Script 35: Token Number on Full Payment
-- Purpose : Change token generation so TokenNo is only
--           assigned after the patient pays in full.
--
-- Changes:
--   1. usp_OPD_GetNextTokenNo — add @TokenDate param (backwards compatible)
--   2. usp_OPD_AssignTokenOnPayment — new SP for post-payment token assign
--   3. usp_Patient_Create — remove token generation; TokenNo = NULL
--   4. usp_Patient_Update — same
-- ============================================================

USE [Dev_EMR];
GO

-- ── 1. Alter usp_OPD_GetNextTokenNo to accept optional @TokenDate ─────────────

CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM   dbo.BranchMaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';

    IF NOT EXISTS (
        SELECT 1 FROM dbo.OPDTokenSequence
        WHERE  BranchId = @BranchId AND TokenDate = @TokenDate
    )
        INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, LastSeq)
        VALUES (@BranchId, @TokenDate, 0);

    UPDATE dbo.OPDTokenSequence
    SET    LastSeq = LastSeq + 1
    WHERE  BranchId = @BranchId AND TokenDate = @TokenDate;

    DECLARE @Seq INT;
    SELECT  @Seq = LastSeq
    FROM    dbo.OPDTokenSequence
    WHERE   BranchId = @BranchId AND TokenDate = @TokenDate;

    SET @TokenNo = @BranchCode + '-' + RIGHT('0000' + CAST(@Seq AS NVARCHAR(10)), 4);
END
GO

-- ── 2. Create usp_OPD_AssignTokenOnPayment ────────────────────────────────────

CREATE OR ALTER PROCEDURE dbo.usp_OPD_AssignTokenOnPayment
    @OPDServiceId   INT,
    @TokenNo        NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(VisitDate AS DATE),
                @ExistingToken   = TokenNo
        FROM    dbo.PatientOPDService WITH (UPDLOCK, ROWLOCK)
        WHERE   OPDServiceId = @OPDServiceId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;
            COMMIT TRANSACTION;
            RETURN;
        END

        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;

        UPDATE dbo.PatientOPDService
        SET    TokenNo = @TokenNo
        WHERE  OPDServiceId = @OPDServiceId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- ── 3. usp_Patient_Create — remove token generation, set TokenNo = NULL ───────

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @PatientCode            NVARCHAR(30)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
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

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        SET @Now = SYSUTCDATETIME();

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

        -- Generate Bill No (unchanged)
        EXEC dbo.usp_OPD_GetNextBillNo @BranchId, @OPDBillNo OUTPUT;

        -- Token is NOT generated here — NULL until full payment
        SET @TokenNo = NULL;

        -- Calculate total
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

-- ── 4. usp_Patient_Update — remove token generation for new visits ─────────────

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
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

PRINT 'Script 35 complete: Token generation moved to post-full-payment flow.';
PRINT '  - usp_OPD_GetNextTokenNo: now accepts optional @TokenDate param.';
PRINT '  - usp_OPD_AssignTokenOnPayment: new SP for post-payment token assign.';
PRINT '  - usp_Patient_Create / usp_Patient_Update: TokenNo = NULL for non-zero bills.';
PRINT '  - Exception: zero-amount bills auto-assign token immediately.';
GO
