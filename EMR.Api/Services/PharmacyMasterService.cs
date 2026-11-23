using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IPharmacyMasterService
{
    Task EnsureMastersAsync(int companyId, int branchId);
    Task<string> BranchCodeAsync(int branchId);
    bool IsKnownMaster(string key);
    Task<List<IDictionary<string, object?>>> ListAsync(string key, int companyId, int branchId);
    Task<Dictionary<string, List<PhOptionDto>>> LookupsAsync(int companyId);
    Task<PhSaveResult> SaveAsync(string key, PhMasterSaveRequest req);
    Task<List<PhItemListRowDto>> ItemsAsync(int companyId, int branchId, string? search, int? categoryId, string? schedule, int? manufacturerId, bool? active, int page, int pageSize);
    Task<List<PhItemListRowDto>> SearchItemsAsync(int companyId, string q, int take);
    Task<List<PhItemListRowDto>> SubstitutesAsync(int companyId, int itemId);
    Task<PhItemDto?> ItemAsync(int companyId, int branchId, int itemId);
    Task<PhItemCountsDto> ItemCountsAsync(int companyId);
    Task<PhItemLookupsDto> ItemLookupsAsync(int companyId);
    Task<PhSaveResult> SaveItemAsync(PhItemSaveRequest req);
}

/// <summary>
/// Pharmacy masters (SQLScripts/2343 tables, 2356 procedures). Stored procedures only. The simple masters are one
/// GetList / Save procedure pair per table; the master key from the request picks the pair from the list below,
/// and the field values become that procedure's parameters (an unknown field is refused by SQL Server).
/// </summary>
public class PharmacyMasterService(IDbConnectionFactory db) : IPharmacyMasterService
{
    private static readonly Dictionary<string, string> Tables = new(StringComparer.OrdinalIgnoreCase)
    {
        ["generics"] = "PhGeneric", ["manufacturers"] = "PhManufacturer", ["suppliers"] = "PhSupplier", ["categories"] = "PhCategory",
        ["dosageforms"] = "PhDosageForm", ["units"] = "PhUom", ["hsn"] = "PhHsn", ["schedules"] = "PhDrugSchedule",
        ["pricerules"] = "PhPriceRule", ["discounts"] = "PhDiscountScheme", ["customers"] = "PhCustomer", ["reasons"] = "PhReason",
        ["numberseries"] = "PhNumberSeries", ["stores"] = "PhStore", ["supplierschemes"] = "PhSupplierScheme", ["rxmap"] = "PhRxGenericMap", ["interactions"] = "PhDrugInteraction"
    };

    public bool IsKnownMaster(string key) => Tables.ContainsKey(key);

