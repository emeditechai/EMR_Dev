-- =============================================================
-- Migration: Add CollectionType, PhlebotomistId, BookingDate to LabOrder
-- and update usp_CreateLabOrder, usp_LabOrder_GetDetail, usp_LabOrder_GetPagedList
-- =============================================================

-- 1. Add columns to dbo.LabOrder if not exists
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabOrder' AND COLUMN_NAME = 'CollectionType')
BEGIN
    ALTER TABLE dbo.LabOrder ADD CollectionType NVARCHAR(50) NOT NULL CONSTRAINT DF_LabOrder_CollectionType DEFAULT 'Lab';
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabOrder' AND COLUMN_NAME = 'PhlebotomistId')
BEGIN
    ALTER TABLE dbo.LabOrder ADD PhlebotomistId INT NULL;
    ALTER TABLE dbo.LabOrder ADD CONSTRAINT FK_LabOrder_Phlebotomist FOREIGN KEY (PhlebotomistId) REFERENCES dbo.Users(Id);
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabOrder' AND COLUMN_NAME = 'BookingDate')
BEGIN
    ALTER TABLE dbo.LabOrder ADD BookingDate DATETIME NULL;
END
GO

-- 2. Update dbo.usp_CreateLabOrder
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

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @CreatedBy, GETDATE(), 1);
        
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

-- 3. Update dbo.usp_LabOrder_GetDetail
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetDetail
(
    @LabOrderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    -- RS1: Order Header & Patient Info
    SELECT 
        o.LabOrderId,
        o.PatientId,
        o.BranchId,
        b.BranchName,
        o.OrderDate,
        o.BillNo,
        o.TokenNo,
        o.TotalAmount,
        o.CollectionType,
        o.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        u.FullName AS CreatedByName,
        p.PatientCode,
        (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
        p.PhoneNumber,
        p.EmailId,
        p.Gender,
        p.DateOfBirth,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        p.Address,
        ph.PaymentHeaderId,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
        ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
        ISNULL(ph.NetAmount, o.TotalAmount)  AS NetAmount,
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    WHERE o.LabOrderId = @LabOrderId;

    -- RS2: Line Items
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        stm.Sample_Name AS SampleType,
        lim.TAT_Hours AS TATHours,
        dm.DeptName AS DepartmentName,
        cm.Category_Name AS CategoryName,
        scm.SubCategory_Name AS SubCategoryName,
        loi.Price,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster cm ON cm.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster scm ON scm.SubCategory_ID = lim.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    WHERE loi.LabOrderId = @LabOrderId
    ORDER BY loi.LabOrderItemId;

    -- RS3: Payments Recorded (Payment Details)
    SELECT 
        pd.PaymentDetailId,
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        pd.PaymentDate,
        pd.ReceiptNo,
        pd.TransactionRef,
        pd.ChequeNo,
        pd.BankName,
        pd.UPIRefNo,
        pd.CardLast4,
        pd.Notes
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1;
END
GO

-- 4. Update dbo.usp_LabOrder_GetPagedList
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT 
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE WHEN ph.PaymentStatus = 'P' THEN 1 ELSE 0 END), 0) AS PaidCount,
        ISNULL(SUM(CASE WHEN ISNULL(ph.PaymentStatus, 'U') = 'U' THEN 1 ELSE 0 END), 0) AS UnpaidCount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (
          @Search IS NULL 
          OR o.BillNo LIKE '%' + @Search + '%' 
          OR o.TokenNo LIKE '%' + @Search + '%'
          OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p 
              WHERE p.PatientId = o.PatientId 
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      );

    -- Paged Items
    WITH PagedOrders AS (
        SELECT 
            o.LabOrderId,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.CollectionType,
            o.PhlebotomistId,
            phleb.FullName AS PhlebotomistName,
            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE 
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL 
            END AS Age,
            ph.PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
            u.FullName AS CreatedByName,
            (
                SELECT COUNT(1) 
                FROM dbo.LabOrderItem loi 
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS ItemCount,
            (
                SELECT STRING_AGG(lim.Test_Name, ', ')
                FROM dbo.LabOrderItem loi
                INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS TestNamesSummary,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (
              @Search IS NULL 
              OR o.BillNo LIKE '%' + @Search + '%' 
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR p.FirstName LIKE '%' + @Search + '%'
              OR p.LastName LIKE '%' + @Search + '%'
              OR p.PhoneNumber LIKE '%' + @Search + '%'
              OR p.PatientCode LIKE '%' + @Search + '%'
          )
    )
    SELECT * FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY RowNum;
END
GO
