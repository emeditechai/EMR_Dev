using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

// ── Item Master ──────────────────────────────────────────────────────────────────────────────────
public sealed class QcItemSaveRequest
{
    public int? ItemId { get; set; }
    public string? ItemName { get; set; }
    public int CategoryId { get; set; }
    public int PurchaseUnitId { get; set; }
    public int ConsumptionUnitId { get; set; }
    public decimal PackSize { get; set; }
    public decimal PurchaseRate { get; set; }
    public decimal? GstPercent { get; set; }
    public string? HsnCode { get; set; }
    public string? Manufacturer { get; set; }
    public string? StorageTemp { get; set; }
    public int? OpenStabilityDays { get; set; }
    public int? MinShelfLifeDays { get; set; }
    public decimal? ReorderLevel { get; set; }
    public decimal? MinStock { get; set; }
    public decimal? MaxStock { get; set; }
    public bool? IsLotTracked { get; set; }
    public bool? IsExpiryTracked { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
}

public sealed class QcStatusRequest
{
    public int Id { get; set; }
    public bool Status { get; set; }
}

public class QcItemsController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcItemsController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await LookupsAsync();
        return View("~/Views/Quality/Items.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? search, int? categoryId, bool? status) =>
        QueryAsync("dbo.usp_Qc_Item_List", new { CompanyId, Search = search, CategoryId = categoryId, Status = status });

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcItemSaveRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new
        {
            r.ItemId, CompanyId, r.ItemName, r.CategoryId, r.PurchaseUnitId, r.ConsumptionUnitId, r.PackSize, r.PurchaseRate, r.GstPercent,
            r.HsnCode, r.Manufacturer, r.StorageTemp, r.OpenStabilityDays, r.MinShelfLifeDays, r.ReorderLevel, r.MinStock, r.MaxStock,
            r.IsLotTracked, r.IsExpiryTracked, r.Remarks, r.Status, UserId
        });
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Qc_Item_Save", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }, r.ItemId is > 0 ? "QC.ItemUpdated" : "QC.ItemCreated", $"Item '{r.ItemName}' saved");

    [HttpPost]
    public Task<IActionResult> SetStatus([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Item_SetStatus", new { ItemId = r.Id, CompanyId, r.Status, Delete = false, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.ItemStatus", $"Item #{r.Id} set {(r.Status ? "active" : "inactive")}");

    [HttpPost]
    public Task<IActionResult> Delete([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Item_SetStatus", new { ItemId = r.Id, CompanyId, Status = false, Delete = true, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.ItemDeleted", $"Item #{r.Id} deleted");
}

// ── Supplier Master ─────────────────────────────────────────────────────────────────────────────
public sealed class QcSupplierSaveRequest
{
    public int? SupplierId { get; set; }
    public string? SupplierName { get; set; }
    public string? ContactPerson { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public string? Address { get; set; }
    public string? Gstin { get; set; }
    public string? Pan { get; set; }
    public int? PaymentTermsDays { get; set; }
    public bool IsApproved { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
}

public class QcSuppliersController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcSuppliersController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public IActionResult Index() => View("~/Views/Quality/Suppliers.cshtml");

    [HttpGet]
    public Task<IActionResult> List(string? search, bool? status, bool? approved) =>
        QueryAsync("dbo.usp_Qc_Supplier_List", new { CompanyId, Search = search, Status = status, Approved = approved });

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcSupplierSaveRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new
        {
            r.SupplierId, CompanyId, r.SupplierName, r.ContactPerson, r.Phone, r.Email, r.Address, r.Gstin, r.Pan, r.PaymentTermsDays,
            r.IsApproved, r.Remarks, r.Status, UserId
        });
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Qc_Supplier_Save", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }, r.SupplierId is > 0 ? "QC.SupplierUpdated" : "QC.SupplierCreated", $"Supplier '{r.SupplierName}' saved");

    [HttpPost]
    public Task<IActionResult> SetStatus([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Supplier_SetStatus", new { SupplierId = r.Id, CompanyId, r.Status, Delete = false, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.SupplierStatus", $"Supplier #{r.Id} set {(r.Status ? "active" : "inactive")}");

    [HttpPost]
    public Task<IActionResult> Delete([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Supplier_SetStatus", new { SupplierId = r.Id, CompanyId, Status = false, Delete = true, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.SupplierDeleted", $"Supplier #{r.Id} deleted");
}

// ── Store / Location ───────────────────────────────────────────────────────────────────────────
public sealed class QcStoreSaveRequest
{
    public int? StoreId { get; set; }
    public int BranchId { get; set; }
    public string? StoreName { get; set; }
    public string? StoreType { get; set; }
    public int? DepartmentId { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
}

public class QcStoresController(IDbConnectionFactory db, IAuditLogService audit, ILogger<QcStoresController> logger) : QcControllerBase(db, audit, logger)
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Lookups = await LookupsAsync();
        return View("~/Views/Quality/Stores.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(int? branchId, string? search, bool? status) =>
        QueryAsync("dbo.usp_Qc_Store_List", new { CompanyId, BranchId = branchId, Search = search, Status = status });

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcStoreSaveRequest r) => RunAsync(async con =>
    {
        var p = new DynamicParameters(new { r.StoreId, CompanyId, r.BranchId, r.StoreName, r.StoreType, r.DepartmentId, r.Remarks, r.Status, UserId });
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Qc_Store_Save", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }, r.StoreId is > 0 ? "QC.StoreUpdated" : "QC.StoreCreated", $"Store '{r.StoreName}' saved");

    [HttpPost]
    public Task<IActionResult> SetStatus([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Store_SetStatus", new { StoreId = r.Id, CompanyId, r.Status, Delete = false, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.StoreStatus", $"Store #{r.Id} set {(r.Status ? "active" : "inactive")}");

    [HttpPost]
    public Task<IActionResult> Delete([FromBody] QcStatusRequest r) => RunAsync(async con =>
    {
        await con.ExecuteAsync("dbo.usp_Qc_Store_SetStatus", new { StoreId = r.Id, CompanyId, Status = false, Delete = true, UserId }, commandType: CommandType.StoredProcedure);
        return null;
    }, "QC.StoreDeleted", $"Store #{r.Id} deleted");
}
