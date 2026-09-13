-- ============================================================================
-- Migration: 2048_add_b2b_lab_order_billing.sql
-- Description:
--   1. Add B2B columns to LabOrder (IsB2B, B2BAgentID, AgentType, B2BTotal).
--   2. Add B2BRate column to LabOrderItem.
--   3. Recreate udt_LabOrderItem with B2BRate DECIMAL(18,2) NULL.
--   4. Update usp_CreateLabOrder with B2B parameters and insertion.
--   5. Update usp_GetAvailableInvestigations to support @RateType and @AgentId.
--   6. Update usp_LabOrder_GetPagedList to support @IsB2B, AgentName, B2BTotal.
--   7. Update usp_LabOrder_GetDetail to return B2B fields in Header and Items.
-- ============================================================================

-- ── 1. Alter dbo.LabOrder ───────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrder') AND name = 'IsB2B')
BEGIN
    ALTER TABLE dbo.LabOrder ADD IsB2B BIT NOT NULL CONSTRAINT DF_LabOrder_IsB2B DEFAULT 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrder') AND name = 'B2BAgentID')
BEGIN
    ALTER TABLE dbo.LabOrder ADD B2BAgentID INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrder') AND name = 'AgentType')
BEGIN
    ALTER TABLE dbo.LabOrder ADD AgentType VARCHAR(10) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrder') AND name = 'B2BTotal')
BEGIN
    ALTER TABLE dbo.LabOrder ADD B2BTotal DECIMAL(18,2) NULL;
END
GO

-- ── 2. Alter dbo.LabOrderItem ───────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LabOrderItem') AND name = 'B2BRate')
BEGIN
    ALTER TABLE dbo.LabOrderItem ADD B2BRate DECIMAL(18,2) NULL;
END
GO

