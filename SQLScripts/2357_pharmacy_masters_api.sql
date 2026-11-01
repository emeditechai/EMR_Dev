-- ============================================================================================================
-- Migration: 2357_pharmacy_masters_api.sql
-- Pharmacy masters through EMR.Api (API + stored procedures, like LAB / OPD).
--   Simple masters: usp_Api_Ph<Table>_GetList / usp_Api_Ph<Table>_Save (one pair per master; generated from the
--   master definitions in EMR.Web/Services/PharmacyMasterService.cs - keep them in step).
--   usp_Api_PhMaster_Lookups, usp_Api_Ph_BranchCode, Item Master: usp_Api_PhItem_*.
-- No table changes. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── generics (PhGeneric) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGeneric_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT GenericId, GenericName, TherapeuticClass, IsActive FROM dbo.PhGeneric
     WHERE CompanyId = @CompanyId
     ORDER BY GenericName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhGeneric_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @GenericName NVARCHAR(250) = NULL,
    @TherapeuticClass NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhGeneric (CompanyId, GenericName, TherapeuticClass, IsActive, CreatedBy)
            VALUES (@CompanyId, @GenericName, @TherapeuticClass, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhGeneric SET GenericName = @GenericName, TherapeuticClass = @TherapeuticClass, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE GenericId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This generic already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── manufacturers (PhManufacturer) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhManufacturer_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ManufacturerId, ManufacturerName, ShortCode, Address, IsActive FROM dbo.PhManufacturer
     WHERE CompanyId = @CompanyId
     ORDER BY ManufacturerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhManufacturer_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @ManufacturerName NVARCHAR(150) = NULL,
    @ShortCode NVARCHAR(20) = NULL,
    @Address NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhManufacturer (CompanyId, ManufacturerName, ShortCode, Address, IsActive, CreatedBy)
            VALUES (@CompanyId, @ManufacturerName, @ShortCode, @Address, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhManufacturer SET ManufacturerName = @ManufacturerName, ShortCode = @ShortCode, Address = @Address, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE ManufacturerId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This manufacturer already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── suppliers (PhSupplier) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplier_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SupplierId, SupplierCode, SupplierName, ContactPerson, Phone, Email, Address, City, StateId, Pincode, Gstin, Pan, CreditDays, DrugLicenceNo, DrugLicenceValidTo, BankName, BankAccountNo, BankIfsc, Remarks, IsActive FROM dbo.PhSupplier
     WHERE CompanyId = @CompanyId
     ORDER BY SupplierName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSupplier_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @SupplierCode NVARCHAR(20) = NULL,
    @SupplierName NVARCHAR(150) = NULL,
    @ContactPerson NVARCHAR(100) = NULL,
    @Phone NVARCHAR(30) = NULL,
    @Email NVARCHAR(150) = NULL,
    @Address NVARCHAR(300) = NULL,
    @City NVARCHAR(80) = NULL,
    @StateId INT = NULL,
    @Pincode NVARCHAR(10) = NULL,
    @Gstin VARCHAR(15) = NULL,
    @Pan VARCHAR(10) = NULL,
    @CreditDays INT = NULL,
    @DrugLicenceNo NVARCHAR(100) = NULL,
    @DrugLicenceValidTo DATE = NULL,
    @BankName NVARCHAR(100) = NULL,
    @BankAccountNo NVARCHAR(30) = NULL,
    @BankIfsc NVARCHAR(15) = NULL,
    @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF NULLIF(LTRIM(RTRIM(@SupplierCode)), N'') IS NULL
            SELECT @SupplierCode = 'SUP' + RIGHT('0000' + CAST(ISNULL(MAX(SupplierId), 0) + 1 AS VARCHAR(10)), 4) FROM dbo.PhSupplier WITH (UPDLOCK, HOLDLOCK);
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhSupplier (CompanyId, SupplierCode, SupplierName, ContactPerson, Phone, Email, Address, City, StateId, Pincode, Gstin, Pan, CreditDays, DrugLicenceNo, DrugLicenceValidTo, BankName, BankAccountNo, BankIfsc, Remarks, IsActive, CreatedBy)
            VALUES (@CompanyId, @SupplierCode, @SupplierName, @ContactPerson, @Phone, @Email, @Address, @City, @StateId, @Pincode, @Gstin, @Pan, @CreditDays, @DrugLicenceNo, @DrugLicenceValidTo, @BankName, @BankAccountNo, @BankIfsc, @Remarks, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhSupplier SET SupplierCode = @SupplierCode, SupplierName = @SupplierName, ContactPerson = @ContactPerson, Phone = @Phone, Email = @Email, Address = @Address, City = @City, StateId = @StateId, Pincode = @Pincode, Gstin = @Gstin, Pan = @Pan, CreditDays = @CreditDays, DrugLicenceNo = @DrugLicenceNo, DrugLicenceValidTo = @DrugLicenceValidTo, BankName = @BankName, BankAccountNo = @BankAccountNo, BankIfsc = @BankIfsc, Remarks = @Remarks, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SupplierId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This supplier already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── categories (PhCategory) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhCategory_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CategoryId, CategoryName, ParentCategoryId, SortOrder, IsActive FROM dbo.PhCategory
     WHERE CompanyId = @CompanyId
     ORDER BY ISNULL(ParentCategoryId, CategoryId), ParentCategoryId, SortOrder, CategoryName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhCategory_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @CategoryName NVARCHAR(100) = NULL,
    @ParentCategoryId INT = NULL,
    @SortOrder INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhCategory (CompanyId, CategoryName, ParentCategoryId, SortOrder, IsActive, CreatedBy)
            VALUES (@CompanyId, @CategoryName, @ParentCategoryId, @SortOrder, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhCategory SET CategoryName = @CategoryName, ParentCategoryId = @ParentCategoryId, SortOrder = @SortOrder, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE CategoryId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This category already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── dosageforms (PhDosageForm) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDosageForm_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DosageFormId, DosageFormName, ShortName, SortOrder, IsActive FROM dbo.PhDosageForm
     WHERE CompanyId = @CompanyId
     ORDER BY SortOrder, DosageFormName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDosageForm_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @DosageFormName NVARCHAR(60) = NULL,
    @ShortName NVARCHAR(10) = NULL,
    @SortOrder INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhDosageForm (CompanyId, DosageFormName, ShortName, SortOrder, IsActive, CreatedBy)
            VALUES (@CompanyId, @DosageFormName, @ShortName, @SortOrder, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhDosageForm SET DosageFormName = @DosageFormName, ShortName = @ShortName, SortOrder = @SortOrder, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE DosageFormId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This dosage form already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── units (PhUom) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhUom_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UomId, UomCode, UomName, SortOrder, IsActive FROM dbo.PhUom
     WHERE CompanyId = @CompanyId
     ORDER BY SortOrder, UomCode;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhUom_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @UomCode NVARCHAR(10) = NULL,
    @UomName NVARCHAR(50) = NULL,
    @SortOrder INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhUom (CompanyId, UomCode, UomName, SortOrder, IsActive, CreatedBy)
            VALUES (@CompanyId, @UomCode, @UomName, @SortOrder, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhUom SET UomCode = @UomCode, UomName = @UomName, SortOrder = @SortOrder, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE UomId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This unit already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── hsn (PhHsn) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhHsn_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT HsnId, HsnCode, Description, GstPercent, CessPercent, EffectiveFrom, IsActive FROM dbo.PhHsn
     WHERE CompanyId = @CompanyId
     ORDER BY HsnCode;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhHsn_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @HsnCode VARCHAR(10) = NULL,
    @Description NVARCHAR(200) = NULL,
    @GstPercent DECIMAL(5,2) = NULL,
    @CessPercent DECIMAL(5,2) = NULL,
    @EffectiveFrom DATE = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @oldGst DECIMAL(9,2), @oldCess DECIMAL(9,2), @oldFrom DATE;
        IF @Id > 0 SELECT @oldGst = GstPercent, @oldCess = CessPercent, @oldFrom = EffectiveFrom FROM dbo.PhHsn WHERE HsnId = @Id AND CompanyId = @CompanyId;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhHsn (CompanyId, HsnCode, Description, GstPercent, CessPercent, EffectiveFrom, IsActive, CreatedBy)
            VALUES (@CompanyId, @HsnCode, @Description, @GstPercent, @CessPercent, @EffectiveFrom, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhHsn SET HsnCode = @HsnCode, Description = @Description, GstPercent = @GstPercent, CessPercent = @CessPercent, EffectiveFrom = @EffectiveFrom, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE HsnId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        IF @oldGst IS NULL OR @oldGst <> ISNULL(@GstPercent, 0) OR @oldCess <> ISNULL(@CessPercent, 0) OR @oldFrom <> @EffectiveFrom
            INSERT dbo.PhHsnRateHistory (HsnId, GstPercent, CessPercent, EffectiveFrom, CreatedBy) VALUES (@Id, ISNULL(@GstPercent, 0), ISNULL(@CessPercent, 0), @EffectiveFrom, @UserId);
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This HSN code already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── schedules (PhDrugSchedule) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDrugSchedule_GetList
    @CompanyId INT = NULL, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ScheduleCode, ScheduleName, RxRequired, RegisterRequired, IsNarcotic, LabelWarning, CAST(1 AS BIT) AS IsActive FROM dbo.PhDrugSchedule ORDER BY SortOrder;
END
GO

-- ── pricerules (PhPriceRule) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPriceRule_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT PriceRuleId, RuleName, PatientType, CategoryId, PriceBasis, RatePercent, Priority, IsActive FROM dbo.PhPriceRule
     WHERE CompanyId = @CompanyId
     ORDER BY PatientType, Priority, RuleName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPriceRule_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @RuleName NVARCHAR(100) = NULL,
    @PatientType VARCHAR(20) = NULL,
    @CategoryId INT = NULL,
    @PriceBasis VARCHAR(10) = NULL,
    @RatePercent DECIMAL(6,2) = NULL,
    @Priority INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhPriceRule (CompanyId, RuleName, PatientType, CategoryId, PriceBasis, RatePercent, Priority, IsActive, CreatedBy)
            VALUES (@CompanyId, @RuleName, @PatientType, @CategoryId, @PriceBasis, @RatePercent, @Priority, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhPriceRule SET RuleName = @RuleName, PatientType = @PatientType, CategoryId = @CategoryId, PriceBasis = @PriceBasis, RatePercent = @RatePercent, Priority = @Priority, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE PriceRuleId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This price rule already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── discounts (PhDiscountScheme) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDiscountScheme_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SchemeId, SchemeName, DiscountType, DiscountValue, AppliesTo, CategoryId, CustomerType, MinBillAmount, ValidFrom, ValidTo, IsActive FROM dbo.PhDiscountScheme
     WHERE CompanyId = @CompanyId
     ORDER BY SchemeName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDiscountScheme_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @SchemeName NVARCHAR(100) = NULL,
    @DiscountType VARCHAR(10) = NULL,
    @DiscountValue DECIMAL(10,2) = NULL,
    @AppliesTo VARCHAR(20) = NULL,
    @CategoryId INT = NULL,
    @CustomerType VARCHAR(20) = NULL,
    @MinBillAmount DECIMAL(12,2) = NULL,
    @ValidFrom DATE = NULL,
    @ValidTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhDiscountScheme (CompanyId, SchemeName, DiscountType, DiscountValue, AppliesTo, CategoryId, CustomerType, MinBillAmount, ValidFrom, ValidTo, IsActive, CreatedBy)
            VALUES (@CompanyId, @SchemeName, @DiscountType, @DiscountValue, @AppliesTo, @CategoryId, @CustomerType, @MinBillAmount, @ValidFrom, @ValidTo, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhDiscountScheme SET SchemeName = @SchemeName, DiscountType = @DiscountType, DiscountValue = @DiscountValue, AppliesTo = @AppliesTo, CategoryId = @CategoryId, CustomerType = @CustomerType, MinBillAmount = @MinBillAmount, ValidFrom = @ValidFrom, ValidTo = @ValidTo, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SchemeId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This discount scheme already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── customers (PhCustomer) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhCustomer_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CustomerId, CustomerName, Mobile, CustomerType, Email, Gstin, Address, CreditAllowed, CreditLimit, SchemeId, IsActive FROM dbo.PhCustomer
     WHERE CompanyId = @CompanyId
     ORDER BY CustomerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhCustomer_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @CustomerName NVARCHAR(150) = NULL,
    @Mobile NVARCHAR(15) = NULL,
    @CustomerType VARCHAR(20) = NULL,
    @Email NVARCHAR(150) = NULL,
    @Gstin VARCHAR(15) = NULL,
    @Address NVARCHAR(300) = NULL,
    @CreditAllowed BIT = NULL,
    @CreditLimit DECIMAL(12,2) = NULL,
    @SchemeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhCustomer (CompanyId, CustomerName, Mobile, CustomerType, Email, Gstin, Address, CreditAllowed, CreditLimit, SchemeId, IsActive, CreatedBy)
            VALUES (@CompanyId, @CustomerName, @Mobile, @CustomerType, @Email, @Gstin, @Address, @CreditAllowed, @CreditLimit, @SchemeId, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhCustomer SET CustomerName = @CustomerName, Mobile = @Mobile, CustomerType = @CustomerType, Email = @Email, Gstin = @Gstin, Address = @Address, CreditAllowed = @CreditAllowed, CreditLimit = @CreditLimit, SchemeId = @SchemeId, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE CustomerId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This customer already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── reasons (PhReason) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhReason_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ReasonId, ReasonType, ReasonName, SortOrder, IsActive FROM dbo.PhReason
     WHERE CompanyId = @CompanyId
     ORDER BY ReasonType, SortOrder, ReasonName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhReason_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @ReasonType VARCHAR(20) = NULL,
    @ReasonName NVARCHAR(150) = NULL,
    @SortOrder INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhReason (CompanyId, ReasonType, ReasonName, SortOrder, IsActive, CreatedBy)
            VALUES (@CompanyId, @ReasonType, @ReasonName, @SortOrder, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhReason SET ReasonType = @ReasonType, ReasonName = @ReasonName, SortOrder = @SortOrder, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE ReasonId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This reason already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── numberseries (PhNumberSeries) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhNumberSeries_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SeriesId, DocName, DocType, Prefix, Padding, ResetYearly, IsActive FROM dbo.PhNumberSeries
     WHERE CompanyId = @CompanyId AND BranchId = @BranchId
     ORDER BY SeriesId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhNumberSeries_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @Prefix VARCHAR(10) = NULL,
    @Padding INT = NULL,
    @ResetYearly BIT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            SELECT 0 AS Id, N'New entries cannot be added here.' AS Error; ROLLBACK; RETURN;
        END
        ELSE
        BEGIN
            UPDATE dbo.PhNumberSeries SET Prefix = @Prefix, Padding = @Padding, ResetYearly = @ResetYearly, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SeriesId = @Id AND CompanyId = @CompanyId AND BranchId = @BranchId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This number series already exists.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── shared ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ph_BranchCode
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL((SELECT BranchCode FROM dbo.BranchMaster WHERE BranchID = @BranchId), CAST(@BranchId AS VARCHAR(10))) AS BranchCode;
END
GO

-- lookups of the simple masters: 1 states, 2 main categories, 3 categories, 4 discount schemes
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhMaster_Lookups
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(StateId AS VARCHAR(10)) AS Value, StateName AS Text FROM dbo.StateMaster WHERE IsActive = 1 ORDER BY StateName;
    SELECT CAST(CategoryId AS VARCHAR(10)) AS Value, CategoryName AS Text FROM dbo.PhCategory WHERE CompanyId = @CompanyId AND ParentCategoryId IS NULL ORDER BY SortOrder, CategoryName;
    SELECT CAST(c.CategoryId AS VARCHAR(10)) AS Value, CASE WHEN p.CategoryId IS NULL THEN c.CategoryName ELSE p.CategoryName + N' › ' + c.CategoryName END AS Text
      FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
     WHERE c.CompanyId = @CompanyId AND c.IsActive = 1 ORDER BY ISNULL(p.SortOrder, c.SortOrder), ISNULL(p.CategoryName, c.CategoryName), c.ParentCategoryId, c.SortOrder;
    SELECT CAST(SchemeId AS VARCHAR(10)) AS Value, SchemeName AS Text FROM dbo.PhDiscountScheme WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SchemeName;
END
GO

-- ── Item Master ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_GetList
    @CompanyId INT, @BranchId INT, @Search NVARCHAR(200) = NULL, @CategoryId INT = NULL, @Schedule VARCHAR(10) = NULL,
    @ManufacturerId INT = NULL, @Active BIT = NULL, @Page INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%', @skip INT = (CASE WHEN @Page < 1 THEN 0 ELSE @Page - 1 END) * @PageSize;
    SELECT i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName,
               CASE WHEN pc.CategoryId IS NULL THEN c.CategoryName ELSE pc.CategoryName + N' › ' + c.CategoryName END AS CategoryName,
               i.ScheduleCode, h.HsnCode, h.GstPercent, pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty,
               i.IsColdChain, i.IsHighAlert, i.IsLasa, i.PrescriptionRequired, ib.RackNo, i.IsActive, COUNT(*) OVER () AS TotalCount
          FROM dbo.PhItem i
          JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
          JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
          JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
          LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
          LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
          LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
          LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
     WHERE i.CompanyId = @CompanyId
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode LIKE @like OR g.GenericName LIKE @like OR i.Barcode = @Search)
       AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId OR c.ParentCategoryId = @CategoryId)
       AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule)
       AND (@ManufacturerId IS NULL OR i.ManufacturerId = @ManufacturerId)
       AND (@Active IS NULL OR i.IsActive = @Active)
     ORDER BY i.ItemName OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Search
    @CompanyId INT, @Q NVARCHAR(200), @Take INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%', @starts NVARCHAR(210) = @Q + N'%';
    SELECT TOP (@Take) i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName,
               CASE WHEN pc.CategoryId IS NULL THEN c.CategoryName ELSE pc.CategoryName + N' › ' + c.CategoryName END AS CategoryName,
               i.ScheduleCode, h.HsnCode, h.GstPercent, pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty,
               i.IsColdChain, i.IsHighAlert, i.IsLasa, i.PrescriptionRequired, ib.RackNo, i.IsActive
          FROM dbo.PhItem i
          JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
          JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
          JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
          LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
          LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
          LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
          LEFT JOIN dbo.PhItemBranch ib ON 1 = 0
     WHERE i.CompanyId = @CompanyId AND (i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q)
     ORDER BY CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Substitutes
    @CompanyId INT, @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName,
               CASE WHEN pc.CategoryId IS NULL THEN c.CategoryName ELSE pc.CategoryName + N' › ' + c.CategoryName END AS CategoryName,
               i.ScheduleCode, h.HsnCode, h.GstPercent, pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty,
               i.IsColdChain, i.IsHighAlert, i.IsLasa, i.PrescriptionRequired, ib.RackNo, i.IsActive
          FROM dbo.PhItem i
          JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
          JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
          JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
          LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
          LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
          LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
          LEFT JOIN dbo.PhItemBranch ib ON 1 = 0
     WHERE i.CompanyId = @CompanyId AND i.ItemId <> @ItemId AND i.GenericId IS NOT NULL
       AND i.GenericId = (SELECT GenericId FROM dbo.PhItem WHERE ItemId = @ItemId)
     ORDER BY i.ItemName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_GetById
    @CompanyId INT, @BranchId INT, @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.*, ib.RackNo, ib.ReorderLevel AS BranchReorderLevel, ib.MinQty AS BranchMinQty, ib.MaxQty AS BranchMaxQty, ISNULL(ib.IsStocked, 1) AS IsStocked
      FROM dbo.PhItem i LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
     WHERE i.ItemId = @ItemId AND i.CompanyId = @CompanyId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Counts
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COUNT(*) AS Total, ISNULL(SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END), 0) AS Active FROM dbo.PhItem WHERE CompanyId = @CompanyId;
END
GO

-- lookups of the Item form: 1 generics, 2 manufacturers, 3 categories, 4 dosage forms, 5 units, 6 HSN, 7 schedules
-- (inactive generics / manufacturers stay in the lists, marked, so an item that already uses one still shows it)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Lookups
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(GenericId AS VARCHAR(10)) AS Value, GenericName + CASE WHEN IsActive = 0 THEN N' (inactive)' ELSE N'' END AS Text FROM dbo.PhGeneric WHERE CompanyId = @CompanyId ORDER BY GenericName;
    SELECT CAST(ManufacturerId AS VARCHAR(10)) AS Value, ManufacturerName + CASE WHEN IsActive = 0 THEN N' (inactive)' ELSE N'' END AS Text FROM dbo.PhManufacturer WHERE CompanyId = @CompanyId ORDER BY ManufacturerName;
    SELECT CAST(c.CategoryId AS VARCHAR(10)) AS Value, CASE WHEN p.CategoryId IS NULL THEN c.CategoryName ELSE p.CategoryName + N' › ' + c.CategoryName END AS Text
      FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
     WHERE c.CompanyId = @CompanyId AND c.IsActive = 1 ORDER BY ISNULL(p.SortOrder, c.SortOrder), ISNULL(p.CategoryName, c.CategoryName), c.ParentCategoryId, c.SortOrder;
    SELECT CAST(DosageFormId AS VARCHAR(10)) AS Value, DosageFormName + ISNULL(N' (' + ShortName + N')', N'') AS Text FROM dbo.PhDosageForm WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SortOrder, DosageFormName;
    SELECT CAST(UomId AS VARCHAR(10)) AS Value, UomName + N' (' + UomCode + N')' AS Text FROM dbo.PhUom WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SortOrder, UomCode;
    SELECT HsnId AS Id, HsnCode AS Code, Description, GstPercent AS Gst FROM dbo.PhHsn WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY HsnCode;
    SELECT ScheduleCode AS Code, ScheduleName AS Name, LabelWarning AS Warning, RxRequired AS Rx FROM dbo.PhDrugSchedule ORDER BY SortOrder;
END
GO

-- saves the item (company) and its rack / levels for the branch; checks in EMR.Web stay as they were
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Save
    @ItemId INT, @CompanyId INT, @BranchId INT, @UserId INT,
    @ItemCode NVARCHAR(20) = NULL,
    @ItemName NVARCHAR(200) = NULL,
    @GenericId INT = NULL,
    @ManufacturerId INT = NULL,
    @CategoryId INT = NULL,
    @DosageFormId INT = NULL,
    @Strength NVARCHAR(60) = NULL,
    @PackSize NVARCHAR(60) = NULL,
    @ScheduleCode VARCHAR(10) = NULL,
    @HsnId INT = NULL,
    @PurchaseUomId INT = NULL,
    @SaleUomId INT = NULL,
    @ConversionQty INT = NULL,
    @AllowLooseSale BIT = NULL,
    @IsColdChain BIT = NULL,
    @IsHighAlert BIT = NULL,
    @IsLasa BIT = NULL,
    @IsReturnable BIT = NULL,
    @IsDiscountAllowed BIT = NULL,
    @PrescriptionRequired BIT = NULL,
    @Barcode NVARCHAR(50) = NULL,
    @ReorderLevel DECIMAL(12,2) = NULL,
    @MinQty DECIMAL(12,2) = NULL,
    @MaxQty DECIMAL(12,2) = NULL,
    @LeadDays INT = NULL,
    @Remarks NVARCHAR(300) = NULL,
    @IsActive BIT = NULL,
    @RackNo NVARCHAR(30) = NULL, @BranchReorderLevel DECIMAL(12,2) = NULL, @BranchMinQty DECIMAL(12,2) = NULL,
    @BranchMaxQty DECIMAL(12,2) = NULL, @IsStocked BIT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @dup VARCHAR(30) = (SELECT TOP 1 ItemCode FROM dbo.PhItem WHERE CompanyId = @CompanyId AND ItemId <> ISNULL(@ItemId, 0)
            AND ItemName = @ItemName AND ISNULL(ManufacturerId, 0) = ISNULL(@ManufacturerId, 0) AND ISNULL(DosageFormId, 0) = ISNULL(@DosageFormId, 0));
        IF @dup IS NOT NULL BEGIN ROLLBACK; SELECT 0 AS Id, N'The same item of this manufacturer and form already exists (' + @dup + N').' AS Error; RETURN; END

        IF @ItemCode IS NULL
            SELECT @ItemCode = 'PH' + RIGHT('00000' + CAST(ISNULL(MAX(ItemId), 0) + 1 AS VARCHAR(10)), 5) FROM dbo.PhItem WITH (UPDLOCK, HOLDLOCK);

        IF ISNULL(@ItemId, 0) = 0
        BEGIN
            INSERT dbo.PhItem (CompanyId, ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId, PurchaseUomId, SaleUomId, ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, IsLasa, IsReturnable, IsDiscountAllowed, PrescriptionRequired, Barcode, ReorderLevel, MinQty, MaxQty, LeadDays, Remarks, IsActive, CreatedBy)
            VALUES (@CompanyId, @ItemCode, @ItemName, @GenericId, @ManufacturerId, @CategoryId, @DosageFormId, @Strength, @PackSize, @ScheduleCode, @HsnId, @PurchaseUomId, @SaleUomId, @ConversionQty, @AllowLooseSale, @IsColdChain, @IsHighAlert, @IsLasa, @IsReturnable, @IsDiscountAllowed, @PrescriptionRequired, @Barcode, @ReorderLevel, @MinQty, @MaxQty, @LeadDays, @Remarks, @IsActive, @UserId);
            SET @ItemId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhItem SET ItemCode = @ItemCode, ItemName = @ItemName, GenericId = @GenericId, ManufacturerId = @ManufacturerId, CategoryId = @CategoryId, DosageFormId = @DosageFormId, Strength = @Strength, PackSize = @PackSize, ScheduleCode = @ScheduleCode, HsnId = @HsnId, PurchaseUomId = @PurchaseUomId, SaleUomId = @SaleUomId, ConversionQty = @ConversionQty, AllowLooseSale = @AllowLooseSale, IsColdChain = @IsColdChain, IsHighAlert = @IsHighAlert, IsLasa = @IsLasa, IsReturnable = @IsReturnable, IsDiscountAllowed = @IsDiscountAllowed, PrescriptionRequired = @PrescriptionRequired, Barcode = @Barcode, ReorderLevel = @ReorderLevel, MinQty = @MinQty, MaxQty = @MaxQty, LeadDays = @LeadDays, Remarks = @Remarks, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE ItemId = @ItemId AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Item not found.' AS Error; RETURN; END
        END

        MERGE dbo.PhItemBranch AS t USING (SELECT @ItemId AS ItemId, @BranchId AS BranchId) AS s ON t.ItemId = s.ItemId AND t.BranchId = s.BranchId
        WHEN MATCHED THEN UPDATE SET RackNo = @RackNo, ReorderLevel = @BranchReorderLevel, MinQty = @BranchMinQty, MaxQty = @BranchMaxQty, IsStocked = @IsStocked, ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHEN NOT MATCHED THEN INSERT (ItemId, BranchId, RackNo, ReorderLevel, MinQty, MaxQty, IsStocked, ModifiedBy, ModifiedDate)
             VALUES (@ItemId, @BranchId, @RackNo, @BranchReorderLevel, @BranchMinQty, @BranchMaxQty, @IsStocked, @UserId, GETDATE());
        COMMIT;
        SELECT @ItemId AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601)
        BEGIN
            SELECT 0 AS Id, CASE WHEN ERROR_MESSAGE() LIKE N'%Barcode%' THEN N'Another item already has this barcode.' ELSE N'Another item already has this item code.' END AS Error;
            RETURN;
        END;
        THROW;
    END CATCH
END
GO

PRINT 'Script 2357 applied: pharmacy masters - API stored procedures.';
GO
