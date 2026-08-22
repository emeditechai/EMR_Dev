-- ====================================================================================================
-- Script: 87_corporate_hospital_rate_master.sql
-- Description: Creates dbo.CorporateHospitalRateMaster table and Stored Procedures for API operations,
--              dynamic master reference items lookup, and seeds initial corporate rate rules.
-- ====================================================================================================

-- 1. Create dbo.CorporateHospitalRateMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CorporateHospitalRateMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.CorporateHospitalRateMaster
    (
        CorpRate_ID          INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        Corporate_ID         INT NOT NULL,
        RateServiceType      NVARCHAR(50) NOT NULL, -- Room, Procedure, OT, ICU, HospitalService, Package
        ReferenceMaster_ID   INT NOT NULL,          -- FK points to the relevant master row based on RateServiceType
        RateType             NVARCHAR(50) NOT NULL, -- Percentage, Rate, Both
        Rate                 DECIMAL(18,2) NULL,    -- Contracted / Fixed Rate
        DiscountPercent      DECIMAL(5,2) NULL,     -- Discount percentage applied
        Effective_From       DATETIME2 NOT NULL,
        Effective_To         DATETIME2 NOT NULL,
        Status               BIT NOT NULL DEFAULT 1, -- 1: Active, 0: Inactive
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_CorporateHospitalRate_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_CorporateHospitalRate_Corporate FOREIGN KEY (Corporate_ID) REFERENCES dbo.CorporateMaster(Corporate_ID) ON DELETE CASCADE
    );
    CREATE INDEX IX_CorpRate_Corporate ON dbo.CorporateHospitalRateMaster(Corporate_ID, Status);
    CREATE INDEX IX_CorpRate_Branch ON dbo.CorporateHospitalRateMaster(Branch_ID, RateServiceType);
    CREATE INDEX IX_CorpRate_Ref ON dbo.CorporateHospitalRateMaster(RateServiceType, ReferenceMaster_ID);
    PRINT 'Created table dbo.CorporateHospitalRateMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.CorporateHospitalRateMaster already exists';
END
GO

