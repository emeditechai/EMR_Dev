-- =============================================================================
-- Migration: 93_opd_doctor_commission_and_disbursal.sql
-- Description: Creates Doctor Visit Process Config, Doctor Commission Config,
--              Doctor Disbursal, Doctor Billing Adjustment tables,
--              and all stored procedures for CRUD, calculation engine,
--              disbursal payout workflow, and 8 Financial Reports (RPT-01 to RPT-08).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Table: dbo.DoctorVisitProcessConfig
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorVisitProcessConfig' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.DoctorVisitProcessConfig (
        ProcessConfigId       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CompanyId             INT NOT NULL DEFAULT 1,
        BranchId              INT NULL, -- NULL / 0 = All Branches
        SpecialityId          INT NULL, -- NULL / 0 = All Specialties
        DoctorId              INT NULL, -- NULL / 0 = All Doctors
        VisitType             NVARCHAR(50) NOT NULL DEFAULT 'All', -- 'All', 'New', 'Follow-up', 'Emergency', 'Review', 'Consultation'
        PaymentTiming         NVARCHAR(50) NOT NULL DEFAULT 'Before Consultation', -- 'Before Consultation', 'After Consultation', 'At Discharge'
        VitalsRequired        BIT NOT NULL DEFAULT 1,
        DiagnosisRequired     BIT NOT NULL DEFAULT 1,
        Icd10Required         BIT NOT NULL DEFAULT 1,
        ProcedureAllowed      BIT NOT NULL DEFAULT 1,
        BillingRequired       BIT NOT NULL DEFAULT 1,
        PaymentBeforeClosure  BIT NOT NULL DEFAULT 1,
        EffectiveFrom         DATE NOT NULL DEFAULT GETDATE(),
        EffectiveTo           DATE NULL,
        IsActive              BIT NOT NULL DEFAULT 1,
        CreatedDate           DATETIME NOT NULL DEFAULT GETDATE(),
        CreatedBy             INT NULL,
        ModifiedDate          DATETIME NULL,
        ModifiedBy            INT NULL
    );

    CREATE INDEX IX_DoctorVisitProcessConfig_Scope ON dbo.DoctorVisitProcessConfig(BranchId, SpecialityId, DoctorId, VisitType, IsActive);
END
GO

-- -----------------------------------------------------------------------------
-- 2. Table: dbo.DoctorCommissionConfig
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorCommissionConfig' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.DoctorCommissionConfig (
        CommissionConfigId    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CompanyId             INT NOT NULL DEFAULT 1,
        BranchId              INT NULL, -- NULL / 0 = All Branches
        DoctorId              INT NULL, -- NULL / 0 = All Doctors
        SpecialityId          INT NULL, -- NULL / 0 = All Specialties
        RevenueType           NVARCHAR(50) NOT NULL DEFAULT 'Consultation', -- 'Consultation', 'Procedure', 'Investigation', 'Package', 'Emergency', 'Telemedicine', 'All Services'
        CalculationType       NVARCHAR(50) NOT NULL DEFAULT 'Percentage', -- 'Percentage', 'Fixed Amount', 'Tiered'
        CommissionBasis       NVARCHAR(50) NOT NULL DEFAULT 'Net Collected', -- 'Net Collected', 'Gross Bill', 'Net Bill (After Discount)', 'Base Tariff'
        DoctorShare           DECIMAL(18,2) NOT NULL DEFAULT 70.00, -- Rate % e.g. 70.00 or Flat Rs amount e.g. 500.00
        ProcedureId           INT NULL, -- Procedure specific rule
        ServiceId             INT NULL, -- Service specific rule
        CorporateId           INT NULL, -- Corporate override
        InsuranceTPAId        INT NULL, -- Insurance override
        ApprovalRequired      BIT NOT NULL DEFAULT 1,
        EffectiveFrom         DATE NOT NULL DEFAULT GETDATE(),
        EffectiveTo           DATE NULL,
        IsActive              BIT NOT NULL DEFAULT 1,
        CreatedDate           DATETIME NOT NULL DEFAULT GETDATE(),
        CreatedBy             INT NULL,
        ModifiedDate          DATETIME NULL,
        ModifiedBy            INT NULL
    );

    CREATE INDEX IX_DoctorCommissionConfig_Lookup ON dbo.DoctorCommissionConfig(DoctorId, SpecialityId, RevenueType, IsActive);
END
GO

-- -----------------------------------------------------------------------------
-- 3. Table: dbo.DoctorDisbursal
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorDisbursal' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.DoctorDisbursal (
        DisbursalId           INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CompanyId             INT NOT NULL DEFAULT 1,
        BranchId              INT NOT NULL DEFAULT 1,
        DoctorId              INT NOT NULL,
        VisitId               INT NOT NULL, -- FK to PatientOPDService.OPDServiceId
        BillId                INT NULL,     -- FK to PaymentHeader.PaymentHeaderId
        ConsultationId        INT NULL,     -- FK to EmrPatientConsultation.ConsultationId
        RevenueType           NVARCHAR(50) NOT NULL DEFAULT 'Consultation',
        GrossBillAmount       DECIMAL(18,2) NOT NULL DEFAULT 0,
        DiscountAmount        DECIMAL(18,2) NOT NULL DEFAULT 0,
        ApprovedAdjustment    DECIMAL(18,2) NOT NULL DEFAULT 0,
        NetBillAmount         DECIMAL(18,2) NOT NULL DEFAULT 0,
        CollectedAmount       DECIMAL(18,2) NOT NULL DEFAULT 0,
        CommissionBasis       NVARCHAR(50) NOT NULL DEFAULT 'Net Collected',
        EligibleAmount        DECIMAL(18,2) NOT NULL DEFAULT 0,
        CommissionConfigId    INT NULL,
        CommissionRule        NVARCHAR(200) NOT NULL DEFAULT 'Standard 70% of Net Collected',
        CommissionPercentage  DECIMAL(18,2) NULL DEFAULT 70.00,
        CalculatedAmount      DECIMAL(18,2) NOT NULL DEFAULT 0,
        AdjustmentAmount      DECIMAL(18,2) NOT NULL DEFAULT 0,
        AdjustmentReason      NVARCHAR(500) NULL,
        NetPayable            DECIMAL(18,2) NOT NULL DEFAULT 0,
        SettlementPeriod      NVARCHAR(20) NOT NULL, -- '2026-08', 'AUG-2026'
        ApprovalStatus        NVARCHAR(50) NOT NULL DEFAULT 'CALCULATED', -- 'NOT_ELIGIBLE', 'ELIGIBLE', 'CALCULATED', 'SUBMITTED', 'APPROVED', 'ON_HOLD', 'REJECTED'
        PaymentStatus         NVARCHAR(50) NOT NULL DEFAULT 'Pending',    -- 'Pending', 'Paid', 'Adjusted', 'Reversed'
        ApprovedBy            INT NULL,
        ApprovedDate          DATETIME NULL,
        PaymentMethod         NVARCHAR(50) NULL, -- 'Bank Transfer', 'NEFT', 'RTGS', 'Cheque', 'UPI', 'Cash'
        PaymentReference      NVARCHAR(100) NULL,
        PaidDate              DATETIME NULL,
        PaidBy                INT NULL,
        DisbursalNotes        NVARCHAR(MAX) NULL,
        IsActive              BIT NOT NULL DEFAULT 1,
        CreatedDate           DATETIME NOT NULL DEFAULT GETDATE(),
        CreatedBy             INT NULL,
        ModifiedDate          DATETIME NULL,
        ModifiedBy            INT NULL
    );

    CREATE INDEX IX_DoctorDisbursal_DoctorPeriod ON dbo.DoctorDisbursal(DoctorId, SettlementPeriod, ApprovalStatus, PaymentStatus, IsActive);
    CREATE INDEX IX_DoctorDisbursal_Visit ON dbo.DoctorDisbursal(VisitId, IsActive);
