-- ============================================================================
-- Migration: 2127_lab_referral_doctor_from_doctor_master.sql
-- Description:
--   The "Referral Doctor" dropdown of B2C / B2B LAB billing now lists doctors of the Doctor Master
--   (Master > Doctors) that are assigned to an active department whose Type is LAB (Department Master),
--   instead of the separate Referral Doctor Master.
--
--   dbo.LabOrder.RefDoctorId                 new, NULL = self (FK to dbo.DoctorMaster)
--   dbo.LabOrder.ReferralDoctorId            kept as-is for bills saved before this script (Referral Doctor Master)
--   dbo.usp_Lab_GetReferralDoctors           new: dropdown list (company + branch, LAB department doctors)
--   dbo.usp_CreateLabOrder                   @ReferralDoctorId is now a Doctor Master id, validated, stored in RefDoctorId
--   dbo.usp_LabOrder_GetDetail / usp_LabReporting_GetDetail / usp_Api_LabReport_BillingRegister /
--   dbo.usp_Api_LabReport_PatientOrders      referral name = Doctor Master doctor, else the old Referral Doctor Master name
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabOrder', 'RefDoctorId') IS NULL
BEGIN
    ALTER TABLE dbo.LabOrder ADD RefDoctorId INT NULL;
    PRINT 'Added dbo.LabOrder.RefDoctorId.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LabOrder_RefDoctor')
    ALTER TABLE dbo.LabOrder WITH CHECK ADD CONSTRAINT FK_LabOrder_RefDoctor
        FOREIGN KEY (RefDoctorId) REFERENCES dbo.DoctorMaster (DoctorId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabOrder_RefDoctorId' AND object_id = OBJECT_ID('dbo.LabOrder'))
    CREATE INDEX IX_LabOrder_RefDoctorId ON dbo.LabOrder (RefDoctorId) WHERE RefDoctorId IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetReferralDoctors
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Active Doctor Master doctors assigned to an active LAB-type department, available in the branch
    -- (same branch rule as the Doctor list: created in the branch or mapped to it).
    SELECT d.DoctorId,
           LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName,
           ps.SpecialityName,
           dep.DepartmentNames
    FROM dbo.DoctorMaster d
    LEFT JOIN dbo.DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    CROSS APPLY (
        SELECT STRING_AGG(CAST(dm.DeptName AS NVARCHAR(MAX)), N', ') AS DepartmentNames
        FROM dbo.DoctorDepartmentMap ddm
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId
        WHERE ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1 AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
    ) dep
    WHERE d.IsActive = 1
      AND dep.DepartmentNames IS NOT NULL
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL
           OR d.CreatedBranchId = @BranchId
           OR EXISTS (SELECT 1 FROM dbo.DoctorBranchMap dbm
                      WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1))
    ORDER BY d.FullName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
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
    @ReferralDoctorId INT          = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT,
    @TokenNo          NVARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Strict validation: Cannot create lab order without at least one valid test investigation
    IF NOT EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) > 0)
    BEGIN
        RAISERROR('Cannot create a laboratory bill without at least one valid test investigation (InvestigationId > 0).', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    -- Referral doctor = Doctor Master doctor assigned to an active LAB-type department (script 2127)
    SET @ReferralDoctorId = NULLIF(@ReferralDoctorId, 0);
    IF @ReferralDoctorId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.DoctorMaster d
        INNER JOIN dbo.DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
        WHERE d.DoctorId = @ReferralDoctorId AND d.IsActive = 1)
    BEGIN
        RAISERROR('The selected referral doctor is not an active doctor of a LAB department.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Generate Token immediately for each B2B billing
        IF ISNULL(@IsB2B, 0) = 1
        BEGIN
            DECLARE @DateOnly DATE = CAST(@EffectiveDate AS DATE);
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo 
                @BranchId  = @BranchId, 
                @TokenDate = @DateOnly, 
                @TokenNo   = @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            SET @TokenNo = NULL; -- B2C tokens are assigned upon payment
        END

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header with generated TokenNo
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal, RefDoctorId)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId);
        
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
        FROM @Items
        WHERE InvestigationId > 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
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
        pd.Notes
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT,
    @BranchId   INT = NULL      -- NULL = every sample of the order (print / dispatch); otherwise only this branch's samples
