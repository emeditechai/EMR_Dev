-- ============================================================================================================
-- 2343  Pharmacy module - Phase 1: masters (plan "Pharmacy Module - End-to-End Implementation Plan", 2026-10-28)
--   * One pharmacy per branch: licence / GSTIN / pharmacist columns on HospitalSettings (Hospital Information)
--     and the pharmacy parameters (MED tab). No store master.
--   * Company-wise masters: Manufacturer, Generic, Category (+ sub-category), Dosage Form, Unit, HSN & GST (with
--     rate history), Supplier, Item (+ branch settings), Price Rule, Discount Scheme, Customer, Reason;
--     branch-wise Number Series; Drug Schedule is statutory and shared (Drugs & Cosmetics Rules 1945 / NDPS Act).
--   * usp_Pharmacy_EnsureMasters seeds standard sample data the first time a company opens a pharmacy master.
--   * Pages under Master > Pharmacy Master (VIEW + EDIT controls). The old placeholder "Medicine Master"
--     page (no controller) is hidden.
-- Additive and re-runnable: no existing table or procedure is changed apart from new HospitalSettings columns.
-- ============================================================================================================
SET NOCOUNT ON;
GO

-- ── Hospital Settings: pharmacy identity (Hospital Information) and parameters (MED tab) ───────────────────
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD
        PharmacyEnabled                 BIT           NOT NULL CONSTRAINT DF_HS_PharmacyEnabled DEFAULT (0),
        PharmacyName                    NVARCHAR(150) NULL,
        PharmacyDrugLicence20B          NVARCHAR(50)  NULL,
        PharmacyDrugLicence20BValidTo   DATE          NULL,
        PharmacyDrugLicence21B          NVARCHAR(50)  NULL,
        PharmacyDrugLicence21BValidTo   DATE          NULL,
        PharmacyGstin                   VARCHAR(15)   NULL,          -- empty = hospital GSTIN
        PharmacistName                  NVARCHAR(100) NULL,
        PharmacistRegNo                 NVARCHAR(50)  NULL,
        PharmacyNdpsLicenceNo           NVARCHAR(50)  NULL,
        PharmacyContactNo               NVARCHAR(30)  NULL,
        PharmacyAllowNegativeStock      BIT           NOT NULL CONSTRAINT DF_HS_PhNegStock DEFAULT (0),
        PharmacyMinShelfLifeSaleDays    INT           NOT NULL CONSTRAINT DF_HS_PhShelfSale DEFAULT (30),
        PharmacyMinShelfLifeIpdDays     INT           NOT NULL CONSTRAINT DF_HS_PhShelfIpd DEFAULT (0),
        PharmacyMinShelfLifeGrnDays     INT           NOT NULL CONSTRAINT DF_HS_PhShelfGrn DEFAULT (90),
        PharmacyNearExpiryAlertDays     INT           NOT NULL CONSTRAINT DF_HS_PhNearExp DEFAULT (90),
        PharmacySaleReturnDays          INT           NOT NULL CONSTRAINT DF_HS_PhRetDays DEFAULT (7),
        PharmacyLooseReturnAllowed      BIT           NOT NULL CONSTRAINT DF_HS_PhLooseRet DEFAULT (0),
        PharmacyMaxManualDiscountPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhMaxDisc DEFAULT (10),
        PharmacyIpdGstExempt            BIT           NOT NULL CONSTRAINT DF_HS_PhIpdGst DEFAULT (1),
        PharmacyBlockDischargeOnPendingIndent BIT     NOT NULL CONSTRAINT DF_HS_PhBlockDis DEFAULT (1),
        PharmacyTtoBillingMode          VARCHAR(10)   NOT NULL CONSTRAINT DF_HS_PhTto DEFAULT ('IPD'),   -- IPD | SALE
        PharmacyRoundOffBill            BIT           NOT NULL CONSTRAINT DF_HS_PhRound DEFAULT (1),
        PharmacyBillPrintFormat         VARCHAR(10)   NOT NULL CONSTRAINT DF_HS_PhPrint DEFAULT ('A4'),  -- A4 | A5 | 80MM
        PharmacyBillNotificationRequired BIT          NOT NULL CONSTRAINT DF_HS_PhNotify DEFAULT (0);
GO

