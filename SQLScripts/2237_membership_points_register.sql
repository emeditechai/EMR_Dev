-- ============================================================================
-- Migration: 2237_membership_points_register.sql
-- Description: Membership points on B2C LAB billing (2236) - reporting:
--   * usp_Api_LabReport_MembershipPoints: Reports > LAB > Membership Points Register. Every points movement of the
--     branch (earned, redeemed on a bill, given back after a cancellation, taken back, expired) with card, plan,
--     patient, bill and receipt; totals, groups (type / date / plan / user) and the points still outstanding on the
--     branch's cards (the liability). Branch-wide, like the B2B partner reports: it is about the cards, not about a
--     cashier's own work.
--   * Page REPORTS.LABMEMBERSHIPPOINTS under Reports > LAB (VIEW = the page, its data and the bill print).
--     No role is granted here: give it from Settings > Security (Super Admin sees it without a grant).
--   * usp_Api_MembershipCard_GetById: the card's Accounting Entries also list the points entries
--     (earned / taken back / expired, and points used as payment on a bill).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_MembershipPoints
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @TxnType      VARCHAR(10)   = NULL,   -- EARN / REDEEM / RESTORE / REVERSE / EXPIRE
    @PlanId       INT           = NULL,
    @CreatedBy    INT           = NULL,
    @Search       NVARCHAR(100) = NULL,
    @UserId       INT           = NULL,
    @IsAdmin      BIT           = 0,
    @IsSuperAdmin BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @TxnType = NULLIF(UPPER(LTRIM(RTRIM(@TxnType))), '');

    SELECT l.LedgerId, l.CreatedDate AS TxnDate,
           CONVERT(VARCHAR(10), CAST(l.CreatedDate AS DATE), 23) AS TxnDay,
           l.TxnType,
           CASE l.TxnType WHEN 'EARN' THEN 'Earned' WHEN 'REDEEM' THEN 'Redeemed' WHEN 'RESTORE' THEN 'Given back'
                          WHEN 'REVERSE' THEN 'Taken back' WHEN 'EXPIRE' THEN 'Expired' END AS TxnLabel,
           c.CardId, c.CardNo, p.PlanId, p.PlanName, p.PlanCode,
           CAST(l.Points AS DECIMAL(18, 2)) AS Points,
           CAST(CASE WHEN l.Points > 0 THEN l.Points ELSE 0 END AS DECIMAL(18, 2)) AS PointsIn,
           CAST(CASE WHEN l.Points < 0 THEN -l.Points ELSE 0 END AS DECIMAL(18, 2)) AS PointsOut,
           CAST(ISNULL(l.Amount, 0) AS DECIMAL(18, 2)) AS Amount,
           CAST(l.BalanceAfter AS DECIMAL(18, 2)) AS BalanceAfter,
           l.ExpiresOn, l.Narration,
           pm.PatientCode,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName,
           pm.PhoneNumber,
           lo.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
           COALESCE(l.ReceiptNo, pd.ReceiptNo) AS ReceiptNo,
           l.CreatedBy AS CreatedById,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedByName
    INTO #R
    FROM dbo.MembershipLedger l
    INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = ISNULL(l.PatientId, c.PrimaryPatientId)
    LEFT JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = l.PaymentHeaderId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId AND ph.ModuleCode = 'LAB'
    LEFT JOIN dbo.PaymentDetail pd ON pd.PaymentDetailId = l.PaymentDetailId
    LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.TxnType IN ('EARN', 'REDEEM', 'RESTORE', 'REVERSE', 'EXPIRE')
      AND l.CreatedDate >= @From AND l.CreatedDate < @To
      -- a bill movement belongs to the bill's branch; an expiry to the branch that issued the card
      AND (COALESCE(lo.BranchId, CASE WHEN l.TxnType = 'EXPIRE' THEN c.IssueBranchId END, l.BranchId) = @BranchId)
      AND (@TxnType IS NULL OR l.TxnType = @TxnType)
      AND (@PlanId IS NULL OR c.PlanId = @PlanId)
      AND (@CreatedBy IS NULL OR l.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR c.CardNo LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%'
           OR pm.PatientCode LIKE '%' + @Search + '%' OR pm.PhoneNumber LIKE '%' + @Search + '%'
           OR pm.FirstName LIKE '%' + @Search + '%' OR pm.LastName LIKE '%' + @Search + '%'
           OR l.ReceiptNo LIKE '%' + @Search + '%' OR pd.ReceiptNo LIKE '%' + @Search + '%');

    -- RS1 summary (+ what the branch's cards still hold today: the points liability)
    SELECT COUNT(1) AS TxnCount,
           COUNT(DISTINCT CardId) AS CardCount,
           COUNT(DISTINCT LabOrderId) AS BillCount,
           ISNULL(SUM(CASE WHEN TxnType = 'EARN'    THEN PointsIn  END), 0) AS EarnedPoints,
           ISNULL(SUM(CASE WHEN TxnType = 'EARN'    THEN Amount    END), 0) AS EarnedValue,
           ISNULL(SUM(CASE WHEN TxnType = 'REDEEM'  THEN PointsOut END), 0) AS RedeemedPoints,
           ISNULL(SUM(CASE WHEN TxnType = 'REDEEM'  THEN Amount    END), 0) AS RedeemedValue,
           ISNULL(SUM(CASE WHEN TxnType = 'RESTORE' THEN PointsIn  END), 0) AS RestoredPoints,
           ISNULL(SUM(CASE WHEN TxnType = 'RESTORE' THEN Amount    END), 0) AS RestoredValue,
           ISNULL(SUM(CASE WHEN TxnType = 'REVERSE' THEN PointsOut END), 0) AS ReversedPoints,
           ISNULL(SUM(CASE WHEN TxnType = 'REVERSE' THEN Amount    END), 0) AS ReversedValue,
           ISNULL(SUM(CASE WHEN TxnType = 'EXPIRE'  THEN PointsOut END), 0) AS ExpiredPoints,
           ISNULL(SUM(CASE WHEN TxnType = 'EXPIRE'  THEN Amount    END), 0) AS ExpiredValue,
           ISNULL(SUM(Points), 0) AS NetPoints,
           (SELECT ISNULL(SUM(c.PointsBalance), 0) FROM dbo.MembershipCard c
            WHERE c.IssueBranchId = @BranchId AND c.PointsBalance > 0) AS OutstandingPoints,
           (SELECT CAST(ISNULL(SUM(c.PointsBalance * p.PointValue), 0) AS DECIMAL(18, 2)) FROM dbo.MembershipCard c
            INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
            WHERE c.IssueBranchId = @BranchId AND c.PointsBalance > 0) AS OutstandingValue,
           (SELECT COUNT(1) FROM dbo.MembershipCard c WHERE c.IssueBranchId = @BranchId AND c.PointsBalance > 0) AS OutstandingCards
    FROM #R;

    -- RS2 groups
    SELECT 'byType' AS GroupKey, NULL AS GroupId, TxnLabel AS GroupName,
           CASE TxnType WHEN 'EARN' THEN 1 WHEN 'REDEEM' THEN 2 WHEN 'RESTORE' THEN 3 WHEN 'REVERSE' THEN 4 ELSE 5 END AS SortOrder,
           COUNT(1) AS TxnCount, SUM(PointsIn) AS PointsIn, SUM(PointsOut) AS PointsOut, SUM(Amount) AS Amount
    FROM #R GROUP BY TxnType, TxnLabel
    UNION ALL
    SELECT 'byDate', NULL, TxnDay, 0, COUNT(1), SUM(PointsIn), SUM(PointsOut), SUM(Amount) FROM #R GROUP BY TxnDay
    UNION ALL
    SELECT 'byPlan', PlanId, PlanName, 0, COUNT(1), SUM(PointsIn), SUM(PointsOut), SUM(Amount) FROM #R GROUP BY PlanId, PlanName
    UNION ALL
    SELECT 'byCreatedBy', CreatedById, CreatedByName, 0, COUNT(1), SUM(PointsIn), SUM(PointsOut), SUM(Amount) FROM #R GROUP BY CreatedById, CreatedByName
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY TxnDate DESC, LedgerId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(CreatedById AS VARCHAR(20)) AS Value, CreatedByName AS Text FROM #R WHERE CreatedById IS NOT NULL
    UNION
    SELECT 'planId', CAST(p.PlanId AS VARCHAR(20)), p.PlanName FROM dbo.MembershipPlan p WHERE p.IsActive = 1
    ORDER BY FilterKey, Text;

    DROP TABLE #R;
END;
GO

-- the card's Accounting Entries: card fee + every points entry of the card
CREATE OR ALTER PROCEDURE dbo.usp_Api_MembershipCard_GetById
    @CardId    INT,
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT c.CardId, c.CompanyId, c.CardNo, c.PlanId, p.PlanCode, p.PlanName, p.PlanType, p.MaxMembers, p.Terms, p.FreeHomeCollection,
           c.IssueBranchId, b.BranchName AS IssueBranchName, c.PrimaryPatientId, pm.PatientCode,
           LTRIM(RTRIM(CONCAT(pm.Salutation + ' ', pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.EmailId, pm.Gender, pm.DateOfBirth,
           c.ValidFrom, c.ValidTo,
           CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS Status, c.StatusReason,
           c.FeeAmount, c.FeePaymentHeaderId, c.ReceiptNo, c.PointsBalance, c.Remarks,
           c.PrintCount, c.LastPrintedOn, c.WhatsAppSentOn, c.EmailSentOn, c.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS IssuedByName,
           (SELECT TOP 1 pmm.MethodName FROM dbo.PaymentDetail pd INNER JOIN dbo.PaymentMethodMaster pmm ON pmm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = c.FeePaymentHeaderId AND pd.IsActive = 1) AS PaymentMethodName
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan p ON p.PlanId = c.PlanId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = c.PrimaryPatientId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.IssueBranchId
    LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.CardId = @CardId AND c.CompanyId = @CompanyId;

    SELECT m.CardMemberId, m.PatientId, pm.PatientCode, LTRIM(RTRIM(CONCAT(pm.FirstName, ' ', pm.LastName))) AS PatientName,
           pm.PhoneNumber, pm.Gender, pm.DateOfBirth, m.Relation, m.IsPrimary, m.CreatedDate
    FROM dbo.MembershipCardMember m
    INNER JOIN dbo.MembershipCard c ON c.CardId = m.CardId AND c.CompanyId = @CompanyId
    INNER JOIN dbo.PatientMaster pm ON pm.PatientId = m.PatientId
    WHERE m.CardId = @CardId AND m.IsActive = 1
    ORDER BY m.IsPrimary DESC, m.CardMemberId;

    SELECT l.LedgerId, l.TxnType, l.Points, l.Amount, l.ExpiresOn, l.BalanceAfter, l.ReceiptNo, l.Narration, l.CreatedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    FROM dbo.MembershipLedger l
    INNER JOIN dbo.MembershipCard c ON c.CardId = l.CardId AND c.CompanyId = @CompanyId
    LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.CardId = @CardId
    ORDER BY l.LedgerId DESC;

    SELECT t.TransactionId, t.VoucherNo, vt.VoucherTypeName, t.TransactionDate, t.ReferenceType, lm.LedgerName,
           d.DebitAmount, d.CreditAmount, t.Narration
    FROM dbo.Acc_LedgerTransaction t
    INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId
    INNER JOIN dbo.Acc_LedgerMaster lm ON lm.LedgerId = d.LedgerId
    LEFT JOIN dbo.Acc_VoucherType vt ON vt.VoucherTypeId = t.VoucherTypeId
    WHERE t.CompanyId = @CompanyId AND t.IsActive = 1
      AND (   (t.ReferenceType IN ('MEM_CARD', 'MEM_RECEIPT') AND t.ReferenceId = @CardId)
           -- 2237: points earned / taken back / expired (per history row of this card)
           OR (t.ReferenceType IN ('MEM_EARN', 'MEM_REVERSE', 'MEM_EXPIRE')
               AND t.ReferenceId IN (SELECT CAST(l.LedgerId AS INT) FROM dbo.MembershipLedger l WHERE l.CardId = @CardId))
           -- points used as payment on a bill (and given back): the POINTS payment lines of this card
           OR (t.ReferenceType = 'LAB_RECEIPT'
               AND t.ReferenceId IN (SELECT l.PaymentDetailId FROM dbo.MembershipLedger l WHERE l.CardId = @CardId AND l.PaymentDetailId IS NOT NULL)))
    ORDER BY t.TransactionId, d.TransactionDetailId;
END
GO

-- Page under Reports > LAB --------------------------------------------------------
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABMEMBERSHIPPOINTS',
             @Title = N'Membership Points Register', @Controller = N'Reports', @Action = N'LabMembershipPoints',
             @Show_In_Menu = 1, @Sort_Order = 55, @Icon = N'bi bi-award me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabMembershipPoints', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'PrintBill', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2237 applied: Membership Points Register (Reports > LAB), card accounting shows points entries.';
GO
