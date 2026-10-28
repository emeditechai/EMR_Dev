using System.Data;
using Dapper;
using EMR.Web.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services;

// Pharmacy > Inventory (SQLScripts/2349): stock enquiry, branch indent & transfer, stock adjustment, expiry / damage write-off,
// physical stock verification, batch correction and the dashboard. Stock moves only through usp_PhStock_Move; approvals are
// maker-checker (Approval Matrix module, else the page's APPROVE control; never the maker); books by usp_Ph_PostInventoryLedger.

public class PhStockRow
{
    public int BatchId { get; set; }
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string? CategoryName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string? RackNo { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public decimal Mrp { get; set; }               // per pack
    public decimal LandedCost { get; set; }        // per sale unit
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }             // sale units
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool IsBlocked { get; set; }
    public string? SupplierName { get; set; }
    public decimal CostValue => Math.Round(Stock * LandedCost, 2);
    public decimal MrpValue => ConversionQty == 0 ? 0 : Math.Round(Stock * Mrp / ConversionQty, 2);
    public int DaysToExpiry => (ExpiryDate - DateTime.Today).Days;
}

public class PhLedgerRow
{
    public DateTime TxnDate { get; set; }
    public string DocType { get; set; } = "";
    public string? DocNo { get; set; }
    public string BatchNo { get; set; } = "";
    public decimal QtyIn { get; set; }
    public decimal QtyOut { get; set; }
    public decimal BalanceAfter { get; set; }
    public decimal UnitCost { get; set; }
    public string? UserName { get; set; }
}

public class PhInvDocRow
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; }
    public string Status { get; set; } = "";
    public string? Party { get; set; }             // transfer: the other branch; adjustment: reason
    public string? Ref { get; set; }
    public int Lines { get; set; }
    public decimal Value { get; set; }
    public string? CreatedByName { get; set; }
    public int CreatedBy { get; set; }
    public string? Direction { get; set; }         // transfer: IN / OUT
}

public class PhInvLine
{
    public int LineId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? ItemCode { get; set; }
    public string? FormShort { get; set; }
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; } = 1;
    public int? BatchId { get; set; }
    public string? BatchNo { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal Qty { get; set; }               // adjustment: change (+/-); transfer: request
    public decimal DispatchQty { get; set; }
    public decimal? ReceivedQty { get; set; }
    public decimal UnitCost { get; set; }
    public decimal Stock { get; set; }             // now, at the branch that acts
    public string? RackNo { get; set; }
    public string? Remarks { get; set; }
    public decimal SystemQty { get; set; }         // physical count snapshot
    public decimal? CountedQty { get; set; }
}

public class PhInvDoc
{
    public int Id { get; set; }
    public string Kind { get; set; } = "";
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; } = DateTime.Today;
    public string Status { get; set; } = "DRAFT";
    public int? ReasonId { get; set; }
    public string? ReasonName { get; set; }
    public string? Remarks { get; set; }
    public string? ActionRemarks { get; set; }
    public string? DisposalMethod { get; set; }
    public string? DisposalAgency { get; set; }
    public DateTime? DisposalDate { get; set; }
    public string? Witness1 { get; set; }
    public string? Witness2 { get; set; }
    public string? CertificateNo { get; set; }
    public decimal PlusValue { get; set; }
    public decimal MinusValue { get; set; }
    // transfer
    public int FromBranchId { get; set; }
    public int ToBranchId { get; set; }
    public string? FromBranch { get; set; }
    public string? ToBranch { get; set; }
    public string? TransferNo { get; set; }
    public DateTime? DispatchDate { get; set; }
    public DateTime? ReceiveDate { get; set; }
    public string? Priority { get; set; }
    public bool IsOtherGstin { get; set; }
    public string? DispatchRemarks { get; set; }
    public string? ReceiveRemarks { get; set; }
    public decimal CostValue { get; set; }
    public decimal VarianceValue { get; set; }
    // physical count
    public string? Scope { get; set; }
    public DateTime? FrozenAt { get; set; }
    public int? AdjustmentId { get; set; }
    public int CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public List<PhInvLine> Lines { get; set; } = [];
}

public class PhBatchCorrectionRow
{
    public int CorrectionId { get; set; }
    public string DocNo { get; set; } = "";
    public DateTime CreatedDate { get; set; }
    public string ItemName { get; set; } = "";
    public string OldBatchNo { get; set; } = ""; public string NewBatchNo { get; set; } = "";
    public DateTime OldExpiry { get; set; } public DateTime NewExpiry { get; set; }
    public decimal OldMrp { get; set; } public decimal NewMrp { get; set; }
    public string Reason { get; set; } = "";
    public string Status { get; set; } = "";
    public string? ActionRemarks { get; set; }
    public int CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public string? ApprovedByName { get; set; }
}

public class PhDashboard
{
    public decimal SalesToday { get; set; } public int BillsToday { get; set; } public decimal ReturnsToday { get; set; }
    public decimal CashToday { get; set; } public decimal NonCashToday { get; set; } public decimal CreditToday { get; set; }
    public decimal SalesMonth { get; set; } public decimal PurchasesToday { get; set; } public decimal PurchasesMonth { get; set; }
    public decimal StockValue { get; set; } public decimal StockMrpValue { get; set; } public int ItemsInStock { get; set; }
    public int Expired { get; set; } public decimal ExpiredValue { get; set; }
    public int Exp30 { get; set; } public decimal Exp30Value { get; set; } public int Exp60 { get; set; } public decimal Exp60Value { get; set; } public int Exp90 { get; set; } public decimal Exp90Value { get; set; }
    public int BelowReorder { get; set; } public int OutOfStock { get; set; }
    public decimal CreditDue { get; set; } public decimal SupplierDue { get; set; }
    public int PendIndents { get; set; } public int PendPos { get; set; } public int DraftGrns { get; set; } public int HeldBills { get; set; }
    public int ToDispatch { get; set; } public int ToReceive { get; set; } public int PendAdjust { get; set; } public int PendWriteOff { get; set; }
    public int PendCounts { get; set; } public int PendCorrections { get; set; }
    public List<(string ItemName, decimal Qty, decimal Value)> TopItems { get; set; } = [];
    public List<(DateTime Day, decimal Value)> Last7 { get; set; } = [];
    public List<PhStockRow> NearExpiry { get; set; } = [];
    public List<(string ItemName, decimal Stock, decimal Reorder, string Uom)> Reorder { get; set; } = [];
}

public interface IPharmacyInventoryService
{
    Task<List<PhStockRow>> StockAsync(int companyId, int branchId, string? search, int? categoryId, string filter);
    Task<List<PhLedgerRow>> LedgerAsync(int companyId, int branchId, int itemId, int? batchId);
    Task<List<PhStockRow>> BatchSearchAsync(int companyId, int branchId, string q, bool expiredOnly = false);
    Task<List<PhOption>> OtherBranchesAsync(int companyId, int branchId);

    Task<List<PhInvDocRow>> TransfersAsync(int companyId, int branchId, string dir, string? status);
    Task<PhInvDoc?> GetTransferAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> SaveTransferRequestAsync(int companyId, int branchId, PhInvDoc d, bool submit, int userId);
    Task<string?> DispatchAsync(int companyId, int branchId, int id, List<PhInvLine> lines, string? remarks, int userId);
    Task<string?> ReceiveAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId);
    Task<string?> CancelTransferAsync(int companyId, int branchId, int id, int userId);

    Task<List<PhInvDocRow>> AdjustmentsAsync(int companyId, int branchId, string kind, string? status);
    Task<PhInvDoc?> GetAdjustmentAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> SaveAdjustmentAsync(int companyId, int branchId, PhInvDoc d, int userId);
    Task<string?> AdjustmentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhInvDocRow>> CountsAsync(int companyId, int branchId);
    Task<PhInvDoc?> GetCountAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> CreateCountAsync(int companyId, int branchId, string? rackPrefix, int? categoryId, bool includeZero, string? remarks, int userId);
    Task<string?> SaveCountsAsync(int companyId, int branchId, int id, Dictionary<int, decimal?> counts, int userId);
    Task<string?> CountActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhBatchCorrectionRow>> CorrectionsAsync(int companyId, int branchId, string? status);
    Task<(int Id, string? Error)> SaveCorrectionAsync(int companyId, int branchId, int batchId, string newBatchNo, DateTime newExpiry, decimal newMrp, string reason, int userId);
    Task<string?> CorrectionActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<int> MakerAsync(string table, int id);
    Task<List<int>> MatrixApproversAsync(int companyId, string moduleCode, int branchId);
    Task<PhDashboard> DashboardAsync(int companyId, int branchId);
}