-- ── statutory drug schedules (shared, fixed) ────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhDrugSchedule') IS NULL
CREATE TABLE dbo.PhDrugSchedule (
    ScheduleCode     VARCHAR(10)   NOT NULL PRIMARY KEY,
    ScheduleName     NVARCHAR(100) NOT NULL,
    RxRequired       BIT NOT NULL,          -- sale needs a doctor's prescription
    RegisterRequired BIT NOT NULL,          -- entry in the H1 / X / NDPS register
    IsNarcotic       BIT NOT NULL,          -- NDPS-licensed pharmacy only, double sign-off
    LabelWarning     NVARCHAR(300) NULL,
    SortOrder        INT NOT NULL
);
GO
MERGE dbo.PhDrugSchedule AS t
USING (VALUES
 ('OTC',  N'Over the counter (non-scheduled)', 0, 0, 0, NULL, 10),
 ('G',    N'Schedule G', 0, 0, 0, N'Caution: It is dangerous to take this preparation except under medical supervision.', 20),
 ('H',    N'Schedule H', 1, 0, 0, N'Schedule H drug - Warning: To be sold by retail on the prescription of a Registered Medical Practitioner only.', 30),
 ('H1',   N'Schedule H1', 1, 1, 0, N'Schedule H1 drug - Warning: Not to be sold by retail without the prescription of a Registered Medical Practitioner. Dangerous to take except in accordance with medical advice.', 40),
 ('X',    N'Schedule X', 1, 1, 1, N'Schedule X drug - Warning: To be sold by retail on the prescription of a Registered Medical Practitioner only. Prescription copy to be retained.', 50),
 ('NDPS', N'Narcotic / Psychotropic (NDPS Act)', 1, 1, 1, N'NDPS drug: dispense only against prescription; record in the NDPS register.', 60)
) AS s (ScheduleCode, ScheduleName, RxRequired, RegisterRequired, IsNarcotic, LabelWarning, SortOrder)
ON t.ScheduleCode = s.ScheduleCode
WHEN MATCHED THEN UPDATE SET ScheduleName = s.ScheduleName, RxRequired = s.RxRequired, RegisterRequired = s.RegisterRequired,
     IsNarcotic = s.IsNarcotic, LabelWarning = s.LabelWarning, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT VALUES (s.ScheduleCode, s.ScheduleName, s.RxRequired, s.RegisterRequired, s.IsNarcotic, s.LabelWarning, s.SortOrder);
GO

