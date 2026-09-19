-- ============================================================
-- Script: 2072_seed_real_world_lab_reference_ranges.sql
-- Description: Seeds standardized real-world medical reference ranges
--              for numeric lab tests (CBC, Blood Sugars, HbA1c, Lipid Profile,
--              LFT, KFT/Creatinine, Thyroid Profile, Vitamin D3, B12, hs-CRP).
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

PRINT 'Seeding real-world standard medical reference ranges into dbo.LabReferenceRangeMaster...';

-- Temporary table to hold standard reference range definitions
DECLARE @RefSeed TABLE (
    TestName NVARCHAR(200),
    UnitSymbol NVARCHAR(50),
    IsCommonForAll BIT,
    AgeFrom DECIMAL(6,2),
    AgeTo DECIMAL(6,2),
    AgeUnit VARCHAR(20),
    Gender VARCHAR(20),
    Trimester VARCHAR(50),
    LowVal DECIMAL(18,4),
    HighVal DECIMAL(18,4),
    Remarks NVARCHAR(1000),
    RangeSource NVARCHAR(500)
);

INSERT INTO @RefSeed 
(TestName, UnitSymbol, IsCommonForAll, AgeFrom, AgeTo, AgeUnit, Gender, Trimester, LowVal, HighVal, Remarks, RangeSource)
VALUES
-- 1. Fasting Blood Sugar (FBS) - Common range (WHO / ADA Guidelines)
('Fasting Blood Sugar (FBS)', 'mg/dL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 70.0000, 99.0000, 'Normal Fasting Plasma Glucose: 70-99 mg/dL. Impaired Fasting Glucose (Pre-diabetes): 100-125 mg/dL. Diabetes Mellitus: >= 126 mg/dL (requires confirmation).', 'American Diabetes Association (ADA) / WHO Guidelines 2024'),

-- 2. Post Prandial Blood Sugar (PPBS) - Common range
('Post Prandial Blood Sugar (PPBS)', 'mg/dL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 70.0000, 139.0000, 'Normal 2-hr Post Prandial: < 140 mg/dL. Impaired Glucose Tolerance: 140-199 mg/dL. Diabetes: >= 200 mg/dL.', 'ADA Standard of Medical Care in Diabetes'),

-- 3. HbA1c (Glycated Hemoglobin) - Common range
('HbA1c (Glycated Hemoglobin)', '%', 1, 0, 150, 'Years', 'All', 'Not Applicable', 4.0000, 5.6000, 'Normal: < 5.7%. Increased Risk of Diabetes (Pre-diabetes): 5.7% - 6.4%. Diabetes Diagnostic Cut-off: >= 6.5%. Target for Diabetic Control: < 7.0%.', 'NGSP / IFCC / ADA Standards'),

-- 4. Serum Creatinine - Age & Gender specific ranges
('Serum Creatinine', 'mg/dL', 0, 0, 1, 'Years', 'All', 'Not Applicable', 0.2000, 0.4000, 'Infants / Neonates baseline creatinine levels.', 'Nelson Textbook of Pediatrics'),
('Serum Creatinine', 'mg/dL', 0, 1, 12, 'Years', 'All', 'Not Applicable', 0.3000, 0.7000, 'Pediatric reference range (Children 1-12 Yrs).', 'Harriet Lane Handbook'),
('Serum Creatinine', 'mg/dL', 0, 13, 150, 'Years', 'Male', 'Not Applicable', 0.7400, 1.3500, 'Adult Male normal range (Jaffe / Enzymatic Method).', 'Tietz Textbook of Clinical Chemistry'),
('Serum Creatinine', 'mg/dL', 0, 13, 150, 'Years', 'Female', 'Not Applicable', 0.5900, 1.0400, 'Adult Female normal range (Physiological GFR distinction).', 'Tietz Textbook of Clinical Chemistry'),

-- 5. Vitamin D3 (25-Hydroxy) - Common range
('Vitamin D3 (25-Hydroxy)', 'ng/mL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 30.0000, 100.0000, 'Deficiency: < 20 ng/mL. Insufficiency: 21 - 29 ng/mL. Sufficiency / Optimal: 30 - 100 ng/mL. Potential Toxicity: > 100 ng/mL.', 'Endocrine Society Clinical Practice Guidelines'),

-- 6. Vitamin B12 (Cyanocobalamin) - Common range
('Vitamin B12 (Cyanocobalamin)', 'pg/mL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 211.0000, 911.0000, 'Deficient: < 200 pg/mL (may present with neurological symptoms or megaloblastic anemia). Borderline: 200 - 300 pg/mL. Normal: 211 - 911 pg/mL.', 'Clinical Hematology Standards'),

-- 7. High Sensitivity C-Reactive Protein (hs-CRP) - Common range
('High Sensitivity C-Reactive Protein (hs-CRP)', 'mg/L', 1, 0, 150, 'Years', 'All', 'Not Applicable', 0.0000, 1.0000, 'Low Cardiovascular Risk: < 1.0 mg/L. Average Risk: 1.0 - 3.0 mg/L. High Risk: > 3.0 mg/L. Acute Inflammatory Response: > 10.0 mg/L.', 'AHA / CDC Risk Assessment Guidelines'),

-- 8. Thyroid Profile / TSH - Trimester & Age specific
('Thyroid Profile (T3, T4, TSH)', 'μIU/mL', 0, 0, 18, 'Years', 'All', 'Not Applicable', 0.7000, 5.9700, 'Pediatric & Adolescent TSH reference range.', 'Tietz Textbook of Laboratory Medicine'),
('Thyroid Profile (T3, T4, TSH)', 'μIU/mL', 0, 18, 150, 'Years', 'All', 'Not Applicable', 0.4500, 4.5000, 'Adult Non-pregnant normal range for TSH.', 'American Thyroid Association (ATA)'),
('Thyroid Profile (T3, T4, TSH)', 'μIU/mL', 0, 18, 50, 'Years', 'Female', '1st Trimester', 0.1000, 2.5000, 'First Trimester Pregnancy Specific TSH Range.', 'ATA Guidelines for Thyroid Disease in Pregnancy'),
('Thyroid Profile (T3, T4, TSH)', 'μIU/mL', 0, 18, 50, 'Years', 'Female', '2nd Trimester', 0.2000, 3.0000, 'Second Trimester Pregnancy Specific TSH Range.', 'ATA Guidelines for Thyroid Disease in Pregnancy'),
('Thyroid Profile (T3, T4, TSH)', 'μIU/mL', 0, 18, 50, 'Years', 'Female', '3rd Trimester', 0.3000, 3.0000, 'Third Trimester Pregnancy Specific TSH Range.', 'ATA Guidelines for Thyroid Disease in Pregnancy'),

-- 9. Complete Blood Count (CBC) / Hemoglobin - Age & Gender specific
('Complete Blood Count (CBC) with ESR', 'g/dL', 0, 0, 1, 'Years', 'All', 'Not Applicable', 11.0000, 18.0000, 'Infant hemoglobin normal baseline.', 'WHO Hemoglobin Concentrations'),
('Complete Blood Count (CBC) with ESR', 'g/dL', 0, 1, 12, 'Years', 'All', 'Not Applicable', 11.5000, 15.5000, 'Pediatric hemoglobin normal range.', 'WHO Hemoglobin Concentrations'),
('Complete Blood Count (CBC) with ESR', 'g/dL', 0, 13, 150, 'Years', 'Male', 'Not Applicable', 13.8000, 17.2000, 'Adult Male normal Hemoglobin range.', 'Wintrobe Clinical Hematology'),
('Complete Blood Count (CBC) with ESR', 'g/dL', 0, 13, 150, 'Years', 'Female', 'Not Applicable', 12.1000, 15.1000, 'Adult Female normal Hemoglobin range.', 'Wintrobe Clinical Hematology'),

-- 10. Lipid Profile Total - Common range
('Lipid Profile Total', 'mg/dL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 0.0000, 200.0000, 'Desirable Total Cholesterol: < 200 mg/dL. Borderline High: 200-239 mg/dL. High Risk: >= 240 mg/dL.', 'NCEP ATP III Guidelines'),

-- 11. Liver Function Test (LFT) - Common range
('Liver Function Test (LFT)', 'U/L', 1, 0, 150, 'Years', 'All', 'Not Applicable', 7.0000, 56.0000, 'Serum ALT / SGPT normal reference values.', 'Tietz Clinical Guide to Laboratory Tests'),

-- 12. Renal Function Test (KFT / RFT) - Common range
('Renal Function Test (KFT / RFT)', 'mg/dL', 1, 0, 150, 'Years', 'All', 'Not Applicable', 7.0000, 20.0000, 'Blood Urea Nitrogen (BUN) normal range.', 'Tietz Clinical Guide to Laboratory Tests');


-- Cursor execution to resolve Foreign Keys and insert data safely
DECLARE @tName NVARCHAR(200), @uSym NVARCHAR(50), @isCommon BIT, @ageFrom DECIMAL(6,2), @ageTo DECIMAL(6,2), @ageUnit VARCHAR(20), @gen VARCHAR(20), @tri VARCHAR(50), @lVal DECIMAL(18,4), @hVal DECIMAL(18,4), @rem NVARCHAR(1000), @src NVARCHAR(500);

DECLARE curSeed CURSOR FOR 
SELECT TestName, UnitSymbol, IsCommonForAll, AgeFrom, AgeTo, AgeUnit, Gender, Trimester, LowVal, HighVal, Remarks, RangeSource 
FROM @RefSeed;

OPEN curSeed;
FETCH NEXT FROM curSeed INTO @tName, @uSym, @isCommon, @ageFrom, @ageTo, @ageUnit, @gen, @tri, @lVal, @hVal, @rem, @src;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @TestId INT = NULL, @MethodId INT = NULL, @UnitId INT = NULL;

    -- Resolve Test_ID from LabInvestigationMaster
    SELECT TOP 1 
        @TestId = Test_ID,
        @MethodId = Method_ID,
        @UnitId = Unit_ID
    FROM dbo.LabInvestigationMaster 
    WHERE LOWER(LTRIM(RTRIM(Test_Name))) = LOWER(LTRIM(RTRIM(@tName))) 
      AND IsDeleted = 0;

    -- If unit symbol provided, try resolving matching unit ID
    IF @uSym IS NOT NULL AND @uSym <> ''
    BEGIN
        DECLARE @FoundUnitId INT;
        SELECT TOP 1 @FoundUnitId = Unit_ID 
        FROM dbo.LabUnitMaster 
        WHERE (LOWER(Unit_Symbol) = LOWER(@uSym) OR LOWER(Unit_Name) LIKE '%' + LOWER(@uSym) + '%')
          AND IsDeleted = 0;
        
        IF @FoundUnitId IS NOT NULL SET @UnitId = @FoundUnitId;
    END

    -- Insert if test found and range doesn't exist
    IF @TestId IS NOT NULL AND @UnitId IS NOT NULL
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM dbo.LabReferenceRangeMaster
            WHERE Test_ID = @TestId
              AND CompanyId = 1
              AND Age_From = @ageFrom
              AND Age_To = @ageTo
              AND Age_Unit = @ageUnit
              AND Gender = @gen
              AND ISNULL(Pregnancy_Trimester, 'Not Applicable') = ISNULL(@tri, 'Not Applicable')
              AND IsDeleted = 0
        )
        BEGIN
            INSERT INTO dbo.LabReferenceRangeMaster (
                CompanyId, Test_ID, Method_ID, Unit_ID, Is_Common_For_All,
                Age_From, Age_To, Age_Unit, Gender, Pregnancy_Trimester,
                Low_Value, High_Value, Special_Remarks, Range_Source,
                Effective_From, Effective_To, Status, IsDeleted, CreatedDate
            )
            VALUES (
                1, @TestId, @MethodId, @UnitId, @isCommon,
                @ageFrom, @ageTo, @ageUnit, @gen, @tri,
                @lVal, @hVal, @rem, @src,
                CAST(GETDATE() AS DATE), NULL, 1, 0, GETDATE()
            );
            PRINT 'Inserted reference range for: ' + @tName + ' [' + @gen + ', Age: ' + CAST(@ageFrom AS VARCHAR) + '-' + CAST(@ageTo AS VARCHAR) + ' ' + @ageUnit + ']';
        END
    END

    FETCH NEXT FROM curSeed INTO @tName, @uSym, @isCommon, @ageFrom, @ageTo, @ageUnit, @gen, @tri, @lVal, @hVal, @rem, @src;
END

CLOSE curSeed;
DEALLOCATE curSeed;

PRINT 'Real-world lab reference ranges seeded successfully.';
GO
