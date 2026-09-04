-- 1. Add ModuleCode to Sequence tables to segregate OPD and LAB incrementing IDs
ALTER TABLE dbo.OPDBillSequence ADD ModuleCode NVARCHAR(10) NOT NULL DEFAULT 'OPD';
ALTER TABLE dbo.OPDTokenSequence ADD ModuleCode NVARCHAR(10) NOT NULL DEFAULT 'OPD';

ALTER TABLE dbo.OPDBillSequence DROP CONSTRAINT PK_OPDBillSequence;
ALTER TABLE dbo.OPDBillSequence ADD CONSTRAINT PK_OPDBillSequence PRIMARY KEY (BranchId, FinancialYear, ModuleCode);

ALTER TABLE dbo.OPDTokenSequence DROP CONSTRAINT PK_OPDTokenSequence;
ALTER TABLE dbo.OPDTokenSequence ADD CONSTRAINT PK_OPDTokenSequence PRIMARY KEY (BranchId, TokenDate, ModuleCode);

-- 2. Add TokenNo to LabOrder
ALTER TABLE dbo.LabOrder ADD TokenNo NVARCHAR(50) NULL;
GO

-- 3. Update CreateLabOrder to generate Bill No (e.g., LAB/HO2627000001)
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

        -- Insert Header with temp BillNo
        INSERT INTO dbo.LabOrder (PatientId, BranchId, OrderDate, BillNo, TotalAmount, CreatedBy, CreatedDate, IsActive)
        VALUES (@PatientId, @BranchId, GETDATE(), 'TEMP', @TotalAmount, @CreatedBy, GETDATE(), 1);
        
        SET @LabOrderId = SCOPE_IDENTITY();
        
        -- Generate Bill No based on OPDBillSequence
        DECLARE @BranchCode NVARCHAR(20);
        SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
        FROM dbo.Branchmaster WHERE BranchID = @BranchId;
        IF @BranchCode IS NULL SET @BranchCode = 'BR';

        DECLARE @Today DATE = CAST(GETDATE() AS DATE);
        DECLARE @CalYear INT = YEAR(@Today);
        DECLARE @Month INT = MONTH(@Today);
        DECLARE @FYStart INT = CASE WHEN @Month >= 4 THEN @CalYear ELSE @CalYear - 1 END;
        DECLARE @FYEnd INT = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear END;
        DECLARE @FY NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

        IF NOT EXISTS (SELECT 1 FROM dbo.OPDBillSequence WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB')
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq) VALUES (@BranchId, @FY, 'LAB', 0);

        UPDATE dbo.OPDBillSequence SET LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';

        DECLARE @Seq INT;
        SELECT @Seq = LastSeq FROM dbo.OPDBillSequence WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';

        SET @BillNo = 'LAB/' + @BranchCode + @FY + RIGHT('000000' + CAST(@Seq AS NVARCHAR(10)), 6);
        
        -- Update BillNo
        UPDATE dbo.LabOrder SET BillNo = @BillNo WHERE LabOrderId = @LabOrderId;

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

-- 4. Create Token Generation for LAB (e.g., LAB-HO-0001)
CREATE OR ALTER PROCEDURE dbo.usp_LAB_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.BranchMaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'BR';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq)
            VALUES (@BranchId, @TokenDate, 'LAB', 1);
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 2627 OR ERROR_NUMBER() = 2601
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'LAB';
            END
            ELSE THROW;
        END CATCH
    END

    SET @TokenNo = 'LAB-' + @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_LAB_AssignTokenOnPayment
    @LabOrderId     INT,
    @TokenNo        NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(OrderDate AS DATE),
                @ExistingToken   = TokenNo
        FROM    dbo.LabOrder WITH (UPDLOCK, ROWLOCK)
        WHERE   LabOrderId = @LabOrderId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;
            COMMIT TRANSACTION;
            RETURN;
        END

        EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;

        UPDATE dbo.LabOrder
        SET    TokenNo = @TokenNo
        WHERE  LabOrderId = @LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- 5. Update Payment Summary SP to fetch the TokenNo for LAB module
ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            s.OPDServiceId          AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            s.OPDServiceId,
            s.OPDBillNo,
            s.TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)  AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM PatientOPDService s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.OPDServiceId = @ModuleRefId;

        DECLARE @PaymentHeaderId_OPD INT;
        SELECT @PaymentHeaderId_OPD = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.ItemId                        AS LineRefId,
            si.ServiceType,
            ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
            ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.ServiceCharges, 0)) AS NetLineAmount,
            ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
            sm.GstPercentage                 AS GstPercentage,
            ISNULL(pli.CgstAmount, 0)        AS CgstAmount,
            ISNULL(pli.SgstAmount, 0)        AS SgstAmount,
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount
        FROM PatientOPDServiceItem si
        LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_OPD AND pli.ModuleLineRefId = si.ItemId AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.ItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_OPD;
    END
    ELSE IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            s.LabOrderId            AS ModuleRefId,
            'LAB'                   AS ModuleCode,
            s.LabOrderId            AS OPDServiceId, 
            s.BillNo                AS OPDBillNo,
            s.TokenNo               AS TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)   AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM LabOrder s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.LabOrderId = @ModuleRefId;

        DECLARE @PaymentHeaderId_LAB INT;
        SELECT @PaymentHeaderId_LAB = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.LabOrderItemId                AS LineRefId,
            'Test'                           AS ServiceType,
            ISNULL(im.Test_Name, '(Unknown)') AS ItemName,
            ISNULL(si.Price, 0)              AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.Price, 0)) AS NetLineAmount,
            0                                AS IsGstRequired,
            0                                AS GstPercentage,
            0                                AS CgstAmount,
            0                                AS SgstAmount,
            0                                AS IgstAmount
        FROM LabOrderItem si
        LEFT JOIN LabInvestigationMaster im ON im.Test_ID = si.InvestigationId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_LAB AND pli.ModuleLineRefId = si.LabOrderItemId AND pli.IsActive = 1
        WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.LabOrderItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_LAB;
    END
