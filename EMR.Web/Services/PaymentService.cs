using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class PaymentService(IDbConnectionFactory db, IMembershipPointsWhatsAppService pointsWhatsApp,
    EMR.Web.Services.Notifications.INotificationService notifications) : IPaymentService
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
                    (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM PaymentDetail pd WHERE pd.PaymentHeaderId = PaymentHeader.PaymentHeaderId AND pd.IsActive = 1)
                    - (SELECT ISNULL(SUM(br.RefundAmount), 0) FROM BillRefund br WHERE br.ModuleCode = PaymentHeader.ModuleCode AND br.ModuleRefId = PaymentHeader.ModuleRefId AND br.IsActive = 1) AS PaidFromReceipts
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
                    (SELECT ISNULL(SUM(pd.PaidAmount), 0) FROM PaymentDetail pd WHERE pd.PaymentHeaderId = PaymentHeader.PaymentHeaderId AND pd.IsActive = 1)
                    - (SELECT ISNULL(SUM(br.RefundAmount), 0) FROM BillRefund br WHERE br.ModuleCode = PaymentHeader.ModuleCode AND br.ModuleRefId = PaymentHeader.ModuleRefId AND br.IsActive = 1) AS PaidFromReceipts
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

    /// <summary>Roles whose users may approve a discount on a LAB bill (the payment screen's "Approved by" list).</summary>
    public static readonly string[] LabDiscountApproverRoles = ["Administrator", "Manager"];

    public const string LabDiscountApproverMessage = "The discount must be approved by a user with the Administrator or Manager role.";

    /// <summary>Active users holding an active Administrator / Manager role - the SQL shared by the list and the save check.</summary>
    public const string LabDiscountApproverSql = @"
        EXISTS (SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.Id = ur.RoleId
                WHERE ur.UserId = u.Id AND ur.IsActive = 1 AND r.Name IN @ApproverRoles)";

    private static async Task<bool> IsLabDiscountApproverAsync(System.Data.IDbConnection con, System.Data.IDbTransaction tx, int userId) =>
        await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM dbo.Users u WHERE u.Id = @userId AND u.IsActive = 1 AND " + LabDiscountApproverSql,
            new { userId, ApproverRoles = LabDiscountApproverRoles }, tx) > 0;

    /// <summary>True when the request carries a discount but no reason / approver (checked before a bill is saved).</summary>
    public static bool IsDiscountApprovalMissing(SavePaymentRequest? request) =>
        request != null
        && (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0)
        && (string.IsNullOrWhiteSpace(request.DiscountReason) || request.DiscountApprovedBy is null or <= 0);

    /// <summary>A bill discount split over the discountable lines in proportion to their amount, the last line taking the
    /// rounding remainder - exactly the split the line snapshot uses (and the payment screen shows).</summary>
    /// <summary>Adds each line's membership benefit to its discount (lines with a benefit took no manual share).</summary>
    private static void ApplyMembership(List<PaymentLineItemRow> lines)
    {
        foreach (var li in lines.Where(x => x.MembershipDiscountAmount > 0))
        {
            li.LineDiscountAmount = Math.Min(li.OriginalAmount, li.LineDiscountAmount + li.MembershipDiscountAmount);
            li.NetLineAmount = Math.Max(0, li.OriginalAmount - li.LineDiscountAmount);
            li.LineDiscountType ??= "M";
        }
    }

    private static void AllocateDiscount(List<PaymentLineItemRow> lines, decimal hDiscAmt, decimal discountableSubTotal)
    {
        var eligible = lines.Where(x => x.IsDiscountAllowed).ToList();
        if (hDiscAmt > 0 && discountableSubTotal > 0 && eligible.Count > 0)
        {
            decimal running = 0m;
            for (int i = 0; i < eligible.Count; i++)
            {
                var el = eligible[i];
                if (i == eligible.Count - 1) el.LineDiscountAmount = Math.Max(0, hDiscAmt - running);
                else { el.LineDiscountAmount = Math.Round(hDiscAmt * (el.OriginalAmount / discountableSubTotal), 2); running += el.LineDiscountAmount; }
                el.NetLineAmount = Math.Max(0, el.OriginalAmount - el.LineDiscountAmount);
            }
        }
        else foreach (var el in eligible) { el.LineDiscountAmount = 0m; el.NetLineAmount = el.OriginalAmount; }
        foreach (var nonEl in lines.Where(x => !x.IsDiscountAllowed)) { nonEl.LineDiscountAmount = 0m; nonEl.NetLineAmount = nonEl.OriginalAmount; }
    }

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

    /// <summary>Checks the membership points OTP of a payment (null = fine or no points redeemed). A verified OTP
    /// stays valid for the same points until it expires, so the booking screen checks it before the order is created
    /// and the payment checks it again.</summary>
    public async Task<string?> VerifyRedeemOtpAsync(SavePaymentRequest? request)
    {
        var redeem = request?.PointsRedeem is { Points: > 0 } pr ? pr : null;
        if (redeem == null) return null;
        if (request!.ModuleCode is { Length: > 0 } mc && mc != "LAB")
            return "Membership points can be redeemed on LAB bills only.";
        if (redeem.CardId <= 0 || redeem.OtpId <= 0 || string.IsNullOrWhiteSpace(redeem.OtpCode))
            return "Send the OTP to the card holder and enter it to redeem points.";
        try
        {
            using var otpCon = db.CreateConnection();
            await otpCon.ExecuteAsync("dbo.usp_Membership_RedeemOtpVerify",
                new { redeem.OtpId, redeem.CardId, redeem.Points, Code = redeem.OtpCode!.Trim() }, commandType: CommandType.StoredProcedure);
            return null;
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return ex.Message;
        }
    }

    public async Task<SavePaymentResult> SavePaymentAsync(SavePaymentRequest request, int? userId)
    {
        var result = await SavePaymentCoreAsync(request, userId);
        // a bill saved with a discount: the bell of the user chosen as "Approved by" (SQLScripts/2263) - once per bill
        if (result.Success && result.PaymentHeaderId is int headerId && request.DiscountApprovedBy is > 0
            && (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0))
            await notifications.NotifyDiscountApprovalAsync(headerId, userId);
        return result;
    }

    private async Task<SavePaymentResult> SavePaymentCoreAsync(SavePaymentRequest request, int? userId)
    {
        try
        {
            // ── Membership points (B2C LAB, SQLScripts/2236): the OTP is checked first, on its own, so a wrong code
            //    counts as an attempt even though the payment is not saved ──
            var redeem = request.PointsRedeem is { Points: > 0 } pr ? pr : null;
            var otpError = await VerifyRedeemOtpAsync(request);
            if (otpError != null) return new SavePaymentResult { Success = false, Error = otpError };

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

            // ── LAB misc charges (SQLScripts/2240): the bill's own misc lines, never the page's. B2C: their amount is part of
            //    the subtotal and GST is added on top; B2B: the partner's B2BTotal already includes them with GST ──
            List<LabOrderMiscLine> labMisc = [];
            bool labIsB2B = false;
            if (request.ModuleCode == "LAB")
            {
                labIsB2B = await con.ExecuteScalarAsync<bool>(
                    "SELECT CAST(ISNULL(IsB2B, 0) AS BIT) FROM LabOrder WHERE LabOrderId = @Id", new { Id = request.ModuleRefId }, tx);
                labMisc = await LabMiscCharges.LoadAsync(con, request.ModuleRefId, tx);
                if (!labIsB2B && labMisc.Count > 0)
                {
                    var activeTests = await con.QuerySingleOrDefaultAsync<decimal?>(
                        "SELECT SUM(Price) FROM LabOrderItem WHERE LabOrderId = @Id AND IsActive = 1", new { Id = request.ModuleRefId }, tx) ?? 0m;
                    dbSubTotal = activeTests + labMisc.Sum(m => m.Amount);
                }

                // payment lines: misc lines rebuilt from the bill, in the order the payment screen listed them (the discount
                // split gives the rounding remainder to the last line - the screen and the server must agree); lab tests carry no GST
                request.LineItems ??= [];
                var screenMiscOrder = request.LineItems
                    .Where(li => li.ModuleLineRefId < 0 || string.Equals(li.ServiceType, LabMiscCharges.ServiceType, StringComparison.OrdinalIgnoreCase))
                    .Select(li => li.ModuleLineRefId).ToList();
                labMisc = labMisc
                    .Select(m => (m, k: screenMiscOrder.FindIndex(r => r == -m.LabOrderMiscChargeId || r == m.MiscChargeId)))
                    .OrderBy(x => x.k < 0 ? int.MaxValue : x.k).ThenBy(x => x.m.LabOrderMiscChargeId)
                    .Select(x => x.m).ToList();
                request.LineItems.RemoveAll(li => li.ModuleLineRefId < 0 || string.Equals(li.ServiceType, LabMiscCharges.ServiceType, StringComparison.OrdinalIgnoreCase));
                foreach (var li in request.LineItems) { li.IsGstRequired = false; li.CgstAmount = 0; li.SgstAmount = 0; li.IgstAmount = 0; }
                foreach (var m in labMisc)
                    request.LineItems.Add(new PaymentLineItemRow
                    {
                        ModuleLineRefId = m.LineRefId,
                        LabOrderMiscChargeId = m.LabOrderMiscChargeId,
                        ItemDescription = m.DisplayName,
                        ServiceType = LabMiscCharges.ServiceType,
                        OriginalAmount = labIsB2B ? m.Amount + m.GstAmount : m.Amount,
                        NetLineAmount = labIsB2B ? m.Amount + m.GstAmount : m.Amount - m.DiscountAmount,
                        LineDiscountAmount = labIsB2B ? 0 : m.DiscountAmount,
                        IsDiscountAllowed = !labIsB2B && m.IsDiscountable,
                        IsGstRequired = !labIsB2B && m.IsGstRequired,
                        GstPercentage = labIsB2B ? null : m.GstPercentage,
                        CgstAmount = labIsB2B ? 0 : m.CgstAmount,
                        SgstAmount = labIsB2B ? 0 : m.SgstAmount
                    });
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
                if (!labIsB2B) discountableSubTotal += labMisc.Where(m => m.IsDiscountable).Sum(m => m.Amount);
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
                       DiscountReason, DiscountApprovedBy,
                       ISNULL(MembershipDiscountAmount, 0) AS MembershipDiscountAmount, ISNULL(MembershipTestDiscount, 0) AS MembershipTestDiscount
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
            if (request.ModuleCode == "LAB")
            {
                totalCgst = labIsB2B ? 0m : labMisc.Sum(m => m.CgstAmount);
                totalSgst = labIsB2B ? 0m : labMisc.Sum(m => m.SgstAmount);
                totalIgst = 0m;
            }

            if (existingHeader != null)
            {
                paymentHeaderId = (int)existingHeader.PaymentHeaderId;

                // Received so far = the bill's receipts less the refunds made on it (a cancelled line refunded)
                currentTotalPaid = await con.QuerySingleAsync<decimal>(@"
                    SELECT ISNULL((SELECT SUM(PaidAmount) FROM PaymentDetail WITH (UPDLOCK, HOLDLOCK)
                                   WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1), 0)
                         - ISNULL((SELECT SUM(RefundAmount) FROM BillRefund
                                   WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1), 0)",
                    new { PaymentHeaderId = paymentHeaderId, ModuleCode = (string)existingHeader.ModuleCode, ModuleRefId = (int)existingHeader.ModuleRefId }, tx);

                // LAB misc lines with GST: their GST was fixed at billing, so a due-collection discount does not apply to them
                if (request.ModuleCode == "LAB" && !labIsB2B)
                    discountableSubTotal -= labMisc.Where(m => m.IsDiscountable && m.IsGstRequired).Sum(m => m.Amount);

                // A bill is discounted only once: once it carries a discount, a later payment (due collection) cannot
                // add, raise, lower or replace it. Repeating the same discount is not a new one and is accepted.
                // the membership benefit (SQLScripts/2241) is not a manual discount
                decimal existingMemDisc = (decimal)existingHeader.MembershipDiscountAmount;
                decimal existingDiscount = Math.Max((decimal)existingHeader.HeaderDiscountAmount, (decimal)existingHeader.LineDiscountTotal - existingMemDisc);
                bool memTestBlocks = (decimal)existingHeader.MembershipTestDiscount > 0;
                if (request.ModuleCode == "LAB" && !labIsB2B)
                    discountableSubTotal -= labMisc.Where(m => m.IsDiscountable && !m.IsGstRequired && m.MembershipDiscountAmount > 0).Sum(m => m.Amount);
                bool requestHasDiscount = request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0;

                // Recompute net amount if new discount is applied, or maintain current net amount
                if (requestHasDiscount && memTestBlocks)
                    return new SavePaymentResult { Success = false, Error = LabMembershipBenefits.ManualDiscountBlockedMessage };

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
                    if (discountChanged && request.ModuleCode == "LAB" && !await IsLabDiscountApproverAsync(con, tx, request.DiscountApprovedBy!.Value))
                        return new SavePaymentResult { Success = false, Error = LabDiscountApproverMessage };

                    // + the membership benefit already on the bill (0 for every other bill)
                    decimal manualPart = hDiscAmt > 0 ? hDiscAmt : (existingMemDisc > 0 ? (decimal)existingHeader.HeaderDiscountAmount : lineDiscountTotal);
                    decimal totalDisc = Math.Min(dbSubTotal, manualPart + existingMemDisc);
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
                            LineDiscountTotal = manualPart + existingMemDisc,
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
                if (hDiscAmt > 0 && request.ModuleCode == "LAB" && !await IsLabDiscountApproverAsync(con, tx, request.DiscountApprovedBy!.Value))
                    return new SavePaymentResult { Success = false, Error = LabDiscountApproverMessage };

                // ── Membership benefits (B2C LAB, SQLScripts/2241): benefit rules on tests and Free Home Collection, from the
                //    member's plan; a line with a benefit takes no share of a manual discount, and benefit rules block one ──
                LabMemberBenefit? memBenefit = null;
                decimal memTotal = 0m, memTests = 0m;
                if (request.ModuleCode == "LAB" && !labIsB2B && request.LineItems != null)
                {
                    memBenefit = await LabMembershipBenefits.ForOrderAsync(con, request.ModuleRefId, tx);
                    if (memBenefit != null)
                    {
                        foreach (var li in request.LineItems)
                        {
                            var key = li.LabOrderMiscChargeId is > 0 ? "M" + li.LabOrderMiscChargeId : "I" + li.ModuleLineRefId;
                            if (!memBenefit.Lines.TryGetValue(key, out var b) || b.Discount <= 0) continue;
                            li.MembershipDiscountAmount = Math.Min(b.Discount, li.OriginalAmount);
                            if (li.IsDiscountAllowed) { li.IsDiscountAllowed = false; }
                            if (li.LabOrderMiscChargeId is > 0) memTotal += li.MembershipDiscountAmount;
                            else { memTotal += li.MembershipDiscountAmount; memTests += li.MembershipDiscountAmount; }
                        }
                        if (memTests > 0 && (deptMode || hDiscAmt > 0))
                            return new SavePaymentResult { Success = false, Error = LabMembershipBenefits.ManualDiscountBlockedMessage };
                        if (hDiscAmt > 0)
                        {
                            // the manual discount is worked out on the lines without a benefit
                            var freeBase = request.LineItems.Where(li => li.MembershipDiscountAmount > 0 && li.LabOrderMiscChargeId is > 0)
                                .Join(labMisc.Where(m => m.IsDiscountable), li => li.LabOrderMiscChargeId, m => m.LabOrderMiscChargeId, (li, m) => m.Amount).Sum();
                            discountableSubTotal = Math.Max(0, discountableSubTotal - freeBase);
                            if (request.HeaderDiscountType == "P") hDiscAmt = Math.Round(discountableSubTotal * (request.HeaderDiscountValue / 100m), 2);
                            else hDiscAmt = Math.Min(discountableSubTotal, hDiscAmt);
                        }
                    }
                }

                // LAB B2C misc lines: each line's share of the discount (the same split the lines get below), then GST on
                // what is left of it; the bill's GST and its misc lines follow
                if (request.ModuleCode == "LAB" && !labIsB2B && labMisc.Count > 0)
                {
                    if (!deptMode) AllocateDiscount(request.LineItems!, hDiscAmt, discountableSubTotal);
                    ApplyMembership(request.LineItems!);
                    totalCgst = 0m; totalSgst = 0m;
                    foreach (var li in request.LineItems!.Where(x => x.LabOrderMiscChargeId is > 0))
                    {
                        var m = labMisc.First(x => x.LabOrderMiscChargeId == li.LabOrderMiscChargeId);
                        if (deptMode) { li.LineDiscountAmount = li.MembershipDiscountAmount; li.NetLineAmount = Math.Max(0, li.OriginalAmount - li.LineDiscountAmount); }
                        var half = m.IsGstRequired ? LabMiscCharges.HalfGst(li.NetLineAmount, m.GstPercentage) : 0m;
                        li.CgstAmount = half; li.SgstAmount = half;
                        totalCgst += half; totalSgst += half;
                        await con.ExecuteAsync(@"
                            UPDATE LabOrderMiscCharge SET DiscountAmount = @Disc, CgstAmount = @Half, SgstAmount = @Half, GstAmount = @Half * 2,
                                   NetAmount = Amount - @Disc + @Half * 2, MembershipDiscountAmount = @Mem
                            WHERE LabOrderMiscChargeId = @Id",
                            new { Disc = li.LineDiscountAmount, Half = half, Id = m.LabOrderMiscChargeId, Mem = li.MembershipDiscountAmount }, tx);
                    }
                    await con.ExecuteAsync("dbo.usp_LabOrder_MiscSyncTotals", new { LabOrderId = request.ModuleRefId }, tx, commandType: CommandType.StoredProcedure);
                }

                decimal manualDisc = hDiscAmt > 0 ? hDiscAmt : (memTotal > 0 ? 0m : lineDiscountTotal);
                decimal totalDisc = Math.Min(dbSubTotal, manualDisc + memTotal);
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
                         DiscountReason, DiscountApprovedBy, DiscountApprovedDate, DiscountEnteredBy,
                         MembershipDiscountAmount, MembershipTestDiscount, MembershipCardId)
                    VALUES
                        (@ModuleCode, @ModuleRefId, @OPDServiceId, @BranchId, @PatientId,
                         @SubTotal, @LineDiscountTotal,
                         @HeaderDiscountType, @HeaderDiscountValue, @HeaderDiscountAmount,
                         @TotalCgstAmount, @TotalSgstAmount, @TotalIgstAmount,
                         @RoundOffAmount, @NetAmount, 0, @NetAmount, 'U',
                         @Notes, GETDATE(), @CreatedBy, 1,
                         @DiscountReason, @DiscountApprovedBy, CASE WHEN @DiscountApprovedBy IS NULL THEN NULL ELSE GETDATE() END,
                         CASE WHEN @DiscountApprovedBy IS NULL THEN NULL ELSE @CreatedBy END,
                         @MembershipDiscountAmount, @MembershipTestDiscount, @MembershipCardId);
                    SELECT SCOPE_IDENTITY();",
                    new
                    {
                        request.ModuleCode,
                        request.ModuleRefId,
                        OPDServiceId = opdServiceIdToSave,
                        request.BranchId,
                        request.PatientId,
                        SubTotal = dbSubTotal,
                        LineDiscountTotal = manualDisc + memTotal,
                        // a bill discounted only by the membership benefit is marked 'M' with its card as the reason
                        HeaderDiscountType  = hDiscAmt <= 0 && memTotal > 0 ? "M" : request.HeaderDiscountType,
                        HeaderDiscountValue  = request.HeaderDiscountValue,
                        HeaderDiscountAmount = hDiscAmt,
                        TotalCgstAmount = totalCgst,
                        TotalSgstAmount = totalSgst,
                        TotalIgstAmount = totalIgst,
                        RoundOffAmount = roundOff,
                        NetAmount = realTimeNetAmount,
                        request.Notes,
                        CreatedBy = userId,
                        DiscountReason = hDiscAmt > 0 ? request.DiscountReason?.Trim() : (memTotal > 0 ? memBenefit!.Reason : null),
                        DiscountApprovedBy = hDiscAmt > 0 ? request.DiscountApprovedBy : null,
                        MembershipDiscountAmount = memTotal,
                        MembershipTestDiscount = memTests,
                        MembershipCardId = memTotal > 0 ? memBenefit!.CardId : (int?)null
                    }, tx);

                // the card's history: the benefit given on this bill
                if (memTotal > 0)
                    await con.ExecuteAsync(@"
                        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, TxnType, Points, Amount, BalanceAfter, Narration, CreatedBy)
                        SELECT c.CardId, @PatientId, @BranchId, @HeaderId, 'DISCOUNT', 0, @Amt, c.PointsBalance,
                               CONCAT('Membership benefit Rs ', CAST(@Amt AS VARCHAR(20)), ' on LAB bill ', lo.BillNo,
                                      CASE WHEN @Tests > 0 THEN CONCAT(' (tests Rs ', CAST(@Tests AS VARCHAR(20)), ')') ELSE '' END,
                                      CASE WHEN @Amt - @Tests > 0 THEN CONCAT(' (free home collection Rs ', CAST(@Amt - @Tests AS VARCHAR(20)), ')') ELSE '' END),
                               @UserId
                        FROM dbo.MembershipCard c CROSS JOIN dbo.LabOrder lo
                        WHERE c.CardId = @CardId AND lo.LabOrderId = @LabOrderId",
                        new { memBenefit!.CardId, request.PatientId, request.BranchId, HeaderId = paymentHeaderId, Amt = memTotal, Tests = memTests,
                              UserId = userId ?? 1, LabOrderId = request.ModuleRefId }, tx);

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

                    // membership benefit on its lines (after the manual split, which gives them no share)
                    if (request.ModuleCode == "LAB") ApplyMembership(request.LineItems);

                    foreach (var li in request.LineItems)
                    {
                        await con.ExecuteAsync(@"
                            INSERT INTO PaymentLineItem
                                (PaymentHeaderId, ModuleLineRefId, ItemDescription, ServiceType,
                                 OriginalAmount, LineDiscountType, LineDiscountValue,
                                 LineDiscountAmount, NetLineAmount, 
                                 IsGstApplicable, GstPercentage, CgstAmount, SgstAmount, IgstAmount,
                                 CreatedDate, CreatedBy, IsActive, LabOrderMiscChargeId, MembershipDiscountAmount)
                            VALUES
                                (@PaymentHeaderId, @ModuleLineRefId, @ItemDescription, @ServiceType,
                                 @OriginalAmount, @LineDiscountType, @LineDiscountValue,
                                 @LineDiscountAmount, @NetLineAmount,
                                 @IsGstApplicable, @GstPercentage, @CgstAmount, @SgstAmount, @IgstAmount,
                                 GETDATE(), @CreatedBy, 1, @LabOrderMiscChargeId, @MembershipDiscountAmount)",
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
                                CreatedBy = userId,
                                li.LabOrderMiscChargeId,
                                li.MembershipDiscountAmount
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
                // Nothing is due on a saved bill: an amount or a discount entered now is refused, and nothing is saved
                // (it used to report success while saving nothing - or keeping only the discount).
                bool collecting = incomingPaidTotal > 0 || redeem != null;
                bool discounting = existingHeader != null && (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0);
                if (collecting || discounting)
                {
                    tx.Rollback();
                    var over = currentTotalPaid - realTimeNetAmount;
                    return new SavePaymentResult
                    {
                        Success = false,
                        Error = $"Nothing is due on this bill: ₹{currentTotalPaid:N2} has been received (after refunds) against a bill of ₹{realTimeNetAmount:N2}"
                              + (over >= 0.01m ? $" - ₹{over:N2} more than the bill" : "")
                              + ". Nothing was saved."
                    };
                }
                await con.ExecuteAsync("dbo.usp_Ledger_PostBillMoney",
                    new { Kind = "ADJUST", RefId = paymentHeaderId, UserId = userId ?? 1 }, tx, commandType: CommandType.StoredProcedure);
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
            if (incomingPaidTotal > 0 || redeem != null)
            {
                // Receipt number: <Branch Code><FY><8-digit serial>, e.g. HO262700000001 - one generator for every module (script 2193)
                var receiptParams = new DynamicParameters();
                receiptParams.Add("@BranchId", request.BranchId);
                receiptParams.Add("@ReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
                await con.ExecuteAsync("dbo.usp_Receipt_GetNextNo", receiptParams, tx, commandType: CommandType.StoredProcedure);
                string batchReceiptNo = receiptParams.Get<string>("@ReceiptNo");
                savedReceiptNo = batchReceiptNo;

                foreach (var p in request.Payments ?? [])
                {
                    if (p.PaidAmount <= 0) continue;

                    var paymentDetailId = await con.ExecuteScalarAsync<int>(@"
                        INSERT INTO PaymentDetail
                            (PaymentHeaderId, PaymentMethodId, PaidAmount,
                             TransactionRef, ChequeNo, BankName, UPIRefNo, CardLast4,
                             PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
                        OUTPUT INSERTED.PaymentDetailId
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

                    // ledger: Dr Cash / Bank, Cr the bill's receivable (SQLScripts/2232)
                    await con.ExecuteAsync("dbo.usp_Ledger_PostBillMoney",
                        new { Kind = "RECEIPT", RefId = paymentDetailId, UserId = userId ?? 1 }, tx, commandType: CommandType.StoredProcedure);
                }

                // membership points pay part of the bill: checked against the plan (Max Redeem %, Min Redeem Bill
                // Amount, Point Value), the card's balance, what is still due and the verified OTP; same receipt
                if (redeem != null)
                {
                    var rp = new DynamicParameters();
                    rp.Add("@PaymentHeaderId", paymentHeaderId);
                    rp.Add("@CardId", redeem.CardId);
                    rp.Add("@Points", redeem.Points);
                    rp.Add("@OtpId", redeem.OtpId);
                    rp.Add("@ReceiptNo", batchReceiptNo);
                    rp.Add("@BranchId", request.BranchId);
                    rp.Add("@UserId", userId ?? 1);
                    rp.Add("@RedeemAmount", dbType: DbType.Decimal, precision: 12, scale: 2, direction: ParameterDirection.Output);
                    await con.ExecuteAsync("dbo.usp_Membership_RedeemOnBill", rp, tx, commandType: CommandType.StoredProcedure);
                }
            }

            // ── Final Recalculate totals on header ─────────────────────────────
            var newTotalPaid = await con.QuerySingleAsync<decimal>(@"
                SELECT ISNULL((SELECT SUM(d.PaidAmount) FROM PaymentDetail d WHERE d.PaymentHeaderId = @PaymentHeaderId AND d.IsActive = 1), 0)
                     - ISNULL((SELECT SUM(r.RefundAmount) FROM PaymentHeader h
                               INNER JOIN BillRefund r ON r.ModuleCode = h.ModuleCode AND r.ModuleRefId = h.ModuleRefId AND r.IsActive = 1
                               WHERE h.PaymentHeaderId = @PaymentHeaderId), 0)",
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

            // membership points of a B2C LAB bill: earned once the bill is fully paid (SQLScripts/2236)
            if (request.ModuleCode == "LAB")
                await con.ExecuteAsync("dbo.usp_Membership_SyncBill", new { PaymentHeaderId = paymentHeaderId, UserId = userId ?? 1 }, tx,
                    commandType: CommandType.StoredProcedure);

            // ledger: discount / round-off entries follow the bill (SQLScripts/2232)
            await con.ExecuteAsync("dbo.usp_Ledger_PostBillMoney",
                new { Kind = "ADJUST", RefId = paymentHeaderId, UserId = userId ?? 1 }, tx, commandType: CommandType.StoredProcedure);

            tx.Commit();

            // what the bill did with membership points
            (string? CardNo, decimal Redeemed, decimal RedeemedAmount, decimal Earned, decimal Balance) mem = default;
            if (request.ModuleCode == "LAB")
                mem = await con.QueryFirstOrDefaultAsync<(string?, decimal, decimal, decimal, decimal)>(@"
                    SELECT c.CardNo, ph.PointsRedeemed, ph.PointsRedeemedAmount, ph.PointsEarned, ISNULL(c.PointsBalance, 0)
                    FROM PaymentHeader ph LEFT JOIN MembershipCard c ON c.CardId = ph.MembershipCardId
                    WHERE ph.PaymentHeaderId = @Id", new { Id = paymentHeaderId });
            // points earned by this payment: WhatsApp to the card holder (if switched on for the branch, SQLScripts/2243)
            if (request.ModuleCode == "LAB" && mem.Item4 > 0)
                pointsWhatsApp.QueueForPayment(paymentHeaderId, userId);

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
                ReceiptNo       = savedReceiptNo,
                MembershipCardNo     = mem.CardNo,
                PointsRedeemed       = mem.Redeemed,
                PointsRedeemedAmount = mem.RedeemedAmount,
                PointsEarned         = mem.Earned,
                PointsBalance        = mem.Balance
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