-- ── 3. Recreate dbo.udt_LabOrderItem ─────────────────────────────────────────
-- Drop usp_CreateLabOrder first because it references udt_LabOrderItem
IF OBJECT_ID('dbo.usp_CreateLabOrder', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CreateLabOrder;
GO

IF TYPE_ID('dbo.udt_LabOrderItem') IS NOT NULL
    DROP TYPE dbo.udt_LabOrderItem;
GO

CREATE TYPE dbo.udt_LabOrderItem AS TABLE
(
    InvestigationId INT NOT NULL,
    [Type] CHAR(1) NULL,
    Price DECIMAL(18,2) NOT NULL,
    IsUrgent BIT NOT NULL,
    B2BRate DECIMAL(18,2) NULL
);
GO

-- ── 4. Recreate dbo.usp_CreateLabOrder ───────────────────────────────────────
CREATE PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @IsB2B            BIT          = 0,
    @B2BAgentID       INT          = NULL,
    @AgentType        VARCHAR(10)  = NULL,
    @B2BTotal         DECIMAL(18,2)= NULL,
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

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items (include Type, IsUrgent, and B2BRate from @Items)
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive, B2BRate)
        SELECT 
            @LabOrderId, 
            InvestigationId, 
            ISNULL(NULLIF([Type], ''), 'I'), 
            Price, 
            ISNULL(IsUrgent, 0), 
            @CreatedBy, 
            GETDATE(), 
            1,
            B2BRate
        FROM @Items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 5. Update dbo.usp_GetAvailableInvestigations ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL,
    @Gender VARCHAR(20) = NULL,
    @AgeInYears INT = NULL,
    @RateType VARCHAR(50) = 'B2C',
    @AgentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        i.Test_ID as InvestigationId,
        i.Test_Code as TestCode,
        i.Test_Name as TestName,
        i.TAT_Hours as TATHours,
        COALESCE(db2c.Rate, i.MRP, 0) as MRP,
        CAST(ISNULL(i.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        st.Sample_Name as SampleType,
        tm.Method_Name as Method,
        CAST(ISNULL(COALESCE(db2b.Is_Discount_Allowed, db2c.Is_Discount_Allowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(0 AS BIT) as IsPackage,
        CAST(ISNULL(i.Is_Outsourced, 0) AS BIT) as IsOutsourced,
        COALESCE(db2b.Rate, db2c.Rate, i.MRP, 0) as B2BRate
    FROM LabInvestigationMaster i
    LEFT JOIN LabRateCardMaster mb2c ON mb2c.Branch_ID = @BranchId 
        AND mb2c.Rate_Type = 'B2C' 
        AND mb2c.Status = 1 
        AND mb2c.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2c.Effective_From AND mb2c.Effective_To
    LEFT JOIN LabRateCardDetail db2c ON db2c.RateCard_ID = mb2c.RateCard_ID 
        AND db2c.Item_ID = i.Test_ID 
        AND db2c.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND db2c.IsDeleted = 0
    LEFT JOIN LabRateCardMaster mb2b ON mb2b.Branch_ID = @BranchId 
        AND mb2b.Rate_Type = @RateType 
        AND mb2b.B2CIdentity_ID = @AgentId
        AND mb2b.Status = 1 
        AND mb2b.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2b.Effective_From AND mb2b.Effective_To
    LEFT JOIN LabRateCardDetail db2b ON db2b.RateCard_ID = mb2b.RateCard_ID 
        AND db2b.Item_ID = i.Test_ID 
        AND db2b.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
        AND db2b.IsDeleted = 0
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
        COALESCE(db2c.Rate, h.MRP, 0) as MRP,
        CAST(0 AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        NULL as SampleType,
        NULL as Method,
        CAST(ISNULL(COALESCE(db2b.Is_Discount_Allowed, db2c.Is_Discount_Allowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(1 AS BIT) as IsPackage,
        CAST(0 AS BIT) as IsOutsourced,
        COALESCE(db2b.Rate, db2c.Rate, h.MRP, 0) as B2BRate
    FROM LabInvestigationProfileHeader h
    LEFT JOIN LabRateCardMaster mb2c ON mb2c.Branch_ID = @BranchId 
        AND mb2c.Rate_Type = 'B2C' 
        AND mb2c.Status = 1 
        AND mb2c.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2c.Effective_From AND mb2c.Effective_To
    LEFT JOIN LabRateCardDetail db2c ON db2c.RateCard_ID = mb2c.RateCard_ID 
        AND db2c.Item_ID = h.Profile_ID 
        AND (db2c.Item_Type = 'Package' OR db2c.Item_Type = 'Profile')
        AND db2c.IsDeleted = 0
    LEFT JOIN LabRateCardMaster mb2b ON mb2b.Branch_ID = @BranchId 
        AND mb2b.Rate_Type = @RateType 
        AND mb2b.B2CIdentity_ID = @AgentId
        AND mb2b.Status = 1 
        AND mb2b.IsDeleted = 0 
        AND CAST(GETDATE() AS DATE) BETWEEN mb2b.Effective_From AND mb2b.Effective_To
    LEFT JOIN LabRateCardDetail db2b ON db2b.RateCard_ID = mb2b.RateCard_ID 
        AND db2b.Item_ID = h.Profile_ID 
        AND (db2b.Item_Type = 'Package' OR db2b.Item_Type = 'Profile')
        AND db2b.IsDeleted = 0
    WHERE h.Status = 1 AND h.IsDeleted = 0
      AND h.Profile_Type = 2 -- 2 = Package
      AND (@DepartmentId IS NULL) 
      AND (@CategoryId IS NULL) 
      AND (@SubCategoryId IS NULL)
      AND (
          h.Applicable_Gender = 'All' 
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
END;
GO

-- ── 6. Update dbo.usp_LabOrder_GetPagedList ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @IsB2B BIT = NULL
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
        ISNULL(SUM(CASE WHEN ISNULL(ph.PaymentStatus, 'U') = 'U' THEN 1 ELSE 0 END), 0) AS UnpaidCount,
        ISNULL(SUM(CASE WHEN o.IsB2B = 1 THEN ISNULL(o.B2BTotal, 0.00) ELSE 0.00 END), 0.00) AS B2BTotalAmount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
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
            o.IsUrgent,
            phleb.FullName AS PhlebotomistName,
            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            o.IsB2B,
            o.B2BAgentID,
            o.AgentType,
            o.B2BTotal,
            CASE 
                WHEN o.AgentType = 'F' THEN f.Franchise_Name
                WHEN o.AgentType = 'C' THEN corp.Corporate_Name
                ELSE NULL
            END AS AgentName,
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
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS ItemCount,
            (
                SELECT STRING_AGG(
                    CASE 
                        WHEN loi.Type = 'P' THEN ISNULL(pkg.Profile_Name, 'Package #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                        ELSE ISNULL(lim.Test_Name, 'Test #' + CAST(loi.InvestigationId AS VARCHAR(10)))
                    END, ', ')
                FROM dbo.LabOrderItem loi
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND (loi.Type = 'I' OR loi.Type IS NULL)
                LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                WHERE loi.LabOrderId = o.LabOrderId AND loi.IsActive = 1
            ) AS TestNamesSummary,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
          AND (
              @Search IS NULL 
              OR o.BillNo LIKE '%' + @Search + '%' 
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR p.FirstName LIKE '%' + @Search + '%'
              OR p.LastName LIKE '%' + @Search + '%'
              OR p.PhoneNumber LIKE '%' + @Search + '%'
              OR p.PatientCode LIKE '%' + @Search + '%'
              OR (o.AgentType = 'F' AND f.Franchise_Name LIKE '%' + @Search + '%')
              OR (o.AgentType = 'C' AND corp.Corporate_Name LIKE '%' + @Search + '%')
          )
    )
    SELECT * FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY RowNum;
END;
GO

-- ── 7. Update dbo.usp_LabOrder_GetDetail ─────────────────────────────────────
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
        o.IsUrgent,
        phleb.FullName AS PhlebotomistName,
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        u.FullName AS CreatedByName,
        o.IsB2B,
        o.B2BAgentID,
        o.AgentType,
        o.B2BTotal,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Name
            WHEN o.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS AgentName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
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
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.LabOrderId = @LabOrderId;

    -- RS2: Line Items (supports Type = 'P' packages and Type = 'I' investigations)
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        ISNULL(loi.Type, 'I') AS Type,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END AS TestName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE stm.Sample_Name END AS SampleType,
        CASE WHEN loi.Type = 'P' THEN CAST(ISNULL(pkg.Profile_TAT_Hours, 24) AS NVARCHAR(50)) ELSE CAST(lim.TAT_Hours AS NVARCHAR(50)) END AS TATHours,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE cm.Category_Name END AS CategoryName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE scm.SubCategory_Name END AS SubCategoryName,
        loi.Price,
        loi.B2BRate,
        loi.IsUrgent,
        ISNULL(pli.LineDiscountAmount, 0) AS DiscountAmount,
        ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster cm ON cm.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster scm ON scm.SubCategory_ID = lim.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
        AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
        AND pli.IsActive = 1
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
END;
GO
