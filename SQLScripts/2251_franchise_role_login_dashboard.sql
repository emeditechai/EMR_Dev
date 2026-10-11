-- ====================================================================================================
-- Script: 2251_franchise_role_login_dashboard.sql
-- Franchise logins (Users.User_Type = 'F', ReferenceUserID = LabFranchiseMaster.Franchise_ID):
--   1. Role "Franchise" in the role master of every company (created when missing).
--   2. Every franchise login gets that role (UserRoles) and its franchise's parent branch (UserBranches) -
--      a login without a role cannot sign in. New franchises get the same rows from the application.
--   3. Page UTILITY.FRANCHISEDASHBOARD (Utility > Franchise Dashboard) with its endpoints.
--   4. What the Franchise role may open: its dashboard, the home page (which sends it to the dashboard) and
--      B2B Lab Billing & Booking - except wallet top-up (control SETTLE), which stays with the lab.
--   5. dbo.usp_Web_FranchiseDashboard: one franchise's profile, period summary, sale register, realization
--      (money received), pending receivable and a day-wise trend.
-- Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Role master ──────────────────────────────────────────────────────────────────────────────────
INSERT INTO dbo.Roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
SELECT N'Franchise', N'Franchise-level access', 0, GETDATE(), GETDATE(), N'fas fa-building', c.CompanyId
FROM dbo.CompanyMaster c
WHERE c.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.Roles r WHERE r.Name = N'Franchise' AND ISNULL(r.CompanyId, c.CompanyId) = c.CompanyId);
GO

-- ── 2. Existing franchise logins: branch and role ───────────────────────────────────────────────────
INSERT INTO dbo.UserBranches (UserId, BranchId, IsActive, CreatedDate, ModifiedDate)
SELECT u.Id, f.Parent_Branch_ID, 1, GETDATE(), GETDATE()
FROM dbo.Users u
JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = u.ReferenceUserID
WHERE u.User_Type = 'F' AND f.Parent_Branch_ID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches b WHERE b.UserId = u.Id AND b.BranchId = f.Parent_Branch_ID);

INSERT INTO dbo.UserRoles (UserId, RoleId, IsActive, AssignedDate, CreatedDate, ModifiedDate, Branch_ID)
SELECT u.Id, r.Id, 1, GETDATE(), GETDATE(), GETDATE(), f.Parent_Branch_ID
FROM dbo.Users u
JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = u.ReferenceUserID
CROSS APPLY (SELECT TOP 1 r.Id FROM dbo.Roles r
              WHERE r.Name = N'Franchise' AND ISNULL(r.CompanyId, ISNULL(u.CompanyId, f.CompanyId)) = ISNULL(u.CompanyId, f.CompanyId)
              ORDER BY r.Id) r
WHERE u.User_Type = 'F'
  AND NOT EXISTS (SELECT 1 FROM dbo.UserRoles ur WHERE ur.UserId = u.Id AND ur.RoleId = r.Id);
GO

-- ── 3 + 4. Page, endpoints and the role's grants ────────────────────────────────────────────────────
DECLARE @co INT, @utility INT, @page INT, @role INT, @p INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @utility = NULL; SET @page = NULL; SET @role = NULL;
    SELECT @utility = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY' AND CompanyId = @co;
    SELECT TOP 1 @role = Id FROM dbo.Roles WHERE Name = N'Franchise' AND ISNULL(CompanyId, @co) = @co ORDER BY Id;

    IF @utility IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @utility, @Page_Code = N'UTILITY.FRANCHISEDASHBOARD', @Title = N'Franchise Dashboard',
             @Controller = N'FranchiseDashboard', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 45, @Icon = N'bi bi-shop-window me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'FranchiseDashboard', @Action = N'Index', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'FranchiseDashboard', @Action = N'Data', @Source = 'SEED';
    END

    -- calls the B2B billing page makes that were registered only under other pages (B2C booking / B2B order list):
    -- the saved bill's detail and the contents of a profile (the AI prescription assist stays a separate grant)
    SET @p = NULL; SET @ctl = NULL;
    SELECT @p = Page_ID FROM dbo.PageMaster WHERE CompanyId = @co AND Page_Code = N'LAB.LABORDERBOOKING.B2BBOOKING';
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'VIEW';
    IF @p IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'GetOrderDetail', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'GetProfileDetails', @Source = 'SEED';
    END

    IF @role IS NOT NULL
    BEGIN
        -- pages the role may open
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
            SELECT Page_ID FROM dbo.PageMaster
            WHERE CompanyId = @co AND Page_Code IN (N'UTILITY.FRANCHISEDASHBOARD', N'HOME.DASHBOARD', N'LAB.LABORDERBOOKING.B2BBOOKING');
        OPEN pg; FETCH NEXT FROM pg INTO @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @role, @Page_ID = @p, @Permission = 'A', @CompanyId = @co,
                 @Reason = N'Franchise login: own dashboard and B2B billing (script 2251)';
            FETCH NEXT FROM pg INTO @p;
        END
        CLOSE pg; DEALLOCATE pg;

        -- ... but not the lab's wallet top-up on the B2B billing page
        SET @p = NULL; SET @ctl = NULL;
        SELECT @p = Page_ID FROM dbo.PageMaster WHERE CompanyId = @co AND Page_Code = N'LAB.LABORDERBOOKING.B2BBOOKING';
        SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'SETTLE';
        IF @ctl IS NOT NULL
            EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @role, @Page_ID = @p, @Control_ID = @ctl, @Permission = 'D', @CompanyId = @co,
                 @Reason = N'A franchise cannot top up its own wallet (script 2251)';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