END

-- 6. Demographics only insert stored procedure
CREATE OR ALTER PROCEDURE dbo.usp_PatientMaster_Insert
(
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE            = NULL,
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @Address                NVARCHAR(500)   = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @CompanyId              INT             = NULL,
    @CreatedBy              INT             = NULL,

    @PatientCode            NVARCHAR(50)    OUTPUT,
    @NewPatientId           INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName NVARCHAR(100);
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check: PhoneNumber + RelationId
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE  PhoneNumber = @PhoneNumber
              AND  RelationId  = @RelationId
              AND  IsActive    = 1
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @CreatedBy, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO

-- 7. Lab Order Paged List SP
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
(
    @BranchId    INT,
    @FromDate    DATE           = NULL,
    @ToDate      DATE           = NULL,
    @Search      NVARCHAR(100)  = NULL,
    @PageNumber  INT            = 1,
    @PageSize    INT            = 10
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, CAST(GETDATE() AS DATE)));
    SET @ToDate   = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    SET @Search   = NULLIF(LTRIM(RTRIM(@Search)), '');

    -- RS1: Stats Summary
    ;WITH FilteredOrders AS (
        SELECT 
            o.LabOrderId,
            o.TotalAmount,
            o.IsActive,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (
              @Search IS NULL OR
              o.BillNo LIKE '%' + @Search + '%' OR
              o.TokenNo LIKE '%' + @Search + '%' OR
              p.PatientCode LIKE '%' + @Search + '%' OR
              p.FirstName LIKE '%' + @Search + '%' OR
              p.LastName LIKE '%' + @Search + '%' OR
              p.PhoneNumber LIKE '%' + @Search + '%'
          )
    )
    SELECT 
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(TotalAmount), 0) AS TotalAmount,
        ISNULL(SUM(CASE WHEN PaymentStatus = 'P' THEN 1 ELSE 0 END), 0) AS PaidCount,
        ISNULL(SUM(CASE WHEN PaymentStatus IN ('U', 'R') THEN 1 ELSE 0 END), 0) AS UnpaidCount
    FROM FilteredOrders;

    -- RS2: Paged Orders
    ;WITH FilteredOrders AS (
        SELECT 
            o.LabOrderId,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
            ph.PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
            ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
            u.FullName                    AS CreatedByName,
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
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.UserMaster u ON u.Id = o.CreatedBy
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
          AND (
              @Search IS NULL OR
              o.BillNo LIKE '%' + @Search + '%' OR
              o.TokenNo LIKE '%' + @Search + '%' OR
              p.PatientCode LIKE '%' + @Search + '%' OR
              p.FirstName LIKE '%' + @Search + '%' OR
              p.LastName LIKE '%' + @Search + '%' OR
              p.PhoneNumber LIKE '%' + @Search + '%'
          )
    )
    SELECT *
    FROM FilteredOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY RowNum;
END
GO

-- 8. Lab Order Detail SP
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
    LEFT JOIN dbo.UserMaster u ON u.Id = o.CreatedBy
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
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1
    ORDER BY pd.PaymentDetailId;
END
GO