public class PharmacyInventoryService(IDbConnectionFactory db, IPharmacySaleService sales) : IPharmacyInventoryService
{
    private static decimal R2(decimal v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);
    private IDbConnection Open() { var c = db.CreateConnection(); c.Open(); return c; }
    private const string UserName = "(SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = {0})";

    private static async Task<string> NextNoAsync(IDbConnection con, IDbTransaction tx, int branchId, string docType)
    {
        var p = new DynamicParameters(new { BranchId = branchId, DocType = docType, DocDate = DateTime.Today });
        p.Add("DocNo", dbType: DbType.String, size: 40, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Ph_NextNumber", p, tx, commandType: CommandType.StoredProcedure);
        return p.Get<string>("DocNo");
    }

    private static Task MoveAsync(IDbConnection con, IDbTransaction tx, int branchId, int batchId, decimal qty, string docType, int docId, string? docNo, int userId) =>
        con.ExecuteAsync("dbo.usp_PhStock_Move", new { BranchId = branchId, BatchId = batchId, Qty = qty, DocType = docType, DocId = docId, DocNo = docNo, UserId = userId, AllowNegative = false },
            tx, commandType: CommandType.StoredProcedure);

    // ── stock enquiry ───────────────────────────────────────────────────────────────────────────────────
    private const string StockSelect = @"
        SELECT b.BatchId, i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, g.GenericName, m.ManufacturerName, c.CategoryName, i.ScheduleCode, ib.RackNo,
               b.BatchNo, b.ExpiryDate, b.Mrp, b.LandedCost, b.GstPercent, ISNULL(s.QtyOnHand, 0) Stock, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty, b.IsBlocked, sp.SupplierName
        FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId
        LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @branchId
        JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
        LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
        LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhSupplier sp ON sp.SupplierId = b.SupplierId
        LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
        WHERE b.CompanyId = @companyId";

    public async Task<List<PhStockRow>> StockAsync(int companyId, int branchId, string? search, int? categoryId, string filter)
    {
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        var where = filter switch
        {
            "expired" => " AND s.QtyOnHand > 0 AND b.ExpiryDate <= CAST(GETDATE() AS DATE)",
            "near" => " AND s.QtyOnHand > 0 AND b.ExpiryDate > CAST(GETDATE() AS DATE) AND b.ExpiryDate <= DATEADD(DAY, 90, CAST(GETDATE() AS DATE))",
            "zero" => " AND ISNULL(s.QtyOnHand, 0) = 0 AND s.BatchId IS NOT NULL",
            "all" => " AND s.BatchId IS NOT NULL",
            _ => " AND s.QtyOnHand > 0"
        };
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhStockRow>(StockSelect + where + @"
              AND (@search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @search OR b.BatchNo LIKE @like OR g.GenericName LIKE @like OR i.Barcode = @search)
              AND (@categoryId IS NULL OR i.CategoryId = @categoryId OR c.ParentCategoryId = @categoryId)
            ORDER BY i.ItemName, b.ExpiryDate", new { companyId, branchId, search, like = "%" + search + "%", categoryId })).ToList();
    }

    public async Task<List<PhLedgerRow>> LedgerAsync(int companyId, int branchId, int itemId, int? batchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhLedgerRow>($@"SELECT TOP 500 l.TxnDate, l.DocType, l.DocNo, b.BatchNo, l.QtyIn, l.QtyOut, l.BalanceAfter, l.UnitCost, {string.Format(UserName, "l.CreatedBy")} UserName
            FROM dbo.PhStockLedger l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
            WHERE l.BranchId = @branchId AND l.ItemId = @itemId AND b.CompanyId = @companyId AND (@batchId IS NULL OR l.BatchId = @batchId)
            ORDER BY l.LedgerId DESC", new { companyId, branchId, itemId, batchId })).ToList();
    }

    public async Task<List<PhStockRow>> BatchSearchAsync(int companyId, int branchId, string q, bool expiredOnly = false)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhStockRow>("SELECT TOP 30 * FROM (" + StockSelect + @" AND s.QtyOnHand > 0
              AND (i.ItemName LIKE @like OR i.ItemCode = @q OR b.BatchNo LIKE @like OR i.Barcode = @q)
              AND (@expiredOnly = 0 OR b.ExpiryDate <= DATEADD(DAY, 90, CAST(GETDATE() AS DATE)))) x ORDER BY x.ItemName, x.ExpiryDate",
            new { companyId, branchId, q, like = "%" + q + "%", expiredOnly })).ToList();
    }

    public async Task<List<PhOption>> OtherBranchesAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhOption>(@"SELECT CAST(b.BranchID AS VARCHAR(10)) Value, b.BranchName + N' (' + b.BranchCode + N')' Text FROM dbo.Branchmaster b
            WHERE b.CompanyId = @companyId AND b.IsActive = 1 AND b.BranchID <> @branchId
              AND EXISTS (SELECT 1 FROM dbo.HospitalSettings h WHERE h.BranchId = b.BranchID AND h.PharmacyEnabled = 1) ORDER BY b.BranchName", new { companyId, branchId })).ToList();
    }

    // ── branch indent & transfer ────────────────────────────────────────────────────────────────────────
    public async Task<List<PhInvDocRow>> TransfersAsync(int companyId, int branchId, string dir, string? status)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhInvDocRow>($@"SELECT TOP 500 t.TransferId Id, COALESCE(t.TransferNo, t.RequestNo) DocNo, COALESCE(t.DispatchDate, t.RequestDate, t.CreatedDate) DocDate, t.Status,
                CASE WHEN t.ToBranchId = @branchId THEN fb.BranchName ELSE tb.BranchName END Party, t.RequestNo Ref,
                (SELECT COUNT(DISTINCT d.ItemId) FROM dbo.PhTransferDtl d WHERE d.TransferId = t.TransferId) Lines, t.CostValue Value,
                {string.Format(UserName, "t.CreatedBy")} CreatedByName, CASE WHEN t.ToBranchId = @branchId THEN 'IN' ELSE 'OUT' END Direction
            FROM dbo.PhTransfer t JOIN dbo.Branchmaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.Branchmaster tb ON tb.BranchID = t.ToBranchId
            WHERE t.CompanyId = @companyId AND ((@dir IN ('ALL', 'IN') AND t.ToBranchId = @branchId) OR (@dir IN ('ALL', 'OUT') AND t.FromBranchId = @branchId AND t.Status <> 'DRAFT'))
              AND (@status IS NULL OR t.Status = @status)
            ORDER BY t.TransferId DESC", new { companyId, branchId, dir, status })).ToList();
    }