    public async Task EnsureMastersAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Pharmacy_EnsureMasters", new { CompanyId = companyId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<string> BranchCodeAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<string?>("dbo.usp_Api_Ph_BranchCode", new { BranchId = branchId }, commandType: CommandType.StoredProcedure)
               ?? branchId.ToString();
    }

    public async Task<List<IDictionary<string, object?>>> ListAsync(string key, int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync($"dbo.usp_Api_{Tables[key]}_GetList", new { CompanyId = companyId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
        return rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();
    }

    public async Task<Dictionary<string, List<PhOptionDto>>> LookupsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Api_PhMaster_Lookups", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        return new()
        {
            ["states"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["mainCategories"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["categories"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["schemes"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["suppliers"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["items"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["generics"] = (await m.ReadAsync<PhOptionDto>()).ToList(),
            ["medications"] = (await m.ReadAsync<PhOptionDto>()).ToList()
        };
    }

    public async Task<PhSaveResult> SaveAsync(string key, PhMasterSaveRequest req)
    {
        if (Tables[key] == "PhDrugSchedule") return new PhSaveResult { Error = "This list cannot be changed." };
        var p = new DynamicParameters();
        p.Add("Id", req.Id); p.Add("CompanyId", req.CompanyId); p.Add("BranchId", req.BranchId); p.Add("UserId", req.UserId); p.Add("IsActive", req.IsActive);
        foreach (var (name, value) in req.Values)
        {
            if (!IsColumnName(name)) return new PhSaveResult { Error = "Unknown field " + name };
            p.Add(name, ToValue(value));
        }
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<PhSaveResult>($"dbo.usp_Api_{Tables[key]}_Save", p, commandType: CommandType.StoredProcedure);
    }

    private static bool IsColumnName(string s) => s.Length is > 0 and <= 64 && s.All(ch => char.IsLetterOrDigit(ch) || ch == '_');

    /// <summary>JSON value as the plain value the procedure parameter expects (dates arrive as yyyy-MM-dd text).</summary>
    private static object? ToValue(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number => v.TryGetInt32(out var i) ? (object)i : v.GetDecimal(),
        _ => v.GetString()
    };

    // ── Item Master ────────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhItemListRowDto>> ItemsAsync(int companyId, int branchId, string? search, int? categoryId, string? schedule, int? manufacturerId, bool? active, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhItemListRowDto>("dbo.usp_Api_PhItem_GetList", new
        {
            CompanyId = companyId, BranchId = branchId, Search = search, CategoryId = categoryId, Schedule = schedule,
            ManufacturerId = manufacturerId, Active = active, Page = page, PageSize = pageSize
        }, commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<List<PhItemListRowDto>> SearchItemsAsync(int companyId, string q, int take)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhItemListRowDto>("dbo.usp_Api_PhItem_Search", new { CompanyId = companyId, Q = q, Take = take },
            commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<List<PhItemListRowDto>> SubstitutesAsync(int companyId, int itemId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhItemListRowDto>("dbo.usp_Api_PhItem_Substitutes", new { CompanyId = companyId, ItemId = itemId },
            commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<PhItemDto?> ItemAsync(int companyId, int branchId, int itemId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PhItemDto>("dbo.usp_Api_PhItem_GetById", new { CompanyId = companyId, BranchId = branchId, ItemId = itemId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PhItemCountsDto> ItemCountsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<PhItemCountsDto>("dbo.usp_Api_PhItem_Counts", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<PhItemLookupsDto> ItemLookupsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Api_PhItem_Lookups", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        return new PhItemLookupsDto
        {
            Generics = (await m.ReadAsync<PhOptionDto>()).ToList(),
            Manufacturers = (await m.ReadAsync<PhOptionDto>()).ToList(),
            Categories = (await m.ReadAsync<PhOptionDto>()).ToList(),
            DosageForms = (await m.ReadAsync<PhOptionDto>()).ToList(),
            Uoms = (await m.ReadAsync<PhOptionDto>()).ToList(),
            Hsn = (await m.ReadAsync<PhHsnOptionDto>()).ToList(),
            Schedules = (await m.ReadAsync<PhScheduleOptionDto>()).ToList()
        };
    }

    public async Task<PhSaveResult> SaveItemAsync(PhItemSaveRequest req)
    {
        var f = req.Item;
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<PhSaveResult>("dbo.usp_Api_PhItem_Save", new
        {
            f.ItemId, req.CompanyId, req.BranchId, req.UserId,
            f.ItemCode, f.ItemName, f.GenericId, f.ManufacturerId, f.CategoryId, f.DosageFormId, f.Strength, f.PackSize, f.ScheduleCode, f.HsnId,
            f.PurchaseUomId, f.SaleUomId, f.ConversionQty, f.AllowLooseSale, f.IsColdChain, f.IsHighAlert, f.IsLasa, f.IsReturnable, f.IsDiscountAllowed,
            f.PrescriptionRequired, f.Barcode, f.ReorderLevel, f.MinQty, f.MaxQty, f.LeadDays, f.Remarks, f.IsActive,
            f.RackNo, f.BranchReorderLevel, f.BranchMinQty, f.BranchMaxQty, f.IsStocked, f.VedClass
        }, commandType: CommandType.StoredProcedure);
    }
}
