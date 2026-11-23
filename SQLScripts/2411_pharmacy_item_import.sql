-- ============================================================================================================
-- 2411  Pharmacy Item Master bulk import (after 2410). Master > Pharmacy > Item / Drug Master > Import.
--   usp_Api_PhItem_Import @Rows (JSON from the Excel template), @Commit 0 = check only (preview), 1 = import.
--   Every row is checked; a missing Generic / Manufacturer / Dosage form / Category (Main › Sub) / HSN / Unit is
--   created; an item that already exists (same name + manufacturer + form, as the Item Master save rule) is skipped.
--   Schedule H1 / X / NDPS always need a prescription; X / NDPS are never returnable (as the Item Master).
--   The same import loads the standard starter list shipped with EMR.Web (App_Data/pharmacy-standard-items.csv).
--   Page control MASTER.PH_ITEMS : IMPORT. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhItem_Import @CompanyId INT, @UserId INT, @Rows NVARCHAR(MAX), @Commit BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    CREATE TABLE #R (
        RowNo INT PRIMARY KEY, ItemName NVARCHAR(200), GenericName NVARCHAR(300), Manufacturer NVARCHAR(150), DosageForm NVARCHAR(60), Strength NVARCHAR(60),
        PackSize NVARCHAR(60), Category NVARCHAR(200), Schedule VARCHAR(10), HsnCode VARCHAR(10), GstPercent DECIMAL(5,2), PurchaseUnit NVARCHAR(20), SaleUnit NVARCHAR(20),
        ConversionQty INT, Barcode NVARCHAR(50), ReorderLevel DECIMAL(12,2), MinQty DECIMAL(12,2), MaxQty DECIMAL(12,2), LeadDays INT,
        RxRequired BIT, LooseSale BIT, ColdChain BIT, HighAlert BIT, Lasa BIT, Returnable BIT, DiscountAllowed BIT, VedClass CHAR(1), Remarks NVARCHAR(300),
        MainCat NVARCHAR(100), SubCat NVARCHAR(100), Status VARCHAR(10) NULL, Message NVARCHAR(400) NULL, ItemId INT NULL);
    CREATE TABLE #Out (ItemId INT, ItemCode NVARCHAR(20));
    INSERT #R (RowNo, ItemName, GenericName, Manufacturer, DosageForm, Strength, PackSize, Category, Schedule, HsnCode, GstPercent, PurchaseUnit, SaleUnit,
               ConversionQty, Barcode, ReorderLevel, MinQty, MaxQty, LeadDays, RxRequired, LooseSale, ColdChain, HighAlert, Lasa, Returnable, DiscountAllowed, VedClass, Remarks)
    SELECT j.RowNo, NULLIF(LTRIM(RTRIM(j.ItemName)), N''), NULLIF(LTRIM(RTRIM(j.GenericName)), N''), NULLIF(LTRIM(RTRIM(j.Manufacturer)), N''), NULLIF(LTRIM(RTRIM(j.DosageForm)), N''),
           NULLIF(LTRIM(RTRIM(j.Strength)), N''), NULLIF(LTRIM(RTRIM(j.PackSize)), N''), NULLIF(LTRIM(RTRIM(j.Category)), N''), UPPER(NULLIF(LTRIM(RTRIM(j.Schedule)), N'')),
           NULLIF(LTRIM(RTRIM(j.HsnCode)), N''), j.GstPercent, UPPER(NULLIF(LTRIM(RTRIM(j.PurchaseUnit)), N'')), UPPER(NULLIF(LTRIM(RTRIM(j.SaleUnit)), N'')),
           ISNULL(j.ConversionQty, 1), NULLIF(LTRIM(RTRIM(j.Barcode)), N''), ISNULL(j.ReorderLevel, 0), ISNULL(j.MinQty, 0), ISNULL(j.MaxQty, 0), ISNULL(j.LeadDays, 2),
           j.RxRequired, ISNULL(j.LooseSale, 1), ISNULL(j.ColdChain, 0), ISNULL(j.HighAlert, 0), ISNULL(j.Lasa, 0), ISNULL(j.Returnable, 1), ISNULL(j.DiscountAllowed, 1),
           UPPER(NULLIF(LTRIM(RTRIM(j.VedClass)), N'')), NULLIF(LTRIM(RTRIM(j.Remarks)), N'')
      FROM OPENJSON(@Rows) WITH (RowNo INT, ItemName NVARCHAR(400), GenericName NVARCHAR(400), Manufacturer NVARCHAR(300), DosageForm NVARCHAR(100), Strength NVARCHAR(100),
                                 PackSize NVARCHAR(100), Category NVARCHAR(300), Schedule NVARCHAR(20), HsnCode NVARCHAR(20), GstPercent DECIMAL(5,2), PurchaseUnit NVARCHAR(40),
                                 SaleUnit NVARCHAR(40), ConversionQty INT, Barcode NVARCHAR(100), ReorderLevel DECIMAL(12,2), MinQty DECIMAL(12,2), MaxQty DECIMAL(12,2), LeadDays INT,
                                 RxRequired BIT, LooseSale BIT, ColdChain BIT, HighAlert BIT, Lasa BIT, Returnable BIT, DiscountAllowed BIT, VedClass NVARCHAR(5), Remarks NVARCHAR(600)) j;
    -- "Main › Sub" (or "Main > Sub"): the category under its main category
    UPDATE #R SET Category = REPLACE(Category, N'>', N'›');
    UPDATE #R SET MainCat = LTRIM(RTRIM(CASE WHEN CHARINDEX(N'›', Category) > 0 THEN LEFT(Category, CHARINDEX(N'›', Category) - 1) ELSE Category END)),
                  SubCat = CASE WHEN CHARINDEX(N'›', Category) > 0 THEN NULLIF(LTRIM(RTRIM(SUBSTRING(Category, CHARINDEX(N'›', Category) + 1, 200))), N'') END;

    -- checks, first error wins
    UPDATE r SET Message =
        CASE WHEN ItemName IS NULL THEN N'Item name is required.'
             WHEN LEN(ItemName) > 200 THEN N'Item name is longer than 200 characters.'
             WHEN Category IS NULL THEN N'Category is required (e.g. Drugs / Medicines › Antibiotics).'
             WHEN Schedule IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.PhDrugSchedule s WHERE s.ScheduleCode = r.Schedule) THEN N'Schedule must be G, H, H1, X, NDPS or OTC.'
             WHEN HsnCode IS NULL OR HsnCode LIKE '%[^0-9]%' OR LEN(HsnCode) NOT IN (4, 6, 8) THEN N'HSN code must be 4, 6 or 8 digits.'
             WHEN GstPercent IS NOT NULL AND GstPercent NOT IN (0, 5, 12, 18, 28) THEN N'GST % must be 0, 5, 12, 18 or 28.'
             WHEN GstPercent IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhHsn h WHERE h.CompanyId = @CompanyId AND h.HsnCode = r.HsnCode) THEN N'New HSN ' + HsnCode + N': give its GST %.'
             WHEN PurchaseUnit IS NULL OR SaleUnit IS NULL THEN N'Purchase unit and sale unit are required (e.g. STRIP / TAB).'
             WHEN ConversionQty < 1 OR ConversionQty > 10000 THEN N'Sale units per purchase unit must be 1 to 10000.'
             WHEN PurchaseUnit = SaleUnit AND ConversionQty <> 1 THEN N'Purchase and sale unit are the same, so the conversion must be 1.'
             WHEN ReorderLevel < 0 OR MinQty < 0 OR MaxQty < 0 THEN N'Stock levels cannot be negative.'
             WHEN MaxQty > 0 AND (MinQty > MaxQty OR ReorderLevel > MaxQty) THEN N'Minimum and reorder level must not be above the maximum.'
             WHEN VedClass IS NOT NULL AND VedClass NOT IN ('V', 'E', 'D') THEN N'VED class must be V, E or D.'
             WHEN Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PhItem i WHERE i.CompanyId = @CompanyId AND i.Barcode = r.Barcode) THEN N'Barcode ' + Barcode + N' is already on another item.'
        END
      FROM #R r;
    UPDATE #R SET Status = 'ERROR' WHERE Message IS NOT NULL;
    UPDATE r SET Status = 'ERROR', Message = N'Same item again in the file (row ' + CAST(f.RowNo AS NVARCHAR(10)) + N').'
      FROM #R r CROSS APPLY (SELECT MIN(x.RowNo) AS RowNo FROM #R x WHERE x.RowNo < r.RowNo AND x.ItemName = r.ItemName
                               AND ISNULL(x.Manufacturer, N'') = ISNULL(r.Manufacturer, N'') AND ISNULL(x.DosageForm, N'') = ISNULL(r.DosageForm, N'')) f
     WHERE r.Message IS NULL AND f.RowNo IS NOT NULL;
    UPDATE r SET Status = 'ERROR', Message = N'Barcode ' + r.Barcode + N' is twice in the file.'
      FROM #R r WHERE r.Message IS NULL AND r.Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM #R x WHERE x.RowNo < r.RowNo AND x.Barcode = r.Barcode);
    -- already in the Item Master: skipped, not changed
    UPDATE r SET Status = 'SKIP', Message = N'Already in Item Master (' + i.ItemCode + N').', ItemId = i.ItemId
      FROM #R r JOIN dbo.PhItem i ON i.CompanyId = @CompanyId AND i.ItemName = r.ItemName
      LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
     WHERE r.Message IS NULL AND ISNULL(m.ManufacturerName, N'') = ISNULL(r.Manufacturer, N'')
       AND (r.DosageForm IS NULL AND i.DosageFormId IS NULL OR df.ShortName = r.DosageForm OR df.DosageFormName = r.DosageForm);
    UPDATE #R SET Status = 'NEW', Message = N'Will be added.' WHERE Status IS NULL;
    -- what will be created along the way (preview)
    UPDATE r SET Message = Message + N' New: ' + STUFF(
             CASE WHEN r.GenericName IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhGeneric g WHERE g.CompanyId = @CompanyId AND g.GenericName = r.GenericName) THEN N', generic' ELSE N'' END
           + CASE WHEN r.Manufacturer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhManufacturer m WHERE m.CompanyId = @CompanyId AND m.ManufacturerName = r.Manufacturer) THEN N', manufacturer' ELSE N'' END
           + CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.PhHsn h WHERE h.CompanyId = @CompanyId AND h.HsnCode = r.HsnCode) THEN N', HSN' ELSE N'' END
           + CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
                                   WHERE c.CompanyId = @CompanyId AND ((r.SubCat IS NULL AND c.ParentCategoryId IS NULL AND c.CategoryName = r.MainCat) OR (c.CategoryName = r.SubCat AND p.CategoryName = r.MainCat))) THEN N', category' ELSE N'' END
           + CASE WHEN r.DosageForm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhDosageForm d WHERE d.CompanyId = @CompanyId AND (d.ShortName = r.DosageForm OR d.DosageFormName = r.DosageForm)) THEN N', dosage form' ELSE N'' END
           + CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.PhUom u WHERE u.CompanyId = @CompanyId AND u.UomCode = r.PurchaseUnit)
                    OR NOT EXISTS (SELECT 1 FROM dbo.PhUom u WHERE u.CompanyId = @CompanyId AND u.UomCode = r.SaleUnit) THEN N', unit' ELSE N'' END, 1, 2, N'')
      FROM #R r WHERE r.Status = 'NEW'
       AND (   (r.GenericName IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhGeneric g WHERE g.CompanyId = @CompanyId AND g.GenericName = r.GenericName))
            OR (r.Manufacturer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhManufacturer m WHERE m.CompanyId = @CompanyId AND m.ManufacturerName = r.Manufacturer))
            OR NOT EXISTS (SELECT 1 FROM dbo.PhHsn h WHERE h.CompanyId = @CompanyId AND h.HsnCode = r.HsnCode)
            OR NOT EXISTS (SELECT 1 FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
                           WHERE c.CompanyId = @CompanyId AND ((r.SubCat IS NULL AND c.ParentCategoryId IS NULL AND c.CategoryName = r.MainCat) OR (c.CategoryName = r.SubCat AND p.CategoryName = r.MainCat)))
            OR (r.DosageForm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhDosageForm d WHERE d.CompanyId = @CompanyId AND (d.ShortName = r.DosageForm OR d.DosageFormName = r.DosageForm)))
            OR NOT EXISTS (SELECT 1 FROM dbo.PhUom u WHERE u.CompanyId = @CompanyId AND u.UomCode = r.PurchaseUnit)
            OR NOT EXISTS (SELECT 1 FROM dbo.PhUom u WHERE u.CompanyId = @CompanyId AND u.UomCode = r.SaleUnit));

    IF @Commit = 1 AND EXISTS (SELECT 1 FROM #R WHERE Status = 'NEW')
    BEGIN
        BEGIN TRAN;
        -- masters first
        INSERT dbo.PhGeneric (CompanyId, GenericName, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, r.GenericName, 1, @UserId FROM #R r
         WHERE r.Status = 'NEW' AND r.GenericName IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhGeneric g WHERE g.CompanyId = @CompanyId AND g.GenericName = r.GenericName);
        INSERT dbo.PhManufacturer (CompanyId, ManufacturerName, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, r.Manufacturer, 1, @UserId FROM #R r
         WHERE r.Status = 'NEW' AND r.Manufacturer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhManufacturer m WHERE m.CompanyId = @CompanyId AND m.ManufacturerName = r.Manufacturer);
        INSERT dbo.PhHsn (CompanyId, HsnCode, Description, GstPercent, CessPercent, EffectiveFrom, IsActive, CreatedBy)
        SELECT @CompanyId, x.HsnCode, N'HSN ' + x.HsnCode, x.Gst, 0, CAST(GETDATE() AS DATE), 1, @UserId
          FROM (SELECT r.HsnCode, MAX(r.GstPercent) AS Gst FROM #R r WHERE r.Status = 'NEW' GROUP BY r.HsnCode) x
         WHERE NOT EXISTS (SELECT 1 FROM dbo.PhHsn h WHERE h.CompanyId = @CompanyId AND h.HsnCode = x.HsnCode);
        INSERT dbo.PhUom (CompanyId, UomCode, UomName, SortOrder, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, u.Code, u.Code, 100, 1, @UserId
          FROM #R r CROSS APPLY (VALUES (r.PurchaseUnit), (r.SaleUnit)) u(Code)
         WHERE r.Status = 'NEW' AND NOT EXISTS (SELECT 1 FROM dbo.PhUom x WHERE x.CompanyId = @CompanyId AND x.UomCode = u.Code);
        INSERT dbo.PhDosageForm (CompanyId, DosageFormName, ShortName, SortOrder, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, r.DosageForm, LEFT(UPPER(r.DosageForm), 10), 100, 1, @UserId FROM #R r
         WHERE r.Status = 'NEW' AND r.DosageForm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhDosageForm d WHERE d.CompanyId = @CompanyId AND (d.ShortName = r.DosageForm OR d.DosageFormName = r.DosageForm));
        INSERT dbo.PhCategory (CompanyId, CategoryName, ParentCategoryId, SortOrder, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, r.MainCat, NULL, 100, 1, @UserId FROM #R r
         WHERE r.Status = 'NEW' AND NOT EXISTS (SELECT 1 FROM dbo.PhCategory c WHERE c.CompanyId = @CompanyId AND c.ParentCategoryId IS NULL AND c.CategoryName = r.MainCat);
        INSERT dbo.PhCategory (CompanyId, CategoryName, ParentCategoryId, SortOrder, IsActive, CreatedBy)
        SELECT DISTINCT @CompanyId, r.SubCat, p.CategoryId, 100, 1, @UserId FROM #R r
          JOIN dbo.PhCategory p ON p.CompanyId = @CompanyId AND p.ParentCategoryId IS NULL AND p.CategoryName = r.MainCat
         WHERE r.Status = 'NEW' AND r.SubCat IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PhCategory c WHERE c.CompanyId = @CompanyId AND c.ParentCategoryId = p.CategoryId AND c.CategoryName = r.SubCat);

        -- items: codes after the highest one
        DECLARE @base INT = ISNULL((SELECT MAX(ItemId) FROM dbo.PhItem WITH (UPDLOCK, HOLDLOCK)), 0);
        DECLARE @Map TABLE (RowNo INT, ItemId INT);
        INSERT dbo.PhItem (CompanyId, ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId, PurchaseUomId, SaleUomId,
               ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, IsLasa, IsReturnable, IsDiscountAllowed, PrescriptionRequired, Barcode, ReorderLevel, MinQty, MaxQty,
               LeadDays, Remarks, IsActive, CreatedBy, VedClass)
        OUTPUT inserted.ItemId, inserted.ItemCode INTO #Out (ItemId, ItemCode)
        SELECT @CompanyId, 'PH' + RIGHT('00000' + CAST(@base + ROW_NUMBER() OVER (ORDER BY r.RowNo) AS VARCHAR(10)), 5), r.ItemName,
               (SELECT TOP 1 GenericId FROM dbo.PhGeneric WHERE CompanyId = @CompanyId AND GenericName = r.GenericName),
               (SELECT TOP 1 ManufacturerId FROM dbo.PhManufacturer WHERE CompanyId = @CompanyId AND ManufacturerName = r.Manufacturer),
               ISNULL((SELECT TOP 1 c.CategoryId FROM dbo.PhCategory c JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
                        WHERE c.CompanyId = @CompanyId AND r.SubCat IS NOT NULL AND c.CategoryName = r.SubCat AND p.CategoryName = r.MainCat),
                      (SELECT TOP 1 CategoryId FROM dbo.PhCategory WHERE CompanyId = @CompanyId AND ParentCategoryId IS NULL AND CategoryName = r.MainCat)),
               (SELECT TOP 1 DosageFormId FROM dbo.PhDosageForm WHERE CompanyId = @CompanyId AND (ShortName = r.DosageForm OR DosageFormName = r.DosageForm) ORDER BY CASE WHEN ShortName = r.DosageForm THEN 0 ELSE 1 END),
               r.Strength, r.PackSize, r.Schedule,
               (SELECT TOP 1 HsnId FROM dbo.PhHsn WHERE CompanyId = @CompanyId AND HsnCode = r.HsnCode),
               (SELECT TOP 1 UomId FROM dbo.PhUom WHERE CompanyId = @CompanyId AND UomCode = r.PurchaseUnit),
               (SELECT TOP 1 UomId FROM dbo.PhUom WHERE CompanyId = @CompanyId AND UomCode = r.SaleUnit),
               r.ConversionQty, r.LooseSale, r.ColdChain, r.HighAlert, r.Lasa,
               CASE WHEN r.Schedule IN ('X', 'NDPS') THEN 0 ELSE r.Returnable END, r.DiscountAllowed,
               CASE WHEN r.Schedule IN ('H1', 'X', 'NDPS') THEN 1 ELSE ISNULL(r.RxRequired, CASE WHEN r.Schedule IN ('H', 'G') THEN 1 ELSE 0 END) END,
               r.Barcode, r.ReorderLevel, r.MinQty, r.MaxQty, r.LeadDays, r.Remarks, 1, @UserId, r.VedClass
          FROM #R r WHERE r.Status = 'NEW' ORDER BY r.RowNo;
        COMMIT;
        -- the new codes go back to their rows (codes follow the row order)
        UPDATE r SET Status = 'ADDED', Message = N'Added as ' + o.ItemCode + N'.', ItemId = o.ItemId
          FROM #R r JOIN (SELECT ItemId, ItemCode, ROW_NUMBER() OVER (ORDER BY ItemCode) AS k FROM #Out) o
            ON o.k = (SELECT COUNT(*) FROM #R x WHERE x.Status = 'NEW' AND x.RowNo <= r.RowNo)
         WHERE r.Status = 'NEW';
    END

    SELECT RowNo, ItemName, Manufacturer, Schedule, Status, Message FROM #R ORDER BY RowNo;
    SELECT COUNT(*) AS Total, SUM(CASE WHEN Status IN ('NEW', 'ADDED') THEN 1 ELSE 0 END) AS ToAdd, SUM(CASE WHEN Status = 'ADDED' THEN 1 ELSE 0 END) AS Added,
           SUM(CASE WHEN Status = 'SKIP' THEN 1 ELSE 0 END) AS Skipped, SUM(CASE WHEN Status = 'ERROR' THEN 1 ELSE 0 END) AS Errors
      FROM #R;
END
GO

-- page control: Item / Drug Master > Import
DECLARE @co INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'MASTER.PH_ITEMS' AND CompanyId = @co;
    IF @page IS NOT NULL
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'IMPORT', @Title = N'Import items from Excel / standard list', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'PharmacyItems', @Action = N'Import', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'PharmacyItems', @Action = N'ImportTemplate', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PharmacyItems', @Action = N'ImportCheck', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PharmacyItems', @Action = N'ImportRun', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2411 applied: Pharmacy Item Master bulk import.';
GO
