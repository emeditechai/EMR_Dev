-- ====================================================================================================
-- Script: 84_hospital_package_master.sql
-- Description: Creates dbo.HospitalPackageMaster (Header) and dbo.HospitalPackageDetail (Dynamic Details)
--              tables, Stored Procedures for API operations & Master Lookups, and seeds sample packages.
-- ====================================================================================================

-- 1. Create dbo.HospitalPackageMaster Table (Header)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HospitalPackageMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HospitalPackageMaster
    (
        HospitalPackage_ID   INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId            INT NOT NULL DEFAULT 1,
        Branch_ID            INT NOT NULL,
        Package_Code         NVARCHAR(50) NOT NULL,
        Package_Name         NVARCHAR(150) NOT NULL,
        Package_Type         NVARCHAR(50) NOT NULL, -- Maternity, Cataract, Surgery, Cardiac, ICU, Wellness Hospitalization, Orthopedic, Laparoscopy, Day Care, etc.
        ValidFrom            DATETIME2 NOT NULL DEFAULT GETDATE(),
        ValidTo              DATETIME2 NULL,
        TotalPackageAmount   DECIMAL(18,2) NOT NULL DEFAULT 0,
        Description          NVARCHAR(500) NULL,
        Status               BIT NOT NULL DEFAULT 1, -- 1: Active, 0: Inactive
        CreatedBy            INT NULL,
        CreatedDate          DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy           INT NULL,
        ModifiedDate         DATETIME2 NULL,
        CONSTRAINT FK_HospitalPackageMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT UQ_HospitalPackageMaster_Branch_Code UNIQUE (Branch_ID, Package_Code)
    );
    PRINT 'Created table dbo.HospitalPackageMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.HospitalPackageMaster already exists';
END
GO

-- 2. Create dbo.HospitalPackageDetail Table (Dynamic Details)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HospitalPackageDetail' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.HospitalPackageDetail
    (
        HospitalPackageDetail_ID INT IDENTITY(1,1) PRIMARY KEY,
        HospitalPackage_ID       INT NOT NULL,
        DetailHeadType           NVARCHAR(50) NOT NULL, -- Bed, Room, Procedure, Doctor fee, Nursing, OT, Anaesthesia, Consumables, Equipment, Hospital services, Other
        MasterReferenceId        INT NULL,              -- Optional FK / Reference ID to corresponding master table
        ItemCode                 NVARCHAR(50) NULL,
        ItemName                 NVARCHAR(200) NOT NULL,
        Quantity                 DECIMAL(18,2) NOT NULL DEFAULT 1,
        UnitRate                 DECIMAL(18,2) NOT NULL DEFAULT 0,
        Amount                   DECIMAL(18,2) NOT NULL DEFAULT 0,
        BillingFrequency         NVARCHAR(50) NOT NULL DEFAULT 'Package Included', -- Package Included, Per Day, One Time, Per Hour, Per Usage
        IsMandatory              BIT NOT NULL DEFAULT 1,
        Remarks                  NVARCHAR(250) NULL,
        DisplayOrder             INT NOT NULL DEFAULT 0,
        CONSTRAINT FK_HospitalPackageDetail_Package FOREIGN KEY (HospitalPackage_ID) REFERENCES dbo.HospitalPackageMaster(HospitalPackage_ID) ON DELETE CASCADE
    );
    PRINT 'Created table dbo.HospitalPackageDetail';
END
ELSE
BEGIN
    PRINT 'Table dbo.HospitalPackageDetail already exists';
END
GO

-- 3. Stored Procedure: usp_HospitalPackage_GetList
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_GetList
    @BranchId    INT = NULL,
    @PackageType NVARCHAR(50) = NULL,
    @Status      BIT = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        p.HospitalPackage_ID,
        p.CompanyId,
        p.Branch_ID,
        b.BranchName,
        b.BranchCode,
        p.Package_Code,
        p.Package_Name,
        p.Package_Type,
        p.ValidFrom,
        p.ValidTo,
        p.TotalPackageAmount,
        p.Description,
        p.Status,
        p.CreatedBy,
        p.CreatedDate,
        p.ModifiedBy,
        p.ModifiedDate,
        (SELECT COUNT(1) FROM dbo.HospitalPackageDetail d WHERE d.HospitalPackage_ID = p.HospitalPackage_ID) AS TotalDetailsCount,
        (SELECT COUNT(DISTINCT d.DetailHeadType) FROM dbo.HospitalPackageDetail d WHERE d.HospitalPackage_ID = p.HospitalPackage_ID) AS DistinctHeadsCount
    FROM dbo.HospitalPackageMaster p
    INNER JOIN dbo.Branchmaster b ON p.Branch_ID = b.BranchID
    WHERE (@BranchId IS NULL OR p.Branch_ID = @BranchId)
      AND (@PackageType IS NULL OR @PackageType = '' OR p.Package_Type = @PackageType)
      AND (@Status IS NULL OR p.Status = @Status)
      AND (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR 
           p.Package_Code LIKE '%' + @Search + '%' OR 
           p.Package_Name LIKE '%' + @Search + '%' OR 
           p.Package_Type LIKE '%' + @Search + '%')
    ORDER BY p.CreatedDate DESC;
