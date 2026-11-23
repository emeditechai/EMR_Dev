-- ============================================================================================================
-- 2406  Pharmacy counter (after 2405): OPD prescription link, clinical safety checks, loyalty points, refill
--       reminders, corporate / insurance credit, batch-checked sale returns. Settings: Hospital Settings > MED (2402).
--   OPD prescription (Rx) link
--     * PhRxGenericMap: each OPD Medication Master medicine -> a pharmacy Generic (Master > Pharmacy > OPD Medicine
--       Mapping). Not mapped: matched by name (generic name starts with the OPD generic name), marked "auto".
--     * usp_Api_PhSale_RxList / _RxLines: a patient's recent OPD consultations and their medicines
--       (EmrPatientConsultation.EmrDataJson, Medication fields: "medId|name|dose|freq|instructions,...") with the
--       in-stock brand to give (cheapest unit MRP among in-stock brands of the generic).
--     * PhSale.ConsultationId + PhSaleRx: what was prescribed and whether it was dispensed (reason when not).
--   Clinical safety checks
--     * PhDrugInteraction (Master > Pharmacy > Drug Interaction): generic pairs, Minor / Moderate / Major, effect, advice.
--     * fn_PhMolecules: the molecules of a generic ("Amoxicillin 500 mg + Clavulanic Acid 125 mg" -> Amoxicillin,
--       Clavulanic Acid), so checks work across strengths and combinations.
--     * usp_Api_PhSale_ClinicalCheck: interactions among the bill (and the patient's last 30 days of pharmacy bills),
--       allergy (PatientMaster.KnownAllergies), duplicate therapy (same molecule twice on the bill).
--     * PhSaleClinicalAlert: alerts shown at billing and the pharmacist's reason to continue.
--   Loyalty points: PhLoyaltyLedger (earn / redeem / reverse) for hospital patients and pharmacy customers;
--     redeemed value is a discount on the bill (spread over the lines before GST); earned on the net paid;
--     points of a cancelled bill do not count; a sale return takes back its share.
--   Refill reminders: PhSaleDtl.DaysSupply (days the medicine lasts) -> PhRefillReminder, sent by WhatsApp
--     N days before it runs out (EMR.Web background job), cancelled when the bill is cancelled.
--   Credit: customer type INSURANCE, PhCustomer.CreditDays (bills older than this block new credit),
--     PhSale.CreditRefNo (employee / policy / claim no., required on corporate and insurance credit).
--   Sale return: the batch number on the pack is checked against the bill line (when given).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── tables ───────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PhRxGenericMap') IS NULL
CREATE TABLE dbo.PhRxGenericMap (
    RxMapId      INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId    INT NOT NULL,
    MedicationId INT NOT NULL,                    -- EmrMedicationMaster (OPD)
    GenericId    INT NOT NULL REFERENCES dbo.PhGeneric (GenericId),
    IsActive     BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_PhRxGenericMap UNIQUE (CompanyId, MedicationId)
);
GO
IF OBJECT_ID('dbo.PhDrugInteraction') IS NULL
CREATE TABLE dbo.PhDrugInteraction (
    InteractionId INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    GenericId1    INT NOT NULL REFERENCES dbo.PhGeneric (GenericId),
    GenericId2    INT NOT NULL REFERENCES dbo.PhGeneric (GenericId),
    Severity      VARCHAR(10) NOT NULL,           -- MINOR | MODERATE | MAJOR
    Effect        NVARCHAR(300) NOT NULL,
    Advice        NVARCHAR(300) NULL,
    IsActive      BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT CK_PhDrugInteraction_Severity CHECK (Severity IN ('MINOR', 'MODERATE', 'MAJOR')),
    CONSTRAINT CK_PhDrugInteraction_Pair CHECK (GenericId1 <> GenericId2)
);
GO
IF COL_LENGTH('dbo.PhSale', 'ConsultationId') IS NULL
    ALTER TABLE dbo.PhSale ADD ConsultationId INT NULL, CreditRefNo NVARCHAR(60) NULL,
        LoyaltyRedeemPoints DECIMAL(12,2) NOT NULL CONSTRAINT DF_PhSale_LoyRedeem DEFAULT (0),
        LoyaltyRedeemValue DECIMAL(12,2) NOT NULL CONSTRAINT DF_PhSale_LoyValue DEFAULT (0),
        LoyaltyEarnedPoints DECIMAL(12,2) NOT NULL CONSTRAINT DF_PhSale_LoyEarned DEFAULT (0);
GO
IF COL_LENGTH('dbo.PhSaleDtl', 'DaysSupply') IS NULL
    ALTER TABLE dbo.PhSaleDtl ADD DaysSupply INT NULL;
GO
IF OBJECT_ID('dbo.PhSaleRx') IS NULL
CREATE TABLE dbo.PhSaleRx (
    SaleRxId       INT IDENTITY(1,1) PRIMARY KEY,
    SaleId         INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    ConsultationId INT NOT NULL,
    Seq            INT NOT NULL,
    MedicationId   INT NULL,
    MedicationName NVARCHAR(200) NOT NULL,
    GenericId      INT NULL,
    Dose           NVARCHAR(50) NULL,
    Frequency      NVARCHAR(50) NULL,
    Instructions   NVARCHAR(100) NULL,
    Status         VARCHAR(15) NOT NULL,          -- DISPENSED | NOT_DISPENSED
    ItemId         INT NULL,                      -- the brand given
    Reason         NVARCHAR(200) NULL
);
GO
IF OBJECT_ID('dbo.PhSaleClinicalAlert') IS NULL
CREATE TABLE dbo.PhSaleClinicalAlert (
    AlertId     INT IDENTITY(1,1) PRIMARY KEY,
    SaleId      INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    Kind        VARCHAR(15) NOT NULL,             -- INTERACTION | ALLERGY | DUPLICATE
    Severity    VARCHAR(10) NOT NULL,
    Message     NVARCHAR(500) NOT NULL,
    Reason      NVARCHAR(300) NULL,               -- why the pharmacist went ahead
    OverriddenBy INT NULL,
    CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.PhLoyaltyLedger') IS NULL
CREATE TABLE dbo.PhLoyaltyLedger (
    LoyaltyId   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CompanyId   INT NOT NULL,
    BranchId    INT NOT NULL,
    PatientId   INT NULL,
    CustomerId  INT NULL,
    Kind        VARCHAR(10) NOT NULL,             -- EARN | REDEEM | REVERSE
    Points      DECIMAL(12,2) NOT NULL,           -- + earned, - redeemed / taken back
    SaleId      INT NULL,
    ReturnId    INT NULL,
    ExpiresOn   DATE NULL,                        -- earned points only
    Remarks     NVARCHAR(200) NULL,
    CreatedBy   INT NULL,
    CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT CK_PhLoyaltyLedger_Member CHECK (PatientId IS NOT NULL OR CustomerId IS NOT NULL)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhLoyaltyLedger_Member')
    CREATE INDEX IX_PhLoyaltyLedger_Member ON dbo.PhLoyaltyLedger (CompanyId, PatientId, CustomerId) INCLUDE (Points, Kind, ExpiresOn, SaleId);
GO
IF OBJECT_ID('dbo.PhRefillReminder') IS NULL
CREATE TABLE dbo.PhRefillReminder (
    ReminderId  INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId   INT NOT NULL,
    BranchId    INT NOT NULL,
    SaleId      INT NOT NULL REFERENCES dbo.PhSale (SaleId),
    SaleDtlId   INT NOT NULL,
    ItemId      INT NOT NULL,
    PatientId   INT NULL,
    CustomerId  INT NULL,
    Name        NVARCHAR(150) NULL,
    Mobile      NVARCHAR(15) NOT NULL,
    RunOutDate  DATE NOT NULL,
    RemindOn    DATE NOT NULL,
    Status      VARCHAR(10) NOT NULL DEFAULT 'PENDING',   -- PENDING | SENDING | SENT | FAILED | CANCELLED | SKIPPED
    SentDate    DATETIME NULL,
    Detail      NVARCHAR(300) NULL,
    CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhRefillReminder_Due')
    CREATE INDEX IX_PhRefillReminder_Due ON dbo.PhRefillReminder (Status, RemindOn) INCLUDE (BranchId, SaleId);
GO
IF COL_LENGTH('dbo.PhCustomer', 'CreditDays') IS NULL
    ALTER TABLE dbo.PhCustomer ADD CreditDays INT NOT NULL CONSTRAINT DF_PhCustomer_CreditDays DEFAULT (30);
GO

-- ── molecules of a generic: strength and form words removed, combinations split on "+" ────────────────────
CREATE OR ALTER FUNCTION dbo.fn_PhMolecules (@GenericId INT)
RETURNS TABLE
AS
RETURN
    SELECT DISTINCT UPPER(LTRIM(RTRIM(LEFT(x.part, PATINDEX('%[0-9(]%', x.part + '0') - 1)))) AS Molecule
      FROM dbo.PhGeneric g
     CROSS APPLY (SELECT LTRIM(RTRIM(value)) AS part FROM STRING_SPLIT(REPLACE(g.GenericName, N' & ', N'+'), '+')) x
     WHERE g.GenericId = @GenericId AND LEN(LTRIM(RTRIM(LEFT(x.part, PATINDEX('%[0-9(]%', x.part + '0') - 1)))) >= 3;
GO

-- ── generic masters: OPD Medicine Mapping, Drug Interaction ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhRxGenericMap_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.RxMapId, m.MedicationId, m.GenericId, m.IsActive
      FROM dbo.PhRxGenericMap m LEFT JOIN dbo.EmrMedicationMaster e ON e.MedicationId = m.MedicationId
     WHERE m.CompanyId = @CompanyId ORDER BY e.MedicationName;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhRxGenericMap_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1, @MedicationId INT = NULL, @GenericId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.EmrMedicationMaster WHERE MedicationId = @MedicationId AND (CompanyId = @CompanyId OR CompanyId IS NULL))
    BEGIN SELECT 0 AS Id, N'Pick the OPD medicine.' AS Error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhGeneric WHERE GenericId = @GenericId AND CompanyId = @CompanyId)
    BEGIN SELECT 0 AS Id, N'Pick the pharmacy generic.' AS Error; RETURN; END;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhRxGenericMap (CompanyId, MedicationId, GenericId, IsActive, CreatedBy) VALUES (@CompanyId, @MedicationId, @GenericId, @IsActive, @UserId);
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhRxGenericMap SET MedicationId = @MedicationId, GenericId = @GenericId, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE RxMapId = @Id AND CompanyId = @CompanyId;
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
        END
        COMMIT;
        SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) BEGIN SELECT 0 AS Id, N'This OPD medicine is already mapped; edit that row.' AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDrugInteraction_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.InteractionId, d.GenericId1, d.GenericId2, d.Severity, d.Effect, d.Advice, d.IsActive
      FROM dbo.PhDrugInteraction d WHERE d.CompanyId = @CompanyId
     ORDER BY CASE d.Severity WHEN 'MAJOR' THEN 0 WHEN 'MODERATE' THEN 1 ELSE 2 END, d.InteractionId DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhDrugInteraction_Save
    @Id INT, @CompanyId INT, @BranchId INT = NULL, @UserId INT, @IsActive BIT = 1,
    @GenericId1 INT = NULL, @GenericId2 INT = NULL, @Severity VARCHAR(10) = NULL, @Effect NVARCHAR(300) = NULL, @Advice NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @GenericId1 IS NULL OR @GenericId2 IS NULL BEGIN SELECT 0 AS Id, N'Pick both generics.' AS Error; RETURN; END;
    IF @GenericId1 = @GenericId2 BEGIN SELECT 0 AS Id, N'Pick two different generics.' AS Error; RETURN; END;
    IF (SELECT COUNT(*) FROM dbo.PhGeneric WHERE GenericId IN (@GenericId1, @GenericId2) AND CompanyId = @CompanyId) <> 2
    BEGIN SELECT 0 AS Id, N'Generic not found.' AS Error; RETURN; END;
    IF @Severity NOT IN ('MINOR', 'MODERATE', 'MAJOR') BEGIN SELECT 0 AS Id, N'Pick the severity.' AS Error; RETURN; END;
    IF LTRIM(RTRIM(ISNULL(@Effect, N''))) = N'' BEGIN SELECT 0 AS Id, N'Describe the effect of the interaction.' AS Error; RETURN; END;
    -- kept as one pair whichever order it was entered in
    DECLARE @a INT = CASE WHEN @GenericId1 < @GenericId2 THEN @GenericId1 ELSE @GenericId2 END, @b INT = CASE WHEN @GenericId1 < @GenericId2 THEN @GenericId2 ELSE @GenericId1 END;
    IF EXISTS (SELECT 1 FROM dbo.PhDrugInteraction WHERE CompanyId = @CompanyId AND GenericId1 = @a AND GenericId2 = @b AND InteractionId <> ISNULL(@Id, 0))
    BEGIN SELECT 0 AS Id, N'This pair is already in the list; edit that row.' AS Error; RETURN; END;
    BEGIN TRAN;
    IF ISNULL(@Id, 0) = 0
    BEGIN
        INSERT dbo.PhDrugInteraction (CompanyId, GenericId1, GenericId2, Severity, Effect, Advice, IsActive, CreatedBy)
        VALUES (@CompanyId, @a, @b, @Severity, LTRIM(RTRIM(@Effect)), NULLIF(LTRIM(RTRIM(@Advice)), N''), @IsActive, @UserId);
        SET @Id = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        UPDATE dbo.PhDrugInteraction SET GenericId1 = @a, GenericId2 = @b, Severity = @Severity, Effect = LTRIM(RTRIM(@Effect)), Advice = NULLIF(LTRIM(RTRIM(@Advice)), N''),
               IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE InteractionId = @Id AND CompanyId = @CompanyId;
        IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'Record not found.' AS Error; RETURN; END
    END
    COMMIT;
    SELECT @Id AS Id, CAST(NULL AS NVARCHAR(300)) AS Error;
END
GO

-- lookups of the simple masters: 1 states, 2 main categories, 3 categories, 4 discount schemes, 5 suppliers, 6 items,
-- 7 generics, 8 OPD medicines
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
    SELECT CAST(SupplierId AS VARCHAR(10)) AS Value, SupplierName AS Text FROM dbo.PhSupplier WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SupplierName;
    SELECT CAST(i.ItemId AS VARCHAR(10)) AS Value, i.ItemName + ISNULL(N' · ' + i.PackSize, N'') + N' (' + i.ItemCode + N')' AS Text
      FROM dbo.PhItem i WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 ORDER BY i.ItemName;
    SELECT CAST(GenericId AS VARCHAR(10)) AS Value, GenericName AS Text FROM dbo.PhGeneric WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY GenericName;
    SELECT CAST(MedicationId AS VARCHAR(10)) AS Value, MedicationName + ISNULL(N' (' + NULLIF(GenericName, N'') + N')', N'') AS Text
      FROM dbo.EmrMedicationMaster WHERE (CompanyId = @CompanyId OR CompanyId IS NULL) AND IsActive = 1 ORDER BY MedicationName;
END
GO

-- ── OPD prescription ─────────────────────────────────────────────────────────────────────────────────────
-- the pharmacy generic of an OPD medicine: the mapping, else the generic whose name starts with the OPD generic name
CREATE OR ALTER FUNCTION dbo.fn_PhRxGeneric (@CompanyId INT, @MedicationId INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 x.GenericId, x.GenericName, x.Mapped
      FROM (
        SELECT g.GenericId, g.GenericName, CAST(1 AS BIT) AS Mapped, 0 AS Rk
          FROM dbo.PhRxGenericMap m JOIN dbo.PhGeneric g ON g.GenericId = m.GenericId
         WHERE m.CompanyId = @CompanyId AND m.MedicationId = @MedicationId AND m.IsActive = 1
        UNION ALL
        SELECT g.GenericId, g.GenericName, CAST(0 AS BIT), 1 + CASE WHEN e.Strength IS NOT NULL AND REPLACE(g.GenericName, N' ', N'') LIKE N'%' + REPLACE(e.Strength, N' ', N'') + N'%' THEN 0 ELSE 1 END
          FROM dbo.EmrMedicationMaster e JOIN dbo.PhGeneric g ON g.CompanyId = @CompanyId AND g.IsActive = 1
               AND NULLIF(LTRIM(RTRIM(e.GenericName)), N'') IS NOT NULL AND g.GenericName LIKE LTRIM(RTRIM(e.GenericName)) + N'%'
         WHERE e.MedicationId = @MedicationId
      ) x
     ORDER BY x.Rk, LEN(x.GenericName);
GO

-- a patient's OPD consultations of the last @Days days that carry medicines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_RxList @CompanyId INT, @BranchId INT, @PatientId INT, @Days INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.ConsultationId, c.VisitDate, c.OPDBillNo, c.DoctorId, d.FullName AS DoctorName, d.MedicalLicenseNo AS DoctorRegNo,
           (SELECT COUNT(*) FROM OPENJSON(c.EmrDataJson) j JOIN dbo.EmrTemplateFields f ON CAST(f.FieldId AS NVARCHAR(20)) = j.[key] AND f.FieldType = 'Medication'
                CROSS APPLY STRING_SPLIT(CAST(j.value AS NVARCHAR(MAX)), ',') s WHERE LTRIM(s.value) <> N'') AS Medicines,
           (SELECT TOP 1 s.SaleNo FROM dbo.PhSale s WHERE s.ConsultationId = c.ConsultationId AND s.Status = 'POSTED' ORDER BY s.SaleId DESC) AS DispensedOn
      FROM dbo.EmrPatientConsultation c
      LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
     WHERE c.PatientId = @PatientId AND (c.CompanyId = @CompanyId OR c.CompanyId IS NULL)
       AND c.VisitDate >= DATEADD(DAY, -@Days, CAST(GETDATE() AS DATE)) AND ISJSON(c.EmrDataJson) = 1
       AND EXISTS (SELECT 1 FROM OPENJSON(c.EmrDataJson) j JOIN dbo.EmrTemplateFields f ON CAST(f.FieldId AS NVARCHAR(20)) = j.[key] AND f.FieldType = 'Medication'
                    WHERE LTRIM(CAST(j.value AS NVARCHAR(MAX))) <> N'')
     ORDER BY c.VisitDate DESC;
END
GO

-- the medicines of one consultation, each with its pharmacy generic and the in-stock brand suggested
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_RxLines @CompanyId INT, @BranchId INT, @ConsultationId INT, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    DECLARE @minExp DATE = DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE));
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'SELL'));
    -- header: the consultation and its doctor
    SELECT c.ConsultationId, c.PatientId, c.VisitDate, c.OPDBillNo, c.DoctorId, d.FullName AS DoctorName, d.MedicalLicenseNo AS DoctorRegNo
      FROM dbo.EmrPatientConsultation c LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
     WHERE c.ConsultationId = @ConsultationId AND (c.CompanyId = @CompanyId OR c.CompanyId IS NULL);
    ;WITH raw AS (
        -- ordered split without STRING_SPLIT(..., 1) (needs compatibility 160): the list as a JSON array
        SELECT ROW_NUMBER() OVER (ORDER BY f.DisplayOrder, f.FieldId, CAST(s.[key] AS INT)) AS Seq, LTRIM(RTRIM(s.value)) AS Entry
          FROM dbo.EmrPatientConsultation c
         CROSS APPLY OPENJSON(c.EmrDataJson) j
          JOIN dbo.EmrTemplateFields f ON CAST(f.FieldId AS NVARCHAR(20)) = j.[key] AND f.FieldType = 'Medication'
         CROSS APPLY OPENJSON(N'["' + REPLACE(STRING_ESCAPE(CAST(j.value AS NVARCHAR(MAX)), 'json'), N',', N'","') + N'"]') s
         WHERE c.ConsultationId = @ConsultationId AND ISJSON(c.EmrDataJson) = 1 AND LTRIM(s.value) <> N''
    ), parts AS (
        SELECT r.Seq,
               MAX(CASE WHEN p.[key] = '0' THEN p.value END) AS MedId, MAX(CASE WHEN p.[key] = '1' THEN p.value END) AS Name,
               MAX(CASE WHEN p.[key] = '2' THEN p.value END) AS Dose, MAX(CASE WHEN p.[key] = '3' THEN p.value END) AS Freq,
               MAX(CASE WHEN p.[key] = '4' THEN p.value END) AS Instr
          FROM raw r CROSS APPLY OPENJSON(N'["' + REPLACE(STRING_ESCAPE(r.Entry, 'json'), N'|', N'","') + N'"]') p GROUP BY r.Seq
    )
    SELECT p.Seq, TRY_CAST(p.MedId AS INT) AS MedicationId, LEFT(ISNULL(p.Name, N''), 200) AS MedicationName, LEFT(p.Dose, 50) AS Dose, LEFT(p.Freq, 50) AS Frequency,
           LEFT(p.Instr, 100) AS Instructions, g.GenericId, g.GenericName, ISNULL(g.Mapped, 0) AS Mapped,
           sug.ItemId AS SuggestedItemId, sug.ItemName AS SuggestedItemName, sug.Stock AS SuggestedStock,
           (SELECT COUNT(DISTINCT i.ItemId) FROM dbo.PhItem i JOIN dbo.PhStoreStock s ON s.ItemId = i.ItemId AND s.StoreId = @StoreId AND s.QtyOnHand > 0
                 JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0 AND b.ExpiryDate > @minExp
             WHERE i.GenericId = g.GenericId AND i.IsActive = 1) AS BrandsInStock
      FROM parts p
     OUTER APPLY dbo.fn_PhRxGeneric(@CompanyId, TRY_CAST(p.MedId AS INT)) g
     OUTER APPLY (SELECT TOP 1 i.ItemId, i.ItemName, SUM(s.QtyOnHand) AS Stock
                    FROM dbo.PhItem i JOIN dbo.PhStoreStock s ON s.ItemId = i.ItemId AND s.StoreId = @StoreId AND s.QtyOnHand > 0
                    JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0 AND b.ExpiryDate > @minExp
                   WHERE i.GenericId = g.GenericId AND i.IsActive = 1 AND i.CompanyId = @CompanyId
                   GROUP BY i.ItemId, i.ItemName, i.ConversionQty
                   ORDER BY MIN(b.Mrp / i.ConversionQty), i.ItemName) sug
     ORDER BY p.Seq;