END
GO

-- -----------------------------------------------------------------------------
-- 4. Table: dbo.DoctorBillingAdjustment
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorBillingAdjustment' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.DoctorBillingAdjustment (
        AdjustmentId          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CompanyId             INT NOT NULL DEFAULT 1,
        BranchId              INT NOT NULL DEFAULT 1,
        DisbursalId           INT NULL,
        VisitId               INT NOT NULL,
        BillId                INT NULL,
        DoctorId              INT NOT NULL,
        AdjustmentType        NVARCHAR(50) NOT NULL, -- 'TDS Deduction', 'Incentive', 'Penalty', 'Manual Correction', 'Recovery', 'Honorarium'
        Amount                DECIMAL(18,2) NOT NULL DEFAULT 0,
        Reason                NVARCHAR(500) NOT NULL,
        RequestedBy           INT NULL,
        ApprovedBy            INT NULL,
        AdjustmentDate        DATETIME NOT NULL DEFAULT GETDATE(),
        IsActive              BIT NOT NULL DEFAULT 1
    );

    CREATE INDEX IX_DoctorBillingAdjustment_Disbursal ON dbo.DoctorBillingAdjustment(DisbursalId, DoctorId, IsActive);
END
GO

-- =============================================================================
-- 5. Stored Procedures: Doctor Visit Process Configuration
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorVisitProcessConfig_GetList
    @BranchId INT = NULL,
    @SpecialityId INT = NULL,
    @DoctorId INT = NULL,
    @VisitType NVARCHAR(50) = NULL,
    @IsActive BIT = NULL,
    @Search NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.ProcessConfigId,
        c.CompanyId,
        c.BranchId,
        b.BranchName,
        c.SpecialityId,
        s.SpecialityName,
        c.DoctorId,
        d.FullName AS DoctorName,
        c.VisitType,
        c.PaymentTiming,
        c.VitalsRequired,
        c.DiagnosisRequired,
        c.Icd10Required,
        c.ProcedureAllowed,
        c.BillingRequired,
        c.PaymentBeforeClosure,
        c.EffectiveFrom,
        c.EffectiveTo,
        c.IsActive,
        c.CreatedDate,
        c.CreatedBy,
        c.ModifiedDate,
        c.ModifiedBy
    FROM dbo.DoctorVisitProcessConfig c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = c.SpecialityId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    WHERE (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId OR c.BranchId IS NULL OR c.BranchId = 0)
      AND (@SpecialityId IS NULL OR c.SpecialityId = @SpecialityId OR c.SpecialityId IS NULL OR c.SpecialityId = 0)
      AND (@DoctorId IS NULL OR c.DoctorId = @DoctorId OR c.DoctorId IS NULL OR c.DoctorId = 0)
      AND (@VisitType IS NULL OR c.VisitType = @VisitType OR c.VisitType = 'All')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
      AND (
          @Search IS NULL
          OR b.BranchName LIKE '%' + @Search + '%'
          OR s.SpecialityName LIKE '%' + @Search + '%'
          OR d.FullName LIKE '%' + @Search + '%'
          OR c.VisitType LIKE '%' + @Search + '%'
          OR c.PaymentTiming LIKE '%' + @Search + '%'
      )
    ORDER BY c.IsActive DESC, c.ProcessConfigId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorVisitProcessConfig_GetById
    @ProcessConfigId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.ProcessConfigId,
        c.CompanyId,
        c.BranchId,
        b.BranchName,
        c.SpecialityId,
        s.SpecialityName,
        c.DoctorId,
        d.FullName AS DoctorName,
        c.VisitType,
        c.PaymentTiming,
        c.VitalsRequired,
        c.DiagnosisRequired,
        c.Icd10Required,
        c.ProcedureAllowed,
        c.BillingRequired,
        c.PaymentBeforeClosure,
        c.EffectiveFrom,
        c.EffectiveTo,
        c.IsActive,
        c.CreatedDate,
        c.CreatedBy,
        c.ModifiedDate,
        c.ModifiedBy
    FROM dbo.DoctorVisitProcessConfig c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = c.SpecialityId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    WHERE c.ProcessConfigId = @ProcessConfigId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorVisitProcessConfig_Save
    @ProcessConfigId INT = NULL,
    @CompanyId INT = 1,
    @BranchId INT = NULL,
    @SpecialityId INT = NULL,
    @DoctorId INT = NULL,
    @VisitType NVARCHAR(50) = 'All',
    @PaymentTiming NVARCHAR(50) = 'Before Consultation',
    @VitalsRequired BIT = 1,
    @DiagnosisRequired BIT = 1,
    @Icd10Required BIT = 1,
    @ProcedureAllowed BIT = 1,
    @BillingRequired BIT = 1,
    @PaymentBeforeClosure BIT = 1,
    @EffectiveFrom DATE = NULL,
    @EffectiveTo DATE = NULL,
    @IsActive BIT = 1,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @EffectiveFrom IS NULL SET @EffectiveFrom = CAST(GETDATE() AS DATE);

    IF @ProcessConfigId IS NULL OR @ProcessConfigId = 0
    BEGIN
        INSERT INTO dbo.DoctorVisitProcessConfig (
            CompanyId, BranchId, SpecialityId, DoctorId, VisitType,
            PaymentTiming, VitalsRequired, DiagnosisRequired, Icd10Required,
            ProcedureAllowed, BillingRequired, PaymentBeforeClosure,
            EffectiveFrom, EffectiveTo, IsActive, CreatedDate, CreatedBy
        )
        VALUES (
            @CompanyId, @BranchId, @SpecialityId, @DoctorId, @VisitType,
            @PaymentTiming, @VitalsRequired, @DiagnosisRequired, @Icd10Required,
            @ProcedureAllowed, @BillingRequired, @PaymentBeforeClosure,
            @EffectiveFrom, @EffectiveTo, @IsActive, GETDATE(), @UserId
        );

        SELECT SCOPE_IDENTITY() AS ProcessConfigId;
    END
    ELSE
    BEGIN
        UPDATE dbo.DoctorVisitProcessConfig
        SET
            CompanyId = @CompanyId,
            BranchId = @BranchId,
            SpecialityId = @SpecialityId,
            DoctorId = @DoctorId,
            VisitType = @VisitType,
            PaymentTiming = @PaymentTiming,
            VitalsRequired = @VitalsRequired,
            DiagnosisRequired = @DiagnosisRequired,
            Icd10Required = @Icd10Required,
            ProcedureAllowed = @ProcedureAllowed,
            BillingRequired = @BillingRequired,
            PaymentBeforeClosure = @PaymentBeforeClosure,
            EffectiveFrom = @EffectiveFrom,
            EffectiveTo = @EffectiveTo,
            IsActive = @IsActive,
            ModifiedDate = GETDATE(),
            ModifiedBy = @UserId
        WHERE ProcessConfigId = @ProcessConfigId;

        SELECT @ProcessConfigId AS ProcessConfigId;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorVisitProcessConfig_Delete
    @ProcessConfigId INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.DoctorVisitProcessConfig WHERE ProcessConfigId = @ProcessConfigId;
    SELECT @@ROWCOUNT;
