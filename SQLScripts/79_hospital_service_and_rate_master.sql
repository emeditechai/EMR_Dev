-- ==============================================================================
-- Migration Script: 79_hospital_service_and_rate_master.sql
-- Description: Hospital Service Master & Hospital Service Rate Master tables and SPs
-- ==============================================================================

-- 1. HospitalServiceMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HospitalServiceMaster')
BEGIN
    CREATE TABLE dbo.HospitalServiceMaster
    (
        HospitalServiceId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HospitalServiceMaster PRIMARY KEY,
        CompanyId           INT NOT NULL CONSTRAINT DF_HospitalServiceMaster_CompanyId DEFAULT 1,
        BranchId            INT NOT NULL,
        DepartmentId        INT NOT NULL,
        ServiceCode         NVARCHAR(50) NOT NULL,
        ServiceName         NVARCHAR(200) NOT NULL,
        ServiceType         NVARCHAR(100) NOT NULL,
        UOM                 NVARCHAR(50) NOT NULL,
        TaxPercentage       DECIMAL(5,2) NOT NULL CONSTRAINT DF_HospitalServiceMaster_TaxPercentage DEFAULT 0.00,
        Description         NVARCHAR(500) NULL,
        IsActive            BIT NOT NULL CONSTRAINT DF_HospitalServiceMaster_IsActive DEFAULT 1,
        CreatedBy           INT NULL,
        CreatedDate         DATETIME NOT NULL CONSTRAINT DF_HospitalServiceMaster_CreatedDate DEFAULT GETDATE(),
        ModifiedBy          INT NULL,
        ModifiedDate        DATETIME NULL,

        CONSTRAINT FK_HospitalServiceMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_HospitalServiceMaster_Department FOREIGN KEY (DepartmentId) REFERENCES dbo.DepartmentMaster(DeptId),
        CONSTRAINT UQ_HospitalServiceMaster_Branch_ServiceCode UNIQUE (BranchId, ServiceCode)
    );

    CREATE INDEX IX_HospitalServiceMaster_Branch_Dept ON dbo.HospitalServiceMaster(BranchId, DepartmentId);
    CREATE INDEX IX_HospitalServiceMaster_ServiceType ON dbo.HospitalServiceMaster(ServiceType);
END;
GO

-- 2. HospitalServiceRateMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HospitalServiceRateMaster')
BEGIN
    CREATE TABLE dbo.HospitalServiceRateMaster
    (
        ServiceRateId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HospitalServiceRateMaster PRIMARY KEY,
        CompanyId           INT NOT NULL CONSTRAINT DF_HospitalServiceRateMaster_CompanyId DEFAULT 1,
        BranchId            INT NOT NULL,
        TariffCategoryId    INT NOT NULL,
        HospitalServiceId   INT NOT NULL,
        Rate                DECIMAL(18,2) NOT NULL CONSTRAINT DF_HospitalServiceRateMaster_Rate DEFAULT 0.00,
        EffectiveFrom       DATE NOT NULL,
        EffectiveTo         DATE NULL,
        Description         NVARCHAR(500) NULL,
        IsActive            BIT NOT NULL CONSTRAINT DF_HospitalServiceRateMaster_IsActive DEFAULT 1,
        CreatedBy           INT NULL,
        CreatedDate         DATETIME NOT NULL CONSTRAINT DF_HospitalServiceRateMaster_CreatedDate DEFAULT GETDATE(),
        ModifiedBy          INT NULL,
        ModifiedDate        DATETIME NULL,

        CONSTRAINT FK_HospitalServiceRateMaster_Branch FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_HospitalServiceRateMaster_TariffCategory FOREIGN KEY (TariffCategoryId) REFERENCES dbo.TariffCategoryMaster(TariffCategoryId),
        CONSTRAINT FK_HospitalServiceRateMaster_HospitalService FOREIGN KEY (HospitalServiceId) REFERENCES dbo.HospitalServiceMaster(HospitalServiceId)
    );

    CREATE INDEX IX_HospitalServiceRateMaster_Lookup ON dbo.HospitalServiceRateMaster(BranchId, TariffCategoryId, HospitalServiceId);
END;
GO

-- 3. Stored Procedure: usp_Api_HospitalService_GetList
CREATE OR ALTER PROCEDURE usp_Api_HospitalService_GetList
    @BranchId INT = NULL,
    @DepartmentId INT = NULL,
    @ServiceType NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        s.HospitalServiceId,
        s.CompanyId,
        s.BranchId,
        b.BranchName,
        b.BranchCode,
        s.DepartmentId,
        d.DeptName AS DepartmentName,
        d.DeptCode AS DepartmentCode,
        s.ServiceCode,
        s.ServiceName,
        s.ServiceType,
        s.UOM,
        s.TaxPercentage,
        s.Description,
        s.IsActive,
        s.CreatedDate
    FROM HospitalServiceMaster s
    INNER JOIN Branchmaster b ON s.BranchId = b.BranchID
    INNER JOIN DepartmentMaster d ON s.DepartmentId = d.DeptId
    WHERE (@BranchId IS NULL OR s.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR s.DepartmentId = @DepartmentId)
      AND (@ServiceType IS NULL OR s.ServiceType = @ServiceType)
      AND (@CompanyId IS NULL OR s.CompanyId = @CompanyId)
    ORDER BY d.DeptName, s.ServiceType, s.ServiceName;
END;
GO

-- 4. Stored Procedure: usp_Api_HospitalServiceRate_GetList
CREATE OR ALTER PROCEDURE usp_Api_HospitalServiceRate_GetList
    @BranchId INT = NULL,
    @TariffCategoryId INT = NULL,
    @HospitalServiceId INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        r.ServiceRateId,
        r.CompanyId,
        r.BranchId,
        b.BranchName,
        b.BranchCode,
        r.TariffCategoryId,
        tc.Name AS TariffCategoryName,
        tc.Code AS TariffCategoryCode,
        tc.PatientCategory,
        r.HospitalServiceId,
        s.ServiceCode,
        s.ServiceName,
        s.ServiceType,
        s.UOM,
        s.TaxPercentage,
        d.DeptName AS DepartmentName,
        r.Rate,
        r.EffectiveFrom,
        r.EffectiveTo,
        r.Description,
        r.IsActive,
        r.CreatedDate
    FROM HospitalServiceRateMaster r
    INNER JOIN Branchmaster b ON r.BranchId = b.BranchID
    INNER JOIN TariffCategoryMaster tc ON r.TariffCategoryId = tc.TariffCategoryId
    INNER JOIN HospitalServiceMaster s ON r.HospitalServiceId = s.HospitalServiceId
    INNER JOIN DepartmentMaster d ON s.DepartmentId = d.DeptId
    WHERE (@BranchId IS NULL OR r.BranchId = @BranchId)
      AND (@TariffCategoryId IS NULL OR r.TariffCategoryId = @TariffCategoryId)
      AND (@HospitalServiceId IS NULL OR r.HospitalServiceId = @HospitalServiceId)
      AND (@CompanyId IS NULL OR r.CompanyId = @CompanyId)
    ORDER BY tc.Name, s.ServiceName, r.EffectiveFrom DESC;
END;
GO