END
GO

-- ── clinical safety checks ───────────────────────────────────────────────────────────────────────────────
-- @ItemIds: [1, 5, 9] (the bill). Answers: Kind, Severity, Title, Message, Advice.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_ClinicalCheck
    @CompanyId INT, @BranchId INT, @PatientId INT = NULL, @CustomerId INT = NULL, @ItemIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @on BIT = ISNULL((SELECT TOP 1 PharmacyClinicalChecksEnabled FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0);
    DECLARE @R TABLE (Kind VARCHAR(15), Severity VARCHAR(10), Title NVARCHAR(200), Message NVARCHAR(500), Advice NVARCHAR(300));
    IF @on = 0 BEGIN SELECT * FROM @R; RETURN; END;

    DECLARE @Bill TABLE (ItemId INT PRIMARY KEY, ItemName NVARCHAR(200), GenericId INT, Src VARCHAR(5));
    INSERT @Bill SELECT DISTINCT i.ItemId, i.ItemName, i.GenericId, 'BILL' FROM OPENJSON(@ItemIds) j JOIN dbo.PhItem i ON i.ItemId = TRY_CAST(j.value AS INT) AND i.CompanyId = @CompanyId;
    -- what the same person got from the pharmacy in the last 30 days (still being taken)
    INSERT @Bill SELECT DISTINCT d.ItemId, i.ItemName, i.GenericId, 'PAST'
      FROM dbo.PhSale s JOIN dbo.PhSaleDtl d ON d.SaleId = s.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
     WHERE s.CompanyId = @CompanyId AND s.Status = 'POSTED' AND s.SaleDate >= DATEADD(DAY, -30, GETDATE())
       AND ((@PatientId IS NOT NULL AND s.PatientId = @PatientId) OR (@CustomerId IS NOT NULL AND s.CustomerId = @CustomerId))
       AND d.ItemId NOT IN (SELECT ItemId FROM @Bill);
    DECLARE @M TABLE (ItemId INT, Molecule NVARCHAR(200));
    INSERT @M SELECT b.ItemId, m.Molecule FROM @Bill b CROSS APPLY dbo.fn_PhMolecules(b.GenericId) m WHERE b.GenericId IS NOT NULL;

    -- interactions: a pair from the master whose molecules are on the bill (at least one side on this bill)
    INSERT @R
    SELECT DISTINCT 'INTERACTION', x.Severity,
           b1.ItemName + N' + ' + b2.ItemName,
           N'Interaction (' + LOWER(x.Severity) + N'): ' + x.Effect + CASE WHEN b1.Src = 'PAST' OR b2.Src = 'PAST' THEN N' (one was dispensed in the last 30 days)' ELSE N'' END,
           x.Advice
      FROM dbo.PhDrugInteraction x
      JOIN @M m1 ON m1.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId1))
      JOIN @M m2 ON m2.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId2))
      JOIN @Bill b1 ON b1.ItemId = m1.ItemId JOIN @Bill b2 ON b2.ItemId = m2.ItemId
     WHERE x.CompanyId = @CompanyId AND x.IsActive = 1 AND b1.ItemId <> b2.ItemId AND (b1.Src = 'BILL' OR b2.Src = 'BILL');

    -- allergy: a word of the patient's known allergies found in a molecule on this bill (or the other way round)
    IF @PatientId IS NOT NULL
    BEGIN
        DECLARE @allergy NVARCHAR(MAX) = (SELECT KnownAllergies FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId);
        IF LTRIM(RTRIM(ISNULL(@allergy, N''))) NOT IN (N'', N'NIL', N'NONE', N'NKDA', N'NO', N'NA', N'N/A')
            INSERT @R
            SELECT DISTINCT 'ALLERGY', 'MAJOR', b.ItemName, N'Patient''s known allergy: "' + LEFT(@allergy, 200) + N'" - matches ' + m.Molecule + N'.',
                   N'Confirm with the patient / prescriber before dispensing.'
              FROM @M m JOIN @Bill b ON b.ItemId = m.ItemId AND b.Src = 'BILL'
              CROSS APPLY (SELECT UPPER(LTRIM(RTRIM(value))) AS Word FROM STRING_SPLIT(REPLACE(REPLACE(REPLACE(@allergy, N';', N','), N'/', N','), CHAR(10), N','), ',')) a
             WHERE LEN(a.Word) >= 4 AND (m.Molecule LIKE N'%' + a.Word + N'%' OR a.Word LIKE N'%' + m.Molecule + N'%');
    END

    -- duplicate therapy: the same molecule in two different items on this bill
    INSERT @R
    SELECT DISTINCT 'DUPLICATE', 'MODERATE', b1.ItemName + N' / ' + b2.ItemName,
           N'Same medicine twice: both contain ' + m1.Molecule + N'.', N'Check it is not a double dose.'
      FROM @M m1 JOIN @M m2 ON m2.Molecule = m1.Molecule AND m2.ItemId > m1.ItemId
      JOIN @Bill b1 ON b1.ItemId = m1.ItemId AND b1.Src = 'BILL' JOIN @Bill b2 ON b2.ItemId = m2.ItemId AND b2.Src = 'BILL';

    SELECT Kind, Severity, Title, Message, Advice FROM @R
     ORDER BY CASE Severity WHEN 'MAJOR' THEN 0 WHEN 'MODERATE' THEN 1 ELSE 2 END, Kind;
