using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class PaymentService(IDbConnectionFactory db) : IPaymentService
{
    // ─── Get active payment methods ──────────────────────────────────────────
    public async Task<IEnumerable<PaymentMethodViewModel>> GetActiveMethodsAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PaymentMethodViewModel>(@"
            SELECT
                PaymentMethodId, MethodName, MethodCode,
                RequiresRef, RequiresChequeNo, RequiresBankName,
                RequiresUPIRef, RequiresCardLast4
            FROM PaymentMethodMaster
            WHERE IsActive = 1
            ORDER BY DisplayOrder", new { });
    }

    // ─── Get payment summary for a given bill ──────────────────────────────
    public async Task<PaymentSummaryViewModel?> GetPaymentSummaryAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();

        // Handle OPD specifically; other modules can be wired when implemented
        if (moduleCode == "OPD")
        {
            // Header + patient info
            var summary = await con.QuerySingleOrDefaultAsync<PaymentSummaryViewModel>(@"
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
                    ISNULL(s.BranchId, 0)   AS BranchId,
                    ISNULL(s.TotalAmount, 0) AS SubTotal
                FROM PatientOPDService s
                INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
                WHERE s.OPDServiceId = @ModuleRefId",
                new { ModuleRefId = moduleRefId });

            if (summary is null) return null;

            // Line items
            var items = await con.QueryAsync<PaymentLineItemSummary>(@"
                SELECT
                    si.ItemId           AS LineRefId,
                    si.ServiceType,
                    ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
                    ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
                    0                                AS LineDiscountAmount,
                    ISNULL(si.ServiceCharges, 0)     AS NetLineAmount,
                    CAST(ISNULL(sm.IsDiscountable, 1) AS BIT) AS IsDiscountAllowed
                FROM PatientOPDServiceItem si
                LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
                WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
                ORDER BY si.ItemId",
                new { ModuleRefId = moduleRefId });

            summary.Items = items.ToList();

            // Check if a payment header already exists (partial payment scenario)
            var existing = await con.QuerySingleOrDefaultAsync(@"
                SELECT
                    PaymentHeaderId, LineDiscountTotal,
                    HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                    RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus,
                    DiscountReason, DiscountApprovedBy,
                    (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName,
                    (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM PaymentDetail pd WHERE pd.PaymentHeaderId = PaymentHeader.PaymentHeaderId AND pd.IsActive = 1) AS PaidFromReceipts
                FROM PaymentHeader
                WHERE ModuleCode = 'OPD' AND ModuleRefId = @ModuleRefId AND IsActive = 1",
                new { ModuleRefId = moduleRefId });

            if (existing != null)
            {
                summary.HasExistingPayment     = true;
                summary.ExistingPaymentHeaderId = (int?)existing.PaymentHeaderId;
                summary.ExistingLineDiscountTotal   = (decimal)existing.LineDiscountTotal;
                summary.ExistingHeaderDiscountType  = string.IsNullOrEmpty((string?)existing.HeaderDiscountType)
                                                        ? (char?)null
                                                        : ((string)existing.HeaderDiscountType)[0];
                summary.ExistingHeaderDiscountValue  = (decimal?)existing.HeaderDiscountValue;
                summary.ExistingHeaderDiscountAmount = (decimal)existing.HeaderDiscountAmount;
                summary.ExistingDiscountReason = (string?)existing.DiscountReason;
                summary.ExistingDiscountApprovedBy = (int?)existing.DiscountApprovedBy;
                summary.ExistingDiscountApprovedByName = (string?)existing.DiscountApprovedByName;
                summary.RoundOffAmount = (decimal)existing.RoundOffAmount;
                summary.NetAmount    = (decimal)existing.NetAmount;
                summary.TotalPaid    = (decimal)existing.TotalPaid;
                summary.PaidFromReceipts = (decimal)existing.PaidFromReceipts;
                summary.BalanceDue   = (decimal)existing.BalanceDue;
                summary.PaymentStatus = (string)existing.PaymentStatus;

                var receipts = await con.QueryAsync<string>("SELECT DISTINCT ReceiptNo FROM PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND ReceiptNo IS NOT NULL AND IsActive = 1", new { PaymentHeaderId = (int)existing.PaymentHeaderId });
                summary.ReceiptNos = string.Join(", ", receipts);
            }
            else
            {
                summary.NetAmount    = summary.SubTotal;
                summary.BalanceDue   = summary.SubTotal;
                summary.PaymentStatus = "U";
            }

            return summary;
        }

        if (moduleCode == "LAB")
        {
            // Header + patient info for LAB
            var summary = await con.QuerySingleOrDefaultAsync<PaymentSummaryViewModel>(@"
                SELECT
                    s.LabOrderId            AS ModuleRefId,
                    'LAB'                   AS ModuleCode,
                    CAST(NULL AS INT)       AS OPDServiceId,
                    s.BillNo                AS OPDBillNo,
                    s.TokenNo,
                    p.PatientId,
                    p.PatientCode,
                    (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
                    p.PhoneNumber           AS PatientPhone,
                    ISNULL(s.BranchId, 0)   AS BranchId,
                    ISNULL(s.TotalAmount, 0) AS SubTotal
                FROM LabOrder s
                INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
                WHERE s.LabOrderId = @ModuleRefId",
                new { ModuleRefId = moduleRefId });

            if (summary is null) return null;

            // Line items
            var items = await con.QueryAsync<PaymentLineItemSummary>(@"
                SELECT
                    si.LabOrderItemId   AS LineRefId,
                    'LAB'               AS ServiceType,
                    CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Unknown Package)') ELSE ISNULL(sm.Test_Name, '(Unknown Test)') END AS ItemName,
                    ISNULL(si.Price, 0) AS OriginalAmount,
                    ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
                    ISNULL(pli.NetLineAmount, si.Price) AS NetLineAmount,
                    CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS IsDiscountAllowed
                FROM LabOrderItem si
                INNER JOIN LabOrder lo ON lo.LabOrderId = si.LabOrderId
                LEFT JOIN LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
                LEFT JOIN LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
                LEFT JOIN LabRateCardMaster m ON m.Branch_ID = lo.BranchId 
                    AND m.Rate_Type = 'B2C' 
                    AND m.Status = 1 
                    AND m.IsDeleted = 0 
                    AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
                LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
                    AND d.Item_ID = si.InvestigationId 
                    AND d.Item_Type = CASE WHEN si.Type = 'P' THEN 'Package' WHEN sm.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
                    AND d.IsDeleted = 0
                LEFT JOIN PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = si.LabOrderId AND ph.IsActive = 1
                LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
                    AND (pli.ModuleLineRefId = si.LabOrderItemId OR pli.ModuleLineRefId = si.InvestigationId)
                    AND pli.IsActive = 1
                WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
                ORDER BY si.LabOrderItemId",
                new { ModuleRefId = moduleRefId });

            summary.Items = items.ToList();

            // Check if a payment header already exists (partial payment scenario)
            var existing = await con.QuerySingleOrDefaultAsync(@"
                SELECT
                    PaymentHeaderId, LineDiscountTotal,
                    HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                    RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus,
                    DiscountReason, DiscountApprovedBy,
                    (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName,
                    (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM PaymentDetail pd WHERE pd.PaymentHeaderId = PaymentHeader.PaymentHeaderId AND pd.IsActive = 1) AS PaidFromReceipts
                FROM PaymentHeader
                WHERE ModuleCode = 'LAB' AND ModuleRefId = @ModuleRefId AND IsActive = 1",
                new { ModuleRefId = moduleRefId });

            if (existing != null)
            {
                summary.HasExistingPayment     = true;
                summary.ExistingPaymentHeaderId = (int?)existing.PaymentHeaderId;
                summary.ExistingLineDiscountTotal   = (decimal)existing.LineDiscountTotal;
                summary.ExistingHeaderDiscountType  = string.IsNullOrEmpty((string?)existing.HeaderDiscountType)
                                                        ? (char?)null
                                                        : ((string)existing.HeaderDiscountType)[0];
                summary.ExistingHeaderDiscountValue  = (decimal?)existing.HeaderDiscountValue;
                summary.ExistingHeaderDiscountAmount = (decimal)existing.HeaderDiscountAmount;
                summary.ExistingDiscountReason = (string?)existing.DiscountReason;
                summary.ExistingDiscountApprovedBy = (int?)existing.DiscountApprovedBy;
                summary.ExistingDiscountApprovedByName = (string?)existing.DiscountApprovedByName;
                summary.RoundOffAmount = (decimal)existing.RoundOffAmount;
                summary.NetAmount    = (decimal)existing.NetAmount;
                summary.TotalPaid    = (decimal)existing.TotalPaid;
                summary.PaidFromReceipts = (decimal)existing.PaidFromReceipts;
                summary.BalanceDue   = (decimal)existing.BalanceDue;
                summary.PaymentStatus = (string)existing.PaymentStatus;

                var receipts = await con.QueryAsync<string>("SELECT DISTINCT ReceiptNo FROM PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND ReceiptNo IS NOT NULL AND IsActive = 1", new { PaymentHeaderId = (int)existing.PaymentHeaderId });
                summary.ReceiptNos = string.Join(", ", receipts);
            }
            else
            {
                summary.NetAmount    = summary.SubTotal;
                summary.BalanceDue   = summary.SubTotal;
                summary.PaymentStatus = "U";
            }

            return summary;
        }

        // Future: IPD, MED — return null for now
        return null;
    }

    // ─── Save payment (new or top-up partial) ────────────────────────────────
    public const string DiscountApprovalRequiredMessage =
        "A discount needs a reason and the name of the person who approved it.";

    /// <summary>{0} = the discount already on the bill.</summary>
    public const string DiscountAlreadyGivenMessage =
        "A discount of ₹{0:N2} has already been given on this bill. A bill can be discounted only once - collect the payment without a new discount.";

    public const string DiscountNotPermittedMessage =
        "You do not have permission to give a discount. Ask a user with the Discount right on this screen.";

    /// <summary>True when the bill carries any discount, on the header or on a line.</summary>
    public static bool HasDiscount(SavePaymentRequest? request) =>
        request != null
        && (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0
            || (request.LineItems?.Any(l => l.LineDiscountAmount > 0 || l.LineDiscountValue > 0) ?? false));

    /// <summary>True when the request carries a discount but no reason / approver (checked before a bill is saved).</summary>
    public static bool IsDiscountApprovalMissing(SavePaymentRequest? request) =>
        request != null
        && (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0)
        && (string.IsNullOrWhiteSpace(request.DiscountReason) || request.DiscountApprovedBy is null or <= 0);

    /// <summary>Department-wise discount given at due collection: writes each test's discount onto the bill's existing
    /// line rows (matched by lab order item, or by investigation for older rows).</summary>
    private static async Task UpdateLabLineDiscountsAsync(System.Data.IDbConnection con, System.Data.IDbTransaction tx, int paymentHeaderId,
        IReadOnlyList<LabDiscountLine> lines, IReadOnlyList<LabLineDiscount> perLine, int? userId)
    {
        for (int i = 0; i < lines.Count; i++)
        {
            var d = perLine[i];
            var args = new
            {
                PaymentHeaderId = paymentHeaderId,
                ItemId = lines[i].LabOrderItemId,
                lines[i].InvestigationId,
                Type = d.Amount > 0 ? d.Type : null,
                Value = d.Amount > 0 ? d.Value : (decimal?)null,
                d.Amount,
                ModifiedBy = userId
            };
            const string set = @"SET LineDiscountType = @Type, LineDiscountValue = @Value, LineDiscountAmount = @Amount,
                                     NetLineAmount = CASE WHEN OriginalAmount - @Amount < 0 THEN 0 ELSE OriginalAmount - @Amount END";
            var n = await con.ExecuteAsync($"UPDATE PaymentLineItem {set} WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1 AND ModuleLineRefId = @ItemId", args, tx);
            if (n == 0)
                await con.ExecuteAsync($"UPDATE PaymentLineItem {set} WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1 AND ModuleLineRefId = @InvestigationId", args, tx);
        }
    }

    /// <summary>
    /// Locks the bill row (LabOrder / PatientOPDService) for the rest of the payment transaction, so two payments of the
    /// same bill can never be checked and saved at the same time. Returns an error when the bill is missing or cancelled.
    /// </summary>
    private static async Task<string?> LockBillAsync(System.Data.IDbConnection con, System.Data.IDbTransaction tx, SavePaymentRequest request)
    {
        bool? active = null;
        if (request.ModuleCode == "LAB")
            active = await con.QuerySingleOrDefaultAsync<bool?>(
                "SELECT CAST(ISNULL(IsActive, 0) AS BIT) FROM dbo.LabOrder WITH (UPDLOCK, ROWLOCK) WHERE LabOrderId = @Id",
                new { Id = request.ModuleRefId }, tx);
        else if (request.ModuleCode == "OPD")
            active = await con.QuerySingleOrDefaultAsync<bool?>(
                "SELECT CAST(ISNULL(IsActive, 0) AS BIT) FROM dbo.PatientOPDService WITH (UPDLOCK, ROWLOCK) WHERE OPDServiceId = @Id",
                new { Id = request.OPDServiceId is > 0 ? request.OPDServiceId.Value : request.ModuleRefId }, tx);
        else
            return null;   // other modules: unchanged

        if (active is null) return "The bill was not found. Nothing was saved.";
        if (active == false) return "This bill has been cancelled. A payment cannot be collected on it.";
        return null;
    }

    /// <summary>
    /// Checks the payment lines before anything is written: no negative amount, at most two decimals, an active payment
    /// mode, and a UPI / bank reference that is not already recorded on another receipt (nor twice in this payment).
    /// </summary>
    private static async Task<string?> ValidatePaymentRowsAsync(System.Data.IDbConnection con, System.Data.IDbTransaction tx, IReadOnlyList<PaymentDetailRow>? payments)
    {
        if (payments is null || payments.Count == 0) return null;
        if (payments.Any(p => p.PaidAmount < 0)) return "A payment amount cannot be negative.";
        if (payments.Any(p => decimal.Round(p.PaidAmount, 2) != p.PaidAmount)) return "A payment amount can have at most two decimals.";

        var paying = payments.Where(p => p.PaidAmount > 0).ToList();
        if (paying.Count == 0) return null;

        var methodIds = paying.Select(p => p.PaymentMethodId).Distinct().ToList();
        var active = (await con.QueryAsync<int>(
            "SELECT PaymentMethodId FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND PaymentMethodId IN @Ids",
            new { Ids = methodIds }, tx)).ToHashSet();
        if (methodIds.Any(id => !active.Contains(id))) return "Choose a valid payment mode for every amount entered.";

        static string? Ref(string? v) => string.IsNullOrWhiteSpace(v) ? null : v.Trim();
        var refs = paying.SelectMany(p => new[] { Ref(p.UPIRefNo), Ref(p.TransactionRef) }).Where(r => r != null).Select(r => r!).ToList();
        var twice = refs.GroupBy(r => r, StringComparer.OrdinalIgnoreCase).FirstOrDefault(g => g.Count() > 1);
        if (twice != null) return $"Reference {twice.Key} is entered on more than one payment line.";
        if (refs.Count > 0)
        {
            var used = await con.QueryFirstOrDefaultAsync<(string Ref, string? ReceiptNo)>(@"
                SELECT TOP 1 COALESCE(NULLIF(LTRIM(RTRIM(pd.UPIRefNo)), ''), NULLIF(LTRIM(RTRIM(pd.TransactionRef)), '')) AS Ref, pd.ReceiptNo
                FROM dbo.PaymentDetail pd
                WHERE pd.IsActive = 1 AND (LTRIM(RTRIM(pd.UPIRefNo)) IN @Refs OR LTRIM(RTRIM(pd.TransactionRef)) IN @Refs)",
                new { Refs = refs }, tx);
            if (used.Ref != null)
                return $"Reference {used.Ref} is already recorded on receipt {used.ReceiptNo ?? "(no receipt no.)"}. The same UPI / bank transaction cannot be collected twice.";
        }
        return null;
    }

    public async Task<SavePaymentResult> SavePaymentAsync(SavePaymentRequest request, int? userId)
    {
        try
        {
            using var con = db.CreateConnection();
            con.Open();
            using var tx = con.BeginTransaction();

            // ── Double-payment guard 1: lock the bill itself, so payments of one bill are saved one after another
            //    (from any screen or counter), and refuse a bill that does not exist or was cancelled ──
            var billCheck = await LockBillAsync(con, tx, request);
            if (billCheck != null) { tx.Rollback(); return new SavePaymentResult { Success = false, Error = billCheck }; }

            // ── Double-payment guard 2: every amount, mode and reference is checked before anything is written ──
            var paymentCheck = await ValidatePaymentRowsAsync(con, tx, request.Payments);
            if (paymentCheck != null) { tx.Rollback(); return new SavePaymentResult { Success = false, Error = paymentCheck }; }

            // ── Real-time Master/Order Resolution & SubTotal Calculation ─────────────
            decimal dbSubTotal = 0m;
            int? opdServiceIdToSave = null;

            if (request.ModuleCode == "OPD")
            {
                opdServiceIdToSave = (request.OPDServiceId.HasValue && request.OPDServiceId.Value > 0)
                    ? request.OPDServiceId
                    : request.ModuleRefId;

                // Query real-time active services total
                var opdItemsSum = await con.QuerySingleOrDefaultAsync<decimal?>(@"
                    SELECT SUM(ServiceCharges)
                    FROM PatientOPDServiceItem
                    WHERE OPDServiceId = @ModuleRefId AND IsActive = 1",
                    new { ModuleRefId = request.ModuleRefId }, tx);

                if (opdItemsSum.HasValue && opdItemsSum.Value > 0)
                {
                    dbSubTotal = opdItemsSum.Value;
                }
                else
                {
                    var opdMasterTotal = await con.QuerySingleOrDefaultAsync<decimal?>(@"
                        SELECT TotalAmount
                        FROM PatientOPDService
                        WHERE OPDServiceId = @ModuleRefId",
                        new { ModuleRefId = request.ModuleRefId }, tx);

                    dbSubTotal = opdMasterTotal ?? request.SubTotal;
                }
            }
            else if (request.ModuleCode == "LAB")
            {
                var labOrderInfo = await con.QuerySingleOrDefaultAsync<(decimal? TotalAmount, bool IsB2B, decimal? B2BTotal)>(@"
                    SELECT TotalAmount, IsB2B, B2BTotal
                    FROM LabOrder
                    WHERE LabOrderId = @ModuleRefId",
                    new { ModuleRefId = request.ModuleRefId }, tx);

                if (labOrderInfo.IsB2B)
                {
                    dbSubTotal = labOrderInfo.B2BTotal ?? request.SubTotal;
                }
                else
                {
                    // Query real-time active lab items total
                    var labItemsSum = await con.QuerySingleOrDefaultAsync<decimal?>(@"
                        SELECT SUM(Price)
                        FROM LabOrderItem
                        WHERE LabOrderId = @ModuleRefId AND IsActive = 1",
                        new { ModuleRefId = request.ModuleRefId }, tx);

                    if (labItemsSum.HasValue && labItemsSum.Value > 0)
                    {
                        dbSubTotal = labItemsSum.Value;
                    }
                    else
                    {
                        dbSubTotal = labOrderInfo.TotalAmount ?? request.SubTotal;
                    }
                }
            }
            else
            {
                dbSubTotal = request.SubTotal;
            }

            if (dbSubTotal <= 0 && request.SubTotal > 0)
            {
                dbSubTotal = request.SubTotal;
            }

            // ── Calculate Discountable SubTotal (for LAB, strictly items where Disc. Allowed = 1) ──
            decimal discountableSubTotal = dbSubTotal;
            if (request.ModuleCode == "LAB")
            {
                var eligibleSum = await con.QuerySingleOrDefaultAsync<decimal?>(@"
                    SELECT SUM(loi.Price)
                    FROM LabOrderItem loi
                    INNER JOIN LabOrder lo ON lo.LabOrderId = loi.LabOrderId
                    LEFT JOIN LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                    LEFT JOIN LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = lo.BranchId 
                        AND m.Rate_Type = 'B2C' 
                        AND m.Status = 1 
                        AND m.IsDeleted = 0 
                        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
                    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
                        AND d.Item_ID = loi.InvestigationId 
                        AND d.Item_Type = CASE WHEN loi.Type = 'P' THEN 'Package' WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
                        AND d.IsDeleted = 0
                    WHERE loi.LabOrderId = @ModuleRefId 
                      AND loi.IsActive = 1 
                      AND ISNULL(d.Is_Discount_Allowed, 0) = 1",
                    new { ModuleRefId = request.ModuleRefId }, tx);

                discountableSubTotal = eligibleSum ?? 0m;
            }

            // ── B2C LAB department-wise discount (type "D"): every line's discount comes from its head - its department,
            //    or Packages - recalculated here from the bill's own lines (the page only previews it) ──
            List<LabDiscountLine>? deptLines = null;
            List<LabLineDiscount>? deptPerLine = null;
            decimal deptTotal = 0m;
            bool deptMode = request.ModuleCode == "LAB"
                && string.Equals(request.HeaderDiscountType, LabDepartmentDiscount.HeaderType, StringComparison.OrdinalIgnoreCase);
            if (deptMode)
            {
                var (lines, isB2BOrder, _) = await LabDepartmentDiscount.LoadForOrderAsync(con, request.ModuleRefId, tx);
                if (isB2BOrder)
                    return new SavePaymentResult { Success = false, Error = "A department-wise discount is for B2C lab bills only." };
                var (perLine, total, deptError) = LabDepartmentDiscount.Compute(lines, request.DepartmentDiscounts);
                if (deptError != null)
                    return new SavePaymentResult { Success = false, Error = deptError };
                deptLines = lines;
                deptPerLine = perLine;
                deptTotal = total;
                request.HeaderDiscountType = LabDepartmentDiscount.HeaderType;
                request.HeaderDiscountValue = total;
                request.HeaderDiscountAmount = total;
            }

            // ── OPD: only services marked "Is Discountable" in Service Master take a bill discount (script 2190) ──
            // When every service of the bill is discountable nothing changes (opdLines stays null).
            List<(int ItemId, int ServiceId, decimal Charges, bool IsDiscountable)>? opdLines = null;
            if (request.ModuleCode == "OPD" && opdServiceIdToSave is > 0)
            {
                var rows = (await con.QueryAsync<(int ItemId, int ServiceId, decimal Charges, bool IsDiscountable)>(@"
                    SELECT si.ItemId, ISNULL(si.ServiceId, 0), ISNULL(si.ServiceCharges, 0), CAST(ISNULL(sm.IsDiscountable, 1) AS BIT)
                    FROM PatientOPDServiceItem si
                    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
                    WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1",
                    new { OPDServiceId = opdServiceIdToSave.Value }, tx)).ToList();
                if (rows.Any(r => !r.IsDiscountable))
                {
                    opdLines = rows;
                    discountableSubTotal = rows.Where(r => r.IsDiscountable).Sum(r => r.Charges);
                }
            }

            // ── Concurrency-Safe Header Lookup with (UPDLOCK, HOLDLOCK) ────────────
            var existingHeader = await con.QuerySingleOrDefaultAsync(@"
                SELECT PaymentHeaderId, ModuleCode, ModuleRefId, OPDServiceId, BranchId, PatientId,
                       SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                       TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus,
                       DiscountReason, DiscountApprovedBy
                FROM   PaymentHeader WITH (UPDLOCK, HOLDLOCK)
                WHERE  ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1",
                new { request.ModuleCode, request.ModuleRefId }, tx);

            int paymentHeaderId;
            decimal realTimeNetAmount;
            decimal currentTotalPaid = 0m;
            decimal lineDiscountTotal = request.LineItems?.Sum(li => li.LineDiscountAmount) ?? 0m;
            decimal totalCgst = request.LineItems?.Sum(li => li.CgstAmount) ?? 0m;
            decimal totalSgst = request.LineItems?.Sum(li => li.SgstAmount) ?? 0m;
            decimal totalIgst = request.LineItems?.Sum(li => li.IgstAmount) ?? 0m;

            if (existingHeader != null)
            {
                paymentHeaderId = (int)existingHeader.PaymentHeaderId;

                // Existing real-time paid amount from details
                currentTotalPaid = await con.QuerySingleAsync<decimal>(@"
                    SELECT ISNULL(SUM(PaidAmount), 0)
                    FROM   PaymentDetail WITH (UPDLOCK, HOLDLOCK)
                    WHERE  PaymentHeaderId = @PaymentHeaderId AND IsActive = 1",
                    new { PaymentHeaderId = paymentHeaderId }, tx);

                // A bill is discounted only once: once it carries a discount, a later payment (due collection) cannot
                // add, raise, lower or replace it. Repeating the same discount is not a new one and is accepted.
                decimal existingDiscount = Math.Max((decimal)existingHeader.HeaderDiscountAmount, (decimal)existingHeader.LineDiscountTotal);
                bool requestHasDiscount = request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0;

                // Recompute net amount if new discount is applied, or maintain current net amount
                if (requestHasDiscount)
                {
                    decimal hDiscAmt = 0m;
                    string? discType = !string.IsNullOrEmpty(request.HeaderDiscountType)
                        ? request.HeaderDiscountType
                        : (string?)existingHeader.HeaderDiscountType;
                    decimal discVal = request.HeaderDiscountValue > 0
                        ? request.HeaderDiscountValue
                        : ((decimal?)existingHeader.HeaderDiscountValue ?? 0m);

                    // Due collection (OPD and LAB alike): a % / ₹ discount is taken on the balance due, at most on the
                    // bill's discountable amount (items marked discountable) - exactly as the payment screen calculates it.
                    decimal balanceBeforeDiscount = Math.Max(0, (decimal)existingHeader.NetAmount - currentTotalPaid);
                    decimal discBase = Math.Min(balanceBeforeDiscount, discountableSubTotal);

                    if (deptMode)
                        hDiscAmt = deptTotal;
                    else if (discType == "P")
                        hDiscAmt = Math.Min(discBase, Math.Round(discBase * (discVal / 100m), 2));
                    else
                        hDiscAmt = Math.Min(discBase, request.HeaderDiscountAmount > 0 ? request.HeaderDiscountAmount : discVal);

                    if (existingDiscount > 0 && Math.Abs(hDiscAmt - existingDiscount) >= 0.01m)
                        return new SavePaymentResult { Success = false, Error = string.Format(DiscountAlreadyGivenMessage, existingDiscount) };

                    bool discountChanged = hDiscAmt > 0
                        && (hDiscAmt != (decimal)existingHeader.HeaderDiscountAmount || string.IsNullOrWhiteSpace((string?)existingHeader.DiscountReason));
                    bool approvalGiven = !string.IsNullOrWhiteSpace(request.DiscountReason) && request.DiscountApprovedBy is > 0;
                    if (discountChanged && !approvalGiven)
                        return new SavePaymentResult { Success = false, Error = DiscountApprovalRequiredMessage };

                    decimal totalDisc = Math.Min(dbSubTotal, hDiscAmt > 0 ? hDiscAmt : lineDiscountTotal);
                    decimal unroundedNet = Math.Max(0, dbSubTotal - totalDisc + totalCgst + totalSgst + totalIgst);
                    decimal roundedNet = Math.Round(unroundedNet, 0, MidpointRounding.AwayFromZero);
                    decimal roundOff = roundedNet - unroundedNet;
                    realTimeNetAmount = roundedNet;

                    await con.ExecuteAsync(@"
                        UPDATE PaymentHeader
                        SET HeaderDiscountType   = ISNULL(@HeaderDiscountType, HeaderDiscountType),
                            HeaderDiscountValue  = CASE WHEN ISNULL(@HeaderDiscountValue, 0) > 0 THEN @HeaderDiscountValue ELSE HeaderDiscountValue END,
                            HeaderDiscountAmount = @HeaderDiscountAmount,
                            LineDiscountTotal    = @LineDiscountTotal,
                            RoundOffAmount       = @RoundOffAmount,
                            NetAmount            = @NetAmount,
                            DiscountReason       = CASE WHEN @SaveApproval = 1 THEN @DiscountReason ELSE DiscountReason END,
                            DiscountApprovedBy   = CASE WHEN @SaveApproval = 1 THEN @DiscountApprovedBy ELSE DiscountApprovedBy END,
                            DiscountApprovedDate = CASE WHEN @SaveApproval = 1 THEN GETDATE() ELSE DiscountApprovedDate END,
                            DiscountEnteredBy    = CASE WHEN @SaveApproval = 1 THEN @ModifiedBy ELSE DiscountEnteredBy END,
                            LastModifiedDate     = GETDATE(),
                            LastModifiedBy       = @ModifiedBy
                        WHERE PaymentHeaderId = @PaymentHeaderId",
                        new
                        {
                            SaveApproval = approvalGiven && hDiscAmt > 0 ? 1 : 0,
                            DiscountReason = request.DiscountReason?.Trim(),
                            request.DiscountApprovedBy,
                            request.HeaderDiscountType,
                            request.HeaderDiscountValue,
                            HeaderDiscountAmount = hDiscAmt,
                            LineDiscountTotal = (hDiscAmt > 0 ? hDiscAmt : lineDiscountTotal),
                            RoundOffAmount = roundOff,
                            NetAmount = realTimeNetAmount,
                            ModifiedBy = userId,
                            PaymentHeaderId = paymentHeaderId
                        }, tx);

                    // department-wise: the bill's line rows carry each test's own discount
                    if (deptMode && deptLines != null && deptPerLine != null)
                        await UpdateLabLineDiscountsAsync(con, tx, paymentHeaderId, deptLines, deptPerLine, userId);
                }
                else
                {
                    decimal exNet = (decimal)existingHeader.NetAmount;
                    realTimeNetAmount = exNet > 0 ? exNet : dbSubTotal;
                }
            }
            else
            {
                // Calculating for new PaymentHeader
                decimal hDiscAmt = 0m;
                if (deptMode)
                    hDiscAmt = deptTotal;
                else if (request.HeaderDiscountType == "P")
                    hDiscAmt = Math.Round(discountableSubTotal * (request.HeaderDiscountValue / 100m), 2);
                else if (request.HeaderDiscountAmount > 0)
                    hDiscAmt = Math.Min(discountableSubTotal, request.HeaderDiscountAmount);
                else if (request.HeaderDiscountValue > 0)
                    hDiscAmt = Math.Min(discountableSubTotal, request.HeaderDiscountValue);

                if (hDiscAmt > 0 && (string.IsNullOrWhiteSpace(request.DiscountReason) || request.DiscountApprovedBy is null or <= 0))
                    return new SavePaymentResult { Success = false, Error = DiscountApprovalRequiredMessage };

                decimal totalDisc = Math.Min(dbSubTotal, hDiscAmt > 0 ? hDiscAmt : lineDiscountTotal);
                decimal unroundedNet = Math.Max(0, dbSubTotal - totalDisc + totalCgst + totalSgst + totalIgst);
                decimal roundedNet = Math.Round(unroundedNet, 0, MidpointRounding.AwayFromZero);
                decimal roundOff = roundedNet - unroundedNet;
                realTimeNetAmount = roundedNet;

                paymentHeaderId = await con.QuerySingleAsync<int>(@"
                    INSERT INTO PaymentHeader
                        (ModuleCode, ModuleRefId, OPDServiceId, BranchId, PatientId,
                         SubTotal, LineDiscountTotal,
                         HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                         TotalCgstAmount, TotalSgstAmount, TotalIgstAmount,
                         RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus,
                         Notes, CreatedDate, CreatedBy, IsActive,
                         DiscountReason, DiscountApprovedBy, DiscountApprovedDate, DiscountEnteredBy)
                    VALUES
                        (@ModuleCode, @ModuleRefId, @OPDServiceId, @BranchId, @PatientId,
                         @SubTotal, @LineDiscountTotal,
                         @HeaderDiscountType, @HeaderDiscountValue, @HeaderDiscountAmount,
                         @TotalCgstAmount, @TotalSgstAmount, @TotalIgstAmount,
                         @RoundOffAmount, @NetAmount, 0, @NetAmount, 'U',
                         @Notes, GETDATE(), @CreatedBy, 1,
                         @DiscountReason, @DiscountApprovedBy, CASE WHEN @DiscountApprovedBy IS NULL THEN NULL ELSE GETDATE() END,
                         CASE WHEN @DiscountApprovedBy IS NULL THEN NULL ELSE @CreatedBy END);
                    SELECT SCOPE_IDENTITY();",
                    new
                    {
                        request.ModuleCode,
                        request.ModuleRefId,
                        OPDServiceId = opdServiceIdToSave,
                        request.BranchId,
                        request.PatientId,
                        SubTotal = dbSubTotal,
                        LineDiscountTotal = (hDiscAmt > 0 ? hDiscAmt : lineDiscountTotal),
                        HeaderDiscountType  = request.HeaderDiscountType,
                        HeaderDiscountValue  = request.HeaderDiscountValue,
                        HeaderDiscountAmount = hDiscAmt,
                        TotalCgstAmount = totalCgst,
                        TotalSgstAmount = totalSgst,
                        TotalIgstAmount = totalIgst,
                        RoundOffAmount = roundOff,
                        NetAmount = realTimeNetAmount,
                        request.Notes,
                        CreatedBy = userId,
                        DiscountReason = hDiscAmt > 0 ? request.DiscountReason?.Trim() : null,
                        DiscountApprovedBy = hDiscAmt > 0 ? request.DiscountApprovedBy : null
                    }, tx);

                // Insert line items snapshot
                if (request.LineItems != null && request.LineItems.Any())
                {
                    // OPD: which lines may take the discount comes from Service Master, not from the page
                    if (opdLines != null)
                    {
                        foreach (var li in request.LineItems)
                        {
                            var match = opdLines.Where(l => l.ItemId == li.ModuleLineRefId).ToList();
                            if (match.Count == 0) match = opdLines.Where(l => l.ServiceId == li.ModuleLineRefId).ToList();
                            if (match.Count > 0) li.IsDiscountAllowed = match[0].IsDiscountable;
                        }
                    }

                    // Department-wise (B2C LAB): each line takes the discount of its own head, from the bill's lines
                    if (deptMode && deptLines != null && deptPerLine != null)
                    {
                        foreach (var li in request.LineItems)
                        {
                            int k = deptLines.FindIndex(l => l.LabOrderItemId == li.ModuleLineRefId);
                            if (k < 0) k = deptLines.FindIndex(l => l.InvestigationId == li.ModuleLineRefId);
                            var d = k >= 0 ? deptPerLine[k] : null;
                            li.LineDiscountType = d is { Amount: > 0 } ? d.Type : null;
                            li.LineDiscountValue = d is { Amount: > 0 } ? d.Value : 0m;
                            li.LineDiscountAmount = d?.Amount ?? 0m;
                            li.NetLineAmount = Math.Max(0, li.OriginalAmount - li.LineDiscountAmount);
                        }
                    }
                    // Reconcile line item discounts for LAB (and OPD bills with a non-discountable service)
                    // so only eligible items receive discount
                    else if (request.ModuleCode == "LAB" || opdLines != null)
                    {
                        var eligibleLines = request.LineItems.Where(x => x.IsDiscountAllowed).ToList();
                        if (hDiscAmt > 0 && discountableSubTotal > 0 && eligibleLines.Any())
                        {
                            decimal runningAllocated = 0m;
                            for (int i = 0; i < eligibleLines.Count; i++)
                            {
                                var el = eligibleLines[i];
                                if (i == eligibleLines.Count - 1)
                                {
                                    el.LineDiscountAmount = Math.Max(0, hDiscAmt - runningAllocated);
                                }
                                else
                                {
                                    el.LineDiscountAmount = Math.Round(hDiscAmt * (el.OriginalAmount / discountableSubTotal), 2);
                                    runningAllocated += el.LineDiscountAmount;
                                }
                                el.NetLineAmount = Math.Max(0, el.OriginalAmount - el.LineDiscountAmount);
                            }
                        }
                        else
                        {
                            foreach (var el in eligibleLines)
                            {
                                el.LineDiscountAmount = 0m;
                                el.NetLineAmount = el.OriginalAmount;
                            }
                        }

                        foreach (var nonEl in request.LineItems.Where(x => !x.IsDiscountAllowed))
                        {
                            nonEl.LineDiscountAmount = 0m;
                            nonEl.NetLineAmount = nonEl.OriginalAmount;
                        }
                    }

                    foreach (var li in request.LineItems)
                    {
                        await con.ExecuteAsync(@"
                            INSERT INTO PaymentLineItem
                                (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType,
                                 OriginalAmount, LineDiscountType, LineDiscountValue,
                                 LineDiscountAmount, NetLineAmount, 
                                 IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount,
                                 CreatedDate, CreatedBy, IsActive)
                            VALUES
                                (@PaymentHeaderId, @ModuleLineRefId, @ItemDescription, @ServiceType,
                                 @OriginalAmount, @LineDiscountType, @LineDiscountValue,
                                 @LineDiscountAmount, @NetLineAmount,
                                 @IsGstApplicable, @GstPercentage, @CgstAmount, @SgstAmount, @IgstAmount,
                                 GETDATE(), @CreatedBy, 1)",
                            new
                            {
                                PaymentHeaderId = paymentHeaderId,
                                li.ModuleLineRefId,
                                li.ItemDescription,
                                li.ServiceType,
                                li.OriginalAmount,
                                LineDiscountType  = li.LineDiscountType,
                                LineDiscountValue  = li.LineDiscountValue,
                                li.LineDiscountAmount,
                                li.NetLineAmount,
                                IsGstApplicable = li.IsGstRequired,
                                li.GstPercentage,
                                li.CgstAmount,
                                li.SgstAmount,
                                li.IgstAmount,
                                CreatedBy = userId
                            }, tx);
                    }
                }
            }

            int targetModuleRefId = (request.OPDServiceId.HasValue && request.OPDServiceId.Value > 0)
                ? request.OPDServiceId.Value
                : request.ModuleRefId;

            // ── Double-payment guard 3: the bill must still have received exactly what the payment screen showed. If
            //    another payment was saved meanwhile (second click, retried request, another counter) nothing is saved ──
            if (request.ExpectedTotalPaid is { } expectedPaid && Math.Abs(currentTotalPaid - expectedPaid) >= 0.01m)
            {
                tx.Rollback();
                return new SavePaymentResult
                {
                    Success = false,
                    Error = $"This bill was updated while the payment screen was open: ₹{currentTotalPaid:N2} has now been received " +
                            $"(the screen showed ₹{expectedPaid:N2}). Nothing was saved. Close and reopen the payment to see the current balance before collecting again."
                };
            }

            // ── Real-Time Balance Check & Overpayment Validation ─────────────────────
            decimal realTimeBalanceDue = Math.Max(0, realTimeNetAmount - currentTotalPaid);
            decimal incomingPaidTotal = request.Payments?
                .Where(p => p.PaidAmount > 0)
                .Sum(p => p.PaidAmount) ?? 0m;

            // Scenario 1: Bill is ALREADY fully paid (e.g. duplicate click / duplicate request)
            if (realTimeBalanceDue <= 0)
            {
                tx.Commit();

                string? existingToken = null;
                if (request.ModuleCode == "OPD")
                {
                    existingToken = await con.QuerySingleOrDefaultAsync<string>(
                        "SELECT TokenNo FROM PatientOPDService WHERE OPDServiceId = @OPDServiceId",
                        new { OPDServiceId = targetModuleRefId });
                }
                else if (request.ModuleCode == "LAB")
                {
                    existingToken = await con.QuerySingleOrDefaultAsync<string>(
                        "SELECT TokenNo FROM LabOrder WHERE LabOrderId = @LabOrderId",
                        new { LabOrderId = targetModuleRefId });
                }

                return new SavePaymentResult
                {
                    Success         = true,
                    PaymentHeaderId = paymentHeaderId,
                    NetAmount       = realTimeNetAmount,
                    TotalPaid       = currentTotalPaid,
                    BalanceDue      = 0m,
                    PaymentStatus   = "P",
                    TokenNo         = existingToken
                };
            }

            // Scenario 2: Incoming payment exceeds remaining payable amount
            // STRICT RULE: Paid amount can NEVER exceed payable amount!
            if (incomingPaidTotal > realTimeBalanceDue + 0.001m)
            {
                tx.Rollback();
                return new SavePaymentResult
                {
                    Success = false,
                    Error = $"Payment amount (₹{incomingPaidTotal:N2}) cannot exceed the remaining balance payable of ₹{realTimeBalanceDue:N2}."
                };
            }

            // ── Insert PaymentDetail rows for valid payment ──────────────────────────
            string? savedReceiptNo = null;
            if (incomingPaidTotal > 0 && request.Payments != null)
            {
                // Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 - one generator for every module (script 2193)
                var receiptParams = new DynamicParameters();
                receiptParams.Add("@BranchId", request.BranchId);
                receiptParams.Add("@ReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
                await con.ExecuteAsync("dbo.usp_Receipt_GetNextNo", receiptParams, tx, commandType: CommandType.StoredProcedure);
                string batchReceiptNo = receiptParams.Get<string>("@ReceiptNo");
                savedReceiptNo = batchReceiptNo;

                foreach (var p in request.Payments)
                {
                    if (p.PaidAmount <= 0) continue;

                    await con.ExecuteAsync(@"
                        INSERT INTO PaymentDetail
                            (PaymentHeaderId, PaymentMethodId, PaidAmount,
                             TransactionRef, ChequeNo, BankName, UPIRefNo, CardLast4,
                             PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
                        VALUES
                            (@PaymentHeaderId, @PaymentMethodId, @PaidAmount,
                             @TransactionRef, @ChequeNo, @BankName, @UPIRefNo, @CardLast4,
                             GETDATE(), @Notes, GETDATE(), @CreatedBy, 1, @ReceiptNo)",
                        new
                        {
                            PaymentHeaderId = paymentHeaderId,
                            p.PaymentMethodId,
                            p.PaidAmount,
                            p.TransactionRef,
                            p.ChequeNo,
                            p.BankName,
                            p.UPIRefNo,
                            p.CardLast4,
                            p.Notes,
                            CreatedBy = userId,
                            ReceiptNo = batchReceiptNo
                        }, tx);
                }
            }

            // ── Final Recalculate totals on header ─────────────────────────────
            var newTotalPaid = await con.QuerySingleAsync<decimal>(@"
                SELECT ISNULL(SUM(PaidAmount), 0)
                FROM   PaymentDetail
                WHERE  PaymentHeaderId = @PaymentHeaderId AND IsActive = 1",
                new { PaymentHeaderId = paymentHeaderId }, tx);

            decimal newBalanceDue = Math.Max(0, realTimeNetAmount - newTotalPaid);
            string status = newTotalPaid >= realTimeNetAmount ? "P"
                          : newTotalPaid > 0                  ? "R"
                                                              : "U";

            await con.ExecuteAsync(@"
                UPDATE PaymentHeader
                SET    TotalPaid        = @TotalPaid,
                       BalanceDue       = @BalanceDue,
                       PaymentStatus    = @PaymentStatus,
                       LastModifiedDate = GETDATE(),
                       LastModifiedBy   = @LastModifiedBy
                WHERE  PaymentHeaderId  = @PaymentHeaderId",
                new
                {
                    TotalPaid       = newTotalPaid,
                    BalanceDue      = newBalanceDue,
                    PaymentStatus   = status,
                    LastModifiedBy  = userId,
                    PaymentHeaderId = paymentHeaderId
                }, tx);

            tx.Commit();

            // ── Assign token on full payment ──────────────────────────────────
            string? assignedToken = null;
            if (status == "P" && request.ModuleCode == "OPD")
            {
                var tokenParams = new DynamicParameters();
                tokenParams.Add("@OPDServiceId", targetModuleRefId);
                tokenParams.Add("@TokenNo", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                await con.ExecuteAsync(
                    "dbo.usp_OPD_AssignTokenOnPayment",
                    tokenParams,
                    commandType: CommandType.StoredProcedure);
                assignedToken = tokenParams.Get<string?>("@TokenNo");
            }
            else if (request.ModuleCode == "LAB" && (status == "P" || await IsTokenOnDuePaymentEnabledAsync(con, request.BranchId)))
            {
                // Fully paid: always. Still due (partial / unpaid): only when Hospital Settings > LAB >
                // "Token No Generate in Due Payment" is Yes for the branch. The SP is idempotent, so a later full payment
                // simply returns the token that was already issued.
                var tokenParams = new DynamicParameters();
                tokenParams.Add("@LabOrderId", targetModuleRefId);
                tokenParams.Add("@TokenNo", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                await con.ExecuteAsync(
                    "dbo.usp_LAB_AssignTokenOnPayment",
                    tokenParams,
                    commandType: CommandType.StoredProcedure);
                assignedToken = tokenParams.Get<string?>("@TokenNo");

                // Auto-collect samples if HospitalSettings.IsSampleCollectionMandatory == NO (0) - unchanged: only on full payment
                if (status == "P")
                {
                    try
                    {
                        await con.ExecuteAsync(
                            "dbo.usp_SampleCollection_AutoCollectIfNoMandatory",
                            new { LabOrderId = targetModuleRefId, UserId = userId },
                            commandType: CommandType.StoredProcedure);
                    }
                    catch
                    {
                        // Non-blocking catch
                    }
                }
            }

            decimal finalRoundOff = await con.QuerySingleOrDefaultAsync<decimal>("SELECT ISNULL(RoundOffAmount, 0) FROM PaymentHeader WHERE PaymentHeaderId = @Id", new { Id = paymentHeaderId });

            return new SavePaymentResult
            {
                Success         = true,
                PaymentHeaderId = paymentHeaderId,
                RoundOffAmount  = finalRoundOff,
                NetAmount       = realTimeNetAmount,
                TotalPaid       = newTotalPaid,
                BalanceDue      = newBalanceDue,
                PaymentStatus   = status,
                TokenNo         = assignedToken,
                ReceiptNo       = savedReceiptNo
            };
        }
        catch (Exception ex)
        {
            return new SavePaymentResult { Success = false, Error = ex.Message };
        }
    }

    /// <summary>Hospital Settings > LAB > "Token No Generate in Due Payment" for the branch. Any failure means "No" (today's behaviour).</summary>
    private static async Task<bool> IsTokenOnDuePaymentEnabledAsync(System.Data.IDbConnection con, int branchId)
    {
        try
        {
            return await con.ExecuteScalarAsync<bool>(
                "SELECT CAST(ISNULL(MAX(CAST(TokenGenerateOnDuePayment AS INT)), 0) AS BIT) FROM dbo.HospitalSettings WHERE BranchId = @BranchId AND IsActive = 1",
                new { BranchId = branchId });
        }
        catch
        {
            return false;
        }
    }

    // ─── Get payment data for the print bill view ────────────────────────────
    public async Task<BillPaymentSummary?> GetPaymentForBillAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();

        var header = await con.QuerySingleOrDefaultAsync(@"
            SELECT PaymentHeaderId,
                   SubTotal, 
                   HeaderDiscountType AS DiscountType, 
                   HeaderDiscountValue AS DiscountValue, 
                   HeaderDiscountAmount AS DiscountAmount,
                   RoundOffAmount,
                   TotalCgstAmount, TotalSgstAmount, TotalIgstAmount,
                   NetAmount, TotalPaid, BalanceDue, PaymentStatus, 
                   LastModifiedDate AS PaidOn
            FROM PaymentHeader 
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1", 
            new { ModuleCode = moduleCode, ModuleRefId = moduleRefId });

        if (header == null) return null;

        var rows = await con.QueryAsync<BillPaymentRow>(@"
            SELECT
                pm.MethodName,
                pd.PaidAmount,
                pd.TransactionRef,
                pd.ChequeNo,
                pd.BankName,
                pd.UPIRefNo,
                pd.CardLast4,
                pd.ReceiptNo
            FROM PaymentDetail pd
            INNER JOIN PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = @HeaderId AND pd.IsActive = 1
            ORDER BY pd.PaymentDetailId",
            new { HeaderId = (int)header.PaymentHeaderId });

        var lineItems = await con.QueryAsync<BillPaymentLineItem>(@"
            SELECT ModuleLineRefId, CgstAmount, SgstAmount, IgstAmount, NetLineAmount
            FROM PaymentLineItem
            WHERE PaymentHeaderId = @HeaderId AND IsActive = 1",
            new { HeaderId = (int)header.PaymentHeaderId });

        return new BillPaymentSummary
        {
            SubTotal       = (decimal)header.SubTotal,
            DiscountType   = (string?)header.DiscountType,
            DiscountValue  = (decimal)header.DiscountValue,
            DiscountAmount = (decimal)header.DiscountAmount,
            RoundOffAmount = (decimal)header.RoundOffAmount,
            TotalCgstAmount= (decimal)header.TotalCgstAmount,
            TotalSgstAmount= (decimal)header.TotalSgstAmount,
            TotalIgstAmount= (decimal)header.TotalIgstAmount,
            NetAmount      = (decimal)header.NetAmount,
            TotalPaid      = (decimal)header.TotalPaid,
            BalanceDue     = (decimal)header.BalanceDue,
            PaymentStatus  = (string)header.PaymentStatus,
            PaidOn         = (DateTime?)header.PaidOn,
            Rows           = rows.ToList(),
            LineItems      = lineItems.ToList()
        };
    }
}