END
GO

-- 4. Stored Procedure: usp_HospitalPackage_GetById
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_GetById
    @HospitalPackage_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Result Set 1: Header
    SELECT 
        p.HospitalPackage_ID,
        p.CompanyId,
        p.Branch_ID,
        b.BranchName,
        b.BranchCode,
        p.Package_Code,
        p.Package_Name,
        p.Package_Type,
        p.ValidFrom,
        p.ValidTo,
        p.TotalPackageAmount,
        p.Description,
        p.Status,
        p.CreatedBy,
        p.CreatedDate,
        p.ModifiedBy,
        p.ModifiedDate
    FROM dbo.HospitalPackageMaster p
    INNER JOIN dbo.Branchmaster b ON p.Branch_ID = b.BranchID
    WHERE p.HospitalPackage_ID = @HospitalPackage_ID;

    -- Result Set 2: Details
    SELECT 
        d.HospitalPackageDetail_ID,
        d.HospitalPackage_ID,
        d.DetailHeadType,
        d.MasterReferenceId,
        d.ItemCode,
        d.ItemName,
        d.Quantity,
        d.UnitRate,
        d.Amount,
        d.BillingFrequency,
        d.IsMandatory,
        d.Remarks,
        d.DisplayOrder
    FROM dbo.HospitalPackageDetail d
    WHERE d.HospitalPackage_ID = @HospitalPackage_ID
    ORDER BY d.DisplayOrder, d.DetailHeadType, d.ItemName;
END
GO

