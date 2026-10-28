-- 2336 Company > Copy master data: also Shifts, EMR Templates, SMTP Email settings and Video consultation settings
--   SMTP / Video: taken from the source company's Head Office (Branchmaster.IsHOBranch = 1); a shift or SMTP setting is
--   copied to the target company's Head Office. Existing ones are kept (shift: same code or name; template: same name;
--   SMTP: the target Head Office already has a setting; video: the same key).
--   Video settings become company-wise: a key is unique per company.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_VideoSystemConfig_ConfigKey' AND object_id = OBJECT_ID('dbo.tbl_VideoSystemConfig'))
BEGIN
    IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_VideoSystemConfig_ConfigKey')
        ALTER TABLE dbo.tbl_VideoSystemConfig DROP CONSTRAINT UQ_VideoSystemConfig_ConfigKey;
    ELSE
        DROP INDEX UQ_VideoSystemConfig_ConfigKey ON dbo.tbl_VideoSystemConfig;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_VideoSystemConfig_CompanyKey' AND object_id = OBJECT_ID('dbo.tbl_VideoSystemConfig'))
    CREATE UNIQUE INDEX UQ_VideoSystemConfig_CompanyKey ON dbo.tbl_VideoSystemConfig (CompanyId, ConfigKey);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Company_CopyLabMasters
    @SourceCompanyId INT,
    @TargetCompanyId INT,
    @Entities        NVARCHAR(400),      -- comma separated keys
    @Preview         BIT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SourceCompanyId = @TargetCompanyId
    BEGIN RAISERROR('Choose a source company other than this company.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @SourceCompanyId)
       OR NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @TargetCompanyId)
    BEGIN RAISERROR('Company not found.', 16, 1); RETURN; END

    -- selected entities plus the parents they need
    DECLARE @sel TABLE (K VARCHAR(20) PRIMARY KEY);
    INSERT @sel SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(ISNULL(@Entities, ''), ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF EXISTS (SELECT 1 FROM @sel WHERE K IN ('PROFILE', 'REFRANGE', 'DESCRIPTIVE')) AND NOT EXISTS (SELECT 1 FROM @sel WHERE K = 'INVESTIGATION') INSERT @sel VALUES ('INVESTIGATION');
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'REFRANGE') AND NOT EXISTS (SELECT 1 FROM @sel WHERE K = 'METHOD') INSERT @sel VALUES ('METHOD');
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'INVESTIGATION')
    BEGIN
        INSERT @sel SELECT x FROM (VALUES ('CATEGORY'), ('SUBCATEGORY'), ('SAMPLETYPE'), ('METHOD')) v(x) WHERE x NOT IN (SELECT K FROM @sel);
    END
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'SUBCATEGORY') AND NOT EXISTS (SELECT 1 FROM @sel WHERE K = 'CATEGORY') INSERT @sel VALUES ('CATEGORY');
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'PANEL')
        INSERT @sel SELECT x FROM (VALUES ('ANTIBIOTIC'), ('SAMPLETYPE')) v(x) WHERE x NOT IN (SELECT K FROM @sel);
    IF NOT EXISTS (SELECT 1 FROM @sel) BEGIN RAISERROR('Choose at least one master to copy.', 16, 1); RETURN; END

    DECLARE @S INT = @SourceCompanyId, @T INT = @TargetCompanyId, @now DATETIME = GETDATE();
    -- a table variable: its rows survive the rollback of a preview
    DECLARE @res TABLE (Seq INT, EntityKey VARCHAR(20), Entity NVARCHAR(60), InSource INT DEFAULT 0, Existing INT DEFAULT 0, Copied INT DEFAULT 0, Skipped INT DEFAULT 0, Auto BIT DEFAULT 0);
    CREATE TABLE #map (Ent VARCHAR(20), Src INT, Tgt INT, IsNew BIT, PRIMARY KEY (Ent, Src));
    DECLARE @id INT, @new INT, @code NVARCHAR(50);

    BEGIN TRY
    BEGIN TRANSACTION;

    -- ── 1. Test Category (department + name) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'CATEGORY')
    BEGIN
        INSERT #map SELECT 'CAT', s.Category_ID, t.Category_ID, 0
          FROM dbo.LabTestCategoryMaster s
         CROSS APPLY (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND x.Department_ID = s.Department_ID AND LOWER(x.Category_Name) = LOWER(s.Category_Name) ORDER BY x.Category_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Category_ID FROM dbo.LabTestCategoryMaster WHERE CompanyId = @S AND IsDeleted = 0
               AND Category_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'CAT') ORDER BY Category_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabTestCategoryMaster', 'Category_ID', 'Category_Code', 'LCAT', 4, @code OUTPUT;
            INSERT dbo.LabTestCategoryMaster (CompanyId, Department_ID, Category_Name, Category_Code, Display_Order, Status, CreatedBy, CreatedDate, IsDeleted, Is_Barcode_Required, Is_Sample_Collection_Required)
            SELECT @T, Department_ID, Category_Name, @code, Display_Order, Status, @UserId, @now, 0, Is_Barcode_Required, Is_Sample_Collection_Required
              FROM dbo.LabTestCategoryMaster WHERE Category_ID = @id;
            INSERT #map VALUES ('CAT', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 1, 'CATEGORY', N'Test Categories', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'CAT';
    END

    -- ── 2. Test Sub-Category (category + name) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'SUBCATEGORY')
    BEGIN
        INSERT #map SELECT 'SUB', s.SubCategory_ID, t.SubCategory_ID, 0
          FROM dbo.LabTestSubCategoryMaster s
          JOIN #map mc ON mc.Ent = 'CAT' AND mc.Src = s.Category_ID
         CROSS APPLY (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND x.Category_ID = mc.Tgt AND LOWER(x.SubCategory_Name) = LOWER(s.SubCategory_Name) ORDER BY x.SubCategory_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT s.SubCategory_ID FROM dbo.LabTestSubCategoryMaster s JOIN #map mc ON mc.Ent = 'CAT' AND mc.Src = s.Category_ID
             WHERE s.CompanyId = @S AND s.IsDeleted = 0 AND s.SubCategory_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'SUB') ORDER BY s.SubCategory_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabTestSubCategoryMaster', 'SubCategory_ID', 'SubCategory_Code', 'LSUBCAT', 4, @code OUTPUT;
            INSERT dbo.LabTestSubCategoryMaster (CompanyId, Category_ID, SubCategory_Name, SubCategory_Code, Display_Order, Status, CreatedBy, CreatedDate, IsDeleted)
            SELECT @T, mc.Tgt, s.SubCategory_Name, @code, s.Display_Order, s.Status, @UserId, @now, 0
              FROM dbo.LabTestSubCategoryMaster s JOIN #map mc ON mc.Ent = 'CAT' AND mc.Src = s.Category_ID WHERE s.SubCategory_ID = @id;
            INSERT #map VALUES ('SUB', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped)
        SELECT 2, 'SUBCATEGORY', N'Test Sub-Categories',
               (SELECT COUNT(*) FROM dbo.LabTestSubCategoryMaster WHERE CompanyId = @S AND IsDeleted = 0),
               SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END),
               (SELECT COUNT(*) FROM dbo.LabTestSubCategoryMaster WHERE CompanyId = @S AND IsDeleted = 0) - COUNT(*)
          FROM #map WHERE Ent = 'SUB';
    END

    -- ── 3. Sample Type (name + container + volume) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'SAMPLETYPE')
    BEGIN
        INSERT #map SELECT 'SMP', s.Sample_Type_ID, t.Sample_Type_ID, 0
          FROM dbo.LabSampleTypeMaster s
         CROSS APPLY (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND LOWER(x.Sample_Name) = LOWER(s.Sample_Name) AND ISNULL(x.Container_Type, '') = ISNULL(s.Container_Type, '')
                        AND x.Volume_Value = s.Volume_Value AND ISNULL(x.Volume_Unit, '') = ISNULL(s.Volume_Unit, '') ORDER BY x.Sample_Type_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE CompanyId = @S AND IsDeleted = 0
               AND Sample_Type_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'SMP') ORDER BY Sample_Type_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabSampleTypeMaster', 'Sample_Type_ID', 'Sample_Code', 'SMP', 4, @code OUTPUT;
            INSERT dbo.LabSampleTypeMaster (CompanyId, Sample_Name, Sample_Code, Container_Type, Volume_Value, Volume_Unit, Volume_Required, Storage_Temperature, Rejection_Criteria, Display_Order, Status, CreatedBy, CreatedDate, Unit_ID, IsDeleted)
            SELECT @T, Sample_Name, @code, Container_Type, Volume_Value, Volume_Unit, Volume_Required, Storage_Temperature, Rejection_Criteria, Display_Order, Status, @UserId, @now, Unit_ID, 0
              FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @id;
            INSERT #map VALUES ('SMP', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 3, 'SAMPLETYPE', N'Sample Types', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'SMP';
    END

    -- ── 4. Test Method (department + name) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'METHOD')
    BEGIN
        INSERT #map SELECT 'MTH', s.Method_ID, t.Method_ID, 0
          FROM dbo.LabTestMethodMaster s
         CROSS APPLY (SELECT TOP 1 Method_ID FROM dbo.LabTestMethodMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND x.Department_ID = s.Department_ID AND LOWER(x.Method_Name) = LOWER(s.Method_Name) ORDER BY x.Method_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Method_ID FROM dbo.LabTestMethodMaster WHERE CompanyId = @S AND IsDeleted = 0
               AND Method_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'MTH') ORDER BY Method_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabTestMethodMaster', 'Method_ID', 'Method_Code', 'MTH', 4, @code OUTPUT;
            INSERT dbo.LabTestMethodMaster (CompanyId, Department_ID, Method_Name, Method_Code, Display_Order, Status, CreatedBy, CreatedDate, IsDeleted)
            SELECT @T, Department_ID, Method_Name, @code, Display_Order, Status, @UserId, @now, 0 FROM dbo.LabTestMethodMaster WHERE Method_ID = @id;
            INSERT #map VALUES ('MTH', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 4, 'METHOD', N'Test Methods', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'MTH';
    END

    -- ── 5. Investigation (department + name), with its parameter options and formula ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'INVESTIGATION')
    BEGIN
        INSERT #map SELECT 'INV', s.Test_ID, t.Test_ID, 0
          FROM dbo.LabInvestigationMaster s
         CROSS APPLY (SELECT TOP 1 Test_ID FROM dbo.LabInvestigationMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND x.Department_ID = s.Department_ID AND LOWER(x.Test_Name) = LOWER(s.Test_Name) ORDER BY x.Test_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT s.Test_ID FROM dbo.LabInvestigationMaster s JOIN #map mc ON mc.Ent = 'CAT' AND mc.Src = s.Category_ID
             WHERE s.CompanyId = @S AND s.IsDeleted = 0 AND s.Test_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'INV') ORDER BY s.Test_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabInvestigationMaster', 'Test_ID', 'Test_Code', 'LAB-', 5, @code OUTPUT;
            INSERT dbo.LabInvestigationMaster (CompanyId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Method_ID, Unit_ID,
                   Reporting_Type, TAT_Hours, NABL_Accredited, NABL_Scope_No, Is_Outsourced, MRP, Status, CreatedBy, CreatedDate, IsDeleted, Is_Profile_Test,
                   Applicable_Gender, Is_Billable, Age_Operator, Applicable_Age, Is_Fasting_Required, Sample_Quantity, Sample_Quantity_Unit_ID,
                   Reported_Duration_Value, Reported_Duration_Unit, Is_Consent_Required, OVD_Document, Prescription_Required, Reporting_Name, Has_External_Document)
            SELECT @T, @code, s.Test_Name, s.Department_ID, mc.Tgt, ms.Tgt, mp.Tgt, mm.Tgt, s.Unit_ID,
                   s.Reporting_Type, s.TAT_Hours, s.NABL_Accredited, s.NABL_Scope_No, s.Is_Outsourced, s.MRP, s.Status, @UserId, @now, 0, s.Is_Profile_Test,
                   s.Applicable_Gender, s.Is_Billable, s.Age_Operator, s.Applicable_Age, s.Is_Fasting_Required, s.Sample_Quantity, s.Sample_Quantity_Unit_ID,
                   s.Reported_Duration_Value, s.Reported_Duration_Unit, s.Is_Consent_Required, s.OVD_Document, s.Prescription_Required, s.Reporting_Name, s.Has_External_Document
              FROM dbo.LabInvestigationMaster s
              JOIN #map mc ON mc.Ent = 'CAT' AND mc.Src = s.Category_ID
              LEFT JOIN #map ms ON ms.Ent = 'SUB' AND ms.Src = s.SubCategory_ID
              LEFT JOIN #map mp ON mp.Ent = 'SMP' AND mp.Src = s.Sample_Type_ID
              LEFT JOIN #map mm ON mm.Ent = 'MTH' AND mm.Src = s.Method_ID
             WHERE s.Test_ID = @id;
            INSERT #map VALUES ('INV', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped)
        SELECT 5, 'INVESTIGATION', N'Investigations',
               (SELECT COUNT(*) FROM dbo.LabInvestigationMaster WHERE CompanyId = @S AND IsDeleted = 0),
               SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END),
               (SELECT COUNT(*) FROM dbo.LabInvestigationMaster WHERE CompanyId = @S AND IsDeleted = 0) - COUNT(*)
          FROM #map WHERE Ent = 'INV';

        -- parameter options: for a target test that has none
        DECLARE @optCopied INT = 0;
        DECLARE @hadOpt TABLE (Test_ID INT PRIMARY KEY);
        INSERT @hadOpt SELECT DISTINCT Test_ID FROM dbo.LabParameterOptionMaster WHERE CompanyId = @T AND IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT o.Option_ID FROM dbo.LabParameterOptionMaster o JOIN #map mi ON mi.Ent = 'INV' AND mi.Src = o.Test_ID
             WHERE o.CompanyId = @S AND o.IsDeleted = 0
               AND mi.Tgt NOT IN (SELECT Test_ID FROM @hadOpt)
             ORDER BY o.Option_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabParameterOptionMaster', 'Option_ID', 'Option_Code', 'OPT', 4, @code OUTPUT;
            INSERT dbo.LabParameterOptionMaster (CompanyId, Option_Code, Test_ID, Option_Text, Display_Order, Is_Abnormal, Is_Default, Status, IsDeleted, CreatedBy, CreatedDate)
            SELECT @T, @code, mi.Tgt, o.Option_Text, o.Display_Order, o.Is_Abnormal, o.Is_Default, o.Status, 0, @UserId, @now
              FROM dbo.LabParameterOptionMaster o JOIN #map mi ON mi.Ent = 'INV' AND mi.Src = o.Test_ID WHERE o.Option_ID = @id;
            SET @optCopied += 1;
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Auto)
        SELECT 6, 'OPTIONS', N'Parameter Options (with investigations)',
               (SELECT COUNT(*) FROM dbo.LabParameterOptionMaster WHERE CompanyId = @S AND IsDeleted = 0),
               (SELECT COUNT(*) FROM dbo.LabParameterOptionMaster WHERE CompanyId = @S AND IsDeleted = 0) - @optCopied, @optCopied, 1;

        -- formula: for a target test that has none, re-pointed to the target's test codes
        DECLARE @fs TABLE (Test_ID INT, Tgt INT, Expr NVARCHAR(MAX), Rnd INT, Cond NVARCHAR(MAX), Active BIT);
        INSERT @fs SELECT f.Test_ID, mi.Tgt, f.Formula_Expression, f.Rounding_Precision, f.Validity_Condition, f.IsActive
          FROM dbo.LabFormulaParameterMaster f JOIN #map mi ON mi.Ent = 'INV' AND mi.Src = f.Test_ID
         WHERE f.CompanyId = @S AND NOT EXISTS (SELECT 1 FROM dbo.LabFormulaParameterMaster x WHERE x.Test_ID = mi.Tgt AND x.CompanyId = @T);
        UPDATE f SET Expr = REPLACE(f.Expr, '[' + src.Test_Code + ']', '[' + tgt.Test_Code + ']')
          FROM @fs f
          CROSS JOIN #map mi
          JOIN dbo.LabInvestigationMaster src ON src.Test_ID = mi.Src
          JOIN dbo.LabInvestigationMaster tgt ON tgt.Test_ID = mi.Tgt
         WHERE mi.Ent = 'INV' AND CHARINDEX('[' + src.Test_Code + ']', f.Expr) > 0;
        -- (a formula may use several tests: repeat until no source code is left)
        DECLARE @pass INT = 0;
        WHILE @pass < 10 AND EXISTS (SELECT 1 FROM @fs f CROSS JOIN #map mi JOIN dbo.LabInvestigationMaster src ON src.Test_ID = mi.Src
                                      JOIN dbo.LabInvestigationMaster tgt ON tgt.Test_ID = mi.Tgt
                                     WHERE mi.Ent = 'INV' AND src.Test_Code <> tgt.Test_Code AND CHARINDEX('[' + src.Test_Code + ']', f.Expr) > 0)
        BEGIN
            UPDATE f SET Expr = REPLACE(f.Expr, '[' + src.Test_Code + ']', '[' + tgt.Test_Code + ']')
              FROM @fs f CROSS JOIN #map mi JOIN dbo.LabInvestigationMaster src ON src.Test_ID = mi.Src JOIN dbo.LabInvestigationMaster tgt ON tgt.Test_ID = mi.Tgt
             WHERE mi.Ent = 'INV' AND src.Test_Code <> tgt.Test_Code AND CHARINDEX('[' + src.Test_Code + ']', f.Expr) > 0;
            SET @pass += 1;
        END
        INSERT dbo.LabFormulaParameterMaster (Test_ID, Formula_Expression, Rounding_Precision, Validity_Condition, IsActive, CompanyId, CreatedBy, CreatedDate)
        SELECT Tgt, Expr, Rnd, Cond, Active, @T, @UserId, @now FROM @fs;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Auto)
        SELECT 7, 'FORMULA', N'Formulas (with investigations)',
               (SELECT COUNT(*) FROM dbo.LabFormulaParameterMaster WHERE CompanyId = @S),
               (SELECT COUNT(*) FROM dbo.LabFormulaParameterMaster WHERE CompanyId = @S) - (SELECT COUNT(*) FROM @fs), (SELECT COUNT(*) FROM @fs), 1;
    END

    -- ── 8. Investigation Profile (name; profiles only - not packages), with its tests ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'PROFILE')
    BEGIN
        INSERT #map SELECT 'PRF', s.Profile_ID, t.Profile_ID, 0
          FROM dbo.LabInvestigationProfileHeader s
         CROSS APPLY (SELECT TOP 1 Profile_ID FROM dbo.LabInvestigationProfileHeader x WHERE x.CompanyId = @T AND x.IsDeleted = 0
                        AND LOWER(x.Profile_Name) = LOWER(s.Profile_Name) ORDER BY x.Profile_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0 AND s.Profile_Type = 1;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Profile_ID FROM dbo.LabInvestigationProfileHeader WHERE CompanyId = @S AND IsDeleted = 0 AND Profile_Type = 1
               AND Profile_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'PRF') ORDER BY Profile_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabInvestigationProfileHeader', 'Profile_ID', 'Profile_Code', 'PRF', 4, @code OUTPUT;
            INSERT dbo.LabInvestigationProfileHeader (CompanyId, Profile_Code, Profile_Name, MRP, Discount_Pct, Age_Operator, Applicable_Age, Applicable_Gender,
                   Profile_TAT_Hours, Profile_NABL_Accredited, Report_Print_Sequence, Status, IsDeleted, CreatedBy, CreatedDate, Test_ID,
                   Effective_Start_Date, Effective_End_Date, Profile_Type)
            SELECT @T, @code, s.Profile_Name, s.MRP, s.Discount_Pct, s.Age_Operator, s.Applicable_Age, s.Applicable_Gender,
                   s.Profile_TAT_Hours, s.Profile_NABL_Accredited, s.Report_Print_Sequence, s.Status, 0, @UserId, @now, mt.Tgt,
                   s.Effective_Start_Date, s.Effective_End_Date, s.Profile_Type
              FROM dbo.LabInvestigationProfileHeader s LEFT JOIN #map mt ON mt.Ent = 'INV' AND mt.Src = s.Test_ID WHERE s.Profile_ID = @id;
            SET @new = SCOPE_IDENTITY();
            INSERT #map VALUES ('PRF', @id, @new, 1);
            INSERT dbo.LabInvestigationProfileDetail (Profile_ID, Test_ID, Sequence, IsDeleted, CreatedBy, CreatedDate)
            SELECT @new, mt.Tgt, d.Sequence, 0, @UserId, @now
              FROM dbo.LabInvestigationProfileDetail d JOIN #map mt ON mt.Ent = 'INV' AND mt.Src = d.Test_ID
             WHERE d.Profile_ID = @id AND d.IsDeleted = 0;
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 8, 'PROFILE', N'Investigation Profiles', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'PRF';
    END

    -- ── 9. Reference Range: for a target test that has none ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'REFRANGE')
    BEGIN
        DECLARE @rrSrc INT = (SELECT COUNT(*) FROM dbo.LabReferenceRangeMaster WHERE CompanyId = @S AND IsDeleted = 0);
        INSERT dbo.LabReferenceRangeMaster (CompanyId, Test_ID, Method_ID, Unit_ID, Age_From, Age_To, Age_Unit, Gender, Pregnancy_Trimester, Low_Value, High_Value,
               Range_Source, Effective_From, Effective_To, Status, IsDeleted, CreatedBy, CreatedDate, Special_Remarks, Is_Common_For_All,
               Notification_Required, Acknowledgement_Required, Tier, Low_Threshold, High_Threshold)
        SELECT @T, mi.Tgt, mm.Tgt, r.Unit_ID, r.Age_From, r.Age_To, r.Age_Unit, r.Gender, r.Pregnancy_Trimester, r.Low_Value, r.High_Value,
               r.Range_Source, r.Effective_From, r.Effective_To, r.Status, 0, @UserId, @now, r.Special_Remarks, r.Is_Common_For_All,
               r.Notification_Required, r.Acknowledgement_Required, r.Tier, r.Low_Threshold, r.High_Threshold
          FROM dbo.LabReferenceRangeMaster r
          JOIN #map mi ON mi.Ent = 'INV' AND mi.Src = r.Test_ID
          LEFT JOIN #map mm ON mm.Ent = 'MTH' AND mm.Src = r.Method_ID
         WHERE r.CompanyId = @S AND r.IsDeleted = 0
           AND NOT EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster x WHERE x.Test_ID = mi.Tgt AND x.CompanyId = @T AND x.IsDeleted = 0);
        DECLARE @rrCopied INT = @@ROWCOUNT;
        -- ranges of a test that is not copied (e.g. a deleted test) are skipped
        DECLARE @rrSkip INT = (SELECT COUNT(*) FROM dbo.LabReferenceRangeMaster r WHERE r.CompanyId = @S AND r.IsDeleted = 0
                                  AND NOT EXISTS (SELECT 1 FROM #map mi WHERE mi.Ent = 'INV' AND mi.Src = r.Test_ID));
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped) VALUES (9, 'REFRANGE', N'Reference Ranges', @rrSrc, @rrSrc - @rrCopied - @rrSkip, @rrCopied, @rrSkip);
    END

    -- ── 10. Descriptive Test Template: for a target test that has none ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'DESCRIPTIVE')
    BEGIN
        DECLARE @dtSrc INT = (SELECT COUNT(*) FROM dbo.LabDescriptiveTestTemplate WHERE CompanyId = @S);
        INSERT dbo.LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId,
               CreatedBy, CreatedDate, Modality, Body_Part, Laterality, Contrast_Required, Contrast_Agent, Views_Projections, Preparation_Instructions)
        SELECT mi.Tgt, d.Section_Name, d.Section_Sequence, d.Is_Mandatory, d.Default_Content_Html, d.Placeholder_Tags, d.IsActive, @T,
               @UserId, @now, d.Modality, d.Body_Part, d.Laterality, d.Contrast_Required, d.Contrast_Agent, d.Views_Projections, d.Preparation_Instructions
          FROM dbo.LabDescriptiveTestTemplate d
          JOIN #map mi ON mi.Ent = 'INV' AND mi.Src = d.Test_ID
         WHERE d.CompanyId = @S
           AND NOT EXISTS (SELECT 1 FROM dbo.LabDescriptiveTestTemplate x WHERE x.Test_ID = mi.Tgt AND x.CompanyId = @T);
        DECLARE @dtCopied INT = @@ROWCOUNT;
        DECLARE @dtSkip INT = (SELECT COUNT(*) FROM dbo.LabDescriptiveTestTemplate d WHERE d.CompanyId = @S
                                  AND NOT EXISTS (SELECT 1 FROM #map mi WHERE mi.Ent = 'INV' AND mi.Src = d.Test_ID));
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped) VALUES (10, 'DESCRIPTIVE', N'Descriptive Test Templates', @dtSrc, @dtSrc - @dtCopied - @dtSkip, @dtCopied, @dtSkip);
    END

    -- ── 11. Organism (name) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'ORGANISM')
    BEGIN
        INSERT #map SELECT 'ORG', s.Organism_ID, t.Organism_ID, 0
          FROM dbo.LabOrganismMaster s
         CROSS APPLY (SELECT TOP 1 Organism_ID FROM dbo.LabOrganismMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0 AND LOWER(x.Organism_Name) = LOWER(s.Organism_Name) ORDER BY x.Organism_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Organism_ID FROM dbo.LabOrganismMaster WHERE CompanyId = @S AND IsDeleted = 0 AND Organism_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'ORG') ORDER BY Organism_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabOrganismMaster', 'Organism_ID', 'Organism_Code', 'ORG', 4, @code OUTPUT;
            INSERT dbo.LabOrganismMaster (CompanyId, Organism_Code, Organism_Name, Gram_Type, Organism_Type, Organism_Category, Description, Status, IsDeleted, CreatedBy, CreatedDate, WHONET_Code)
            SELECT @T, @code, Organism_Name, Gram_Type, Organism_Type, Organism_Category, Description, Status, 0, @UserId, @now, WHONET_Code FROM dbo.LabOrganismMaster WHERE Organism_ID = @id;
            INSERT #map VALUES ('ORG', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 11, 'ORGANISM', N'Organisms', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'ORG';
    END

    -- ── 12. Antibiotic (name) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'ANTIBIOTIC')
    BEGIN
        INSERT #map SELECT 'ABX', s.Antibiotic_ID, t.Antibiotic_ID, 0
          FROM dbo.LabAntibioticMaster s
         CROSS APPLY (SELECT TOP 1 Antibiotic_ID FROM dbo.LabAntibioticMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0 AND LOWER(x.Antibiotic_Name) = LOWER(s.Antibiotic_Name) ORDER BY x.Antibiotic_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Antibiotic_ID FROM dbo.LabAntibioticMaster WHERE CompanyId = @S AND IsDeleted = 0 AND Antibiotic_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'ABX') ORDER BY Antibiotic_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabAntibioticMaster', 'Antibiotic_ID', 'Antibiotic_Code', 'ABX', 4, @code OUTPUT;
            INSERT dbo.LabAntibioticMaster (CompanyId, Antibiotic_Code, Antibiotic_Name, Abbreviation, Antibiotic_Class, Route, Description, Status, IsDeleted, CreatedBy, CreatedDate, WHONET_Code)
            SELECT @T, @code, Antibiotic_Name, Abbreviation, Antibiotic_Class, Route, Description, Status, 0, @UserId, @now, WHONET_Code FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @id;
            INSERT #map VALUES ('ABX', @id, SCOPE_IDENTITY(), 1);
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 12, 'ANTIBIOTIC', N'Antibiotics', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'ABX';
    END

    -- ── 13. Antibiotic Panel (name), with its antibiotics ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'PANEL')
    BEGIN
        INSERT #map SELECT 'ABP', s.Panel_ID, t.Panel_ID, 0
          FROM dbo.LabAntibioticPanelMaster s
         CROSS APPLY (SELECT TOP 1 Panel_ID FROM dbo.LabAntibioticPanelMaster x WHERE x.CompanyId = @T AND x.IsDeleted = 0 AND LOWER(x.Panel_Name) = LOWER(s.Panel_Name) ORDER BY x.Panel_ID) t
         WHERE s.CompanyId = @S AND s.IsDeleted = 0;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT Panel_ID FROM dbo.LabAntibioticPanelMaster WHERE CompanyId = @S AND IsDeleted = 0 AND Panel_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'ABP') ORDER BY Panel_ID;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Company_NextCode 'LabAntibioticPanelMaster', 'Panel_ID', 'Panel_Code', 'ABP', 4, @code OUTPUT;
            INSERT dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, IsDeleted, CreatedBy, CreatedDate, Sample_Type_ID)
            SELECT @T, @code, s.Panel_Name, s.Gram_Type, s.Organism_Category, s.Description, s.Status, 0, @UserId, @now, mp.Tgt
              FROM dbo.LabAntibioticPanelMaster s LEFT JOIN #map mp ON mp.Ent = 'SMP' AND mp.Src = s.Sample_Type_ID WHERE s.Panel_ID = @id;
            SET @new = SCOPE_IDENTITY();
            INSERT #map VALUES ('ABP', @id, @new, 1);
            INSERT dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order, Tier)
            SELECT @new, ma.Tgt, d.Display_Order, d.Tier
              FROM dbo.LabAntibioticPanelDetail d JOIN #map ma ON ma.Ent = 'ABX' AND ma.Src = d.Antibiotic_ID WHERE d.Panel_ID = @id;
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 13, 'PANEL', N'Antibiotic Panels', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'ABP';
    END

    -- ══ 2336: masters outside LAB ══
    -- the Head Office of each company (SMTP / Video settings come from the source's Head Office; a copied shift or SMTP
    -- setting goes to the target's Head Office)
    DECLARE @SHO INT = (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @S AND IsActive = 1 AND IsHOBranch = 1 ORDER BY BranchID);
    DECLARE @THO INT = (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @T AND IsActive = 1 AND IsHOBranch = 1 ORDER BY BranchID);

    -- ── 14. Shift (code, else name) - copied to the target's Head Office ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'SHIFT')
    BEGIN
        INSERT #map SELECT 'SHF', s.ShiftMaster_ID, t.ShiftMaster_ID, 0
          FROM dbo.ShiftMaster s
         CROSS APPLY (SELECT TOP 1 ShiftMaster_ID FROM dbo.ShiftMaster x WHERE x.CompanyId = @T
                        AND (LOWER(x.ShiftCode) = LOWER(s.ShiftCode) OR LOWER(x.ShiftName) = LOWER(s.ShiftName)) ORDER BY x.ShiftMaster_ID) t
         WHERE s.CompanyId = @S;
        IF @THO IS NOT NULL
        BEGIN
            DECLARE c CURSOR LOCAL STATIC FOR
                SELECT ShiftMaster_ID FROM dbo.ShiftMaster WHERE CompanyId = @S AND ShiftMaster_ID NOT IN (SELECT Src FROM #map WHERE Ent = 'SHF') ORDER BY ShiftMaster_ID;
            OPEN c; FETCH NEXT FROM c INTO @id;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT dbo.ShiftMaster (CompanyId, Branch_ID, ShiftCode, ShiftName, StartTime, EndTime, GraceTimeMinutes, BreakDurationMinutes, IsNightShift, Status, CreatedBy, CreatedDate)
                SELECT @T, @THO, s.ShiftCode, s.ShiftName, s.StartTime, s.EndTime, s.GraceTimeMinutes, s.BreakDurationMinutes, s.IsNightShift, s.Status, @UserId, @now
                  FROM dbo.ShiftMaster s WHERE s.ShiftMaster_ID = @id;
                INSERT #map VALUES ('SHF', @id, SCOPE_IDENTITY(), 1);
                FETCH NEXT FROM c INTO @id;
            END
            CLOSE c; DEALLOCATE c;
        END
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped)
        SELECT 14, 'SHIFT', N'Shifts', (SELECT COUNT(*) FROM dbo.ShiftMaster WHERE CompanyId = @S),
               SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END),
               (SELECT COUNT(*) FROM dbo.ShiftMaster WHERE CompanyId = @S) - COUNT(*)   -- no Head Office in this company
          FROM #map WHERE Ent = 'SHF';
    END

    -- ── 15. EMR Template (name), with its sections, fields and specialities ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'EMRTEMPLATE')
    BEGIN
        INSERT #map SELECT 'EMT', s.TemplateId, t.TemplateId, 0
          FROM dbo.EmrTemplates s
         CROSS APPLY (SELECT TOP 1 TemplateId FROM dbo.EmrTemplates x WHERE x.CompanyId = @T AND LOWER(x.TemplateName) = LOWER(s.TemplateName) ORDER BY x.TemplateId) t
         WHERE s.CompanyId = @S;
        DECLARE c CURSOR LOCAL STATIC FOR
            SELECT TemplateId FROM dbo.EmrTemplates WHERE CompanyId = @S AND TemplateId NOT IN (SELECT Src FROM #map WHERE Ent = 'EMT') ORDER BY TemplateId;
        OPEN c; FETCH NEXT FROM c INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT dbo.EmrTemplates (TemplateName, Description, IsActive, CreatedBy, CreatedDate, CompanyId)
            SELECT s.TemplateName, s.Description, s.IsActive, @UserId, @now, @T FROM dbo.EmrTemplates s WHERE s.TemplateId = @id;
            SET @new = SCOPE_IDENTITY();
            INSERT #map VALUES ('EMT', @id, @new, 1);
            -- sections, then their fields (section ids mapped through MERGE ... OUTPUT)
            DECLARE @secMap TABLE (OldId INT, NewId INT);
            DELETE FROM @secMap;
            MERGE dbo.EmrTemplateSections AS tg
            USING (SELECT * FROM dbo.EmrTemplateSections WHERE TemplateId = @id) AS sc ON 1 = 0
            WHEN NOT MATCHED THEN
                INSERT (TemplateId, SectionName, DisplayOrder, IsActive, CreatedBy, CreatedDate, CompanyId)
                VALUES (@new, sc.SectionName, sc.DisplayOrder, sc.IsActive, @UserId, @now, @T)
            OUTPUT sc.SectionId, inserted.SectionId INTO @secMap (OldId, NewId);
            INSERT dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive, CreatedBy, CreatedDate, CompanyId)
            SELECT sm.NewId, f.FieldName, f.FieldType, f.OptionsJson, f.IsRequired, f.DisplayOrder, f.IsActive, @UserId, @now, @T
              FROM dbo.EmrTemplateFields f JOIN @secMap sm ON sm.OldId = f.SectionId;
            -- specialities are shared by all companies: the same speciality
            INSERT dbo.EmrTemplateSpecialityMap (TemplateId, SpecialityId, IsActive, CreatedBy, CreatedDate, CompanyId)
            SELECT @new, m.SpecialityId, m.IsActive, @UserId, @now, @T FROM dbo.EmrTemplateSpecialityMap m WHERE m.TemplateId = @id;
            FETCH NEXT FROM c INTO @id;
        END
        CLOSE c; DEALLOCATE c;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        SELECT 15, 'EMRTEMPLATE', N'EMR Templates', COUNT(*), SUM(CASE WHEN IsNew = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN IsNew = 1 THEN 1 ELSE 0 END) FROM #map WHERE Ent = 'EMT';
    END

    -- ── 16. SMTP Email setting: the source Head Office's settings, to the target Head Office when it has none ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'SMTP')
    BEGIN
        DECLARE @smtpSrc INT = (SELECT COUNT(*) FROM dbo.SmtpEmailConfiguration WHERE BranchId = @SHO AND IsActive = 1);
        DECLARE @smtpHave BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.SmtpEmailConfiguration WHERE BranchId = @THO) THEN 1 ELSE 0 END;
        DECLARE @smtpCopied INT = 0;
        IF @THO IS NOT NULL AND @smtpHave = 0
        BEGIN
            -- the password stays encrypted with the application's key (shared by every company)
            INSERT dbo.SmtpEmailConfiguration (BranchId, ConfigName, ProviderType, SmtpHost, SmtpPort, UseSsl, UseStartTls, SenderEmail, SenderDisplayName,
                                               Username, PasswordEncrypted, IsDefault, IsActive, CreatedBy, CreatedDate, CompanyId, ApplicationBaseUrl)
            SELECT @THO, s.ConfigName, s.ProviderType, s.SmtpHost, s.SmtpPort, s.UseSsl, s.UseStartTls, s.SenderEmail, s.SenderDisplayName,
                   s.Username, s.PasswordEncrypted, s.IsDefault, s.IsActive, @UserId, @now, @T, s.ApplicationBaseUrl
              FROM dbo.SmtpEmailConfiguration s WHERE s.BranchId = @SHO AND s.IsActive = 1;
            SET @smtpCopied = @@ROWCOUNT;
        END
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied, Skipped)
        VALUES (16, 'SMTP', N'SMTP Email Settings (Head Office)', @smtpSrc,
                CASE WHEN @smtpHave = 1 THEN @smtpSrc ELSE 0 END, @smtpCopied,
                CASE WHEN @THO IS NULL THEN @smtpSrc ELSE 0 END);
    END

    -- ── 17. Video consultation settings (per key) ──
    IF EXISTS (SELECT 1 FROM @sel WHERE K = 'VIDEO')
    BEGIN
        DECLARE @vidSrc INT = (SELECT COUNT(*) FROM dbo.tbl_VideoSystemConfig WHERE CompanyId = @S);
        INSERT dbo.tbl_VideoSystemConfig (ConfigKey, ConfigValue, MeetingCreationUrl, IsActive, CreatedDate, ModifiedBy, CompanyId)
        SELECT s.ConfigKey, s.ConfigValue, s.MeetingCreationUrl, s.IsActive, @now, CAST(@UserId AS NVARCHAR(50)), @T
          FROM dbo.tbl_VideoSystemConfig s
         WHERE s.CompanyId = @S AND NOT EXISTS (SELECT 1 FROM dbo.tbl_VideoSystemConfig x WHERE x.CompanyId = @T AND x.ConfigKey = s.ConfigKey);
        DECLARE @vidCopied INT = @@ROWCOUNT;
        INSERT @res (Seq, EntityKey, Entity, InSource, Existing, Copied)
        VALUES (17, 'VIDEO', N'Video Consultation Settings', @vidSrc, @vidSrc - @vidCopied, @vidCopied);
    END

    -- entities the user did not tick but that came with the ones they did
    UPDATE r SET Auto = 1 FROM @res r
     WHERE r.EntityKey NOT IN (SELECT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(ISNULL(@Entities, ''), ','))
       AND r.EntityKey NOT IN ('OPTIONS', 'FORMULA');

    IF @Preview = 1 ROLLBACK TRANSACTION; ELSE COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT EntityKey, Entity, InSource, ISNULL(Existing, 0) AS Existing, ISNULL(Copied, 0) AS Copied, ISNULL(Skipped, 0) AS Skipped, Auto
      FROM @res ORDER BY Seq;
END
GO
PRINT 'Script 2336 applied: copy Shifts, EMR Templates, SMTP and Video settings; video settings company-wise.';
GO