    public async Task<PhInvDoc?> GetTransferAsync(int companyId, int branchId, int id)
    {
        using var con = db.CreateConnection();
        var d = await con.QuerySingleOrDefaultAsync<PhInvDoc>($@"SELECT t.TransferId Id, 'TRANSFER' Kind, t.RequestNo DocNo, ISNULL(t.RequestDate, t.CreatedDate) DocDate, t.Status, t.Remarks, t.FromBranchId, t.ToBranchId,
                fb.BranchName FromBranch, tb.BranchName ToBranch, t.TransferNo, t.DispatchDate, t.ReceiveDate, t.Priority, t.IsOtherGstin, t.DispatchRemarks, t.ReceiveRemarks, t.CostValue, t.VarianceValue,
                t.CreatedBy, {string.Format(UserName, "t.CreatedBy")} CreatedByName, t.CreatedDate
            FROM dbo.PhTransfer t JOIN dbo.Branchmaster fb ON fb.BranchID = t.FromBranchId JOIN dbo.Branchmaster tb ON tb.BranchID = t.ToBranchId
            WHERE t.TransferId = @id AND t.CompanyId = @companyId AND (t.ToBranchId = @branchId OR (t.FromBranchId = @branchId AND t.Status <> 'DRAFT'))", new { id, companyId, branchId });
        if (d == null) return null;
        d.Lines = (await con.QueryAsync<PhInvLine>(@"SELECT x.TransferDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
                x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RequestQty Qty, x.DispatchQty, x.ReceivedQty, x.UnitCost, x.VarianceReason Remarks,
                ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @from AND s.ItemId = x.ItemId), 0) Stock
            FROM dbo.PhTransferDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
            LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
            WHERE x.TransferId = @id ORDER BY i.ItemName, b.ExpiryDate", new { id, from = d.FromBranchId })).ToList();
        return d;
    }

    public async Task<(int Id, string? Error)> SaveTransferRequestAsync(int companyId, int branchId, PhInvDoc d, bool submit, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (d.FromBranchId <= 0 || d.FromBranchId == branchId) return (0, "Pick the branch to ask from.");
        if (lines.Count == 0) return (0, "Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every item needs a quantity.");
        if (lines.GroupBy(l => l.ItemId).Any(g => g.Count() > 1)) return (0, "An item is listed twice.");
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.Branchmaster WHERE BranchID = @f AND CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @b)", new { f = d.FromBranchId, b = branchId }, tx) == 0)
        { tx.Rollback(); return (0, "That branch is not of this company."); }
        var otherGstin = await con.ExecuteScalarAsync<bool>(@"SELECT CAST(CASE WHEN ISNULL(NULLIF(a.G, ''), '#') <> ISNULL(NULLIF(b.G, ''), '#') THEN 1 ELSE 0 END AS BIT) FROM
            (SELECT TOP 1 ISNULL(NULLIF(PharmacyGstin, ''), GSTCode) G FROM dbo.HospitalSettings WHERE BranchId = @b ORDER BY IsActive DESC) a CROSS JOIN
            (SELECT TOP 1 ISNULL(NULLIF(PharmacyGstin, ''), GSTCode) G FROM dbo.HospitalSettings WHERE BranchId = @f ORDER BY IsActive DESC) b", new { b = branchId, f = d.FromBranchId }, tx);
        var args = new { d.Id, companyId, branchId, d.FromBranchId, Priority = d.Priority == "URGENT" ? "URGENT" : "NORMAL", d.Remarks, otherGstin, userId };
        if (d.Id > 0)
        {
            if (await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @Id AND ToBranchId = @branchId", args, tx) != "DRAFT") { tx.Rollback(); return (0, "Only a draft indent can be changed."); }
            await con.ExecuteAsync("UPDATE dbo.PhTransfer SET FromBranchId = @FromBranchId, Priority = @Priority, Remarks = @Remarks, IsOtherGstin = @otherGstin WHERE TransferId = @Id; DELETE dbo.PhTransferDtl WHERE TransferId = @Id;", args, tx);
        }
        else
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhTransfer (CompanyId, ToBranchId, FromBranchId, Priority, Remarks, IsOtherGstin, CreatedBy) VALUES (@companyId, @branchId, @FromBranchId, @Priority, @Remarks, @otherGstin, @userId);
                SELECT CAST(SCOPE_IDENTITY() AS INT);", args, tx);
        await con.ExecuteAsync("INSERT dbo.PhTransferDtl (TransferId, ItemId, RequestQty) SELECT @TransferId, ItemId, @Qty FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @companyId",
            lines.Select(l => new { TransferId = d.Id, l.ItemId, l.Qty, companyId }), tx);
        if (submit)
        {
            var no = await NextNoAsync(con, tx, branchId, "BIND");
            await con.ExecuteAsync("UPDATE dbo.PhTransfer SET Status = 'REQUESTED', RequestNo = @no, RequestDate = GETDATE() WHERE TransferId = @Id", new { d.Id, no }, tx);
        }
        tx.Commit();
        return (d.Id, null);
    }

    public async Task<string?> DispatchAsync(int companyId, int branchId, int id, List<PhInvLine> lines, string? remarks, int userId)
    {
        lines = lines.Where(l => l.BatchId > 0 && l.DispatchQty > 0).ToList();
        if (lines.Count == 0) return "Pick the batches and quantities to send.";
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var t = await con.QuerySingleOrDefaultAsync<(string Status, int From)>("SELECT Status, FromBranchId FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @id AND CompanyId = @companyId", new { id, companyId }, tx);
            if (t.Status != "REQUESTED" || t.From != branchId) { tx.Rollback(); return "Only an indent asked of this branch, not yet sent, can be dispatched."; }
            var req = (await con.QueryAsync<(int ItemId, decimal Qty)>("SELECT ItemId, SUM(RequestQty) FROM dbo.PhTransferDtl WHERE TransferId = @id GROUP BY ItemId", new { id }, tx)).ToDictionary(x => x.ItemId, x => x.Qty);
            var batches = (await con.QueryAsync<(int BatchId, int ItemId, decimal Cost, DateTime Exp, bool Blocked)>("SELECT BatchId, ItemId, LandedCost, ExpiryDate, IsBlocked FROM dbo.PhBatch WHERE CompanyId = @companyId AND BatchId IN @ids",
                new { companyId, ids = lines.Select(l => l.BatchId) }, tx)).ToDictionary(b => b.BatchId);
            foreach (var l in lines)
            {
                if (!batches.TryGetValue(l.BatchId!.Value, out var b) || !req.ContainsKey(b.ItemId)) { tx.Rollback(); return "A batch is not of an item on this indent."; }
                if (b.Blocked || b.Exp <= DateTime.Today) { tx.Rollback(); return "An expired or blocked batch cannot be sent."; }
                l.ItemId = b.ItemId; l.UnitCost = b.Cost;
            }
            foreach (var g in lines.GroupBy(l => l.ItemId))
                if (g.Sum(l => l.DispatchQty) > req[g.Key]) { tx.Rollback(); return "More is being sent than was asked for."; }
            var no = await NextNoAsync(con, tx, branchId, "TRF");
            // the request lines stay (one per item); the batches sent are added
            await con.ExecuteAsync("DELETE dbo.PhTransferDtl WHERE TransferId = @id AND RequestQty = 0", new { id }, tx);
            foreach (var l in lines)
            {
                await con.ExecuteAsync(@"INSERT dbo.PhTransferDtl (TransferId, ItemId, RequestQty, BatchId, DispatchQty, UnitCost) VALUES (@id, @ItemId, 0, @BatchId, @DispatchQty, @UnitCost)",
                    new { id, l.ItemId, l.BatchId, l.DispatchQty, l.UnitCost }, tx);
                await MoveAsync(con, tx, branchId, l.BatchId!.Value, -l.DispatchQty, "TRFO", id, no, userId);
            }
            await con.ExecuteAsync(@"UPDATE dbo.PhTransfer SET Status = 'DISPATCHED', TransferNo = @no, DispatchDate = GETDATE(), DispatchedBy = @userId, DispatchRemarks = @remarks, CostValue = @cost WHERE TransferId = @id",
                new { id, no, userId, remarks, cost = R2(lines.Sum(l => l.DispatchQty * l.UnitCost)) }, tx);
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return ex.Message; }
    }

    public async Task<string?> ReceiveAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var t = await con.QuerySingleOrDefaultAsync<(string Status, int To, string No)>("SELECT Status, ToBranchId, TransferNo FROM dbo.PhTransfer WITH (UPDLOCK) WHERE TransferId = @id AND CompanyId = @companyId", new { id, companyId }, tx);
            if (t.Status != "DISPATCHED" || t.To != branchId) { tx.Rollback(); return "Only a transfer sent to this branch can be received."; }
            var sent = (await con.QueryAsync<(int DtlId, int BatchId, decimal Qty, decimal Cost)>("SELECT TransferDtlId, BatchId, DispatchQty, UnitCost FROM dbo.PhTransferDtl WHERE TransferId = @id AND DispatchQty > 0", new { id }, tx)).ToList();
            decimal variance = 0;
            foreach (var s in sent)
            {
                var got = received.TryGetValue(s.DtlId, out var g) ? g : s.Qty;
                if (got < 0 || got > s.Qty) { tx.Rollback(); return "Received quantity cannot be more than what was sent."; }
                var why = reasons.TryGetValue(s.DtlId, out var w) ? w?.Trim() : null;
                if (got < s.Qty && string.IsNullOrWhiteSpace(why)) { tx.Rollback(); return "Give the reason for every quantity received short (broken, missing ...)."; }
                await con.ExecuteAsync("UPDATE dbo.PhTransferDtl SET ReceivedQty = @got, VarianceReason = @why WHERE TransferDtlId = @DtlId", new { got, why, s.DtlId }, tx);
                if (got > 0) await MoveAsync(con, tx, branchId, s.BatchId, got, "TRFI", id, t.No, userId);
                variance += (s.Qty - got) * s.Cost;
            }
            await con.ExecuteAsync("UPDATE dbo.PhTransfer SET Status = 'RECEIVED', ReceiveDate = GETDATE(), ReceivedBy = @userId, ReceiveRemarks = @remarks, VarianceValue = @v WHERE TransferId = @id",
                new { id, userId, remarks, v = R2(variance) }, tx);
            await con.ExecuteAsync("dbo.usp_Ph_PostInventoryLedger", new { Kind = "TRFLOSS", RefId = id, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return ex.Message; }
    }

    public async Task<string?> CancelTransferAsync(int companyId, int branchId, int id, int userId)
    {
        using var con = db.CreateConnection();
        var n = await con.ExecuteAsync(@"UPDATE dbo.PhTransfer SET Status = 'CANCELLED', CancelledBy = @userId, CancelledDate = GETDATE()
            WHERE TransferId = @id AND CompanyId = @companyId AND Status IN ('DRAFT', 'REQUESTED') AND (ToBranchId = @branchId OR FromBranchId = @branchId)", new { id, companyId, branchId, userId });
        return n == 0 ? "Only an indent not yet sent can be cancelled." : null;
    }

    // ── adjustment / write-off ──────────────────────────────────────────────────────────────────────────
    public async Task<List<PhInvDocRow>> AdjustmentsAsync(int companyId, int branchId, string kind, string? status)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhInvDocRow>($@"SELECT TOP 500 a.AdjustmentId Id, a.DocNo, a.DocDate, a.Status, r.ReasonName Party, a.Remarks Ref,
                (SELECT COUNT(*) FROM dbo.PhAdjustmentDtl d WHERE d.AdjustmentId = a.AdjustmentId) Lines,
                ISNULL((SELECT SUM(d.QtyChange * d.UnitCost) FROM dbo.PhAdjustmentDtl d WHERE d.AdjustmentId = a.AdjustmentId), 0) Value,
                a.CreatedBy, {string.Format(UserName, "a.CreatedBy")} CreatedByName
            FROM dbo.PhAdjustment a LEFT JOIN dbo.PhReason r ON r.ReasonId = a.ReasonId
            WHERE a.CompanyId = @companyId AND a.BranchId = @branchId AND a.Kind = @kind AND (@status IS NULL OR a.Status = @status) ORDER BY a.AdjustmentId DESC", new { companyId, branchId, kind, status })).ToList();
    }

    public async Task<PhInvDoc?> GetAdjustmentAsync(int companyId, int branchId, int id)
    {
        using var con = db.CreateConnection();
        var d = await con.QuerySingleOrDefaultAsync<PhInvDoc>($@"SELECT a.AdjustmentId Id, a.Kind, a.DocNo, a.DocDate, a.Status, a.ReasonId, r.ReasonName, a.Remarks, a.ActionRemarks, a.DisposalMethod, a.DisposalAgency,
                a.DisposalDate, a.Witness1, a.Witness2, a.CertificateNo, a.PlusValue, a.MinusValue, a.CreatedBy, {string.Format(UserName, "a.CreatedBy")} CreatedByName, a.CreatedDate,
                {string.Format(UserName, "a.ApprovedBy")} ApprovedByName, a.ApprovedDate
            FROM dbo.PhAdjustment a LEFT JOIN dbo.PhReason r ON r.ReasonId = a.ReasonId WHERE a.AdjustmentId = @id AND a.CompanyId = @companyId AND a.BranchId = @branchId", new { id, companyId, branchId });
        if (d == null) return null;
        d.Lines = (await con.QueryAsync<PhInvLine>(@"SELECT x.AdjustmentDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
                x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.QtyChange Qty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
            FROM dbo.PhAdjustmentDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
            JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
            LEFT JOIN dbo.PhStock s ON s.BatchId = x.BatchId AND s.BranchId = @branchId WHERE x.AdjustmentId = @id ORDER BY x.AdjustmentDtlId", new { id, branchId })).ToList();
        return d;
    }

    public async Task<(int Id, string? Error)> SaveAdjustmentAsync(int companyId, int branchId, PhInvDoc d, int userId)
    {
        var writeOff = d.Kind == "WRITEOFF";
        var lines = d.Lines.Where(l => l.BatchId > 0 && l.Qty != 0).ToList();
        if (d.ReasonId is null or 0) return (0, "Pick the reason.");
        if (lines.Count == 0) return (0, "Add at least one batch with a quantity.");
        if (lines.GroupBy(l => l.BatchId).Any(g => g.Count() > 1)) return (0, "A batch is listed twice.");
        if (writeOff) lines.ForEach(l => l.Qty = -Math.Abs(l.Qty));   // a write-off only takes stock out
        using var con = Open();
        using var tx = con.BeginTransaction();
        var batches = (await con.QueryAsync<(int BatchId, int ItemId, decimal Cost, decimal Stock)>(@"SELECT b.BatchId, b.ItemId, b.LandedCost, ISNULL(s.QtyOnHand, 0) FROM dbo.PhBatch b
            LEFT JOIN dbo.PhStock s ON s.BatchId = b.BatchId AND s.BranchId = @branchId WHERE b.CompanyId = @companyId AND b.BatchId IN @ids", new { companyId, branchId, ids = lines.Select(l => l.BatchId) }, tx)).ToDictionary(b => b.BatchId);
        foreach (var l in lines)
        {
            if (!batches.TryGetValue(l.BatchId!.Value, out var b)) { tx.Rollback(); return (0, "A batch was not found."); }
            if (l.Qty < 0 && -l.Qty > b.Stock) { tx.Rollback(); return (0, $"A batch has only {b.Stock:0.##} in stock; it cannot go below zero."); }
            l.ItemId = b.ItemId; l.UnitCost = b.Cost;
        }
        var args = new { d.Id, companyId, branchId, Kind = writeOff ? "WRITEOFF" : "ADJUST", d.DocDate, d.ReasonId, d.Remarks, d.DisposalMethod, d.DisposalAgency, d.DisposalDate, d.Witness1, d.Witness2, d.CertificateNo, userId };
        if (d.Id > 0)
        {
            if (await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @Id AND CompanyId = @companyId AND BranchId = @branchId AND Kind = @Kind", args, tx) != "DRAFT")
            { tx.Rollback(); return (0, "Only a draft can be changed."); }
            await con.ExecuteAsync(@"UPDATE dbo.PhAdjustment SET DocDate = @DocDate, ReasonId = @ReasonId, Remarks = @Remarks, DisposalMethod = @DisposalMethod, DisposalAgency = @DisposalAgency, DisposalDate = @DisposalDate,
                Witness1 = @Witness1, Witness2 = @Witness2, CertificateNo = @CertificateNo, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE AdjustmentId = @Id; DELETE dbo.PhAdjustmentDtl WHERE AdjustmentId = @Id;", args, tx);
        }
        else
            d.Id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhAdjustment (CompanyId, BranchId, Kind, DocDate, ReasonId, Remarks, DisposalMethod, DisposalAgency, DisposalDate, Witness1, Witness2, CertificateNo, CreatedBy)
                VALUES (@companyId, @branchId, @Kind, @DocDate, @ReasonId, @Remarks, @DisposalMethod, @DisposalAgency, @DisposalDate, @Witness1, @Witness2, @CertificateNo, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", args, tx);
        await con.ExecuteAsync("INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost, Remarks) VALUES (@AdjustmentId, @BatchId, @ItemId, @Qty, @UnitCost, @Remarks)",
            lines.Select(l => new { AdjustmentId = d.Id, l.BatchId, l.ItemId, l.Qty, l.UnitCost, l.Remarks }), tx);
        tx.Commit();
        return (d.Id, null);
    }

    public async Task<string?> AdjustmentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var a = await con.QuerySingleOrDefaultAsync<(string Status, string Kind, int CreatedBy, string? Method, DateTime? Date, string? W1)>(
                "SELECT Status, Kind, CreatedBy, DisposalMethod, DisposalDate, Witness1 FROM dbo.PhAdjustment WITH (UPDLOCK) WHERE AdjustmentId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx);
            if (a.Status == null) { tx.Rollback(); return "Not found."; }
            switch (action)
            {
                case "submit":
                    if (a.Status != "DRAFT") { tx.Rollback(); return "Only a draft can be submitted."; }
                    if (a.Kind == "WRITEOFF" && (string.IsNullOrWhiteSpace(a.Method) || a.Date == null || string.IsNullOrWhiteSpace(a.W1)))
                    { tx.Rollback(); return "Enter how and when the stock is destroyed and at least one witness before submitting."; }
                    var no = await NextNoAsync(con, tx, branchId, a.Kind == "WRITEOFF" ? "WOF" : "ADJ");
                    await con.ExecuteAsync("UPDATE dbo.PhAdjustment SET Status = 'SUBMITTED', DocNo = @no, SubmittedBy = @userId, SubmittedDate = GETDATE() WHERE AdjustmentId = @id", new { id, no, userId }, tx);
                    break;
                case "approve":
                    if (a.Status != "SUBMITTED") { tx.Rollback(); return "Only a submitted document can be approved."; }
                    if (a.CreatedBy == userId) { tx.Rollback(); return "You made this document; another user must approve it."; }
                    var docNo = await con.ExecuteScalarAsync<string>("SELECT DocNo FROM dbo.PhAdjustment WHERE AdjustmentId = @id", new { id }, tx);
                    var lines = await con.QueryAsync<(int BatchId, decimal Qty, decimal Cost)>("SELECT BatchId, QtyChange, UnitCost FROM dbo.PhAdjustmentDtl WHERE AdjustmentId = @id", new { id }, tx);
                    foreach (var l in lines) await MoveAsync(con, tx, branchId, l.BatchId, l.Qty, a.Kind == "WRITEOFF" ? "WOF" : "ADJ", id, docNo, userId);
                    await con.ExecuteAsync(@"UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @userId, ApprovedDate = GETDATE(), ActionRemarks = @remarks,
                        PlusValue = @plus, MinusValue = @minus WHERE AdjustmentId = @id",
                        new { id, userId, remarks, plus = R2(lines.Where(l => l.Qty > 0).Sum(l => l.Qty * l.Cost)), minus = R2(-lines.Where(l => l.Qty < 0).Sum(l => l.Qty * l.Cost)) }, tx);
                    await con.ExecuteAsync("dbo.usp_Ph_PostInventoryLedger", new { Kind = "ADJ", RefId = id, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
                    break;
                case "reject":
                    if (a.Status != "SUBMITTED") { tx.Rollback(); return "Only a submitted document can be rejected."; }
                    if (a.CreatedBy == userId) { tx.Rollback(); return "You made this document; another user must decide on it."; }
                    if (string.IsNullOrWhiteSpace(remarks)) { tx.Rollback(); return "Give the reason for rejecting."; }
                    await con.ExecuteAsync("UPDATE dbo.PhAdjustment SET Status = 'REJECTED', ApprovedBy = @userId, ApprovedDate = GETDATE(), ActionRemarks = @remarks WHERE AdjustmentId = @id", new { id, userId, remarks }, tx);
                    break;
                case "cancel":
                    if (a.Status is not ("DRAFT" or "SUBMITTED")) { tx.Rollback(); return "Only a draft or submitted document can be cancelled."; }
                    await con.ExecuteAsync("UPDATE dbo.PhAdjustment SET Status = 'CANCELLED', ActionRemarks = ISNULL(@remarks, ActionRemarks), ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE AdjustmentId = @id", new { id, userId, remarks }, tx);
                    break;
                default: tx.Rollback(); return "Unknown action.";
            }
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return ex.Message; }
    }

    // ── physical stock verification ─────────────────────────────────────────────────────────────────────
    public async Task<List<PhInvDocRow>> CountsAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhInvDocRow>($@"SELECT TOP 200 c.StockCountId Id, c.CountNo DocNo, c.FrozenAt DocDate, c.Status, c.Scope Party, c.Remarks Ref,
                (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId) Lines,
                ISNULL((SELECT SUM((d.CountedQty - d.SystemQty) * d.UnitCost) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NOT NULL), 0) Value,
                c.CreatedBy, {string.Format(UserName, "c.CreatedBy")} CreatedByName
            FROM dbo.PhStockCount c WHERE c.CompanyId = @companyId AND c.BranchId = @branchId ORDER BY c.StockCountId DESC", new { companyId, branchId })).ToList();
    }

    public async Task<PhInvDoc?> GetCountAsync(int companyId, int branchId, int id)
    {
        using var con = db.CreateConnection();
        var d = await con.QuerySingleOrDefaultAsync<PhInvDoc>($@"SELECT c.StockCountId Id, 'COUNT' Kind, c.CountNo DocNo, c.FrozenAt DocDate, c.FrozenAt, c.Scope, c.Status, c.Remarks, c.ActionRemarks, c.AdjustmentId,
                c.CreatedBy, {string.Format(UserName, "c.CreatedBy")} CreatedByName, c.CreatedDate, {string.Format(UserName, "c.ApprovedBy")} ApprovedByName, c.ApprovedDate
            FROM dbo.PhStockCount c WHERE c.StockCountId = @id AND c.CompanyId = @companyId AND c.BranchId = @branchId", new { id, companyId, branchId });
        if (d == null) return null;
        d.Lines = (await con.QueryAsync<PhInvLine>(@"SELECT x.StockCountDtlId LineId, x.ItemId, i.ItemName, i.ItemCode, df.ShortName FormShort, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
                x.BatchId, b.BatchNo, b.ExpiryDate, b.Mrp, x.RackNo, x.SystemQty, x.CountedQty, x.UnitCost, x.Remarks, ISNULL(s.QtyOnHand, 0) Stock
            FROM dbo.PhStockCountDtl x JOIN dbo.PhItem i ON i.ItemId = x.ItemId JOIN dbo.PhBatch b ON b.BatchId = x.BatchId
            JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
            LEFT JOIN dbo.PhStock s ON s.BatchId = x.BatchId AND s.BranchId = @branchId
            WHERE x.StockCountId = @id ORDER BY ISNULL(x.RackNo, 'zzz'), i.ItemName, b.ExpiryDate", new { id, branchId })).ToList();
        return d;
    }

    public async Task<(int Id, string? Error)> CreateCountAsync(int companyId, int branchId, string? rackPrefix, int? categoryId, bool includeZero, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhStockCount WHERE BranchId = @branchId AND Status IN ('COUNTING', 'SUBMITTED')", new { branchId }, tx) > 0)
        { tx.Rollback(); return (0, "A verification of this branch is still open; finish or cancel it first."); }
        rackPrefix = string.IsNullOrWhiteSpace(rackPrefix) ? null : rackPrefix.Trim().ToUpperInvariant();
        var scope = string.Join(" · ", new[] { rackPrefix != null ? "racks " + rackPrefix + "*" : null,
            categoryId != null ? "category " + await con.ExecuteScalarAsync<string>("SELECT CategoryName FROM dbo.PhCategory WHERE CategoryId = @categoryId", new { categoryId }, tx) : null,
            includeZero ? "including zero stock" : null }.Where(x => x != null));
        var no = await NextNoAsync(con, tx, branchId, "PCNT");
        var id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhStockCount (CompanyId, BranchId, CountNo, FrozenAt, Scope, Status, Remarks, CreatedBy) VALUES (@companyId, @branchId, @no, GETDATE(), @scope, 'COUNTING', @remarks, @userId);
            SELECT CAST(SCOPE_IDENTITY() AS INT);", new { companyId, branchId, no, scope = scope.Length == 0 ? "All stock" : scope, remarks, userId }, tx);
        var n = await con.ExecuteAsync(@"INSERT dbo.PhStockCountDtl (StockCountId, BatchId, ItemId, RackNo, SystemQty, UnitCost)
            SELECT @id, s.BatchId, s.ItemId, ib.RackNo, s.QtyOnHand, b.LandedCost
            FROM dbo.PhStock s WITH (HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = s.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
            LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = s.ItemId AND ib.BranchId = s.BranchId
            WHERE s.BranchId = @branchId AND b.CompanyId = @companyId AND (@includeZero = 1 OR s.QtyOnHand <> 0)
              AND (@rack IS NULL OR ib.RackNo LIKE @rack + '%') AND (@categoryId IS NULL OR i.CategoryId = @categoryId OR c.ParentCategoryId = @categoryId)",
            new { id, branchId, companyId, includeZero, rack = rackPrefix, categoryId }, tx);
        if (n == 0) { tx.Rollback(); return (0, "Nothing in stock matches; widen the selection."); }
        tx.Commit();
        return (id, null);
    }

    public async Task<string?> SaveCountsAsync(int companyId, int branchId, int id, Dictionary<int, decimal?> counts, int userId)
    {
        if (counts.Values.Any(v => v < 0)) return "A count cannot be negative.";
        using var con = Open();
        using var tx = con.BeginTransaction();
        if (await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PhStockCount WITH (UPDLOCK) WHERE StockCountId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx) != "COUNTING")
        { tx.Rollback(); return "Counts can be entered only while the verification is open."; }
        await con.ExecuteAsync("UPDATE dbo.PhStockCountDtl SET CountedQty = @Qty WHERE StockCountDtlId = @Id AND StockCountId = @sid", counts.Select(c => new { Id = c.Key, Qty = c.Value, sid = id }), tx);
        tx.Commit();
        return null;
    }

    public async Task<string?> CountActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        try
        {
            var c = await con.QuerySingleOrDefaultAsync<(string Status, int CreatedBy, string CountNo, int Uncounted)>(@"SELECT Status, CreatedBy, CountNo,
                    (SELECT COUNT(*) FROM dbo.PhStockCountDtl d WHERE d.StockCountId = c.StockCountId AND d.CountedQty IS NULL)
                FROM dbo.PhStockCount c WITH (UPDLOCK) WHERE StockCountId = @id AND CompanyId = @companyId AND BranchId = @branchId", new { id, companyId, branchId }, tx);
            if (c.Status == null) { tx.Rollback(); return "Not found."; }
            switch (action)
            {
                case "submit":
                    if (c.Status != "COUNTING") { tx.Rollback(); return "Only an open verification can be submitted."; }
                    if (c.Uncounted > 0) { tx.Rollback(); return $"{c.Uncounted} batch(es) are not counted yet. Enter a count for every line (0 if none found)."; }
                    await con.ExecuteAsync("UPDATE dbo.PhStockCount SET Status = 'SUBMITTED', SubmittedBy = @userId, SubmittedDate = GETDATE() WHERE StockCountId = @id", new { id, userId }, tx);
                    break;
                case "approve":
                    if (c.Status != "SUBMITTED") { tx.Rollback(); return "Only a submitted verification can be approved."; }
                    if (c.CreatedBy == userId) { tx.Rollback(); return "You started this verification; another user must approve it."; }
                    // the difference found is applied to today's stock (sales after the freeze are kept)
                    var diffs = (await con.QueryAsync<(int BatchId, int ItemId, decimal Diff, decimal Cost)>(@"SELECT BatchId, ItemId, CountedQty - SystemQty, UnitCost FROM dbo.PhStockCountDtl
                        WHERE StockCountId = @id AND CountedQty IS NOT NULL AND CountedQty <> SystemQty", new { id }, tx)).ToList();
                    int? adjId = null;
                    if (diffs.Count > 0)
                    {
                        var reason = await con.ExecuteScalarAsync<int?>("SELECT TOP 1 ReasonId FROM dbo.PhReason WHERE CompanyId = @companyId AND ReasonType = 'ADJUSTMENT' AND ReasonName LIKE '%count%' ORDER BY SortOrder", new { companyId }, tx);
                        adjId = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhAdjustment (CompanyId, BranchId, Kind, DocNo, DocDate, ReasonId, Status, Remarks, StockCountId, CreatedBy, SubmittedBy, SubmittedDate)
                            VALUES (@companyId, @branchId, 'PHYSICAL', @no, CAST(GETDATE() AS DATE), @reason, 'SUBMITTED', @remarks, @id, @maker, @maker, GETDATE()); SELECT CAST(SCOPE_IDENTITY() AS INT);",
                            new { companyId, branchId, no = c.CountNo, reason, remarks = "Physical stock verification " + c.CountNo, id, maker = c.CreatedBy }, tx);
                        await con.ExecuteAsync("INSERT dbo.PhAdjustmentDtl (AdjustmentId, BatchId, ItemId, QtyChange, UnitCost) VALUES (@adjId, @BatchId, @ItemId, @Diff, @Cost)",
                            diffs.Select(d => new { adjId, d.BatchId, d.ItemId, d.Diff, d.Cost }), tx);
                        foreach (var d in diffs) await MoveAsync(con, tx, branchId, d.BatchId, d.Diff, "PCNT", id, c.CountNo, userId);
                        await con.ExecuteAsync(@"UPDATE dbo.PhAdjustment SET Status = 'APPROVED', ApprovedBy = @userId, ApprovedDate = GETDATE(), PlusValue = @plus, MinusValue = @minus WHERE AdjustmentId = @adjId",
                            new { adjId, userId, plus = R2(diffs.Where(d => d.Diff > 0).Sum(d => d.Diff * d.Cost)), minus = R2(-diffs.Where(d => d.Diff < 0).Sum(d => d.Diff * d.Cost)) }, tx);
                        await con.ExecuteAsync("dbo.usp_Ph_PostInventoryLedger", new { Kind = "ADJ", RefId = adjId, UserId = userId }, tx, commandType: CommandType.StoredProcedure);
                    }
                    await con.ExecuteAsync("UPDATE dbo.PhStockCount SET Status = 'APPROVED', ApprovedBy = @userId, ApprovedDate = GETDATE(), ActionRemarks = @remarks, AdjustmentId = @adjId WHERE StockCountId = @id",
                        new { id, userId, remarks, adjId }, tx);
                    break;
                case "reject":
                    if (c.Status != "SUBMITTED") { tx.Rollback(); return "Only a submitted verification can be sent back."; }
                    if (string.IsNullOrWhiteSpace(remarks)) { tx.Rollback(); return "Say what is to be recounted."; }
                    await con.ExecuteAsync("UPDATE dbo.PhStockCount SET Status = 'COUNTING', ActionRemarks = @remarks WHERE StockCountId = @id", new { id, remarks }, tx);
                    break;
                case "cancel":
                    if (c.Status is not ("COUNTING" or "SUBMITTED")) { tx.Rollback(); return "Only an open verification can be cancelled."; }
                    await con.ExecuteAsync("UPDATE dbo.PhStockCount SET Status = 'CANCELLED', ActionRemarks = @remarks WHERE StockCountId = @id", new { id, remarks }, tx);
                    break;
                default: tx.Rollback(); return "Unknown action.";
            }
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 51000 and < 55000) { tx.Rollback(); return ex.Message; }
    }

    // ── batch correction ────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhBatchCorrectionRow>> CorrectionsAsync(int companyId, int branchId, string? status)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhBatchCorrectionRow>($@"SELECT TOP 300 c.CorrectionId, c.DocNo, c.CreatedDate, i.ItemName, c.OldBatchNo, c.NewBatchNo, c.OldExpiry, c.NewExpiry, c.OldMrp, c.NewMrp, c.Reason, c.Status,
                c.ActionRemarks, c.CreatedBy, {string.Format(UserName, "c.CreatedBy")} CreatedByName, {string.Format(UserName, "c.ApprovedBy")} ApprovedByName
            FROM dbo.PhBatchCorrection c JOIN dbo.PhBatch b ON b.BatchId = c.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
            WHERE c.CompanyId = @companyId AND c.BranchId = @branchId AND (@status IS NULL OR c.Status = @status) ORDER BY c.CorrectionId DESC", new { companyId, branchId, status })).ToList();
    }

    public async Task<(int Id, string? Error)> SaveCorrectionAsync(int companyId, int branchId, int batchId, string newBatchNo, DateTime newExpiry, decimal newMrp, string reason, int userId)
    {
        newBatchNo = newBatchNo?.Trim().ToUpperInvariant() ?? "";
        newExpiry = new DateTime(newExpiry.Year, newExpiry.Month, DateTime.DaysInMonth(newExpiry.Year, newExpiry.Month));
        if (newBatchNo.Length is 0 or > 30) return (0, "Batch number is required (up to 30 characters).");
        if (newMrp <= 0) return (0, "MRP must be above zero.");
        if (string.IsNullOrWhiteSpace(reason)) return (0, "Give the reason for the correction (for the audit trail).");
        using var con = Open();
        using var tx = con.BeginTransaction();
        var b = await con.QuerySingleOrDefaultAsync<(int ItemId, string BatchNo, DateTime Expiry, decimal Mrp, decimal Rate, decimal Gst)>(
            "SELECT ItemId, BatchNo, ExpiryDate, Mrp, PurchaseRate, GstPercent FROM dbo.PhBatch WHERE BatchId = @batchId AND CompanyId = @companyId", new { batchId, companyId }, tx);
        if (b.BatchNo == null) { tx.Rollback(); return (0, "Batch not found."); }
        if (b.BatchNo == newBatchNo && b.Expiry == newExpiry && b.Mrp == newMrp) { tx.Rollback(); return (0, "Nothing is changed."); }
        if (newMrp < b.Rate * (1 + b.Gst / 100)) { tx.Rollback(); return (0, $"The new MRP is below the purchase cost with GST (₹{b.Rate * (1 + b.Gst / 100):0.00})."); }
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhBatchCorrection WHERE BatchId = @batchId AND Status = 'SUBMITTED'", new { batchId }, tx) > 0)
        { tx.Rollback(); return (0, "A correction of this batch is already waiting for approval."); }
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM dbo.PhBatch WHERE ItemId = @ItemId AND BatchNo = @newBatchNo AND Mrp = @newMrp AND BatchId <> @batchId", new { b.ItemId, newBatchNo, newMrp, batchId }, tx) > 0)
        { tx.Rollback(); return (0, "Another batch of this item already has that batch number and MRP."); }
        var no = await NextNoAsync(con, tx, branchId, "BCOR");
        var id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PhBatchCorrection (CompanyId, BranchId, DocNo, BatchId, OldBatchNo, NewBatchNo, OldExpiry, NewExpiry, OldMrp, NewMrp, Reason, CreatedBy)
            VALUES (@companyId, @branchId, @no, @batchId, @BatchNo, @newBatchNo, @Expiry, @newExpiry, @Mrp, @newMrp, @reason, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new { companyId, branchId, no, batchId, b.BatchNo, newBatchNo, b.Expiry, newExpiry, b.Mrp, newMrp, reason = reason.Trim(), userId }, tx);
        tx.Commit();
        return (id, null);
    }

    public async Task<string?> CorrectionActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId)
    {
        using var con = Open();
        using var tx = con.BeginTransaction();
        var c = await con.QuerySingleOrDefaultAsync<(string Status, int CreatedBy, int BatchId, string NewBatchNo, DateTime NewExpiry, decimal NewMrp, string OldBatchNo, DateTime OldExpiry, decimal OldMrp)>(
            "SELECT Status, CreatedBy, BatchId, NewBatchNo, NewExpiry, NewMrp, OldBatchNo, OldExpiry, OldMrp FROM dbo.PhBatchCorrection WITH (UPDLOCK) WHERE CorrectionId = @id AND CompanyId = @companyId AND BranchId = @branchId",
            new { id, companyId, branchId }, tx);
        if (c.Status != "SUBMITTED") { tx.Rollback(); return "Only a correction waiting for approval can be decided."; }
        if (c.CreatedBy == userId) { tx.Rollback(); return "You asked for this correction; another user must decide on it."; }
        if (action == "reject")
        {
            if (string.IsNullOrWhiteSpace(remarks)) { tx.Rollback(); return "Give the reason for rejecting."; }
            await con.ExecuteAsync("UPDATE dbo.PhBatchCorrection SET Status = 'REJECTED', ApprovedBy = @userId, ApprovedDate = GETDATE(), ActionRemarks = @remarks WHERE CorrectionId = @id", new { id, userId, remarks }, tx);
        }
        else if (action == "approve")
        {
            // the batch must still be as it was when the correction was asked
            var n = await con.ExecuteAsync(@"UPDATE dbo.PhBatch SET BatchNo = @NewBatchNo, ExpiryDate = @NewExpiry, Mrp = @NewMrp
                WHERE BatchId = @BatchId AND BatchNo = @OldBatchNo AND ExpiryDate = @OldExpiry AND Mrp = @OldMrp", new { c.BatchId, c.NewBatchNo, c.NewExpiry, c.NewMrp, c.OldBatchNo, c.OldExpiry, c.OldMrp }, tx);
            if (n == 0) { tx.Rollback(); return "The batch was changed since this correction was asked; ask again."; }
            await con.ExecuteAsync("UPDATE dbo.PhBatchCorrection SET Status = 'APPROVED', ApprovedBy = @userId, ApprovedDate = GETDATE(), ActionRemarks = @remarks WHERE CorrectionId = @id", new { id, userId, remarks }, tx);
        }
        else { tx.Rollback(); return "Unknown action."; }
        tx.Commit();
        return null;
    }

    // ── approvals ───────────────────────────────────────────────────────────────────────────────────────
    public async Task<int> MakerAsync(string table, int id)
    {
        var (t, k) = table switch
        {
            "adj" => ("PhAdjustment", "AdjustmentId"), "count" => ("PhStockCount", "StockCountId"), "corr" => ("PhBatchCorrection", "CorrectionId"), _ => throw new ArgumentException(table)
        };
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int?>($"SELECT CreatedBy FROM dbo.{t} WHERE {k} = @id", new { id }) ?? 0;
    }

    /// <summary>Approvers named in the Approval Matrix for this module (branch-wise matrix first, else company-wise); empty = no matrix.</summary>
    public async Task<List<int>> MatrixApproversAsync(int companyId, string moduleCode, int branchId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<int>(@"SELECT a.UserId FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = (
                SELECT TOP 1 m.Matrix_ID FROM dbo.ApprovalMatrix m JOIN dbo.ApprovalModule am ON am.Module_Code = m.Module_Code AND am.IsActive = 1
                WHERE m.CompanyId = @companyId AND m.Module_Code = @moduleCode AND m.IsActive = 1 AND (m.Scope = 'C' OR m.Branch_ID = @branchId)
                  AND EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover x WHERE x.Matrix_ID = m.Matrix_ID)
                ORDER BY CASE m.Scope WHEN 'B' THEN 0 ELSE 1 END)", new { companyId, moduleCode, branchId })).ToList();
    }

    // ── dashboard ───────────────────────────────────────────────────────────────────────────────────────
    public async Task<PhDashboard> DashboardAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        var p = new { companyId, branchId };
        var d = await con.QuerySingleAsync<PhDashboard>(@"
            DECLARE @today DATE = CAST(GETDATE() AS DATE), @month DATE = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);
            SELECT
              ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND SaleDate >= @today), 0) SalesToday,
              (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND SaleDate >= @today) BillsToday,
              ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSaleReturn WHERE BranchId = @branchId AND ReturnDate >= @today), 0) ReturnsToday,
              ISNULL((SELECT SUM(CASE WHEN pm.MethodCode = 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                      WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @branchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) CashToday,
              ISNULL((SELECT SUM(CASE WHEN pm.MethodCode <> 'CASH' THEN pd.PaidAmount END) FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                      WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @branchId AND pd.IsActive = 1 AND pd.CreatedDate >= @today), 0) NonCashToday,
              ISNULL((SELECT SUM(NetAmount - PaidAmount) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND SaleDate >= @today AND NetAmount > PaidAmount), 0) CreditToday,
              ISNULL((SELECT SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND SaleDate >= @month), 0) SalesMonth,
              ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @branchId AND Status = 'POSTED' AND GrnDate >= @today), 0) PurchasesToday,
              ISNULL((SELECT SUM(NetAmount) FROM dbo.PhGrn WHERE BranchId = @branchId AND Status = 'POSTED' AND GrnDate >= @month), 0) PurchasesMonth,
              ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0), 0) StockValue,
              ISNULL((SELECT SUM(s.QtyOnHand * b.Mrp / i.ConversionQty) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0), 0) StockMrpValue,
              (SELECT COUNT(DISTINCT ItemId) FROM dbo.PhStock WHERE BranchId = @branchId AND QtyOnHand > 0) ItemsInStock,
              (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today) Expired,
              ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate <= @today), 0) ExpiredValue,
              (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)) Exp30,
              ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > @today AND b.ExpiryDate <= DATEADD(DAY, 30, @today)), 0) Exp30Value,
              (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)) Exp60,
              ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 30, @today) AND b.ExpiryDate <= DATEADD(DAY, 60, @today)), 0) Exp60Value,
              (SELECT COUNT(*) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)) Exp90,
              ISNULL((SELECT SUM(s.QtyOnHand * b.LandedCost) FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId WHERE s.BranchId = @branchId AND s.QtyOnHand > 0 AND b.ExpiryDate > DATEADD(DAY, 60, @today) AND b.ExpiryDate <= DATEADD(DAY, 90, @today)), 0) Exp90Value,
              ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND BalanceDue > 0), 0) CreditDue,
              (SELECT COUNT(*) FROM dbo.PhPurchaseIndent WHERE BranchId = @branchId AND Status = 'SUBMITTED') PendIndents,
              (SELECT COUNT(*) FROM dbo.PhPurchaseOrder WHERE BranchId = @branchId AND Status IN ('DRAFT', 'APPROVED', 'PARTIAL')) PendPos,
              (SELECT COUNT(*) FROM dbo.PhGrn WHERE BranchId = @branchId AND Status = 'DRAFT') DraftGrns,
              (SELECT COUNT(*) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'HOLD') HeldBills,
              (SELECT COUNT(*) FROM dbo.PhTransfer WHERE FromBranchId = @branchId AND Status = 'REQUESTED') ToDispatch,
              (SELECT COUNT(*) FROM dbo.PhTransfer WHERE ToBranchId = @branchId AND Status = 'DISPATCHED') ToReceive,
              (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @branchId AND Kind = 'ADJUST' AND Status = 'SUBMITTED') PendAdjust,
              (SELECT COUNT(*) FROM dbo.PhAdjustment WHERE BranchId = @branchId AND Kind = 'WRITEOFF' AND Status = 'SUBMITTED') PendWriteOff,
              (SELECT COUNT(*) FROM dbo.PhStockCount WHERE BranchId = @branchId AND Status IN ('COUNTING', 'SUBMITTED')) PendCounts,
              (SELECT COUNT(*) FROM dbo.PhBatchCorrection WHERE BranchId = @branchId AND Status = 'SUBMITTED') PendCorrections", p);
        var reorder = (await con.QueryAsync<(string, decimal, decimal, string)>(@"SELECT TOP 15 i.ItemName, ISNULL(st.Qty, 0) / i.ConversionQty, ISNULL(ib.ReorderLevel, i.ReorderLevel), pu.UomCode
            FROM dbo.PhItem i JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
            OUTER APPLY (SELECT SUM(QtyOnHand) Qty FROM dbo.PhStock s WHERE s.BranchId = @branchId AND s.ItemId = i.ItemId) st
            WHERE i.CompanyId = @companyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
              AND ISNULL(st.Qty, 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)
            ORDER BY ISNULL(st.Qty, 0) / i.ConversionQty / NULLIF(ISNULL(ib.ReorderLevel, i.ReorderLevel), 0)", p)).ToList();
        d.Reorder = reorder;
        d.BelowReorder = await con.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM dbo.PhItem i LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
            WHERE i.CompanyId = @companyId AND i.IsActive = 1 AND ISNULL(ib.IsStocked, 1) = 1 AND ISNULL(ib.ReorderLevel, i.ReorderLevel) > 0
              AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @branchId AND s.ItemId = i.ItemId), 0) / i.ConversionQty <= ISNULL(ib.ReorderLevel, i.ReorderLevel)", p);
        d.OutOfStock = await con.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM dbo.PhItem i WHERE i.CompanyId = @companyId AND i.IsActive = 1
            AND ISNULL((SELECT SUM(QtyOnHand) FROM dbo.PhStock s WHERE s.BranchId = @branchId AND s.ItemId = i.ItemId), 0) <= 0
            AND EXISTS (SELECT 1 FROM dbo.PhStockLedger l WHERE l.BranchId = @branchId AND l.ItemId = i.ItemId)", p);
        d.TopItems = (await con.QueryAsync<(string, decimal, decimal)>(@"SELECT TOP 10 i.ItemName, SUM(x.Qty - x.ReturnedQty), SUM(x.Amount * (x.Qty - x.ReturnedQty) / x.Qty)
            FROM dbo.PhSaleDtl x JOIN dbo.PhSale s ON s.SaleId = x.SaleId JOIN dbo.PhItem i ON i.ItemId = x.ItemId
            WHERE s.BranchId = @branchId AND s.Status = 'POSTED' AND s.SaleDate >= DATEADD(DAY, -30, GETDATE()) GROUP BY i.ItemName ORDER BY 3 DESC", p)).ToList();
        d.Last7 = (await con.QueryAsync<(DateTime, decimal)>(@"SELECT CAST(SaleDate AS DATE), SUM(NetAmount) FROM dbo.PhSale WHERE BranchId = @branchId AND Status = 'POSTED' AND SaleDate >= DATEADD(DAY, -6, CAST(GETDATE() AS DATE))
            GROUP BY CAST(SaleDate AS DATE) ORDER BY 1", p)).ToList();
        d.SupplierDue = await con.ExecuteScalarAsync<decimal>(@"SELECT ISNULL(SUM(g.NetAmount), 0) - ISNULL((SELECT SUM(a.Amount) FROM dbo.PhSupplierPaymentAlloc a JOIN dbo.PhSupplierPayment sp ON sp.PaymentId = a.PaymentId WHERE sp.BranchId = @branchId AND sp.Status = 'POSTED'), 0)
            FROM dbo.PhGrn g WHERE g.BranchId = @branchId AND g.Status = 'POSTED'", p);
        d.NearExpiry = (await StockAsync(companyId, branchId, null, null, "near")).OrderBy(r => r.ExpiryDate).Take(12).ToList();
        return d;
    }
}