END
GO

-- =============================================================================
-- 6. Stored Procedures: Doctor Commission Configuration
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_GetList
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SpecialityId INT = NULL,
    @RevenueType NVARCHAR(50) = NULL,
    @IsActive BIT = NULL,
    @Search NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.CommissionConfigId,
        c.CompanyId,
        c.BranchId,
        b.BranchName,
        c.DoctorId,
        d.FullName AS DoctorName,
        c.SpecialityId,
        s.SpecialityName,
        c.RevenueType,
        c.CalculationType,
        c.CommissionBasis,
        c.DoctorShare,
        c.ProcedureId,
        p.ProcedureName,
        c.ServiceId,
        sm.ItemName AS ServiceName,
        c.CorporateId,
        corp.Corporate_Name AS CorporateName,
        c.InsuranceTPAId,
        ins.Name AS InsuranceName,
        c.ApprovalRequired,
        c.EffectiveFrom,
        c.EffectiveTo,
        c.IsActive,
        c.CreatedDate,
        c.CreatedBy,
        c.ModifiedDate,
        c.ModifiedBy
    FROM dbo.DoctorCommissionConfig c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = c.SpecialityId
    LEFT JOIN dbo.ProcedureMaster p ON p.ProcedureId = c.ProcedureId
    LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = c.ServiceId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = c.CorporateId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = c.InsuranceTPAId
    WHERE (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId OR c.BranchId IS NULL OR c.BranchId = 0)
      AND (@DoctorId IS NULL OR c.DoctorId = @DoctorId OR c.DoctorId IS NULL OR c.DoctorId = 0)
      AND (@SpecialityId IS NULL OR c.SpecialityId = @SpecialityId OR c.SpecialityId IS NULL OR c.SpecialityId = 0)
      AND (@RevenueType IS NULL OR c.RevenueType = @RevenueType OR c.RevenueType = 'All Services')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
      AND (
          @Search IS NULL
          OR d.FullName LIKE '%' + @Search + '%'
          OR s.SpecialityName LIKE '%' + @Search + '%'
          OR c.RevenueType LIKE '%' + @Search + '%'
          OR c.CommissionBasis LIKE '%' + @Search + '%'
          OR p.ProcedureName LIKE '%' + @Search + '%'
          OR sm.ItemName LIKE '%' + @Search + '%'
          OR corp.Corporate_Name LIKE '%' + @Search + '%'
          OR ins.Name LIKE '%' + @Search + '%'
      )
    ORDER BY c.IsActive DESC, c.CommissionConfigId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_GetById
    @CommissionConfigId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.CommissionConfigId,
        c.CompanyId,
        c.BranchId,
        b.BranchName,
        c.DoctorId,
        d.FullName AS DoctorName,
        c.SpecialityId,
        s.SpecialityName,
        c.RevenueType,
        c.CalculationType,
        c.CommissionBasis,
        c.DoctorShare,
        c.ProcedureId,
        p.ProcedureName,
        c.ServiceId,
        sm.ItemName AS ServiceName,
        c.CorporateId,
        corp.Corporate_Name AS CorporateName,
        c.InsuranceTPAId,
        ins.Name AS InsuranceName,
        c.ApprovalRequired,
        c.EffectiveFrom,
        c.EffectiveTo,
        c.IsActive,
        c.CreatedDate,
        c.CreatedBy,
        c.ModifiedDate,
        c.ModifiedBy
    FROM dbo.DoctorCommissionConfig c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = c.SpecialityId
    LEFT JOIN dbo.ProcedureMaster p ON p.ProcedureId = c.ProcedureId
    LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = c.ServiceId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = c.CorporateId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = c.InsuranceTPAId
    WHERE c.CommissionConfigId = @CommissionConfigId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_Save
    @CommissionConfigId INT = NULL,
    @CompanyId INT = 1,
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SpecialityId INT = NULL,
    @RevenueType NVARCHAR(50) = 'Consultation',
    @CalculationType NVARCHAR(50) = 'Percentage',
    @CommissionBasis NVARCHAR(50) = 'Net Collected',
    @DoctorShare DECIMAL(18,2) = 70.00,
    @ProcedureId INT = NULL,
    @ServiceId INT = NULL,
    @CorporateId INT = NULL,
    @InsuranceTPAId INT = NULL,
    @ApprovalRequired BIT = 1,
    @EffectiveFrom DATE = NULL,
    @EffectiveTo DATE = NULL,
    @IsActive BIT = 1,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @EffectiveFrom IS NULL SET @EffectiveFrom = CAST(GETDATE() AS DATE);

    IF @CommissionConfigId IS NULL OR @CommissionConfigId = 0
    BEGIN
        INSERT INTO dbo.DoctorCommissionConfig (
            CompanyId, BranchId, DoctorId, SpecialityId, RevenueType,
            CalculationType, CommissionBasis, DoctorShare, ProcedureId,
            ServiceId, CorporateId, InsuranceTPAId, ApprovalRequired,
            EffectiveFrom, EffectiveTo, IsActive, CreatedDate, CreatedBy
        )
        VALUES (
            @CompanyId, @BranchId, @DoctorId, @SpecialityId, @RevenueType,
            @CalculationType, @CommissionBasis, @DoctorShare, @ProcedureId,
            @ServiceId, @CorporateId, @InsuranceTPAId, @ApprovalRequired,
            @EffectiveFrom, @EffectiveTo, @IsActive, GETDATE(), @UserId
        );

        SELECT SCOPE_IDENTITY() AS CommissionConfigId;
    END
    ELSE
    BEGIN
        UPDATE dbo.DoctorCommissionConfig
        SET
            CompanyId = @CompanyId,
            BranchId = @BranchId,
            DoctorId = @DoctorId,
            SpecialityId = @SpecialityId,
            RevenueType = @RevenueType,
            CalculationType = @CalculationType,
            CommissionBasis = @CommissionBasis,
            DoctorShare = @DoctorShare,
            ProcedureId = @ProcedureId,
            ServiceId = @ServiceId,
            CorporateId = @CorporateId,
            InsuranceTPAId = @InsuranceTPAId,
            ApprovalRequired = @ApprovalRequired,
            EffectiveFrom = @EffectiveFrom,
            EffectiveTo = @EffectiveTo,
            IsActive = @IsActive,
            ModifiedDate = GETDATE(),
            ModifiedBy = @UserId
        WHERE CommissionConfigId = @CommissionConfigId;

        SELECT @CommissionConfigId AS CommissionConfigId;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_Delete
    @CommissionConfigId INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.DoctorCommissionConfig WHERE CommissionConfigId = @CommissionConfigId;
    SELECT @@ROWCOUNT;
END
GO

