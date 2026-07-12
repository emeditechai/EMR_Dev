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
                    NetAmount, TotalPaid, BalanceDue, PaymentStatus
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
                summary.NetAmount    = (decimal)existing.NetAmount;
                summary.TotalPaid    = (decimal)existing.TotalPaid;
                summary.BalanceDue   = (decimal)existing.BalanceDue;
                summary.PaymentStatus = (string)existing.PaymentStatus;

                var receipts = await con.QueryAsync<string>("SELECT ReceiptNo FROM PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND ReceiptNo IS NOT NULL AND IsActive = 1", new { PaymentHeaderId = (int)existing.PaymentHeaderId });
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

        // Future: IPD, LAB, MED — return null for now
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

            // ── Compute line discount and GST totals from submitted line items ──────────
            decimal lineDiscountTotal = request.LineItems.Sum(li => li.LineDiscountAmount);
            decimal totalCgst = request.LineItems.Sum(li => li.CgstAmount);
            decimal totalSgst = request.LineItems.Sum(li => li.SgstAmount);
            decimal totalIgst = request.LineItems.Sum(li => li.IgstAmount);

            // ── Resolve or create PaymentHeader ───────────────────────────────
            var existingHeaderId = await con.QuerySingleOrDefaultAsync<int?>(@"
                SELECT PaymentHeaderId
                FROM   PaymentHeader
                WHERE  ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1",
                new { request.ModuleCode, request.ModuleRefId }, tx);

            int paymentHeaderId;

            if (existingHeaderId.HasValue)
            {
                // Top-up partial payment — add new detail rows; recalculate totals after insert
                paymentHeaderId = existingHeaderId.Value;
            }
            else
            {
                // New payment header
                paymentHeaderId = await con.QuerySingleAsync<int>(@"
                    INSERT INTO PaymentHeader
                        (ModuleCode, ModuleRefId, OPDServiceId, BranchId, PatientId,
                         SubTotal, LineDiscountTotal,
                         HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
                         TotalCgstAmount, TotalSgstAmount, TotalIgstAmount,
                         NetAmount, TotalPaid, BalanceDue, PaymentStatus,
                         Notes, CreatedDate, CreatedBy, IsActive)
                    VALUES
                        (@ModuleCode, @ModuleRefId, @OPDServiceId, @BranchId, @PatientId,
                         @SubTotal, @LineDiscountTotal,
                         @HeaderDiscountType, @HeaderDiscountValue, @HeaderDiscountAmount,
                         @TotalCgstAmount, @TotalSgstAmount, @TotalIgstAmount,
                         @NetAmount, 0, @NetAmount, 'U',
                         @Notes, GETDATE(), @CreatedBy, 1);
                    SELECT SCOPE_IDENTITY();",
                    new
                    {
                        request.ModuleCode,
                        request.ModuleRefId,
                        request.OPDServiceId,
                        request.BranchId,
                        request.PatientId,
                        request.SubTotal,
                        LineDiscountTotal = lineDiscountTotal,
                        HeaderDiscountType  = request.HeaderDiscountType,
                        HeaderDiscountValue  = request.HeaderDiscountValue,
                        HeaderDiscountAmount = request.HeaderDiscountAmount,
                        TotalCgstAmount = totalCgst,
                        TotalSgstAmount = totalSgst,
                        TotalIgstAmount = totalIgst,
                        request.NetAmount,
                        request.Notes,
                        CreatedBy = userId
                    }, tx);

                // Insert line items (snapshot + per-line discount placeholders)
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

            // ── Insert PaymentDetail rows ──────────────────────────────────────
            var branchCode = await con.QuerySingleOrDefaultAsync<string>("SELECT BranchCode FROM Branchmaster WHERE BranchId = @BranchId", new { request.BranchId }, tx) ?? "BR";
            string financialYear = DateTime.Now.Month >= 4 ? $"{DateTime.Now.Year}-{DateTime.Now.Year + 1}" : $"{DateTime.Now.Year - 1}-{DateTime.Now.Year}";
            string datePart = DateTime.Now.ToString("ddMMyyyy");

            foreach (var p in request.Payments)
            {
                int nextSeq = await con.QuerySingleAsync<int>(@"
                    DECLARE @NextSeq INT;
                    UPDATE ReceiptSequence SET @NextSeq = LastSeq = LastSeq + 1 WHERE BranchId = @BranchId AND FinancialYear = @FinancialYear;
                    IF @NextSeq IS NULL
                    BEGIN
                        SET @NextSeq = 1;
                        INSERT INTO ReceiptSequence (BranchId, FinancialYear, LastSeq) VALUES (@BranchId, @FinancialYear, @NextSeq);
                    END
                    SELECT @NextSeq;", new { request.BranchId, FinancialYear = financialYear }, tx);

                string receiptNo = $"{branchCode}{datePart}{nextSeq:D6}";

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
                        ReceiptNo = receiptNo
                    }, tx);
            }

            // ── Recalculate totals on header ───────────────────────────────────
            var totalPaid = await con.QuerySingleAsync<decimal>(@"
                SELECT ISNULL(SUM(PaidAmount), 0)
                FROM   PaymentDetail
                WHERE  PaymentHeaderId = @PaymentHeaderId AND IsActive = 1",
                new { PaymentHeaderId = paymentHeaderId }, tx);

            // Fetch current netAmount from header (handles top-up case)
            var netAmount = await con.QuerySingleAsync<decimal>(
                "SELECT NetAmount FROM PaymentHeader WHERE PaymentHeaderId = @PaymentHeaderId",
                new { PaymentHeaderId = paymentHeaderId }, tx);

            decimal balanceDue = netAmount - totalPaid;
            string status = totalPaid >= netAmount ? "P"
                          : totalPaid > 0          ? "R"
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
                    TotalPaid      = totalPaid,
                    BalanceDue     = balanceDue,
                    PaymentStatus  = status,
                    LastModifiedBy = userId,
                    PaymentHeaderId = paymentHeaderId
                }, tx);

            tx.Commit();

            // ── Assign token on full payment ──────────────────────────────────
            // Once the bill is fully paid (PaymentStatus = 'P'), call the SP
            // that generates and writes the token to PatientOPDService.
            string? assignedToken = null;
            if (status == "P" && request.ModuleCode == "OPD" && request.OPDServiceId.HasValue)
            {
                // Run outside the now-committed transaction (the SP manages its own)
                var tokenParams = new DynamicParameters();
                tokenParams.Add("@OPDServiceId", request.OPDServiceId.Value);
                tokenParams.Add("@TokenNo", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
                await con.ExecuteAsync(
                    "dbo.usp_OPD_AssignTokenOnPayment",
                    tokenParams,
                    commandType: CommandType.StoredProcedure);
                assignedToken = tokenParams.Get<string?>("@TokenNo");
            }

            return new SavePaymentResult
            {
                Success         = true,
                PaymentHeaderId = paymentHeaderId,
                NetAmount       = netAmount,
                TotalPaid       = totalPaid,
                BalanceDue      = balanceDue,
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
