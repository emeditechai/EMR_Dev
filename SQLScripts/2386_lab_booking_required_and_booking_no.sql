-- ============================================================================================================
-- Migration: 2386_lab_booking_required_and_booking_no.sql
-- B2C / B2B LAB booking: "Is Booking Req" (LabOrder.IsBookingRequired, default 0). With it on, the booking date & time is
-- taken from the screen and the order gets a booking number BK<BranchCode><FY><6-digit sequence>, e.g. BKHO2627000001,
-- counted per branch and financial year (Apr-Mar) in dbo.OPDBillSequence (ModuleCode 'LABBK'), so it restarts every year.
-- With it off nothing changes (booking date = billing time, no booking number).
--   usp_LabOrder_SetBooking: called right after usp_CreateLabOrder (which is not changed) to mark the order and give it
--   its number. usp_LabOrder_GetDetail / usp_LabOrder_GetPagedList (live definitions) also return BookingNo and
--   IsBookingRequired, and the list search finds a booking number. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabOrder', 'IsBookingRequired') IS NULL
    ALTER TABLE dbo.LabOrder ADD IsBookingRequired BIT NOT NULL CONSTRAINT DF_LabOrder_IsBookingRequired DEFAULT (0);
GO
IF COL_LENGTH('dbo.LabOrder', 'BookingNo') IS NULL
    ALTER TABLE dbo.LabOrder ADD BookingNo NVARCHAR(30) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabOrder_BookingNo')
    CREATE UNIQUE INDEX UX_LabOrder_BookingNo ON dbo.LabOrder (BookingNo) WHERE BookingNo IS NOT NULL;
GO

-- next booking number of a branch: BK<BranchCode><FY><6 digits>, the sequence restarts each financial year
CREATE OR ALTER PROCEDURE dbo.usp_LAB_GetNextBookingNo
    @BranchId  INT,
    @BookingNo NVARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.Branchmaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL OR @BranchCode = '' SET @BranchCode = 'BR';

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @FYStart INT = CASE WHEN MONTH(@Today) >= 4 THEN YEAR(@Today) ELSE YEAR(@Today) - 1 END;
    DECLARE @FY NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYStart + 1 AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;
    UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LABBK';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @FY, 'LABBK', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
                UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LABBK';
            ELSE THROW;
        END CATCH
    END
    SET @BookingNo = 'BK' + @BranchCode + @FY + RIGHT('000000' + CAST(@NewSeq AS NVARCHAR(10)), 6);
END
GO

-- after usp_CreateLabOrder: "Is Booking Req" on -> mark the order and give it its booking number (once)
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_SetBooking
    @LabOrderId        INT,
    @IsBookingRequired BIT,
    @BookingNo         NVARCHAR(30) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @BookingNo = BookingNo FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;
    IF ISNULL(@IsBookingRequired, 0) = 0 OR @BookingNo IS NOT NULL RETURN;

    DECLARE @BranchId INT = (SELECT BranchId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId);
    IF @BranchId IS NULL RETURN;
    BEGIN TRANSACTION;
        EXEC dbo.usp_LAB_GetNextBookingNo @BranchId = @BranchId, @BookingNo = @BookingNo OUTPUT;
        UPDATE dbo.LabOrder SET IsBookingRequired = 1, BookingNo = @BookingNo WHERE LabOrderId = @LabOrderId;
    COMMIT TRANSACTION;