-- =============================================================================
-- 7. Stored Procedures: Doctor Disbursal Workbench & Engine
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_GetList
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SettlementPeriod NVARCHAR(20) = NULL,
    @ApprovalStatus NVARCHAR(50) = NULL,
    @PaymentStatus NVARCHAR(50) = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.DisbursalId,
        d.CompanyId,
        d.BranchId,
        b.BranchName,
        d.DoctorId,
        doc.FullName AS DoctorName,
        doc.MedicalLicenseNo AS DoctorCode,
        spec.SpecialityName,
        d.VisitId,
        opd.VisitDate,
        opd.OPDBillNo,
        p.PatientCode,
        p.FirstName + ' ' + ISNULL(p.LastName, '') AS PatientName,
        d.BillId,
        d.ConsultationId,
        d.RevenueType,
        d.GrossBillAmount,
        d.DiscountAmount,
        d.ApprovedAdjustment,
        d.NetBillAmount,
        d.CollectedAmount,
        d.CommissionBasis,
        d.EligibleAmount,
        d.CommissionConfigId,
        d.CommissionRule,
        d.CommissionPercentage,
        d.CalculatedAmount,
        d.AdjustmentAmount,
        d.AdjustmentReason,
        d.NetPayable,
        d.SettlementPeriod,
        d.ApprovalStatus,
        d.PaymentStatus,
        d.ApprovedBy,
        uAppr.FullName AS ApprovedByName,
        d.ApprovedDate,
        d.PaymentMethod,
        d.PaymentReference,
        d.PaidDate,
        d.PaidBy,
        uPaid.FullName AS PaidByName,
        d.DisbursalNotes,
        d.IsActive,
        d.CreatedDate
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster spec ON spec.SpecialityId = doc.PrimarySpecialityId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = d.BranchId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = d.VisitId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = opd.PatientId
    LEFT JOIN dbo.Users uAppr ON uAppr.Id = d.ApprovedBy
    LEFT JOIN dbo.Users uPaid ON uPaid.Id = d.PaidBy
    WHERE (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR d.DoctorId = @DoctorId)
      AND (@SettlementPeriod IS NULL OR d.SettlementPeriod = @SettlementPeriod)
      AND (@ApprovalStatus IS NULL OR d.ApprovalStatus = @ApprovalStatus)
      AND (@PaymentStatus IS NULL OR d.PaymentStatus = @PaymentStatus)
      AND (@FromDate IS NULL OR CAST(opd.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(opd.VisitDate AS DATE) <= @ToDate)
      AND (
          @Search IS NULL
          OR doc.FullName LIKE '%' + @Search + '%'
          OR opd.OPDBillNo LIKE '%' + @Search + '%'
          OR p.PatientCode LIKE '%' + @Search + '%'
          OR p.FirstName LIKE '%' + @Search + '%'
          OR p.LastName LIKE '%' + @Search + '%'
          OR d.SettlementPeriod LIKE '%' + @Search + '%'
          OR d.PaymentReference LIKE '%' + @Search + '%'
      )
    ORDER BY d.CreatedDate DESC, d.DisbursalId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_GetById
    @DisbursalId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.DisbursalId,
        d.CompanyId,
        d.BranchId,
        b.BranchName,
        d.DoctorId,
        doc.FullName AS DoctorName,
        doc.MedicalLicenseNo AS DoctorCode,
        spec.SpecialityName,
        d.VisitId,
        opd.VisitDate,
        opd.OPDBillNo,
        p.PatientCode,
        p.FirstName + ' ' + ISNULL(p.LastName, '') AS PatientName,
        d.BillId,
        d.ConsultationId,
        d.RevenueType,
        d.GrossBillAmount,
        d.DiscountAmount,
        d.ApprovedAdjustment,
        d.NetBillAmount,
        d.CollectedAmount,
        d.CommissionBasis,
        d.EligibleAmount,
        d.CommissionConfigId,
        d.CommissionRule,
        d.CommissionPercentage,
        d.CalculatedAmount,
        d.AdjustmentAmount,
        d.AdjustmentReason,
        d.NetPayable,
        d.SettlementPeriod,
        d.ApprovalStatus,
        d.PaymentStatus,
        d.ApprovedBy,
        uAppr.FullName AS ApprovedByName,
        d.ApprovedDate,
        d.PaymentMethod,
        d.PaymentReference,
        d.PaidDate,
        d.PaidBy,
        uPaid.FullName AS PaidByName,
        d.DisbursalNotes,
        d.IsActive,
        d.CreatedDate
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster spec ON spec.SpecialityId = doc.PrimarySpecialityId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = d.BranchId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = d.VisitId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = opd.PatientId
    LEFT JOIN dbo.Users uAppr ON uAppr.Id = d.ApprovedBy
    LEFT JOIN dbo.Users uPaid ON uPaid.Id = d.PaidBy
    WHERE d.DisbursalId = @DisbursalId;

    -- Return any associated adjustments
    SELECT
        a.AdjustmentId,
        a.AdjustmentType,
        a.Amount,
        a.Reason,
        a.AdjustmentDate,
        uReq.FullName AS RequestedByName,
        uAppr.FullName AS ApprovedByName
    FROM dbo.DoctorBillingAdjustment a
    LEFT JOIN dbo.Users uReq ON uReq.Id = a.RequestedBy
    LEFT JOIN dbo.Users uAppr ON uAppr.Id = a.ApprovedBy
    WHERE a.DisbursalId = @DisbursalId AND a.IsActive = 1
    ORDER BY a.AdjustmentDate DESC;
END
GO

-- -----------------------------------------------------------------------------
-- Auto-Calculation Engine: Evaluates completed visits and generates/refreshes disbursals
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_CalculateForVisits
    @BranchId INT = 1,
    @DoctorId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @SettlementPeriod NVARCHAR(20) = NULL,
    @UserId INT = NULL,
    @CompanyId INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -30, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @SettlementPeriod IS NULL OR @SettlementPeriod = ''
        SET @SettlementPeriod = FORMAT(GETDATE(), 'yyyy-MM');

    -- Temporary table for eligible completed visits
    DECLARE @EligibleVisits TABLE (
        VisitId INT,
        BranchId INT,
        DoctorId INT,
        BillId INT,
        ConsultationId INT,
        VisitDate DATETIME,
        GrossAmount DECIMAL(18,2),
        DiscountAmount DECIMAL(18,2),
        NetAmount DECIMAL(18,2),
        CollectedAmount DECIMAL(18,2),
        SpecialityId INT
    );

    INSERT INTO @EligibleVisits
    SELECT
        opd.OPDServiceId AS VisitId,
        ISNULL(opd.BranchId, @BranchId) AS BranchId,
        opd.ConsultingDoctorId AS DoctorId,
        ph.PaymentHeaderId AS BillId,
        cons.ConsultationId,
        opd.VisitDate,
        ISNULL(ph.SubTotal, ISNULL(opd.TotalAmount, 0)) AS GrossAmount,
        ISNULL(ph.LineDiscountTotal + ph.HeaderDiscountAmount, 0) AS DiscountAmount,
        ISNULL(ph.NetAmount, ISNULL(opd.TotalAmount, 0)) AS NetAmount,
        ISNULL(ph.TotalPaid, ISNULL(opd.TotalAmount, 0)) AS CollectedAmount,
        doc.PrimarySpecialityId
    FROM dbo.PatientOPDService opd
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = opd.ConsultingDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = opd.OPDServiceId AND ph.IsActive = 1
    LEFT JOIN dbo.EmrPatientConsultation cons ON cons.OPDServiceId = opd.OPDServiceId
    WHERE opd.IsActive = 1
      AND (@DoctorId IS NULL OR opd.ConsultingDoctorId = @DoctorId)
      AND (@BranchId IS NULL OR opd.BranchId = @BranchId OR opd.BranchId IS NULL)
      AND CAST(opd.VisitDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND opd.ConsultingDoctorId IS NOT NULL;

    -- Process each visit and compute commission based on matched DoctorCommissionConfig
    DECLARE @CalculatedCount INT = 0;

    DECLARE @vVisitId INT, @vBranchId INT, @vDoctorId INT, @vBillId INT, @vConsultationId INT;
    DECLARE @vGross DECIMAL(18,2), @vDiscount DECIMAL(18,2), @vNet DECIMAL(18,2), @vCollected DECIMAL(18,2), @vSpecId INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT VisitId, BranchId, DoctorId, BillId, ConsultationId, GrossAmount, DiscountAmount, NetAmount, CollectedAmount, SpecialityId
        FROM @EligibleVisits;

    OPEN cur;
    FETCH NEXT FROM cur INTO @vVisitId, @vBranchId, @vDoctorId, @vBillId, @vConsultationId, @vGross, @vDiscount, @vNet, @vCollected, @vSpecId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- 1. Identify Doctor's Consulting Fee for this Visit:
        DECLARE @vConsultGross DECIMAL(18,2) = NULL;
        DECLARE @vConsultLineDiscount DECIMAL(18,2) = 0;

        -- Check PaymentLineItem first
        IF @vBillId IS NOT NULL AND @vBillId > 0
        BEGIN
            SELECT 
                @vConsultGross = SUM(pli.OriginalAmount),
                @vConsultLineDiscount = SUM(ISNULL(pli.LineDiscountAmount, 0))
            FROM dbo.PaymentLineItem pli
            WHERE pli.PaymentHeaderId = @vBillId
              AND pli.IsActive = 1
              AND (pli.ServiceType = 'Consulting' OR pli.ItemDescription LIKE '%Consult%');
        END

        -- If not found in PaymentLineItem, check PatientOPDServiceItem
        IF @vConsultGross IS NULL OR @vConsultGross = 0
        BEGIN
            SELECT 
                @vConsultGross = SUM(psi.ServiceCharges)
            FROM dbo.PatientOPDServiceItem psi
            WHERE psi.OPDServiceId = @vVisitId
              AND psi.IsActive = 1
              AND (psi.ServiceType = 'Consulting' OR psi.ServiceType LIKE '%Consult%');
        END

        -- If not found in PatientOPDServiceItem, check DoctorConsultingFeeMap
        IF @vConsultGross IS NULL OR @vConsultGross = 0
        BEGIN
            SELECT TOP 1
                @vConsultGross = sm.ItemCharges
            FROM dbo.DoctorConsultingFeeMap m
            INNER JOIN dbo.ServiceMaster sm ON sm.ServiceId = m.ServiceId
            WHERE m.DoctorId = @vDoctorId
              AND (m.BranchId = @vBranchId OR m.BranchId IS NULL OR m.BranchId = 0)
              AND m.IsActive = 1;
        END

        -- Fallback to visit gross amount if no specific consulting fee is configured
        IF @vConsultGross IS NULL OR @vConsultGross = 0
        BEGIN
            SET @vConsultGross = @vGross;
        END

        -- 2. Calculate OPD Bill Discount Proportion on Consulting Fee:
        DECLARE @vConsultDiscount DECIMAL(18,2) = ISNULL(@vConsultLineDiscount, 0);
        IF @vGross > 0 AND @vDiscount > 0
        BEGIN
            DECLARE @vTotalHeaderDiscount DECIMAL(18,2) = @vDiscount - ISNULL(@vConsultLineDiscount, 0);
            IF @vTotalHeaderDiscount > 0
            BEGIN
                SET @vConsultDiscount = @vConsultDiscount + ROUND((@vConsultGross / @vGross) * @vTotalHeaderDiscount, 2);
            END
            IF @vConsultDiscount > @vConsultGross SET @vConsultDiscount = @vConsultGross;
        END

        -- Net Consulting Bill Amount
        DECLARE @vConsultNet DECIMAL(18,2) = @vConsultGross - @vConsultDiscount;
        IF @vConsultNet < 0 SET @vConsultNet = 0;

        -- 3. Calculate Bill Net Paid Amount for Consulting (collected after discount):
        DECLARE @vConsultPaid DECIMAL(18,2) = 0;
        IF @vNet > 0 AND @vCollected >= @vNet
        BEGIN
            SET @vConsultPaid = @vConsultNet;
        END
        ELSE IF @vNet > 0 AND @vCollected > 0
        BEGIN
            SET @vConsultPaid = ROUND((@vConsultNet / @vNet) * @vCollected, 2);
            IF @vConsultPaid > @vConsultNet SET @vConsultPaid = @vConsultNet;
        END
        ELSE IF @vGross > 0 AND @vCollected > 0
        BEGIN
            SET @vConsultPaid = ROUND((@vConsultGross / @vGross) * @vCollected, 2);
            IF @vConsultPaid > @vConsultNet SET @vConsultPaid = @vConsultNet;
        END
        ELSE
        BEGIN
            SET @vConsultPaid = 0;
        END

        -- Match highest-priority active DoctorCommissionConfig
        -- Priority 1: Specific Doctor
        -- Priority 2: Specific Speciality
        -- Priority 3: Default General Rule (DoctorId IS NULL, SpecialityId IS NULL)
        DECLARE @cfgId INT = NULL, @cfgBasis NVARCHAR(50) = 'Net Collected', @cfgType NVARCHAR(50) = 'Percentage';
        DECLARE @cfgShare DECIMAL(18,2) = 70.00, @cfgApproval BIT = 1, @cfgRevType NVARCHAR(50) = 'Consultation';

        SELECT TOP 1
            @cfgId = c.CommissionConfigId,
            @cfgBasis = c.CommissionBasis,
            @cfgType = c.CalculationType,
            @cfgShare = c.DoctorShare,
            @cfgApproval = c.ApprovalRequired,
            @cfgRevType = c.RevenueType
        FROM dbo.DoctorCommissionConfig c
        WHERE c.IsActive = 1
          AND (c.BranchId IS NULL OR c.BranchId = 0 OR c.BranchId = @vBranchId)
          AND (c.DoctorId = @vDoctorId OR (c.DoctorId IS NULL AND c.SpecialityId = @vSpecId) OR (c.DoctorId IS NULL AND c.SpecialityId IS NULL))
          AND (c.RevenueType IN ('Consultant', 'Consultation', 'All Services') OR c.RevenueType IS NULL)
        ORDER BY
            CASE WHEN c.DoctorId = @vDoctorId THEN 1 WHEN c.SpecialityId = @vSpecId THEN 2 ELSE 3 END ASC,
            c.CommissionConfigId DESC;

        -- Fallback default config if none matched
        IF @cfgRevType IS NULL SET @cfgRevType = 'Consultation';

        -- Determine Eligible Basis Amount:
        -- If RevenueType is 'Consultant' or 'Consultation', calculate on Consulting Fees / Bill Net Paid Amount
        DECLARE @vEffectiveGross DECIMAL(18,2) = @vConsultGross;
        DECLARE @vEffectiveDiscount DECIMAL(18,2) = @vConsultDiscount;
        DECLARE @vEffectiveNet DECIMAL(18,2) = @vConsultNet;
        DECLARE @vEffectivePaid DECIMAL(18,2) = @vConsultPaid;

        IF @cfgRevType = 'All Services'
        BEGIN
            SET @vEffectiveGross = @vGross;
            SET @vEffectiveDiscount = @vDiscount;
            SET @vEffectiveNet = @vNet;
            SET @vEffectivePaid = @vCollected;
        END

        DECLARE @vEligible DECIMAL(18,2) = 0;
        IF @cfgBasis = 'Gross Bill'
            SET @vEligible = @vEffectiveGross;
        ELSE IF @cfgBasis = 'Net Bill (After Discount)'
            SET @vEligible = @vEffectiveNet;
        ELSE -- Default: Net Collected (Bill Net Paid Amount)
            SET @vEligible = @vEffectivePaid;

        -- Calculate Doctor Share Amount
        DECLARE @vCalculated DECIMAL(18,2) = 0;
        IF @cfgType = 'Fixed Amount'
            SET @vCalculated = @cfgShare;
        ELSE -- Percentage
            SET @vCalculated = ROUND((@vEligible * @cfgShare / 100.0), 2);

        DECLARE @vRuleDesc NVARCHAR(200);
        IF @cfgType = 'Fixed Amount'
            SET @vRuleDesc = 'Flat ₹' + CAST(@cfgShare AS NVARCHAR(20)) + ' per visit (' + @cfgRevType + ')';
        ELSE
            SET @vRuleDesc = CAST(@cfgShare AS NVARCHAR(10)) + '% of ' + @cfgBasis + ' (' + @cfgRevType + ')';

        -- Check if disbursal already exists for this visit
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorDisbursal WHERE VisitId = @vVisitId AND IsActive = 1)
        BEGIN
            INSERT INTO dbo.DoctorDisbursal (
                CompanyId, BranchId, DoctorId, VisitId, BillId, ConsultationId,
                RevenueType, GrossBillAmount, DiscountAmount, ApprovedAdjustment,
                NetBillAmount, CollectedAmount, CommissionBasis, EligibleAmount,
                CommissionConfigId, CommissionRule, CommissionPercentage,
                CalculatedAmount, AdjustmentAmount, NetPayable, SettlementPeriod,
                ApprovalStatus, PaymentStatus, IsActive, CreatedDate, CreatedBy
            )
            VALUES (
                @CompanyId, @vBranchId, @vDoctorId, @vVisitId, @vBillId, @vConsultationId,
                @cfgRevType, @vEffectiveGross, @vEffectiveDiscount, 0,
                @vEffectiveNet, @vEffectivePaid, @cfgBasis, @vEligible,
                @cfgId, @vRuleDesc, (CASE WHEN @cfgType = 'Percentage' THEN @cfgShare ELSE NULL END),
                @vCalculated, 0, @vCalculated, @SettlementPeriod,
                (CASE WHEN @vEffectivePaid <= 0 THEN 'NOT_ELIGIBLE' ELSE 'CALCULATED' END),
                'Pending', 1, GETDATE(), @UserId
            );

            SET @CalculatedCount = @CalculatedCount + 1;
        END
        ELSE
        BEGIN
            -- Update only if not yet Approved or Paid
            UPDATE dbo.DoctorDisbursal
            SET
                RevenueType = @cfgRevType,
                GrossBillAmount = @vEffectiveGross,
                DiscountAmount = @vEffectiveDiscount,
                NetBillAmount = @vEffectiveNet,
                CollectedAmount = @vEffectivePaid,
                CommissionBasis = @cfgBasis,
                EligibleAmount = @vEligible,
                CommissionConfigId = @cfgId,
                CommissionRule = @vRuleDesc,
                CommissionPercentage = (CASE WHEN @cfgType = 'Percentage' THEN @cfgShare ELSE NULL END),
                CalculatedAmount = @vCalculated,
                NetPayable = @vCalculated + AdjustmentAmount,
                ApprovalStatus = CASE WHEN PaymentStatus = 'Paid' OR ApprovalStatus = 'APPROVED' THEN ApprovalStatus
                                      WHEN @vEffectivePaid <= 0 THEN 'NOT_ELIGIBLE' ELSE 'CALCULATED' END,
                ModifiedDate = GETDATE(),
                ModifiedBy = @UserId
            WHERE VisitId = @vVisitId AND PaymentStatus <> 'Paid' AND ApprovalStatus <> 'APPROVED';
        END

        FETCH NEXT FROM cur INTO @vVisitId, @vBranchId, @vDoctorId, @vBillId, @vConsultationId, @vGross, @vDiscount, @vNet, @vCollected, @vSpecId;
    END

    CLOSE cur;
    DEALLOCATE cur;

    SELECT @CalculatedCount AS ProcessedCount;
END
GO

-- -----------------------------------------------------------------------------
-- Adjustments, Approvals and Payouts
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_UpdateAdjustment
    @DisbursalId INT,
    @AdjustmentType NVARCHAR(50),
    @AdjustmentAmount DECIMAL(18,2),
    @Reason NVARCHAR(500),
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @VisitId INT, @BillId INT, @DoctorId INT, @BranchId INT, @CompanyId INT;
    SELECT @VisitId = VisitId, @BillId = BillId, @DoctorId = DoctorId, @BranchId = BranchId, @CompanyId = CompanyId
    FROM dbo.DoctorDisbursal WHERE DisbursalId = @DisbursalId;

    IF @VisitId IS NULL RETURN 0;

    -- Record in billing adjustments ledger
    INSERT INTO dbo.DoctorBillingAdjustment (
        CompanyId, BranchId, DisbursalId, VisitId, BillId, DoctorId,
        AdjustmentType, Amount, Reason, RequestedBy, ApprovedBy, AdjustmentDate, IsActive
    )
    VALUES (
        @CompanyId, @BranchId, @DisbursalId, @VisitId, @BillId, @DoctorId,
        @AdjustmentType, @AdjustmentAmount, @Reason, @UserId, @UserId, GETDATE(), 1
    );

    -- Update disbursal total adjustment & net payable
    UPDATE dbo.DoctorDisbursal
    SET
        AdjustmentAmount = AdjustmentAmount + @AdjustmentAmount,
        AdjustmentReason = CASE WHEN AdjustmentReason IS NULL THEN @Reason ELSE AdjustmentReason + '; ' + @Reason END,
        NetPayable = CalculatedAmount + (AdjustmentAmount + @AdjustmentAmount),
        ApprovalStatus = 'ADJUSTED',
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE DisbursalId = @DisbursalId;

    SELECT @@ROWCOUNT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_UpdateStatus
    @DisbursalId INT,
    @ApprovalStatus NVARCHAR(50), -- 'APPROVED', 'ON_HOLD', 'REJECTED', 'SUBMITTED'
    @DisbursalNotes NVARCHAR(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.DoctorDisbursal
    SET
        ApprovalStatus = @ApprovalStatus,
        ApprovedBy = CASE WHEN @ApprovalStatus = 'APPROVED' THEN @UserId ELSE ApprovedBy END,
        ApprovedDate = CASE WHEN @ApprovalStatus = 'APPROVED' THEN GETDATE() ELSE ApprovedDate END,
        DisbursalNotes = ISNULL(@DisbursalNotes, DisbursalNotes),
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE DisbursalId = @DisbursalId;

    SELECT @@ROWCOUNT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_BulkApprove
    @DisbursalIds NVARCHAR(MAX), -- comma-separated e.g. "1,2,3"
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.DoctorDisbursal
    SET
        ApprovalStatus = 'APPROVED',
        ApprovedBy = @UserId,
        ApprovedDate = GETDATE(),
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE DisbursalId IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@DisbursalIds, ','))
      AND PaymentStatus <> 'Paid';

    SELECT @@ROWCOUNT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDisbursal_ProcessPayout
    @DisbursalId INT,
    @PaymentMethod NVARCHAR(50), -- 'NEFT', 'Bank Transfer', 'UPI', 'Cheque', 'Cash'
    @PaymentReference NVARCHAR(100),
    @PaidDate DATETIME = NULL,
    @DisbursalNotes NVARCHAR(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @PaidDate IS NULL SET @PaidDate = GETDATE();

    UPDATE dbo.DoctorDisbursal
    SET
        ApprovalStatus = 'APPROVED',
        PaymentStatus = 'Paid',
        PaymentMethod = @PaymentMethod,
        PaymentReference = @PaymentReference,
        PaidDate = @PaidDate,
        PaidBy = @UserId,
        DisbursalNotes = ISNULL(@DisbursalNotes, DisbursalNotes),
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE DisbursalId = @DisbursalId;

    SELECT @@ROWCOUNT;
END
GO

-- =============================================================================
-- 8. Stored Procedures: Post-Payment Finance & Doctor Settlement Reports (RPT-01 to RPT-08)
-- =============================================================================

-- RPT-01: Visit Payment Status
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_VisitPaymentStatus
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -30, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);

    SELECT
        opd.VisitDate,
        opd.OPDServiceId AS VisitNo,
        p.PatientCode + ' - ' + p.FirstName + ' ' + ISNULL(p.LastName, '') AS Patient,
        doc.FullName AS Doctor,
        opd.OPDBillNo AS Bill,
        ISNULL(ph.NetAmount, ISNULL(opd.TotalAmount, 0)) AS NetAmount,
        ISNULL(ph.TotalPaid, 0) AS Paid,
        ISNULL(ph.BalanceDue, 0) AS Outstanding,
        CASE
            WHEN ISNULL(ph.BalanceDue, 0) <= 0 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'Paid'
            WHEN ISNULL(ph.TotalPaid, 0) > 0 AND ISNULL(ph.BalanceDue, 0) > 0 THEN 'Partial'
            WHEN ISNULL(ph.TotalPaid, 0) = 0 THEN 'Unpaid'
            ELSE 'Settled'
        END AS Status
    FROM dbo.PatientOPDService opd
    INNER JOIN dbo.PatientMaster p ON p.PatientId = opd.PatientId
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = opd.ConsultingDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = opd.OPDServiceId AND ph.IsActive = 1
    WHERE opd.IsActive = 1
      AND (@CompanyId IS NULL OR opd.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR opd.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR opd.ConsultingDoctorId = @DoctorId)
      AND CAST(opd.VisitDate AS DATE) BETWEEN @FromDate AND @ToDate
    ORDER BY opd.VisitDate DESC;
