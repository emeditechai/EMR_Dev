-- ====================================================================================================
-- Script: 99_seed_lab_masters_data.sql
-- Description: Seeds standard Indian clinical laboratory data into:
--              1. dbo.LabUnitMaster
--              2. dbo.LabTestCategoryMaster
--              3. dbo.LabTestSubCategoryMaster
--              4. dbo.LabSampleTypeMaster
--              5. dbo.LabTestMethodMaster
-- ====================================================================================================

-- ── 1. SEED LAB UNIT MASTER ─────────────────────────────────────────────────────────────────────────
PRINT 'Seeding dbo.LabUnitMaster...';

DECLARE @Units TABLE (
    Unit_Name NVARCHAR(150),
    Unit_Symbol NVARCHAR(50),
    Conversion_Factor DECIMAL(18,6),
    Display_Order INT
);

INSERT INTO @Units (Unit_Name, Unit_Symbol, Conversion_Factor, Display_Order) VALUES
('Milligrams per Deciliter', 'mg/dL', 1.0, 1),
('Grams per Deciliter', 'g/dL', 1.0, 2),
('Millimoles per Liter', 'mmol/L', 1.0, 3),
('Micromoles per Liter', 'μmol/L', 1.0, 4),
('International Units per Liter', 'IU/L', 1.0, 5),
('Units per Liter', 'U/L', 1.0, 6),
('Micrograms per Deciliter', 'μg/dL', 1.0, 7),
('Nanograms per Milliliter', 'ng/mL', 1.0, 8),
('Picograms per Milliliter', 'pg/mL', 1.0, 9),
('Micro International Units per Milliliter', 'μIU/mL', 1.0, 10),
('Cells per Cubic Millimeter', 'cells/cu.mm', 1.0, 11),
('Thousands per Cubic Millimeter', '10^3/μL', 1.0, 12),
('Millions per Cubic Millimeter', '10^6/μL', 1.0, 13),
('Percentage', '%', 1.0, 14),
('Millimeters per Hour', 'mm/hr', 1.0, 15),
('Milliequivalents per Liter', 'mEq/L', 1.0, 16),
('Seconds', 'sec', 1.0, 17),
('Index / Ratio', 'Ratio', 1.0, 18),
('Micrograms per Milliliter', 'μg/mL', 1.0, 19),
('Femtoliters', 'fL', 1.0, 20);

DECLARE @UName NVARCHAR(150), @USymbol NVARCHAR(50), @CFactor DECIMAL(18,6), @UOrder INT;
DECLARE curUnits CURSOR FOR SELECT Unit_Name, Unit_Symbol, Conversion_Factor, Display_Order FROM @Units;
OPEN curUnits;
FETCH NEXT FROM curUnits INTO @UName, @USymbol, @CFactor, @UOrder;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster WHERE LOWER(Unit_Name) = LOWER(@UName))
    BEGIN
        DECLARE @NextUnitId INT;
        DECLARE @GenUnitCode NVARCHAR(50);
        SELECT @NextUnitId = ISNULL(MAX(Unit_ID), 0) + 1 FROM dbo.LabUnitMaster;
        SET @GenUnitCode = 'UNT' + RIGHT('0000' + CAST(@NextUnitId AS NVARCHAR(10)), 4);

        INSERT INTO dbo.LabUnitMaster (CompanyId, BranchId, Unit_Name, Unit_Code, Unit_Symbol, Conversion_Factor, Display_Order, Status, CreatedDate)
        VALUES (1, 1, @UName, @GenUnitCode, @USymbol, @CFactor, @UOrder, 1, GETDATE());
    END
    FETCH NEXT FROM curUnits INTO @UName, @USymbol, @CFactor, @UOrder;
END
CLOSE curUnits;
DEALLOCATE curUnits;
PRINT 'dbo.LabUnitMaster seeded successfully.';
GO

-- ── 2. SEED LAB TEST CATEGORY MASTER ─────────────────────────────────────────────────────────────────
PRINT 'Seeding dbo.LabTestCategoryMaster...';

-- Get Pathology department ID if available
DECLARE @PathDeptId INT;
SELECT TOP 1 @PathDeptId = DeptId FROM dbo.DepartmentMaster WHERE DeptName LIKE '%Pathology%' OR DeptName LIKE '%Lab%' OR DeptCode LIKE '%PATH%';
IF @PathDeptId IS NULL SET @PathDeptId = 1;

