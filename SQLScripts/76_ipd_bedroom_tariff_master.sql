-- ============================================================================
-- Script: 76_ipd_bedroom_tariff_master.sql
-- Description: Create BedRoomTariffMaster and BedRoomTariffHistory for IPD Module
-- ============================================================================

-- 1. Create BedRoomTariffMaster table
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'BedRoomTariffMaster'
)
BEGIN
    CREATE TABLE dbo.BedRoomTariffMaster (
        BedRateId           INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId           INT             NOT NULL CONSTRAINT DF_BedRoomTariffMaster_CompanyId DEFAULT(1),
        BranchId            INT             NOT NULL,
        WardId              INT             NOT NULL,
        RoomId              INT             NOT NULL,
        BedCategoryId       INT             NOT NULL,
        TariffCategoryId    INT             NOT NULL,
        EffectiveFrom       DATE            NOT NULL,
        EffectiveTo         DATE            NULL,
        RoomCharge          DECIMAL(18,2)   NOT NULL CONSTRAINT DF_BedRoomTariffMaster_RoomCharge DEFAULT(0.00),
        BedCharge           DECIMAL(18,2)   NOT NULL CONSTRAINT DF_BedRoomTariffMaster_BedCharge DEFAULT(0.00),
        NursingCharge       DECIMAL(18,2)   NOT NULL CONSTRAINT DF_BedRoomTariffMaster_NursingCharge DEFAULT(0.00),
        AttendantCharge     DECIMAL(18,2)   NOT NULL CONSTRAINT DF_BedRoomTariffMaster_AttendantCharge DEFAULT(0.00),
        IsolationCharge     DECIMAL(18,2)   NOT NULL CONSTRAINT DF_BedRoomTariffMaster_IsolationCharge DEFAULT(0.00),
        GstPercentage       DECIMAL(5,2)    NOT NULL CONSTRAINT DF_BedRoomTariffMaster_GstPercentage DEFAULT(0.00),
        IsActive            BIT             NOT NULL CONSTRAINT DF_BedRoomTariffMaster_IsActive DEFAULT(1),
        CreatedBy           INT             NULL,
        CreatedDate         DATETIME2       NOT NULL CONSTRAINT DF_BedRoomTariffMaster_CreatedDate DEFAULT(GETDATE()),
        ModifiedBy          INT             NULL,
        ModifiedDate        DATETIME2       NULL,
        CONSTRAINT FK_BedRoomTariffMaster_Company 
            FOREIGN KEY (CompanyId) REFERENCES dbo.CompanyMaster(CompanyId),
        CONSTRAINT FK_BedRoomTariffMaster_Branch 
            FOREIGN KEY (BranchId) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_BedRoomTariffMaster_Ward 
            FOREIGN KEY (WardId) REFERENCES dbo.WardMaster(WardId),
        CONSTRAINT FK_BedRoomTariffMaster_Room 
            FOREIGN KEY (RoomId) REFERENCES dbo.RoomMaster(RoomId),
        CONSTRAINT FK_BedRoomTariffMaster_BedCategory 
            FOREIGN KEY (BedCategoryId) REFERENCES dbo.BedCategoryMaster(BedCategoryId),
        CONSTRAINT FK_BedRoomTariffMaster_TariffCategory 
            FOREIGN KEY (TariffCategoryId) REFERENCES dbo.TariffCategoryMaster(TariffCategoryId),
        CONSTRAINT CHK_BedRoomTariff_EffectiveDates 
            CHECK (EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom),
        CONSTRAINT CHK_BedRoomTariff_NonNegativeRates 
            CHECK (RoomCharge >= 0 AND BedCharge >= 0 AND NursingCharge >= 0 AND AttendantCharge >= 0 AND IsolationCharge >= 0 AND GstPercentage >= 0)
    );

    CREATE INDEX IX_BedRoomTariff_Branch_Ward_Room ON dbo.BedRoomTariffMaster(BranchId, WardId, RoomId);
    CREATE INDEX IX_BedRoomTariff_BedCategory ON dbo.BedRoomTariffMaster(BedCategoryId);
    CREATE INDEX IX_BedRoomTariff_TariffCategory ON dbo.BedRoomTariffMaster(TariffCategoryId);
    CREATE INDEX IX_BedRoomTariff_Dates ON dbo.BedRoomTariffMaster(EffectiveFrom, EffectiveTo);

    PRINT 'BedRoomTariffMaster table created.';