END
GO

-- RPT-02: Yet-to-Pay / Outstanding by Visit (with Aging Buckets)
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_OutstandingByVisit
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);

    SELECT
        opd.VisitDate,
        opd.OPDServiceId AS VisitNo,
        p.PatientCode + ' - ' + p.FirstName + ' ' + ISNULL(p.LastName, '') AS Patient,
        doc.FullName AS Doctor,
        opd.OPDBillNo AS Bill,
        ISNULL(ph.NetAmount, ISNULL(opd.TotalAmount, 0)) AS NetAmount,
        ISNULL(ph.TotalPaid, 0) AS Paid,
        ISNULL(ph.BalanceDue, ISNULL(opd.TotalAmount, 0)) AS Outstanding,
        DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) AS DaysOld,
        CASE
            WHEN DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) = 0 THEN 'Current'
            WHEN DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) BETWEEN 1 AND 7 THEN '1–7 days'
            WHEN DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) BETWEEN 8 AND 30 THEN '8–30 days'
            WHEN DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) BETWEEN 31 AND 60 THEN '31–60 days'
            WHEN DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) BETWEEN 61 AND 90 THEN '61–90 days'
            ELSE '90+ days'
        END AS Aging,
        CASE
            WHEN ISNULL(ph.TotalPaid, 0) = 0 AND DATEDIFF(DAY, CAST(opd.VisitDate AS DATE), CAST(GETDATE() AS DATE)) > 30 THEN 'Overdue'
            WHEN ISNULL(ph.TotalPaid, 0) = 0 THEN 'Unpaid'
            WHEN ISNULL(ph.TotalPaid, 0) > 0 AND ISNULL(ph.BalanceDue, 0) > 0 THEN 'Partial'
            ELSE 'Paid'
        END AS Status
    FROM dbo.PatientOPDService opd
    INNER JOIN dbo.PatientMaster p ON p.PatientId = opd.PatientId
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = opd.ConsultingDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = opd.OPDServiceId AND ph.IsActive = 1
    WHERE opd.IsActive = 1
      AND (@CompanyId IS NULL OR opd.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR opd.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR opd.ConsultingDoctorId = @DoctorId)
      AND (ph.BalanceDue > 0 OR ph.PaymentHeaderId IS NULL)
      AND CAST(opd.VisitDate AS DATE) BETWEEN @FromDate AND @ToDate
    ORDER BY opd.VisitDate DESC;