DECLARE @Categories TABLE (
    Category_Name NVARCHAR(150),
    Display_Order INT
);

INSERT INTO @Categories (Category_Name, Display_Order) VALUES
('Clinical Biochemistry', 1),
('Hematology & Hemostasis', 2),
('Clinical Pathology & Urinalysis', 3),
('Microbiology & Serology', 4),
('Endocrinology & Immunology', 5),
('Histopathology & Cytopathology', 6),
('Molecular Diagnostics & RT-PCR', 7);

DECLARE @CatName NVARCHAR(150), @CatOrder INT;
DECLARE curCat CURSOR FOR SELECT Category_Name, Display_Order FROM @Categories;
OPEN curCat;
FETCH NEXT FROM curCat INTO @CatName, @CatOrder;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster WHERE LOWER(Category_Name) = LOWER(@CatName))
    BEGIN
        DECLARE @NextCatId INT;
        DECLARE @GenCatCode NVARCHAR(50);
        SELECT @NextCatId = ISNULL(MAX(Category_ID), 0) + 1 FROM dbo.LabTestCategoryMaster;
        SET @GenCatCode = 'LCAT' + RIGHT('0000' + CAST(@NextCatId AS NVARCHAR(10)), 4);

        INSERT INTO dbo.LabTestCategoryMaster (CompanyId, BranchId, Department_ID, Category_Name, Category_Code, Display_Order, Status, CreatedDate)
        VALUES (1, 1, @PathDeptId, @CatName, @GenCatCode, @CatOrder, 1, GETDATE());
    END
    FETCH NEXT FROM curCat INTO @CatName, @CatOrder;
END
CLOSE curCat;
DEALLOCATE curCat;
PRINT 'dbo.LabTestCategoryMaster seeded successfully.';
GO

-- ── 3. SEED LAB TEST SUB CATEGORY MASTER ─────────────────────────────────────────────────────────────
PRINT 'Seeding dbo.LabTestSubCategoryMaster...';

DECLARE @SubCategories TABLE (
    Category_Name NVARCHAR(150),
    SubCategory_Name NVARCHAR(150),
    Display_Order INT
);

INSERT INTO @SubCategories (Category_Name, SubCategory_Name, Display_Order) VALUES
('Clinical Biochemistry', 'Lipid Profile', 1),
('Clinical Biochemistry', 'Liver Function Test (LFT)', 2),
('Clinical Biochemistry', 'Renal Function Test (RFT / KFT)', 3),
('Clinical Biochemistry', 'Diabetic Profile & HbA1c', 4),
('Clinical Biochemistry', 'Cardiac Markers & Enzymes', 5),
('Hematology & Hemostasis', 'Complete Blood Count (CBC) & ESR', 1),
('Hematology & Hemostasis', 'Coagulation Profile (PT/INR, APTT)', 2),
('Hematology & Hemostasis', 'Anemia & Iron Profile', 3),
('Clinical Pathology & Urinalysis', 'Routine Urine & Microscopic Examination', 1),
('Clinical Pathology & Urinalysis', 'Stool Routine & Occult Blood', 2),
('Clinical Pathology & Urinalysis', 'Semen Analysis', 3),
('Microbiology & Serology', 'Blood & Urine Culture Sensitivity', 1),
('Microbiology & Serology', 'Viral Markers (HBsAg, HCV, HIV, VDRL)', 2),
('Microbiology & Serology', 'Typhoid & Dengue Serology (Widal, NS1, IgM)', 3),
('Endocrinology & Immunology', 'Thyroid Profile (T3, T4, TSH)', 1),
('Endocrinology & Immunology', 'Vitamin & Bone Markers (Vit D3, Vit B12)', 2),
('Endocrinology & Immunology', 'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', 3),
('Molecular Diagnostics & RT-PCR', 'RT-PCR Viral Panel', 1);