END
GO

-- ── loyalty ──────────────────────────────────────────────────────────────────────────────────────────────
-- points a member can use now: earned and not expired, less redeemed / taken back; a cancelled bill's points do not count
CREATE OR ALTER FUNCTION dbo.fn_PhLoyaltyBalance (@CompanyId INT, @PatientId INT, @CustomerId INT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN x.Bal < 0 THEN 0 ELSE x.Bal END AS DECIMAL(12,2)) AS Points, x.Earned, x.Used
      FROM (SELECT ISNULL(SUM(CASE WHEN l.Kind = 'EARN' AND (l.ExpiresOn IS NULL OR l.ExpiresOn >= CAST(GETDATE() AS DATE)) THEN l.Points
                                   WHEN l.Kind <> 'EARN' THEN l.Points ELSE 0 END), 0) AS Bal,
                   ISNULL(SUM(CASE WHEN l.Kind = 'EARN' THEN l.Points ELSE 0 END), 0) AS Earned,
                   ISNULL(-SUM(CASE WHEN l.Kind <> 'EARN' THEN l.Points ELSE 0 END), 0) AS Used
              FROM dbo.PhLoyaltyLedger l LEFT JOIN dbo.PhSale s ON s.SaleId = l.SaleId
             WHERE l.CompanyId = @CompanyId AND (s.SaleId IS NULL OR s.Status = 'POSTED')
               AND ((@PatientId IS NOT NULL AND l.PatientId = @PatientId) OR (@CustomerId IS NOT NULL AND l.CustomerId = @CustomerId))) x;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_LoyaltyBalance @CompanyId INT, @BranchId INT, @PatientId INT = NULL, @CustomerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.Points, b.Earned, b.Used, ISNULL(h.PharmacyLoyaltyPointValue, 1) AS PointValue, ISNULL(h.PharmacyLoyaltyMinRedeem, 0) AS MinRedeem,
           ISNULL(h.PharmacyLoyaltyMaxRedeemPercent, 0) AS MaxRedeemPercent, ISNULL(h.PharmacyLoyaltyEnabled, 0) AS Enabled
      FROM dbo.fn_PhLoyaltyBalance(@CompanyId, @PatientId, @CustomerId) b
      OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC) h;