END
GO

-- RPT-03: Doctor Commission
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DoctorCommission
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SettlementPeriod NVARCHAR(20) = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        doc.FullName AS Doctor,
        COUNT(d.DisbursalId) AS Visits,
        SUM(d.EligibleAmount) AS EligibleCollection,
        AVG(ISNULL(d.CommissionPercentage, 70.00)) AS CommissionPercent,
        SUM(d.CalculatedAmount) AS CommissionAmount,
        SUM(d.AdjustmentAmount) AS Adjustments,
        SUM(d.NetPayable) AS NetPayable,
        SUM(CASE WHEN d.PaymentStatus = 'Paid' THEN d.NetPayable ELSE 0 END) AS Paid,
        SUM(CASE WHEN d.PaymentStatus <> 'Paid' THEN d.NetPayable ELSE 0 END) AS YetToPay
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    WHERE d.IsActive = 1
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR d.DoctorId = @DoctorId)
      AND (@SettlementPeriod IS NULL OR d.SettlementPeriod = @SettlementPeriod)
      AND (@FromDate IS NULL OR CAST(d.CreatedDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(d.CreatedDate AS DATE) <= @ToDate)
    GROUP BY doc.DoctorId, doc.FullName
    ORDER BY doc.FullName ASC;
END
GO

-- RPT-04: Doctor Disbursal Register
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DoctorDisbursalRegister
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SettlementPeriod NVARCHAR(20) = NULL,
    @PaymentStatus NVARCHAR(50) = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.DisbursalId,
        doc.FullName AS Doctor,
        d.SettlementPeriod AS Period,
        d.EligibleAmount,
        d.CalculatedAmount AS Commission,
        d.NetPayable AS ApprovedAmount,
        CASE WHEN d.PaymentStatus = 'Paid' THEN d.NetPayable ELSE 0 END AS PaidAmount,
        ISNULL(d.PaymentReference, '—') AS PaymentRef,
        d.PaidDate,
        d.ApprovalStatus + ' / ' + d.PaymentStatus AS Status
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    WHERE d.IsActive = 1
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR d.DoctorId = @DoctorId)
      AND (@SettlementPeriod IS NULL OR d.SettlementPeriod = @SettlementPeriod)
      AND (@PaymentStatus IS NULL OR d.PaymentStatus = @PaymentStatus)
      AND (@FromDate IS NULL OR CAST(d.CreatedDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(d.CreatedDate AS DATE) <= @ToDate)
    ORDER BY d.DisbursalId DESC;
END
GO

-- RPT-05: Payment Transactions
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_PaymentTransactions
    @BranchId INT = NULL,
    @PaymentMethodId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -30, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);

    SELECT
        pd.CreatedDate AS [DateTime],
        ph.OPDServiceId AS VisitNo,
        opd.OPDBillNo AS Bill,
        p.PatientCode + ' - ' + p.FirstName + ' ' + ISNULL(p.LastName, '') AS Patient,
        pm.MethodName AS PaymentMode,
        pd.PaidAmount AS Amount,
        ISNULL(pd.TransactionRef, ISNULL(pd.ReceiptNo, '—')) AS TransactionReference,
        ISNULL(u.FullName, 'System') AS ReceivedBy
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = ph.PatientId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = ph.OPDServiceId
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
    WHERE pd.IsActive = 1 AND ph.IsActive = 1
      AND (@CompanyId IS NULL OR ph.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND (@PaymentMethodId IS NULL OR pd.PaymentMethodId = @PaymentMethodId)
      AND CAST(pd.CreatedDate AS DATE) BETWEEN @FromDate AND @ToDate
    ORDER BY pd.CreatedDate DESC;
END
GO

-- RPT-06: Billing Adjustments
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_BillingAdjustments
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -30, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);

    SELECT
        a.AdjustmentDate AS [Date],
        a.VisitId AS VisitNo,
        opd.OPDBillNo AS Bill,
        doc.FullName AS Doctor,
        a.AdjustmentType,
        a.Amount,
        a.Reason,
        ISNULL(uReq.FullName, 'System') AS RequestedBy,
        ISNULL(uAppr.FullName, 'Pending') AS ApprovedBy
    FROM dbo.DoctorBillingAdjustment a
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = a.DoctorId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = a.VisitId
    LEFT JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = a.BillId
    LEFT JOIN dbo.Users uReq ON uReq.Id = a.RequestedBy
    LEFT JOIN dbo.Users uAppr ON uAppr.Id = a.ApprovedBy
    WHERE a.IsActive = 1
      AND (@CompanyId IS NULL OR a.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR a.DoctorId = @DoctorId)
      AND CAST(a.AdjustmentDate AS DATE) BETWEEN @FromDate AND @ToDate
    ORDER BY a.AdjustmentDate DESC;
