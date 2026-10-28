-- 2328 Company > Copy master data (super admin): the TARGET company pulls LAB masters from a SOURCE company.
--
-- Data goes EMR.Web (Companies/CopyMasters) -> EMR.Api (api/company-copy) -> usp_Company_CopyLabMasters.
--   * Entities (keys): CATEGORY, SUBCATEGORY, SAMPLETYPE, METHOD, INVESTIGATION, PROFILE, REFRANGE, DESCRIPTIVE,
--     ORGANISM, ANTIBIOTIC, PANEL. A selected entity brings its parents (INVESTIGATION -> CATEGORY, SUBCATEGORY,
--     SAMPLETYPE, METHOD; PROFILE / REFRANGE / DESCRIPTIVE -> INVESTIGATION; PANEL -> ANTIBIOTIC, SAMPLETYPE ...).
--   * A row the target already has (same name, the rule each master's own Create uses) is linked, not copied again.
--   * Copied rows get new codes from the masters' own sequences (codes are unique across the database); formula
--     expressions are re-pointed to the target's test codes.
--   * Children go with their parent: an investigation's parameter options and formula, a profile's tests, a panel's
--     antibiotics. Reference ranges and descriptive templates are copied for a target test that has none.
--   * Profiles only (Profile_Type 1), never packages. Departments and Lab Units are global and kept as they are.
--   * One transaction; @Preview = 1 runs the same work and rolls it back, returning what would happen.
-- Also: profile names unique per company (they were unique across all companies).

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── profile name unique per company ──
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabInvestigationProfileHeader_ProfileName' AND object_id = OBJECT_ID('dbo.LabInvestigationProfileHeader'))
    DROP INDEX UX_LabInvestigationProfileHeader_ProfileName ON dbo.LabInvestigationProfileHeader;
GO
CREATE UNIQUE INDEX UX_LabInvestigationProfileHeader_ProfileName
    ON dbo.LabInvestigationProfileHeader (CompanyId, Profile_Name) WHERE IsDeleted = 0;
GO
-- the profile save procedure: the duplicate-name check within the company only
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabInvestigationProfile_Save'));
IF @def IS NOT NULL AND CHARINDEX('[Profile_Name] = @Profile_Name AND [CompanyId] = @CompanyId', @def) = 0
BEGIN
    SET @def = REPLACE(@def, 'WHERE [Profile_Name] = @Profile_Name ', 'WHERE [Profile_Name] = @Profile_Name AND [CompanyId] = @CompanyId ');
    SET @def = STUFF(@def, PATINDEX('%CREATE%PROCEDURE%', @def), LEN('CREATE'), 'ALTER');
    EXEC sys.sp_executesql @def;
END
GO

-- ── next free code for a master (the masters' own pattern: prefix + next number, skipping codes in use) ──
CREATE OR ALTER PROCEDURE dbo.usp_Company_NextCode
    @Table SYSNAME, @IdColumn SYSNAME, @CodeColumn SYSNAME, @Prefix NVARCHAR(20), @Digits INT, @Code NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @next INT, @exists BIT = 1, @sql NVARCHAR(MAX);
    SET @sql = N'SELECT @n = ISNULL(MAX(' + QUOTENAME(@IdColumn) + N'), 0) + 1 FROM dbo.' + QUOTENAME(@Table) + N' WITH (UPDLOCK, HOLDLOCK);';
    EXEC sys.sp_executesql @sql, N'@n INT OUTPUT', @n = @next OUTPUT;
    WHILE @exists = 1
    BEGIN
        SET @Code = @Prefix + RIGHT(REPLICATE('0', @Digits) + CAST(@next AS NVARCHAR(10)), @Digits);
        SET @sql = N'SELECT @e = CASE WHEN EXISTS (SELECT 1 FROM dbo.' + QUOTENAME(@Table) + N' WHERE ' + QUOTENAME(@CodeColumn) + N' = @c) THEN 1 ELSE 0 END;';
        EXEC sys.sp_executesql @sql, N'@c NVARCHAR(50), @e BIT OUTPUT', @c = @Code, @e = @exists OUTPUT;
        SET @next += 1;
    END
END
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

PRINT 'Script 2328 applied: Company > Copy master data (LAB masters).';
GO