END
GO

-- ── refill reminders (sent by EMR.Web) ──────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRefill_Due @Take INT = 50
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    -- not sent for a cancelled bill, or a medicine already bought again
    UPDATE r SET Status = 'CANCELLED', Detail = N'Bill cancelled.' FROM dbo.PhRefillReminder r JOIN dbo.PhSale s ON s.SaleId = r.SaleId
     WHERE r.Status = 'PENDING' AND s.Status <> 'POSTED';
    UPDATE r SET Status = 'SKIPPED', Detail = N'Bought again on ' + FORMAT(x.SaleDate, 'dd-MMM-yyyy', 'en-US') + N'.'
      FROM dbo.PhRefillReminder r
     CROSS APPLY (SELECT TOP 1 s2.SaleDate FROM dbo.PhSale s2 JOIN dbo.PhSaleDtl d2 ON d2.SaleId = s2.SaleId
                   WHERE s2.Status = 'POSTED' AND s2.SaleId > r.SaleId AND d2.ItemId = r.ItemId
                     AND ((r.PatientId IS NOT NULL AND s2.PatientId = r.PatientId) OR (r.CustomerId IS NOT NULL AND s2.CustomerId = r.CustomerId) OR s2.Mobile = r.Mobile)
                   ORDER BY s2.SaleId) x
     WHERE r.Status = 'PENDING' AND r.RemindOn <= CAST(GETDATE() AS DATE);
    -- a claim left by a run that stopped half-way is retried after an hour
    UPDATE dbo.PhRefillReminder SET Status = 'PENDING' WHERE Status = 'SENDING' AND SentDate < DATEADD(HOUR, -1, GETDATE());
    -- claim (so each reminder goes out once, even with two servers), then answer what to send
    DECLARE @C TABLE (ReminderId INT PRIMARY KEY);
    UPDATE TOP (@Take) r SET Status = 'SENDING', SentDate = GETDATE()
    OUTPUT inserted.ReminderId INTO @C
      FROM dbo.PhRefillReminder r WITH (READPAST, UPDLOCK)
     WHERE r.Status = 'PENDING' AND r.RemindOn <= CAST(GETDATE() AS DATE)
       AND ISNULL((SELECT TOP 1 h.PharmacyRefillReminderEnabled FROM dbo.HospitalSettings h WHERE h.BranchId = r.BranchId ORDER BY h.IsActive DESC), 0) = 1;
    SELECT r.ReminderId, r.BranchId, r.SaleId, r.Name, r.Mobile, r.RunOutDate, i.ItemName, s.SaleNo,
           ISNULL(NULLIF(h.PharmacyName, N''), h.HotelName) AS PharmacyName, ISNULL(NULLIF(h.PharmacyContactNo, N''), h.ContactNumber1) AS PharmacyPhone
      FROM @C c JOIN dbo.PhRefillReminder r ON r.ReminderId = c.ReminderId JOIN dbo.PhItem i ON i.ItemId = r.ItemId JOIN dbo.PhSale s ON s.SaleId = r.SaleId
      OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings WHERE BranchId = r.BranchId ORDER BY IsActive DESC) h
     ORDER BY r.RemindOn, r.ReminderId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_PhRefill_Mark @ReminderId INT, @Status VARCHAR(10), @Detail NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PhRefillReminder SET Status = @Status, Detail = LEFT(@Detail, 300), SentDate = GETDATE()
     WHERE ReminderId = @ReminderId AND Status = 'SENDING';
END
GO

