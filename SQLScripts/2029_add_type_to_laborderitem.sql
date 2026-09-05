-- 1. Add Type column to LabOrderItem
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'LabOrderItem' 
      AND COLUMN_NAME = 'Type'
)
BEGIN
    ALTER TABLE dbo.LabOrderItem ADD Type CHAR(1) NOT NULL DEFAULT 'I';
END
GO

-- 2. Update existing packages to have Type = 'P' and make ID positive
UPDATE dbo.LabOrderItem 
SET Type = 'P', InvestigationId = ABS(InvestigationId) 
WHERE InvestigationId < 0;
GO

-- 3. Recreate the UDT (Requires dropping SP first)
DROP PROCEDURE IF EXISTS dbo.usp_CreateLabOrder;
DROP TYPE IF EXISTS dbo.udt_LabOrderItem;
GO

CREATE TYPE dbo.udt_LabOrderItem AS TABLE (
    InvestigationId INT,
    Type CHAR(1),
    Price DECIMAL(10,2)
);
GO

-- 4. Recreate usp_CreateLabOrder
CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount,
             CollectionType, PhlebotomistId, BookingDate,
             CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount,
             ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @BookingDate,
             @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Type, Price, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, ISNULL(Type, 'I'), Price, @CreatedBy, GETDATE(), 1
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 5. Update usp_GetAvailableInvestigations to return positive ID for packages
CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL,
    @Gender VARCHAR(20) = NULL,
    @AgeInYears INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        i.Test_ID as InvestigationId,
        i.Test_Code as TestCode,
        i.Test_Name as TestName,
        i.TAT_Hours as TATHours,
        COALESCE(d.Rate, i.MRP, 0) as MRP,
        CAST(ISNULL(i.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        st.Sample_Name as SampleType,
        tm.Method_Name as Method,
        CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) as IsDiscountAllowed,
        CAST(0 AS BIT) as IsPackage
    FROM LabInvestigationMaster i
    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = @BranchId 
        AND m.Rate_Type = 'B2C' 
        AND m.Status = 1 
        AND m.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
        AND d.Item_ID = i.Test_ID 
        AND d.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND d.IsDeleted = 0
    LEFT JOIN LabInvestigationProfileHeader h ON (h.Test_ID = i.Test_ID OR h.Profile_Name = i.Test_Name) AND h.IsDeleted = 0
    LEFT JOIN dbo.LabSampleTypeMaster st ON i.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON i.Method_ID = tm.Method_ID
    WHERE i.Status = 1 AND i.IsDeleted = 0
      AND i.Is_Billable = 1
      AND (@DepartmentId IS NULL OR i.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR i.Category_ID = @CategoryId)
      AND (@SubCategoryId IS NULL OR i.SubCategory_ID = @SubCategoryId)
      AND (
          i.Applicable_Gender = 'All' 
          OR @Gender IS NULL 
          OR i.Applicable_Gender = @Gender
      )
      AND (
          i.Age_Operator IS NULL 
          OR i.Age_Operator = '-- No Age Limit --' 
          OR @AgeInYears IS NULL 
          OR (i.Age_Operator = '=' AND @AgeInYears = i.Applicable_Age)
          OR (i.Age_Operator = '>=' AND @AgeInYears >= i.Applicable_Age)
          OR (i.Age_Operator = '<=' AND @AgeInYears <= i.Applicable_Age)
      )

    UNION ALL

    -- Packages (Profile_Type = 2)
    SELECT 
        h.Profile_ID as InvestigationId,
        h.Profile_Code as TestCode,
        h.Profile_Name as TestName,
        h.Profile_TAT_Hours as TATHours,
        COALESCE(d.Rate, h.MRP, 0) as MRP,
        CAST(0 AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        NULL as SampleType,
        NULL as Method,
        CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) as IsDiscountAllowed,
        CAST(1 AS BIT) as IsPackage
    FROM LabInvestigationProfileHeader h
    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = @BranchId 
        AND m.Rate_Type = 'B2C' 
        AND m.Status = 1 
        AND m.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
        AND d.Item_ID = h.Profile_ID 
        AND d.Item_Type = 'Package' 
        AND d.IsDeleted = 0
    WHERE h.Status = 1 AND h.IsDeleted = 0
      AND h.Profile_Type = 2
      -- Packages are typically cross-departmental, so we don't filter them out when a specific department/category is selected
      AND (
          h.Applicable_Gender = 'All Genders' 
          OR h.Applicable_Gender = 'All'
          OR @Gender IS NULL 
          OR h.Applicable_Gender = @Gender
      )
      AND (
          h.Age_Operator IS NULL 
          OR h.Age_Operator = '-- No Age Limit --' 
          OR @AgeInYears IS NULL 
          OR (h.Age_Operator = '=' AND @AgeInYears = h.Applicable_Age)
          OR (h.Age_Operator = '>=' AND @AgeInYears >= h.Applicable_Age)
          OR (h.Age_Operator = '<=' AND @AgeInYears <= h.Applicable_Age)
      )
    ORDER BY TestName;
END
GO

-- 6. Update usp_CreateSampleCollectionFromLabOrder to use Type = 'P'
CREATE OR ALTER PROCEDURE dbo.usp_CreateSampleCollectionFromLabOrder
    @LabOrderId INT,
    @BranchId   INT = NULL,
    @CompanyId  INT = NULL,
    @CreatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PatientId       INT;
    DECLARE @OrderDate       DATETIME;
    DECLARE @BookingDateTime DATETIME;
    DECLARE @TokenNo         NVARCHAR(50);
    DECLARE @OrderBranch     INT;

    SELECT 
        @PatientId       = PatientId,
        @OrderDate       = OrderDate,
        @BookingDateTime = BookingDate,
        @TokenNo         = TokenNo,
        @OrderBranch     = BranchId
    FROM dbo.LabOrder
    WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
    BEGIN
        RAISERROR('LabOrder with ID %d was not found.', 16, 1, @LabOrderId);
        RETURN;
    END

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = @OrderBranch;

    IF @CompanyId IS NULL OR @CompanyId <= 0
        SET @CompanyId = 1;

    -- If records already exist for this order, update TokenNo / Bookingdatetime if needed and return
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId)
    BEGIN
        UPDATE dbo.SampleCollection
        SET 
            TokenNo = ISNULL(@TokenNo, TokenNo),
            Bookingdatetime = ISNULL(@BookingDateTime, Bookingdatetime)
        WHERE Laborderid = @LabOrderId 
          AND (
              (@TokenNo IS NOT NULL AND (TokenNo IS NULL OR TokenNo <> @TokenNo))
              OR (@BookingDateTime IS NOT NULL AND (Bookingdatetime IS NULL OR Bookingdatetime <> @BookingDateTime))
          );

        SELECT COUNT(1) AS RowsCount FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId;
        RETURN;
    END

    -- Temporary table to hold resolved individual investigation tests
    CREATE TABLE #TestsToInsert (
        InvestigationId INT,
        DepartmentId    INT,
        CategoryId      INT,
        SubCategoryId   INT
    );

    -- 1A. Packages (Type = 'P'): Direct tests under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
       AND t.Is_Profile_Test = 0 -- Exclude profiles for now
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 1B. Packages (Type = 'P'): Tests under profiles that are under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail pd 
        ON pd.Profile_ID = h.Profile_ID 
       AND pd.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster pt 
        ON pt.Test_ID = pd.Test_ID AND pt.Is_Profile_Test = 1
    INNER JOIN dbo.LabInvestigationProfileHeader pheader 
        ON (pheader.Test_ID = pt.Test_ID OR pheader.Profile_Name = pt.Test_Name) AND pheader.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail child_d 
        ON child_d.Profile_ID = pheader.Profile_ID AND child_d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = child_d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 2. Profiles (Type = 'I' AND Is_Profile_Test = 1): Tests under regular profiles
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1;

    -- 3. Non-profile regular individual tests (Type = 'I' AND Is_Profile_Test = 0)
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = loi.InvestigationId 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.Type = 'I'
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

    -- Insert into SampleCollection table with Bookingdatetime
    INSERT INTO dbo.SampleCollection (
        Laborderid,
        BranchID,
        CompanyID,
        PatientID,
        TokenNo,
        InvestigationID,
        DepartmentID,
        DepartmentD,
        TestcategoryID,
        TestsubcategoryID,
        TestsubcategotyID,
        Orderdate,
        Bookingdatetime,
        Is_Active,
        Samplecollectiondate,
        Samplecollectiontime,
        Iscancelled,
        CreatedBy,
        CreatedDate
    )
    SELECT 
        @LabOrderId,
        @BranchId,
        @CompanyId,
        @PatientId,
        @TokenNo,
        ti.InvestigationId,
        ti.DepartmentId,
        ti.DepartmentId, -- DepartmentD alias
        ti.CategoryId,
        ti.SubCategoryId,
        ti.SubCategoryId, -- TestsubcategotyID alias
        @OrderDate,
        @BookingDateTime,
        1,
        NULL,
        NULL,
        0,
        @CreatedBy,
        GETDATE()
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO
