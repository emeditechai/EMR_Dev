-- =================================================================================
-- Script: 2027_add_packages_to_lab_booking.sql
-- Description: Updates stored procedures to support Packages (Profile_Type = 2) 
--              with negative InvestigationIds.
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;
GO

-- ── 1. Update dbo.usp_GetAvailableInvestigations ────────────────────────────────
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
        -(h.Profile_ID) as InvestigationId,
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
    WHERE h.Profile_Type = 2 
      AND h.Status = 1 AND h.IsDeleted = 0
      -- Packages are typically cross-departmental, so we don't filter them out when a specific department/category is selected
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
END
GO

-- ── 2. Update dbo.usp_CreateSampleCollectionFromLabOrder ────────────────────────
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

    CREATE TABLE #TestsToInsert (
        InvestigationId INT,
        DepartmentId    INT,
        CategoryId      INT,
        SubCategoryId   INT
    );

    -- 1A. Packages (InvestigationId < 0): Direct tests under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = ABS(loi.InvestigationId) AND loi.InvestigationId < 0
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

    -- 1B. Packages (InvestigationId < 0): Tests under profiles that are under the package
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON h.Profile_ID = ABS(loi.InvestigationId) AND loi.InvestigationId < 0
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

    -- 2. Profiles (InvestigationId > 0, Is_Profile_Test = 1): Tests under regular profiles
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
      AND loi.InvestigationId > 0
      AND loi.IsActive = 1;

    -- 3. Non-profile regular individual tests (InvestigationId > 0)
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
      AND loi.InvestigationId > 0
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

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
        ti.DepartmentId,
        ti.CategoryId,
        ti.SubCategoryId,
        ti.SubCategoryId,
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

-- ── 3. Update dbo.usp_Bill_GetDetailForCancellation ────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Bill_GetDetailForCancellation
    @ModuleCode CHAR(3),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            lo.LabOrderId          AS ModuleRefId,
            'LAB'                  AS ModuleCode,
            lo.BillNo,
            lo.OrderDate           AS BillDate,
            lo.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, lo.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.LabOrder lo
        INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = lo.BranchId
        WHERE lo.LabOrderId = @ModuleRefId;

        SELECT
            loi.LabOrderItemId   AS LineRefId,
            loi.LabOrderId       AS ModuleRefId,
            ISNULL(lm.Test_Name, pkg.Profile_Name) AS ItemName,
            ISNULL(lm.Test_Code, pkg.Profile_Code) AS ItemCode,
            loi.Price            AS OriginalAmount,
            ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)    AS DiscountAmount,
            loi.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN loi.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = loi.LabOrderItemId AND bc.ModuleCode = 'LAB' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            lst.Sample_Name      AS SampleTypeName,
            dm.DeptName          AS DepartmentName,
            lc.Category_Name     AS CategoryName
        FROM dbo.LabOrderItem loi
        LEFT JOIN dbo.LabInvestigationMaster lm   ON lm.Test_ID = loi.InvestigationId AND loi.InvestigationId > 0
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = ABS(loi.InvestigationId) AND loi.InvestigationId < 0
        LEFT JOIN dbo.LabSampleTypeMaster lst      ON lst.Sample_Type_ID = lm.Sample_Type_ID
        LEFT JOIN dbo.DepartmentMaster dm          ON dm.DeptId         = lm.Department_ID
        LEFT JOIN dbo.LabTestCategoryMaster lc     ON lc.Category_ID    = lm.Category_ID
        LEFT JOIN dbo.PaymentHeader ph            ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli         ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                                  AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
                                                  AND pli.IsActive = 1
        WHERE loi.LabOrderId = @ModuleRefId
        ORDER BY loi.LabOrderItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            os.OPDServiceId         AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            os.OPDBillNo            AS BillNo,
            os.VisitDate            AS BillDate,
            os.TotalAmount,
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation,'') + ' ' + p.FirstName + ' ' + ISNULL(p.LastName,''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.EmailId,
            p.Address,
            CASE WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) END AS Age,
            ISNULL(ph.PaymentHeaderId, 0)   AS PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U')   AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)         AS TotalPaid,
            ISNULL(ph.BalanceDue, os.TotalAmount) AS BalanceDue,
            ISNULL(ph.NetAmount, os.TotalAmount)  AS NetAmount,
            ISNULL(ph.HeaderDiscountAmount, 0)    AS TotalDiscountAmount,
            ISNULL(ph.LineDiscountTotal, 0)       AS LineDiscountTotal,
            ISNULL(ph.RoundOffAmount, 0)          AS RoundOffAmount,
            b.BranchName
        FROM dbo.PatientOPDService os
        INNER JOIN dbo.PatientMaster p ON p.PatientId = os.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = os.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.Branchmaster b ON b.BranchID = os.BranchId
        WHERE os.OPDServiceId = @ModuleRefId;

        SELECT
            si.ItemId             AS LineRefId,
            si.OPDServiceId       AS ModuleRefId,
            ISNULL(sm.ItemName, si.ServiceType) AS ItemName,
            si.ServiceType        AS ItemCode,
            si.ServiceCharges     AS OriginalAmount,
            ISNULL(pli.NetLineAmount, si.ServiceCharges) AS NetAmount,
            ISNULL(pli.LineDiscountAmount, 0)           AS DiscountAmount,
            si.IsActive,
            ISNULL(
                (SELECT SUM(bci.CancelledAmount) 
                 FROM dbo.BillCancellationItem bci
                 INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                 WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
            , 0) AS CancelledAmount,
            CASE WHEN si.IsActive = 0 THEN 1
                 WHEN EXISTS (SELECT 1 FROM dbo.BillCancellationItem bci
                              INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
                              WHERE bci.LineRefId = si.ItemId AND bc.ModuleCode = 'OPD' AND bc.IsActive = 1)
                 THEN 1 ELSE 0 END AS IsCancelled,
            NULL AS SampleTypeName,
            NULL AS DepartmentName,
            NULL AS CategoryName
        FROM dbo.PatientOPDServiceItem si
        LEFT JOIN dbo.ServiceMaster sm    ON sm.ServiceId = si.ServiceId
        LEFT JOIN dbo.PaymentHeader ph     ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
        LEFT JOIN dbo.PaymentLineItem pli  ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                                           AND pli.ModuleLineRefId = si.ItemId 
                                           AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId
        ORDER BY si.ItemId;

        SELECT
            pd.PaymentDetailId,
            pm.MethodName,
            pm.MethodCode,
            pd.PaidAmount,
            pd.PaymentDate,
            pd.ReceiptNo,
            pd.TransactionRef
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @ModuleRefId AND pd.IsActive = 1;
    END
END
GO

-- ── 4. Update dbo.usp_LabOrder_GetDetail ───────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetDetail
(
    @LabOrderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

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
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    WHERE o.LabOrderId = @LabOrderId;

    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        ISNULL(lim.Test_Code, pkg.Profile_Code) AS TestCode,
        ISNULL(lim.Test_Name, pkg.Profile_Name) AS TestName,
        stm.Sample_Name AS SampleType,
        ISNULL(lim.TAT_Hours, pkg.Profile_TAT_Hours) AS TATHours,
        dm.DeptName AS DepartmentName,
        cm.Category_Name AS CategoryName,
        scm.SubCategory_Name AS SubCategoryName,
        loi.Price,
        ISNULL(pli.LineDiscountAmount, 0) AS DiscountAmount,
        ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND loi.InvestigationId > 0
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = ABS(loi.InvestigationId) AND loi.InvestigationId < 0
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