END
ELSE
BEGIN
    PRINT 'BedRoomTariffMaster table already exists.';
END
GO

-- 2. Create BedRoomTariffHistory table
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_NAME = 'BedRoomTariffHistory'
)
BEGIN
    CREATE TABLE dbo.BedRoomTariffHistory (
        HistoryId           INT IDENTITY(1,1) PRIMARY KEY,
        BedRateId           INT             NOT NULL,
        CompanyId           INT             NOT NULL,
        BranchId            INT             NOT NULL,
        WardId              INT             NOT NULL,
        RoomId              INT             NOT NULL,
        BedCategoryId       INT             NOT NULL,
        TariffCategoryId    INT             NOT NULL,
        EffectiveFrom       DATE            NOT NULL,
        EffectiveTo         DATE            NULL,
        RoomCharge          DECIMAL(18,2)   NOT NULL,
        BedCharge           DECIMAL(18,2)   NOT NULL,
        NursingCharge       DECIMAL(18,2)   NOT NULL,
        AttendantCharge     DECIMAL(18,2)   NOT NULL,
        IsolationCharge     DECIMAL(18,2)   NOT NULL,
        GstPercentage       DECIMAL(5,2)    NOT NULL,
        IsActive            BIT             NOT NULL,
        ChangeAction        NVARCHAR(50)    NOT NULL, -- CREATED, UPDATED, REVISED, DEACTIVATED
        ChangeReason        NVARCHAR(500)   NULL,
        ChangedBy           INT             NULL,
        ChangedDate         DATETIME2       NOT NULL CONSTRAINT DF_BedRoomTariffHistory_ChangedDate DEFAULT(GETDATE()),
        CONSTRAINT FK_BedRoomTariffHistory_BedRate 
            FOREIGN KEY (BedRateId) REFERENCES dbo.BedRoomTariffMaster(BedRateId) ON DELETE CASCADE
    );

    CREATE INDEX IX_BedRoomTariffHistory_BedRateId ON dbo.BedRoomTariffHistory(BedRateId);
    CREATE INDEX IX_BedRoomTariffHistory_ChangedDate ON dbo.BedRoomTariffHistory(ChangedDate);

    PRINT 'BedRoomTariffHistory table created.';
END
ELSE
BEGIN
    PRINT 'BedRoomTariffHistory table already exists.';
END
GO