DECLARE @TCatName NVARCHAR(150), @SubCatName NVARCHAR(150), @SubCatOrder INT;
DECLARE curSubCat CURSOR FOR SELECT Category_Name, SubCategory_Name, Display_Order FROM @SubCategories;
OPEN curSubCat;
FETCH NEXT FROM curSubCat INTO @TCatName, @SubCatName, @SubCatOrder;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @ResolvedCatId INT;
    SELECT TOP 1 @ResolvedCatId = Category_ID FROM dbo.LabTestCategoryMaster WHERE LOWER(Category_Name) = LOWER(@TCatName);

    IF @ResolvedCatId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.LabTestSubCategoryMaster 
        WHERE Category_ID = @ResolvedCatId AND LOWER(SubCategory_Name) = LOWER(@SubCatName)
    )
    BEGIN
        DECLARE @NextSubId INT;
        DECLARE @GenSubCode NVARCHAR(50);
        SELECT @NextSubId = ISNULL(MAX(SubCategory_ID), 0) + 1 FROM dbo.LabTestSubCategoryMaster;
        SET @GenSubCode = 'LSUBCAT' + RIGHT('0000' + CAST(@NextSubId AS NVARCHAR(10)), 4);

        INSERT INTO dbo.LabTestSubCategoryMaster (CompanyId, BranchId, Category_ID, SubCategory_Name, SubCategory_Code, Display_Order, Status, CreatedDate)
        VALUES (1, 1, @ResolvedCatId, @SubCatName, @GenSubCode, @SubCatOrder, 1, GETDATE());
    END
    FETCH NEXT FROM curSubCat INTO @TCatName, @SubCatName, @SubCatOrder;
END
CLOSE curSubCat;
DEALLOCATE curSubCat;
PRINT 'dbo.LabTestSubCategoryMaster seeded successfully.';
GO

-- ── 4. SEED LAB SAMPLE TYPE MASTER ────────────────────────────────────────────────────────────────────
PRINT 'Seeding dbo.LabSampleTypeMaster...';

DECLARE @Samples TABLE (
    Sample_Name NVARCHAR(150),
    Container_Type NVARCHAR(100),
    Volume_Value DECIMAL(10,2),
    Unit_Symbol NVARCHAR(50),
    Storage_Temp NVARCHAR(50),
    Rejection_Criteria NVARCHAR(500),
    Display_Order INT
);

INSERT INTO @Samples (Sample_Name, Container_Type, Volume_Value, Unit_Symbol, Storage_Temp, Rejection_Criteria, Display_Order) VALUES
('Whole Blood (EDTA)', 'Purple Top (EDTA)', 3.0, 'mL', '2 to 8', 'Clotted or hemolyzed blood sample will be rejected.', 1),
('Serum', 'Yellow Top (SST)', 5.0, 'mL', '2 to 8', 'Grossly hemolyzed or lipemic serum sample.', 2),
('Plain Blood / Serum', 'Red Top Vial', 5.0, 'mL', '2 to 8', 'Insufficient volume or hemolyzed sample.', 3),
('Citrated Plasma', 'Blue Top (Sodium Citrate)', 2.7, 'mL', '2 to 8', 'Underfilled or overfilled tube; clotted plasma.', 4),
('Fluoride Plasma', 'Grey Top (Sodium Fluoride)', 2.0, 'mL', '2 to 8', 'Clotted or hemolyzed sample.', 5),
('Heparinized Whole Blood', 'Green Top (Heparin)', 3.0, 'mL', '2 to 8', 'Clotted blood sample.', 6),
('Random Urine Sample', 'Sterile Container / Swab', 30.0, 'mL', '2 to 8', 'Unlabeled container or leaked specimen container.', 7),
('Mid-Stream Clean Catch Urine', 'Sterile Container / Swab', 50.0, 'mL', '2 to 8', 'Contaminated container without sterile cap.', 8),
('Throat / Nasopharyngeal Swab', 'Sterile Container / Swab', 1.0, 'Swab', '2 to 8', 'Dry swab or unapproved transport medium.', 9);