-- ── company-wise masters ───────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhManufacturer') IS NULL
CREATE TABLE dbo.PhManufacturer (
    ManufacturerId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId        INT NOT NULL,
    ManufacturerName NVARCHAR(150) NOT NULL,
    ShortCode        NVARCHAR(20) NULL,
    Address          NVARCHAR(300) NULL,
    IsActive         BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhManufacturer UNIQUE (CompanyId, ManufacturerName)
);
GO
IF OBJECT_ID('dbo.PhGeneric') IS NULL
CREATE TABLE dbo.PhGeneric (
    GenericId        INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId        INT NOT NULL,
    GenericName      NVARCHAR(250) NOT NULL,       -- composition, e.g. "Amoxicillin 500 mg + Clavulanic Acid 125 mg"
    TherapeuticClass NVARCHAR(100) NULL,
    IsActive         BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhGeneric UNIQUE (CompanyId, GenericName)
);
GO
IF OBJECT_ID('dbo.PhCategory') IS NULL
CREATE TABLE dbo.PhCategory (
    CategoryId       INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId        INT NOT NULL,
    CategoryName     NVARCHAR(100) NOT NULL,
    ParentCategoryId INT NULL REFERENCES dbo.PhCategory (CategoryId),   -- NULL = main category
    SortOrder        INT NOT NULL DEFAULT 0,
    IsActive         BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhCategory UNIQUE (CompanyId, CategoryName)
);
GO
IF OBJECT_ID('dbo.PhDosageForm') IS NULL
CREATE TABLE dbo.PhDosageForm (
    DosageFormId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    DosageFormName NVARCHAR(60) NOT NULL,
    ShortName      NVARCHAR(10) NULL,             -- printed before the brand: TAB, CAP, SYP, INJ ...
    SortOrder      INT NOT NULL DEFAULT 0,
    IsActive       BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhDosageForm UNIQUE (CompanyId, DosageFormName)
);
GO
IF OBJECT_ID('dbo.PhUom') IS NULL
CREATE TABLE dbo.PhUom (
    UomId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId INT NOT NULL,
    UomCode   NVARCHAR(10) NOT NULL,
    UomName   NVARCHAR(50) NOT NULL,
    SortOrder INT NOT NULL DEFAULT 0,
    IsActive  BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhUom UNIQUE (CompanyId, UomCode)
);
GO
IF OBJECT_ID('dbo.PhHsn') IS NULL
CREATE TABLE dbo.PhHsn (
    HsnId          INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    HsnCode        VARCHAR(10) NOT NULL,
    Description    NVARCHAR(200) NOT NULL,
    GstPercent     DECIMAL(5,2) NOT NULL,          -- current rate (CGST = SGST = half)
    CessPercent    DECIMAL(5,2) NOT NULL DEFAULT 0,
    EffectiveFrom  DATE NOT NULL,                  -- of the current rate
    IsActive       BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhHsn UNIQUE (CompanyId, HsnCode)
);
GO
IF OBJECT_ID('dbo.PhHsnRateHistory') IS NULL
CREATE TABLE dbo.PhHsnRateHistory (
    HistoryId     INT IDENTITY(1,1) PRIMARY KEY,
    HsnId         INT NOT NULL REFERENCES dbo.PhHsn (HsnId),
    GstPercent    DECIMAL(5,2) NOT NULL,
    CessPercent   DECIMAL(5,2) NOT NULL,
    EffectiveFrom DATE NOT NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.PhSupplier') IS NULL
CREATE TABLE dbo.PhSupplier (
    SupplierId         INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId          INT NOT NULL,
    SupplierCode       NVARCHAR(20) NOT NULL,
    SupplierName       NVARCHAR(150) NOT NULL,
    ContactPerson      NVARCHAR(100) NULL,
    Phone              NVARCHAR(30) NULL,
    Email              NVARCHAR(150) NULL,
    Address            NVARCHAR(300) NULL,
    City               NVARCHAR(80) NULL,
    StateId            INT NULL,                  -- decides CGST + SGST or IGST on purchase
    Pincode            NVARCHAR(10) NULL,
    Gstin              VARCHAR(15) NULL,
    Pan                VARCHAR(10) NULL,
    DrugLicenceNo      NVARCHAR(100) NULL,
    DrugLicenceValidTo DATE NULL,
    CreditDays         INT NOT NULL DEFAULT 30,
    BankName           NVARCHAR(100) NULL,
    BankAccountNo      NVARCHAR(30) NULL,
    BankIfsc           NVARCHAR(15) NULL,
    Remarks            NVARCHAR(300) NULL,
    IsActive           BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhSupplier_Code UNIQUE (CompanyId, SupplierCode),
    CONSTRAINT UQ_PhSupplier_Name UNIQUE (CompanyId, SupplierName)
);
GO
IF OBJECT_ID('dbo.PhItem') IS NULL
CREATE TABLE dbo.PhItem (
    ItemId             INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId          INT NOT NULL,
    ItemCode           NVARCHAR(20) NOT NULL,
    ItemName           NVARCHAR(200) NOT NULL,     -- brand as on the pack, e.g. "Dolo 650"
    GenericId          INT NULL REFERENCES dbo.PhGeneric (GenericId),
    ManufacturerId     INT NULL REFERENCES dbo.PhManufacturer (ManufacturerId),
    CategoryId         INT NOT NULL REFERENCES dbo.PhCategory (CategoryId),
    DosageFormId       INT NULL REFERENCES dbo.PhDosageForm (DosageFormId),
    Strength           NVARCHAR(60) NULL,
    PackSize           NVARCHAR(60) NULL,          -- as printed: "Strip of 15 tablets", "100 ml bottle"
    ScheduleCode       VARCHAR(10) NOT NULL REFERENCES dbo.PhDrugSchedule (ScheduleCode),
    HsnId              INT NOT NULL REFERENCES dbo.PhHsn (HsnId),
    PurchaseUomId      INT NOT NULL REFERENCES dbo.PhUom (UomId),   -- the pack bought and priced (MRP is per pack)
    SaleUomId          INT NOT NULL REFERENCES dbo.PhUom (UomId),   -- the smallest unit stock is kept in
    ConversionQty      INT NOT NULL DEFAULT 1,     -- sale units in one purchase unit (strip of 15 = 15)
    AllowLooseSale     BIT NOT NULL DEFAULT 1,
    IsColdChain        BIT NOT NULL DEFAULT 0,
    IsHighAlert        BIT NOT NULL DEFAULT 0,
    IsLasa             BIT NOT NULL DEFAULT 0,     -- look-alike / sound-alike
    IsReturnable       BIT NOT NULL DEFAULT 1,
    IsDiscountAllowed  BIT NOT NULL DEFAULT 1,
    Barcode            NVARCHAR(50) NULL,
    ReorderLevel       DECIMAL(12,2) NOT NULL DEFAULT 0,   -- in purchase units; default for every branch
    MinQty             DECIMAL(12,2) NOT NULL DEFAULT 0,
    MaxQty             DECIMAL(12,2) NOT NULL DEFAULT 0,
    LeadDays           INT NOT NULL DEFAULT 2,
    Remarks            NVARCHAR(300) NULL,
    IsActive           BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhItem_Code UNIQUE (CompanyId, ItemCode),
    CONSTRAINT CK_PhItem_Conversion CHECK (ConversionQty >= 1)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhItem_Name')
    CREATE INDEX IX_PhItem_Name ON dbo.PhItem (CompanyId, ItemName) INCLUDE (GenericId, IsActive);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PhItem_Barcode')
    CREATE UNIQUE INDEX UX_PhItem_Barcode ON dbo.PhItem (CompanyId, Barcode) WHERE Barcode IS NOT NULL;
GO
IF OBJECT_ID('dbo.PhItemBranch') IS NULL
CREATE TABLE dbo.PhItemBranch (
    ItemId       INT NOT NULL REFERENCES dbo.PhItem (ItemId),
    BranchId     INT NOT NULL,
    RackNo       NVARCHAR(30) NULL,
    ReorderLevel DECIMAL(12,2) NULL,               -- NULL = item default
    MinQty       DECIMAL(12,2) NULL,
    MaxQty       DECIMAL(12,2) NULL,
    IsStocked    BIT NOT NULL DEFAULT 1,           -- No = not kept at this branch's pharmacy
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT PK_PhItemBranch PRIMARY KEY (ItemId, BranchId)
);
GO
IF OBJECT_ID('dbo.PhPriceRule') IS NULL
CREATE TABLE dbo.PhPriceRule (
    PriceRuleId  INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId    INT NOT NULL,
    RuleName     NVARCHAR(100) NOT NULL,
    PatientType  VARCHAR(20) NOT NULL,             -- WALKIN | IPD_CASH | IPD_INSURANCE | IPD_CORPORATE | IPD_SCHEME | STAFF
    CategoryId   INT NULL REFERENCES dbo.PhCategory (CategoryId),   -- NULL = all categories
    PriceBasis   VARCHAR(10) NOT NULL,             -- MRP | MRP_LESS | COST_PLUS  (result never above MRP)
    RatePercent  DECIMAL(6,2) NOT NULL DEFAULT 0,
    Priority     INT NOT NULL DEFAULT 100,         -- lower wins when several rules match
    IsActive     BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhPriceRule UNIQUE (CompanyId, RuleName)
);
GO
IF OBJECT_ID('dbo.PhDiscountScheme') IS NULL
CREATE TABLE dbo.PhDiscountScheme (
    SchemeId      INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    SchemeName    NVARCHAR(100) NOT NULL,
    DiscountType  VARCHAR(10) NOT NULL,            -- PERCENT | FLAT
    DiscountValue DECIMAL(10,2) NOT NULL,
    AppliesTo     VARCHAR(20) NOT NULL DEFAULT 'ALL',   -- ALL | CATEGORY | CUSTOMER_TYPE
    CategoryId    INT NULL REFERENCES dbo.PhCategory (CategoryId),
    CustomerType  VARCHAR(20) NULL,
    MinBillAmount DECIMAL(12,2) NOT NULL DEFAULT 0,
    ValidFrom     DATE NULL,
    ValidTo       DATE NULL,
    IsActive      BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhDiscountScheme UNIQUE (CompanyId, SchemeName)
);
GO
IF OBJECT_ID('dbo.PhCustomer') IS NULL
CREATE TABLE dbo.PhCustomer (
    CustomerId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    CustomerName   NVARCHAR(150) NOT NULL,
    Mobile         NVARCHAR(15) NOT NULL,
    Email          NVARCHAR(150) NULL,
    Address        NVARCHAR(300) NULL,
    CustomerType   VARCHAR(20) NOT NULL DEFAULT 'REGULAR',   -- REGULAR | STAFF | CORPORATE | DOCTOR
    Gstin          VARCHAR(15) NULL,
    CreditAllowed  BIT NOT NULL DEFAULT 0,
    CreditLimit    DECIMAL(12,2) NOT NULL DEFAULT 0,
    SchemeId       INT NULL REFERENCES dbo.PhDiscountScheme (SchemeId),
    IsActive       BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhCustomer_Mobile UNIQUE (CompanyId, Mobile)
);
GO
IF OBJECT_ID('dbo.PhReason') IS NULL
CREATE TABLE dbo.PhReason (
    ReasonId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId  INT NOT NULL,
    ReasonType VARCHAR(20) NOT NULL,               -- SALE_RETURN | IPD_RETURN | PURCHASE_RETURN | ADJUSTMENT | CANCEL
    ReasonName NVARCHAR(150) NOT NULL,
    SortOrder  INT NOT NULL DEFAULT 0,
    IsActive   BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhReason UNIQUE (CompanyId, ReasonType, ReasonName)
);
GO
IF OBJECT_ID('dbo.PhNumberSeries') IS NULL
CREATE TABLE dbo.PhNumberSeries (
    SeriesId    INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId   INT NOT NULL,
    BranchId    INT NOT NULL,
    DocType     VARCHAR(10) NOT NULL,              -- SALE, SRET, IPDI, IPDR, INDT, PO, GRN, PRET, TRF, ADJ
    DocName     NVARCHAR(60) NOT NULL,
    Prefix      VARCHAR(10) NOT NULL,
    Padding     INT NOT NULL DEFAULT 6,
    ResetYearly BIT NOT NULL DEFAULT 1,            -- restart each financial year (April)
    IsActive    BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhNumberSeries UNIQUE (BranchId, DocType)
);
GO
IF OBJECT_ID('dbo.PhNumberCounter') IS NULL
CREATE TABLE dbo.PhNumberCounter (                 -- last number used, per series and financial year
    SeriesId  INT NOT NULL REFERENCES dbo.PhNumberSeries (SeriesId),
    FinYear   VARCHAR(4) NOT NULL,                 -- 2627 = Apr 2026 - Mar 2027 ('0000' when not reset yearly)
    LastNo    INT NOT NULL DEFAULT 0,
    CONSTRAINT PK_PhNumberCounter PRIMARY KEY (SeriesId, FinYear)
);
GO

-- ── seed standard sample data for a company (and number series for a branch) ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Pharmacy_EnsureMasters @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhUom WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhUom (CompanyId, UomCode, UomName, SortOrder)
        SELECT @CompanyId, c, n, o FROM (VALUES ('TAB',N'Tablet',10),('CAP',N'Capsule',20),('STRIP',N'Strip',30),('BOX',N'Box',40),
            ('BTL',N'Bottle',50),('VIAL',N'Vial',60),('AMP',N'Ampoule',70),('TUBE',N'Tube',80),('SACHET',N'Sachet',90),
            ('NOS',N'Numbers (each)',100),('PAIR',N'Pair',110),('PKT',N'Packet',120),('ROLL',N'Roll',130),('ML',N'Millilitre',140)) v (c, n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhDosageForm WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhDosageForm (CompanyId, DosageFormName, ShortName, SortOrder)
        SELECT @CompanyId, n, s, o FROM (VALUES (N'Tablet','TAB',10),(N'Capsule','CAP',20),(N'Syrup','SYP',30),(N'Suspension','SUSP',40),
            (N'Injection','INJ',50),(N'Infusion / IV Fluid','INF',60),(N'Ointment','OINT',70),(N'Cream','CRM',80),(N'Gel','GEL',90),
            (N'Drops','DRP',100),(N'Inhaler','INH',110),(N'Respules / Nebuliser','RESP',120),(N'Powder / Sachet','PWD',130),
            (N'Lotion','LOT',140),(N'Spray','SPR',150),(N'Suppository','SUPP',160),(N'Surgical / Device','SURG',170)) v (n, s, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhCategory WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhCategory (CompanyId, CategoryName, SortOrder)
        SELECT @CompanyId, n, o FROM (VALUES (N'Drugs / Medicines',10),(N'Surgical',20),(N'Consumables',30),(N'Implants',40),
            (N'OTC / FMCG',50),(N'Nutrition & Supplements',60),(N'Cosmetics & Personal Care',70),(N'Medical Devices',80)) v (n, o);
        DECLARE @drug INT = (SELECT CategoryId FROM dbo.PhCategory WHERE CompanyId = @CompanyId AND CategoryName = N'Drugs / Medicines');
        INSERT dbo.PhCategory (CompanyId, CategoryName, ParentCategoryId, SortOrder)
        SELECT @CompanyId, n, @drug, o FROM (VALUES (N'Antibiotics',11),(N'Analgesics & Antipyretics',12),(N'Antacids & PPIs',13),
            (N'Antidiabetics',14),(N'Insulins',15),(N'Cardiac & Antihypertensives',16),(N'Respiratory',17),(N'IV Fluids',18),
            (N'Vitamins & Minerals',19),(N'Antiemetics',20)) v (n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhHsn WHERE CompanyId = @CompanyId)
    BEGIN
        -- GST rates as revised from 22-Sep-2025 (most medicines and medical goods 12% -> 5%). Check with your CA.
        INSERT dbo.PhHsn (CompanyId, HsnCode, Description, GstPercent, EffectiveFrom)
        SELECT @CompanyId, h, d, g, '2025-09-22' FROM (VALUES
            ('3004', N'Medicaments in measured doses (tablets, capsules, syrups, injections)', 5.00),
            ('3003', N'Medicaments not in measured doses', 5.00),
            ('3002', N'Vaccines, sera, blood fractions, insulin-type biologicals', 5.00),
            ('3005', N'Wadding, gauze, bandages, dressings', 5.00),
            ('3006', N'Pharmaceutical goods (sutures, blood-grouping reagents, ostomy)', 5.00),
            ('9018', N'Medical / surgical instruments (syringes, needles, catheters, cannulae)', 5.00),
            ('4015', N'Surgical / examination gloves of rubber', 5.00),
            ('9021', N'Orthopaedic appliances and implants', 5.00),
            ('3304', N'Beauty / skin-care preparations', 18.00)) v (h, d, g);
        INSERT dbo.PhHsnRateHistory (HsnId, GstPercent, CessPercent, EffectiveFrom)
        SELECT HsnId, GstPercent, CessPercent, EffectiveFrom FROM dbo.PhHsn WHERE CompanyId = @CompanyId;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhManufacturer WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhManufacturer (CompanyId, ManufacturerName, ShortCode)
        SELECT @CompanyId, n, s FROM (VALUES (N'Micro Labs Ltd','MICRO'),(N'Alkem Laboratories Ltd','ALKEM'),(N'Alembic Pharmaceuticals Ltd','ALEMB'),
            (N'GlaxoSmithKline Pharmaceuticals Ltd','GSK'),(N'USV Pvt Ltd','USV'),(N'Glenmark Pharmaceuticals Ltd','GLEN'),
            (N'Zydus Lifesciences Ltd','ZYDUS'),(N'Cipla Ltd','CIPLA'),(N'Aristo Pharmaceuticals Pvt Ltd','ARIS'),
            (N'Novo Nordisk India Pvt Ltd','NOVO'),(N'Baxter India Pvt Ltd','BAXT'),(N'Becton Dickinson India Pvt Ltd','BD'),
            (N'Torrent Pharmaceuticals Ltd','TORR'),(N'Franco-Indian Pharmaceuticals Pvt Ltd','FDC'),(N'Sun Pharmaceutical Industries Ltd','SUN'),
            (N'Mankind Pharma Ltd','MANK'),(N'Dr. Reddy''s Laboratories Ltd','DRL'),(N'Lupin Ltd','LUPIN')) v (n, s);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhGeneric WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhGeneric (CompanyId, GenericName, TherapeuticClass)
        SELECT @CompanyId, n, c FROM (VALUES (N'Paracetamol 650 mg',N'Analgesic / Antipyretic'),(N'Pantoprazole 40 mg',N'Proton pump inhibitor'),
            (N'Azithromycin 500 mg',N'Macrolide antibiotic'),(N'Amoxicillin 500 mg + Clavulanic Acid 125 mg',N'Penicillin antibiotic'),
            (N'Cefixime 200 mg',N'Cephalosporin antibiotic'),(N'Metformin 500 mg',N'Antidiabetic (biguanide)'),
            (N'Telmisartan 40 mg',N'Antihypertensive (ARB)'),(N'Aspirin 75 mg',N'Antiplatelet'),(N'Atorvastatin 10 mg',N'Statin'),
            (N'Montelukast 10 mg + Levocetirizine 5 mg',N'Anti-allergic'),(N'Ondansetron 4 mg',N'Antiemetic'),
            (N'Ambroxol + Levosalbutamol + Guaifenesin',N'Cough expectorant'),(N'Ceftriaxone 1 g',N'Cephalosporin antibiotic'),
            (N'Pantoprazole 40 mg (injection)',N'Proton pump inhibitor'),(N'Sodium Chloride 0.9%',N'IV fluid'),
            (N'Human Insulin (regular) 40 IU/ml',N'Insulin'),(N'Calcium Carbonate 1250 mg + Vitamin D3 250 IU',N'Calcium supplement'),
            (N'Oral Rehydration Salts (WHO)',N'Electrolyte replenisher')) v (n, c);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhReason WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhReason (CompanyId, ReasonType, ReasonName, SortOrder)
        SELECT @CompanyId, t, n, o FROM (VALUES
            ('SALE_RETURN',N'Doctor changed prescription',10),('SALE_RETURN',N'Excess quantity bought',20),('SALE_RETURN',N'Wrong item given',30),
            ('IPD_RETURN',N'Medicine discontinued',10),('IPD_RETURN',N'Patient discharged',20),('IPD_RETURN',N'Excess issued',30),('IPD_RETURN',N'Patient expired',40),
            ('PURCHASE_RETURN',N'Expired / near expiry',10),('PURCHASE_RETURN',N'Damaged in transit',20),('PURCHASE_RETURN',N'Wrong item supplied',30),('PURCHASE_RETURN',N'Rate difference',40),
            ('ADJUSTMENT',N'Breakage / damage',10),('ADJUSTMENT',N'Expired - write off',20),('ADJUSTMENT',N'Physical count difference',30),('ADJUSTMENT',N'Theft / pilferage',40),
            ('CANCEL',N'Wrong patient / customer',10),('CANCEL',N'Billing error',20),('CANCEL',N'Customer refused',30)) v (t, n, o);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhPriceRule WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhPriceRule (CompanyId, RuleName, PatientType, PriceBasis, RatePercent, Priority)
        VALUES (@CompanyId, N'Walk-in at MRP', 'WALKIN', 'MRP', 0, 100),
               (@CompanyId, N'IPD cash at MRP', 'IPD_CASH', 'MRP', 0, 100),
               (@CompanyId, N'IPD insurance at MRP', 'IPD_INSURANCE', 'MRP', 0, 100),
               (@CompanyId, N'IPD corporate at MRP', 'IPD_CORPORATE', 'MRP', 0, 100),
               (@CompanyId, N'Staff at MRP less 10%', 'STAFF', 'MRP_LESS', 10, 100);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhDiscountScheme WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhDiscountScheme (CompanyId, SchemeName, DiscountType, DiscountValue, AppliesTo, CustomerType, MinBillAmount)
        VALUES (@CompanyId, N'Senior citizen 5%', 'PERCENT', 5, 'ALL', NULL, 0),
               (@CompanyId, N'Staff 10%', 'PERCENT', 10, 'CUSTOMER_TYPE', 'STAFF', 0),
               (@CompanyId, N'Bill above 2000 - 3%', 'PERCENT', 3, 'ALL', NULL, 2000);
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PhItem WHERE CompanyId = @CompanyId)
    BEGIN
        INSERT dbo.PhItem (CompanyId, ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId,
                           PurchaseUomId, SaleUomId, ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, ReorderLevel, MinQty, MaxQty)
        SELECT @CompanyId, 'PH' + RIGHT('00000' + CAST(v.n AS VARCHAR(6)), 5), v.item,
               g.GenericId, m.ManufacturerId, c.CategoryId, f.DosageFormId, v.strength, v.pack, v.sch, h.HsnId, pu.UomId, su.UomId, v.conv, v.loose, v.cold, v.alert,
               v.reorder, v.reorder / 2, v.reorder * 4
        FROM (VALUES
            (1, N'Dolo 650', N'Paracetamol 650 mg', N'Micro Labs Ltd', N'Analgesics & Antipyretics', N'Tablet', N'650 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 20),
            (2, N'Pan 40', N'Pantoprazole 40 mg', N'Alkem Laboratories Ltd', N'Antacids & PPIs', N'Tablet', N'40 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 20),
            (3, N'Azithral 500', N'Azithromycin 500 mg', N'Alembic Pharmaceuticals Ltd', N'Antibiotics', N'Tablet', N'500 mg', N'Strip of 5 tablets', 'H1', '3004', 'STRIP', 'TAB', 5, 1, 0, 0, 10),
            (4, N'Augmentin 625 Duo', N'Amoxicillin 500 mg + Clavulanic Acid 125 mg', N'GlaxoSmithKline Pharmaceuticals Ltd', N'Antibiotics', N'Tablet', N'625 mg', N'Strip of 10 tablets', 'H1', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (5, N'Taxim-O 200', N'Cefixime 200 mg', N'Alkem Laboratories Ltd', N'Antibiotics', N'Tablet', N'200 mg', N'Strip of 10 tablets', 'H1', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (6, N'Glycomet 500', N'Metformin 500 mg', N'USV Pvt Ltd', N'Antidiabetics', N'Tablet', N'500 mg', N'Strip of 10 tablets', 'H', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 20),
            (7, N'Telma 40', N'Telmisartan 40 mg', N'Glenmark Pharmaceuticals Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'40 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 15),
            (8, N'Ecosprin 75', N'Aspirin 75 mg', N'USV Pvt Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'75 mg', N'Strip of 14 tablets', 'H', '3004', 'STRIP', 'TAB', 14, 1, 0, 0, 15),
            (9, N'Atorva 10', N'Atorvastatin 10 mg', N'Zydus Lifesciences Ltd', N'Cardiac & Antihypertensives', N'Tablet', N'10 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 15),
            (10, N'Montair LC', N'Montelukast 10 mg + Levocetirizine 5 mg', N'Cipla Ltd', N'Respiratory', N'Tablet', N'10 mg / 5 mg', N'Strip of 15 tablets', 'H', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 10),
            (11, N'Emeset 4', N'Ondansetron 4 mg', N'Cipla Ltd', N'Antiemetics', N'Tablet', N'4 mg', N'Strip of 10 tablets', 'H', '3004', 'STRIP', 'TAB', 10, 1, 0, 0, 10),
            (12, N'Ascoril LS Syrup', N'Ambroxol + Levosalbutamol + Guaifenesin', N'Glenmark Pharmaceuticals Ltd', N'Respiratory', N'Syrup', N'100 ml', N'100 ml bottle', 'H', '3004', 'BTL', 'BTL', 1, 0, 0, 0, 10),
            (13, N'Monocef 1 g Injection', N'Ceftriaxone 1 g', N'Aristo Pharmaceuticals Pvt Ltd', N'Antibiotics', N'Injection', N'1 g', N'1 vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 0, 0, 20),
            (14, N'Pan 40 Injection', N'Pantoprazole 40 mg (injection)', N'Alkem Laboratories Ltd', N'Antacids & PPIs', N'Injection', N'40 mg', N'1 vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 0, 0, 20),
            (15, N'Sodium Chloride 0.9% 500 ml', N'Sodium Chloride 0.9%', N'Baxter India Pvt Ltd', N'IV Fluids', N'Infusion / IV Fluid', N'0.9% w/v', N'500 ml bottle', 'H', '3004', 'BTL', 'BTL', 1, 0, 0, 0, 50),
            (16, N'Human Actrapid 40 IU/ml', N'Human Insulin (regular) 40 IU/ml', N'Novo Nordisk India Pvt Ltd', N'Insulins', N'Injection', N'40 IU/ml', N'10 ml vial', 'H', '3004', 'VIAL', 'VIAL', 1, 0, 1, 1, 5),
            (17, N'Shelcal 500', N'Calcium Carbonate 1250 mg + Vitamin D3 250 IU', N'Torrent Pharmaceuticals Ltd', N'Vitamins & Minerals', N'Tablet', N'500 mg', N'Strip of 15 tablets', 'OTC', '3004', 'STRIP', 'TAB', 15, 1, 0, 0, 10),
            (18, N'Electral Powder 21.8 g', N'Oral Rehydration Salts (WHO)', N'Franco-Indian Pharmaceuticals Pvt Ltd', N'OTC / FMCG', N'Powder / Sachet', N'21.8 g', N'1 sachet', 'OTC', '3004', 'SACHET', 'SACHET', 1, 0, 0, 0, 30),
            (19, N'BD Emerald Syringe 5 ml', NULL, N'Becton Dickinson India Pvt Ltd', N'Surgical', N'Surgical / Device', N'5 ml', N'Box of 100', 'OTC', '9018', 'BOX', 'NOS', 100, 1, 0, 0, 2),
            (20, N'Surgical Gloves Sterile 7.0', NULL, N'Becton Dickinson India Pvt Ltd', N'Surgical', N'Surgical / Device', N'Size 7.0', N'Box of 50 pairs', 'OTC', '4015', 'BOX', 'PAIR', 50, 1, 0, 0, 2)
        ) v (n, item, generic, mfr, cat, form, strength, pack, sch, hsn, puom, suom, conv, loose, cold, alert, reorder)
        JOIN dbo.PhCategory c      ON c.CompanyId = @CompanyId AND c.CategoryName = v.cat
        JOIN dbo.PhHsn h           ON h.CompanyId = @CompanyId AND h.HsnCode = v.hsn
        JOIN dbo.PhUom pu          ON pu.CompanyId = @CompanyId AND pu.UomCode = v.puom
        JOIN dbo.PhUom su          ON su.CompanyId = @CompanyId AND su.UomCode = v.suom
        LEFT JOIN dbo.PhGeneric g  ON g.CompanyId = @CompanyId AND g.GenericName = v.generic
        LEFT JOIN dbo.PhManufacturer m ON m.CompanyId = @CompanyId AND m.ManufacturerName = v.mfr
        LEFT JOIN dbo.PhDosageForm f   ON f.CompanyId = @CompanyId AND f.DosageFormName = v.form;
    END
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhNumberSeries WHERE BranchId = @BranchId)
    BEGIN
        INSERT dbo.PhNumberSeries (CompanyId, BranchId, DocType, DocName, Prefix)
        SELECT @CompanyId, @BranchId, t, n, p FROM (VALUES ('SALE',N'Pharmacy Sale Bill','PS'),('SRET',N'Sale Return','PSR'),
            ('IPDI',N'IPD Issue','PII'),('IPDR',N'IPD Return','PIR'),('INDT',N'IPD / Ward Indent','PIN'),('PO',N'Purchase Order','PO'),
            ('GRN',N'Goods Receipt (GRN)','GRN'),('PRET',N'Purchase Return','PRT'),('TRF',N'Stock Transfer','TRF'),('ADJ',N'Stock Adjustment','ADJ'),
            ('PIND',N'Purchase Indent','PRQ'),('SPAY',N'Supplier Payment','SPY')) v (t, n, p);
    END
END;
GO

-- ── pages: Master > Pharmacy Master ──────────────────────────────────────────────────────────────────────
UPDATE dbo.PageMaster SET Show_In_Menu = 0 WHERE Page_Code = N'MASTER.MEDICINES';   -- placeholder, no controller
GO
DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT, @i INT = 1;
SELECT TOP 1 @menu = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.PHARMACY_MASTER' ORDER BY Menu_ID;
IF @menu IS NULL
BEGIN
    DECLARE @master INT;
    SELECT TOP 1 @master = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER' ORDER BY Menu_ID;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @master, @Menu_Type = 'MENU', @Menu_Code = N'MASTER.PHARMACY_MASTER',
         @Title = N'Pharmacy Master', @Sort_Order = 50, @Icon = N'bi bi-bag-heart me-2', @UserId = NULL, @Menu_ID = @menu OUTPUT;
END

DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Act NVARCHAR(60), SaveAct NVARCHAR(60), Sort INT, Icon NVARCHAR(60));
INSERT @pages (Code, Title, Ctl, Act, SaveAct, Sort, Icon) VALUES
 (N'MASTER.PH_ITEMS',         N'Item / Drug Master',     N'PharmacyItems',   N'Index',         N'Save',               10, N'bi bi-capsule me-2'),
 (N'MASTER.PH_GENERICS',      N'Generic / Molecule',     N'PharmacyMasters', N'Generics',      N'SaveGeneric',        20, N'bi bi-diagram-3 me-2'),
 (N'MASTER.PH_MANUFACTURERS', N'Manufacturer',           N'PharmacyMasters', N'Manufacturers', N'SaveManufacturer',   30, N'bi bi-building-gear me-2'),
 (N'MASTER.PH_SUPPLIERS',     N'Supplier / Distributor', N'PharmacyMasters', N'Suppliers',     N'SaveSupplier',       40, N'bi bi-truck me-2'),
 (N'MASTER.PH_CATEGORIES',    N'Item Category',          N'PharmacyMasters', N'Categories',    N'SaveCategory',       50, N'bi bi-tags me-2'),
 (N'MASTER.PH_DOSAGEFORMS',   N'Dosage Form',            N'PharmacyMasters', N'DosageForms',   N'SaveDosageForm',     60, N'bi bi-prescription2 me-2'),
 (N'MASTER.PH_UOMS',          N'Unit of Measure',        N'PharmacyMasters', N'Units',         N'SaveUnit',           70, N'bi bi-rulers me-2'),
 (N'MASTER.PH_HSN',           N'HSN & GST Rate',         N'PharmacyMasters', N'Hsn',           N'SaveHsn',            80, N'bi bi-percent me-2'),
 (N'MASTER.PH_SCHEDULES',     N'Drug Schedule',          N'PharmacyMasters', N'Schedules',     NULL,                  90, N'bi bi-shield-exclamation me-2'),
 (N'MASTER.PH_PRICERULES',    N'Price Rule',             N'PharmacyMasters', N'PriceRules',    N'SavePriceRule',     100, N'bi bi-currency-rupee me-2'),
 (N'MASTER.PH_DISCOUNTS',     N'Discount Scheme',        N'PharmacyMasters', N'Discounts',     N'SaveDiscount',      110, N'bi bi-ticket-perforated me-2'),
 (N'MASTER.PH_CUSTOMERS',     N'Pharmacy Customer',      N'PharmacyMasters', N'Customers',     N'SaveCustomer',      120, N'bi bi-person-vcard me-2'),
 (N'MASTER.PH_REASONS',       N'Return / Adjust Reason', N'PharmacyMasters', N'Reasons',       N'SaveReason',        130, N'bi bi-chat-left-text me-2'),
 (N'MASTER.PH_NUMBERSERIES',  N'Document Number Series', N'PharmacyMasters', N'NumberSeries',  N'SaveNumberSeries',  140, N'bi bi-123 me-2');

DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @a NVARCHAR(60), @s NVARCHAR(60), @sort INT, @icon NVARCHAR(60);
WHILE @menu IS NOT NULL AND @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @a = Act, @s = SaveAct, @sort = Sort, @icon = Icon FROM @pages WHERE n = @i;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = @a,
         @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @a, @Source = 'SEED';
    IF @code = N'MASTER.PH_ITEMS'
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = N'Search', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = N'Form', @Source = 'SEED';
    END
    IF @s IS NOT NULL
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Add / edit', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = @c, @Action = @s, @Source = 'SEED';
    END
    SET @i += 1;
END
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2343 applied: Pharmacy Phase 1 masters (tables, Hospital Settings pharmacy columns, sample data, pages).';
GO