-- 3. Seed Sample Standard Rates
IF NOT EXISTS (SELECT 1 FROM dbo.BedRoomTariffMaster)
BEGIN
    DECLARE @WardGwA INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'GW001');
    DECLARE @WardIcu INT = (SELECT TOP 1 WardId FROM dbo.WardMaster WHERE WardCode = 'ICU01');
    IF @WardGwA IS NULL SET @WardGwA = (SELECT TOP 1 WardId FROM dbo.WardMaster ORDER BY WardId);
    IF @WardIcu IS NULL SET @WardIcu = @WardGwA;

    DECLARE @Room101A INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '101-A');
    DECLARE @Room102B INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '102-B');
    DECLARE @Room201Iso INT = (SELECT TOP 1 RoomId FROM dbo.RoomMaster WHERE RoomNumber = '201-ISO');
    IF @Room101A IS NULL SET @Room101A = (SELECT TOP 1 RoomId FROM dbo.RoomMaster ORDER BY RoomId);
    IF @Room102B IS NULL SET @Room102B = @Room101A;
    IF @Room201Iso IS NULL SET @Room201Iso = @Room101A;

    DECLARE @CatGen INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryCode = 'GEN');
    DECLARE @CatSemi INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryCode = 'SPRV');
    DECLARE @CatIcu INT = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster WHERE CategoryCode = 'ICU');
    IF @CatGen IS NULL SET @CatGen = (SELECT TOP 1 BedCategoryId FROM dbo.BedCategoryMaster ORDER BY BedCategoryId);
    IF @CatSemi IS NULL SET @CatSemi = @CatGen;
    IF @CatIcu IS NULL SET @CatIcu = @CatGen;

    DECLARE @TariffGen INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE Code = 'GEN');
    DECLARE @TariffCorp INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE Code = 'CORP');
    DECLARE @TariffIns INT = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster WHERE Code = 'INS');
    IF @TariffGen IS NULL SET @TariffGen = (SELECT TOP 1 TariffCategoryId FROM dbo.TariffCategoryMaster ORDER BY TariffCategoryId);
    IF @TariffCorp IS NULL SET @TariffCorp = @TariffGen;
    IF @TariffIns IS NULL SET @TariffIns = @TariffGen;

    -- General Ward Rate (General Cash Tariff)
    INSERT INTO dbo.BedRoomTariffMaster (
        CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, CreatedDate
    ) VALUES (
        1, 1, @WardGwA, @Room101A, @CatGen, @TariffGen,
        '2026-01-01', NULL, 1200.00, 800.00, 500.00, 300.00, 0.00, 5.00, 1, GETDATE()
    );
    DECLARE @Rate1 INT = SCOPE_IDENTITY();
    INSERT INTO dbo.BedRoomTariffHistory (
        BedRateId, CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, ChangeAction, ChangeReason, ChangedDate
    ) VALUES (
        @Rate1, 1, 1, @WardGwA, @Room101A, @CatGen, @TariffGen,
        '2026-01-01', NULL, 1200.00, 800.00, 500.00, 300.00, 0.00, 5.00, 1, 'CREATED', 'Initial annual standard rack rate setup', GETDATE()
    );

    -- Semi-Private Room Rate (Corporate Tariff)
    INSERT INTO dbo.BedRoomTariffMaster (
        CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, CreatedDate
    ) VALUES (
        1, 1, @WardGwA, @Room102B, @CatSemi, @TariffCorp,
        '2026-01-01', NULL, 2500.00, 1500.00, 800.00, 500.00, 0.00, 12.00, 1, GETDATE()
    );
    DECLARE @Rate2 INT = SCOPE_IDENTITY();
    INSERT INTO dbo.BedRoomTariffHistory (
        BedRateId, CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, ChangeAction, ChangeReason, ChangedDate
    ) VALUES (
        @Rate2, 1, 1, @WardGwA, @Room102B, @CatSemi, @TariffCorp,
        '2026-01-01', NULL, 2500.00, 1500.00, 800.00, 500.00, 0.00, 12.00, 1, 'CREATED', 'Corporate tied-up rate schedule', GETDATE()
    );

    -- ICU Isolation Room Rate (Insurance / TPA Tariff)
    INSERT INTO dbo.BedRoomTariffMaster (
        CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, CreatedDate
    ) VALUES (
        1, 1, @WardIcu, @Room201Iso, @CatIcu, @TariffIns,
        '2026-01-01', NULL, 6000.00, 4000.00, 2500.00, 1000.00, 2000.00, 18.00, 1, GETDATE()
    );
    DECLARE @Rate3 INT = SCOPE_IDENTITY();
    INSERT INTO dbo.BedRoomTariffHistory (
        BedRateId, CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
        EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge, AttendantCharge, IsolationCharge, GstPercentage, IsActive, ChangeAction, ChangeReason, ChangedDate
    ) VALUES (
        @Rate3, 1, 1, @WardIcu, @Room201Iso, @CatIcu, @TariffIns,
        '2026-01-01', NULL, 6000.00, 4000.00, 2500.00, 1000.00, 2000.00, 18.00, 1, 'CREATED', 'Insurance TPA critical care isolation schedule', GETDATE()
    );

    PRINT 'BedRoomTariffMaster seeded successfully with history logs.';
END
GO
