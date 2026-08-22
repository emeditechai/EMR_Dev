-- ====================================================================================================
-- Script: 88_insurance_tariff_configuration.sql
-- Description: Creates dbo.InsuranceTariffMaster table and Stored Procedures for Insurance Tariff
--              Configuration (Room, Package, Procedure, HospitalService, NonPayableItem),
--              dynamic master reference items lookup, and seeds initial insurance tariff rules.
-- ====================================================================================================

-- 1. Create dbo.InsuranceTariffMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InsuranceTariffMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.InsuranceTariffMaster
    (
        InsTariff_ID         INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        InsuranceTPA_ID      INT NOT NULL,
        EntitlementType      NVARCHAR(50) NOT NULL, -- Room, Package, Procedure, HospitalService, NonPayableItem
        Reference_ID         INT NOT NULL,          -- FK points to the relevant master row based on EntitlementType
        DeductionRuleType    NVARCHAR(100) NOT NULL, -- None, Fixed Deduction, Percentage Co-Pay, Proportional Capping, Non-Payable Item, Agreed Tariff Cap
        DeductionValue       DECIMAL(18,2) NOT NULL DEFAULT 0, -- Amount or percentage value
        Rate                 DECIMAL(18,2) NOT NULL DEFAULT 0, -- Approved/Agreed Insurer Tariff Rate
        Effective_From       DATETIME2 NOT NULL,
        Effective_To         DATETIME2 NOT NULL,
        Status               BIT NOT NULL DEFAULT 1, -- 1: Active, 0: Inactive
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_InsuranceTariff_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_InsuranceTariff_InsuranceTPA FOREIGN KEY (InsuranceTPA_ID) REFERENCES dbo.InsuranceTPAMaster(InsuranceTPA_ID) ON DELETE CASCADE
    );
    CREATE INDEX IX_InsTariff_InsuranceTPA ON dbo.InsuranceTariffMaster(InsuranceTPA_ID, Status);
    CREATE INDEX IX_InsTariff_Branch ON dbo.InsuranceTariffMaster(Branch_ID, EntitlementType);
    CREATE INDEX IX_InsTariff_Ref ON dbo.InsuranceTariffMaster(EntitlementType, Reference_ID);
    PRINT 'Created table dbo.InsuranceTariffMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.InsuranceTariffMaster already exists';
END
GO

-- 2. Stored Procedure: usp_InsuranceTariff_GetMasterItems
-- Returns all available services/items from existing master tables under each dynamic EntitlementType
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_GetMasterItems
    @EntitlementType NVARCHAR(50) = NULL,
    @BranchId        INT = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Room Master
    IF @EntitlementType IS NULL OR @EntitlementType = '' OR @EntitlementType = 'Room'
    BEGIN
        SELECT 
            'Room' AS EntitlementType,
            r.RoomId AS Reference_ID,
            r.RoomNumber AS ItemCode,
            'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ' - ' + ISNULL(r.RoomType, '') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = r.RoomId AND t.IsActive = 1), 2500.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.RoomMaster r
        WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
          AND r.IsActive = 1
    END

    -- 2. Package Master
    IF @EntitlementType IS NULL OR @EntitlementType = '' OR @EntitlementType = 'Package'
    BEGIN
        SELECT 
            'Package' AS EntitlementType,
            hp.HospitalPackage_ID AS Reference_ID,
            hp.Package_Code AS ItemCode,
            hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' AS ItemName,
            CAST(hp.TotalPackageAmount AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.HospitalPackageMaster hp
        WHERE (@BranchId IS NULL OR hp.Branch_ID = @BranchId OR hp.Branch_ID IS NULL)
          AND hp.Status = 1
    END

    -- 3. Procedure Master
    IF @EntitlementType IS NULL OR @EntitlementType = '' OR @EntitlementType = 'Procedure'
    BEGIN
        SELECT 
            'Procedure' AS EntitlementType,
            p.ProcedureId AS Reference_ID,
            p.ProcedureCode AS ItemCode,
            p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = p.ProcedureId AND pt.IsActive = 1), 5000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.ProcedureMaster p
        WHERE (@BranchId IS NULL OR p.BranchId = @BranchId OR p.BranchId IS NULL)
          AND p.IsActive = 1
    END

    -- 4. Hospital Service Master
    IF @EntitlementType IS NULL OR @EntitlementType = '' OR @EntitlementType = 'HospitalService'
    BEGIN
        SELECT 
            'HospitalService' AS EntitlementType,
            hs.HospitalServiceId AS Reference_ID,
            hs.ServiceCode AS ItemCode,
            hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = hs.HospitalServiceId AND hsr.IsActive = 1), 1000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.HospitalServiceMaster hs
        WHERE (@BranchId IS NULL OR hs.BranchId = @BranchId OR hs.BranchId IS NULL)
          AND hs.IsActive = 1
    END

    -- 5. Non-Payable Items (Consumables, Administrative, PPE, Gloves, Registration, etc. from HospitalServiceMaster)
    IF @EntitlementType IS NULL OR @EntitlementType = '' OR @EntitlementType = 'NonPayableItem'
    BEGIN
        SELECT 
            'NonPayableItem' AS EntitlementType,
            hs.HospitalServiceId AS Reference_ID,
            hs.ServiceCode AS ItemCode,
            hs.ServiceName + ' [Non-Payable Consumable]' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = hs.HospitalServiceId AND hsr.IsActive = 1), 350.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.HospitalServiceMaster hs
        WHERE (@BranchId IS NULL OR hs.BranchId = @BranchId OR hs.BranchId IS NULL)
          AND hs.IsActive = 1
    END
