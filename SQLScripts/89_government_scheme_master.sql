-- ====================================================================================================
-- Script: 89_government_scheme_master.sql
-- Description: Creates dbo.GovernmentSchemeMaster table and Stored Procedures for Government Scheme Master
--              (CGHS, ECHS, Ayushman Bharat PM-JAY, State Scheme, PSU Scheme, ESIC, CAPF, etc.)
--              supporting RuleConfigJSON and Indian Government standard features.
-- ====================================================================================================

-- 1. Create dbo.GovernmentSchemeMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'GovernmentSchemeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.GovernmentSchemeMaster
    (
        Scheme_ID            INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        SchemeCode           NVARCHAR(50) NOT NULL,
        SchemeName           NVARCHAR(200) NOT NULL,
        SchemeType           NVARCHAR(100) NOT NULL, -- Central Government, State Government, Defence / Ex-Servicemen, PSU / Autonomous Body, Social Security / Labour
        AuthorityName        NVARCHAR(200) NOT NULL, -- e.g. National Health Authority (NHA), MoHFW, Central Org ECHS, State Health Agency (SHA), etc.
        RuleConfigJSON       NVARCHAR(MAX) NULL,     -- Scheme-specific configurable rules (Annual coverage, Pre-auth, Biometric, Co-pay, TMS portal, Documents)
        Effective_From       DATETIME2 NOT NULL,
        Effective_To         DATETIME2 NOT NULL,
        IsActive             BIT NOT NULL DEFAULT 1,
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_GovScheme_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_GovScheme_Branch_Type ON dbo.GovernmentSchemeMaster(Branch_ID, SchemeType, IsActive);
    CREATE INDEX IX_GovScheme_Code ON dbo.GovernmentSchemeMaster(SchemeCode);
    PRINT 'Created table dbo.GovernmentSchemeMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.GovernmentSchemeMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_GovernmentScheme_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_GetList
    @BranchId    INT = NULL,
    @SchemeType  NVARCHAR(100) = NULL,
    @IsActive    BIT = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        gs.Scheme_ID,
        gs.CompanyId,
        gs.Branch_ID,
        b.BranchName,
        b.BranchCode,
        gs.SchemeCode,
        gs.SchemeName,
        gs.SchemeType,
        gs.AuthorityName,
        gs.RuleConfigJSON,
        gs.Effective_From,
        gs.Effective_To,
        gs.IsActive,
        gs.CreatedBy,
        gs.CreatedDate,
        gs.ModifiedBy,
        gs.ModifiedDate
    FROM dbo.GovernmentSchemeMaster gs
    INNER JOIN dbo.Branchmaster b ON gs.Branch_ID = b.BranchID
    WHERE (@BranchId IS NULL OR gs.Branch_ID = @BranchId)
      AND (@SchemeType IS NULL OR @SchemeType = '' OR gs.SchemeType = @SchemeType)
      AND (@IsActive IS NULL OR gs.IsActive = @IsActive)
      AND (@CompanyId IS NULL OR gs.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           gs.SchemeCode LIKE '%' + @Search + '%' OR
           gs.SchemeName LIKE '%' + @Search + '%' OR
           gs.SchemeType LIKE '%' + @Search + '%' OR
           gs.AuthorityName LIKE '%' + @Search + '%')
    ORDER BY gs.Scheme_ID DESC;
END
GO

-- 3. Stored Procedure: usp_Api_GovernmentScheme_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_GetById
    @Scheme_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        gs.Scheme_ID,
        gs.CompanyId,
        gs.Branch_ID,
        b.BranchName,
        b.BranchCode,
        gs.SchemeCode,
        gs.SchemeName,
        gs.SchemeType,
        gs.AuthorityName,
        gs.RuleConfigJSON,
        gs.Effective_From,
        gs.Effective_To,
        gs.IsActive,
        gs.CreatedBy,
        gs.CreatedDate,
        gs.ModifiedBy,
        gs.ModifiedDate
    FROM dbo.GovernmentSchemeMaster gs
    INNER JOIN dbo.Branchmaster b ON gs.Branch_ID = b.BranchID
    WHERE gs.Scheme_ID = @Scheme_ID;
END
GO

-- 4. Stored Procedure: usp_Api_GovernmentScheme_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_Create
    @CompanyId       INT = 1,
    @Branch_ID       INT,
    @SchemeCode      NVARCHAR(50),
    @SchemeName      NVARCHAR(200),
    @SchemeType      NVARCHAR(100),
    @AuthorityName   NVARCHAR(200),
    @RuleConfigJSON  NVARCHAR(MAX) = NULL,
    @Effective_From  DATETIME2,
    @Effective_To    DATETIME2,
    @IsActive        BIT = 1,
    @CreatedBy       INT = NULL,
    @NewScheme_ID    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Prevent duplicate scheme codes in same branch
    IF EXISTS (SELECT 1 FROM dbo.GovernmentSchemeMaster WHERE Branch_ID = @Branch_ID AND SchemeCode = @SchemeCode)
    BEGIN
        RAISERROR('A government scheme with this Scheme Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    INSERT INTO dbo.GovernmentSchemeMaster
    (
        CompanyId,
        Branch_ID,
        SchemeCode,
        SchemeName,
        SchemeType,
        AuthorityName,
        RuleConfigJSON,
        Effective_From,
        Effective_To,
        IsActive,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @SchemeCode,
        @SchemeName,
        @SchemeType,
        @AuthorityName,
        @RuleConfigJSON,
        @Effective_From,
        @Effective_To,
        @IsActive,
        @CreatedBy,
        GETDATE()
    );

    SET @NewScheme_ID = SCOPE_IDENTITY();
END
GO

-- 5. Stored Procedure: usp_Api_GovernmentScheme_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_Update
    @Scheme_ID       INT,
    @Branch_ID       INT,
    @SchemeCode      NVARCHAR(50),
    @SchemeName      NVARCHAR(200),
    @SchemeType      NVARCHAR(100),
    @AuthorityName   NVARCHAR(200),
    @RuleConfigJSON  NVARCHAR(MAX) = NULL,
    @Effective_From  DATETIME2,
    @Effective_To    DATETIME2,
    @IsActive        BIT = 1,
    @ModifiedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Prevent duplicate scheme codes in same branch excluding current
    IF EXISTS (SELECT 1 FROM dbo.GovernmentSchemeMaster WHERE Branch_ID = @Branch_ID AND SchemeCode = @SchemeCode AND Scheme_ID <> @Scheme_ID)
    BEGIN
        RAISERROR('Another government scheme with this Scheme Code already exists for the selected branch.', 16, 1);
        RETURN;
    END

    UPDATE dbo.GovernmentSchemeMaster
    SET
        Branch_ID       = @Branch_ID,
        SchemeCode      = @SchemeCode,
        SchemeName      = @SchemeName,
        SchemeType      = @SchemeType,
        AuthorityName   = @AuthorityName,
        RuleConfigJSON  = @RuleConfigJSON,
        Effective_From  = @Effective_From,
        Effective_To    = @Effective_To,
        IsActive        = @IsActive,
        ModifiedBy      = @ModifiedBy,
        ModifiedDate    = GETDATE()
    WHERE Scheme_ID     = @Scheme_ID;
END
GO

-- 6. Stored Procedure: usp_Api_GovernmentScheme_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_ToggleStatus
    @Scheme_ID   INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.GovernmentSchemeMaster
    SET 
        IsActive = CASE WHEN IsActive = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE Scheme_ID = @Scheme_ID;

    SELECT IsActive FROM dbo.GovernmentSchemeMaster WHERE Scheme_ID = @Scheme_ID;
END
GO

-- 7. Stored Procedure: usp_Api_GovernmentScheme_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_GovernmentScheme_Delete
    @Scheme_ID   INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.GovernmentSchemeMaster
    WHERE Scheme_ID = @Scheme_ID;
END
GO

-- 8. Seed Initial Realistic Indian Government Schemes
IF NOT EXISTS (SELECT 1 FROM dbo.GovernmentSchemeMaster)
BEGIN
    DECLARE @DefaultBranch INT;
    SELECT TOP 1 @DefaultBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @DefaultBranch IS NOT NULL
    BEGIN
        -- 1. Ayushman Bharat – PM-JAY
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'PMJAY-01', 'Ayushman Bharat – Pradhan Mantri Jan Arogya Yojana (PM-JAY)', 'Central Government', 'National Health Authority (NHA)',
         '{"AnnualCoverageLimit":500000.00,"PreAuthMandatory":true,"BiometricAuthRequired":true,"AbhaCreationMandatory":true,"CoPayPercentage":0.00,"MaxClaimSubmissionDays":7,"PackageRateDiscountPercent":0.00,"DefaultBedCategory":"General Ward","TMSPortalUrl":"https://tms.pmjay.gov.in","NHA_SchemeCode":"PMJAY_V2","BeneficiaryIdType":"PM-JAY Golden Card / Aadhaar / Ration Card","MandatoryDocuments":["PM-JAY Golden Card / e-Card","Aadhaar Card","Ration Card","Pre-Authorization Approval Letter","Discharge Summary"],"SpecialRemarks":"100% Cashless secondary and tertiary hospitalisation coverage up to Rs 5 Lakh per family per year."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        -- 2. Central Government Health Scheme (CGHS)
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'CGHS-DEL', 'Central Government Health Scheme (CGHS)', 'Central Government', 'Ministry of Health & Family Welfare (MoHFW)',
         '{"AnnualCoverageLimit":0.00,"PreAuthMandatory":true,"BiometricAuthRequired":true,"AbhaCreationMandatory":true,"CoPayPercentage":0.00,"MaxClaimSubmissionDays":15,"PackageRateDiscountPercent":0.00,"DefaultBedCategory":"Semi-Private / Private as per Pay Matrix","TMSPortalUrl":"https://cghs.nic.in","NHA_SchemeCode":"CGHS_CENTRAL","BeneficiaryIdType":"CGHS Plastic Card / Beneficiary ID","MandatoryDocuments":["CGHS Beneficiary Card","Referral Letter from CGHS Dispensary/Wellness Centre","Permission Letter","Discharge Summary"],"SpecialRemarks":"Comprehensive healthcare for central government employees, pensioners, and eligible dependents."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        -- 3. Ex-Servicemen Contributory Health Scheme (ECHS)
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'ECHS-HQ', 'Ex-Servicemen Contributory Health Scheme (ECHS)', 'Defence / Ex-Servicemen', 'Central Organisation ECHS / Ministry of Defence',
         '{"AnnualCoverageLimit":0.00,"PreAuthMandatory":true,"BiometricAuthRequired":true,"AbhaCreationMandatory":false,"CoPayPercentage":0.00,"MaxClaimSubmissionDays":30,"PackageRateDiscountPercent":0.00,"DefaultBedCategory":"As per Rank / Entitlement","TMSPortalUrl":"https://echs.gov.in","NHA_SchemeCode":"ECHS_DEFENCE","BeneficiaryIdType":"ECHS 64Kb Smart Card","MandatoryDocuments":["ECHS 64Kb Smart Card","Polyclinic Referral Slip","Emergency Certificate (if unreferred)","Discharge Summary"],"SpecialRemarks":"Cashless treatment for Armed Forces veterans, war widows, and their legitimate dependents across empaneled hospitals."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        -- 4. Swasthya Sathi Scheme
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'SWS-WB', 'Swasthya Sathi Scheme', 'State Government', 'State Health Agency - Government of West Bengal',
         '{"AnnualCoverageLimit":500000.00,"PreAuthMandatory":true,"BiometricAuthRequired":true,"AbhaCreationMandatory":false,"CoPayPercentage":0.00,"MaxClaimSubmissionDays":7,"PackageRateDiscountPercent":0.00,"DefaultBedCategory":"General Ward","TMSPortalUrl":"https://swasthyasathi.gov.in","NHA_SchemeCode":"SWS_WB_01","BeneficiaryIdType":"Swasthya Sathi Smart Card (Family Head: Female)","MandatoryDocuments":["Swasthya Sathi Smart Card","Aadhaar Card of Patient","Pre-Authorization Approval Slip","Discharge Summary"],"SpecialRemarks":"Flagship universal health insurance scheme of Government of West Bengal covering up to Rs 5 Lakh per family per annum."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        -- 5. Employees State Insurance Scheme (ESIC)
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'ESIC-HQ', 'Employees State Insurance Corporation (ESIC)', 'Social Security / Labour', 'Ministry of Labour & Employment - ESIC',
         '{"AnnualCoverageLimit":0.00,"PreAuthMandatory":true,"BiometricAuthRequired":true,"AbhaCreationMandatory":true,"CoPayPercentage":0.00,"MaxClaimSubmissionDays":15,"PackageRateDiscountPercent":0.00,"DefaultBedCategory":"General Ward","TMSPortalUrl":"https://esic.gov.in","NHA_SchemeCode":"ESIC_SOCIAL","BeneficiaryIdType":"ESIC Pehchan Card / IP Number","MandatoryDocuments":["ESIC Pehchan Card","Referral Letter from ESI Hospital / Dispensary (Form 16)","IP Contribution Status Slip","Discharge Summary"],"SpecialRemarks":"Full medical care and cash benefits for insured persons and dependent family members in the formal organized workforce."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        -- 6. PSU Scheme: SAIL Medical Scheme
        INSERT INTO dbo.GovernmentSchemeMaster
        (CompanyId, Branch_ID, SchemeCode, SchemeName, SchemeType, AuthorityName, RuleConfigJSON, Effective_From, Effective_To, IsActive, CreatedDate)
        VALUES
        (1, @DefaultBranch, 'PSU-SAIL', 'Steel Authority of India Ltd (SAIL) Mediclaim Scheme', 'PSU / Autonomous Body', 'SAIL Corporate Medical Directorate',
         '{"AnnualCoverageLimit":400000.00,"PreAuthMandatory":true,"BiometricAuthRequired":false,"AbhaCreationMandatory":false,"CoPayPercentage":5.00,"MaxClaimSubmissionDays":30,"PackageRateDiscountPercent":10.00,"DefaultBedCategory":"As per Grade (Non-Executive / Executive)","TMSPortalUrl":"https://sail.co.in","NHA_SchemeCode":"PSU_SAIL_MED","BeneficiaryIdType":"SAIL Medical Booklet / Employee ID","MandatoryDocuments":["SAIL Medical Card / Booklet","Employee Referral from Plant Hospital","Pre-Authorization Letter","Discharge Summary"],"SpecialRemarks":"Indoor hospitalisation coverage for serving and retired employees of Steel Authority of India Ltd."}',
         GETDATE(), DATEADD(YEAR, 5, GETDATE()), 1, GETDATE());

        PRINT 'Sample Indian Government schemes seeded successfully.';
    END
END
GO
