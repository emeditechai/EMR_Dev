using System.Data;
using Dapper;
using EMR.Web.Data;
using Microsoft.Data.SqlClient;

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
    Task<List<PhPosItem>> ItemSearchAsync(int companyId, int branchId, string q, int? genericId, int? itemId = null);
    Task<List<PhPosBatch>> BatchesAsync(int companyId, int branchId, int itemId);
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
}

public class PharmacySaleService(IDbConnectionFactory db) : IPharmacySaleService
{
    private static decimal R2(decimal v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);
    private static readonly string[] Methods = ["CASH", "CARD", "UPI", "NEFT", "CHEQUE"];

    private IDbConnection Open() { var c = db.CreateConnection(); c.Open(); return c; }

    public async Task<PhPharmacySettings> SettingsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PhPharmacySettings>(@"SELECT TOP 1 PharmacyEnabled, PharmacyDrugLicence20BValidTo Licence20BValidTo, PharmacyNdpsLicenceNo NdpsLicenceNo,
                PharmacyMinShelfLifeSaleDays MinShelfLifeSaleDays, PharmacyAllowNegativeStock AllowNegativeStock, PharmacyMaxManualDiscountPercent MaxManualDiscountPercent,
                PharmacyRoundOffBill RoundOffBill, PharmacySaleReturnDays SaleReturnDays, PharmacyLooseReturnAllowed LooseReturnAllowed, PharmacyBillPrintFormat BillPrintFormat,
                PharmacyBillNotificationRequired BillNotificationRequired
            FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC", new { branchId }) ?? new PhPharmacySettings { MinShelfLifeSaleDays = 30, MaxManualDiscountPercent = 10, RoundOffBill = true, SaleReturnDays = 7 };
    }