END
GO

-- 3. Stored Procedure: usp_InsuranceTariff_GetList
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_GetList
    @InsuranceTPA_ID INT = NULL,
    @BranchId        INT = NULL,
    @EntitlementType NVARCHAR(50) = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        it.InsTariff_ID,
        it.CompanyId,
        it.Branch_ID,
        b.BranchName,
        b.BranchCode,
        it.InsuranceTPA_ID,
        ins.Name AS InsuranceTPAName,
        ins.Code AS InsuranceTPACode,
        ins.Type AS InsuranceTPAType,
        it.EntitlementType,
        it.Reference_ID,
        it.DeductionRuleType,
        it.DeductionValue,
        it.Rate,
        it.Effective_From,
        it.Effective_To,
        it.Status,
        it.CreatedBy,
        it.CreatedDate,
        it.ModifiedBy,
        it.ModifiedDate,
        -- Resolve Dynamic Item Code, Name and Standard Base Rate from respective Master
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 r.RoomNumber FROM dbo.RoomMaster r WHERE r.RoomId = it.Reference_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Code FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureCode FROM dbo.ProcedureMaster p WHERE p.ProcedureId = it.Reference_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            ELSE CAST(it.Reference_ID AS NVARCHAR(50))
        END AS ItemCode,
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = it.Reference_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' FROM dbo.ProcedureMaster p WHERE p.ProcedureId = it.Reference_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hs.ServiceName + ' [Non-Payable Item]' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            ELSE 'Unknown Service Item #' + CAST(it.Reference_ID AS NVARCHAR(50))
        END AS ItemName,
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = it.Reference_ID AND t.IsActive = 1)
            WHEN 'Package' THEN (SELECT TOP 1 hp.TotalPackageAmount FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = it.Reference_ID AND pt.IsActive = 1)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = it.Reference_ID AND hsr.IsActive = 1)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = it.Reference_ID AND hsr.IsActive = 1)
            ELSE 0.00
        END AS StandardBaseRate
    FROM dbo.InsuranceTariffMaster it
    INNER JOIN dbo.InsuranceTPAMaster ins ON it.InsuranceTPA_ID = ins.InsuranceTPA_ID
    INNER JOIN dbo.Branchmaster b ON it.Branch_ID = b.BranchID
    WHERE (@InsuranceTPA_ID IS NULL OR it.InsuranceTPA_ID = @InsuranceTPA_ID)
      AND (@BranchId IS NULL OR it.Branch_ID = @BranchId)
      AND (@EntitlementType IS NULL OR @EntitlementType = '' OR it.EntitlementType = @EntitlementType)
      AND (@Status IS NULL OR it.Status = @Status)
      AND (@CompanyId IS NULL OR it.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           it.EntitlementType LIKE '%' + @Search + '%' OR
           it.DeductionRuleType LIKE '%' + @Search + '%' OR
           ins.Name LIKE '%' + @Search + '%')
    ORDER BY it.CreatedDate DESC;
