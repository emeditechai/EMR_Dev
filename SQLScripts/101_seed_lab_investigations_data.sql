-- ====================================================================================================
-- Script: 101_seed_lab_investigations_data.sql
-- Description: Seeds standard Indian clinical data for Investigation Master (Lab Tests)
-- ====================================================================================================

DECLARE @DeptId INT, @CatId INT, @SubId INT, @SampleId INT, @MethodId INT, @UnitId INT;

-- Resolve Pathology / Lab Department
SELECT TOP 1 @DeptId = DeptId FROM dbo.DepartmentMaster WHERE DeptType = 'Lab' OR DeptName LIKE '%Pathology%' OR DeptCode LIKE '%PATH%';
IF @DeptId IS NULL SET @DeptId = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster ORDER BY DeptId);

-- Resolve Default Master References
SELECT TOP 1 @CatId = Category_ID FROM dbo.LabTestCategoryMaster WHERE Status = 1 ORDER BY Category_ID;
SELECT TOP 1 @SubId = SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE Status = 1 ORDER BY SubCategory_ID;
SELECT TOP 1 @SampleId = Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Status = 1 ORDER BY Sample_Type_ID;
SELECT TOP 1 @MethodId = Method_ID FROM dbo.LabTestMethodMaster WHERE Status = 1 ORDER BY Method_ID;
SELECT TOP 1 @UnitId = Unit_ID FROM dbo.LabUnitMaster WHERE Status = 1 ORDER BY Unit_ID;

IF @DeptId IS NOT NULL AND @CatId IS NOT NULL
BEGIN
    DECLARE @Tests TABLE (
        TestName NVARCHAR(200),
        ReportingType NVARCHAR(50),
        TATHours INT,
        NABLAccredited BIT,
        NABLScopeNo NVARCHAR(100),
        IsOutsourced BIT,
        MRP DECIMAL(18,2)
    );

    INSERT INTO @Tests (TestName, ReportingType, TATHours, NABLAccredited, NABLScopeNo, IsOutsourced, MRP) VALUES
    ('Complete Blood Count (CBC) with ESR', 'Numeric', 6, 1, 'NABL-LAB-2026-CBC', 0, 450.00),
    ('Fasting Blood Sugar (FBS)', 'Numeric', 4, 1, 'NABL-LAB-2026-GLU', 0, 150.00),
    ('Post Prandial Blood Sugar (PPBS)', 'Numeric', 4, 1, 'NABL-LAB-2026-GLU', 0, 150.00),
    ('HbA1c (Glycated Hemoglobin)', 'Numeric', 12, 1, 'NABL-LAB-2026-HBA1C', 0, 600.00),
    ('Lipid Profile Total', 'Numeric', 12, 1, 'NABL-LAB-2026-LIPID', 0, 850.00),
    ('Liver Function Test (LFT)', 'Numeric', 12, 1, 'NABL-LAB-2026-LFT', 0, 950.00),
    ('Renal Function Test (KFT / RFT)', 'Numeric', 12, 1, 'NABL-LAB-2026-RFT', 0, 900.00),
    ('Thyroid Profile (T3, T4, TSH)', 'Numeric', 24, 1, 'NABL-LAB-2026-THY', 0, 750.00),
    ('Serum Creatinine', 'Numeric', 4, 1, 'NABL-LAB-2026-CREAT', 0, 200.00),
    ('Urine Routine & Microscopy', 'Descriptive', 4, 0, NULL, 0, 180.00),
    ('Dengue NS1 Antigen & IgM/IgG', 'Text', 6, 1, 'NABL-LAB-2026-DENG', 0, 1200.00),
    ('RT-PCR for COVID-19 / Respiratory Virus', 'Text', 24, 1, 'NABL-LAB-2026-RTPCR', 1, 1500.00),
    ('Vitamin D3 (25-Hydroxy)', 'Numeric', 24, 1, 'NABL-LAB-2026-VITD', 0, 1400.00),
    ('Vitamin B12 (Cyanocobalamin)', 'Numeric', 24, 1, 'NABL-LAB-2026-VITB12', 0, 1100.00),
    ('High Sensitivity C-Reactive Protein (hs-CRP)', 'Numeric', 8, 1, 'NABL-LAB-2026-CRP', 0, 550.00);

    DECLARE @TName NVARCHAR(200), @RType NVARCHAR(50), @TAT INT, @NABL BIT, @Scope NVARCHAR(100), @Outsourced BIT, @Price DECIMAL(18,2);
    DECLARE curTest CURSOR FOR SELECT TestName, ReportingType, TATHours, NABLAccredited, NABLScopeNo, IsOutsourced, MRP FROM @Tests;
    OPEN curTest;
    FETCH NEXT FROM curTest INTO @TName, @RType, @TAT, @NABL, @Scope, @Outsourced, @Price;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM dbo.LabInvestigationMaster WHERE BranchId = 1 AND LOWER(Test_Name) = LOWER(@TName)
        )
        BEGIN
            DECLARE @NextId INT;
            DECLARE @GenCode NVARCHAR(50);
            SELECT @NextId = ISNULL(MAX(Test_ID), 0) + 1 FROM dbo.LabInvestigationMaster;
            SET @GenCode = 'TST' + RIGHT('0000' + CAST(@NextId AS NVARCHAR(10)), 4);

            INSERT INTO dbo.LabInvestigationMaster
            (
                CompanyId, BranchId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID,
                Sample_Type_ID, Method_ID, Unit_ID, Reporting_Type, TAT_Hours, NABL_Accredited, NABL_Scope_No,
                Is_Outsourced, MRP, Status, CreatedDate
            )
            VALUES
            (
                1, 1, @GenCode, @TName, @DeptId, @CatId, @SubId,
                @SampleId, @MethodId, @UnitId, @RType, @TAT, @NABL, @Scope,
                @Outsourced, @Price, 1, GETDATE()
            );
        END
        FETCH NEXT FROM curTest INTO @TName, @RType, @TAT, @NABL, @Scope, @Outsourced, @Price;
    END

    CLOSE curTest;
    DEALLOCATE curTest;
    PRINT 'dbo.LabInvestigationMaster seeded successfully.';
END
GO