AS
BEGIN
    SET NOCOUNT ON;

    -- Which samples belong to @BranchId (same rule as dbo.usp_LabReporting_GetHeaderList):
    --   * a sample that was never transferred belongs to the branch that booked it (sc.BranchID)
    --   * a transferred sample belongs to the TARGET branch, and only once it has been received
    --   * once the TARGET branch approves it, it also comes back to the SOURCE branch - read-only there
    --     (IsReadOnlyForBranch = 1), so the booking branch can see the result and print the report
    -- so a partially transferred order shows only its own tests on each branch's Report Entry screen.

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;
    DECLARE @IsReceived BIT = 0;
    DECLARE @ReceivedDate DATETIME = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks,
        @IsReceived = ISNULL(sc.IsReceived, 0),
        @ReceivedDate = sc.ReceivedDate
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1
      AND (@BranchId IS NULL
           OR (sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1));

    -- Patient Demographic variables for reference range and delta check matching
    DECLARE @PatientId INT = NULL;
    DECLARE @PatientGender VARCHAR(20) = NULL;
    DECLARE @PatientAge DECIMAL(6,2) = NULL;
    DECLARE @CompanyId INT = 1;

    SELECT 
        @PatientId = lo.PatientId,
        @PatientGender = p.Gender,
        @CompanyId = ISNULL(bm.CompanyId, 1),
        @PatientAge = CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    WHERE lo.LabOrderId = @LabOrderId;

    -- Compute Overall Order Status based on entered test results
    DECLARE @OverallStatusId INT = 0;
    DECLARE @OverallStatusCode VARCHAR(30) = 'PENDING';
    DECLARE @OverallStatusName NVARCHAR(100) = 'Pending Entry';
    DECLARE @OverallBadgeClass NVARCHAR(200) = 'bg-secondary-subtle text-secondary border border-secondary-subtle';
    DECLARE @DraftedDate DATETIME = NULL;
    DECLARE @SubmittedDate DATETIME = NULL;
    DECLARE @ValidatedDate DATETIME = NULL;
    DECLARE @ApprovedDate DATETIME = NULL;

    DECLARE @TotalItems INT = 0;
    DECLARE @FilledItems INT = 0;
    DECLARE @MinStatusId INT = 0;
    DECLARE @MaxStatusId INT = 0;

    SELECT 
        @TotalItems = COUNT(*),
        @FilledItems = COUNT(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0     -- a test cancelled from the bill is no longer reported
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)));

    -- Compute Overall Order Status based on entered test results
    -- Supports partial reporting: overall status reflects the status of entered collected tests
    IF @FilledItems > 0
    BEGIN
        SET @OverallStatusId = @MaxStatusId;
    END
    ELSE
    BEGIN
        SET @OverallStatusId = 0; -- Pending Entry
    END

    IF @OverallStatusId > 0
    BEGIN
        SELECT 
            @OverallStatusCode = StatusCode,
            @OverallStatusName = StatusName,
            @OverallBadgeClass = BadgeClass
        FROM dbo.Reportentrystatus
        WHERE ReportStatusId = @OverallStatusId;
    END

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        @PatientAge AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(lo.RefDoctorId, lo.ReferralDoctorId) AS ReferralDoctorId,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctorName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks,
        ISNULL(@IsReceived, 0) AS IsReceived,
        @ReceivedDate AS ReceivedDate,
        -- Overall Report Status Information
        @OverallStatusId AS ReportStatusId,
        @OverallStatusCode AS StatusCode,
        @OverallStatusName AS ReportStatusName,
        @OverallBadgeClass AS ReportBadgeClass,
        @DraftedDate AS DraftedDate,
        @SubmittedDate AS SubmittedDate,
        @ValidatedDate AS ValidatedDate,
        @ApprovedDate AS ApprovedDate
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Investigation Items for this Order (Collected, Re-Collect, Rejected)
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        -- Test Method Name
        COALESCE(NULLIF(m_ref.Method_Name, ''), NULLIF(m_inv.Method_Name, ''), '') AS MethodName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        -- Unit Name / Symbol from LabReferenceRangeMaster.Unit_ID (with lim.Unit_ID fallback)
        COALESCE(NULLIF(ref.UnitSymbol, ''), NULLIF(u_inv.Unit_Symbol, ''), u_inv.Unit_Name, '') AS UnitName,
        COALESCE(led.Reporting_Type, lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        -- Sample Status metadata
        ISNULL(sc.CollectionstatusID, 2) AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected') AS SampleCollectionStatus,
        ISNULL(scs.StatusCode, 'COLLECTED') AS SampleCollectionStatusCode,
        sc.RejectionReasonId,
        sc.RejectionReason,
        led.LabEntryDetailId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN NULL ELSE led.TestValue END AS TestValue,
        -- Pre-populate Remarks from LabReferenceRangeMaster.Special_Remarks if empty
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,

        -- Header/Group-level Lab Remarks
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        -- Critical / Panic tier: a result beyond Low_Threshold / High_Threshold is flagged 'Critical' / 'Panic'
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Tier END AS RangeTier,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Low_Threshold END AS LowThreshold,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.High_Threshold END AS HighThreshold,
        CASE 
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NOT NULL AND ref.Low_Value > 0 THEN
                CONCAT(
                    CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)), 
                    ' — ', 
                    CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30))
                )
            WHEN ref.Low_Value = 0 AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NULL AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NULL THEN
                CONCAT('> ', CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)))
            ELSE '—'
        END AS ReferenceRange,
        -- Flag: Saved AbnormalFlag, or dynamically evaluated
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN NULL
            ELSE COALESCE(led.AbnormalFlag, 
                CASE 
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Tier IN ('Critical Value', 'Panic Value')
                         AND ((ref.Low_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Threshold)
                           OR (ref.High_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Threshold))
                         THEN CASE ref.Tier WHEN 'Panic Value' THEN 'Panic' ELSE 'Critical' END
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                    ELSE NULL
                END
            )
        END AS AbnormalFlag,
        -- TAT
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        -- Prior Result for Delta Check
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty TestValue or Rejected/Re-collected items
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 0
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        -- 1 = this branch only transferred the sample out; the result was produced and approved elsewhere,
        --     so the Report Entry screen shows it but must not let this branch change anything on it.
        CAST(CASE WHEN @BranchId IS NOT NULL
                   AND sc.IsTransferred = 1
                   AND sc.SourceBranchID = @BranchId
                   AND ISNULL(sc.TargetBranchID, 0) <> @BranchId
                  THEN 1 ELSE 0 END AS BIT) AS IsReadOnlyForBranch,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks,
        ISNULL(sc.IsReceived, 0)    AS IsReceived,
        sc.ReceivedDate,
        sc.ReceiveRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabTestMethodMaster m_inv ON m_inv.Method_ID = lim.Method_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u_inv ON u_inv.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID

    -- Join Group-level remarks if saved
    LEFT JOIN dbo.LabReportTestRemarks rem_prof ON rem_prof.LabOrderId = sc.Laborderid 
                                               AND rem_prof.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20))
                                               AND sc.ProfileId IS NOT NULL
                                               AND rem_prof.IsActive = 1
    LEFT JOIN dbo.LabReportTestRemarks rem_inv ON rem_inv.LabOrderId = sc.Laborderid 
                                              AND rem_inv.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20))
                                              AND rem_inv.IsActive = 1

    -- Match best Reference Range for patient's Gender & Age
    OUTER APPLY (
        SELECT TOP 1 
            r.RefRange_ID,
            r.Method_ID AS RefMethodId,
            r.Unit_ID,
            r.Low_Value,
            r.High_Value,
            r.Special_Remarks,
            r.Tier,
            r.Low_Threshold,
            r.High_Threshold,
            r.Age_From,
            r.Age_To,
            r.Gender AS RangeGender,
            u.Unit_Name,
            COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS UnitSymbol
        FROM dbo.LabReferenceRangeMaster r
        LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = r.Unit_ID
        WHERE r.Test_ID = sc.InvestigationID
          AND r.IsDeleted = 0
          AND r.Status = 1
          AND (r.CompanyId = @CompanyId OR r.CompanyId = 1)
          AND r.Effective_From <= CAST(GETDATE() AS DATE)
          AND (r.Effective_To IS NULL OR r.Effective_To >= CAST(GETDATE() AS DATE))
          AND (
              (@PatientAge IS NULL)
              OR (r.Age_Unit = 'Years' AND @PatientAge >= r.Age_From AND @PatientAge <= r.Age_To)
              OR (r.Age_Unit = 'Months' AND (@PatientAge * 12.0) >= r.Age_From AND (@PatientAge * 12.0) <= r.Age_To)
              OR (r.Age_Unit = 'Days' AND (@PatientAge * 365.25) >= r.Age_From AND (@PatientAge * 365.25) <= r.Age_To)
              OR r.Is_Common_For_All = 1
          )
          AND (
              r.Is_Common_For_All = 1
              OR r.Gender = 'All'
              OR LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, ''))
          )
        ORDER BY 
          CASE WHEN LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, '')) THEN 1 ELSE 2 END ASC,
          CASE WHEN r.Is_Common_For_All = 0 THEN 1 ELSE 2 END ASC,
          r.RefRange_ID DESC
    ) ref
    LEFT JOIN dbo.LabTestMethodMaster m_ref ON m_ref.Method_ID = ref.RefMethodId

    -- Previous Historical Result for Delta Check
    OUTER APPLY (
        SELECT TOP 1 
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = @PatientId
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev

    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0     -- a test cancelled from the bill is no longer reported
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)))
    ORDER BY sc.samplecollectionID ASC;

    -- RS 3: Header-Level Lab Remarks
    SELECT 
        GroupKey,
        HeaderName,
        ProfileId,
        InvestigationId,
        LabRemarks
    FROM dbo.LabReportTestRemarks
    WHERE LabOrderId = @LabOrderId AND IsActive = 1;
