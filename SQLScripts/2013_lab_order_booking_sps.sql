-- ============================================================
-- 2013_lab_order_booking_sps.sql
-- Creates Stored Procedures for Lab Order Booking (End to End)
-- ============================================================

-- ── 1. Create UDTT for Lab Order Items ─────────────────────────
IF TYPE_ID('dbo.udt_LabOrderItem') IS NULL
BEGIN
    CREATE TYPE [dbo].[udt_LabOrderItem] AS TABLE(
        InvestigationId INT NOT NULL,
        Price DECIMAL(10,2) NOT NULL
    );
END
GO

-- ── 2. SP: Get Lab Departments ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_GetLabDepartments
AS
BEGIN
    SET NOCOUNT ON;
    -- Returns all active departments. Can filter by DeptType = 'LAB' if needed, but currently keeping it general based on existing code.
    SELECT 
        DeptId AS DepartmentId,
        DeptName AS DepartmentName
    FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND DeptType = 'LAB';
END
GO

-- ── 3. SP: Get Lab Categories ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_GetLabCategories
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        Category_ID AS CategoryId,
        Category_Name AS CategoryName
    FROM dbo.LabTestCategoryMaster
    WHERE Status = 1
      AND (@DepartmentId IS NULL OR Department_ID = @DepartmentId);
END
GO

-- ── 4. SP: Get Lab Sub Categories ──────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_GetLabSubCategories
    @CategoryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        SubCategory_ID AS SubCategoryId,
        SubCategory_Name AS SubCategoryName
    FROM dbo.LabTestSubCategoryMaster
    WHERE Status = 1
      AND (@CategoryId IS NULL OR Category_ID = @CategoryId);
END
GO

-- ── 5. SP: Get Available Investigations ────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL
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
        tm.Method_Name as Method
    FROM LabInvestigationMaster i
    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = @BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0 AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.Item_ID = i.Test_ID AND d.Item_Type = 'Test' AND d.IsDeleted = 0
    LEFT JOIN LabInvestigationProfileHeader h ON (h.Test_ID = i.Test_ID OR h.Profile_Name = i.Test_Name) AND h.IsDeleted = 0
    LEFT JOIN dbo.LabSampleTypeMaster st ON i.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON i.Method_ID = tm.Method_ID
    WHERE i.Status = 1 AND i.IsDeleted = 0
      AND (@DepartmentId IS NULL OR i.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR i.Category_ID = @CategoryId)
      AND (@SubCategoryId IS NULL OR i.SubCategory_ID = @SubCategoryId)
    ORDER BY i.Test_Name;
END
GO

-- ── 6. SP: Create Lab Order ────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId INT,
    @BranchId INT,
    @CreatedBy INT,
    @TotalAmount DECIMAL(10,2),
    @Items dbo.udt_LabOrderItem READONLY,
    @LabOrderId INT OUTPUT,
    @BillNo NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate Bill No using existing usp_OPD_GetNextBillNo
        EXEC dbo.usp_OPD_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        INSERT INTO dbo.LabOrder (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CreatedBy, CreatedDate, IsActive)
        VALUES (@PatientId, @BranchId, GETDATE(), @BillNo, @TotalAmount, @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, Price, CreatedBy, CreatedDate, IsActive)
        SELECT @LabOrderId, InvestigationId, Price, @CreatedBy, GETDATE(), 1
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