    // ── look-ups ────────────────────────────────────────────────────────────────────────────────────────
    private const string SellableBatches = @"
        FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
        WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))";

    public async Task<List<PhPosItem>> ItemSearchAsync(int companyId, int branchId, string q, int? genericId, int? itemId = null)
    {
        var shelf = (await SettingsAsync(branchId)).MinShelfLifeSaleDays;
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhPosItem>($@"
            SELECT TOP 25 i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, i.Strength, i.PackSize, i.GenericId, g.GenericName, m.ManufacturerName, i.CategoryId,
                   i.ScheduleCode, sc.RxRequired, sc.RegisterRequired, sc.IsNarcotic, sc.LabelWarning, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
                   i.AllowLooseSale, i.IsDiscountAllowed, i.IsReturnable, i.IsHighAlert, i.IsLasa, i.IsColdChain, h.GstPercent, ib.RackNo,
                   ISNULL(st.Qty, 0) Stock, st.NearestExpiry, st.PackMrp
            FROM dbo.PhItem i
            JOIN dbo.PhHsn h ON h.HsnId = i.HsnId JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
            JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
            LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
            LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
            LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
            OUTER APPLY (SELECT SUM(s.QtyOnHand) Qty, MIN(b.ExpiryDate) NearestExpiry,
                                (SELECT TOP 1 b2.Mrp FROM dbo.PhStock s2 JOIN dbo.PhBatch b2 ON b2.BatchId = s2.BatchId
                                 WHERE s2.BranchId = @branchId AND s2.ItemId = i.ItemId AND s2.QtyOnHand > 0 AND b2.IsBlocked = 0
                                   AND b2.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE)) ORDER BY b2.ExpiryDate, b2.BatchId) PackMrp
                         {SellableBatches} AND s.ItemId = i.ItemId) st
            WHERE i.CompanyId = @companyId AND i.IsActive = 1
              AND (@genericId IS NULL OR i.GenericId = @genericId) AND (@itemId IS NULL OR i.ItemId = @itemId)
              AND (@q IS NULL OR i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @q OR i.Barcode = @q)
            ORDER BY CASE WHEN i.Barcode = @q OR i.ItemCode = @q THEN 0 WHEN ISNULL(st.Qty, 0) > 0 THEN 1 ELSE 2 END,
                     CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName",
            new { companyId, branchId, shelf, genericId, itemId, q = string.IsNullOrWhiteSpace(q) ? null : q.Trim(), like = "%" + q?.Trim() + "%", starts = q?.Trim() + "%" })).ToList();
    }

    public async Task<List<PhPosBatch>> BatchesAsync(int companyId, int branchId, int itemId)
    {
        var shelf = (await SettingsAsync(branchId)).MinShelfLifeSaleDays;
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhPosBatch>($@"SELECT b.BatchId, b.ItemId, b.BatchNo, b.ExpiryDate, b.Mrp PackMrp, b.Mrp / i.ConversionQty UnitMrp, b.LandedCost, b.GstPercent, s.QtyOnHand Stock
            {SellableBatches} AND s.ItemId = @itemId
            AND EXISTS (SELECT 1 FROM dbo.PhItem i0 WHERE i0.ItemId = @itemId AND i0.CompanyId = @companyId)
            ORDER BY b.ExpiryDate, b.BatchId".Replace("FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId", "FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId"),
            new { companyId, branchId, itemId, shelf })).ToList();
    }

    public async Task<List<PhOption>> PaymentMethodsAsync()
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhOption>("SELECT UPPER(MethodCode) Value, MethodName Text FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND UPPER(MethodCode) IN @Methods ORDER BY PaymentMethodId", new { Methods })).ToList();
    }

    /// <summary>Price per sale unit (GST inclusive) by the Price Rule master: never above the batch MRP.</summary>
    public async Task<decimal> UnitPriceAsync(int companyId, int itemId, int batchId, string priceType)
    {
        using var con = db.CreateConnection();
        return await PriceAsync(con, null, companyId, itemId, batchId, priceType);
    }

    private static async Task<decimal> PriceAsync(IDbConnection con, IDbTransaction? tx, int companyId, int itemId, int batchId, string priceType)
    {
        var x = await con.QuerySingleAsync<(decimal UnitMrp, decimal Cost, decimal Gst, int CategoryId, int? ParentId)>(@"
            SELECT b.Mrp / i.ConversionQty, b.LandedCost, b.GstPercent, i.CategoryId, c.ParentCategoryId
            FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId WHERE b.BatchId = @batchId AND b.ItemId = @itemId",
            new { batchId, itemId }, tx);
        var rule = await con.QueryFirstOrDefaultAsync<(string Basis, decimal Pct)?>(@"
            SELECT TOP 1 PriceBasis, RatePercent FROM dbo.PhPriceRule
            WHERE CompanyId = @companyId AND IsActive = 1 AND PatientType = @priceType AND (CategoryId IS NULL OR CategoryId IN (@cat, @parent))
            ORDER BY CASE WHEN CategoryId = @cat THEN 0 WHEN CategoryId = @parent THEN 1 ELSE 2 END, Priority",
            new { companyId, priceType, cat = x.CategoryId, parent = x.ParentId ?? -1 }, tx);
        var price = rule?.Basis switch
        {
            "MRP_LESS" => x.UnitMrp * (1 - rule.Value.Pct / 100),
            "COST_PLUS" => x.Cost * (1 + rule.Value.Pct / 100) * (1 + x.Gst / 100),
            _ => x.UnitMrp
        };
        return Math.Round(Math.Min(price, x.UnitMrp), 4);
    }

    // ── save a bill ─────────────────────────────────────────────────────────────────────────────────────
    private sealed class Priced
    {
        public int ItemId; public int BatchId; public decimal Qty; public decimal UnitMrp; public decimal UnitPrice; public decimal Disc;
        public decimal Amount; public decimal Gst; public decimal Taxable; public decimal GstAmt; public decimal Cost; public string Schedule = "";
        public bool Register; public bool Narcotic; public string ItemName = "";
    }

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
        var set = await SettingsAsync(branchId);
        if (!set.PharmacyEnabled) return Fail("The pharmacy is not enabled for this branch (Hospital Settings > Pharmacy & Drug Licence).");
        if (!hold && set.Licence20BValidTo is { } lic && lic < DateTime.Today) return Fail($"The pharmacy's drug licence expired on {lic:dd-MMM-yyyy}; sales are stopped until it is renewed in Hospital Settings.");
        var lines = r.Lines.Where(l => l.ItemId > 0).ToList();
        if (lines.Count == 0) return Fail("Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return Fail("Every item needs a quantity above zero.");
        if (lines.Any(l => l.DiscPercent is < 0 or > 100) || r.BillDiscPercent is < 0 or > 100) return Fail("Discount % must be between 0 and 100.");
        r.CustomerKind = r.CustomerKind is "PATIENT" or "CUSTOMER" ? r.CustomerKind : "WALKIN";
        r.CustomerName = r.CustomerName?.Trim(); r.Mobile = r.Mobile?.Trim(); r.Address = r.Address?.Trim(); r.DoctorName = r.DoctorName?.Trim(); r.RxNo = r.RxNo?.Trim();
        if (!string.IsNullOrEmpty(r.Mobile) && !System.Text.RegularExpressions.Regex.IsMatch(r.Mobile, "^[6-9][0-9]{9}$")) return Fail("Mobile: 10 digits starting 6-9.");

        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            // customer
            string priceType = "WALKIN";
            PhCustomerRow? cust = null;
            if (r.CustomerKind == "PATIENT")
            {
                var p = await con.QuerySingleOrDefaultAsync<(string Name, string? Phone, string? Address, string? Email)?>(@"SELECT LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))), PhoneNumber, Address, EmailId
                    FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @companyId AND IsActive = 1", new { r.PatientId, companyId }, tx);
                if (p == null) { tx.Rollback(); return Fail("Pick the patient (UHID)."); }
                r.CustomerName ??= p.Value.Name; r.Mobile ??= p.Value.Phone; r.Address ??= p.Value.Address; r.Email ??= p.Value.Email;
                r.CustomerId = null;
            }
            else if (r.CustomerKind == "CUSTOMER")
            {
                cust = await con.QuerySingleOrDefaultAsync<PhCustomerRow>(@"SELECT CustomerId, CustomerName, Mobile, Email, Address, CustomerType, CreditAllowed, CreditLimit
                    FROM dbo.PhCustomer WHERE CustomerId = @CustomerId AND CompanyId = @companyId AND IsActive = 1", new { r.CustomerId, companyId }, tx);
                if (cust == null) { tx.Rollback(); return Fail("Pick the pharmacy customer."); }
                r.CustomerName = cust.CustomerName; r.Mobile = cust.Mobile; r.Email ??= cust.Email; r.Address ??= cust.Address; r.PatientId = null;
                if (cust.CustomerType == "STAFF") priceType = "STAFF";
            }
            else { r.PatientId = null; r.CustomerId = null; }

            // items and batches: first expiry first, split over batches; a chosen batch is used as it is
            var items = (await con.QueryAsync<(int ItemId, string ItemName, int Conv, bool Loose, bool DiscOk, string Schedule, bool Rx, bool Reg, bool Narc, bool Active)>(@"
                SELECT i.ItemId, i.ItemName, i.ConversionQty, i.AllowLooseSale, i.IsDiscountAllowed, i.ScheduleCode, sc.RxRequired, sc.RegisterRequired, sc.IsNarcotic, i.IsActive
                FROM dbo.PhItem i JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode WHERE i.CompanyId = @companyId AND i.ItemId IN @ids",
                new { companyId, ids = lines.Select(l => l.ItemId).Distinct() }, tx)).ToDictionary(i => i.ItemId);
            var priced = new List<Priced>();
            var minExpiry = DateTime.Today.AddDays(set.MinShelfLifeSaleDays);
            foreach (var l in lines)
            {
                if (!items.TryGetValue(l.ItemId, out var it) || !it.Active) { tx.Rollback(); return Fail("An item is not in the Item Master or is inactive."); }
                if (!it.Loose && l.Qty % it.Conv != 0) { tx.Rollback(); return Fail($"{it.ItemName} is sold in full packs of {it.Conv} only."); }
                if (it.Narc && string.IsNullOrWhiteSpace(set.NdpsLicenceNo)) { tx.Rollback(); return Fail($"{it.ItemName} is a Schedule X / NDPS drug: the branch has no NDPS licence in Hospital Settings."); }
                var batches = (await con.QueryAsync<(int BatchId, decimal Stock, DateTime Expiry, bool Blocked)>(@"
                    SELECT b.BatchId, s.QtyOnHand, b.ExpiryDate, b.IsBlocked FROM dbo.PhStock s WITH (UPDLOCK, HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.BranchId = @branchId AND s.ItemId = @ItemId AND (@BatchId IS NULL OR b.BatchId = @BatchId) ORDER BY b.ExpiryDate, b.BatchId",
                    new { branchId, l.ItemId, l.BatchId }, tx)).ToList();
                if (l.BatchId != null && batches.Count == 0) { tx.Rollback(); return Fail($"{it.ItemName}: the chosen batch has no stock here."); }
                var left = l.Qty;
                foreach (var b in batches)
                {
                    if (left <= 0) break;
                    if (b.Blocked || b.Expiry <= DateTime.Today) { if (l.BatchId != null) { tx.Rollback(); return Fail($"{it.ItemName}: the chosen batch is expired or blocked."); } continue; }
                    if (b.Expiry <= minExpiry) { if (l.BatchId != null) { tx.Rollback(); return Fail($"{it.ItemName}: the chosen batch expires within {set.MinShelfLifeSaleDays} days and cannot be sold."); } continue; }
                    var take = hold || l.BatchId != null ? left : Math.Min(left, Math.Max(0, b.Stock));
                    if (take <= 0) continue;
                    priced.Add(new Priced { ItemId = l.ItemId, BatchId = b.BatchId, Qty = take, Disc = l.DiscPercent, Schedule = it.Schedule, Register = it.Reg, Narcotic = it.Narc, ItemName = it.ItemName });
                    left -= take;
                }
                if (left > 0)
                {
                    if (!set.AllowNegativeStock && !hold) { tx.Rollback(); return Fail($"Not enough sellable stock of {it.ItemName}: short by {left:0.##}."); }
                    var last = priced.LastOrDefault(p => p.ItemId == l.ItemId);
                    if (last == null) { tx.Rollback(); return Fail($"{it.ItemName} has no sellable batch."); }
                    last.Qty += left;
                }
            }

            // prices and amounts (MRP inclusive of GST)
            foreach (var p in priced)
            {
                var b = await con.QuerySingleAsync<(decimal UnitMrp, decimal Cost, decimal Gst)>("SELECT b.Mrp / i.ConversionQty, b.LandedCost, b.GstPercent FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE b.BatchId = @BatchId", new { p.BatchId }, tx);
                p.UnitMrp = Math.Round(b.UnitMrp, 4); p.Cost = b.Cost; p.Gst = b.Gst;
                p.UnitPrice = await PriceAsync(con, tx, companyId, p.ItemId, p.BatchId, priceType);
                p.Disc = items[p.ItemId].DiscOk ? Math.Min(100, p.Disc + r.BillDiscPercent) : 0;
                p.Amount = R2(p.Qty * p.UnitPrice * (1 - p.Disc / 100));
                p.Taxable = R2(p.Amount * 100 / (100 + p.Gst));
                p.GstAmt = p.Amount - p.Taxable;
            }
            var manualDisc = priced.Count == 0 ? 0 : priced.Max(p => p.Disc);
            if (!hold && manualDisc > set.MaxManualDiscountPercent && !canDiscount)
            { tx.Rollback(); return Fail($"Discount {manualDisc:0.##}% is above the {set.MaxManualDiscountPercent:0.##}% allowed at the counter; a user with the Discount permission must bill it."); }

            // prescription and register
            if (!hold && priced.Any(p => items[p.ItemId].Rx) && (string.IsNullOrWhiteSpace(r.DoctorName) || string.IsNullOrWhiteSpace(r.RxNo)))
            { tx.Rollback(); return Fail("A prescription drug (Schedule H / H1 / X) is on the bill: enter the doctor and the prescription number."); }
            if (!hold && priced.Any(p => p.Register) && (string.IsNullOrWhiteSpace(r.CustomerName) || string.IsNullOrWhiteSpace(r.Address)))
            { tx.Rollback(); return Fail("A Schedule H1 / X drug is on the bill: the patient's name and address are needed for the register."); }

            var mrpAmt = R2(priced.Sum(p => p.Qty * p.UnitMrp));
            var lineTotal = priced.Sum(p => p.Amount);
            var net = set.RoundOffBill ? Math.Round(lineTotal, 0, MidpointRounding.AwayFromZero) : lineTotal;
            var taxable = priced.Sum(p => p.Taxable); var gst = priced.Sum(p => p.GstAmt);
            var cgst = R2(gst / 2); var sgst = gst - cgst;
            var cost = R2(priced.Sum(p => p.Qty * p.Cost));

            // payments: full payment, or the balance on credit for a credit customer
            var pays = r.Payments.Where(x => x.Amount > 0).Select(x => new PhPaymentIn { Method = x.Method.ToUpperInvariant(), Amount = R2(x.Amount), Ref = x.Ref?.Trim() }).ToList();
            if (pays.Any(x => !Methods.Contains(x.Method))) { tx.Rollback(); return Fail("Pick the payment mode."); }
            if (pays.Any(x => x.Method is "CARD" or "UPI" or "NEFT" or "CHEQUE" && string.IsNullOrWhiteSpace(x.Ref))) { tx.Rollback(); return Fail("Enter the card / UPI / transaction reference."); }
            var tendered = pays.Sum(x => x.Amount);
            var nonCash = pays.Where(x => x.Method != "CASH").Sum(x => x.Amount);
            if (nonCash > net) { tx.Rollback(); return Fail("Card / UPI / bank amount is more than the bill."); }
            var change = Math.Max(0, tendered - net);
            if (change > 0) { var cashPay = pays.First(x => x.Method == "CASH"); cashPay.Amount -= change; }   // change returned from the cash given
            var paid = pays.Sum(x => x.Amount);
            var due = hold ? 0 : net - paid;
            if (!hold && due > 0)
            {
                if (cust == null || !cust.CreditAllowed) { tx.Rollback(); return Fail($"₹{due:0.00} is not paid. Only a credit customer can take a bill on credit."); }
                if (!canCredit) { tx.Rollback(); return Fail("You do not have permission to bill on credit."); }
                var outstanding = await con.ExecuteScalarAsync<decimal>("SELECT ISNULL(SUM(BalanceDue), 0) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED'", new { cust.CustomerId }, tx);
                if (outstanding + due > cust.CreditLimit) { tx.Rollback(); return Fail($"Credit limit ₹{cust.CreditLimit:0.00} would be crossed (outstanding ₹{outstanding:0.00} + this bill ₹{due:0.00})."); }
            }

            // header
            string? saleNo = null;
            if (!hold) saleNo = await NextNoAsync(con, tx, branchId, "SALE");
            var head = new
            {
                companyId, branchId, saleNo, Status = hold ? "HOLD" : "POSTED", r.CustomerKind, r.PatientId, r.CustomerId, r.CustomerName, r.Mobile, r.Email, r.Address,
                r.DoctorId, r.DoctorName, r.DoctorRegNo, r.RxNo, r.RxDate, priceType, r.BillDiscPercent, mrpAmt, disc = mrpAmt - lineTotal, taxable, cgst, sgst,
                round = net - lineTotal, net, paid, due, cost, r.HoldLabel, r.Remarks, userId, Id = r.HoldId ?? 0
            };
            int saleId;
            if (r.HoldId is int hid && hid > 0)
            {
                var n = await con.ExecuteAsync(@"UPDATE dbo.PhSale SET SaleNo = @saleNo, SaleDate = GETDATE(), Status = @Status, CustomerKind = @CustomerKind, PatientId = @PatientId, CustomerId = @CustomerId,
                        CustomerName = @CustomerName, Mobile = @Mobile, Email = @Email, Address = @Address, DoctorId = @DoctorId, DoctorName = @DoctorName, DoctorRegNo = @DoctorRegNo,
                        RxNo = @RxNo, RxDate = @RxDate, PriceType = @priceType, BillDiscPercent = @BillDiscPercent, MrpAmount = @mrpAmt, DiscountAmount = @disc, TaxableAmount = @taxable,
                        CgstAmount = @cgst, SgstAmount = @sgst, RoundOff = @round, NetAmount = @net, PaidAmount = @paid, BalanceDue = @due, CostAmount = @cost, HoldLabel = @HoldLabel,
                        Remarks = @Remarks, ModifiedBy = @userId, ModifiedDate = GETDATE()
                    WHERE SaleId = @Id AND CompanyId = @companyId AND BranchId = @branchId AND Status = 'HOLD'", head, tx);
                if (n == 0) { tx.Rollback(); return Fail("The held bill was already finished or discarded."); }
                await con.ExecuteAsync("DELETE dbo.PhSaleDtl WHERE SaleId = @hid", new { hid }, tx);
                saleId = hid;
            }
            else
                saleId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhSale (CompanyId, BranchId, SaleNo, Status, CustomerKind, PatientId, CustomerId, CustomerName, Mobile, Email, Address,
                        DoctorId, DoctorName, DoctorRegNo, RxNo, RxDate, PriceType, BillDiscPercent, MrpAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, RoundOff,
                        NetAmount, PaidAmount, BalanceDue, CostAmount, HoldLabel, Remarks, CreatedBy)
                    VALUES (@companyId, @branchId, @saleNo, @Status, @CustomerKind, @PatientId, @CustomerId, @CustomerName, @Mobile, @Email, @Address,
                        @DoctorId, @DoctorName, @DoctorRegNo, @RxNo, @RxDate, @priceType, @BillDiscPercent, @mrpAmt, @disc, @taxable, @cgst, @sgst, @round,
                        @net, @paid, @due, @cost, @HoldLabel, @Remarks, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", head, tx);

            foreach (var p in priced)
            {
                var dtl = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhSaleDtl (SaleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, DiscPercent, Amount, GstPercent, TaxableAmount, GstAmount, UnitCost)
                    VALUES (@saleId, @ItemId, @BatchId, @Qty, @UnitMrp, @UnitPrice, @Disc, @Amount, @Gst, @Taxable, @GstAmt, @Cost); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                    new { saleId, p.ItemId, p.BatchId, p.Qty, p.UnitMrp, p.UnitPrice, p.Disc, p.Amount, p.Gst, p.Taxable, p.GstAmt, p.Cost }, tx);
                if (hold) continue;
                await con.ExecuteAsync("dbo.usp_PhStock_Move", new { BranchId = branchId, p.BatchId, Qty = -p.Qty, DocType = "SALE", DocId = saleId, DocNo = saleNo, UserId = userId, AllowNegative = set.AllowNegativeStock },
                    tx, commandType: CommandType.StoredProcedure);
                if (p.Register)
                    await con.ExecuteAsync(@"INSERT dbo.PhScheduleRegister (CompanyId, BranchId, SaleId, SaleDtlId, EntryDate, ScheduleCode, ItemId, BatchId, Qty, PatientName, PatientAddress, PrescriberName, PrescriberRegNo, RxNo, DispensedBy)
                        VALUES (@companyId, @branchId, @saleId, @dtl, GETDATE(), @Schedule, @ItemId, @BatchId, @Qty, @CustomerName, @Address, @DoctorName, @DoctorRegNo, @RxNo, @userId)",
                        new { companyId, branchId, saleId, dtl, p.Schedule, p.ItemId, p.BatchId, p.Qty, r.CustomerName, r.Address, r.DoctorName, r.DoctorRegNo, r.RxNo, userId }, tx);
            }
            if (hold) { tx.Commit(); return new PhSaleResult { Success = true, SaleId = saleId, NetAmount = net }; }

            // money: like OPD / LAB (PaymentHeader / PaymentDetail, module PHR)
            var patientId = r.PatientId ?? await WalkinPatientAsync(con, tx, companyId, branchId);
            var headerId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue,
                    HeaderDiscountAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
                VALUES ('PHR', @saleId, @branchId, @patientId, @mrpAmt, @disc, 'P', 0, 0, @net, @paid, @due, @status, @note, GETDATE(), @userId, 1, @cgst, @sgst, 0, @companyId, @round);
                SELECT CAST(SCOPE_IDENTITY() AS INT);",
                new { saleId, branchId, patientId, mrpAmt, disc = mrpAmt - lineTotal, net, paid, due, status = due > 0 ? "U" : "P", note = "Pharmacy bill " + saleNo, userId, cgst, sgst, companyId, round = net - lineTotal }, tx);
            string? receiptNo = null;
            if (paid > 0)
            {
                receiptNo = await ReceiptNoAsync(con, tx, branchId);
                foreach (var pay in pays.Where(x => x.Amount > 0))
                {
                    var pdId = await InsertPaymentAsync(con, tx, headerId, pay, receiptNo, userId, companyId, "Pharmacy bill " + saleNo);
                    await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SRCPT", RefId = pdId, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
                }
            }
            await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SALE", RefId = saleId, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            tx.Commit();
            return new PhSaleResult { Success = true, SaleId = saleId, SaleNo = saleNo, ReceiptNo = receiptNo, NetAmount = net, Change = change, BalanceDue = due };
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000)
        {
            tx.Rollback();
            return Fail(ex.Message);
        }
    }

    private sealed class PhCustomerRow
    {
        public int CustomerId { get; set; }
        public string CustomerName { get; set; } = "";
        public string Mobile { get; set; } = "";
        public string? Email { get; set; }
        public string? Address { get; set; }
        public string CustomerType { get; set; } = "";
        public bool CreditAllowed { get; set; }
        public decimal CreditLimit { get; set; }
    }

    private static async Task<int> WalkinPatientAsync(IDbConnection con, IDbTransaction tx, int companyId, int branchId)
    {
        var p = new DynamicParameters(new { CompanyId = companyId, BranchId = branchId });
        p.Add("PatientId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Ph_WalkinPatient", p, tx, commandType: CommandType.StoredProcedure);
        return p.Get<int>("PatientId");
    }

    private static async Task<string> ReceiptNoAsync(IDbConnection con, IDbTransaction tx, int branchId)
    {
        var p = new DynamicParameters(new { BranchId = branchId });
        p.Add("ReceiptNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Receipt_GetNextNo", p, tx, commandType: CommandType.StoredProcedure);
        return p.Get<string>("ReceiptNo");
    }

    private static async Task<string> NextNoAsync(IDbConnection con, IDbTransaction tx, int branchId, string docType)
    {
        var p = new DynamicParameters(new { BranchId = branchId, DocType = docType, DocDate = DateTime.Today });
        p.Add("DocNo", dbType: DbType.String, size: 40, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Ph_NextNumber", p, tx, commandType: CommandType.StoredProcedure);
        return p.Get<string>("DocNo");
    }

    private static async Task<int> InsertPaymentAsync(IDbConnection con, IDbTransaction tx, int headerId, PhPaymentIn pay, string receiptNo, int userId, int companyId, string note) =>
        await con.ExecuteScalarAsync<int>(@"INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
            SELECT @headerId, PaymentMethodId, @Amount, @Ref, CASE WHEN @Method = 'UPI' THEN @Ref END, CASE WHEN @Method = 'CARD' THEN RIGHT(@Ref, 4) END, CASE WHEN @Method = 'CHEQUE' THEN @Ref END,
                   GETDATE(), @note, GETDATE(), @userId, 1, @receiptNo, @companyId
            FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @Method;
            SELECT CAST(SCOPE_IDENTITY() AS INT);", new { headerId, pay.Amount, pay.Ref, pay.Method, receiptNo, userId, companyId, note }, tx);

    public async Task<string?> DiscardHoldAsync(int companyId, int branchId, int saleId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        var n = await con.ExecuteAsync("DELETE d FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId WHERE s.SaleId = @saleId AND s.Status = 'HOLD' AND s.CompanyId = @companyId AND s.BranchId = @branchId; " +
                                       "DELETE dbo.PhSale WHERE SaleId = @saleId AND Status = 'HOLD' AND CompanyId = @companyId AND BranchId = @branchId;", new { saleId, companyId, branchId }, tx);
        tx.Commit();
        return n == 0 ? "Held bill not found." : null;
    }

    // ── bills ───────────────────────────────────────────────────────────────────────────────────────────
    private const string UserName = "(SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = {0})";

    public async Task<List<PhSaleListRow>> ListAsync(int companyId, int branchId, string status, string? search, DateTime? from, DateTime? to)
    {
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhSaleListRow>($@"SELECT TOP 500 s.SaleId, s.SaleNo, s.SaleDate, s.Status, s.CustomerName, s.Mobile, s.DoctorName,
                (SELECT COUNT(*) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId) Lines, s.NetAmount, s.PaidAmount, s.ReturnedAmount, s.BalanceDue,
                {string.Format(UserName, "s.CreatedBy")} CreatedByName, s.HoldLabel
            FROM dbo.PhSale s
            WHERE s.CompanyId = @companyId AND s.BranchId = @branchId
              AND (@status = 'ALL' OR s.Status = @status OR (@status = 'DUE' AND s.Status = 'POSTED' AND s.BalanceDue > 0))
              AND (@from IS NULL OR s.SaleDate >= @from) AND (@to IS NULL OR s.SaleDate < DATEADD(DAY, 1, @to))
              AND (@search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.Mobile LIKE @like OR s.DoctorName LIKE @like)
            ORDER BY s.SaleDate DESC", new { companyId, branchId, status, from, to, search, like = "%" + search + "%" })).ToList();
    }

    public async Task<PhSaleBill?> GetAsync(int companyId, int branchId, int saleId)
    {
        using var con = db.CreateConnection();
        var b = await con.QuerySingleOrDefaultAsync<PhSaleBill>($@"SELECT s.*, pm.PatientCode, {string.Format(UserName, "s.CreatedBy")} CreatedByName
            FROM dbo.PhSale s LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId WHERE s.SaleId = @saleId AND s.CompanyId = @companyId AND s.BranchId = @branchId", new { saleId, companyId, branchId });
        if (b == null) return null;
        b.Lines = (await con.QueryAsync<PhSaleLine>(@"SELECT d.SaleDtlId, d.ItemId, i.ItemName, df.ShortName FormShort, i.ScheduleCode, h.HsnCode, d.BatchId, bt.BatchNo, bt.ExpiryDate, su.UomCode SaleUom,
                i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.UnitMrp, d.UnitPrice, d.DiscPercent, d.Amount, d.GstPercent, d.TaxableAmount, d.GstAmount, d.UnitCost, d.ReturnedQty
            FROM dbo.PhSaleDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch bt ON bt.BatchId = d.BatchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
            JOIN dbo.PhHsn h ON h.HsnId = i.HsnId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
            WHERE d.SaleId = @saleId ORDER BY d.SaleDtlId", new { saleId })).ToList();
        b.Payments = (await con.QueryAsync<PhSalePayment>(@"SELECT pd.ReceiptNo, COALESCE(pd.PaymentDate, pd.CreatedDate) PaymentDate, pm.MethodName, COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) Ref, pd.PaidAmount Amount
            FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @saleId AND pd.IsActive = 1 ORDER BY pd.PaymentDetailId", new { saleId })).ToList();
        b.Returns = (await con.QueryAsync<PhSaleReturnRow>($@"SELECT r.ReturnId, r.ReturnNo, r.ReturnDate, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount, {string.Format(UserName, "r.CreatedBy")} CreatedByName
            FROM dbo.PhSaleReturn r LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId WHERE r.SaleId = @saleId ORDER BY r.ReturnId", new { saleId })).ToList();
        return b;
    }

    // ── sale return ─────────────────────────────────────────────────────────────────────────────────────
    public async Task<PhSaleBill?> FindForReturnAsync(int companyId, int branchId, string q)
    {
        using var con = db.CreateConnection();
        var id = await con.ExecuteScalarAsync<int?>(@"SELECT TOP 1 SaleId FROM dbo.PhSale WHERE CompanyId = @companyId AND BranchId = @branchId AND Status = 'POSTED'
            AND (SaleNo = @q OR SaleNo LIKE '%/' + @q) ORDER BY SaleDate DESC", new { companyId, branchId, q = q.Trim() });
        return id == null ? null : await GetAsync(companyId, branchId, id.Value);
    }

    public async Task<(int Id, string? No, string? Error)> SaveReturnAsync(int companyId, int branchId, int saleId, Dictionary<int, decimal> qty, int reasonId, string refundMode, string? refundRef, string? remarks, int userId)
    {
        qty = qty.Where(x => x.Value > 0).ToDictionary(x => x.Key, x => x.Value);
        if (qty.Count == 0) return (0, null, "Enter the quantity returned for at least one item.");
        if (reasonId <= 0) return (0, null, "Pick the reason for the return.");
        var set = await SettingsAsync(branchId);
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var bill = await con.QuerySingleOrDefaultAsync<(int SaleId, DateTime SaleDate, string Status, decimal BalanceDue, int? CustomerId, string? SaleNo)>(
                "SELECT SaleId, SaleDate, Status, BalanceDue, CustomerId, SaleNo FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @saleId AND CompanyId = @companyId AND BranchId = @branchId", new { saleId, companyId, branchId }, tx);
            if (bill.Status != "POSTED") { tx.Rollback(); return (0, null, "Only a saved, not cancelled, bill can take a return."); }
            if (bill.SaleDate.Date.AddDays(set.SaleReturnDays) < DateTime.Today) { tx.Rollback(); return (0, null, $"Returns are taken within {set.SaleReturnDays} days of the bill; this bill is of {bill.SaleDate:dd-MMM-yyyy}."); }
            var lines = (await con.QueryAsync<PhSaleLine>(@"SELECT d.SaleDtlId, d.ItemId, i.ItemName, i.ScheduleCode, d.BatchId, b.ExpiryDate, i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.Amount, d.TaxableAmount, d.GstAmount, d.UnitCost, d.ReturnedQty
                FROM dbo.PhSaleDtl d WITH (UPDLOCK) JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId WHERE d.SaleId = @saleId AND d.SaleDtlId IN @ids",
                new { saleId, ids = qty.Keys }, tx)).ToDictionary(l => l.SaleDtlId);
            decimal taxable = 0, gst = 0, amount = 0, cost = 0;
            var rows = new List<(PhSaleLine L, decimal Q, decimal Amt, decimal Tax, decimal Gst)>();
            foreach (var (dtlId, q) in qty)
            {
                if (!lines.TryGetValue(dtlId, out var l)) { tx.Rollback(); return (0, null, "An item is not on this bill."); }
                if (!l.IsReturnable || l.ScheduleCode is "X" or "NDPS") { tx.Rollback(); return (0, null, $"{l.ItemName} is not returnable."); }
                if (l.IsColdChain) { tx.Rollback(); return (0, null, $"{l.ItemName} is a cold-chain item and cannot be taken back."); }
                if (l.ExpiryDate <= DateTime.Today) { tx.Rollback(); return (0, null, $"{l.ItemName}: the batch has expired."); }
                if (q > l.Qty - l.ReturnedQty) { tx.Rollback(); return (0, null, $"{l.ItemName}: only {l.Qty - l.ReturnedQty:0.##} can still be returned."); }
                if (!set.LooseReturnAllowed && q % l.ConversionQty != 0) { tx.Rollback(); return (0, null, $"{l.ItemName}: loose / cut strips are not taken back (full packs of {l.ConversionQty})."); }
                var amt = R2(l.Amount * q / l.Qty); var tax = R2(l.TaxableAmount * q / l.Qty); var g = amt - tax;
                rows.Add((l, q, amt, tax, g)); amount += amt; taxable += tax; gst += g; cost += R2(l.UnitCost * q);
            }
            var net = set.RoundOffBill ? Math.Round(amount, 0, MidpointRounding.AwayFromZero) : amount;
            var adjusted = Math.Min(net, bill.BalanceDue);
            var refund = net - adjusted;
            refundMode = refundMode.ToUpperInvariant();
            if (refund > 0 && !Methods.Contains(refundMode)) { tx.Rollback(); return (0, null, "Pick how the money is paid back."); }
            if (refund == 0) refundMode = "ADJUST";

            var no = await NextNoAsync(con, tx, branchId, "SRET");
            int? refundId = null;
            if (refund > 0)
            {
                // money paid back is recorded like an OPD / LAB partial cancellation: BillCancellation (P) + BillRefund
                var cnId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
                    VALUES ('PHR', @saleId, @cn, 'P', GETDATE(), @net, 0, @reason, 'C', @userId, GETDATE(), 1); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                    new { saleId, cn = "CN-PHR/" + no, net, reason = "Sale return " + no + (string.IsNullOrWhiteSpace(remarks) ? "" : ": " + remarks), userId }, tx);
                refundId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
                    VALUES (@cnId, 'PHR', @saleId, @refund, @refundMode, GETDATE(), @refundRef, @note, 'P', @userId, GETDATE(), 1); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                    new { cnId, saleId, refund, refundMode, refundRef, note = "Pharmacy sale return " + no, userId }, tx);
            }
            var rid = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhSaleReturn (CompanyId, BranchId, ReturnNo, SaleId, ReasonId, RefundMode, RefundRef, TaxableAmount, GstAmount, RoundOff, NetAmount, AdjustedAmount, RefundAmount, CostAmount, RefundId, Remarks, CreatedBy)
                VALUES (@companyId, @branchId, @no, @saleId, @reasonId, @refundMode, @refundRef, @taxable, @gst, @round, @net, @adjusted, @refund, @cost, @refundId, @remarks, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                new { companyId, branchId, no, saleId, reasonId, refundMode, refundRef, taxable, gst, round = net - amount, net, adjusted, refund, cost, refundId, remarks, userId }, tx);
            foreach (var (l, q, amt, tax, g) in rows)
            {
                await con.ExecuteAsync(@"INSERT dbo.PhSaleReturnDtl (ReturnId, SaleDtlId, ItemId, BatchId, Qty, Amount, TaxableAmount, GstAmount, UnitCost) VALUES (@rid, @SaleDtlId, @ItemId, @BatchId, @q, @amt, @tax, @g, @UnitCost);
                    UPDATE dbo.PhSaleDtl SET ReturnedQty = ReturnedQty + @q WHERE SaleDtlId = @SaleDtlId;", new { rid, l.SaleDtlId, l.ItemId, l.BatchId, q, amt, tax, g, l.UnitCost }, tx);
                await con.ExecuteAsync("dbo.usp_PhStock_Move", new { BranchId = branchId, l.BatchId, Qty = q, DocType = "SRET", DocId = rid, DocNo = no, UserId = userId, AllowNegative = true }, tx, commandType: CommandType.StoredProcedure);
            }
            await con.ExecuteAsync(@"UPDATE dbo.PhSale SET ReturnedAmount = ReturnedAmount + @net, BalanceDue = BalanceDue - @adjusted, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE SaleId = @saleId;
                UPDATE dbo.PaymentHeader SET BalanceDue = (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @saleId), PaymentStatus = CASE WHEN (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @saleId) > 0 THEN 'U' ELSE 'P' END,
                       LastModifiedDate = GETDATE(), LastModifiedBy = @userId WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @saleId;", new { saleId, net, adjusted, userId }, tx);
            await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SRET", RefId = rid, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            if (refundId != null) await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SREFUND", RefId = refundId, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            tx.Commit();
            return (rid, no, null);
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return (0, null, ex.Message); }
    }

    public async Task<List<PhSaleReturnRow>> ReturnsAsync(int companyId, int branchId, DateTime from, DateTime to, string? search)
    {
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhSaleReturnRow>($@"SELECT TOP 500 r.ReturnId, r.ReturnNo, r.ReturnDate, s.SaleNo, s.CustomerName, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount,
                {string.Format(UserName, "r.CreatedBy")} CreatedByName
            FROM dbo.PhSaleReturn r JOIN dbo.PhSale s ON s.SaleId = r.SaleId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
            WHERE r.CompanyId = @companyId AND r.BranchId = @branchId AND r.ReturnDate >= @from AND r.ReturnDate < DATEADD(DAY, 1, @to)
              AND (@search IS NULL OR r.ReturnNo LIKE @like OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.Mobile LIKE @like)
            ORDER BY r.ReturnDate DESC", new { companyId, branchId, from, to, search, like = "%" + search + "%" })).ToList();
    }

    public async Task<(PhSaleReturnRow? Head, PhSaleBill? Bill, List<PhSaleLine> Lines)> GetReturnAsync(int companyId, int branchId, int returnId)
    {
        using var con = db.CreateConnection();
        var row = await con.QuerySingleOrDefaultAsync<PhSaleReturnRow>($@"SELECT r.ReturnId, r.ReturnNo, r.ReturnDate, s.SaleNo, s.CustomerName, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount,
                {string.Format(UserName, "r.CreatedBy")} CreatedByName
            FROM dbo.PhSaleReturn r JOIN dbo.PhSale s ON s.SaleId = r.SaleId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
            WHERE r.ReturnId = @returnId AND r.CompanyId = @companyId AND r.BranchId = @branchId", new { returnId, companyId, branchId });
        var saleId = await con.ExecuteScalarAsync<int>("SELECT SaleId FROM dbo.PhSaleReturn WHERE ReturnId = @returnId", new { returnId });
        var h = (Row: row, SaleId: saleId);
        if (h.Row == null) return (null, null, []);
        var lines = (await con.QueryAsync<PhSaleLine>(@"SELECT d.SaleDtlId, d.ItemId, i.ItemName, df.ShortName FormShort, b.BatchNo, b.ExpiryDate, su.UomCode SaleUom, d.Qty, d.Amount, d.TaxableAmount, d.GstAmount, sd.GstPercent
            FROM dbo.PhSaleReturnDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
            JOIN dbo.PhSaleDtl sd ON sd.SaleDtlId = d.SaleDtlId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId WHERE d.ReturnId = @returnId", new { returnId })).ToList();
        return (h.Row, await GetAsync(companyId, branchId, h.SaleId), lines);
    }

    // ── cancellation ────────────────────────────────────────────────────────────────────────────────────
    public async Task<string?> CancelAsync(int companyId, int branchId, int saleId, string reason, int userId)
    {
        if (string.IsNullOrWhiteSpace(reason)) return "Give the reason for cancelling.";
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var s = await con.QuerySingleOrDefaultAsync<(string Status, DateTime SaleDate, int CreatedBy, decimal ReturnedAmount, string SaleNo, decimal NetAmount)>(
                "SELECT Status, SaleDate, CreatedBy, ReturnedAmount, SaleNo, NetAmount FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @saleId AND CompanyId = @companyId AND BranchId = @branchId", new { saleId, companyId, branchId }, tx);
            if (s.Status != "POSTED") { tx.Rollback(); return "Only a saved bill can be cancelled."; }
            if (s.SaleDate.Date != DateTime.Today) { tx.Rollback(); return "A bill can be cancelled only on the day it was made; take a sale return instead."; }
            if (s.ReturnedAmount > 0) { tx.Rollback(); return "Medicines of this bill were already returned; take a sale return for the rest."; }
            if (await con.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM dbo.CashClosing WHERE BranchId = @branchId AND UserId = @CreatedBy AND Module = 'PHR' AND BusinessDate = CAST(@SaleDate AS DATE) AND CutoffAt >= @SaleDate",
                    new { branchId, s.CreatedBy, s.SaleDate }, tx) > 0)
            { tx.Rollback(); return "The cashier has already closed the day for this bill; it cannot be cancelled. Take a sale return instead."; }

            var lines = await con.QueryAsync<(int BatchId, decimal Qty)>("SELECT BatchId, Qty FROM dbo.PhSaleDtl WHERE SaleId = @saleId", new { saleId }, tx);
            foreach (var l in lines)
                await con.ExecuteAsync("dbo.usp_PhStock_Move", new { BranchId = branchId, l.BatchId, l.Qty, DocType = "SCAN", DocId = saleId, DocNo = s.SaleNo, UserId = userId, AllowNegative = true }, tx, commandType: CommandType.StoredProcedure);
            var cnId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
                VALUES ('PHR', @saleId, @no, 'F', GETDATE(), @NetAmount, 0, @reason, 'C', @userId, GETDATE(), 1); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                new { saleId, no = "CN-PHR/" + s.SaleNo, s.NetAmount, reason, userId }, tx);
            // the money taken goes back the way it came (counted as refunds in the cashier's day closing)
            var paidByMode = await con.QueryAsync<(string Mode, decimal Amount)>(@"SELECT UPPER(pm.MethodCode), SUM(pd.PaidAmount) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @saleId AND pd.IsActive = 1 GROUP BY pm.MethodCode", new { saleId }, tx);
            foreach (var p in paidByMode.Where(p => p.Amount > 0))
                await con.ExecuteAsync(@"INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, Notes, Status, CreatedBy, CreatedDate, IsActive)
                    VALUES (@cnId, 'PHR', @saleId, @Amount, @Mode, GETDATE(), @note, 'P', @userId, GETDATE(), 1)", new { cnId, saleId, p.Amount, p.Mode, note = "Pharmacy bill cancelled " + s.SaleNo, userId }, tx);
            await con.ExecuteAsync(@"UPDATE dbo.PhSale SET Status = 'CANCELLED', BalanceDue = 0, CancelReason = @reason, CancelledBy = @userId, CancelledDate = GETDATE() WHERE SaleId = @saleId;
                UPDATE dbo.PhScheduleRegister SET IsCancelled = 1 WHERE SaleId = @saleId;
                UPDATE dbo.PaymentHeader SET BalanceDue = 0, LastModifiedDate = GETDATE(), LastModifiedBy = @userId WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @saleId;", new { saleId, reason, userId }, tx);
            await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SCANCEL", RefId = saleId, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return ex.Message; }
    }

    // ── credit collection ───────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhCreditCustomer>> CreditCustomersAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhCreditCustomer>(@"SELECT c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit, SUM(s.BalanceDue) Outstanding, COUNT(*) OpenBills, MIN(s.SaleDate) OldestBill
            FROM dbo.PhSale s JOIN dbo.PhCustomer c ON c.CustomerId = s.CustomerId
            WHERE s.CompanyId = @companyId AND s.BranchId = @branchId AND s.Status = 'POSTED' AND s.BalanceDue > 0
            GROUP BY c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit ORDER BY c.CustomerName", new { companyId, branchId })).ToList();
    }

    public async Task<(List<PhSaleListRow> Bills, PhCreditCustomer? Customer)> OpenBillsAsync(int companyId, int branchId, int customerId)
    {
        using var con = db.CreateConnection();
        var bills = (await con.QueryAsync<PhSaleListRow>(@"SELECT SaleId, SaleNo, SaleDate, Status, CustomerName, Mobile, NetAmount, PaidAmount, ReturnedAmount, BalanceDue
            FROM dbo.PhSale WHERE CompanyId = @companyId AND BranchId = @branchId AND CustomerId = @customerId AND Status = 'POSTED' AND BalanceDue > 0 ORDER BY SaleDate", new { companyId, branchId, customerId })).ToList();
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
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var bills = (await con.QueryAsync<(int SaleId, decimal Due, string SaleNo)>(@"SELECT SaleId, BalanceDue, SaleNo FROM dbo.PhSale WITH (UPDLOCK)
                WHERE CompanyId = @companyId AND BranchId = @branchId AND CustomerId = @customerId AND Status = 'POSTED' AND SaleId IN @ids", new { companyId, branchId, customerId, ids = alloc.Keys }, tx)).ToDictionary(b => b.SaleId);
            foreach (var a in alloc)
                if (!bills.TryGetValue(a.Key, out var b) || a.Value > b.Due) { tx.Rollback(); return (null, "An amount is more than the bill's balance."); }
            var receiptNo = await ReceiptNoAsync(con, tx, branchId);
            foreach (var a in alloc)
            {
                var headerId = await con.ExecuteScalarAsync<int>("SELECT PaymentHeaderId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @k AND IsActive = 1", new { k = a.Key }, tx);
                var pd = await InsertPaymentAsync(con, tx, headerId, new PhPaymentIn { Method = method, Amount = a.Value, Ref = reference?.Trim() }, receiptNo, userId, companyId, "Pharmacy credit collection " + bills[a.Key].SaleNo);
                await con.ExecuteAsync(@"UPDATE dbo.PhSale SET PaidAmount = PaidAmount + @v, BalanceDue = BalanceDue - @v, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE SaleId = @k;
                    UPDATE dbo.PaymentHeader SET TotalPaid = TotalPaid + @v, BalanceDue = BalanceDue - @v, PaymentStatus = CASE WHEN BalanceDue - @v > 0 THEN 'U' ELSE 'P' END, LastModifiedDate = GETDATE(), LastModifiedBy = @userId
                    WHERE PaymentHeaderId = @headerId;", new { v = a.Value, k = a.Key, headerId, userId }, tx);
                await con.ExecuteAsync("dbo.usp_Ph_PostSaleLedger", new { Kind = "SRCPT", RefId = pd, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            }
            tx.Commit();
            return (receiptNo, null);
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return (null, ex.Message); }
    }

    public async Task<(List<PhSalePayment> Rows, string? Customer, string? Mobile)> ReceiptAsync(int companyId, int branchId, string receiptNo)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<PhSalePayment>(@"SELECT pd.ReceiptNo, COALESCE(pd.PaymentDate, pd.CreatedDate) PaymentDate, pm.MethodName,
                LTRIM(ISNULL(COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) + N' · ', N'') + N'Bill ' + s.SaleNo) Ref, pd.PaidAmount Amount
            FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
            LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.ReceiptNo = @receiptNo AND s.CompanyId = @companyId AND s.BranchId = @branchId AND pd.IsActive = 1
            ORDER BY pd.PaymentDetailId", new { receiptNo, companyId, branchId })).ToList();
        var who = await con.QueryFirstOrDefaultAsync<(string? Name, string? Mobile)>(@"SELECT TOP 1 s.CustomerName, s.Mobile FROM dbo.PaymentDetail pd
            JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
            WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.ReceiptNo = @receiptNo AND s.CompanyId = @companyId AND s.BranchId = @branchId", new { receiptNo, companyId, branchId });
        return (rows, who.Name, who.Mobile);
    }

    public async Task<List<dynamic>> ScheduleRegisterAsync(int companyId, int branchId, DateTime from, DateTime to, string? schedule)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync(@"SELECT r.EntryDate, s.SaleNo, r.ScheduleCode, i.ItemName, b.BatchNo, b.ExpiryDate, r.Qty, su.UomCode SaleUom, m.ManufacturerName,
                r.PatientName, r.PatientAddress, r.PrescriberName, r.PrescriberRegNo, r.RxNo, ISNULL(NULLIF(u.FullName, ''), u.Username) DispensedBy, r.IsCancelled
            FROM dbo.PhScheduleRegister r JOIN dbo.PhSale s ON s.SaleId = r.SaleId JOIN dbo.PhItem i ON i.ItemId = r.ItemId JOIN dbo.PhBatch b ON b.BatchId = r.BatchId
            JOIN dbo.PhUom su ON su.UomId = i.SaleUomId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.Users u ON u.Id = r.DispensedBy
            WHERE r.CompanyId = @companyId AND r.BranchId = @branchId AND r.EntryDate >= @from AND r.EntryDate < DATEADD(DAY, 1, @to) AND (@schedule IS NULL OR r.ScheduleCode = @schedule)
            ORDER BY r.EntryDate", new { companyId, branchId, from, to, schedule })).ToList();
    }
}
