using System.Data;
using Dapper;
using EMR.Web.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services;

// Pharmacy > Purchase (SQLScripts/2344): Purchase Indent -> Purchase Order -> GRN -> Purchase Return, Supplier Payments.
// Quantities on indent / PO / GRN are in purchase units (packs); stock and returns are in sale units.
// Amounts are always worked out here (the page only previews them); GRN and return posting is in stored procedures.

public class PhTxnItem
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }            // sale units at this branch
    public decimal ReorderLevel { get; set; }     // packs (branch value, else item default)
    public decimal MaxQty { get; set; }
    public decimal PendingPoQty { get; set; }     // packs ordered, not yet received
    public decimal? LastRate { get; set; }        // per pack, from the last GRN
    public decimal? LastMrp { get; set; }
    public string? LastSupplier { get; set; }
}

public class PhDocListRow
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; }
    public string? Party { get; set; }
    public string? Ref { get; set; }
    public string Status { get; set; } = "";
    public int Lines { get; set; }
    public decimal Amount { get; set; }
    public string? Extra { get; set; }
    public DateTime? DueDate { get; set; }
    public decimal Balance { get; set; }
}

public class PhDocLine
{
    public int LineId { get; set; }
    public int ItemId { get; set; }
    public string? ItemName { get; set; }
    public string? ItemCode { get; set; }
    public string? FormShort { get; set; }
    public string? PurchaseUom { get; set; }
    public string? SaleUom { get; set; }
    public int ConversionQty { get; set; } = 1;
    public decimal Qty { get; set; }
    public decimal FreeQty { get; set; }
    public decimal Rate { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal GstPercent { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal GstAmount { get; set; }
    public string? Remarks { get; set; }
    public decimal Stock { get; set; }
    // GRN
    public int? PoDtlId { get; set; }
    public string? BatchNo { get; set; }
    public DateTime? MfgDate { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal PendingQty { get; set; }       // PO: ordered - received
    public decimal ReceivedQty { get; set; }
    // return
    public int? BatchId { get; set; }
}

public class PhDoc
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; } = DateTime.Today;
    public string Status { get; set; } = "DRAFT";
    public int? SupplierId { get; set; }
    public string? SupplierName { get; set; }
    public int? RefId { get; set; }              // PO: indent; GRN: PO
    public string? RefNo { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string? Priority { get; set; }
    public bool IsInterState { get; set; }
    public bool IsDirect { get; set; }            // PO entered with GRN Not Required: approval posts the stock
    public string? InvoiceNo { get; set; }
    public DateTime? InvoiceDate { get; set; }
    public decimal InvoiceAmount { get; set; }
    public decimal OtherCharges { get; set; }
    public int? ReasonId { get; set; }
    public string? Terms { get; set; }
    public string? Remarks { get; set; }
    public string? ActionRemarks { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOff { get; set; }
    public decimal NetAmount { get; set; }
    public DateTime? DueDate { get; set; }
    public string? AttachmentPath { get; set; }
    public string? AttachmentName { get; set; }
    public string? EmailedTo { get; set; }
    public DateTime? EmailedDate { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public List<PhDocLine> Lines { get; set; } = [];
}

public class PhSupplierInfo
{
    public int SupplierId { get; set; }
    public string SupplierName { get; set; } = "";
    public string? Gstin { get; set; }
    public string? Email { get; set; }
    public int CreditDays { get; set; }
    public DateTime? DrugLicenceValidTo { get; set; }
    public bool IsInterState { get; set; }
    public string? Warning { get; set; }
}

public class PhBatchPick
{
    public int BatchId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal RatePerUnit { get; set; }       // purchase rate per sale unit
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public string? SupplierName { get; set; }
}

public class PhPayable
{
    public int GrnId { get; set; }
    public string GrnNo { get; set; } = "";
    public string InvoiceNo { get; set; } = "";
    public DateTime InvoiceDate { get; set; }
    public DateTime? DueDate { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Paid { get; set; }
    public decimal Balance => NetAmount - Paid;
}

public class PhSupplierBalance
{
    public int SupplierId { get; set; }
    public string SupplierName { get; set; } = "";
    public decimal Purchases { get; set; }
    public decimal Returns { get; set; }
    public decimal Paid { get; set; }
    public decimal Balance => Purchases - Returns - Paid;
    public decimal Overdue { get; set; }
    public int OpenBills { get; set; }
}

public class PhBranchHeader
{
    public string Name { get; set; } = "";
    public string? Address { get; set; }
    public string? Phone { get; set; }
    public string? Gstin { get; set; }
    public string? Licence20B { get; set; }
    public string? Licence21B { get; set; }
    public string? Pharmacist { get; set; }
    public string? LogoPath { get; set; }
}

/// <summary>What a purchase document page needs: the document, its lookups and which buttons the user may use.</summary>
public class PhDocPage
{
    public string Kind { get; set; } = "";
    public string PageCode { get; set; } = "";
    public string Title { get; set; } = "";
    public string Icon { get; set; } = "";
    public string Description { get; set; } = "";
    public PhDoc Doc { get; set; } = new();
    public List<PhOption> Suppliers { get; set; } = [];
    public List<PhOption> Reasons { get; set; } = [];
    public List<PhOption> OpenPos { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
    public PhSupplierInfo? Supplier { get; set; }
    public int MinShelfLifeDays { get; set; }
    public bool Editable => Doc.Status == "DRAFT";
    public bool Direct => Kind == "po" && Doc.IsDirect;
}

public class PhRateHistory
{
    public DateTime GrnDate { get; set; }
    public string? GrnNo { get; set; }
    public string SupplierName { get; set; } = "";
    public string BatchNo { get; set; } = "";
    public decimal Qty { get; set; }
    public decimal FreeQty { get; set; }
    public decimal Rate { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Mrp { get; set; }
    public decimal NetRate => Math.Round(Rate * (1 - DiscPercent / 100) * Qty / Math.Max(1, Qty + FreeQty), 2);   // effective rate with free goods
}

public class PhRegisterRow
{
    public string DocType { get; set; } = "";      // Purchase | Debit note
    public int Id { get; set; }
    public string DocNo { get; set; } = "";
    public DateTime DocDate { get; set; }
    public string SupplierName { get; set; } = "";
    public string? Gstin { get; set; }
    public string? InvoiceNo { get; set; }
    public DateTime? InvoiceDate { get; set; }
    public decimal Taxable { get; set; }
    public decimal Cgst { get; set; }
    public decimal Sgst { get; set; }
    public decimal Igst { get; set; }
    public decimal Other { get; set; }
    public decimal RoundOff { get; set; }
    public decimal Net { get; set; }
}

public class PhGstSummaryRow
{
    public decimal GstPercent { get; set; }
    public decimal Taxable { get; set; }
    public decimal Gst { get; set; }
}

public interface IPharmacyPurchaseService
{
    Task<List<PhRateHistory>> RateHistoryAsync(int companyId, int itemId);
    Task<string?> AttachAsync(int companyId, int branchId, int grnId, string path, string name);
    Task MarkEmailedAsync(int poId, string email);
    Task<(List<PhRegisterRow> Rows, List<PhGstSummaryRow> Gst)> RegisterAsync(int companyId, int branchId, DateTime from, DateTime to, int? supplierId);
    Task<List<PhOption>> OpenPosAsync(int companyId, int branchId, int supplierId);
    Task<PhBranchHeader> BranchHeaderAsync(int branchId);
    Task<List<PhTxnItem>> ItemSearchAsync(int companyId, int branchId, string q, int take = 15);
    Task<List<PhOption>> SuppliersAsync(int companyId);
    Task<PhSupplierInfo?> SupplierInfoAsync(int companyId, int branchId, int supplierId);
    Task<List<PhOption>> ReasonsAsync(int companyId, string type);
    Task<int> MinShelfLifeGrnDaysAsync(int branchId);
    Task<bool> GrnNotRequiredAsync(int branchId);
    Task<Dictionary<string, int>> StatusCountsAsync(string kind, int companyId, int branchId);
    Task<List<PhDocListRow>> ListAsync(string kind, int companyId, int branchId, string? status, string? search, DateTime? from, DateTime? to);
    Task<PhDoc?> GetAsync(string kind, int companyId, int branchId, int id);

    Task<List<PhTxnItem>> ReorderSuggestAsync(int companyId, int branchId);
    Task<(int Id, string? Error)> SaveIndentAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> IndentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhDocLine>> IndentLinesForPoAsync(int companyId, int branchId, int indentId);
    Task<(int Id, string? Error)> SavePoAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> PoActionAsync(int companyId, int branchId, int id, string action, int userId);

    Task<List<PhDocLine>> PoLinesForGrnAsync(int companyId, int branchId, int poId);
    Task<(int Id, List<string> Warnings, string? Error)> SaveGrnAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> DeleteDraftAsync(string kind, int companyId, int branchId, int id);
    Task<List<string>> GrnWarningsAsync(int companyId, int branchId, int grnId);
    Task<(string? DocNo, string? Error)> PostGrnAsync(int companyId, int branchId, int id, bool acceptWarnings, int userId);

    Task<List<PhBatchPick>> BatchSearchAsync(int companyId, int branchId, string q, int? supplierId);
    Task<(int Id, string? Error)> SaveReturnAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<(string? DocNo, string? Error)> PostReturnAsync(int companyId, int branchId, int id, int userId);

    Task<List<PhSupplierBalance>> SupplierBalancesAsync(int companyId, int branchId);
    Task<List<PhPayable>> PayablesAsync(int companyId, int branchId, int supplierId);
    Task<(int Id, string? Error)> SavePaymentAsync(int companyId, int branchId, int supplierId, DateTime date, string mode, string? reference, string? remarks, Dictionary<int, decimal> alloc, int userId);
    Task<string?> CancelPaymentAsync(int companyId, int branchId, int id, int userId);
}

public class PharmacyPurchaseService(IDbConnectionFactory db) : IPharmacyPurchaseService
{
    public static readonly Dictionary<string, (string Label, string Css)> StatusInfo = new()
    {
        ["DRAFT"] = ("Draft", "bg-secondary-subtle text-secondary-emphasis border border-secondary-subtle"),
        ["SUBMITTED"] = ("Submitted", "bg-info-subtle text-info-emphasis border border-info-subtle"),
        ["APPROVED"] = ("Approved", "bg-primary-subtle text-primary-emphasis border border-primary-subtle"),
        ["PARTIAL"] = ("Part received", "bg-warning-subtle text-warning-emphasis border border-warning-subtle"),
        ["ORDERED"] = ("Ordered", "bg-success-subtle text-success border border-success-subtle"),
        ["CLOSED"] = ("Closed", "bg-success-subtle text-success border border-success-subtle"),
        ["POSTED"] = ("Posted", "bg-success-subtle text-success border border-success-subtle"),
        ["REJECTED"] = ("Rejected", "bg-danger-subtle text-danger border border-danger-subtle"),
        ["CANCELLED"] = ("Cancelled", "bg-light text-secondary border")
    };

    private static decimal R2(decimal v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);

    public async Task<List<PhRateHistory>> RateHistoryAsync(int companyId, int itemId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhRateHistory>(@"SELECT TOP 8 g.GrnDate, g.GrnNo, s.SupplierName, d.BatchNo, d.Qty, d.FreeQty, d.Rate, d.DiscPercent, d.GstPercent, d.Mrp
            FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
            WHERE g.CompanyId = @companyId AND d.ItemId = @itemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC", new { companyId, itemId })).ToList();
    }

    public async Task<string?> AttachAsync(int companyId, int branchId, int grnId, string path, string name)
    {
        using var con = db.CreateConnection();
        var n = await con.ExecuteAsync("UPDATE dbo.PhGrn SET AttachmentPath = @path, AttachmentName = @name WHERE GrnId = @grnId AND CompanyId = @companyId AND BranchId = @branchId AND Status <> 'CANCELLED'",
            new { companyId, branchId, grnId, path, name });
        return n == 0 ? "GRN not found." : null;
    }

    public async Task MarkEmailedAsync(int poId, string email)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("UPDATE dbo.PhPurchaseOrder SET EmailedTo = @email, EmailedDate = GETDATE() WHERE PoId = @poId", new { poId, email });
    }

    public async Task<(List<PhRegisterRow> Rows, List<PhGstSummaryRow> Gst)> RegisterAsync(int companyId, int branchId, DateTime from, DateTime to, int? supplierId)
    {
        using var con = db.CreateConnection();
        var p = new { companyId, branchId, from, to, supplierId };
        var rows = (await con.QueryAsync<PhRegisterRow>(@"
            SELECT 'Purchase' DocType, g.GrnId Id, g.GrnNo DocNo, g.GrnDate DocDate, s.SupplierName, s.Gstin, g.InvoiceNo, g.InvoiceDate,
                   g.TaxableAmount Taxable, g.CgstAmount Cgst, g.SgstAmount Sgst, g.IgstAmount Igst, g.OtherCharges Other, g.RoundOff, g.NetAmount Net
            FROM dbo.PhGrn g JOIN dbo.PhSupplier s ON s.SupplierId = g.SupplierId
            WHERE g.CompanyId = @companyId AND g.BranchId = @branchId AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @from AND @to AND (@supplierId IS NULL OR g.SupplierId = @supplierId)
            UNION ALL
            SELECT 'Debit note', r.ReturnId, r.ReturnNo, r.ReturnDate, s.SupplierName, s.Gstin, NULL, NULL,
                   -r.TaxableAmount, CASE WHEN r.IsInterState = 1 THEN 0 ELSE -ROUND(r.GstAmount / 2, 2) END, CASE WHEN r.IsInterState = 1 THEN 0 ELSE -(r.GstAmount - ROUND(r.GstAmount / 2, 2)) END,
                   CASE WHEN r.IsInterState = 1 THEN -r.GstAmount ELSE 0 END, 0, -r.RoundOff, -r.NetAmount
            FROM dbo.PhPurchaseReturn r JOIN dbo.PhSupplier s ON s.SupplierId = r.SupplierId
            WHERE r.CompanyId = @companyId AND r.BranchId = @branchId AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @from AND @to AND (@supplierId IS NULL OR r.SupplierId = @supplierId)
            ORDER BY DocDate, DocNo", p)).ToList();
        var gst = (await con.QueryAsync<PhGstSummaryRow>(@"
            SELECT GstPercent, SUM(Taxable) Taxable, SUM(Gst) Gst FROM (
                SELECT d.GstPercent, d.TaxableAmount Taxable, d.GstAmount Gst FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId
                WHERE g.CompanyId = @companyId AND g.BranchId = @branchId AND g.Status = 'POSTED' AND g.GrnDate BETWEEN @from AND @to AND (@supplierId IS NULL OR g.SupplierId = @supplierId)
                UNION ALL
                SELECT d.GstPercent, -d.TaxableAmount, -d.GstAmount FROM dbo.PhPurchaseReturnDtl d JOIN dbo.PhPurchaseReturn r ON r.ReturnId = d.ReturnId
                WHERE r.CompanyId = @companyId AND r.BranchId = @branchId AND r.Status = 'POSTED' AND r.ReturnDate BETWEEN @from AND @to AND (@supplierId IS NULL OR r.SupplierId = @supplierId)) x
            GROUP BY GstPercent ORDER BY GstPercent", p)).ToList();
        return (rows, gst);
    }

    /// <summary>Indian-style amount in words: "Rupees One Lakh Twenty Three Thousand ... and Fifty Paise Only".</summary>
    public static string AmountInWords(decimal amount)
    {
        string[] ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
        string[] tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];
        string Two(long n) => n < 20 ? ones[n] : tens[n / 10] + (n % 10 > 0 ? " " + ones[n % 10] : "");
        string Three(long n) => (n >= 100 ? ones[n / 100] + " Hundred" + (n % 100 > 0 ? " " : "") : "") + (n % 100 > 0 ? Two(n % 100) : "");
        amount = Math.Abs(Math.Round(amount, 2));
        var rupees = (long)Math.Floor(amount); var paise = (long)Math.Round((amount - rupees) * 100);
        if (rupees == 0 && paise == 0) return "Rupees Zero Only";
        var parts = new List<string>();
        var crore = rupees / 10000000; rupees %= 10000000;
        var lakh = rupees / 100000; rupees %= 100000;
        var thousand = rupees / 1000; rupees %= 1000;
        if (crore > 0) parts.Add(Three(crore) + " Crore");
        if (lakh > 0) parts.Add(Two(lakh) + " Lakh");
        if (thousand > 0) parts.Add(Two(thousand) + " Thousand");
        if (rupees > 0) parts.Add(Three(rupees));
        var words = parts.Count > 0 ? "Rupees " + string.Join(" ", parts) : "";
        if (paise > 0) words += (words.Length > 0 ? " and " : "") + Two(paise) + " Paise";
        return words + " Only";
    }

    public async Task<List<PhOption>> OpenPosAsync(int companyId, int branchId, int supplierId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhOption>(@"SELECT CAST(PoId AS VARCHAR(10)) Value, PoNo + N' · ' + CONVERT(VARCHAR(11), PoDate, 106) + N' · ₹' + CONVERT(VARCHAR(20), NetAmount) Text
            FROM dbo.PhPurchaseOrder WHERE CompanyId = @companyId AND BranchId = @branchId AND SupplierId = @supplierId AND Status IN ('APPROVED', 'PARTIAL') ORDER BY PoDate", new { companyId, branchId, supplierId })).ToList();
    }

    public async Task<PhBranchHeader> BranchHeaderAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PhBranchHeader>(@"SELECT TOP 1 ISNULL(NULLIF(h.PharmacyName, ''), h.HotelName) Name, h.Address, ISNULL(NULLIF(h.PharmacyContactNo, ''), h.ContactNumber1) Phone,
                NULLIF(ISNULL(NULLIF(h.PharmacyGstin, ''), h.GSTCode), '') Gstin, h.PharmacyDrugLicence20B Licence20B, h.PharmacyDrugLicence21B Licence21B,
                h.PharmacistName + ISNULL(N' (Reg. ' + h.PharmacistRegNo + N')', N'') Pharmacist, h.LogoPath
            FROM dbo.HospitalSettings h WHERE h.BranchId = @branchId ORDER BY h.IsActive DESC", new { branchId }) ?? new PhBranchHeader { Name = "Pharmacy" };
    }

    // ── lookups ──────────────────────────────────────────────────────────────────────────────────────────
    private const string ItemCols = @"
        i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName, i.ScheduleCode,
        pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty, h.GstPercent,
        ISNULL((SELECT SUM(s.QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @branchId AND s.ItemId = i.ItemId), 0) AS Stock,
        ISNULL(ib.ReorderLevel, i.ReorderLevel) AS ReorderLevel, ISNULL(ib.MaxQty, i.MaxQty) AS MaxQty,
        ISNULL((SELECT SUM(pd.Qty - pd.ReceivedQty) FROM dbo.PhPurchaseOrderDtl pd JOIN dbo.PhPurchaseOrder po ON po.PoId = pd.PoId
                WHERE po.BranchId = @branchId AND po.Status IN ('APPROVED','PARTIAL') AND pd.ItemId = i.ItemId AND pd.Qty > pd.ReceivedQty), 0) AS PendingPoQty,
        lg.Rate AS LastRate, lg.Mrp AS LastMrp, lg.SupplierName AS LastSupplier";
    private const string ItemJoins = @"
        FROM dbo.PhItem i
        JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
        JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
        LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
        LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
        LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
        LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
        OUTER APPLY (SELECT TOP 1 d.Rate, d.Mrp, s.SupplierName FROM dbo.PhGrnDtl d JOIN dbo.PhGrn gr ON gr.GrnId = d.GrnId JOIN dbo.PhSupplier s ON s.SupplierId = gr.SupplierId
                     WHERE d.ItemId = i.ItemId AND gr.Status = 'POSTED' AND gr.CompanyId = @companyId ORDER BY gr.PostedDate DESC) lg";

    public async Task<List<PhTxnItem>> ItemSearchAsync(int companyId, int branchId, string q, int take = 15)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhTxnItem>($"SELECT TOP (@take) {ItemCols} {ItemJoins} " +
            @"WHERE i.CompanyId = @companyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1
                AND (i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @q OR i.Barcode = @q)
              ORDER BY CASE WHEN i.Barcode = @q OR i.ItemCode = @q THEN 0 WHEN i.ItemName LIKE @starts THEN 1 ELSE 2 END, i.ItemName",
            new { companyId, branchId, q, take, like = "%" + q + "%", starts = q + "%" })).ToList();
    }

    public async Task<List<PhOption>> SuppliersAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhOption>("SELECT CAST(SupplierId AS VARCHAR(10)) Value, SupplierName + N' (' + SupplierCode + N')' Text FROM dbo.PhSupplier WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY SupplierName", new { companyId })).ToList();
    }

    public async Task<List<PhOption>> ReasonsAsync(int companyId, string type)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhOption>("SELECT CAST(ReasonId AS VARCHAR(10)) Value, ReasonName Text FROM dbo.PhReason WHERE CompanyId = @companyId AND ReasonType = @type AND IsActive = 1 ORDER BY SortOrder, ReasonName", new { companyId, type })).ToList();
    }

    public async Task<bool> GrnNotRequiredAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<bool?>("SELECT TOP 1 PharmacyGrnNotRequired FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC", new { branchId }) ?? false;
    }

    public async Task<int> MinShelfLifeGrnDaysAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int?>("SELECT TOP 1 PharmacyMinShelfLifeGrnDays FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC", new { branchId }) ?? 90;
    }

    public async Task<PhSupplierInfo?> SupplierInfoAsync(int companyId, int branchId, int supplierId)
    {
        using var con = db.CreateConnection();
        var s = await con.QuerySingleOrDefaultAsync<PhSupplierInfo>(@"
            SELECT s.SupplierId, s.SupplierName, s.Gstin, s.Email, s.CreditDays, s.DrugLicenceValidTo,
                   CAST(CASE
                        WHEN LEN(s.Gstin) >= 2 AND LEN(bg.Gstin) >= 2 THEN CASE WHEN LEFT(s.Gstin, 2) <> LEFT(bg.Gstin, 2) THEN 1 ELSE 0 END
                        WHEN st.StateName IS NOT NULL AND b.State IS NOT NULL THEN CASE WHEN st.StateName <> b.State THEN 1 ELSE 0 END
                        ELSE 0 END AS BIT) AS IsInterState
            FROM dbo.PhSupplier s
            LEFT JOIN dbo.StateMaster st ON st.StateId = s.StateId
            CROSS JOIN (SELECT State FROM dbo.BranchMaster WHERE BranchID = @branchId) b
            OUTER APPLY (SELECT TOP 1 NULLIF(ISNULL(NULLIF(PharmacyGstin, ''), GSTCode), '') AS Gstin FROM dbo.HospitalSettings WHERE BranchId = @branchId ORDER BY IsActive DESC) bg
            WHERE s.SupplierId = @supplierId AND s.CompanyId = @companyId", new { companyId, branchId, supplierId });
        if (s?.DrugLicenceValidTo is { } v && v < DateTime.Today) s.Warning = $"Supplier's drug licence expired on {v:dd-MMM-yyyy}.";
        return s;
    }

    private static readonly Dictionary<string, (string Table, string Id, string No, string Date)> Docs = new()
    {
        ["indent"] = ("PhPurchaseIndent", "IndentId", "IndentNo", "IndentDate"),
        ["po"] = ("PhPurchaseOrder", "PoId", "PoNo", "PoDate"),
        ["grn"] = ("PhGrn", "GrnId", "GrnNo", "GrnDate"),
        ["return"] = ("PhPurchaseReturn", "ReturnId", "ReturnNo", "ReturnDate"),
        ["payment"] = ("PhSupplierPayment", "PaymentId", "PaymentNo", "PaymentDate")
    };

    public async Task<Dictionary<string, int>> StatusCountsAsync(string kind, int companyId, int branchId)
    {
        var t = Docs[kind];
        using var con = db.CreateConnection();
        return (await con.QueryAsync<(string, int)>($"SELECT Status, COUNT(*) FROM dbo.{t.Table} WHERE CompanyId = @companyId AND BranchId = @branchId GROUP BY Status", new { companyId, branchId }))
            .ToDictionary(x => x.Item1, x => x.Item2);
    }

    public async Task<List<PhDocListRow>> ListAsync(string kind, int companyId, int branchId, string? status, string? search, DateTime? from, DateTime? to)
    {
        var sql = kind switch
        {
            "indent" => @"SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, u.Name Party, d.Priority Ref, d.Status,
                            (SELECT COUNT(*) FROM dbo.PhPurchaseIndentDtl x WHERE x.IndentId = d.IndentId) Lines, 0 Amount, d.Remarks Extra
                          FROM dbo.PhPurchaseIndent d OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) Name FROM dbo.Users WHERE Id = d.CreatedBy) u",
            "po" => @"SELECT d.PoId Id, d.PoNo DocNo, d.PoDate DocDate, s.SupplierName Party, i.IndentNo Ref, d.Status,
                        (SELECT COUNT(*) FROM dbo.PhPurchaseOrderDtl x WHERE x.PoId = d.PoId) Lines, d.NetAmount Amount, CONVERT(VARCHAR(11), d.ExpectedDate, 106) Extra
                      FROM dbo.PhPurchaseOrder d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseIndent i ON i.IndentId = d.IndentId",
            "grn" => @"SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, s.SupplierName Party, d.InvoiceNo Ref, d.Status,
                         (SELECT COUNT(*) FROM dbo.PhGrnDtl x WHERE x.GrnId = d.GrnId) Lines, d.NetAmount Amount, p.PoNo Extra, d.DueDate,
                         d.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment sp ON sp.PaymentId = a.PaymentId WHERE a.GrnId = d.GrnId AND sp.Status = 'POSTED'), 0) Balance
                       FROM dbo.PhGrn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseOrder p ON p.PoId = d.PoId",
            "return" => @"SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, s.SupplierName Party, r.ReasonName Ref, d.Status,
                            (SELECT COUNT(*) FROM dbo.PhPurchaseReturnDtl x WHERE x.ReturnId = d.ReturnId) Lines, d.NetAmount Amount, d.Remarks Extra
                          FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhReason r ON r.ReasonId = d.ReasonId",
            "payment" => @"SELECT d.PaymentId Id, d.PaymentNo DocNo, d.PaymentDate DocDate, s.SupplierName Party, d.PaymentMode + ISNULL(N' · ' + d.ReferenceNo, N'') Ref, d.Status,
                             (SELECT COUNT(*) FROM dbo.PhSupplierPaymentAlloc x WHERE x.PaymentId = d.PaymentId) Lines, d.Amount, d.Remarks Extra
                           FROM dbo.PhSupplierPayment d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId",
            _ => throw new ArgumentException(kind)
        };
        var t = Docs[kind];
        sql = $"SELECT TOP 500 * FROM ({sql} WHERE d.CompanyId = @companyId AND d.BranchId = @branchId) x " +
              "WHERE (@status IS NULL OR x.Status = @status) AND (@from IS NULL OR x.DocDate >= @from) AND (@to IS NULL OR x.DocDate <= @to) " +
              "AND (@search IS NULL OR x.DocNo LIKE @like OR x.Party LIKE @like OR x.Ref LIKE @like) ORDER BY x.DocDate DESC, x.Id DESC";
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhDocListRow>(sql, new { companyId, branchId, status, from, to, search, like = "%" + search + "%" })).ToList();
    }