END
GO

-- RPT-07: Refund / Reversal
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_RefundReversals
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -30, CAST(GETDATE() AS DATE));
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);

    SELECT
        d.ModifiedDate AS [Date],
        d.VisitId AS VisitNo,
        opd.OPDBillNo AS Bill,
        doc.FullName AS Doctor,
        d.NetBillAmount AS OriginalAmount,
        ABS(d.AdjustmentAmount) AS RefundAmount,
        d.AdjustmentReason AS Reason,
        ISNULL(uAppr.FullName, 'Admin') AS ApprovedBy,
        d.CalculatedAmount - d.NetPayable AS CommissionReversal
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = d.VisitId
    LEFT JOIN dbo.Users uAppr ON uAppr.Id = d.ApprovedBy
    WHERE d.IsActive = 1
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (d.AdjustmentAmount < 0 OR d.PaymentStatus = 'Reversed' OR d.ApprovalStatus = 'REJECTED')
      AND CAST(d.ModifiedDate AS DATE) BETWEEN @FromDate AND @ToDate
    ORDER BY d.ModifiedDate DESC;
END
GO

-- RPT-08: Doctor Settlement Summary
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DoctorSettlementSummary
    @BranchId INT = NULL,
    @DoctorId INT = NULL,
    @SettlementPeriod NVARCHAR(20) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        doc.FullName AS Doctor,
        spec.SpecialityName AS Specialty,
        COUNT(d.DisbursalId) AS Visits,
        SUM(d.CollectedAmount) AS Collection,
        SUM(d.CalculatedAmount) AS Commission,
        SUM(CASE WHEN d.PaymentStatus = 'Paid' THEN d.NetPayable ELSE 0 END) AS Paid,
        SUM(CASE WHEN d.PaymentStatus <> 'Paid' THEN d.NetPayable ELSE 0 END) AS YetToPay
    FROM dbo.DoctorDisbursal d
    INNER JOIN dbo.DoctorMaster doc ON doc.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster spec ON spec.SpecialityId = doc.PrimarySpecialityId
    WHERE d.IsActive = 1
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@DoctorId IS NULL OR d.DoctorId = @DoctorId)
      AND (@SettlementPeriod IS NULL OR d.SettlementPeriod = @SettlementPeriod)
    GROUP BY doc.DoctorId, doc.FullName, spec.SpecialityName
    ORDER BY doc.FullName ASC;