-- 5. Stored Procedure: usp_HospitalPackage_Create
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_Create
    @CompanyId          INT = 1,
    @Branch_ID          INT,
    @Package_Code       NVARCHAR(50),
    @Package_Name       NVARCHAR(150),
    @Package_Type       NVARCHAR(50),
    @ValidFrom          DATETIME2,
    @ValidTo            DATETIME2 = NULL,
    @TotalPackageAmount DECIMAL(18,2) = 0,
    @Description        NVARCHAR(500) = NULL,
    @Status             BIT = 1,
    @CreatedBy          INT = NULL,
    @DetailsJson        NVARCHAR(MAX) = NULL,
    @NewHospitalPackage_ID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        -- Check unique package code
        IF EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE Branch_ID = @Branch_ID AND Package_Code = @Package_Code)
        BEGIN
            RAISERROR('Package Code already exists for this branch.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        INSERT INTO dbo.HospitalPackageMaster
        (
            CompanyId,
            Branch_ID,
            Package_Code,
            Package_Name,
            Package_Type,
            ValidFrom,
            ValidTo,
            TotalPackageAmount,
            Description,
            Status,
            CreatedBy,
            CreatedDate
        )
        VALUES
        (
            @CompanyId,
            @Branch_ID,
            @Package_Code,
            @Package_Name,
            @Package_Type,
            @ValidFrom,
            @ValidTo,
            @TotalPackageAmount,
            @Description,
            @Status,
            @CreatedBy,
            GETDATE()
        );

        SET @NewHospitalPackage_ID = SCOPE_IDENTITY();

        -- Insert details from JSON if supplied
        IF @DetailsJson IS NOT NULL AND ISJSON(@DetailsJson) = 1
        BEGIN
            INSERT INTO dbo.HospitalPackageDetail
            (
                HospitalPackage_ID,
                DetailHeadType,
                MasterReferenceId,
                ItemCode,
                ItemName,
                Quantity,
                UnitRate,
                Amount,
                BillingFrequency,
                IsMandatory,
                Remarks,
                DisplayOrder
            )
            SELECT 
                @NewHospitalPackage_ID,
                ISNULL(JSON_VALUE(value, '$.detailHeadType'), 'Other'),
                TRY_CAST(JSON_VALUE(value, '$.masterReferenceId') AS INT),
                JSON_VALUE(value, '$.itemCode'),
                ISNULL(JSON_VALUE(value, '$.itemName'), 'Package Item'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.quantity') AS DECIMAL(18,2)), 1),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.unitRate') AS DECIMAL(18,2)), 0),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)), 0),
                ISNULL(JSON_VALUE(value, '$.billingFrequency'), 'Package Included'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.isMandatory') AS BIT), 1),
                JSON_VALUE(value, '$.remarks'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.displayOrder') AS INT), [key])
            FROM OPENJSON(@DetailsJson);

            -- Recalculate and update TotalPackageAmount if greater than 0
            DECLARE @CalculatedTotal DECIMAL(18,2);
            SELECT @CalculatedTotal = SUM(Amount) FROM dbo.HospitalPackageDetail WHERE HospitalPackage_ID = @NewHospitalPackage_ID;
            IF @CalculatedTotal IS NOT NULL AND @CalculatedTotal > 0
            BEGIN
                UPDATE dbo.HospitalPackageMaster
                SET TotalPackageAmount = @CalculatedTotal
                WHERE HospitalPackage_ID = @NewHospitalPackage_ID;
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 6. Stored Procedure: usp_HospitalPackage_Update
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_Update
    @HospitalPackage_ID INT,
    @CompanyId          INT = 1,
    @Branch_ID          INT,
    @Package_Code       NVARCHAR(50),
    @Package_Name       NVARCHAR(150),
    @Package_Type       NVARCHAR(50),
    @ValidFrom          DATETIME2,
    @ValidTo            DATETIME2 = NULL,
    @TotalPackageAmount DECIMAL(18,2) = 0,
    @Description        NVARCHAR(500) = NULL,
    @Status             BIT = 1,
    @ModifiedBy         INT = NULL,
    @DetailsJson        NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;

    BEGIN TRY
        -- Check unique package code
        IF EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster 
                   WHERE Branch_ID = @Branch_ID 
                     AND Package_Code = @Package_Code 
                     AND HospitalPackage_ID <> @HospitalPackage_ID)
        BEGIN
            RAISERROR('Another package with this Package Code already exists for this branch.', 16, 1);
            ROLLBACK TRANSACTION;
            RETURN;
        END

        UPDATE dbo.HospitalPackageMaster
        SET CompanyId          = @CompanyId,
            Branch_ID          = @Branch_ID,
            Package_Code       = @Package_Code,
            Package_Name       = @Package_Name,
            Package_Type       = @Package_Type,
            ValidFrom          = @ValidFrom,
            ValidTo            = @ValidTo,
            TotalPackageAmount = @TotalPackageAmount,
            Description        = @Description,
            Status             = @Status,
            ModifiedBy         = @ModifiedBy,
            ModifiedDate       = GETDATE()
        WHERE HospitalPackage_ID = @HospitalPackage_ID;

        -- Replace Details from JSON if supplied
        IF @DetailsJson IS NOT NULL AND ISJSON(@DetailsJson) = 1
        BEGIN
            DELETE FROM dbo.HospitalPackageDetail WHERE HospitalPackage_ID = @HospitalPackage_ID;

            INSERT INTO dbo.HospitalPackageDetail
            (
                HospitalPackage_ID,
                DetailHeadType,
                MasterReferenceId,
                ItemCode,
                ItemName,
                Quantity,
                UnitRate,
                Amount,
                BillingFrequency,
                IsMandatory,
                Remarks,
                DisplayOrder
            )
            SELECT 
                @HospitalPackage_ID,
                ISNULL(JSON_VALUE(value, '$.detailHeadType'), 'Other'),
                TRY_CAST(JSON_VALUE(value, '$.masterReferenceId') AS INT),
                JSON_VALUE(value, '$.itemCode'),
                ISNULL(JSON_VALUE(value, '$.itemName'), 'Package Item'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.quantity') AS DECIMAL(18,2)), 1),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.unitRate') AS DECIMAL(18,2)), 0),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)), 0),
                ISNULL(JSON_VALUE(value, '$.billingFrequency'), 'Package Included'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.isMandatory') AS BIT), 1),
                JSON_VALUE(value, '$.remarks'),
                ISNULL(TRY_CAST(JSON_VALUE(value, '$.displayOrder') AS INT), [key])
            FROM OPENJSON(@DetailsJson);

            -- Update TotalPackageAmount
            DECLARE @CalculatedTotal DECIMAL(18,2);
            SELECT @CalculatedTotal = SUM(Amount) FROM dbo.HospitalPackageDetail WHERE HospitalPackage_ID = @HospitalPackage_ID;
            IF @CalculatedTotal IS NOT NULL AND @CalculatedTotal > 0
            BEGIN
                UPDATE dbo.HospitalPackageMaster
                SET TotalPackageAmount = @CalculatedTotal
                WHERE HospitalPackage_ID = @HospitalPackage_ID;
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 7. Stored Procedure: usp_HospitalPackage_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_ToggleStatus
    @HospitalPackage_ID INT,
    @ModifiedBy         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.HospitalPackageMaster
    SET Status       = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy   = @ModifiedBy,
        ModifiedDate = GETDATE()
    WHERE HospitalPackage_ID = @HospitalPackage_ID;
END
GO

-- 8. Stored Procedure: usp_HospitalPackage_Delete
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_Delete
    @HospitalPackage_ID INT,
    @DeletedBy          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.HospitalPackageMaster
    WHERE HospitalPackage_ID = @HospitalPackage_ID;
END
GO

-- 9. Stored Procedure: usp_HospitalPackage_GetMasterLookups
CREATE OR ALTER PROCEDURE dbo.usp_HospitalPackage_GetMasterLookups
    @BranchId  INT = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Bed Master
    SELECT 
        'Bed' AS DetailHeadType,
        b.BedId AS MasterReferenceId,
        b.BedNumber AS ItemCode,
        'Bed: ' + b.BedNumber + ' (' + ISNULL(bc.CategoryName, 'Standard') + ' - ' + ISNULL(w.WardName, '') + ')' AS ItemName,
        CAST(ISNULL((SELECT TOP 1 (t.BedCharge + t.RoomCharge) FROM dbo.BedRoomTariffMaster t WHERE t.BedCategoryId = b.BedCategoryId AND t.IsActive = 1), 1500.00) AS DECIMAL(18,2)) AS DefaultRate,
        'Per Day' AS DefaultBillingFrequency
    FROM dbo.BedMaster b
    LEFT JOIN dbo.BedCategoryMaster bc ON b.BedCategoryId = bc.BedCategoryId
    LEFT JOIN dbo.WardMaster w ON b.WardId = w.WardId
    WHERE (@BranchId IS NULL OR b.BranchId = @BranchId OR b.BranchId IS NULL)
      AND b.IsActive = 1

    UNION ALL

    -- 2. Room Master
    SELECT 
        'Room' AS DetailHeadType,
        r.RoomId AS MasterReferenceId,
        r.RoomNumber AS ItemCode,
        'Room: ' + r.RoomNumber + ' (' + ISNULL(r.RoomCategory, 'General') + ' - ' + ISNULL(r.RoomType, '') + ')' AS ItemName,
        CAST(2500.00 AS DECIMAL(18,2)) AS DefaultRate,
        'Per Day' AS DefaultBillingFrequency
    FROM dbo.RoomMaster r
    WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
      AND r.IsActive = 1

    UNION ALL

    -- 3. Procedure Master
    SELECT 
        'Procedure' AS DetailHeadType,
        p.ProcedureId AS MasterReferenceId,
        p.ProcedureCode AS ItemCode,
        p.ProcedureName + ' [' + ISNULL(p.ProcedureCategory, 'General') + ']' AS ItemName,
        CAST(ISNULL((SELECT TOP 1 pt.TotalRate FROM dbo.ProcedureTariffMaster pt WHERE pt.ProcedureId = p.ProcedureId AND pt.IsActive = 1), 5000.00) AS DECIMAL(18,2)) AS DefaultRate,
        'One Time' AS DefaultBillingFrequency
    FROM dbo.ProcedureMaster p
    WHERE (@BranchId IS NULL OR p.BranchId = @BranchId OR p.BranchId IS NULL)
      AND p.IsActive = 1

    UNION ALL

    -- 4. Doctor Master (Doctor fee)
    SELECT 
        'Doctor fee' AS DetailHeadType,
        d.DoctorId AS MasterReferenceId,
        CAST(d.DoctorId AS NVARCHAR(50)) AS ItemCode,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName + ' (' + ISNULL(s.SpecialityName, 'Consultant') + ')' AS ItemName,
        CAST(ISNULL((SELECT TOP 1 sm.ItemCharges FROM dbo.DoctorConsultingFeeMap f INNER JOIN dbo.ServiceMaster sm ON f.ServiceId = sm.ServiceId WHERE f.DoctorId = d.DoctorId AND (@BranchId IS NULL OR f.BranchId = @BranchId)), 1000.00) AS DECIMAL(18,2)) AS DefaultRate,
        'Package Included' AS DefaultBillingFrequency
    FROM dbo.DoctorMaster d
    LEFT JOIN dbo.DoctorSpecialityMaster s ON d.PrimarySpecialityId = s.SpecialityId
    WHERE d.IsActive = 1

    UNION ALL

    -- 5. Nursing Station / Nursing Services
    SELECT 
        'Nursing' AS DetailHeadType,
        ns.NursingStationId AS MasterReferenceId,
        ns.StationCode AS ItemCode,
        'Nursing Care - ' + ns.StationName + ' (' + ISNULL(w.WardName, 'General') + ')' AS ItemName,
        CAST(800.00 AS DECIMAL(18,2)) AS DefaultRate,
        'Per Day' AS DefaultBillingFrequency
    FROM dbo.NursingStationMaster ns
    LEFT JOIN dbo.WardMaster w ON ns.WardId = w.WardId
    WHERE (@BranchId IS NULL OR ns.BranchId = @BranchId OR ns.BranchId IS NULL)
      AND ns.IsActive = 1

    UNION ALL

    -- 6. OT Master
    SELECT 
        'OT' AS DetailHeadType,
        ot.OtId AS MasterReferenceId,
        ot.OtCode AS ItemCode,
        'Operation Theatre: ' + ot.OtName + ' (' + ISNULL(ot.OtType, 'Major') + ')' AS ItemName,
        CAST(ISNULL((SELECT TOP 1 ott.TotalRate FROM dbo.OtTariffMaster ott WHERE ott.OtId = ot.OtId AND ott.IsActive = 1), 5000.00) AS DECIMAL(18,2)) AS DefaultRate,
        'One Time' AS DefaultBillingFrequency
    FROM dbo.OtMaster ot
    WHERE (@BranchId IS NULL OR ot.BranchId = @BranchId OR ot.BranchId IS NULL)
      AND ot.IsActive = 1

    UNION ALL

    -- 7. Anaesthesia
    SELECT 
        'Anaesthesia' AS DetailHeadType,
        a.AnaesthesiaTypeId AS MasterReferenceId,
        a.TypeCode AS ItemCode,
        'Anaesthesia: ' + a.TypeName + ISNULL(' (' + a.Description + ')', '') AS ItemName,
        CAST(ISNULL((SELECT TOP 1 ar.TotalRate FROM dbo.AnaesthesiaRateMaster ar WHERE ar.AnaesthesiaTypeId = a.AnaesthesiaTypeId AND ar.IsActive = 1), 3500.00) AS DECIMAL(18,2)) AS DefaultRate,
        'One Time' AS DefaultBillingFrequency
    FROM dbo.AnaesthesiaTypeMaster a
    WHERE (@BranchId IS NULL OR a.BranchId = @BranchId OR a.BranchId IS NULL)
      AND a.IsActive = 1

    UNION ALL

    -- 8. Equipment (OT / Medical Equipment)
    SELECT 
        'Equipment' AS DetailHeadType,
        eq.EquipmentId AS MasterReferenceId,
        eq.EquipmentCode AS ItemCode,
        'Equipment: ' + eq.EquipmentName + ' (' + ISNULL(eq.EquipmentType, 'Standard') + ')' AS ItemName,
        CAST(1200.00 AS DECIMAL(18,2)) AS DefaultRate,
        'Per Usage' AS DefaultBillingFrequency
    FROM dbo.OtEquipmentMaster eq
    WHERE (@BranchId IS NULL OR eq.BranchId = @BranchId OR eq.BranchId IS NULL)
      AND eq.IsActive = 1

    UNION ALL

    -- 9. Hospital Services
    SELECT 
        'Hospital services' AS DetailHeadType,
        hs.HospitalServiceId AS MasterReferenceId,
        hs.ServiceCode AS ItemCode,
        hs.ServiceName + ' [' + ISNULL(hs.ServiceType, 'General') + ']' AS ItemName,
        CAST(ISNULL((SELECT TOP 1 hsr.Rate FROM dbo.HospitalServiceRateMaster hsr WHERE hsr.HospitalServiceId = hs.HospitalServiceId AND hsr.IsActive = 1), 500.00) AS DECIMAL(18,2)) AS DefaultRate,
        'Package Included' AS DefaultBillingFrequency
    FROM dbo.HospitalServiceMaster hs
    WHERE (@BranchId IS NULL OR hs.BranchId = @BranchId OR hs.BranchId IS NULL)
      AND hs.IsActive = 1

    UNION ALL

    -- 10. Consumables (Standard / Pharmacy presets)
    SELECT 
        'Consumables' AS DetailHeadType,
        NULL AS MasterReferenceId,
        'MED-CONS-01' AS ItemCode,
        'Standard Surgical Consumables & Disposable Kit' AS ItemName,
        CAST(2500.00 AS DECIMAL(18,2)) AS DefaultRate,
        'Package Included' AS DefaultBillingFrequency

    ORDER BY DetailHeadType, ItemName;
END
GO

-- 10. Seed Initial Standard Hospital Packages
DECLARE @DefaultBranchId INT = (SELECT TOP 1 BranchID FROM dbo.Branchmaster ORDER BY BranchID);
IF @DefaultBranchId IS NOT NULL
BEGIN
    -- Package 1: Normal Delivery Maternity Package
    IF NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE Branch_ID = @DefaultBranchId AND Package_Code = 'PKG-MAT-01')
    BEGIN
        DECLARE @PkgId1 INT;
        EXEC dbo.usp_HospitalPackage_Create
            @CompanyId = 1,
            @Branch_ID = @DefaultBranchId,
            @Package_Code = 'PKG-MAT-01',
            @Package_Name = 'Normal Delivery Maternity Care Package (3 Days)',
            @Package_Type = 'Maternity',
            @ValidFrom = '2026-01-01',
            @ValidTo = '2026-12-31',
            @TotalPackageAmount = 32500.00,
            @Description = 'Comprehensive 3-day maternity package including normal vaginal delivery, room accommodation, neonatal initial checkup, nursing care, and consumables.',
            @Status = 1,
            @CreatedBy = 1,
            @DetailsJson = '[
                {"detailHeadType":"Bed","itemCode":"BED-MAT-01","itemName":"3-Day Post-Natal Semi-Private Bed","quantity":3,"unitRate":2000,"amount":6000,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Postnatal ward accommodation"},
                {"detailHeadType":"Procedure","itemCode":"PROC-DEL-01","itemName":"Normal Vaginal Delivery Procedure","quantity":1,"unitRate":12000,"amount":12000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Delivery conduction with fetal monitoring"},
                {"detailHeadType":"Doctor fee","itemCode":"DOC-GYN-01","itemName":"Obstetrician & Pediatrician Inpatient Visits","quantity":3,"unitRate":1500,"amount":4500,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Daily rounds & baby screening"},
                {"detailHeadType":"Nursing","itemCode":"NUR-MAT-01","itemName":"24/7 Specialized Midwifery & Nursing Care","quantity":3,"unitRate":800,"amount":2400,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Lactation and maternal nursing"},
                {"detailHeadType":"OT","itemCode":"OT-LAB-01","itemName":"Labor & Birthing Suite Facility Charges","quantity":1,"unitRate":4000,"amount":4000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Labor room setup"},
                {"detailHeadType":"Consumables","itemCode":"CONS-MAT-01","itemName":"Maternity Delivery Kit & Disposables","quantity":1,"unitRate":2500,"amount":2500,"billingFrequency":"Package Included","isMandatory":true,"remarks":"Sterile gowns, cord clamps, pads"},
                {"detailHeadType":"Hospital services","itemCode":"SRV-NEO-01","itemName":"Newborn Immunization (BCG, Polio, Hep-B) & Lab","quantity":1,"unitRate":1100,"amount":1100,"billingFrequency":"Package Included","isMandatory":true,"remarks":"Initial newborn vaccination"}
            ]',
            @NewHospitalPackage_ID = @PkgId1 OUTPUT;
        PRINT 'Seeded Package 1: Normal Delivery Maternity Package';
    END

    -- Package 2: Cataract Surgery Package (Phaco + Foldable IOL)
    IF NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE Branch_ID = @DefaultBranchId AND Package_Code = 'PKG-CAT-01')
    BEGIN
        DECLARE @PkgId2 INT;
        EXEC dbo.usp_HospitalPackage_Create
            @CompanyId = 1,
            @Branch_ID = @DefaultBranchId,
            @Package_Code = 'PKG-CAT-01',
            @Package_Name = 'Phacoemulsification Cataract Surgery with Foldable IOL',
            @Package_Type = 'Cataract',
            @ValidFrom = '2026-01-01',
            @ValidTo = '2026-12-31',
            @TotalPackageAmount = 24000.00,
            @Description = 'Day-care cataract package featuring sutureless phaco surgery, premium foldable hydrophobic intraocular lens, topical anaesthesia, and post-op follow-up.',
            @Status = 1,
            @CreatedBy = 1,
            @DetailsJson = '[
                {"detailHeadType":"Procedure","itemCode":"PROC-EYE-01","itemName":"Phacoemulsification with Foldable IOL Implantation","quantity":1,"unitRate":14000,"amount":14000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Advanced micro-incision phaco"},
                {"detailHeadType":"Doctor fee","itemCode":"DOC-OPH-01","itemName":"Senior Ophthalmic Surgeon Professional Fee","quantity":1,"unitRate":4000,"amount":4000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Surgical & post-op consultation"},
                {"detailHeadType":"Anaesthesia","itemCode":"ANA-TOP-01","itemName":"Topical / Peribulbar Eye Anaesthesia","quantity":1,"unitRate":1500,"amount":1500,"billingFrequency":"One Time","isMandatory":true,"remarks":"Local anaesthesia administration"},
                {"detailHeadType":"OT","itemCode":"OT-EYE-01","itemName":"Ophthalmic Micro-OT Charges & Operating Microscope","quantity":1,"unitRate":2500,"amount":2500,"billingFrequency":"One Time","isMandatory":true,"remarks":"Dedicated ophthalmic suite"},
                {"detailHeadType":"Consumables","itemCode":"CONS-IOL-01","itemName":"Foldable Hydrophobic Acrylic IOL & Viscoelastics","quantity":1,"unitRate":1500,"amount":1500,"billingFrequency":"Package Included","isMandatory":true,"remarks":"Premium lens & viscoelastic gel"},
                {"detailHeadType":"Bed","itemCode":"BED-DAY-01","itemName":"Day Care Eye Recovery Lounge (4 Hours)","quantity":1,"unitRate":500,"amount":500,"billingFrequency":"One Time","isMandatory":true,"remarks":"Day-care observation bed"}
            ]',
            @NewHospitalPackage_ID = @PkgId2 OUTPUT;
        PRINT 'Seeded Package 2: Cataract Surgery Package';
    END

    -- Package 3: Laparoscopic Cholecystectomy Package
    IF NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE Branch_ID = @DefaultBranchId AND Package_Code = 'PKG-SURG-01')
    BEGIN
        DECLARE @PkgId3 INT;
        EXEC dbo.usp_HospitalPackage_Create
            @CompanyId = 1,
            @Branch_ID = @DefaultBranchId,
            @Package_Code = 'PKG-SURG-01',
            @Package_Name = 'Laparoscopic Cholecystectomy (Gallbladder) Package (2 Days)',
            @Package_Type = 'Surgery',
            @ValidFrom = '2026-01-01',
            @ValidTo = '2026-12-31',
            @TotalPackageAmount = 48500.00,
            @Description = 'Minimally invasive laparoscopic gallbladder removal including 2-day twin-sharing stay, surgeon & anaesthetist fees, HD laparoscopy tower, and standard consumables.',
            @Status = 1,
            @CreatedBy = 1,
            @DetailsJson = '[
                {"detailHeadType":"Bed","itemCode":"BED-TWIN-01","itemName":"Twin-Sharing Surgical Inpatient Bed (2 Days)","quantity":2,"unitRate":2500,"amount":5000,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Surgical ward room"},
                {"detailHeadType":"Procedure","itemCode":"PROC-LAP-01","itemName":"Laparoscopic Cholecystectomy Procedure","quantity":1,"unitRate":18000,"amount":18000,"billingFrequency":"One Time","isMandatory":true,"remarks":"4-port laparoscopic dissection"},
                {"detailHeadType":"Doctor fee","itemCode":"DOC-SURG-01","itemName":"General / Laparoscopic Surgeon Fee","quantity":1,"unitRate":8000,"amount":8000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Surgeon operative & round charges"},
                {"detailHeadType":"Anaesthesia","itemCode":"ANA-GA-01","itemName":"General Anaesthesia with Endotracheal Intubation","quantity":1,"unitRate":4500,"amount":4500,"billingFrequency":"One Time","isMandatory":true,"remarks":"Consultant Anaesthesiologist fee"},
                {"detailHeadType":"OT","itemCode":"OT-MAJ-01","itemName":"Major Modular Operation Theatre Charges (2 Hours)","quantity":1,"unitRate":6000,"amount":6000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Laminar flow modular OT"},
                {"detailHeadType":"Equipment","itemCode":"EQ-LAP-01","itemName":"4K HD Laparoscopy Tower & Harmonic Scalpel","quantity":1,"unitRate":3500,"amount":3500,"billingFrequency":"Per Usage","isMandatory":true,"remarks":"Video laparoscope & energy device"},
                {"detailHeadType":"Nursing","itemCode":"NUR-SURG-01","itemName":"Post-Surgical Nursing & Wound Care (2 Days)","quantity":2,"unitRate":1000,"amount":2000,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Vital monitoring & IV therapy"},
                {"detailHeadType":"Consumables","itemCode":"CONS-LAP-01","itemName":"Titanium Clips, Trocars & Laparoscopic Disposables","quantity":1,"unitRate":1500,"amount":1500,"billingFrequency":"Package Included","isMandatory":true,"remarks":"Laparoscopy consumables"}
            ]',
            @NewHospitalPackage_ID = @PkgId3 OUTPUT;
        PRINT 'Seeded Package 3: Laparoscopic Cholecystectomy Package';
    END

    -- Package 4: Executive Wellness Hospitalization Package
    IF NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE Branch_ID = @DefaultBranchId AND Package_Code = 'PKG-WELL-01')
    BEGIN
        DECLARE @PkgId4 INT;
        EXEC dbo.usp_HospitalPackage_Create
            @CompanyId = 1,
            @Branch_ID = @DefaultBranchId,
            @Package_Code = 'PKG-WELL-01',
            @Package_Name = 'Executive Wellness & Comprehensive Health Check Inpatient Package',
            @Package_Type = 'Wellness Hospitalization',
            @ValidFrom = '2026-01-01',
            @ValidTo = '2026-12-31',
            @TotalPackageAmount = 18500.00,
            @Description = '1-Day executive private suite stay with total body diagnostic screening, cardiology profile (Echo, TMT), imaging, comprehensive pathology, and multi-specialist consultations.',
            @Status = 1,
            @CreatedBy = 1,
            @DetailsJson = '[
                {"detailHeadType":"Room","itemCode":"ROOM-PVT-01","itemName":"Executive Private Suite (1 Day Stay)","quantity":1,"unitRate":4500,"amount":4500,"billingFrequency":"Per Day","isMandatory":true,"remarks":"Private air-conditioned room with TV & diet"},
                {"detailHeadType":"Hospital services","itemCode":"SRV-PATH-01","itemName":"Master Health Pathology Panel (65 Parameters)","quantity":1,"unitRate":3500,"amount":3500,"billingFrequency":"One Time","isMandatory":true,"remarks":"CBC, Lipid, LFT, KFT, HbA1c, Thyroid, Vit D/B12"},
                {"detailHeadType":"Hospital services","itemCode":"SRV-CARD-01","itemName":"2D Echocardiography & Treadmill Stress Test (TMT)","quantity":1,"unitRate":4000,"amount":4000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Non-invasive cardiac profiling"},
                {"detailHeadType":"Hospital services","itemCode":"SRV-RAD-01","itemName":"USG Whole Abdomen & Digital Chest X-Ray","quantity":1,"unitRate":2500,"amount":2500,"billingFrequency":"One Time","isMandatory":true,"remarks":"Radiological workup"},
                {"detailHeadType":"Doctor fee","itemCode":"DOC-CONS-01","itemName":"Physician, Cardiologist & Dietitian Consultations","quantity":1,"unitRate":3000,"amount":3000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Comprehensive report review & diet counselling"},
                {"detailHeadType":"Nursing","itemCode":"NUR-GEN-01","itemName":"Wellness Coordinator & Nursing Support","quantity":1,"unitRate":1000,"amount":1000,"billingFrequency":"One Time","isMandatory":true,"remarks":"Escorted investigations & sample collection"}
            ]',
            @NewHospitalPackage_ID = @PkgId4 OUTPUT;
        PRINT 'Seeded Package 4: Executive Wellness Hospitalization Package';
    END
END
GO