-- ── counter sale: + OPD prescription, clinical alerts, loyalty, days of supply (refill reminders), credit reference ──
-- @Lines:    [{ "ItemId", "BatchId", "Qty" (sale units), "DiscPercent", "DaysSupply" }]
-- @Payments: [{ "Method", "Amount", "Ref" }]  - empty when held
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @Hold BIT, @CanDiscount BIT, @CanCredit BIT, @HoldId INT = NULL,
    @CustomerKind VARCHAR(10), @PatientId INT = NULL, @CustomerId INT = NULL, @CustomerName NVARCHAR(4000) = NULL, @Mobile NVARCHAR(4000) = NULL,
    @Email NVARCHAR(4000) = NULL, @Address NVARCHAR(4000) = NULL, @DoctorId INT = NULL, @DoctorName NVARCHAR(4000) = NULL, @DoctorRegNo NVARCHAR(4000) = NULL,
    @RxNo NVARCHAR(4000) = NULL, @RxDate DATE = NULL, @BillDiscPercent DECIMAL(9,4) = 0, @Remarks NVARCHAR(4000) = NULL, @HoldLabel NVARCHAR(4000) = NULL,
    @Lines NVARCHAR(MAX), @Payments NVARCHAR(MAX) = N'[]', @StoreId INT = NULL,
    -- SQLScripts/2406: OPD prescription, clinical alerts, loyalty, credit reference
    @ConsultationId INT = NULL, @RxLines NVARCHAR(MAX) = NULL, @Alerts NVARCHAR(MAX) = NULL, @RedeemPoints DECIMAL(12,2) = 0, @CreditRefNo NVARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'SELL'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose a selling store (counter) of this branch.' AS Error; RETURN; END;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @err NVARCHAR(500);
    DECLARE @enabled BIT = 0, @lic DATE, @ndps NVARCHAR(100), @shelf INT = 30, @neg BIT = 0, @maxDisc DECIMAL(9,4) = 10, @roundOff BIT = 1;
    SELECT TOP 1 @enabled = PharmacyEnabled, @lic = PharmacyDrugLicence20BValidTo, @ndps = PharmacyNdpsLicenceNo, @shelf = PharmacyMinShelfLifeSaleDays,
           @neg = PharmacyAllowNegativeStock, @maxDisc = PharmacyMaxManualDiscountPercent, @roundOff = PharmacyRoundOffBill
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    IF ISNULL(@enabled, 0) = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy is not enabled for this branch (Hospital Settings > Pharmacy & Drug Licence).' AS Error; RETURN; END;
    IF @Hold = 0 AND @lic < @today
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy''s drug licence expired on ' + FORMAT(@lic, 'dd-MMM-yyyy', 'en-US') + N'; sales are stopped until it is renewed in Hospital Settings.' AS Error; RETURN; END;

    DECLARE @In TABLE (Seq INT PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), DaysSupply INT);
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.ItemId'), JSON_VALUE(value, '$.BatchId'), JSON_VALUE(value, '$.Qty'), ISNULL(JSON_VALUE(value, '$.DiscPercent'), 0),
                      NULLIF(TRY_CAST(JSON_VALUE(value, '$.DaysSupply') AS INT), 0)
                 FROM OPENJSON(@Lines);
    IF EXISTS (SELECT 1 FROM @In WHERE DaysSupply < 0 OR DaysSupply > 365) BEGIN SELECT CAST(0 AS BIT) AS Success, N'Days of supply must be between 1 and 365.' AS Error; RETURN; END;
    DECLARE @Pay TABLE (Seq INT PRIMARY KEY, Method VARCHAR(10), Amount DECIMAL(18,2), Ref NVARCHAR(200));
    INSERT @Pay SELECT CAST([key] AS INT), JSON_VALUE(value, '$.Method'), JSON_VALUE(value, '$.Amount'), JSON_VALUE(value, '$.Ref') FROM OPENJSON(ISNULL(@Payments, N'[]'));
    DECLARE @P TABLE (Seq INT IDENTITY PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), UnitMrp DECIMAL(12,4), UnitPrice DECIMAL(12,4),
                      Amount DECIMAL(18,2), Gst DECIMAL(5,2), Taxable DECIMAL(18,2), GstAmt DECIMAL(18,2), Cost DECIMAL(12,4), Schedule VARCHAR(10), Register BIT, Narcotic BIT, ItemName NVARCHAR(200), DaysSupply INT);

    BEGIN TRY
        BEGIN TRAN;
        -- customer
        DECLARE @priceType VARCHAR(20) = 'WALKIN', @custFound BIT = 0, @custCredit BIT = 0, @custLimit DECIMAL(14,2) = 0, @custType VARCHAR(20) = NULL, @custDays INT = 30;
        IF @CustomerKind = 'PATIENT'
        BEGIN
            DECLARE @pn NVARCHAR(300), @pp NVARCHAR(50), @pa NVARCHAR(500), @pe NVARCHAR(150), @pf BIT = 0;
            SELECT @pf = 1, @pn = LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))), @pp = PhoneNumber, @pa = Address, @pe = EmailId
              FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @pf = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the patient (UHID).' AS Error; RETURN; END;
            SET @CustomerName = ISNULL(@CustomerName, @pn); SET @Mobile = ISNULL(@Mobile, @pp); SET @Address = ISNULL(@Address, @pa); SET @Email = ISNULL(@Email, @pe);
            SET @CustomerId = NULL;
        END
        ELSE IF @CustomerKind = 'CUSTOMER'
        BEGIN
            DECLARE @cn NVARCHAR(150), @cm NVARCHAR(15), @ce NVARCHAR(150), @ca NVARCHAR(300), @ct VARCHAR(20);
            SELECT @custFound = 1, @cn = CustomerName, @cm = Mobile, @ce = Email, @ca = Address, @ct = CustomerType, @custCredit = CreditAllowed, @custLimit = CreditLimit,
                   @custType = CustomerType, @custDays = CreditDays
              FROM dbo.PhCustomer WHERE CustomerId = @CustomerId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @custFound = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the pharmacy customer.' AS Error; RETURN; END;
            SET @CustomerName = @cn; SET @Mobile = @cm; SET @Email = ISNULL(@Email, @ce); SET @Address = ISNULL(@Address, @ca); SET @PatientId = NULL;
            IF @ct = 'STAFF' SET @priceType = 'STAFF';
        END
        ELSE BEGIN SET @PatientId = NULL; SET @CustomerId = NULL; END;

        -- items and batches: first expiry first, split over batches; a chosen batch is used as it is
        DECLARE @It TABLE (ItemId INT PRIMARY KEY, ItemName NVARCHAR(200), Conv INT, Loose BIT, DiscOk BIT, Schedule VARCHAR(10), Rx BIT, Reg BIT, Narc BIT, Active BIT);
        INSERT @It SELECT i.ItemId, i.ItemName, i.ConversionQty, i.AllowLooseSale, i.IsDiscountAllowed, i.ScheduleCode, i.PrescriptionRequired, sc.RegisterRequired, sc.IsNarcotic, i.IsActive
                     FROM dbo.PhItem i JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
                    WHERE i.CompanyId = @CompanyId AND i.ItemId IN (SELECT ItemId FROM @In);
        DECLARE @minExpiry DATE = DATEADD(DAY, @shelf, @today);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @item INT, @batch INT, @qty DECIMAL(18,6), @disc DECIMAL(9,4), @left DECIMAL(18,6),
                @name NVARCHAR(200), @conv INT, @loose BIT, @narc BIT, @reg BIT, @sch VARCHAR(10), @active BIT;
        DECLARE @B TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Stock DECIMAL(14,3), Expiry DATE, Blocked BIT);
        DECLARE @bn INT, @bId INT, @bStock DECIMAL(14,3), @bExp DATE, @bBlocked BIT, @take DECIMAL(18,6), @last INT;
        WHILE @seq IS NOT NULL
        BEGIN
            DECLARE @days INT = NULL;
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @disc = Disc, @days = DaysSupply FROM @In WHERE Seq = @seq;
            SELECT @name = NULL, @active = NULL;
            SELECT @name = ItemName, @conv = Conv, @loose = Loose, @narc = Narc, @reg = Reg, @sch = Schedule, @active = Active FROM @It WHERE ItemId = @item;
            IF @name IS NULL OR @active = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item is not in the Item Master or is inactive.' AS Error; RETURN; END;
            IF @loose = 0 AND @qty % @conv <> 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is sold in full packs of ' + CAST(@conv AS NVARCHAR(10)) + N' only.' AS Error; RETURN; END;
            IF @narc = 1 AND NULLIF(LTRIM(RTRIM(@ndps)), N'') IS NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is a Schedule X / NDPS drug: the branch has no NDPS licence in Hospital Settings.' AS Error; RETURN; END;
            DELETE @B;
            INSERT @B (BatchId, Stock, Expiry, Blocked)
            SELECT b.BatchId, s.QtyOnHand, b.ExpiryDate, b.IsBlocked FROM dbo.PhStoreStock s WITH (UPDLOCK, HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
             WHERE s.StoreId = @StoreId AND s.ItemId = @item AND (@batch IS NULL OR b.BatchId = @batch) ORDER BY b.ExpiryDate, b.BatchId;
            IF @batch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @B) BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch has no stock here.' AS Error; RETURN; END;
            SET @left = @qty;
            SET @bn = (SELECT MIN(Rn) FROM @B);
            WHILE @bn IS NOT NULL AND @left > 0
            BEGIN
                SELECT @bId = BatchId, @bStock = Stock, @bExp = Expiry, @bBlocked = Blocked FROM @B WHERE Rn = @bn;
                IF @bBlocked = 1 OR @bExp <= @today
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch is expired or blocked.' AS Error; RETURN; END;
                END
                ELSE IF @bExp <= @minExpiry
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch expires within ' + CAST(@shelf AS NVARCHAR(10)) + N' days and cannot be sold.' AS Error; RETURN; END;
                END
                ELSE
                BEGIN
                    SET @take = CASE WHEN @Hold = 1 OR @batch IS NOT NULL THEN @left
                                     WHEN @left < (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) THEN @left
                                     ELSE (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) END;
                    IF @take > 0
                    BEGIN
                        INSERT @P (ItemId, BatchId, Qty, Disc, Schedule, Register, Narcotic, ItemName, DaysSupply) VALUES (@item, @bId, @take, @disc, @sch, @reg, @narc, @name, @days);
                        SET @left = @left - @take;
                    END
                END
                SET @bn = (SELECT MIN(Rn) FROM @B WHERE Rn > @bn);
            END
            IF @left > 0
            BEGIN
                IF @neg = 0 AND @Hold = 0
                BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Not enough sellable stock of ' + @name + N': short by ' + FORMAT(@left, '0.##') + N'.' AS Error; RETURN; END;
                SET @last = (SELECT MAX(Seq) FROM @P WHERE ItemId = @item);
                IF @last IS NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' has no sellable batch.' AS Error; RETURN; END;
                UPDATE @P SET Qty = Qty + @left WHERE Seq = @last;
            END
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END

        -- prices and amounts (MRP inclusive of GST)
        UPDATE p SET UnitMrp = ROUND(CAST(b.Mrp AS DECIMAL(38,18)) / i.ConversionQty, 4), Cost = b.LandedCost, Gst = b.GstPercent,
                     UnitPrice = pr.UnitPrice,
                     Disc = CASE WHEN it.DiscOk = 1 THEN CASE WHEN p.Disc + @BillDiscPercent > 100 THEN 100 ELSE p.Disc + @BillDiscPercent END ELSE 0 END
          FROM @P p JOIN dbo.PhBatch b ON b.BatchId = p.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN @It it ON it.ItemId = p.ItemId
          CROSS APPLY dbo.fn_PhSaleUnitPrice(@CompanyId, p.ItemId, p.BatchId, @priceType) pr;
        UPDATE @P SET Amount = ROUND(CAST(Qty AS DECIMAL(38,18)) * UnitPrice * (1 - CAST(Disc AS DECIMAL(38,18)) / 100), 2);
        UPDATE @P SET Taxable = ROUND(CAST(Amount AS DECIMAL(38,18)) * 100 / (100 + Gst), 2);
        UPDATE @P SET GstAmt = Amount - Taxable;
        DECLARE @manualDisc DECIMAL(9,4) = ISNULL((SELECT MAX(Disc) FROM @P), 0);
        IF @Hold = 0 AND @manualDisc > @maxDisc AND @CanDiscount = 0
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Discount ' + FORMAT(@manualDisc, '0.##') + N'% is above the ' + FORMAT(@maxDisc, '0.##') + N'% allowed at the counter; a user with the Discount permission must bill it.' AS Error; RETURN; END;

        -- prescription and register
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.Rx = 1)
           AND (LTRIM(RTRIM(ISNULL(@DoctorName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@RxNo, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item that needs a prescription is on the bill: enter the doctor and the prescription number.' AS Error; RETURN; END;
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P WHERE Register = 1)
           AND (LTRIM(RTRIM(ISNULL(@CustomerName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@Address, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'A Schedule H1 / X drug is on the bill: the patient''s name and address are needed for the register.' AS Error; RETURN; END;

        -- loyalty points (SQLScripts/2406): the value redeemed is a discount spread over the lines before GST
        DECLARE @loyOn BIT = 0, @loyEarn DECIMAL(8,2) = 0, @loyValue DECIMAL(8,2) = 1, @loyMin INT = 0, @loyMaxPct DECIMAL(5,2) = 0, @loyExpiry INT = 365,
                @redeemValue DECIMAL(18,2) = 0, @earned DECIMAL(12,2) = 0;
        SELECT TOP 1 @loyOn = PharmacyLoyaltyEnabled, @loyEarn = PharmacyLoyaltyEarnPer100, @loyValue = PharmacyLoyaltyPointValue, @loyMin = PharmacyLoyaltyMinRedeem,
               @loyMaxPct = PharmacyLoyaltyMaxRedeemPercent, @loyExpiry = PharmacyLoyaltyExpiryDays
          FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
        SET @RedeemPoints = ISNULL(@RedeemPoints, 0);
        IF @Hold = 0 AND @RedeemPoints > 0
        BEGIN
            IF @loyOn = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Loyalty points are off for this branch.' AS Error; RETURN; END;
            IF @CustomerKind = 'WALKIN' BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can be used only by a hospital patient or a pharmacy customer.' AS Error; RETURN; END;
            IF @RedeemPoints <> FLOOR(@RedeemPoints) BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Redeem whole points.' AS Error; RETURN; END;
            DECLARE @have DECIMAL(12,2) = (SELECT Points FROM dbo.fn_PhLoyaltyBalance(@CompanyId, @PatientId, @CustomerId));
            IF @RedeemPoints > @have BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Only ' + FORMAT(@have, '0') + N' points are available.' AS Error; RETURN; END;
            IF @have < @loyMin BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can be used from ' + CAST(@loyMin AS NVARCHAR(10)) + N' points on.' AS Error; RETURN; END;
            SET @redeemValue = ROUND(@RedeemPoints * @loyValue, 2);
            DECLARE @billBefore DECIMAL(18,2) = (SELECT SUM(Amount) FROM @P);
            IF @redeemValue > ROUND(@billBefore * @loyMaxPct / 100, 2)
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can pay up to ' + FORMAT(@loyMaxPct, '0.##') + N'% of the bill (₹' + FORMAT(ROUND(@billBefore * @loyMaxPct / 100, 2), '0.00') + N').' AS Error; RETURN; END;
            -- spread over the lines by amount; the last line takes the paise left over
            UPDATE @P SET Amount = Amount - ROUND(CAST(Amount AS DECIMAL(38,18)) * @redeemValue / @billBefore, 2);
            UPDATE @P SET Amount = Amount - (@redeemValue - (@billBefore - (SELECT SUM(Amount) FROM @P))) WHERE Seq = (SELECT MAX(Seq) FROM @P);
            UPDATE @P SET Taxable = ROUND(CAST(Amount AS DECIMAL(38,18)) * 100 / (100 + Gst), 2);
            UPDATE @P SET GstAmt = Amount - Taxable;
        END

        DECLARE @mrpAmt DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * UnitMrp), 2) FROM @P);
        DECLARE @lineTotal DECIMAL(18,2) = (SELECT SUM(Amount) FROM @P);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@lineTotal, 0) ELSE @lineTotal END;
        DECLARE @taxable DECIMAL(18,2) = (SELECT SUM(Taxable) FROM @P), @gst DECIMAL(18,2) = (SELECT SUM(GstAmt) FROM @P);
        DECLARE @cgst DECIMAL(18,2) = ROUND(@gst / 2, 2);
        DECLARE @sgst DECIMAL(18,2) = @gst - @cgst;
        DECLARE @cost DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @P);

        -- payments: full payment, or the balance on credit for a credit customer
        DELETE @Pay WHERE Amount <= 0;
        DECLARE @tendered DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @nonCash DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay WHERE Method <> 'CASH'), 0);
        IF @nonCash > @net BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Card / UPI / bank amount is more than the bill.' AS Error; RETURN; END;
        DECLARE @change DECIMAL(18,2) = CASE WHEN @tendered - @net > 0 THEN @tendered - @net ELSE 0 END;
        IF @change > 0 UPDATE @Pay SET Amount = Amount - @change WHERE Seq = (SELECT MIN(Seq) FROM @Pay WHERE Method = 'CASH');   -- change returned from the cash given
        DECLARE @paid DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @due DECIMAL(18,2) = CASE WHEN @Hold = 1 THEN 0 ELSE @net - @paid END;
        IF @Hold = 0 AND @due > 0
        BEGIN
            IF @custFound = 0 OR @custCredit = 0
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'₹' + FORMAT(@due, '0.00') + N' is not paid. Only a credit customer can take a bill on credit.' AS Error; RETURN; END;
            IF @CanCredit = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'You do not have permission to bill on credit.' AS Error; RETURN; END;
            IF @custType IN ('CORPORATE', 'INSURANCE') AND LTRIM(RTRIM(ISNULL(@CreditRefNo, N''))) = N''
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, CASE WHEN @custType = 'INSURANCE' THEN N'Enter the policy / claim number for the insurance credit bill.' ELSE N'Enter the employee ID / authorisation number for the corporate credit bill.' END AS Error; RETURN; END;
            DECLARE @overdue DATETIME = (SELECT MIN(SaleDate) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED' AND BalanceDue > 0
                                           AND SaleDate < DATEADD(DAY, -ISNULL(@custDays, 30), CAST(@today AS DATETIME)));
            IF @overdue IS NOT NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'This customer has a credit bill of ' + FORMAT(@overdue, 'dd-MMM-yyyy', 'en-US') + N' unpaid beyond ' + CAST(ISNULL(@custDays, 30) AS NVARCHAR(10)) + N' credit days: collect it before new credit.' AS Error; RETURN; END;
            DECLARE @outstanding DECIMAL(18,2) = ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED'), 0);
            IF @outstanding + @due > @custLimit
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Credit limit ₹' + FORMAT(@custLimit, '0.00') + N' would be crossed (outstanding ₹' + FORMAT(@outstanding, '0.00') + N' + this bill ₹' + FORMAT(@due, '0.00') + N').' AS Error; RETURN; END;
        END

        -- header
        DECLARE @saleNo NVARCHAR(40) = NULL, @saleId INT;
        IF @Hold = 0 EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SALE', @DocDate = @today, @DocNo = @saleNo OUTPUT;
        IF ISNULL(@HoldId, 0) > 0
        BEGIN
            UPDATE dbo.PhSale SET SaleNo = @saleNo, SaleDate = GETDATE(), Status = CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, CustomerKind = @CustomerKind, PatientId = @PatientId,
                   CustomerId = @CustomerId, CustomerName = @CustomerName, Mobile = @Mobile, Email = @Email, Address = @Address, DoctorId = @DoctorId, DoctorName = @DoctorName,
                   DoctorRegNo = @DoctorRegNo, RxNo = @RxNo, RxDate = @RxDate, PriceType = @priceType, BillDiscPercent = @BillDiscPercent, MrpAmount = @mrpAmt,
                   DiscountAmount = @mrpAmt - @lineTotal, TaxableAmount = @taxable, CgstAmount = @cgst, SgstAmount = @sgst, RoundOff = @net - @lineTotal, NetAmount = @net,
                   PaidAmount = @paid, BalanceDue = @due, CostAmount = @cost, HoldLabel = @HoldLabel, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SaleId = @HoldId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'HOLD';
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'The held bill was already finished or discarded.' AS Error; RETURN; END;
            DELETE dbo.PhSaleDtl WHERE SaleId = @HoldId;
            SET @saleId = @HoldId;
        END
        ELSE
        BEGIN
            INSERT dbo.PhSale (CompanyId, BranchId, SaleNo, Status, CustomerKind, PatientId, CustomerId, CustomerName, Mobile, Email, Address,
                   DoctorId, DoctorName, DoctorRegNo, RxNo, RxDate, PriceType, BillDiscPercent, MrpAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, RoundOff,
                   NetAmount, PaidAmount, BalanceDue, CostAmount, HoldLabel, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @saleNo, CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, @CustomerKind, @PatientId, @CustomerId, @CustomerName, @Mobile, @Email, @Address,
                   @DoctorId, @DoctorName, @DoctorRegNo, @RxNo, @RxDate, @priceType, @BillDiscPercent, @mrpAmt, @mrpAmt - @lineTotal, @taxable, @cgst, @sgst, @net - @lineTotal,
                   @net, @paid, @due, @cost, @HoldLabel, @Remarks, @UserId);
            SET @saleId = CAST(SCOPE_IDENTITY() AS INT);
        END

        UPDATE dbo.PhSale SET StoreId = @StoreId, ConsultationId = @ConsultationId, CreditRefNo = NULLIF(LTRIM(RTRIM(@CreditRefNo)), N''),
               LoyaltyRedeemPoints = CASE WHEN @Hold = 1 THEN 0 ELSE @RedeemPoints END, LoyaltyRedeemValue = CASE WHEN @Hold = 1 THEN 0 ELSE @redeemValue END
         WHERE SaleId = @saleId;
        DECLARE @ps INT = (SELECT MIN(Seq) FROM @P), @dtl INT;
        DECLARE @pItem INT, @pBatch INT, @pQty DECIMAL(18,6), @pReg BIT, @pSch VARCHAR(10);
        WHILE @ps IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleDtl (SaleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, DiscPercent, Amount, GstPercent, TaxableAmount, GstAmount, UnitCost, DaysSupply)
            SELECT @saleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, Disc, Amount, Gst, Taxable, GstAmt, Cost, DaysSupply FROM @P WHERE Seq = @ps;
            SET @dtl = CAST(SCOPE_IDENTITY() AS INT);
            IF @Hold = 0
            BEGIN
                SELECT @pItem = ItemId, @pBatch = BatchId, @pQty = Qty, @pReg = Register, @pSch = Schedule FROM @P WHERE Seq = @ps;
                SET @pQty = -@pQty;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @pBatch, @Qty = @pQty, @DocType = 'SALE', @DocId = @saleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = @neg, @StoreId = @StoreId;
                IF @pReg = 1
                    INSERT dbo.PhScheduleRegister (CompanyId, BranchId, SaleId, SaleDtlId, EntryDate, ScheduleCode, ItemId, BatchId, Qty, PatientName, PatientAddress, PrescriberName, PrescriberRegNo, RxNo, DispensedBy)
                    VALUES (@CompanyId, @BranchId, @saleId, @dtl, GETDATE(), @pSch, @pItem, @pBatch, -@pQty, @CustomerName, @Address, @DoctorName, @DoctorRegNo, @RxNo, @UserId);
            END
            SET @ps = (SELECT MIN(Seq) FROM @P WHERE Seq > @ps);
        END
        IF @Hold = 1
        BEGIN
            COMMIT;
            SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, CAST(NULL AS NVARCHAR(40)) AS SaleNo, CAST(NULL AS NVARCHAR(50)) AS ReceiptNo,
                   @net AS NetAmount, CAST(0 AS DECIMAL(18,2)) AS Change, CAST(0 AS DECIMAL(18,2)) AS BalanceDue;
            RETURN;
        END

        -- money: like OPD / LAB (PaymentHeader / PaymentDetail, module PHR)
        DECLARE @patient INT = @PatientId;
        IF @patient IS NULL EXEC dbo.usp_Ph_WalkinPatient @CompanyId = @CompanyId, @BranchId = @BranchId, @PatientId = @patient OUTPUT;
        INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue,
               HeaderDiscountAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
        VALUES ('PHR', @saleId, @BranchId, @patient, @mrpAmt, @mrpAmt - @lineTotal, 'P', 0, 0, @net, @paid, @due, CASE WHEN @due > 0 THEN 'U' ELSE 'P' END,
               N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @cgst, @sgst, 0, @CompanyId, @net - @lineTotal);
        DECLARE @headerId INT = CAST(SCOPE_IDENTITY() AS INT), @receiptNo NVARCHAR(50) = NULL, @pd INT;
        IF @paid > 0
        BEGIN
            EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @receiptNo OUTPUT;
            DECLARE @py INT = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0), @pm VARCHAR(10), @pamt DECIMAL(18,2), @pref NVARCHAR(200);
            WHILE @py IS NOT NULL
            BEGIN
                SELECT @pm = Method, @pamt = Amount, @pref = Ref FROM @Pay WHERE Seq = @py;
                INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
                SELECT @headerId, PaymentMethodId, @pamt, @pref, CASE WHEN @pm = 'UPI' THEN @pref END, CASE WHEN @pm = 'CARD' THEN RIGHT(@pref, 4) END, CASE WHEN @pm = 'CHEQUE' THEN @pref END,
                       GETDATE(), N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @receiptNo, @CompanyId
                  FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @pm;
                SET @pd = CAST(SCOPE_IDENTITY() AS INT);
                EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRCPT', @RefId = @pd, @UserId = @UserId;
                SET @py = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0 AND Seq > @py);
            END
        END
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SALE', @RefId = @saleId, @UserId = @UserId;

        -- OPD prescription: what was prescribed and what was given (SQLScripts/2406)
        IF @ConsultationId IS NOT NULL AND ISJSON(@RxLines) = 1
            INSERT dbo.PhSaleRx (SaleId, ConsultationId, Seq, MedicationId, MedicationName, GenericId, Dose, Frequency, Instructions, Status, ItemId, Reason)
            SELECT @saleId, @ConsultationId, j.Seq, j.MedicationId, LEFT(ISNULL(j.MedicationName, N''), 200), j.GenericId, LEFT(j.Dose, 50), LEFT(j.Frequency, 50), LEFT(j.Instructions, 100),
                   CASE WHEN j.Status = 'DISPENSED' THEN 'DISPENSED' ELSE 'NOT_DISPENSED' END, j.ItemId, LEFT(NULLIF(LTRIM(RTRIM(j.Reason)), N''), 200)
              FROM OPENJSON(@RxLines) WITH (Seq INT, MedicationId INT, MedicationName NVARCHAR(400), GenericId INT, Dose NVARCHAR(100), Frequency NVARCHAR(100),
                                            Instructions NVARCHAR(200), Status VARCHAR(20), ItemId INT, Reason NVARCHAR(400)) j;
        -- clinical alerts shown at the counter and the reason to go ahead
        IF ISJSON(@Alerts) = 1
            INSERT dbo.PhSaleClinicalAlert (SaleId, Kind, Severity, Message, Reason, OverriddenBy)
            SELECT @saleId, LEFT(j.Kind, 15), LEFT(j.Severity, 10), LEFT(ISNULL(j.Message, N''), 500), LEFT(j.Reason, 300), @UserId
              FROM OPENJSON(@Alerts) WITH (Kind VARCHAR(20), Severity VARCHAR(20), Message NVARCHAR(1000), Reason NVARCHAR(600)) j;
        -- loyalty: points used, then points earned on what was paid for
        IF @loyOn = 1 AND @CustomerKind IN ('PATIENT', 'CUSTOMER')
        BEGIN
            IF @RedeemPoints > 0
                INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Kind, Points, SaleId, Remarks, CreatedBy)
                VALUES (@CompanyId, @BranchId, @PatientId, @CustomerId, 'REDEEM', -@RedeemPoints, @saleId, N'Used on bill ' + @saleNo + N' (₹' + FORMAT(@redeemValue, '0.00') + N')', @UserId);
            SET @earned = FLOOR(@net * @loyEarn / 100);
            IF @earned > 0
            BEGIN
                INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Kind, Points, SaleId, ExpiresOn, Remarks, CreatedBy)
                VALUES (@CompanyId, @BranchId, @PatientId, @CustomerId, 'EARN', @earned, @saleId, CASE WHEN @loyExpiry > 0 THEN DATEADD(DAY, @loyExpiry, @today) END,
                        N'Earned on bill ' + @saleNo, @UserId);
                UPDATE dbo.PhSale SET LoyaltyEarnedPoints = @earned WHERE SaleId = @saleId;
            END
        END
        -- refill reminders: lines with days of supply, for a buyer with a mobile number
        IF ISNULL((SELECT TOP 1 PharmacyRefillReminderEnabled FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) = 1
           AND @Mobile LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        BEGIN
            DECLARE @before INT = ISNULL((SELECT TOP 1 PharmacyRefillReminderDaysBefore FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 2);
            INSERT dbo.PhRefillReminder (CompanyId, BranchId, SaleId, SaleDtlId, ItemId, PatientId, CustomerId, Name, Mobile, RunOutDate, RemindOn)
            SELECT @CompanyId, @BranchId, @saleId, MIN(d.SaleDtlId), d.ItemId, @PatientId, @CustomerId, @CustomerName, @Mobile,
                   DATEADD(DAY, MAX(d.DaysSupply), @today),
                   CASE WHEN DATEADD(DAY, MAX(d.DaysSupply) - @before, @today) > @today THEN DATEADD(DAY, MAX(d.DaysSupply) - @before, @today) ELSE DATEADD(DAY, 1, @today) END
              FROM dbo.PhSaleDtl d WHERE d.SaleId = @saleId AND d.DaysSupply > 0 GROUP BY d.ItemId;
        END
        COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, @saleNo AS SaleNo, @receiptNo AS ReceiptNo, @net AS NetAmount, @change AS Change, @due AS BalanceDue,
               @earned AS PointsEarned, @RedeemPoints AS PointsRedeemed;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── sale return: + batch on the pack checked against the bill line; loyalty taken back (SQLScripts/2406) ──
-- @Lines: [{ "SaleDtlId", "Qty", "BatchNo" (as on the pack; optional) }]
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_SaveReturn
    @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @ReasonId INT, @RefundMode VARCHAR(10), @RefundRef NVARCHAR(4000) = NULL, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @days INT = 7, @loose BIT = 0, @roundOff BIT = 1;
    SELECT TOP 1 @days = PharmacySaleReturnDays, @loose = PharmacyLooseReturnAllowed, @roundOff = PharmacyRoundOffBill FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    DECLARE @In TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, Qty DECIMAL(18,6), BatchNo NVARCHAR(60));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.SaleDtlId'), JSON_VALUE(value, '$.Qty'), NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.BatchNo'))), N'') FROM OPENJSON(@Lines);
    DECLARE @R TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, ItemId INT, BatchId INT, Q DECIMAL(18,6), Amt DECIMAL(18,2), Tax DECIMAL(18,2), G DECIMAL(18,2), UnitCost DECIMAL(12,4));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @balance DECIMAL(18,2);
        DECLARE @saleStore INT = (SELECT StoreId FROM dbo.PhSale WHERE SaleId = @SaleId AND BranchId = @BranchId);
        SELECT @status = Status, @saleDate = SaleDate, @balance = BalanceDue FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'POSTED' BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a saved, not cancelled, bill can take a return.' AS Error; RETURN; END;
        IF DATEADD(DAY, @days, CAST(@saleDate AS DATE)) < @today
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Returns are taken within ' + CAST(@days AS NVARCHAR(10)) + N' days of the bill; this bill is of ' + FORMAT(@saleDate, 'dd-MMM-yyyy', 'en-US') + N'.' AS Error; RETURN; END;

        DECLARE @L TABLE (SaleDtlId INT PRIMARY KEY, ItemId INT, ItemName NVARCHAR(200), ScheduleCode VARCHAR(10), BatchId INT, ExpiryDate DATE, ConversionQty INT,
                          IsReturnable BIT, IsColdChain BIT, Qty DECIMAL(14,3), Amount DECIMAL(14,2), TaxableAmount DECIMAL(14,2), UnitCost DECIMAL(12,4), ReturnedQty DECIMAL(14,3));
        INSERT @L SELECT d.SaleDtlId, d.ItemId, i.ItemName, i.ScheduleCode, d.BatchId, b.ExpiryDate, i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.Amount, d.TaxableAmount, d.UnitCost, d.ReturnedQty
                    FROM dbo.PhSaleDtl d WITH (UPDLOCK) JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
                   WHERE d.SaleId = @SaleId AND d.SaleDtlId IN (SELECT SaleDtlId FROM @In);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @dtlId INT, @q DECIMAL(18,6), @found BIT, @nm NVARCHAR(200), @sch VARCHAR(10), @ret BIT, @cold BIT,
                @exp DATE, @lq DECIMAL(14,3), @rq DECIMAL(14,3), @conv INT, @lamt DECIMAL(14,2), @ltax DECIMAL(14,2), @amt DECIMAL(18,2), @tax DECIMAL(18,2);
        WHILE @seq IS NOT NULL
        BEGIN
            DECLARE @packBatch NVARCHAR(60) = NULL;
            SELECT @dtlId = SaleDtlId, @q = Qty, @packBatch = BatchNo FROM @In WHERE Seq = @seq;
            SET @found = 0;
            SELECT @found = 1, @nm = ItemName, @sch = ScheduleCode, @ret = IsReturnable, @cold = IsColdChain, @exp = ExpiryDate, @lq = Qty, @rq = ReturnedQty, @conv = ConversionQty,
                   @lamt = Amount, @ltax = TaxableAmount FROM @L WHERE SaleDtlId = @dtlId;
            IF @found = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'An item is not on this bill.' AS Error; RETURN; END;
            IF @ret = 0 OR @sch IN ('X', 'NDPS') BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is not returnable.' AS Error; RETURN; END;
            -- SQLScripts/2406: the batch printed on the pack brought back must be the batch sold on this bill
            IF @packBatch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @L l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId WHERE l.SaleDtlId = @dtlId AND UPPER(b.BatchNo) = UPPER(@packBatch))
            BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': batch ' + @packBatch + N' on the pack is not the batch sold on this bill (' +
                       (SELECT b.BatchNo FROM @L l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId WHERE l.SaleDtlId = @dtlId) + N'). Not taken back.' AS Error; RETURN; END;
            IF @cold = 1 BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is a cold-chain item and cannot be taken back.' AS Error; RETURN; END;
            IF @exp <= @today BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': the batch has expired.' AS Error; RETURN; END;
            IF @q > @lq - @rq BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': only ' + FORMAT(@lq - @rq, '0.##') + N' can still be returned.' AS Error; RETURN; END;
            IF @loose = 0 AND @q % @conv <> 0
            BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': loose / cut strips are not taken back (full packs of ' + CAST(@conv AS NVARCHAR(10)) + N').' AS Error; RETURN; END;
            SET @amt = ROUND(CAST(@lamt AS DECIMAL(38,18)) * @q / @lq, 2);
            SET @tax = ROUND(CAST(@ltax AS DECIMAL(38,18)) * @q / @lq, 2);
            INSERT @R SELECT @seq, @dtlId, ItemId, BatchId, @q, @amt, @tax, @amt - @tax, UnitCost FROM @L WHERE SaleDtlId = @dtlId;
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END
        DECLARE @amount DECIMAL(18,2) = (SELECT SUM(Amt) FROM @R), @taxable DECIMAL(18,2) = (SELECT SUM(Tax) FROM @R), @gst DECIMAL(18,2) = (SELECT SUM(G) FROM @R);
        DECLARE @cost DECIMAL(18,2) = (SELECT SUM(ROUND(CAST(UnitCost AS DECIMAL(38,18)) * Q, 2)) FROM @R);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@amount, 0) ELSE @amount END;
        DECLARE @adjusted DECIMAL(18,2) = CASE WHEN @net < @balance THEN @net ELSE @balance END;
        DECLARE @refund DECIMAL(18,2) = @net - @adjusted;
        SET @RefundMode = UPPER(@RefundMode);
        IF @refund > 0 AND ISNULL(@RefundMode, '') NOT IN ('CASH', 'CARD', 'UPI', 'NEFT', 'CHEQUE')
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Pick how the money is paid back.' AS Error; RETURN; END;
        IF @refund = 0 SET @RefundMode = 'ADJUST';

        DECLARE @no NVARCHAR(40), @refundId INT = NULL, @cnId INT, @rid INT;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SRET', @DocDate = @today, @DocNo = @no OUTPUT;
        IF @refund > 0
        BEGIN
            -- money paid back is recorded like an OPD / LAB partial cancellation: BillCancellation (P) + BillRefund
            INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
            VALUES ('PHR', @SaleId, N'CN-PHR/' + @no, 'P', GETDATE(), @net, 0, N'Sale return ' + @no + CASE WHEN LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' THEN N'' ELSE N': ' + @Remarks END, 'C', @UserId, GETDATE(), 1);
            SET @cnId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
            VALUES (@cnId, 'PHR', @SaleId, @refund, @RefundMode, GETDATE(), @RefundRef, N'Pharmacy sale return ' + @no, 'P', @UserId, GETDATE(), 1);
            SET @refundId = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhSaleReturn (CompanyId, BranchId, ReturnNo, SaleId, ReasonId, RefundMode, RefundRef, TaxableAmount, GstAmount, RoundOff, NetAmount, AdjustedAmount, RefundAmount, CostAmount, RefundId, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @SaleId, @ReasonId, @RefundMode, @RefundRef, @taxable, @gst, @net - @amount, @net, @adjusted, @refund, @cost, @refundId, @Remarks, @UserId);
        SET @rid = CAST(SCOPE_IDENTITY() AS INT);
        DECLARE @rs INT = (SELECT MIN(Seq) FROM @R), @rBatch INT;
        WHILE @rs IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleReturnDtl (ReturnId, SaleDtlId, ItemId, BatchId, Qty, Amount, TaxableAmount, GstAmount, UnitCost)
            SELECT @rid, SaleDtlId, ItemId, BatchId, Q, Amt, Tax, G, UnitCost FROM @R WHERE Seq = @rs;
            SELECT @dtlId = SaleDtlId, @q = Q, @rBatch = BatchId FROM @R WHERE Seq = @rs;
            UPDATE dbo.PhSaleDtl SET ReturnedQty = ReturnedQty + @q WHERE SaleDtlId = @dtlId;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @rBatch, @Qty = @q, @DocType = 'SRET', @DocId = @rid, @DocNo = @no, @UserId = @UserId, @AllowNegative = 1,
                 @StoreId = @saleStore;
            SET @rs = (SELECT MIN(Seq) FROM @R WHERE Seq > @rs);
        END
        UPDATE dbo.PhSale SET ReturnedAmount = ReturnedAmount + @net, BalanceDue = BalanceDue - @adjusted, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId),
               PaymentStatus = CASE WHEN (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId) > 0 THEN 'U' ELSE 'P' END,
               LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
         WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRET', @RefId = @rid, @UserId = @UserId;
        -- loyalty (SQLScripts/2406): the points earned on the bill are taken back in proportion to the value returned
        DECLARE @earnedOnBill DECIMAL(12,2), @billNet DECIMAL(18,2), @lp INT, @lc INT;
        SELECT @earnedOnBill = LoyaltyEarnedPoints, @billNet = NetAmount, @lp = PatientId, @lc = CustomerId FROM dbo.PhSale WHERE SaleId = @SaleId;
        IF ISNULL(@earnedOnBill, 0) > 0 AND @billNet > 0 AND (@lp IS NOT NULL OR @lc IS NOT NULL)
        BEGIN
            DECLARE @back DECIMAL(12,2) = CEILING(@earnedOnBill * @net / @billNet);
            DECLARE @alreadyBack DECIMAL(12,2) = ISNULL((SELECT -SUM(Points) FROM dbo.PhLoyaltyLedger WHERE SaleId = @SaleId AND Kind = 'REVERSE'), 0);
            IF @back > @earnedOnBill - @alreadyBack SET @back = @earnedOnBill - @alreadyBack;
            IF @back > 0
                INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Kind, Points, SaleId, ReturnId, Remarks, CreatedBy)
                VALUES (@CompanyId, @BranchId, @lp, @lc, 'REVERSE', -@back, @SaleId, @rid, N'Return ' + @no, @UserId);
        END
        IF @refundId IS NOT NULL EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SREFUND', @RefId = @refundId, @UserId = @UserId;
        COMMIT;
        SELECT @rid AS Id, @no AS DocNo, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT 0 AS Id, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── Pharmacy Customer master: + credit days (SQLScripts/2406) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhCustomer_GetList
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CustomerId, CustomerName, Mobile, CustomerType, Email, Gstin, Address, CreditAllowed, CreditLimit, CreditDays, SchemeId, IsActive FROM dbo.PhCustomer
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
    @SchemeId INT = NULL,
    @CreditDays INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        IF ISNULL(@Id, 0) = 0
        BEGIN
            INSERT dbo.PhCustomer (CompanyId, CustomerName, Mobile, CustomerType, Email, Gstin, Address, CreditAllowed, CreditLimit, SchemeId, IsActive, CreatedBy, CreditDays)
            VALUES (@CompanyId, @CustomerName, @Mobile, @CustomerType, @Email, @Gstin, @Address, @CreditAllowed, @CreditLimit, @SchemeId, @IsActive, @UserId, ISNULL(@CreditDays, 30));
            SET @Id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            UPDATE dbo.PhCustomer SET CustomerName = @CustomerName, Mobile = @Mobile, CustomerType = @CustomerType, Email = @Email, Gstin = @Gstin, Address = @Address, CreditAllowed = @CreditAllowed, CreditLimit = @CreditLimit, SchemeId = @SchemeId, CreditDays = ISNULL(@CreditDays, CreditDays), IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
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