END
GO

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
        o.BookingNo,                                             -- 2386
        CAST(ISNULL(o.IsBookingRequired, 0) AS BIT) AS IsBookingRequired,
        o.TotalAmount,
        o.CollectionType,
        o.PhlebotomistId,
        o.IsUrgent,
        phleb.FullName AS PhlebotomistName,
        ISNULL(o.RefDoctorId, o.ReferralDoctorId) AS ReferralDoctorId,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctorName,
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        ISNULL(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
        u.Username AS CreatedByUsername,
        o.IsB2B,
        o.B2BAgentID,
        o.AgentType,
        o.B2BTotal,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Name
            WHEN o.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS AgentName,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Code
            WHEN o.AgentType = 'C' THEN corp.Corporate_Code
            ELSE NULL
        END AS AgentCode,
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
        CASE 
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
            WHEN o.IsB2B = 1 THEN 'U'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
        CASE 
            WHEN o.IsB2B = 1 THEN 
                CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00 
                     ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
            ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
        END AS BalanceDue,
        ISNULL(ph.NetAmount, o.TotalAmount)  AS NetAmount,
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount,
        -- why the discount was given and who approved / entered it (asked at billing since 2121)
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), '') AS DiscountReason,
        ph.DiscountApprovedDate,
        (SELECT ISNULL(NULLIF(LTRIM(RTRIM(x.FullName)), ''), x.Username) FROM dbo.Users x WHERE x.Id = ph.DiscountApprovedBy) AS DiscountApprovedByName,
        (SELECT ISNULL(NULLIF(LTRIM(RTRIM(x.FullName)), ''), x.Username) FROM dbo.Users x WHERE x.Id = ph.DiscountEnteredBy)  AS DiscountEnteredByName
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.LabOrderId = @LabOrderId;

    -- RS2: Line Items
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

    -- RS3: Payments Recorded
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
        pd.Notes,
        -- 2205: who received it, and whether it was collected later against the balance due (same rule as
        -- usp_MoneyReceipt_Get: the bill's PaymentHeader existed before the payment)
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS ReceivedByName,
        CAST(CASE WHEN DATEDIFF(SECOND, ph.CreatedDate, pd.CreatedDate) > 5 THEN 1 ELSE 0 END AS BIT) AS IsDueCollection
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1
    ORDER BY pd.PaymentDate, pd.PaymentDetailId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @IsB2B BIT = NULL,
    -- which date the From / To range applies to: 'B' = booking date (falls back to the order date), 'C' = bill /
    -- created date; NULL = the order date, as before (B2B list and every other caller unchanged)
    @DateType CHAR(1) = NULL,
    -- 2233: payment / cancellation filter of the order list: NULL = all; DUE = nothing received yet; PARTIAL = part
    -- received; PAID = fully covered; PCAN = some tests cancelled; FCAN = the whole bill cancelled
    @PaymentFilter VARCHAR(10) = NULL,
    -- 2234: B2B order list - partner type ('F' franchise / 'C' company) and one partner of that type; NULL = all
    @AgentType VARCHAR(5) = NULL,
    @AgentId INT = NULL,
    -- 2258: only the bills created by this user (a franchise login's own bills); NULL = everyone's
    @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @FromDate IS NULL SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT
        COUNT(1) AS TotalOrders,
        ISNULL(SUM(o.TotalAmount + ISNULL(o.MiscAmount, 0) + ISNULL(o.MiscGstAmount, 0)), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 1
            ELSE 0
        END), 0) AS PaidCount,
        ISNULL(SUM(CASE
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) < ISNULL(o.B2BTotal, o.TotalAmount) THEN 1
            WHEN ISNULL(o.IsB2B, 0) = 0 AND ISNULL(ph.PaymentStatus, 'U') <> 'P' THEN 1
            ELSE 0
        END), 0) AS UnpaidCount,
        ISNULL(SUM(CASE WHEN o.IsB2B = 1 THEN ISNULL(o.B2BTotal, 0.00) ELSE 0.00 END), 0.00) AS B2BTotalAmount
    FROM dbo.LabOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
      AND CAST(CASE @DateType WHEN 'B' THEN ISNULL(o.BookingDate, o.OrderDate) WHEN 'C' THEN o.CreatedDate ELSE o.OrderDate END AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
      AND (@AgentType IS NULL OR o.AgentType = @AgentType)
      AND (@AgentId IS NULL OR o.B2BAgentID = @AgentId)
      AND (@CreatedBy IS NULL OR o.CreatedBy = @CreatedBy OR (o.AgentType = 'F' AND o.B2BAgentID = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @CreatedBy AND u.User_Type = 'F')))
      AND (@PaymentFilter IS NULL
           OR (@PaymentFilter = 'FCAN' AND ISNULL(o.IsActive, 0) = 0)
           OR (@PaymentFilter = 'PCAN' AND ISNULL(o.IsActive, 0) = 1
               AND EXISTS (SELECT 1 FROM dbo.LabOrderItem xi WHERE xi.LabOrderId = o.LabOrderId AND ISNULL(xi.IsActive, 0) = 0))
           OR (@PaymentFilter IN ('DUE', 'PARTIAL', 'PAID') AND ISNULL(o.IsActive, 0) = 1
               AND (CASE WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                         WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                         WHEN o.IsB2B = 1 THEN 'U'
                         ELSE ISNULL(ph.PaymentStatus, 'U') END)
                   = CASE @PaymentFilter WHEN 'DUE' THEN 'U' WHEN 'PARTIAL' THEN 'R' ELSE 'P' END))
      AND (
          @Search IS NULL
          OR o.BillNo LIKE '%' + @Search + '%'
          OR o.TokenNo LIKE '%' + @Search + '%' OR o.BookingNo LIKE '%' + @Search + '%'
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
            o.BookingNo,                                         -- 2386
            CAST(ISNULL(o.IsBookingRequired, 0) AS BIT) AS IsBookingRequired,
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
            CASE
                WHEN o.AgentType = 'F' THEN f.Franchise_Code
                WHEN o.AgentType = 'C' THEN corp.Corporate_Code
                ELSE NULL
            END AS AgentCode,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL
            END AS Age,
            ph.PaymentHeaderId,
            CASE
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                WHEN o.IsB2B = 1 THEN 'U'
                ELSE ISNULL(ph.PaymentStatus, 'U')
            END AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            CASE
                WHEN o.IsB2B = 1 THEN
                    CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00
                         ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
                ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
            END AS BalanceDue,
            ISNULL(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
            u.Username AS CreatedByUsername,
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
            -- Tests already signed off (ReportStatusId = 5 "Report Approve"); >0 means the report can be
            -- printed even if not every test on the order is approved yet (partial approval allowed).
            (
                SELECT COUNT(1)
                FROM dbo.SampleCollection sc
                INNER JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                WHERE sc.Laborderid = o.LabOrderId AND led.ReportStatusId = 5
            ) AS ApprovedTestCount,
            ROW_NUMBER() OVER (ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
        WHERE (@BranchId IS NULL OR @BranchId = 0 OR o.BranchId = @BranchId)
          AND CAST(CASE @DateType WHEN 'B' THEN ISNULL(o.BookingDate, o.OrderDate) WHEN 'C' THEN o.CreatedDate ELSE o.OrderDate END AS DATE) BETWEEN @FromDate AND @ToDate
          AND (@IsB2B IS NULL OR (@IsB2B = 1 AND o.IsB2B = 1) OR (@IsB2B = 0 AND ISNULL(o.IsB2B, 0) = 0))
      AND (@AgentType IS NULL OR o.AgentType = @AgentType)
      AND (@AgentId IS NULL OR o.B2BAgentID = @AgentId)
      AND (@CreatedBy IS NULL OR o.CreatedBy = @CreatedBy OR (o.AgentType = 'F' AND o.B2BAgentID = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @CreatedBy AND u.User_Type = 'F')))
      AND (@PaymentFilter IS NULL
           OR (@PaymentFilter = 'FCAN' AND ISNULL(o.IsActive, 0) = 0)
           OR (@PaymentFilter = 'PCAN' AND ISNULL(o.IsActive, 0) = 1
               AND EXISTS (SELECT 1 FROM dbo.LabOrderItem xi WHERE xi.LabOrderId = o.LabOrderId AND ISNULL(xi.IsActive, 0) = 0))
           OR (@PaymentFilter IN ('DUE', 'PARTIAL', 'PAID') AND ISNULL(o.IsActive, 0) = 1
               AND (CASE WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
                         WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
                         WHEN o.IsB2B = 1 THEN 'U'
                         ELSE ISNULL(ph.PaymentStatus, 'U') END)
                   = CASE @PaymentFilter WHEN 'DUE' THEN 'U' WHEN 'PARTIAL' THEN 'R' ELSE 'P' END))
          AND (
              @Search IS NULL
              OR o.BillNo LIKE '%' + @Search + '%'
              OR o.TokenNo LIKE '%' + @Search + '%' OR o.BookingNo LIKE '%' + @Search + '%'
              OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p
              WHERE p.PatientId = o.PatientId
                AND (p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      )
    )
    SELECT
        LabOrderId,
        PatientId,
        BranchId,
        OrderDate,
        BillNo,
        TokenNo,
        BookingNo,
        IsBookingRequired,
        TotalAmount,
        CollectionType,
        PhlebotomistId,
        IsUrgent,
        PhlebotomistName,
        BookingDate,
        IsActive,
        CreatedDate,
        CreatedBy,
        IsB2B,
        B2BAgentID,
        AgentType,
        B2BTotal,
        AgentName,
        AgentCode,
        PatientCode,
        PatientName,
        PhoneNumber,
        Gender,
        Age,
        PaymentHeaderId,
        PaymentStatus,
        TotalPaid,
        BalanceDue,
        CreatedByName,
        CreatedByUsername,
        ItemCount,
        TestNamesSummary,
        ApprovedTestCount,
        TotalCount
    FROM PagedOrders
    WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @PageSize)
    ORDER BY LabOrderId DESC;
END;
GO

-- the money receipt also shows the LAB booking number (live definition + BookingNo)
CREATE OR ALTER PROCEDURE dbo.usp_MoneyReceipt_Get
    @ReceiptNo NVARCHAR(50),
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HeaderId INT, @FirstOn DATETIME, @Amount DECIMAL(18, 2), @ReceivedBy INT, @Bills INT;

    SELECT @HeaderId = MIN(pd.PaymentHeaderId), @FirstOn = MIN(pd.CreatedDate), @Amount = SUM(pd.PaidAmount),
           @ReceivedBy = MIN(pd.CreatedBy), @Bills = COUNT(DISTINCT pd.PaymentHeaderId)
    FROM dbo.PaymentDetail pd
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1;

    IF @HeaderId IS NULL
    BEGIN
        SELECT TOP 0 CAST(NULL AS NVARCHAR(50)) AS ReceiptNo;   -- not found
        RETURN;
    END;

    -- Paid on this bill before this receipt (other receipts only)
    DECLARE @PaidBefore DECIMAL(18, 2) =
        (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM dbo.PaymentDetail pd
         WHERE pd.PaymentHeaderId = @HeaderId AND pd.IsActive = 1
           AND ISNULL(pd.ReceiptNo, N'') <> @ReceiptNo AND pd.CreatedDate < @FirstOn);

    SELECT
        @ReceiptNo                                         AS ReceiptNo,
        @FirstOn                                           AS ReceiptOn,
        RTRIM(ph.ModuleCode)                               AS ModuleCode,
        ph.ModuleRefId,
        ph.BranchId,
        b.BranchName,
        COALESCE(lo.BillNo, os.OPDBillNo)                  AS BillNo,
        COALESCE(lo.OrderDate, os.VisitDate, ph.CreatedDate) AS BillDate,
        COALESCE(lo.TokenNo, os.TokenNo)                   AS TokenNo,
        lo.BookingNo                                       AS BookingNo,   -- 2386
        p.PatientCode,
        LTRIM(RTRIM(REPLACE(ISNULL(p.FirstName, N'') + N' ' + ISNULL(p.MiddleName, N'') + N' ' + ISNULL(p.LastName, N''), N'  ', N' '))) AS PatientName,
        p.PhoneNumber                                      AS PatientPhone,
        p.Gender                                           AS PatientGender,
        ph.NetAmount,
        @PaidBefore                                        AS PaidBefore,
        @Amount                                            AS Amount,
        CASE WHEN ph.NetAmount - @PaidBefore - @Amount > 0 THEN ph.NetAmount - @PaidBefore - @Amount ELSE 0 END AS BalanceAfter,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS ReceivedByName,
        -- Due collection: the bill (PaymentHeader) was saved before this receipt. The first payment at billing is
        -- written within the same save, about a second after the header. A receipt spread over several bills is a
        -- B2B settlement, which has its own receipt (LabOrderBooking/PrintSettlementReceipt).
        CAST(CASE WHEN @Bills > 1 THEN 0 WHEN DATEDIFF(SECOND, ph.CreatedDate, @FirstOn) > 5 OR @PaidBefore > 0 THEN 1 ELSE 0 END AS BIT) AS IsDueCollection,
        @Bills                                             AS BillCount,
        -- the bill's discount (2227): gross, how much, how it was given, why and who approved it; and whether it was
        -- given with this receipt (the approval is saved in the same transaction as the receipt's payment rows)
        ph.SubTotal                                        AS GrossAmount,
        CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) >= ISNULL(ph.LineDiscountTotal, 0) THEN ISNULL(ph.HeaderDiscountAmount, 0) ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DiscountAmount,
        NULLIF(RTRIM(ph.HeaderDiscountType), '')          AS DiscountType,
        ph.HeaderDiscountValue                             AS DiscountValue,
        ISNULL(ph.RoundOffAmount, 0)                       AS RoundOffAmount,
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), N'')       AS DiscountReason,
        ISNULL(NULLIF(LTRIM(RTRIM(da.FullName)), N''), da.Username) AS DiscountApprovedByName,
        CAST(CASE WHEN ph.DiscountApprovedDate IS NOT NULL AND ABS(DATEDIFF(SECOND, ph.DiscountApprovedDate, @FirstOn)) <= 60 THEN 1 ELSE 0 END AS BIT) AS DiscountOnThisReceipt,
        CAST(CASE WHEN @BranchId IS NULL OR ph.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS BranchAllowed
    FROM dbo.PaymentHeader ph
    LEFT JOIN dbo.LabOrder lo           ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    LEFT JOIN dbo.PatientOPDService os  ON ph.ModuleCode = 'OPD' AND os.OPDServiceId = ph.ModuleRefId
    LEFT JOIN dbo.PatientMaster p       ON p.PatientId = COALESCE(lo.PatientId, os.PatientId, ph.PatientId)
    LEFT JOIN dbo.Branchmaster b        ON b.BranchID = ph.BranchId
    LEFT JOIN dbo.Users u               ON u.Id = @ReceivedBy
    LEFT JOIN dbo.Users da              ON da.Id = ph.DiscountApprovedBy
    WHERE ph.PaymentHeaderId = @HeaderId;

    SELECT
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        NULLIF(LTRIM(RTRIM(pd.UPIRefNo)), N'')       AS UPIRefNo,
        NULLIF(LTRIM(RTRIM(pd.CardLast4)), '')       AS CardLast4,
        NULLIF(LTRIM(RTRIM(pd.ChequeNo)), N'')       AS ChequeNo,
        NULLIF(LTRIM(RTRIM(pd.BankName)), N'')       AS BankName,
        NULLIF(LTRIM(RTRIM(pd.TransactionRef)), N'') AS TransactionRef
    FROM dbo.PaymentDetail pd
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.ReceiptNo = @ReceiptNo AND pd.IsActive = 1
    ORDER BY pd.PaymentDetailId;
END;
GO

-- Reports > LAB > Daily Billing Register: the booking number under the token (live definition + BookingNo)
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_BillingRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @BillingType   VARCHAR(3)    = NULL,   -- B2C / B2B
    @PaymentStatus VARCHAR(10)   = NULL,   -- PAID / PARTIAL / UNPAID / CANCELLED
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 SET @CreatedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @PaymentStatus = NULLIF(UPPER(LTRIM(RTRIM(@PaymentStatus))), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.BookingNo /* 2386 */, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctor,
        items.TestCount, items.TestNames,
        CAST(lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount /* 2240: + misc charges with GST */,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        -- 2374: round off of the bill (B2C; a B2B bill is not rounded here)
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.RoundOffAmount, 0) END AS DECIMAL(18, 2)) AS RoundOffAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN lo.IsActive = 0 THEN 0
                  WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END
                  ELSE CASE WHEN ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END END AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(lo.IsB2B, 0) = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'PAID'
             WHEN ISNULL(lo.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    OUTER APPLY (SELECT COUNT(1) AS TestCount,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT SUM(bc.CancelledAmount) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1) canc
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%' OR lo.BookingNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @PaymentStatus IS NOT NULL DELETE FROM #R WHERE PaymentStatus <> @PaymentStatus;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount,
           SUM(CASE WHEN IsCancelled = 0 THEN 1 ELSE 0 END) AS ActiveBills,
           SUM(CASE WHEN IsCancelled = 1 THEN 1 ELSE 0 END) AS CancelledBills,
           SUM(CASE WHEN BillingType = 'B2C' THEN 1 ELSE 0 END) AS B2CBills,
           SUM(CASE WHEN BillingType = 'B2B' THEN 1 ELSE 0 END) AS B2BBills,
           ISNULL(SUM(TestCount), 0) AS TestCount,
           ISNULL(SUM(GrossAmount), 0) AS GrossAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount, ISNULL(SUM(RoundOffAmount), 0) AS RoundOffAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           COUNT(DISTINCT PatientId) AS PatientCount
    FROM #R;

    -- RS2 groups
    SELECT 'byDate' AS GroupKey, NULL AS GroupId, BillDay AS GroupName, 0 AS SortOrder,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount, SUM(RoundOffAmount) AS RoundOffAmount,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY CreatedById, CreatedBy
    UNION ALL
    SELECT 'byBillingType', NULL, BillingType, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillingType
    UNION ALL
    SELECT 'byPaymentStatus', NULL, PaymentStatus,
           CASE PaymentStatus WHEN 'PAID' THEN 1 WHEN 'PARTIAL' THEN 2 WHEN 'UNPAID' THEN 3 ELSE 4 END,
           COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(RoundOffAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PaymentStatus
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO

PRINT 'Script 2386 applied: Is Booking Req + booking number on LAB orders.';
GO