END
GO

-- 4. Stored Procedure: usp_InsuranceTariff_GetById
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_GetById
    @InsTariff_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        it.InsTariff_ID,
        it.CompanyId,
        it.Branch_ID,
        b.BranchName,
        b.BranchCode,
        it.InsuranceTPA_ID,
        ins.Name AS InsuranceTPAName,
        ins.Code AS InsuranceTPACode,
        ins.Type AS InsuranceTPAType,
        it.EntitlementType,
        it.Reference_ID,
        it.DeductionRuleType,
        it.DeductionValue,
        it.Rate,
        it.Effective_From,
        it.Effective_To,
        it.Status,
        it.CreatedBy,
        it.CreatedDate,
        it.ModifiedBy,
        it.ModifiedDate,
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 r.RoomNumber FROM dbo.RoomMaster r WHERE r.RoomId = it.Reference_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Code FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureCode FROM dbo.ProcedureMaster p WHERE p.ProcedureId = it.Reference_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            ELSE CAST(it.Reference_ID AS NVARCHAR(50))
        END AS ItemCode,
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = it.Reference_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' FROM dbo.ProcedureMaster p WHERE p.ProcedureId = it.Reference_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hs.ServiceName + ' [Non-Payable Item]' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = it.Reference_ID)
            ELSE 'Unknown Service Item #' + CAST(it.Reference_ID AS NVARCHAR(50))
        END AS ItemName,
        CASE it.EntitlementType
            WHEN 'Room' THEN (SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = it.Reference_ID AND t.IsActive = 1)
            WHEN 'Package' THEN (SELECT TOP 1 hp.TotalPackageAmount FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = it.Reference_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = it.Reference_ID AND pt.IsActive = 1)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = it.Reference_ID AND hsr.IsActive = 1)
            WHEN 'NonPayableItem' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = it.Reference_ID AND hsr.IsActive = 1)
            ELSE 0.00
        END AS StandardBaseRate
    FROM dbo.InsuranceTariffMaster it
    INNER JOIN dbo.InsuranceTPAMaster ins ON it.InsuranceTPA_ID = ins.InsuranceTPA_ID
    INNER JOIN dbo.Branchmaster b ON it.Branch_ID = b.BranchID
    WHERE it.InsTariff_ID = @InsTariff_ID;
END
GO