-- ── 5. Franchise dashboard data ─────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Web_FranchiseDashboard
    @FranchiseId INT,
    @FromDate    DATE,
    @ToDate      DATE
AS
BEGIN
    SET NOCOUNT ON;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));

    -- every bill of the franchise, with what is still due on it (the contract price is what the franchise owes)
    SELECT lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate, lo.PatientId, lo.IsActive,
           CAST(lo.TotalAmount AS DECIMAL(18, 2)) AS MrpAmount,
           CAST(ISNULL(lo.B2BTotal, lo.TotalAmount) AS DECIMAL(18, 2)) AS BillAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           CAST(CASE WHEN lo.IsActive = 0 THEN 0
                     WHEN ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) < 0 THEN 0
                     ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) - ISNULL(ph.TotalPaid, 0) END AS DECIMAL(18, 2)) AS DueAmount,
           ph.PaymentHeaderId
    INTO #B
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.AgentType = 'F' AND lo.B2BAgentID = @FranchiseId;

    -- money received against those bills
    SELECT pd.PaymentDetailId, b.LabOrderId, ISNULL(pd.PaymentDate, pd.CreatedDate) AS PaidOn, pd.ReceiptNo,
           CAST(pd.PaidAmount AS DECIMAL(18, 2)) AS PaidAmount,
           CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN N'Wallet' ELSE ISNULL(pm.MethodName, N'Other') END AS PaymentMode
    INTO #P
    FROM #B b
    JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = b.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId;

    DECLARE @Outstanding DECIMAL(18, 2) = ISNULL((SELECT SUM(DueAmount) FROM #B), 0);

    -- 1. the franchise
    SELECT f.Franchise_ID AS FranchiseId, f.Franchise_Code AS FranchiseCode, f.Franchise_Name AS FranchiseName,
           CASE f.Franchise_Type WHEN 1 THEN 'Collection Center' WHEN 2 THEN 'Franchise Lab' WHEN 3 THEN 'Pickup Point' WHEN 4 THEN 'Marketing' ELSE 'Franchise' END AS FranchiseType,
           pb.BranchName AS ParentBranch, f.Mobile_No AS MobileNo, f.Email, f.Onboarding_Date AS OnboardingDate, f.Go_Live_Date AS GoLiveDate,
           f.Agreement_Valid_From AS AgreementFrom, f.Agreement_Valid_To AS AgreementTo,
           CAST(f.Status AS BIT) AS IsSuspended, f.Suspension_Reason AS SuspensionReason, f.IsActive,
           CASE ISNULL(c.Credit_Facility_Type, 1) WHEN 1 THEN 'Prepaid (Wallet)' WHEN 2 THEN 'Postpaid (Credit)' WHEN 3 THEN 'Hybrid' ELSE 'Prepaid (Wallet)' END AS CreditFacility,
           CAST(ISNULL(c.Credit_Limit, 0) AS DECIMAL(18, 2)) AS CreditLimit,
           CAST(CASE WHEN c.Temp_Limit_Valid_Till IS NULL OR c.Temp_Limit_Valid_Till >= CAST(GETDATE() AS DATE) THEN ISNULL(c.Temporary_Limit_Increase, 0) ELSE 0 END AS DECIMAL(18, 2)) AS TemporaryLimit,
           c.Credit_Days AS CreditDays, ISNULL(c.Grace_Days, 0) AS GraceDays,
           CAST(ISNULL(c.Security_Deposit_Amount, 0) AS DECIMAL(18, 2)) AS SecurityDeposit,
           CAST(ISNULL(w.CurrentBalance, 0) AS DECIMAL(18, 2)) AS WalletBalance,
           @Outstanding AS OutstandingNow
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.Branchmaster pb ON pb.BranchID = f.Parent_Branch_ID
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
    LEFT JOIN dbo.LabFranchiseWallet w ON w.Franchise_ID = f.Franchise_ID
    WHERE f.Franchise_ID = @FranchiseId AND f.IsDeleted = 0;

    -- 2. the period
    SELECT
        (SELECT COUNT(1) FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 1) AS Bills,
        (SELECT COUNT(1) FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 0) AS CancelledBills,
        (SELECT COUNT(DISTINCT PatientId) FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 1) AS Patients,
        ISNULL((SELECT SUM(MrpAmount) FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 1), 0) AS MrpAmount,
        ISNULL((SELECT SUM(BillAmount) FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 1), 0) AS SalesAmount,
        ISNULL((SELECT SUM(PaidAmount) FROM #P WHERE PaidOn >= @From AND PaidOn < @To), 0) AS RealizedAmount,
        ISNULL((SELECT SUM(DueAmount) FROM #B WHERE OrderDate >= @From AND OrderDate < @To), 0) AS PendingOnPeriodBills,
        @Outstanding AS PendingTotal;

    -- 3. sale register: bills of the period
    SELECT b.LabOrderId, b.BillNo, b.TokenNo, b.OrderDate AS BillDate, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           items.TestCount, items.TestNames, b.MrpAmount, b.BillAmount, b.PaidAmount, b.DueAmount,
           CASE WHEN b.IsActive = 0 THEN 'Cancelled' WHEN b.DueAmount <= 0 THEN 'Paid' WHEN b.PaidAmount > 0 THEN 'Part paid' ELSE 'Unpaid' END AS BillStatus
    FROM #B b
    JOIN dbo.PatientMaster p ON p.PatientId = b.PatientId
    OUTER APPLY (SELECT COUNT(1) AS TestCount,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS TestNames
                   FROM dbo.LabOrderItem loi
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE loi.LabOrderId = b.LabOrderId AND (loi.IsActive = 1 OR b.IsActive = 0)) items
    WHERE b.OrderDate >= @From AND b.OrderDate < @To
    ORDER BY b.OrderDate DESC;

    -- 4. realization: money received in the period (whenever the bill was raised)
    SELECT x.PaidOn, x.ReceiptNo, b.BillNo, b.OrderDate AS BillDate,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           x.PaymentMode, x.PaidAmount
    FROM #P x
    JOIN #B b ON b.LabOrderId = x.LabOrderId
    JOIN dbo.PatientMaster p ON p.PatientId = b.PatientId
    WHERE x.PaidOn >= @From AND x.PaidOn < @To
    ORDER BY x.PaidOn DESC;

    -- 5. pending receivable: every bill still due today, oldest first
    SELECT b.LabOrderId, b.BillNo, b.OrderDate AS BillDate, DATEDIFF(DAY, b.OrderDate, GETDATE()) AS AgeDays,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           b.BillAmount, b.PaidAmount, b.DueAmount
    FROM #B b
    JOIN dbo.PatientMaster p ON p.PatientId = b.PatientId
    WHERE b.DueAmount > 0
    ORDER BY b.OrderDate;

    -- 6. day-wise sales and realization of the period
    SELECT d.Day, SUM(d.Sales) AS Sales, SUM(d.Realized) AS Realized
    FROM (SELECT CONVERT(VARCHAR(10), CAST(OrderDate AS DATE), 23) AS Day, BillAmount AS Sales, CAST(0 AS DECIMAL(18, 2)) AS Realized
            FROM #B WHERE OrderDate >= @From AND OrderDate < @To AND IsActive = 1
          UNION ALL
          SELECT CONVERT(VARCHAR(10), CAST(PaidOn AS DATE), 23), 0, PaidAmount FROM #P WHERE PaidOn >= @From AND PaidOn < @To) d
    GROUP BY d.Day
    ORDER BY d.Day;
END
GO

PRINT 'Script 2251 applied: Franchise role, franchise logins, Franchise Dashboard page and grants.';
GO