-- 2. Stored Procedure: usp_CorporateHospitalRate_GetMasterItems
-- Returns all available services/items from existing master tables under each dynamic service head
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_GetMasterItems
    @RateServiceType NVARCHAR(50) = NULL,
    @BranchId        INT = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Room Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'Room'
    BEGIN
        SELECT 
            'Room' AS RateServiceType,
            r.RoomId AS ReferenceMaster_ID,
            r.RoomNumber AS ItemCode,
            'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ' - ' + ISNULL(r.RoomType, '') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = r.RoomId AND t.IsActive = 1), 2500.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.RoomMaster r
        WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
          AND r.IsActive = 1
    END

    -- 2. Procedure Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'Procedure'
    BEGIN
        SELECT 
            'Procedure' AS RateServiceType,
            p.ProcedureId AS ReferenceMaster_ID,
            p.ProcedureCode AS ItemCode,
            p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = p.ProcedureId AND pt.IsActive = 1), 5000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.ProcedureMaster p
        WHERE (@BranchId IS NULL OR p.BranchId = @BranchId OR p.BranchId IS NULL)
          AND p.IsActive = 1
    END

    -- 3. OT Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'OT'
    BEGIN
        SELECT 
            'OT' AS RateServiceType,
            ot.OtId AS ReferenceMaster_ID,
            ot.OtCode AS ItemCode,
            'OT: ' + ot.OtName + ' (' + ISNULL(ot.OtType, 'Major') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 ott.TotalRate FROM dbo.OtTariffMaster ott WHERE ott.OtId = ot.OtId AND ott.IsActive = 1), 5000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.OtMaster ot
        WHERE (@BranchId IS NULL OR ot.BranchId = @BranchId OR ot.BranchId IS NULL)
          AND ot.IsActive = 1
    END

    -- 4. ICU Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'ICU'
    BEGIN
        SELECT 
            'ICU' AS RateServiceType,
            i.IcuId AS ReferenceMaster_ID,
            i.IcuCode AS ItemCode,
            'ICU: ' + i.IcuName + ' (' + ISNULL(i.IcuType, 'ICU') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 it.TotalRate FROM dbo.IcuTariffMaster it WHERE it.IcuId = i.IcuId AND it.IsActive = 1), 8000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.IcuMaster i
        WHERE (@BranchId IS NULL OR i.BranchId = @BranchId OR i.BranchId IS NULL)
          AND i.IsActive = 1
    END

    -- 5. Hospital Service Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'HospitalService'
    BEGIN
        SELECT 
            'HospitalService' AS RateServiceType,
            hs.HospitalServiceId AS ReferenceMaster_ID,
            hs.ServiceCode AS ItemCode,
            hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' AS ItemName,
            CAST(ISNULL((SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = hs.HospitalServiceId AND hsr.IsActive = 1), 1000.00) AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.HospitalServiceMaster hs
        WHERE (@BranchId IS NULL OR hs.BranchId = @BranchId OR hs.BranchId IS NULL)
          AND hs.IsActive = 1
    END

    -- 6. Hospital Package Master
    IF @RateServiceType IS NULL OR @RateServiceType = '' OR @RateServiceType = 'Package'
    BEGIN
        SELECT 
            'Package' AS RateServiceType,
            hp.HospitalPackage_ID AS ReferenceMaster_ID,
            hp.Package_Code AS ItemCode,
            hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' AS ItemName,
            CAST(hp.TotalPackageAmount AS DECIMAL(18,2)) AS BaseRate
        FROM dbo.HospitalPackageMaster hp
        WHERE (@BranchId IS NULL OR hp.Branch_ID = @BranchId OR hp.Branch_ID IS NULL)
          AND hp.Status = 1
    END
END
GO

-- 3. Stored Procedure: usp_CorporateHospitalRate_GetList
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_GetList
    @Corporate_ID    INT = NULL,
    @BranchId        INT = NULL,
    @RateServiceType NVARCHAR(50) = NULL,
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        cr.CorpRate_ID,
        cr.CompanyId,
        cr.Branch_ID,
        b.BranchName,
        b.BranchCode,
        cr.Corporate_ID,
        c.Corporate_Name,
        c.Corporate_Code,
        cr.RateServiceType,
        cr.ReferenceMaster_ID,
        cr.RateType,
        cr.Rate,
        cr.DiscountPercent,
        cr.Effective_From,
        cr.Effective_To,
        cr.Status,
        cr.CreatedBy,
        cr.CreatedDate,
        cr.ModifiedBy,
        cr.ModifiedDate,
        -- Resolve Dynamic Item Code, Name and Standard Base Rate from respective Master
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 r.RoomNumber FROM dbo.RoomMaster r WHERE r.RoomId = cr.ReferenceMaster_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureCode FROM dbo.ProcedureMaster p WHERE p.ProcedureId = cr.ReferenceMaster_ID)
            WHEN 'OT' THEN (SELECT TOP 1 ot.OtCode FROM dbo.OtMaster ot WHERE ot.OtId = cr.ReferenceMaster_ID)
            WHEN 'ICU' THEN (SELECT TOP 1 i.IcuCode FROM dbo.IcuMaster i WHERE i.IcuId = cr.ReferenceMaster_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = cr.ReferenceMaster_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Code FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE CAST(cr.ReferenceMaster_ID AS NVARCHAR(50))
        END AS ItemCode,
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = cr.ReferenceMaster_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' FROM dbo.ProcedureMaster p WHERE p.ProcedureId = cr.ReferenceMaster_ID)
            WHEN 'OT' THEN (SELECT TOP 1 ot.OtName + ' (' + ISNULL(ot.OtType, 'Major') + ')' FROM dbo.OtMaster ot WHERE ot.OtId = cr.ReferenceMaster_ID)
            WHEN 'ICU' THEN (SELECT TOP 1 i.IcuName + ' (' + ISNULL(i.IcuType, 'ICU') + ')' FROM dbo.IcuMaster i WHERE i.IcuId = cr.ReferenceMaster_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = cr.ReferenceMaster_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE 'Unknown Service Item #' + CAST(cr.ReferenceMaster_ID AS NVARCHAR(50))
        END AS ItemName,
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = cr.ReferenceMaster_ID AND t.IsActive = 1)
            WHEN 'Procedure' THEN (SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = cr.ReferenceMaster_ID AND pt.IsActive = 1)
            WHEN 'OT' THEN (SELECT TOP 1 ott.TotalRate FROM dbo.OtTariffMaster ott WHERE ott.OtId = cr.ReferenceMaster_ID AND ott.IsActive = 1)
            WHEN 'ICU' THEN (SELECT TOP 1 it.TotalRate FROM dbo.IcuTariffMaster it WHERE it.IcuId = cr.ReferenceMaster_ID AND it.IsActive = 1)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = cr.ReferenceMaster_ID AND hsr.IsActive = 1)
            WHEN 'Package' THEN (SELECT TOP 1 hp.TotalPackageAmount FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE 0.00
        END AS StandardBaseRate
    FROM dbo.CorporateHospitalRateMaster cr
    INNER JOIN dbo.CorporateMaster c ON cr.Corporate_ID = c.Corporate_ID
    INNER JOIN dbo.Branchmaster b ON cr.Branch_ID = b.BranchID
    WHERE (@Corporate_ID IS NULL OR cr.Corporate_ID = @Corporate_ID)
      AND (@BranchId IS NULL OR cr.Branch_ID = @BranchId)
      AND (@RateServiceType IS NULL OR @RateServiceType = '' OR cr.RateServiceType = @RateServiceType)
      AND (@Status IS NULL OR cr.Status = @Status)
      AND (@CompanyId IS NULL OR cr.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           cr.RateServiceType LIKE '%' + @Search + '%' OR
           cr.RateType LIKE '%' + @Search + '%' OR
           c.Corporate_Name LIKE '%' + @Search + '%')
    ORDER BY cr.CreatedDate DESC;
END
GO

-- 4. Stored Procedure: usp_CorporateHospitalRate_GetById
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_GetById
    @CorpRate_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        cr.CorpRate_ID,
        cr.CompanyId,
        cr.Branch_ID,
        b.BranchName,
        b.BranchCode,
        cr.Corporate_ID,
        c.Corporate_Name,
        c.Corporate_Code,
        cr.RateServiceType,
        cr.ReferenceMaster_ID,
        cr.RateType,
        cr.Rate,
        cr.DiscountPercent,
        cr.Effective_From,
        cr.Effective_To,
        cr.Status,
        cr.CreatedBy,
        cr.CreatedDate,
        cr.ModifiedBy,
        cr.ModifiedDate,
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 r.RoomNumber FROM dbo.RoomMaster r WHERE r.RoomId = cr.ReferenceMaster_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureCode FROM dbo.ProcedureMaster p WHERE p.ProcedureId = cr.ReferenceMaster_ID)
            WHEN 'OT' THEN (SELECT TOP 1 ot.OtCode FROM dbo.OtMaster ot WHERE ot.OtId = cr.ReferenceMaster_ID)
            WHEN 'ICU' THEN (SELECT TOP 1 i.IcuCode FROM dbo.IcuMaster i WHERE i.IcuId = cr.ReferenceMaster_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceCode FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = cr.ReferenceMaster_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Code FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE CAST(cr.ReferenceMaster_ID AS NVARCHAR(50))
        END AS ItemCode,
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 'Room ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ')' FROM dbo.RoomMaster r WHERE r.RoomId = cr.ReferenceMaster_ID)
            WHEN 'Procedure' THEN (SELECT TOP 1 p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' FROM dbo.ProcedureMaster p WHERE p.ProcedureId = cr.ReferenceMaster_ID)
            WHEN 'OT' THEN (SELECT TOP 1 ot.OtName + ' (' + ISNULL(ot.OtType, 'Major') + ')' FROM dbo.OtMaster ot WHERE ot.OtId = cr.ReferenceMaster_ID)
            WHEN 'ICU' THEN (SELECT TOP 1 i.IcuName + ' (' + ISNULL(i.IcuType, 'ICU') + ')' FROM dbo.IcuMaster i WHERE i.IcuId = cr.ReferenceMaster_ID)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hs.ServiceName + ' (' + ISNULL(hs.ServiceType, 'General') + ')' FROM dbo.HospitalServiceMaster hs WHERE hs.HospitalServiceId = cr.ReferenceMaster_ID)
            WHEN 'Package' THEN (SELECT TOP 1 hp.Package_Name + ' (' + ISNULL(hp.Package_Type, 'Standard') + ')' FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE 'Unknown Service Item #' + CAST(cr.ReferenceMaster_ID AS NVARCHAR(50))
        END AS ItemName,
        CASE cr.RateServiceType
            WHEN 'Room' THEN (SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.RoomId = cr.ReferenceMaster_ID AND t.IsActive = 1)
            WHEN 'Procedure' THEN (SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = cr.ReferenceMaster_ID AND pt.IsActive = 1)
            WHEN 'OT' THEN (SELECT TOP 1 ott.TotalRate FROM dbo.OtTariffMaster ott WHERE ott.OtId = cr.ReferenceMaster_ID AND ott.IsActive = 1)
            WHEN 'ICU' THEN (SELECT TOP 1 it.TotalRate FROM dbo.IcuTariffMaster it WHERE it.IcuId = cr.ReferenceMaster_ID AND it.IsActive = 1)
            WHEN 'HospitalService' THEN (SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = cr.ReferenceMaster_ID AND hsr.IsActive = 1)
            WHEN 'Package' THEN (SELECT TOP 1 hp.TotalPackageAmount FROM dbo.HospitalPackageMaster hp WHERE hp.HospitalPackage_ID = cr.ReferenceMaster_ID)
            ELSE 0.00
        END AS StandardBaseRate
    FROM dbo.CorporateHospitalRateMaster cr
    INNER JOIN dbo.CorporateMaster c ON cr.Corporate_ID = c.Corporate_ID
    INNER JOIN dbo.Branchmaster b ON cr.Branch_ID = b.BranchID
    WHERE cr.CorpRate_ID = @CorpRate_ID;
END
GO

-- 5. Stored Procedure: usp_CorporateHospitalRate_Create
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_Create
    @CompanyId          INT = 1,
    @Branch_ID          INT,
    @Corporate_ID       INT,
    @RateServiceType    NVARCHAR(50),
    @ReferenceMaster_ID INT,
    @RateType           NVARCHAR(50),
    @Rate               DECIMAL(18,2) = NULL,
    @DiscountPercent    DECIMAL(5,2) = NULL,
    @Effective_From     DATETIME2,
    @Effective_To       DATETIME2,
    @Status             BIT = 1,
    @CreatedBy          INT = NULL,
    @NewCorpRate_ID     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Adjust fields according to RateType
    IF @RateType = 'Percentage' SET @Rate = NULL;
    IF @RateType = 'Rate' SET @DiscountPercent = NULL;

    INSERT INTO dbo.CorporateHospitalRateMaster
    (
        CompanyId,
        Branch_ID,
        Corporate_ID,
        RateServiceType,
        ReferenceMaster_ID,
        RateType,
        Rate,
        DiscountPercent,
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
        @Corporate_ID,
        @RateServiceType,
        @ReferenceMaster_ID,
        @RateType,
        @Rate,
        @DiscountPercent,
        @Effective_From,
        @Effective_To,
        @Status,
        @CreatedBy,
        GETDATE()
    );

    SET @NewCorpRate_ID = SCOPE_IDENTITY();
END
GO

-- 6. Stored Procedure: usp_CorporateHospitalRate_Update
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_Update
    @CorpRate_ID        INT,
    @Branch_ID          INT,
    @Corporate_ID       INT,
    @RateServiceType    NVARCHAR(50),
    @ReferenceMaster_ID INT,
    @RateType           NVARCHAR(50),
    @Rate               DECIMAL(18,2) = NULL,
    @DiscountPercent    DECIMAL(5,2) = NULL,
    @Effective_From     DATETIME2,
    @Effective_To       DATETIME2,
    @Status             BIT = 1,
    @ModifiedBy         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @RateType = 'Percentage' SET @Rate = NULL;
    IF @RateType = 'Rate' SET @DiscountPercent = NULL;

    UPDATE dbo.CorporateHospitalRateMaster
    SET
        Branch_ID          = @Branch_ID,
        Corporate_ID       = @Corporate_ID,
        RateServiceType    = @RateServiceType,
        ReferenceMaster_ID = @ReferenceMaster_ID,
        RateType           = @RateType,
        Rate               = @Rate,
        DiscountPercent    = @DiscountPercent,
        Effective_From     = @Effective_From,
        Effective_To       = @Effective_To,
        Status             = @Status,
        ModifiedBy         = @ModifiedBy,
        ModifiedDate       = GETDATE()
    WHERE CorpRate_ID      = @CorpRate_ID;
END
GO

-- 7. Stored Procedure: usp_CorporateHospitalRate_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_ToggleStatus
    @CorpRate_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.CorporateHospitalRateMaster
    SET 
        Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE CorpRate_ID = @CorpRate_ID;

    SELECT Status FROM dbo.CorporateHospitalRateMaster WHERE CorpRate_ID = @CorpRate_ID;
END
GO

-- 8. Stored Procedure: usp_CorporateHospitalRate_Delete
CREATE OR ALTER PROCEDURE dbo.usp_CorporateHospitalRate_Delete
    @CorpRate_ID INT,
    @ModifiedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.CorporateHospitalRateMaster
    WHERE CorpRate_ID = @CorpRate_ID;
END
GO

-- 9. Seed Sample Corporate Rates for Primary Corporate Partner
IF NOT EXISTS (SELECT 1 FROM dbo.CorporateHospitalRateMaster)
BEGIN
    DECLARE @SampleCorp INT;
    SELECT TOP 1 @SampleCorp = Corporate_ID FROM dbo.CorporateMaster ORDER BY Corporate_ID;

    DECLARE @SampleBranch INT;
    SELECT TOP 1 @SampleBranch = BranchID FROM dbo.Branchmaster ORDER BY BranchID;

    IF @SampleCorp IS NOT NULL AND @SampleBranch IS NOT NULL
    BEGIN
        -- Find a sample procedure, room, service, package, OT, ICU
        DECLARE @RefProc INT, @RefRoom INT, @RefSvc INT, @RefPkg INT, @RefOt INT, @RefIcu INT;
        SELECT TOP 1 @RefProc = ProcedureId FROM dbo.ProcedureMaster ORDER BY ProcedureId;
        SELECT TOP 1 @RefRoom = RoomId FROM dbo.RoomMaster ORDER BY RoomId;
        SELECT TOP 1 @RefSvc = HospitalServiceId FROM dbo.HospitalServiceMaster ORDER BY HospitalServiceId;
        SELECT TOP 1 @RefPkg = HospitalPackage_ID FROM dbo.HospitalPackageMaster ORDER BY HospitalPackage_ID;
        SELECT TOP 1 @RefOt = OtId FROM dbo.OtMaster ORDER BY OtId;
        SELECT TOP 1 @RefIcu = IcuId FROM dbo.IcuMaster ORDER BY IcuId;

        -- 1. Procedure with Discount Percent (Percentage RateType)
        IF @RefProc IS NOT NULL
        BEGIN
            INSERT INTO dbo.CorporateHospitalRateMaster
            (CompanyId, Branch_ID, Corporate_ID, RateServiceType, ReferenceMaster_ID, RateType, Rate, DiscountPercent, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleCorp, 'Procedure', @RefProc, 'Percentage', NULL, 15.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 2. Room with Fixed Contracted Rate (Rate RateType)
        IF @RefRoom IS NOT NULL
        BEGIN
            INSERT INTO dbo.CorporateHospitalRateMaster
            (CompanyId, Branch_ID, Corporate_ID, RateServiceType, ReferenceMaster_ID, RateType, Rate, DiscountPercent, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleCorp, 'Room', @RefRoom, 'Rate', 2000.00, NULL, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 3. Package with Both Rate & Discount (Both RateType)
        IF @RefPkg IS NOT NULL
        BEGIN
            INSERT INTO dbo.CorporateHospitalRateMaster
            (CompanyId, Branch_ID, Corporate_ID, RateServiceType, ReferenceMaster_ID, RateType, Rate, DiscountPercent, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleCorp, 'Package', @RefPkg, 'Both', 35000.00, 10.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        -- 4. Hospital Service with Discount
        IF @RefSvc IS NOT NULL
        BEGIN
            INSERT INTO dbo.CorporateHospitalRateMaster
            (CompanyId, Branch_ID, Corporate_ID, RateServiceType, ReferenceMaster_ID, RateType, Rate, DiscountPercent, Effective_From, Effective_To, Status, CreatedDate)
            VALUES
            (1, @SampleBranch, @SampleCorp, 'HospitalService', @RefSvc, 'Percentage', NULL, 20.00, GETDATE(), DATEADD(YEAR, 1, GETDATE()), 1, GETDATE());
        END

        PRINT 'Sample Corporate Hospital Rates seeded successfully.';
    END
END
GO