-- 5. Stored Procedure: usp_InsuranceTariff_Create
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_Create
    @CompanyId         INT = 1,
    @Branch_ID         INT,
    @InsuranceTPA_ID   INT,
    @EntitlementType   NVARCHAR(50),
    @Reference_ID      INT,
    @DeductionRuleType NVARCHAR(100),
    @DeductionValue    DECIMAL(18,2) = 0,
    @Rate              DECIMAL(18,2) = 0,
    @Effective_From    DATETIME2,
    @Effective_To      DATETIME2,
    @Status            BIT = 1,
    @CreatedBy         INT = NULL,
    @NewInsTariff_ID   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.InsuranceTariffMaster
    (
        CompanyId,
        Branch_ID,
        InsuranceTPA_ID,
        EntitlementType,
        Reference_ID,
        DeductionRuleType,
        DeductionValue,
        Rate,
        Effective_From,
        Effective_To,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        @InsuranceTPA_ID,
        @EntitlementType,
        @Reference_ID,
        @DeductionRuleType,
        @DeductionValue,
        @Rate,
        @Effective_From,
        @Effective_To,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewInsTariff_ID = SCOPE_IDENTITY();
END
GO

-- 6. Stored Procedure: usp_InsuranceTariff_Update
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_Update
    @InsTariff_ID      INT,
    @Branch_ID         INT,
    @InsuranceTPA_ID   INT,
    @EntitlementType   NVARCHAR(50),
    @Reference_ID      INT,
    @DeductionRuleType NVARCHAR(100),
    @DeductionValue    DECIMAL(18,2) = 0,
    @Rate              DECIMAL(18,2) = 0,
    @Effective_From    DATETIME2,
    @Effective_To      DATETIME2,
    @Status            BIT = 1,
    @ModifiedBy        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.InsuranceTariffMaster
    SET
        Branch_ID         = @Branch_ID,
        InsuranceTPA_ID   = @InsuranceTPA_ID,
        EntitlementType   = @EntitlementType,
        Reference_ID      = @Reference_ID,
        DeductionRuleType = @DeductionRuleType,
        DeductionValue    = @DeductionValue,
        Rate              = @Rate,
        Effective_From    = @Effective_From,
        Effective_To      = @Effective_To,
        Status            = @Status,
        ModifiedBy        = @ModifiedBy,
        ModifiedDate      = GETDATE()
    WHERE InsTariff_ID    = @InsTariff_ID;
END
GO

-- 7. Stored Procedure: usp_InsuranceTariff_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_ToggleStatus
    @InsTariff_ID INT,
    @ModifiedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.InsuranceTariffMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE InsTariff_ID = @InsTariff_ID;

    SELECT Status FROM dbo.InsuranceTariffMaster WHERE InsTariff_ID = @InsTariff_ID;
END
GO

-- 8. Stored Procedure: usp_InsuranceTariff_Delete
CREATE OR ALTER PROCEDURE dbo.usp_InsuranceTariff_Delete
    @InsTariff_ID INT,
    @ModifiedBy   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.InsuranceTariffMaster
    WHERE InsTariff_ID = @InsTariff_ID;
END
GO

-- 9. Seed Sample Insurance Tariff Rules
IF NOT EXISTS (SELECT 1 FROM dbo.InsuranceTariffMaster)
BEGIN
    DECLARE @SampleIns INT;
    SELECT TOP 1 @SampleIns = InsuranceTPA_ID FROM dbo.InsuranceTPAMaster ORDER BY InsuranceTPA_ID;

    DECLARE @SampleBranch INT;
    SELECT TOP 1 @SampleBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @SampleIns IS NOT NULL AND @SampleBranch IS NOT NULL
    BEGIN
        DECLARE @RefProc INT, @RefRoom INT, @RefSvc INT, @RefPkg INT;
        SELECT TOP 1 @RefProc = ProcedureId FROM dbo.ProcedureMaster ORDER BY ProcedureId;
        SELECT TOP 1 @RefRoom = RoomId FROM dbo.RoomMaster ORDER BY RoomId;
        SELECT TOP 1 @RefSvc = HospitalServiceId FROM dbo.HospitalServiceMaster ORDER BY HospitalServiceId;
        SELECT TOP 1 @RefPkg = HospitalPackage_ID FROM dbo.HospitalPackageMaster ORDER BY HospitalPackage_ID;

        -- 1. Room Tariff with Capping Rule (Agreed Tariff Rate = 2200, 10% Co-Pay)
        IF @RefRoom IS NOT NULL
        BEGIN
            INSERT INTO dbo.InsuranceTariffMaster
            (CompanyId, Branch_ID, InsuranceTPA_ID, EntitlementType, Reference_ID, DeductionRuleType, DeductionValue, Rate, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleIns, 'Room', @RefRoom, 'Percentage Co-Pay (%)', 10.00, 2200.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 2. Package Tariff with Agreed Package Tariff
        IF @RefPkg IS NOT NULL
        BEGIN
            INSERT INTO dbo.InsuranceTariffMaster
            (CompanyId, Branch_ID, InsuranceTPA_ID, EntitlementType, Reference_ID, DeductionRuleType, DeductionValue, Rate, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleIns, 'Package', @RefPkg, 'Agreed Tariff Cap (₹)', 0.00, 32000.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 3. Procedure Tariff with Standard Rule
        IF @RefProc IS NOT NULL
        BEGIN
            INSERT INTO dbo.InsuranceTariffMaster
            (CompanyId, Branch_ID, InsuranceTPA_ID, EntitlementType, Reference_ID, DeductionRuleType, DeductionValue, Rate, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleIns, 'Procedure', @RefProc, 'Standard Tariff', 0.00, 4800.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 4. Non-Payable Item (Consumables - 100% Deduction)
        IF @RefSvc IS NOT NULL
        BEGIN
            INSERT INTO dbo.InsuranceTariffMaster
            (CompanyId, Branch_ID, InsuranceTPA_ID, EntitlementType, Reference_ID, DeductionRuleType, DeductionValue, Rate, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleIns, 'NonPayableItem', @RefSvc, 'Non-Payable (100% Deducted)', 100.00, 0.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        PRINT 'Sample Insurance Tariff Configuration rules seeded successfully.';
    END
END
GO