DECLARE @SName NVARCHAR(150), @CType NVARCHAR(100), @VVal DECIMAL(10,2), @USym NVARCHAR(50), @STemp NVARCHAR(50), @Rej NVARCHAR(500), @SOrder INT;
DECLARE curSmp CURSOR FOR SELECT Sample_Name, Container_Type, Volume_Value, Unit_Symbol, Storage_Temp, Rejection_Criteria, Display_Order FROM @Samples;
OPEN curSmp;
FETCH NEXT FROM curSmp INTO @SName, @CType, @VVal, @USym, @STemp, @Rej, @SOrder;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @ResolvedUnitId INT;
    SELECT TOP 1 @ResolvedUnitId = Unit_ID FROM dbo.LabUnitMaster WHERE LOWER(Unit_Symbol) = LOWER(@USym) OR LOWER(Unit_Name) = LOWER(@USym);

    IF NOT EXISTS (
        SELECT 1 FROM dbo.LabSampleTypeMaster 
        WHERE BranchId = 1 
          AND LOWER(Sample_Name) = LOWER(@SName)
          AND LOWER(Container_Type) = LOWER(@CType)
    )
    BEGIN
        DECLARE @NextSmpId INT;
        DECLARE @GenSmpCode NVARCHAR(50);
        SELECT @NextSmpId = ISNULL(MAX(Sample_Type_ID), 0) + 1 FROM dbo.LabSampleTypeMaster;
        SET @GenSmpCode = 'SMP' + RIGHT('0000' + CAST(@NextSmpId AS NVARCHAR(10)), 4);

        DECLARE @VReq NVARCHAR(50) = CAST(CAST(@VVal AS FLOAT) AS NVARCHAR(20)) + ' ' + @USym;

        INSERT INTO dbo.LabSampleTypeMaster 
        (CompanyId, BranchId, Sample_Name, Sample_Code, Container_Type, Volume_Value, Unit_ID, Volume_Unit, Volume_Required, Storage_Temperature, Rejection_Criteria, Display_Order, Status, CreatedDate)
        VALUES 
        (1, 1, @SName, @GenSmpCode, @CType, @VVal, @ResolvedUnitId, @USym, @VReq, @STemp, @Rej, @SOrder, 1, GETDATE());
    END
    FETCH NEXT FROM curSmp INTO @SName, @CType, @VVal, @USym, @STemp, @Rej, @SOrder;
END
CLOSE curSmp;
DEALLOCATE curSmp;
PRINT 'dbo.LabSampleTypeMaster seeded successfully.';
GO

-- ── 5. SEED LAB TEST METHOD MASTER ────────────────────────────────────────────────────────────────────
PRINT 'Seeding dbo.LabTestMethodMaster...';

DECLARE @PathDeptId2 INT;
SELECT TOP 1 @PathDeptId2 = DeptId FROM dbo.DepartmentMaster WHERE DeptName LIKE '%Pathology%' OR DeptName LIKE '%Lab%' OR DeptCode LIKE '%PATH%';
IF @PathDeptId2 IS NULL SET @PathDeptId2 = 1;

DECLARE @Methods TABLE (
    Method_Name NVARCHAR(150),
    Display_Order INT
);

INSERT INTO @Methods (Method_Name, Display_Order) VALUES
('Automated Electrical Impedance & Flow Cytometry', 1),
('Photometric / Spectrophotometry', 2),
('Enzyme-Linked Immunosorbent Assay (ELISA)', 3),
('Chemiluminescence Immunoassay (CLIA)', 4),
('Ion Selective Electrode (ISE)', 5),
('High Performance Liquid Chromatography (HPLC)', 6),
('Coagulometry / Turbidimetric Clot Detection', 7),
('Automated Microscopy & Flow Cell Digital Imaging', 8),
('Real-Time Polymerase Chain Reaction (RT-PCR)', 9),
('Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 10);

DECLARE @MName NVARCHAR(150), @MOrder INT;
DECLARE curMth CURSOR FOR SELECT Method_Name, Display_Order FROM @Methods;
OPEN curMth;
FETCH NEXT FROM curMth INTO @MName, @MOrder;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dbo.LabTestMethodMaster 
        WHERE Department_ID = @PathDeptId2 AND LOWER(Method_Name) = LOWER(@MName)
    )
    BEGIN
        DECLARE @NextMthId INT;
        DECLARE @GenMthCode NVARCHAR(50);
        SELECT @NextMthId = ISNULL(MAX(Method_ID), 0) + 1 FROM dbo.LabTestMethodMaster;
        SET @GenMthCode = 'MTH' + RIGHT('0000' + CAST(@NextMthId AS NVARCHAR(10)), 4);

        INSERT INTO dbo.LabTestMethodMaster (CompanyId, BranchId, Department_ID, Method_Name, Method_Code, Display_Order, Status, CreatedDate)
        VALUES (1, 1, @PathDeptId2, @MName, @GenMthCode, @MOrder, 1, GETDATE());
    END
    FETCH NEXT FROM curMth INTO @MName, @MOrder;
END
CLOSE curMth;
DEALLOCATE curMth;
PRINT 'dbo.LabTestMethodMaster seeded successfully.';
GO