    public async Task<PhDoc?> GetAsync(string kind, int companyId, int branchId, int id)
    {
        using var con = db.CreateConnection();
        var p = new { companyId, branchId, id };
        const string by = "OUTER APPLY (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) N FROM dbo.Users WHERE Id = {0}) {1}";
        PhDoc? d;
        string linesSql;
        switch (kind)
        {
            case "indent":
                d = await con.QuerySingleOrDefaultAsync<PhDoc>($@"SELECT d.IndentId Id, d.IndentNo DocNo, d.IndentDate DocDate, d.Status, d.Priority, d.Remarks, d.ActionRemarks,
                        cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
                    FROM dbo.PhPurchaseIndent d {string.Format(by, "d.CreatedBy", "cb")} {string.Format(by, "d.ApprovedBy", "ab")}
                    WHERE d.IndentId = @id AND d.CompanyId = @companyId AND d.BranchId = @branchId", p);
                linesSql = @"SELECT x.IndentDtlId LineId, x.ItemId, x.Qty, x.Remarks, x.StockAtIndent Stock FROM dbo.PhPurchaseIndentDtl x WHERE x.IndentId = @id ORDER BY x.IndentDtlId";
                break;
            case "po":
                d = await con.QuerySingleOrDefaultAsync<PhDoc>($@"SELECT d.PoId Id, d.PoNo DocNo, d.PoDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.IndentId RefId, i.IndentNo RefNo,
                        d.ExpectedDate, d.IsInterState, d.IsDirect, d.InvoiceNo, d.InvoiceDate, ISNULL(d.InvoiceAmount, 0) InvoiceAmount, d.OtherCharges, d.Terms, d.Remarks, d.TaxableAmount, d.GstAmount, d.NetAmount, d.EmailedTo, d.EmailedDate, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.ApprovedDate
                    FROM dbo.PhPurchaseOrder d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseIndent i ON i.IndentId = d.IndentId
                    {string.Format(by, "d.CreatedBy", "cb")} {string.Format(by, "d.ApprovedBy", "ab")}
                    WHERE d.PoId = @id AND d.CompanyId = @companyId AND d.BranchId = @branchId", p);
                linesSql = @"SELECT x.PoDtlId LineId, x.ItemId, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount, x.ReceivedQty, x.Qty - x.ReceivedQty PendingQty,
                                    x.BatchNo, x.ExpiryDate, ISNULL(x.Mrp, 0) Mrp
                             FROM dbo.PhPurchaseOrderDtl x WHERE x.PoId = @id ORDER BY x.PoDtlId";
                break;
            case "grn":
                d = await con.QuerySingleOrDefaultAsync<PhDoc>($@"SELECT d.GrnId Id, d.GrnNo DocNo, d.GrnDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.PoId RefId, po.PoNo RefNo,
                        d.InvoiceNo, d.InvoiceDate, d.InvoiceAmount, d.IsInterState, d.OtherCharges, d.Remarks, d.TaxableAmount, d.CgstAmount + d.SgstAmount + d.IgstAmount GstAmount,
                        d.DiscountAmount, d.RoundOff, d.NetAmount, d.DueDate, d.AttachmentPath, d.AttachmentName, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
                    FROM dbo.PhGrn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId LEFT JOIN dbo.PhPurchaseOrder po ON po.PoId = d.PoId
                    {string.Format(by, "d.CreatedBy", "cb")} {string.Format(by, "d.PostedBy", "ab")}
                    WHERE d.GrnId = @id AND d.CompanyId = @companyId AND d.BranchId = @branchId", p);
                linesSql = @"SELECT x.GrnDtlId LineId, x.ItemId, x.PoDtlId, x.BatchNo, x.MfgDate, x.ExpiryDate, x.Mrp, x.Qty, x.FreeQty, x.Rate, x.DiscPercent, x.GstPercent, x.TaxableAmount, x.GstAmount,
                                    ISNULL(pd.Qty - pd.ReceivedQty, 0) PendingQty
                             FROM dbo.PhGrnDtl x LEFT JOIN dbo.PhPurchaseOrderDtl pd ON pd.PoDtlId = x.PoDtlId WHERE x.GrnId = @id ORDER BY x.GrnDtlId";
                break;
            case "return":
                d = await con.QuerySingleOrDefaultAsync<PhDoc>($@"SELECT d.ReturnId Id, d.ReturnNo DocNo, d.ReturnDate DocDate, d.Status, d.SupplierId, s.SupplierName, d.ReasonId, d.IsInterState,
                        d.Remarks, d.TaxableAmount, d.GstAmount, d.RoundOff, d.NetAmount, cb.N CreatedByName, d.CreatedDate, ab.N ApprovedByName, d.PostedDate ApprovedDate
                    FROM dbo.PhPurchaseReturn d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId
                    {string.Format(by, "d.CreatedBy", "cb")} {string.Format(by, "d.PostedBy", "ab")}
                    WHERE d.ReturnId = @id AND d.CompanyId = @companyId AND d.BranchId = @branchId", p);
                linesSql = @"SELECT x.ReturnDtlId LineId, x.ItemId, x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.Qty, x.Rate, x.GstPercent, x.TaxableAmount, x.GstAmount,
                                    ISNULL((SELECT QtyOnHand FROM dbo.PhStock st WHERE st.BranchId = @branchId AND st.BatchId = x.BatchId), 0) Stock
                             FROM dbo.PhPurchaseReturnDtl x JOIN dbo.PhBatch b ON b.BatchId = x.BatchId WHERE x.ReturnId = @id ORDER BY x.ReturnDtlId";
                break;
            case "payment":
                d = await con.QuerySingleOrDefaultAsync<PhDoc>($@"SELECT d.PaymentId Id, d.PaymentNo DocNo, d.PaymentDate DocDate, d.Status, d.SupplierId, s.SupplierName,
                        d.PaymentMode Priority, d.ReferenceNo InvoiceNo, d.Remarks, d.Amount NetAmount, cb.N CreatedByName, d.CreatedDate
                    FROM dbo.PhSupplierPayment d JOIN dbo.PhSupplier s ON s.SupplierId = d.SupplierId {string.Format(by, "d.CreatedBy", "cb")}
                    WHERE d.PaymentId = @id AND d.CompanyId = @companyId AND d.BranchId = @branchId", p);
                linesSql = @"SELECT a.AllocId LineId, 0 ItemId, g.GrnNo ItemName, g.InvoiceNo ItemCode, g.InvoiceDate ExpiryDate, g.NetAmount Mrp, a.Amount TaxableAmount
                             FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhGrn g ON g.GrnId = a.GrnId WHERE a.PaymentId = @id ORDER BY a.AllocId";
                break;
            default: throw new ArgumentException(kind);
        }
        if (d == null) return null;
        d.Lines = (await con.QueryAsync<PhDocLine>(linesSql, p)).ToList();
        await FillItemInfoAsync(con, companyId, branchId, d.Lines);
        return d;
    }

    private static async Task FillItemInfoAsync(IDbConnection con, int companyId, int branchId, List<PhDocLine> lines)
    {
        if (lines.Count == 0) return;
        var info = (await con.QueryAsync<PhTxnItem>($"SELECT {ItemCols} {ItemJoins} WHERE i.CompanyId = @companyId AND i.ItemId IN @ids",
            new { companyId, branchId, ids = lines.Select(l => l.ItemId).Distinct() })).ToDictionary(i => i.ItemId);
        foreach (var l in lines)
            if (info.TryGetValue(l.ItemId, out var i))
            {
                l.ItemName = i.ItemName; l.ItemCode = i.ItemCode; l.FormShort = i.FormShort; l.PurchaseUom = i.PurchaseUom; l.SaleUom = i.SaleUom; l.ConversionQty = i.ConversionQty;
                if (l.BatchId == null) l.Stock = i.Stock;
            }
    }

    // ── purchase indent ──────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhTxnItem>> ReorderSuggestAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhTxnItem>($"SELECT * FROM (SELECT {ItemCols} {ItemJoins} WHERE i.CompanyId = @companyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1) x " +
            "WHERE x.ReorderLevel > 0 AND x.Stock / x.ConversionQty + x.PendingPoQty <= x.ReorderLevel ORDER BY x.ItemName", new { companyId, branchId })).ToList();
    }

    public async Task<(int Id, string? Error)> SaveIndentAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (lines.Count == 0) return (0, "Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every item needs a quantity above zero.");
        if (lines.GroupBy(l => l.ItemId).Any(g => g.Count() > 1)) return (0, "An item is listed twice; keep one line per item.");
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (d.Id > 0)
        {
            var st = await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhPurchaseIndent WITH (UPDLOCK) WHERE IndentId = @Id AND CompanyId = @companyId AND BranchId = @branchId", new { d.Id, companyId, branchId }, tx);
            if (st != "DRAFT") { tx.Rollback(); return (0, "Only a draft indent can be changed."); }
            await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET IndentDate = @DocDate, Priority = @Priority, Remarks = @Remarks, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE IndentId = @Id",
                new { d.Id, d.DocDate, Priority = d.Priority == "URGENT" ? "URGENT" : "NORMAL", d.Remarks, userId }, tx);
            await con.ExecuteAsync("DELETE dbo.PhPurchaseIndentDtl WHERE IndentId = @Id", new { d.Id }, tx);
        }
        else
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhPurchaseIndent (CompanyId, BranchId, IndentDate, Priority, Remarks, CreatedBy) VALUES (@companyId, @branchId, @DocDate, @Priority, @Remarks, @userId);
                SELECT CAST(SCOPE_IDENTITY() AS INT);", new { companyId, branchId, d.DocDate, Priority = d.Priority == "URGENT" ? "URGENT" : "NORMAL", d.Remarks, userId }, tx);
        await con.ExecuteAsync(@"INSERT dbo.PhPurchaseIndentDtl (IndentId, ItemId, Qty, StockAtIndent, Remarks)
            SELECT @IndentId, i.ItemId, @Qty, ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock WHERE BranchId = @branchId AND ItemId = i.ItemId), 0), @Remarks
            FROM dbo.PhItem i WHERE i.ItemId = @ItemId AND i.CompanyId = @companyId AND i.IsActive = 1",
            lines.Select(l => new { IndentId = d.Id, l.ItemId, l.Qty, l.Remarks, branchId, companyId }), tx);
        tx.Commit();
        return (d.Id, null);
    }

    public async Task<string?> IndentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        var h = await con.QuerySingleOrDefaultAsync<(string Status, DateTime Date)>("SELECT Status, IndentDate FROM dbo.PhPurchaseIndent WITH (UPDLOCK) WHERE IndentId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx);
        if (h.Status == null) { tx.Rollback(); return "Indent not found."; }
        switch (action)
        {
            case "submit":
                if (h.Status != "DRAFT") { tx.Rollback(); return "Only a draft can be submitted."; }
                var no = await NextNumberAsync(con, tx, branchId, "PIND", h.Date);
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET Status = 'SUBMITTED', IndentNo = @no, SubmittedBy = @userId, SubmittedDate = GETDATE() WHERE IndentId = @id", new { id, no, userId }, tx);
                break;
            case "approve":
            case "reject":
                if (h.Status != "SUBMITTED") { tx.Rollback(); return "Only a submitted indent can be approved or rejected."; }
                if (action == "reject" && string.IsNullOrWhiteSpace(remarks)) { tx.Rollback(); return "Give the reason for rejecting."; }
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET Status = @s, ActionRemarks = @remarks, ApprovedBy = @userId, ApprovedDate = GETDATE() WHERE IndentId = @id",
                    new { id, s = action == "approve" ? "APPROVED" : "REJECTED", remarks, userId }, tx);
                break;
            case "cancel":
                if (h.Status is not ("DRAFT" or "SUBMITTED" or "APPROVED")) { tx.Rollback(); return "This indent cannot be cancelled."; }
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET Status = 'CANCELLED', ActionRemarks = ISNULL(@remarks, ActionRemarks), ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE IndentId = @id", new { id, remarks, userId }, tx);
                break;
            default: tx.Rollback(); return "Unknown action.";
        }
        tx.Commit();
        return null;
    }

    // ── purchase order ───────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhDocLine>> IndentLinesForPoAsync(int companyId, int branchId, int indentId)
    {
        using var con = db.CreateConnection();
        var lines = (await con.QueryAsync<PhDocLine>(@"SELECT x.ItemId, x.Qty, h.GstPercent,
                ISNULL((SELECT TOP 1 d.Rate FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId WHERE d.ItemId = x.ItemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC), 0) Rate
            FROM dbo.PhPurchaseIndentDtl x JOIN dbo.PhPurchaseIndent i ON i.IndentId = x.IndentId JOIN dbo.PhItem it ON it.ItemId = x.ItemId JOIN dbo.PhHsn h ON h.HsnId = it.HsnId
            WHERE x.IndentId = @indentId AND i.CompanyId = @companyId AND i.BranchId = @branchId AND i.Status = 'APPROVED'", new { companyId, branchId, indentId })).ToList();
        await FillItemInfoAsync(con, companyId, branchId, lines);
        return lines;
    }

    private static void Price(PhDocLine l)
    {
        l.TaxableAmount = R2(l.Qty * l.Rate * (1 - l.DiscPercent / 100));
        l.GstAmount = R2(l.TaxableAmount * l.GstPercent / 100);
    }

    private static string? CheckPricedLines(List<PhDocLine> lines)
    {
        if (lines.Count == 0) return "Add at least one item.";
        if (lines.Any(l => l.Qty <= 0)) return "Every item needs a quantity above zero.";
        if (lines.Any(l => l.FreeQty < 0 || l.Rate < 0)) return "Free quantity and rate cannot be negative.";
        if (lines.Any(l => l.DiscPercent is < 0 or > 100)) return "Discount % must be between 0 and 100.";
        if (lines.Any(l => l.GstPercent is not (0 or 5 or 12 or 18 or 28))) return "GST % must be 0, 5, 12, 18 or 28.";
        return null;
    }

    public async Task<(int Id, string? Error)> SavePoAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (d.SupplierId is null or 0) return (0, "Pick the supplier.");
        if (CheckPricedLines(lines) is { } err) return (0, err);
        if (lines.Any(l => l.Rate <= 0)) return (0, "Every item needs a rate.");
        if (d.ExpectedDate != null && d.ExpectedDate < d.DocDate) return (0, "Expected delivery is before the order date.");
        if (d.Id == 0) d.IsDirect = await GrnNotRequiredAsync(branchId);   // a draft keeps the mode it was started in (never taken from the page)
        else using (var c0 = db.CreateConnection())
            d.IsDirect = await c0.ExecuteScalarAsync<bool?>("SELECT IsDirect FROM dbo.PhPurchaseOrder WHERE PoId = @Id AND CompanyId = @companyId AND BranchId = @branchId", new { d.Id, companyId, branchId }) ?? false;
        if (d.IsDirect)
        {
            d.InvoiceNo = d.InvoiceNo?.Trim();
            if (string.IsNullOrWhiteSpace(d.InvoiceNo)) return (0, "Enter the supplier's bill number (GRN is not required, so the order takes the bill).");
            if (d.InvoiceDate == null) return (0, "Enter the supplier's bill date.");
            if (d.InvoiceDate > DateTime.Today) return (0, "Bill date cannot be in the future.");
            if (d.OtherCharges < 0) return (0, "Other charges cannot be negative.");
            if (CheckBatchLines(lines) is { } berr) return (0, berr);
        }
        else { d.InvoiceNo = null; d.InvoiceDate = null; d.InvoiceAmount = 0; d.OtherCharges = 0; lines.ForEach(l => { l.BatchNo = null; l.ExpiryDate = null; l.Mrp = 0; }); }
        lines.ForEach(Price);
        var taxable = lines.Sum(l => l.TaxableAmount); var gst = lines.Sum(l => l.GstAmount);
        var net = d.IsDirect ? Math.Round(taxable + gst + d.OtherCharges, 0, MidpointRounding.AwayFromZero) : R2(taxable + gst);
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (d.IsDirect && await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhGrn WHERE CompanyId = @companyId AND SupplierId = @SupplierId AND InvoiceNo = @InvoiceNo AND Status <> 'CANCELLED'",
                new { companyId, d.SupplierId, d.InvoiceNo }, tx) > 0)
        { tx.Rollback(); return (0, $"Bill {d.InvoiceNo} of this supplier is already entered."); }
        var args = new { d.Id, companyId, branchId, d.DocDate, d.SupplierId, IndentId = d.RefId, d.ExpectedDate, d.IsInterState, d.Terms, d.Remarks, taxable, gst, net, userId,
                         d.IsDirect, d.InvoiceNo, d.InvoiceDate, InvoiceAmount = d.IsDirect ? d.InvoiceAmount : (decimal?)null, d.OtherCharges };
        if (d.Id > 0)
        {
            var st = await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhPurchaseOrder WITH (UPDLOCK) WHERE PoId = @Id AND CompanyId = @companyId AND BranchId = @branchId", args, tx);
            if (st != "DRAFT") { tx.Rollback(); return (0, "Only a draft order can be changed."); }
            await con.ExecuteAsync(@"UPDATE dbo.PhPurchaseOrder SET PoDate = @DocDate, SupplierId = @SupplierId, ExpectedDate = @ExpectedDate, IsInterState = @IsInterState, Terms = @Terms, Remarks = @Remarks,
                TaxableAmount = @taxable, GstAmount = @gst, NetAmount = @net, InvoiceNo = @InvoiceNo, InvoiceDate = @InvoiceDate, InvoiceAmount = @InvoiceAmount, OtherCharges = @OtherCharges,
                ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE PoId = @Id", args, tx);
            await con.ExecuteAsync("DELETE dbo.PhPurchaseOrderDtl WHERE PoId = @Id", args, tx);
        }
        else
        {
            if (d.RefId != null && await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhPurchaseIndent WHERE IndentId = @IndentId AND CompanyId = @companyId AND BranchId = @branchId", args, tx) != "APPROVED")
            { tx.Rollback(); return (0, "The indent is not approved (or already ordered)."); }
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhPurchaseOrder (CompanyId, BranchId, PoDate, SupplierId, IndentId, ExpectedDate, IsInterState, Terms, Remarks, TaxableAmount, GstAmount, NetAmount,
                    IsDirect, InvoiceNo, InvoiceDate, InvoiceAmount, OtherCharges, CreatedBy)
                VALUES (@companyId, @branchId, @DocDate, @SupplierId, @IndentId, @ExpectedDate, @IsInterState, @Terms, @Remarks, @taxable, @gst, @net,
                    @IsDirect, @InvoiceNo, @InvoiceDate, @InvoiceAmount, @OtherCharges, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", args, tx);
            if (d.RefId != null) await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET Status = 'ORDERED' WHERE IndentId = @IndentId", args, tx);
        }
        await con.ExecuteAsync(@"INSERT dbo.PhPurchaseOrderDtl (PoId, ItemId, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount, BatchNo, ExpiryDate, Mrp)
            SELECT @PoId, ItemId, @Qty, @FreeQty, @Rate, @DiscPercent, @GstPercent, @TaxableAmount, @GstAmount, @BatchNo, @ExpiryDate, @Mrp FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @companyId",
            lines.Select(l => new { PoId = d.Id, l.ItemId, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount, l.BatchNo, l.ExpiryDate, Mrp = d.IsDirect ? l.Mrp : (decimal?)null, companyId }), tx);
        tx.Commit();
        return (d.Id, null);
    }

    public async Task<string?> PoActionAsync(int companyId, int branchId, int id, string action, int userId)
    {
        if (action == "approve" && await GetAsync("po", companyId, branchId, id) is { IsDirect: true, Status: "DRAFT" } direct)
            return await ApproveDirectAsync(companyId, branchId, direct, userId);
        return await PoActionCoreAsync(companyId, branchId, id, action, userId);
    }

    /// <summary>GRN Not Required: approve the order, then create and post its GRN (stock in). If the GRN cannot be posted the order goes back to draft.</summary>
    private async Task<string?> ApproveDirectAsync(int companyId, int branchId, PhDoc po, int userId)
    {
        if (Math.Abs(po.InvoiceAmount - po.NetAmount) > 1)
            return $"Supplier bill amount ₹{po.InvoiceAmount:0.00} and order total ₹{po.NetAmount:0.00} differ. Correct the lines or the bill amount before approving.";
        if (await PoActionCoreAsync(companyId, branchId, po.Id, "approve", userId) is { } err) return err;
        var grn = new PhDoc
        {
            DocDate = po.DocDate > DateTime.Today ? DateTime.Today : po.DocDate, SupplierId = po.SupplierId, RefId = po.Id, InvoiceNo = po.InvoiceNo, InvoiceDate = po.InvoiceDate,
            InvoiceAmount = po.InvoiceAmount, OtherCharges = po.OtherCharges, IsInterState = po.IsInterState, Remarks = "Posted on approval of the purchase order (GRN not required).",
            Lines = po.Lines.Select(l => new PhDocLine { PoDtlId = l.LineId, ItemId = l.ItemId, BatchNo = l.BatchNo, ExpiryDate = l.ExpiryDate, Mrp = l.Mrp, Qty = l.Qty, FreeQty = l.FreeQty,
                                                         Rate = l.Rate, DiscPercent = l.DiscPercent, GstPercent = l.GstPercent }).ToList()
        };
        var (grnId, _, saveErr) = await SaveGrnAsync(companyId, branchId, grn, userId);
        string? postErr = saveErr;
        if (saveErr == null) (_, postErr) = await PostGrnAsync(companyId, branchId, grnId, true, userId);
        if (postErr == null) return null;
        using (var con = db.CreateConnection())   // undo: back to draft (the PO number already given is not reused)
            await con.ExecuteAsync(@"IF @grnId > 0 AND EXISTS (SELECT 1 FROM dbo.PhGrn WHERE GrnId = @grnId AND Status = 'DRAFT')
                    BEGIN DELETE dbo.PhGrnDtl WHERE GrnId = @grnId; DELETE dbo.PhGrn WHERE GrnId = @grnId; END
                UPDATE dbo.PhPurchaseOrder SET Status = 'DRAFT', PoNo = NULL, ApprovedBy = NULL, ApprovedDate = NULL WHERE PoId = @id AND Status = 'APPROVED';",
                new { grnId, id = po.Id });
        return "Stock could not be posted, so the order is back to draft: " + postErr;
    }

    private async Task<string?> PoActionCoreAsync(int companyId, int branchId, int id, string action, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        var h = await con.QuerySingleOrDefaultAsync<(string Status, DateTime Date, int? IndentId)>("SELECT Status, PoDate, IndentId FROM dbo.PhPurchaseOrder WITH (UPDLOCK) WHERE PoId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx);
        if (h.Status == null) { tx.Rollback(); return "Order not found."; }
        switch (action)
        {
            case "approve":
                if (h.Status != "DRAFT") { tx.Rollback(); return "Only a draft order can be approved."; }
                var no = await NextNumberAsync(con, tx, branchId, "PO", h.Date);
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseOrder SET Status = 'APPROVED', PoNo = @no, ApprovedBy = @userId, ApprovedDate = GETDATE() WHERE PoId = @id", new { id, no, userId }, tx);
                break;
            case "cancel":
                if (h.Status is not ("DRAFT" or "APPROVED")) { tx.Rollback(); return "Only a draft or approved order with nothing received can be cancelled."; }
                if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhGrn WHERE PoId = @id AND Status <> 'CANCELLED'", new { id }, tx) > 0) { tx.Rollback(); return "A GRN is already entered against this order."; }
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseOrder SET Status = 'CANCELLED', ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE PoId = @id", new { id, userId }, tx);
                if (h.IndentId != null) await con.ExecuteAsync("UPDATE dbo.PhPurchaseIndent SET Status = 'APPROVED' WHERE IndentId = @i AND Status = 'ORDERED'", new { i = h.IndentId }, tx);
                break;
            case "close":
                if (h.Status != "PARTIAL") { tx.Rollback(); return "Only a part-received order can be short-closed."; }
                await con.ExecuteAsync("UPDATE dbo.PhPurchaseOrder SET Status = 'CLOSED', ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE PoId = @id", new { id, userId }, tx);
                break;
            default: tx.Rollback(); return "Unknown action.";
        }
        tx.Commit();
        return null;
    }

    // ── GRN ──────────────────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhDocLine>> PoLinesForGrnAsync(int companyId, int branchId, int poId)
    {
        using var con = db.CreateConnection();
        var lines = (await con.QueryAsync<PhDocLine>(@"SELECT x.PoDtlId, x.ItemId, x.Qty - x.ReceivedQty Qty, x.Qty - x.ReceivedQty PendingQty,
                CASE WHEN x.ReceivedQty = 0 THEN x.FreeQty ELSE 0 END FreeQty, x.Rate, x.DiscPercent, x.GstPercent,
                (SELECT TOP 1 d.Mrp FROM dbo.PhGrnDtl d JOIN dbo.PhGrn g ON g.GrnId = d.GrnId WHERE d.ItemId = x.ItemId AND g.Status = 'POSTED' ORDER BY g.PostedDate DESC) Mrp
            FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder p ON p.PoId = x.PoId
            WHERE x.PoId = @poId AND p.CompanyId = @companyId AND p.BranchId = @branchId AND p.Status IN ('APPROVED', 'PARTIAL') AND x.Qty > x.ReceivedQty
            ORDER BY x.PoDtlId", new { companyId, branchId, poId })).ToList();
        await FillItemInfoAsync(con, companyId, branchId, lines);
        return lines;
    }

    public async Task<(int Id, List<string> Warnings, string? Error)> SaveGrnAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var warn = new List<string>();
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        d.InvoiceNo = d.InvoiceNo?.Trim();
        if (d.SupplierId is null or 0) return (0, warn, "Pick the supplier.");
        if (string.IsNullOrWhiteSpace(d.InvoiceNo)) return (0, warn, "Enter the supplier's invoice number.");
        if (d.InvoiceDate == null) return (0, warn, "Enter the supplier's invoice date.");
        if (d.InvoiceDate > d.DocDate) return (0, warn, "Invoice date is after the GRN date.");
        if (d.DocDate > DateTime.Today) return (0, warn, "GRN date cannot be in the future.");
        if (d.OtherCharges < 0) return (0, warn, "Other charges cannot be negative.");
        if (CheckPricedLines(lines) is { } err) return (0, warn, err);
        if (CheckBatchLines(lines) is { } berr) return (0, warn, berr);
        lines.ForEach(Price);
        return await SaveGrnCoreAsync(companyId, branchId, d, lines, userId, warn);
    }

    /// <summary>Batch, expiry and MRP rules for stock coming in (GRN, or a purchase order when GRN is not required).</summary>
    private static string? CheckBatchLines(List<PhDocLine> lines)
    {
        foreach (var l in lines)
        {
            l.BatchNo = l.BatchNo?.Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(l.BatchNo) || l.BatchNo.Length > 30) return "Every item needs a batch number (up to 30 characters).";
            if (l.ExpiryDate == null) return $"Enter the expiry of batch {l.BatchNo}.";
            l.ExpiryDate = new DateTime(l.ExpiryDate.Value.Year, l.ExpiryDate.Value.Month, DateTime.DaysInMonth(l.ExpiryDate.Value.Year, l.ExpiryDate.Value.Month));
            if (l.ExpiryDate <= DateTime.Today) return $"Batch {l.BatchNo} has already expired.";
            if (l.MfgDate != null && l.MfgDate >= l.ExpiryDate) return $"Batch {l.BatchNo}: manufacturing date is after expiry.";
            if (l.Mrp <= 0) return $"Enter the MRP of batch {l.BatchNo}.";
            var costWithGst = l.Rate * (1 - l.DiscPercent / 100) * (1 + l.GstPercent / 100);
            if (costWithGst > l.Mrp) return $"Batch {l.BatchNo}: purchase cost with GST (₹{costWithGst:0.00}) is above the MRP (₹{l.Mrp:0.00}).";
        }
        if (lines.GroupBy(l => (l.ItemId, l.BatchNo, l.Mrp)).Any(g => g.Count() > 1)) return "The same item, batch and MRP is entered twice; put it on one line.";
        return null;
    }

    private async Task<(int Id, List<string> Warnings, string? Error)> SaveGrnCoreAsync(int companyId, int branchId, PhDoc d, List<PhDocLine> lines, int userId, List<string> warn)
    {

        using var con = Open();
        using var tx = con.BeginTransaction();
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhGrn WHERE CompanyId = @companyId AND SupplierId = @SupplierId AND InvoiceNo = @InvoiceNo AND Status <> 'CANCELLED' AND GrnId <> @Id",
                new { companyId, d.SupplierId, d.InvoiceNo, d.Id }, tx) > 0)
        { tx.Rollback(); return (0, warn, $"Invoice {d.InvoiceNo} of this supplier is already entered."); }
        if (d.RefId != null)
        {
            var pend = (await con.QueryAsync<(int PoDtlId, decimal Pending)>(@"SELECT x.PoDtlId, x.Qty - x.ReceivedQty FROM dbo.PhPurchaseOrderDtl x JOIN dbo.PhPurchaseOrder p ON p.PoId = x.PoId
                WHERE x.PoId = @PoId AND p.SupplierId = @SupplierId AND p.Status IN ('APPROVED', 'PARTIAL')", new { PoId = d.RefId, d.SupplierId }, tx)).ToDictionary(x => x.PoDtlId, x => x.Pending);
            if (pend.Count == 0) { tx.Rollback(); return (0, warn, "The purchase order is not open for this supplier."); }
            foreach (var g in lines.Where(l => l.PoDtlId != null).GroupBy(l => l.PoDtlId!.Value))
                if (!pend.TryGetValue(g.Key, out var p) || g.Sum(l => l.Qty) > p) { tx.Rollback(); return (0, warn, "Received quantity is more than the quantity pending on the order."); }
        }
        else lines.ForEach(l => l.PoDtlId = null);

        var taxable = lines.Sum(l => l.TaxableAmount); var gst = lines.Sum(l => l.GstAmount);
        var gross = R2(lines.Sum(l => l.Qty * l.Rate));
        var cgst = d.IsInterState ? 0 : R2(gst / 2); var sgst = d.IsInterState ? 0 : gst - cgst; var igst = d.IsInterState ? gst : 0;
        var exact = taxable + gst + d.OtherCharges;
        var net = Math.Round(exact, 0, MidpointRounding.AwayFromZero);
        var args = new
        {
            d.Id, companyId, branchId, d.DocDate, d.SupplierId, PoId = d.RefId, d.InvoiceNo, d.InvoiceDate, d.InvoiceAmount, d.IsInterState, d.OtherCharges, d.Remarks,
            gross, disc = gross - taxable, taxable, cgst, sgst, igst, round = net - exact, net, userId
        };
        if (d.Id > 0)
        {
            var st = await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhGrn WITH (UPDLOCK) WHERE GrnId = @Id AND CompanyId = @companyId AND BranchId = @branchId", args, tx);
            if (st != "DRAFT") { tx.Rollback(); return (0, warn, "Only a draft GRN can be changed."); }
            await con.ExecuteAsync(@"UPDATE dbo.PhGrn SET GrnDate = @DocDate, SupplierId = @SupplierId, PoId = @PoId, InvoiceNo = @InvoiceNo, InvoiceDate = @InvoiceDate, InvoiceAmount = @InvoiceAmount,
                IsInterState = @IsInterState, OtherCharges = @OtherCharges, Remarks = @Remarks, GrossAmount = @gross, DiscountAmount = @disc, TaxableAmount = @taxable,
                CgstAmount = @cgst, SgstAmount = @sgst, IgstAmount = @igst, RoundOff = @round, NetAmount = @net, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE GrnId = @Id", args, tx);
            await con.ExecuteAsync("DELETE dbo.PhGrnDtl WHERE GrnId = @Id", args, tx);
        }
        else
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhGrn (CompanyId, BranchId, GrnDate, SupplierId, PoId, InvoiceNo, InvoiceDate, InvoiceAmount, IsInterState, OtherCharges, Remarks,
                    GrossAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, IgstAmount, RoundOff, NetAmount, CreatedBy)
                VALUES (@companyId, @branchId, @DocDate, @SupplierId, @PoId, @InvoiceNo, @InvoiceDate, @InvoiceAmount, @IsInterState, @OtherCharges, @Remarks,
                    @gross, @disc, @taxable, @cgst, @sgst, @igst, @round, @net, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", args, tx);
        await con.ExecuteAsync(@"INSERT dbo.PhGrnDtl (GrnId, PoDtlId, ItemId, BatchNo, MfgDate, ExpiryDate, Mrp, Qty, FreeQty, Rate, DiscPercent, GstPercent, TaxableAmount, GstAmount)
            SELECT @GrnId, @PoDtlId, ItemId, @BatchNo, @MfgDate, @ExpiryDate, @Mrp, @Qty, @FreeQty, @Rate, @DiscPercent, @GstPercent, @TaxableAmount, @GstAmount FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @companyId",
            lines.Select(l => new { GrnId = d.Id, l.PoDtlId, l.ItemId, l.BatchNo, l.MfgDate, l.ExpiryDate, l.Mrp, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount, companyId }), tx);
        tx.Commit();
        warn.AddRange(await GrnWarningsAsync(companyId, branchId, d.Id));
        return (d.Id, warn, null);
    }

    public async Task<List<string>> GrnWarningsAsync(int companyId, int branchId, int grnId)
    {
        var w = new List<string>();
        var g = await GetAsync("grn", companyId, branchId, grnId);
        if (g == null) return w;
        var days = await MinShelfLifeGrnDaysAsync(branchId);
        foreach (var l in g.Lines.Where(l => l.ExpiryDate < DateTime.Today.AddDays(days)))
            w.Add($"{l.ItemName} batch {l.BatchNo} expires {l.ExpiryDate:MMM-yyyy}: less than {days} days of shelf life.");
        using (var con = db.CreateConnection())
            foreach (var l in g.Lines)
            {
                var last = await con.ExecuteScalarAsync<decimal?>(@"SELECT TOP 1 d.Mrp FROM dbo.PhGrnDtl d JOIN dbo.PhGrn x ON x.GrnId = d.GrnId
                    WHERE d.ItemId = @ItemId AND x.Status = 'POSTED' AND x.CompanyId = @companyId ORDER BY x.PostedDate DESC", new { l.ItemId, companyId });
                if (last != null && last != l.Mrp) w.Add($"{l.ItemName}: MRP ₹{l.Mrp:0.00} differs from the last purchase (₹{last:0.00}).");
            }
        if (Math.Abs(g.InvoiceAmount - g.NetAmount) > 1)
            w.Add($"Supplier bill amount ₹{g.InvoiceAmount:0.00} does not match the GRN total ₹{g.NetAmount:0.00} (difference ₹{g.InvoiceAmount - g.NetAmount:0.00}).");
        if (await SupplierInfoAsync(companyId, branchId, g.SupplierId!.Value) is { Warning: { } sw }) w.Add(sw);
        return w;
    }

    public async Task<string?> DeleteDraftAsync(string kind, int companyId, int branchId, int id)
    {
        var (t, dtl) = kind switch { "grn" => ("PhGrn", "PhGrnDtl"), "return" => ("PhPurchaseReturn", "PhPurchaseReturnDtl"), _ => throw new ArgumentException(kind) };
        var idc = Docs[kind].Id;
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (await con.ExecuteScalarAsync<string?>($"SELECT Status FROM dbo.{t} WITH (UPDLOCK) WHERE {idc} = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx) != "DRAFT")
        { tx.Rollback(); return "Only a draft can be deleted."; }
        await con.ExecuteAsync($"DELETE dbo.{dtl} WHERE {idc} = @id; DELETE dbo.{t} WHERE {idc} = @id;", new { id }, tx);
        tx.Commit();
        return null;
    }

    public async Task<(string? DocNo, string? Error)> PostGrnAsync(int companyId, int branchId, int id, bool acceptWarnings, int userId)
    {
        var g = await GetAsync("grn", companyId, branchId, id);
        if (g == null) return (null, "GRN not found.");
        if (Math.Abs(g.InvoiceAmount - g.NetAmount) > 1) return (null, $"Supplier bill amount ₹{g.InvoiceAmount:0.00} and GRN total ₹{g.NetAmount:0.00} differ. Correct the lines or the bill amount before posting.");
        var warns = await GrnWarningsAsync(companyId, branchId, id);
        if (warns.Count > 0 && !acceptWarnings) return (null, "Tick 'I have checked the warnings' to post: " + string.Join(" ", warns));
        return await PostAsync("dbo.usp_PhGrn_Post", new { GrnId = id, UserId = userId });
    }

    // ── purchase return ──────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhBatchPick>> BatchSearchAsync(int companyId, int branchId, string q, int? supplierId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhBatchPick>(@"SELECT TOP 25 b.BatchId, b.ItemId, i.ItemName, df.ShortName FormShort, b.BatchNo, b.ExpiryDate, b.Mrp,
                b.PurchaseRate / i.ConversionQty RatePerUnit, b.GstPercent, s.QtyOnHand Stock, su.UomCode SaleUom, i.ConversionQty, sp.SupplierName
            FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
            LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
            LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
            WHERE s.BranchId = @branchId AND b.CompanyId = @companyId AND s.QtyOnHand > 0
              AND (i.ItemName LIKE @like OR b.BatchNo LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @q OR i.Barcode = @q)
            ORDER BY CASE WHEN b.SupplierId = @supplierId THEN 0 ELSE 1 END, b.ExpiryDate", new { companyId, branchId, q, like = "%" + q + "%", supplierId })).ToList();
    }

    public async Task<(int Id, string? Error)> SaveReturnAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.BatchId > 0).ToList();
        if (d.SupplierId is null or 0) return (0, "Pick the supplier.");
        if (d.ReasonId is null or 0) return (0, "Pick the reason for the return.");
        if (lines.Count == 0) return (0, "Add at least one batch.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every batch needs a quantity above zero.");
        if (lines.GroupBy(l => l.BatchId).Any(g => g.Count() > 1)) return (0, "A batch is listed twice.");
        using var con = Open();
        using var tx = con.BeginTransaction();
        // rate and GST always from the batch, quantity checked against stock now (and again when posted)
        var batches = (await con.QueryAsync<(int BatchId, int ItemId, decimal Rate, decimal Gst, decimal Stock)>(@"SELECT b.BatchId, b.ItemId, b.PurchaseRate / i.ConversionQty, b.GstPercent, ISNULL(s.QtyOnHand, 0)
            FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @branchId
            WHERE b.CompanyId = @companyId AND b.BatchId IN @ids", new { companyId, branchId, ids = lines.Select(l => l.BatchId) }, tx)).ToDictionary(b => b.BatchId);
        foreach (var l in lines)
        {
            if (!batches.TryGetValue(l.BatchId!.Value, out var b)) { tx.Rollback(); return (0, "A batch was not found."); }
            if (l.Qty > b.Stock) { tx.Rollback(); return (0, $"Return quantity of a batch ({l.Qty:0.##}) is more than its stock ({b.Stock:0.##})."); }
            l.ItemId = b.ItemId; l.Rate = Math.Round(b.Rate, 4); l.GstPercent = b.Gst;
            l.TaxableAmount = R2(l.Qty * l.Rate); l.GstAmount = R2(l.TaxableAmount * l.GstPercent / 100);
        }
        var taxable = lines.Sum(l => l.TaxableAmount); var gst = lines.Sum(l => l.GstAmount);
        var net = Math.Round(taxable + gst, 0, MidpointRounding.AwayFromZero);
        var args = new { d.Id, companyId, branchId, d.DocDate, d.SupplierId, d.ReasonId, d.IsInterState, d.Remarks, taxable, gst, round = net - taxable - gst, net, userId };
        if (d.Id > 0)
        {
            var st = await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhPurchaseReturn WITH (UPDLOCK) WHERE ReturnId = @Id AND CompanyId = @companyId AND BranchId = @branchId", args, tx);
            if (st != "DRAFT") { tx.Rollback(); return (0, "Only a draft return can be changed."); }
            await con.ExecuteAsync(@"UPDATE dbo.PhPurchaseReturn SET ReturnDate = @DocDate, SupplierId = @SupplierId, ReasonId = @ReasonId, IsInterState = @IsInterState, Remarks = @Remarks,
                TaxableAmount = @taxable, GstAmount = @gst, RoundOff = @round, NetAmount = @net, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE ReturnId = @Id", args, tx);
            await con.ExecuteAsync("DELETE dbo.PhPurchaseReturnDtl WHERE ReturnId = @Id", args, tx);
        }
        else
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhPurchaseReturn (CompanyId, BranchId, ReturnDate, SupplierId, ReasonId, IsInterState, Remarks, TaxableAmount, GstAmount, RoundOff, NetAmount, CreatedBy)
                VALUES (@companyId, @branchId, @DocDate, @SupplierId, @ReasonId, @IsInterState, @Remarks, @taxable, @gst, @round, @net, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", args, tx);
        await con.ExecuteAsync(@"INSERT dbo.PhPurchaseReturnDtl (ReturnId, BatchId, ItemId, Qty, Rate, GstPercent, TaxableAmount, GstAmount) VALUES (@ReturnId, @BatchId, @ItemId, @Qty, @Rate, @GstPercent, @TaxableAmount, @GstAmount)",
            lines.Select(l => new { ReturnId = d.Id, l.BatchId, l.ItemId, l.Qty, l.Rate, l.GstPercent, l.TaxableAmount, l.GstAmount }), tx);
        tx.Commit();
        return (d.Id, null);
    }

    public async Task<(string? DocNo, string? Error)> PostReturnAsync(int companyId, int branchId, int id, int userId)
    {
        using (var con = db.CreateConnection())
            if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhPurchaseReturn WHERE ReturnId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }) == 0)
                return (null, "Return not found.");
        return await PostAsync("dbo.usp_PhPurchaseReturn_Post", new { ReturnId = id, UserId = userId });
    }

    // ── supplier payments ────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhSupplierBalance>> SupplierBalancesAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhSupplierBalance>(@"
            WITH g AS (
                SELECT gr.SupplierId, gr.NetAmount, gr.DueDate,
                       gr.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) Bal
                FROM dbo.PhGrn gr WHERE gr.CompanyId = @companyId AND gr.BranchId = @branchId AND gr.Status = 'POSTED')
            SELECT s.SupplierId, s.SupplierName,
                   ISNULL((SELECT SUM(NetAmount) FROM g WHERE g.SupplierId = s.SupplierId), 0) Purchases,
                   ISNULL((SELECT SUM(NetAmount) FROM dbo.PhPurchaseReturn r WHERE r.SupplierId = s.SupplierId AND r.BranchId = @branchId AND r.Status = 'POSTED'), 0) Returns,
                   ISNULL((SELECT SUM(Amount) FROM dbo.PhSupplierPayment p WHERE p.SupplierId = s.SupplierId AND p.BranchId = @branchId AND p.Status = 'POSTED'), 0) Paid,
                   ISNULL((SELECT SUM(Bal) FROM g WHERE g.SupplierId = s.SupplierId AND g.DueDate < CAST(GETDATE() AS DATE) AND g.Bal > 0), 0) Overdue,
                   (SELECT COUNT(*) FROM g WHERE g.SupplierId = s.SupplierId AND g.Bal > 0) OpenBills
            FROM dbo.PhSupplier s
            WHERE s.CompanyId = @companyId AND EXISTS (SELECT 1 FROM g WHERE g.SupplierId = s.SupplierId)
            ORDER BY s.SupplierName", new { companyId, branchId })).ToList();
    }

    public async Task<List<PhPayable>> PayablesAsync(int companyId, int branchId, int supplierId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhPayable>(@"SELECT gr.GrnId, gr.GrnNo, gr.InvoiceNo, gr.InvoiceDate, gr.DueDate, gr.NetAmount,
                ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0) Paid
            FROM dbo.PhGrn gr WHERE gr.CompanyId = @companyId AND gr.BranchId = @branchId AND gr.SupplierId = @supplierId AND gr.Status = 'POSTED'
            ORDER BY ISNULL(gr.DueDate, gr.InvoiceDate), gr.GrnId", new { companyId, branchId, supplierId })).Where(p => p.Balance > 0).ToList();
    }

    public async Task<(int Id, string? Error)> SavePaymentAsync(int companyId, int branchId, int supplierId, DateTime date, string mode, string? reference, string? remarks, Dictionary<int, decimal> alloc, int userId)
    {
        alloc = alloc.Where(a => a.Value > 0).ToDictionary(a => a.Key, a => R2(a.Value));
        if (alloc.Count == 0) return (0, "Enter the amount paid against at least one bill.");
        if (mode is not ("CASH" or "CHEQUE" or "NEFT" or "UPI" or "CARD")) return (0, "Pick the payment mode.");
        if (mode != "CASH" && string.IsNullOrWhiteSpace(reference)) return (0, "Enter the cheque / transaction reference.");
        if (date > DateTime.Today) return (0, "Payment date cannot be in the future.");
        using var con = Open();
        using var tx = con.BeginTransaction(IsolationLevel.Serializable);
        var bills = (await con.QueryAsync<(int GrnId, decimal Bal)>(@"SELECT gr.GrnId, gr.NetAmount - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment p ON p.PaymentId = a.PaymentId
                WHERE a.GrnId = gr.GrnId AND p.Status = 'POSTED'), 0)
            FROM dbo.PhGrn gr WITH (UPDLOCK) WHERE gr.CompanyId = @companyId AND gr.BranchId = @branchId AND gr.SupplierId = @supplierId AND gr.Status = 'POSTED' AND gr.GrnId IN @ids",
            new { companyId, branchId, supplierId, ids = alloc.Keys }, tx)).ToDictionary(b => b.GrnId, b => b.Bal);
        foreach (var a in alloc)
            if (!bills.TryGetValue(a.Key, out var bal) || a.Value > bal) { tx.Rollback(); return (0, "An amount is more than the bill's balance."); }
        var no = await NextNumberAsync(con, tx, branchId, "SPAY", date);
        var id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhSupplierPayment (CompanyId, BranchId, PaymentNo, PaymentDate, SupplierId, PaymentMode, ReferenceNo, Amount, Remarks, CreatedBy)
            VALUES (@companyId, @branchId, @no, @date, @supplierId, @mode, @reference, @amount, @remarks, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new { companyId, branchId, no, date, supplierId, mode, reference = reference?.Trim(), amount = alloc.Values.Sum(), remarks, userId }, tx);
        await con.ExecuteAsync("INSERT dbo.PhSupplierPaymentAlloc (PaymentId, GrnId, Amount) VALUES (@id, @GrnId, @Amount)", alloc.Select(a => new { id, GrnId = a.Key, Amount = a.Value }), tx);
        try { await con.ExecuteAsync("dbo.usp_Ph_PostLedger", new { Kind = "SPAY", RefId = id, UserId = userId }, tx, commandType: CommandType.StoredProcedure); }   // Payment voucher (SQLScripts/2347)
        catch (SqlException ex) when (ex.Number is >= 51000 and < 54000) { tx.Rollback(); return (0, "Not saved - accounts: " + ex.Message); }
        tx.Commit();
        return (id, null);
    }

    public async Task<string?> CancelPaymentAsync(int companyId, int branchId, int id, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        var n = await con.ExecuteAsync("UPDATE dbo.PhSupplierPayment SET Status = 'CANCELLED' WHERE PaymentId = @id AND CompanyId = @companyId AND BranchId = @branchId AND Status = 'POSTED'", new { id, companyId, branchId }, tx);
        if (n == 0) { tx.Rollback(); return "Payment not found or already cancelled."; }
        try { await con.ExecuteAsync("dbo.usp_Ph_PostLedger", new { Kind = "SPAYX", RefId = id, UserId = userId }, tx, commandType: CommandType.StoredProcedure); }   // reverses the Payment voucher
        catch (SqlException ex) when (ex.Number is >= 51000 and < 54000) { tx.Rollback(); return "Not cancelled - accounts: " + ex.Message; }
        tx.Commit();
        return null;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────
    private IDbConnection Open()
    {
        var con = db.CreateConnection();
        con.Open();
        return con;
    }

    private static async Task<string> NextNumberAsync(IDbConnection con, IDbTransaction tx, int branchId, string docType, DateTime date)
    {
        var p = new DynamicParameters(new { BranchId = branchId, DocType = docType, DocDate = date.Date });
        p.Add("DocNo", dbType: DbType.String, size: 40, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Ph_NextNumber", p, tx, commandType: CommandType.StoredProcedure);
        return p.Get<string>("DocNo");
    }

    private async Task<(string? DocNo, string? Error)> PostAsync(string proc, object args)
    {
        try
        {
            using var con = db.CreateConnection();
            return (await con.ExecuteScalarAsync<string>(proc, args, commandType: CommandType.StoredProcedure), null);
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 54000) { return (null, ex.Message); }   // 53xxx: accounts (books locked, ledger missing)
    }
}