END
GO

-- =============================================================================
-- 9. Seed Initial Data
-- =============================================================================
IF NOT EXISTS (SELECT 1 FROM dbo.DoctorVisitProcessConfig WHERE VisitType = 'All' AND IsActive = 1)
BEGIN
    INSERT INTO dbo.DoctorVisitProcessConfig (
        CompanyId, BranchId, SpecialityId, DoctorId, VisitType, PaymentTiming,
        VitalsRequired, DiagnosisRequired, Icd10Required, ProcedureAllowed,
        BillingRequired, PaymentBeforeClosure, EffectiveFrom, IsActive, CreatedDate
    )
    VALUES (
        1, NULL, NULL, NULL, 'All', 'Before Consultation',
        1, 1, 1, 1, 1, 1, GETDATE(), 1, GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfig WHERE RevenueType = 'Consultation' AND IsActive = 1)
BEGIN
    INSERT INTO dbo.DoctorCommissionConfig (
        CompanyId, BranchId, DoctorId, SpecialityId, RevenueType, CalculationType,
        CommissionBasis, DoctorShare, ApprovalRequired, EffectiveFrom, IsActive, CreatedDate
    )
    VALUES
    (1, NULL, NULL, NULL, 'Consultation', 'Percentage', 'Net Collected', 70.00, 1, GETDATE(), 1, GETDATE()),
    (1, NULL, NULL, NULL, 'Procedure', 'Percentage', 'Net Collected', 60.00, 1, GETDATE(), 1, GETDATE()),
    (1, NULL, NULL, NULL, 'Investigation', 'Percentage', 'Net Collected', 15.00, 1, GETDATE(), 1, GETDATE()),
    (1, NULL, NULL, NULL, 'Emergency', 'Percentage', 'Net Collected', 75.00, 1, GETDATE(), 1, GETDATE());
END
GO
