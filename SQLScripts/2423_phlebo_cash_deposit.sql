-- 2423: LAB > Phlebotomist Cash Deposit.
--   The cashier sees each phlebotomist of the branch with the cash they hold (cash taken at the door in the app, less what they
--   deposited) and records a deposit when the phlebotomist hands the cash over. A deposit is a DEPOSIT row in PhleboCashLedger
--   with a negative amount, so Cash held in the app goes down. It cannot be more than the cash held. Only cash is counted:
--   UPI and card payments go straight to the lab's account. The patient's payment was already posted when it was taken,
--   so a deposit moves no money in the books: it only records that the cash reached the counter.
--   Page LAB.PHLEBOCASH (LAB menu). No role is granted here: give it from Settings > Security.

-- the branch's phlebotomists with their cash held now, and when they last deposited
CREATE OR ALTER PROCEDURE dbo.usp_Lab_PhleboCash_List
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id AS UserId, ISNULL(u.FullName, u.Username) AS Name, u.PhoneNumber,
           ISNULL(l.CashHeld, 0) AS CashHeld,
           ISNULL(l.Collected, 0) AS Collected,
           ISNULL(l.Deposited, 0) AS Deposited,
           l.LastDepositAt
      FROM dbo.Users u
      JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
      OUTER APPLY (SELECT SUM(c.Amount) AS CashHeld,
                          SUM(CASE WHEN c.EntryType = 'COLLECT' THEN c.Amount ELSE 0 END) AS Collected,
                          -SUM(CASE WHEN c.EntryType = 'DEPOSIT' THEN c.Amount ELSE 0 END) AS Deposited,
                          MAX(CASE WHEN c.EntryType = 'DEPOSIT' THEN c.CreatedDate END) AS LastDepositAt
                     FROM dbo.PhleboCashLedger c WHERE c.UserId = u.Id) l
     WHERE u.IsPhlebotomist = 1 AND (u.IsActive = 1 OR ISNULL(l.CashHeld, 0) <> 0)
     ORDER BY CASE WHEN ISNULL(l.CashHeld, 0) > 0 THEN 0 ELSE 1 END, Name;
END
GO

-- deposits taken at this branch between two dates
CREATE OR ALTER PROCEDURE dbo.usp_Lab_PhleboCash_Deposits
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL,
    @PhlebotomistId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = ISNULL(@FromDate, CAST(GETDATE() AS DATE));
    SET @ToDate = ISNULL(@ToDate, @FromDate);
    IF @ToDate < @FromDate BEGIN RAISERROR('The To date cannot be before the From date.', 16, 1); RETURN; END
    IF DATEDIFF(DAY, @FromDate, @ToDate) > 92 BEGIN RAISERROR('Choose a range of 3 months or less.', 16, 1); RETURN; END

    SELECT c.CashLedgerId, c.CreatedDate AS DepositAt, c.UserId, ISNULL(p.FullName, p.Username) AS PhlebotomistName,
           -c.Amount AS Amount, c.DepositReference, ISNULL(r.FullName, r.Username) AS ReceivedBy
      FROM dbo.PhleboCashLedger c
      JOIN dbo.Users p ON p.Id = c.UserId
      LEFT JOIN dbo.Users r ON r.Id = c.CreatedBy
     WHERE c.BranchId = @BranchId AND c.EntryType = 'DEPOSIT'
       AND c.CreatedDate >= @FromDate AND c.CreatedDate < DATEADD(DAY, 1, @ToDate)
       AND (@PhlebotomistId IS NULL OR c.UserId = @PhlebotomistId)
     ORDER BY c.CreatedDate DESC;
END
GO

-- record cash handed over by a phlebotomist; never more than they hold
CREATE OR ALTER PROCEDURE dbo.usp_Lab_PhleboCash_Deposit
    @BranchId       INT,
    @PhlebotomistId INT,
    @Amount         DECIMAL(12, 2),
    @Reference      NVARCHAR(100) = NULL,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Company INT = (SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId);

    IF @PhlebotomistId = @UserId BEGIN RAISERROR('Another person must take your deposit.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.Users u JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1
                    WHERE u.Id = @PhlebotomistId AND u.IsPhlebotomist = 1)
        BEGIN RAISERROR('This phlebotomist does not belong to this branch.', 16, 1); RETURN; END
    IF ISNULL(@Amount, 0) <= 0 BEGIN RAISERROR('Enter the amount deposited.', 16, 1); RETURN; END
    IF @Amount <> ROUND(@Amount, 2) BEGIN RAISERROR('Enter the amount in rupees and paise.', 16, 1); RETURN; END

    BEGIN TRAN;
    -- the lock stops two counters taking the same cash twice
    DECLARE @Held DECIMAL(12, 2) = ISNULL((SELECT SUM(Amount) FROM dbo.PhleboCashLedger WITH (UPDLOCK, HOLDLOCK) WHERE UserId = @PhlebotomistId), 0);
    IF @Amount > @Held
    BEGIN
        ROLLBACK;
        DECLARE @Msg NVARCHAR(200) = CONCAT(N'The deposit cannot be more than the cash held (₹', FORMAT(@Held, 'N2', 'en-IN'), N').');
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END

    INSERT dbo.PhleboCashLedger (CompanyId, BranchId, UserId, LabOrderId, PaymentDetailId, Amount, EntryType, DepositReference, CreatedBy)
    VALUES (@Company, @BranchId, @PhlebotomistId, NULL, NULL, -@Amount, 'DEPOSIT', NULLIF(LTRIM(RTRIM(@Reference)), N''), @UserId);
    COMMIT;

    SELECT @Held - @Amount AS CashHeld;
END
GO

-- ── page and endpoints ──────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @lab INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @lab = NULL;
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @lab IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.PHLEBOCASH', @Title = N'Phlebotomist Cash Deposit',
             @Controller = N'LabPhleboCash', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 36, @Icon = N'bi bi-cash-coin me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboCash', @Action = N'Index',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboCash', @Action = N'Data',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabPhleboCash', @Action = N'Deposit',  @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