-- ── pages ────────────────────────────────────────────────────────────────────────────────────────────────
-- Master > Pharmacy: OPD Medicine Mapping, Drug Interaction (next to the other pharmacy masters);
-- POS endpoints (VIEW): RxList, RxLines, ClinicalCheck, Loyalty; refill reminder log (Pharmacy > Sales)
DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT, @code NVARCHAR(100), @title NVARCHAR(150), @act NVARCHAR(100), @save NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE @M TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Act NVARCHAR(100), SaveAct NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @M VALUES (N'MASTER.PH_RXMAP', N'OPD Medicine Mapping', N'RxMap', N'SaveRxMap', 150, N'bi bi-link-45deg me-2'),
                 (N'MASTER.PH_INTERACTIONS', N'Drug Interaction', N'Interactions', N'SaveInteraction', 160, N'bi bi-exclamation-diamond me-2');
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = pm.Menu_ID FROM dbo.PageMaster pm WHERE pm.Page_Code = 'MASTER.PH_DISCOUNTS' AND pm.CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE m CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Act, SaveAct, Sort, Icon FROM @M;
        OPEN m; FETCH NEXT FROM m INTO @code, @title, @act, @save, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = N'PharmacyMasters', @Action = @act,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PharmacyMasters', @Action = @act, @Source = 'SEED';
            SET @ctl = NULL;
            EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Add / edit', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PharmacyMasters', @Action = @save, @Source = 'SEED';
            FETCH NEXT FROM m INTO @code, @title, @act, @save, @sort, @icon;
        END
        CLOSE m; DEALLOCATE m;
    END

    SET @page = NULL; SET @view = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'PHARMACY.POS' AND CompanyId = @co;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhSales', @Action = N'RxList', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhSales', @Action = N'RxLines', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhSales', @Action = N'ClinicalCheck', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhSales', @Action = N'Loyalty', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2406 applied: Pharmacy OPD Rx link, clinical checks, loyalty, refill reminders, credit reference, batch-checked returns.';
GO