END;
GO

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
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctor,
        items.TestCount, items.TestNames,
        CAST(lo.TotalAmount AS DECIMAL(18, 2)) AS GrossAmount,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
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
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
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
           ISNULL(SUM(GrossAmount), 0) AS GrossAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           COUNT(DISTINCT PatientId) AS PatientCount
    FROM #R;

    -- RS2 groups
    SELECT 'byDate' AS GroupKey, NULL AS GroupId, BillDay AS GroupName, 0 AS SortOrder,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(GrossAmount) AS GrossAmount, SUM(DiscountAmount) AS DiscountAmount,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY BillDay
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedBy, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY CreatedById, CreatedBy
    UNION ALL
    SELECT 'byBillingType', NULL, BillingType, 0, COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillingType
    UNION ALL
    SELECT 'byPaymentStatus', NULL, PaymentStatus,
           CASE PaymentStatus WHEN 'PAID' THEN 1 WHEN 'PARTIAL' THEN 2 WHEN 'UNPAID' THEN 3 ELSE 4 END,
           COUNT(1), SUM(TestCount), SUM(GrossAmount), SUM(DiscountAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY PaymentStatus
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PatientOrders
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @ReportStatus  VARCHAR(10)   = NULL,   -- APPROVED / PARTIAL / INPROGRESS / PENDING / CANCELLED
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
    SET @ReportStatus = NULLIF(UPPER(LTRIM(RTRIM(@ReportStatus))), '');

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        p.PatientId, p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber, p.Gender,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctor,
        items.TestNames,
        ISNULL(rep.TotalTests, 0) AS TestCount,
        ISNULL(rep.ApprovedTests, 0) AS ApprovedTests,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(rep.TotalTests, 0) > 0 AND rep.ApprovedTests = rep.TotalTests THEN 'APPROVED'
             WHEN ISNULL(rep.ApprovedTests, 0) > 0 THEN 'PARTIAL'
             WHEN ISNULL(rep.EnteredTests, 0) > 0 THEN 'INPROGRESS'
             ELSE 'PENDING' END AS ReportStatus,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(CASE WHEN lo.IsActive = 0 THEN 0
                  WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END
                  ELSE CASE WHEN ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END END AS DECIMAL(18, 2)) AS DueAmount,
        ISNULL(prn.PrintCount, 0) AS PrintCount,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportEmailLog el WHERE el.LabOrderId = lo.LabOrderId AND el.Status = 'Sent') THEN 1 ELSE 0 END AS BIT) AS Emailed,
        lo.CreatedBy AS CreatedById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    OUTER APPLY (SELECT STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT COUNT(1) AS TotalTests,
                        SUM(CASE WHEN led.ReportStatusId = 5 THEN 1 ELSE 0 END) AS ApprovedTests,
                        SUM(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE 0 END) AS EnteredTests
                   FROM dbo.SampleCollection sc
                   LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
                  WHERE sc.Laborderid = lo.LabOrderId AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
                    AND ISNULL(sc.IsoutSource, 0) = 0 AND sc.CollectionstatusID <> 4) rep
    OUTER APPLY (SELECT COUNT(1) AS PrintCount FROM dbo.AuditLogs a
                  WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportPrinted' AND a.ReferenceId = lo.LabOrderId) prn
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @ReportStatus IS NOT NULL DELETE FROM #R WHERE ReportStatus <> @ReportStatus;

    -- RS1 summary
    SELECT COUNT(DISTINCT PatientId) AS PatientCount, COUNT(1) AS OrderCount,
           ISNULL(SUM(TestCount), 0) AS TestCount, ISNULL(SUM(ApprovedTests), 0) AS ApprovedTests,
           SUM(CASE WHEN ReportStatus = 'APPROVED' THEN 1 ELSE 0 END) AS OrdersApproved,
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END) AS OrdersOpen,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount
    FROM #R;

    -- RS2 groups
    SELECT 'byPatient' AS GroupKey, PatientId AS GroupId, PatientName + ' (' + ISNULL(PatientCode, '') + ')' AS GroupName, 0 AS SortOrder,
           COUNT(1) AS OrderCount, SUM(TestCount) AS TestCount, SUM(ApprovedTests) AS ApprovedTests,
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END) AS OpenOrders,
           SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount, MAX(BillDate) AS LastVisit
    FROM #R GROUP BY PatientId, PatientName, PatientCode
    UNION ALL
    SELECT 'byReportStatus', NULL, ReportStatus,
           CASE ReportStatus WHEN 'PENDING' THEN 1 WHEN 'INPROGRESS' THEN 2 WHEN 'PARTIAL' THEN 3 WHEN 'APPROVED' THEN 4 ELSE 5 END,
           COUNT(1), SUM(TestCount), SUM(ApprovedTests),
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END),
           SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(BillDate)
    FROM #R GROUP BY ReportStatus
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), SUM(TestCount), SUM(ApprovedTests),
           SUM(CASE WHEN ReportStatus IN ('PARTIAL', 'INPROGRESS', 'PENDING') THEN 1 ELSE 0 END),
           SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount), MAX(BillDate)
    FROM #R GROUP BY BillDay
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY PatientName, BillDate DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedBy AS Text FROM #R WHERE CreatedById IS NOT NULL;

    DROP TABLE #R;
END;
GO

PRINT 'Script 2127 applied: LAB referral doctor now from Doctor Master (LAB departments).';
GO
