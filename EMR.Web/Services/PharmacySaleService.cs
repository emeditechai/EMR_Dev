using System.Text.Json;
using EMR.Web.ApiClients;

namespace EMR.Web.Services;

// Pharmacy > Sales (SQLScripts/2348): counter sale (POS), hold / recall, sale return, cancellation, credit collection.
// Money is kept like OPD / LAB (PaymentHeader / PaymentDetail, module 'PHR', receipt numbers from usp_Receipt_GetNextNo;
// refunds in BillRefund, cancellations in BillCancellation) so the cashier day closing and receipts see it; the ledger is
// posted by usp_Ph_PostSaleLedger. Prices, batches and amounts are always worked out here - the page only previews them.

public class PhPosItem
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public int? GenericId { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public int CategoryId { get; set; }
    public string ScheduleCode { get; set; } = "";
    public bool RxRequired { get; set; }
    public bool RegisterRequired { get; set; }
    public bool IsNarcotic { get; set; }
    public string? LabelWarning { get; set; }
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool AllowLooseSale { get; set; }
    public bool IsDiscountAllowed { get; set; }
    public bool IsReturnable { get; set; }
    public bool IsHighAlert { get; set; }
    public bool IsLasa { get; set; }
    public bool IsColdChain { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }          // sellable (not expired, within shelf life, not blocked), sale units
    public string? RackNo { get; set; }
    public DateTime? NearestExpiry { get; set; }
    public decimal? PackMrp { get; set; }       // of the first (FEFO) batch
}

