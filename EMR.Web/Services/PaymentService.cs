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
                    ISNULL(si.ServiceCharges, 0)     AS NetLineAmount
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
                    RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus
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
                summary.RoundOffAmount = (decimal)existing.RoundOffAmount;
                summary.NetAmount    = (decimal)existing.NetAmount;
                summary.TotalPaid    = (decimal)existing.TotalPaid;
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
                    ISNULL(sm.Test_Name, '(Unknown Test)') AS ItemName,
                    ISNULL(si.Price, 0) AS OriginalAmount,
                    ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
                    ISNULL(pli.NetLineAmount, si.Price) AS NetLineAmount,
                    CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS IsDiscountAllowed
                FROM LabOrderItem si
                INNER JOIN LabOrder lo ON lo.LabOrderId = si.LabOrderId
                LEFT JOIN LabInvestigationMaster sm ON sm.Test_ID = si.InvestigationId
                LEFT JOIN LabRateCardMaster m ON m.Branch_ID = lo.BranchId 
                    AND m.Rate_Type = 'B2C' 
                    AND m.Status = 1 
                    AND m.IsDeleted = 0 
                    AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
                LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
                    AND d.Item_ID = sm.Test_ID 
                    AND d.Item_Type = CASE WHEN sm.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
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
                    RoundOffAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus
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
                summary.RoundOffAmount = (decimal)existing.RoundOffAmount;
                summary.NetAmount    = (decimal)existing.NetAmount;
                summary.TotalPaid    = (decimal)existing.TotalPaid;
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
    public async Task<SavePaymentResult> SavePaymentAsync(SavePaymentRequest request, int? userId)
    {
        try
        {
            using var con = db.CreateConnection();
            con.Open();
            using var tx = con.BeginTransaction();

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
                    var labMasterTotal = await con.QuerySingleOrDefaultAsync<decimal?>(@"
                        SELECT TotalAmount
                        FROM LabOrder
                        WHERE LabOrderId = @ModuleRefId",
                        new { ModuleRefId = request.ModuleRefId }, tx);

                    dbSubTotal = labMasterTotal ?? request.SubTotal;
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
                    INNER JOIN LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
                    LEFT JOIN LabRateCardMaster m ON m.Branch_ID = lo.BranchId 
                        AND m.Rate_Type = 'B2C' 
                        AND m.Status = 1 
                        AND m.IsDeleted = 0 
                        AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
                    LEFT JOIN LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID 
                        AND d.Item_ID = lim.Test_ID 
                        AND d.Item_Type = CASE WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END 
                        AND d.IsDeleted = 0
                    WHERE loi.LabOrderId = @ModuleRefId 
                      AND loi.IsActive = 1 
                      AND ISNULL(d.Is_Discount_Allowed, 0) = 1",
                    new { ModuleRefId = request.ModuleRefId }, tx);

                discountableSubTotal = eligibleSum ?? 0m;
            }

            // ── Concurrency-Safe Header Lookup with (UPDLOCK, HOLDLOCK) ────────────
            var existingHeader = await con.QuerySingleOrDefaultAsync(@"
                SELECT PaymentHeaderId, ModuleCode, ModuleRefId, OPDServiceId, BranchId, PatientId,
                       SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                       TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus
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

                // Recompute net amount if new discount is applied, or maintain current net amount
                if (request.HeaderDiscountAmount > 0 || request.HeaderDiscountValue > 0)
                {
                    decimal hDiscAmt = 0m;
                    string? discType = !string.IsNullOrEmpty(request.HeaderDiscountType)
                        ? request.HeaderDiscountType
                        : (string?)existingHeader.HeaderDiscountType;
                    decimal discVal = request.HeaderDiscountValue > 0
                        ? request.HeaderDiscountValue
                        : ((decimal?)existingHeader.HeaderDiscountValue ?? 0m);

                    if (discType == "P")
                        hDiscAmt = Math.Round(discountableSubTotal * (discVal / 100m), 2);
                    else
                        hDiscAmt = Math.Min(discountableSubTotal, request.HeaderDiscountAmount > 0 ? request.HeaderDiscountAmount : discVal);

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
                            LastModifiedDate     = GETDATE(),
                            LastModifiedBy       = @ModifiedBy
                        WHERE PaymentHeaderId = @PaymentHeaderId",
                        new
                        {
                            request.HeaderDiscountType,
                            request.HeaderDiscountValue,
                            HeaderDiscountAmount = hDiscAmt,
                            LineDiscountTotal = (hDiscAmt > 0 ? hDiscAmt : lineDiscountTotal),
                            RoundOffAmount = roundOff,
                            NetAmount = realTimeNetAmount,
                            ModifiedBy = userId,
                            PaymentHeaderId = paymentHeaderId
                        }, tx);
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
                if (request.HeaderDiscountType == "P")
                    hDiscAmt = Math.Round(discountableSubTotal * (request.HeaderDiscountValue / 100m), 2);
                else if (request.HeaderDiscountAmount > 0)
                    hDiscAmt = Math.Min(discountableSubTotal, request.HeaderDiscountAmount);
                else if (request.HeaderDiscountValue > 0)
                    hDiscAmt = Math.Min(discountableSubTotal, request.HeaderDiscountValue);

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
                         Notes, CreatedDate, CreatedBy, IsActive)
                    VALUES
                        (@ModuleCode, @ModuleRefId, @OPDServiceId, @BranchId, @PatientId,
                         @SubTotal, @LineDiscountTotal,
                         @HeaderDiscountType, @HeaderDiscountValue, @HeaderDiscountAmount,
                         @TotalCgstAmount, @TotalSgstAmount, @TotalIgstAmount,
                         @RoundOffAmount, @NetAmount, 0, @NetAmount, 'U',
                         @Notes, GETDATE(), @CreatedBy, 1);
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
                        CreatedBy = userId
                    }, tx);

                // Insert line items snapshot
                if (request.LineItems != null && request.LineItems.Any())
                {
                    // Reconcile line item discounts for LAB so only eligible items receive discount
                    if (request.ModuleCode == "LAB")
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
            if (incomingPaidTotal > 0 && request.Payments != null)
            {
                var branchCode = await con.QuerySingleOrDefaultAsync<string>(
                    "SELECT BranchCode FROM Branchmaster WHERE BranchId = @BranchId",
                    new { request.BranchId }, tx) ?? "BR";
                string financialYear = DateTime.Now.Month >= 4
                    ? $"{DateTime.Now.Year}-{DateTime.Now.Year + 1}"
                    : $"{DateTime.Now.Year - 1}-{DateTime.Now.Year}";
                string datePart = DateTime.Now.ToString("ddMMyyyy");

                int nextSeq = await con.QuerySingleAsync<int>(@"
                    DECLARE @NextSeq INT;
                    UPDATE ReceiptSequence SET @NextSeq = LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FinancialYear;
                    IF @NextSeq IS NULL
                    BEGIN
                        SET @NextSeq = 1;
                        INSERT INTO ReceiptSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FinancialYear, @NextSeq);
                    END
                    SELECT @NextSeq;", new { request.BranchId, FinancialYear = financialYear }, tx);

                string batchReceiptNo = $"{branchCode}{datePart}{nextSeq:D6}";

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
            else if (status == "P" && request.ModuleCode == "LAB")
            {
                var tokenParams = new DynamicParameters();
                tokenParams.Add("@LabOrderId", targetModuleRefId);
                tokenParams.Add("@TokenNo", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                await con.ExecuteAsync(
                    "dbo.usp_LAB_AssignTokenOnPayment",
                    tokenParams,
                    commandType: CommandType.StoredProcedure);
                assignedToken = tokenParams.Get<string?>("@TokenNo");

                // Auto-collect samples if HospitalSettings.IsSampleCollectionMandatory == NO (0)
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
                TokenNo         = assignedToken
            };
        }
        catch (Exception ex)
        {
            return new SavePaymentResult { Success = false, Error = ex.Message };
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