public class PhPosBatch
{
    public int BatchId { get; set; }
    public int ItemId { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public decimal PackMrp { get; set; }
    public decimal UnitMrp { get; set; }
    public decimal LandedCost { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }
}

public class PhSaleLineIn
{
    public int ItemId { get; set; }
    public int? BatchId { get; set; }          // null = first expiry first (split over batches when needed)
    public decimal Qty { get; set; }           // sale units
    public decimal DiscPercent { get; set; }
}

public class PhPaymentIn
{
    public string Method { get; set; } = "";   // CASH | CARD | UPI | NEFT | CHEQUE
    public decimal Amount { get; set; }
    public string? Ref { get; set; }
}

public class PhSaleRequest
{
    public int? StoreId { get; set; }          // the selling store (counter) the stock leaves; null = the branch's default (SQLScripts/2364)
    public int? HoldId { get; set; }           // a held bill being finished
    public string CustomerKind { get; set; } = "WALKIN";   // WALKIN | PATIENT | CUSTOMER
    public int? PatientId { get; set; }
    public int? CustomerId { get; set; }
    public string? CustomerName { get; set; }
    public string? Mobile { get; set; }
    public string? Email { get; set; }
    public string? Address { get; set; }
    public int? DoctorId { get; set; }
    public string? DoctorName { get; set; }
    public string? DoctorRegNo { get; set; }
    public string? RxNo { get; set; }
    public DateTime? RxDate { get; set; }
    public decimal BillDiscPercent { get; set; }
    public string? Remarks { get; set; }
    public string? HoldLabel { get; set; }
    public List<PhSaleLineIn> Lines { get; set; } = [];
    public List<PhPaymentIn> Payments { get; set; } = [];
}

public class PhSaleResult
{
    public bool Success { get; set; }
    public string? Error { get; set; }
    public int SaleId { get; set; }
    public string? SaleNo { get; set; }
    public string? ReceiptNo { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Change { get; set; }
    public decimal BalanceDue { get; set; }
}

public class PhSaleLine
{
    public int SaleDtlId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string? HsnCode { get; set; }
    public int BatchId { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool IsReturnable { get; set; }
    public bool IsColdChain { get; set; }
    public decimal Qty { get; set; }
    public decimal UnitMrp { get; set; }
    public decimal UnitPrice { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal Amount { get; set; }
    public decimal GstPercent { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal UnitCost { get; set; }
    public decimal ReturnedQty { get; set; }
    public decimal Returnable => Qty - ReturnedQty;
}

public class PhSaleBill
{
    public int SaleId { get; set; }
    public int BranchId { get; set; }
    public string? SaleNo { get; set; }
    public DateTime SaleDate { get; set; }
    public string Status { get; set; } = "";
    public string CustomerKind { get; set; } = "";
    public int? PatientId { get; set; }
    public string? PatientCode { get; set; }
    public int? CustomerId { get; set; }
    public string? CustomerName { get; set; }
    public string? Mobile { get; set; }
    public string? Email { get; set; }
    public string? Address { get; set; }
    public int? DoctorId { get; set; }
    public string? DoctorName { get; set; }
    public string? DoctorRegNo { get; set; }
    public string? RxNo { get; set; }
    public DateTime? RxDate { get; set; }
    public decimal BillDiscPercent { get; set; }
    public decimal MrpAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal CgstAmount { get; set; }
    public decimal SgstAmount { get; set; }
    public decimal RoundOff { get; set; }
    public decimal NetAmount { get; set; }
    public decimal PaidAmount { get; set; }
    public decimal ReturnedAmount { get; set; }
    public decimal BalanceDue { get; set; }
    public string? HoldLabel { get; set; }
    public string? Remarks { get; set; }
    public string? CancelReason { get; set; }
    public string? CreatedByName { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public List<PhSaleLine> Lines { get; set; } = [];
    public List<PhSalePayment> Payments { get; set; } = [];
    public List<PhSaleReturnRow> Returns { get; set; } = [];
}

public class PhSalePayment
{
    public string? ReceiptNo { get; set; }
    public DateTime PaymentDate { get; set; }
    public string MethodName { get; set; } = "";
    public string? Ref { get; set; }
    public decimal Amount { get; set; }
}

public class PhSaleReturnRow
{
    public int ReturnId { get; set; }
    public string ReturnNo { get; set; } = "";
    public DateTime ReturnDate { get; set; }
    public string? SaleNo { get; set; }
    public string? CustomerName { get; set; }
    public string? ReasonName { get; set; }
    public string RefundMode { get; set; } = "";
    public decimal NetAmount { get; set; }
    public decimal AdjustedAmount { get; set; }
    public decimal RefundAmount { get; set; }
    public string? CreatedByName { get; set; }
}

public class PhSaleListRow
{
    public int SaleId { get; set; }
    public string? SaleNo { get; set; }
    public DateTime SaleDate { get; set; }
    public string Status { get; set; } = "";
    public string? CustomerName { get; set; }
    public string? Mobile { get; set; }
    public string? DoctorName { get; set; }
    public int Lines { get; set; }
    public decimal NetAmount { get; set; }
    public decimal PaidAmount { get; set; }
    public decimal ReturnedAmount { get; set; }
    public decimal BalanceDue { get; set; }
    public string? CreatedByName { get; set; }
    public string? HoldLabel { get; set; }
}

public class PhCreditCustomer
{
    public int CustomerId { get; set; }
    public string CustomerName { get; set; } = "";
    public string Mobile { get; set; } = "";
    public decimal CreditLimit { get; set; }
    public decimal Outstanding { get; set; }
    public int OpenBills { get; set; }
    public DateTime? OldestBill { get; set; }
}

public class PhPharmacySettings
{
    public bool PharmacyEnabled { get; set; }
    public DateTime? Licence20BValidTo { get; set; }
    public string? NdpsLicenceNo { get; set; }
    public int MinShelfLifeSaleDays { get; set; }
    public bool AllowNegativeStock { get; set; }
    public decimal MaxManualDiscountPercent { get; set; }
    public bool RoundOffBill { get; set; }
    public int SaleReturnDays { get; set; }
    public bool LooseReturnAllowed { get; set; }
    public string BillPrintFormat { get; set; } = "A4";
    public bool BillNotificationRequired { get; set; }
}

public interface IPharmacySaleService
{
    Task<PhPharmacySettings> SettingsAsync(int branchId);
    Task<List<PhPosItem>> ItemSearchAsync(int companyId, int branchId, string q, int? genericId, int? itemId = null, int? storeId = null);
    Task<List<PhPosBatch>> BatchesAsync(int companyId, int branchId, int itemId, int? storeId = null);
    Task<decimal> UnitPriceAsync(int companyId, int itemId, int batchId, string priceType);
    Task<List<PhOption>> PaymentMethodsAsync();
    Task<PhSaleResult> SaveAsync(int companyId, int branchId, PhSaleRequest r, int userId, bool canDiscount, bool canCredit);
    Task<PhSaleResult> HoldAsync(int companyId, int branchId, PhSaleRequest r, int userId);
    Task<string?> DiscardHoldAsync(int companyId, int branchId, int saleId);
    Task<List<PhSaleListRow>> ListAsync(int companyId, int branchId, string status, string? search, DateTime? from, DateTime? to);
    Task<PhSaleBill?> GetAsync(int companyId, int branchId, int saleId);
    Task<PhSaleBill?> FindForReturnAsync(int companyId, int branchId, string q);
    Task<(int Id, string? No, string? Error)> SaveReturnAsync(int companyId, int branchId, int saleId, Dictionary<int, decimal> qty, int reasonId, string refundMode, string? refundRef, string? remarks, int userId);
    Task<List<PhSaleReturnRow>> ReturnsAsync(int companyId, int branchId, DateTime from, DateTime to, string? search);
    Task<(PhSaleReturnRow? Head, PhSaleBill? Bill, List<PhSaleLine> Lines)> GetReturnAsync(int companyId, int branchId, int returnId);
    Task<string?> CancelAsync(int companyId, int branchId, int saleId, string reason, int userId);
    Task<List<PhCreditCustomer>> CreditCustomersAsync(int companyId, int branchId);
    Task<(string? ReceiptNo, string? Error)> CollectAsync(int companyId, int branchId, int customerId, string method, string? reference, Dictionary<int, decimal> alloc, int userId);
    Task<(List<PhSaleListRow> Bills, PhCreditCustomer? Customer)> OpenBillsAsync(int companyId, int branchId, int customerId);
    Task<(List<PhSalePayment> Rows, string? Customer, string? Mobile)> ReceiptAsync(int companyId, int branchId, string receiptNo);
    Task<List<dynamic>> ScheduleRegisterAsync(int companyId, int branchId, DateTime from, DateTime to, string? schedule);
    Task<List<System.Text.Json.JsonElement>> CustomersAsync(int companyId, string? q);
    Task<List<System.Text.Json.JsonElement>> PatientsAsync(int companyId, string q);
    Task<List<System.Text.Json.JsonElement>> DoctorsAsync(int companyId, string? q);
}

/// <summary>
/// Pharmacy > Sales through EMR.Api (api/pharmacy/sales, SQLScripts/2359). Checks that need no data (quantities, discount
/// range, mobile, payment modes and references) stay here; batch picking, prices, stock, money and the ledger run in the
/// stored procedures, each save in one transaction, with the same messages as before.
/// </summary>
public class PharmacySaleService(PharmacyApiClient api) : IPharmacySaleService
{
    private const string Base = "api/pharmacy/sales";
    private static decimal R2(decimal v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);
    private static readonly string[] Methods = ["CASH", "CARD", "UPI", "NEFT", "CHEQUE"];
    private static string Q(params (string, object?)[] a) => PharmacyApiClient.Q(a);
    // lines for OPENJSON: property names exactly as the procedure reads them (PascalCase)
    private static string Json(object o) => JsonSerializer.Serialize(o);
    private static T Row<T>(JsonElement e) => e.Deserialize<T>(PharmacyApiClient.Json)!;

    private sealed class SaveRow { public bool Success { get; set; } public string? Error { get; set; } public int Id { get; set; } public string? DocNo { get; set; } }

    public async Task<PhPharmacySettings> SettingsAsync(int branchId) =>
        (await api.GetAsync<List<PhPharmacySettings>>($"{Base}/settings/{branchId}")).FirstOrDefault()
        ?? new PhPharmacySettings { MinShelfLifeSaleDays = 30, MaxManualDiscountPercent = 10, RoundOffBill = true, SaleReturnDays = 7 };

    // ── look-ups ────────────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhPosItem>> ItemSearchAsync(int companyId, int branchId, string q, int? genericId, int? itemId = null, int? storeId = null) =>
        api.GetAsync<List<PhPosItem>>($"{Base}/item-search" + Q(("companyId", companyId), ("branchId", branchId),
            ("q", string.IsNullOrWhiteSpace(q) ? null : q.Trim()), ("genericId", genericId), ("itemId", itemId), ("storeId", storeId)));

    public Task<List<PhPosBatch>> BatchesAsync(int companyId, int branchId, int itemId, int? storeId = null) =>
        api.GetAsync<List<PhPosBatch>>($"{Base}/batches" + Q(("companyId", companyId), ("branchId", branchId), ("itemId", itemId), ("storeId", storeId)));

    public Task<List<PhOption>> PaymentMethodsAsync() => api.GetAsync<List<PhOption>>($"{Base}/payment-methods");

    /// <summary>Price per sale unit (GST inclusive) by the Price Rule master: never above the batch MRP.</summary>
    public async Task<decimal> UnitPriceAsync(int companyId, int itemId, int batchId, string priceType) =>
        (await api.GetAsync<PriceRow>($"{Base}/unit-price" + Q(("companyId", companyId), ("itemId", itemId), ("batchId", batchId), ("priceType", priceType)))).UnitPrice;

    private sealed record PriceRow(decimal UnitPrice);

    public Task<List<JsonElement>> CustomersAsync(int companyId, string? q) => api.GetAsync<List<JsonElement>>($"{Base}/customers" + Q(("companyId", companyId), ("q", q)));
    public Task<List<JsonElement>> PatientsAsync(int companyId, string q) => api.GetAsync<List<JsonElement>>($"{Base}/patients" + Q(("companyId", companyId), ("q", q)));
    public Task<List<JsonElement>> DoctorsAsync(int companyId, string? q) => api.GetAsync<List<JsonElement>>($"{Base}/doctors" + Q(("companyId", companyId), ("q", q)));

    // ── save a bill ─────────────────────────────────────────────────────────────────────────────────────
    public async Task<PhSaleResult> HoldAsync(int companyId, int branchId, PhSaleRequest r, int userId)
    {
        r.Payments = [];
        return await SaveCoreAsync(companyId, branchId, r, userId, hold: true, canDiscount: true, canCredit: true);
    }

    public Task<PhSaleResult> SaveAsync(int companyId, int branchId, PhSaleRequest r, int userId, bool canDiscount, bool canCredit) =>
        SaveCoreAsync(companyId, branchId, r, userId, hold: false, canDiscount, canCredit);

    private async Task<PhSaleResult> SaveCoreAsync(int companyId, int branchId, PhSaleRequest r, int userId, bool hold, bool canDiscount, bool canCredit)
    {
        PhSaleResult Fail(string e) => new() { Error = e };
        var lines = r.Lines.Where(l => l.ItemId > 0).ToList();
        if (lines.Count == 0) return Fail("Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return Fail("Every item needs a quantity above zero.");
        if (lines.Any(l => l.DiscPercent is < 0 or > 100) || r.BillDiscPercent is < 0 or > 100) return Fail("Discount % must be between 0 and 100.");
        r.CustomerKind = r.CustomerKind is "PATIENT" or "CUSTOMER" ? r.CustomerKind : "WALKIN";
        r.CustomerName = r.CustomerName?.Trim(); r.Mobile = r.Mobile?.Trim(); r.Address = r.Address?.Trim(); r.DoctorName = r.DoctorName?.Trim(); r.RxNo = r.RxNo?.Trim();
        if (!string.IsNullOrEmpty(r.Mobile) && !System.Text.RegularExpressions.Regex.IsMatch(r.Mobile, "^[6-9][0-9]{9}$")) return Fail("Mobile: 10 digits starting 6-9.");
        var pays = r.Payments.Where(x => x.Amount > 0).Select(x => new PhPaymentIn { Method = x.Method.ToUpperInvariant(), Amount = R2(x.Amount), Ref = x.Ref?.Trim() }).ToList();
        if (pays.Any(x => !Methods.Contains(x.Method))) return Fail("Pick the payment mode.");
        if (pays.Any(x => x.Method is "CARD" or "UPI" or "NEFT" or "CHEQUE" && string.IsNullOrWhiteSpace(x.Ref))) return Fail("Enter the card / UPI / transaction reference.");

        var res = await api.PostAsync<PhSaleResult>($"{Base}/save", new
        {
            companyId, branchId, userId, hold, canDiscount, canCredit, r.HoldId, r.CustomerKind, r.PatientId, r.CustomerId, r.CustomerName, r.Mobile, r.Email, r.Address,
            r.DoctorId, r.DoctorName, r.DoctorRegNo, r.RxNo, r.RxDate, r.BillDiscPercent, r.Remarks, r.HoldLabel,
            Lines = Json(lines.Select(l => new { l.ItemId, l.BatchId, l.Qty, l.DiscPercent })),
            Payments = Json(pays.Select(p => new { p.Method, p.Amount, p.Ref })),
            r.StoreId
        });
        return res;
    }

    public async Task<string?> DiscardHoldAsync(int companyId, int branchId, int saleId) =>
        (await api.PostAsync<SaveRow>($"{Base}/discard-hold", new { companyId, branchId, userId = 0, saleId, reason = (string?)null })).Error;

    // ── bills ───────────────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhSaleListRow>> ListAsync(int companyId, int branchId, string status, string? search, DateTime? from, DateTime? to) =>
        api.GetAsync<List<PhSaleListRow>>($"{Base}/list" + Q(("companyId", companyId), ("branchId", branchId), ("status", status),
            ("search", string.IsNullOrWhiteSpace(search) ? null : search.Trim()), ("from", from), ("to", to)));

    public async Task<PhSaleBill?> GetAsync(int companyId, int branchId, int saleId)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>($"{Base}/bill/{saleId}" + Q(("companyId", companyId), ("branchId", branchId)));
        if (sets[0].Count == 0) return null;
        var b = Row<PhSaleBill>(sets[0][0]);
        b.Lines = sets[1].Select(Row<PhSaleLine>).ToList();
        b.Payments = sets[2].Select(Row<PhSalePayment>).ToList();
        b.Returns = sets[3].Select(Row<PhSaleReturnRow>).ToList();
        return b;
    }

    // ── sale return ─────────────────────────────────────────────────────────────────────────────────────
    private sealed record IdRow(int SaleId);

    public async Task<PhSaleBill?> FindForReturnAsync(int companyId, int branchId, string q)
    {
        var id = (await api.GetAsync<List<IdRow>>($"{Base}/find-for-return" + Q(("companyId", companyId), ("branchId", branchId), ("q", q.Trim())))).FirstOrDefault();
        return id == null ? null : await GetAsync(companyId, branchId, id.SaleId);
    }

    public async Task<(int Id, string? No, string? Error)> SaveReturnAsync(int companyId, int branchId, int saleId, Dictionary<int, decimal> qty, int reasonId, string refundMode, string? refundRef, string? remarks, int userId)
    {
        qty = qty.Where(x => x.Value > 0).ToDictionary(x => x.Key, x => x.Value);
        if (qty.Count == 0) return (0, null, "Enter the quantity returned for at least one item.");
        if (reasonId <= 0) return (0, null, "Pick the reason for the return.");
        var r = await api.PostAsync<SaveRow>($"{Base}/return/save", new
        {
            companyId, branchId, userId, saleId, reasonId, refundMode, refundRef, remarks,
            Lines = Json(qty.Select(x => new { SaleDtlId = x.Key, Qty = x.Value }))
        });
        return r.Error != null ? (0, null, r.Error) : (r.Id, r.DocNo, null);
    }

    public Task<List<PhSaleReturnRow>> ReturnsAsync(int companyId, int branchId, DateTime from, DateTime to, string? search) =>
        api.GetAsync<List<PhSaleReturnRow>>($"{Base}/returns" + Q(("companyId", companyId), ("branchId", branchId), ("from", from), ("to", to),
            ("search", string.IsNullOrWhiteSpace(search) ? null : search.Trim())));

    public async Task<(PhSaleReturnRow? Head, PhSaleBill? Bill, List<PhSaleLine> Lines)> GetReturnAsync(int companyId, int branchId, int returnId)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>($"{Base}/return/{returnId}" + Q(("companyId", companyId), ("branchId", branchId)));
        if (sets[0].Count == 0) return (null, null, []);
        var head = Row<PhSaleReturnRow>(sets[0][0]);
        var saleId = sets[1].Count > 0 ? Row<IdRow>(sets[1][0]).SaleId : 0;
        return (head, await GetAsync(companyId, branchId, saleId), sets[2].Select(Row<PhSaleLine>).ToList());
    }

    // ── cancellation ────────────────────────────────────────────────────────────────────────────────────
    public async Task<string?> CancelAsync(int companyId, int branchId, int saleId, string reason, int userId)
    {
        if (string.IsNullOrWhiteSpace(reason)) return "Give the reason for cancelling.";
        return (await api.PostAsync<SaveRow>($"{Base}/cancel", new { companyId, branchId, userId, saleId, reason })).Error;
    }

    // ── credit collection ───────────────────────────────────────────────────────────────────────────────
    public Task<List<PhCreditCustomer>> CreditCustomersAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhCreditCustomer>>($"{Base}/credit-customers" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<(List<PhSaleListRow> Bills, PhCreditCustomer? Customer)> OpenBillsAsync(int companyId, int branchId, int customerId)
    {
        var bills = await api.GetAsync<List<PhSaleListRow>>($"{Base}/open-bills" + Q(("companyId", companyId), ("branchId", branchId), ("customerId", customerId)));
        var cust = (await CreditCustomersAsync(companyId, branchId)).FirstOrDefault(c => c.CustomerId == customerId);
        return (bills, cust);
    }

    public async Task<(string? ReceiptNo, string? Error)> CollectAsync(int companyId, int branchId, int customerId, string method, string? reference, Dictionary<int, decimal> alloc, int userId)
    {
        alloc = alloc.Where(a => a.Value > 0).ToDictionary(a => a.Key, a => R2(a.Value));
        method = method.ToUpperInvariant();
        if (alloc.Count == 0) return (null, "Enter the amount received against at least one bill.");
        if (!Methods.Contains(method)) return (null, "Pick the payment mode.");
        if (method != "CASH" && string.IsNullOrWhiteSpace(reference)) return (null, "Enter the card / UPI / transaction reference.");
        var r = await api.PostAsync<SaveRow>($"{Base}/collect", new
        {
            companyId, branchId, userId, customerId, method, reference = reference?.Trim(),
            Alloc = Json(alloc.Select(a => new { SaleId = a.Key, Amount = a.Value }))
        });
        return (r.DocNo, r.Error);
    }

    private sealed record WhoRow(string? Name, string? Mobile);

    public async Task<(List<PhSalePayment> Rows, string? Customer, string? Mobile)> ReceiptAsync(int companyId, int branchId, string receiptNo)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>($"{Base}/receipt" + Q(("companyId", companyId), ("branchId", branchId), ("receiptNo", receiptNo)));
        var who = sets[1].Count > 0 ? Row<WhoRow>(sets[1][0]) : new WhoRow(null, null);
        return (sets[0].Select(Row<PhSalePayment>).ToList(), who.Name, who.Mobile);
    }

    /// <summary>Rows for the register view, which reads them as dynamic.</summary>
    public async Task<List<dynamic>> ScheduleRegisterAsync(int companyId, int branchId, DateTime from, DateTime to, string? schedule)
    {
        var rows = await api.GetAsync<List<Dictionary<string, JsonElement>>>($"{Base}/schedule-register" +
            Q(("companyId", companyId), ("branchId", branchId), ("from", from), ("to", to), ("schedule", schedule)));
        return rows.Select(r =>
        {
            IDictionary<string, object?> x = new System.Dynamic.ExpandoObject();
            foreach (var (k, v) in r) x[k] = PharmacyApiClient.Plain(v);
            return (dynamic)x;
        }).ToList();
    }
}
